require 'spec_helper'
require 'blue_hydra/att_codec'

describe BlueHydra::AttCodec do
  # Locals rather than constants: a constant here would land on Object and be
  # shared with every other spec file. The examples close over them.
  #
  # Every vector is written out by hand from the PDU layouts in Core 6.3 Vol 3
  # Part F section 3.4 (opcode octet first, multi-octet fields little-endian)
  # rather than built from the subject's own tables, so a wrong layout in the
  # subject cannot also be wrong in the expectation.
  codec = BlueHydra::AttCodec

  hex  = ->(s) { [s.delete(" ")].pack("H*") }
  uuid = ->(bits, h) { codec::Uuid.new(bits: bits, hex: h) }

  # Nordic UART Service and its TX characteristic: 128-bit UUIDs off the
  # Bluetooth Base UUID, so they can never fold to 16 bits. On air the octets
  # are least-significant first; written form is most-significant first.
  nus_service_air = "9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 01 00 40 6e"
  nus_service     = uuid.(128, "6e400001b5a3f393e0a9e50e24dcca9e")
  nus_tx_air      = "9e ca dc 24 0e e5 a9 e0 93 f3 a3 b5 03 00 40 6e"
  nus_tx          = uuid.(128, "6e400003b5a3f393e0a9e50e24dcca9e")
  # GAP 0x1800 sent in its full 128-bit Base UUID form.
  gap_long_air    = "fb 34 9b 5f 80 00 00 80 00 10 00 00 00 18 00 00"
  gap_long        = uuid.(128, "0000180000001000800000805f9b34fb")

  # Requirement 9.1's opcode list, written out.
  req_9_1_opcodes = [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0A, 0x0B,
                     0x0C, 0x0D, 0x10, 0x11, 0x1B, 0x1D, 0x1E]

  # [label, on-air hex, decoded structure]
  vectors = [
    # 3.4.1 Error Response: request opcode in error, handle in error, error code
    ["Error Response", "01 10 01 00 0a",
     codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x0A)],
    ["Error Response with a two-octet handle", "01 0a 34 12 05",
     codec::ErrorResponse.new(request_opcode: 0x0A, handle: 0x1234, error_code: 0x05)],

    # 3.4.2 Exchange MTU: Client / Server Rx MTU
    ["Exchange MTU Request(517)", "02 05 02", codec::ExchangeMtuRequest.new(mtu: 517)],
    ["Exchange MTU Response(23)", "03 17 00", codec::ExchangeMtuResponse.new(mtu: 23)],

    # 3.4.3 Find Information: range; format then handle/UUID pairs
    ["Find Information Request", "04 03 00 05 00",
     codec::FindInformationRequest.new(start_handle: 0x0003, end_handle: 0x0005)],
    ["Find Information Response format 0x01 (16-bit)", "05 01 03 00 02 29 04 00 04 29",
     codec::FindInformationResponse.new(format: 0x01,
                                        entries: [[0x0003, uuid.(16, "2902")], [0x0004, uuid.(16, "2904")]])],
    ["Find Information Response format 0x02 (128-bit)", "05 02 0f 00 #{nus_tx_air}",
     codec::FindInformationResponse.new(format: 0x02, entries: [[0x000F, nus_tx]])],

    # 3.4.3 Find By Type Value Request: range, 16-bit type, value to match
    ["Find By Type Value Request", "06 01 00 ff ff 00 28 0d 18",
     codec::FindByTypeValueRequest.new(start_handle: 0x0001, end_handle: 0xFFFF,
                                       uuid: uuid.(16, "2800"), value: hex.("0d 18"))],
    ["Find By Type Value Request with an empty value", "06 01 00 ff ff 00 28",
     codec::FindByTypeValueRequest.new(start_handle: 0x0001, end_handle: 0xFFFF,
                                       uuid: uuid.(16, "2800"), value: "".b)],

    # 3.4.4 Read By Type: range then a 2- or 16-octet type; length then entries
    ["Read By Type Request (16-bit)", "08 01 00 ff ff 03 28",
     codec::ReadByTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: uuid.(16, "2803"))],
    ["Read By Type Request (128-bit)", "08 01 00 ff ff #{nus_tx_air}",
     codec::ReadByTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: nus_tx)],
    ["Read By Type Response of two 16-bit characteristic declarations",
     "09 07 02 00 02 03 00 00 2a 04 00 02 05 00 01 2a",
     codec::ReadByTypeResponse.new(length: 7,
                                   entries: [[0x0002, hex.("02 03 00 00 2a")], [0x0004, hex.("02 05 00 01 2a")]])],
    ["Read By Type Response of a 128-bit characteristic declaration", "09 15 0d 00 10 0e 00 #{nus_tx_air}",
     codec::ReadByTypeResponse.new(length: 21, entries: [[0x000D, hex.("10 0e 00 #{nus_tx_air}")]])],
    ["Read By Type Response with length 2 (empty values)", "09 02 03 00 04 00",
     codec::ReadByTypeResponse.new(length: 2, entries: [[0x0003, "".b], [0x0004, "".b]])],

    # 3.4.4 Read and Read Blob
    ["Read Request", "0a 03 00", codec::ReadRequest.new(handle: 0x0003)],
    ["Read Response", "0b 42 6c 75 65", codec::ReadResponse.new(value: hex.("42 6c 75 65"))],
    ["Read Response with an empty value", "0b", codec::ReadResponse.new(value: "".b)],
    ["Read Blob Request", "0c 03 00 16 00", codec::ReadBlobRequest.new(handle: 0x0003, offset: 0x0016)],
    ["Read Blob Response", "0d 01 02 03", codec::ReadBlobResponse.new(value: hex.("01 02 03"))],
    ["Read Blob Response with an empty value", "0d", codec::ReadBlobResponse.new(value: "".b)],

    # 3.4.4 Read By Group Type: range then group type; length then entries
    ["Read By Group Type Request (primary)", "10 01 00 ff ff 00 28",
     codec::ReadByGroupTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: uuid.(16, "2800"))],
    ["Read By Group Type Request (secondary)", "10 08 00 ff ff 01 28",
     codec::ReadByGroupTypeRequest.new(start_handle: 0x0008, end_handle: 0xFFFF, uuid: uuid.(16, "2801"))],
    ["Read By Group Type Request (128-bit group type)", "10 01 00 ff ff #{nus_service_air}",
     codec::ReadByGroupTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: nus_service)],
    ["Read By Group Type Response, length 6 (16-bit UUIDs)", "11 06 01 00 07 00 00 18 08 00 0b 00 01 18",
     codec::ReadByGroupTypeResponse.new(length: 6,
                                        entries: [[0x0001, 0x0007, uuid.(16, "1800")],
                                                  [0x0008, 0x000B, uuid.(16, "1801")]])],
    ["Read By Group Type Response, length 20 (128-bit UUID)", "11 14 0c 00 0f 00 #{nus_service_air}",
     codec::ReadByGroupTypeResponse.new(length: 20, entries: [[0x000C, 0x000F, nus_service]])],

    # 3.4.7 Server initiated: handle then value; confirmation is the opcode alone
    ["Handle Value Notification", "1b 10 00 64", codec::HandleValueNotification.new(handle: 0x0010, value: hex.("64"))],
    ["Handle Value Notification with an empty value", "1b 10 00",
     codec::HandleValueNotification.new(handle: 0x0010, value: "".b)],
    ["Handle Value Indication (Service Changed 0x0001-0xFFFF)", "1d 03 00 01 00 ff ff",
     codec::HandleValueIndication.new(handle: 0x0003, value: hex.("01 00 ff ff"))],
    ["Handle Value Confirmation", "1e", codec::HandleValueConfirmation.new]
  ]

  describe "Core 6.3 Vol 3 Part F byte vectors" do
    it "cover every opcode in Requirement 9.1, which is exactly the set the codec handles" do
      expect(vectors.map { |_, air, _| hex.(air).getbyte(0) }.uniq.sort).to eq(req_9_1_opcodes)
      expect(codec::OPCODES.values.sort).to eq(req_9_1_opcodes)
    end

    vectors.each do |label, air, pdu|
      it "decodes #{label}" do
        expect(codec.decode(hex.(air))).to eq(pdu)
      end

      it "encodes #{label}" do
        bytes = codec.encode(pdu)
        expect(bytes).to eq(hex.(air))
        expect(bytes.encoding).to eq(Encoding::BINARY)
        expect(codec.opcode_of(pdu)).to eq(hex.(air).getbyte(0))
      end
    end

    it "decodes a String by its bytes whatever its encoding" do
      utf8 = hex.("0b ff fe").force_encoding(Encoding::UTF_8)
      expect(codec.decode(utf8)).to eq(codec::ReadResponse.new(value: hex.("ff fe")))
    end
  end

  # Requirement 9.6: any code 0x00-0xFF is carried through, not interpreted.
  describe "Error Response codes" do
    [
      [0x00, "reserved"],
      [0x0A, "Attribute Not Found"],
      [0x80, "first application error"],
      [0x9F, "last application error"],
      [0xFF, "top of the code space"]
    ].each do |code, label|
      it format("decodes and encodes code 0x%02X (%s)", code, label) do
        air = hex.(format("01 0a 05 00 %02x", code))
        pdu = codec::ErrorResponse.new(request_opcode: 0x0A, handle: 0x0005, error_code: code)
        expect(codec.decode(air)).to eq(pdu)
        expect(codec.encode(pdu)).to eq(air)
      end
    end
  end

  # Requirement 9.1: handles come back exactly as received; range and order
  # are the walker's to check (Requirement 6.5), not the codec's.
  describe "handles returned as received" do
    [
      ["a Find Information Request whose start is above its end", "04 ff ff 01 00",
       codec::FindInformationRequest.new(start_handle: 0xFFFF, end_handle: 0x0001)],
      ["a Find Information Response with descending handles", "05 01 05 00 02 29 03 00 02 29",
       codec::FindInformationResponse.new(format: 0x01,
                                          entries: [[0x0005, uuid.(16, "2902")], [0x0003, uuid.(16, "2902")]])],
      ["a Read By Group Type Response with an end group below its handle, repeated",
       "11 06 07 00 01 00 00 18 07 00 01 00 00 18",
       codec::ReadByGroupTypeResponse.new(length: 6,
                                          entries: [[0x0007, 0x0001, uuid.(16, "1800")],
                                                    [0x0007, 0x0001, uuid.(16, "1800")]])],
      ["a Read By Type Response with handles 0x0000 and 0xFFFF", "09 03 00 00 aa ff ff bb",
       codec::ReadByTypeResponse.new(length: 3, entries: [[0x0000, hex.("aa")], [0xFFFF, hex.("bb")]])]
    ].each do |label, air, pdu|
      it "keeps #{label}" do
        expect(codec.decode(hex.(air))).to eq(pdu)
        expect(codec.encode(pdu)).to eq(hex.(air))
      end
    end
  end

  # Requirement 9.5: the on-air width is kept and 128-bit UUIDs read
  # most-significant byte first, lowercase, no hyphens.
  describe "UUID widths" do
    it "keeps a 16-bit UUID sent in 128-bit Base UUID form at 128 bits, both ways" do
      air = hex.("11 14 01 00 05 00 #{gap_long_air}")
      pdu = codec::ReadByGroupTypeResponse.new(length: 20, entries: [[0x0001, 0x0005, gap_long]])
      expect(codec.decode(air)).to eq(pdu)
      expect(codec.encode(pdu)).to eq(air)
    end

    it "renders a 128-bit UUID as 32 lowercase hex characters, most-significant byte first" do
      pdu = codec.decode(hex.("11 14 0c 00 0f 00 #{nus_service_air}"))
      rendered = pdu.entries.first.last
      expect(rendered.bits).to eq(128)
      expect(rendered.hex).to eq("6e400001b5a3f393e0a9e50e24dcca9e")
    end
  end

  describe ".decode_characteristic_declaration" do
    it "decodes the 5-byte form: properties, value handle, 16-bit UUID" do
      expect(codec.decode_characteristic_declaration(hex.("02 03 00 00 2a")))
        .to eq(codec::CharacteristicDeclaration.new(properties: 0x02, value_handle: 0x0003, uuid: uuid.(16, "2a00")))
    end

    it "decodes the 19-byte form with a 128-bit UUID" do
      expect(codec.decode_characteristic_declaration(hex.("10 0e 00 #{nus_tx_air}")))
        .to eq(codec::CharacteristicDeclaration.new(properties: 0x10, value_handle: 0x000E, uuid: nus_tx))
    end

    it "keeps the properties octet as the raw bit field" do
      expect(codec.decode_characteristic_declaration(hex.("ff 34 12 29 2a")))
        .to eq(codec::CharacteristicDeclaration.new(properties: 0xFF, value_handle: 0x1234, uuid: uuid.(16, "2a29")))
    end

    it "decodes the entry values of a Read By Type Response for 0x2803" do
      response = codec.decode(hex.("09 07 02 00 02 03 00 00 2a 04 00 02 05 00 01 2a"))
      decls = response.entries.map { |_, value| codec.decode_characteristic_declaration(value) }
      expect(decls).to eq([
        codec::CharacteristicDeclaration.new(properties: 0x02, value_handle: 0x0003, uuid: uuid.(16, "2a00")),
        codec::CharacteristicDeclaration.new(properties: 0x02, value_handle: 0x0005, uuid: uuid.(16, "2a01"))
      ])
    end

    [0, 4, 6, 18, 20].each do |size|
      it "returns a Malformed with no opcode for a #{size}-byte value" do
        expect(codec.decode_characteristic_declaration("\x02".b * size))
          .to eq(codec::Malformed.new(opcode: nil, reason: :bad_declaration_length))
      end
    end
  end

  describe ".decode_include_declaration" do
    it "decodes the 6-byte form: included service range and its 16-bit UUID" do
      expect(codec.decode_include_declaration(hex.("05 00 08 00 0f 18")))
        .to eq(codec::IncludeDeclaration.new(start_handle: 0x0005, end_handle: 0x0008, uuid: uuid.(16, "180f")))
    end

    it "decodes the 4-byte form (128-bit included service) with the UUID absent" do
      expect(codec.decode_include_declaration(hex.("09 00 0c 00")))
        .to eq(codec::IncludeDeclaration.new(start_handle: 0x0009, end_handle: 0x000C, uuid: nil))
    end

    it "decodes the entry values of a Read By Type Response for 0x2802" do
      six  = codec.decode(hex.("09 08 04 00 05 00 08 00 0f 18"))
      four = codec.decode(hex.("09 06 04 00 09 00 0c 00"))
      expect(codec.decode_include_declaration(six.entries.first.last).uuid).to eq(uuid.(16, "180f"))
      expect(codec.decode_include_declaration(four.entries.first.last).uuid).to be_nil
    end

    # 20 would be a 128-bit UUID inline, which the include declaration never carries.
    [0, 3, 5, 7, 8, 20].each do |size|
      it "returns a Malformed with no opcode for a #{size}-byte value" do
        expect(codec.decode_include_declaration("\x01".b * size))
          .to eq(codec::Malformed.new(opcode: nil, reason: :bad_declaration_length))
      end
    end
  end

  # Requirement 9.2: one row per malformed class, the class's reason, and the
  # first byte carried as the opcode whenever there is one.
  describe "malformed PDUs" do
    it "reports an empty PDU with no opcode" do
      expect(codec.decode("")).to eq(codec::Malformed.new(opcode: nil, reason: :empty))
    end

    it "decodes a 517-byte PDU and reports a 518-byte one as too long" do
      expect(codec.decode(hex.("0b") + ("\xAA".b * 516)))
        .to eq(codec::ReadResponse.new(value: "\xAA".b * 516))
      expect(codec.decode(hex.("0b") + ("\xAA".b * 517)))
        .to eq(codec::Malformed.new(opcode: 0x0B, reason: :too_long))
      expect(codec.decode(hex.("1b 10 00") + ("\x00".b * 515)))
        .to eq(codec::Malformed.new(opcode: 0x1B, reason: :too_long))
    end

    [
      # an opcode not listed in Requirement 9.1, Command Flag opcodes included
      ["Find By Type Value Response 0x07",       "07 01 00 05 00",    :unknown_opcode],
      ["Write Request 0x12",                     "12 03 00 01",       :unknown_opcode],
      ["Write Command 0x52 (Command Flag)",      "52 03 00 01",       :unknown_opcode],
      ["Signed Write Command 0xD2 (Command Flag)", "d2 03 00 01 #{'00' * 12}", :unknown_opcode],
      ["opcode 0x00",                            "00",                :unknown_opcode],
      ["opcode 0xFF",                            "ff 01 02",          :unknown_opcode],

      # shorter than the opcode's fixed fields
      ["Error Response one octet short",          "01 10 01 00",       :too_short],
      ["Exchange MTU Request with one MTU octet", "02 05",             :too_short],
      ["Exchange MTU Response with no MTU",       "03",                :too_short],
      ["Find Information Request without its full end handle", "04 01 00 ff", :too_short],
      ["Find Information Response with no format", "05",              :too_short],
      ["Find By Type Value Request without its full type", "06 01 00 ff ff 00", :too_short],
      ["Read By Type Request without its full range", "08 01 00 ff",   :too_short],
      ["Read By Type Response with no length",    "09",                :too_short],
      ["Read Request with no handle",             "0a",                :too_short],
      ["Read Blob Request with no offset",        "0c 03 00",          :too_short],
      ["Read By Group Type Request without its full range", "10 01 00", :too_short],
      ["Read By Group Type Response with no length", "11",             :too_short],
      ["Handle Value Notification with a one-octet handle", "1b 10",   :too_short],
      ["Handle Value Indication with no handle",  "1d",                :too_short],

      # longer than the fixed fields, for an opcode with no variable field
      ["Error Response with a trailing octet",       "01 10 01 00 0a 00",    :trailing_bytes],
      ["Exchange MTU Request with a trailing octet", "02 05 02 00",          :trailing_bytes],
      ["Exchange MTU Response with a trailing octet", "03 17 00 00",         :trailing_bytes],
      ["Find Information Request with a trailing octet", "04 01 00 ff ff 00", :trailing_bytes],
      ["Read Request with a trailing octet",         "0a 03 00 00",          :trailing_bytes],
      ["Read Blob Request with a trailing octet",    "0c 03 00 16 00 00",    :trailing_bytes],
      ["Handle Value Confirmation with a parameter", "1e 00",                :trailing_bytes],

      # a request UUID field other than 2 or 16 octets
      ["Read By Type Request with no UUID",          "08 01 00 ff ff",             :bad_uuid_length],
      ["Read By Type Request with a 4-octet UUID",   "08 01 00 ff ff 03 28 00 00", :bad_uuid_length],
      ["Read By Type Request with a 17-octet UUID",  "08 01 00 ff ff #{nus_tx_air} 00", :bad_uuid_length],
      ["Read By Group Type Request with a 1-octet UUID", "10 01 00 ff ff 00",      :bad_uuid_length],
      ["Read By Group Type Request with a 15-octet UUID", "10 01 00 ff ff #{'00' * 15}", :bad_uuid_length],

      # Find Information Response format other than 0x01 / 0x02
      ["Find Information Response format 0x00", "05 00 03 00 02 29", :bad_format],
      ["Find Information Response format 0x03", "05 03 03 00 02 29", :bad_format],

      # Read By Type Response length below 2
      ["Read By Type Response length 0", "09 00 03 00", :bad_length],
      ["Read By Type Response length 1", "09 01 03",    :bad_length],

      # Read By Group Type Response length other than 6 or 20
      ["Read By Group Type Response length 4",  "11 04 01 00 07 00",          :bad_length],
      ["Read By Group Type Response length 7",  "11 07 01 00 07 00 00 18 00", :bad_length],
      ["Read By Group Type Response length 21", "11 15 0c 00 0f 00 #{nus_service_air} 00", :bad_length],

      # an empty entry list
      ["Find Information Response with no entries",   "05 01", :no_entries],
      ["Read By Type Response with no entries",       "09 07", :no_entries],
      ["Read By Group Type Response with no entries", "11 06", :no_entries],

      # an entry list that does not divide into whole entries
      ["Find Information Response format 0x01 with a partial entry", "05 01 03 00 02 29 04 00", :ragged_entries],
      ["Find Information Response format 0x02 with a 16-bit entry",  "05 02 03 00 02 29",       :ragged_entries],
      ["Read By Type Response with a partial second entry", "09 07 02 00 02 03 00 00 2a 04 00", :ragged_entries],
      ["Read By Group Type Response with a partial second entry", "11 06 01 00 07 00 00 18 08 00", :ragged_entries],
      ["Read By Group Type Response length 20 with a 16-bit entry", "11 14 01 00 07 00 00 18",     :ragged_entries]
    ].each do |label, air, reason|
      it "reports #{label} as #{reason} with its opcode" do
        bytes = hex.(air)
        expect(codec.decode(bytes)).to eq(codec::Malformed.new(opcode: bytes.getbyte(0), reason: reason))
      end
    end
  end

  # Requirement 9.8 plus the module's strictness: encode raises for anything
  # decode could not have produced from a valid PDU, and returns no bytes.
  describe ".encode ArgumentError" do
    u2800 = uuid.(16, "2800")

    [
      # not a PDU
      ["a Malformed",                      codec::Malformed.new(opcode: 0x01, reason: :too_short)],
      ["an empty-PDU Malformed",           codec::Malformed.new(opcode: nil, reason: :empty)],
      ["a String",                         hex.("0a 03 00")],
      ["nil",                              nil],
      ["a characteristic declaration",     codec::CharacteristicDeclaration.new(properties: 2, value_handle: 3, uuid: uuid.(16, "2a00"))],
      ["a Uuid",                           u2800],

      # handles, offset and MTU outside 0x0000..0xFFFF, or not Integers
      ["a Read Request handle of 0x10000", codec::ReadRequest.new(handle: 0x10000)],
      ["a Read Request handle of -1",      codec::ReadRequest.new(handle: -1)],
      ["a nil Read Request handle",        codec::ReadRequest.new(handle: nil)],
      ["a String Read Request handle",     codec::ReadRequest.new(handle: "3")],
      ["a Float Read Request handle",      codec::ReadRequest.new(handle: 3.0)],
      ["a Find Information Request end handle of 0x10000",
       codec::FindInformationRequest.new(start_handle: 1, end_handle: 0x10000)],
      ["a Read By Type Request start handle of -1",
       codec::ReadByTypeRequest.new(start_handle: -1, end_handle: 0xFFFF, uuid: u2800)],
      ["a Read Blob Request offset of 0x10000", codec::ReadBlobRequest.new(handle: 3, offset: 0x10000)],
      ["a Handle Value Indication handle of 0x10000", codec::HandleValueIndication.new(handle: 0x10000, value: "".b)],
      ["a Find Information Response entry handle of 0x10000",
       codec::FindInformationResponse.new(format: 0x01, entries: [[0x10000, uuid.(16, "2902")]])],
      ["a Read By Type Response entry handle of -1",
       codec::ReadByTypeResponse.new(length: 3, entries: [[-1, hex.("aa")]])],
      ["a Read By Group Type Response end group handle of 0x10000",
       codec::ReadByGroupTypeResponse.new(length: 6, entries: [[1, 0x10000, u2800]])],
      ["an Exchange MTU Request MTU of 0x10000", codec::ExchangeMtuRequest.new(mtu: 0x10000)],
      ["an Exchange MTU Response MTU of -1",     codec::ExchangeMtuResponse.new(mtu: -1)],

      # one-octet fields outside 0x00..0xFF
      ["an Error Response code of 0x100",          codec::ErrorResponse.new(request_opcode: 0x0A, handle: 1, error_code: 0x100)],
      ["an Error Response request opcode of -1",   codec::ErrorResponse.new(request_opcode: -1, handle: 1, error_code: 0x0A)],
      ["a Read By Type Response length of 0x100",  codec::ReadByTypeResponse.new(length: 0x100, entries: [[1, hex.("aa")]])],

      # a UUID other than a 16- or 128-bit Uuid with lowercase hex of its width
      ["a 32-bit Uuid",
       codec::ReadByTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(32, "00002800"))],
      ["a 16-bit Uuid whose hex is longer than 16 bits",
       codec::ReadByGroupTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(16, "002800"))],
      ["a 128-bit Uuid whose hex is 16 bits",
       codec::ReadByGroupTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(128, "2800"))],
      ["an uppercase 16-bit Uuid",
       codec::ReadByTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(16, "2A00"))],
      ["an uppercase 128-bit Uuid",
       codec::ReadByTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(128, "6E400001B5A3F393E0A9E50E24DCCA9E"))],
      ["a hyphenated 128-bit Uuid",
       codec::ReadByTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: uuid.(128, "6e400001-b5a3-f393-e0a9-e50e24dcca9e"))],
      ["an Integer in place of a Uuid",
       codec::ReadByTypeRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: 0x2803)],
      ["a Find By Type Value Request with a 128-bit attribute type",
       codec::FindByTypeValueRequest.new(start_handle: 1, end_handle: 0xFFFF, uuid: nus_service, value: "".b)],
      ["a nil Uuid in a Find Information Response entry",
       codec::FindInformationResponse.new(format: 0x01, entries: [[3, nil]])],

      # empty or ragged entry lists
      ["a Find Information Response with no entries",   codec::FindInformationResponse.new(format: 0x01, entries: [])],
      ["a Read By Type Response with no entries",       codec::ReadByTypeResponse.new(length: 7, entries: [])],
      ["a Read By Group Type Response with no entries", codec::ReadByGroupTypeResponse.new(length: 6, entries: [])],
      ["a Read By Type Response with nil entries",      codec::ReadByTypeResponse.new(length: 7, entries: nil)],
      ["a Read By Group Type Response entry of two fields",
       codec::ReadByGroupTypeResponse.new(length: 6, entries: [[1, 7]])],
      ["a Read By Type Response entry of three fields",
       codec::ReadByTypeResponse.new(length: 3, entries: [[1, hex.("aa"), 2]])],
      ["a Find Information Response entry that is not an Array",
       codec::FindInformationResponse.new(format: 0x01, entries: [uuid.(16, "2902")])],

      # entries disagreeing with the length or format byte
      ["Find Information format 0x01 carrying a 128-bit UUID",
       codec::FindInformationResponse.new(format: 0x01, entries: [[0x000F, nus_tx]])],
      ["Find Information format 0x02 carrying a 16-bit UUID",
       codec::FindInformationResponse.new(format: 0x02, entries: [[0x0003, uuid.(16, "2902")]])],
      ["Find Information format 0x03",
       codec::FindInformationResponse.new(format: 0x03, entries: [[0x0003, uuid.(16, "2902")]])],
      ["a Read By Type Response whose second value is shorter than its length",
       codec::ReadByTypeResponse.new(length: 7, entries: [[2, hex.("02 03 00 00 2a")], [4, hex.("02 05 00")]])],
      ["a Read By Type Response of length 1",
       codec::ReadByTypeResponse.new(length: 1, entries: [[3, "".b]])],
      ["a Read By Group Type Response of length 6 carrying a 128-bit UUID",
       codec::ReadByGroupTypeResponse.new(length: 6, entries: [[0x000C, 0x000F, nus_service]])],
      ["a Read By Group Type Response of length 20 carrying a 16-bit UUID",
       codec::ReadByGroupTypeResponse.new(length: 20, entries: [[0x0001, 0x0007, u2800]])],

      # a value that is not a String
      ["a nil Read Response value", codec::ReadResponse.new(value: nil)],

      # longer than 517 bytes
      ["a 518-byte Read Response",              codec::ReadResponse.new(value: "\xAA".b * 517)],
      ["a 518-byte Handle Value Notification",  codec::HandleValueNotification.new(handle: 0x0010, value: "\x00".b * 515)],
      ["a 518-byte Read By Type Response of well-formed entries",
       codec::ReadByTypeResponse.new(length: 6, entries: Array.new(86) { |i| [i + 1, hex.("01 02 03 04")] })]
    ].each do |label, pdu|
      it "raises for #{label}" do
        expect { codec.encode(pdu) }.to raise_error(ArgumentError)
      end
    end

    it "encodes exactly 517 bytes" do
      expect(codec.encode(codec::ReadResponse.new(value: "\xAA".b * 516)).bytesize).to eq(517)
      expect(codec.encode(codec::HandleValueNotification.new(handle: 0x0010, value: "\x00".b * 514)).bytesize).to eq(517)
      expect(codec.encode(codec::ReadByTypeResponse.new(length: 5, entries: Array.new(103) { |i| [i + 1, hex.("01 02 03")] }))
               .bytesize).to eq(517)
    end
  end

  describe "helpers" do
    it "opcode_of reports a Malformed's opcode byte and rejects a non-PDU" do
      expect(codec.opcode_of(codec::Malformed.new(opcode: 0x52, reason: :unknown_opcode))).to eq(0x52)
      expect(codec.opcode_of(codec::Malformed.new(opcode: nil, reason: :empty))).to be_nil
      expect { codec.opcode_of("\x0a".b) }.to raise_error(ArgumentError)
    end

    # The *_RSP rows of the Part F section 3.4.8 opcode summary, Read Multiple
    # Variable Response (0x21) included. Its request (0x20) and Multiple
    # Handle Value Notification (0x23) answer nothing.
    it "response_opcode? is true for response opcodes only" do
      [0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19, 0x21].each do |op|
        expect(codec.response_opcode?(op)).to be(true), format("0x%02X", op)
      end
      [0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x10, 0x12, 0x1B, 0x1D, 0x1E, 0x20, 0x23, 0x52, 0xD2, nil].each do |op|
        expect(codec.response_opcode?(op)).to be(false), op.inspect
      end
    end

    it "command? is true when bit 6 (Command Flag) is set and false for nil" do
      expect(codec.command?(0x52)).to be(true)
      expect(codec.command?(0xD2)).to be(true)
      [0x12, 0x1B, 0x1D, 0x1E, 0x01, nil].each { |op| expect(codec.command?(op)).to be(false), op.inspect }
    end

    it "uuid16 builds a 16-bit Uuid and raises outside 0x0000..0xFFFF" do
      expect(codec.uuid16(0x2A00)).to eq(uuid.(16, "2a00"))
      expect(codec.uuid16(0)).to eq(uuid.(16, "0000"))
      [0x10000, -1, "2a00", nil].each { |n| expect { codec.uuid16(n) }.to raise_error(ArgumentError) }
    end

    it "uuid_from_bytes reads on-air order and raises for widths other than 2 or 16 octets" do
      expect(codec.uuid_from_bytes(hex.("00 28"))).to eq(uuid.(16, "2800"))
      expect(codec.uuid_from_bytes(hex.(nus_service_air))).to eq(nus_service)
      [0, 1, 3, 4, 15, 17].each do |size|
        expect { codec.uuid_from_bytes("\x00".b * size) }.to raise_error(ArgumentError)
      end
    end
  end

  # Feature: gatt-service-scanning, Property 7: Att_Codec round trip
  #
  # Validates: Requirements 9.1, 9.3, 9.4, 9.5, 9.6
  #
  # Each case picks an ATT_MTU in 23..517 and one of the 17 opcodes in
  # req_9_1_opcodes, then builds a structure decode could have produced from a
  # valid PDU of that opcode no longer than the MTU: handles, offsets and MTU
  # fields anywhere in 0x0000..0xFFFF, Error Responses with any request opcode
  # and code, UUIDs at both widths (a 16-bit value in its 128-bit Base UUID
  # form stays 128-bit), Find Information entries matching their format,
  # Read By Type entries sharing one value length (length 2..255), Read By
  # Group Type entries sharing one width (length 6 or 20), and as many entries
  # or value bytes as the MTU leaves room for. Lengths and counts land on
  # their lower and upper bound often, so full PDUs and empty values are
  # common rather than rare.
  #
  # The expected size comes from the Part F layouts restated in the generator,
  # not from the subject's tables, so a layout the subject got wrong both ways
  # still shows. The printed tuple [mtu, opcode, pdu, size, tags] is the whole
  # input; tags only record which branches the case took.
  it "Property 7: encode then decode returns every valid PDU of each Requirement 9.1 opcode that fits an ATT_MTU of 23 to 517" do
    base_tail = "00001000800000805f9b34fb"
    seen = Hash.new(0)

    # The lambdas are created inside the generator so they share rantly's
    # self (property_of instance_evals its block) and can call range, freq etc.
    property_of {
      tags = []
      pick = ->(lo, hi) { freq([1, :literal, lo], [1, :literal, hi], [3, proc { range(lo, hi) }]) }
      u8   = -> { pick.(0x00, 0xFF) }
      u16  = -> { freq([1, :literal, 0x0000], [1, :literal, 0x0001], [1, :literal, 0xFFFF], [4, proc { range(0, 0xFFFF) }]) }
      blob = ->(n) { array(n) { range(0x00, 0xFF) }.pack("C*") }
      uuid16 = lambda {
        tags << :uuid16
        uuid.(16, format("%04x", u16.()))
      }
      uuid128 = lambda {
        if boolean
          tags << :uuid128_base
          uuid.(128, format("0000%04x", u16.()) + base_tail)
        else
          tags << :uuid128
          uuid.(128, format("%032x", range(0, 2**128 - 1)))
        end
      }

      mtu = freq([1, :literal, 23], [1, :literal, 517], [4, proc { range(23, 517) }])
      opcode = choose(*req_9_1_opcodes)
      # [structure, encoded size]; headers count the opcode octet.
      pdu, size =
        case opcode
        when 0x01
          [codec::ErrorResponse.new(request_opcode: u8.(), handle: u16.(), error_code: u8.()), 5]
        when 0x02 then [codec::ExchangeMtuRequest.new(mtu: u16.()), 3]
        when 0x03 then [codec::ExchangeMtuResponse.new(mtu: u16.()), 3]
        when 0x04 then [codec::FindInformationRequest.new(start_handle: u16.(), end_handle: u16.()), 5]
        when 0x05
          info_format = choose(0x01, 0x02)
          tags << (info_format == 0x01 ? :find_information_16 : :find_information_128)
          entry = info_format == 0x01 ? 4 : 18
          n = pick.(1, (mtu - 2) / entry)
          list = array(n) { [u16.(), info_format == 0x01 ? uuid16.() : uuid128.()] }
          [codec::FindInformationResponse.new(format: info_format, entries: list), 2 + n * entry]
        when 0x06
          value = blob.(pick.(0, mtu - 7))
          [codec::FindByTypeValueRequest.new(start_handle: u16.(), end_handle: u16.(), uuid: uuid16.(), value: value),
           7 + value.bytesize]
        when 0x08, 0x10
          klass = opcode == 0x08 ? codec::ReadByTypeRequest : codec::ReadByGroupTypeRequest
          type = boolean ? uuid16.() : uuid128.()
          [klass.new(start_handle: u16.(), end_handle: u16.(), uuid: type), 5 + type.bits / 8]
        when 0x09
          value_len = pick.(0, [253, mtu - 4].min)
          n = pick.(1, (mtu - 2) / (value_len + 2))
          list = array(n) { [u16.(), blob.(value_len)] }
          [codec::ReadByTypeResponse.new(length: value_len + 2, entries: list), 2 + n * (value_len + 2)]
        when 0x0A then [codec::ReadRequest.new(handle: u16.()), 3]
        when 0x0B, 0x0D
          klass = opcode == 0x0B ? codec::ReadResponse : codec::ReadBlobResponse
          value = blob.(pick.(0, mtu - 1))
          [klass.new(value: value), 1 + value.bytesize]
        when 0x0C then [codec::ReadBlobRequest.new(handle: u16.(), offset: u16.()), 5]
        when 0x11
          length = choose(6, 20)
          tags << (length == 6 ? :group_16 : :group_128)
          n = pick.(1, (mtu - 2) / length)
          list = array(n) { [u16.(), u16.(), length == 6 ? uuid16.() : uuid128.()] }
          [codec::ReadByGroupTypeResponse.new(length: length, entries: list), 2 + n * length]
        when 0x1B, 0x1D
          klass = opcode == 0x1B ? codec::HandleValueNotification : codec::HandleValueIndication
          value = blob.(pick.(0, mtu - 3))
          [klass.new(handle: u16.(), value: value), 3 + value.bytesize]
        when 0x1E then [codec::HandleValueConfirmation.new, 1]
        end
      [mtu, opcode, pdu, size, tags.uniq]
    # 500 rather than 100 for the coverage assertions below. The rarest tags
    # (a Find Information format, a Read By Group Type width) are 1 case in 34,
    # so 500 misses one of the four about once in 750,000 runs; at 100 an
    # opcode (1 in 17) would go unseen about once in 25 runs.
    }.check(500) { |mtu, opcode, pdu, size, tags|
      seen[opcode] += 1
      tags.each { |tag| seen[tag] += 1 }

      bytes = codec.encode(pdu)
      expect(bytes.encoding).to eq(Encoding::BINARY)
      expect(bytes.getbyte(0)).to eq(opcode)
      expect(bytes.bytesize).to eq(size)
      expect(bytes.bytesize).to be <= mtu
      expect(bytes.bytesize).to be <= 517
      seen[:fills_mtu] += 1 if bytes.bytesize == mtu

      decoded = codec.decode(bytes)
      expect(decoded).to eq(pdu)
      expect(codec.encode(decoded)).to eq(bytes)
    }

    # A generator that stopped reaching an opcode or UUID width would let the
    # property pass without testing it.
    expect(req_9_1_opcodes - seen.keys).to eq([])
    expect(%i[uuid16 uuid128 uuid128_base find_information_16 find_information_128 group_16 group_128 fills_mtu] -
           seen.keys).to eq([])
  end

  # Feature: gatt-service-scanning, Property 8: Att_Codec decoding never raises
  #
  # Validates: Requirements 9.2, 9.7
  #
  # decode is fed whatever the peer put on the bearer. Each case builds one
  # such String, plus a 0..40-byte value for the two declaration decoders
  # (4, 5, 6 or 19 bytes, or a neighbour 3, 7, 18 or 20, two times in three),
  # from one of these shapes:
  #   * sweep: a first byte drawn without replacement from a deck of
  #     0x00..0xFF, refilled when empty, and a random tail, so every first
  #     byte turns up whether or not Requirement 9.1 lists it;
  #   * well_formed, truncated, extended, mutated, header: a valid PDU of a
  #     Requirement 9.1 opcode built with encode, kept whole, cut short (often
  #     inside its fixed fields, or just after a response's format or length
  #     byte so its entry list is empty), followed by random octets, with one
  #     parameter octet replaced (half the time the first, a response's
  #     format or length byte), or with random parameters in place of its
  #     own. Each shape draws its opcode from its own deck of the 17;
  #     extended draws from opcode x {stays within 517, goes past 517};
  #   * text: an ASCII first byte then valid UTF-8 with multi-byte
  #     characters, a String whose character count is not its byte count;
  #   * empty.
  # Inputs run to 531 bytes and pass 517 about one case in ten. Every shape
  # but text is tagged binary, UTF-8 (random octets are mostly invalid
  # UTF-8), US-ASCII or UTF-16LE; text is tagged UTF-8.
  #
  # What decode may return is restated here rather than read from the
  # subject: the class for each Requirement 9.1 opcode and the Malformed
  # reasons for the Requirement 9.2 classes. A typed result has to re-encode
  # to exactly the input bytes, so decode accepted nothing but a valid PDU
  # (encode raises for anything decode could not have produced from one). A
  # Malformed carries the first byte as its opcode; only the empty String
  # gives nil and :empty. Past 517 bytes, or with a first byte 9.1 does not
  # list, the result is Malformed whichever reason wins.
  #
  # The input is [shape, encoding, hex of the PDU, hex of the declaration
  # value]. A plain Array is not shrinkable in rantly, so a failing case is
  # printed as generated, and every expectation derives from those four.
  it "Property 8: decode and the declaration decoders never raise and return a typed PDU or a Malformed for any String" do
    max_pdu = 517
    classes = {
      0x01 => codec::ErrorResponse,           0x02 => codec::ExchangeMtuRequest,
      0x03 => codec::ExchangeMtuResponse,     0x04 => codec::FindInformationRequest,
      0x05 => codec::FindInformationResponse, 0x06 => codec::FindByTypeValueRequest,
      0x08 => codec::ReadByTypeRequest,       0x09 => codec::ReadByTypeResponse,
      0x0A => codec::ReadRequest,             0x0B => codec::ReadResponse,
      0x0C => codec::ReadBlobRequest,         0x0D => codec::ReadBlobResponse,
      0x10 => codec::ReadByGroupTypeRequest,  0x11 => codec::ReadByGroupTypeResponse,
      0x1B => codec::HandleValueNotification, 0x1D => codec::HandleValueIndication,
      0x1E => codec::HandleValueConfirmation
    }
    opcodes = classes.keys
    expect(opcodes).to eq(req_9_1_opcodes)
    # One reason per Requirement 9.2 class of a non-empty PDU; the empty PDU
    # has its own, :empty.
    reasons = %i[too_long unknown_opcode too_short trailing_bytes bad_uuid_length bad_format bad_length
                 no_entries ragged_entries]
    bad_declaration = codec::Malformed.new(opcode: nil, reason: :bad_declaration_length)
    binary = Encoding::BINARY.name
    encodings = [binary, Encoding::UTF_8.name, Encoding::US_ASCII.name, Encoding::UTF_16LE.name]
    shapes = %i[sweep well_formed truncated extended mutated header text empty]
    decks = Hash.new { |h, name| h[name] = [] }
    firsts = Hash.new(0)
    seen = Hash.new(0)

    # Procs and lambdas here run under rantly's instance_eval, so they reach
    # the locals above and rantly's generators.
    property_of {
      # A card from the named deck, refilled with every card once it empties.
      draw = lambda do |name, cards|
        deck = decks[name]
        deck.replace(cards) if deck.empty?
        deck.delete_at(range(0, deck.size - 1))
      end
      u8  = -> { range(0x00, 0xFF) }
      u16 = -> { freq([3, proc { range(0, 0xFFFF) }], [1, proc { choose(0x0000, 0x0001, 0xFFFF) }]) }
      random_bytes = ->(n) { array(n) { range(0x00, 0xFF) }.pack("C*") }
      # 0..room: mostly small, sometimes anything, sometimes all of it.
      size_in = ->(room) { freq([3, proc { range(0, [24, room].min) }], [1, proc { range(0, room) }], [1, :literal, room]) }
      count_in = ->(most) { 1 + size_in.(most - 1) }
      uuid16  = -> { codec::Uuid.new(bits: 16, hex: format("%04x", range(0, 0xFFFF))) }
      uuid128 = -> { codec::Uuid.new(bits: 128, hex: format("%032x", range(0, 2**128 - 1))) }
      # A valid PDU of the opcode, as encode writes it, at most 517 bytes.
      # Entry counts top out at the most that fit: 2 + 18 * 28, 2 + 4 * 128,
      # 2 + 20 * 25 and 2 + 6 * 85.
      valid = lambda do |opcode|
        pdu =
          case opcode
          when 0x01 then codec::ErrorResponse.new(request_opcode: u8.(), handle: u16.(), error_code: u8.())
          when 0x02 then codec::ExchangeMtuRequest.new(mtu: u16.())
          when 0x03 then codec::ExchangeMtuResponse.new(mtu: u16.())
          when 0x04 then codec::FindInformationRequest.new(start_handle: u16.(), end_handle: u16.())
          when 0x05
            wide = boolean
            list = array(count_in.(wide ? 28 : 128)) { [u16.(), wide ? uuid128.() : uuid16.()] }
            codec::FindInformationResponse.new(format: wide ? 0x02 : 0x01, entries: list)
          when 0x06
            codec::FindByTypeValueRequest.new(start_handle: u16.(), end_handle: u16.(), uuid: uuid16.(),
                                              value: random_bytes.(size_in.(max_pdu - 7)))
          when 0x08, 0x10
            klass = opcode == 0x08 ? codec::ReadByTypeRequest : codec::ReadByGroupTypeRequest
            klass.new(start_handle: u16.(), end_handle: u16.(), uuid: boolean ? uuid16.() : uuid128.())
          when 0x09
            length = 2 + size_in.(253)
            list = array(count_in.((max_pdu - 2) / length)) { [u16.(), random_bytes.(length - 2)] }
            codec::ReadByTypeResponse.new(length: length, entries: list)
          when 0x0A then codec::ReadRequest.new(handle: u16.())
          when 0x0B then codec::ReadResponse.new(value: random_bytes.(size_in.(max_pdu - 1)))
          when 0x0C then codec::ReadBlobRequest.new(handle: u16.(), offset: u16.())
          when 0x0D then codec::ReadBlobResponse.new(value: random_bytes.(size_in.(max_pdu - 1)))
          when 0x11
            wide = boolean
            list = array(count_in.(wide ? 25 : 85)) { [u16.(), u16.(), wide ? uuid128.() : uuid16.()] }
            codec::ReadByGroupTypeResponse.new(length: wide ? 20 : 6, entries: list)
          when 0x1B
            codec::HandleValueNotification.new(handle: u16.(), value: random_bytes.(size_in.(max_pdu - 3)))
          when 0x1D
            codec::HandleValueIndication.new(handle: u16.(), value: random_bytes.(size_in.(max_pdu - 3)))
          when 0x1E then codec::HandleValueConfirmation.new
          end
        codec.encode(pdu)
      end

      shape = freq([6, :literal, :sweep], [3, :literal, :well_formed], [4, :literal, :truncated],
                   [3, :literal, :extended], [2, :literal, :mutated], [2, :literal, :header],
                   [1, :literal, :text], [1, :literal, :empty])
      pdu =
        case shape
        when :sweep
          tail = freq([4, proc { range(0, 8) }], [2, proc { range(0, 64) }], [1, proc { range(0, max_pdu - 1) }],
                      [1, :literal, max_pdu - 1], [1, proc { range(max_pdu, max_pdu + 13) }])
          [draw.(:sweep, (0x00..0xFF).to_a)].pack("C") + random_bytes.(tail)
        when :well_formed
          valid.(draw.(shape, opcodes))
        when :truncated
          whole = valid.(draw.(shape, opcodes))
          size = whole.bytesize
          # The first 7 octets hold every opcode's fixed fields; 2 is the
          # opcode and a response's format or length byte.
          keep = if size == 1 then 0
                 else freq([1, :literal, 1], [1, :literal, [2, size - 1].min],
                           [3, proc { range(1, [size, 7].min - 1) }], [2, proc { range(1, size - 1) }])
                 end
          whole.byteslice(0, keep)
        when :extended
          opcode, past = draw.(shape, opcodes.product([false, true]))
          whole = valid.(opcode)
          extra = past ? range(max_pdu + 1 - whole.bytesize, max_pdu + 14 - whole.bytesize) : range(1, 16)
          whole + random_bytes.(extra)
        when :mutated
          whole = valid.(draw.(shape, opcodes))
          whole.setbyte(boolean ? 1 : range(1, whole.bytesize - 1), u8.()) if whole.bytesize > 1
          whole
        when :header
          params = freq([3, proc { range(0, 2) }], [3, proc { range(0, 8) }], [2, proc { range(0, 24) }],
                        [1, proc { range(0, max_pdu - 1) }])
          [draw.(shape, opcodes)].pack("C") + random_bytes.(params)
        when :text
          first = freq([3, proc { choose(*opcodes) }], [1, proc { range(0x00, 0x7F) }])
          [first].pack("C") + array(range(0, 40)) { choose("a", "\u0000", "\u00e9", "\u20ac", "\u{1F600}") }.join.b
        when :empty
          "".b
        end
      encoding = shape == :text ? Encoding::UTF_8.name : freq([4, :literal, encodings[0]], [3, :literal, encodings[1]],
                                                              [1, :literal, encodings[2]], [1, :literal, encodings[3]])
      declaration = random_bytes.(freq([3, proc { choose(4, 5, 6, 19) }], [1, proc { choose(3, 7, 18, 20) }],
                                       [2, proc { range(0, 40) }]))

      [shape, encoding, pdu.unpack1("H*"), declaration.unpack1("H*")]
    # 2000 rather than 100 for the coverage assertions below. The rarest
    # Malformed reason, :no_entries, comes from about 1 case in 130 (a
    # response cut just after its format or length byte, or a Read By Type
    # Response header with one parameter octet): 2000 cases average 15.5 of
    # them (minimum 9 over 40 runs), missing it well under once in 10^6 runs,
    # where 100 would miss it in most. :bad_format and :bad_length average
    # 21. The decks make the rest all but certain: every first byte (about
    # 545 sweep draws against a 256-card deck), every opcode typed (about 16
    # well_formed draws each) and every opcode Malformed (about 8 extended
    # draws past 517 each, the only way a Read or Read Blob Response can be
    # Malformed). The 2000 cases take about 0.3 s.
    }.check(2000) { |shape, encoding, pdu_hex, declaration_hex|
      input = [pdu_hex].pack("H*").force_encoding(encoding)
      raw = input.b
      first = raw.getbyte(0)
      seen[shape] += 1
      seen[encoding] += 1
      firsts[first] += 1 if first
      if encoding == Encoding::UTF_8.name
        utf8 = if !input.valid_encoding? then :utf8_invalid
               elsif input.length < raw.bytesize then :utf8_multibyte
               else :utf8_ascii
               end
        seen[utf8] += 1
      end
      seen[:max_length] += 1 if raw.bytesize == max_pdu
      seen[:past_max_length] += 1 if raw.bytesize > max_pdu

      result = nil
      expect { result = codec.decode(input) }.not_to raise_error
      expect(result).to be_an_instance_of(codec::Malformed) if raw.bytesize > max_pdu || !classes.key?(first)
      if result.is_a?(codec::Malformed)
        if raw.empty?
          expect(result).to eq(codec::Malformed.new(opcode: nil, reason: :empty))
        else
          expect(result.opcode).to eq(first)
          expect(reasons).to include(result.reason)
        end
        seen[[:malformed, result.reason]] += 1
        seen[[:malformed, first]] += 1
      else
        expect(result).to be_an_instance_of(classes.fetch(first))
        expect(codec.encode(result)).to eq(raw)
        seen[[:typed, first]] += 1
      end
      seen[[result.is_a?(codec::Malformed) ? :malformed : :typed, :non_binary]] += 1 unless encoding == binary

      value = [declaration_hex].pack("H*").force_encoding(encoding)
      characteristic = included = nil
      expect { characteristic = codec.decode_characteristic_declaration(value) }.not_to raise_error
      expect { included = codec.decode_include_declaration(value) }.not_to raise_error
      if [5, 19].include?(value.bytesize)
        expect(characteristic).to be_an_instance_of(codec::CharacteristicDeclaration)
      else
        expect(characteristic).to eq(bad_declaration)
      end
      if [4, 6].include?(value.bytesize)
        expect(included).to be_an_instance_of(codec::IncludeDeclaration)
      else
        expect(included).to eq(bad_declaration)
      end
      seen[[:characteristic, characteristic.is_a?(codec::Malformed) ? :malformed : value.bytesize]] += 1
      seen[[:include, included.is_a?(codec::Malformed) ? :malformed : value.bytesize]] += 1
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect((0x00..0xFF).to_a - firsts.keys).to eq([])
    wanted = opcodes.flat_map { |op| [[:typed, op], [:malformed, op]] } +
             [:empty, *reasons].map { |reason| [:malformed, reason] } +
             shapes + encodings + %i[utf8_multibyte utf8_invalid max_length past_max_length] +
             [[:typed, :non_binary], [:malformed, :non_binary]] +
             [[:characteristic, 5], [:characteristic, 19], [:characteristic, :malformed],
              [:include, 4], [:include, 6], [:include, :malformed]]
    expect(wanted - seen.keys).to eq([])
  end
end
