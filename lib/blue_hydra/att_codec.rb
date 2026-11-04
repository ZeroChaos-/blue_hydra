module BlueHydra
  # Encoder and decoder for ATT PDUs, laid out per Bluetooth Core 6.3 Vol 3
  # Part F section 3.4, plus decoders for the include and characteristic
  # declaration values (Part G sections 3.2 and 3.3.1) that Read By Type
  # Response entries carry. This is the only place the GATT walk parses or
  # produces ATT bytes.
  #
  # decode is fed whatever the peer put on the bearer, so it never raises: any
  # String yields either a typed PDU or a Malformed. A Malformed still carries
  # the first byte as its opcode, because the walker needs it to tell a broken
  # response (ends that discovery procedure as partial) from a broken peer
  # request (answered with Invalid PDU) or a broken indication (still
  # confirmed, or the peer stalls for its 30 s transaction timeout). The
  # declaration decoders likewise return a Malformed rather than raise.
  #
  # encode is fed only structures we built, so it is strict instead: it raises
  # ArgumentError for anything decode could not have produced from a valid PDU
  # (a Malformed, a field out of range for its octets, a UUID of the wrong
  # width, an empty entry list, a length or format byte its entries disagree
  # with) and for a result longer than MAX_PDU. Accepting exactly what decode
  # produces is what makes encode(decode(b)) == b for every valid PDU b. A
  # lenient encoder would put bytes on air that parse as something other than
  # the structure we built: the peer splits a Read By Type Response by its
  # length byte alone, so one value of the wrong length re-frames every entry
  # after it.
  #
  # Multi-octet fields are little-endian on air. Handles come back exactly as
  # received, with no range or ordering checks: only the walker knows the
  # search range a response has to fall inside.
  module AttCodec
    # Both sides of our bearer advertise an Rx MTU of 517 (Exchange MTU Request
    # and our answer to the peer's), so the agreed ATT_MTU is at most 517 and no
    # valid PDU can be longer.
    MAX_PDU = 517

    # bits is 16 or 128, keeping the width the UUID had on air. hex is
    # lowercase with no hyphens, 4 or 32 characters, most-significant byte
    # first: the on-air order is little-endian, the written order (Nordic
    # database, le_service_uuids) is not.
    Uuid = Data.define(:bits, :hex)

    # One class per opcode the walker or the Att_Server handles. Values are
    # binary Strings; entries are Arrays as noted.
    ErrorResponse            = Data.define(:request_opcode, :handle, :error_code)
    ExchangeMtuRequest       = Data.define(:mtu)
    ExchangeMtuResponse      = Data.define(:mtu)
    FindInformationRequest   = Data.define(:start_handle, :end_handle)
    FindInformationResponse  = Data.define(:format, :entries)          # entries [[handle, Uuid], ...]
    FindByTypeValueRequest   = Data.define(:start_handle, :end_handle, :uuid, :value)
    ReadByTypeRequest        = Data.define(:start_handle, :end_handle, :uuid)
    ReadByTypeResponse       = Data.define(:length, :entries)          # entries [[handle, value], ...]
    ReadRequest              = Data.define(:handle)
    ReadResponse             = Data.define(:value)
    ReadBlobRequest          = Data.define(:handle, :offset)
    ReadBlobResponse         = Data.define(:value)
    ReadByGroupTypeRequest   = Data.define(:start_handle, :end_handle, :uuid)
    ReadByGroupTypeResponse  = Data.define(:length, :entries)          # entries [[handle, end_group_handle, Uuid], ...]
    HandleValueNotification  = Data.define(:handle, :value)
    HandleValueIndication    = Data.define(:handle, :value)
    HandleValueConfirmation  = Data.define

    # reason is one of :empty, :too_long, :unknown_opcode, :too_short,
    # :trailing_bytes, :bad_uuid_length, :bad_format, :bad_length,
    # :no_entries, :ragged_entries, or :bad_declaration_length from the
    # declaration decoders. opcode is nil for an empty PDU and for a
    # declaration value, which is a field inside a PDU rather than a PDU.
    Malformed = Data.define(:opcode, :reason)

    # Values of characteristic (0x2803) and include (0x2802) declarations.
    # properties is the raw bit field. An include declaration names the
    # included service's UUID only when that UUID is 16-bit; for a 128-bit
    # service it is 4 bytes and uuid is nil, left to the walker to fill in
    # from the services it has discovered.
    CharacteristicDeclaration = Data.define(:properties, :value_handle, :uuid)
    IncludeDeclaration        = Data.define(:start_handle, :end_handle, :uuid)

    OPCODES = {
      ErrorResponse           => 0x01,
      ExchangeMtuRequest      => 0x02,
      ExchangeMtuResponse     => 0x03,
      FindInformationRequest  => 0x04,
      FindInformationResponse => 0x05,
      FindByTypeValueRequest  => 0x06,
      ReadByTypeRequest       => 0x08,
      ReadByTypeResponse      => 0x09,
      ReadRequest             => 0x0A,
      ReadResponse            => 0x0B,
      ReadBlobRequest         => 0x0C,
      ReadBlobResponse        => 0x0D,
      ReadByGroupTypeRequest  => 0x10,
      ReadByGroupTypeResponse => 0x11,
      HandleValueNotification => 0x1B,
      HandleValueIndication   => 0x1D,
      HandleValueConfirmation => 0x1E,
    }.freeze

    # Opcodes that answer a client request: the *_RSP rows of the opcode
    # summary (Part F section 3.4.8). A PDU carrying one is matched against the
    # walker's outstanding request (or dropped as a stray) and is never
    # answered as a peer request. That includes Read Multiple Variable Response
    # (0x21, added in Core 5.2) even though we never send its request: left
    # out, a stray 0x21 would be refused with Error Response 0x06 as if the
    # peer had asked us something. Multiple Handle Value Notification (0x23,
    # also 5.2) is server-initiated and answers nothing, so it is not here.
    RESPONSE_OPCODES = [0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19, 0x21].freeze

    # Bit 6 of the opcode. A command (Write Command 0x52, Signed Write Command
    # 0xD2, ...) expects no reply, so a peer command must never be answered.
    COMMAND_FLAG = 0x40

    UUID_SIZES = [2, 16].freeze

    # Find Information Response format byte -> entry size: a 2-octet handle
    # plus a 16-bit (0x01) or 128-bit (0x02) UUID.
    FIND_INFORMATION_ENTRY_SIZES = { 0x01 => 4, 0x02 => 18 }.freeze

    # The walker only issues Read By Group Type for service declarations
    # (0x2800/0x2801), whose value is a 16- or 128-bit UUID, so an entry is a
    # 2-octet handle, a 2-octet end group handle and 2 or 16 UUID octets. Any
    # other length cannot be a service declaration.
    GROUP_ENTRY_SIZES = [6, 20].freeze

    # Properties (1 octet) and value handle (2) then a 16- or 128-bit UUID.
    CHARACTERISTIC_DECLARATION_SIZES = [5, 19].freeze

    # The Uuid#hex encode accepts for each width: lowercase, as decode renders
    # it, so an encodable Uuid always decodes back equal.
    UUID_HEX = { 16 => /\A[0-9a-f]{4}\z/, 128 => /\A[0-9a-f]{32}\z/ }.freeze

    class << self
      # Any String in any encoding -> typed PDU or Malformed. Never raises.
      def decode(bytes)
        bytes = bytes.b
        return Malformed.new(opcode: nil, reason: :empty) if bytes.empty?
        opcode = bytes.getbyte(0)
        reason = catch(:malformed) do
          malformed!(:too_long) if bytes.bytesize > MAX_PDU
          return decode_params(opcode, bytes.byteslice(1..))
        end
        Malformed.new(opcode: opcode, reason: reason)
      end

      # Typed PDU -> binary String, or ArgumentError (see the module comment).
      def encode(pdu)
        raise ArgumentError, "a Malformed cannot be encoded: #{pdu.inspect}" if pdu.is_a?(Malformed)
        bytes = put_u8(opcode_of(pdu), "opcode") << encode_params(pdu)
        raise ArgumentError, "PDU is #{bytes.bytesize} bytes, longer than #{MAX_PDU}" if bytes.bytesize > MAX_PDU
        bytes
      end

      # Any String -> CharacteristicDeclaration or Malformed. Never raises.
      def decode_characteristic_declaration(value)
        value = value.b
        unless CHARACTERISTIC_DECLARATION_SIZES.include?(value.bytesize)
          return Malformed.new(opcode: nil, reason: :bad_declaration_length)
        end
        CharacteristicDeclaration.new(properties: value.getbyte(0), value_handle: u16(value, 1),
                                      uuid: uuid_from_bytes(value.byteslice(3..)))
      end

      # Any String -> IncludeDeclaration or Malformed. Never raises.
      def decode_include_declaration(value)
        value = value.b
        uuid = case value.bytesize
               when 6 then uuid_from_bytes(value.byteslice(4, 2))
               when 4 then nil
               else return Malformed.new(opcode: nil, reason: :bad_declaration_length)
               end
        IncludeDeclaration.new(start_handle: u16(value, 0), end_handle: u16(value, 2), uuid: uuid)
      end

      # The opcode a PDU object encodes to. A Malformed reports the opcode byte
      # it was decoded from (nil for an empty PDU or a declaration value).
      def opcode_of(pdu)
        return pdu.opcode if pdu.is_a?(Malformed)
        OPCODES.fetch(pdu.class) { raise ArgumentError, "not an ATT PDU: #{pdu.inspect}" }
      end

      def response_opcode?(opcode)
        RESPONSE_OPCODES.include?(opcode)
      end

      # False for nil, so the opcode of an empty PDU can be classified without
      # a guard at every call site.
      def command?(opcode)
        opcode.is_a?(Integer) && opcode.anybits?(COMMAND_FLAG)
      end

      def uuid16(n)
        raise ArgumentError, "16-bit UUID out of range: #{n.inspect}" unless n.is_a?(Integer) && n.between?(0, 0xFFFF)
        Uuid.new(bits: 16, hex: format("%04x", n))
      end

      # 2 or 16 octets in on-air (little-endian) order.
      def uuid_from_bytes(bytes)
        bytes = bytes.b
        raise ArgumentError, "UUID must be 2 or 16 bytes, got #{bytes.bytesize}" unless UUID_SIZES.include?(bytes.bytesize)
        Uuid.new(bits: bytes.bytesize * 8, hex: bytes.reverse.unpack1("H*"))
      end

      private

      # decode_params and the helpers it calls run inside decode's
      # catch(:malformed); a helper that finds the PDU malformed throws the
      # reason rather than returning it.
      def malformed!(reason)
        throw :malformed, reason
      end

      # params is the PDU without its opcode byte.
      def decode_params(opcode, params)
        case opcode
        when 0x01
          fixed(params, 4)
          ErrorResponse.new(request_opcode: params.getbyte(0), handle: u16(params, 1), error_code: params.getbyte(3))
        when 0x02
          fixed(params, 2)
          ExchangeMtuRequest.new(mtu: u16(params, 0))
        when 0x03
          fixed(params, 2)
          ExchangeMtuResponse.new(mtu: u16(params, 0))
        when 0x04
          fixed(params, 4)
          FindInformationRequest.new(start_handle: u16(params, 0), end_handle: u16(params, 2))
        when 0x05 then find_information_response(params)
        when 0x06 then find_by_type_value_request(params)
        when 0x08 then typed_range_request(ReadByTypeRequest, params)
        when 0x09 then read_by_type_response(params)
        when 0x0A
          fixed(params, 2)
          ReadRequest.new(handle: u16(params, 0))
        when 0x0B then ReadResponse.new(value: params)
        when 0x0C
          fixed(params, 4)
          ReadBlobRequest.new(handle: u16(params, 0), offset: u16(params, 2))
        when 0x0D then ReadBlobResponse.new(value: params)
        when 0x10 then typed_range_request(ReadByGroupTypeRequest, params)
        when 0x11 then read_by_group_type_response(params)
        when 0x1B then handle_value(HandleValueNotification, params)
        when 0x1D then handle_value(HandleValueIndication, params)
        when 0x1E
          fixed(params, 0)
          HandleValueConfirmation.new
        else malformed!(:unknown_opcode)
        end
      end

      # For an opcode with no variable-length field, the parameters must be
      # exactly this long.
      def fixed(params, size)
        malformed!(:too_short) if params.bytesize < size
        malformed!(:trailing_bytes) if params.bytesize > size
      end

      def at_least(params, size)
        malformed!(:too_short) if params.bytesize < size
      end

      def u16(bytes, offset)
        bytes.unpack1("S<", offset: offset)
      end

      # Read By Type and Read By Group Type Requests: a handle range then a
      # 16- or 128-bit UUID, told apart only by the PDU length.
      def typed_range_request(klass, params)
        at_least(params, 4)
        uuid = params.byteslice(4..)
        malformed!(:bad_uuid_length) unless UUID_SIZES.include?(uuid.bytesize)
        klass.new(start_handle: u16(params, 0), end_handle: u16(params, 2), uuid: uuid_from_bytes(uuid))
      end

      # The Attribute Type here is always 2 octets (Find By Type Value only
      # takes a 16-bit UUID), so everything after it, possibly nothing, is the
      # value to match.
      def find_by_type_value_request(params)
        at_least(params, 6)
        FindByTypeValueRequest.new(start_handle: u16(params, 0), end_handle: u16(params, 2),
                                   uuid: uuid_from_bytes(params.byteslice(4, 2)), value: params.byteslice(6..))
      end

      def find_information_response(params)
        at_least(params, 1)
        info_format = params.getbyte(0)
        size = FIND_INFORMATION_ENTRY_SIZES[info_format] or malformed!(:bad_format)
        list = entries(params.byteslice(1..), size) { |e| [u16(e, 0), uuid_from_bytes(e.byteslice(2..))] }
        FindInformationResponse.new(format: info_format, entries: list)
      end

      # Each entry is a 2-octet handle followed by length - 2 value octets, so
      # a length below 2 cannot hold the handle.
      def read_by_type_response(params)
        at_least(params, 1)
        length = params.getbyte(0)
        malformed!(:bad_length) if length < 2
        list = entries(params.byteslice(1..), length) { |e| [u16(e, 0), e.byteslice(2..)] }
        ReadByTypeResponse.new(length: length, entries: list)
      end

      def read_by_group_type_response(params)
        at_least(params, 1)
        length = params.getbyte(0)
        malformed!(:bad_length) unless GROUP_ENTRY_SIZES.include?(length)
        list = entries(params.byteslice(1..), length) { |e| [u16(e, 0), u16(e, 2), uuid_from_bytes(e.byteslice(4..))] }
        ReadByGroupTypeResponse.new(length: length, entries: list)
      end

      def handle_value(klass, params)
        at_least(params, 2)
        klass.new(handle: u16(params, 0), value: params.byteslice(2..))
      end

      # Split a response's entry list into size-octet entries and map each
      # through the block. Callers guarantee size >= 2.
      def entries(data, size)
        malformed!(:no_entries) if data.empty?
        malformed!(:ragged_entries) unless (data.bytesize % size).zero?
        (0...data.bytesize).step(size).map { |at| yield data.byteslice(at, size) }
      end

      # The parameters after the opcode byte. opcode_of has already rejected
      # anything that is not one of the OPCODES classes.
      def encode_params(pdu)
        case pdu
        when ErrorResponse
          put_u8(pdu.request_opcode, "request opcode") << put_u16(pdu.handle, "handle") <<
            put_u8(pdu.error_code, "error code")
        when ExchangeMtuRequest, ExchangeMtuResponse then put_u16(pdu.mtu, "MTU")
        when FindInformationRequest then put_range(pdu)
        when FindInformationResponse
          size = FIND_INFORMATION_ENTRY_SIZES.fetch(pdu.format) do
            raise ArgumentError, "Find Information format must be 0x01 or 0x02, got #{pdu.format.inspect}"
          end
          put_u8(pdu.format, "format") <<
            put_entries(pdu.entries, 2, size) { |handle, uuid| put_u16(handle, "handle") << put_uuid(uuid) }
        when FindByTypeValueRequest
          uuid = put_uuid(pdu.uuid)
          unless uuid.bytesize == 2
            raise ArgumentError, "Find By Type Value takes a 16-bit attribute type, got #{pdu.uuid.inspect}"
          end
          put_range(pdu) << uuid << put_value(pdu.value)
        when ReadByTypeRequest, ReadByGroupTypeRequest then put_range(pdu) << put_uuid(pdu.uuid)
        when ReadByTypeResponse
          put_u8(pdu.length, "length") <<
            put_entries(pdu.entries, 2, pdu.length) { |handle, value| put_u16(handle, "handle") << put_value(value) }
        when ReadRequest then put_u16(pdu.handle, "handle")
        when ReadResponse, ReadBlobResponse then put_value(pdu.value)
        when ReadBlobRequest then put_u16(pdu.handle, "handle") << put_u16(pdu.offset, "offset")
        when ReadByGroupTypeResponse
          length = put_u8(pdu.length, "length")
          list = put_entries(pdu.entries, 3, pdu.length) do |handle, end_group_handle, uuid|
            put_u16(handle, "handle") << put_u16(end_group_handle, "end group handle") << put_uuid(uuid)
          end
          length << list
        when HandleValueNotification, HandleValueIndication
          put_u16(pdu.handle, "handle") << put_value(pdu.value)
        when HandleValueConfirmation then "".b
        end
      end

      # The put_ helpers each return a new binary String, so the caller can
      # append to it, or raise ArgumentError for a field decode could not
      # have produced.
      def put_u8(n, field)
        raise ArgumentError, "#{field} must be an Integer in 0x00..0xFF, got #{n.inspect}" unless n.is_a?(Integer) && n.between?(0, 0xFF)
        [n].pack("C")
      end

      def put_u16(n, field)
        raise ArgumentError, "#{field} must be an Integer in 0x0000..0xFFFF, got #{n.inspect}" unless n.is_a?(Integer) && n.between?(0, 0xFFFF)
        [n].pack("S<")
      end

      def put_range(pdu)
        put_u16(pdu.start_handle, "start handle") << put_u16(pdu.end_handle, "end handle")
      end

      # Written at the width the Uuid carries, never shortened to 16 bits or
      # widened through the Bluetooth Base UUID: a 16-bit UUID sent in 128-bit
      # form re-encodes as the 16 octets it arrived as.
      def put_uuid(uuid)
        pattern = uuid.is_a?(Uuid) && UUID_HEX[uuid.bits]
        unless pattern && uuid.hex.is_a?(String) && pattern.match?(uuid.hex)
          raise ArgumentError, "UUID must be a 16- or 128-bit Uuid with lowercase hex, got #{uuid.inspect}"
        end
        [uuid.hex].pack("H*").reverse
      end

      def put_value(value)
        raise ArgumentError, "value must be a String, got #{value.inspect}" unless value.is_a?(String)
        value.b
      end

      # A response's entry list. Every entry has to encode to exactly the size
      # its length or format byte gives, because that byte alone is what the
      # receiver splits the list by (see the module comment).
      def put_entries(list, arity, size)
        raise ArgumentError, "entries must be a non-empty Array, got #{list.inspect}" unless list.is_a?(Array) && !list.empty?
        list.each_with_object("".b) do |entry, out|
          raise ArgumentError, "entry must be an Array of #{arity}, got #{entry.inspect}" unless entry.is_a?(Array) && entry.size == arity
          bytes = yield(*entry)
          unless bytes.bytesize == size
            raise ArgumentError, "entry encodes to #{bytes.bytesize} bytes, not the #{size.inspect} its length or format byte gives: #{entry.inspect}"
          end
          out << bytes
        end
      end
    end
  end
end
