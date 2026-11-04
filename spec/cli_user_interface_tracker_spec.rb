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

  # conn-limit is a Direct_Connect_Path outcome (LeConnect :conn_limit, EMLINK
  # from the local controller), kept beside the other direct LE counters
  # (Requirements 13.12, 18.2). The counters are process-global and never
  # reset, so every assertion here is relative to the value seen on entry.
  describe "direct LE conn-limit counter" do
    let(:tracker) { BlueHydra::CliUserInterfaceTracker }

    # every direct LE counter other than conn-limit, read as one snapshot
    def other_direct_le_counts
      {
        connected: tracker.le_direct_connected_count,
        failed:    tracker.le_direct_failed_count,
        error:     tracker.le_direct_error_count,
        abandoned: tracker.le_direct_abandoned_count,
        dropped:   tracker.le_direct_dropped_count
      }
    end

    it "increments by exactly one per helper call" do
      before = tracker.le_direct_conn_limit_count
      tracker.increment_le_direct_conn_limit_count
      expect(tracker.le_direct_conn_limit_count).to eq(before + 1)
      2.times { tracker.increment_le_direct_conn_limit_count }
      expect(tracker.le_direct_conn_limit_count).to eq(before + 3)
    end

    it "leaves the other direct LE counters untouched" do
      others = other_direct_le_counts
      3.times { tracker.increment_le_direct_conn_limit_count }
      expect(other_direct_le_counts).to eq(others)
    end

    it "is not moved by the other direct LE increment helpers" do
      before = tracker.le_direct_conn_limit_count
      tracker.increment_le_direct_connected_count
      tracker.increment_le_direct_failed_count
      tracker.increment_le_direct_error_count
      tracker.increment_le_direct_abandoned_count
      tracker.increment_le_direct_dropped_count
      expect(tracker.le_direct_conn_limit_count).to eq(before)
    end
  end
end
