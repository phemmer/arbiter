class Arbiter
	require 'corosync_commander'
	require 'corosync/cmap'
	require 'socket'
	require 'shellwords'
	require 'json'

	def self.finalizer(sockpath)
		proc do
			File.unlink sockpath
		end
	end
	def initialize()
		sock_path = ENV['SOCKET_PATH'] || '/var/run/arbiter.sock'
		if File.exists?(sock_path)
			begin
				sock = UNIXSocket.new(sock_path)
				abort "There is another process using #{sock_path}!"
			rescue => e
				File.unlink(sock_path)
			end
		end

		@status = {}
		@status_mutex = Mutex.new

		@locks = {}
		@locks_mutex = Mutex.new

		@cc = CorosyncCommander.new
		@cc.commands.register 'lock', &self.method(:cc_lock)
		@cc.commands.register 'unlock', &self.method(:cc_unlock)
		@cc.commands.register 'lock request', &self.method(:cc_lock_request)
		@cc.commands.register 'update', &self.method(:cc_update)
		@cc.on_confchg &self.method(:cc_confchg)

		@cmap = Corosync::CMAP.new(true)

		@healthy_threshold_percent = (ENV['HEALTHY_THRESHOLD_PERCENT'] || 50).to_i

		@cc.join('arbiter')

		@server = UNIXServer.open(sock_path)
		@client_bufs = {}
		@client_locks = {}
		ObjectSpace.define_finalizer(self, self.class.finalizer(sock_path))
	end

	def run
		client_socks = []
		loop do
			socks = select([@server] + client_socks)
			socks[0].each do |sock|
				if sock == @server then
					client_socks << sock.accept
				else
					begin
						client_readline(sock)
					rescue => e
						$stderr.puts "Unknown error on client #{sock.fileno}"
						$stderr.puts "#{e} @ #{e.backtrace.first}"
						client_cmd(sock.fileno, 'unlock')
						client_socks.delete(sock)
						@client_bufs.delete(sock.fileno)
						sock.close if !sock.closed?
					rescue EOFError => e # client has disconnected
						client_cmd(sock.fileno, 'unlock')
						client_socks.delete(sock)
						@client_bufs.delete(sock.fileno)
						sock.close if !sock.closed?
					end
				end
			end
		end
	end
	def client_readline(sock)
		client_id = sock.fileno
		buf = @client_bufs[client_id] ||= ''
		buf.concat sock.read_nonblock(4096)
		lines = buf.split("\n", -1)
		while lines.size > 1 do # will loop until the last line. lines should be terminated by a newline, so the last line will be empty or incomplete
			line = lines.shift
			sock.puts client_cmd(client_id, line)
		end
		@client_bufs[client_id] = lines.last
	end
	def client_cmd(client_id, line)
		args = Shellwords.split(line)
		cmd = args.shift
		if cmd == 'lock' then
			return false if @client_locks.has_key?(client_id) # already locked

			lock_id, sender = @cc.execute([], 'lock request', args.join(' ')).to_enum(Exception).find{|sender, lock_id| !lock_id.nil?}
			if lock_id then
				@client_locks[client_id] = lock_id
				return true
			end

			return false
		elsif cmd == 'unlock' then
			return unless @client_locks[client_id] # not locked

			@cc.execute([], 'unlock', nil, @client_locks[client_id])
			@client_locks.delete(client_id)
			nil
		elsif cmd == 'status' then
			status = {}
			status[:healthy_threshold] = self.healthy_threshold
			status[:healthy_count] = self.healthy_count
			status[:node_count] = self.node_count
			@status_mutex.synchronize do
				status[:nodes] = @status.dup
				@locks_mutex.synchronize do
					@locks.each do |nodeid, node_locks|
						message = node_locks.values.map {|lock| "#{lock[0]} - #{lock[1]}"}
						lock_time = node_locks.values.map {|lock| lock[2]}.sort.first
						status[:nodes][nodeid] = ['locked', message, lock_time]
					end
				end
			end
			status.to_json
		elsif cmd == 'set' || cmd == 'update' then
			@cc.execute([], 'update', args.shift, args.join(' '), Time.new.to_i)
			nil
		end
	end

	def status(nodeid)
		status = 'unknown'
		@status_mutex.synchronize do
			return 'unknown' if !node_status = @status[nodeid]
			return node_status[0] if node_status[0] != 'healthy'
		end
		@locks_mutex.synchronize do
			return 'locked' if @locks.has_key?(nodeid)
		end
		return 'healthy'
	end
	def healthy?(nodeid)
		status == 'healthy'
	end
	def healthy_count
		count = 0
		@status_mutex.synchronize do
			@status.each do |nodeid, node_status|
				next if node_status[0] != 'healthy'
				@locks_mutex.synchronize do
					count += 1 unless @locks.has_key?(nodeid)
				end
			end
		end

		count
	end
	def node_count
		cmap_nodes = []
		@cmap.keys('nodelist.node').each do |key|
			num = key.split('.')[2]
			cmap_nodes << num unless cmap_nodes.include?(num)
		end
		cmap_nodes.size
	end
	def healthy_threshold
		node_count = self.node_count

		healthy_threshold = @healthy_threshold_percent.to_f / 100 * node_count
		healthy_threshold = healthy_threshold.ceil
		healthy_threshold -= 1 if healthy_threshold == node_count
		healthy_threshold
	end

	def cc_lock_request(sender, message)
		puts "CC_LOCK_REQUEST nodeid=#{sender.nodeid} message=#{message.inspect}"
		return nil unless @cc.leader?
		puts "STATUS=#{status(sender.nodeid).inspect} HEALTHY_COUNT=#{healthy_count.inspect} HEALTHY_THRESHOLD=#{healthy_threshold.inspect}"
		return false if status(sender.nodeid) == 'healthy' and healthy_count - 1 < healthy_threshold
		return false if status(sender.nodeid) == 'unknown' and healthy_count < healthy_threshold # it might be healthy, it might not. But in case it is healthy, don't grant a lock if the cluster is degraded

		now = Time.new.to_i
		lock_id = nil
		lock = nil
		@locks_mutex.synchronize do
			@locks[sender.nodeid] ||= {}
			lock_id = SecureRandom.uuid
			lock = @locks[sender.nodeid][lock_id] = [sender.to_s, message, now]
		end
		@cc.execute([], 'lock', sender.nodeid, lock_id, lock) # inform everyone else in case someone else has to take over as leader
		return lock_id
	end
	def cc_lock(sender, locked_nodeid, lock_id, lock)
		puts "CC_LOCK locked_nodeid=#{locked_nodeid.inspect} lock_id=#{lock_id.inspect} lock=#{lock.inspect}"

		@locks_mutex.synchronize do
			@locks[locked_nodeid] ||= {}
			@locks[locked_nodeid][lock_id] = lock
		end
		nil
	end
	def cc_unlock(sender, locked_nodeid, lock_id)
		puts "CC_UNLOCK sender=#{sender.to_s} locked_nodeid=#{locked_nodeid.inspect} lock_id=#{lock_id.inspect}"

		locked_nodeid = sender.nodeid if locked_nodeid.nil?
		@locks_mutex.synchronize do
			return unless @locks[locked_nodeid]
			return unless @locks[locked_nodeid][lock_id]
			@locks[locked_nodeid].delete(lock_id)
			@locks.delete(locked_nodeid) unless @locks[locked_nodeid].size > 0
		end
		@status_mutex.synchronize do
			@status[locked_nodeid] = ['unknown', 'unlocked', Time.new.to_i]
		end
		nil
	end
	def cc_update(sender, status, message, time)
		puts "CC_UPDATE nodeid=#{sender.nodeid} status=#{status.inspect} message=#{message.inspect}"

		@status_mutex.synchronize do
			@status[sender.nodeid] = [status, message, time]
		end
		nil
	end
	def cc_confchg(members, members_leave, members_join)
		puts "CC_CONFCHG members=#{members.map{|m| m.to_s}.inspect} members_leave=#{members_leave.map{|m| m.to_s}.inspect} members_join=#{members_join.map{|m| m.to_s}.inspect}"

		members_leave.each do |member|
			@status_mutex.synchronize do
				@status.delete(member.nodeid)
			end
			@locks_mutex.synchronize do
				@locks.delete(member.nodeid)
			end
		end

		if members_join.size > 0 then
			# new node just joined. send our status/locks to it
			nodeid = @cc.cpg.member.nodeid
			@status_mutex.synchronize do
				status = @status[nodeid]
				if !status.nil? then
					@cc.execute(members_join, 'update', *status)
				end
				@locks_mutex.synchronize do
					locks = @locks[nodeid]
					if !locks.nil? then
						locks.each do |lock_id, lock|
							@cc.execute(members_join, 'lock', nodeid, lock_id, lock)
						end
					end
				end
			end
		end
	end
end
