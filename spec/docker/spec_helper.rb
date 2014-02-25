RSpec.configure do |config|
  config.color_enabled = true
  config.formatter = :documentation
end

$:.unshift('/home/phemmer/git/docker-remote/lib')
require 'docker'
$docker = Docker.new
$docker.container_auto_remove = true
$docker.image_auto_remove = true

module SDockerImage
	require 'shellwords'

	SOURCE_IMAGE = 'ubuntu:12.04'
	NAME = 'local:arbiter'

	PROJECT_NAME = %x{git rev-parse --show-toplevel}.chomp.split('/').last
	TMPDIR= "/tmp/sdocker-#{$$}"

	def self.dir_finalizer(path)
		proc { FileUtils.rm_rf(path) }
	end

	def self.id
		return @id if @id

		Dir.mkdir(TMPDIR)
		ObjectSpace.define_finalizer(self, self.dir_finalizer(TMPDIR))
		
		image = $docker.images[NAME]
		if image then
			@id = image.id
			return @id
		end


		container = $docker.containers.create('Image' => SOURCE_IMAGE, 'Cmd' => ['bash','-c',<<EOI1])
# core
set -x
apt-get update
apt-get install -y ssh
mkdir /var/run/sshd
mkdir /root/.ssh
chmod 600 root/.ssh
passwd -d root
sed -i -e '/PermitEmptyPasswords/d' /etc/ssh/sshd_config
echo 'PermitEmptyPasswords yes' >> /etc/ssh/sshd_config
sed -i -e 's/nullok_secure/nullok/' /etc/pam.d/common-auth

########################################
# ruby

set -e

echo 'deb [trusted=yes] http://ppa.launchpad.net/brightbox/ruby-ng-experimental/ubuntu precise main' > /etc/apt/sources.list.d/brightbox-ruby.list
wget -q -O - 'http://keyserver.ubuntu.com:11371/pks/lookup?op=get&search=0xF5DA5F09C3173AA6' | apt-key add -
apt-get update -o Dir::Etc::sourcelist=sources.list.d/brightbox-ruby.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0

echo 'deb [trusted=yes] http://s3.amazonaws.com/cloudcom-packages/ubuntu precise/' > /etc/apt/sources.list.d/cloud.list
apt-get update -o Dir::Etc::sourcelist=sources.list.d/cloud.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0

apt-get -y install ruby2.0 ruby2.0-dev ruby-switch build-essential
ruby-switch --set ruby2.0

cat > /etc/gemrc <<'EOI2'
---
gem: --no-rdoc --no-ri
EOI2

gem install bundler

########################################
# corosync

apt-get -y install corosync libcorosync-common4 libcorosync-common-dev libcpg-dev libquorum-dev libvotequorum-dev libcmap-dev
cat > /etc/corosync/corosync.conf.template <<'EOI2'
totem {
  version: 2
  token: 2000
  token_retransmits_before_loss_const: 10
  vsftype: none
  clear_node_high_bit: yes
  secauth: off
  transport: udpu
}

logging {
  fileline: off
  syslog_facility: local2
  syslog_priority: debug
}

quorum {
  provider: corosync_votequorum
  allow_downscale: 1
}

nodelist {
#NODELIST#
}
EOI2

cat > /etc/init/corosync.conf <<'EOI2'
description "Corosync clustering service"

expect fork

start on runlevel [2345]
stop on runlevel [!2345]

exec /usr/sbin/corosync

post-start script
  timeout 10 sh <<'EOI' || { stop; exit 1 }
    while ! corosync-cfgtool -s >/dev/null 2>&1; do sleep 0.5; done
EOI
end script

respawn
respawn limit 5 60

# vim: set ft=upstart ts=2 sw=2 tw=0 :
EOI2

rm /etc/init.d/corosync

:
EOI1
		io = container.attach([:stdout,:stderr]) {|io, stream, data| {:stdout => $stdout, :stderr => $stderr}[stream].write(data)}
		container.start
		io.wait
		image = container.to_image(:repo => NAME.split(':').first, :tag => NAME.split(':').last)
		image.auto_remove = false

		@id = image.id
	end
end

class SDockerContainer
	require 'shellwords'

	def self.sync
		@@containers ||= {}

		hostips = Hash[@@containers.values.map{|c| [c.hostname, c.ip]}]
		@@containers.values.each do |container|
			script = ''
			nodelist = ''
			hostips.each do |host,ip|
				#script << "grep -q #{host} /etc/hosts || echo '#{ip} #{host}' >> /etc/hosts\n"
				#nodelist << "  node { ring0_addr: #{host} }\n"
				nodelist << "  node {\n    ring0_addr: #{ip}\n  }\n"
			end
			script << "sed -e 's/#NODELIST#/#{nodelist.gsub("\n", "\\\n")}/' /etc/corosync/corosync.conf.template > /etc/corosync/corosync.conf\n"
			script << "pidof corosync > /dev/null && corosync-cfgtool -R >/dev/null || corosync\n"
			system(*(container.sshcmd(script)))
		end
	end

	def initialize(cmd, version = nil)
		@@containers ||= {}
		unless ENV['debug'] then
			stderr_fd = $stderr.fcntl(Fcntl::F_DUPFD)
			File.open('/dev/null','w') {|fh| $stderr.reopen(fh)}
		end

		@container = $docker.containers.create(
			'Image' => SDockerImage.id,
			'Hostname' => hostname,
			'Cmd' => ['sh','-c','exec `which sshd` -D']
		)
		puts "Building container #{@container.id}"
		@container.start
		Timeout.timeout(15) do
			system(*(sshcmd('true')))
			break if $?.exitstatus == 0
			sleep 1
		end

		@@containers[@container.id] = self
		self.class.sync

		puts "Building package version=#{version}"
		package_io = IO.popen(['rake','package',"source=#{version}","out=/dev/stdout"],'r')
		system(*(sshcmd("mkdir /#{SDockerImage::PROJECT_NAME}; tar -xzC /#{SDockerImage::PROJECT_NAME} --strip-components=1")), 0 => package_io)
		package_io.close

		puts "Installing package"
		cmd("bundle install --local")

		puts "Executing #{cmd}"
		cmd("#{cmd} >/tmp/log 2>&1 &")

		puts "Build complete"
		if stderr_fd then
			$stderr.reopen(IO.new(stderr_fd))
		end
	end
	def terminate
		self.cmd('pkill corosync')
		@@containers.delete(@container.id)
		self.class.sync
	end

	def hostname
		rnd = Random.new(self.object_id)
		(0...4).map{('a'..'z').to_a[rnd.rand(26)]}.join
	end
	def ip
		@container.ipaddress
	end

	def sshcmd(*args)
		cmd_string = args.size > 1 ? Shellwords.shelljoin(args) : args[0]
		['ssh', '-o', "UserKnownHostsFile=#{SDockerImage::TMPDIR}/known_hosts", '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes', '-o', 'ForwardX11=no', "root@#{ip}", cmd_string]
	end

	def cmd(*args)
		cmd_string = "cd /#{SDockerImage::PROJECT_NAME}; " + (args.size > 1 ? Shellwords.shelljoin(args) : args[0])
		%x{#{Shellwords.shelljoin(sshcmd(cmd_string))}}
	end
end

module SDocker
	def self.launch(count)
		containers = []
		count.times do |i|
			containers << SDockerContainer.new('bin/arbiter start')
		end
		containers
	end
end


########################################

REPO_TOP = %x{git rev-parse --show-toplevel}.chomp
if File.exists?("#{REPO_TOP}/VERSION") then
	VERSION = VERSION_MINOR = File.read("#{REPO_TOP}/VERSION").chomp
else
	VERSION = VERSION_MINOR = '0.0.0'
end
VERSION_MAJOR = VERSION.split('.')[0,2].join('.')
VERSION_DESIGN = VERSION.split('.').first

VERSION_MINOR_TAGS = %x{git tag}.chomp.split("\n").find_all{|v| v.match(/#{Regexp.escape(VERSION_MINOR)}(\.|$)/)}
VERSION_MAJOR_TAGS = %x{git tag}.chomp.split("\n").find_all{|v| v.match(/#{Regexp.escape(VERSION_MAJOR)}(\.|$)/)}
VERSION_DESIGN_TAGS = %x{git tag}.chomp.split("\n").find_all{|v| v.match(/#{Regexp.escape(VERSION_DESIGN)}(\.|$)/)}
