require_relative 'spec_helper'
require 'yaml'

describe 'arbiter' do
  before :all do
    versions = ENV['VERSIONS'] ? ENV['VERSIONS'].split(/[ ,;]+/) : ['','','']
    @containers = []
    versions.each do |version|
      @containers << SDockerContainer.new('bin/arbiter start', version)
    end
  end

  def status(container)
    output = container.cmd('bin/arbiter status')
    $stderr.puts output if ENV['debug']
    return nil if $?.exitstatus != 0
    YAML.load(output)
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
end
