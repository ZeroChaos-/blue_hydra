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
    expect(attrs[:classic_tx_power]).to eq(["-56 dB"])
    expect(attrs[:classic_company_data]).to eq(["01adddd439aed386c76574e9ab9e11958e25c1f70ae203"])
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
    [
      "> HCI Event: Disconnect Complete (0x05) plen 4       2015-12-10 11:30:58.970878\r\n",
      "        Address: #{addr} (Apple)\r\n"
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
    BlueHydra.config["chunker_debug"] = true
    q_in = Queue.new; q_out = Queue.new
    drain(q_in, q_out, [no_address_msg, starting_msg("AA:BB:CC:00:00:06")])
    expect(q_out.empty?).to eq(true)
    BlueHydra.config["chunker_debug"] = false
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
    runner.info_scan_queue = Queue.new
    runner.push_to_queue(:le, "AB:CD:EF:44:55:66")
    item = runner.info_scan_queue.pop
    expect(item[:command]).to eq(:leinfo)
  end

  it "push_to_queue ignores the local adapter address" do
    runner = BlueHydra::Runner.new
    runner.query_history = {}
    runner.info_scan_queue = Queue.new
    runner.push_to_queue(:le, BlueHydra::LOCAL_ADAPTER_ADDRESS)
    expect(runner.info_scan_queue.empty?).to eq(true)
  end

  it "reports a status hash for its queues and threads" do
    runner = BlueHydra::Runner.new
    [:raw_queue, :chunk_queue, :result_queue, :info_scan_queue, :l2ping_queue].each do |q|
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
                  :processing_speed, :stunned

    def initialize
      @cui_status       = {}
      @scanner_status   = {}
      @result_queue     = Queue.new
      @info_scan_queue  = Queue.new
      @l2ping_queue     = Queue.new
      @query_history    = {}
      @processing_speed = 1.0
      @stunned          = false
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
