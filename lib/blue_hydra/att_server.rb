require 'blue_hydra/att_codec'

module BlueHydra
  # The server side of our ATT bearer. ATT has no client-only mode: the fixed
  # CID 0x0004 channel the walker opens is also the peer's way in to our GATT
  # server, and peers (iPhones especially) discover it as soon as the link is
  # up. A request left unanswered stalls the peer for its 30 s ATT transaction
  # timeout, or it drops the link mid-walk, so every request gets an answer.
  #
  # We expose no attributes and never write, so every answer is a refusal and
  # handle can only ever produce Error Response (0x01), Exchange MTU Response
  # (0x03) or Handle Value Confirmation (0x1E). That keeps the bearer inside
  # the read-only opcode allowlist whatever the peer sends.
  #
  # Pure and stateless: it computes the reply, the walker sends it (encoding
  # it, and counting peer-req) and applies the MTU cap.
  class AttServer
    # Matches the Client Rx MTU the walker sends in its own Exchange MTU
    # Request; both are AttCodec::MAX_PDU, the largest PDU the codec accepts.
    SERVER_RX_MTU = AttCodec::MAX_PDU

    INVALID_HANDLE        = 0x01
    INVALID_PDU           = 0x04
    REQUEST_NOT_SUPPORTED = 0x06
    ATTRIBUTE_NOT_FOUND   = 0x0A

    EXCHANGE_MTU_REQUEST               = 0x02
    HANDLE_VALUE_NOTIFICATION          = 0x1B
    HANDLE_VALUE_INDICATION            = 0x1D
    HANDLE_VALUE_CONFIRMATION          = 0x1E
    # Core 5.2. Server-initiated like 0x1B and owed nothing, but the codec
    # does not decode it, so it arrives Malformed and is classified here by
    # its raw opcode.
    MULTIPLE_HANDLE_VALUE_NOTIFICATION = 0x23

    # The discovery requests a peer runs against our database. With no
    # attributes, Attribute Not Found at the Starting Handle is the answer
    # that ends the peer's discovery procedure normally. A Starting Handle of
    # 0x0000, or one above the Ending Handle, is Invalid Handle instead (Core
    # 6.3 Vol 3 Part F 3.4.3.1, 3.4.3.3, 3.4.4.1, 3.4.4.9): the range check
    # comes before any lookup, so it applies even to an empty database.
    DISCOVERY_REQUESTS = {
      0x04 => AttCodec::FindInformationRequest,
      0x06 => AttCodec::FindByTypeValueRequest,
      0x08 => AttCodec::ReadByTypeRequest,
      0x10 => AttCodec::ReadByGroupTypeRequest,
    }.freeze

    # decoded_or_malformed is AttCodec.decode of the peer PDU; raw_opcode is its
    # first byte (nil for an empty PDU). Returns [reply, event, mtu_arg]:
    #
    #   reply   - an AttCodec PDU to send, or nil to send nothing
    #   event   - :mtu_request, :request, :indication, :discard or :invalid
    #   mtu_arg - the peer's Client Rx MTU for :mtu_request, else nil. It is
    #             passed through as received; the walker applies the floor of 23.
    #
    # Classification goes by raw_opcode before looking at whether the decode was
    # Malformed. The codec decodes only the opcodes the walk uses, so a command
    # such as Write Command (0x52) or Signed Write Command (0xD2) arrives as an
    # :unknown_opcode Malformed, and a command must never be answered. Likewise
    # an indication is confirmed even when malformed: the peer cannot send
    # another indication until it sees the confirmation, and without one its
    # 30 s transaction timeout closes the bearer.
    def handle(decoded_or_malformed, raw_opcode)
      # No opcode means nothing an Error Response could name.
      return [nil, :discard, nil] if raw_opcode.nil?
      return [nil, :discard, nil] if AttCodec.command?(raw_opcode)

      case raw_opcode
      when HANDLE_VALUE_INDICATION
        # Handle and value are discarded: we take no subscriptions.
        [AttCodec::HandleValueConfirmation.new, :indication, nil]
      when HANDLE_VALUE_NOTIFICATION, MULTIPLE_HANDLE_VALUE_NOTIFICATION, HANDLE_VALUE_CONFIRMATION
        [nil, :discard, nil]
      when EXCHANGE_MTU_REQUEST
        exchange_mtu(decoded_or_malformed)
      else
        # A response is never answered. One reaching here has no outstanding
        # client request to match, so it is a stray and is dropped.
        return [nil, :discard, nil] if AttCodec.response_opcode?(raw_opcode)

        klass = DISCOVERY_REQUESTS[raw_opcode]
        return discovery(decoded_or_malformed, raw_opcode, klass) if klass

        # Read, Read Blob, Read Multiple, Write, Prepare/Execute Write and
        # undefined opcodes alike: we hold no attributes and accept no writes.
        [error(raw_opcode, 0x0000, REQUEST_NOT_SUPPORTED), :request, nil]
      end
    end

    private

    def exchange_mtu(pdu)
      return invalid(EXCHANGE_MTU_REQUEST) unless pdu.is_a?(AttCodec::ExchangeMtuRequest)
      [AttCodec::ExchangeMtuResponse.new(mtu: SERVER_RX_MTU), :mtu_request, pdu.mtu]
    end

    def discovery(pdu, opcode, klass)
      return invalid(opcode) unless pdu.is_a?(klass)
      start = pdu.start_handle
      code  = start.zero? || start > pdu.end_handle ? INVALID_HANDLE : ATTRIBUTE_NOT_FOUND
      [error(opcode, start, code), :request, nil]
    end

    # A malformed request has no Starting Handle we can trust, so the Error
    # Response names handle 0x0000.
    def invalid(opcode)
      [error(opcode, 0x0000, INVALID_PDU), :invalid, nil]
    end

    def error(opcode, handle, code)
      AttCodec::ErrorResponse.new(request_opcode: opcode, handle: handle, error_code: code)
    end
  end
end
