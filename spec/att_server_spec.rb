require 'spec_helper'
require 'blue_hydra/att_server'

describe BlueHydra::AttServer do
  # Locals rather than constants: a constant here would land on Object and be
  # shared with every other spec file. The examples close over them.
  #
  # Peer PDUs and expected replies are spaced hex written out by hand from
  # Core 6.3 Vol 3 Part F section 3.4 (opcode octet first, multi-octet fields
  # little-endian), so a wrong layout in the codec cannot also be wrong here.
  # Starting Handles are distinct and have both octets non-zero where it
  # matters, so a reply naming the wrong handle, or 0x0000 where the request's
  # handle belongs, shows up as different bytes.
  codec = BlueHydra::AttCodec

  # [label, peer PDU, reply on air, request opcode, Starting Handle]. A sane
  # range: Starting Handle non-zero and below the Ending Handle.
  discovery = [
    ["Find Information Request",   "04 05 00 ff ff",             "01 04 05 00 0a", 0x04, 0x0005],
    ["Find By Type Value Request", "06 10 00 ff ff 00 28 0d 18", "01 06 10 00 0a", 0x06, 0x0010],
    ["Read By Type Request",       "08 02 01 ff ff 03 28",       "01 08 02 01 0a", 0x08, 0x0102],
    ["Read By Group Type Request", "10 34 12 ff ff 00 28",       "01 10 34 12 0a", 0x10, 0x1234],
  ]

  # The same four requests with Starting Handle equal to the Ending Handle:
  # a one-handle range, which Core 6.3 Vol 3 Part F 3.4.3.1 et al. allow, so
  # still Attribute Not Found. Handles with both octets non-zero again.
  one_handle_ranges = [
    ["Find Information Request",   "04 05 03 05 03",             "01 04 05 03 0a", 0x04, 0x0305],
    ["Find By Type Value Request", "06 10 02 10 02 00 28 0d 18", "01 06 10 02 0a", 0x06, 0x0210],
    ["Read By Type Request",       "08 02 01 02 01 03 28",       "01 08 02 01 0a", 0x08, 0x0102],
    ["Read By Group Type Request", "10 34 12 34 12 00 28",       "01 10 34 12 0a", 0x10, 0x1234],
  ]

  # [label, peer PDU, reply on air, request opcode, Starting Handle]. Each of
  # the four requests with Starting Handle 0x0000, and each with a Starting
  # Handle above its Ending Handle (by one, and by a wide margin), all Invalid
  # Handle naming the Starting Handle as sent (Core 6.3 Vol 3 Part F 3.4.3.1,
  # 3.4.3.3, 3.4.4.1, 3.4.4.9). The Ending Handles are non-zero so that a
  # reply echoing the wrong handle field shows up.
  invalid_ranges = [
    ["Find Information Request with Starting Handle 0x0000",   "04 00 00 ff ff",             "01 04 00 00 01", 0x04, 0x0000],
    ["Find By Type Value Request with Starting Handle 0x0000", "06 00 00 05 00 00 28 0d 18", "01 06 00 00 01", 0x06, 0x0000],
    ["Read By Type Request with Starting Handle 0x0000",       "08 00 00 01 00 03 28",       "01 08 00 00 01", 0x08, 0x0000],
    ["Read By Group Type Request with Starting Handle 0x0000", "10 00 00 ff ff 00 28",       "01 10 00 00 01", 0x10, 0x0000],
    ["Find Information Request with Starting Handle one above the Ending Handle",
     "04 06 03 05 03",             "01 04 06 03 01", 0x04, 0x0306],
    ["Find By Type Value Request with Starting Handle above the Ending Handle",
     "06 ff ff 10 02 00 28 0d 18", "01 06 ff ff 01", 0x06, 0xFFFF],
    ["Read By Type Request with Starting Handle one above the Ending Handle",
     "08 03 01 02 01 03 28",       "01 08 03 01 01", 0x08, 0x0103],
    ["Read By Group Type Request with Starting Handle above the Ending Handle",
     "10 34 12 01 00 00 28",       "01 10 34 12 01", 0x10, 0x1234],
  ]

  # [label, peer PDU, reply on air, request opcode]. Each still carries a
  # plausible Starting Handle, which the reply must not echo.
  malformed_requests = [
    ["an Exchange MTU Request one octet short",          "02 f7",                   "01 02 00 00 04", 0x02],
    ["a Find Information Request one octet short",       "04 05 00 ff",             "01 04 00 00 04", 0x04],
    ["a Find By Type Value Request with a 1-octet type", "06 10 00 ff ff 00",       "01 06 00 00 04", 0x06],
    ["a Read By Type Request with a 1-octet UUID",       "08 02 01 ff ff 03",       "01 08 00 00 04", 0x08],
    ["a Read By Group Type Request with a 3-octet UUID", "10 34 12 ff ff 00 28 00", "01 10 00 00 04", 0x10],
  ]

  indications = [
    ["a well-formed Handle Value Indication", "1d 03 00 01 02", false],
    ["a Handle Value Indication too short to hold its handle", "1d 03", true],
  ]

  # Signed Write Command is handle, value, then a 12-octet signature. A
  # Multiple Handle Value Notification (Core 5.2, Vol 3 Part F 3.4.7.4) is a
  # list of handle, 16-bit length, value tuples; the codec decodes neither it
  # nor a command, so both arrive Malformed and are discarded on the raw
  # opcode alone, which the garbage-bodied one proves.
  discarded = [
    ["Handle Value Notification",  "1b 03 00 aa"],
    ["Handle Value Confirmation",  "1e"],
    ["Write Command (0x52)",       "52 03 00 01"],
    ["Signed Write Command (0xD2)", "d2 03 00 01 #{'00 ' * 12}"],
    ["well-formed Multiple Handle Value Notification (0x23)",   "23 03 00 01 00 41 05 00 02 00 aa bb"],
    ["garbage-bodied Multiple Handle Value Notification (0x23)", "23 ff"],
  ]

  # Responses with no outstanding client request. Write Response (0x13) is
  # one the codec does not decode, so it arrives Malformed.
  strays = [
    ["a Read Response (0x0B)",   "0b 01 02"],
    ["a Write Response (0x13)",  "13"],
    ["an Error Response (0x01)", "01 0a 03 00 0a"],
  ]

  # [label, peer PDU, reply on air, request opcode]
  unsupported = [
    ["Read Request (0x0A)",            "0a 03 00",    "01 0a 00 00 06", 0x0A],
    ["an undefined opcode (0x30)",     "30 01 02",    "01 30 00 00 06", 0x30],
    # Not decoded by the codec, so Malformed, yet still 0x06: Invalid PDU is
    # reserved for the opcodes of Requirement 8.1 and 8.2 (8.8).
    ["Write Request (0x12)",           "12 03 00 01", "01 12 00 00 06", 0x12],
    ["a Read Request one octet short", "0a 03",       "01 0a 00 00 06", 0x0A],
  ]

  def bytes_of(pdu_hex)
    [pdu_hex.delete(" ")].pack("H*")
  end

  def decode(pdu_hex)
    BlueHydra::AttCodec.decode(bytes_of(pdu_hex))
  end

  # What the walker passes: the codec's decode of the bytes on the bearer and
  # their first octet (nil for an empty PDU).
  def serve(pdu_hex)
    bytes = bytes_of(pdu_hex)
    described_class.new.handle(BlueHydra::AttCodec.decode(bytes), bytes.getbyte(0))
  end

  def on_air(reply)
    BlueHydra::AttCodec.encode(reply).unpack1("H*")
  end

  describe "Exchange MTU Request (Requirement 8.1)" do
    it "answers with Exchange MTU Response carrying Server Rx MTU 517 and hands back the peer's Client Rx MTU" do
      expect(decode("02 f7 00")).to eq(codec::ExchangeMtuRequest.new(mtu: 247))
      reply, event, mtu_arg = serve("02 f7 00")
      expect(reply).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
      expect(on_air(reply)).to eq("030502")
      expect(event).to eq(:mtu_request)
      expect(mtu_arg).to eq(247)
    end

    # The floor of 23 is the walker's to apply (Requirement 8.9), so the
    # server must not hide what the peer actually sent.
    it "hands back a Client Rx MTU below 23 unchanged" do
      { "02 16 00" => 22, "02 10 00" => 16, "02 00 00" => 0 }.each do |pdu, mtu|
        reply, event, mtu_arg = serve(pdu)
        expect(on_air(reply)).to eq("030502")
        expect(event).to eq(:mtu_request)
        expect(mtu_arg).to eq(mtu)
      end
    end
  end

  describe "discovery requests (Requirement 8.2)" do
    discovery.each do |label, pdu, reply_hex, opcode, start_handle|
      it "answers a #{label} with Attribute Not Found naming its opcode and Starting Handle" do
        expect(decode(pdu)).not_to be_a(codec::Malformed)
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: opcode, handle: start_handle, error_code: 0x0A))
        expect(on_air(reply)).to eq(reply_hex.delete(" "))
        expect(event).to eq(:request)
        expect(mtu_arg).to be_nil
      end
    end

    one_handle_ranges.each do |label, pdu, reply_hex, opcode, start_handle|
      it "answers a #{label} whose Starting Handle equals its Ending Handle with Attribute Not Found, not Invalid Handle" do
        expect(decode(pdu)).not_to be_a(codec::Malformed)
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: opcode, handle: start_handle, error_code: 0x0A))
        expect(on_air(reply)).to eq(reply_hex.delete(" "))
        expect(event).to eq(:request)
        expect(mtu_arg).to be_nil
      end
    end

    invalid_ranges.each do |label, pdu, reply_hex, opcode, start_handle|
      it "answers a #{label} with Invalid Handle naming its opcode and Starting Handle" do
        expect(decode(pdu)).not_to be_a(codec::Malformed)
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: opcode, handle: start_handle, error_code: 0x01))
        expect(on_air(reply)).to eq(reply_hex.delete(" "))
        expect(event).to eq(:request)
        expect(mtu_arg).to be_nil
      end
    end
  end

  describe "malformed Exchange MTU and discovery requests (Requirement 8.8)" do
    malformed_requests.each do |label, pdu, reply_hex, opcode|
      it "answers #{label} with Invalid PDU at handle 0x0000" do
        expect(decode(pdu)).to be_a(codec::Malformed)
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: opcode, handle: 0x0000, error_code: 0x04))
        expect(on_air(reply)).to eq(reply_hex.delete(" "))
        expect(event).to eq(:invalid)
        expect(mtu_arg).to be_nil
      end
    end
  end

  describe "Handle Value Indication (Requirement 8.4)" do
    indications.each do |label, pdu, malformed|
      it "confirms #{label} exactly once and keeps nothing of it" do
        expect(decode(pdu).is_a?(codec::Malformed)).to eq(malformed)
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::HandleValueConfirmation.new)
        expect(on_air(reply)).to eq("1e")
        expect(event).to eq(:indication)
        expect(mtu_arg).to be_nil
      end
    end
  end

  describe "PDUs that get no reply (Requirement 8.5)" do
    discarded.each do |label, pdu|
      it "discards a #{label}" do
        expect(serve(pdu)).to eq([nil, :discard, nil])
      end
    end

    it "discards an empty PDU, which has no opcode an Error Response could name" do
      expect(decode("")).to eq(codec::Malformed.new(opcode: nil, reason: :empty))
      expect(serve("")).to eq([nil, :discard, nil])
    end

    # 0x23 is not a response opcode and not one the codec decodes, so without
    # its own clause it would fall to Requirement 8.3 and be refused 0x06.
    it "discards a Multiple Handle Value Notification by its opcode, the codec having reported it Malformed" do
      ["23 03 00 01 00 41 05 00 02 00 aa bb", "23 ff", "23"].each do |pdu|
        expect(codec.response_opcode?(0x23)).to be(false)
        expect(decode(pdu)).to eq(codec::Malformed.new(opcode: 0x23, reason: :unknown_opcode))
        expect(serve(pdu)).to eq([nil, :discard, nil])
      end
    end
  end

  describe "stray responses" do
    strays.each do |label, pdu|
      it "drops #{label} rather than answering it" do
        expect(serve(pdu)).to eq([nil, :discard, nil])
      end
    end
  end

  describe "every other request (Requirement 8.3)" do
    unsupported.each do |label, pdu, reply_hex, opcode|
      it "answers #{label} with Request Not Supported at handle 0x0000" do
        reply, event, mtu_arg = serve(pdu)
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: opcode, handle: 0x0000, error_code: 0x06))
        expect(on_air(reply)).to eq(reply_hex.delete(" "))
        expect(event).to eq(:request)
        expect(mtu_arg).to be_nil
      end
    end
  end

  # Requirement 7.7: whatever the peer sends, the bearer carries only
  # read-only opcodes. Across every vector above.
  it "only ever replies with Error Response, Exchange MTU Response or Handle Value Confirmation" do
    pdus = ["02 f7 00", ""] + [discovery, one_handle_ranges, invalid_ranges, malformed_requests, indications, discarded,
                               strays, unsupported].flat_map { |table| table.map { |row| row[1] } }
    replies = pdus.map { |pdu| serve(pdu).first }.compact
    expect(replies).not_to be_empty
    opcodes = replies.map { |reply| BlueHydra::AttCodec.encode(reply).getbyte(0) }.uniq
    expect([0x01, 0x03, 0x1E]).to include(*opcodes)
  end

  # Feature: gatt-service-scanning, Property 6: The Att_Server never raises and only ever answers with 0x01, 0x03 or 0x1E
  #
  # Validates: Requirements 7.7, 8.2, 8.3, 8.5
  #
  # For any byte string of 0 to 517 bytes presented as a peer PDU,
  # AttServer#handle returns without raising either no reply or a PDU whose
  # opcode is Error Response, Exchange MTU Response or Handle Value
  # Confirmation; for a first byte that is a request opcode outside {0x02,
  # 0x04, 0x06, 0x08, 0x10} with the Command Flag clear, the reply is Error
  # Response 0x06 carrying that opcode and handle 0x0000; for a well-formed
  # 0x04, 0x06, 0x08 or 0x10 request whose Starting Handle is 0x0000 or
  # greater than its Ending Handle, the reply is Error Response 0x01 Invalid
  # Handle carrying that opcode and the Starting Handle, and otherwise Error
  # Response 0x0A carrying that opcode and the Starting Handle; for a first
  # byte with the Command Flag set, 0x1B, 0x1E or 0x23 (Multiple Handle Value
  # Notification), there is no reply.
  #
  # The opcode classes are restated here from Core 6.3 Vol 3 Part F rather
  # than read from the subject or the codec, so a misfiled opcode there cannot
  # also be misfiled here:
  #   * the Command Flag is bit 6 (section 3.3.1);
  #   * the response opcodes are the *_RSP rows of the opcode summary (section
  #     3.4.8), Read Multiple Variable Response (0x21) included;
  #   * 0x02 and the four discovery requests are answered by 8.1, 8.2 and 8.8,
  #     whose replies the examples above pin down; the 8.2 range check is
  #     restated below over the Starting and Ending Handle octets of the PDU
  #     (little-endian at offsets 1 and 3 in all four requests);
  #   * 0x1B, 0x1E and 0x23 are the server-initiated PDUs owed nothing (8.5);
  #     0x23 is one the codec does not decode, so it arrives Malformed;
  #   * every other first byte with the Command Flag clear, other than 0x1D,
  #     falls to 8.3. That includes 0x80 to 0xBF, which set the
  #     Authentication Signature Flag (bit 7) without the Command Flag and
  #     name no PDU.
  #
  # The generator mixes: a first byte drawn without replacement from a deck
  # of 0x00..0xFF, refilled when empty, with a random tail; well-formed PDUs of each request the codec encodes;
  # those cut short (into their fixed fields three times in four, so most are
  # Malformed) or with octets appended; Command-Flag opcodes, Write Command
  # and Signed Write Command among them; response opcodes, half as encoded
  # responses; notifications, indications and confirmations, well-formed and
  # malformed; the requests the server refuses with 0x06; and the empty PDU.
  # Tails run to the full 517 octets about one time in eight.
  #
  # The input is [shape, hex of the PDU]. A plain Array is not shrinkable in
  # rantly, so a failing case is printed as generated, and every expectation
  # derives from the hex alone.
  it "Property 6: never raises and only ever answers with 0x01, 0x03 or 0x1E, whatever the peer sends" do
    command_flag = 0x40
    responses = [0x01, 0x03, 0x05, 0x07, 0x09, 0x0B, 0x0D, 0x0F, 0x11, 0x13, 0x17, 0x19, 0x21]
    served = [0x02, 0x04, 0x06, 0x08, 0x10]
    # Requests Core 6.3 defines that the server refuses with 0x06: Read, Read
    # Blob, Read Multiple, Write, Prepare Write, Execute Write and Read
    # Multiple Variable.
    refused = [0x0A, 0x0C, 0x0E, 0x12, 0x16, 0x18, 0x20]
    # The requests AttCodec.encode can build.
    encodable = [0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x10]
    allowed_replies = [0x01, 0x03, 0x1E]
    events = %i[mtu_request request indication discard invalid]

    classify = lambda do |first|
      if first.nil? then :empty
      elsif first.anybits?(command_flag) then :command
      elsif first == 0x1B then :notification
      elsif first == 0x1D then :indication
      elsif first == 0x1E then :confirmation
      elsif first == 0x23 then :multiple_notification
      elsif responses.include?(first) then :response
      elsif served.include?(first) then :served
      else :unsupported
      end
    end

    max_pdu = 517
    deck = []
    firsts = Hash.new(0)
    seen = Hash.new(0)

    # Procs and lambdas here run under rantly's instance_eval, so they reach the
    # locals above and rantly's generators but not the example's helpers.
    property_of {
      u16 = -> { freq([3, proc { range(0, 0xFFFF) }], [1, proc { choose(0x0000, 0x0001, 0xFFFF) }]) }
      random_bytes = ->(n) { array(n) { range(0x00, 0xFF) }.pack("C*") }
      # Random octets to follow the first `used`, keeping the PDU within 517.
      tail = lambda do |used|
        room = max_pdu - used
        n = freq([4, proc { range(0, [8, room].min) }], [2, proc { range(0, [64, room].min) }],
                 [1, proc { range(0, room) }], [1, :literal, room])
        random_bytes.(n)
      end
      uuid16 = -> { codec::Uuid.new(bits: 16, hex: format("%04x", range(0, 0xFFFF))) }
      uuid = -> { boolean ? uuid16.() : codec::Uuid.new(bits: 128, hex: format("%032x", range(0, 2**128 - 1))) }
      request = lambda do
        case choose(*encodable)
        when 0x02 then codec::ExchangeMtuRequest.new(mtu: u16.())
        when 0x04 then codec::FindInformationRequest.new(start_handle: u16.(), end_handle: u16.())
        when 0x06
          codec::FindByTypeValueRequest.new(start_handle: u16.(), end_handle: u16.(), uuid: uuid16.(), value: tail.(7))
        when 0x08 then codec::ReadByTypeRequest.new(start_handle: u16.(), end_handle: u16.(), uuid: uuid.())
        when 0x0A then codec::ReadRequest.new(handle: u16.())
        when 0x0C then codec::ReadBlobRequest.new(handle: u16.(), offset: u16.())
        when 0x10 then codec::ReadByGroupTypeRequest.new(start_handle: u16.(), end_handle: u16.(), uuid: uuid.())
        end
      end

      shape = freq([8, :literal, :sweep], [4, :literal, :well_formed], [3, :literal, :truncated],
                   [1, :literal, :extended], [1, :literal, :command], [1, :literal, :response],
                   [2, :literal, :handle_value], [1, :literal, :refused], [1, :literal, :empty])
      pdu =
        case shape
        when :sweep
          deck.replace((0x00..0xFF).to_a) if deck.empty?
          [deck.delete_at(range(0, deck.size - 1))].pack("C") + tail.(1)
        when :well_formed
          codec.encode(request.())
        when :truncated
          whole = codec.encode(request.())
          # Each encodable request needs at least its first min(length, 7)
          # octets to decode, so a cut below that is always Malformed. A cut
          # anywhere else may still decode: a shorter Find By Type Value
          # value, or a 128-bit UUID cut to 16 bits.
          keep = range(0, 3).positive? ? range(1, [whole.bytesize, 7].min - 1) : range(1, whole.bytesize - 1)
          whole.byteslice(0, keep)
        when :extended
          whole = codec.encode(request.())
          room = max_pdu - whole.bytesize
          whole + random_bytes.(room.zero? ? 0 : range(1, [16, room].min))
        when :command
          [freq([1, proc { choose(0x52, 0xD2) }], [3, proc { range(0x00, 0xFF) | command_flag }])].pack("C") + tail.(1)
        when :response
          case range(0, 7)
          when 0 then codec.encode(codec::ErrorResponse.new(request_opcode: range(0, 0xFF), handle: u16.(),
                                                            error_code: range(0, 0xFF)))
          when 1 then codec.encode(codec::ExchangeMtuResponse.new(mtu: u16.()))
          when 2 then codec.encode(codec::ReadResponse.new(value: tail.(1)))
          when 3 then codec.encode(codec::ReadBlobResponse.new(value: tail.(1)))
          else [choose(*responses)].pack("C") + tail.(1)
          end
        when :handle_value
          case range(0, 5)
          when 0 then codec.encode(codec::HandleValueNotification.new(handle: u16.(), value: tail.(3)))
          when 1 then codec.encode(codec::HandleValueIndication.new(handle: u16.(), value: tail.(3)))
          when 2 then codec.encode(codec::HandleValueConfirmation.new)
          else
            # too short to hold a handle, or a confirmation with parameters
            opcode = choose(0x1B, 0x1D, 0x1E)
            [opcode].pack("C") + random_bytes.(opcode == 0x1E ? range(1, 8) : range(0, 1))
          end
        when :refused
          [choose(*refused)].pack("C") + tail.(1)
        when :empty
          "".b
        end

      [shape, pdu.unpack1("H*")]
    # 1000 rather than 100 so the sweep (8 in 22 of cases, about 364 draws,
    # sd 15) empties the 256-card deck at least once, 7 sd clear, and every
    # class asserted below turns up. The rarest, a well-formed and a
    # malformed indication, average about 15 cases each (minimum 7 over 30
    # runs), so a run misses one about once in 10^6. The 1000 cases take
    # about 0.1 s.
    }.check(1000) { |_shape, hex|
      bytes = [hex].pack("H*")
      first = bytes.getbyte(0)
      decoded = codec.decode(bytes)
      kind = classify.call(first)

      expect(bytes.bytesize).to be_between(0, max_pdu)
      firsts[first] += 1 if first
      seen[kind] += 1
      seen[:max_length] += 1 if bytes.bytesize == max_pdu
      seen[[decoded.is_a?(codec::Malformed) ? :malformed : :well_formed, first]] += 1 if encodable.include?(first)
      seen[[:indication, decoded.is_a?(codec::Malformed) ? :malformed : :well_formed]] += 1 if kind == :indication

      # exactly as the walker calls it
      result = nil
      expect { result = described_class.new.handle(decoded, first) }.not_to raise_error
      expect(result).to be_an(Array)
      expect(result.size).to eq(3)

      reply, event, mtu_arg = result
      expect(events).to include(event)
      seen[[:event, event]] += 1
      expect(mtu_arg).to be_nil unless event == :mtu_request

      on_air = nil
      unless reply.nil?
        expect { on_air = codec.encode(reply) }.not_to raise_error
        expect(allowed_replies).to include(on_air.getbyte(0))
      end

      case kind
      when :unsupported
        expect(reply).to eq(codec::ErrorResponse.new(request_opcode: first, handle: 0x0000, error_code: 0x06))
        expect(on_air.bytes).to eq([0x01, first, 0x00, 0x00, 0x06])
      when :command, :notification, :confirmation, :multiple_notification
        expect(reply).to be_nil
      when :indication
        expect(reply).to eq(codec::HandleValueConfirmation.new)
        expect(on_air.bytes).to eq([0x1E])
      when :served
        if first != 0x02 && !decoded.is_a?(codec::Malformed)
          # Requirement 8.2 over the octets: Starting Handle at offset 1,
          # Ending Handle at offset 3, both little-endian, in every one of
          # the four requests.
          start_handle, end_handle = bytes.byteslice(1, 4).unpack("S<S<")
          code = start_handle.zero? || start_handle > end_handle ? 0x01 : 0x0A
          seen[[:served, code == 0x01 ? :invalid_handle : :not_found]] += 1
          expect(reply).to eq(codec::ErrorResponse.new(request_opcode: first, handle: start_handle, error_code: code))
          expect(on_air.bytes).to eq([0x01, first, *[start_handle].pack("S<").bytes, code])
        end
      end
    }

    # A generator that stopped reaching one of these would let the property
    # pass without testing it.
    expect((0x00..0xFF).to_a - firsts.keys).to eq([])
    wanted = %i[empty command notification indication confirmation multiple_notification response served unsupported
                max_length] +
             encodable.flat_map { |op| [[:well_formed, op], [:malformed, op]] } +
             [[:indication, :well_formed], [:indication, :malformed]] +
             [[:served, :invalid_handle], [:served, :not_found]] +
             events.map { |event| [:event, event] }
    expect(wanted - seen.keys).to eq([])
  end
end
