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
      le_connectable
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
      classic_features_bitmap: [[0, "0xff"]],
      # the two list Gatt_Columns, the twelfth and thirteenth (Requirement 12.2)
      gatt_service_uuids:      ["Generic Access (0x1800)"],
      gatt_characteristics:    [{ uuid: "Device Name (0x2a00)", service_uuid: "Generic Access (0x1800)",
                                  service_type: "primary", service_start: 1, service_end: 7,
                                  service_includes: [], decl_handle: 2, value_handle: 3,
                                  properties: ["read"], descriptors: [], read_status: "not-read" }]
    )

    serialized = d.syncable_attributes.select { |a| d.is_serialized?(a) }
    expect(serialized.count).to eq(13)
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

  # le_connectable is a scalar boolean among a column of Text attributes, so the
  # three states have to stay distinguishable on the wire: true, an observed
  # false, and never-observed. An observed false is the one at risk - it is
  # falsey, so any "unless val" style filter would swallow it and make a
  # non-connectable device indistinguishable from an unseen one.
  it "sends le_connectable when it is true" do
    d = device(address: "DE:AD:00:00:5C:05", le_connectable: true)
    expect(d.stream_builder_data(true)[:le_connectable]).to eq(true)
  end

  it "sends le_connectable when it is an observed false" do
    d = device(address: "DE:AD:00:00:5C:06", le_connectable: false)
    data = d.stream_builder_data(true)
    expect(data).to have_key(:le_connectable)
    expect(data[:le_connectable]).to eq(false)
  end

  it "omits le_connectable when it has never been observed" do
    d = device(address: "DE:AD:00:00:5C:07")
    expect(d.le_connectable).to eq(nil)
    expect(d.stream_builder_data(true)).not_to have_key(:le_connectable)
  end

  it "does not treat le_connectable as serialized" do
    d = BlueHydra::Device.new
    expect(d.is_serialized?(:le_connectable)).to eq(false)
    expect(d.syncable_attributes).to include(:le_connectable)
  end
end

# The parser emits one value per chunk, so a batch can carry both, and the column
# holds the OR-reduction. The naive reduction is the one the normal-attribute loop
# uses, .uniq.sort.first, which raises on booleans because they are not
# Comparable.
describe BlueHydra::Device, "le_connectable from a result batch" do
  def result(connectable)
    { address: ["DE:AD:00:00:5C:10"], le_connectable: connectable }
  end

  it "is true when any chunk in the batch said connectable" do
    d = BlueHydra::Device.update_or_create_from_result(result([false, true, false]))
    expect(d.le_connectable).to eq(true)
  end

  it "is false when every chunk said non-connectable" do
    d = BlueHydra::Device.update_or_create_from_result(result([false, false]))
    expect(d.le_connectable).to eq(false)
  end

  it "does not raise on a mixed batch" do
    # booleans are not Comparable, so the .uniq.sort.first the normal-attribute
    # loop applies would raise ArgumentError here
    expect { BlueHydra::Device.update_or_create_from_result(result([true, false])) }
      .not_to raise_error
  end

  # The runner reads result[:le_connectable] for ConnectTracker after calling
  # this, so the caller's hash must come back intact. It does because the method
  # dups before consuming - this pins that, since the deletes inside would
  # otherwise reach the caller.
  it "does not consume keys out of the caller's result hash" do
    r = result([true])
    BlueHydra::Device.update_or_create_from_result(r)
    expect(r).to have_key(:le_connectable)
    expect(r[:le_connectable]).to eq([true])
    expect(r).to have_key(:address)
  end

  it "leaves le_connectable nil when the batch never mentions it" do
    d = BlueHydra::Device.update_or_create_from_result({ address: ["DE:AD:00:00:5C:11"] })
    expect(d.le_connectable).to eq(nil)
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

# The 13 Gatt_Columns are written only by Walk results: the hash
# GattScanner#walk_result puts on result_queue tagged gatt_walk: true, which
# update_or_create_from_result hands to apply_gatt_result on the Result_Thread.
# Everything below drives that path through update_or_create_from_result, as
# the Runner does, and reads the stored columns back from the DB.
describe BlueHydra::Device, "Gatt_Columns" do
  gatt_columns = BlueHydra::Device::GATT_COLUMNS
  identity_columns = BlueHydra::Device::GATT_IDENTITY_COLUMNS
  max_bytes   = BlueHydra::GattCharacteristics::MAX_BYTES
  max_entries = BlueHydra::GattCharacteristics::MAX_ENTRIES

  hash_a = "0f" * 16
  hash_b = "1e" * 16

  # One address per example: the in-memory DB lives for the whole run, so an
  # address reused across examples would find the other example's record. The
  # UAP/LAP (octets 2 to 5) is distinct too, for the no-fallback example.
  counter = 0
  let(:mac) { counter += 1; format("DE:AD:00:6A:%02X:%02X", counter / 256, counter % 256) }

  before do
    allow(BlueHydra.logger).to receive(:debug)
    allow(BlueHydra.logger).to receive(:warn)
  end

  # Uuid_Formatter renders, as the walker reports them.
  def svc(uuid)
    BlueHydra::UuidNames.service(uuid)
  end

  def chr(uuid)
    BlueHydra::UuidNames.characteristic(uuid)
  end

  def gatt_device(address, **attrs)
    d = BlueHydra::Device.new
    d.address = address
    attrs.each { |k, v| d.send("#{k}=", v) }
    d.save
    d
  end

  # A fresh query, not the object an example holds, so what it sees is what
  # the save wrote.
  def reload(address)
    BlueHydra::Device.first(address: address)
  end

  # The Walk result hash of the design, with the fields a Walk that learnt
  # nothing would carry; overrides fill in what an example is about.
  def walk_result(address, outcome, **overrides)
    {
      gatt_walk:       true,
      address:         address,
      outcome:         outcome,
      resumed:         false,
      ended_at:        1_784_926_865,
      database_hash:   nil,
      hash_changed:    false,
      service_uuids:   [],
      characteristics: [],
      identity:        {},
      outstanding:     { procedures: [], reads: [] }
    }.merge(overrides)
  end

  def apply(result)
    BlueHydra::Device.update_or_create_from_result(result)
  end

  # A valid gatt_characteristics entry in the in-memory form (Symbol keys,
  # Uuid_Formatter strings), as spec/gatt_characteristics_spec.rb builds them.
  # read_status decides the conditional keys; overrides replace or add keys.
  def gatt_entry(value_handle, read_status = "read", **overrides)
    built = {
      uuid:             "Device Name (0x2a00)",
      service_uuid:     "Generic Access (0x1800)",
      service_type:     "primary",
      service_start:    1,
      service_end:      0xFFFF,
      service_includes: [],
      decl_handle:      value_handle - 1,
      value_handle:     value_handle,
      properties:       ["read"],
      descriptors:      [],
      read_status:      read_status,
    }
    built[:error_code] = 5 if %w[protected error].include?(read_status)
    if read_status == "read"
      built[:value]          = "Kitchen Sensor"
      built[:value_encoding] = "identity"
    end
    built.merge(overrides)
  end

  # A read entry whose serialised text is exactly bytes long, carrying raw_hex
  # hex characters of raw_hex when given (the 13 bytes of ,"raw_hex":"" wrap
  # them). The fixed part is measured through serialize so the padding is
  # exact whatever the template above says.
  def entry_of_size(value_handle, bytes, raw_hex: nil)
    base  = gatt_entry(value_handle, value: "", value_encoding: "utf8")
    fixed = BlueHydra::GattCharacteristics.serialize([base]).bytesize - 2 + (raw_hex ? 13 + raw_hex : 0)
    raise "#{bytes} bytes is below the #{fixed} an entry at #{value_handle} needs" if bytes < fixed
    overrides = { value: "v" * (bytes - fixed), value_encoding: "utf8" }
    overrides[:raw_hex] = "a" * raw_hex if raw_hex
    gatt_entry(value_handle, **overrides)
  end

  # entry as fit_to_caps leaves it once its raw_hex is removed.
  def stripped(entry)
    entry.reject { |key, _| key == :raw_hex }.merge(raw_hex_truncated: true)
  end

  def stored_chars(record)
    BlueHydra::GattCharacteristics.parse(record.gatt_characteristics)
  end

  def stored_uuids(record)
    JSON.parse(record.gatt_service_uuids)
  end

  describe "columns and allowlists (Requirements 11.3, 12.1, 12.2)" do
    it "has the 13 Gatt_Columns as Text attributes, every one in GATT_COLUMNS" do
      expect(gatt_columns).to match_array(%i[
        gatt_service_uuids gatt_characteristics gatt_database_hash gatt_device_name gatt_appearance
        gatt_manufacturer_name gatt_model_number gatt_serial_number gatt_firmware_revision
        gatt_hardware_revision gatt_software_revision gatt_system_id gatt_pnp_id
      ])
      expect(identity_columns.values + %i[gatt_service_uuids gatt_characteristics]).to match_array(gatt_columns)

      device = BlueHydra::Device.new
      gatt_columns.each do |column|
        expect(device.respond_to?(column)).to eq(true), "#{column} is not an attribute"
        expect(BlueHydra::Device.properties[column]).to be_a(DataMapper::Property::Text), "#{column} is not Text"
      end
      # the two lists run to the byte cap, past a Text's 65,535 default
      expect(BlueHydra::Device.properties[:gatt_service_uuids].length).to eq(max_bytes)
      expect(BlueHydra::Device.properties[:gatt_characteristics].length).to eq(max_bytes)
    end

    # The allowlists in update_or_create_from_result decide which result keys
    # reach a column. A parser-shaped result (Array values) with every
    # Gatt_Columns key proves each is listed: eleven scalars in the normal
    # list, the two lists in the array list.
    it "accepts every Gatt_Columns entry through the result allowlists" do
      raw = { address: [mac] }
      identity_columns.values.each_with_index { |column, i| raw[column] = ["value-#{i}"] }
      raw[:gatt_service_uuids]   = [svc(0x1800)]
      raw[:gatt_characteristics] = [gatt_entry(3)]

      apply(raw)
      record = reload(mac)

      identity_columns.values.each_with_index do |column, i|
        expect(record.send(column)).to eq("value-#{i}"), "#{column} was not stored"
      end
      expect(stored_uuids(record)).to eq([svc(0x1800)])
      expect(stored_chars(record)).to eq([gatt_entry(3)])
    end

    it "ships every Gatt_Columns entry in syncable_attributes" do
      expect(BlueHydra::Device.new.syncable_attributes).to include(*gatt_columns)
    end

    it "serialises the two lists and no other Gatt_Columns entry" do
      device = BlueHydra::Device.new
      serialized = gatt_columns.select { |column| device.is_serialized?(column) }
      expect(serialized).to match_array(%i[gatt_service_uuids gatt_characteristics])
    end
  end

  describe "which record a result reaches (Requirement 11.14)" do
    it "updates the record whose address matches, compared case-insensitively" do
      stored = gatt_device(mac)

      record = apply(walk_result(mac.downcase, :complete, identity: { device_name: "Kitchen Sensor" }))

      expect(record.id).to eq(stored.id)
      expect(reload(mac).gatt_device_name).to eq("Kitchen Sensor")
      expect(reload(mac).address).to eq(mac)
    end

    # The advertisement path falls back to UAP/LAP, so a result for another
    # address with the same lower octets would land on this record there.
    it "discards a result whose address has no record, without the UAP/LAP fallback, and logs it at debug" do
      stored = gatt_device(mac, gatt_device_name: "Kept")
      other  = "FF:FF" + mac[5..]
      expect(other).not_to eq(mac)
      expect(BlueHydra::Device.find_by_uap_lap(other)).to eq(stored)
      count = BlueHydra::Device.count

      returned = apply(walk_result(other, :complete, service_uuids: [svc(0x1800)],
                                   characteristics: [gatt_entry(3)], identity: { device_name: "Intruder" }))

      expect(returned).to be_nil
      expect(BlueHydra::Device.count).to eq(count)
      expect(BlueHydra::Device.first(address: other)).to be_nil
      kept = reload(mac)
      expect(kept.gatt_device_name).to eq("Kept")
      expect(kept.gatt_service_uuids).to be_nil
      expect(kept.gatt_characteristics).to be_nil
      expect(BlueHydra.logger).to have_received(:debug)
        .with("gatt: #{other} has no Device record, Walk result discarded").once
    end

    it "refuses a result with an outcome that places no result" do
      gatt_device(mac)
      expect { apply(walk_result(mac, :unchanged)) }.to raise_error(
        ArgumentError,
        "gatt: #{mac} Walk result has outcome :unchanged, not one of complete, partial, protected, timeout, disconnected"
      )
    end
  end

  describe "what a result changes (Requirement 11.4)" do
    # every column that is not a Gatt_Columns entry and not status/last_seen
    def untouched(record)
      record.attributes.reject do |name, _|
        BlueHydra::Device::GATT_COLUMNS.include?(name) || %i[status last_seen updated_at].include?(name)
      end
    end

    it "leaves name, appearance, manufacturer, firmware, lmp_version and every classic_* and le_* column as they were" do
      gatt_device(mac,
                  status: "offline", last_seen: 1_700_000_000,
                  name: "Kitchen Hub", appearance: "Generic Phone", manufacturer: "Apple, Inc.",
                  firmware: "1.2.3", lmp_version: "5.0 (0x09)", company: "Apple, Inc.", company_type: "Unknown",
                  classic_mode: true, classic_major_class: "Phone", classic_minor_class: "Smart phone",
                  classic_class: ["Networking (LAN, Ad hoc)"], classic_rssi: [{ t: 1, rssi: "-36 dBm" }],
                  classic_tx_power: "4 dBm", classic_service_uuids: ["PnP Information (0x1200)"],
                  classic_channels: ["1"], classic_features: ["3 slot packets"],
                  classic_features_bitmap: [[0, "0xff"]],
                  le_mode: true, le_address_type: "Public", le_service_uuids: ["Unknown (0xfeed)"],
                  le_rssi: [{ t: 1, rssi: "-50 dBm" }], le_tx_power: "3 dBm",
                  le_flags: ["LE General Discoverable Mode"], le_features: ["LE Encryption"],
                  le_features_bitmap: [[0, "0x1f"]], le_company_data: "0102", le_company_uuid: "0x004c",
                  le_connectable: true, le_ibeacon_measured_power: "-59 dB")
      before = untouched(reload(mac))
      expect(before.keys).to include(:name, :appearance, :manufacturer, :firmware, :lmp_version)
      expect(before.keys.grep(/\A(classic|le)_/)).to match_array(
        BlueHydra::Device.properties.map(&:name).grep(/\A(classic|le)_/)
      )

      apply(walk_result(mac, :complete, ended_at: 1_700_000_100,
                        service_uuids: [svc(0x1800)], characteristics: [gatt_entry(3)],
                        identity: { device_name: "GATT Name", appearance: "0x0040",
                                    manufacturer_name: "GATT Maker", firmware_revision: "9.9.9" }))
      after = reload(mac)

      expect(untouched(after)).to eq(before)
      expect(after.status).to eq("online")
      expect(after.last_seen).to eq(1_700_000_100)
      expect(after.gatt_device_name).to eq("GATT Name")
      expect(after.gatt_appearance).to eq("0x0040")
      expect(after.gatt_manufacturer_name).to eq("GATT Maker")
      expect(after.gatt_firmware_revision).to eq("9.9.9")
      # the identity values went to their own columns, not these
      expect(after.name).to eq("Kitchen Hub")
      expect(after.appearance).to eq("Generic Phone")
      expect(after.manufacturer).to eq("Apple, Inc.")
      expect(after.firmware).to eq("1.2.3")
    end

    it "keeps a later stored last_seen over an earlier Walk end" do
      gatt_device(mac, last_seen: 1_700_000_000)

      apply(walk_result(mac, :complete, ended_at: 1_699_999_000))

      expect(reload(mac).last_seen).to eq(1_700_000_000)
    end
  end

  describe "gatt_characteristics by Walk outcome (Requirements 11.6, 11.7, 11.8, 11.16)" do
    let(:e3) { gatt_entry(3) }
    let(:e5) { gatt_entry(5, "not-read") }
    let(:e7) { gatt_entry(7, "not-readable", properties: ["notify"]) }

    before do
      gatt_device(mac)
      apply(walk_result(mac, :complete, service_uuids: [svc(0x1800)], characteristics: [e3, e5]))
      expect(stored_chars(reload(mac))).to eq([e3, e5])
    end

    it "replaces the list on complete" do
      apply(walk_result(mac, :complete, characteristics: [e7]))
      expect(stored_chars(reload(mac))).to eq([e7])
    end

    it "replaces the list on partial with at least one characteristic" do
      apply(walk_result(mac, :partial, characteristics: [e7]))
      expect(stored_chars(reload(mac))).to eq([e7])
    end

    %i[timeout disconnected].each do |outcome|
      it "merges by value handle on #{outcome}, the result's entry winning and no stored entry dropped" do
        e5_read = gatt_entry(5, value: "now read", value_encoding: "utf8", raw_hex: "6e6f772072656164")

        apply(walk_result(mac, outcome, characteristics: [e7, e5_read]))

        expect(stored_chars(reload(mac))).to eq([e3, e5_read, e7])
      end
    end

    it "leaves the list unchanged on protected, while the other columns still update" do
      text = reload(mac).gatt_characteristics

      record = apply(walk_result(mac, :protected, service_uuids: [svc(0x180a)],
                                 identity: { device_name: "Named anyway" }))

      expect(record.gatt_characteristics).to eq(text)
      expect(stored_chars(reload(mac))).to eq([e3, e5])
      expect(stored_uuids(record)).to eq([svc(0x1800), svc(0x180a)])
      expect(record.gatt_device_name).to eq("Named anyway")
      expect(record.filthy_attributes).not_to include(:gatt_characteristics)
    end

    it "leaves the list unchanged on partial with no characteristics" do
      text = reload(mac).gatt_characteristics

      # a later Walk end, so the save is not a no-op and the filthy set is built
      record = apply(walk_result(mac, :partial, ended_at: 1_784_926_866, characteristics: []))

      expect(record.gatt_characteristics).to eq(text)
      expect(stored_chars(reload(mac))).to eq([e3, e5])
      expect(record.filthy_attributes).to eq([:last_seen])
    end
  end

  describe "Database Hash (Requirements 11.9, 17.6)" do
    let(:e3) { gatt_entry(3) }
    let(:e5) { gatt_entry(5, "not-read") }
    let(:e7) { gatt_entry(7, "not-read") }

    before { gatt_device(mac) }

    it "clears gatt_characteristics but not gatt_service_uuids when the result's hash differs from the stored one" do
      apply(walk_result(mac, :complete, database_hash: hash_a,
                        service_uuids: [svc(0x1800), svc(0x180f)], characteristics: [e3, e5]))

      # a merge outcome: into the cleared list, so nothing of the old structure survives
      apply(walk_result(mac, :timeout, database_hash: hash_b, hash_changed: false,
                        service_uuids: [svc(0x180a)], characteristics: [e7]))
      record = reload(mac)

      expect(stored_chars(record)).to eq([e7])
      expect(stored_uuids(record)).to eq([svc(0x1800), svc(0x180a), svc(0x180f)])
      expect(record.gatt_database_hash).to eq(hash_b)
    end

    it "clears gatt_characteristics on hash_changed whatever the outcome, and Sync leaves the empty list out" do
      apply(walk_result(mac, :complete, database_hash: hash_a, service_uuids: [svc(0x1800)], characteristics: [e3]))

      record = apply(walk_result(mac, :protected, database_hash: hash_b, hash_changed: true))

      expect(record.gatt_characteristics).to eq("[]")
      expect(reload(mac).gatt_characteristics).to eq("[]")
      expect(record.gatt_database_hash).to eq(hash_b)
      expect(stored_uuids(record)).to eq([svc(0x1800)])
      # changed, so filthy; an empty JSON array, so not shipped (Requirement 12.3)
      expect(record.filthy_attributes).to include(:gatt_characteristics)
      expect(record.stream_builder_data).not_to have_key(:gatt_characteristics)
    end

    it "clears nothing while either hash is missing" do
      # stored list built before any hash was read, result carrying one
      apply(walk_result(mac, :complete, characteristics: [e3]))
      apply(walk_result(mac, :timeout, database_hash: hash_a, characteristics: [e5]))
      record = reload(mac)
      expect(stored_chars(record)).to eq([e3, e5])
      expect(record.gatt_database_hash).to eq(hash_a)

      # stored hash, result without one: hash_changed false proves no change
      apply(walk_result(mac, :disconnected, database_hash: nil, characteristics: [e7]))
      record = reload(mac)
      expect(stored_chars(record)).to eq([e3, e5, e7])
      expect(record.gatt_database_hash).to eq(hash_a)
    end
  end

  describe "identity columns (Requirements 11.12, 11.13, 11.15)" do
    it "overwrites each identity column from a read, non-empty value, whatever the outcome" do
      gatt_device(mac, gatt_device_name: "Old", gatt_appearance: "0x0000")
      identity = {
        device_name: "Kitchen Sensor", appearance: "0x0340", manufacturer_name: "Acme",
        model_number: "M1", serial_number: "S1", firmware_revision: "F1", hardware_revision: "H1",
        software_revision: "W1", system_id: "0011223344556677", pnp_id: "0x01 0x004c 0x0001 0x0100",
        database_hash: hash_a
      }
      expect(identity.keys).to match_array(identity_columns.keys)

      apply(walk_result(mac, :protected, identity: identity))
      record = reload(mac)
      identity_columns.each do |key, column|
        expect(record.send(column)).to eq(identity[key]), "#{column} was not overwritten"
      end

      apply(walk_result(mac, :timeout, identity: { device_name: "Renamed" }))
      expect(reload(mac).gatt_device_name).to eq("Renamed")
    end

    # The walker leaves protected, malformed and unread Identity_Set values out
    # of identity, so the result simply lacks the key; an empty value is left
    # out here as well.
    it "leaves an identity column alone for a protected, malformed, omitted or empty value" do
      gatt_device(mac, gatt_device_name: "Kept name", gatt_appearance: "0x0340",
                       gatt_model_number: "Kept model", gatt_serial_number: "Kept serial")
      chars = [
        gatt_entry(3, "protected", uuid: chr(0x2A00)),
        gatt_entry(5, "malformed", uuid: chr(0x2A01)),
        gatt_entry(7, "not-read",  uuid: chr(0x2A24))
      ]

      record = apply(walk_result(mac, :complete, characteristics: chars, identity: { serial_number: "" }))

      expect(record.gatt_device_name).to eq("Kept name")
      expect(record.gatt_appearance).to eq("0x0340")
      expect(record.gatt_model_number).to eq("Kept model")
      expect(record.gatt_serial_number).to eq("Kept serial")
      # none of the identity columns was written, so none is dirty
      expect(record.filthy_attributes & identity_columns.values).to eq([])
      expect(record.filthy_attributes).to include(:gatt_characteristics)
      expect(stored_chars(reload(mac))).to eq(chars)
    end

    it "stores a 512-character decoded value and a 1,024-character hex value intact, in the columns and in an entry" do
      name_512 = "N" * 512
      hex_1024 = "ab" * 512
      entry = gatt_entry(3, value: "v" * 512, value_encoding: "utf8", raw_hex: hex_1024)
      gatt_device(mac)

      apply(walk_result(mac, :complete, characteristics: [entry],
                        identity: { device_name: name_512, system_id: hex_1024 }))
      record = reload(mac)

      expect(record.gatt_device_name).to eq(name_512)
      expect(record.gatt_system_id).to eq(hex_1024)
      expect(stored_chars(record)).to eq([entry])
      expect(stored_chars(record)[0][:raw_hex].length).to eq(1_024)
      expect(BlueHydra.logger).not_to have_received(:warn)
    end
  end

  describe "the two lists and their caps (Requirements 11.5, 11.13, 11.17, 11.19)" do
    # 128-bit UUIDs off the Base UUID, so they stay 128-bit and are Unknown to
    # the Nordic database. They sort by n, and the ffff prefix puts every one
    # of them after any 16-bit UUID's 0000xxxx-... expansion.
    def unknown_services(count)
      (0...count).map { |n| svc(format("ffff%04x-1111-2222-3333-444444444444", n)) }
    end

    before { gatt_device(mac) }

    it "stores gatt_service_uuids as the de-duplicated union ordered by 128-bit value" do
      apply(walk_result(mac, :complete, service_uuids: [svc(0x180a), svc(0x1800)]))
      apply(walk_result(mac, :protected, service_uuids: [svc(0x180f), svc(0x1800), *unknown_services(1)]))

      expect(stored_uuids(reload(mac))).to eq([svc(0x1800), svc(0x180a), svc(0x180f), *unknown_services(1)])
    end

    it "stores 1,000 service UUIDs and 1,000 characteristics intact, without a warning" do
      uuids = unknown_services(max_entries)
      chars = (1001..2000).map { |h| gatt_entry(h, "not-read") }

      apply(walk_result(mac, :complete, service_uuids: uuids, characteristics: chars))
      record = reload(mac)

      expect(stored_uuids(record)).to eq(uuids)
      expect(stored_chars(record)).to eq(chars)
      expect(record.gatt_characteristics.bytesize).to be <= max_bytes
      expect(BlueHydra.logger).not_to have_received(:warn)
    end

    it "keeps the first 1,000 of 1,001 service UUIDs, saves the rest of the result and warns once" do
      uuids = unknown_services(max_entries + 1)

      apply(walk_result(mac, :complete, service_uuids: uuids.reverse, identity: { device_name: "Still saved" }))
      record = reload(mac)

      expect(stored_uuids(record)).to eq(uuids.first(max_entries))
      expect(record.gatt_device_name).to eq("Still saved")
      expect(BlueHydra.logger).to have_received(:warn)
        .with("gatt: #{mac} gatt_service_uuids over 1000 entries: 1 dropped").once
    end

    # The worked example of spec/gatt_characteristics_spec.rb, delivered as a
    # Walk result: value_handle => [serialised entry bytes, raw_hex characters].
    # 272,640 bytes of entries + 7 = 272,647. Every raw_hex is removed first
    # (101 to 104 then 60,000 bytes each, 105 30,000, 106 1,000: 271,007, still
    # over), then entries go from the top handle down: 106 (270,006, still
    # over), then 105 (240,005, fits). 105 and 106 lost their raw_hex before
    # being dropped, so 3 raw_hex markers remain in the stored text.
    it "trims an oversize gatt_characteristics list raw_hex largest-first, then entries from the top handle, and warns once" do
      sizes = { 101 => [60_088, 100], 102 => [60_588, 600], 103 => [60_288, 300],
                104 => [60_000, nil], 105 => [30_488, 500], 106 => [1_188, 200] }
      list  = [104, 106, 102, 101, 105, 103].map { |h| entry_of_size(h, sizes[h][0], raw_hex: sizes[h][1]) }
      expect(BlueHydra::GattCharacteristics.serialize(list).bytesize).to eq(272_647)

      apply(walk_result(mac, :complete, characteristics: list, identity: { device_name: "Still saved" }))
      record = reload(mac)

      by_handle = list.to_h { |e| [e[:value_handle], e] }
      expect(stored_chars(record)).to eq([stripped(by_handle[101]), stripped(by_handle[102]),
                                          stripped(by_handle[103]), by_handle[104]])
      expect(record.gatt_characteristics.bytesize).to eq(240_005)
      expect(record.gatt_device_name).to eq("Still saved")
      expect(BlueHydra.logger).to have_received(:warn)
        .with("gatt: #{mac} gatt_characteristics over cap: 272647 -> 240005 bytes, " \
              "3 raw_hex removed, 2 entries dropped").once
    end
  end

  # The payload is change-gated by prepare_the_filth (before save) on
  # DataMapper's dirty tracking, so what Sync ships is decided by which columns
  # the save actually changed. stream_builder_data without sync_all is that
  # record, as in the "sync payload shape" examples above.
  describe "sync delivery (Requirements 12.3, 12.4, 12.7)" do
    before { gatt_device(mac) }

    it "delivers exactly the Gatt_Columns the save changed" do
      apply(walk_result(mac, :protected, ended_at: 1_700_000_000,
                        service_uuids: [svc(0x1800)], identity: { appearance: "0x0340" }))

      record = apply(walk_result(mac, :complete, ended_at: 1_700_000_010,
                                 service_uuids: [svc(0x1800), svc(0x180a)], characteristics: [gatt_entry(3)],
                                 identity: { appearance: "0x0340", device_name: "Kitchen Sensor" }))

      expect(record.filthy_attributes).to match_array(%i[last_seen gatt_service_uuids gatt_characteristics gatt_device_name])
      data = record.stream_builder_data
      expect(data.keys & gatt_columns).to match_array(%i[gatt_service_uuids gatt_characteristics gatt_device_name])
      expect(data[:gatt_service_uuids]).to eq([svc(0x1800), svc(0x180a)])
      expect(data[:gatt_characteristics]).to eq(JSON.parse(BlueHydra::GattCharacteristics.serialize([gatt_entry(3)])))
      expect(data[:gatt_device_name]).to eq("Kitchen Sensor")
    end

    it "delivers no Gatt_Columns when the result changes none of them" do
      result = walk_result(mac, :complete, ended_at: 1_700_000_000, database_hash: hash_a,
                           service_uuids: [svc(0x1800)], characteristics: [gatt_entry(3)],
                           identity: { device_name: "Kitchen Sensor", appearance: "0x0340" })
      apply(result)

      # the same result again: nothing is dirty, so save never reaches
      # prepare_the_filth and no sync payload is produced at all
      same = apply(result)
      expect(same.filthy_attributes).to be_nil
      expect(same.stream_builder_data.keys & gatt_columns).to eq([])

      # the same result from a later Walk: only last_seen moved
      later = apply(result.merge(ended_at: 1_700_000_001))
      expect(later.filthy_attributes).to eq([:last_seen])
      expect(later.stream_builder_data.keys & gatt_columns).to eq([])
    end

    it "leaves gatt_service_uuids out when every UUID was already stored, in any order" do
      apply(walk_result(mac, :complete, ended_at: 1_700_000_000,
                        service_uuids: [svc(0x180a), svc(0x1800), svc(0x180f)]))
      text = reload(mac).gatt_service_uuids
      expect(JSON.parse(text)).to eq([svc(0x1800), svc(0x180a), svc(0x180f)])

      reordered = apply(walk_result(mac, :partial, ended_at: 1_700_000_005,
                                    service_uuids: [svc(0x180f), svc(0x180a), svc(0x1800)]))
      expect(reordered.gatt_service_uuids).to eq(text)
      expect(reordered.filthy_attributes).to eq([:last_seen])
      expect(reordered.stream_builder_data).not_to have_key(:gatt_service_uuids)

      subset = apply(walk_result(mac, :protected, ended_at: 1_700_000_010, service_uuids: [svc(0x180a)]))
      expect(subset.gatt_service_uuids).to eq(text)
      expect(subset.filthy_attributes).to eq([:last_seen])
      expect(subset.stream_builder_data).not_to have_key(:gatt_service_uuids)
    end
  end

  describe ".mark_offline (Requirement 17.8)" do
    before { BlueHydra::GattTracker.reset! }
    after  { BlueHydra::GattTracker.reset! }

    it "forgets the address's Resume_State and keeps its Finished_Walk, beside ConnectTracker.forget" do
      device = gatt_device(mac, status: "online")
      BlueHydra::GattTracker.store_resume_state(mac, BlueHydra::GattWalker::WalkState.fresh)
      BlueHydra::GattTracker.record_finished(mac, hash_a, 100.0, 60)
      expect(BlueHydra::GattTracker.resume_state(mac)).not_to be_nil
      expect(BlueHydra::GattTracker).to receive(:forget).with(mac).and_call_original
      expect(BlueHydra::ConnectTracker).to receive(:forget).with(mac).and_call_original

      BlueHydra::Device.mark_offline(device)

      expect(device.status).to eq("offline")
      expect(BlueHydra::GattTracker.resume_state(mac)).to be_nil
      expect(BlueHydra::GattTracker.finished(mac)).to eq(finished_at: 100.0, database_hash: hash_a)
    end
  end
end
