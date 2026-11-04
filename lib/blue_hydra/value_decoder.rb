module BlueHydra
  # Best-effort rendering of GATT characteristic values read by the
  # Gatt_Walker. Pure functions with no state, so any Walk thread may call them.
  #
  # Decode order, first match wins:
  #   1. Identity_Set UUIDs use their dedicated encodings (decode_identity).
  #   2. A Characteristic Presentation Format (0x2904) decodes the value per its
  #      Format when that Format is supported and the octet count fits, and
  #      keeps it as hex otherwise. A present descriptor is authoritative, so a
  #      value it does not fit is not retried against the UTF-8 list below.
  #   3. A UUID in UTF8_STRING_CHARACTERISTICS decodes as UTF-8.
  #   4. Anything else stays lowercase hex.
  #
  # Values come from arbitrary peers, so every byte string has a rendering and
  # nothing here raises on one: a value that does not fit its declared shape is
  # kept as hex. Rendered values are Strings because they land in Text columns
  # and the gatt_characteristics JSON.
  module ValueDecoder
    # encoding is "identity", "format:<type>[;unit:0xNNNN]", "utf8" or "hex".
    # raw_hex is the received bytes as lowercase hex, set only for a decoded
    # non-identity value: a "hex" value already is the hex, and identity values
    # are stored in their own columns in their dedicated encoding.
    Decoded = Data.define(:value, :encoding, :raw_hex)

    # The 7-octet Characteristic Presentation Format value. exponent is signed;
    # unit is a 16-bit UUID from the SIG units table.
    PresentationFormat = Data.define(:format, :exponent, :unit, :namespace, :description)

    # Supported Presentation Format codes => [type, octet count]; nil count is a
    # variable-length string. Every other code (the floats including SFLOAT,
    # struct, nibble, 2-bit, uint12, uint128, sint12, sint48, sint64, sint128,
    # duint16, reserved) is not decoded and its value stays hex.
    FORMATS = {
      0x01 => [:boolean, 1],
      0x04 => [:uint8, 1], 0x06 => [:uint16, 2], 0x07 => [:uint24, 3],
      0x08 => [:uint32, 4], 0x09 => [:uint48, 6], 0x0A => [:uint64, 8],
      0x0C => [:sint8, 1], 0x0E => [:sint16, 2], 0x0F => [:sint24, 3], 0x10 => [:sint32, 4],
      0x19 => [:utf8s, nil], 0x1A => [:utf16s, nil]
    }.freeze

    SIGNED_FORMATS = %i[sint8 sint16 sint24 sint32].freeze

    # Boolean octets other than these are not a boolean and stay hex.
    BOOLEANS = { 0x00 => "false", 0x01 => "true" }.freeze

    # Unit 0x2700 is "unitless", so it adds no ";unit:" suffix.
    UNITLESS = 0x2700

    # Characteristics outside the Identity_Set whose value is defined as a
    # UTF-8 string, checked against the SIG definition of each. 0x2A3D
    # "String" is deliberately absent: it is gone from the SIG Assigned
    # Numbers and no current GSS or service specification defines its value.
    UTF8_STRING_CHARACTERISTICS = [
      0x2A87, # Email Address  (GSS: utf8s)
      0x2A8A, # First Name     (GSS: utf8s)
      0x2A90, # Last Name      (GSS: utf8s)
      0x2AB5, # Location Name  (Indoor Positioning Service 1.0 3.9: UTF-8 string)
      0x2AB6, # URI            (HTTP Proxy Service 1.0 3.1: utf8s)
      0x2ABE  # Object Name    (GSS: utf8s)
    ].freeze

    # Identity_Set strings: Device Name, Model Number, Serial Number, Firmware,
    # Hardware and Software Revision, Manufacturer Name.
    IDENTITY_STRINGS = [0x2A00, 0x2A24, 0x2A25, 0x2A26, 0x2A27, 0x2A28, 0x2A29].freeze

    APPEARANCE    = 0x2A01
    SYSTEM_ID     = 0x2A23
    PNP_ID        = 0x2A50
    DATABASE_HASH = 0x2B2A

    # Fixed-size Identity_Set values; any other length is malformed.
    IDENTITY_LENGTHS = { APPEARANCE => 2, SYSTEM_ID => 8, PNP_ID => 7, DATABASE_HASH => 16 }.freeze

    # The Bluetooth Base UUID 0000xxxx-0000-1000-8000-00805f9b34fb after the
    # 16-bit field, hyphens removed. A 128-bit spelling of a SIG UUID must
    # decode the same as its 16-bit form.
    BASE_UUID_TAIL = "00001000800000805f9b34fb".freeze

    class << self
      # The dedicated Identity_Set rendering: a String, nil for a string value
      # that is empty once trailing 0x00 bytes are stripped, or :malformed for
      # a fixed-size value of the wrong length. nil also for a UUID outside the
      # Identity_Set, which has no dedicated encoding.
      #
      # Trailing 0x00 is stripped because devices commonly NUL-pad fixed
      # buffers; nothing else is trimmed, so the stored string is what the
      # device sent.
      def decode_identity(uuid16, bytes)
        u16 = to_uuid16(uuid16)
        bytes = bytes.b
        if IDENTITY_STRINGS.include?(u16)
          text = utf8(strip_trailing_nuls(bytes))
          text.empty? ? nil : text
        elsif (length = IDENTITY_LENGTHS[u16])
          return :malformed unless bytes.bytesize == length

          case u16
          when APPEARANCE then format("0x%04x", bytes.unpack1("v"))
          # vendor ID source, vendor ID, product ID, product version
          when PNP_ID then format("0x%02x 0x%04x 0x%04x 0x%04x", *bytes.unpack("Cv3"))
          # System ID and Database Hash keep received byte order: they are
          # opaque identifiers, not numbers.
          else hex(bytes)
          end
        end
      end

      # nil unless exactly 7 octets, the descriptor's only defined size.
      def parse_presentation_format(bytes)
        bytes = bytes.b
        return nil unless bytes.bytesize == 7

        fmt, exponent, unit, namespace, description = bytes.unpack("CcvCv")
        PresentationFormat.new(format: fmt, exponent: exponent, unit: unit,
                               namespace: namespace, description: description)
      end

      # uuid is a 16-bit Integer, a hex String (4 or 32 digits, hyphens
      # optional) or anything with a String #hex such as AttCodec::Uuid. A
      # 128-bit UUID on the Bluetooth Base folds to its 16-bit form.
      def decode(uuid, bytes, presentation_format: nil)
        bytes = bytes.b
        u16 = to_uuid16(uuid)

        if IDENTITY_STRINGS.include?(u16) || IDENTITY_LENGTHS.key?(u16)
          value = decode_identity(u16, bytes)
          # The Gatt_Walker records a malformed identity value before reaching
          # here; there is no dedicated rendering for it, so it stays hex.
          return as_hex(bytes) if value == :malformed

          return Decoded.new(value: value, encoding: "identity", raw_hex: nil)
        end

        return decode_formatted(bytes, presentation_format) || as_hex(bytes) if presentation_format

        if UTF8_STRING_CHARACTERISTICS.include?(u16)
          return Decoded.new(value: utf8(strip_trailing_nuls(bytes)), encoding: "utf8", raw_hex: hex(bytes))
        end

        as_hex(bytes)
      end

      private

      def decode_formatted(bytes, pf)
        type, size = FORMATS[pf.format]
        return nil if type.nil? || (size && bytes.bytesize != size)

        value =
          case type
          when :boolean then BOOLEANS[bytes.getbyte(0)]
          when :utf8s   then utf8(bytes)
          when :utf16s  then utf16le(bytes)
          else scaled(little_endian(bytes, signed: SIGNED_FORMATS.include?(type)), pf.exponent)
          end
        return nil if value.nil?

        encoding = "format:#{type}"
        encoding += format(";unit:0x%04x", pf.unit) unless pf.unit == UNITLESS
        Decoded.new(value: value, encoding: encoding, raw_hex: hex(bytes))
      end

      def little_endian(bytes, signed:)
        value = bytes.bytes.reverse.inject(0) { |acc, byte| (acc << 8) | byte }
        bits = bytes.bytesize * 8
        signed && value >= (1 << (bits - 1)) ? value - (1 << bits) : value
      end

      # value * 10**exponent rendered exactly. Rational keeps it free of float
      # artefacts (2345 at -2 is "23.45", never 23.449999...), and a negative
      # exponent renders exactly -exponent fractional digits so the declared
      # resolution survives (100 at -2 is "1.00").
      def scaled(value, exponent)
        number = Rational(value) * (Rational(10)**exponent)
        return number.to_i.to_s if exponent >= 0

        digits = -exponent
        whole = number.truncate
        fraction = ((number - whole).abs * (10**digits)).to_i
        "#{'-' if number.negative?}#{whole.abs}.#{fraction.to_s.rjust(digits, '0')}"
      end

      # Each invalid sequence becomes U+FFFD (String#scrub's default for
      # Unicode encodings), so any byte string decodes.
      def utf8(bytes)
        bytes.dup.force_encoding(Encoding::UTF_8).scrub
      end

      # The Core specification's utf16s is little-endian. An unpaired surrogate
      # or an odd trailing byte is an invalid sequence and becomes U+FFFD.
      def utf16le(bytes)
        bytes.dup.force_encoding(Encoding::UTF_16LE).scrub.encode(Encoding::UTF_8)
      end

      def strip_trailing_nuls(bytes)
        length = bytes.bytesize
        length -= 1 while length.positive? && bytes.getbyte(length - 1).zero?
        bytes.byteslice(0, length)
      end

      def hex(bytes)
        bytes.unpack1("H*")
      end

      def as_hex(bytes)
        Decoded.new(value: hex(bytes), encoding: "hex", raw_hex: nil)
      end

      def to_uuid16(uuid)
        case uuid
        when Integer
          uuid if uuid.between?(0, 0xFFFF)
        when String
          digits = uuid.delete("-").downcase
          return nil unless digits.match?(/\A\h+\z/)

          if digits.length == 4
            digits.to_i(16)
          elsif digits.length == 32 && digits.start_with?("0000") && digits.end_with?(BASE_UUID_TAIL)
            digits[4, 4].to_i(16)
          end
        else
          hex = uuid.hex if uuid.respond_to?(:hex)
          to_uuid16(hex) if hex.is_a?(String)
        end
      end
    end
  end
end
