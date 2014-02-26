require_relative 'spec_helper'
require 'yaml'
require 'timeout'

describe 'arbiter' do
  before :all do
    versions = ENV['VERSIONS'] ? ENV['VERSIONS'].split(/[ ,;]+/) : ['','','']
    @containers = []
    versions.each do |version|
      container = SDockerContainer.new(version)
      container.data[:arbiter_pid] = container.cmd_background('bin/arbiter start')
      @containers << container
    end
    @containers.each do |container|
      container.data[:node_id] = container.cmd('corosync-cmapctl -g runtime.votequorum.this_node_id | awk "{ print \$NF }"').chomp
    end

    @rng = Random.new(RSpec.configuration.seed)
  end

  around :each do |example|
    Timeout::timeout(60) { example.run }
  end

  def status(container)
    output = container.cmd('bin/arbiter status')
    $stderr.puts output if ENV['debug']
    return nil if $?.exitstatus != 0
    YAML.load(output)
  end
  def set_healthy(container, healthy = true)
    linkcmd = healthy ? 'true' : 'false'
    container.cmd("mkdir -p /etc/arbiter.d; rm /etc/arbiter.d/check 2>/dev/null; ln -s `which #{linkcmd}` /etc/arbiter.d/check; bin/arbiter check")
  end

  it 'should be running' do
    @containers.each do |container|
      status = self.status(container)
      expect(status).to be_a(Hash)
      expect(status['node_count']).to eq(@containers.size)
      expect(status['healthy_count']).to be <= @containers.size
      expect(status['healthy_threshold']).to be >= (@containers.size / 2)
      expect(status['healthy_threshold']).to be <= @containers.size
      expect(status['nodes']).to be_a(Hash)
      #expect(status['healthy_count']).to eq(@containers.size)
      #expect(status['nodes'].size).to eq(@containers.size)
    end
  end

  it 'should all be healthy' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    @containers.each do |container|
      status = self.status(container)

      expect(status['healthy_count']).to eq(@containers.size)
      expect(status['nodes'].size).to eq(@containers.size)
      expect(status['nodes'].keys.sort).to eq(@containers.map{|c| c.data[:node_id]}.sort)
    end
  end

  it 'should recover from process failure' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    # fail a random container
    container_fail = @containers.sample(random: @rng)
    container_fail.cmd("kill #{container_fail.data[:arbiter_pid]}")
    expect(status(container_fail)).to be_nil

    # make sure the other containers noticed the failure
    container_ok = @containers.find{|c| c != container_fail}
    status_ok = self.status(container_ok)
    expect(status_ok['healthy_count']).to eq(@containers.size - 1)

    # start it back up
    container_fail.data[:arbiter_pid] = container_fail.cmd_background('bin/arbiter start')
    sleep 1 # sleep is ugly, but simplest way of waiting for the service to start
    set_healthy(container_fail, true)

    # verify the other nodes noticed it
    status_ok = self.status(container_ok)
    expect(status_ok['healthy_count']).to eq(@containers.size)

    # verify it picked up the other nodes
    status_fail = self.status(container_fail)
    expect(status_fail['healthy_count']).to eq(@containers.size)
    expect(status_fail['nodes'].size).to eq(@containers.size)
  end

  it 'should recover from corosync failure' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    # fail a random corosync
    container_fail = @containers.sample(random: @rng)
    container_fail.cmd('pkill corosync')
    expect(status(container_fail)).to be_nil

    expect(container_fail.cmd("test -e /proc/#{container_fail.data[:arbiter_pid]}; echo $?").chomp).to eq('1')

    container_ok = @containers.find{|c| c!= container_fail}
    status_ok = self.status(container_ok)
    expect(status_ok['healthy_count']).to eq(@containers.size - 1)

    # start corosync
    container_fail.cmd('corosync')

    # start the service
    container_fail.data[:arbiter_pid] = container_fail.cmd_background('bin/arbiter start')
    sleep 1 # sleep is ugly, but simplest way of waiting for the service to start
    set_healthy(container_fail, true)

    # verify the other nodes noticed it
    status_ok = self.status(container_ok)
    expect(status_ok['healthy_count']).to eq(@containers.size)

    # verify it picked up the other nodes
    status_fail = self.status(container_fail)
    expect(status_fail['healthy_count']).to eq(@containers.size)
    expect(status_fail['nodes'].size).to eq(@containers.size)
  end
end
