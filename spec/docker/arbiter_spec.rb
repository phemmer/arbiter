require_relative 'spec_helper'
require 'yaml'
require 'timeout'

describe 'arbiter' do
  before :all do
    versions = ENV['VERSIONS'] ? ENV['VERSIONS'].split(/[ ,;]+/) : ['','','']
    @containers = Set.new
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

  def expect_status(state)
    state[:healthy] ||= @containers - (state[:unhealthy] || []) - (state[:dead] || [])
    state[:unhealthy] ||= @containers - (state[:healthy] || []) - (state[:dead] || [])
    state[:dead] ||= @containers - (state[:healthy] || []) - (state[:unhealthy] || [])

    (state[:healthy] + state[:unhealthy]).each do |container|
      status = self.status(container)
      expect(status).to be_a(Hash)
      expect(status['node_count']).to eq(@containers.size)
      expect(status['healthy_count']).to eq(state[:healthy].size)
      expect(status['healthy_threshold']).to be >= (@containers.size / 2)
      expect(status['healthy_threshold']).to be <= @containers.size
      expect(status['nodes']).to be_a(Hash)
      expect(status['nodes'].size).to be >= state[:healthy].size
      healthy_node_ids = state[:healthy].map{|c| c.data[:node_id]}
      unhealthy_node_ids = state[:unhealthy].map{|c| c.data[:node_id]}
      present_node_ids = status['nodes'].keys
      expect((healthy_node_ids | unhealthy_node_ids).sort).to eq(present_node_ids.sort)
    end

    state[:dead].each do |container|
      status = self.status(container)
      expect(status).to be_nil
    end
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

    expect_status(healthy: @containers)
  end

  it 'should recover from process failure' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    # fail a random container
    container_fail = @containers.to_a.sample(random: @rng)
    container_fail.cmd("kill #{container_fail.data[:arbiter_pid]}")

    expect_status(healthy: @containers - [container_fail], dead: [container_fail])

    # start it back up
    container_fail.data[:arbiter_pid] = container_fail.cmd_background('bin/arbiter start')
    sleep 1 # sleep is ugly, but simplest way of waiting for the service to start
    set_healthy(container_fail, true)

    # verify
    expect_status(healthy: @containers)
  end

  it 'should recover from corosync shutdown' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    # fail a random corosync
    container_fail = @containers.to_a.sample(random: @rng)
    container_fail.cmd('pkill corosync')

    expect(container_fail.cmd("test -e /proc/#{container_fail.data[:arbiter_pid]}; echo $?").chomp).to eq('1')

    expect_status(healthy: @containers - [container_fail], dead: [container_fail])

    # start corosync
    container_fail.cmd('corosync')

    # start the service
    container_fail.data[:arbiter_pid] = container_fail.cmd_background('bin/arbiter start')
    sleep 1 # sleep is ugly, but simplest way of waiting for the service to start
    set_healthy(container_fail, true)

    # verify
    expect_status(healthy: @containers)
  end

  it 'should recover from corosync failure' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    # fail a random corosync
    container_fail = @containers.to_a.sample(random: @rng)
    container_fail.cmd('pkill -9 corosync')
    sleep 5

    expect(container_fail.cmd("test -e /proc/#{container_fail.data[:arbiter_pid]}; echo $?").chomp).to eq('1')

    expect_status(healthy: @containers - [container_fail], dead: [container_fail])

    # start corosync
    container_fail.cmd('corosync')
    sleep 2

    # start the service
    container_fail.data[:arbiter_pid] = container_fail.cmd_background('bin/arbiter start')
    sleep 1 # sleep is ugly, but simplest way of waiting for the service to start
    set_healthy(container_fail, true)

    # verify
    expect_status(healthy: @containers)
  end

  it 'should track unhealthy containers' do
    # set each container unhealthy one by one and verify
    # set each container healthy one by one and verify
  end

  it 'should recover from network interruption' do
    container_fail = @containers.to_a.sample(random: @rng)
    container_fail.cmd('iptables -A OUTPUT -p udp ! --dport 53 -j DROP; iptables -A INPUT -p udp ! --sport 53 -j DROP')
    sleep 5

    expect_status(healthy: @containers - [container_fail], unhealthy: [container_fail])

    container_fail.cmd('iptables -F OUTPUT; iptables -F INPUT')

    sleep 5

    expect_status(healthy: @containers)
  end

  it 'should shlock a command' do
    # set all healthy and verify
  end

  it 'should shlock a command only when threshold met' do
    # set unhealthy one by one and verify healthy when >= threshold, unhealthy when < threshold
  end

  it 'should shlock a shell' do
    # set all healthy and verify
  end

  it 'should not shlock a command when quorum lost' do
  end
end
