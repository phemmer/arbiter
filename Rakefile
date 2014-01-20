require 'rubygems'
require 'bundler/setup'
require 'rake'

desc "Generate upstart service file"
task "upstart" do
	run_dir = ENV['run_dir'] || '/tmp'
	app_dir = ENV['app_dir'] || File.expand_path('../', __FILE__)

	require 'erb'
	erb = ERB.new(File.read(File.expand_path('../service/arbiter.upstart.erb', __FILE__)), nil, '-')
	puts erb.result(binding)
end
