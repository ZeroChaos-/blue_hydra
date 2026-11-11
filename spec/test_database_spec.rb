require 'spec_helper'

describe "the suite's in-memory database" do
  # Backdating every idle connection stands in for a long DB-idle stretch, so
  # this does not depend on how fast the suite runs.
  it "survives a DataObjects scavenger pass over connections idle for an hour" do
    BlueHydra::Device.count
    aged = 0
    DataObjects::Pooling.lock.synchronize do
      DataObjects::Pooling.pools.to_a.each do |pool|
        pool.lock.synchronize do
          pool.available.each do |connection|
            connection.instance_variable_set(:@__allocated_in_pool, Time.now - 3600)
            aged += 1
          end
          # the scavenger thread's step for each pool
          pool.dispose if pool.expired?
        end
      end
    end

    expect(aged).to be > 0
    expect { BlueHydra::Device.count }.not_to raise_error
  end
end
