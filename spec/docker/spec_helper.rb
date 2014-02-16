RSpec.configure do |config|
  config.color_enabled = true
  config.formatter = :documentation
end

$:.unshift('/home/phemmer/git/docker-api/lib')
$:.unshift('/home/phemmer/git/excon/lib')
require 'docker'
Docker::Container.auto_remove = true
Docker::Image.auto_remove = true

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
		
		#system('ssh-keygen','-f', "#{TMPDIR}/id_rsa", '-N', '')
		#abort if $?.exitstatus > 0
		File.open("#{TMPDIR}/id_rsa",'w') do |fh|
			fh.write "-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAx6GcJsGIAG+Fe7w12A7KPNdO5DO7Hy8GHeTnEwQOjohXFAF6
35QsNzP5llFuJ4rq6O4kaxf8t1QwIUJWBkwrnzIy0TjIJuNgTHtuEJATQntL2g28
r4+YUT3bL0TaNAeZlvr4ZNNqMhueD3JrFV42Op/igWXmTyMS39SNmt2Zl3PpDXOS
q3vPIhKhImzKB1bcQ7lGpxme7UHeytjOPEbs5xlYVzIXsHeUwrBlalsy0zxY/j13
uhO/LT9qYkQ1pLFvEdMX/M/eXkK/Q9ND36yOzOHSMycbEmDYSnIZZoP31yQB5vy2
9vd6u8+MT9d0RO6sm4VtkBoUiv6WvaLGbxl/3QIDAQABAoIBAByWZw8hvcEaN0pN
3IQRMiLeTlzdj5lamYykX/bYKOF+YsHpqFfmFyLcnYxKIvUkrpkmqS5w4+647p+E
qV8Df2evv5k4gWkYPI0XS96xUyC9GVKjjvaxIIXZzs6JFJpI0FTPocyGffmo/MyH
fRA1SpzAkqYnGoEQq75D6PdZbopCfM+QhdGiK+qTcrh0UmGqBMU+KAbrFkPuLQZu
ihDWQcV0SdAnaxNwdBl/zeccxLv5gEt3rHZDWnjrakGr4RjcTKIZxKj1twJlnaxL
phtn0dpaAFagqOuGRAFsGgWkGzrQMBuiDqSGXuuQM43angWWUdzyRuNGhL7cIonW
njcsf10CgYEA/yT/LjLpw7cQCVbMIBUD8nzIzrH75yYftBbfdffoXP+q4LX9J/XG
pncf7P23fJxZdHO8ZHCpNy98G1Vc27XPti/8hEFT5krxfaC/zIg1MYRpsyDFariC
p1yAlRQy7FA+7Gm8Gh7BOzpzVuOotzZfRmGvj8AUrMgM25ZQ34VcSy8CgYEAyEz2
oeVTkGAywc43wkBTqkSN9kAnUIgjNF63WMZrh5edn3hdrtAB/C5FVkZuvi+7sAFa
esCYzRrs++7sBacMj9GK42rlZc9hE1J2SCZlWqjmP9egMbI+ALYTdyBQM/RZLe9S
m7zTKe44vqCT/wkmXk7jz1Ao+YXDkQmqOa3KcrMCgYBftnhH02+gLOdGKZpvmpKd
f7Qw3dHat5GDFGWFspcnc/2dSIgMWoXH4r5GQDN5+okQR25v21ePTS/obRBll4Gx
HbVDw+H+bTTEZO4ugxY5Wivwt6V3UHoq4GeYBTjJL507QLsArXLdjiLAgKzE9g+t
rm2Wpn7bBjzUj0INZ9DknwKBgBm0Fqor3Y9XaOwJ5Ine612cMoN5NBJXhf0AcpLH
06Cwyh9euNboBnkwDuHFZAyv32v0oIHEGVeoruSdglgvWaNTBnmsjAeGlzR9joQv
uS3rIrDqoLn/34kD1HejA+fG4XLNlVI65vYohcugm51MtUnA4ecGqFts2O3RybBh
JuuVAoGBAO3qbOesD5l5LnT0FjeBsaBgCrH8QR94VJIV+MXk1jKTDTCVCJxs7Nck
MY4fsxfj0SYyQHgtu/i/Sr7dP/HMSJIX8SvjfrpR3sOQBss6Io0YHjprPkZEbY8l
FvKhC/1vM/lTbg6F6rpls41DMP2r1+H3qkrcDNhCKIiGTK+O6Qsp
-----END RSA PRIVATE KEY-----
"
		end
		File.chmod(0600, "#{TMPDIR}/id_rsa")
		File.open("#{TMPDIR}/id_rsa.pub", 'w') do |fh|
			fh.write 'ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDHoZwmwYgAb4V7vDXYDso8107kM7sfLwYd5OcTBA6OiFcUAXrflCw3M/mWUW4niuro7iRrF/y3VDAhQlYGTCufMjLROMgm42BMe24QkBNCe0vaDbyvj5hRPdsvRNo0B5mW+vhk02oyG54PcmsVXjY6n+KBZeZPIxLf1I2a3ZmXc+kNc5Kre88iEqEibMoHVtxDuUanGZ7tQd7K2M48RuznGVhXMhewd5TCsGVqWzLTPFj+PXe6E78tP2piRDWksW8R0xf8z95eQr9D00PfrI7M4dIzJxsSYNhKchlmg/fXJAHm/Lb293q7z4xP13RE7qybhW2QGhSK/pa9osZvGX/d
'
		end

		image = Docker::Image.all.find{|i| i.info['RepoTags'] && i.info['RepoTags'].include?(NAME)}
		if image then
			@id = image.id
			return @id
		end


		container = Docker::Container.create('Image' => SOURCE_IMAGE, 'Cmd' => ['bash','-c',<<EOI1])
# core
set -x
apt-get update
apt-get install -y ssh
mkdir /var/run/sshd
mkdir /root/.ssh
chmod 600 root/.ssh
echo '#{File.read("#{TMPDIR}/id_rsa.pub")}' >> /root/.ssh/authorized_keys
# `which sshd`

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
		container.start
		container.attach(:logs => true) { |stream, chunk| (stream == 'stdout' ? $stdout : $stderr).write chunk }
		image = container.commit('repo' => NAME.split(':').first, 'tag' => NAME.split(':').last)

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
			script << "pidof corosync && corosync-cfgtool -R || corosync\n"
			system(*(container.sshcmd(script)))
		end
	end

	def initialize(cmd, version = nil)
		@@containers ||= {}

		@container = Docker::Container.create(
			'Image' => SDockerImage.id,
			'Hostname' => hostname,
			'Cmd' => ['sh','-c','exec `which sshd` -D']
		)
		@container.start
		@info = @container.json
		Timeout.timeout(15) do
			system(*(sshcmd('true')))
			break if $?.exitstatus == 0
			sleep 1
		end

		@@containers[@container.id] = self
		self.class.sync

		package_io = IO.popen(['rake','package',"source=#{version}","out=/dev/stdout"],'r')
		system(*(sshcmd("mkdir /#{SDockerImage::PROJECT_NAME}; tar -xzC /#{SDockerImage::PROJECT_NAME} --strip-components=1")), 0 => package_io)
		package_io.close

		cmd("bundle install --local")

		cmd("#{cmd} >/tmp/log 2>&1 &")
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
		@info['NetworkSettings']['IPAddress']
	end

	def sshcmd(*args)
		cmd_string = args.size > 1 ? Shellwords.shelljoin(args) : args[0]
		['ssh', '-i', "#{SDockerImage::TMPDIR}/id_rsa", '-o', "UserKnownHostsFile=#{SDockerImage::TMPDIR}/known_hosts", '-o', 'StrictHostKeyChecking=no', '-o', 'BatchMode=yes', '-o', 'ForwardX11=no', "root@#{ip}", cmd_string]
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
