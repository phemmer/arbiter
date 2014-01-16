# http://www.vagrantbox.es
# Look for vagrantup.com for official images

module Vagrant
  def self.vgcommand(*args)
    Bundle.with_clean_env do
      child = IO.popen('-', 'r')
      if child.nil? then
        #Dir.chdir(@vgdir)
        exec('vagrant', *args)
        exit 99
      end

      output = child.read
      pinfo = Process.wait2(child.pid)
      status = pinfo[1].exitstatus
      output.send(:define_method, :status) { status }
    end
  end

  def self.start
    vgcommand('up', '--parallel')
    at_exit { system('vagrant', 'down') }
  end
end

