require 'spec_helper'
require 'blue_hydra/gatt_characteristics'
require 'json'

describe BlueHydra::GattCharacteristics do
  # Locals rather than constants: a constant here would land on Object and be
  # shared with every other spec file. The examples close over them.

  # Freezes obj and everything inside it, so an example that passes it to the
  # subject fails with FrozenError if the subject writes to any of it.
  deep_freeze = lambda do |obj|
    case obj
    when Hash  then obj.each { |key, value| deep_freeze.(key); deep_freeze.(value) }
    when Array then obj.each { |value| deep_freeze.(value) }
    end
    obj.freeze
  end

  # One entry of each read_status, with the exact text serialize must write for
  # it (Requirement 11.10), in ascending value_handle. The uuids are what
  # UuidNames renders for them at the pinned Nordic commit, including the
  # Unknown ones. Each entry's keys are inserted in KEY_ORDER here; the
  # key-order example reverses them.
  goldens = [
    ["read, identity value, an unresolved include",
     { uuid: "Device Name (0x2a00)", service_uuid: "Generic Access (0x1800)", service_type: "primary",
       service_start: 1, service_end: 7,
       service_includes: [{ uuid: "Unknown (0x1234)", start: 40, end: 45 }, { uuid: nil, start: 50, end: 60 }],
       decl_handle: 2, value_handle: 3, properties: ["read", "write"], descriptors: [],
       read_status: "read", value: "Kitchen Sensor", value_encoding: "identity" },
     '{"uuid":"Device Name (0x2a00)","service_uuid":"Generic Access (0x1800)","service_type":"primary",' \
     '"service_start":1,"service_end":7,"service_includes":[{"uuid":"Unknown (0x1234)","start":40,"end":45},' \
     '{"uuid":null,"start":50,"end":60}],"decl_handle":2,"value_handle":3,"properties":["read","write"],' \
     '"descriptors":[],"read_status":"read","value":"Kitchen Sensor","value_encoding":"identity"}'],
    ["read, kept as hex",
     { uuid: "Unknown (0x5678)", service_uuid: "Generic Access (0x1800)", service_type: "primary",
       service_start: 1, service_end: 7, service_includes: [], decl_handle: 4, value_handle: 5,
       properties: ["read"], descriptors: [], read_status: "read", value: "0102ff", value_encoding: "hex" },
     '{"uuid":"Unknown (0x5678)","service_uuid":"Generic Access (0x1800)","service_type":"primary",' \
     '"service_start":1,"service_end":7,"service_includes":[],"decl_handle":4,"value_handle":5,' \
     '"properties":["read"],"descriptors":[],"read_status":"read","value":"0102ff","value_encoding":"hex"}'],
    ["not-readable",
     { uuid: "Service Changed (0x2a05)", service_uuid: "Generic Attribute (0x1801)", service_type: "primary",
       service_start: 8, service_end: 11, service_includes: [], decl_handle: 9, value_handle: 10,
       properties: ["indicate"], descriptors: [{ uuid: "Client Characteristic Configuration (0x2902)", handle: 11 }],
       read_status: "not-readable" },
     '{"uuid":"Service Changed (0x2a05)","service_uuid":"Generic Attribute (0x1801)","service_type":"primary",' \
     '"service_start":8,"service_end":11,"service_includes":[],"decl_handle":9,"value_handle":10,' \
     '"properties":["indicate"],"descriptors":[{"uuid":"Client Characteristic Configuration (0x2902)",' \
     '"handle":11}],"read_status":"not-readable"}'],
    ["read, format-decoded with raw_hex",
     { uuid: "Battery Level (0x2a19)", service_uuid: "Battery Service (0x180f)", service_type: "primary",
       service_start: 16, service_end: 20, service_includes: [], decl_handle: 17, value_handle: 18,
       properties: ["read", "notify"],
       descriptors: [{ uuid: "Client Characteristic Configuration (0x2902)", handle: 19 },
                     { uuid: "Characteristic Presentation Format (0x2904)", handle: 20 }],
       read_status: "read", value: 100, value_encoding: "format:uint8;unit:0x27ad", raw_hex: "64" },
     '{"uuid":"Battery Level (0x2a19)","service_uuid":"Battery Service (0x180f)","service_type":"primary",' \
     '"service_start":16,"service_end":20,"service_includes":[],"decl_handle":17,"value_handle":18,' \
     '"properties":["read","notify"],"descriptors":[{"uuid":"Client Characteristic Configuration (0x2902)",' \
     '"handle":19},{"uuid":"Characteristic Presentation Format (0x2904)","handle":20}],"read_status":"read",' \
     '"value":100,"value_encoding":"format:uint8;unit:0x27ad","raw_hex":"64"}'],
    ["protected",
     { uuid: "Manufacturer Name String (0x2a29)", service_uuid: "Unknown (0x1234)", service_type: "primary",
       service_start: 21, service_end: 27, service_includes: [], decl_handle: 22, value_handle: 23,
       properties: ["read"], descriptors: [], read_status: "protected", error_code: 5 },
     '{"uuid":"Manufacturer Name String (0x2a29)","service_uuid":"Unknown (0x1234)","service_type":"primary",' \
     '"service_start":21,"service_end":27,"service_includes":[],"decl_handle":22,"value_handle":23,' \
     '"properties":["read"],"descriptors":[],"read_status":"protected","error_code":5}'],
    ["not-read",
     { uuid: "Unknown (0x5678)", service_uuid: "Unknown (0x1234)", service_type: "primary",
       service_start: 21, service_end: 27, service_includes: [], decl_handle: 24, value_handle: 25,
       properties: ["read", "write-without-response"], descriptors: [], read_status: "not-read" },
     '{"uuid":"Unknown (0x5678)","service_uuid":"Unknown (0x1234)","service_type":"primary",' \
     '"service_start":21,"service_end":27,"service_includes":[],"decl_handle":24,"value_handle":25,' \
     '"properties":["read","write-without-response"],"descriptors":[],"read_status":"not-read"}'],
    ["error",
     { uuid: "Unknown (12345678-9abc-def0-1234-56789abcdef0)", service_uuid: "Unknown (0x1234)",
       service_type: "primary", service_start: 21, service_end: 27, service_includes: [],
       decl_handle: 26, value_handle: 27, properties: ["read"], descriptors: [],
       read_status: "error", error_code: 14 },
     '{"uuid":"Unknown (12345678-9abc-def0-1234-56789abcdef0)","service_uuid":"Unknown (0x1234)",' \
     '"service_type":"primary","service_start":21,"service_end":27,"service_includes":[],"decl_handle":26,' \
     '"value_handle":27,"properties":["read"],"descriptors":[],"read_status":"error","error_code":14}'],
    ["read, raw_hex removed for the byte cap",
     { uuid: "Unknown (12345678-9abc-def0-1234-56789abcdef0)",
       service_uuid: "Unknown (12345678-9abc-def0-1234-56789abcdef1)", service_type: "secondary",
       service_start: 30, service_end: 35, service_includes: [], decl_handle: 32, value_handle: 33,
       properties: ["read"], descriptors: [], read_status: "read", value: "hello", value_encoding: "utf8",
       raw_hex_truncated: true },
     '{"uuid":"Unknown (12345678-9abc-def0-1234-56789abcdef0)",' \
     '"service_uuid":"Unknown (12345678-9abc-def0-1234-56789abcdef1)","service_type":"secondary",' \
     '"service_start":30,"service_end":35,"service_includes":[],"decl_handle":32,"value_handle":33,' \
     '"properties":["read"],"descriptors":[],"read_status":"read","value":"hello","value_encoding":"utf8",' \
     '"raw_hex_truncated":true}'],
    ["malformed",
     { uuid: "Unknown (0x5678)", service_uuid: "Unknown (12345678-9abc-def0-1234-56789abcdef1)",
       service_type: "secondary", service_start: 30, service_end: 35, service_includes: [],
       decl_handle: 34, value_handle: 35, properties: ["read"], descriptors: [], read_status: "malformed" },
     '{"uuid":"Unknown (0x5678)","service_uuid":"Unknown (12345678-9abc-def0-1234-56789abcdef1)",' \
     '"service_type":"secondary","service_start":30,"service_end":35,"service_includes":[],"decl_handle":34,' \
     '"value_handle":35,"properties":["read"],"descriptors":[],"read_status":"malformed"}'],
  ]
  goldens.each { |_, entry, text| deep_freeze.(entry); text.freeze }

  # A valid entry in the in-memory form: Symbol keys at every level, uuids as
  # UuidNames renders them. read_status decides which conditional keys appear:
  # value and value_encoding for "read", error_code for protected and error.
  # overrides then replace or add keys, and except removes them, so an example
  # can build exactly one schema violation.
  def entry(value_handle, read_status = "read", except: [], **overrides)
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
    built.merge(overrides).reject { |key, _| except.include?(key) }
  end

  # The cap examples' entries: a not-read entry when value_len is nil,
  # otherwise a read one whose value is value_len "v"s and whose raw_hex, when
  # given, is raw_hex_len "a"s. Varying those two lengths sets the entry's
  # serialised size.
  def cap_entry(value_handle, value_len: nil, raw_hex_len: nil)
    return entry(value_handle, "not-read") if value_len.nil?
    overrides = { value: "v" * value_len, value_encoding: "utf8" }
    overrides[:raw_hex] = "a" * raw_hex_len if raw_hex_len
    entry(value_handle, **overrides)
  end

  # The serialised text of cap_entry, written out here rather than read back
  # through the subject, so that the cap examples' byte counts are computed.
  # truncated: the text once fit_to_caps has removed the raw_hex.
  def cap_text(value_handle, value_len: nil, raw_hex_len: nil, truncated: false)
    head = %({"uuid":"Device Name (0x2a00)","service_uuid":"Generic Access (0x1800)","service_type":"primary",) +
           %("service_start":1,"service_end":65535,"service_includes":[],) +
           %("decl_handle":#{value_handle - 1},"value_handle":#{value_handle},) +
           %("properties":["read"],"descriptors":[],)
    return head + %("read_status":"not-read"}) if value_len.nil?
    tail = if truncated      then %(,"raw_hex_truncated":true)
           elsif raw_hex_len then %(,"raw_hex":"#{'a' * raw_hex_len}")
           else ""
           end
    head + %("read_status":"read","value":"#{'v' * value_len}","value_encoding":"utf8"#{tail}})
  end

  # A read cap_entry whose serialised text is exactly bytes long. With
  # raw_hex: n it carries n hex characters of raw_hex, which the 13 bytes of
  # ,"raw_hex":"" wrap.
  def entry_of_size(value_handle, bytes, raw_hex: nil)
    fixed = cap_text(value_handle, value_len: 0).bytesize + (raw_hex ? 13 + raw_hex : 0)
    raise "#{bytes} bytes is below the #{fixed} an entry at #{value_handle} needs" if bytes < fixed
    cap_entry(value_handle, value_len: bytes - fixed, raw_hex_len: raw_hex)
  end

  # entry as fit_to_caps leaves it once its raw_hex is removed.
  def stripped(entry)
    entry.reject { |key, _| key == :raw_hex }.merge(raw_hex_truncated: true)
  end

  # entry with its keys, and its includes' and descriptors' keys, inserted in
  # reverse order.
  def reversed_keys(entry)
    entry.to_a.reverse.to_h do |key, value|
      value = value.map { |item| item.is_a?(Hash) ? item.to_a.reverse.to_h : item } if value.is_a?(Array)
      [key, value]
    end
  end

  def deep_copy(obj)
    Marshal.load(Marshal.dump(obj))
  end

  def handles(list)
    list.map { |e| e[:value_handle] }
  end

  it "caps the serialised gatt_characteristics text at 262,144 bytes and both lists at 1,000 entries" do
    expect(described_class::MAX_BYTES).to eq(262_144)
    expect(described_class::MAX_ENTRIES).to eq(1_000)
  end

  describe ".serialize" do
    # Requirement 11.10: the keys of an entry depend on its read_status.
    goldens.each do |label, golden_entry, text|
      it "writes a #{label} entry as its exact schema text" do
        expect(described_class.serialize([golden_entry])).to eq("[#{text}]")
      end
    end

    it "writes value and value_encoding only for read, and error_code only for protected and error" do
      conditional = goldens.to_h do |_, golden_entry, _|
        written = JSON.parse(described_class.serialize([golden_entry]))[0].keys
        label   = golden_entry[:read_status] + (golden_entry[:value_encoding] ? ":#{golden_entry[:value_encoding]}" : "")
        [label, written & %w[error_code value value_encoding raw_hex raw_hex_truncated]]
      end
      expect(conditional).to eq(
        "read:identity"                 => %w[value value_encoding],
        "read:hex"                      => %w[value value_encoding],
        "not-readable"                  => [],
        "read:format:uint8;unit:0x27ad" => %w[value value_encoding raw_hex],
        "protected"                     => %w[error_code],
        "not-read"                      => [],
        "error"                         => %w[error_code],
        "read:utf8"                     => %w[value value_encoding raw_hex_truncated],
        "malformed"                     => []
      )
    end

    it "writes keys in schema order whatever order they were inserted in" do
      goldens.each do |label, golden_entry, text|
        reversed = reversed_keys(golden_entry)
        expect(reversed.keys).not_to eq(golden_entry.keys)
        expect(reversed).to eq(golden_entry)
        expect(described_class.serialize([reversed])).to eq("[#{text}]"), label
      end
    end

    it "writes entries in ascending value_handle whatever order they come in" do
      shuffled = goldens.map { |_, golden_entry, _| golden_entry }.values_at(4, 0, 8, 2, 6, 1, 7, 3, 5)
      expect(described_class.serialize(shuffled)).to eq("[#{goldens.map(&:last).join(',')}]")
    end

    it "writes the same list to identical text every time" do
      list = goldens.map { |_, golden_entry, _| golden_entry }
      expect(described_class.serialize(list)).to eq(described_class.serialize(list.reverse))
      expect(described_class.serialize(list)).to eq(described_class.serialize(list))
    end

    it "writes an empty list as []" do
      expect(described_class.serialize([])).to eq("[]")
    end
  end

  describe ".parse" do
    it "reads a column never written, nil or empty, as the empty list" do
      expect(described_class.parse(nil)).to eq([])
      expect(described_class.parse("")).to eq([])
      expect(described_class.parse("[]")).to eq([])
    end

    it "returns what serialize wrote, entry for entry (Requirement 11.11)" do
      list = goldens.map { |_, golden_entry, _| golden_entry }
      expect(described_class.parse(described_class.serialize(list))).to eq(list)
    end

    it "returns a list serialised out of order in ascending value_handle" do
      list = goldens.map { |_, golden_entry, _| golden_entry }
      expect(described_class.parse(described_class.serialize(list.reverse))).to eq(list)
    end

    it "uses Symbol keys at every level, including includes and descriptors" do
      parsed = described_class.parse("[#{goldens[0].last},#{goldens[3].last}]")
      expect(parsed[0].keys).to all(be_a(Symbol))
      expect(parsed[0][:service_includes].map(&:keys)).to eq([%i[uuid start end], %i[uuid start end]])
      expect(parsed[0][:service_includes][1][:uuid]).to be_nil
      expect(parsed[1][:descriptors].map(&:keys)).to eq([%i[uuid handle], %i[uuid handle]])
      expect(parsed[1][:read_status]).to eq("read")
      expect(parsed[1][:value]).to eq(100)
    end
  end

  # Feature: gatt-service-scanning, Property 12: Characteristic list serialisation round trip and determinism
  #
  # Validates: Requirements 11.10, 11.11
  #
  # Each case is a list of 0 to 30 entries built from the design's entry
  # schema. Every read_status appears, each entry carrying only the
  # conditional keys its status allows. A read value has one of the four
  # value_encodings: identity, format:<type> with or without a unit, utf8 or
  # hex. A format or utf8 value carries a raw_hex of 0 to 1,024 hex
  # characters, or raw_hex_truncated in its place. The uuids are UuidNames
  # renders of Nordic-listed and unlisted UUIDs at both widths, of 128-bit
  # Base UUID spellings that fold to 16 bits, and of 32-bit UUIDs on the Base,
  # which do not. Includes come with and without a resolved uuid. Handles are
  # drawn independently from 0x0001..0xFFFF with both bounds common, value
  # handles distinct within a list; serialize checks no relation between
  # them. Text values mix what JSON must escape (quote, backslash, control
  # characters, NUL among them) with U+2028, U+FEFF, U+FFFD and characters
  # beyond the BMP. Numeric values are Strings, as the Value_Decoder renders
  # them. Entries come in ascending, descending or random value_handle order,
  # and each entry's, include's and descriptor's keys are inserted in schema,
  # reversed or random order.
  #
  # The expected list is the input sorted by value_handle: parse(serialize(
  # list)) == list holds as written for a list already ascending, and
  # serialize sorts any other (Requirement 11.10). Hash equality ignores
  # insertion order, so parse's result can equal an input whose keys went in
  # shuffled; re-serialising it then shows that two equal lists built in
  # different orders write identical text. The schema key order is restated
  # here, not read from KEY_ORDER. Every expectation derives from the printed
  # list, so a failing case can be reproduced from rantly's output.
  it "Property 12: parse returns what serialize wrote, and serialize writes any list to the same text every time" do
    entry_keys     = %i[uuid service_uuid service_type service_start service_end service_includes
                        decl_handle value_handle properties descriptors read_status error_code
                        value value_encoding raw_hex raw_hex_truncated]
    property_names = %w[broadcast read write-without-response write notify indicate
                        authenticated-signed-writes extended-properties]
    read_statuses  = %w[read protected not-read not-readable error malformed]
    format_types   = %w[boolean uint8 uint16 uint24 uint32 uint48 uint64 sint8 sint16 sint24 sint32 utf8s utf16s]
    text_pieces    = ["a", "Z", "7", " ", ".", "(", ")", "\"", "\\", "/", "\u0000", "\b", "\f", "\n", "\r", "\t",
                      "\u0001", "\u001f", "\u007f", "\u00e9", "\u20ac", "\u2028", "\ufeff", "\ufffd",
                      "\u{1f600}", "\u{10ffff}"]
    # Every UUID the vendored Nordic files list, per role, as they spell it.
    listed = BlueHydra::UuidNames::FILES.to_h do |role, file|
      [role, JSON.parse(File.read(File.join(BlueHydra::UuidNames::DATA_DIR, file))).map { |e| e["uuid"] }]
    end
    seen = Hash.new(0)

    # The lambdas are created inside the generator so they share rantly's
    # self (property_of instance_evals its block) and can call range, freq
    # etc. What freq and array evaluate must be a proc or block, not a
    # lambda: rantly instance_evals it, which passes an argument.
    property_of {
      tags = []
      pick   = ->(lo, hi) { freq([1, :literal, lo], [1, :literal, hi], [4, proc { range(lo, hi) }]) }
      handle = -> { pick.(0x0001, 0xFFFF) }
      hex    = ->(bytes) { array(bytes) { range(0x00, 0xFF) }.pack("C*").unpack1("H*") }
      text   = lambda do
        s = array(pick.(0, 40)) { choose(*text_pieces) }.join
        tags << :escaped_char if s.match?(/["\\\x00-\x1f]/)
        tags << :beyond_bmp if s.each_char.any? { |c| c.ord > 0xFFFF }
        tags << :line_separator if s.include?("\u2028")
        s
      end

      uuid = lambda do |role|
        kind = freq([3, :literal, :listed_uuid], [2, :literal, :bits16], [2, :literal, :bits128],
                    [1, :literal, :folded], [1, :literal, :bits32])
        tags << kind
        spelled =
          case kind
          when :listed_uuid then choose(*listed[role])
          when :bits16      then range(0x0000, 0xFFFF)
          when :bits128     then format("%032x", range(0, 2**128 - 1))
          # a 16-bit UUID in its 128-bit Base UUID spelling, rendered 16-bit
          when :folded      then format("0000%04x-0000-1000-8000-00805f9b34fb", range(0x0000, 0xFFFF))
          # a 32-bit UUID on the Base, which stays 128-bit
          when :bits32      then format("%08x-0000-1000-8000-00805f9b34fb", range(0x1_0000, 0xFFFF_FFFF))
          end
        rendered = BlueHydra::UuidNames.render(role, spelled)
        tags << (rendered.match?(/\(0x\h{4}\)\z/) ? :uuid16 : :uuid128)
        tags << (rendered.start_with?("Unknown (") ? :unknown_name : :listed_name)
        tags << :parenthesised_name if rendered.count("(") > 1
        rendered
      end

      # hash with its keys inserted in schema, reversed or random order
      reorder = lambda do |hash|
        keys =
          case freq([1, :literal, :schema], [1, :literal, :reversed], [2, :literal, :random])
          when :schema   then hash.keys
          when :reversed then hash.keys.reverse
          else                hash.keys.sort_by { range(0, 2**30) }
          end
        tags << :keys_reordered unless keys == hash.keys
        keys.to_h { |key| [key, hash[key]] }
      end

      build = lambda do |value_handle|
        status = choose(*read_statuses)
        tags << status.to_sym
        built = {
          uuid:             uuid.(:characteristic),
          service_uuid:     uuid.(:service),
          service_type:     choose("primary", "secondary"),
          service_start:    handle.(),
          service_end:      handle.(),
          service_includes: array(pick.(0, 3)) {
            include_uuid = freq([1, :literal, nil], [3, proc { uuid.(:service) }])
            tags << :unresolved_include if include_uuid.nil?
            reorder.({ uuid: include_uuid, start: handle.(), end: handle.() })
          },
          decl_handle:      handle.(),
          value_handle:     value_handle,
          # in bit order; read is set unless the characteristic is not readable
          properties:       property_names.select { |name| name == "read" ? status != "not-readable" : boolean },
          descriptors:      array(pick.(0, 4)) { reorder.({ uuid: uuid.(:descriptor), handle: handle.() }) },
          read_status:      status,
        }
        built[:error_code] = pick.(0x01, 0xFF) if %w[protected error].include?(status)
        if status == "read"
          kind = choose(:identity, :format, :utf8, :hex)
          tags << kind
          case kind
          when :identity
            built[:value]          = text.()
            built[:value_encoding] = "identity"
          when :utf8
            built[:value]          = text.()
            built[:value_encoding] = "utf8"
          when :hex
            built[:value]          = hex.(pick.(0, 512))
            built[:value_encoding] = "hex"
          when :format
            type = choose(*format_types)
            built[:value] =
              case type
              when "boolean"         then choose("true", "false")
              when "utf8s", "utf16s" then text.()
              else
                # a scaled integer: digits, a fraction for a negative exponent, a sign
                digits = range(0, 2**64 - 1).to_s
                digits += ".#{format('%03d', range(0, 999))}" if boolean
                boolean ? "-#{digits}" : digits
              end
            unit = freq([1, :literal, nil], [2, proc { range(0x2701, 0x27FF) }])
            tags << (unit ? :format_with_unit : :format_unitless)
            built[:value_encoding] = "format:#{type}#{format(';unit:0x%04x', unit) if unit}"
          end
          tags << :empty_value if built[:value].empty?
          # a decode other than hex keeps the raw bytes, unless the cap removed them
          if %i[format utf8].include?(kind)
            if freq([3, :literal, true], [1, :literal, false])
              built[:raw_hex] = hex.(pick.(0, 512))
              tags << :raw_hex
              tags << :raw_hex_empty if built[:raw_hex].empty?
              tags << :raw_hex_1024 if built[:raw_hex].length == 1_024
            else
              built[:raw_hex_truncated] = true
              tags << :raw_hex_truncated
            end
          end
        end
        reorder.(built)
      end

      count = freq([1, :literal, 0], [1, :literal, 1], [6, proc { range(2, 30) }])
      handles = []
      handles |= [handle.()] while handles.size < count
      handles =
        case freq([1, :literal, :ascending], [1, :literal, :descending], [2, :literal, :as_drawn])
        when :ascending  then handles.sort
        when :descending then handles.sort.reverse
        else                  handles
        end
      [handles.map { |h| build.(h) }, tags.uniq]
    # 200 rather than 100 for the coverage assertions below. The rarest are an
    # empty list and a one-entry list, each 1 case in 8, so 200 misses one of
    # them about once in 10^11 runs. The 200 cases take about 1 s.
    }.check(200) { |list, tags|
      tags.each { |tag| seen[tag] += 1 }
      handles = list.map { |e| e[:value_handle] }
      seen[:empty_list] += 1 if list.empty?
      seen[:one_entry] += 1 if list.size == 1
      seen[:out_of_order] += 1 if handles != handles.sort
      seen[:handle_0x0001] += 1 if handles.include?(0x0001)
      seen[:handle_0xffff] += 1 if handles.include?(0xFFFF)
      # Frozen, so a serialize or parse that wrote to its input would fail here.
      deep_freeze.(list)
      expected = list.sort_by { |e| e[:value_handle] }

      text = described_class.serialize(list)
      expect(described_class.serialize(list)).to eq(text)

      parsed = described_class.parse(text)
      expect(parsed).to eq(expected)
      expect(described_class.serialize(parsed)).to eq(text)

      # Requirement 11.10's layout: entries in ascending value handle, keys in
      # schema order at every level.
      written = JSON.parse(text)
      expect(written.map { |e| e["value_handle"] }).to eq(handles.sort)
      expect(written.map(&:keys)).to eq(expected.map { |e| entry_keys.select { |key| e.key?(key) }.map(&:to_s) })
      expect(written.flat_map { |e| e["service_includes"].map(&:keys) }).to all(eq(%w[uuid start end]))
      expect(written.flat_map { |e| e["descriptors"].map(&:keys) }).to all(eq(%w[uuid handle]))
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect(%i[read protected not-read not-readable error malformed
              identity format utf8 hex format_with_unit format_unitless empty_value
              raw_hex raw_hex_empty raw_hex_1024 raw_hex_truncated
              listed_uuid bits16 bits128 folded bits32 uuid16 uuid128 listed_name unknown_name parenthesised_name
              unresolved_include keys_reordered escaped_char beyond_bmp line_separator
              empty_list one_entry out_of_order handle_0x0001 handle_0xffff] - seen.keys).to eq([])
  end

  describe "schema checks" do
    serialize_msg = ->(text) { /\A#{Regexp.escape("GattCharacteristics.serialize: #{text}")}/ }
    at3           = ->(text) { serialize_msg.("entry at value_handle 0x0003: #{text}") }

    # One example per check, each list breaking exactly one rule.
    [
      ["a list that is not an Array", -> { nil }, serialize_msg.("NilClass is not an Array")],
      ["an entry that is not a Hash", -> { [entry(3), "x"] }, serialize_msg.("entry 1 is a String, not a Hash")],
      ["String keys, as JSON.parse writes them without symbolize_names",
       -> { [entry(3).transform_keys(&:to_s)] },
       serialize_msg.("entry 0 has value_handle nil, not an Integer in 0x0001..0xFFFF")],
      ["value_handle 0", -> { [entry(3, value_handle: 0)] },
       serialize_msg.("entry 0 has value_handle 0, not an Integer in 0x0001..0xFFFF")],
      ["value_handle 0x10000", -> { [entry(3, value_handle: 0x10000)] },
       serialize_msg.("entry 0 has value_handle 65536, not an Integer in 0x0001..0xFFFF")],
      ["a hex-string value_handle", -> { [entry(3, value_handle: "0x0003")] },
       serialize_msg.('entry 0 has value_handle "0x0003", not an Integer in 0x0001..0xFFFF')],
      ["two entries for one value_handle", -> { [entry(3), entry(3, "not-read")] },
       serialize_msg.("value_handle 0x0003 appears more than once")],
      ["a key outside the schema", -> { [entry(3, raw_hex_truncate: true)] },
       at3.("unknown keys [:raw_hex_truncate]")],
      ["a missing required key", -> { [entry(3, except: [:descriptors])] },
       at3.("missing keys [:descriptors]")],
      ["a Symbol read_status", -> { [entry(3, "not-read", read_status: :read)] },
       at3.("read_status :read is not one of read, protected, not-read, not-readable, error, malformed")],
      ["a value on a not-read entry", -> { [entry(3, "not-read", value: "x")] },
       at3.('value must be present exactly when read_status is "read" (read_status "not-read")')],
      ["a read entry without value_encoding", -> { [entry(3, except: [:value_encoding])] },
       at3.('value_encoding must be present exactly when read_status is "read" (read_status "read")')],
      ["an error_code on a read entry", -> { [entry(3, error_code: 5)] },
       at3.('error_code must be present exactly when read_status is protected or error (read_status "read")')],
      ["an error entry without error_code", -> { [entry(3, "error", except: [:error_code])] },
       at3.('error_code must be present exactly when read_status is protected or error (read_status "error")')],
      ["raw_hex on a malformed entry", -> { [entry(3, "malformed", raw_hex: "00")] },
       at3.("raw_hex must be a String on a read entry")],
      ["a raw_hex that is not a String", -> { [entry(3, raw_hex: 0x64)] },
       at3.("raw_hex must be a String on a read entry")],
      ["raw_hex_truncated false", -> { [entry(3, raw_hex_truncated: false)] },
       at3.("raw_hex_truncated must be true, on a read entry without raw_hex")],
      ["raw_hex_truncated beside a raw_hex", -> { [entry(3, raw_hex: "00", raw_hex_truncated: true)] },
       at3.("raw_hex_truncated must be true, on a read entry without raw_hex")],
      ["raw_hex_truncated on a protected entry", -> { [entry(3, "protected", raw_hex_truncated: true)] },
       at3.("raw_hex_truncated must be true, on a read entry without raw_hex")],
      ["a bare uuid", -> { [entry(3, uuid: "0x2a00")] },
       at3.('uuid "0x2a00" is not in Uuid_Formatter form')],
      ["a uuid on the Base UUID left unfolded",
       -> { [entry(3, uuid: "Device Name (00002a00-0000-1000-8000-00805f9b34fb)")] },
       at3.('uuid "Device Name (00002a00-0000-1000-8000-00805f9b34fb)" is not in Uuid_Formatter form')],
      ["an upper-case service_uuid", -> { [entry(3, service_uuid: "Generic Access (0X1800)")] },
       at3.('service_uuid "Generic Access (0X1800)" is not in Uuid_Formatter form')],
      ["a nil service_uuid", -> { [entry(3, service_uuid: nil)] },
       at3.("service_uuid nil is not in Uuid_Formatter form")],
      ["service_includes that is not an Array", -> { [entry(3, service_includes: nil)] },
       at3.("service_includes is a NilClass, not an Array")],
      ["an include missing its end", -> { [entry(3, service_includes: [{ uuid: nil, start: 40 }])] },
       at3.("service_includes item 0 must be a Hash with exactly the keys [:uuid, :start, :end]")],
      ["an include with a bare uuid", -> { [entry(3, service_includes: [{ uuid: "0x1234", start: 40, end: 45 }])] },
       at3.('service_includes item 0: uuid "0x1234" is not in Uuid_Formatter form')],
      ["descriptors that is not an Array", -> { [entry(3, descriptors: {})] },
       at3.("descriptors is a Hash, not an Array")],
      ["a descriptor with String keys",
       -> { [entry(3, descriptors: [{ "uuid" => "Characteristic Presentation Format (0x2904)", "handle" => 4 }])] },
       at3.("descriptors item 0 must be a Hash with exactly the keys [:uuid, :handle]")],
      ["a descriptor with a nil uuid", -> { [entry(3, descriptors: [{ uuid: nil, handle: 4 }])] },
       at3.("descriptors item 0: uuid nil is not in Uuid_Formatter form")],
    ].each do |what, build, message|
      it "serialize refuses #{what}" do
        expect { described_class.serialize(instance_exec(&build)) }.to raise_error(ArgumentError, message)
      end
    end

    it "accepts a nil include uuid, the one uuid allowed to be unresolved" do
      text = described_class.serialize([entry(3, service_includes: [{ uuid: nil, start: 40, end: 45 }])])
      expect(text).to include('"service_includes":[{"uuid":null,"start":40,"end":45}]')
    end

    parse_msg = ->(text) { /\A#{Regexp.escape("GattCharacteristics.parse: #{text}")}/ }
    [
      ["text that is not JSON", -> { '[{"uuid":' }, parse_msg.("not valid JSON (")],
      ["a top-level object", -> { '{"value_handle":3}' }, parse_msg.("top level is Hash, not an Array")],
      ["a top-level null", -> { "null" }, parse_msg.("top level is NilClass, not an Array")],
      ["a hex-string value_handle", -> { JSON.generate([entry(3, value_handle: "0x0003")]) },
       parse_msg.('entry 0 has value_handle "0x0003", not an Integer in 0x0001..0xFFFF')],
      ["a key outside the schema", -> { JSON.generate([entry(3, raw_hex_truncate: true)]) },
       parse_msg.("entry at value_handle 0x0003: unknown keys [:raw_hex_truncate]")],
      ["a read entry without its value", -> { JSON.generate([entry(3, except: [:value])]) },
       parse_msg.('entry at value_handle 0x0003: value must be present exactly when read_status is "read"')],
    ].each do |what, build, message|
      it "parse refuses #{what}" do
        expect { described_class.parse(instance_exec(&build)) }.to raise_error(ArgumentError, message)
      end
    end

    it "fit_to_caps refuses a list serialize would refuse" do
      expect { described_class.fit_to_caps([entry(3, uuid: "0x2a00")]) }.to raise_error(
        ArgumentError,
        /\AGattCharacteristics\.fit_to_caps: entry at value_handle 0x0003: uuid "0x2a00" is not in Uuid_Formatter form/
      )
    end
  end

  describe ".merge_by_value_handle" do
    it "keeps every stored entry, lets the incoming entry win a shared value handle, ascending (Requirement 11.8)" do
      stored   = [entry(9, "not-read"), entry(3, "not-read"), entry(5, "not-read")]
      incoming = [entry(7), entry(5)]
      expect(described_class.merge_by_value_handle(stored, incoming))
        .to eq([entry(3, "not-read"), entry(5), entry(7), entry(9, "not-read")])
    end

    it "adds each resumed Walk's entries to what earlier ones stored" do
      first  = described_class.merge_by_value_handle([], [entry(5, "not-read"), entry(3)])
      second = described_class.merge_by_value_handle(first, [entry(9)])
      third  = described_class.merge_by_value_handle(second, [entry(5)])
      expect(third).to eq([entry(3), entry(5), entry(9)])
    end

    it "returns the other list in ascending order when one is empty, and [] for two" do
      expect(described_class.merge_by_value_handle([entry(9), entry(3)], [])).to eq([entry(3), entry(9)])
      expect(described_class.merge_by_value_handle([], [entry(9), entry(3)])).to eq([entry(3), entry(9)])
      expect(described_class.merge_by_value_handle([], [])).to eq([])
    end

    it "refuses a list that is not an Array or holds a non-Hash" do
      expect { described_class.merge_by_value_handle(nil, []) }.to raise_error(
        ArgumentError, "GattCharacteristics.merge_by_value_handle stored: NilClass is not an Array"
      )
      expect { described_class.merge_by_value_handle([], ["x"]) }.to raise_error(
        ArgumentError, "GattCharacteristics.merge_by_value_handle incoming: entry 0 is a String, not a Hash"
      )
    end

    it "refuses two entries for one value handle within either list" do
      expect { described_class.merge_by_value_handle([], [entry(5), entry(5, "not-read")]) }.to raise_error(
        ArgumentError, "GattCharacteristics.merge_by_value_handle incoming: value_handle 0x0005 appears more than once"
      )
      expect { described_class.merge_by_value_handle([entry(5), entry(5)], [entry(7)]) }.to raise_error(
        ArgumentError, "GattCharacteristics.merge_by_value_handle stored: value_handle 0x0005 appears more than once"
      )
    end
  end

  # Feature: gatt-service-scanning, Property 11: Merge by value handle keeps every stored entry and lets the newer win
  #
  # Validates: Requirements 11.8, 17.4
  #
  # Each case draws 0 to 30 distinct value handles from 0x0001..0xFFFF, both
  # bounds common, and gives each to the stored list, the incoming list or
  # both. The split is one of: all incoming (stored empty), all stored
  # (incoming empty), disjoint, all in both, or a mix in which stored-only,
  # incoming-only and shared handles interleave. Entries are built from the
  # design's entry schema as in Property 12: every read_status, each with only
  # the conditional keys it allows, every value_encoding, raw_hex or
  # raw_hex_truncated on a format or utf8 value, includes with and without a
  # resolved uuid, and keys inserted in schema, reversed or random order. At a
  # shared handle the incoming entry never equals the stored one. It is either
  # the same characteristic with a new read outcome, as when a resumed Walk
  # reads a value an earlier Walk left pending or reads it again, or an entry
  # built afresh. Each list comes in ascending, descending or random
  # value_handle order.
  #
  # The merge must hold exactly the union of the two lists' value handles, in
  # ascending order, with the incoming entry at each incoming handle and the
  # stored entry at each handle only the stored list holds. Merging the same
  # lists reversed must give the same list, and so must merging into the
  # stored list as the Device parses it back from its column. The merged
  # list's text must be the same on every serialize, and parse must return the
  # merged list from it. Both inputs are deep-frozen, so a merge that wrote to
  # either fails. The schema key order is restated here, not read from
  # KEY_ORDER. Every expectation derives from the printed lists, so a failing
  # case can be reproduced from rantly's output.
  it "Property 11: merge_by_value_handle keeps every stored entry, lets the incoming entry win, and sorts by value handle" do
    entry_keys     = %i[uuid service_uuid service_type service_start service_end service_includes
                        decl_handle value_handle properties descriptors read_status error_code
                        value value_encoding raw_hex raw_hex_truncated]
    outcome_keys   = %i[read_status error_code value value_encoding raw_hex raw_hex_truncated]
    property_names = %w[broadcast read write-without-response write notify indicate
                        authenticated-signed-writes extended-properties]
    read_statuses  = %w[read protected not-read not-readable error malformed]
    # A readable characteristic read again; read twice over, as a second read
    # usually succeeds.
    reread_statuses = %w[read read protected not-read error malformed]
    text_pieces     = ["a", "Z", "7", " ", "\"", "\\", "\u0000", "\n", "\u00e9", "\u2028", "\u{1f600}"]
    seen = Hash.new(0)

    # As in Property 12, the lambdas are created inside the generator so they
    # share rantly's self, and freq and array are given procs or blocks.
    property_of {
      pick   = ->(lo, hi) { freq([1, :literal, lo], [1, :literal, hi], [4, proc { range(lo, hi) }]) }
      handle = -> { pick.(0x0001, 0xFFFF) }
      hex    = ->(bytes) { array(bytes) { range(0x00, 0xFF) }.pack("C*").unpack1("H*") }
      text   = -> { array(pick.(0, 20)) { choose(*text_pieces) }.join }
      # a 16-bit or 128-bit UUID as UuidNames renders it, listed or Unknown
      uuid   = lambda do |role|
        spelled = freq([1, proc { range(0x0000, 0xFFFF) }], [1, proc { format("%032x", range(0, 2**128 - 1)) }])
        BlueHydra::UuidNames.render(role, spelled)
      end

      # hash with its keys inserted in schema, reversed or random order
      reorder = lambda do |hash|
        keys =
          case freq([1, :literal, :schema], [1, :literal, :reversed], [2, :literal, :random])
          when :schema   then hash.keys
          when :reversed then hash.keys.reverse
          else                hash.keys.sort_by { range(0, 2**30) }
          end
        keys.to_h { |key| [key, hash[key]] }
      end

      # The outcome keys of a read: read_status, then the conditional keys
      # that status allows.
      outcome = lambda do |statuses|
        status = choose(*statuses)
        result = { read_status: status }
        result[:error_code] = pick.(0x01, 0xFF) if %w[protected error].include?(status)
        if status == "read"
          kind = choose(:identity, :format, :utf8, :hex)
          case kind
          when :identity
            result[:value]          = text.()
            result[:value_encoding] = "identity"
          when :utf8
            result[:value]          = text.()
            result[:value_encoding] = "utf8"
          when :hex
            result[:value]          = hex.(pick.(0, 32))
            result[:value_encoding] = "hex"
          when :format
            type = choose("boolean", "uint8", "sint16", "utf8s")
            result[:value] =
              case type
              when "boolean" then choose("true", "false")
              when "uint8"   then range(0, 255).to_s
              when "sint16"  then range(-32_768, 32_767).to_s
              else                text.()
              end
            result[:value_encoding] = "format:#{type}#{';unit:0x27ad' if boolean}"
          end
          # a decode other than hex keeps the raw bytes, unless the cap removed them
          if %i[format utf8].include?(kind)
            if boolean
              result[:raw_hex] = hex.(pick.(0, 32))
            else
              result[:raw_hex_truncated] = true
            end
          end
        end
        result
      end

      build = lambda do |value_handle|
        result = outcome.(read_statuses)
        reorder.({
          uuid:             uuid.(:characteristic),
          service_uuid:     uuid.(:service),
          service_type:     choose("primary", "secondary"),
          service_start:    handle.(),
          service_end:      handle.(),
          service_includes: array(pick.(0, 2)) {
            reorder.({ uuid: freq([1, :literal, nil], [3, proc { uuid.(:service) }]),
                       start: handle.(), end: handle.() })
          },
          decl_handle:      handle.(),
          value_handle:     value_handle,
          # in bit order; read is set unless the characteristic is not readable
          properties:       property_names.select { |name|
            name == "read" ? result[:read_status] != "not-readable" : boolean
          },
          descriptors:      array(pick.(0, 2)) { reorder.({ uuid: uuid.(:descriptor), handle: handle.() }) },
        }.merge(result))
      end

      # The incoming entry for a handle the stored list holds too, drawn until
      # it differs from the stored entry. A characteristic that is not
      # readable has no other outcome to read, so its entry is built afresh.
      newer = lambda do |old|
        reread = old[:read_status] != "not-readable" && freq([3, :literal, true], [1, :literal, false])
        loop do
          fresh =
            if reread
              reorder.(old.reject { |key, _| outcome_keys.include?(key) }.merge(outcome.(reread_statuses)))
            else
              build.(old[:value_handle])
            end
          break fresh unless fresh == old
        end
      end

      count = freq([1, :literal, 0], [1, :literal, 1], [6, proc { range(2, 30) }])
      drawn = []
      drawn |= [handle.()] while drawn.size < count
      split = freq([1, :literal, :stored_empty], [1, :literal, :incoming_empty], [2, :literal, :disjoint],
                   [1, :literal, :identical], [3, :literal, :mixed])
      side = drawn.to_h { |h|
        [h, case split
            when :stored_empty   then :incoming
            when :incoming_empty then :stored
            when :identical      then :both
            when :disjoint       then choose(:stored, :incoming)
            else                      choose(:stored, :incoming, :both)
            end]
      }
      stored   = drawn.reject { |h| side[h] == :incoming }.to_h { |h| [h, build.(h)] }
      incoming = drawn.reject { |h| side[h] == :stored }.to_h { |h|
        [h, stored.key?(h) ? newer.(stored[h]) : build.(h)]
      }
      ordered = lambda do |entries|
        case freq([1, :literal, :ascending], [1, :literal, :descending], [2, :literal, :as_drawn])
        when :ascending  then entries.sort_by { |e| e[:value_handle] }
        when :descending then entries.sort_by { |e| -e[:value_handle] }
        else                  entries
        end
      end
      [ordered.(stored.values), ordered.(incoming.values)]
    # 200 rather than 100 for the coverage assertions below. The rarest is a
    # read value read again at a shared handle, about 1 case in 9, which 200
    # cases miss about once in 10^10 runs. The 200 cases take under 1 s.
    }.check(200) { |stored, incoming|
      # Frozen, so a merge that wrote to either list would fail here.
      deep_freeze.(stored)
      deep_freeze.(incoming)
      stored_at   = stored.to_h { |e| [e[:value_handle], e] }
      incoming_at = incoming.to_h { |e| [e[:value_handle], e] }
      union       = (stored_at.keys | incoming_at.keys).sort
      shared      = stored_at.keys & incoming_at.keys
      stored_only = stored_at.keys - incoming_at.keys

      (stored + incoming).each do |e|
        seen[e[:read_status].to_sym] += 1
        seen[e[:value_encoding].split(":").first.to_sym] += 1 if e.key?(:value_encoding)
        seen[:raw_hex] += 1 if e.key?(:raw_hex)
        seen[:raw_hex_truncated] += 1 if e.key?(:raw_hex_truncated)
        seen[:keys_reordered] += 1 if e.keys != entry_keys.select { |key| e.key?(key) }
      end
      seen[:stored_empty] += 1 if stored.empty?
      seen[:incoming_empty] += 1 if incoming.empty?
      seen[:both_empty] += 1 if stored.empty? && incoming.empty?
      seen[:disjoint] += 1 if stored.any? && incoming.any? && shared.empty?
      seen[:partial_overlap] += 1 if shared.any? && union.size > shared.size
      seen[:every_stored_replaced] += 1 if stored.any? && stored_only.empty?
      seen[:stored_kept] += 1 if incoming.any? && stored_only.any?
      # stored-only, incoming-only and shared runs alternate at least twice
      seen[:interleaved] += 1 if union.chunk_while { |a, b| stored_at.key?(a) == stored_at.key?(b) &&
                                                            incoming_at.key?(a) == incoming_at.key?(b) }.count >= 3
      seen[:stored_out_of_order] += 1 if handles(stored) != handles(stored).sort
      seen[:incoming_out_of_order] += 1 if handles(incoming) != handles(incoming).sort
      seen[:handle_0x0001] += 1 if union.include?(0x0001)
      seen[:handle_0xffff] += 1 if union.include?(0xFFFF)
      shared.each do |h|
        before, after = stored_at[h], incoming_at[h]
        seen[:shared_differs] += 1 if after != before
        same_characteristic = before.reject { |key, _| outcome_keys.include?(key) } ==
                              after.reject { |key, _| outcome_keys.include?(key) }
        seen[same_characteristic ? :reread : :rebuilt] += 1
        seen[:status_changed] += 1 if after[:read_status] != before[:read_status]
        seen[:pending_read_completed] += 1 if before[:read_status] == "not-read" && after[:read_status] == "read"
        seen[:read_again] += 1 if before[:read_status] == "read" && after[:read_status] == "read"
      end

      merged = described_class.merge_by_value_handle(stored, incoming)
      expect(handles(merged)).to eq(union)
      merged_at = merged.to_h { |e| [e[:value_handle], e] }
      incoming_at.each { |h, e| expect(merged_at[h]).to eq(e) }
      stored_only.each { |h| expect(merged_at[h]).to eq(stored_at[h]) }

      expect(described_class.merge_by_value_handle(stored.reverse, incoming.reverse)).to eq(merged)

      text = described_class.serialize(merged)
      expect(described_class.serialize(merged)).to eq(text)
      expect(described_class.parse(text)).to eq(merged)
      # The Device merges into the stored column as parse returns it.
      from_column = described_class.merge_by_value_handle(described_class.parse(described_class.serialize(stored)),
                                                          incoming)
      expect(described_class.serialize(from_column)).to eq(text)
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect(%i[read protected not-read not-readable error malformed identity format utf8 hex
              raw_hex raw_hex_truncated keys_reordered
              stored_empty incoming_empty both_empty disjoint partial_overlap every_stored_replaced stored_kept
              interleaved stored_out_of_order incoming_out_of_order handle_0x0001 handle_0xffff
              shared_differs reread rebuilt status_changed pending_read_completed read_again] - seen.keys).to eq([])
  end

  describe ".union_service_uuids" do
    unknown16 = ->(uuid) { format("Unknown (0x%04x)", uuid) }

    it "keeps one entry per UUID in ascending 128-bit order, not text order (Requirement 11.5)" do
      stored   = ["Nordic UART Service (6e400001-b5a3-f393-e0a9-e50e24dcca9e)", "Generic Access (0x1800)"]
      incoming = ["Battery Service (0x180f)", "Generic Access (0x1800)",
                  "Unknown (00000001-0000-0000-0000-000000000000)"]
      expect(described_class.union_service_uuids(stored, incoming)).to eq(
        [["Unknown (00000001-0000-0000-0000-000000000000)", "Generic Access (0x1800)",
          "Battery Service (0x180f)", "Nordic UART Service (6e400001-b5a3-f393-e0a9-e50e24dcca9e)"], 0]
      )
    end

    it "keeps the stored rendering of a UUID the incoming list names differently" do
      expect(described_class.union_service_uuids(["Unknown (0x185b)"], ["Ranging Service (RAS) (0x185b)"]))
        .to eq([["Unknown (0x185b)"], 0])
    end

    it "keeps the first rendering of a UUID within one list" do
      expect(described_class.union_service_uuids([], ["Unknown (0x185b)", "Ranging Service (RAS) (0x185b)"]))
        .to eq([["Unknown (0x185b)"], 0])
    end

    it "leaves a stored list byte-identical for a result that adds no UUID" do
      stored = ["Generic Access (0x1800)", "Battery Service (0x180f)"]
      list, dropped = described_class.union_service_uuids(stored, ["Battery Service (0x180f)"])
      expect(JSON.generate(list)).to eq(JSON.generate(stored))
      expect(dropped).to eq(0)
    end

    it "stores the first 1,000 of 1,001 entries in ascending order and reports 1 dropped (Requirement 11.17)" do
      stored   = (0x0002..0x03e9).map(&unknown16)
      incoming = [unknown16.(0x0001)]
      list, dropped = described_class.union_service_uuids(stored, incoming)
      expect(list).to eq((0x0001..0x03e8).map(&unknown16))
      expect(list.size).to eq(1_000)
      expect(list).not_to include(unknown16.(0x03e9))
      expect(dropped).to eq(1)
    end

    it "drops nothing at exactly 1,000 entries" do
      list, dropped = described_class.union_service_uuids((0x0001..0x0300).map(&unknown16),
                                                          (0x0200..0x03e8).map(&unknown16))
      expect(list).to eq((0x0001..0x03e8).map(&unknown16))
      expect(dropped).to eq(0)
    end

    it "refuses a list that is not an Array" do
      expect { described_class.union_service_uuids(nil, []) }.to raise_error(
        ArgumentError, "GattCharacteristics.union_service_uuids stored: NilClass is not an Array"
      )
      expect { described_class.union_service_uuids([], "Generic Access (0x1800)") }.to raise_error(
        ArgumentError, "GattCharacteristics.union_service_uuids incoming: String is not an Array"
      )
    end

    [
      ["a bare uuid", "0x180f"],
      ["an upper-case uuid", "Generic Access (0X1800)"],
      ["a uuid on the Base UUID left unfolded", "Generic Access (00001800-0000-1000-8000-00805f9b34fb)"],
      ["a Symbol", :"Generic Access (0x1800)"],
    ].each do |what, bad|
      it "refuses an entry that is #{what}" do
        expect { described_class.union_service_uuids(["Generic Access (0x1800)", bad], []) }.to raise_error(
          ArgumentError,
          "GattCharacteristics.union_service_uuids stored: entry 1 #{bad.inspect} is not in Uuid_Formatter form"
        )
      end
    end
  end

  # Feature: gatt-service-scanning, Property 10: Service UUID union is ordered, de-duplicated and idempotent
  #
  # Validates: Requirements 11.5, 12.7
  #
  # Each case draws a pool of distinct service UUIDs and builds a stored and
  # an incoming list from it, so the two share UUIDs and repeat them. The
  # UUIDs are Nordic-listed services at both widths, 16-bit UUIDs, 32-bit
  # UUIDs on the Base (which stay 128-bit), random 128-bit UUIDs, 128-bit
  # UUIDs one below or above a 16-bit UUID's Base spelling, and 128-bit UUIDs
  # whose upper 64 bits are zero, which sort before every UUID on the Base.
  # Each occurrence is rendered as UuidNames renders the service, as Unknown,
  # or under another Nordic name, parenthesised and non-ASCII ones among them.
  # One UUID can therefore appear under several renderings in either list, as
  # after a Nordic database update. The stored list is empty, as the union
  # writes it (distinct UUIDs ascending, one rendering each), or any list of
  # the pool's renderings. One case in three is a cap case: 950 to 1,100
  # distinct UUIDs, 1,000 and 1,001 among them, split between a stored list as
  # written and an incoming list.
  #
  # The expected list follows from the 128-bit value the generator drew for
  # each entry, not from UuidNames.sort_key: each distinct value under its
  # first rendering in stored-then-incoming order, ascending by value, the
  # first 1,000 kept and the rest counted as dropped. The union's JSON text,
  # parsed back as the stored column would be, is then given the same
  # incoming list again, and a replay list of renderings of UUIDs the union
  # kept, in any order, repeated and renamed. Both must leave the text
  # byte-identical, the replay dropping nothing (Requirement 12.7). Every
  # expectation derives from the printed case, so a failing case can be
  # reproduced from rantly's output.
  it "Property 10: union_service_uuids keeps one entry per UUID in 128-bit order, and re-applying it changes nothing" do
    # 00000000-0000-1000-8000-00805f9b34fb, the Bluetooth Base UUID. A 16- or
    # 32-bit UUID sits in its bits 96 and up.
    base_uuid = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb
    nordic = BlueHydra::UuidNames::FILES.to_h do |role, file|
      [role, JSON.parse(File.read(File.join(BlueHydra::UuidNames::DATA_DIR, file), encoding: Encoding::UTF_8))]
    end
    listed              = nordic[:service].map { |e| e["uuid"] }
    names               = nordic.values.flatten.map { |e| e["name"] }.uniq
    parenthesised_names = names.select { |name| name.include?("(") }
    non_ascii_names     = names.reject(&:ascii_only?)
    seen = Hash.new(0)

    # As in Property 12, the lambdas are created inside the generator so they
    # share rantly's self, and freq and array are given procs or blocks.
    property_of {
      tags = []
      shuffle = ->(list) { list.sort_by { range(0, 2**30) } }

      # A UUID's 128-bit value.
      uuid_value = lambda do
        kind = freq([3, :literal, :listed_uuid], [3, :literal, :bits16], [1, :literal, :bits32],
                    [2, :literal, :bits128], [1, :literal, :near_base], [1, :literal, :low128])
        tags << kind
        case kind
        when :listed_uuid
          hex = choose(*listed).delete("-").downcase
          hex.length == 4 ? base_uuid | (hex.to_i(16) << 96) : hex.to_i(16)
        when :bits16    then base_uuid | (range(0x0000, 0xFFFF) << 96)
        when :bits32    then base_uuid | (range(0x1_0000, 0xFFFF_FFFF) << 96)
        when :bits128   then range(0, 2**128 - 1)
        # beside a 16-bit UUID in 128-bit order, but not on the Base
        when :near_base then (base_uuid | (range(0x0000, 0xFFFF) << 96)) + choose(-1, 1)
        when :low128    then range(0, 2**64 - 1)
        end
      end

      # [rendering, value]. render is given all 32 hex digits, so a 16-bit
      # UUID reaches it in its Base spelling and must fold.
      render_as = lambda do |value|
        rendered = BlueHydra::UuidNames.render(:service, format("%032x", value))
        uuid = rendered[/\(([^()]+)\)\z/, 1]
        kind = freq([4, :literal, :service_render], [1, :literal, :unknown_rendering], [2, :literal, :other_name])
        tags << kind
        case kind
        when :unknown_rendering then rendered = "Unknown (#{uuid})"
        when :other_name
          name = freq([1, proc { choose(*parenthesised_names) }], [1, proc { choose(*non_ascii_names) }],
                      [4, proc { choose(*names) }])
          rendered = "#{name} (#{uuid})"
        end
        tags << (uuid.start_with?("0x") ? :uuid16 : :uuid128)
        tags << (rendered.start_with?("Unknown (") ? :unknown_name : :named)
        tags << :parenthesised_name if rendered.count("(") > 1
        tags << :non_ascii_name unless rendered.ascii_only?
        [rendered, value]
      end

      cap = freq([1, :literal, true], [2, :literal, false])
      size =
        if cap then freq([1, :literal, 1_000], [1, :literal, 1_001], [1, proc { range(950, 1_100) }])
        else        freq([2, proc { range(1, 6) }], [1, proc { range(7, 60) }])
        end
      pool = {}
      pool[uuid_value.()] = true while pool.size < size
      pool = pool.keys
      draw = -> { render_as.(pool[range(0, pool.size - 1)]) }
      # the column as the union writes it: distinct values ascending, one rendering each
      as_written = ->(values) { values.sort.map { |value| render_as.(value) } }

      if cap
        tags << :stored_as_written
        mixed    = shuffle.(pool)
        split    = range(0, [size, 1_000].min)
        stored   = as_written.(mixed.first(split))
        repeats  = array(range(0, 50)) { pool[range(0, size - 1)] }
        incoming = shuffle.(mixed.drop(split) + repeats).map { |value| render_as.(value) }
      else
        kind = choose(:stored_none, :stored_as_written, :stored_arbitrary)
        tags << kind
        stored =
          case kind
          when :stored_none       then []
          when :stored_as_written then as_written.(pool.select { boolean })
          else                         array(range(1, 2 * size)) { draw.() }
          end
        incoming = array(freq([1, :literal, 0], [3, proc { range(1, 2 * size) }])) { draw.() }
      end
      replay = array(range(0, 2 * [size, 60].min)) { draw.() }
      [stored, incoming, replay, tags.uniq]
    # The rarest tag is a cap case of exactly 1,000 UUIDs, 1 case in 9, so 200
    # cases miss it fewer than once in 10^10 runs. The cap cases take most of
    # the 200 cases' 2.5 s.
    }.check(200) { |stored, incoming, replay, tags|
      tags.each { |tag| seen[tag] += 1 }
      # Frozen, so a union that wrote to its input would fail here.
      stored_texts   = deep_freeze.(stored.map(&:first))
      incoming_texts = deep_freeze.(incoming.map(&:first))

      first_rendering = {}
      (stored + incoming).each { |rendered, value| first_rendering[value] ||= rendered }
      values   = first_rendering.keys.sort
      kept     = values.first(1_000).to_h { |value| [value, first_rendering[value]] }
      expected = kept.values

      by_value = ->(list) { list.group_by(&:last).transform_values { |pairs| pairs.map(&:first) } }
      stored_by_value   = by_value.(stored)
      incoming_by_value = by_value.(incoming)
      replayed          = replay.select { |_, value| kept.key?(value) }
      seen[:stored_empty] += 1 if stored.empty?
      seen[:incoming_empty] += 1 if incoming.empty?
      seen[:repeated_in_stored] += 1 if stored_by_value.size < stored.size
      seen[:repeated_in_incoming] += 1 if incoming_by_value.size < incoming.size
      seen[:shared] += 1 if (stored_by_value.keys & incoming_by_value.keys).any?
      seen[:renamed] += 1 if incoming_by_value.any? { |value, renderings|
        stored_by_value.key?(value) && (renderings - [stored_by_value[value].first]).any?
      }
      seen[:renamed_within_list] += 1 if [stored_by_value, incoming_by_value].any? { |h|
        h.each_value.any? { |renderings| renderings.uniq.size > 1 }
      }
      seen[:text_order_differs] += 1 if expected != expected.sort
      seen[%i[under_cap at_cap over_cap][(values.size <=> 1_000) + 1]] += 1
      seen[:stored_entry_dropped] += 1 if stored_by_value.keys.any? { |value| !kept.key?(value) }
      seen[:replay_nonempty] += 1 if replayed.any?
      seen[:replay_renamed] += 1 if replayed.any? { |rendered, value| rendered != kept[value] }

      list, dropped = described_class.union_service_uuids(stored_texts, incoming_texts)
      expect(list).to eq(expected)
      expect(dropped).to eq(values.size - kept.size)

      # The column holds the union's JSON text, and the next result is merged
      # into what the Device parses back from it.
      text = JSON.generate(list)
      again = described_class.union_service_uuids(JSON.parse(text), incoming_texts).first
      expect(JSON.generate(again)).to eq(text)

      replay_list, replay_dropped =
        described_class.union_service_uuids(JSON.parse(text), deep_freeze.(replayed.map(&:first)))
      expect(JSON.generate(replay_list)).to eq(text)
      expect(replay_dropped).to eq(0)
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect(%i[listed_uuid bits16 bits32 bits128 near_base low128
              service_render unknown_rendering other_name uuid16 uuid128 named unknown_name
              parenthesised_name non_ascii_name stored_as_written stored_arbitrary stored_empty incoming_empty
              repeated_in_stored repeated_in_incoming shared renamed renamed_within_list text_order_differs
              under_cap at_cap over_cap stored_entry_dropped replay_nonempty replay_renamed] - seen.keys).to eq([])
  end

  describe ".fit_to_caps" do
    # The byte counts below are computed from cap_text. This pins cap_text to
    # what serialize writes, so the counts are what the subject measures.
    it "measures entries as the cap examples compute them" do
      expect(cap_text(101, value_len: 0, raw_hex_len: 0).bytesize - cap_text(101, value_len: 0).bytesize).to eq(13)
      expect(cap_text(101, value_len: 0, truncated: true).bytesize - cap_text(101, value_len: 0).bytesize).to eq(25)
      expect(cap_text(101, value_len: 0).bytesize).to eq(289)
      expect(cap_text(1001).bytesize).to eq(260)
      [[101, nil, nil], [1001, nil, nil], [101, 0, nil], [102, 7, 3], [1500, 46, 50]].each do |h, v, r|
        expect(described_class.serialize([cap_entry(h, value_len: v, raw_hex_len: r)]))
          .to eq("[#{cap_text(h, value_len: v, raw_hex_len: r)}]")
      end
      expect(described_class.serialize([stripped(cap_entry(102, value_len: 7, raw_hex_len: 3))]))
        .to eq("[#{cap_text(102, value_len: 7, truncated: true)}]")
      expect(described_class.serialize([entry_of_size(103, 55_555, raw_hex: 444)]).bytesize).to eq(55_557)
    end

    it "returns a list within both caps as the same Array, unsorted, with zero stats" do
      list = [entry(9), entry(3, "not-read")]
      result, stats = described_class.fit_to_caps(list)
      expect(result).to be(list)
      expect(stats).to eq(bytes_before: described_class.serialize(list).bytesize,
                          bytes_after: described_class.serialize(list).bytesize,
                          raw_hex_removed: 0, entries_dropped: 0)
    end

    it "returns an empty list as it is" do
      list = []
      expect(described_class.fit_to_caps(list)).to eq([list, { bytes_before: 2, bytes_after: 2,
                                                               raw_hex_removed: 0, entries_dropped: 0 }])
      expect(described_class.fit_to_caps(list).first).to be(list)
    end

    # Requirement 16.15's worked example, in two parts. Every list below is
    # passed out of order and must come back ascending.
    it "removes raw_hex largest-first, the higher value handle first on a tie, and drops nothing while that fits" do
      # value_handle => [serialised entry bytes, raw_hex characters]
      sizes = { 101 => [60_000, 5_000], 102 => [50_000, 2_000], 103 => [50_000, 3_000],
                104 => [50_000, 1_000], 105 => [58_138, 3_000] }
      list  = [103, 105, 101, 104, 102].map { |h| entry_of_size(h, sizes[h][0], raw_hex: sizes[h][1]) }
      # 268,138 bytes of entries + 4 commas + 2 brackets = 268,144, 6,000 over.
      # Removing a raw_hex of n characters shrinks the text by n - 12: the
      # 13-byte ,"raw_hex":"" and its hex go, the 25-byte marker comes.
      #   101's 5,000 first, though lowest handle: 268,144 - 4,988 = 263,156, still over
      #   105's 3,000 next, before 103's equal 3,000: 263,156 - 2,988 = 260,168, fits
      # 103, 102 and 104 keep theirs, and no entry is dropped, though dropping
      # 105 alone would also have fitted.
      result, stats = described_class.fit_to_caps(list)

      by_handle = list.to_h { |e| [e[:value_handle], e] }
      expect(result).to eq([stripped(by_handle[101]), by_handle[102], by_handle[103],
                            by_handle[104], stripped(by_handle[105])])
      expect(result.map { |e| e[:raw_hex]&.length }).to eq([nil, 2_000, 3_000, 1_000, nil])
      expect(result.map { |e| e[:raw_hex_truncated] }).to eq([true, nil, nil, nil, true])
      expect(stats).to eq(bytes_before: 268_144, bytes_after: 260_168, raw_hex_removed: 2, entries_dropped: 0)
      expect(described_class.serialize(result).bytesize).to eq(260_168)
    end

    it "removes every raw_hex before dropping any entry, then drops from the highest value handle down" do
      # value_handle => [serialised entry bytes, raw_hex characters]. Once its
      # raw_hex is removed an entry is 12 - n bytes larger: 101 to 104 are
      # 60,000 bytes each, 105 is 30,000 and 106 is 1,000.
      sizes = { 101 => [60_088, 100], 102 => [60_588, 600], 103 => [60_288, 300],
                104 => [60_000, nil], 105 => [30_488, 500], 106 => [1_188, 200] }
      list  = [104, 106, 102, 101, 105, 103].map { |h| entry_of_size(h, sizes[h][0], raw_hex: sizes[h][1]) }
      # 272,640 bytes of entries + 7 = 272,647. With every raw_hex removed:
      #   4 x 60,000 + 30,000 + 1,000 + 7 = 271,007, still over
      #   drop 106: 270,006, still over, though it is the smallest entry
      #   drop 105: 4 x 60,000 + 5 = 240,005, fits
      # Dropping 105 alone, or the largest entry, would have fitted too; the
      # rule is the highest value handle. 105 and 106 had their raw_hex
      # removed before being dropped, so raw_hex_removed counts only the three
      # markers left in the stored text.
      result, stats = described_class.fit_to_caps(list)

      by_handle = list.to_h { |e| [e[:value_handle], e] }
      expect(handles(result)).to eq([101, 102, 103, 104])
      expect(result).to eq([stripped(by_handle[101]), stripped(by_handle[102]), stripped(by_handle[103]),
                            by_handle[104]])
      expect(result[3]).not_to have_key(:raw_hex_truncated)
      expect(stats).to eq(bytes_before: 272_647, bytes_after: 240_005, raw_hex_removed: 3, entries_dropped: 2)
      expect(described_class.serialize(result).bytesize).to eq(240_005)
    end

    it "removes a raw_hex too short to shrink the text before dropping any entry" do
      # 101's 2-character raw_hex: removing it grows the entry from 400 to 410
      # bytes, and Requirement 11.19 still has it go before 102 is dropped.
      list = [entry_of_size(102, 262_000), entry_of_size(101, 400, raw_hex: 2)]
      result, stats = described_class.fit_to_caps(list)
      expect(result).to eq([stripped(list[1])])
      expect(stats).to eq(bytes_before: 262_403, bytes_after: 412, raw_hex_removed: 1, entries_dropped: 1)
    end

    it "drops an entry too large on its own, leaving an empty list" do
      result, stats = described_class.fit_to_caps([entry_of_size(101, 262_143)])
      expect(result).to eq([])
      expect(stats).to eq(bytes_before: 262_145, bytes_after: 2, raw_hex_removed: 0, entries_dropped: 1)
    end

    it "keeps a text of exactly 262,144 bytes as it is, raw_hex and all" do
      list = [entry_of_size(101, 262_142, raw_hex: 13)]
      result, stats = described_class.fit_to_caps(list)
      expect(result).to be(list)
      expect(result[0][:raw_hex].length).to eq(13)
      expect(stats).to eq(bytes_before: 262_144, bytes_after: 262_144, raw_hex_removed: 0, entries_dropped: 0)
    end

    it "trims a text of 262,145 bytes to exactly 262,144 by removing one 13-character raw_hex" do
      list = [entry_of_size(101, 262_143, raw_hex: 13)]
      result, stats = described_class.fit_to_caps(list)
      expect(result).to eq([stripped(list[0])])
      expect(stats).to eq(bytes_before: 262_145, bytes_after: 262_144, raw_hex_removed: 1, entries_dropped: 0)
    end

    it "keeps exactly 1,000 entries as they are" do
      list = (1001..2000).map { |h| cap_entry(h) }
      result, stats = described_class.fit_to_caps(list)
      expect(result).to be(list)
      # 1,000 entries of 260 bytes + 999 commas + 2 brackets
      expect(stats).to eq(bytes_before: 261_001, bytes_after: 261_001, raw_hex_removed: 0, entries_dropped: 0)
    end

    it "drops only the highest value handle from 1,001 entries within the byte cap, removing no raw_hex" do
      raw = { 1500 => entry_of_size(1500, 400, raw_hex: 50), 2001 => entry_of_size(2001, 400, raw_hex: 50) }
      list = (1001..2001).map { |h| raw[h] || cap_entry(h) }.reverse
      # 999 x 260 + 2 x 400 + 1,002 = 261,542, within the byte cap; the entry
      # cap alone drops 2001, raw_hex and all: 999 x 260 + 400 + 1,001 = 261,141.
      result, stats = described_class.fit_to_caps(list)
      expect(handles(result)).to eq((1001..2000).to_a)
      expect(result[499]).to eq(raw[1500])
      expect(result).to all(satisfy { |e| !e.key?(:raw_hex_truncated) })
      expect(stats).to eq(bytes_before: 261_542, bytes_after: 261_141, raw_hex_removed: 0, entries_dropped: 1)
      expect(described_class.serialize(result).bytesize).to eq(261_141)
    end

    it "removes raw_hex before dropping any entry when over both caps" do
      raw = { 1500 => entry_of_size(1500, 2_400, raw_hex: 2_000), 2001 => entry_of_size(2001, 2_400, raw_hex: 2_000) }
      list = (1001..2001).map { |h| raw[h] || cap_entry(h) }
      # 999 x 260 + 2 x 2,400 + 1,002 = 265,542. Both raw_hex go, each saving
      # 1,988: 263,554, then 261,566. Only then does the entry cap drop 2001:
      # 999 x 260 + 412 + 1,001 = 261,153. Dropping for size first would have
      # taken 2001 down to 1997 and kept 1500's raw_hex.
      result, stats = described_class.fit_to_caps(list)
      expect(handles(result)).to eq((1001..2000).to_a)
      expect(result[499]).to eq(stripped(raw[1500]))
      expect(stats).to eq(bytes_before: 265_542, bytes_after: 261_153, raw_hex_removed: 1, entries_dropped: 1)
    end

    it "takes an equal-length raw_hex from the entry the entry cap then drops" do
      raw = { 1500 => entry_of_size(1500, 900, raw_hex: 500), 2001 => entry_of_size(2001, 900, raw_hex: 500) }
      list = (1001..2001).map { |h| raw[h] || cap_entry(h) }
      # 999 x 260 + 2 x 900 + 1,002 = 262,542, 398 over. Removing 2001's
      # raw_hex, the higher handle of the tie, saves 488 and fits; the entry
      # cap then drops 2001, so the kept list loses no raw_hex at all.
      result, stats = described_class.fit_to_caps(list)
      expect(handles(result)).to eq((1001..2000).to_a)
      expect(result[499]).to eq(raw[1500])
      expect(stats).to eq(bytes_before: 262_542, bytes_after: 261_641, raw_hex_removed: 0, entries_dropped: 1)
    end
  end

  # Feature: gatt-service-scanning, Property 13: Caps are met by removing raw_hex largest-first before dropping entries from the top handle down
  #
  # Validates: Requirements 11.18, 11.19
  #
  # Each case is a list of entries built as the cap examples build theirs:
  # not-read entries, and read ones whose value has a drawn length and which
  # carry a raw_hex of drawn length, no raw_hex, or raw_hex_truncated as an
  # earlier cap left them. Each case reuses a few raw_hex lengths, so equal
  # lengths, which value handle settles, are common, and lengths of 12 or
  # fewer, whose removal does not shrink the text, come up too. A case is up
  # to 20 small entries, always within both caps; 1 to 12 large ones, about
  # the byte cap; or 1,000 to 1,060 entries on dense value handles, mostly
  # not-read with a few read ones anywhere and near the top handles
  # especially. Those are exactly 1,000 within the byte cap or over it, 1,001
  # to 1,003 over the entry cap alone, or over both caps, two kinds of them
  # just over the byte cap by design (see aim below). In all but the small
  # cases the lowest-handle entry's value is sized so that one measure lands
  # on 262,144 bytes, a byte either side or near it: the list as given, the
  # list less its first j raw_hex in removal order, or its first m entries
  # with every raw_hex removed. Or that value is drawn up to twice the byte
  # cap, so the entry alone may not fit. Entries come in ascending,
  # descending or random value_handle order.
  #
  # The expected result follows from the sizes the cap examples compute for
  # the drawn entries, not from the subject: the list as passed when it is
  # within both caps; otherwise, in ascending value_handle, the list less
  # the fewest raw_hex in removal order (longest first, the higher value
  # handle first on a tie) that bring it within the byte cap, or less all of
  # them, cut to its longest prefix within both caps. The stats follow from
  # the same sizes.
  #
  # The design's clauses are then checked on the result itself, with
  # serialize as the measure. Both caps are met, and bytes_before and
  # bytes_after are the input's and the result's text. The dropped entries
  # are the highest value handles. Each kept entry is as given or has traded
  # its raw_hex for raw_hex_truncated: true, and every raw_hex removed ranks
  # before every raw_hex kept. No raw_hex is removed when only the entry cap
  # is exceeded, and an entry is dropped for size only once no raw_hex
  # remains and only while the next one would not fit. The result is not
  # over-trimmed: put the last raw_hex removed back, remove every one ranked
  # before it, and the whole list is over the byte cap. Nor is removal cut
  # short: remove every raw_hex ranked before the first one kept and the
  # whole list fits, when that one is over 12 characters so that each
  # removal ahead of it shrank the text. The input is deep-frozen. Every
  # expectation derives from the printed specs, so a failing case can be
  # reproduced from rantly's output.
  it "Property 13: fit_to_caps meets both caps, removing raw_hex largest-first before dropping from the top handle" do
    max_bytes   = 262_144
    max_entries = 1_000
    # cap_text's fixed part at a value handle: a not-read entry, and a read
    # one with an empty value. The digits of the two handles set it.
    not_read_bytes = Hash.new { |memo, h| memo[h] = cap_text(h).bytesize }
    read_bytes     = Hash.new { |memo, h| memo[h] = cap_text(h, value_len: 0).bytesize }

    # A case is a list of specs, [value_handle, kind, value_len, raw_hex_len],
    # kind one of :not_read, :plain (a read value, no raw_hex), :raw_hex and
    # :truncated, so that rantly prints a failing case compactly. The lambdas
    # below are created outside the generator and run with the example's
    # self, so the generator can use them as well as the assertion. build
    # deep-freezes each entry, and builds a not-read one, which depends on
    # its handle alone, once per handle.
    not_read_entry = Hash.new { |memo, h| memo[h] = deep_freeze.(cap_entry(h)) }
    build = lambda do |(h, kind, value_len, raw_hex_len)|
      case kind
      when :not_read  then not_read_entry[h]
      when :plain     then deep_freeze.(cap_entry(h, value_len: value_len))
      when :raw_hex   then deep_freeze.(cap_entry(h, value_len: value_len, raw_hex_len: raw_hex_len))
      when :truncated then deep_freeze.(cap_entry(h, value_len: value_len).merge(raw_hex_truncated: true))
      end
    end
    # The serialised size of a spec's entry: ,"raw_hex":"" is 13 bytes and
    # ,"raw_hex_truncated":true 25, as the cap examples measure them.
    size_of = lambda do |(h, kind, value_len, raw_hex_len)|
      case kind
      when :not_read  then not_read_bytes[h]
      when :plain     then read_bytes[h] + value_len
      when :raw_hex   then read_bytes[h] + value_len + 13 + raw_hex_len
      when :truncated then read_bytes[h] + value_len + 25
      end
    end
    # ... and once any raw_hex is removed
    bare_size_of = ->(spec) { spec[1] == :raw_hex ? size_of.([spec[0], :truncated, spec[2]]) : size_of.(spec) }
    # "[", the entries joined by ",", "]"
    list_bytes = ->(sizes) { sizes.empty? ? 2 : sizes.sum + sizes.size + 1 }
    # Indexes of the raw_hex holders among specs in removal order: longest
    # raw_hex first, the higher value handle first on a tie.
    removal_order = lambda do |specs|
      specs.each_index.select { |i| specs[i][1] == :raw_hex }.sort_by { |i| [-specs[i][3], -specs[i][0]] }
    end
    seen = Hash.new(0)

    # As in Property 12, the lambdas that call rantly are created inside the
    # generator, and freq and array are given procs or blocks.
    property_of {
      pick = ->(lo, hi) { freq([1, :literal, lo], [1, :literal, hi], [4, proc { range(lo, hi) }]) }

      # What the case aims at. :small is within both caps and :large about
      # the byte cap. The rest are about 1,000 entries: :within_1000 is
      # exactly 1,000 within the byte cap, :over_1000 1,000 over it,
      # :entry_cap 1,001 to 1,003 within it, and :both_caps 1,001 to 1,060
      # over both. Two more are 1,001 entries just over the byte cap, where
      # removing the longest raw_hex is enough. In :twin the top handle and
      # a lower one carry it, of equal length: the top one's goes, as its
      # handle is higher, and the entry cap then drops its entry, so the
      # kept list loses no raw_hex. In :kept_first the top entry has none, so
      # a kept entry loses its raw_hex, though dropping the top entry for the
      # entry cap would have fitted on its own: raw_hex goes first.
      aim  = freq([6, :literal, :small], [19, :literal, :large], [2, :literal, :within_1000],
                  [2, :literal, :over_1000], [2, :literal, :entry_cap], [1, :literal, :both_caps],
                  [2, :literal, :twin], [2, :literal, :kept_first])
      many = !%i[small large].include?(aim)
      n =
        case aim
        when :small                   then freq([1, :literal, 0], [1, proc { range(1, 20) }])
        when :large                   then freq([1, :literal, 1], [4, proc { range(2, 12) }])
        when :within_1000, :over_1000 then 1_000
        when :entry_cap               then range(1_001, 1_003)
        when :both_caps               then freq([1, :literal, 1_001], [2, proc { range(1_002, 1_060) }])
        else                               1_001
        end
      handles =
        if many
          # Dense, so that 1,003 entries fit in the byte cap: a not-read one
          # is 254 to 260 bytes below handle 10,000.
          last = range(0, 40)
          Array.new(n) { last += freq([12, :literal, 1], [1, proc { range(2, 4) }]) }
        else
          drawn = []
          drawn |= [pick.(0x0001, 0xFFFF)] while drawn.size < n
          drawn.sort
        end
      # the longest value or raw_hex drawn, in characters
      most    = { small: 2_000, large: max_bytes / [n, 1].max / 2 }.fetch(aim, 100)
      # each case reuses a few raw_hex lengths, so that equal lengths are common
      palette = array(range(1, 3)) { freq([1, proc { range(0, 13) }], [2, proc { range(14, most) }]) }
      spec_for = lambda do |h, kind|
        case kind
        when :not_read then [h, :not_read]
        when :raw_hex  then [h, :raw_hex, range(0, most), freq([3, proc { choose(*palette) }], [1, proc { range(0, most) }])]
        else                [h, kind, range(0, most)]
        end
      end
      read_kind = -> { freq([4, :literal, :raw_hex], [1, :literal, :plain], [1, :literal, :truncated]) }

      specs =
        if many
          # mostly not-read, with a few read entries anywhere and near the top handles especially
          at = array(range(1, 6)) {
            freq([1, :literal, n - 1], [1, proc { range(n - 30, n - 1) }], [2, proc { range(1, n - 1) }])
          }
          handles.each_with_index.map { |h, i| spec_for.(h, at.include?(i) ? read_kind.() : :not_read) }
        else
          handles.map { |h| spec_for.(h, freq([1, :literal, :not_read], [5, proc { read_kind.() }])) }
        end
      case aim
      when :twin       then [-1, range(1, n - 31)].each { |i| specs[i] = [handles[i], :raw_hex, range(0, most), most] }
      when :kept_first then specs[-1] = spec_for.(handles[-1], freq([1, :literal, :not_read], [1, :literal, :plain]))
      end

      # The lowest-handle entry's value is sized so that one measure lands
      # on or near 262,144 bytes. Its value is in every measure and is never
      # removed, so changing it shifts each measure by as much.
      unless aim == :small
        # :entry_cap keeps a raw_hex here, as the entry cap alone removes
        # none, and :kept_first has one to remove.
        kind     = %i[entry_cap kept_first].include?(aim) ? :raw_hex : choose(:plain, :raw_hex)
        specs[0] = spec_for.(specs[0][0], kind)
        # one long enough that removing the longest raw_hex shrinks the text
        specs[0][3] = range(14, most) if aim == :kept_first
        sizes = specs.map(&size_of)
        bare  = specs.map(&bare_size_of)
        order = removal_order.(specs)
        less  = lambda do |j|
          order.first(j).each { |i| sizes[i] = bare[i] }
          list_bytes.(sizes)
        end
        top   = [n, max_entries].min
        measure, offset =
          case aim
          # the list as given, on the byte cap or up to 2,000 bytes under it
          when :within_1000, :entry_cap
            [list_bytes.(sizes), freq([2, :literal, 0], [1, :literal, -1], [1, proc { range(-2_000, -2) }])]
          # the list less its longest raw_hex, on the byte cap or under it by
          # less than the 88 bytes that removing a raw_hex of 100 saves
          when :twin       then [less.(1), freq([2, :literal, 0], [1, :literal, -1], [1, proc { range(-80, -2) }])]
          # as :twin, but under by less than any raw_hex of 14 or more saves
          when :kept_first then [less.(1), freq([2, :literal, 0], [1, :literal, -1])]
          else
            # :over_1000 lands above the byte cap, the rest on it, a byte
            # either side of it, or near it
            offset = if aim == :over_1000 then freq([2, :literal, 1], [1, proc { range(2, 300) }])
                     else freq([3, :literal, 0], [1, :literal, -1], [2, :literal, 1], [1, proc { range(-300, 300) }])
                     end
            case freq([2, :literal, :as_given], [3, :literal, :less_raw_hex], [2, :literal, :prefix], [2, :literal, :big])
            # the list as given
            when :as_given     then [list_bytes.(sizes), offset]
            # the list less its first j raw_hex in removal order
            when :less_raw_hex then [less.(freq([1, :literal, 1], [2, proc { range(0, order.size) }])), offset]
            # its first m entries with every raw_hex removed
            when :prefix       then [list_bytes.(bare.first(range([top - 40, 1].max, top))), offset]
            # or a value up to twice the byte cap, which may not fit alone
            else
              specs[0][2] = range(0, 2 * max_bytes)
              [nil, nil]
            end
          end
        if measure
          grow = max_bytes + offset - measure
          specs[0][2] += grow if specs[0][2] + grow >= 0
        end
      end

      case freq([1, :literal, :ascending], [1, :literal, :descending], [2, :literal, :shuffled])
      when :ascending  then specs
      when :descending then specs.reverse
      else                  specs.sort_by { range(0, 2**30) }
      end
    # 300 rather than 100 for the coverage assertions below. The rarest are
    # the five 1,000-entry aims other than :both_caps, 1 case in 18 each,
    # each landing its tags, so 300 cases miss a given one about once in
    # 3 x 10^7 runs. Those cases take nearly all of the 300's 4 s or so.
    }.check(300) { |specs|
      # Frozen, entries and all, so a fit_to_caps that wrote to its input
      # would fail here.
      list = specs.map(&build).freeze
      n    = specs.size
      sorted_specs = specs.sort_by(&:first)
      sorted       = list.sort_by { |e| e[:value_handle] }

      # The expected result, from the sizes alone. removed: the fewest raw_hex
      # in removal order whose removal brings the list within the byte cap,
      # or all of them. keep: the longest prefix of what is left within both
      # caps. A prefix's text is its entries' sizes, a comma between each two
      # and the brackets, so it grows with the prefix.
      sizes   = sorted_specs.map(&size_of)
      bare    = sorted_specs.map(&bare_size_of)
      order   = removal_order.(sorted_specs)
      less    = ->(j) { sizes.each_index.map { |i| order.first(j).include?(i) ? bare[i] : sizes[i] } }
      removed = order.first((0..order.size).find { |j| list_bytes.(less.(j)) <= max_bytes } || order.size)
      left    = less.(removed.size)
      ends    = left.each_with_object([0]) { |size, sums| sums << sums.last + size }
      keep    = [n, max_entries].min.downto(0).find { |k| (k.zero? ? 2 : ends[k] + k + 1) <= max_bytes }
      before  = list_bytes.(sizes)
      within  = before <= max_bytes && n <= max_entries
      expected = within ? list : sorted.first(keep).each_with_index.map { |e, i| removed.include?(i) ? stripped(e) : e }

      result, stats = described_class.fit_to_caps(list)
      expect(result).to eq(expected)
      expect(stats).to eq(bytes_before: before, bytes_after: list_bytes.(left.first(keep)),
                          raw_hex_removed: removed.count { |i| i < keep }, entries_dropped: n - keep)

      # The design's clauses, measured by serialize. An entry's text does not
      # depend on its neighbours, so a list that differs from one already
      # measured in a few entries is measured by those entries' own texts.
      text = described_class.serialize(result)
      own  = ->(e) { described_class.serialize([e]).bytesize - 2 }
      expect(stats[:bytes_after]).to eq(text.bytesize)
      expect(text.bytesize).to be <= max_bytes
      expect(result.size).to be <= max_entries
      kept_raw_hex = result.select { |e| e.key?(:raw_hex) }
      if within
        expect(result).to be(list)
        expect(stats[:bytes_before]).to eq(text.bytesize)
      else
        # Dropped entries are exactly the highest value handles.
        expect(handles(result)).to eq(handles(sorted).first(result.size))
        expect(stats[:entries_dropped]).to eq(n - result.size)
        # Each kept entry is as given, or has traded its raw_hex for the marker.
        lost = result.each_index.reject { |i| result[i] == sorted[i] }
        lost.each do |i|
          expect(sorted[i]).to have_key(:raw_hex)
          expect(result[i]).to eq(stripped(sorted[i]))
        end
        expect(stats[:raw_hex_removed]).to eq(lost.size)
        # bytes_before is the input's text: the result's, with the removed
        # raw_hex put back and the dropped entries' text spliced in, its
        # brackets traded for a comma unless nothing was kept.
        dropped = sorted.drop(result.size)
        splice  = dropped.empty? ? 0 : described_class.serialize(dropped).bytesize - (result.empty? ? 2 : 1)
        expect(stats[:bytes_before]).to eq(text.bytesize + lost.sum { |i| own.(sorted[i]) - own.(result[i]) } + splice)
        # Every raw_hex removed ranks before every raw_hex kept in removal order.
        rank = ->(e) { [-e[:raw_hex].length, -e[:value_handle]] }
        unless lost.empty? || kept_raw_hex.empty?
          expect(lost.map { |i| rank.(sorted[i]) }.max <=> kept_raw_hex.map(&rank).min).to eq(-1)
        end
        # The entry cap alone removes no raw_hex.
        expect(lost).to eq([]) if before <= max_bytes
        if result.size < [n, max_entries].min
          # Dropped for size: only once no raw_hex remains, and no further
          # than needed, as the next entry would not fit.
          expect(kept_raw_hex).to eq([])
          following = sorted[result.size]
          following = stripped(following) if following.key?(:raw_hex)
          expect(text.bytesize + (result.empty? ? 0 : 1) + own.(following)).to be > max_bytes
        end
        unless lost.empty?
          # The last raw_hex removed was removed while the whole list, every
          # raw_hex ranked before it gone, was over the byte cap, so the
          # result is not over-trimmed.
          last    = lost.map { |i| rank.(sorted[i]) }.max
          earlier = sorted.select { |e| e.key?(:raw_hex) && (rank.(e) <=> last) == -1 }
          expect(stats[:bytes_before] + earlier.sum { |e| own.(stripped(e)) - own.(e) }).to be > max_bytes
        end
        first_kept = kept_raw_hex.map(&rank).min
        if before > max_bytes && first_kept && -first_kept[0] > 12
          # And removal stopped because the whole list fitted, not because
          # entries were to be dropped: with every raw_hex ranked before the
          # first one kept removed, the whole list is within the byte cap.
          # Each of those is over 12 characters, so each removal shrank it.
          ahead = sorted.select { |e| e.key?(:raw_hex) && (rank.(e) <=> first_kept) == -1 }
          expect(stats[:bytes_before] + ahead.sum { |e| own.(stripped(e)) - own.(e) }).to be <= max_bytes
        end
      end

      seen[:empty_list] += 1 if n.zero?
      seen[:out_of_order] += 1 if handles(list) != handles(sorted)
      if within
        seen[:within] += 1
        seen[:within_at_byte_cap] += 1 if before == max_bytes
        seen[:within_at_1000] += 1 if n == max_entries
      else
        seen[:one_byte_over] += 1 if before == max_bytes + 1
        seen[:over_at_1000] += 1 if n == max_entries
        seen[:over_at_1001] += 1 if n == max_entries + 1
        seen[:after_at_byte_cap] += 1 if stats[:bytes_after] == max_bytes
        # an entry an earlier cap left marked, kept as it was
        seen[:pre_truncated] += 1 if result.each_index.any? { |i| sorted[i].key?(:raw_hex_truncated) }
        seen[:raw_hex_alone] += 1 if keep == n && removed.any?
        seen[:raw_hex_kept] += 1 if removed.any? && kept_raw_hex.any?
        seen[:short_raw_hex_removed] += 1 if removed.any? { |i| sorted_specs[i][3] <= 12 }
        seen[:dropped_after_raw_hex] += 1 if keep < [n, max_entries].min && removed.any?
        seen[:all_dropped] += 1 if keep.zero?
        if n > max_entries
          seen[before <= max_bytes ? :entry_cap_alone : :both_caps] += 1
          seen[:entry_cap_alone_raw_hex_kept] += 1 if before <= max_bytes && kept_raw_hex.any?
          seen[:both_caps_raw_hex_enough] += 1 if before > max_bytes && keep == max_entries && removed.any?
          # a kept raw_hex removed, though the first 1,000 entries as given fit
          seen[:raw_hex_before_entry_cap] += 1 if removed.any? { |i| i < keep } &&
                                                   list_bytes.(sizes.first(max_entries)) <= max_bytes
        end
        # equal raw_hex lengths, one removed and the other not
        tied = (order - removed).select { |i|
          removed.any? { |j| sorted_specs[j][3] == sorted_specs[i][3] }
        }
        seen[:tie] += 1 if tied.any?
        # as above, the removed one then dropped and the other kept
        seen[:tie_removed_then_dropped] += 1 if tied.any? { |i|
          i < keep && removed.any? { |j| j >= keep && sorted_specs[j][3] == sorted_specs[i][3] }
        }
      end
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect(%i[empty_list out_of_order within within_at_byte_cap within_at_1000
              one_byte_over over_at_1000 over_at_1001 after_at_byte_cap pre_truncated
              raw_hex_alone raw_hex_kept short_raw_hex_removed dropped_after_raw_hex all_dropped
              entry_cap_alone entry_cap_alone_raw_hex_kept both_caps both_caps_raw_hex_enough
              raw_hex_before_entry_cap tie tie_removed_then_dropped] - seen.keys).to eq([])
  end

  describe "inputs" do
    it "are never modified, including nested Hashes, Arrays and Strings" do
      oversize = [104, 106, 102, 101, 105, 103].map { |h| entry_of_size(h, 52_000, raw_hex: 1_000) }
      golden_list = goldens.map { |_, golden_entry, _| golden_entry }.reverse
      services = ["Battery Service (0x180f)", "Generic Access (0x1800)"]
      text = described_class.serialize(golden_list)
      inputs = [oversize, golden_list, services, text]
      before = deep_copy(inputs)
      inputs.each { |input| deep_freeze.(input) }

      expect(handles(described_class.fit_to_caps(oversize).first)).to eq([101, 102, 103, 104, 105])
      expect(described_class.fit_to_caps(golden_list).first).to be(golden_list)
      expect(described_class.serialize(oversize).bytesize).to eq(6 * 52_000 + 7)
      expect(described_class.parse(text)).to eq(golden_list.reverse)
      expect(handles(described_class.merge_by_value_handle(golden_list, oversize)).size).to eq(15)
      expect(described_class.union_service_uuids(services, ["Generic Access (0x1800)"]).first)
        .to eq(services.reverse)
      expect(inputs).to eq(before)
    end
  end
end
