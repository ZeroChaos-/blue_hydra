require 'spec_helper'

describe BlueHydra::CliUserInterfaceTracker do
  describe "auto-connect health counters" do
    before do
      BlueHydra::CliUserInterfaceTracker.auto_connect_added_count     = 0
      BlueHydra::CliUserInterfaceTracker.auto_connect_connected_count = 0
      BlueHydra::CliUserInterfaceTracker.auto_connect_failed_count    = 0
    end

    it "increments the added counter" do
      2.times { BlueHydra::CliUserInterfaceTracker.increment_auto_connect_added_count }
      expect(BlueHydra::CliUserInterfaceTracker.auto_connect_added_count).to eq(2)
    end

    it "increments the connected counter" do
      BlueHydra::CliUserInterfaceTracker.increment_auto_connect_connected_count
      expect(BlueHydra::CliUserInterfaceTracker.auto_connect_connected_count).to eq(1)
    end

    it "increments the failed counter" do
      3.times { BlueHydra::CliUserInterfaceTracker.increment_auto_connect_failed_count }
      expect(BlueHydra::CliUserInterfaceTracker.auto_connect_failed_count).to eq(3)
    end
  end
end
