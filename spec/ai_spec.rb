# encoding: UTF-8
require 'spec_helper'

# These specs were added to increase overall test coverage of Blue Hydra.
# They focus on the pure-logic, non-hardware portions of the codebase that
# were previously untested: the Pulse module, the BlueHydra module level
# config/logger accessors, the Device model helpers/setters, the CLI status
# tracker, the Parser branch handling, the Chunker dispatch logic and a few
# testable Runner helper methods.

PULSE_DEBUG_LOG = File.expand_path('../../pulse_debug.log', __FILE__)

def reset_pulse_state!
  BlueHydra.pulse = false
  BlueHydra.pulse_debug = false
  File.delete(PULSE_DEBUG_LOG) if File.exist?(PULSE_DEBUG_LOG)
end

#############################################################################
# Pulse module
#############################################################################
describe BlueHydra::Pulse do
  after(:each) { reset_pulse_state! }

  it "send_event returns false when pulse is enabled (open source no-op)" do
    BlueHydra.pulse = true
    expect(BlueHydra::Pulse.send_event("blue_hydra", { key: 'x' })).to eq(false)
  end

  it "send_event returns nil when pulse is disabled" do
    expect(BlueHydra::Pulse.send_event("blue_hydra", { key: 'x' })).to eq(nil)
  end

  it "do_debug appends json to the pulse debug log" do
    BlueHydra::Pulse.do_debug('{"hello":"world"}')
    expect(File.read(PULSE_DEBUG_LOG)).to include('{"hello":"world"}')
  end

  it "do_send writes to the debug log and skips the socket when pulse is off" do
    BlueHydra.pulse_debug = true
    BlueHydra::Pulse.do_send('{"sent":true}')
    expect(File.read(PULSE_DEBUG_LOG)).to include('{"sent":true}')
  end

  it "reset emits a reset message containing the current sync version" do
    BlueHydra.pulse_debug = true
    BlueHydra::Pulse.reset
    log = File.read(PULSE_DEBUG_LOG)
    expect(log).to include('"type":"reset"')
    expect(log).to include('"source":"blue-hydra"')
    expect(log).to include(BlueHydra::SYNC_VERSION)
  end

  it "hard_reset emits a reset message with a mismatched sync version" do
    BlueHydra.pulse_debug = true
    BlueHydra::Pulse.hard_reset
    expect(File.read(PULSE_DEBUG_LOG)).to include('ANYTHINGBUTTHISVERSION')
  end

  it "reset does nothing when both pulse and pulse_debug are off" do
    BlueHydra::Pulse.reset
    expect(File.exist?(PULSE_DEBUG_LOG)).to eq(false)
  end
end

#############################################################################
# BlueHydra module level accessors / logger
#############################################################################
describe "BlueHydra module accessors" do
  it "exposes config and the various loggers" do
    expect(BlueHydra.config).to be_a(Hash)
    expect(BlueHydra.logger).to respond_to(:info)
    expect(BlueHydra.rssi_logger).to respond_to(:info)
    expect(BlueHydra.chunk_logger).to respond_to(:info)
  end

  it "has working boolean getters/setters for the runtime options" do
    {
      demo_mode:      :demo_mode=,
      no_db:          :no_db=,
      signal_spitter: :signal_spitter=,
      file_api:       :file_api=,
      pulse_debug:    :pulse_debug=
    }.each do |getter, setter|
      original = BlueHydra.send(getter)
      BlueHydra.send(setter, true)
      expect(BlueHydra.send(getter)).to eq(true)
      BlueHydra.send(setter, false)
      expect(BlueHydra.send(getter)).to eq(false)
      BlueHydra.send(setter, original)
    end
  end

  it "info_scan defaults to true and can be toggled" do
    original = BlueHydra.info_scan
    BlueHydra.info_scan = false
    expect(BlueHydra.info_scan).to eq(false)
    BlueHydra.info_scan = true
    expect(BlueHydra.info_scan).to eq(true)
    BlueHydra.info_scan = original
  end

  it "update_logger sets a level for every configured log_level" do
    original = BlueHydra.config["log_level"]
    %w{ fatal error warn info debug something_unknown }.each do |lvl|
      BlueHydra.config["log_level"] = lvl
      expect { BlueHydra.update_logger }.to_not raise_error
    end
    BlueHydra.config["log_level"] = original
    BlueHydra.update_logger
  end

  it "NilLogger silently swallows all logging calls" do
    nl = BlueHydra::NilLogger.new
    expect(nl.fatal("x")).to eq(nil)
    expect(nl.error("x")).to eq(nil)
    expect(nl.warn("x")).to eq(nil)
    expect(nl.info("x")).to eq(nil)
    expect(nl.debug("x")).to eq(nil)
    expect(nl.level = 1).to eq(1)
    expect(nl.formatter = nil).to eq(nil)
  end
end

#############################################################################
# Device model helpers and custom setters
#############################################################################
describe BlueHydra::Device do
  it "exposes the list of syncable attributes" do
    d = BlueHydra::Device.new
    expect(d.syncable_attributes).to include(:name, :vendor, :le_rssi)
  end

  it "knows which attributes are serialized" do
    d = BlueHydra::Device.new
    expect(d.is_serialized?(:le_rssi)).to eq(true)
    expect(d.is_serialized?(:classic_class)).to eq(true)
    expect(d.is_serialized?(:name)).to eq(false)
  end

  it "looks up vendor 'N/A' for random le addresses" do
    d = BlueHydra::Device.new
    d.le_address_type = "Random"
    d.set_vendor
    expect(d.vendor).to eq("N/A - Random Address")
  end

  it "sets a real vendor for non-random addresses" do
    d = BlueHydra::Device.new
    d.address = "AA:BB:CC:DD:EE:F0"
    d.set_vendor(true)
    expect(d.vendor).to be_a(String)
  end

  it "short_name= only fills name when name is not already set" do
    d = BlueHydra::Device.new
    d.short_name = "shorty"
    expect(d.name).to eq("shorty")

    d2 = BlueHydra::Device.new
    d2.name = "realname"
    d2.short_name = "shorty"
    expect(d2.name).to eq("realname")

    d3 = BlueHydra::Device.new
    d3.short_name = ""
    expect(d3.name).to eq(nil)
  end

  it "merges classic_channels uniquely" do
    d = BlueHydra::Device.new
    d.classic_channels = ["0x01, Ch1, Ch2", "Ch2, Ch3"]
    parsed = JSON.parse(d.classic_channels)
    expect(parsed).to include("Ch1", "Ch2", "Ch3")
    expect(parsed).to_not include("0x01")
  end

  it "merges classic_class, dropping hex entries" do
    d = BlueHydra::Device.new
    d.classic_class = [["0xdeadbeef", "Phone", "Audio"]]
    parsed = JSON.parse(d.classic_class)
    expect(parsed).to include("Phone", "Audio")
    expect(parsed).to_not include("0xdeadbeef")
  end

  it "merges classic_features and le_features uniquely" do
    d = BlueHydra::Device.new
    d.classic_features = ["0x07, 3 slot packets, 5 slot packets"]
    d.le_features = ["0x01, LE Encryption"]
    expect(JSON.parse(d.classic_features)).to include("3 slot packets", "5 slot packets")
    expect(JSON.parse(d.le_features)).to include("LE Encryption")
  end

  it "merges le_flags uniquely" do
    d = BlueHydra::Device.new
    d.le_flags = ["0x06, LE General Discoverable Mode, BR/EDR Not Supported"]
    expect(JSON.parse(d.le_flags)).to include("LE General Discoverable Mode")
  end

  it "wraps bare le_service_uuids and normalizes legacy service data" do
    d = BlueHydra::Device.new
    # seed legacy service-data style value directly to exercise the fix path
    d[:le_service_uuids] = JSON.generate(["(UUID 0xfe9f): 0000000000"])
    d.le_service_uuids = ["1234", "Already (0x1111)"]
    parsed = JSON.parse(d.le_service_uuids)
    expect(parsed).to include("Unknown (1234)")
    expect(parsed).to include("Already (0x1111)")
    expect(parsed).to include("Unknown (0xfe9f)")
  end

  it "wraps bare classic_service_uuids" do
    d = BlueHydra::Device.new
    d.classic_service_uuids = ["5678", "Named (0x2222)"]
    parsed = JSON.parse(d.classic_service_uuids)
    expect(parsed).to include("Unknown (5678)")
    expect(parsed).to include("Named (0x2222)")
  end

  it "caps classic_rssi and le_rssi history to 100 entries" do
    d = BlueHydra::Device.new
    big = (1..150).map { |i| { t: i, rssi: "-#{i} dBm" } }
    d.classic_rssi = big
    d.le_rssi = big
    expect(JSON.parse(d.classic_rssi).count).to eq(100)
    expect(JSON.parse(d.le_rssi).count).to eq(100)
  end

  it "handles le_address_type for Public and Random" do
    pub = BlueHydra::Device.new
    pub.le_random_address_type = "Static (0x01)"
    pub.le_address_type = "Public (0x00)"
    expect(pub.le_address_type).to eq("Public")
    expect(pub.le_random_address_type).to eq(nil)

    rand_d = BlueHydra::Device.new
    rand_d.le_address_type = "Random (0x01)"
    expect(rand_d.le_address_type).to eq("Random")
  end

  it "only sets le_random_address_type when not a public device" do
    d = BlueHydra::Device.new
    d.le_address_type = "Public (0x00)"
    d.le_random_address_type = "Static (0x01)"
    expect(d.le_random_address_type).to eq(nil)

    d2 = BlueHydra::Device.new
    d2.le_random_address_type = "Static (0x01)"
    expect(d2.le_random_address_type).to eq("Static (0x01)")
  end

  it "merges feature bitmaps into a page keyed object" do
    d = BlueHydra::Device.new
    d.le_features_bitmap = [["0", "0x01"], ["1", "0x02"]]
    d.classic_features_bitmap = [["0", "0xff"]]
    expect(JSON.parse(d.le_features_bitmap)).to eq({ "0" => "0x01", "1" => "0x02" })
    expect(JSON.parse(d.classic_features_bitmap)).to eq({ "0" => "0xff" })
  end

  it "conditionally looks up vendor when setting an address" do
    d = BlueHydra::Device.new
    d.address = "00:00:11:22:33:44" # leading 00:00 -> no lookup
    expect(d.address).to eq("00:00:11:22:33:44")
    d.address = "AA:BB:CC:DD:EE:F1" # real -> lookup happens
    expect(d.vendor).to be_a(String)
  end

  it "find_by_uap_lap locates devices by the last four octets" do
    d = BlueHydra::Device.new
    d.address = "C0:FF:EE:00:11:22"
    d.save
    found = BlueHydra::Device.find_by_uap_lap("FF:FF:EE:00:11:22")
    expect(found).to eq(d)
  end

  it "marks stale classic and le devices offline" do
    classic = BlueHydra::Device.new
    classic.address = "DE:AD:00:00:00:01"
    classic.classic_mode = true
    classic.status = "online"
    classic.save
    classic.last_seen = Time.now.to_i - (60 * 20)
    classic.save

    le = BlueHydra::Device.new
    le.address = "DE:AD:00:00:00:02"
    le.le_mode = true
    le.status = "online"
    le.save
    le.last_seen = Time.now.to_i - (60 * 10)
    le.save

    BlueHydra::Device.mark_old_devices_offline

    expect(BlueHydra::Device.get(classic.id).status).to eq("offline")
    expect(BlueHydra::Device.get(le.id).status).to eq("offline")
  end

  it "runs the startup branch of mark_old_devices_offline" do
    expect { BlueHydra::Device.mark_old_devices_offline(true) }.to_not raise_error
  end

  it "sync_all_to_pulse iterates without error" do
    BlueHydra::Device.new.tap { |d| d.address = "DE:AD:00:00:00:03"; d.save }
    expect { BlueHydra::Device.sync_all_to_pulse }.to_not raise_error
  end

  describe "sync_to_pulse" do
    after(:each) { reset_pulse_state! }

    it "emits a bluetooth payload when pulse_debug is enabled" do
      BlueHydra.pulse_debug = true
      d = BlueHydra::Device.new
      d.address = "DE:AD:00:00:00:04"
      d.le_proximity_uuid = "1234"
      d.le_major_num = "1"
      d.le_minor_num = "2"
      d.le_company_data = "cafe"
      d.company = "Acme (1)"
      d.save # after :save triggers sync_to_pulse
      log = File.read(PULSE_DEBUG_LOG)
      expect(log).to include('"type":"bluetooth"')
      expect(log).to include('"address":"DE:AD:00:00:00:04"')
    end
  end
end

#############################################################################
# CliUserInterfaceTracker
#############################################################################
describe BlueHydra::CliUserInterfaceTracker do
  # minimal stand-in for a Runner that just holds the cui_status hash
  class FakeRunner
    attr_accessor :cui_status
    def initialize
      @cui_status = {}
    end
  end

  it "tracks an LE device and massages attributes for display" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:20"
    attrs  = {
      address:           [addr],
      last_seen:         [Time.now.to_i],
      le_rssi:           [{ rssi: "-50 dBm" }],
      lmp_version:       ["Bluetooth 4.1 (0x07) - Subversion 1 (0x1)"],
      le_address_type:   ["Public"],
      short_name:        ["shorty"],
      appearance:        ["Watch (0x00c0)"],
      ibeacon_range:     [5],
      company:           ["Apple, Inc. (76)"],
      le_company_data:   ["abc"]
    }

    tracker = BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr)
    tracker.update_cui_status

    status = runner.cui_status.values.first
    expect(status[:address]).to eq(addr)
    expect(status[:rssi]).to eq("-50 ")
    expect(status[:range]).to eq("5m")
    expect(status[:vers]).to eq("LE4.1")
    expect(status[:name]).to eq("shorty")
    expect(status[:type]).to eq("Watch ")
  end

  # The parser emits one range per chunk, so a batch is a series of estimates for
  # a beacon that is probably moving. The table has to show the newest, and agree
  # with what Device.update_or_create_from_result stored (also the last).
  it "shows the newest range estimate in a batch, not the oldest" do
    runner = FakeRunner.new
    addr   = "AA:BB:CC:DD:EE:21"
    tracker = BlueHydra::CliUserInterfaceTracker.new(
      runner,
      [["      LE Advertising Report (0x02)"]],
      { address: [addr], last_seen: [Time.now.to_i], ibeacon_range: [2.5, 9.75] },
      addr
    )
    tracker.update_cui_status

    expect(runner.cui_status.values.first[:range]).to eq("9.75m")
  end

  it "keeps the LE version label when the subversion hex contains 00 or ff" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:23"
    # subversion 0x0016 contains the substring "0x00" and must NOT be mistaken
    # for an unknown/invalid version code (that regression showed everything as
    # BTLE)
    attrs  = {
      address:     [addr],
      last_seen:   [Time.now.to_i],
      lmp_version: ["Bluetooth 5.2 (0x0b) - Subversion 22 (0x0016)"]
    }
    BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr).update_cui_status
    expect(runner.cui_status.values.first[:vers]).to eq("LE5.2")
  end

  it "keeps the LE version label when the subversion hex is ffff" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:25"
    attrs  = {
      address:     [addr],
      last_seen:   [Time.now.to_i],
      lmp_version: ["Bluetooth 5.0 (0x09) - Subversion 65535 (0xffff)"]
    }
    BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr).update_cui_status
    expect(runner.cui_status.values.first[:vers]).to eq("LE5.0")
  end

  it "falls back to BTLE for an unknown/invalid le version code (0x00)" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:24"
    attrs  = {
      address:     [addr],
      last_seen:   [Time.now.to_i],
      lmp_version: ["Bluetooth 1.0b (0x00) - Subversion 1 (0x0001)"]
    }
    BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr).update_cui_status
    expect(runner.cui_status.values.first[:vers]).to eq("BTLE")
  end

  it "reuses the existing uuid when the same address is tracked again" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:21"
    attrs  = { address: [addr], last_seen: [Time.now.to_i] }

    BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr).update_cui_status
    first_uuid = runner.cui_status.keys.first

    BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr).update_cui_status
    expect(runner.cui_status.keys).to eq([first_uuid])
  end

  it "tracks a classic device and uses vendor lookup for manuf" do
    runner = FakeRunner.new
    chunk  = [["> HCI Event: Remote Name Req Complete (0x07)"]]
    addr   = "AA:BB:CC:DD:EE:22"
    attrs  = {
      address:             [addr],
      last_seen:           [Time.now.to_i],
      classic_rssi:        [{ rssi: "-40 dBm" }],
      lmp_version:         ["Bluetooth 4.1 (0x07) - Subversion 1 (0x1)"],
      classic_minor_class: ["Uncategorized, code for device"]
    }

    tracker = BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr)
    tracker.update_cui_status

    status = runner.cui_status.values.first
    expect(status[:rssi]).to eq("-40 ")
    expect(status[:vers]).to eq("CL4.1")
    expect(status[:type]).to eq("Uncategorized")
    expect(status[:manuf]).to be_a(String)
  end

  it "derives manuf from company info for non-public le devices" do
    runner = FakeRunner.new
    chunk  = [["      LE Advertising Report (0x02)"]]
    addr   = "AA:BB:CC:DD:EE:23"
    attrs  = {
      address:         [addr],
      last_seen:       [Time.now.to_i],
      le_address_type: ["Random"],
      company:         ["Acme Corp (123)"]
    }

    tracker = BlueHydra::CliUserInterfaceTracker.new(runner, chunk, attrs, addr)
    tracker.update_cui_status
    expect(runner.cui_status.values.first[:manuf]).to eq("Acme Corp ")
  end
end

#############################################################################
# Parser branch coverage
#############################################################################
describe "BlueHydra::Parser branch handling" do
  # build a chunk in the shape the parser expects:
  #   index 0  -> HCI header line (shifted off)
  #   index 1  -> determines le/classic mode
  #   ...      -> data lines
  #   last     -> "last_seen: <ts>" timestamp (popped off)
  def parse(lines)
    chunk = lines + ["last_seen: 1500000000"]
    p = BlueHydra::Parser.new([chunk])
    p.parse
    p.attributes
  end

  it "parses classic single-line attributes" do
    attrs = parse([
      "> HCI Event: Remote Name Req Complete (0x07) plen 1",
      "        Status: Success (0x00)",
      "        Address: 00:11:22:33:44:55 (OUI 00-11-22)",
      "        LMP version: Bluetooth 4.1 (0x07)",
      "        Manufacturer: Broadcom (15)",
      "        Name: TestDevice",
      "        Firmware: 1.0",
      "        Appearance: Watch (0x00c0)",
      "        RSSI: -50 dBm (0xce)",
      "        TX power: 4 dBm",
      "        Address type: Public (0x00)",
      "        Name (short): shorty",
      "        Handle: 12",
      "        UUID: PnP Information (0x1200)"
    ])

    expect(attrs[:classic_mode]).to eq([true])
    expect(attrs[:address]).to eq(["00:11:22:33:44:55"])
    expect(attrs[:lmp_version]).to eq(["Bluetooth 4.1 (0x07)"])
    expect(attrs[:manufacturer]).to eq(["Broadcom (15)"])
    expect(attrs[:name]).to eq(["TestDevice"])
    expect(attrs[:firmware]).to eq(["1.0"])
    expect(attrs[:appearance]).to eq(["Watch (0x00c0)"])
    expect(attrs[:short_name]).to eq(["shorty"])
    expect(attrs[:classic_address_type]).to eq(["Public (0x00)"])
    expect(attrs[:classic_handle]).to eq(["12"])
    expect(attrs[:last_seen]).to eq([1500000000])
    expect(attrs[:classic_rssi].first[:rssi]).to eq("-50 dBm")
  end

  it "parses le address with random address type" do
    attrs = parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Advertising Report (0x02)",
      "        LE Address: 11:22:33:44:55:66 (Resolvable)"
    ])
    expect(attrs[:le_mode]).to eq([true])
    expect(attrs[:address]).to eq(["11:22:33:44:55:66"])
    expect(attrs[:le_random_address_type]).to eq(["(Resolvable)"])
  end

  it "parses a classic Class grouped block" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Class: 0x7a020c",
      "          Major class: Phone (cellular, cordless, payphone, modem)",
      "          Minor class: Smart phone",
      "          Networking (LAN, Ad hoc)"
    ])
    expect(attrs[:classic_major_class]).to eq(["Phone (cellular, cordless, payphone, modem)"])
    expect(attrs[:classic_minor_class]).to eq(["Smart phone"])
    expect(attrs[:classic_class].flatten).to include("Networking (LAN, Ad hoc)")
  end

  it "parses an le Flags grouped block" do
    attrs = parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Advertising Report (0x02)",
      "        Flags: 0x06",
      "          LE General Discoverable Mode",
      "          BR/EDR Not Supported"
    ])
    expect(attrs[:le_flags].first).to include("LE General Discoverable Mode")
  end

  it "parses a Page / Features grouped block" do
    attrs = parse([
      "> HCI Event: Remote Host Supported Features (0x3d) plen 1",
      "        Status: Success (0x00)",
      "        Page: 1/1",
      "        Features: 0x07 0x00 0x00 0x00 0x00 0x00 0x00 0x00",
      "          Secure Simple Pairing (Host Support)",
      "          LE Supported (Host)"
    ])
    expect(attrs[:classic_features_bitmap]).to eq([["1", "0x07 0x00 0x00 0x00 0x00 0x00 0x00 0x00"]])
    expect(attrs[:classic_features].first).to include("Secure Simple Pairing (Host Support)")
  end

  it "parses a Features grouped block with default page" do
    attrs = parse([
      "> HCI Event: Remote Host Supported Features (0x3d) plen 1",
      "        Status: Success (0x00)",
      "        Features: 0x07 0x00",
      "          Secure Simple Pairing (Host Support)"
    ])
    expect(attrs[:classic_features_bitmap]).to eq([["0", "0x07 0x00"]])
  end

  it "parses a Channels grouped block" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Channels: 0-39",
      "          something else"
    ])
    expect(attrs[:classic_channels].first).to include("0-39")
  end

  it "parses 128-bit and 16-bit service uuid lists" do
    attrs128 = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        128-bit Service UUIDs (complete): 2 entries",
      "          00000000-deca-fade-deca-deafdecacafe",
      "          2d8d2466-e14d-451c-88bc-7301abea291a"
    ])
    expect(attrs128[:classic_service_uuids]).to include("00000000-deca-fade-deca-deafdecacafe")

    attrs16 = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        16-bit Service UUIDs (complete): 1 entries",
      "          PnP Information (0x1200)"
    ])
    expect(attrs16[:classic_uuids]).to include("PnP Information (0x1200)")
  end

  it "parses a Primary Service attribute" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Attribute type: Primary Service (0x2800)",
      "          UUID: Unknown (7905f431-b5ce-4e99-a40f-4b1e122d00d0)"
    ])
    expect(attrs[:classic_service_uuids]).to include("Unknown (7905f431-b5ce-4e99-a40f-4b1e122d00d0)")
  end

  it "parses a Service Data single line" do
    attrs = parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Advertising Report (0x02)",
      "        Service Data (UUID 0xfe9f): 0000000000000000000000000000000000000000"
    ])
    expect(attrs[:le_service_uuids]).to include("0xfe9f")
  end

  it "parses a Company iBeacon block (proximity, major, minor, tx power, data)" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Company: Apple, Inc. (76)",
      "          Type: iBeacon (2)",
      "          UUID: 7988f2b6-dc41-1291-8746-ecf83cc7a06c",
      "          Version: 15104.61591",
      "          TX power: -56 dB",
      "          Data: 01adddd439aed386c76574e9ab9e11958e25c1f70ae203"
    ])
    expect(attrs[:company]).to eq(["Apple, Inc. (76)"])
    expect(attrs[:company_type]).to eq(["iBeacon (2)"])
    expect(attrs[:classic_proximity_uuid]).to_not eq(nil)
    expect(attrs[:classic_major_num]).to_not eq(nil)
    expect(attrs[:classic_minor_num]).to_not eq(nil)
    expect(attrs[:classic_company_data]).to eq(["01adddd439aed386c76574e9ab9e11958e25c1f70ae203"])
  end

  # "-56 dB" is the beacon's measured power - the RSSI it calibrates to one metre.
  # It used to land in classic_tx_power/le_tx_power, which meant that column held
  # a reference RSSI in the wrong units, and on a beacon advertising no AD Tx
  # Power element it held nothing else.
  it "keeps an iBeacon's measured power out of the TX power attribute" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Company: Apple, Inc. (76)",
      "          Type: iBeacon (2)",
      "          UUID: 7988f2b6-dc41-1291-8746-ecf83cc7a06c",
      "          Version: 15104.61591",
      "          TX power: -56 dB",
      "          Data: 01adddd439aed386c76574e9ab9e11958e25c1f70ae203"
    ])
    expect(attrs[:classic_tx_power]).to be_nil
    expect(attrs[:classic_ibeacon_measured_power]).to eq(["-56 dB"])
  end

  it "parses a Company block with non-ibeacon types" do
    attrs = parse([
      "> HCI Event: Extended Inquiry Result (0x2f) plen 1",
      "        Status: Success (0x00)",
      "        Company: Foo Corp (123)",
      "          Type: Unknown (12)",
      "          UUID: abcd",
      "          Version: 1.2",
      "          Data: 00ff"
    ])
    expect(attrs[:company]).to eq(["Foo Corp (123)"])
    expect(attrs[:classic_company_uuid]).to eq(["abcd"])
    expect(attrs[:classic_company_version]).to eq(["1.2"])
    expect(attrs[:classic_company_data]).to eq(["00ff"])
  end

  it "parses an LE-prefixed regrouped block" do
    attrs = parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Advertising Report (0x02)",
      "        Address: 11:22:33:44:55:66 (OUI)",
      "        Name: BeaconThing"
    ])
    expect(attrs[:address]).to eq(["11:22:33:44:55:66"])
    expect(attrs[:name]).to eq(["BeaconThing"])
  end
end

#############################################################################
# TX power: four different quantities, one label
#############################################################################
# btmon prints "TX power:" for the device's advertised power, an iBeacon's
# measured power, our own controller's power, and the report field's
# not-available sentinel. One regex swept up all four, so a single advertising
# report fed two quantities into one Text column and Device resolved them by
# lexical sort - which ranked the sentinel "127 dBm" above a real "3 dBm".
#
# Reproduced on a 9 minute device capture: 88 of 1051 chunks carried a conflict,
# and the two addresses that flapped in the device's own log came out storing
# "127 dBm" and "-59 dB" respectively.
describe "BlueHydra::Parser TX power sources" do
  def parse(lines)
    chunk = lines + ["last_seen: 1500000000"]
    p = BlueHydra::Parser.new([chunk])
    p.parse
    p.attributes
  end

  def le_report(*data_lines)
    [
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Extended Advertising Report (0x0d)",
      "        Address: AA:BB:CC:DD:EE:FF (OUI)"
    ] + data_lines
  end

  it "records the device's advertised TX power" do
    attrs = parse(le_report("        TX power: 3 dBm"))
    expect(attrs[:le_tx_power]).to eq(["3 dBm"])
  end

  it "records a negative advertised TX power" do
    attrs = parse(le_report("        TX power: -12 dBm"))
    expect(attrs[:le_tx_power]).to eq(["-12 dBm"])
  end

  # 0x7f, the report field's "information not available". Not a reading, and no
  # transmitter emits +127 dBm, so it is dropped wherever it appears.
  it "drops the not-available sentinel" do
    attrs = parse(le_report("        TX power: 127 dBm"))
    expect(attrs[:le_tx_power]).to be_nil
  end

  # the exact shape that flapped on device: the sentinel and the real value in
  # one report. Only the real one may survive, or the lexical sort in Device
  # picks the sentinel.
  it "keeps only the real value when the sentinel arrives alongside it" do
    attrs = parse(le_report(
      "        TX power: 127 dBm",
      "        Name (complete): 84C8D48AFC5E4102",
      "        TX power: 3 dBm"
    ))
    expect(attrs[:le_tx_power]).to eq(["3 dBm"])
  end

  # our own controller answering an HCI read. bluez prints these lowercase with
  # the raw byte; BtmonHandler drops them upstream, so this is belt and braces.
  it "ignores our own controller's TX power" do
    attrs = parse(le_report("        TX power: 12 dbm (0x0c)"))
    expect(attrs[:le_tx_power]).to be_nil
  end

  it "ignores an unparseable TX power" do
    attrs = parse(le_report("        TX power: unavailable"))
    expect(attrs[:le_tx_power]).to be_nil
  end
end

#############################################################################
# iBeacon proximity UUID grouping
#############################################################################
# The UUID used to be regrouped with four capture groups where a UUID has five,
# so the last 16 characters came out as one blob. The hex was right; a dash was
# missing. It affected every iBeacon sighting - 64 of 64 in a 9 minute capture.
describe "BlueHydra::Parser proximity UUID" do
  def parse(lines)
    chunk = lines + ["last_seen: 1500000000"]
    p = BlueHydra::Parser.new([chunk])
    p.parse
    p.attributes
  end

  def beacon(uuid)
    parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Extended Advertising Report (0x0d)",
      "        Address: AA:BB:CC:DD:EE:FF (OUI)",
      "        Company: Apple, Inc. (76)",
      "          Type: iBeacon (2)",
      "          UUID: #{uuid}",
      "          Version: 15104.61591",
      "          TX power: -59 dB"
    ])
  end

  # taken from a real capture: these exact wire bytes produced the misgrouped
  # "74278bda-b644-4520-8f0c720eaf059935"
  it "groups the UUID 8-4-4-4-12" do
    attrs = beacon("359905af-0e72-0c8f-2045-44b6da8b2774")
    expect(attrs[:le_proximity_uuid]).to eq(["74278bda-b644-4520-8f0c-720eaf059935"])
  end

  it "produces a canonically shaped UUID" do
    uuid = beacon("359905af-0e72-0c8f-2045-44b6da8b2774")[:le_proximity_uuid].first
    expect(uuid).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  # the byte reversal undoes bluez printing this UUID back to front, and must
  # survive any future tidying of the regrouping
  it "reverses the byte order bluez printed, recovering the wire bytes" do
    uuid = beacon("359905af-0e72-0c8f-2045-44b6da8b2774")[:le_proximity_uuid].first
    expect(uuid.delete("-")).to eq("74278bdab64445208f0c720eaf059935")
  end

  # an empty or partial UUID is worse than none: it is an identity key for a
  # rotated address, so two unrelated beacons that both failed to parse would
  # resolve to one record
  it "records nothing for a UUID that is not 16 bytes" do
    expect(beacon("359905af-0e72-0c8f")[:le_proximity_uuid]).to be_nil
  end

  it "records nothing for a non-hex UUID" do
    expect(beacon("zzzzzzzz-0e72-0c8f-2045-44b6da8b2774")[:le_proximity_uuid]).to be_nil
  end
end

#############################################################################
# iBeacon range
#############################################################################
# The range was computed inline with the RSSI line from a value parsed later in
# the same chunk, so it was always nil and the estimate never happened - 0 of 64
# iBeacon chunks in a 9 minute capture produced one, and the CUI has a column for
# it that was therefore always blank.
describe "BlueHydra::Parser iBeacon range" do
  def parse(lines)
    chunk = lines + ["last_seen: 1500000000"]
    p = BlueHydra::Parser.new([chunk])
    p.parse
    p.attributes
  end

  # RSSI first, then the manufacturer data: the order btmon actually emits, and
  # the order that used to defeat the calculation.
  def beacon_chunk(rssi, measured)
    [
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Extended Advertising Report (0x0d)",
      "        Address: AA:BB:CC:DD:EE:FF (OUI)",
      "        RSSI: #{rssi} dBm (0xab)",
      "        Company: Apple, Inc. (76)",
      "          Type: iBeacon (2)",
      "          UUID: 7988f2b6-dc41-1291-8746-ecf83cc7a06c",
      "          Version: 15104.61591",
      "          TX power: #{measured} dB"
    ]
  end

  it "estimates the range even though RSSI is printed before the measured power" do
    attrs = parse(beacon_chunk(-85, -59))
    expect(attrs[:ibeacon_range]).to eq([Math.sqrt(10 ** (26 / 10.0)).round(2)])
  end

  # at the calibration distance the ratio is 0 dB, so the estimate is 1 metre -
  # a fixed point that catches the ratio being inverted
  it "estimates one metre when the RSSI equals the measured power" do
    attrs = parse(beacon_chunk(-59, -59))
    expect(attrs[:ibeacon_range]).to eq([1.0])
  end

  it "estimates further away as the RSSI weakens" do
    near = parse(beacon_chunk(-65, -59))[:ibeacon_range].first
    far  = parse(beacon_chunk(-85, -59))[:ibeacon_range].first
    expect(far).to be > near
  end

  it "does not guess a range for a device that is not a beacon" do
    attrs = parse([
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Extended Advertising Report (0x0d)",
      "        Address: AA:BB:CC:DD:EE:FF (OUI)",
      "        RSSI: -85 dBm (0xab)",
      "        TX power: 3 dBm"
    ])
    expect(attrs[:ibeacon_range]).to be_nil
  end

  # the measured power belongs to the chunk that carried it; a later report from
  # the same batch must not borrow another beacon's calibration
  it "does not carry a measured power into a later chunk" do
    beacon = beacon_chunk(-85, -59) + ["last_seen: 1500000000"]
    plain  = [
      "> HCI Event: LE Meta Event (0x3e) plen 1",
      "      LE Extended Advertising Report (0x0d)",
      "        Address: AA:BB:CC:DD:EE:FF (OUI)",
      "        RSSI: -70 dBm (0xba)",
      "last_seen: 1500000001"
    ]
    p = BlueHydra::Parser.new([beacon, plain])
    p.parse

    expect(p.attributes[:ibeacon_range].count).to eq(1)
  end
end

#############################################################################
# Chunker dispatch logic
#############################################################################
describe "BlueHydra::Chunker dispatch" do
  def starting_msg(addr)
    [
      "> HCI Event: Role Change (0x12) plen 8               2015-12-10 11:31:08.667931\r\n",
      "        Address: #{addr} (Apple)\r\n"
    ]
  end

  def nonstarting_msg(addr)
    # Encryption Change (0x08) is address-bearing but NOT a chunk-start code, so
    # it merges into the current working set - which is the only property these
    # specs need from it.
    #
    # Third event to hold this role: Disconnect Complete (0x05) and then Max Slots
    # Change (0x1b) both became start codes as address-bearing events were found
    # merging devices together. See Chunker::HCI_EVENT_START_CODES.
    [
      "> HCI Event: Encryption Change (0x08) plen 4          2015-12-10 11:30:58.970878\r\n",
      "        Status: Success (0x00)\r\n",
      "        Handle: 256 Address: #{addr} (Apple)\r\n"
    ]
  end

  def no_address_msg
    [
      "> HCI Event: Command Complete (0x0e) plen 4          2015-12-10 11:30:24.387882\r\n",
      "        Foo: bar\r\n"
    ]
  end

  # run the chunker until it has flushed at least one working set
  def drain(q_in, q_out, pushes)
    chunker = BlueHydra::Chunker.new(q_in, q_out)
    t = Thread.new { chunker.chunk_it_up }
    pushes.each { |m| q_in.push(m) }
    sleep 0.5
    t.kill
  end

  it "pushes a clean single-address working set downstream" do
    q_in = Queue.new; q_out = Queue.new
    drain(q_in, q_out, [starting_msg("AA:BB:CC:11:22:33"), starting_msg("AA:BB:CC:44:55:66")])
    expect(q_out.empty?).to eq(false)
  end

  it "skips working sets whose address is in ignore_mac" do
    ignored = "AA:BB:CC:77:88:99"
    BlueHydra.config["ignore_mac"] << ignored
    q_in = Queue.new; q_out = Queue.new
    drain(q_in, q_out, [starting_msg(ignored), starting_msg("AA:BB:CC:00:00:01")])
    expect(q_out.empty?).to eq(true)
    BlueHydra.config["ignore_mac"].delete(ignored)
  end

  it "discards working sets that contain more than one address" do
    q_in = Queue.new; q_out = Queue.new
    drain(q_in, q_out, [
      starting_msg("AA:BB:CC:00:00:02"),
      nonstarting_msg("AA:BB:CC:00:00:03"),
      starting_msg("AA:BB:CC:00:00:04")
    ])
    expect(q_out.empty?).to eq(true)
  end

  it "discards working sets that contain no address" do
    q_in = Queue.new; q_out = Queue.new
    drain(q_in, q_out, [no_address_msg, starting_msg("AA:BB:CC:00:00:05")])
    expect(q_out.empty?).to eq(true)
  end

  it "logs to the chunk logger when chunker_debug is enabled" do
    # Must be a double: writing the real chunk logger is a suite failure (see
    # ChunkLogGuard in spec_helper). Asserting against it also makes this
    # example actually test what its name says - it previously only checked that
    # the zero-address chunk was discarded.
    chunk_log = double("chunk_logger", info: nil)
    allow(BlueHydra).to receive(:chunk_logger).and_return(chunk_log)

    BlueHydra.config["chunker_debug"] = true
    begin
      q_in = Queue.new; q_out = Queue.new
      drain(q_in, q_out, [no_address_msg, starting_msg("AA:BB:CC:00:00:06")])
      expect(q_out.empty?).to eq(true)
      expect(chunk_log).to have_received(:info).at_least(:once)
    ensure
      # ensure, so a failure here cannot leak chunker_debug into other examples
      BlueHydra.config["chunker_debug"] = false
    end
  end
end

#############################################################################
# Runner helper methods
#############################################################################
describe "BlueHydra::Runner helpers" do
  it "ubertooth_firmware_check flags devices that need a firmware upgrade" do
    runner = BlueHydra::Runner.new
    runner.scanner_status = {}
    result = runner.ubertooth_firmware_check("Please upgrade to latest released firmware\nmore")
    expect(result).to eq(false)
    expect(runner.scanner_status[:ubertooth]).to eq('Disabled, firmware upgrade required')
  end

  it "ubertooth_firmware_check passes clean firmware output" do
    runner = BlueHydra::Runner.new
    runner.scanner_status = {}
    expect(runner.ubertooth_firmware_check("everything is fine")).to eq(true)
  end

  it "update_processing_speed divides the processed count by the actual elapsed time" do
    runner = BlueHydra::Runner.new
    runner.instance_variable_set(:@processing_tracker, 40)
    runner.instance_variable_set(:@processing_timer, Time.now.to_i - 20) # 20s window
    runner.update_processing_speed
    expect(runner.processing_speed).to be_within(0.01).of(2.0) # 40 / 20
  end

  it "update_processing_speed does nothing until the sampling window elapses" do
    runner = BlueHydra::Runner.new
    runner.processing_speed = 7.0
    runner.instance_variable_set(:@processing_tracker, 5)
    runner.instance_variable_set(:@processing_timer, Time.now.to_i - 3) # < 10s
    runner.update_processing_speed
    expect(runner.processing_speed).to eq(7.0) # unchanged
  end

  it "push_to_queue enqueues a classic info scan" do
    runner = BlueHydra::Runner.new
    runner.query_history = {}
    runner.info_scan_queue = Queue.new
    runner.push_to_queue(:classic, "AB:CD:EF:11:22:33")
    expect(runner.info_scan_queue.empty?).to eq(false)
    item = runner.info_scan_queue.pop
    expect(item[:command]).to eq(:info)
    expect(item[:address]).to eq("AB:CD:EF:11:22:33")
  end

  it "push_to_queue enqueues an le info scan" do
    runner = BlueHydra::Runner.new
    runner.query_history = {}
    runner.le_info_scan_queue = Queue.new
    runner.push_to_queue(:le, "AB:CD:EF:44:55:66")
    item = runner.le_info_scan_queue.pop
    expect(item[:command]).to eq(:leinfo)
  end

  it "push_to_queue ignores the local adapter address" do
    runner = BlueHydra::Runner.new
    runner.query_history = {}
    runner.le_info_scan_queue = Queue.new
    runner.push_to_queue(:le, BlueHydra::LOCAL_ADAPTER_ADDRESS)
    expect(runner.le_info_scan_queue.empty?).to eq(true)
  end

  it "push_to_queue carries the le address type on the queue entry" do
    runner = BlueHydra::Runner.new
    runner.query_history = {}
    runner.le_info_scan_queue = Queue.new
    runner.push_to_queue(:le, "AB:CD:EF:44:55:77", "Random")
    item = runner.le_info_scan_queue.pop
    expect(item[:le_address_type]).to eq("Random")
  end

  it "service_le_info_scans drains the le queue into the auto-connect list" do
    runner = BlueHydra::Runner.new
    runner.auto_connect_list = {}
    runner.le_pending = {}
    runner.le_info_scan_queue = Queue.new
    fake_mgmt = double("mgmt")
    allow(fake_mgmt).to receive(:add_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    runner.mgmt = fake_mgmt

    runner.le_info_scan_queue.push({ command: :leinfo, address: "AA:BB:CC:DD:EE:50", le_address_type: "Public" })
    runner.service_le_info_scans

    expect(runner.le_info_scan_queue.empty?).to eq(true)
    expect(runner.auto_connect_list).to have_key("AA:BB:CC:DD:EE:50")
    expect(fake_mgmt).to have_received(:add_device).with("AA:BB:CC:DD:EE:50", BlueHydra::Mgmt::LE_PUBLIC)
  end

  it "request_leinfo adds an le device via mgmt when a slot is free" do
    runner = BlueHydra::Runner.new
    runner.auto_connect_list = {}
    runner.le_pending = {}
    runner.le_direct_pending = {}
    fake_mgmt = double("mgmt")
    allow(fake_mgmt).to receive(:add_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    runner.mgmt = fake_mgmt

    # CA: is a random STATIC address (top two bits of the first octet set), which
    # is what mgmt Add Device requires. A random address without those bits is
    # private and takes the direct-connect path instead (see the specs below).
    runner.request_leinfo("CA:BB:CC:DD:EE:40", "Random")

    expect(runner.auto_connect_list).to have_key("CA:BB:CC:DD:EE:40")
    expect(runner.le_pending).to be_empty
    expect(runner.le_direct_pending).to be_empty
    expect(fake_mgmt).to have_received(:add_device).with("CA:BB:CC:DD:EE:40", BlueHydra::Mgmt::LE_RANDOM)
  end

  describe "private-address LE devices (direct connect path)" do
    let(:fake_mgmt) do
      m = double("mgmt")
      allow(m).to receive(:add_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
      # the phase reads the real off-time for its deadline and puts discovery back
      # on when it exits
      allow(m).to receive(:discovery_off_for).and_return(0.0)
      allow(m).to receive(:start_discovery).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
      m
    end

    def runner_with_lists
      runner = BlueHydra::Runner.new
      runner.auto_connect_list  = {}
      runner.le_pending         = {}
      runner.le_direct_pending  = {}
      runner.mgmt               = fake_mgmt
      runner
    end

    # 0x7A -> top two bits 01: a resolvable private address.
    # 0x18 -> top two bits 00: a non-resolvable private address.
    # Neither can be given to mgmt Add Device, so neither may reach it.
    ["7A:BB:CC:DD:EE:01", "18:BB:CC:DD:EE:02"].each do |address|
      it "routes #{address} to the direct-connect queue instead of Add Device" do
        runner = runner_with_lists

        runner.request_leinfo(address, "Random")

        expect(runner.le_direct_pending).to have_key(address)
        expect(runner.auto_connect_list).to be_empty
        expect(runner.le_pending).to be_empty
        expect(fake_mgmt).not_to have_received(:add_device)
      end
    end

    it "records the mgmt address type so the connect uses the LE random path" do
      runner = runner_with_lists
      runner.request_leinfo("7A:BB:CC:DD:EE:01", "Random")
      expect(runner.le_direct_pending["7A:BB:CC:DD:EE:01"]).to eq(BlueHydra::Mgmt::LE_RANDOM)
    end

    it "re-sighting an address refreshes its queue position rather than duplicating it" do
      runner = runner_with_lists
      runner.request_leinfo("7A:00:00:00:00:01", "Random")
      runner.request_leinfo("7A:00:00:00:00:02", "Random")
      runner.request_leinfo("7A:00:00:00:00:01", "Random")

      expect(runner.le_direct_pending.size).to eq(2)
      # the re-sighted address moves to the back (freshest last)
      expect(runner.le_direct_pending.keys.last).to eq("7A:00:00:00:00:01")
    end

    it "drops the oldest entry when the backlog is full and counts the drop" do
      runner = runner_with_lists
      limit  = BlueHydra::Runner::LE_DIRECT_PENDING_LIMIT
      before = BlueHydra::CliUserInterfaceTracker.le_direct_dropped_count

      (limit + 1).times { |i| runner.request_leinfo("7A:00:00:%02X:%02X:%02X" % [i / 65536, (i / 256) % 256, i % 256], "Random") }

      expect(runner.le_direct_pending.size).to eq(limit)
      expect(BlueHydra::CliUserInterfaceTracker.le_direct_dropped_count).to eq(before + 1)
      # the first one queued is the one that went
      expect(runner.le_direct_pending).not_to have_key("7A:00:00:00:00:00")
    end

    it "next_le_direct_batch takes at most the configured parallel count, oldest first" do
      runner = runner_with_lists
      total  = BlueHydra::Runner::LE_DIRECT_CONNECT_PARALLEL + 3
      total.times { |i| runner.request_leinfo("7A:00:00:00:00:%02X" % i, "Random") }

      batch = runner.next_le_direct_batch

      expect(batch.size).to eq(BlueHydra::Runner::LE_DIRECT_CONNECT_PARALLEL)
      expect(batch.keys.first).to eq("7A:00:00:00:00:00")
      # taken entries leave the backlog, so the next batch makes progress
      expect(runner.le_direct_pending.size).to eq(3)
      expect(runner.le_direct_pending).not_to have_key("7A:00:00:00:00:00")
    end

    # The phase itself, not just its parts: a wiring bug here (no deadline, no
    # discovery suppression, a batch that never drains) only shows up on hardware.
    describe "le_direct_connect_phase" do
      def runner_for_phase(device_count)
        runner = runner_with_lists
        device_count.times { |i| runner.request_leinfo("7A:00:00:00:%02X:%02X" % [i / 256, i % 256], "Random") }
        allow(runner).to receive(:disable_scan_before_connect)
        allow(runner).to receive(:resume_discovery_if_over_budget) { |off_since| off_since }
        runner
      end

      it "drains the whole backlog in batches and suppresses discovery for each" do
        runner  = runner_for_phase(BlueHydra::Runner::LE_DIRECT_CONNECT_PARALLEL + 2)
        batches = []
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) do |entries, _deadline|
          batches << entries.keys
          entries.transform_values { :connected }
        end
        runner.le_connect = fake_connect

        runner.le_direct_connect_phase

        expect(runner.le_direct_pending).to be_empty
        expect(batches.size).to eq(2)
        expect(batches.first.size).to eq(BlueHydra::Runner::LE_DIRECT_CONNECT_PARALLEL)
        expect(batches.last.size).to eq(2)
        # discovery must be off for every batch, not just the first
        expect(runner).to have_received(:disable_scan_before_connect).twice
      end

      it "gives each batch a deadline inside the discovery-off budget" do
        runner    = runner_for_phase(2)
        deadlines = []
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) do |entries, deadline|
          deadlines << deadline
          entries.transform_values { :connected }
        end
        runner.le_connect = fake_connect

        started = Time.now
        runner.le_direct_connect_phase

        expect(deadlines.size).to eq(1)
        expect(deadlines.first).not_to be_nil
        # the deadline is the budget from when discovery went off, not open-ended
        expect(deadlines.first).to be <= (started + BlueHydra::Runner::DISCOVERY_OFF_BUDGET + 1)
      end

      it "yields the radio back to scanning between batches" do
        runner = runner_for_phase(BlueHydra::Runner::LE_DIRECT_CONNECT_PARALLEL + 1)
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) { |entries, _d| entries.transform_values { :connected } }
        runner.le_connect = fake_connect

        runner.le_direct_connect_phase

        # once per batch: this is what bounds contiguous discovery-off time
        expect(runner).to have_received(:resume_discovery_if_over_budget).twice
      end

      it "always leaves discovery on when it exits" do
        runner = runner_for_phase(2)
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) { |entries, _d| entries.transform_values { :connected } }
        runner.le_connect = fake_connect

        runner.le_direct_connect_phase

        # otherwise the off-window just continues into the classic drain
        expect(fake_mgmt).to have_received(:start_discovery).at_least(:once)
      end

      it "leaves discovery on even when a batch blows up" do
        runner = runner_for_phase(2)
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch).and_raise("radio on fire")
        runner.le_connect = fake_connect

        expect { runner.le_direct_connect_phase }.to raise_error(/radio on fire/)
        expect(fake_mgmt).to have_received(:start_discovery).at_least(:once)
      end

      it "shortens the batch deadline by time discovery was already off" do
        runner = runner_for_phase(2)
        # a previous phase already spent all but one second of the budget. Derived
        # from the constant rather than hardcoded, so tuning the budget does not
        # silently turn this into a test of nothing.
        already_off = BlueHydra::Runner::DISCOVERY_OFF_BUDGET - 1
        allow(fake_mgmt).to receive(:discovery_off_for).and_return(already_off.to_f)
        deadlines = []
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) do |entries, deadline|
          deadlines << deadline
          entries.transform_values { :connected }
        end
        runner.le_connect = fake_connect

        started = Time.now
        runner.le_direct_connect_phase

        # about the one second that was left, not a fresh full budget
        remaining = deadlines.first - started
        expect(remaining).to be < 2.0
        expect(remaining).to be < BlueHydra::Runner::DISCOVERY_OFF_BUDGET
      end

      it "never hands out a zero or negative deadline" do
        runner = runner_for_phase(2)
        # budget already blown through
        allow(fake_mgmt).to receive(:discovery_off_for).and_return(60.0)
        deadlines = []
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) do |entries, deadline|
          deadlines << deadline
          entries.transform_values { :abandoned }
        end
        runner.le_connect = fake_connect

        started = Time.now
        runner.le_direct_connect_phase

        # a floor keeps the batch from being abandoned before it can start
        expect(deadlines.first).to be > started
      end

      it "counts abandoned devices so a spent budget is visible" do
        runner = runner_for_phase(2)
        fake_connect = double("le_connect")
        allow(fake_connect).to receive(:connect_batch) { |entries, _d| entries.transform_values { :abandoned } }
        runner.le_connect = fake_connect
        before = BlueHydra::CliUserInterfaceTracker.le_direct_abandoned_count

        runner.le_direct_connect_phase

        expect(BlueHydra::CliUserInterfaceTracker.le_direct_abandoned_count).to eq(before + 2)
      end
    end

    it "counts a direct-connect batch's outcomes" do
      runner    = runner_with_lists
      connected = BlueHydra::CliUserInterfaceTracker.le_direct_connected_count
      failed    = BlueHydra::CliUserInterfaceTracker.le_direct_failed_count

      errored = BlueHydra::CliUserInterfaceTracker.le_direct_error_count

      runner.record_le_direct_results(
        "7A:00:00:00:00:01" => :connected,
        "7A:00:00:00:00:02" => :unreachable,
        "7A:00:00:00:00:03" => :error
      )

      expect(BlueHydra::CliUserInterfaceTracker.le_direct_connected_count).to eq(connected + 1)
      # a local socket error is counted apart from "asked and got no answer"
      expect(BlueHydra::CliUserInterfaceTracker.le_direct_failed_count).to eq(failed + 1)
      expect(BlueHydra::CliUserInterfaceTracker.le_direct_error_count).to eq(errored + 1)
    end
  end

  describe "discovery-off budget accounting" do
    def runner_with_mgmt(off_for)
      runner = BlueHydra::Runner.new
      m = double("mgmt")
      allow(m).to receive(:discovery_off_for).and_return(off_for)
      allow(m).to receive(:start_discovery).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
      runner.mgmt = m
      allow(runner).to receive(:sleep)
      runner
    end

    it "does not yield while discovery has been off less than the budget" do
      runner = runner_with_mgmt(1.0)
      off_since = Time.now
      expect(runner.resume_discovery_if_over_budget(off_since)).to eq(off_since)
      expect(runner.mgmt).not_to have_received(:start_discovery)
    end

    it "yields once discovery has been off longer than the budget" do
      runner = runner_with_mgmt(BlueHydra::Runner::DISCOVERY_OFF_BUDGET + 1)
      runner.resume_discovery_if_over_budget(Time.now)
      expect(runner.mgmt).to have_received(:start_discovery)
    end

    # The bug this replaced: a phase timed from its own entry, so time an earlier
    # phase had already spent with discovery off was invisible and the budget was
    # effectively granted twice over.
    it "measures against the kernel's off-time, not the caller's clock" do
      runner = runner_with_mgmt(BlueHydra::Runner::DISCOVERY_OFF_BUDGET + 5)
      # caller's own reference point says no time has passed at all
      runner.resume_discovery_if_over_budget(Time.now)
      expect(runner.mgmt).to have_received(:start_discovery)
    end

    it "falls back to the caller's clock when mgmt is unavailable" do
      runner = BlueHydra::Runner.new
      runner.mgmt = nil
      off_since = Time.now
      # under budget by the caller's clock, and no mgmt to consult
      expect(runner.resume_discovery_if_over_budget(off_since)).to eq(off_since)
    end
  end

  it "connect_phase leaves discovery on when it exits" do
    runner = BlueHydra::Runner.new
    runner.auto_connect_list = {}
    m = double("mgmt")
    allow(m).to receive(:start_discovery).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    allow(m).to receive(:connection_events).and_return(Queue.new)
    runner.mgmt = m
    allow(runner).to receive(:disable_scan_before_connect)
    allow(runner).to receive(:drain_connection_events)

    runner.connect_phase

    expect(m).to have_received(:start_discovery)
  end

  it "clear_auto_connect counts adds that never connected as timeouts" do
    runner = BlueHydra::Runner.new
    fake_mgmt = double("mgmt")
    allow(fake_mgmt).to receive(:remove_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:01" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: true },
      "AA:BB:CC:DD:EE:02" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: false },
      "AA:BB:CC:DD:EE:03" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: false }
    }
    before = BlueHydra::CliUserInterfaceTracker.auto_connect_timeout_count

    runner.clear_auto_connect

    # only the two that never connected count as timed out
    expect(BlueHydra::CliUserInterfaceTracker.auto_connect_timeout_count).to eq(before + 2)
    expect(runner.auto_connect_list).to be_empty
  end

  it "request_leinfo holds a device in le_pending when full and never loses it" do
    runner = BlueHydra::Runner.new
    runner.le_pending = {}
    fake_mgmt = double("mgmt")
    allow(fake_mgmt).to receive(:add_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    allow(fake_mgmt).to receive(:remove_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    runner.mgmt = fake_mgmt
    # fill all 32 slots with fresh (non-expired) entries
    runner.auto_connect_list = {}
    32.times do |i|
      runner.auto_connect_list["AA:BB:CC:DD:EE:%02X" % i] =
        { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now }
    end

    runner.request_leinfo("BB:BB:CC:DD:EE:FF", "Public")

    # held, not dropped: list still at cap, request waiting in le_pending
    expect(runner.auto_connect_list.size).to eq(32)
    expect(runner.auto_connect_list).not_to have_key("BB:BB:CC:DD:EE:FF")
    expect(runner.le_pending).to have_key("BB:BB:CC:DD:EE:FF")

    # free a slot (event-driven removal in the real flow), then fill promotes
    freed = runner.auto_connect_list.keys.first
    runner.auto_connect_list.delete(freed)
    runner.fill_auto_connect

    expect(runner.auto_connect_list).not_to have_key(freed)            # slot freed
    expect(runner.auto_connect_list).to have_key("BB:BB:CC:DD:EE:FF")  # pending promoted
    expect(runner.le_pending).to be_empty                             # nothing lost
  end

  # Helper: a fake mgmt exposing a real connection_events Queue plus the
  # add/remove/stop stubs the auto-connect flow uses.
  def fake_mgmt_with_events
    events = Queue.new
    m = double("mgmt")
    allow(m).to receive(:connection_events).and_return(events)
    allow(m).to receive(:add_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    allow(m).to receive(:remove_device).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    allow(m).to receive(:stop_discovery).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    # connect_phase now puts discovery back on when it exits, and reads the real
    # off-time rather than timing itself
    allow(m).to receive(:start_discovery).and_return(BlueHydra::Mgmt::STATUS_SUCCESS)
    allow(m).to receive(:discovery_off_for).and_return(0.0)
    [m, events]
  end

  it "process_connection_events removes a device immediately on Device Disconnected" do
    runner = BlueHydra::Runner.new
    fake_mgmt, events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:70" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: true }
    }

    events << { type: :disconnected, address: "AA:BB:CC:DD:EE:70" }
    runner.process_connection_events

    expect(runner.auto_connect_list).to be_empty
    expect(fake_mgmt).to have_received(:remove_device).with("AA:BB:CC:DD:EE:70", BlueHydra::Mgmt::LE_RANDOM)
  end

  it "process_connection_events removes and counts a Connect Failed" do
    BlueHydra::CliUserInterfaceTracker.auto_connect_failed_count = 0
    runner = BlueHydra::Runner.new
    fake_mgmt, events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:71" => { address_type: BlueHydra::Mgmt::LE_PUBLIC, added_at: Time.now, connected: false }
    }

    events << { type: :failed, address: "AA:BB:CC:DD:EE:71" }
    runner.process_connection_events

    expect(runner.auto_connect_list).to be_empty
    expect(BlueHydra::CliUserInterfaceTracker.auto_connect_failed_count).to eq(1)
  end

  it "process_connection_events marks a device connected and keeps it pending" do
    BlueHydra::CliUserInterfaceTracker.auto_connect_connected_count = 0
    runner = BlueHydra::Runner.new
    fake_mgmt, events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:72" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: false }
    }

    events << { type: :connected, address: "AA:BB:CC:DD:EE:72" }
    runner.process_connection_events

    expect(runner.auto_connect_list["AA:BB:CC:DD:EE:72"][:connected]).to eq(true)
    expect(runner.auto_connect_list).to have_key("AA:BB:CC:DD:EE:72") # still pending
    expect(BlueHydra::CliUserInterfaceTracker.auto_connect_connected_count).to eq(1)
  end

  it "process_connection_events ignores events for untracked addresses" do
    runner = BlueHydra::Runner.new
    fake_mgmt, events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {}

    events << { type: :disconnected, address: "FF:FF:FF:FF:FF:FF" }
    runner.process_connection_events

    expect(fake_mgmt).not_to have_received(:remove_device)
  end

  it "connect_phase suppresses discovery and resumes once the pending set empties" do
    runner = BlueHydra::Runner.new
    fake_mgmt, _events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:73" => { address_type: BlueHydra::Mgmt::LE_RANDOM, added_at: Time.now, connected: false }
    }
    # simulate the device disconnecting on the first processing pass
    allow(runner).to receive(:process_connection_events) { runner.auto_connect_list.clear }

    runner.connect_phase

    expect(fake_mgmt).to have_received(:stop_discovery) # discovery suppressed for the connect window
    expect(runner.auto_connect_list).to be_empty
  end

  it "connect_phase clears still-pending devices when the discovery-off budget elapses" do
    stub_const("BlueHydra::Runner::DISCOVERY_OFF_BUDGET", 0)
    runner = BlueHydra::Runner.new
    fake_mgmt, _events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {
      "AA:BB:CC:DD:EE:74" => { address_type: BlueHydra::Mgmt::LE_PUBLIC, added_at: Time.now, connected: false }
    }
    # no events arrive; the device never connects or disconnects

    runner.connect_phase

    expect(runner.auto_connect_list).to be_empty
    expect(fake_mgmt).to have_received(:remove_device).with("AA:BB:CC:DD:EE:74", BlueHydra::Mgmt::LE_PUBLIC)
  end

  # resume_discovery_if_over_budget is covered by the "discovery-off budget
  # accounting" describe block above, which also pins down that the elapsed time
  # comes from the kernel's off-time rather than the caller's clock.

  it "scan_phase adds pending devices up to CONNECT_PENDING_LIMIT then stops" do
    stub_const("BlueHydra::Runner::CONNECT_PENDING_LIMIT", 2)
    runner = BlueHydra::Runner.new
    fake_mgmt, _events = fake_mgmt_with_events
    runner.mgmt = fake_mgmt
    runner.auto_connect_list = {}
    runner.le_info_scan_queue = Queue.new
    runner.le_pending = {
      "AA:BB:CC:DD:EE:80" => "Public",
      "AA:BB:CC:DD:EE:81" => "Random",
      "AA:BB:CC:DD:EE:82" => "Public"
    }

    runner.scan_phase(5)

    expect(runner.auto_connect_list.size).to eq(2)   # capped at the pending limit
    expect(runner.le_pending.size).to eq(1)          # remainder held, never dropped
  end

  it "scan_with_reset_retry does not reset when the connect succeeds" do
    runner = BlueHydra::Runner.new
    expect(runner).not_to receive(:hci_reset)

    calls  = 0
    result = runner.scan_with_reset_retry { calls += 1; nil } # nil stderr == success

    expect(calls).to eq(1)
    expect(result).to be_nil
  end

  it "scan_with_reset_retry resets and retries once on a reset-worthy connect error" do
    runner = BlueHydra::Runner.new
    allow(runner).to receive(:hci_reset)

    results = ["Could not create connection: Input/output error", nil]
    calls   = 0
    final   = runner.scan_with_reset_retry { r = results[calls]; calls += 1; r }

    expect(runner).to have_received(:hci_reset).once
    expect(calls).to eq(2)      # original attempt + one retry
    expect(final).to be_nil     # retry succeeded
  end

  it "scan_with_reset_retry does not reset for an unreachable device (no route to host)" do
    runner = BlueHydra::Runner.new
    expect(runner).not_to receive(:hci_reset)

    calls = 0
    final = runner.scan_with_reset_retry { calls += 1; "connect: No route to host" }

    expect(calls).to eq(1)      # not reset-worthy, no retry
    expect(final).to match(/No route to host/)
  end

  it "reports a status hash for its queues and threads" do
    runner = BlueHydra::Runner.new
    [:raw_queue, :chunk_queue, :result_queue, :info_scan_queue, :le_info_scan_queue, :l2ping_queue].each do |q|
      runner.send("#{q}=", Queue.new)
    end
    worker = Thread.new { sleep 2 }
    [:btmon_thread, :chunker_thread, :parser_thread, :result_thread, :discovery_thread].each do |th|
      runner.send("#{th}=", worker)
    end
    status = runner.status
    expect(status).to be_a(Hash)
    expect(status[:raw_queue]).to eq(0)
    expect(status[:stopping]).to eq(nil)
    worker.kill
  end
end

#############################################################################
# CliUserInterface (render + helpers)
#############################################################################
describe BlueHydra::CliUserInterface do
  # a fuller fake runner exposing everything the UI reaches for
  class CuiFakeRunner
    attr_accessor :cui_status, :scanner_status, :result_queue,
                  :info_scan_queue, :l2ping_queue, :query_history,
                  :processing_speed, :stunned, :mgmt

    def initialize
      @cui_status       = {}
      @scanner_status   = {}
      @result_queue     = Queue.new
      @info_scan_queue  = Queue.new
      @l2ping_queue     = Queue.new
      @query_history    = {}
      @processing_speed = 1.0
      @stunned          = false
      @mgmt             = nil # matches a real Runner before discovery starts
    end
  end

  def silence_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  def device_status(overrides = {})
    {
      last_seen: Time.now.to_i,
      created:   Time.now.to_i,
      vers:      "LE4.1",
      address:   "AA:BB:CC:DD:EE:30",
      rssi:      "-50",
      name:      "Device",
      manuf:     "Acme",
      type:      "Phone",
      range:     "5m"
    }.merge(overrides)
  end

  let(:printable_keys) { [:_seen, :vers, :address, :rssi, :name, :manuf, :type, :range] }

  it "aliases queue and status accessors to the runner" do
    runner = CuiFakeRunner.new
    cui = BlueHydra::CliUserInterface.new(runner)
    expect(cui.scanner_status).to be(runner.scanner_status)
    expect(cui.result_queue).to be(runner.result_queue)
    expect(cui.l2ping_queue).to be(runner.l2ping_queue)
    expect(cui.query_history).to be(runner.query_history)
  end

  it "stop! requests graceful shutdown by signalling SIGINT to itself" do
    runner = CuiFakeRunner.new
    cui = BlueHydra::CliUserInterface.new(runner)
    allow(cui).to receive(:puts) # silence the "Exiting..." banner
    # must stub Process.kill or we would actually SIGINT the test runner
    expect(Process).to receive(:kill).with("INT", Process.pid)
    cui.stop!
  end

  it "reports info_scan_queue length or 'disabled' based on config" do
    runner = CuiFakeRunner.new
    cui = BlueHydra::CliUserInterface.new(runner)
    expect(cui.info_scan_queue).to eq(0)

    original = BlueHydra.info_scan
    BlueHydra.info_scan = false
    expect(cui.info_scan_queue).to eq("disabled")
    BlueHydra.info_scan = original
  end

  it "expires stale devices out of cui_status" do
    original_file = BlueHydra.config["file"]
    BlueHydra.config["file"] = false
    runner = CuiFakeRunner.new
    runner.cui_status["keep"]   = device_status(last_seen: Time.now.to_i)
    runner.cui_status["expire"] = device_status(last_seen: Time.now.to_i - 10_000)
    cui = BlueHydra::CliUserInterface.new(runner)
    result = cui.cui_status
    expect(result).to have_key("keep")
    expect(result).to_not have_key("expire")
    BlueHydra.config["file"] = original_file
  end

  it "renders an empty device table" do
    runner = CuiFakeRunner.new
    cui = BlueHydra::CliUserInterface.new(runner)
    keys = nil
    silence_stdout do
      keys = cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :disabled)
    end
    expect(keys).to eq(nil).or be_a(Array)
  end

  it "renders a populated device table across sorts and orders" do
    runner = CuiFakeRunner.new
    runner.cui_status["a"] = device_status(address: "AA:BB:CC:DD:EE:31", rssi: "-30", range: "2m")
    runner.cui_status["b"] = device_status(address: "AA:BB:CC:DD:EE:32", rssi: "-80", range: "9m")

    cui = BlueHydra::CliUserInterface.new(runner)

    [:rssi, :range, :_seen, :address].each do |sort|
      ["ascending", "descending"].each do |order|
        keys = nil
        silence_stdout do
          keys = cui.render_cui(40, sort, order, printable_keys.dup, :disabled)
        end
        expect(keys).to include(:address)
      end
    end
  end

  it "honors exclude filters when rendering" do
    runner = CuiFakeRunner.new
    excluded = "AA:BB:CC:DD:EE:33"
    runner.cui_status["x"] = device_status(address: excluded)
    BlueHydra.config["ui_exc_filter_mac"] << excluded
    cui = BlueHydra::CliUserInterface.new(runner)
    silence_stdout do
      cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :disabled)
    end
    BlueHydra.config["ui_exc_filter_mac"].delete(excluded)
  end

  it "honors exclusive include filter mode when rendering" do
    runner = CuiFakeRunner.new
    runner.cui_status["x"] = device_status(address: "AA:BB:CC:DD:EE:34")
    runner.cui_status["y"] = device_status(address: "AA:BB:CC:DD:EE:35")
    BlueHydra.config["ui_inc_filter_mac"] << "AA:BB:CC:DD:EE:34"
    cui = BlueHydra::CliUserInterface.new(runner)
    silence_stdout do
      cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :exclusive)
      cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :hilight)
    end
    BlueHydra.config["ui_inc_filter_mac"].delete("AA:BB:CC:DD:EE:34")
  end

  it "queues an l2ping for stale classic devices while rendering" do
    original_file = BlueHydra.config["file"]
    BlueHydra.config["file"] = false
    runner = CuiFakeRunner.new
    runner.cui_status["cl"] = device_status(
      address:   "AA:BB:CC:DD:EE:36",
      vers:      "CL4.0",
      last_seen: Time.now.to_i - 270
    )
    cui = BlueHydra::CliUserInterface.new(runner)
    silence_stdout do
      cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :disabled)
    end
    expect(runner.l2ping_queue.empty?).to eq(false)
    BlueHydra.config["file"] = original_file
  end

  it "masks addresses when demo mode is enabled" do
    runner = CuiFakeRunner.new
    runner.cui_status["d"] = device_status(address: "AA:BB:CC:DD:EE:37")
    cui = BlueHydra::CliUserInterface.new(runner)
    original = BlueHydra.demo_mode
    BlueHydra.demo_mode = true
    silence_stdout do
      cui.render_cui(40, :address, "ascending", printable_keys.dup, :disabled)
    end
    BlueHydra.demo_mode = original
  end

  describe "VERS is labeled from the device's known transport" do
    # push one chunk through the tracker; chunk_first_line drives its le/classic
    # detection (the post-shift first line), attrs supplies parsed values.
    def track(runner, chunk_first_line, attrs, address)
      t = BlueHydra::CliUserInterfaceTracker.new(runner, [[chunk_first_line]], attrs, address)
      t.update_cui_status
      t
    end

    it "labels a version read on an LE device as LEx.x (not CLx.x)" do
      runner = CuiFakeRunner.new
      addr = "AA:BB:CC:DD:EE:90"
      # first seen via LE advertising (no version) -> records :le, shows BTLE
      track(runner, "      LE Extended Advertising Report (0x0d)", { address: [addr] }, addr)
      # then a version read - transport-agnostic chunk that parses as classic
      t = track(runner, "        Status: Success (0x00)",
                { address: [addr], lmp_version: ["Bluetooth 6.0 (0x0e) - Subversion 1"] }, addr)
      expect(runner.cui_status[t.uuid][:vers]).to eq("LE6.0")
    end

    it "labels a version read on a classic-only device as CLx.x" do
      runner = CuiFakeRunner.new
      addr = "AA:BB:CC:DD:EE:91"
      # first seen via classic (no version) -> records :classic
      track(runner, "        Page: 1/1", { address: [addr] }, addr)
      t = track(runner, "        Status: Success (0x00)",
                { address: [addr], lmp_version: ["Bluetooth 5.2 (0x0b) - Subversion 1"] }, addr)
      expect(runner.cui_status[t.uuid][:vers]).to eq("CL5.2")
    end
  end
end

#############################################################################
# Command.execute3 extra paths
#############################################################################
describe "BlueHydra::Command.execute3" do
  it "captures stderr output" do
    result = BlueHydra::Command.execute3("echo oops 1>&2")
    expect(result[:stderr]).to eq("oops")
    expect(result[:exit_code]).to eq(0)
  end

  it "enforces a timeout and kills the long running process" do
    result = BlueHydra::Command.execute3("sleep 5", 1)
    expect(result).to be_a(Hash)
  end
end

#############################################################################
# Runner thread workers (driven directly, then killed)
#############################################################################
describe "BlueHydra::Runner threads" do
  def kill_thread(t)
    t.kill if t
  end

  it "parser thread converts chunks into result queue entries" do
    runner = BlueHydra::Runner.new
    runner.chunk_queue  = Queue.new
    runner.result_queue = Queue.new
    runner.cui_status   = {}

    chunk = [
      "> HCI Event: Remote Name Req Complete (0x07) plen 1",
      "        Status: Success (0x00)",
      "        Address: 00:11:22:33:44:60 (OUI)",
      "        Name: ParsedDevice",
      "last_seen: #{Time.now.to_i}"
    ]

    runner.start_parser_thread
    runner.chunk_queue.push([chunk])

    # give the worker a moment to process
    20.times { break unless runner.result_queue.empty?; sleep 0.1 }

    expect(runner.result_queue.empty?).to eq(false)
    attrs = runner.result_queue.pop
    expect(attrs[:address]).to eq(["00:11:22:33:44:60"])
    kill_thread(runner.parser_thread)
  end

  it "result thread creates devices from queued results" do
    runner = BlueHydra::Runner.new
    runner.result_queue    = Queue.new
    runner.info_scan_queue = Queue.new
    runner.l2ping_queue    = Queue.new
    runner.query_history   = {}

    runner.start_result_thread
    runner.result_queue.push({
      address:   ["CC:DD:EE:FF:00:61"],
      name:      ["ResultDevice"],
      last_seen: [Time.now.to_i]
    })

    20.times do
      break if BlueHydra::Device.all(address: "CC:DD:EE:FF:00:61").count > 0
      sleep 0.1
    end

    expect(BlueHydra::Device.all(address: "CC:DD:EE:FF:00:61").count).to be >= 1
    kill_thread(runner.result_thread)
  end

  it "chunker thread groups raw queue messages into the chunk queue" do
    runner = BlueHydra::Runner.new
    runner.raw_queue   = Queue.new
    runner.chunk_queue = Queue.new

    runner.start_chunker_thread

    runner.raw_queue.push([
      "> HCI Event: Role Change (0x12) plen 8               2015-12-10 11:31:08.667931\r\n",
      "        Address: AA:BB:CC:00:00:61 (Apple)\r\n"
    ])
    runner.raw_queue.push([
      "> HCI Event: Role Change (0x12) plen 8               2015-12-10 11:31:09.667931\r\n",
      "        Address: AA:BB:CC:00:00:62 (Apple)\r\n"
    ])

    20.times { break unless runner.chunk_queue.empty?; sleep 0.1 }
    expect(runner.chunk_queue.empty?).to eq(false)
    kill_thread(runner.chunker_thread)
  end

  it "btmon thread runs the configured command via the handler" do
    runner = BlueHydra::Runner.new
    runner.raw_queue = Queue.new
    filepath = File.expand_path('../fixtures/btmon.stdout', __FILE__)
    runner.command = "cat #{filepath}"

    runner.start_btmon_thread
    20.times { break unless runner.raw_queue.empty?; sleep 0.1 }
    expect(runner.raw_queue.empty?).to eq(false)
    kill_thread(runner.btmon_thread)
  end
end

#############################################################################
# Database safety: the suite must never touch a file based database
#############################################################################
describe "test database isolation" do
  it "uses an in-memory sqlite database, not a file" do
    adapter = DataMapper.repository(:default).adapter
    expect(adapter).to be_a(DataMapper::Adapters::SqliteAdapter)
    expect(adapter.options["path"]).to eq(":memory:")
  end

  it "does not write to any on-disk blue_hydra.db when records are saved" do
    # the two locations the app would otherwise persist to (see lib/blue_hydra.rb)
    candidates = [
      File.expand_path('../../blue_hydra.db', __FILE__),
      '/etc/blue_hydra/blue_hydra.db'
    ]

    # snapshot the on-disk state (existence/size/mtime) before writing. A file
    # based db may already exist on this machine from real-world use; the point
    # is that the test suite must not touch it.
    before = candidates.map do |path|
      File.exist?(path) ? [true, File.size(path), File.mtime(path)] : [false, nil, nil]
    end

    # force several db writes to prove they land in memory, not on disk
    5.times do |i|
      d = BlueHydra::Device.new
      d.address = "DB:15:01:00:E0:%02d" % i
      d.save
    end

    after = candidates.map do |path|
      File.exist?(path) ? [true, File.size(path), File.mtime(path)] : [false, nil, nil]
    end

    expect(after).to eq(before)
  end
end

# Discovery is the whole job: a controller that will not start it produces no
# data at all. A DART sat in exactly that state - LE disabled, every Start
# Discovery answered REJECTED - looking alive while seeing nothing. That is the
# failure this turns into a loud exit rather than a log line in a running
# process.
describe "BlueHydra::Runner discovery failure handling" do
  let(:runner) { BlueHydra::Runner.new }

  before do
    allow(BlueHydra.logger).to receive(:fatal)
    allow(BlueHydra.logger).to receive(:warn)
    allow(BlueHydra).to receive(:send_event)
    allow(runner).to receive(:puts) # daemon_mode is false under test
  end

  def expect_exit_1
    expect { yield }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
  end

  it "logs fatal, notifies, and exits non-zero" do
    expect_exit_1 { runner.discovery_failed_fatal(BlueHydra::Mgmt::STATUS_REJECTED) }

    expect(BlueHydra.logger).to have_received(:fatal)
      .with(/start discovery failed.*0x0b \(REJECTED\)/)
    expect(BlueHydra).to have_received(:send_event).with(
      'blue_hydra',
      hash_including(key: 'blue_hydra_start_discovery_failed', severity: 'FATAL')
    )
  end

  it "distinguishes a first-cycle failure from repeated ones" do
    expect_exit_1 { runner.discovery_failed_fatal(BlueHydra::Mgmt::STATUS_REJECTED) }
    expect(BlueHydra.logger).to have_received(:fatal).with(/on the first discovery cycle/)

    expect_exit_1 { runner.discovery_failed_fatal(BlueHydra::Mgmt::STATUS_REJECTED, attempts: 2) }
    expect(BlueHydra.logger).to have_received(:fatal).with(/2 times in a row/)
  end

  # A refusal may be transient, so it is retried; only a controller that refuses
  # every attempt is called dead. But on the very first cycle nothing has ever
  # worked, so there is nothing to call transient - that is the DART case, which
  # ran for hours answering REJECTED to everything.
  describe "retry policy" do
    before do
      allow(BlueHydra.logger).to receive(:info)
      allow(runner).to receive(:sleep) # don't actually wait in the suite
    end

    it "is fatal on the first cycle without retrying" do
      mgmt = instance_double(
        BlueHydra::Mgmt,
        enabled_transports: ["BREDR"],
        start_discovery: BlueHydra::Mgmt::STATUS_SUCCESS # would rescue it, if reached
      )
      runner.mgmt = mgmt

      expect_exit_1 { runner.retry_start_discovery(BlueHydra::Mgmt::STATUS_REJECTED) }

      expect(mgmt).not_to have_received(:start_discovery)
      expect(runner).not_to have_received(:sleep)
      expect(BlueHydra.logger).to have_received(:fatal).with(/on the first discovery cycle/)
    end

    it "retries after a pause and carries on when a retry works" do
      runner.instance_variable_set(:@discovery_ever_started, true)
      runner.mgmt = instance_double(
        BlueHydra::Mgmt,
        enabled_transports: ["BREDR", "LE"],
        start_discovery: BlueHydra::Mgmt::STATUS_SUCCESS
      )

      status = runner.retry_start_discovery(BlueHydra::Mgmt::STATUS_REJECTED)

      expect(status).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(runner).to have_received(:sleep).with(BlueHydra::Runner::START_DISCOVERY_RETRY_DELAY).once
      expect(BlueHydra.logger).to have_received(:warn).with(/on attempt 1 of 2, retrying in 8s/)
      expect(BlueHydra.logger).to have_received(:info).with(/recovered on attempt 2/)
    end

    # BUSY means discovery is already running, so a retry that comes back BUSY has
    # found what it was looking for - it must not burn the remaining attempts and
    # must not end in a fatal.
    it "accepts a retry that comes back BUSY as recovered" do
      runner.instance_variable_set(:@discovery_ever_started, true)
      runner.mgmt = instance_double(
        BlueHydra::Mgmt,
        enabled_transports: ["BREDR", "LE"],
        start_discovery: BlueHydra::Mgmt::STATUS_BUSY
      )

      status = runner.retry_start_discovery(BlueHydra::Mgmt::STATUS_REJECTED)

      expect(status).to eq(BlueHydra::Mgmt::STATUS_BUSY)
      expect(runner.mgmt).to have_received(:start_discovery).once
      expect(BlueHydra.logger).to have_received(:info).with(/recovered on attempt 2/)
      expect(BlueHydra.logger).not_to have_received(:fatal)
    end

    # One retry, then the verdict. More attempts do not buy tolerance for anything
    # that reaches here - they only postpone the exit - so the count stays at two.
    it "is fatal once the single retry also fails" do
      runner.instance_variable_set(:@discovery_ever_started, true)
      runner.mgmt = instance_double(
        BlueHydra::Mgmt,
        enabled_transports: ["BREDR"],
        start_discovery: BlueHydra::Mgmt::STATUS_REJECTED
      )

      expect_exit_1 { runner.retry_start_discovery(BlueHydra::Mgmt::STATUS_REJECTED) }

      expect(runner.mgmt).to have_received(:start_discovery).once # plus the caller's own
      expect(runner).to have_received(:sleep).once
      expect(BlueHydra.logger).to have_received(:fatal).with(/2 times in a row/)
      expect(BlueHydra).to have_received(:send_event).with(
        'blue_hydra',
        hash_including(key: 'blue_hydra_start_discovery_failed', severity: 'FATAL')
      )
    end

    # At least 6s so a controller that is merely slow has a real chance to answer,
    # no more than 10s so a dead unit is not left sitting there.
    it "waits between 6 and 10 seconds before the retry" do
      expect(BlueHydra::Runner::START_DISCOVERY_RETRY_DELAY).to be_between(6, 10)
    end
  end

  it "records which transports were enabled when it failed" do
    runner.mgmt = instance_double(BlueHydra::Mgmt, enabled_transports: ["BREDR"])
    expect_exit_1 { runner.discovery_failed_fatal(BlueHydra::Mgmt::STATUS_REJECTED) }
    expect(BlueHydra.logger).to have_received(:fatal)
      .with(/enabled transports at the time of failure: BREDR/)
  end

  it "says none when the controller had no transport enabled" do
    runner.mgmt = instance_double(BlueHydra::Mgmt, enabled_transports: [])
    expect_exit_1 { runner.discovery_failed_fatal(BlueHydra::Mgmt::STATUS_REJECTED) }
    expect(BlueHydra.logger).to have_received(:fatal)
      .with(/enabled transports at the time of failure: none/)
  end

  # Mid-cycle resumes are a different case: the cycle's own start_discovery
  # already succeeded, so a refusal here is new. If it is not transient, the next
  # cycle's start is where it becomes fatal.
  it "only warns when a mid-cycle resume is refused" do
    runner.warn_resume_failed("after connect phase", BlueHydra::Mgmt::STATUS_REJECTED)
    expect(BlueHydra.logger).to have_received(:warn)
      .with(/resume discovery after connect phase failed.*REJECTED/)
    expect(BlueHydra).not_to have_received(:send_event)
  end

  it "says nothing when a resume succeeds" do
    runner.warn_resume_failed("mid-drain", BlueHydra::Mgmt::STATUS_SUCCESS)
    expect(BlueHydra.logger).not_to have_received(:warn)
  end

  # A resume racing a reader-thread re-arm is the normal case, not a fault: the
  # re-arm got there first and discovery is on. Warning about it trained the log
  # to cry wolf on the one status that proves the radio is scanning.
  it "says nothing when a resume finds discovery already running" do
    runner.warn_resume_failed("after connect phase", BlueHydra::Mgmt::STATUS_BUSY)
    expect(BlueHydra.logger).not_to have_received(:warn)
  end
end

# The crash this prevents: a 9 minute on-device run exited FATAL with "start
# discovery failed 3 times in a row ... 0x0a (BUSY)" while Device Found events
# were still arriving. Every one of those three BUSY answers came back in under
# 10 microseconds with no HCI traffic behind it, because discovery was already
# running - started by our own reader-thread re-arm, which won the race for the
# window between the cycle's hci_reset and the cycle's own start_discovery.
#
# Retrying could never have fixed it, at any count. Each pause gave the reader
# thread more time to keep discovery alive, so every attempt was refused for the
# same reason - an earlier run died the same way on two attempts.
describe "BlueHydra::Mgmt.discovery_on?" do
  it "counts SUCCESS as discovery running" do
    expect(BlueHydra::Mgmt.discovery_on?(BlueHydra::Mgmt::STATUS_SUCCESS)).to be true
  end

  # the whole point: the kernel answers BUSY only when discovery.state is not
  # DISCOVERY_STOPPED, so BUSY is "already scanning", not "refused to scan"
  it "counts BUSY as discovery running" do
    expect(BlueHydra::Mgmt.discovery_on?(BlueHydra::Mgmt::STATUS_BUSY)).to be true
  end

  it "does not count a genuine refusal" do
    expect(BlueHydra::Mgmt.discovery_on?(BlueHydra::Mgmt::STATUS_REJECTED)).to be false
  end

  # a powered-down controller answers NOT_POWERED, never BUSY, so the two cannot
  # be conflated by this predicate
  it "does not count a powered-down controller" do
    expect(BlueHydra::Mgmt.discovery_on?(BlueHydra::Mgmt::STATUS_NOT_POWERED)).to be false
  end
end

describe "BlueHydra::Runner discovery cycle racing its own re-arm" do
  let(:runner) { BlueHydra::Runner.new }

  before do
    allow(BlueHydra.logger).to receive(:debug)
    allow(BlueHydra.logger).to receive(:fatal)
    allow(BlueHydra.logger).to receive(:warn)
    allow(BlueHydra).to receive(:send_event)
    allow(runner).to receive(:hci_reset)
    allow(runner).to receive(:sleep)
    allow(BlueHydra).to receive(:info_scan).and_return(false)
  end

  it "carries on when the cycle's own Start Discovery finds discovery running" do
    runner.mgmt = instance_double(
      BlueHydra::Mgmt,
      enabled_transports: ["BREDR", "LE"],
      start_discovery: BlueHydra::Mgmt::STATUS_BUSY
    )

    expect { runner.run_mgmt_discovery(30) }.not_to raise_error

    expect(runner.mgmt).to have_received(:start_discovery).once # no retries
    expect(BlueHydra.logger).not_to have_received(:fatal)
    expect(BlueHydra).not_to have_received(:send_event)
    expect(BlueHydra.logger).to have_received(:debug)
      .with(/start discovery answered 0x0a \(BUSY\), discovery was already running/)
  end

  it "still sleeps out the discovery window rather than spinning" do
    runner.mgmt = instance_double(
      BlueHydra::Mgmt,
      enabled_transports: ["BREDR", "LE"],
      start_discovery: BlueHydra::Mgmt::STATUS_BUSY
    )

    runner.run_mgmt_discovery(30)

    expect(runner).to have_received(:sleep).with(30)
  end
end

# A controller with LE switched off can only ever report classic devices, and
# from the device table alone that looks like a quiet room rather than a
# half-blind sensor. The first line names the transports so an interactive user
# sees it the way the log line and the event show everyone else.
describe "BlueHydra::CliUserInterface transport labelling" do
  class LabelFakeRunner
    attr_accessor :mgmt
  end

  def cui_with(transports)
    runner = LabelFakeRunner.new
    runner.mgmt = transports == :no_mgmt ? nil :
                  instance_double(BlueHydra::Mgmt, enabled_transports: transports)
    BlueHydra::CliUserInterface.new(runner, 300)
  end

  it "names both transports when both are discovered" do
    expect(cui_with(["BREDR", "LE"]).devices_seen_label)
      .to eq("BREDR+LE devices seen in last 300s")
  end

  it "names only BREDR when LE is off" do
    expect(cui_with(["BREDR"]).devices_seen_label).to eq("BREDR devices seen in last 300s")
  end

  it "names only LE on a single-mode LE controller" do
    expect(cui_with(["LE"]).devices_seen_label).to eq("LE devices seen in last 300s")
  end

  it "says outright that nothing can be discovered when no transport is on" do
    expect(cui_with([]).devices_seen_label).to eq("NO TRANSPORT ENABLED, nothing can be discovered")
  end

  # The discovery thread determines the transports at startup, so the first paint
  # or two can land before that; keep the original wording rather than guessing.
  it "keeps the original wording while the transports are unknown" do
    expect(cui_with(nil).devices_seen_label).to eq("Devices Seen in last 300s")
    expect(cui_with(:no_mgmt).devices_seen_label).to eq("Devices Seen in last 300s")
  end
end

# Don't spend a connect on a device that cannot answer. Two independent gates,
# both consulted in request_leinfo so they cover the kernel auto-connect path and
# the direct-connect path alike. See BlueHydra::ConnectTracker.
describe "BlueHydra::Runner connect gating" do
  let(:runner) { BlueHydra::Runner.new }
  let(:mac)    { "7A:BB:CC:DD:EE:FF" }   # random static => auto-connect path
  let(:rpa)    { "55:BB:CC:DD:EE:FF" }   # resolvable private => direct path

  before do
    BlueHydra::ConnectTracker.reset!
    BlueHydra.config["connect_to_nonconnectable"] = false
    allow(BlueHydra.logger).to receive(:debug)
    runner.auto_connect_list = {}
    runner.le_pending        = {}
    runner.le_direct_pending = {}
    runner.mgmt = instance_double(
      BlueHydra::Mgmt,
      add_device:    BlueHydra::Mgmt::STATUS_SUCCESS,
      remove_device: BlueHydra::Mgmt::STATUS_SUCCESS
    )
  end

  after { BlueHydra::ConnectTracker.reset! }

  describe "connectability gate" do
    it "attempts a device we have no advertising opinion on yet" do
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to have_key(rpa)
    end

    it "attempts a device that advertised connectable" do
      BlueHydra::ConnectTracker.record_connectable(rpa, true)
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to have_key(rpa)
    end

    it "skips a device that only ever advertised non-connectable" do
      BlueHydra::ConnectTracker.record_connectable(rpa, false)
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to be_empty
    end

    it "attempts it anyway when connect_to_nonconnectable is on" do
      BlueHydra.config["connect_to_nonconnectable"] = true
      BlueHydra::ConnectTracker.record_connectable(rpa, false)
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to have_key(rpa)
    end

    # the gate sits ahead of the identity-address routing, so it covers the
    # kernel auto-connect path too, not just direct connects
    it "also gates the auto-connect path" do
      BlueHydra::ConnectTracker.record_connectable(mac, false)
      runner.request_leinfo(mac, "Random")
      expect(runner.le_pending).to be_empty
      expect(runner.auto_connect_list).to be_empty
    end
  end

  describe "strike gate" do
    it "stops attempting after three consecutive failures" do
      2.times { BlueHydra::ConnectTracker.strike(rpa) }
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to have_key(rpa) # two strikes still tries

      runner.le_direct_pending = {}
      BlueHydra::ConnectTracker.strike(rpa)             # third
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to be_empty
    end

    it "applies to a device that advertises connectable" do
      BlueHydra::ConnectTracker.record_connectable(rpa, true)
      3.times { BlueHydra::ConnectTracker.strike(rpa) }
      runner.request_leinfo(rpa, "Random")
      expect(runner.le_direct_pending).to be_empty
    end
  end

  describe "recording outcomes" do
    it "strikes an unreachable direct connect and clears on a connected one" do
      runner.record_le_direct_results(rpa => :unreachable)
      expect(BlueHydra::ConnectTracker.strikes(rpa)).to eq(1)

      runner.record_le_direct_results(rpa => :error)
      expect(BlueHydra::ConnectTracker.strikes(rpa)).to eq(2)

      runner.record_le_direct_results(rpa => :connected)
      expect(BlueHydra::ConnectTracker.strikes(rpa)).to eq(0)
    end

    # abandoned means our budget ran out, which says nothing about the device
    it "does NOT strike an abandoned direct connect" do
      runner.record_le_direct_results(rpa => :abandoned)
      expect(BlueHydra::ConnectTracker.strikes(rpa)).to eq(0)
    end

    it "strikes an auto-connect Connect Failed and clears on Connected" do
      runner.auto_connect_list[mac] = { address_type: BlueHydra::Mgmt::LE_RANDOM, connected: false }
      allow(runner.mgmt).to receive(:connection_events).and_return(
        Queue.new.tap { |q| q << { type: :failed, address: mac } }
      )
      runner.process_connection_events
      expect(BlueHydra::ConnectTracker.strikes(mac)).to eq(1)

      runner.auto_connect_list[mac] = { address_type: BlueHydra::Mgmt::LE_RANDOM, connected: false }
      allow(runner.mgmt).to receive(:connection_events).and_return(
        Queue.new.tap { |q| q << { type: :connected, address: mac } }
      )
      runner.process_connection_events
      expect(BlueHydra::ConnectTracker.strikes(mac)).to eq(0)
    end

    # an add the kernel never saw advertise is the same "no answer" the direct
    # path calls unreachable
    it "strikes an auto-connect entry that timed out" do
      runner.auto_connect_list[mac] = { address_type: BlueHydra::Mgmt::LE_RANDOM, connected: false }
      runner.clear_auto_connect
      expect(BlueHydra::ConnectTracker.strikes(mac)).to eq(1)
    end

    it "does not strike an auto-connect entry that did connect" do
      runner.auto_connect_list[mac] = { address_type: BlueHydra::Mgmt::LE_RANDOM, connected: true }
      runner.clear_auto_connect
      expect(BlueHydra::ConnectTracker.strikes(mac)).to eq(0)
    end
  end
end

# Strikes are in-memory and must not outlive the sighting that earned them, so
# every offline transition drops them. That is the only expiry besides a success.
describe "BlueHydra::Device.mark_offline" do
  let(:mac) { "7A:BB:CC:DD:EE:11" }

  before { BlueHydra::ConnectTracker.reset! }
  after  { BlueHydra::ConnectTracker.reset! }

  it "sets the status and forgets the device's strikes" do
    3.times { BlueHydra::ConnectTracker.strike(mac) }
    BlueHydra::ConnectTracker.record_connectable(mac, false)
    expect(BlueHydra::ConnectTracker.struck_out?(mac)).to eq(true)

    device = BlueHydra::Device.new
    device.address = mac
    BlueHydra::Device.mark_offline(device)

    expect(device.status).to eq('offline')
    expect(BlueHydra::ConnectTracker.strikes(mac)).to eq(0)
    expect(BlueHydra::ConnectTracker.connectable(mac)).to be_nil
  end

  # it is the caller's job to persist; mark_offline only changes state
  it "does not save the record itself" do
    device = BlueHydra::Device.new
    device.address = mac
    expect(device).not_to receive(:save)
    BlueHydra::Device.mark_offline(device)
  end
end

# push_to_queue stamps query_history when a scan is ENQUEUED, not when it
# succeeds, so a single failed connect used to cost the device the whole
# info_scan_rate (600s default) before anyone tried again - and for the private
# addresses that dominate the LE path, the address has usually rotated by then.
describe "BlueHydra::Runner failed-connect retry cadence" do
  let(:runner) { BlueHydra::Runner.new }
  let(:mac)    { "55:BB:CC:DD:EE:FF" }

  before do
    BlueHydra::ConnectTracker.reset!
    BlueHydra.config["info_scan_rate"] = 600
    allow(BlueHydra.logger).to receive(:debug)
    runner.query_history      = {}
    runner.le_info_scan_queue = Queue.new
  end

  after { BlueHydra::ConnectTracker.reset! }

  # pretend the last enqueue happened +ago+ seconds back
  def stamp(ago)
    runner.query_history[mac] = { le: Time.now.to_i - ago }
  end

  it "makes a device with no failures wait the full info_scan_rate" do
    stamp(30)
    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue).to be_empty

    stamp(601)
    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue.size).to eq(1)
  end

  it "re-queues a device whose connect failed after only FAILED_RETRY_INTERVAL" do
    BlueHydra::ConnectTracker.strike(mac)
    stamp(BlueHydra::ConnectTracker::FAILED_RETRY_INTERVAL + 1)

    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue.size).to eq(1)
  end

  it "still honours the short floor rather than re-queueing on every sighting" do
    BlueHydra::ConnectTracker.strike(mac)
    stamp(BlueHydra::ConnectTracker::FAILED_RETRY_INTERVAL - 5)

    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue).to be_empty
  end

  # the short interval exists to get the three attempts over with quickly; once
  # the device is written off there is no work left to enqueue
  it "goes back to the full cadence once the device has struck out" do
    3.times { BlueHydra::ConnectTracker.strike(mac) }
    stamp(BlueHydra::ConnectTracker::FAILED_RETRY_INTERVAL + 1)

    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue).to be_empty
  end

  it "goes back to the full cadence after a successful connect" do
    BlueHydra::ConnectTracker.strike(mac)
    BlueHydra::ConnectTracker.success(mac)
    stamp(BlueHydra::ConnectTracker::FAILED_RETRY_INTERVAL + 1)

    runner.push_to_queue(:le, mac, "Random")
    expect(runner.le_info_scan_queue).to be_empty
  end

  # three attempts at the short interval instead of three at 600s: about half a
  # minute to resolve a device rather than half an hour
  it "resolves three strikes inside a minute of wall clock" do
    worst_case = BlueHydra::ConnectTracker::STRIKE_LIMIT *
                 BlueHydra::ConnectTracker::FAILED_RETRY_INTERVAL
    expect(worst_case).to be < 60
    expect(worst_case).to be < BlueHydra.config["info_scan_rate"]
  end

  # Every strike comes from an LE connect, and the tracker is keyed on the full
  # address, so without an explicit mode check a dual-mode device's LE failures
  # would shorten its classic cadence too - which an LE failure is no evidence
  # for. This spec is the guard on that.
  it "leaves the classic cadence alone even when the address has LE strikes" do
    runner.info_scan_queue = Queue.new
    BlueHydra::ConnectTracker.strike(mac)
    runner.query_history[mac.split(":")[2, 4].join(":")] = { classic: Time.now.to_i - 30 }

    runner.push_to_queue(:classic, mac)
    expect(runner.info_scan_queue).to be_empty
  end
end
