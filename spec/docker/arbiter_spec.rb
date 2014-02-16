require_relative 'spec_helper'

describe 'arbiter' do
  before :all do
    @containers = SDocker.launch 3
  end

  it 'should be running' do
    @containers.each do |container|
      container.cmd('bin/arbiter status')
      expect($?.exitstatus).to eq(0)
    end
  end
end
