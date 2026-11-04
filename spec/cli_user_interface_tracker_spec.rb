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

  # The NAME cell of a Debug_CUI row ranks its sources complete > gatt > short
  # (Requirements 13.13, 13.14). Rows are built the way the parser thread
  # builds them, one update_cui_status per chunk, and the GATT name arrives the
  # way the result thread will deliver it, through apply_gatt_device_name.
  # Rows are keyed by the tracker's internal uuid, so every lookup goes by the
  # row's :address, as the method itself does.
  describe "NAME cell precedence: complete, then GATT Device Name, then short" do
    let(:tracker)   { BlueHydra::CliUserInterfaceTracker }
    # a Struct rather than a named class: ai_spec.rb already owns FakeRunner
    let(:runner)    { Struct.new(:cui_status).new({}) }
    let(:chunk)     { [["      LE Advertising Report (0x02)"]] }
    let(:address)   { "AA:BB:CC:DD:EE:40" }
    let(:gatt_name) { "GATT Device Name" }

    # one parsed chunk for `address`, as the parser thread would feed it
    def see(extra = {})
      attrs = { address: [address], last_seen: [Time.now.to_i] }.merge(extra)
      tracker.new(runner, chunk, attrs, address).update_cui_status
    end

    def apply(name = gatt_name, addr = address)
      tracker.apply_gatt_device_name(runner.cui_status, addr, name)
    end

    def row
      runner.cui_status.values.find { |r| r[:address] == address }
    end

    def snapshot
      Marshal.load(Marshal.dump(runner.cui_status))
    end

    it "fills an empty cell from a shortened name as :short" do
      see(short_name: ["shorty"])
      expect(row[:name]).to eq("shorty")
      expect(row[:name_source]).to eq(:short)
    end

    it "fills an empty cell from a complete name as :complete" do
      see(name: ["Complete Name"])
      expect(row[:name]).to eq("Complete Name")
      expect(row[:name_source]).to eq(:complete)
    end

    it "fills an empty cell from a GATT name as :gatt" do
      see
      expect(row[:name]).to be_nil
      expect(apply).to eq(true)
      expect(row[:name]).to eq(gatt_name)
      expect(row[:name_source]).to eq(:gatt)
    end

    it "short then gatt: the GATT name replaces the shortened name" do
      see(short_name: ["shorty"])
      expect(apply).to eq(true)
      expect(row[:name]).to eq(gatt_name)
      expect(row[:name_source]).to eq(:gatt)
    end

    it "gatt then short: a later chunk with only a shortened name leaves the GATT name" do
      see
      apply
      see(short_name: ["shorty"])
      expect(row[:name]).to eq(gatt_name)
      expect(row[:name_source]).to eq(:gatt)
    end

    it "gatt then complete: a later chunk with a complete name replaces the GATT name" do
      see
      apply
      see(name: ["Complete Name"])
      expect(row[:name]).to eq("Complete Name")
      expect(row[:name_source]).to eq(:complete)
    end

    it "complete then gatt: the complete name stays" do
      see(name: ["Complete Name"])
      expect(apply).to eq(false)
      expect(row[:name]).to eq("Complete Name")
      expect(row[:name_source]).to eq(:complete)
    end

    it "complete then short: the complete name stays" do
      see(name: ["Complete Name"])
      see(short_name: ["shorty"])
      expect(row[:name]).to eq("Complete Name")
      expect(row[:name_source]).to eq(:complete)
    end

    # The generic attribute loop only writes :name on change. The source must
    # still flip to :complete when the advertised text equals the GATT text, or
    # a later, different GATT name would replace what is now a complete name.
    it "records :complete when the complete name matches the GATT text already shown" do
      see
      apply("Same Text")
      see(name: ["Same Text"])
      expect(row[:name_source]).to eq(:complete)

      expect(apply("Other Text")).to eq(false)
      expect(row[:name]).to eq("Same Text")
    end

    it "a complete name overwrites an earlier complete name on change, as today" do
      see(name: ["First"])
      see(name: ["Second"])
      expect(row[:name]).to eq("Second")
      expect(row[:name_source]).to eq(:complete)
    end

    it "ignores a nil, empty or non-String GATT name" do
      see(short_name: ["shorty"])
      before = snapshot

      [nil, "", 42, :sym, ["Array"]].each do |bad|
        expect(apply(bad)).to eq(false)
      end

      expect(runner.cui_status).to eq(before)
      expect(row[:name]).to eq("shorty")
      expect(row[:name_source]).to eq(:short)
    end

    it "a chunk whose name is [nil] sets neither the cell nor a source" do
      see(name: [nil])
      expect(row[:name]).to be_nil
      expect(row[:name_source]).to be_nil
    end

    it "creates no row and changes nothing for an address the table has not seen" do
      expect(apply(gatt_name, "11:22:33:44:55:66")).to eq(false)
      expect(runner.cui_status).to eq({})

      see(short_name: ["shorty"])
      before = snapshot
      expect(apply(gatt_name, "11:22:33:44:55:66")).to eq(false)
      expect(runner.cui_status).to eq(before)
      expect(runner.cui_status.keys).to eq(before.keys)
    end

    it "matches the row by :address after other cells have changed" do
      see(short_name: ["shorty"], le_rssi: [{ rssi: "-50 dBm" }])
      uuid = runner.cui_status.keys.first
      # keyed by the tracker's uuid, never by the address
      expect(runner.cui_status).not_to have_key(address)

      see(le_rssi: [{ rssi: "-70 dBm" }], appearance: ["Watch (0x00c0)"])
      expect(runner.cui_status.keys).to eq([uuid])
      expect(row[:rssi]).to eq("-70 ")

      expect(apply).to eq(true)
      expect(runner.cui_status[uuid][:name]).to eq(gatt_name)
      expect(runner.cui_status[uuid][:name_source]).to eq(:gatt)
    end

    it "touches no Device on the way" do
      [:first, :all, :get, :create, :update_or_create_from_result].each do |m|
        expect(BlueHydra::Device).not_to receive(m)
      end

      see(short_name: ["shorty"])
      apply
      see(name: ["Complete Name"])
      apply("Another")
      expect(row[:name]).to eq("Complete Name")
    end
  end
end
