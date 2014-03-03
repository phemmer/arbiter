require_relative 'spec_helper'
require 'yaml'
require 'timeout'

class RSpec::Expectations::ExpectationNotMetError
  require 'byebug'
  alias_method :debug_initialize, :initialize
  def initialize(*args, &block)
    debug_initialize(*args, &block)
    if ENV['inspect_failure'] then
      $stderr.puts self.to_s
      byebug(1,7)
    end
  end
end

Module.new do
  def self.example_failed(example)
    return if example.execution_result[:exception].is_a?(RSpec::Expectations::ExpectationNotMetError)
    if ENV['inspect_failure'] then
      $stderr.puts example.execution_result[:exception].to_s
      exception = example.execution_result[:exception]
      byebug(1)
    end
  end
  RSpec.configuration.reporter.register_listener(self, :example_failed)
end




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

  #around :each do |example|
    #Timeout::timeout(60) { example.run }
  #end

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

    healthy_node_ids = state[:healthy].map{|c| c.data[:node_id]}
    unhealthy_node_ids = state[:unhealthy].map{|c| c.data[:node_id]}

    (state[:healthy] + state[:unhealthy]).each do |container|
      status = self.status(container)
      expect(status).to be_a(Hash)
      expect(status['node_count']).to eq(@containers.size)
      expect(status['healthy_count']).to eq(state[:healthy].size)
      expect(status['healthy_threshold']).to be >= (@containers.size / 2)
      expect(status['healthy_threshold']).to be <= @containers.size
      expect(status['nodes']).to be_a(Hash)
      expect(status['nodes'].size).to be >= state[:healthy].size
      expect(status['nodes'].keys.sort).to eq(healthy_node_ids | unhealthy_node_ids)
    end

    state[:dead].each do |container|
      status = self.status(container)
      # we can't expect one of several conditions, so we have to be evil

      next if status.nil? # this is good

      # process is up, but it should not be in a 'healthy' state
      expect(status['nodes']).to_not include(*(healthy_node_ids | unhealthy_node_ids))
      expect(status['healthy_count']).to be < status['healthy_threshold']
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

  it 'should recover from network interruption' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    container_fail = @containers.to_a.sample(random: @rng)
    begin
      container_fail.cmd('iptables -A OUTPUT -o eth0 -p udp ! --dport 53 -j DROP; iptables -A INPUT -i eth0 -p udp ! --sport 53 -j DROP')
      sleep 5

      expect_status(healthy: @containers - [container_fail], dead: [container_fail])
    ensure
      container_fail.cmd('iptables -F OUTPUT; iptables -F INPUT')
    end

    sleep 5

    expect_status(healthy: @containers)
  end

  it 'should shlock a command' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    @containers.each do |container|
      expect(container.cmd('bin/arbiter shlock echo hi').chomp).to eq('hi')
    end
  end

  it 'should shlock a command only when threshold met' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    status = self.status(@containers.first)
    healthy_threshold = status['healthy_threshold']
    containers_unhealthy = []
    @containers.each_with_index do |container,i|
      set_healthy(container, false)
      containers_unhealthy << container
      containers_healthy = @containers - containers_unhealthy

      if containers_healthy.size > healthy_threshold then
        # validate shlock works on healthy container when threshold met
        expect(containers_healthy.first.cmd('bin/arbiter shlock --wait=0 echo hi').chomp).to eq('hi')
      elsif containers_healthy.size > 0 then
        # validate shlock fails on healthy container when threshold not met
        expect(containers_healthy.first.cmd('bin/arbiter shlock --wait=0 echo hi').chomp).to eq('')
      end
      # validate shlock works on unhealthy container
      expect(container.cmd('bin/arbiter shlock --wait=0 echo hi').chomp).to eq('hi')
    end
  end

  it 'should shlock a shell' do
    @containers.each do |container|
      set_healthy(container, true)
    end

    container = @containers.to_a.sample(random: @rng)
    expect(container.cmd('echo "echo hi" | bin/arbiter shlock').chomp).to eq('hi')
  end

  it 'should not shlock a command when quorum lost' do
    # not quite sure how to implement this one
  end
end
