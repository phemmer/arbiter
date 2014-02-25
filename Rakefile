require 'rubygems'
require 'bundler/setup'
require 'rake'

require 'rspec/core/rake_task'
RSpec::Core::RakeTask.new(:spec)

###

desc "Generate upstart service file"
task "upstart" do
  run_dir = ENV['run_dir'] || '/tmp'
  app_dir = ENV['app_dir'] || File.expand_path('../', __FILE__)

  require 'erb'
  erb = ERB.new(File.read(File.expand_path('../service/arbiter.upstart.erb', __FILE__)), nil, '-')
  puts erb.result(binding)
end


####

desc 'create a tarball with all dependency gems included'
task 'package' do
  # Args:
  #   source: Where to get the source from
  #     '': Current working tree
  #     'INDEX': Current git index
  #     *: git ref (tree-ish)
  #   out: where to place the resulting file

  require 'fileutils'
  name = Dir.pwd.split('/').last
  require 'shellwords'

  out = ENV['out'] || "#{name}.tar.gz"

  tmpdir = "/tmp/#{name}-#{$$}.tmp/"
  Dir.mkdir(tmpdir)
  tmpdir_src = "#{tmpdir}/#{name}"
  Dir.mkdir(tmpdir_src)
  at_exit { FileUtils.rm_rf(tmpdir) }

  treeish = ENV['source'] || ''
  if treeish == '' then
    cmd = ['tar','-c', *(%x{git ls-files}.split("\n"))]
  elsif treeish == 'INDEX' then
    cmd = ['git', 'archive', %x{git write-tree}]
  else
    cmd = ['git', 'archive', treeish]
  end
  sh("#{Shellwords.shelljoin(cmd)} | tar -xC #{tmpdir_src}")
  # we don't want Bundle.with_clean_env as we want to preserve most of the env
  # However if we dont clean BUNDLE_GEMFILE, then it ends up installing in the original directory
  Bundler.with_clean_env do
    sh("cd #{tmpdir_src}; bundle package --all >/dev/null")
  end
  sh("tar -czf #{out} -C #{tmpdir} #{name}")
  puts out unless ENV['out'] # show unless it was given to us
end
