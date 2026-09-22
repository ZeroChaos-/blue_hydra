require 'spec_helper'

# the actual bluetooth devices dawg
describe BlueHydra::Device do
  it "has useful attributes" do
    device = BlueHydra::Device.new

    %w{
      id
      name
      status
      address
      uap_lap
      vendor
      appearance
      company
      company_type
      lmp_version
      manufacturer
      firmware
      classic_mode
      classic_service_uuids
      classic_channels
      classic_major_class
      classic_minor_class
      classic_class
      classic_rssi
      classic_tx_power
      classic_features
      classic_features_bitmap
      le_mode
      le_service_uuids
      le_address_type
      le_random_address_type
      le_flags
      le_rssi
      le_tx_power
      le_features
      le_features_bitmap
      le_ibeacon_measured_power
      ibeacon_range
      created_at
      updated_at
      last_seen
      uuid
    }.each do |attr|
      expect(device.respond_to?(attr)).to eq(true)
    end
  end

  it "generates a uuid when saving" do
    d = BlueHydra::Device.new
    d.address = "DE:AD:BE:EF:CA:FE"
    expect(d.uuid).to eq(nil)
    d.save
    expect(d.uuid.class).to eq(String)
    uuid_regex = /^[0-9a-z]{8}-([0-9a-z]{4}-){3}[0-9a-z]{12}$/
    expect(d.uuid =~ uuid_regex).to eq(0)
  end

  it "recovers from a uuid collision by regenerating the sync id on save" do
    first = BlueHydra::Device.new
    first.address = "DE:AD:00:00:CC:01"
    first.save
    expect(first.uuid).to be_a(String)

    # Force a second device to reuse the first's uuid. The DB-level unique
    # index rejects the duplicate and #save must regenerate the sync id and
    # retry rather than raising. (Without the unique index this duplicate would
    # save happily and the final expectation below would fail, so this exercises
    # both the index and the retry handling.)
    second = BlueHydra::Device.new
    second.address = "DE:AD:00:00:CC:02"
    second.uuid = first.uuid
    expect { second.save }.to_not raise_error
    expect(second.uuid).to_not eq(first.uuid)
    expect(second.id).to_not be_nil
    # the regenerated uuid is what actually got persisted
    expect(BlueHydra::Device.get(second.id).uuid).to eq(second.uuid)
  end

  it "sets a uap_lap from an address" do
    address  = "D5:AD:B5:5F:CA:F5"
    device = BlueHydra::Device.new
    device.address = address
    device.save
    expect(device.uap_lap).to eq("B5:5F:CA:F5")

    device2 = BlueHydra::Device.find_by_uap_lap("FF:00:B5:5F:CA:F5")
    expect(device2).to eq(device)
  end

  it "serializes some attributes" do
    device = BlueHydra::Device.new
    classic_class = [
      [
        "0x7a020c",
        "Networking (LAN, Ad hoc)",
        "Capturing (Scanner, Microphone)",
        "Object Transfer (v-Inbox, v-Folder)",
        "Audio (Speaker, Microphone, Headset)",
        "Telephony (Cordless telephony, Modem, Headset)"
      ]
    ]

    classic_uuids = [
      "PnP Information (0x1200)",
      "Handsfree Audio Gateway (0x111f)",
      "Phonebook Access Server (0x112f)",
      "Audio Source (0x110a)",
      "A/V Remote Control Target (0x110c)",
      "NAP (0x1116)",
      "Message Access Server (0x1132)"
    ]

    le_uuids = ["Unknown (0xfeed)"]

    device.classic_class = classic_class
    device.classic_service_uuids = classic_uuids
    device.le_service_uuids = le_uuids

    expect(JSON.parse(device.classic_class).first).to eq("Networking (LAN, Ad hoc)")
    expect(JSON.parse(device.classic_service_uuids).first).to eq("PnP Information (0x1200)")
    expect(JSON.parse(device.le_service_uuids).first).to eq("Unknown (0xfeed)")
  end

  it "create or updates from a hash" do
    raw = {
      classic_num_responses: ["1"],
      address: ["00:00:00:00:00:00"],
      classic_page_scan_repetition_mode: ["R1 (0x01)"],
      classic_page_period_mode: ["P2 (0x02)"],
      classic_major_class: ["Phone (cellular, cordless, payphone, modem)"],
      classic_minor_class: ["Smart phone"],
      classic_class: [[
          "0x7a020c",
          "Networking (LAN, Ad hoc)",
          "Capturing (Scanner, Microphone)",
          "Object Transfer (v-Inbox, v-Folder)",
          "Audio (Speaker, Microphone, Headset)",
          "Telephony (Cordless telephony, Modem, Headset)"
        ]],
      classic_clock_offset: ["0x54a2"],
      classic_rssi: ["-36 dBm (0xdc)"],
      name: ["iPhone"],
      classic_service_uuids: [
        "PnP Information (0x1200)",
        "Handsfree Audio Gateway (0x111f)",
        "Phonebook Access Server (0x112f)",
        "Audio Source (0x110a)",
        "A/V Remote Control Target (0x110c)",
        "NAP (0x1116)",
        "Message Access Server (0x1132)",
        "00000000-deca-fade-deca-deafdecacafe",
        "2d8d2466-e14d-451c-88bc-7301abea291a"
      ],
      classic_unknown: [
        "[\"        Company: not assigned (19456)\\r\\n\", \"          Type: iBeacon (2)\\r\\n\"]",
        "02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................",
        "00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00  ................",
        "00 00                                            .."
      ]
    }

    device = BlueHydra::Device.update_or_create_from_result(raw)

    expect(device.address).to eq("00:00:00:00:00:00")
    expect(device.name).to eq("iPhone")
    expect(
      JSON.parse(device.classic_class).first).to eq("Networking (LAN, Ad hoc)")
    expect(
      JSON.parse(device.classic_service_uuids).first).to eq("PnP Information (0x1200)")
  end

  # ibeacon_range was in neither the normal nor the array attribute list, so the
  # parser's estimate was dropped on the floor and the column stayed NULL.
  it "persists an iBeacon range estimate" do
    device = BlueHydra::Device.update_or_create_from_result(
      address: ["DE:AD:00:00:BE:01"],
      ibeacon_range: [4.21]
    )
    expect(device.ibeacon_range).to eq("4.21")
  end

  # successive estimates track a moving beacon, so the newest wins. Sorting (what
  # the normal-attribute loop does) would pick the smallest number instead - the
  # closest it ever got rather than where it is now.
  it "keeps the most recent range rather than the smallest" do
    device = BlueHydra::Device.update_or_create_from_result(
      address: ["DE:AD:00:00:BE:02"],
      ibeacon_range: [2.5, 9.75]
    )
    expect(device.ibeacon_range).to eq("9.75")
  end

  it "persists an iBeacon measured power separately from TX power" do
    device = BlueHydra::Device.update_or_create_from_result(
      address: ["DE:AD:00:00:BE:03"],
      le_ibeacon_measured_power: ["-59 dB"],
      le_tx_power: ["3 dBm"]
    )
    expect(device.le_ibeacon_measured_power).to eq("-59 dB")
    expect(device.le_tx_power).to eq("3 dBm")
  end

  # The measured power is the half of the distance calculation nothing downstream
  # can get any other way, so it goes on the wire.
  it "syncs an iBeacon measured power" do
    expect(BlueHydra::Device.new.syncable_attributes)
      .to include(:le_ibeacon_measured_power)
  end

  # The range is a pure function of the measured power and the RSSI, both of which
  # are synced, so sending it would ship a derived value AND freeze the free-space
  # path loss exponent this calculates it with. Downstream can do better from the
  # whole le_rssi series.
  it "does not sync the derived range" do
    expect(BlueHydra::Device.new.syncable_attributes).not_to include(:ibeacon_range)
  end

  it "keeps the range local for the CUI rather than dropping the column" do
    expect(BlueHydra::Device.new.respond_to?(:ibeacon_range)).to eq(true)
  end
end

# The payload is built twice - sync_to_pulse and stream_builder_data - from two
# copies of the same loop, so anything asserted here is asserted against the
# structure both of them produce. stream_builder_data returns the hash directly,
# which is why it is the one under test.
describe BlueHydra::Device, "sync payload shape" do
  def device(attrs = {})
    d = BlueHydra::Device.new
    d.address = attrs.delete(:address) || "DE:AD:00:00:5C:01"
    attrs.each { |k, v| d.send("#{k}=", v) }
    d.save
    d
  end

  # These are JSON in the column, so they must arrive as structures. The two
  # bitmaps were missing from is_serialized? and arrived as encoded strings,
  # leaving a consumer to double-parse exactly those two of the eleven.
  it "sends every serialized attribute as a structure, not an encoded string" do
    d = device(
      le_features:              ["LE Encryption"],
      le_flags:                 ["LE General Discoverable Mode"],
      le_rssi:                  [{ t: 1, rssi: "-50 dBm" }],
      le_features_bitmap:       [[0, "0x1f"]],
      classic_features_bitmap:  [[0, "0xff"]]
    )
    data = d.stream_builder_data(true)

    expect(data[:le_features]).to eq(["LE Encryption"])
    expect(data[:le_flags]).to eq(["LE General Discoverable Mode"])
    expect(data[:le_rssi]).to be_an(Array)
    expect(data[:le_features_bitmap]).to eq({ "0" => "0x1f" })
    expect(data[:classic_features_bitmap]).to eq({ "0" => "0xff" })
  end

  it "treats both features bitmaps as serialized" do
    d = BlueHydra::Device.new
    expect(d.is_serialized?(:le_features_bitmap)).to eq(true)
    expect(d.is_serialized?(:classic_features_bitmap)).to eq(true)
  end

  # Empty is empty whichever container it came from. Only "[]" was recognised, so
  # an empty bitmap went out as the literal string "{}" while an empty array-backed
  # attribute was correctly omitted.
  it "omits an empty bitmap the same way it omits an empty array" do
    d = device(
      address:            "DE:AD:00:00:5C:02",
      le_features:        [],
      le_features_bitmap: []
    )
    data = d.stream_builder_data(true)

    expect(data).not_to have_key(:le_features)
    expect(data).not_to have_key(:le_features_bitmap)
  end

  it "recognises both empty containers and nil" do
    d = BlueHydra::Device.new
    expect(d.empty_for_sync?(nil)).to eq(true)
    expect(d.empty_for_sync?("[]")).to eq(true)
    expect(d.empty_for_sync?("{}")).to eq(true)
    expect(d.empty_for_sync?("[\"real\"]")).to eq(false)
    expect(d.empty_for_sync?("-59 dB")).to eq(false)
  end

  # every serialized attribute is JSON.parse'd on the way out, so a value that is
  # not valid JSON would raise mid-sync rather than just arrive misshapen
  it "stores valid JSON in every attribute it declares serialized" do
    d = device(
      address:                 "DE:AD:00:00:5C:03",
      le_features:             ["LE Encryption"],
      classic_features:        ["3 slot packets"],
      le_flags:                ["LE General Discoverable Mode"],
      le_service_uuids:        ["Unknown (0xfeed)"],
      classic_service_uuids:   ["PnP Information (0x1200)"],
      classic_channels:        ["1"],
      classic_class:           ["0x7a020c"],
      le_rssi:                 [{ t: 1, rssi: "-50 dBm" }],
      classic_rssi:            [{ t: 1, rssi: "-36 dBm" }],
      le_features_bitmap:      [[0, "0x1f"]],
      classic_features_bitmap: [[0, "0xff"]]
    )

    serialized = d.syncable_attributes.select { |a| d.is_serialized?(a) }
    expect(serialized.count).to eq(11)
    serialized.each do |attr|
      expect { JSON.parse(d.send(attr)) }.not_to raise_error, "#{attr} is not JSON"
    end
  end

  # The cloud keeps data forever while the local DB is cleared, so its own first
  # sighting is the better record and ours would only contradict it.
  it "does not send created_at" do
    d = device(address: "DE:AD:00:00:5C:04")
    expect(d.stream_builder_data(true)).not_to have_key(:created_at)
    expect(d.syncable_attributes).not_to include(:created_at)
  end
end

# The cloud matches records on (le_proximity_uuid, le_major_num, le_minor_num), so
# the triple is an identity key and every message needs it - not just the ones
# where it changed. It is immutable per beacon, which makes "send it once" look
# like an optimisation; it would leave every later message unmatchable.
describe BlueHydra::Device, "beacon identity triple on the wire" do
  let(:beacon) do
    d = BlueHydra::Device.new
    d.address           = "DE:AD:00:00:B3:01"
    d.le_proximity_uuid = "74278bda-b644-4520-8f0c-720eaf059935"
    d.le_major_num      = "0"
    d.le_minor_num      = "1736"
    d.save
    d
  end

  it "sends the triple even when nothing about it changed" do
    beacon
    # a second save with only an unrelated change: the triple is not dirty
    beacon.le_rssi = [{ t: 2, rssi: "-70 dBm" }]
    beacon.save

    data = beacon.stream_builder_data # NOT sync_all
    expect(data[:le_proximity_uuid]).to eq("74278bda-b644-4520-8f0c-720eaf059935")
    expect(data[:le_major_num]).to eq("0")
    expect(data[:le_minor_num]).to eq("1736")
  end

  # if any of these were ever moved into the change-gated list they would stop
  # appearing on most messages, and matching would fail silently
  it "keeps the triple out of the change-gated list" do
    %i[le_proximity_uuid le_major_num le_minor_num].each do |attr|
      expect(beacon.syncable_attributes).not_to include(attr),
        "#{attr} must stay in the always-send block; the cloud matches on it"
    end
  end

  it "sends the canonically grouped UUID, which is the shape the key now takes" do
    expect(beacon.stream_builder_data(true)[:le_proximity_uuid])
      .to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end
end
