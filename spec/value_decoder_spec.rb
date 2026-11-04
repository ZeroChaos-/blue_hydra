require 'spec_helper'
require 'blue_hydra/value_decoder'

describe BlueHydra::ValueDecoder do
  # Locals rather than constants: a constant here would land on Object and be
  # shared with every other spec file. The examples close over them. The
  # expected tables are written out in full rather than read back from the
  # subject's own constants.

  # Stand-in for AttCodec::Uuid: decode accepts anything with a String #hex.
  hex_uuid = Struct.new(:hex)

  identity_strings = {
    0x2A00 => "Device Name",
    0x2A24 => "Model Number",
    0x2A25 => "Serial Number",
    0x2A26 => "Firmware Revision",
    0x2A27 => "Hardware Revision",
    0x2A28 => "Software Revision",
    0x2A29 => "Manufacturer Name"
  }

  utf8_characteristics = {
    0x2A87 => "Email Address",
    0x2A8A => "First Name",
    0x2A90 => "Last Name",
    0x2AB5 => "Location Name",
    0x2AB6 => "URI",
    0x2ABE => "Object Name"
  }

  # Requirement 7.15's supported Format codes; every other code stays hex.
  supported_formats = [0x01, 0x04, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0C, 0x0E, 0x0F, 0x10, 0x19, 0x1A]

  # Not on the Bluetooth Base UUID, so it never folds to a 16-bit UUID.
  vendor_uuid = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"

  def octets(*list)
    list.flatten.pack("C*")
  end

  def decoded(value, encoding, raw_hex)
    described_class::Decoded.new(value: value, encoding: encoding, raw_hex: raw_hex)
  end

  def hex_result(hex)
    decoded(hex, "hex", nil)
  end

  # Unit 0x2700 is "unitless", so by default no ";unit:" suffix is expected.
  def pf(format, exponent: 0, unit: 0x2700)
    described_class::PresentationFormat.new(format: format, exponent: exponent, unit: unit,
                                            namespace: 0x01, description: 0x0000)
  end

  def decode(uuid, bytes, presentation_format = nil)
    described_class.decode(uuid, bytes, presentation_format: presentation_format)
  end

  def decode_identity(uuid, bytes)
    described_class.decode_identity(uuid, bytes)
  end

  describe "Identity_Set strings (Requirement 7.10)" do
    identity_strings.each do |uuid, name|
      label = format("%s (0x%04x)", name, uuid)

      it "decodes #{label} as UTF-8 with trailing 0x00 stripped" do
        bytes = "Thingy:52\x00\x00".b
        expect(decode_identity(uuid, bytes)).to eq("Thingy:52")
        expect(decode(uuid, bytes)).to eq(decoded("Thingy:52", "identity", nil))
      end

      it "carries an empty or all-0x00 #{label} as no value" do
        ["".b, "\x00".b, "\x00\x00\x00".b].each do |bytes|
          expect(decode_identity(uuid, bytes)).to be_nil
          expect(decode(uuid, bytes)).to eq(decoded(nil, "identity", nil))
        end
      end
    end

    it "strips only trailing 0x00, keeping leading and embedded ones" do
      expect(decode_identity(0x2A00, "\x00ab\x00c\x00\x00".b)).to eq("\u0000ab\u0000c")
    end

    it "applies no other trimming" do
      expect(decode_identity(0x2A29, "  Acme \t\r\n".b)).to eq("  Acme \t\r\n")
    end

    it "replaces each invalid UTF-8 sequence with U+FFFD" do
      value = decode_identity(0x2A24, "ab\xFFcd\xC3\x00".b)
      expect(value).to eq("ab\uFFFDcd\uFFFD")
      expect(value.encoding).to eq(Encoding::UTF_8)
      expect(value).to be_valid_encoding
    end

    it "keeps valid multi-byte UTF-8" do
      expect(decode_identity(0x2A00, "Caf\u00e9 \u2615".b)).to eq("Caf\u00e9 \u2615")
    end

    it "accepts a value String in any encoding, frozen included" do
      expect(decode_identity(0x2A00, "Caf\u00e9\u0000".freeze)).to eq("Caf\u00e9")
      expect(decode(0x2A00, "Caf\u00e9".freeze)).to eq(decoded("Caf\u00e9", "identity", nil))
    end

    it "uses the identity encoding even when a Char_Presentation_Format is present" do
      expect(decode(0x2A00, "AB".b, pf(0x06))).to eq(decoded("AB", "identity", nil))
    end
  end

  describe "Identity_Set fixed-size renderings (Requirement 7.11)" do
    [
      # Appearance: 0x + 4 lowercase digits of the little-endian value, so the
      # second byte received is the high one.
      ["Appearance",    0x2A01, [0x41, 0x03], "0x0341"],
      ["Appearance",    0x2A01, [0xC1, 0x00], "0x00c1"],
      ["Appearance",    0x2A01, [0x00, 0x00], "0x0000"],
      ["Appearance",    0x2A01, [0xFF, 0xFF], "0xffff"],
      # System ID and Database Hash: 2 lowercase digits per byte, received
      # order, no separator. The vectors are asymmetric so a reversal shows.
      ["System ID",     0x2A23, [0x12, 0x34, 0x56, 0xFF, 0xFE, 0x9A, 0xBC, 0xDE], "123456fffe9abcde"],
      ["System ID",     0x2A23, [0x00] * 8, "0000000000000000"],
      ["Database Hash", 0x2B2A,
       [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
       "00112233445566778899aabbccddeeff"],
      ["Database Hash", 0x2B2A,
       [0xA5, 0x0F, 0x00, 0x01, 0x10, 0xF0, 0x7E, 0x81, 0x00, 0x00, 0x00, 0x00, 0x09, 0x90, 0xC3, 0x3C],
       "a50f000110f07e81000000000990c33c"],
      # PnP ID: vendor ID source (2 digits), then vendor ID, product ID and
      # product version, each little-endian and 4 digits, space separated.
      ["PnP ID",        0x2A50, [0x01, 0x4C, 0x00, 0x34, 0x12, 0xCD, 0xAB], "0x01 0x004c 0x1234 0xabcd"],
      ["PnP ID",        0x2A50, [0x02, 0x15, 0x19, 0x00, 0x00, 0xFF, 0xFF], "0x02 0x1915 0x0000 0xffff"]
    ].each do |name, uuid, list, rendering|
      it "renders #{name} #{list.map { |b| format('%02x', b) }.join(' ')} as #{rendering.inspect}" do
        bytes = octets(list)
        expect(decode_identity(uuid, bytes)).to eq(rendering)
        expect(decode(uuid, bytes)).to eq(decoded(rendering, "identity", nil))
      end
    end

    it "keeps trailing 0x00 bytes of a fixed-size value" do
      expect(decode_identity(0x2A23, octets(0xAB, 0xCD, 0, 0, 0, 0, 0, 0))).to eq("abcd000000000000")
      expect(decode_identity(0x2A01, octets(0x00, 0x00))).to eq("0x0000")
    end
  end

  describe "Identity_Set wrong lengths (Requirement 7.13)" do
    {
      "Appearance"    => [0x2A01, 2],
      "System ID"     => [0x2A23, 8],
      "PnP ID"        => [0x2A50, 7],
      "Database Hash" => [0x2B2A, 16]
    }.each do |name, (uuid, size)|
      [0, 1, size - 1, size + 1, size * 2].uniq.each do |length|
        it "treats a #{length}-byte #{name} as malformed and decode keeps it as hex" do
          list = Array.new(length) { |i| 0xA0 + i }
          expected_hex = list.map { |b| format("%02x", b) }.join

          expect(decode_identity(uuid, octets(list))).to eq(:malformed)
          expect(decode(uuid, octets(list))).to eq(hex_result(expected_hex))
        end
      end
    end

    it "does not strip 0x00 padding to reach the expected length" do
      expect(decode_identity(0x2A01, octets(0x41, 0x03, 0x00))).to eq(:malformed)
      expect(decode(0x2A01, octets(0x41, 0x03, 0x00))).to eq(hex_result("410300"))
    end
  end

  describe ".decode_identity outside the Identity_Set" do
    [0x2A19, 0x2A6E, 0x2A87, 0x2A3D, 0x1234, 0x0000, 0xFFFF, vendor_uuid, nil].each do |uuid|
      it "returns nil for #{uuid.is_a?(Integer) ? format('0x%04x', uuid) : uuid.inspect}" do
        expect(decode_identity(uuid, octets(0x41, 0x03))).to be_nil
        expect(decode_identity(uuid, "".b)).to be_nil
      end
    end
  end

  describe ".parse_presentation_format" do
    it "unpacks the 7 octets little-endian with a signed Exponent" do
      parsed = described_class.parse_presentation_format(octets(0x06, 0xFE, 0x2F, 0x27, 0x01, 0x34, 0x12))
      expect(parsed).to eq(described_class::PresentationFormat.new(format: 0x06, exponent: -2, unit: 0x272F,
                                                                   namespace: 0x01, description: 0x1234))
    end

    it "reads Exponent 0x7f as 127 and 0x80 as -128" do
      expect(described_class.parse_presentation_format(octets(0x04, 0x7F, 0, 0x27, 1, 0, 0)).exponent).to eq(127)
      expect(described_class.parse_presentation_format(octets(0x04, 0x80, 0, 0x27, 1, 0, 0)).exponent).to eq(-128)
    end

    [0, 1, 6, 8, 16].each do |length|
      it "returns nil for a #{length}-octet descriptor value" do
        expect(described_class.parse_presentation_format(octets([0x04] * length))).to be_nil
      end
    end
  end

  describe "Char_Presentation_Format decoding (Requirement 7.15)" do
    it "decodes uint16 with Exponent -2 and Unit 0x272f, rendering the unit as a 16-bit UUID" do
      # 0x0929 = 2345 hundredths of a degree Celsius, from a real descriptor value
      descriptor = described_class.parse_presentation_format(octets(0x06, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00))

      expect(decode(0x2A6E, octets(0x29, 0x09), descriptor))
        .to eq(decoded("23.45", "format:uint16;unit:0x272f", "2909"))
      expect(decode(0x2A6E, octets(0x64, 0x00), descriptor))
        .to eq(decoded("1.00", "format:uint16;unit:0x272f", "6400"))
    end

    describe "boolean" do
      it "decodes 0x00 as false and 0x01 as true" do
        expect(decode(0x1234, octets(0x00), pf(0x01))).to eq(decoded("false", "format:boolean", "00"))
        expect(decode(0x1234, octets(0x01), pf(0x01))).to eq(decoded("true", "format:boolean", "01"))
      end

      [0x02, 0x80, 0xFF].each do |byte|
        it "keeps #{format('0x%02x', byte)} as hex because it is not a boolean" do
          expect(decode(0x1234, octets(byte), pf(0x01))).to eq(hex_result(format("%02x", byte)))
        end
      end
    end

    describe "integers, little-endian" do
      [
        [0x04, "uint8",  [0x00], "0"],
        [0x04, "uint8",  [0xFF], "255"],
        [0x06, "uint16", [0x34, 0x12], "4660"],
        [0x06, "uint16", [0xFF, 0xFF], "65535"],
        [0x07, "uint24", [0x01, 0x02, 0x03], "197121"],
        [0x07, "uint24", [0xFF, 0xFF, 0xFF], "16777215"],
        [0x08, "uint32", [0x78, 0x56, 0x34, 0x12], "305419896"],
        [0x08, "uint32", [0xFF, 0xFF, 0xFF, 0xFF], "4294967295"],
        [0x09, "uint48", [0x01, 0x00, 0x00, 0x00, 0x00, 0x80], "140737488355329"],
        [0x09, "uint48", [0xFF] * 6, "281474976710655"],
        [0x0A, "uint64", [0x00] * 7 + [0x80], "9223372036854775808"],
        [0x0A, "uint64", [0xFF] * 8, "18446744073709551615"],
        [0x0C, "sint8",  [0x7F], "127"],
        [0x0C, "sint8",  [0x80], "-128"],
        [0x0C, "sint8",  [0xFF], "-1"],
        [0x0E, "sint16", [0xFF, 0x7F], "32767"],
        [0x0E, "sint16", [0x00, 0x80], "-32768"],
        [0x0E, "sint16", [0xFE, 0xFF], "-2"],
        # sint24 has no native pack directive, so its sign bit is bit 7 of
        # the third byte and must be extended by hand.
        [0x0F, "sint24", [0xFF, 0xFF, 0x7F], "8388607"],
        [0x0F, "sint24", [0x00, 0x00, 0x80], "-8388608"],
        [0x0F, "sint24", [0xFF, 0xFF, 0xFF], "-1"],
        [0x0F, "sint24", [0x18, 0xFC, 0xFF], "-1000"],
        [0x10, "sint32", [0xFF, 0xFF, 0xFF, 0x7F], "2147483647"],
        [0x10, "sint32", [0x00, 0x00, 0x00, 0x80], "-2147483648"],
        [0x10, "sint32", [0xFF, 0xFF, 0xFF, 0xFF], "-1"]
      ].each do |code, type, list, value|
        hex = list.map { |b| format("%02x", b) }.join

        it "decodes #{type} #{hex} as #{value}" do
          expect(decode(0x1234, octets(list), pf(code))).to eq(decoded(value, "format:#{type}", hex))
        end
      end
    end

    describe "Exponent" do
      [
        # positive and zero exponents render as an integer
        [0x04, [0x05], 0, "5"],
        [0x04, [0x05], 2, "500"],
        [0x0C, [0xFD], 1, "-30"],
        [0x04, [0x01], 127, "1#{'0' * 127}"],
        [0x0A, [0xFF] * 8, 3, "18446744073709551615000"],
        # a negative exponent renders exactly -exponent fractional digits
        [0x06, [0x64, 0x00], -2, "1.00"],
        [0x04, [0x05], -3, "0.005"],
        [0x04, [0x00], -2, "0.00"],
        [0x0E, [0xD7, 0xF6], -2, "-23.45"],
        [0x0C, [0xFB], -1, "-0.5"],
        [0x0C, [0xFF], -3, "-0.001"],
        [0x04, [0x01], -128, "0.#{'0' * 127}1"],
        # Rational, not Float: no binary rounding artefacts at 64 bits
        [0x0A, [0xFF] * 8, -2, "184467440737095516.15"]
      ].each do |code, list, exponent, value|
        it "scales #{list.map { |b| format('%02x', b) }.join} by 10**#{exponent} as #{value[0, 30].inspect}" do
          result = decode(0x1234, octets(list), pf(code, exponent: exponent))
          expect(result.value).to eq(value)
          expect(result.value).to be_a(String)
        end
      end

      it "does not apply to boolean or string formats" do
        expect(decode(0x1234, octets(0x01), pf(0x01, exponent: 3)).value).to eq("true")
        expect(decode(0x1234, "42".b, pf(0x19, exponent: -2)).value).to eq("42")
        expect(decode(0x1234, octets(0x34, 0x00, 0x32, 0x00), pf(0x1A, exponent: 2)).value).to eq("42")
      end
    end

    describe "Unit" do
      it "adds no unit suffix for 0x2700 unitless" do
        expect(decode(0x1234, octets(0x05), pf(0x04, unit: 0x2700)).encoding).to eq("format:uint8")
      end

      [0x0000, 0x2701, 0x272F, 0x27AD, 0xFFFF].each do |unit|
        it "renders Unit #{format('0x%04X', unit)} as a lowercase 16-bit UUID" do
          expect(decode(0x1234, octets(0x05), pf(0x04, unit: unit)).encoding)
            .to eq(format("format:uint8;unit:0x%04x", unit))
        end
      end

      it "applies to every supported format, not just integers" do
        expect(decode(0x1234, octets(0x01), pf(0x01, unit: 0x27AD)))
          .to eq(decoded("true", "format:boolean;unit:0x27ad", "01"))
        expect(decode(0x1234, "on".b, pf(0x19, unit: 0x2701)))
          .to eq(decoded("on", "format:utf8s;unit:0x2701", "6f6e"))
        expect(decode(0x1234, octets(0x6F, 0x00), pf(0x1A, unit: 0x2701)))
          .to eq(decoded("o", "format:utf16s;unit:0x2701", "6f00"))
      end
    end

    describe "utf8s (0x19)" do
      it "decodes UTF-8" do
        expect(decode(0x1234, "Caf\u00e9".b, pf(0x19))).to eq(decoded("Caf\u00e9", "format:utf8s", "436166c3a9"))
      end

      it "does not strip trailing 0x00, unlike the UTF-8 list" do
        expect(decode(0x1234, "ab\x00\x00".b, pf(0x19))).to eq(decoded("ab\u0000\u0000", "format:utf8s", "61620000"))
      end

      it "replaces invalid sequences with U+FFFD" do
        value = decode(0x1234, "a\xFFb".b, pf(0x19)).value
        expect(value).to eq("a\uFFFDb")
        expect(value).to be_valid_encoding
      end

      it "decodes an empty value as an empty string" do
        expect(decode(0x1234, "".b, pf(0x19))).to eq(decoded("", "format:utf8s", ""))
      end
    end

    describe "utf16s (0x1A), little-endian" do
      [
        ["ASCII",              [0x48, 0x00, 0x69, 0x00],       "Hi"],
        ["a BMP character",    [0xE9, 0x00],                   "\u00e9"],
        ["a surrogate pair",   [0x3D, 0xD8, 0x00, 0xDE],       "\u{1F600}"],
        ["an unpaired surrogate", [0x3D, 0xD8, 0x41, 0x00],    "\uFFFDA"],
        ["an odd byte count",  [0x48, 0x00, 0x69],             "H\uFFFD"],
        ["0x0000 code units",  [0x48, 0x00, 0x00, 0x00],       "H\u0000"]
      ].each do |label, list, value|
        it "decodes #{label} to UTF-8" do
          result = decode(0x1234, octets(list), pf(0x1A))
          expect(result).to eq(decoded(value, "format:utf16s", list.map { |b| format("%02x", b) }.join))
          expect(result.value.encoding).to eq(Encoding::UTF_8)
          expect(result.value).to be_valid_encoding
        end
      end
    end
  end

  describe "Char_Presentation_Format kept as hex (Requirement 7.16)" do
    [
      [0x14, "float32",           [0x00, 0x00, 0x80, 0x3F]],
      [0x15, "float64",           [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F]],
      [0x16, "SFLOAT",            [0x72, 0xF0]],
      [0x17, "FLOAT",             [0x6E, 0x01, 0x00, 0xFF]],
      [0x1B, "struct",            [0x01, 0x02, 0x03, 0x04, 0x05]],
      [0x02, "2bit",              [0x03]],
      [0x03, "nibble",            [0x0F]],
      [0x05, "uint12",            [0xFF, 0x0F]],
      [0x0B, "uint128",           [0xAB] * 16],
      [0x0D, "sint12",            [0xFF, 0x0F]],
      [0x11, "sint48",            [0xFF] * 6],
      [0x12, "sint64",            [0xFF] * 8],
      [0x13, "sint128",           [0xFF] * 16],
      [0x18, "duint16",           [0x01, 0x00, 0x02, 0x00]],
      [0x00, "reserved 0x00",     [0x01]],
      [0x1C, "medASN.1",          [0x30, 0x00]],
      [0xFF, "reserved 0xff",     [0x01]]
    ].each do |code, label, list|
      hex = list.map { |b| format("%02x", b) }.join

      it "keeps #{label} (#{format('0x%02x', code)}) #{hex} as hex" do
        expect(decode(0x1234, octets(list), pf(code))).to eq(hex_result(hex))
      end
    end

    it "keeps 1, 2, 4 and 8-byte values as hex for every Format outside the supported set" do
      (0x00..0xFF).reject { |code| supported_formats.include?(code) }.each do |code|
        [[0x80], [0x80, 0x01], [0x80, 0x01, 0x02, 0x03], [0x80] * 8].each do |list|
          expect(decode(0x1234, octets(list), pf(code, exponent: -2, unit: 0x272F)))
            .to eq(hex_result(list.map { |b| format("%02x", b) }.join)), "Format #{format('0x%02x', code)}, #{list.size} bytes"
        end
      end
    end

    [
      [0x01, "boolean", [[], [0x01, 0x00]]],
      [0x04, "uint8",   [[], [0x01, 0x00]]],
      [0x06, "uint16",  [[0x01], [0x01, 0x02, 0x03]]],
      [0x07, "uint24",  [[0x01, 0x02], [0x01, 0x02, 0x03, 0x04]]],
      [0x08, "uint32",  [[0x01, 0x02, 0x03], [0x01] * 5]],
      [0x09, "uint48",  [[0x01] * 5, [0x01] * 7]],
      [0x0A, "uint64",  [[0x01] * 7, [0x01] * 9]],
      [0x0C, "sint8",   [[], [0xFF, 0xFF]]],
      [0x0E, "sint16",  [[0xFF], [0xFF] * 3]],
      [0x0F, "sint24",  [[0xFF] * 2, [0xFF] * 4]],
      [0x10, "sint32",  [[0xFF] * 3, [0xFF] * 5]]
    ].each do |code, type, lists|
      it "keeps #{type} as hex when the octet count does not match" do
        lists.each do |list|
          expect(decode(0x1234, octets(list), pf(code))).to eq(hex_result(list.map { |b| format("%02x", b) }.join))
        end
      end
    end

    # A present descriptor is authoritative: a value it does not fit is not
    # retried against the UTF-8 list.
    it "does not fall through to the UTF-8 list when the descriptor does not fit" do
      expect(decode(0x2A8A, "Ada".b, pf(0x06))).to eq(hex_result("416461"))
      expect(decode(0x2A8A, "Ada".b, pf(0x1B))).to eq(hex_result("416461"))
    end

    it "decodes a UTF-8 list UUID per a descriptor that fits" do
      expect(decode(0x2A8A, "A".b, pf(0x04))).to eq(decoded("65", "format:uint8", "41"))
    end
  end

  describe "no Char_Presentation_Format (Requirement 7.17)" do
    it "lists exactly the six known UTF-8 string characteristics, without 0x2A3D" do
      expect(described_class::UTF8_STRING_CHARACTERISTICS).to eq(utf8_characteristics.keys)
      expect(described_class::UTF8_STRING_CHARACTERISTICS).not_to include(0x2A3D)
    end

    utf8_characteristics.each do |uuid, name|
      it "decodes #{name} (#{format('0x%04x', uuid)}) as UTF-8 with trailing 0x00 stripped" do
        expect(decode(uuid, "a@b.c\x00".b)).to eq(decoded("a@b.c", "utf8", "6140622e6300"))
      end
    end

    it "replaces invalid sequences with U+FFFD and keeps leading and embedded 0x00" do
      result = decode(0x2A90, "\x00L\xFFe\x00e\x00".b)
      expect(result).to eq(decoded("\u0000L\uFFFDe\u0000e", "utf8", "004cff65006500"))
      expect(result.value).to be_valid_encoding
    end

    it "decodes an all-0x00 value as an empty string, keeping raw_hex" do
      expect(decode(0x2AB6, "\x00\x00".b)).to eq(decoded("", "utf8", "0000"))
    end

    [
      ["String 0x2A3D, dropped from the list", 0x2A3D],
      ["Battery Level 0x2A19",                 0x2A19],
      ["an unassigned 16-bit UUID",            0x1234],
      ["0xFFFF",                               0xFFFF],
      ["a vendor 128-bit UUID",                vendor_uuid]
    ].each do |label, uuid|
      it "keeps #{label} as lowercase hex" do
        expect(decode(uuid, octets(0xAB, 0xCD, 0x00, 0x41))).to eq(hex_result("abcd0041"))
      end
    end

    it "keeps an empty unknown value as empty hex" do
      expect(decode(0x1234, "".b)).to eq(hex_result(""))
    end

    it "treats an explicit nil presentation_format as absent" do
      expect(described_class.decode(0x2A87, "x".b, presentation_format: nil)).to eq(decoded("x", "utf8", "78"))
      expect(described_class.decode(0x2A87, "x".b)).to eq(decoded("x", "utf8", "78"))
    end
  end

  describe "UUID forms" do
    let(:appearance) { octets(0x41, 0x03) }

    [
      ["a 16-bit Integer",                        0x2A01],
      ["4 lowercase hex digits",                  "2a01"],
      ["4 uppercase hex digits",                  "2A01"],
      ["the 128-bit Base UUID spelling",          "00002a01-0000-1000-8000-00805f9b34fb"],
      ["the 128-bit spelling in uppercase",       "00002A01-0000-1000-8000-00805F9B34FB"],
      ["the 128-bit spelling without hyphens",    "00002a0100001000800000805f9b34fb"],
      ["an object with a 16-bit String #hex",     hex_uuid.new("2a01")],
      ["an object with a 128-bit String #hex",    hex_uuid.new("00002a0100001000800000805f9b34fb")]
    ].each do |label, uuid|
      it "recognises Appearance given as #{label}" do
        expect(decode_identity(uuid, appearance)).to eq("0x0341")
        expect(decode(uuid, appearance)).to eq(decoded("0x0341", "identity", nil))
      end
    end

    it "folds a 128-bit spelling of a UTF-8 list UUID too" do
      expect(decode("00002a87-0000-1000-8000-00805f9b34fb", "x".b)).to eq(decoded("x", "utf8", "78"))
    end

    [
      ["a 128-bit UUID off the Base UUID tail",       "00002a01-0000-1000-8000-00805f9b34fc"],
      ["a 128-bit UUID with non-zero upper 16 bits",  "12342a01-0000-1000-8000-00805f9b34fb"],
      ["an Integer above 0xFFFF",                     0x12A01],
      ["a negative Integer",                          -1],
      ["a String that is not hex",                    "zz01"],
      ["an object whose #hex is not a String",        hex_uuid.new(0x2A01)],
      ["nil",                                         nil]
    ].each do |label, uuid|
      it "treats #{label} as unknown, keeping the value as hex" do
        expect(decode_identity(uuid, appearance)).to be_nil
        expect(decode(uuid, appearance)).to eq(hex_result("4103"))
      end
    end
  end

  describe "raw_hex" do
    # Requirement 7.12: retained, as the received bytes in lowercase hex,
    # whenever a non-identity decode was applied; absent for a hex value
    # (value already is the hex) and for an identity value.
    [
      ["format integer",   0x1234, [0xD7, 0xF6], 0x0E, "d7f6"],
      ["format boolean",   0x1234, [0x01],       0x01, "01"],
      ["format utf8s",     0x1234, [0x41, 0x00], 0x19, "4100"],
      ["format utf16s",    0x1234, [0x41, 0x00], 0x1A, "4100"],
      ["UTF-8 list",       0x2ABE, [0x41, 0x00], nil,  "4100"]
    ].each do |label, uuid, list, code, raw_hex|
      it "is the received bytes for a #{label} decode" do
        result = decode(uuid, octets(list), code && pf(code))
        expect(result.encoding).not_to eq("hex")
        expect(result.raw_hex).to eq(raw_hex)
      end
    end

    [
      ["an unknown UUID",                 0x1234, [0xAB, 0xCD], nil],
      ["an unsupported Format",           0x1234, [0xAB, 0xCD], 0x16],
      ["a wrong octet count",             0x1234, [0xAB, 0xCD], 0x04],
      ["a non-boolean boolean octet",     0x1234, [0xAB],       0x01],
      ["a malformed Identity_Set value",  0x2A01, [0xAB],       nil]
    ].each do |label, uuid, list, code|
      it "is absent for #{label} kept as hex" do
        result = decode(uuid, octets(list), code && pf(code))
        expect(result.encoding).to eq("hex")
        expect(result.raw_hex).to be_nil
      end
    end

    it "is absent for an identity value" do
      expect(decode(0x2A00, "Name".b).raw_hex).to be_nil
      expect(decode(0x2B2A, octets([0x01] * 16)).raw_hex).to be_nil
    end
  end

  # Feature: gatt-service-scanning, Property 5: The Value_Decoder matches its reference model and never raises
  #
  # Validates: Requirements 7.10, 7.12, 7.15, 7.16, 7.17, 7.18
  #
  # The expected Decoded comes from a reference model restated here from the
  # requirements, not from the subject's constants or private helpers, so the
  # subject is not graded against itself:
  #   * UTF-8 and UTF-16LE are decoded by hand following the WHATWG decoders
  #     (one U+FFFD per maximal invalid subpart; one for an unpaired surrogate;
  #     one for input ending mid-sequence, an odd trailing byte included).
  #     Checked against String#scrub on 200,000 random and adversarial inputs
  #     with no mismatch before relying on it.
  #   * integers are summed little-endian by hand and scaled with Integer
  #     arithmetic only: the digits of |n| padded to -exponent + 1 and split.
  #   * the generator records the 16-bit UUID each spelling denotes (nil for a
  #     128-bit UUID off the Bluetooth Base), so Base UUID folding is checked
  #     against what was constructed rather than re-derived.
  #
  # The generator is biased so every branch is reached (asserted after the
  # run): Identity_Set, UTF-8 list and random UUIDs in every accepted spelling;
  # mostly supported Formats; value lengths that match the Format's or the
  # identity value's octet count about half the time; text built from valid,
  # invalid and NUL-padded pieces. Every expectation derives from the printed
  # tuple [uuid, u16 it denotes, bytes, presentation_format] alone, so a failing
  # case can be reproduced from rantly's output.
  it "Property 5: matches its reference model and never raises for any value, UUID and Char_Presentation_Format" do
    pf_class = described_class::PresentationFormat
    decoded_class = described_class::Decoded

    # Requirement 7.15's supported Formats: code => [type, octet count (nil
    # for strings), signed].
    model_formats = {
      0x01 => [:boolean, 1, false],
      0x04 => [:uint8, 1, false], 0x06 => [:uint16, 2, false], 0x07 => [:uint24, 3, false],
      0x08 => [:uint32, 4, false], 0x09 => [:uint48, 6, false], 0x0A => [:uint64, 8, false],
      0x0C => [:sint8, 1, true], 0x0E => [:sint16, 2, true], 0x0F => [:sint24, 3, true],
      0x10 => [:sint32, 4, true],
      0x19 => [:utf8s, nil, false], 0x1A => [:utf16s, nil, false]
    }
    expect(model_formats.keys).to match_array(supported_formats)

    # Requirement 7.13's fixed sizes.
    identity_lengths = { 0x2A01 => 2, 0x2A23 => 8, 0x2A50 => 7, 0x2B2A => 16 }
    # The Bluetooth Base UUID after its 16-bit field.
    base_tail = "-0000-1000-8000-00805f9b34fb"
    hex_digits = "0123456789abcdef".chars
    text_pieces = ["a", "Z", " ", "\t", "\u00e9", "\u2615", "\u{1F600}", "\x00", "\xFF", "\xC3", "\x80",
                   "\xED\xA0\x80", "\xF0\x90", "\xE3\x81", "\xC0\xAF", "\x3D\xD8", "\x00\xDC", "\x48\x00"].map(&:b)

    to_hex = ->(bytes) { bytes.each_byte.map { |b| format("%02x", b) }.join }

    strip_nuls = lambda do |bytes|
      list = bytes.bytes
      list.pop while list.last == 0
      list.pack("C*")
    end

    utf8_ref = lambda do |bytes|
      list = bytes.bytes
      points = []
      i = 0
      while i < list.size
        lead = list[i]
        if lead < 0x80
          points << lead
          i += 1
          next
        end
        # continuation count, allowed range of the first continuation, lead bits
        need, low, high, point =
          case lead
          when 0xC2..0xDF               then [1, 0x80, 0xBF, lead & 0x1F]
          when 0xE0                     then [2, 0xA0, 0xBF, lead & 0x0F]
          when 0xE1..0xEC, 0xEE..0xEF   then [2, 0x80, 0xBF, lead & 0x0F]
          when 0xED                     then [2, 0x80, 0x9F, lead & 0x0F]
          when 0xF0                     then [3, 0x90, 0xBF, lead & 0x07]
          when 0xF1..0xF3               then [3, 0x80, 0xBF, lead & 0x07]
          when 0xF4                     then [3, 0x80, 0x8F, lead & 0x07]
          end
        unless need
          points << 0xFFFD
          i += 1
          next
        end
        j = i + 1
        complete = need.times.all? do |k|
          byte = list[j]
          ok = byte && byte.between?(k.zero? ? low : 0x80, k.zero? ? high : 0xBF)
          if ok
            point = (point << 6) | (byte & 0x3F)
            j += 1
          end
          ok
        end
        # On a bad continuation the offending byte is not consumed.
        points << (complete ? point : 0xFFFD)
        i = j
      end
      points.pack("U*")
    end

    utf16le_ref = lambda do |bytes|
      list = bytes.bytes
      points = []
      pending = nil
      i = 0
      while i + 1 < list.size
        unit = list[i] | (list[i + 1] << 8)
        i += 2
        if pending
          lead = pending
          pending = nil
          if unit.between?(0xDC00, 0xDFFF)
            points << (0x10000 + ((lead - 0xD800) << 10) + (unit - 0xDC00))
            next
          end
          points << 0xFFFD # unpaired high surrogate; this unit is processed afresh
        end
        if unit.between?(0xD800, 0xDBFF) then pending = unit
        elsif unit.between?(0xDC00, 0xDFFF) then points << 0xFFFD
        else points << unit
        end
      end
      points << 0xFFFD if pending || i < list.size
      points.pack("U*")
    end

    little_endian_ref = lambda do |bytes, signed|
      n = bytes.bytes.each_with_index.sum { |byte, i| byte << (8 * i) }
      bits = 8 * bytes.bytesize
      signed && n >= 2**(bits - 1) ? n - 2**bits : n
    end

    scaled_ref = lambda do |n, exponent|
      if exponent >= 0
        (n * 10**exponent).to_s
      else
        digits = -exponent
        magnitude = n.abs.to_s.rjust(digits + 1, "0")
        "#{'-' if n.negative?}#{magnitude[0...-digits]}.#{magnitude[-digits..]}"
      end
    end

    # [[value, encoding, raw_hex], branch label]
    model = lambda do |u16, bytes, pf|
      hex = to_hex.call(bytes)
      as_hex = [hex, "hex", nil]

      if identity_strings.key?(u16)
        text = utf8_ref.call(strip_nuls.call(bytes))
        return text.empty? ? [[nil, "identity", nil], :identity_empty] : [[text, "identity", nil], :identity_text]
      end

      if (length = identity_lengths[u16])
        return [as_hex, :identity_malformed] unless bytes.bytesize == length

        o = bytes.bytes
        value = case u16
                when 0x2A01 then format("0x%04x", o[0] | (o[1] << 8))
                when 0x2A50 then format("0x%02x 0x%04x 0x%04x 0x%04x",
                                        o[0], o[1] | (o[2] << 8), o[3] | (o[4] << 8), o[5] | (o[6] << 8))
                else hex
                end
        return [[value, "identity", nil], :identity_fixed]
      end

      if pf
        # A present descriptor is authoritative: no fall-through to the UTF-8 list.
        type, size, signed = model_formats[pf.format]
        return [as_hex, :format_unfit] if type.nil? || (size && bytes.bytesize != size)

        value, branch =
          case type
          when :boolean then [{ 0x00 => "false", 0x01 => "true" }[bytes.getbyte(0)], :format_boolean]
          when :utf8s   then [utf8_ref.call(bytes), :format_string]
          when :utf16s  then [utf16le_ref.call(bytes), :format_string]
          else [scaled_ref.call(little_endian_ref.call(bytes, signed), pf.exponent), :format_integer]
          end
        return [as_hex, :format_unfit] if value.nil?

        encoding = "format:#{type}"
        encoding += format(";unit:0x%04x", pf.unit) unless pf.unit == 0x2700
        return [[value, encoding, hex], branch]
      end

      return [[utf8_ref.call(strip_nuls.call(bytes)), "utf8", hex], :utf8_list] if utf8_characteristics.key?(u16)

      [as_hex, :unknown]
    end

    seen = Hash.new(0)

    # Procs and blocks here run under rantly's instance_eval, so they reach the
    # locals above but not the example's helper methods.
    property_of {
      u16 = case freq([3, :literal, :identity_string], [3, :literal, :identity_fixed], [3, :literal, :utf8_list],
                      [3, :literal, :random16], [2, :literal, :off_base])
            when :identity_string then choose(*identity_strings.keys)
            when :identity_fixed  then choose(*identity_lengths.keys)
            when :utf8_list       then choose(*utf8_characteristics.keys)
            when :random16        then range(0, 0xFFFF)
            end

      uuid =
        if u16
          long = format("0000%04x", u16) + base_tail
          choose(u16, u16, format("%04x", u16), format("%04X", u16), long, long.upcase, long.delete("-"),
                 hex_uuid.new(format("%04x", u16)), hex_uuid.new(long.delete("-")))
        else
          digits =
            if boolean
              # random, with non-zero upper 16 bits so it cannot be on the Base
              format("%04x", range(1, 0xFFFF)) + array(28) { choose(*hex_digits) }.join
            else
              # one digit off the Base UUID, outside the 16-bit field
              near = format("0000%04x", range(0, 0xFFFF)) + base_tail.delete("-")
              at = choose(*(0..3).to_a, *(8..31).to_a)
              near[at] = choose(*(hex_digits - [near[at]]))
              near
            end
          dashed = [digits[0, 8], digits[8, 4], digits[12, 4], digits[16, 4], digits[20, 12]].join("-")
          choose(dashed, dashed.upcase, digits, hex_uuid.new(digits))
        end

      pf =
        unless range(0, 2).zero?
          code = freq([8, proc { choose(*supported_formats) }], [5, :literal, 0x01],
                      [2, proc { choose(0x19, 0x1A) }], [3, proc { range(0x00, 0xFF) }])
          pf_class.new(format: code,
                       exponent: freq([3, proc { range(-4, 4) }], [1, proc { range(-128, 127) }]),
                       unit: freq([2, :literal, 0x2700], [3, proc { range(0, 0xFFFF) }],
                                  [1, proc { choose(0x0000, 0x2701, 0x272F, 0x27AD, 0xFFFF) }]),
                       namespace: range(0, 0xFF), description: range(0, 0xFFFF))
        end

      fits = [identity_lengths[u16], pf && model_formats.dig(pf.format, 1)].compact
      mode = freq([8, :literal, :fit], [2, :literal, :short], [1, :literal, :long], [3, :literal, :text])
      bytes =
        if mode == :text
          (array(range(0, 12)) { choose(*text_pieces) }.join.b + ("\x00".b * range(0, 3))).byteslice(0, 512)
        else
          n = case mode
              when :fit   then fits.empty? ? range(0, 8) : choose(*fits)
              when :short then range(0, 16)
              else range(0, 512)
              end
          list = case freq([3, :literal, :random], [1, :literal, :zeros], [3, :literal, :edges])
                 when :random then array(n) { range(0x00, 0xFF) }
                 when :zeros  then [0x00] * n
                 else array(n) { choose(0x00, 0x01, 0x7F, 0x80, 0xFF) }
                 end
          list.pack("C*")
        end
      # decode takes a value String in any encoding.
      bytes = freq([3, :literal, bytes], [1, proc { bytes.dup.force_encoding(Encoding::UTF_8) }])

      [uuid, u16, bytes, pf]
    # 500 rather than 100 for the coverage assertion below: over 20,000 cases
    # the rarest branch, a boolean that decodes, was 2.2% of inputs, so 500
    # misses it about once in 10^5 runs. The run takes well under 0.1 s.
    }.check(500) { |uuid, u16, bytes, pf|
      raw = bytes.b
      (value, encoding, raw_hex), branch = model.call(u16, raw, pf)
      seen[branch] += 1

      result = nil
      expect { result = described_class.decode(uuid, bytes, presentation_format: pf) }.not_to raise_error
      expect(result).to eq(decoded_class.new(value: value, encoding: encoding, raw_hex: raw_hex))

      # Restated from Requirement 7.12 on the result alone.
      if %w[hex identity].include?(result.encoding)
        expect(result.raw_hex).to be_nil
      else
        expect(result.raw_hex).to eq(to_hex.call(raw))
      end
      expect(result.value).to eq(to_hex.call(raw)) if result.encoding == "hex"
      if result.value.is_a?(String)
        expect(result.value).to be_valid_encoding
        expect(result.value.encoding).to eq(Encoding::UTF_8) if %i[identity_text format_string utf8_list].include?(branch)
      end
    }

    # A generator that stopped reaching a branch would let the property pass
    # without testing it.
    expect(%i[identity_text identity_empty identity_fixed identity_malformed format_integer format_boolean
              format_string format_unfit utf8_list unknown] - seen.keys).to eq([])
  end
end
