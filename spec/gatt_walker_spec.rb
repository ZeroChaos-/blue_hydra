require 'spec_helper'
require 'blue_hydra/gatt_walker'
require 'blue_hydra/gatt_characteristics'
require_relative 'support/fake_att_peer'

# GattWalker driven through the FakeAttPeer harness (Requirement 16.1): no real
# socket is opened and every wait runs on the fake clock.
#
# Bearer setup and the Exchange MTU (Requirement 5). Examples that need a Walk
# to get past the exchange run Plan.resume of a WalkState with nothing left
# outstanding (through_exchange_plan), so the exchange is the Walk's only
# request and the Walk then ends complete. That keeps these examples to what
# bearer setup and the exchange decide, whatever discovery and reads do.
describe BlueHydra::GattWalker do
  let(:codec)         { BlueHydra::AttCodec }
  let(:clock)         { FakeClock.new }
  let(:address)       { "7A:BB:CC:DD:EE:FF" }
  let(:local_address) { "00:11:22:33:44:55" }
  let(:db)            { GattDatabase.build { primary(0x1800) { characteristic 0x2A00, value: "Name" } } }
  let(:server_rx_mtu) { 517 }
  let(:peer)          { FakeAttPeer.new(db, clock: clock, server_rx_mtu: server_rx_mtu) }

  # Every message logged, as [level, message].
  let(:log) { [] }
  let(:recording_logger) do
    entries = log
    Object.new.tap do |logger|
      %i[debug info warn error fatal unknown].each do |level|
        logger.define_singleton_method(level) do |message = nil, &block|
          entries << [level, message || block&.call]
          true
        end
      end
    end
  end

  # Requirement 5.4's errnos for disconnected: ENOTCONN and
  # LeConnect::UNREACHABLE_ERRORS, listed here as the requirement names them.
  disconnect_errnos = [
    Errno::ENOTCONN, Errno::EHOSTDOWN, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
    Errno::ECONNABORTED, Errno::ENETUNREACH, Errno::ECONNRESET, Errno::ENOSYS
  ]

  before do
    allow(Socket).to receive(:new).and_raise("GattWalker specs must not open a real socket")
    allow(BlueHydra).to receive(:logger).and_return(recording_logger)
  end

  # Requirements 5.2 and 5.11: no socket option, BT_SECURITY above all, is set
  # on the Att_Bearer in any example, and the walker breaks no ATT rule the
  # harness checks (one outstanding request, one Exchange MTU per bearer, the
  # opcode allowlist).
  after do
    expect(peer.calls.map(&:name)).not_to include(:setsockopt)
    expect(peer.violations).to be_empty
  end

  def logged(level)
    log.select { |entry_level, _| entry_level == level }.map(&:last)
  end

  # A Resume_State with nothing outstanding: no procedure left, reads generated
  # and all done. Run with it, a Walk sends its Exchange MTU Request and then
  # reaches the end of its worklist.
  def through_exchange_plan
    state = BlueHydra::GattWalker::WalkState.fresh
    state.procedures.clear
    state.reads_generated = true
    BlueHydra::GattWalker::Plan.resume(state)
  end

  # A walker whose open_socket is the real one, i.e. Socket.new. Same defaults
  # as FakeAttPeer#build_walker.
  def walker_with_real_open_socket(**overrides)
    BlueHydra::GattWalker.new(
      address: address, address_type: BlueHydra::Mgmt::LE_RANDOM, hci_index: 0,
      local_address: local_address, plan: BlueHydra::GattWalker::Plan.full,
      deadline: clock.now + 10.0, read_all: true,
      link_up: ->(_address) { clock.now }, stopping: -> { false }, on_peer_request: -> {},
      clock: clock, **overrides
    )
  end

  def call_names
    peer.calls.map(&:name)
  end

  def socket_call(name)
    calls = peer.calls.select { |call| call.name == name }
    expect(calls.size).to eq(1), "expected one #{name} call, got #{call_names.inspect}"
    calls.first
  end

  # Requirement 5.6: the bearer is closed by the time run returns (so before the
  # Gatt_Scanner counts the outcome from the report), and the socket saw
  # nothing after the close. walker.bearer is nil when close_bearer ran before
  # the bearer was installed: the socket was closed instead of installed.
  # +served+ is the peer the Walk ran on, the let peer unless given.
  def expect_bearer_closed(walker, report, served = peer)
    names = served.calls.map(&:name)
    expect(served.closed?).to be(true)
    expect(walker.bearer).to be_nil.or(be_closed)
    expect(names.count(:close)).to eq(1)
    expect(names.last).to eq(:close)
    expect(served.calls.last.at).to be <= report.ended_at
  end

  # A Walk that ended during bearer setup: one connect at most, no ATT PDU.
  def expect_ended_before_any_pdu(walker, report, outcome)
    expect(report.outcome).to eq(outcome)
    expect(call_names.count(:connect_nonblock)).to be <= 1
    expect(call_names).not_to include(:send)
    expect(peer.requests).to be_empty
    expect(report.requests_sent).to eq(0)
    expect(report.mtu).to eq(BlueHydra::GattWalker::DEFAULT_MTU)
    expect_bearer_closed(walker, report)
  end

  # Requirement 5.7: exactly one Exchange MTU Request, Client Rx MTU 517, as
  # the first client request, and requests_sent counting it.
  def expect_one_exchange(report)
    expect(peer.requests.map(&:pdu)).to eq([codec::ExchangeMtuRequest.new(mtu: 517)])
    expect(report.requests_sent).to eq(peer.requests.size)
  end

  # Requirement 5.5: a debug line naming the device address and the errno, and
  # nothing above debug.
  def expect_errno_logged(errno)
    lines = logged(:debug).select { |line| line.include?(address) && line.include?(errno.name.split("::").last) }
    expect(lines).not_to be_empty, "no debug line names #{address} and #{errno}: #{log.inspect}"
    expect(lines).to all(match(/\b#{errno::Errno}\b/))
    expect(logged(:warn) + logged(:error)).to be_empty
  end

  # Each client request as a short tuple, so a whole request sequence reads as
  # one list: [:mtu, Client Rx MTU]; [:primary | :secondary, start, end] for
  # Read By Group Type 0x2800 / 0x2801; [:includes | :characteristics | :hash,
  # start, end] for Read By Type 0x2802 / 0x2803 / 0x2B2A; [:descriptors,
  # start, end] for Find Information; [:read, handle]; [:read_blob, handle,
  # offset]. Anything else stays its decoded PDU. +served+ is the peer whose
  # requests are listed, the let peer unless given.
  def request_summaries(served = peer)
    kinds = { 0x2800 => :primary, 0x2801 => :secondary, 0x2802 => :includes, 0x2803 => :characteristics,
              0x2B2A => :hash }.transform_keys { |uuid| codec.uuid16(uuid) }
    served.requests.map do |request|
      pdu = request.pdu
      case pdu
      when codec::ExchangeMtuRequest then [:mtu, pdu.mtu]
      when codec::ReadByGroupTypeRequest, codec::ReadByTypeRequest
        [kinds.fetch(pdu.uuid, pdu.uuid), pdu.start_handle, pdu.end_handle]
      when codec::FindInformationRequest then [:descriptors, pdu.start_handle, pdu.end_handle]
      when codec::ReadRequest then [:read, pdu.handle]
      when codec::ReadBlobRequest then [:read_blob, pdu.handle, pdu.offset]
      else pdu
      end
    end
  end

  # The decoded PDU the peer (+served+, the let peer unless given) delivered in
  # answer to client request +index+.
  def response_to(index, served = peer)
    delivered = served.delivered.find { |pdu| pdu.kind == :response && pdu.request_index == index }
    delivered && codec.decode(delivered.raw)
  end

  # The WalkState the Walk worked through, nil when it ended before one was
  # built. report.state carries it only for timeout and disconnected; the
  # discovery and hash check examples read what a Walk discovered from it,
  # at the AttCodec::Uuid values the report renders.
  def walked_state(walker)
    walker.instance_variable_get(:@state)
  end

  # +state+'s services and characteristics in
  # GattDatabase#expected_discovery's shape, so a Walk's discovery compares
  # directly against the database it walked.
  def discovered(state)
    {
      services: state.services,
      characteristics: state.characteristics.map do |char|
        { service_index: char.service_index, decl_handle: char.decl_handle, value_handle: char.value_handle,
          properties: char.properties, uuid: char.uuid,
          descriptors: char.descriptors.map { |handle, uuid| { handle: handle, uuid: uuid } } }
      end
    }
  end

  # Makes the peer's send raise +errno+ for the first PDU +which+ picks (it
  # is given the PDU's bytes), as a send on a Link that has just gone does.
  # The harness's own hooks drop the Link only as a response is read, and a
  # send then fails only once the walker has seen the EOF, by which time it
  # sends nothing more; this is the send that finds the Link gone first. The
  # PDU never reaches the peer: no Received, no :send call.
  def fail_send(errno, &which)
    failed = false
    peer.singleton_class.prepend(Module.new do
      define_method(:send) do |bytes, flags = 0, *rest|
        if !failed && which.call(bytes.b)
          failed = true
          raise errno
        end
        super(bytes, flags, *rest)
      end
    end)
  end

  describe "opening, binding and connecting the Att_Bearer (Requirement 5.1)" do
    it "opens one AF_BLUETOOTH SOCK_SEQPACKET BTPROTO_L2CAP socket and walks on it" do
      expect(Socket).to receive(:new).with(31, Socket::SOCK_SEQPACKET, 0).once.and_return(peer)
      walker = walker_with_real_open_socket(plan: through_exchange_plan)

      report = walker.run

      expect(report.outcome).to eq(:complete)
      expect(call_names).to eq(%i[bind connect_nonblock send close])
      expect_bearer_closed(walker, report)
    end

    it "binds the controller address as LE public on CID 0x0004, then connects to the handed-off random address" do
      walker = peer.build_walker(plan: through_exchange_plan)
      report = walker.run

      expect(report.outcome).to eq(:complete)
      expect(call_names).to eq(%i[open bind connect_nonblock send close])
      # struct sockaddr_l2: family 31, l2_psm 0, bdaddr little-endian, l2_cid 0x0004, l2_bdaddr_type
      expect(socket_call(:bind).args.first.unpack1("H*")).to eq("1f000000554433221100040001")
      expect(socket_call(:connect_nonblock).args.first.unpack1("H*")).to eq("1f000000ffeeddccbb7a040002")
      expect(peer.bound_sockaddr).to eq(family: 31, psm: 0, address: local_address, cid: 0x0004, address_type: 0x01)
      expect(peer.connected_sockaddr).to eq(family: 31, psm: 0, address: address, cid: 0x0004, address_type: 0x02)
    end

    it "connects with the public address type a handoff carries and binds the configured controller address" do
      walker = peer.build_walker(address: "C0:FF:EE:00:00:01", address_type: BlueHydra::Mgmt::LE_PUBLIC,
                                 local_address: "AA:BB:CC:00:11:22", plan: through_exchange_plan)
      walker.run

      expect(socket_call(:bind).args.first.unpack1("H*")).to eq("1f000000221100ccbbaa040001")
      expect(socket_call(:connect_nonblock).args.first.unpack1("H*")).to eq("1f000000010000eeffc0040001")
    end

    it "reads a pending connect's result from SO_ERROR once, without connecting again" do
      peer.connect_outcome(:pending, after: 0.999)
      walker = peer.build_walker(plan: through_exchange_plan)
      report = walker.run

      expect(report.outcome).to eq(:complete)
      expect(call_names).to eq(%i[open bind connect_nonblock getsockopt send close])
      expect(peer.waits.select { |wait| wait.kind == :writable }.map(&:timeout)).to eq([1.0])
      expect_one_exchange(report)
    end

    it "has no setsockopt call anywhere in the walker source (Requirements 5.2, 5.11)" do
      source = File.read(File.expand_path("../lib/blue_hydra/gatt_walker.rb", __dir__))
      code   = source.lines.reject { |line| line.lstrip.start_with?("#") }.join
      expect(code).not_to match(/setsockopt|BT_SECURITY/)
    end
  end

  describe "with no Link up (Requirement 5.10)" do
    it "issues no bind or connect and records disconnected" do
      asked  = []
      walker = peer.build_walker(link_up: ->(link_address) { asked << link_address; nil })
      report = walker.run

      expect(asked).to eq([address])
      expect(call_names).to eq(%i[open close])
      expect(peer.connected_sockaddr).to be_nil
      expect(report.handoff_lag).to be_nil
      expect_ended_before_any_pdu(walker, report, :disconnected)
      expect(logged(:debug)).to include(a_string_including(address))
    end
  end

  describe "a connect failing with EBUSY (Requirement 5.3)" do
    it "closes the socket and records busy, without retrying or sending a PDU" do
      peer.connect_outcome(Errno::EBUSY)
      walker = peer.build_walker
      report = walker.run

      expect(call_names).to eq(%i[open bind connect_nonblock close])
      expect_ended_before_any_pdu(walker, report, :busy)
    end

    it "records busy for EBUSY read back from SO_ERROR too" do
      peer.connect_outcome(:pending, after: 0.01, so_error: Errno::EBUSY)
      walker = peer.build_walker
      report = walker.run

      expect(call_names).to eq(%i[open bind connect_nonblock getsockopt close])
      expect_ended_before_any_pdu(walker, report, :busy)
    end
  end

  describe "a connect that finds no Link to attach to (Requirement 5.4)" do
    disconnect_errnos.each do |errno|
      it "records disconnected when connect raises #{errno.name}" do
        peer.connect_outcome(errno)
        walker = peer.build_walker
        report = walker.run

        expect(call_names).to eq(%i[open bind connect_nonblock close])
        expect_ended_before_any_pdu(walker, report, :disconnected)
      end

      it "records disconnected when SO_ERROR reads #{errno.name}" do
        peer.connect_outcome(:pending, after: 0.05, so_error: errno)
        walker = peer.build_walker
        report = walker.run

        expect(call_names).to eq(%i[open bind connect_nonblock getsockopt close])
        expect_ended_before_any_pdu(walker, report, :disconnected)
      end
    end

    it "records disconnected when the connect has not completed within 1 s" do
      peer.connect_outcome(:never)
      walker = peer.build_walker
      report = walker.run

      expect(socket_call(:close).at - socket_call(:connect_nonblock).at).to eq(1.0)
      expect(peer.waits.map { |wait| [wait.kind, wait.timeout] }).to eq([[:writable, 1.0]])
      expect(call_names).to eq(%i[open bind connect_nonblock close])
      expect_ended_before_any_pdu(walker, report, :disconnected)
    end

    # Requirement 5.5's debug line for ENOSYS. bt_to_errno has no case for
    # HCI 0x3E Connection Failed to be Established and answers ENOSYS for it,
    # so the commonest unanswered-connect outcome would otherwise read as a
    # missing syscall; the line says what the kernel meant. The outcome is
    # the table's, disconnected, hint or no hint.
    describe "the ENOSYS failure line" do
      let(:enosys_hint) do
        ", kernel: unmapped HCI status (bt_to_errno fallback), typically 0x3E Connection Failed to be Established"
      end

      it "carries the bt_to_errno hint when connect raises ENOSYS" do
        peer.connect_outcome(Errno::ENOSYS)
        walker = peer.build_walker
        report = walker.run

        expect_ended_before_any_pdu(walker, report, :disconnected)
        expect(logged(:debug)).to include(
          "gatt: #{address} bearer connect disconnected: Errno::ENOSYS (errno #{Errno::ENOSYS::Errno})#{enosys_hint}"
        )
        expect(logged(:warn) + logged(:error)).to be_empty
      end

      it "carries the hint when SO_ERROR reads ENOSYS too" do
        peer.connect_outcome(:pending, after: 0.05, so_error: Errno::ENOSYS)
        walker = peer.build_walker
        report = walker.run

        expect_ended_before_any_pdu(walker, report, :disconnected)
        expect(logged(:debug)).to include(
          "gatt: #{address} bearer connect disconnected: Errno::ENOSYS (errno #{Errno::ENOSYS::Errno})#{enosys_hint}"
        )
      end

      it "is plain for any other disconnected errno" do
        peer.connect_outcome(Errno::ETIMEDOUT)
        walker = peer.build_walker
        report = walker.run

        expect_ended_before_any_pdu(walker, report, :disconnected)
        failure_lines = logged(:debug).grep(/bearer connect/)
        expect(failure_lines).to eq(
          ["gatt: #{address} bearer connect disconnected: Errno::ETIMEDOUT (errno #{Errno::ETIMEDOUT::Errno})"]
        )
        expect(failure_lines.join).not_to include("bt_to_errno")
      end
    end
  end

  describe "any other bearer setup errno (Requirement 5.5)" do
    it "records error and logs the address and errno at debug when connect raises EINVAL" do
      peer.connect_outcome(Errno::EINVAL)
      walker = peer.build_walker
      report = walker.run

      expect_ended_before_any_pdu(walker, report, :error)
      expect_errno_logged(Errno::EINVAL)
    end

    it "records error when SO_ERROR reads EINVAL" do
      peer.connect_outcome(:pending, after: 0.05, so_error: Errno::EINVAL)
      walker = peer.build_walker
      report = walker.run

      expect_ended_before_any_pdu(walker, report, :error)
      expect_errno_logged(Errno::EINVAL)
    end

    it "records EMLINK from connect as error: conn_limit belongs to LeConnect" do
      peer.connect_outcome(Errno::EMLINK)
      walker = peer.build_walker
      report = walker.run

      expect_ended_before_any_pdu(walker, report, :error)
      expect_errno_logged(Errno::EMLINK)
    end

    it "records error with no connect when bind raises EINVAL" do
      peer.bind_raises(Errno::EINVAL)
      walker = peer.build_walker
      report = walker.run

      expect(call_names).to eq(%i[open bind close])
      expect_ended_before_any_pdu(walker, report, :error)
      expect_errno_logged(Errno::EINVAL)
    end

    it "records error when the socket cannot be opened" do
      allow(Socket).to receive(:new).and_raise(Errno::EAFNOSUPPORT)
      walker = walker_with_real_open_socket
      report = walker.run

      expect(report.outcome).to eq(:error)
      expect(walker.bearer).to be_nil
      expect(report.requests_sent).to eq(0)
      expect(peer.calls).to be_empty
      expect_errno_logged(Errno::EAFNOSUPPORT)
    end
  end

  describe "closing the Att_Bearer before run returns (Requirement 5.6)" do
    [
      [:busy,         "connect raised EBUSY",                       -> { peer.connect_outcome(Errno::EBUSY); {} }],
      [:disconnected, "no Link was up",                             -> { { link_up: ->(_address) { nil } } }],
      [:disconnected, "the Link dropped during the exchange",       -> { peer.drop_link_after(0); {} }],
      [:error,        "connect raised EINVAL",                      -> { peer.connect_outcome(Errno::EINVAL); {} }],
      [:error,        "recv raised EINVAL during the exchange",     -> { peer.raise_on_recv(Errno::EINVAL); {} }],
      [:timeout,      "the exchange went unanswered to Walk_Bound", -> { peer.delay_response(0, Float::INFINITY); {} }],
      [:complete,     "the Walk reached its end",                   -> { { plan: through_exchange_plan } }]
    ].each do |outcome, why, script|
      it "closes it when the Walk ends #{outcome} (#{why})" do
        walker = peer.build_walker(**instance_exec(&script))
        report = walker.run

        expect(report.outcome).to eq(outcome)
        expect(report.requests_sent).to eq(peer.requests.size)
        expect_bearer_closed(walker, report)
      end
    end
  end

  describe "shutdown" do
    it "sends no PDU once stopping is true (Requirement 14.6)" do
      walker = peer.build_walker(stopping: -> { true })
      report = walker.run

      expect(call_names).not_to include(:send)
      expect_ended_before_any_pdu(walker, report, :disconnected)
    end

    it "records disconnected with no bind or connect when close_bearer ran first on another thread" do
      walker = peer.build_walker
      Thread.new { walker.close_bearer }.join
      report = walker.run

      expect(peer.open_count).to eq(1)
      expect(call_names).to eq(%i[open close])
      expect_ended_before_any_pdu(walker, report, :disconnected)
    end
  end

  describe "the Exchange MTU (Requirements 5.7, 5.8)" do
    # [Server Rx MTU answered, ATT_MTU]: our 517 caps a larger answer, and an
    # answer below 23 is floored at 23.
    [[23, 23], [517, 517], [247, 247], [65_535, 517], [22, 23], [0, 23]].each do |server_rx, mtu|
      context "answered with Server Rx MTU #{server_rx}" do
        let(:server_rx_mtu) { server_rx }

        it "uses ATT_MTU #{mtu}" do
          walker = peer.build_walker(plan: through_exchange_plan)
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(report.mtu).to eq(mtu)
          expect(peer.att_mtu).to eq(mtu) # the harness's own floor-23 minimum agrees
          expect_one_exchange(report)
          expect_bearer_closed(walker, report)
        end
      end
    end

    it "continues the Walk at ATT_MTU 23 when the exchange is answered with an Error Response" do
      peer.answer_with_error(0, 0x06) # Request Not Supported
      walker = peer.build_walker(plan: through_exchange_plan)
      report = walker.run

      expect(peer.delivered.map(&:raw))
        .to eq([codec.encode(codec::ErrorResponse.new(request_opcode: 0x02, handle: 0x0000, error_code: 0x06))])
      # The Error Response did not end the Walk: it went on to the end of its
      # worklist.
      expect(report.outcome).to eq(:complete)
      expect(report.mtu).to eq(23)
      expect_one_exchange(report)
      expect_bearer_closed(walker, report)
    end

    it "sends no second Exchange MTU Request when the first goes unanswered" do
      peer.delay_response(0, Float::INFINITY)
      walker = peer.build_walker
      report = walker.run

      expect(report.outcome).to eq(:timeout)
      expect(report.mtu).to eq(23)
      expect_one_exchange(report)
    end

    # Feature: gatt-service-scanning, Property 3: ATT_MTU is the floor-23 minimum of the three MTUs
    #
    # For any Server Rx MTU 0..65535 answered to our Exchange MTU Request and
    # any Client Rx MTU 0..65535 in an Exchange MTU Request the peer sends
    # before or after ours, ATT_MTU is max(23, min(517, Server Rx MTU, Client
    # Rx MTU or 517)) for the rest of the Walk, and the Walk sends exactly one
    # Exchange MTU Request on its bearer.
    #
    # Each case is two Walks, both end to end: a full Walk on 256 one-handle
    # primary services, whose Read By Group Type pages carry
    # (ATT_MTU - 2) / 6 entries, so the first three pages are full at every
    # ATT_MTU up to 517. The Link drops once the exchange and those three
    # pages have been answered, so the Walk ends disconnected, and its report
    # carries the ATT_MTU it ended with and, as the live WalkState, the
    # services it found. In both, the walker's ATT_MTU equals the expected
    # one and the one the harness paged at; every response served fits in
    # it; every page is full at it (one more 6-octet entry would not fit), so
    # the server paged at that MTU and no smaller one; the walker recorded
    # exactly the services those pages carried; and its one Exchange MTU
    # Request was its first request.
    #
    # (a) The Server Rx MTU alone: the peer sends no request of its own.
    # (b) The peer's Client Rx MTU as well, through the Att_Server. The peer
    #     sends an Exchange MTU Request while our exchange is outstanding
    #     (inject_peer_pdu before_request: 0, so it is answered before our
    #     exchange's answer is read: before), and one while the first primary
    #     page is (before_request: 1: after). The walker answers each with an
    #     Exchange MTU Response, which the harness's att_mtu counts as an
    #     exchange too, so the page checks cover the Client Rx MTU as they do
    #     the Server Rx MTU. A last one, before the second page, carries a
    #     Client Rx MTU at or above the ATT_MTU reached and leaves it as it
    #     is: the lowest cap stands. Each reply goes through on_peer_request
    #     once.
    #
    # The input is [Server Rx MTU, Client Rx MTU before, Client Rx MTU after,
    # raise_by], a Client Rx MTU nil when the peer sends no request at that
    # point. Each MTU is drawn below 23, in 23..517, above 517 or at a
    # boundary, so the floor, the minimum and our 517 each decide some cases.
    # A plain Array is not shrinkable in rantly, so a failing case is printed
    # as generated.
    it "Property 3: ATT_MTU is the floor-23 minimum of the three MTUs, after exactly one Exchange MTU Request" do
      expected_mtu = ->(*mtus) { [23, [517, *mtus.compact].min].max }
      entry_octets = 6 # a Read By Group Type entry: handle, End Group Handle, 16-bit UUID
      full_pages   = 3
      paged_db = GattDatabase.build do |b|
        (full_pages * ((517 - 2) / entry_octets) + 1).times { |i| b.primary(0x1000 + i) }
      end
      exchange_response = codec::ExchangeMtuResponse.new(mtu: 517)

      # A Walk of paged_db, +script+ scripting its peer first:
      # [peer, report, on_peer_request calls].
      walk = lambda do |server_rx, script = nil|
        served = FakeAttPeer.new(paged_db, clock: FakeClock.new, server_rx_mtu: server_rx)
        script&.call(served)
        served.drop_link_after(1 + full_pages)
        calls  = 0
        report = served.build_walker(on_peer_request: -> { calls += 1 }).run
        [served, report, calls]
      end

      # The Walk ran at +att_mtu+ from its first page on.
      expect_paged_at = lambda do |served, report, att_mtu|
        expect(report.outcome).to eq(:disconnected)
        expect(served.closed?).to be(true)
        expect(report.mtu).to eq(att_mtu)
        expect(served.att_mtu).to eq(att_mtu)
        expect(served.requests.first.pdu).to eq(codec::ExchangeMtuRequest.new(mtu: 517))
        expect(served.requests.map(&:pdu).grep(codec::ExchangeMtuRequest).size).to eq(1)
        expect(report.requests_sent).to eq(served.requests.size)
        responses = served.delivered.select { |pdu| pdu.kind == :response }.map(&:raw)
        expect(responses.map(&:bytesize)).to all(be <= att_mtu)
        pages = responses.drop(1)
        expect(pages.map { |raw| raw.getbyte(0) }).to eq([0x11] * full_pages)
        expect(pages.map(&:bytesize)).to all(be > att_mtu - entry_octets)
        per_page = (att_mtu - 2) / entry_octets
        expect(report.state.services.map { |service| service[:start] }).to eq((1..full_pages * per_page).to_a)
        expect(served.violations).to be_empty
      end

      seen = Hash.new(0)
      # A proc, because rantly instance_evals generators on itself.
      mtu = proc {
        freq([2, proc { range(0, 22) }], [3, proc { range(23, 517) }], [2, proc { range(518, 0xFFFF) }],
             [2, proc { choose(0, 22, 23, 24, 516, 517, 518, 0xFFFF) }])
      }

      property_of {
        [call(mtu), freq([1, :literal, nil], [2, mtu]), freq([1, :literal, nil], [2, mtu]), range(0, 0xFFFF)]
      }.check(200) { |server_rx, client_rx_before, client_rx_after, raise_by|
        seen[server_rx < 23 ? :below_floor : (server_rx > 517 ? :above_517 : :negotiable)] += 1
        seen[:before] += 1 if client_rx_before
        seen[:after] += 1 if client_rx_after

        # (a) the Server Rx MTU alone
        served, report, calls = walk.(server_rx)
        expect_paged_at.(served, report, expected_mtu.(server_rx))
        expect(served.peer_received).to be_empty
        expect(calls).to eq(0)

        # (b) the peer's Client Rx MTU before and after our exchange, then one
        # that would raise it
        reached = expected_mtu.(server_rx, client_rx_before, client_rx_after)
        # before_request => the Client Rx MTU the peer sends then
        sent = { 0 => client_rx_before, 1 => client_rx_after, 2 => [reached + raise_by, 0xFFFF].min }.compact
        served, report, calls = walk.(server_rx, lambda { |capped|
          sent.each do |index, client_rx|
            capped.inject_peer_pdu(codec::ExchangeMtuRequest.new(mtu: client_rx), before_request: index)
          end
        })
        expect_paged_at.(served, report, reached)
        expect(served.injections.map { |injection| [injection.before_request, injection.delivered_at.nil?] })
          .to eq(sent.keys.map { |index| [index, false] })
        expect(served.injections.map { |injection| injection.reply&.pdu }).to all(eq(exchange_response))
        expect(served.peer_received.size).to eq(served.injections.size)
        expect(calls).to eq(served.injections.size)
      }

      expect(seen.keys).to include(:below_floor, :negotiable, :above_517, :before, :after)
    end
  end

  # GATT discovery (Requirement 6). The databases give their characteristics
  # no Read property, so a Walk of them sends discovery requests only and its
  # whole request sequence can be listed.
  describe "discovery (Requirement 6)" do
    describe "paging (Requirements 6.1, 6.3, 6.4, 6.12)" do
      # At ATT_MTU 23 three Read By Group Type entries, three characteristic
      # declarations or five Find Information entries fit in a page, so the
      # primary, characteristic and descriptor procedures each take more than
      # one; at 517 each fits in one.
      let(:db) do
        GattDatabase.build do
          primary 0x180F do                              # 0x0001..0x000F
            characteristic 0x2A19, props: [:notify]      # 0x0002 / 0x0003
            characteristic 0x2A1A, props: [:notify]      # 0x0004 / 0x0005
            characteristic 0x2A1B, props: [:notify]      # 0x0006 / 0x0007
            characteristic 0x2A1C, props: [:notify] do   # 0x0008 / 0x0009
              [0x2901, 0x2902, 0x2903, 0x2905, 0x2906, 0x2907].each { |uuid| descriptor uuid } # 0x000A..0x000F
            end
          end
          primary 0x1800                                 # 0x0010
          primary 0x1801                                 # 0x0011
          primary 0x180A, end_at: 0x0020                 # 0x0012..0x0020
          secondary 0x1812, end_at: 0xFFFF               # 0x0021..0xFFFF
        end
      end

      # Each request after a procedure's first starts at the previous page's
      # last handle + 1, its last End Group Handle for services. Primary
      # discovery ends on 0x0A; secondary on a page whose End Group Handle is
      # 0xFFFF; the first service's characteristics on 0x0A after a page ending
      # below the service end; the last characteristic's descriptors, which
      # run to the service end, on a page reaching it. The other descriptor
      # ranges are empty and get no request. A service's includes and
      # characteristics follow in start order once both service procedures
      # have ended, and its descriptors once its characteristics have.
      {
        23 => [
          [:mtu, 517],
          [:primary, 0x0001, 0xFFFF], [:primary, 0x0012, 0xFFFF], [:primary, 0x0021, 0xFFFF],
          [:secondary, 0x0001, 0xFFFF],
          [:includes, 0x0001, 0x000F],
          [:characteristics, 0x0001, 0x000F], [:characteristics, 0x0007, 0x000F], [:characteristics, 0x0009, 0x000F],
          [:includes, 0x0010, 0x0010], [:characteristics, 0x0010, 0x0010],
          [:includes, 0x0011, 0x0011], [:characteristics, 0x0011, 0x0011],
          [:includes, 0x0012, 0x0020], [:characteristics, 0x0012, 0x0020],
          [:includes, 0x0021, 0xFFFF], [:characteristics, 0x0021, 0xFFFF],
          [:descriptors, 0x000A, 0x000F], [:descriptors, 0x000F, 0x000F]
        ],
        517 => [
          [:mtu, 517],
          [:primary, 0x0001, 0xFFFF], [:primary, 0x0021, 0xFFFF],
          [:secondary, 0x0001, 0xFFFF],
          [:includes, 0x0001, 0x000F],
          [:characteristics, 0x0001, 0x000F], [:characteristics, 0x0009, 0x000F],
          [:includes, 0x0010, 0x0010], [:characteristics, 0x0010, 0x0010],
          [:includes, 0x0011, 0x0011], [:characteristics, 0x0011, 0x0011],
          [:includes, 0x0012, 0x0020], [:characteristics, 0x0012, 0x0020],
          [:includes, 0x0021, 0xFFFF], [:characteristics, 0x0021, 0xFFFF],
          [:descriptors, 0x000A, 0x000F]
        ]
      }.each do |mtu, expected_requests|
        context "at ATT_MTU #{mtu}" do
          let(:server_rx_mtu) { mtu }

          it "asks for each next page from the last handle + 1 and discovers the whole database" do
            walker = peer.build_walker
            report = walker.run

            expect(report.outcome).to eq(:complete)
            expect(report.mtu).to eq(mtu)
            expect(request_summaries).to eq(expected_requests)
            expect(report.requests_sent).to eq(expected_requests.size)
            expect(peer.delivered.map { |pdu| pdu.raw.bytesize }).to all(be <= mtu)
            state = walked_state(walker)
            expect(state.partial).to be(false)
            expect(state.procedures).to be_empty
            expect(discovered(state)).to eq(db.expected_discovery)
            expect_bearer_closed(walker, report)
          end
        end
      end
    end

    context "on an empty database" do
      let(:db) { GattDatabase.empty }

      it "records complete when both service procedures get 0x0A on their first request (Requirement 6.8)" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(request_summaries).to eq([[:mtu, 517], [:primary, 0x0001, 0xFFFF], [:secondary, 0x0001, 0xFFFF]])
        not_found = codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x0A)
        expect([response_to(1), response_to(2)]).to eq([not_found, not_found])
        expect(report.requests_sent).to eq(3)
        expect([report.services, report.characteristics, report.identity]).to eq([[], [], {}])
        expect(walked_state(walker).services).to be_empty
        expect(report.state).to be_nil
        expect_bearer_closed(walker, report)
      end
    end

    describe "includes (Requirement 6.2)" do
      let(:custom_uuid) { GattDatabase.uuid("6e400001-b5a3-f393-e0a9-e50e24dcca9e") }
      let(:db) do
        GattDatabase.build do
          primary 0x1800 do                 # 0x0001..0x0004
            include_service :custom         # 0x0002: a 128-bit service, so the 4-octet form
            include_range 0x0100, 0x0104    # 0x0003: the 4-octet form, and no service starts at 0x0100
            include_service :battery        # 0x0004: a 16-bit service, so the 6-octet form
          end
          secondary "6e400001-b5a3-f393-e0a9-e50e24dcca9e", name: :custom # 0x0005
          secondary 0x180F, name: :battery                                # 0x0006
        end
      end

      it "takes a 4-octet include's UUID from the discovered service at its start handle, or none, sending no Read" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        # A Read By Type page holds one value length: the two 4-octet includes
        # (length 6), then the 6-octet one (length 8).
        expect(request_summaries.values_at(6, 7)).to eq([[:includes, 0x0001, 0x0004], [:includes, 0x0004, 0x0004]])
        expect(response_to(6)).to have_attributes(length: 6, entries: [[0x0002, [5, 5].pack("S<S<")],
                                                                       [0x0003, [0x0100, 0x0104].pack("S<S<")]])
        expect(response_to(7).length).to eq(8)
        expect(walked_state(walker).services.first[:includes]).to eq([
          { start: 0x0005, end: 0x0005, uuid: custom_uuid },
          { start: 0x0100, end: 0x0104, uuid: nil },
          { start: 0x0006, end: 0x0006, uuid: codec.uuid16(0x180F) }
        ])
        expect(discovered(walked_state(walker))).to eq(db.expected_discovery)
        expect(peer.requests.map(&:opcode)).not_to include(0x0A, 0x0C)
      end
    end

    describe "descriptor ranges (Requirement 6.3)" do
      let(:db) do
        GattDatabase.build do
          primary 0x180D, end_at: 0x0010 do              # 0x0001..0x0010
            characteristic 0x2A37, props: [:notify] do   # 0x0002 / 0x0003
              descriptor 0x2902, value: [0x00, 0x00]     # 0x0004
            end
            characteristic 0x2A38, props: [:notify]      # 0x0005 / 0x0006: the next declaration follows at once
            characteristic 0x2A39, props: [:notify] do   # 0x0007 / 0x0008: the last, so its range runs to 0x0010
              descriptor 0x2901, value: "x"              # 0x0009
            end
          end
          primary 0x1800 do                              # 0x0011..0x0013
            characteristic 0x2A19, props: [:notify]      # 0x0012 / 0x0013: its value is the service's last handle
          end
        end
      end

      it "searches from each value handle + 1 to the next declaration or the service end, skipping empty ranges" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        # 0x0006 + 1 > 0x0007 - 1 and 0x0013 + 1 > 0x0013: no request for either.
        expect(request_summaries.select { |kind, *| kind == :descriptors })
          .to eq([[:descriptors, 0x0004, 0x0004], [:descriptors, 0x0009, 0x0010], [:descriptors, 0x000A, 0x0010]])
        expect(walked_state(walker).characteristics.map { |char| char.descriptors.map(&:first) })
          .to eq([[0x0004], [], [0x0009], []])
        expect(discovered(walked_state(walker))).to eq(db.expected_discovery)
      end
    end

    describe "a Security_Error on the first primary-service request (Requirement 6.7)" do
      [0x05, 0x08, 0x0C, 0x0F].each do |code|
        it format("records protected after 0x%02x and sends no further request", code) do
          peer.security_error_on_first_primary(code)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:protected)
          expect(request_summaries).to eq([[:mtu, 517], [:primary, 0x0001, 0xFFFF]])
          expect(response_to(1)).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: code))
          expect(report.requests_sent).to eq(2)
          expect(walked_state(walker).services).to be_empty
          expect(report.state).to be_nil
          expect_bearer_closed(walker, report)
        end
      end
    end

    describe "Error Response 0x10 Unsupported Group Type (Requirements 6.4, 6.6)" do
      # Android's GATT server answers every Read By Group Type whose type is
      # not Primary Service with 0x10 (gatt_sr.cc,
      # gatts_process_primary_service_req), so the 0x2801 sweep is refused on
      # its first request. The first primary service includes the secondary
      # one in the 4-octet form; the two primaries each hold a readable
      # Identity_Set characteristic (read whatever read_all is), the secondary
      # a readable one outside the set; the first and the last characteristic
      # carry a descriptor. So the examples see what is still walked and read,
      # and what the Walk never learns of.
      let(:db) do
        GattDatabase.build do
          primary 0x1800 do                                                 # 0x0001..0x0005
            include_service :custom                                         # 0x0002: 4-octet, the secondary below
            characteristic 0x2A00, props: [:read], value: "Name" do         # 0x0003 / 0x0004
              descriptor 0x2901, value: "n"                                 # 0x0005
            end
          end
          primary 0x180A do                                                 # 0x0006..0x0008
            characteristic 0x2A29, props: [:read], value: "Acme"            # 0x0007 / 0x0008
          end
          secondary "6e400001-b5a3-f393-e0a9-e50e24dcca9e", name: :custom do # 0x0009..0x000C
            characteristic 0x2A19, props: [:read], value: "\x64" do         # 0x000A / 0x000B
              descriptor 0x2902, value: [0x00, 0x00]                        # 0x000C
            end
          end
        end
      end

      it "ends secondary discovery normally on 0x10 and still walks and reads every primary service (Requirement 6.4)" do
        peer.reject_secondary_services!
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        # One 0x2801 request, answered 0x10 with its Starting Handle, and no
        # second; then both primary services' includes, characteristics and
        # the one descriptor range, then the two Identity_Set reads. No
        # request names a handle of the secondary service (0x0009..0x000C).
        expect(request_summaries).to eq([
          [:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x0009, 0xFFFF],
          [:secondary, 0x0001, 0xFFFF],
          [:includes, 0x0001, 0x0005], [:includes, 0x0003, 0x0005],
          [:characteristics, 0x0001, 0x0005], [:characteristics, 0x0004, 0x0005],
          [:includes, 0x0006, 0x0008],
          [:characteristics, 0x0006, 0x0008], [:characteristics, 0x0008, 0x0008],
          [:descriptors, 0x0005, 0x0005],
          [:read, 0x0004], [:read, 0x0008]
        ])
        expect(response_to(3)).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x10))
        expect(report.requests_sent).to eq(14)

        state = walked_state(walker)
        expect(state.partial).to be(false)
        expect(state.procedures).to be_empty
        # The secondary service is never recorded, so the 4-octet include of
        # it has no discovered service to take its UUID from (Requirement 6.2).
        expect(state.services).to eq([
          { uuid: codec.uuid16(0x1800), type: :primary, start: 0x0001, end: 0x0005,
            includes: [{ start: 0x0009, end: 0x000C, uuid: nil }] },
          { uuid: codec.uuid16(0x180A), type: :primary, start: 0x0006, end: 0x0008, includes: [] }
        ])
        expect(state.characteristics.map { |char| [char.decl_handle, char.value_handle, char.descriptors.map(&:first)] })
          .to eq([[0x0003, 0x0004, [0x0005]], [0x0007, 0x0008, []]])
        expect(report.characteristics.map { |entry| entry.values_at(:value_handle, :read_status) })
          .to eq([[0x0004, "read"], [0x0008, "read"]])
        expect(report.identity).to eq(device_name: "Name", manufacturer_name: "Acme")
        expect(logged(:debug).grep(/ended partial/)).to be_empty
        expect(report.state).to be_nil
        expect_bearer_closed(walker, report)
      end

      it "ends primary discovery partial on 0x10, walking what the secondary sweep finds (Requirement 6.6)" do
        peer.answer_with_error(1, 0x10)
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:partial)
        # No second primary request; the secondary service is still found,
        # walked and its readable value read.
        expect(request_summaries).to eq([
          [:mtu, 517], [:primary, 0x0001, 0xFFFF],
          [:secondary, 0x0001, 0xFFFF], [:secondary, 0x000D, 0xFFFF],
          [:includes, 0x0009, 0x000C],
          [:characteristics, 0x0009, 0x000C], [:characteristics, 0x000B, 0x000C],
          [:descriptors, 0x000C, 0x000C],
          [:read, 0x000B]
        ])
        expect(response_to(1)).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x10))
        state = walked_state(walker)
        expect(state.partial).to be(true)
        expect(state.services.map { |service| service.values_at(:type, :start, :end) }).to eq([[:secondary, 0x0009, 0x000C]])
        expect(state.characteristics.map(&:value_handle)).to eq([0x000B])
        expect(logged(:debug))
          .to include(a_string_including("primary discovery 0x0001..0xffff ended partial at 0x0001: Error Response 0x10"))
        expect(report.state).to be_nil
        expect_bearer_closed(walker, report)
      end
    end

    describe "a discovery response that cannot be used (Requirements 6.5, 6.6, 6.9, 6.13)" do
      # At ATT_MTU 23 the four primary services take two Read By Group Type
      # pages and the first service's four characteristics two Read By Type
      # pages. Request 2 asks for the second primary page, from 0x000C, and
      # only it carries the fourth service; request 6 asks for the first
      # characteristic page.
      let(:server_rx_mtu) { 23 }
      let(:db) do
        GattDatabase.build do
          primary 0x180F do                           # 0x0001..0x0009
            characteristic 0x2A19, props: [:notify]   # 0x0002 / 0x0003
            characteristic 0x2A1A, props: [:notify]   # 0x0004 / 0x0005
            characteristic 0x2A1B, props: [:notify]   # 0x0006 / 0x0007
            characteristic 0x2A1C, props: [:notify]   # 0x0008 / 0x0009
          end
          primary 0x1800                              # 0x000A
          primary 0x1801                              # 0x000B
          primary 0x180A                              # 0x000C
        end
      end

      # A Security_Error on request 2 is not on the first primary-service
      # request, so it makes the Walk partial rather than protected.
      [
        ["handles that do not advance (the first page resent)", -> { peer.corrupt_page(2, :non_advancing) }],
        ["a handle below the Starting Handle",                  -> { peer.corrupt_page(2, :handle_below_start) }],
        ["handles that do not strictly increase",               -> { peer.corrupt_page(2, :non_increasing) }],
        ["an End Group Handle below its own handle",            -> { peer.corrupt_page(2, :end_before_start) }],
        ["a truncated page",                                    -> { peer.corrupt_page(2, :truncated) }],
        ["a page with no entries",                              -> { peer.corrupt_page(2, :no_entries) }],
        ["a page with a length no entry has",                   -> { peer.corrupt_page(2, :bad_length) }],
        ["a response opcode that does not answer the request",  -> { peer.corrupt_page(2, :wrong_opcode) }],
        ["Security_Error 0x05",                                 -> { peer.answer_with_error(2, 0x05) }],
        ["Security_Error 0x0F",                                 -> { peer.answer_with_error(2, 0x0F) }],
        ["Error Response 0x0E Unlikely Error",                  -> { peer.answer_with_error(2, 0x0E) }]
      ].each do |why, script|
        it "ends primary discovery partial on #{why}, keeping and walking the first page's services" do
          instance_exec(&script)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:partial)
          # No third primary request, and every other procedure still runs.
          expect(request_summaries).to eq([
            [:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x000C, 0xFFFF],
            [:secondary, 0x0001, 0xFFFF],
            [:includes, 0x0001, 0x0009],
            [:characteristics, 0x0001, 0x0009], [:characteristics, 0x0007, 0x0009], [:characteristics, 0x0009, 0x0009],
            [:includes, 0x000A, 0x000A], [:characteristics, 0x000A, 0x000A],
            [:includes, 0x000B, 0x000B], [:characteristics, 0x000B, 0x000B]
          ])
          state = walked_state(walker)
          expect(state.partial).to be(true)
          expected = db.expected_discovery
          expect(discovered(state))
            .to eq(services: expected[:services].first(3), characteristics: expected[:characteristics])
          expect(logged(:debug)).to include(a_string_including("primary discovery 0x0001..0xffff ended partial at 0x000c"))
          expect_bearer_closed(walker, report)
        end
      end

      [
        ["a handle above the Ending Handle",              -> { peer.corrupt_page(6, :handle_above_end) }],
        ["a declaration of a length no declaration has",  -> { peer.corrupt_page(6, :bad_declaration) }],
        ["Security_Error 0x08",                           -> { peer.answer_with_error(6, 0x08) }],
        ["Security_Error 0x0C",                           -> { peer.answer_with_error(6, 0x0C) }]
      ].each do |why, script|
        it "ends a service's characteristic discovery partial on #{why} and walks the other services" do
          instance_exec(&script)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:partial)
          # The first service's characteristic procedure ends at its first
          # page, so it has no characteristic and no descriptor range.
          expect(request_summaries).to eq([
            [:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x000C, 0xFFFF], [:primary, 0x000D, 0xFFFF],
            [:secondary, 0x0001, 0xFFFF],
            [:includes, 0x0001, 0x0009], [:characteristics, 0x0001, 0x0009],
            [:includes, 0x000A, 0x000A], [:characteristics, 0x000A, 0x000A],
            [:includes, 0x000B, 0x000B], [:characteristics, 0x000B, 0x000B],
            [:includes, 0x000C, 0x000C], [:characteristics, 0x000C, 0x000C]
          ])
          state = walked_state(walker)
          expect(state.partial).to be(true)
          expect(discovered(state)).to eq(services: db.expected_discovery[:services], characteristics: [])
          expect(logged(:debug))
            .to include(a_string_including("characteristics discovery 0x0001..0x0009 ended partial at 0x0001"))
          expect_bearer_closed(walker, report)
        end
      end

      it "records disconnected, not partial, when the Link drops after a page that made the Walk partial" do
        peer.corrupt_page(2, :non_advancing)
        peer.drop_link_after(6) # responses 0 to 5 read: up to the first characteristic page
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:disconnected)
        expect(request_summaries.last).to eq([:characteristics, 0x0007, 0x0009])
        expect(peer.requests.map(&:lost)).to eq([false] * 6 + [true])
        # The live WalkState, with what was discovered before the drop and the
        # interrupted page still at the head of the worklist.
        state = report.state
        expect(state).to equal(walked_state(walker))
        expect(state.partial).to be(true)
        expect(state.services.map { |service| service[:start] }).to eq([0x0001, 0x000A, 0x000B])
        expect(state.characteristics.map(&:value_handle)).to eq([0x0003, 0x0005, 0x0007])
        expect(state.procedures.first.to_h.slice(:kind, :next, :end)).to eq(kind: :characteristics, next: 0x0007, end: 0x0009)
        expect_bearer_closed(walker, report)
      end
    end

    # Feature: gatt-service-scanning, Property 1: A Walk discovers exactly the served database
    #
    # For any database GattDatabase.generate draws (0 to 32 primary and
    # secondary services, 4- and 6-octet includes, 0 to 16 characteristics
    # per service, 0 to 4 descriptors per characteristic, 16- and 128-bit
    # UUIDs, handle gaps, a third of them ending at 0xFFFF), any Server Rx
    # MTU, read_all true or false, and a peer that either pages the 0x2801
    # sweep or, as Android's GATT server does, answers its every request with
    # 0x10 Unsupported Group Type (reject_secondary), a full Walk
    # - records complete at ATT_MTU max(23, min(517, Server Rx MTU)), and its
    #   WalkState holds exactly the database's discovered services (type,
    #   UUID, start, end: every service, or the primaries alone when the
    #   sweep was refused), includes (UUID, nil for a 4-octet one no
    #   discovered service starts at), characteristics (declaration and value
    #   handle, properties, UUID) and descriptors (handle, UUID)
    #   (Requirements 6.1 to 6.4, 6.8, 6.11);
    # - sends its one Exchange MTU Request first and after it only Read By
    #   Group Type for 0x2800/0x2801, Read By Type for 0x2802/0x2803 or an
    #   Identity_Set UUID, Find Information with start <= end, and Read or
    #   Read Blob of a handle Requirement 7.2 allows: a readable Identity_Set
    #   value and, with read_all, any other readable value or its 0x2904, in
    #   a discovered service;
    # - runs exactly the discovery procedures the discovered services call
    #   for, each from its range start and none for an empty descriptor
    #   range, primary before secondary, both before any include or
    #   characteristic procedure, and a service's includes before its
    #   characteristics before their descriptors (6.1 to 6.3);
    # - asks for each continuation page from the previous page's last handle
    #   (last End Group Handle for services) + 1, and ends each procedure on
    #   0x0A, on 0x10 for the secondary procedure, or on a page whose last
    #   handle is the range end, with no request for it after that (6.4,
    #   6.12): after the 0x10 the one 0x2801 request is the last.
    # Which values are read, in what order and with what bytes, is Property 2.
    # The generator's read errors are Security_Errors only, which leave a Walk
    # complete (6.8).
    #
    # The report renders that discovery (Requirement 10.9): report.services
    # and the structural keys of each report.characteristics entry
    # (service_uuid, service_type, service_start, service_end and
    # service_includes in place of service_index, properties as the names of
    # its set bits) equal
    # db.expected_discovery { |role, uuid| BlueHydra::UuidNames.render(role, uuid) };
    # every uuid, service_uuid, service_includes[].uuid and descriptors[].uuid
    # is "Name (uuid)" or "Unknown (uuid)" with uuid 0x and 4 lowercase hex
    # digits or 8-4-4-4-12 of them; and GattCharacteristics takes the entries
    # as they are, parse(serialize(entries)) giving them back. The WalkState
    # is checked as well, at the AttCodec::Uuid values the report renders.
    #
    # The input is [seed, Server Rx MTU, read_all, reject_secondary]:
    # GattDatabase.generate(seed, reject_secondary:) rebuilds the database,
    # and its summary lists the handle layout. The Server Rx MTU is drawn
    # below 23, in 23..517, above 517 or at a boundary.
    it "Property 1: a full Walk is complete and discovers exactly the served database" do
      types = { primary: 0x2800, secondary: 0x2801, includes: 0x2802, characteristics: 0x2803 }
              .transform_values { |uuid| codec.uuid16(uuid) }
      identity_types      = GattDatabase::Generator::IDENTITY_UUIDS.map { |uuid| codec.uuid16(uuid) }
      presentation_format = codec.uuid16(0x2904)
      page_class = { primary: codec::ReadByGroupTypeResponse, secondary: codec::ReadByGroupTypeResponse,
                     includes: codec::ReadByTypeResponse, characteristics: codec::ReadByTypeResponse,
                     descriptors: codec::FindInformationResponse }

      one_of   = ->(uuid, candidates) { candidates.any? { |candidate| GattDatabase.same_uuid?(uuid, candidate) } }
      readable = ->(char) { char.properties.anybits?(GattDatabase::PROPERTIES[:read]) }

      # The discovery procedure a request belongs to, as [kind, range end]
      # (no two procedures of one kind share a range end), or nil.
      procedure_of = lambda do |pdu|
        kind =
          case pdu
          when codec::ReadByGroupTypeRequest then %i[primary secondary].find { |k| one_of.(pdu.uuid, [types[k]]) }
          when codec::ReadByTypeRequest then %i[includes characteristics].find { |k| one_of.(pdu.uuid, [types[k]]) }
          when codec::FindInformationRequest then :descriptors
          end
        kind && [kind, pdu.end_handle]
      end

      # [kind, range end] => range start of every procedure a full Walk of
      # +db+ runs: both service sweeps (the 0x2801 one is sent even when the
      # peer refuses it), then those of the services the Walk discovered.
      expected_procedures = lambda do |db|
        expected = { [:primary, 0xFFFF] => 0x0001, [:secondary, 0xFFFF] => 0x0001 }
        db.discovered_services.each do |service|
          expected[[:includes, service.end]]        = service.start
          expected[[:characteristics, service.end]] = service.start
          service.characteristics.each_with_index do |char, index|
            following = service.characteristics[index + 1]
            range_end = following ? following.decl_handle - 1 : service.end
            expected[[:descriptors, range_end]] = char.value_handle + 1 if char.value_handle < range_end
          end
        end
        expected
      end

      # The handles Requirement 7.2 lets a Read or Read Blob name: in a
      # discovered service, since a Walk reads nothing it did not discover.
      readable_handles = lambda do |db, read_all|
        db.discovered_services.flat_map(&:characteristics).select(&readable).each_with_object(Set.new) do |char, handles|
          if one_of.(char.uuid, identity_types)
            handles << char.value_handle
          elsif read_all
            handles << char.value_handle
            char.descriptors.each do |descriptor|
              handles << descriptor.handle if GattDatabase.same_uuid?(descriptor.uuid, presentation_format)
            end
          end
        end
      end

      allowed = lambda do |pdu, reads|
        case pdu
        when codec::ReadByGroupTypeRequest then one_of.(pdu.uuid, types.values_at(:primary, :secondary))
        when codec::ReadByTypeRequest then one_of.(pdu.uuid, types.values_at(:includes, :characteristics) + identity_types)
        when codec::FindInformationRequest then pdu.start_handle <= pdu.end_handle
        when codec::ReadRequest, codec::ReadBlobRequest then reads.include?(pdu.handle)
        else false
        end
      end

      last_handle = ->(page) { page.is_a?(codec::ReadByGroupTypeResponse) ? page.entries.last[1] : page.entries.last[0] }

      # The rendered form, built from the harness's own tables: an entry's
      # structural keys from an expected_discovery characteristic and its
      # service, and the Uuid_Formatter's output shape.
      property_names = GattDatabase::PROPERTIES.transform_keys { |name| name.to_s.tr("_", "-") }
      structure_keys = %i[uuid service_uuid service_type service_start service_end service_includes
                          decl_handle value_handle properties descriptors]
      expected_entry = lambda do |services, char|
        service = services.fetch(char[:service_index])
        { uuid: char[:uuid], service_uuid: service[:uuid], service_type: service[:type].to_s,
          service_start: service[:start], service_end: service[:end], service_includes: service[:includes],
          decl_handle: char[:decl_handle], value_handle: char[:value_handle],
          properties: property_names.select { |_name, bit| char[:properties].anybits?(bit) }.keys,
          descriptors: char[:descriptors] }
      end
      formatted = /\A.+ \((?:0x[0-9a-f]{4}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\)\z/
      rendered_uuids = lambda do |report|
        report.services.flat_map { |service| [service[:uuid], *service[:includes].map { |inc| inc[:uuid] }] } +
          report.characteristics.flat_map do |entry|
            [entry[:uuid], entry[:service_uuid], *entry[:service_includes].map { |inc| inc[:uuid] },
             *entry[:descriptors].map { |descriptor| descriptor[:uuid] }]
          end
      end

      seen = Hash.new(0)
      # A proc, because rantly instance_evals generators on itself.
      mtu = proc {
        freq([2, proc { range(0, 22) }], [4, proc { range(23, 517) }], [2, proc { range(518, 0xFFFF) }],
             [2, proc { choose(22, 23, 24, 246, 247, 516, 517, 518) }])
      }

      property_of {
        [range(0, GattDatabase::Generator::SEED_MAX), call(mtu), boolean, boolean]
      }.check(200) { |seed, server_rx, read_all, reject_secondary|
        db      = GattDatabase.generate(seed, reject_secondary: reject_secondary)
        served  = FakeAttPeer.new(db, clock: FakeClock.new, server_rx_mtu: server_rx)
        walker  = served.build_walker(read_all: read_all)
        report  = walker.run
        att_mtu = [23, [517, server_rx].min].max

        expect(report.outcome).to eq(:complete)
        expect(report.mtu).to eq(att_mtu)
        expect(served.att_mtu).to eq(att_mtu)
        expect(report.requests_sent).to eq(served.requests.size)
        expect(served.closed?).to be(true)
        expect(served.violations).to be_empty

        state = walked_state(walker)
        expect(state.partial).to be(false)
        expect(state.procedures).to be_empty
        expect(discovered(state)).to eq(db.expected_discovery)
        expect(state.services.map { |service| service[:type] }).not_to include(:secondary) if reject_secondary
        expect(report.state).to be_nil

        rendered = db.expected_discovery { |role, uuid| BlueHydra::UuidNames.render(role, uuid) }
        expect(report.services).to eq(rendered[:services].map { |service| service.merge(type: service[:type].to_s) })
        expect(report.characteristics.map { |entry| entry.slice(*structure_keys) })
          .to eq(rendered[:characteristics].map { |char| expected_entry.(rendered[:services], char) })
        expect(rendered_uuids.(report).compact.grep_v(formatted)).to be_empty
        gatt = BlueHydra::GattCharacteristics
        expect(gatt.parse(gatt.serialize(report.characteristics))).to eq(report.characteristics)

        requests  = served.requests
        responses = served.delivered.select { |pdu| pdu.kind == :response }
                          .to_h { |pdu| [pdu.request_index, codec.decode(pdu.raw)] }
        reads     = readable_handles.(db, read_all)
        pages     = Hash.new { |hash, key| hash[key] = [] } # [kind, range end] => its request indices, ascending
        problems  = []

        expect(requests.first.pdu).to eq(codec::ExchangeMtuRequest.new(mtu: 517))
        requests.drop(1).each do |request|
          unless allowed.(request.pdu, reads)
            problems << "request #{request.index} is not one Requirement 7.2 allows: #{request.pdu.inspect}"
          end
          key = procedure_of.(request.pdu)
          pages[key] << request.index if key
        end
        expect(problems).to be_empty
        expect(pages.transform_values { |indices| requests[indices.first].pdu.start_handle }).to eq(expected_procedures.(db))

        # Requirements 6.4 and 6.12, page by page. 0x10 ends the secondary
        # procedure, and only it, as 0x0A ends any.
        pages.each do |(kind, range_end), indices|
          name = format("%s procedure ..0x%04x", kind, range_end)
          indices.each_with_index do |index, position|
            response = responses[index]
            page     = response if response.is_a?(page_class.fetch(kind))
            ended    =
              if page
                last_handle.(page) == range_end
              else
                response.is_a?(codec::ErrorResponse) && response.request_opcode == requests[index].opcode &&
                  (response.error_code == 0x0A || (kind == :secondary && response.error_code == 0x10))
              end
            if position == indices.size - 1
              problems << "#{name}: its last request, #{index}, was answered #{response.inspect}" unless ended
            elsif ended || !page
              problems << "#{name}: request #{indices[position + 1]} follows #{response.inspect}, " \
                          "the answer to request #{index}"
            elsif (start = requests[indices[position + 1]].pdu.start_handle) != last_handle.(page) + 1
              problems << format("%s: request %d starts at 0x%04x, not request %d's last handle 0x%04x + 1",
                                 name, indices[position + 1], start, index, last_handle.(page))
            end
          end
        end

        # Requirement 6.4: a refused sweep is one 0x2801 request, answered
        # 0x10 with its Starting Handle, and the Walk is complete all the same.
        if reject_secondary
          secondary = pages[[:secondary, 0xFFFF]]
          expect(secondary.size).to eq(1)
          expect(responses[secondary.first])
            .to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x10))
        end

        # Requirements 6.1 to 6.3: the order the procedures run in.
        first = pages.transform_values(&:first)
        last  = pages.transform_values(&:last)
        services_found = [last[[:primary, 0xFFFF]], last[[:secondary, 0xFFFF]]].max
        if first[[:secondary, 0xFFFF]] < last[[:primary, 0xFFFF]]
          problems << "secondary discovery began before primary discovery ended"
        end
        db.discovered_services.each do |service|
          includes, chars = [:includes, service.end], [:characteristics, service.end]
          name = format("service 0x%04x", service.start)
          problems << "#{name}: include discovery began before service discovery ended" if first[includes] < services_found
          if first[chars] < last[includes]
            problems << "#{name}: characteristic discovery began before include discovery ended"
          end
          pages.each_key do |kind, range_end|
            next unless kind == :descriptors && range_end.between?(service.start, service.end)
            next unless first[[kind, range_end]] < last[chars]
            problems << format("%s: descriptor discovery ..0x%04x began before characteristic discovery ended",
                               name, range_end)
          end
        end
        expect(problems).to be_empty

        seen[server_rx < 23 ? :below_floor : (server_rx > 517 ? :above_517 : :negotiable)] += 1
        seen[read_all ? :read_all : :identity_only] += 1
        seen[:empty] += 1 if db.services.empty?
        has_secondary = db.services.any? { |service| service.type == :secondary }
        seen[reject_secondary ? :secondary_refused : :secondary_paged] += 1 if has_secondary
        seen[:ends_at_ffff] += 1 if db.services.last&.end == 0xFFFF
        seen[:last_attribute_at_ffff] += 1 if db.attributes.last&.handle == 0xFFFF
        db.discovered_services.flat_map(&:includes).each do |include|
          form =
            if db.attribute(include.handle).value.bytesize == 6 then :include_6
            elsif db.resolved_include_uuid(include) then :include_4
            elsif db.services.any? { |service| service.type == :secondary && service.start == include.start }
              :include_4_of_refused_secondary
            else :include_4_unresolved
            end
          seen[form] += 1
        end
        uuids = db.services.map(&:uuid) + db.characteristics.map(&:uuid) + db.descriptors.map(&:uuid)
        seen[:uuid16] += 1 if uuids.any? { |uuid| uuid.bits == 16 }
        seen[:uuid128] += 1 if uuids.any? { |uuid| uuid.bits == 128 }
        seen[:continued] += 1 if pages.each_value.any? { |indices| indices.size > 1 }
        seen[:read_blob] += 1 if requests.any? { |request| request.pdu.is_a?(codec::ReadBlobRequest) }
        if !read_all && db.characteristics.any? { |char| readable.(char) && !one_of.(char.uuid, identity_types) }
          seen[:unread] += 1
        end
      }

      expect(seen.keys).to include(:below_floor, :negotiable, :above_517, :read_all, :identity_only, :empty,
                                   :secondary_paged, :secondary_refused, :ends_at_ffff, :last_attribute_at_ffff,
                                   :include_6, :include_4, :include_4_unresolved, :include_4_of_refused_secondary,
                                   :uuid16, :uuid128, :continued, :read_blob, :unread)
    end
  end

  # Plan.hash_check (Requirements 4.4 to 4.6). The database is one service
  # holding a readable Database Hash, so the full Walk a hash check falls
  # through to also reads that hash as an Identity_Set value.
  describe "the Database Hash check (Requirements 4.4 to 4.6)" do
    recorded = "00112233445566778899aabbccddeeff"

    let(:recorded_hash) { recorded }
    # The 0x2B2A value the database serves (nil: it has no Database Hash) and
    # the error code a read of it is answered with.
    let(:served_hash) { [recorded].pack("H*") }
    let(:hash_read_error) { nil }
    let(:db) do
      value      = served_hash
      read_error = hash_read_error
      GattDatabase.build do
        primary 0x1801 do # 0x0001..0x0003, the hash at 0x0002 / 0x0003
          characteristic 0x2B2A, props: [:read], value: value, read_error: read_error if value
        end
      end
    end
    let(:hash_request) do
      codec::ReadByTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: codec.uuid16(0x2B2A))
    end
    let(:plan) { BlueHydra::GattWalker::Plan.hash_check(recorded_hash) }

    it "records unchanged after exactly two client requests when the hash equals the recorded one (Requirement 4.5)" do
      walker = peer.build_walker(plan: plan)
      report = walker.run

      expect(report.outcome).to eq(:unchanged)
      expect(peer.requests.map(&:pdu)).to eq([codec::ExchangeMtuRequest.new(mtu: 517), hash_request])
      expect(report.requests_sent).to eq(2)
      expect(report.database_hash).to eq(recorded_hash)
      expect(report.hash_changed).to be(false)
      expect(report.state).to be_nil
      expect(walked_state(walker)).to be_nil
      expect_bearer_closed(walker, report)
    end

    it "compares the value with the lowest handle when the response carries more than one (Requirement 4.4)" do
      peer.answer_with(1, codec::ReadByTypeResponse.new(length: 18, entries: [[0x0010, "\xFF".b * 16],
                                                                              [0x0003, served_hash]]))
      walker = peer.build_walker(plan: plan)
      report = walker.run

      expect(report.outcome).to eq(:unchanged)
      expect(peer.requests.map(&:pdu)).to eq([codec::ExchangeMtuRequest.new(mtu: 517), hash_request])
      expect(report.database_hash).to eq(recorded_hash)
    end

    # [why, served value as hex (nil: no Database Hash), its read error, script,
    # hash_changed, database_hash reported]. Only a well-formed hash that
    # differs proves a change. When the check is unavailable the full Walk
    # still reads the hash as an Identity_Set value where it can, and reports
    # the one it read (Requirement 4.8).
    changed = "ffeeddccbbaa99887766554433221100"
    [
      ["the hash differs from the recorded one",   changed,          nil,  -> {}, true,  changed],
      ["the database has no Database Hash (0x0A)", nil,              nil,  -> {}, false, nil],
      ["the hash is protected (Security_Error)",   recorded,         0x05, -> {}, false, nil],
      ["the response is malformed",                recorded,         nil,  -> { peer.corrupt_page(1, :truncated) }, false, recorded],
      ["the hash is 15 octets",                    recorded[0, 30],  nil,  -> {}, false, nil],
      ["the hash is 17 octets",                    "#{recorded}00",  nil,  -> {}, false, nil]
    ].each do |why, served, read_error, script, hash_changed, reported|
      context "when #{why}" do
        let(:served_hash) { served && [served].pack("H*") }
        let(:hash_read_error) { read_error }

        it "walks in full on the same bearer without a second Exchange MTU Request (Requirement 4.6)" do
          instance_exec(&script)
          walker = peer.build_walker(plan: plan)
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(request_summaries.first(3)).to eq([[:mtu, 517], [:hash, 0x0001, 0xFFFF], [:primary, 0x0001, 0xFFFF]])
          expect(peer.requests.map(&:pdu).grep(codec::ExchangeMtuRequest).size).to eq(1)
          expect(peer.open_count).to eq(1)
          expect(report.requests_sent).to eq(peer.requests.size)
          expect(report.hash_changed).to be(hash_changed)
          expect(report.database_hash).to eq(reported)
          state = walked_state(walker)
          expect(state.database_hash).to eq(reported)
          expect(discovered(state)).to eq(db.expected_discovery)
          expect(logged(:debug)).to include(a_string_including("#{address} Database Hash").and(a_string_ending_with("full Walk")))
          expect_bearer_closed(walker, report)
        end
      end
    end

    [
      [:disconnected, "the Link drops",                -> { peer.drop_link_after(1) }],
      [:timeout,      "it goes unanswered to Walk_Bound", -> { peer.delay_response(1, Float::INFINITY) }]
    ].each do |outcome, why, script|
      it "records #{outcome} with nothing more sent when #{why} during the hash read" do
        instance_exec(&script)
        walker = peer.build_walker(plan: plan)
        report = walker.run

        expect(report.outcome).to eq(outcome)
        expect(peer.requests.map(&:pdu)).to eq([codec::ExchangeMtuRequest.new(mtu: 517), hash_request])
        expect(report.hash_changed).to be(false)
        expect(report.database_hash).to be_nil
        expect(report.state).to be_nil
        expect_bearer_closed(walker, report)
      end
    end
  end

  # PDUs the peer sends on its own account (Requirement 8), each injected
  # while one of the walker's requests is outstanding, so whatever the
  # Att_Server answers goes out in the middle of the walker's own
  # transaction. The default database's full Walk sends the same requests
  # whatever the peer injects: plain_requests.
  describe "answering the peer while a client request is outstanding (Requirement 8)" do
    att = BlueHydra::AttCodec
    not_found      = ->(opcode, handle) { att::ErrorResponse.new(request_opcode: opcode, handle: handle, error_code: 0x0A) }
    invalid_handle = ->(opcode, handle) { att::ErrorResponse.new(request_opcode: opcode, handle: handle, error_code: 0x01) }
    not_supported  = ->(opcode) { att::ErrorResponse.new(request_opcode: opcode, handle: 0x0000, error_code: 0x06) }
    invalid_pdu    = ->(opcode) { att::ErrorResponse.new(request_opcode: opcode, handle: 0x0000, error_code: 0x04) }
    confirmation   = att::HandleValueConfirmation.new

    # [what the peer sends, the PDU (raw bytes for what the codec does not
    # encode), the reply due (nil: none), Requirement]
    peer_pdus = [
      ["an Exchange MTU Request", att::ExchangeMtuRequest.new(mtu: 64), att::ExchangeMtuResponse.new(mtu: 517), "8.1"],
      ["a Find Information Request", att::FindInformationRequest.new(start_handle: 0x0001, end_handle: 0xFFFF),
       not_found.(0x04, 0x0001), "8.2"],
      ["a Find By Type Value Request",
       att::FindByTypeValueRequest.new(start_handle: 0x0002, end_handle: 0xFFFF, uuid: att.uuid16(0x2800),
                                       value: "\x00\x18".b),
       not_found.(0x06, 0x0002), "8.2"],
      ["a Read By Type Request",
       att::ReadByTypeRequest.new(start_handle: 0x0003, end_handle: 0xFFFF, uuid: att.uuid16(0x2A00)),
       not_found.(0x08, 0x0003), "8.2"],
      ["a Read By Group Type Request",
       att::ReadByGroupTypeRequest.new(start_handle: 0x0005, end_handle: 0xFFFF, uuid: att.uuid16(0x2800)),
       not_found.(0x10, 0x0005), "8.2"],
      # Starting Handle 0x0000 is Invalid Handle rather than Attribute Not
      # Found (Core 6.3 Vol 3 Part F 3.4.4.9), still naming the Starting
      # Handle as sent.
      ["a Read By Group Type Request with Starting Handle 0x0000",
       att::ReadByGroupTypeRequest.new(start_handle: 0x0000, end_handle: 0xFFFF, uuid: att.uuid16(0x2800)),
       invalid_handle.(0x10, 0x0000), "8.2"],
      ["a Read Request",          att::ReadRequest.new(handle: 0x0003), not_supported.(0x0A), "8.3"],
      ["a Write Request",         "\x12\x03\x00\x01\x02".b,              not_supported.(0x12), "8.3"],
      ["undefined opcode 0x3F",   "\x3F\x01\x02".b,                      not_supported.(0x3F), "8.3"],
      ["a malformed Exchange MTU Request",            "\x02\x17".b,                 invalid_pdu.(0x02),   "8.8"],
      ["a malformed Read By Group Type Request",      "\x10\x01\x00\xFF\xFF\x00".b, invalid_pdu.(0x10),   "8.8"],
      ["a Handle Value Indication", att::HandleValueIndication.new(handle: 0x0003, value: "\x01".b), confirmation, "8.4"],
      ["a malformed Handle Value Indication",         "\x1D\x03".b,                 confirmation,         "8.4"],
      ["a Handle Value Notification", att::HandleValueNotification.new(handle: 0x0003, value: "\x01".b), nil, "8.5"],
      # Multiple Handle Value Notification (Core 5.2) is server-initiated and
      # owed nothing, like 0x1B; the codec does not decode it, so the
      # Att_Server discards it on the raw opcode.
      ["a Multiple Handle Value Notification (0x23)", "\x23\x03\x00\x01\x00\x41".b,                      nil, "8.5"],
      ["a Write Command",             "\x52\x03\x00\x01".b,                                              nil, "8.5"],
      ["a Signed Write Command",      "\xD2\x03\x00\x01".b + "\x00".b * 12,                              nil, "8.5"],
      ["a Handle Value Confirmation", "\x1E".b,                                                          nil, "8.5"]
    ]

    let(:plain_requests) do
      [[:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x0004, 0xFFFF], [:secondary, 0x0001, 0xFFFF],
       [:includes, 0x0001, 0x0003], [:characteristics, 0x0001, 0x0003], [:characteristics, 0x0003, 0x0003],
       [:read, 0x0003]]
    end
    # The fake-clock time of each on_peer_request call.
    let(:peer_request_calls) { [] }

    def counting_walker(**overrides)
      calls = peer_request_calls
      peer.build_walker(on_peer_request: -> { calls << clock.now }, **overrides)
    end

    # Request 1's response comes 0.5 s after it, so a reply that goes out
    # before then went out while request 1 was outstanding.
    peer_pdus.each do |what, pdu, reply, requirement|
      verb = reply ? "answers" : "discards"
      it "#{verb} #{what} during the wait for request 1 and still takes request 1's response (Requirement #{requirement})" do
        peer.delay_response(1, 0.5)
        peer.inject_peer_pdu(pdu, before_request: 1)
        walker = counting_walker
        report = walker.run
        injection = peer.injections.first

        expect(report.outcome).to eq(:complete)
        # Request 1 was neither resent nor answered by the peer's PDU: its
        # own response came next, carried the service, and the Walk went on
        # as it would have without the PDU.
        expect(peer.delivered.first(3).map { |pdu_read| [pdu_read.kind, pdu_read.request_index] })
          .to eq([[:response, 0], [:peer, nil], [:response, 1]])
        expect(response_to(1)).to be_a(codec::ReadByGroupTypeResponse)
        expect(request_summaries).to eq(plain_requests)
        expect(report.requests_sent).to eq(plain_requests.size)
        expect(report.services.map { |service| service[:start] }).to eq([0x0001])
        expect(report.identity).to eq(device_name: "Name")

        if reply
          expect(peer.peer_received.map(&:pdu)).to eq([reply])
          expect(injection.reply).to eq(peer.peer_received.first)
          # Inside request 1's wait: after request 1 and before request 2
          # went out, at the moment the PDU was read, ahead of request 1's
          # response (Requirement 8.6).
          expect(peer.received.index(injection.reply)).to eq(2)
          expect(injection.reply.at).to eq(injection.delivered_at)
          expect(injection.reply.at).to be <= injection.queued_at + 1.0
          expect(injection.reply.at).to be < peer.delivered[2].at
          expect(peer_request_calls).to eq([injection.reply.at])
        else
          expect(injection.delivered_at).not_to be_nil
          expect(injection.reply).to be_nil
          expect(peer.peer_received).to be_empty
          expect(peer_request_calls).to be_empty
        end
        expect_bearer_closed(walker, report)
      end
    end

    it "calls on_peer_request once per reply sent, Handle Value Confirmations included, and for nothing else (Requirement 8.7)" do
      # Spread over three of the walker's waits: the first primary page, the
      # secondary procedure and the Device Name read.
      peer_pdus.each_with_index do |(_what, pdu, _reply), index|
        peer.inject_peer_pdu(pdu, before_request: [1, 3, 7][index % 3])
      end
      walker = counting_walker
      report = walker.run
      replies = peer_pdus.map { |_what, _pdu, reply| reply }

      expect(report.outcome).to eq(:complete)
      expect(request_summaries).to eq(plain_requests)
      expect(peer.injections.map { |injection| injection.reply&.pdu }).to eq(replies)
      expect(peer.peer_received.size).to eq(replies.compact.size)
      expect(peer.peer_received.map(&:opcode).count(0x1E)).to eq(2)
      expect(peer_request_calls).to eq(peer.peer_received.map(&:at))
      # Replies are not client requests (Requirement 13.6).
      expect(report.requests_sent).to eq(plain_requests.size)
      expect(peer.received.size).to eq(plain_requests.size + replies.compact.size)
    end

    it "ends the Walk disconnected, counting no peer request, when sending a reply finds the Link gone (Requirement 6.10)" do
      peer.inject_peer_pdu(codec::ReadByGroupTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF,
                                                             uuid: codec.uuid16(0x2800)), before_request: 1)
      fail_send(Errno::EPIPE) { |raw| raw.getbyte(0) == 0x01 }
      walker = counting_walker
      report = walker.run

      expect(report.outcome).to eq(:disconnected)
      expect(peer_request_calls).to be_empty
      expect(peer.peer_received).to be_empty
      # Nothing after the failed reply: request 1's response was never read
      # and no other request went out.
      expect(request_summaries).to eq([[:mtu, 517], [:primary, 0x0001, 0xFFFF]])
      expect(peer.delivered.map(&:kind)).to eq(%i[response peer])
      expect(call_names.count(:send)).to eq(2)
      expect(report.requests_sent).to eq(2)
      expect(report.state).to equal(walked_state(walker))
      expect(report.outstanding[:procedures].first).to eq(kind: :primary, start: 0x0001, end: 0xFFFF, next: 0x0001)
      expect(logged(:warn) + logged(:error)).to be_empty
      expect_bearer_closed(walker, report)
    end

    # Requirement 8.9: the cap holds for every page after it, Read Blob parts
    # included. At ATT_MTU 517 the ten services' Read By Group Type entries
    # fit one page and the 100-octet value one Read Response; below it they
    # take (ATT_MTU - 2) / 6 entries a page and ATT_MTU - 1 octets a part.
    describe "a peer's Client Rx MTU (Requirements 5.7, 8.9)" do
      let(:long_value) { Array.new(100) { |i| i }.pack("C*") }
      let(:db) do
        value = long_value
        GattDatabase.build do
          primary 0x180F do                                      # 0x0001..0x0003
            characteristic 0xFFF1, props: [:read], value: value  # 0x0002 / 0x0003
          end
          9.times { |i| primary(0x1810 + i) }                    # 0x0004..0x000C
        end
      end
      let(:service_ends) { [0x0003, *0x0004..0x000C] }

      # [when the peer sends it, its Client Rx MTU, the ATT_MTU from then on]
      [
        [1,   40,  40, "after our exchange"],
        [0,   40,  40, "before our exchange is answered"],
        [1,   10,  23, "below 23, floored at 23"],
        [1,  600, 517, "above our own 517"]
      ].each do |before_request, client_rx, att_mtu, why|
        it "pages at ATT_MTU #{att_mtu} for a Client Rx MTU of #{client_rx} sent #{why}" do
          peer.inject_peer_pdu(codec::ExchangeMtuRequest.new(mtu: client_rx), before_request: before_request)
          walker = counting_walker
          report = walker.run
          per_page = (att_mtu - 2) / 6

          expect(report.outcome).to eq(:complete)
          expect(report.mtu).to eq(att_mtu)
          expect(peer.att_mtu).to eq(att_mtu)
          expect(peer.injections.first.reply.pdu).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
          expect(peer_request_calls.size).to eq(1)
          expect(peer.requests.map(&:pdu).grep(codec::ExchangeMtuRequest)).to eq([codec::ExchangeMtuRequest.new(mtu: 517)])
          # Each page as full as the ATT_MTU allows, each next one from the
          # previous page's last End Group Handle + 1.
          expect(request_summaries.select { |kind, *| kind == :primary })
            .to eq(([0x0001] + service_ends.each_slice(per_page).map { |page| page.last + 1 })
                   .map { |start| [:primary, start, 0xFFFF] })
          expect(request_summaries.select { |kind, *| %i[read read_blob].include?(kind) })
            .to eq([[:read, 0x0003]] + (att_mtu - 1).step(99, att_mtu - 1).map { |offset| [:read_blob, 0x0003, offset] })
          expect(peer.delivered.select { |pdu| pdu.kind == :response }.map { |pdu| pdu.raw.bytesize })
            .to all(be <= att_mtu)
          expect(report.characteristics.first).to include(read_status: "read", value: long_value.unpack1("H*"))
          expect_bearer_closed(walker, report)
        end
      end
    end

    # stopping turns true the moment the first injected PDU is read, so the
    # walker's request it is injected before has gone out and is still
    # outstanding.
    describe "once shutdown has begun (Requirement 14.6)" do
      let(:stopping) { -> { !peer.injections.first.delivered_at.nil? } }

      it "sends no Att_Server reply, no Handle Value Confirmation and no further request" do
        peer.inject_peer_pdu(codec::ReadByGroupTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF,
                                                               uuid: codec.uuid16(0x2800)), before_request: 1)
        peer.inject_peer_pdu(codec::HandleValueIndication.new(handle: 0x0003, value: "\x01".b), before_request: 1)
        walker = counting_walker(stopping: stopping)
        report = walker.run

        expect(report.outcome).to eq(:disconnected)
        expect(peer.injections.map(&:delivered_at)).to all(be_a(Float))
        expect(peer.peer_received).to be_empty
        expect(peer_request_calls).to be_empty
        # Request 1's response was still read; nothing was sent after it.
        expect(response_to(1)).to be_a(codec::ReadByGroupTypeResponse)
        expect(request_summaries).to eq([[:mtu, 517], [:primary, 0x0001, 0xFFFF]])
        expect(call_names.count(:send)).to eq(2)
        expect(report.requests_sent).to eq(2)
        expect_bearer_closed(walker, report)
      end

      it "still caps ATT_MTU at a peer's Client Rx MTU whose Exchange MTU Response it does not send (Requirement 8.9)" do
        peer.inject_peer_pdu(codec::ExchangeMtuRequest.new(mtu: 40), before_request: 0)
        walker = counting_walker(stopping: stopping)
        report = walker.run

        expect(report.outcome).to eq(:disconnected)
        expect(peer.peer_received).to be_empty
        expect(peer_request_calls).to be_empty
        expect(request_summaries).to eq([[:mtu, 517]])
        # Our exchange was answered 517, after the peer's request had capped it.
        expect(response_to(0)).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
        expect(report.mtu).to eq(40)
        # The harness counts an exchange only once it is answered.
        expect(peer.att_mtu).to eq(517)
        expect_bearer_closed(walker, report)
      end
    end

    # Feature: gatt-service-scanning, Property 16: Only allowlisted opcodes are ever sent
    #
    # For any database GattDatabase.generate draws at a size that keeps a
    # case quick (0 to 8 services, 0 to 6 characteristics each, 0 to 2
    # descriptors, values of 0 to 100 octets, so Read Blobs occur at ATT_MTU
    # 23), any Server Rx MTU, read_all true or false, Walk_Bound 10 s or
    # 60 s, a fresh Walk under Plan.full or Plan.hash_check (against the
    # database's own Database Hash when it has one, so the check sometimes
    # ends the Walk unchanged, otherwise against a hash it cannot have), cut
    # or not at a random request by a Link drop or a response that never
    # comes, and then, when it reported a Resume_State, a Plan.resume Walk of
    # it, cut or not the same way, against a peer that misbehaves at random
    # requests of each Walk:
    # - it sends PDUs of its own ahead of the response: well-formed ones
    #   (every request the codec encodes with random handles and UUIDs, Write
    #   Request, Write Command, Signed Write Command, Prepare Write, Execute
    #   Write, Read Multiple, Read Multiple Variable, Multiple Handle Value
    #   Notification, indications, notifications and confirmations), garbage
    #   (any opcode but a response's followed by 0 to 24 random octets), or a
    #   sweep of one such garbage PDU for every opcode 0x00..0xFF that is not
    #   a response's, so each is read by some Walk of the run;
    # - it answers with an Error Response of any code 0x00..0xFF naming the
    #   request's handle or a random one, with garbage behind any response
    #   opcode (the ones the Walk never asks for, 0x07, 0x13, 0x17, 0x19 and
    #   0x21, included), with a page corrupted in every corrupt_page mode its
    #   answer allows, or late (0.01 to 0.5 s, 30 s, never).
    # Unsolicited responses are not injected: ATT has one request outstanding
    # per direction, so a stray response is indistinguishable from the real
    # one and would desynchronise any client; the garbage answers cover that
    # path. Then, on every bearer of the case:
    # - every PDU the Gatt_Walker and its Att_Server sent has an opcode in
    #   Requirement 7.7's allowlist {0x01, 0x02, 0x03, 0x04, 0x08, 0x0A, 0x0C,
    #   0x10, 0x1E} and decodes as that opcode's PDU; so no Write Request,
    #   Write Command, Signed Write Command, Prepare or Execute Write, Read
    #   Multiple, Read Multiple Variable, Find By Type Value, notification or
    #   indication ever went out (7.7);
    # - the client requests among them are Exchange MTU, Find Information,
    #   Read By Type, Read, Read Blob and Read By Group Type Requests only,
    #   every Read By Type for 0x2802, 0x2803 or 0x2B2A (7.2);
    # - the Att_Server's replies are Error Response, Exchange MTU Response and
    #   Handle Value Confirmation only (8.4, 8.5);
    # - the resumed Walk holds to all of it (16.14, 17.9);
    # - the harness finds no ATT rule broken: one request outstanding at a
    #   time, one Exchange MTU Request per bearer, no reply to a PDU not owed
    #   one, no socket option set.
    # Across the run the sweeps' PDUs cover every non-response opcode.
    #
    # The input is [seed, Server Rx MTU, read_all, Walk_Bound, plan, cut,
    # events, resume cut, resume events]. GattDatabase.generate(seed,
    # services: 0..8, chars: 0..6, descriptors: 0..2, values: 0..100)
    # rebuilds the database. A cut is nil or [:drop | :timeout, k]: the Link
    # dropping as request k is sent, or request k's response never arriving.
    # An event is [kind, request index, payload]: [:inject, i, bytes] and
    # [:sweep, i, seed] queue peer PDUs ahead of request i's response;
    # [:delay, i, seconds] delays that response; [:error, i, code, handle],
    # [:raw, i, bytes] and [:corrupt, i, pick] replace it, applied as request
    # i is sent so that a corruption is resolved against the answer the
    # database gives that request (pick chooses among the modes it allows);
    # one replacement per index, the last listed. Indices mostly fall in 0..6
    # (corruptions in 1..16) so that they land on requests the Walk sends; an
    # index past the Walk's last request does nothing. A plain Array is not
    # shrinkable in rantly, so a failing case is printed as generated.
    it "Property 16: every PDU sent on a fresh or resumed Walk carries an allowlisted opcode, whatever the peer sends or answers" do
      att           = BlueHydra::AttCodec
      allowlist     = [0x01, 0x02, 0x03, 0x04, 0x08, 0x0A, 0x0C, 0x10, 0x1E]
      request_codes = [0x02, 0x04, 0x08, 0x0A, 0x0C, 0x10]
      reply_codes   = [0x01, 0x03, 0x1E]
      # Requirement 7.7's never-sent PDUs, named for a failure message.
      forbidden = { 0x06 => "Find By Type Value Request", 0x0E => "Read Multiple Request", 0x12 => "Write Request",
                    0x16 => "Prepare Write Request", 0x18 => "Execute Write Request",
                    0x1B => "Handle Value Notification", 0x1D => "Handle Value Indication",
                    0x20 => "Read Multiple Variable Request", 0x52 => "Write Command", 0xD2 => "Signed Write Command" }
      response_opcodes = (0x00..0xFF).select { |opcode| att.response_opcode?(opcode) }
      peer_opcodes     = (0x00..0xFF).to_a - response_opcodes
      by_type_uuids    = [0x2802, 0x2803, 0x2B2A].map { |uuid| att.uuid16(uuid) }
      database_hash    = att.uuid16(0x2B2A)
      db_options       = { services: 0..8, chars: 0..6, descriptors: 0..2, values: 0..100 }

      # One garbage PDU per non-response opcode, bodies drawn from +seed+.
      sweep_pdus = lambda do |seed|
        rng = Random.new(seed)
        peer_opcodes.map { |opcode| [opcode].pack("C") + rng.bytes(rng.rand(0..24)) }
      end

      # The key FakeAttPeer files an uncorrupted page under, for :non_advancing.
      page_key = lambda do |pdu|
        case pdu
        when att::ReadByGroupTypeRequest, att::ReadByTypeRequest then [att.opcode_of(pdu), GattDatabase.uuid128(pdu.uuid)]
        when att::FindInformationRequest then [att.opcode_of(pdu)]
        end
      end

      # The corrupt_page mode +pick+ selects among those the answer +served+
      # will give the request +raw+ allows: any response can be truncated or
      # carry the wrong opcode; the page modes need a page, :handle_above_end
      # an Ending Handle below 0xFFFF, :end_before_start a Read By Group Type
      # page, :bad_declaration a Read By Type page, and :non_advancing an
      # earlier uncorrupted, unscripted page of the same type (+tampered+
      # holds the indices whose answers were corrupted or replaced, which the
      # harness does not file).
      corruptions_applied = Hash.new(0)
      corrupt_mode = lambda do |served, db, raw, pick, tampered|
        pdu    = att.decode(raw)
        answer =
          case pdu
          when att::ReadByGroupTypeRequest then db.read_by_group_type(pdu, served.att_mtu)
          when att::ReadByTypeRequest      then db.read_by_type(pdu, served.att_mtu)
          when att::FindInformationRequest then db.find_information(pdu, served.att_mtu)
          end
        any_response = %i[truncated wrong_opcode]
        page_only    = []
        if answer.respond_to?(:entries)
          page_only += %i[handle_below_start non_increasing no_entries bad_length]
          page_only << :handle_above_end if pdu.end_handle < 0xFFFF
          page_only << :end_before_start if answer.is_a?(att::ReadByGroupTypeResponse)
          page_only << :bad_declaration if answer.is_a?(att::ReadByTypeResponse)
          filed = served.delivered.select do |delivered|
            delivered.kind == :response && FakeAttPeer::PAGE_OPCODES.include?(delivered.raw.getbyte(0)) &&
              !tampered.include?(delivered.request_index)
          end
          page_only << :non_advancing if filed.any? { |delivered| page_key.(served.requests[delivered.request_index].pdu) == page_key.(pdu) }
        end
        # Most answers are not pages, so the page modes get most of the picks
        # when they apply, the one applied least so far across the run first,
        # so that each (:non_advancing above all, which needs a continuation
        # page or a second descriptor procedure) comes up while it can.
        mode =
          if pick < 20 || page_only.empty?
            any_response[pick % 2]
          else
            fewest = page_only.map { |candidate| corruptions_applied[candidate] }.min
            rarest = page_only.select { |candidate| corruptions_applied[candidate] == fewest }
            rarest[pick % rarest.size]
          end
        corruptions_applied[mode] += 1
        mode
      end

      # Scripts +served+ with +events+: peer PDUs and delays up front, by
      # index; the answer replacements as the request goes out, through a
      # send that applies the one keyed to the request's index. Returns the
      # corrupt_page modes applied, filled in as the Walk runs.
      script = lambda do |served, db, events|
        replacements = {}
        events.each do |kind, index, *payload|
          case kind
          when :inject then served.inject_peer_pdu(payload.first, before_request: index)
          when :sweep  then sweep_pdus.(payload.first).each { |pdu| served.inject_peer_pdu(pdu, before_request: index) }
          when :delay  then served.delay_response(index, payload.first)
          else replacements[index] = [kind, *payload]
          end
        end
        applied  = []
        tampered = Set.new
        served.singleton_class.prepend(Module.new do
          define_method(:send) do |bytes, flags = 0, *rest|
            opcode = bytes.b.getbyte(0)
            client = opcode && !BlueHydra::AttCodec.response_opcode?(opcode) && opcode != 0x1E
            if client && (replacement = replacements.delete(requests.size))
              at = requests.size
              kind, *payload = replacement
              case kind
              when :error
                error_code, error_handle = payload
                answer_with_error(at, error_code, handle: error_handle)
              when :raw
                answer_with(at, payload.first)
                tampered << at
              when :corrupt
                mode = corrupt_mode.(self, db, bytes.b, payload.first, tampered)
                corrupt_page(at, mode)
                tampered << at
                applied << mode
              end
            end
            super(bytes, flags, *rest)
          end
        end)
        applied
      end

      # Requirements 7.2, 7.7, 8.4 and 8.5 over the raw bytes +served+ took
      # from the walker, independently of the harness's own allowlist check.
      expect_allowlisted = lambda do |served, report, label|
        problems = []
        served.received.each_with_index do |sent, position|
          opcode  = sent.raw.getbyte(0)
          decoded = att.decode(sent.raw)
          unless allowlist.include?(opcode)
            problems << format("%s: PDU %d, %s, is outside the Requirement 7.7 allowlist: %s", label, position,
                               opcode ? format("opcode 0x%02x (%s)", opcode, forbidden.fetch(opcode, "not an allowed PDU")) : "empty",
                               sent.raw.unpack1("H*"))
          end
          if decoded.is_a?(att::Malformed) || att.opcode_of(decoded) != opcode
            problems << format("%s: PDU %d does not decode as its opcode's PDU: %s (%s)", label, position,
                               sent.raw.unpack1("H*"), decoded.inspect)
          end
        end
        served.requests.each do |request|
          unless request_codes.include?(request.opcode)
            problems << format("%s: request %d, opcode %s, is not one of the six read-only requests", label, request.index,
                               request.opcode ? format("0x%02x", request.opcode) : "none")
          end
          next unless request.pdu.is_a?(att::ReadByTypeRequest)
          next if by_type_uuids.any? { |uuid| GattDatabase.same_uuid?(uuid, request.pdu.uuid) }
          problems << format("%s: request %d is a Read By Type for %s, not 0x2802, 0x2803 or 0x2B2A", label,
                             request.index, GattDatabase.uuid_text(request.pdu.uuid))
        end
        served.peer_received.each do |reply|
          unless reply_codes.include?(reply.opcode)
            problems << format("%s: Att_Server reply %d, opcode 0x%02x, is not an Error Response, Exchange MTU Response " \
                               "or Handle Value Confirmation", label, reply.index, reply.opcode)
          end
        end
        expect(problems).to be_empty
        expect(served.violations).to be_empty, "#{label}: #{served.violations.inspect}"
        expect(served.calls.map(&:name)).not_to include(:setsockopt), label
        expect(report.requests_sent).to eq(served.requests.size), label
        expect(served.received.size).to eq(served.requests.size + served.peer_received.size), label
        expect(served.closed?).to be(true), label
      end

      seen             = Hash.new(0)
      injected_opcodes = Set.new
      # Procs, because rantly instance_evals generators on itself.
      mtu = proc {
        freq([3, proc { 23 }], [2, proc { range(24, 100) }], [2, proc { range(101, 517) }],
             [1, proc { choose(0, 22, 518, 0xFFFF) }])
      }
      # Request indices: mostly early ones, so that they land on requests the
      # Walk sends, requests 1 and 2 (the first primary-service request of a
      # full Walk and of a hash check that fell through, Requirement 6.7)
      # more often than the rest.
      index  = proc { freq([2, :literal, 1], [1, :literal, 2], [3, proc { range(0, 6) }], [2, proc { range(0, 60) }]) }
      handle = proc { freq([3, proc { range(1, 0x40) }], [1, proc { range(0, 0xFFFF) }]) }
      octets = proc { array(range(0, 24)) { range(0, 255) }.pack("C*") }
      uuid   = proc {
        boolean ? BlueHydra::AttCodec.uuid16(range(0, 0xFFFF)) :
                  BlueHydra::AttCodec::Uuid.new(bits: 128, hex: format("%016x%016x", range(0, 2**64 - 1), range(0, 2**64 - 1)))
      }
      # A well-formed peer PDU: the codec's requests, indications,
      # notifications and confirmations, and the PDUs it does not encode,
      # packed by hand (Core 6.3 Vol 3 Part F 3.4.5, 3.4.6, 3.4.7).
      # Exchange MTU Requests and indications, the two with a reply of their
      # own (8.1, 8.4), are drawn more often than the rest.
      formed = proc {
        h   = call(handle)
        enc = BlueHydra::AttCodec
        freq(
          [5, proc { enc.encode(enc::ExchangeMtuRequest.new(mtu: range(0, 0xFFFF))) }],
          [4, proc { enc.encode(enc::HandleValueIndication.new(handle: h, value: call(octets))) }],
          proc { enc.encode(enc::FindInformationRequest.new(start_handle: h, end_handle: range(h, 0xFFFF))) },
          proc {
            enc.encode(enc::FindByTypeValueRequest.new(start_handle: h, end_handle: range(h, 0xFFFF),
                                                        uuid: enc.uuid16(range(0, 0xFFFF)), value: call(octets)))
          },
          proc { enc.encode(enc::ReadByTypeRequest.new(start_handle: h, end_handle: range(h, 0xFFFF), uuid: call(uuid))) },
          proc { enc.encode(enc::ReadByGroupTypeRequest.new(start_handle: h, end_handle: range(h, 0xFFFF), uuid: call(uuid))) },
          proc { enc.encode(enc::ReadRequest.new(handle: h)) },
          proc { enc.encode(enc::ReadBlobRequest.new(handle: h, offset: range(0, 0xFFFF))) },
          proc { enc.encode(enc::HandleValueNotification.new(handle: h, value: call(octets))) },
          proc { enc.encode(enc::HandleValueConfirmation.new) },
          proc { [0x12, h].pack("CS<") + call(octets) },                     # Write Request
          proc { [0x52, h].pack("CS<") + call(octets) },                     # Write Command
          proc { [0xD2, h].pack("CS<") + call(octets) + ("\x00".b * 12) },   # Signed Write Command
          proc { [0x16, h, range(0, 0xFFFF)].pack("CS<S<") + call(octets) }, # Prepare Write Request
          proc { [0x18, range(0, 1)].pack("CC") },                           # Execute Write Request
          proc { [0x0E, h, range(1, 0xFFFF)].pack("CS<S<") },                # Read Multiple Request
          proc { [0x20, h, range(1, 0xFFFF)].pack("CS<S<") },                # Read Multiple Variable Request
          proc { [0x23, h, 1, range(0, 255)].pack("CS<S<C") }                # Multiple Handle Value Notification
        )
      }
      garbage = proc { [choose(*peer_opcodes)].pack("C") + call(octets) }
      # Error codes: the Security_Errors (on the first primary-service
      # request, a protected Walk), the codes the walker treats specially or
      # a compliant server sends, and anything.
      code = proc {
        freq([3, proc { choose(0x05, 0x08, 0x0C, 0x0F) }],
             [2, proc { choose(0x01, 0x02, 0x04, 0x06, 0x07, 0x0A, 0x0B, 0x0E, 0x11) }],
             [1, proc { range(0x00, 0xFF) }])
      }
      event = proc {
        freq([4, proc { [:inject, call(index), freq([2, formed], [2, garbage])] }],
             [1, proc { [:sweep, call(index), range(0, 2**31 - 1)] }],
             [2, proc {
               [:delay, call(index), freq([3, proc { range(1, 50) / 100.0 }], [1, :literal, 30.0], [1, :literal, Float::INFINITY])]
             }],
             [2, proc { [:error, call(index), call(code), boolean ? nil : range(0, 0xFFFF)] }],
             # Corruptions reach past the service pages so that include,
             # characteristic and descriptor pages, whose Ending Handle is
             # below 0xFFFF, get their share.
             [4, proc { [:corrupt, freq([1, proc { range(1, 6) }], [2, proc { range(1, 16) }]), range(0, 99)] }],
             [2, proc { [:raw, call(index), [choose(*response_opcodes)].pack("C") + call(octets)] }])
      }
      # A hash check against a hash the database cannot have falls through to
      # a full Walk, so half the Walks starting as one costs little.
      plan = proc { choose(:full, :hash_check) }
      cut  = proc { freq([2, :literal, nil], [2, proc { [:drop, call(index)] }], [1, proc { [:timeout, call(index)] }]) }

      property_of {
        [range(0, GattDatabase::Generator::SEED_MAX), call(mtu), boolean, choose(10.0, 60.0), call(plan), call(cut),
         array(range(0, 8)) { call(event) }, call(cut), array(range(0, 5)) { call(event) }]
      }.check(200) { |seed, server_rx, read_all, walk_bound, plan_kind, first_cut, events, resume_cut, resume_events|
        db         = GattDatabase.generate(seed, **db_options)
        clock      = FakeClock.new
        first_plan =
          if plan_kind == :hash_check
            served_hash = db.characteristics.find { |char| GattDatabase.same_uuid?(char.uuid, database_hash) }
            recorded    = served_hash&.value&.bytesize == 16 ? served_hash.value.unpack1("H*") : format("%032x", seed)
            BlueHydra::GattWalker::Plan.hash_check(recorded)
          else
            BlueHydra::GattWalker::Plan.full
          end

        # Walks db on a fresh peer sharing the clock under +plan+, scripted
        # with +walk_events+ and cut as +walk_cut+ says: [peer, report, modes].
        run_walk = lambda do |walk_plan, walk_cut, walk_events|
          served = FakeAttPeer.new(db, clock: clock, server_rx_mtu: server_rx)
          modes  = script.(served, db, walk_events)
          if walk_cut
            mode, k = walk_cut
            mode == :drop ? served.drop_link_after(k) : served.delay_response(k, Float::INFINITY)
          end
          report = served.build_walker(plan: walk_plan, read_all: read_all, deadline: clock.now + walk_bound).run
          [served, report, modes]
        end

        # What a Walk's peer saw, for coverage. A command, notification
        # (0x1B or 0x23) or confirmation is owed no reply (Requirement 8.5).
        note = lambda do |served, modes, walk_events|
          delivered = served.injections.select(&:delivered_at)
          injected_opcodes.merge(delivered.map { |injection| injection.raw.getbyte(0) })
          seen[:peer_pdu_read] += 1 unless delivered.empty?
          seen[:peer_pdu_discarded] += 1 if delivered.any? { |injection|
            opcode = injection.raw.getbyte(0)
            injection.reply.nil? && (att.command?(opcode) || [0x1B, 0x1E, 0x23].include?(opcode))
          }
          seen[:peer_request_answered] += 1 if served.peer_received.any? { |reply| reply.opcode == 0x01 }
          seen[:peer_exchange_mtu_answered] += 1 if served.peer_received.any? { |reply| reply.opcode == 0x03 }
          seen[:indication_confirmed] += 1 if served.peer_received.any? { |reply| reply.opcode == 0x1E }
          seen[:sweep_read] += 1 if walk_events.any? { |kind, at, _| kind == :sweep && at < served.requests.size }
          seen[:delayed] += 1 if walk_events.any? { |kind, at, _| kind == :delay && at < served.requests.size }
          seen[:error_answered] += 1 if walk_events.any? { |kind, at, _| kind == :error && at < served.requests.size }
          seen[:raw_answered] += 1 if walk_events.any? { |kind, at, _| kind == :raw && at < served.requests.size }
          modes.each { |mode| seen[:"corrupt_#{mode}"] += 1 }
          seen[:read_blob] += 1 if served.requests.any? { |request| request.pdu.is_a?(att::ReadBlobRequest) }
          if served.requests.any? { |request| request.pdu.is_a?(att::ReadByTypeRequest) && GattDatabase.same_uuid?(request.pdu.uuid, database_hash) }
            seen[:hash_checked] += 1
          end
        end

        first_peer, first, first_modes = run_walk.(first_plan, first_cut, events)
        expect_allowlisted.(first_peer, first, "fresh Walk")
        expect(first.resumed).to be(false)
        note.(first_peer, first_modes, events)
        seen[plan_kind] += 1
        seen[:"fresh_#{first.outcome}"] += 1

        if first.state
          second_peer, second, second_modes = run_walk.(BlueHydra::GattWalker::Plan.resume(first.state), resume_cut, resume_events)
          expect_allowlisted.(second_peer, second, "resumed Walk")
          expect(second.resumed).to be(true)
          expect(second_peer.requests.first&.pdu).to eq(att::ExchangeMtuRequest.new(mtu: 517))
          note.(second_peer, second_modes, resume_events)
          seen[:resumed] += 1
          seen[:"resumed_#{second.outcome}"] += 1
        else
          seen[:nothing_to_resume] += 1
        end

        seen[server_rx == 23 ? :mtu_23 : (server_rx.between?(24, 517) ? :negotiable : :out_of_range)] += 1
        seen[read_all ? :read_all : :identity_only] += 1
        seen[walk_bound > 30 ? :bound_60s : :bound_10s] += 1
        seen[:empty_db] += 1 if db.services.empty?
      }

      # Every non-response opcode reached some Walk's Att_Server. A hash
      # check ending unchanged (fresh_unchanged) is tallied but not required:
      # it needs a database holding a readable 16-octet Database Hash, rare
      # at this size, and sends no opcode a hash check that falls through
      # does not.
      expect(peer_opcodes - injected_opcodes.to_a).to be_empty
      expect(seen.keys).to include(:full, :hash_check, :hash_checked, :resumed, :nothing_to_resume,
                                   :fresh_complete, :fresh_partial, :fresh_protected, :fresh_timeout,
                                   :fresh_disconnected, :resumed_complete, :resumed_timeout, :resumed_disconnected,
                                   :peer_pdu_read, :peer_pdu_discarded, :peer_request_answered,
                                   :peer_exchange_mtu_answered, :indication_confirmed, :sweep_read, :delayed,
                                   :error_answered, :raw_answered, :read_blob,
                                   :corrupt_truncated, :corrupt_wrong_opcode, :corrupt_handle_below_start,
                                   :corrupt_handle_above_end, :corrupt_non_increasing, :corrupt_end_before_start,
                                   :corrupt_non_advancing, :corrupt_bad_declaration, :corrupt_no_entries,
                                   :corrupt_bad_length, :mtu_23, :negotiable, :out_of_range, :read_all, :identity_only,
                                   :bound_10s, :bound_60s, :empty_db)
    end
  end

  # A Walk ending before its end (Requirements 3.4, 3.5, 6.10, 6.13). At
  # ATT_MTU 23 the four primary services take two Read By Group Type pages:
  # request 1 from 0x0001, request 2 from 0x000C, and request 3, from
  # 0x000D, is answered 0x0A. The examples that cut the Walk at request 3
  # leave the same worklist: primary discovery at 0x000D at its head, the
  # four services found, no characteristic yet.
  describe "a Walk cut short" do
    let(:server_rx_mtu) { 23 }
    let(:db) do
      GattDatabase.build do
        primary 0x180F do                           # 0x0001..0x0009
          characteristic 0x2A19, props: [:notify]   # 0x0002 / 0x0003
          characteristic 0x2A1A, props: [:notify]   # 0x0004 / 0x0005
          characteristic 0x2A1B, props: [:notify]   # 0x0006 / 0x0007
          characteristic 0x2A1C, props: [:notify]   # 0x0008 / 0x0009
        end
        primary 0x1800                              # 0x000A
        primary 0x1801                              # 0x000B
        primary 0x180A                              # 0x000C
      end
    end
    let(:deadline) { clock.now + 10.0 }
    let(:requests_to_3) do
      [[:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x000C, 0xFFFF], [:primary, 0x000D, 0xFFFF]]
    end

    # The Walk ended +outcome+ with +sent+ client requests on the bearer,
    # holding what it found before request 3 and that request's page still
    # to ask for, and sent nothing after.
    def expect_cut_at_request_3(walker, report, outcome, sent:)
      expect(report.outcome).to eq(outcome)
      expect(request_summaries).to eq(requests_to_3.first(sent))
      expect(report.requests_sent).to eq(sent)
      expect(call_names.count(:send)).to eq(sent)
      expect(report.state).to equal(walked_state(walker))
      expect(report.outstanding).to eq(
        procedures: [{ kind: :primary,   start: 0x0001, end: 0xFFFF, next: 0x000D },
                     { kind: :secondary, start: 0x0001, end: 0xFFFF, next: 0x0001 }],
        reads: []
      )
      expect(report.services.map { |service| service[:start] }).to eq([0x0001, 0x000A, 0x000B, 0x000C])
      expect(report.characteristics).to eq([])
      expect(report.identity).to eq({})
      expect_bearer_closed(walker, report)
    end

    describe "by Walk_Bound (Requirement 3.4)" do
      it "records timeout when request 3 is still unanswered as Walk_Bound expires, sending nothing after" do
        peer.delay_response(2, 9.5)
        peer.delay_response(3, Float::INFINITY)
        walker = peer.build_walker(deadline: deadline)
        report = walker.run

        expect_cut_at_request_3(walker, report, :timeout, sent: 4)
        # Request 3's wait is what was left of Walk_Bound, and the bearer
        # closed at its expiry.
        expect(peer.waits.last.to_h.slice(:kind, :timeout)).to eq(kind: :readable, timeout: 0.5)
        expect(socket_call(:close).at).to eq(deadline)
        expect(report.ended_at).to eq(deadline)
        expect(logged(:debug)).to include(
          a_string_including("#{address} no response to opcode 0x10 after 0.50s: Walk_Bound expired")
        )
      end

      it "records timeout without sending request 3 when request 2's response arrives as Walk_Bound expires" do
        peer.delay_response(2, 10.0)
        walker = peer.build_walker(deadline: deadline)
        report = walker.run

        expect(peer.delivered.last.at).to eq(deadline)
        expect_cut_at_request_3(walker, report, :timeout, sent: 3)
        expect(socket_call(:close).at).to eq(deadline)
      end

      it "records timeout, not partial, when Walk_Bound expires after a page that made the Walk partial (Requirement 6.13)" do
        peer.corrupt_page(2, :non_advancing)
        peer.delay_response(6, Float::INFINITY) # the second characteristic page
        walker = peer.build_walker(deadline: deadline)
        report = walker.run

        expect(report.outcome).to eq(:timeout)
        expect(request_summaries.last).to eq([:characteristics, 0x0007, 0x0009])
        expect(report.requests_sent).to eq(7)
        state = report.state
        expect(state).to equal(walked_state(walker))
        expect(state.partial).to be(true)
        expect(report.outstanding[:procedures].first).to eq(kind: :characteristics, start: 0x0001, end: 0x0009, next: 0x0007)
        expect(report.characteristics.map { |entry| entry[:value_handle] }).to eq([0x0003, 0x0005, 0x0007])
        expect(socket_call(:close).at).to eq(deadline)
        expect_bearer_closed(walker, report)
      end

      it "records timeout when Walk_Bound ends before the 1 s connect window does" do
        peer.connect_outcome(:never)
        walker = peer.build_walker(deadline: clock.now + 0.5)
        report = walker.run

        expect(peer.waits.map { |wait| [wait.kind, wait.timeout] }).to eq([[:writable, 0.5]])
        expect(socket_call(:close).at).to eq(1000.5)
        expect_ended_before_any_pdu(walker, report, :timeout)
        expect(logged(:debug)).to include("gatt: #{address} bearer connect timeout: not complete within 0.50s")
      end

      it "records disconnected when Walk_Bound and the 1 s connect window end together (Requirement 5.4)" do
        peer.connect_outcome(:never)
        walker = peer.build_walker(deadline: clock.now + 1.0)
        report = walker.run

        expect(peer.waits.map { |wait| [wait.kind, wait.timeout] }).to eq([[:writable, 1.0]])
        expect(socket_call(:close).at).to eq(1001.0)
        expect_ended_before_any_pdu(walker, report, :disconnected)
        expect(logged(:debug)).to include("gatt: #{address} bearer connect disconnected: not complete within 1.00s")
      end
    end

    describe "by the 30 s ATT transaction timeout (Requirements 3.4, 3.5)" do
      it "records timeout when request 3 goes 30 s unanswered inside a 60 s Walk_Bound, sending nothing after" do
        peer.delay_response(3, Float::INFINITY)
        walk_bound_end = clock.now + 60.0
        walker = peer.build_walker(deadline: walk_bound_end)
        report = walker.run

        expect_cut_at_request_3(walker, report, :timeout, sent: 4)
        expect(peer.waits.last.to_h.slice(:kind, :timeout)).to eq(kind: :readable, timeout: 30.0)
        # 30 s after request 3, with 30 s of Walk_Bound still left.
        expect(socket_call(:close).at).to eq(peer.requests[3].at + 30.0)
        expect(walk_bound_end - socket_call(:close).at).to eq(30.0)
        expect(logged(:debug)).to include(
          a_string_including("#{address} no response to opcode 0x10 after 30.00s: ATT transaction timeout")
        )
      end
    end

    # The harness queues every injected PDU the moment the request it is
    # scripted before arrives, so here time passes between them through
    # on_peer_request, which moves the fake clock on as each reply goes out.
    # Request 1's wait still ends where it began by ending: each wait after a
    # peer PDU is what is left of the first.
    [
      ["the 30 s transaction timeout", 60.0, 10.0, [30.0, 20.0, 10.0], "ATT transaction timeout"],
      ["Walk_Bound",                   10.0, 3.0,  [10.0, 7.0, 4.0],   "Walk_Bound expired"]
    ].each do |bound, walk_bound, step, waits, reason|
      it "ends the wait for request 1 at #{bound} however many peer PDUs arrive during it (Requirement 3.5)" do
        peer.delay_response(1, Float::INFINITY)
        [0x2A00, 0x2A01].each do |uuid|
          peer.inject_peer_pdu(codec::ReadByTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF,
                                                            uuid: codec.uuid16(uuid)), before_request: 1)
        end
        replies = 0
        walker = peer.build_walker(deadline: clock.now + walk_bound,
                                   on_peer_request: -> { replies += 1; clock.advance(step) })
        report = walker.run

        expect(report.outcome).to eq(:timeout)
        expect(replies).to eq(2)
        expect(peer.peer_received.size).to eq(2)
        expect(peer.waits.last(3).map { |wait| [wait.kind, wait.timeout] }).to eq(waits.map { |left| [:readable, left] })
        expect(socket_call(:close).at).to eq(peer.requests[1].at + waits.first)
        expect(request_summaries).to eq(requests_to_3.first(2))
        expect(logged(:debug)).to include(
          a_string_including(format("no response to opcode 0x10 after %.2fs: %s", waits.first, reason))
        )
        expect_bearer_closed(walker, report)
      end
    end

    describe "by the Link dropping (Requirement 6.10)" do
      it "records disconnected when the bearer reports EOF" do
        peer.drop_link_after(3)
        walker = peer.build_walker
        report = walker.run

        expect(peer.requests.map(&:lost)).to eq([false, false, false, true])
        expect_cut_at_request_3(walker, report, :disconnected, sent: 4)
        expect(logged(:warn) + logged(:error)).to be_empty
      end

      BlueHydra::GattWalker::BEARER_DISCONNECT_ERRORS.each do |errno|
        it "records disconnected when a recv fails with #{errno.name}" do
          peer.raise_on_recv(errno, after: 3)
          walker = peer.build_walker
          report = walker.run

          expect(peer.requests.map(&:lost)).to eq([false, false, false, true])
          expect_cut_at_request_3(walker, report, :disconnected, sent: 4)
          expect(logged(:warn) + logged(:error)).to be_empty
        end

        it "records disconnected when sending request 3 fails with #{errno.name}" do
          fail_send(errno) { |_raw| peer.requests.size == 3 }
          walker = peer.build_walker
          report = walker.run

          # requests_sent counts only requests that went out.
          expect_cut_at_request_3(walker, report, :disconnected, sent: 3)
          expect(logged(:warn) + logged(:error)).to be_empty
        end
      end
    end

    # Feature: gatt-service-scanning, Property 4: No wait exceeds the lesser of Walk_Bound remaining and 30 s
    #
    # For any Walk_Bound from 0.1 s to 120 s (below the 1 s connect window,
    # 1 s to 30 s where Walk_Bound is the tighter bound, above 30 s where the
    # ATT transaction timeout is, and exactly 1 s and 30 s), any database
    # GattDatabase.generate draws (kept to 8 services of 6 characteristics,
    # which is plenty of requests), any of three Server Rx MTUs, a connect
    # that completes at once, pends for 0 to 1.2 s or for exactly its wait,
    # or never completes, any response delays (short ones; 30 s; one landing
    # exactly on the bound in force at its request's send; one 10 ms past it;
    # one that never comes) and peer requests, indications and notifications
    # arriving while a client request is outstanding, each reply the
    # Att_Server sends costing 0 to 0.99 s of fake time (on_peer_request
    # moves the clock):
    # - every wait for a response is bounded by the lesser of the Walk_Bound
    #   remaining when it began and 30 s (Requirement 3.5), and every wait of
    #   one transaction ends at the same instant, the lesser of the request's
    #   send time + 30 s and the deadline: the peer PDUs the Att_Server answers
    #   in between shorten the next wait and never extend it;
    # - the one connect wait is the lesser of 1 s and Walk_Bound (Requirements
    #   3.4, 5.4), and a pending connect completing inside that is taken;
    # - every client request goes out before the deadline, nothing goes out
    #   after a wait has run out, the bearer is closed once, at ended_at, and
    #   ended_at is at or before the deadline, except when a reply's service
    #   ran past the bound: the Walk then ends the moment it is done, inside
    #   Requirement 3.4's 1 s;
    # - the Walk ends timeout exactly when a bound was hit: the connect window
    #   cut short by Walk_Bound, a wait run out (the debug line naming which
    #   bound), a reply finishing at or past the bound, or a response landing
    #   on the deadline with work still to do (taken, then nothing more sent).
    #   A connect window of the full 1 s run out is disconnected, and
    #   otherwise the Walk reaches its end: complete.
    #
    # The input is [seed, Server Rx MTU, Walk_Bound, [connect, after], delays,
    # peer PDUs, step]. A delay is [request index, seconds | :on_bound |
    # :past_bound]; the symbols are set when that request is sent, relative
    # to the clock then. Peer PDUs are [request index, kinds] injected before
    # that request's response. Indices mostly fall in 0..6 so that they land
    # on requests the Walk sends; an index past the Walk's last request does
    # nothing. Waits are read from the peer's log, each tagged with the
    # request outstanding when it began. A plain Array is not shrinkable in
    # rantly, so a failing case is printed as generated.
    it "Property 4: no wait exceeds the lesser of Walk_Bound remaining and 30 s, and a bound hit ends the Walk timeout at once" do
      att_timeout     = BlueHydra::GattWalker::ATT_TRANSACTION_TIMEOUT
      connect_timeout = BlueHydra::GattWalker::CONNECT_TIMEOUT
      eps             = 1e-9
      db_options      = { services: 0..8, chars: 0..6, descriptors: 0..2, values: 0..40 }
      peer_pdus = {
        request:      codec::ReadByTypeRequest.new(start_handle: 0x0001, end_handle: 0xFFFF, uuid: codec.uuid16(0x2A00)),
        exchange_mtu: codec::ExchangeMtuRequest.new(mtu: 100),
        indication:   codec::HandleValueIndication.new(handle: 0x0003, value: "\x01".b),
        notification: codec::HandleValueNotification.new(handle: 0x0003, value: "\x01".b)
      }

      # Instruments +served+ before its Walk: every wait_readable is tagged
      # with the index of the client request outstanding when it began
      # (requests.size - 1), and a request whose index is in +lazy+ gets its
      # delay as it is sent: :on_bound lands the response on the bound then in
      # force, the lesser of the Walk_Bound remaining and 30 s, :past_bound
      # 10 ms past it. Returns the tags, filled in as the Walk runs.
      instrument = lambda do |served, deadline, lazy|
        tags = []
        served.singleton_class.prepend(Module.new do
          define_method(:wait_readable) do |timeout = nil|
            tags << requests.size - 1
            super(timeout)
          end

          define_method(:send) do |bytes, flags = 0, *rest|
            opcode = bytes.b.getbyte(0)
            client = opcode && !BlueHydra::AttCodec.response_opcode?(opcode) && opcode != 0x1E
            kind   = client && lazy[requests.size]
            if kind
              in_force = [deadline - clock.now, att_timeout].min
              delay_response(requests.size, kind == :on_bound ? in_force : in_force + 0.01)
            end
            super(bytes, flags, *rest)
          end
        end)
        tags
      end

      seen = Hash.new(0)
      # Procs, because rantly instance_evals generators on itself.
      bound = proc {
        freq([3, proc { range(10, 99) / 100.0 }], [1, proc { choose(1.0, 30.0) }],
             [3, proc { range(101, 2999) / 100.0 }], [4, proc { range(3001, 12_000) / 100.0 }])
      }
      index = proc { freq([3, proc { range(0, 6) }], [2, proc { range(0, 80) }]) }
      delay = proc {
        [call(index), freq([3, proc { range(1, 50) / 100.0 }], [2, :literal, 30.0], [2, :literal, Float::INFINITY],
                           [3, :literal, :on_bound], [1, :literal, :past_bound])]
      }
      connect = proc {
        freq([4, proc { [:immediate, 0.0] }],
             [3, proc { [:pending, freq([3, proc { range(0, 120) / 100.0 }], [1, :literal, :window_end])] }],
             [2, proc { [:never, 0.0] }])
      }
      pdus = proc { [call(index), array(range(1, 3)) { choose(:request, :exchange_mtu, :indication, :notification) }] }

      property_of {
        [range(0, GattDatabase::Generator::SEED_MAX), choose(23, 100, 517), call(bound), call(connect),
         array(range(0, 4)) { call(delay) }, array(range(0, 3)) { call(pdus) }, range(0, 99) / 100.0]
      }.check(300) { |seed, server_rx, walk_bound, (connect_kind, after), delays, injections, step|
        clock    = FakeClock.new
        started  = clock.now
        served   = FakeAttPeer.new(GattDatabase.generate(seed, **db_options), clock: clock, server_rx_mtu: server_rx)
        deadline = started + walk_bound
        after    = [connect_timeout, walk_bound].min if after == :window_end # completes as the connect wait ends
        case connect_kind
        when :pending then served.connect_outcome(:pending, after: after)
        when :never   then served.connect_outcome(:never)
        end
        lazy = {}
        delays.each do |request_index, seconds|
          if seconds.is_a?(Symbol)
            lazy[request_index] = seconds
          else
            served.delay_response(request_index, seconds)
            lazy.delete(request_index)
          end
        end
        injections.each do |request_index, kinds|
          kinds.each { |kind| served.inject_peer_pdu(peer_pdus.fetch(kind), before_request: request_index) }
        end
        tags  = instrument.(served, deadline, lazy)
        steps = [] # [clock before, clock after] of each reply's service
        mark  = log.size
        report = served.build_walker(deadline: deadline, on_peer_request: lambda {
          before = clock.now
          clock.advance(step)
          steps << [before, clock.now]
        }).run
        debug      = log[mark..].select { |level, _| level == :debug }.map(&:last)
        unanswered = debug.grep(/no response to opcode/)
        requests   = served.requests
        readable   = served.waits.select { |wait| wait.kind == :readable }
        writable   = served.waits.select { |wait| wait.kind == :writable }
        bound_of   = ->(tag) { [requests.fetch(tag).at + att_timeout, deadline].min }
        att_bound  = ->(tag) { requests.fetch(tag).at + att_timeout < deadline }
        reason     = ->(tag) { att_bound.(tag) ? "ATT transaction timeout" : "Walk_Bound expired" }

        expect(served.violations).to be_empty
        expect(tags.size).to eq(readable.size)
        expect(report.started_at).to eq(started)

        # The connect wait (Requirements 3.4, 5.4): at most one, begun at
        # once, the lesser of 1 s and Walk_Bound; a connect resolving inside
        # it is taken (SO_ERROR is then read), one that does not is not.
        expect(writable.size).to be <= 1
        connect_wait = writable.first
        if connect_wait
          expect(connect_wait.at).to eq(started)
          expect(connect_wait.timeout).to be_within(eps).of([connect_timeout, deadline - connect_wait.at].min)
        end
        connect_expired = !connect_wait.nil? && served.calls.none? { |call| call.name == :getsockopt }
        expect(connect_expired)
          .to eq(connect_kind == :never || (connect_kind == :pending && after > [connect_timeout, walk_bound].min))

        # Every wait for a response (Requirement 3.5): within the lesser of
        # the Walk_Bound remaining and 30 s, and ending at its transaction's
        # bound, measured from the send, whatever was answered in between.
        readable.zip(tags).each do |wait, tag|
          expect(tag).to be >= 0
          expect(wait.at).to be >= requests.fetch(tag).at
          expect(wait.timeout).to be > 0
          expect(wait.timeout).to be <= [deadline - wait.at, att_timeout].min + eps
          expect(wait.at + wait.timeout).to be_within(eps).of(bound_of.(tag))
        end

        # Requests and the bearer (Requirement 3.4).
        expect(requests.map(&:lost)).to all(be(false))
        expect(requests.map(&:at)).to all(be < deadline)
        expect(report.requests_sent).to eq(requests.size)
        ran_out = readable.size - served.delivered.size # waits that returned nothing: 0, or the one that ended the Walk
        expect(ran_out).to be_between(0, 1)
        if ran_out == 1
          expect(served.received.map(&:at)).to all(be <= readable.last.at)
          expect(readable.last.at + readable.last.timeout).to be_within(eps).of(report.ended_at)
        end
        expect(served.closed?).to be(true)
        expect(served.calls.count { |call| call.name == :close }).to eq(1)
        expect(served.calls.last.name).to eq(:close)
        expect(served.calls.last.at).to eq(report.ended_at)
        # A reply whose service ended at or past the transaction's bound ends
        # the Walk there: transact finds no time left and waits no more.
        overrun = steps.last && tags.any? && steps.last.last >= bound_of.(tags.last) ? steps.last.last : nil
        if overrun
          expect(report.ended_at).to eq(overrun)
          expect(report.ended_at - bound_of.(tags.last)).to be <= step + eps
        else
          expect(report.ended_at).to be <= deadline + eps
        end
        expect(report.ended_at).to be <= deadline + 1.0

        # The outcome, from which bound was hit.
        if connect_expired
          cut_by_walk_bound = connect_wait.timeout < connect_timeout - eps
          expect(report.outcome).to eq(cut_by_walk_bound ? :timeout : :disconnected)
          expect(requests).to be_empty
          expect(report.ended_at).to be_within(eps).of(connect_wait.at + connect_wait.timeout)
          seen[cut_by_walk_bound ? :connect_cut_by_walk_bound : :connect_window_ran_out] += 1
        elsif ran_out == 1
          expect(report.outcome).to eq(:timeout)
          expect(report.ended_at).to be_within(eps).of(bound_of.(tags.last))
          expect(unanswered.size).to eq(1)
          expect(unanswered.first).to include(reason.(tags.last))
          seen[att_bound.(tags.last) ? :att_timeout : :walk_bound_ran_out] += 1
        elsif overrun
          expect(report.outcome).to eq(:timeout)
          expect(unanswered.size).to eq(1)
          expect(unanswered.first).to include(reason.(tags.last))
          seen[:reply_overran_bound] += 1
        elsif report.outcome == :timeout
          # Nothing ran out: the last response, or the connect itself, landed
          # on the deadline and was taken, and the next request found no
          # Walk_Bound left to send in.
          expect(report.ended_at).to be_within(eps).of(deadline)
          expect(unanswered).to be_empty
          last = served.delivered.last
          if last
            expect(last.kind).to eq(:response)
            expect(last.at).to be_within(eps).of(deadline)
            expect(report.outstanding.values.flatten).not_to be_empty
            seen[:response_on_deadline_then_refused] += 1
          else
            expect(requests).to be_empty
            expect(connect_wait.at + connect_wait.timeout).to be_within(eps).of(deadline)
            seen[:connect_on_deadline_then_refused] += 1
          end
        else
          expect(report.outcome).to eq(:complete)
          expect(report.state).to be_nil
          expect(unanswered).to be_empty
          seen[:reached_end] += 1
        end

        # Coverage, from what happened rather than what was scripted.
        seen[walk_bound < 1 ? :bound_below_1s : (walk_bound <= 30 ? :bound_1s_to_30s : :bound_above_30s)] += 1
        seen[connect_kind] += 1
        so_error_read = served.calls.find { |call| call.name == :getsockopt }
        if so_error_read && (so_error_read.at - (connect_wait.at + connect_wait.timeout)).abs <= eps
          seen[:connect_taken_at_window_end] += 1
        end
        seen[:peer_replies] += 1 if steps.any?
        shrunk = readable.zip(tags).each_cons(2).any? { |(a, tag_a), (b, tag_b)| tag_a == tag_b && b.timeout < a.timeout }
        seen[:wait_shrunk_by_replies] += 1 if shrunk
        responses = served.delivered.select { |pdu| pdu.kind == :response }
        seen[:response_on_deadline] += 1 if responses.any? { |pdu| (pdu.at - deadline).abs <= eps }
        seen[:response_on_att_bound] += 1 if responses.any? { |pdu|
          att_bound.(pdu.request_index) && (pdu.at - (requests[pdu.request_index].at + att_timeout)).abs <= eps
        }
      }

      expect(seen.keys).to include(:bound_below_1s, :bound_1s_to_30s, :bound_above_30s, :immediate, :pending, :never,
                                   :connect_cut_by_walk_bound, :connect_window_ran_out, :connect_taken_at_window_end,
                                   :att_timeout, :walk_bound_ran_out, :reply_overran_bound,
                                   :response_on_deadline_then_refused, :reached_end, :peer_replies,
                                   :wait_shrunk_by_replies, :response_on_deadline, :response_on_att_bound)
    end
  end

  # What GattScanner's one end-of-Walk debug line reports (Requirement
  # 13.6) comes from the WalkReport: the address, the outcome, whether it
  # resumed, started_at to ended_at (the bearer's close), the client
  # requests sent, the MTU, and the services, characteristics and values
  # read it found.
  describe "the WalkReport fields of Requirement 13.6" do
    let(:db) do
      GattDatabase.build do
        primary 0x1800 do                                              # 0x0001..0x0005
          characteristic 0x2A00, props: [:read], value: "Sensor"      # 0x0002 / 0x0003
          characteristic 0x2A01, props: [:read], value: [0xC1, 0x03]  # 0x0004 / 0x0005
        end
        primary 0x180F do                                              # 0x0006..0x0008
          characteristic 0x2A19, props: [:notify]                     # 0x0007 / 0x0008
        end
      end
    end

    it "carries the address, outcome, timings, client request count, MTU and what the Walk found and read" do
      started = clock.now
      peer.connect_outcome(:pending, after: 0.5)
      peer.delay_response(2, 0.25)
      peer.inject_peer_pdu(codec::ExchangeMtuRequest.new(mtu: 100), before_request: 1)
      peer.inject_peer_pdu(codec::HandleValueIndication.new(handle: 0x0008, value: "\x01".b), before_request: 3)
      walker = peer.build_walker(link_up: ->(_address) { started - 0.25 })
      report = walker.run

      expect(report).to have_attributes(address: address, outcome: :complete, resumed: false, mtu: 100,
                                        started_at: started, ended_at: started + 0.75, handoff_lag: 0.25)
      # The duration runs to the close: the 0.5 s connect and the 0.25 s
      # response.
      expect(report.ended_at).to eq(socket_call(:close).at)
      # Client requests only, not the Exchange MTU Response and the Handle
      # Value Confirmation the walker also sent.
      expect(peer.peer_received.map(&:opcode)).to eq([0x03, 0x1E])
      expect(report.requests_sent).to eq(peer.requests.size)
      expect(peer.received.size).to eq(report.requests_sent + 2)
      expect(report.services.size).to eq(2)
      expect(report.characteristics.size).to eq(3)
      expect(report.characteristics.count { |entry| entry[:read_status] == "read" }).to eq(2)
      expect_bearer_closed(walker, report)
    end

    it "reports ATT_MTU 23 with no Exchange MTU Response, and no characteristics for a Walk cut before them" do
      peer.answer_with_error(0, 0x06)
      peer.drop_link_after(3) # the exchange, then primary discovery's two requests
      walker = peer.build_walker
      report = walker.run

      expect(report).to have_attributes(outcome: :disconnected, mtu: 23, requests_sent: 4)
      expect(request_summaries.last).to eq([:secondary, 0x0001, 0xFFFF])
      expect(report.services.size).to eq(2)
      expect(report.characteristics).to eq([])
      expect(report.identity).to eq({})
      expect_bearer_closed(walker, report)
    end
  end

  # Value reads (Requirement 7). Every read a Walk sends shows in
  # request_summaries as [:read, handle] or [:read_blob, handle, offset]. What
  # a read stored is asserted on the rendered report, report.characteristics
  # (the gatt_characteristics entries) and report.identity, since those are
  # what the Device stores.
  #
  # A database of one primary service whose characteristics are contiguous
  # and end at the service end takes requests 0 to 6 to discover (the
  # exchange, two primary, one secondary, one include and two characteristic
  # requests), so its first read is request 7.
  describe "value reads (Requirement 7)" do
    # Each characteristic's read outcome as its entry renders it, by value
    # handle. slice keeps only the keys the entry has, so a key it must not
    # carry (error_code on a read entry, value on a protected one, raw_hex on
    # a hex one) fails the comparison as surely as a wrong value does.
    def read_fields(report)
      report.characteristics.to_h do |entry|
        [entry[:value_handle], entry.slice(:read_status, :error_code, :value, :value_encoding, :raw_hex)]
      end
    end

    def reads_sent
      request_summaries.select { |kind, *| %i[read read_blob].include?(kind) }
    end

    def hex(bytes)
      bytes.b.unpack1("H*")
    end

    # The walker's CharRecord for +value_handle+, for the octets it collected
    # and the presentation format it parsed, which the entry does not carry.
    def char_at(walker, value_handle)
      walked_state(walker).characteristics.find { |char| char.value_handle == value_handle }
    end

    describe "a value longer than one part (Requirement 7.1)" do
      let(:long_value) { Array.new(600) { |i| i % 251 }.pack("C*") }
      let(:db) do
        value = long_value
        GattDatabase.build do
          primary 0x180F do                                      # 0x0001..0x0003
            characteristic 0xFFF1, props: [:read], value: value  # 0x0002 / 0x0003
          end
        end
      end

      # Each part of ATT_MTU - 1 octets is followed by a Read Blob at the
      # collected offset until 512 octets are in: at 23 the 24th part takes
      # the value to 528 octets, at 247 the third, a short one, to 600, and at
      # 517 the Read Response alone carries 516. Each is cut at 512.
      {
        23  => [[:read, 0x0003]] + (1..23).map { |part| [:read_blob, 0x0003, 22 * part] },
        247 => [[:read, 0x0003], [:read_blob, 0x0003, 246], [:read_blob, 0x0003, 492]],
        517 => [[:read, 0x0003]]
      }.each do |mtu, expected_reads|
        context "at ATT_MTU #{mtu}" do
          let(:server_rx_mtu) { mtu }

          it "reads the 600-octet value at the collected offset and keeps its first 512 octets" do
            walker = peer.build_walker
            report = walker.run

            expect(report.outcome).to eq(:complete)
            expect(reads_sent).to eq(expected_reads)
            expect((7...peer.requests.size).sum { |index| response_to(index).value.bytesize }).to be > 512
            expect(char_at(walker, 0x0003).value_bytes).to eq(long_value.byteslice(0, 512))
            expect(read_fields(report)).to eq(
              0x0003 => { read_status: "read", value: hex(long_value.byteslice(0, 512)), value_encoding: "hex" }
            )
            expect_bearer_closed(walker, report)
          end
        end
      end

      context "when the Link drops part-way through it at ATT_MTU 23" do
        let(:server_rx_mtu) { 23 }

        it "leaves the read outstanding at the collected offset, its characteristic rendered not-read" do
          peer.drop_link_after(10) # the Read and two Read Blobs answered: 66 octets in
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:disconnected)
          expect(reads_sent)
            .to eq([[:read, 0x0003], [:read_blob, 0x0003, 22], [:read_blob, 0x0003, 44], [:read_blob, 0x0003, 66]])
          expect(peer.requests.last.lost).to be(true)
          task = report.state.reads.first
          expect([task.kind, task.handle, task.offset, task.collected])
            .to eq([:value, 0x0003, 66, long_value.byteslice(0, 66)])
          expect(report.outstanding).to eq(procedures: [], reads: [{ kind: :value, value_handle: 0x0003 }])
          expect(char_at(walker, 0x0003).read_status).to be_nil
          expect(read_fields(report)).to eq(0x0003 => { read_status: "not-read" })
          expect_bearer_closed(walker, report)
        end
      end
    end

    # At ATT_MTU 23 the 50-octet value comes as request 7's Read and request
    # 8's and 9's Read Blobs at offsets 22 and 44, the last a short part of 6.
    # The characteristic is outside the Identity_Set, so no failure here makes
    # the Walk partial (Requirement 6.9 counts Identity_Set reads only). None
    # of these blobs is carried over from an earlier Walk, so 0x0B ends the
    # value here without the Requirement 7.19 re-read, which "a carried Read
    # Blob answered 0x0B at a larger ATT_MTU" under resuming covers.
    describe "a read ended by an Error Response (Requirements 7.1, 7.8, 7.9)" do
      let(:server_rx_mtu) { 23 }
      let(:value) { Array.new(50) { |i| 0x30 + i }.pack("C*") }
      let(:db) do
        bytes = value
        GattDatabase.build do
          primary 0x180F do                                      # 0x0001..0x0003
            characteristic 0xFFF1, props: [:read], value: bytes  # 0x0002 / 0x0003
          end
        end
      end
      let(:all_reads) { [[:read, 0x0003], [:read_blob, 0x0003, 22], [:read_blob, 0x0003, 44]] }

      it "ends the value at the first part shorter than ATT_MTU - 1" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(reads_sent).to eq(all_reads)
        expect(response_to(9).value.bytesize).to eq(6)
        expect(read_fields(report)).to eq(0x0003 => { read_status: "read", value: hex(value), value_encoding: "hex" })
      end

      context "when the value is exactly one part long" do
        let(:value) { "0123456789abcdefghijkl" } # 22 octets, ATT_MTU - 1

        it "ends it on the 0x0B Attribute Not Long that answers the Read Blob after the Read" do
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(reads_sent).to eq([[:read, 0x0003], [:read_blob, 0x0003, 22]])
          expect(response_to(8)).to eq(codec::ErrorResponse.new(request_opcode: 0x0C, handle: 0x0003, error_code: 0x0B))
          expect(read_fields(report)).to eq(0x0003 => { read_status: "read", value: hex(value), value_encoding: "hex" })
        end
      end

      [[0x0B, "Attribute Not Long"], [0x07, "Invalid Offset"]].each do |code, name|
        it format("ends the value with the 44 octets collected on 0x%02x %s to the second Read Blob", code, name) do
          peer.answer_with_error(9, code)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(reads_sent).to eq(all_reads)
          expect(char_at(walker, 0x0003).value_bytes).to eq(value.byteslice(0, 44))
          expect(read_fields(report))
            .to eq(0x0003 => { read_status: "read", value: hex(value.byteslice(0, 44)), value_encoding: "hex" })
        end
      end

      # [request answered, its index, code, Read_Status]. 0x0B and 0x07 end
      # only a Read Blob sequence normally; to the opening Read they are
      # errors like any other code.
      [
        ["the first Read Blob", 8, 0x05, "protected"],
        ["the first Read Blob", 8, 0x0E, "error"],
        ["the Read",            7, 0x0B, "error"],
        ["the Read",            7, 0x07, "error"]
      ].each do |answered, index, code, status|
        it format("records %s with code 0x%02x and drops the octets collected on 0x%02x to %s", status, code, code, answered) do
          peer.answer_with_error(index, code)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(reads_sent).to eq(all_reads.first(index - 6))
          expect(char_at(walker, 0x0003).value_bytes).to be_nil
          expect(read_fields(report)).to eq(0x0003 => { read_status: status, error_code: code })
          expect(logged(:debug)).to include(a_string_including(format("value read at 0x0003 %s: Error Response 0x%02x", status, code)))
        end
      end

      # A Read Blob Response (0x0D) answering the Read: no ATT error code to
      # record, and the entry keeps error_code with nil.
      it "records error with error_code nil when the Read is answered with a response that does not answer it" do
        peer.corrupt_page(7, :wrong_opcode)
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(reads_sent).to eq([[:read, 0x0003]])
        expect(response_to(7)).to be_a(codec::ReadBlobResponse)
        expect(char_at(walker, 0x0003).value_bytes).to be_nil
        expect(read_fields(report)).to eq(0x0003 => { read_status: "error", error_code: nil })
        expect(logged(:debug)).to include(a_string_including("value read at 0x0003 error: mismatched response opcode 0x0d"))
      end
    end

    describe "an Identity_Set read answered with an Error Response (Requirements 6.8, 6.9, 7.8, 7.9)" do
      let(:name_read_error) { nil }
      let(:db) do
        read_error = name_read_error
        GattDatabase.build do
          primary 0x1800 do                                                                 # 0x0001..0x0005
            characteristic 0x2A00, props: [:read], value: "Sensor", read_error: read_error  # 0x0002 / 0x0003
            characteristic 0x2A01, props: [:read], value: [0xC1, 0x03]                      # 0x0004 / 0x0005
          end
        end
      end
      let(:appearance_read) { { read_status: "read", value: "0x03c1", value_encoding: "identity" } }

      [0x05, 0x08, 0x0C, 0x0F].each do |code|
        context format("with Security_Error 0x%02x", code) do
          let(:name_read_error) { code }

          it "records Device Name protected with the code and no value, reads on, and leaves the Walk complete" do
            walker = peer.build_walker
            report = walker.run

            expect(report.outcome).to eq(:complete)
            expect(reads_sent).to eq([[:read, 0x0003], [:read, 0x0005]])
            expect(read_fields(report))
              .to eq(0x0003 => { read_status: "protected", error_code: code }, 0x0005 => appearance_read)
            expect(char_at(walker, 0x0003).value_bytes).to be_nil
            expect(report.identity).to eq(appearance: "0x03c1")
            expect_bearer_closed(walker, report)
          end
        end
      end

      [[0x02, "Read Not Permitted"], [0x0E, "Unlikely Error"]].each do |code, name|
        context format("with Error Response 0x%02x %s", code, name) do
          let(:name_read_error) { code }

          it "records Device Name error with the code and no value, reads on, and makes the Walk partial" do
            walker = peer.build_walker
            report = walker.run

            expect(report.outcome).to eq(:partial)
            expect(reads_sent).to eq([[:read, 0x0003], [:read, 0x0005]])
            expect(read_fields(report))
              .to eq(0x0003 => { read_status: "error", error_code: code }, 0x0005 => appearance_read)
            expect(report.identity).to eq(appearance: "0x03c1")
            expect(logged(:debug))
              .to include(a_string_including(format("identity read at 0x0003 error: Error Response 0x%02x", code)))
            expect_bearer_closed(walker, report)
          end
        end
      end

      # The entry keeps error_code, nil: a Malformed or mismatched PDU has no
      # ATT error code to record.
      [
        ["a response opcode that does not answer the Read", -> { peer.corrupt_page(7, :wrong_opcode) }],
        ["a malformed Error Response",                       -> { peer.answer_with(7, "\x01\x0A".b) }]
      ].each do |why, script|
        it "records Device Name error with no code on #{why}, and makes the Walk partial" do
          instance_exec(&script)
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:partial)
          expect(request_summaries[7]).to eq([:read, 0x0003])
          expect(reads_sent).to eq([[:read, 0x0003], [:read, 0x0005]])
          expect(read_fields(report))
            .to eq(0x0003 => { read_status: "error", error_code: nil }, 0x0005 => appearance_read)
          expect(report.identity).to eq(appearance: "0x03c1")
        end
      end
    end

    describe "duplicate Identity_Set instances (Requirements 7.5, 7.6)" do
      let(:db) do
        GattDatabase.build do
          primary 0x1800 do                                         # 0x0001..0x0007
            characteristic 0x2A00, props: [:notify]                 # 0x0002 / 0x0003: the lowest, not readable
            characteristic 0x2A00, props: [:read], value: "Second"  # 0x0004 / 0x0005: the lowest readable
            characteristic 0x2A00, props: [:read], value: "Third"   # 0x0006 / 0x0007
          end
          primary 0x1801 do                                         # 0x0008..0x000A
            characteristic 0x2A00, props: [:read], value: "Fourth"  # 0x0009 / 0x000A
          end
        end
      end

      it "reads only the readable Device Name with the lowest value handle and carries only its value" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(reads_sent).to eq([[:read, 0x0005]])
        expect(read_fields(report)).to eq(
          0x0003 => { read_status: "not-readable" },
          0x0005 => { read_status: "read", value: "Second", value_encoding: "identity" },
          0x0007 => { read_status: "not-read" },
          0x000A => { read_status: "not-read" }
        )
        expect(report.identity).to eq(device_name: "Second")
      end
    end

    # The Battery service comes first, so its readable values have the lowest
    # handles, and Manufacturer Name sits below Device Name and Appearance:
    # the read order is the Identity_Set's own (Device Name, Appearance,
    # Manufacturer Name), then every other readable value by ascending value
    # handle, each after its 0x2904.
    describe "gatt_read_all (Requirements 1.8, 7.3, 7.4, 7.5, 7.14)" do
      let(:db) do
        GattDatabase.build do
          primary 0x180F do                                                       # 0x0001..0x0008
            characteristic 0x2A19, props: %i[read notify], value: [0x64] do       # 0x0002 / 0x0003
              descriptor 0x2904, value: [0x04, 0x00, 0xAD, 0x27, 0x01, 0x00, 0x00] # 0x0004: uint8, percentage
            end
            characteristic 0xFFF1, props: [:read], value: [0x01, 0x02]            # 0x0005 / 0x0006
            characteristic 0xFFF2, props: [:notify]                               # 0x0007 / 0x0008
          end
          primary 0x180A do                                                       # 0x0009..0x000B
            characteristic 0x2A29, props: [:read], value: "Acme"                  # 0x000A / 0x000B
          end
          primary 0x1800 do                                                       # 0x000C..0x0010
            characteristic 0x2A00, props: [:read], value: "Sensor"                # 0x000D / 0x000E
            characteristic 0x2A01, props: [:read], value: [0xC1, 0x03]            # 0x000F / 0x0010
          end
        end
      end
      # Requests 0 to 13, the same whatever gatt_read_all says. The 0x2904 is
      # discovered either way; only reading it depends on gatt_read_all.
      let(:discovery) do
        [
          [:mtu, 517], [:primary, 0x0001, 0xFFFF], [:primary, 0x0011, 0xFFFF], [:secondary, 0x0001, 0xFFFF],
          [:includes, 0x0001, 0x0008], [:characteristics, 0x0001, 0x0008], [:characteristics, 0x0008, 0x0008],
          [:includes, 0x0009, 0x000B], [:characteristics, 0x0009, 0x000B], [:characteristics, 0x000B, 0x000B],
          [:includes, 0x000C, 0x0010], [:characteristics, 0x000C, 0x0010], [:characteristics, 0x0010, 0x0010],
          [:descriptors, 0x0004, 0x0004]
        ]
      end
      let(:identity_reads) { [[:read, 0x000E], [:read, 0x0010], [:read, 0x000B]] }
      let(:identity_fields) do
        {
          0x000B => { read_status: "read", value: "Acme",   value_encoding: "identity" },
          0x000E => { read_status: "read", value: "Sensor", value_encoding: "identity" },
          0x0010 => { read_status: "read", value: "0x03c1", value_encoding: "identity" }
        }
      end
      let(:identity) { { device_name: "Sensor", appearance: "0x03c1", manufacturer_name: "Acme" } }

      it "reads the Identity_Set, then each other readable value ascending, its 0x2904 first, when true" do
        walker = peer.build_walker(read_all: true)
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(request_summaries)
          .to eq(discovery + identity_reads + [[:read, 0x0004], [:read, 0x0003], [:read, 0x0006]])
        expect(read_fields(report)).to eq(identity_fields.merge(
          0x0003 => { read_status: "read", value: "100", value_encoding: "format:uint8;unit:0x27ad", raw_hex: "64" },
          0x0006 => { read_status: "read", value: "0102", value_encoding: "hex" },
          0x0008 => { read_status: "not-readable" }
        ))
        expect(report.identity).to eq(identity)
      end

      it "reads the Identity_Set only, and no other value or 0x2904, when false" do
        walker = peer.build_walker(read_all: false)
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(request_summaries).to eq(discovery + identity_reads)
        expect(read_fields(report)).to eq(identity_fields.merge(
          0x0003 => { read_status: "not-read" },
          0x0006 => { read_status: "not-read" },
          0x0008 => { read_status: "not-readable" }
        ))
        # No read was ever sent for them, so no Read_Status was decided:
        # nil, rendered not-read.
        expect([0x0003, 0x0006].map { |handle| char_at(walker, handle).read_status }).to eq([nil, nil])
        expect(report.identity).to eq(identity)
      end

      # Requirement 16.2's "Identity_Set captured when a Walk is cut off after
      # discovery": the identity reads, requests 14 to 16, come ahead of
      # every other read, so a Walk cut off once they are in still reports
      # them, and the reads it never finished stay in its WalkState for
      # Resume_State.
      [
        # The answer to the last identity read arrives just as Walk_Bound
        # expires, so the next read is never sent.
        [:timeout, "Walk_Bound expires as the last Identity_Set value arrives",
         -> { peer.delay_response(16, 10.0) }, []],
        # The 0x2904 read goes out on a dead Link and is lost.
        [:disconnected, "the Link drops after the Identity_Set reads",
         -> { peer.drop_link_after(17) }, [[:read, 0x0004]]]
      ].each do |outcome, why, script, sent_after|
        it "reports the Identity_Set and keeps the other reads outstanding when #{why}" do
          instance_exec(&script)
          walker = peer.build_walker(read_all: true)
          report = walker.run

          expect(report.outcome).to eq(outcome)
          expect(request_summaries).to eq(discovery + identity_reads + sent_after)
          expect(report.identity).to eq(identity)
          expect(read_fields(report)).to eq(identity_fields.merge(
            0x0003 => { read_status: "not-read" },
            0x0006 => { read_status: "not-read" },
            0x0008 => { read_status: "not-readable" }
          ))
          # Their reads still pending: no Read_Status yet, rendered not-read.
          expect([0x0003, 0x0006].map { |handle| char_at(walker, handle).read_status }).to eq([nil, nil])
          expect(report.state).to equal(walked_state(walker))
          expect(report.state.reads.map { |task| [task.kind, task.handle, task.offset] })
            .to eq([[:presentation_format, 0x0004, 0], [:value, 0x0003, 0], [:value, 0x0006, 0]])
          expect(report.outstanding[:reads]).to eq([
            { kind: :presentation_format, value_handle: 0x0003 },
            { kind: :value, value_handle: 0x0003 },
            { kind: :value, value_handle: 0x0006 }
          ])
          expect(report.outstanding[:procedures]).to be_empty
          expect_bearer_closed(walker, report)
        end
      end
    end

    describe "Identity_Set encodings (Requirements 7.10, 7.11, 7.13)" do
      let(:values) do
        { name: "Kitchen\x00\x00", appearance: [0xC1, 0x03], system_id: (1..8).to_a,
          pnp_id: [0x02, 0x5E, 0x04, 0x01, 0x02, 0x10, 0x00], hash: ["00112233445566778899aabbccddeeff"].pack("H*") }
      end
      let(:db) do
        v = values
        GattDatabase.build do
          primary 0x1800 do                                                      # 0x0001..0x0005
            characteristic 0x2A00, props: [:read], value: v[:name]               # 0x0002 / 0x0003
            characteristic 0x2A01, props: [:read], value: v[:appearance]         # 0x0004 / 0x0005
          end
          primary 0x180A do                                                      # 0x0006..0x000A
            characteristic 0x2A23, props: [:read], value: v[:system_id]          # 0x0007 / 0x0008
            characteristic 0x2A50, props: [:read], value: v[:pnp_id]             # 0x0009 / 0x000A
          end
          primary 0x1801 do                                                      # 0x000B..0x000D
            characteristic 0x2B2A, props: [:read], value: v[:hash]               # 0x000C / 0x000D
          end
        end
      end

      it "stores Appearance as 0x and 4 lowercase hex digits of its little-endian value, and the rest as specified" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(reads_sent).to eq([[:read, 0x0003], [:read, 0x0005], [:read, 0x0008], [:read, 0x000A], [:read, 0x000D]])
        expected = {
          device_name:   "Kitchen", # trailing 0x00 stripped
          appearance:    "0x03c1",
          system_id:     "0102030405060708",
          pnp_id:        "0x02 0x045e 0x0201 0x0010",
          database_hash: "00112233445566778899aabbccddeeff"
        }
        expect(report.identity).to eq(expected)
        # Identity values carry their dedicated encoding and no raw_hex.
        expect(read_fields(report)).to eq(
          [0x0003, 0x0005, 0x0008, 0x000A, 0x000D].zip(expected.values).to_h do |handle, value|
            [handle, { read_status: "read", value: value, value_encoding: "identity" }]
          end
        )
        expect(report.database_hash).to eq(expected[:database_hash])
      end

      context "when every fixed-size value has the wrong length and the name is all 0x00" do
        let(:values) do
          { name: "\x00\x00", appearance: [0xC1, 0x03, 0x00], system_id: (1..7).to_a,
            pnp_id: [0x02, 0x5E, 0x04, 0x01, 0x02, 0x10, 0x00, 0x00], hash: "\x11".b * 15 }
        end

        it "records each fixed-size value malformed, the name read with no value, none in identity, and the Walk complete" do
          walker = peer.build_walker
          report = walker.run

          expect(report.outcome).to eq(:complete)
          expect(reads_sent).to eq([[:read, 0x0003], [:read, 0x0005], [:read, 0x0008], [:read, 0x000A], [:read, 0x000D]])
          expect(read_fields(report)).to eq(
            0x0003 => { read_status: "read", value: nil, value_encoding: "identity" },
            0x0005 => { read_status: "malformed" },
            0x0008 => { read_status: "malformed" },
            0x000A => { read_status: "malformed" },
            0x000D => { read_status: "malformed" }
          )
          expect(report.identity).to eq({})
          expect(report.database_hash).to be_nil
        end
      end
    end

    # Values outside the Identity_Set, read in ascending value-handle order
    # after Device Name, each after its 0x2904 when it has one.
    describe "decoding other values (Requirements 7.12, 7.14 to 7.17)" do
      let(:custom_uuid) { "a1b2c3d4-0000-4000-8000-00000000f003" }
      let(:db) do
        custom = custom_uuid
        GattDatabase.build do
          primary 0x181A do                                                           # 0x0001..0x0011
            characteristic 0x2A6E, props: [:read], value: [0x29, 0x09] do             # 0x0002 / 0x0003: 2345
              descriptor 0x2904, value: [0x06, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00]    # 0x0004: uint16, exponent -2, 0x272f
            end
            characteristic 0xFFF1, props: [:read], value: [0x00, 0x00, 0xC0, 0x3F] do # 0x0005 / 0x0006: 1.5
              descriptor 0x2904, value: [0x14, 0x00, 0x00, 0x27, 0x01, 0x00, 0x00]    # 0x0007: float32
            end
            characteristic 0xFFF2, props: [:read], value: [0x01, 0x02, 0x03] do       # 0x0008 / 0x0009
              descriptor 0x2904, value: [0x1B, 0x00, 0x00, 0x27, 0x01, 0x00, 0x00]    # 0x000A: struct
            end
            characteristic 0xFFF3, props: [:read], value: [0x29, 0x09, 0x00] do       # 0x000B / 0x000C
              descriptor 0x2904, value: [0x06, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00]    # 0x000D: uint16, but 3 octets
            end
            characteristic 0x2AB5, props: [:read], value: "Kitchen\x00"               # 0x000E / 0x000F: Location Name
            characteristic custom, props: [:read], value: [0xDE, 0xAD]                # 0x0010 / 0x0011
          end
          primary 0x1800 do                                                           # 0x0012..0x0014
            characteristic 0x2A00, props: [:read], value: "Kitchen Sensor"            # 0x0013 / 0x0014
          end
        end
      end

      it "reads each 0x2904 just before its characteristic's value, after the Identity_Set (Requirement 7.14)" do
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(reads_sent).to eq([
          [:read, 0x0014],
          [:read, 0x0004], [:read, 0x0003], [:read, 0x0007], [:read, 0x0006], [:read, 0x000A], [:read, 0x0009],
          [:read, 0x000D], [:read, 0x000C], [:read, 0x000F], [:read, 0x0011]
        ])
        expect(char_at(walker, 0x0003).presentation_format)
          .to eq(BlueHydra::ValueDecoder::PresentationFormat.new(format: 0x06, exponent: -2, unit: 0x272F,
                                                                namespace: 0x01, description: 0x0000))
      end

      it "decodes a uint16 with Exponent -2 to 23.45, renders its Unit as the 16-bit UUID, and keeps raw_hex" do
        report = peer.build_walker.run

        expect(read_fields(report)[0x0003]).to eq(
          read_status: "read", value: "23.45", value_encoding: "format:uint16;unit:0x272f", raw_hex: "2909"
        )
      end

      it "keeps a value as hex, with no raw_hex, under a float32 or struct Format or one its size does not match" do
        report = peer.build_walker.run

        expect(read_fields(report).values_at(0x0006, 0x0009, 0x000C)).to eq([
          { read_status: "read", value: "0000c03f", value_encoding: "hex" },
          { read_status: "read", value: "010203",   value_encoding: "hex" },
          { read_status: "read", value: "290900",   value_encoding: "hex" }
        ])
      end

      it "decodes a known UTF-8 string characteristic with trailing 0x00 stripped, keeping raw_hex" do
        report = peer.build_walker.run

        expect(read_fields(report)[0x000F])
          .to eq(read_status: "read", value: "Kitchen", value_encoding: "utf8", raw_hex: "4b69746368656e00")
      end

      it "keeps the value of an unknown UUID with no 0x2904 as hex, with no raw_hex" do
        report = peer.build_walker.run

        entry = report.characteristics.find { |candidate| candidate[:value_handle] == 0x0011 }
        expect(entry[:uuid]).to eq("Unknown (#{custom_uuid})")
        expect(read_fields(report)[0x0011]).to eq(read_status: "read", value: "dead", value_encoding: "hex")
      end

      it "carries raw_hex, the value's octets as lowercase hex, beside every decoded value and nowhere else" do
        walker = peer.build_walker
        report = walker.run

        decoded, plain = report.characteristics.partition do |entry|
          !%w[hex identity].include?(entry[:value_encoding])
        end
        expect(decoded.map { |entry| entry[:value_handle] }).to eq([0x0003, 0x000F])
        decoded.each do |entry|
          expect(entry[:raw_hex]).to eq(hex(char_at(walker, entry[:value_handle]).value_bytes))
        end
        expect(plain.map { |entry| entry[:value_encoding] }.uniq).to contain_exactly("hex", "identity")
        expect(plain.select { |entry| entry.key?(:raw_hex) }).to be_empty
        gatt = BlueHydra::GattCharacteristics
        expect(gatt.parse(gatt.serialize(report.characteristics))).to eq(report.characteristics)
      end
    end

    # The same value and 0x2904 that decode to "23.45" above, with the 0x2904
    # read refused: the failure is only logged, and the value read after it
    # still runs and decodes as if there were no 0x2904.
    describe "a 0x2904 read answered with an Error Response (Requirement 7.14)" do
      [0x05, 0x0E].each do |code|
        context format("with code 0x%02x", code) do
          let(:db) do
            GattDatabase.build do
              primary 0x181A do                                                                          # 0x0001..0x0004
                characteristic 0x2A6E, props: [:read], value: [0x29, 0x09] do                            # 0x0002 / 0x0003
                  descriptor 0x2904, value: [0x06, 0xFE, 0x2F, 0x27, 0x01, 0x00, 0x00], read_error: code # 0x0004
                end
              end
            end
          end

          it "still reads the value and decodes it without a format, leaving the Walk complete" do
            walker = peer.build_walker
            report = walker.run

            expect(report.outcome).to eq(:complete)
            expect(reads_sent).to eq([[:read, 0x0004], [:read, 0x0003]])
            expect(response_to(8)).to eq(codec::ErrorResponse.new(request_opcode: 0x0A, handle: 0x0004, error_code: code))
            expect(char_at(walker, 0x0003).presentation_format).to be_nil
            expect(read_fields(report)).to eq(0x0003 => { read_status: "read", value: "2909", value_encoding: "hex" })
            expect(logged(:debug)).to include(a_string_including(
              format("presentation format read at 0x0004 failed (Error Response 0x%02x): value decoded without one", code)
            ))
          end
        end
      end
    end

    # A peer declaring characteristics no gatt_characteristics list may hold:
    # GattCharacteristics refuses a value handle outside 0x0001..0xFFFF or one
    # two entries share (Requirement 11.10). The service has no
    # characteristics of its own; request 5, its characteristic discovery
    # over 0x0001..0x0007, is answered with three notify-only declarations
    # whose value handles are 0x0000, 0x0005 and 0x0005 again.
    describe "a declared value handle the result cannot carry (Requirement 11.10)" do
      let(:db) { GattDatabase.build { primary 0x180F, end_at: 0x0007 } }

      def declaration(value_handle, uuid)
        [0x10, value_handle].pack("CS<") + GattDatabase.uuid_bytes(codec.uuid16(uuid))
      end

      it "leaves out a value handle of 0x0000 and each repeat of one, keeping the first, with one debug line" do
        peer.answer_with(5, codec::ReadByTypeResponse.new(length: 7, entries: [
          [0x0002, declaration(0x0000, 0x2A19)],
          [0x0004, declaration(0x0005, 0x2A1A)],
          [0x0007, declaration(0x0005, 0x2A1B)]
        ]))
        walker = peer.build_walker
        report = walker.run

        expect(report.outcome).to eq(:complete)
        expect(request_summaries[5]).to eq([:characteristics, 0x0001, 0x0007])
        expect(walked_state(walker).characteristics.map { |char| [char.decl_handle, char.value_handle] })
          .to eq([[0x0002, 0x0000], [0x0004, 0x0005], [0x0007, 0x0005]])
        expect(report.characteristics.map { |entry| entry.slice(:decl_handle, :value_handle) })
          .to eq([{ decl_handle: 0x0004, value_handle: 0x0005 }])
        expect(report.characteristics.first[:uuid]).to end_with("(0x2a1a)")
        expect(logged(:debug)).to include(
          "gatt: #{address} 2 characteristic(s) left out of the result: value handle 0x0000 or repeated"
        )
        gatt = BlueHydra::GattCharacteristics
        expect(gatt.parse(gatt.serialize(report.characteristics))).to eq(report.characteristics)
      end
    end

    # Feature: gatt-service-scanning, Property 2: Value reads collect the right bytes for the right handles in the right order
    #
    # For any database GattDatabase.generate draws (Property 1's, with
    # characteristic values of 0 to 600 octets, Identity_Set fixed-size
    # values the wrong length a quarter of the time, and Security_Errors on
    # some values and descriptors), any Server Rx MTU, read_all true or false
    # and a server that answers a Read Blob at the end of a one-part value
    # with 0x0B Attribute Not Long or with an empty part, a full Walk
    # - sends its Read and Read Blob Requests after every discovery request,
    #   and they are exactly, in order (Requirements 1.8, 7.2 to 7.6, 7.14):
    #   for each Identity_Set UUID in the Identity_Set's own order, the
    #   readable instance with the lowest value handle; then, with read_all,
    #   every other readable characteristic by ascending value handle, each
    #   after its 0x2904 when it has one; without read_all nothing more. No
    #   handle of a characteristic without Read, of an unchosen Identity_Set
    #   instance, of an Identity_Set characteristic's 0x2904 or of any other
    #   descriptor is ever read;
    # - reads each of those attributes with a Read and then Read Blobs at an
    #   offset equal to the octets collected so far, while the last part was
    #   a full ATT_MTU - 1 and fewer than 512 octets are in, so it stops at
    #   the first short (or empty) part, at 512, or at the 0x0B or 0x07 that
    #   answers a Read Blob (Requirement 7.1);
    # - collects exactly the served value cut at 512 octets (or, after a
    #   Read Blob answered 0x0B or 0x07, the octets before its offset) in the
    #   CharRecord, and renders read for it; malformed instead for an
    #   Identity_Set fixed-size value of the wrong length (7.13), protected
    #   with its code and no octets for a value answered with a
    #   Security_Error (7.8); not-readable for every characteristic without
    #   Read, duplicate Identity_Set instances included (7.5); not-read for
    #   the other readable instances of an Identity_Set UUID (7.6) and, with
    #   read_all false, for every readable characteristic outside the
    #   Identity_Set (1.8, 7.4). A read non-Identity_Set entry shows those
    #   octets as its hex value or its raw_hex.
    # The Walk is complete throughout: a Security_Error, 0x0B or 0x07 on a
    # read leaves it so (6.8). How values decode is Property 5 and the
    # examples above.
    #
    # The input is [seed, Server Rx MTU, read_all, attribute_not_long,
    # blob_error]. The Server Rx MTU is Property 1's draw with the ATT_MTUs
    # either side of 512-octet and one-part boundaries added. blob_error is
    # nil or [pick, code]: the Walk is run a second time on a fresh peer that
    # answers the pick-th Read Blob of the first Walk (modulo their count)
    # with Error Response code, 0x07 Invalid Offset or 0x0B Attribute Not
    # Long, which a compliant server only sends past a value's end; the Walk
    # is deterministic, so that request has the same index the second time.
    it "Property 2: value reads collect the right bytes for the right handles in the right order" do
      # The Identity_Set in the order the requirements' glossary lists it,
      # which is the order the design queues its reads in.
      identity_order = [0x2A00, 0x2A01, 0x2A29, 0x2A24, 0x2A25, 0x2A26, 0x2A27, 0x2A28, 0x2A23, 0x2A50, 0x2B2A]
      expect(identity_order.sort).to eq(GattDatabase::Generator::IDENTITY_UUIDS.sort)
      identity_uuids      = identity_order.to_h { |number| [number, codec.uuid16(number)] }
      fixed_lengths       = GattDatabase::Generator::IDENTITY_LENGTHS
      security_errors     = GattDatabase::Generator::SECURITY_ERRORS
      presentation_format = codec.uuid16(0x2904)
      max_value           = 512
      error_statuses      = %w[protected error]

      readable    = ->(char) { char.properties.anybits?(GattDatabase::PROPERTIES[:read]) }
      identity_of = lambda do |char|
        identity_uuids.find { |_number, uuid| GattDatabase.same_uuid?(char.uuid, uuid) }&.first
      end
      format_of = lambda do |char|
        char.descriptors.select { |descriptor| GattDatabase.same_uuid?(descriptor.uuid, presentation_format) }
            .min_by(&:handle)
      end

      # The requests a read of the attribute at +handle+ serving +value+
      # sends at ATT_MTU +mtu+, as [:read, handle] and [:read_blob, handle,
      # offset], and the octets it collects, nil when +read_error+ answers
      # its Read (Requirement 7.1). The served value runs out in a short or
      # empty part or in 0x0B, each of which ends the read; +cut+ is the
      # offset of a Read Blob answer_with_error answers, which ends it with
      # the octets before that offset.
      read_of = lambda do |handle, value, read_error, mtu, cut|
        return [[[:read, handle]], nil] if read_error

        full      = mtu - 1
        requests  = [[:read, handle]]
        part      = [value.bytesize, full].min
        collected = part
        while part == full && collected < max_value
          requests << [:read_blob, handle, collected]
          break if collected == cut
          part = [value.bytesize - collected, full].min
          collected += part
        end
        [requests, value.byteslice(0, [collected, max_value].min)]
      end

      # What a full Walk of +db+ reads: [the Read and Read Blob Requests in
      # order, value handle => [Read_Status, error code, CharRecord octets,
      # Identity_Set UUID or nil] for every characteristic].
      expected_reads = lambda do |db, mtu, read_all, cuts|
        requests = []
        outcomes = {}
        read_value = lambda do |char, identity|
          sent, bytes = read_of.(char.value_handle, char.value, char.read_error, mtu, cuts[char.value_handle])
          requests.concat(sent)
          status =
            if char.read_error then security_errors.include?(char.read_error) ? "protected" : "error"
            elsif identity && fixed_lengths.key?(identity) && bytes.bytesize != fixed_lengths[identity] then "malformed"
            else "read"
            end
          outcomes[char.value_handle] = [status, char.read_error, bytes, identity]
        end

        identity_order.each do |number|
          instances = db.characteristics.select { |char| identity_of.(char) == number }
          chosen    = instances.select(&readable).min_by(&:value_handle)
          instances.each do |char|
            next if char.equal?(chosen)
            outcomes[char.value_handle] = [readable.(char) ? "not-read" : "not-readable", nil, nil, number]
          end
          read_value.(chosen, number) if chosen
        end
        db.characteristics.reject(&identity_of).sort_by(&:value_handle).each do |char|
          if !readable.(char)
            outcomes[char.value_handle] = ["not-readable", nil, nil, nil]
          elsif !read_all
            outcomes[char.value_handle] = ["not-read", nil, nil, nil]
          else
            if (descriptor = format_of.(char))
              requests.concat(read_of.(descriptor.handle, descriptor.value, descriptor.read_error, mtu, nil).first)
            end
            read_value.(char, nil)
          end
        end
        [requests, outcomes]
      end

      read_request = lambda do |pdu|
        case pdu
        when codec::ReadRequest then [:read, pdu.handle]
        when codec::ReadBlobRequest then [:read_blob, pdu.handle, pdu.offset]
        end
      end

      walk = lambda do |db, server_rx, read_all, attribute_not_long, error_at|
        served = FakeAttPeer.new(db, clock: FakeClock.new, server_rx_mtu: server_rx,
                                     attribute_not_long: attribute_not_long)
        served.answer_with_error(*error_at) if error_at
        walker = served.build_walker(read_all: read_all)
        [served, walker, walker.run]
      end

      # The problems with one Walk, [] when it read as Property 2 says.
      # +cuts+ is value handle => the offset of the Read Blob answered with
      # an error by answer_with_error.
      problems_with = lambda do |db, att_mtu, read_all, served, walker, report, cuts|
        problems = []
        problems << "outcome #{report.outcome.inspect}, not :complete" unless report.outcome == :complete
        problems << "ATT_MTU #{report.mtu}, not #{att_mtu}" unless report.mtu == att_mtu
        problems.concat(served.violations)

        want_requests, outcomes = expected_reads.(db, att_mtu, read_all, cuts)
        sent  = served.requests.map { |request| read_request.(request.pdu) }
        reads = sent.drop_while(&:nil?)
        if reads != want_requests
          at = (0...[reads.size, want_requests.size].max).find { |i| reads[i] != want_requests[i] }
          problems << format("read request %d of %d (Walk request %d): sent %s, expected %s of %d", at, reads.size,
                             sent.size - reads.size + at, reads[at].inspect, want_requests[at].inspect,
                             want_requests.size)
        end

        records = walked_state(walker).characteristics.to_h { |char| [char.value_handle, char] }
        entries = report.characteristics.to_h { |entry| [entry[:value_handle], entry] }
        unless entries.keys.sort == outcomes.keys.sort
          problems << "entries for #{entries.keys.sort.inspect}, characteristics at #{outcomes.keys.sort.inspect}"
        end
        outcomes.each do |handle, (status, code, bytes, identity)|
          entry, record = entries[handle], records[handle]
          next unless entry && record

          name   = format("0x%04x", handle)
          fields = { read_status: status }
          fields[:error_code] = code if error_statuses.include?(status)
          got = entry.slice(:read_status, :error_code)
          problems << "#{name}: rendered #{got.inspect}, expected #{fields.inspect}" unless got == fields
          unless record.value_bytes == bytes
            problems << format("%s: collected %s, expected %s", name, record.value_bytes&.bytesize.inspect,
                               bytes ? "the #{bytes.bytesize} served octets" : "nothing")
          end
          next unless status == "read" && got == fields

          if identity
            unless entry[:value_encoding] == "identity"
              problems << "#{name}: Identity_Set value encoded #{entry[:value_encoding].inspect}"
            end
          else
            shown = entry[:value_encoding] == "hex" ? entry[:value] : entry[:raw_hex]
            problems << "#{name}: entry shows #{shown.inspect}, not the collected octets' hex" unless shown == hex(bytes)
          end
        end
        [problems, want_requests, outcomes]
      end

      seen = Hash.new(0)
      # A proc, because rantly instance_evals generators on itself.
      mtu = proc {
        freq([2, proc { range(0, 22) }], [4, proc { range(23, 517) }], [1, proc { range(518, 0xFFFF) }],
             [3, proc { choose(22, 23, 24, 45, 246, 247, 248, 511, 512, 513, 514, 516, 517, 518) }])
      }
      blob_error = proc {
        freq([2, proc { nil }], [1, proc { [range(0, 999), 0x07] }], [1, proc { [range(0, 999), 0x0B] }])
      }

      property_of {
        [range(0, GattDatabase::Generator::SEED_MAX), call(mtu), boolean, boolean, call(blob_error)]
      }.check(200) { |seed, server_rx, read_all, attribute_not_long, (pick, code)|
        db      = GattDatabase.generate(seed)
        att_mtu = [23, [517, server_rx].min].max

        served, walker, report = walk.(db, server_rx, read_all, attribute_not_long, nil)
        problems, want_requests, outcomes = problems_with.(db, att_mtu, read_all, served, walker, report, {})
        expect(problems).to be_empty

        blobs = served.requests.select { |request| request.pdu.is_a?(codec::ReadBlobRequest) }
        if code && !blobs.empty?
          blob = blobs[pick % blobs.size]
          again, rewalker, rereport = walk.(db, server_rx, read_all, attribute_not_long, [blob.index, code])
          cuts = { blob.pdu.handle => blob.pdu.offset }
          reproblems, = problems_with.(db, att_mtu, read_all, again, rewalker, rereport, cuts)
          expect(reproblems.map { |problem| format("with 0x%02x to request %d: %s", code, blob.index, problem) })
            .to be_empty
          seen[format("blob_0x%02x", code).to_sym] += 1
        end

        # Coverage, from the model and from how each Read Blob was answered.
        seen[server_rx < 23 ? :below_floor : (server_rx > 517 ? :above_517 : :negotiable)] += 1
        seen[read_all ? :read_all : :identity_only] += 1
        seen[attribute_not_long ? :attribute_not_long : :empty_part_at_end] += 1
        seen[:no_reads] += 1 if want_requests.empty?
        answers = served.delivered.select { |pdu| pdu.kind == :response }.to_h { |pdu| [pdu.request_index, pdu.raw] }
        blobs.each do |request|
          answer = codec.decode(answers.fetch(request.index))
          tag =
            if answer.is_a?(codec::ErrorResponse) then format("ended_on_0x%02x", answer.error_code).to_sym
            elsif answer.value.empty? then :ended_on_empty_part
            elsif answer.value.bytesize < att_mtu - 1 then :ended_on_short_part
            else :continued
            end
          seen[tag] += 1
        end
        outcomes.each do |handle, (status, _code, bytes, _identity)|
          seen[status.to_sym] += 1
          seen[:cut_at_512] += 1 if bytes&.bytesize == max_value && db.attribute(handle).value.bytesize > max_value
        end
        # Requirements 7.5 and 7.6 among an Identity_Set UUID's instances:
        # one without Read below the instance read, and readable ones left
        # not-read.
        identity_outcomes = outcomes.select { |_handle, outcome| outcome[3] }
        identity_outcomes.group_by { |_handle, outcome| outcome[3] }.each_value do |instances|
          read_at = instances.find { |_handle, (status, *)| !%w[not-read not-readable].include?(status) }&.first
          next unless read_at
          seen[:identity_not_readable_below] += 1 if instances.any? { |h, (s, *)| s == "not-readable" && h < read_at }
          seen[:identity_not_read] += 1 if instances.any? { |_h, (s, *)| s == "not-read" }
        end
        next unless read_all

        db.characteristics.each do |char|
          next unless readable.(char) && (descriptor = format_of.(char))
          if identity_of.(char)
            seen[:identity_0x2904_unread] += 1 unless outcomes[char.value_handle][0] == "not-read"
          else
            seen[descriptor.read_error ? :format_refused : :format_read] += 1
          end
        end
      }

      expect(seen.keys).to include(:below_floor, :negotiable, :above_517, :read_all, :identity_only, :attribute_not_long,
                                   :empty_part_at_end, :no_reads, :continued, :ended_on_short_part, :ended_on_empty_part,
                                   :ended_on_0x0b, :blob_0x07, :blob_0x0b, :cut_at_512, :read, :malformed, :protected,
                                   :"not-read", :"not-readable", :identity_not_readable_below, :identity_not_read,
                                   :identity_0x2904_unread, :format_read, :format_refused)
    end
  end

  # Resumable Walks (Requirement 17). A Walk the Link drops reports its
  # WalkState with the interrupted request still at the head of its worklist,
  # and a Walk run with Plan.resume of that state continues the worklist on a
  # new bearer: its one Exchange MTU Request, then exactly the requests the
  # interrupted Walk had still to send, the lost one first. Every Walk of an
  # example serves the same database at the same Server Rx MTU, so the
  # resumed Walk's requests are the uninterrupted Walk's from the lost one on.
  #
  # drop_link_after(k) lets k responses in and loses request k, so the Walk
  # it cuts sends full_requests.first(k + 1) and a Walk resumed from its state
  # sends [:mtu, 517] + full_requests.drop(k).
  #
  # At ATT_MTU 23 the uninterrupted Walk of the database below is the 27
  # requests of full_requests: three primary pages (three services fit a
  # page), the secondary request, an include and two characteristic requests
  # per service, the one descriptor request, the four Identity_Set reads
  # (Device Name, Appearance, Manufacturer Name, Database Hash), the 0x2904
  # read, Battery Level, and the 50-octet value as a Read and two Read Blobs.
  describe "resuming an interrupted Walk (Requirements 17.1, 17.3, 17.5)" do
    let(:server_rx_mtu) { 23 }
    let(:served_hash)   { "00112233445566778899aabbccddeeff" }
    let(:long_value)    { Array.new(50) { |i| 0x30 + i }.pack("C*") }
    let(:db) do
      value, hash = long_value, served_hash
      GattDatabase.build do
        primary 0x180F do                                                       # 0x0001..0x0008
          characteristic 0x2A19, props: %i[read notify], value: [0x64] do       # 0x0002 / 0x0003
            descriptor 0x2904, value: [0x04, 0x00, 0xAD, 0x27, 0x01, 0x00, 0x00] # 0x0004: uint8, percentage
          end
          characteristic 0xFFF1, props: [:read], value: value                   # 0x0005 / 0x0006: 50 octets
          characteristic 0xFFF2, props: [:notify]                               # 0x0007 / 0x0008
        end
        primary 0x180A do                                                       # 0x0009..0x000B
          characteristic 0x2A29, props: [:read], value: "Acme"                  # 0x000A / 0x000B
        end
        primary 0x1800 do                                                       # 0x000C..0x0010
          characteristic 0x2A00, props: [:read], value: "Sensor"                # 0x000D / 0x000E
          characteristic 0x2A01, props: [:read], value: [0xC1, 0x03]            # 0x000F / 0x0010
        end
        primary 0x1801 do                                                       # 0x0011..0x0013
          characteristic 0x2B2A, props: [:read], value: [hash].pack("H*")       # 0x0012 / 0x0013
        end
      end
    end
    let(:full_requests) do
      [
        [:mtu, 517],
        [:primary, 0x0001, 0xFFFF], [:primary, 0x0011, 0xFFFF], [:primary, 0x0014, 0xFFFF],      # 1 to 3
        [:secondary, 0x0001, 0xFFFF],                                                           # 4
        [:includes, 0x0001, 0x0008], [:characteristics, 0x0001, 0x0008], [:characteristics, 0x0008, 0x0008], # 5 to 7
        [:includes, 0x0009, 0x000B], [:characteristics, 0x0009, 0x000B], [:characteristics, 0x000B, 0x000B], # 8 to 10
        [:includes, 0x000C, 0x0010], [:characteristics, 0x000C, 0x0010], [:characteristics, 0x0010, 0x0010], # 11 to 13
        [:includes, 0x0011, 0x0013], [:characteristics, 0x0011, 0x0013], [:characteristics, 0x0013, 0x0013], # 14 to 16
        [:descriptors, 0x0004, 0x0004],                                                         # 17
        [:read, 0x000E], [:read, 0x0010], [:read, 0x000B], [:read, 0x0013],                     # 18 to 21
        [:read, 0x0004], [:read, 0x0003],                                                       # 22, 23
        [:read, 0x0006], [:read_blob, 0x0006, 22], [:read_blob, 0x0006, 44]                     # 24 to 26
      ]
    end
    let(:identity) do
      { device_name: "Sensor", appearance: "0x03c1", manufacturer_name: "Acme", database_hash: served_hash }
    end
    let(:exchange) { [:mtu, 517] }

    def resume_plan(state)
      BlueHydra::GattWalker::Plan.resume(state)
    end

    # Walks db on a fresh peer sharing the clock, the Link dropping once
    # +drop_after+ responses are in (never when nil), a block given scripting
    # the peer first: [peer, walker, report]. The peer answers the exchange
    # with +server_rx+, the group's Server Rx MTU of 23 unless given. Each
    # peer gets the after hook's checks, as it is not the let peer.
    def walk(plan: BlueHydra::GattWalker::Plan.full, drop_after: nil, server_rx: nil, **overrides)
      served = FakeAttPeer.new(db, clock: clock, server_rx_mtu: server_rx || server_rx_mtu)
      served.drop_link_after(drop_after) if drop_after
      yield served if block_given?
      walker = served.build_walker(plan: plan, **overrides)
      report = walker.run
      expect(served.calls.map(&:name)).not_to include(:setsockopt)
      expect(served.violations).to be_empty
      [served, walker, report]
    end

    # The Walk on +served+ sent +sent+, lost the last of them to the Link
    # dropping, ended disconnected and reports its WalkState with work still
    # outstanding (Requirement 17.1).
    def expect_interrupted(served, walker, report, sent:, resumed:)
      expect(report.outcome).to eq(:disconnected)
      expect(report.resumed).to be(resumed)
      expect(request_summaries(served)).to eq(sent)
      expect(served.requests.map(&:lost)).to eq([false] * (sent.size - 1) + [true])
      expect(report.requests_sent).to eq(sent.size)
      expect(report.state).to equal(walked_state(walker))
      expect(report.state.outstanding?).to be(true)
      expect(report.outstanding).not_to eq(procedures: [], reads: [])
      expect_bearer_closed(walker, report, served)
    end

    # A fresh Walk the Link drops as request +k+ is sent: [peer, walker,
    # report].
    def interrupted_at(k)
      served, walker, report = walk(drop_after: k)
      expect_interrupted(served, walker, report, sent: full_requests.first(k + 1), resumed: false)
      [served, walker, report]
    end

    # The resumed Walk on +served+ sent its exchange and then exactly +sent+,
    # no hash check among them, reached its end and reports no state
    # (Requirements 17.3, 17.7).
    def expect_resumed_to_end(served, walker, report, sent:)
      expect(report.outcome).to eq(:complete)
      expect(report.resumed).to be(true)
      expect(report.state).to be_nil
      expect(report.outstanding).to eq(procedures: [], reads: [])
      requests = request_summaries(served)
      expect(requests).to eq([exchange] + sent)
      expect(requests.map(&:first)).not_to include(:hash)
      expect(report.requests_sent).to eq(requests.size)
      expect(walked_state(walker).outstanding?).to be(false)
      expect(walked_state(walker).partial).to be(false)
      expect_bearer_closed(walker, report, served)
    end

    # Every attribute handle the discovery pages delivered on +served+ carry:
    # the declaration handles of the services, includes and characteristics
    # and the descriptor handles the Walk on it discovered.
    def handles_paged(served)
      served.delivered.select { |pdu| pdu.kind == :response }.flat_map do |pdu|
        decoded = codec.decode(pdu.raw)
        decoded.respond_to?(:entries) ? decoded.entries.map(&:first) : []
      end
    end

    def reads_in(requests)
      requests.select { |kind, *| %i[read read_blob].include?(kind) }
    end

    # The value handles of every characteristic whose read +state+ has
    # finished, with a value or without.
    def finished_reads(state)
      state.characteristics.select(&:read_status).map(&:value_handle)
    end

    # What the Device stores from +report+.
    def result_of(report)
      { services: report.services, characteristics: report.characteristics, identity: report.identity }
    end

    # The results of +reports+ as the Device accumulates them across Walks
    # (Requirements 11.5, 11.8, 17.4): services by start handle and
    # characteristics by value handle, a later Walk's entry winning, and the
    # identity values merged.
    def union(*reports)
      reports.map { |report| result_of(report) }.reduce do |stored, incoming|
        services = (stored[:services] + incoming[:services]).to_h { |service| [service[:start], service] }
        {
          services:        services.keys.sort.map { |start| services[start] },
          characteristics: BlueHydra::GattCharacteristics.merge_by_value_handle(stored[:characteristics],
                                                                               incoming[:characteristics]),
          identity:        stored[:identity].merge(incoming[:identity])
        }
      end
    end

    # The read fields of the entry for +value_handle+ in +report+, as value
    # reads' read_fields renders one.
    def read_entry(report, value_handle)
      report.characteristics.find { |entry| entry[:value_handle] == value_handle }
            .slice(:read_status, :error_code, :value, :value_encoding, :raw_hex)
    end

    it "sends full_requests and reads every value when uninterrupted" do
      served, walker, report = walk

      expect(report.outcome).to eq(:complete)
      expect(report.resumed).to be(false)
      expect(request_summaries(served)).to eq(full_requests)
      expect(report.identity).to eq(identity)
      expect(report.database_hash).to eq(served_hash)
      expect(report.characteristics.map { |entry| entry[:read_status] })
        .to eq(%w[read read not-readable read read read read])
      expect(read_entry(report, 0x0006)).to eq(read_status: "read", value: long_value.unpack1("H*"), value_encoding: "hex")
      expect(report.state).to be_nil
      expect_bearer_closed(walker, report, served)
    end

    # [k, what request k is]: the Link drops as that request is sent, with k
    # responses in. Each phase of a Walk is cut at least once: before any
    # page is in, in the service, characteristic and descriptor procedures, at
    # the first read, among the Identity_Set reads, at the 0x2904 read, at a
    # value read and in the middle of a Read Blob sequence.
    [
      [1,  "the first primary page, before any service is in"],
      [2,  "the second primary page, three services in"],
      [4,  "the secondary request, primary discovery ended"],
      [5,  "the first include request, both service procedures ended"],
      [7,  "the first service's second characteristic page"],
      [17, "the descriptor request, every characteristic in"],
      [18, "the Device Name read, discovery done and the reads generated"],
      [21, "the Database Hash read, three Identity_Set values in"],
      [22, "the 0x2904 read, the Identity_Set in"],
      [23, "the Battery Level read, its 0x2904 parsed"],
      [25, "the first Read Blob, 22 of the 50 octets collected"],
      [26, "the second Read Blob, 44 octets collected"]
    ].each do |k, lost|
      context "when the Link drops as request #{k}, #{lost}, is sent" do
        it "leaves its state, and the Walk resumed from it sends the exchange then only the requests left and finishes" do
          _, _, full_report = walk
          first, _walker, report = interrupted_at(k)
          state    = report.state
          snapshot = Marshal.dump(state)

          second, rewalker, rereport = walk(plan: resume_plan(state))

          expect(Marshal.dump(state)).to eq(snapshot)
          expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(k))
          # Requirement 17.3 in the Walk's own terms: no handle a page of the
          # first Walk delivered comes back in a page of the second, no value
          # the first Walk finished reading is read again, and no Read or Read
          # Blob the first Walk had answered is sent again. The lost request
          # is sent again, having been answered by nobody.
          expect(handles_paged(second) & handles_paged(first)).to be_empty
          expect(reads_in(request_summaries(second)).map { |_kind, handle, _offset| handle } & finished_reads(state))
            .to be_empty
          expect(reads_in(request_summaries(second)) & reads_in(full_requests.first(k))).to be_empty
          # Requirement 17.4: together the two Walks' results are the
          # uninterrupted Walk's, and the resumed Walk, holding the whole
          # WalkState, reports all of it itself.
          expect(union(report, rereport)).to eq(result_of(full_report))
          expect(result_of(rereport)).to eq(result_of(full_report))
          expect(rereport.identity).to eq(identity)
          expect(rereport.database_hash).to eq(served_hash)
        end
      end
    end

    # [k, j, where the drops land, the outstanding work after each]: the
    # first Walk loses request k; the Walk resumed from it loses its request
    # j, which is full request k + j - 1; a third Walk resumes from that.
    # The second Walk's outstanding set is the first's less what it finished,
    # with whatever discovery appended, and smaller.
    primary_from_0x0011   = { kind: :primary,   start: 0x0001, end: 0xFFFF, next: 0x0011 }
    secondary_from_0x0001 = { kind: :secondary, start: 0x0001, end: 0xFFFF, next: 0x0001 }
    reads_from_appearance = [
      { kind: :identity, value_handle: 0x0010 }, { kind: :identity, value_handle: 0x000B },
      { kind: :identity, value_handle: 0x0013 }, { kind: :presentation_format, value_handle: 0x0003 },
      { kind: :value, value_handle: 0x0003 }, { kind: :value, value_handle: 0x0006 }
    ]
    [
      [2, 3, "both in service discovery",
       { procedures: [primary_from_0x0011, secondary_from_0x0001], reads: [] },
       { procedures: [secondary_from_0x0001], reads: [] }],
      [7, 13, "in characteristic discovery, then among the Identity_Set reads",
       { procedures: [
         { kind: :characteristics, start: 0x0001, end: 0x0008, next: 0x0008 },
         { kind: :includes, start: 0x0009, end: 0x000B, next: 0x0009 },
         { kind: :characteristics, start: 0x0009, end: 0x000B, next: 0x0009 },
         { kind: :includes, start: 0x000C, end: 0x0010, next: 0x000C },
         { kind: :characteristics, start: 0x000C, end: 0x0010, next: 0x000C },
         { kind: :includes, start: 0x0011, end: 0x0013, next: 0x0011 },
         { kind: :characteristics, start: 0x0011, end: 0x0013, next: 0x0011 }
       ], reads: [] },
       { procedures: [], reads: reads_from_appearance }],
      [20, 3, "both among the reads",
       { procedures: [], reads: reads_from_appearance.drop(1) },
       { procedures: [], reads: reads_from_appearance.drop(3) }]
    ].each do |k, j, where, outstanding_first, outstanding_second|
      context "when the Link drops as request #{k} is sent and again as the resumed Walk's request #{j} is, #{where}" do
        it "reports the still-outstanding set, smaller than the one it resumed from, and a third Walk finishes from it" do
          _, _, full_report = walk
          first, _walker, report = interrupted_at(k)
          expect(report.outstanding).to eq(outstanding_first)
          state    = report.state
          snapshot = Marshal.dump(state)

          second, rewalker, rereport = walk(plan: resume_plan(state), drop_after: j)
          expect(Marshal.dump(state)).to eq(snapshot)
          expect_interrupted(second, rewalker, rereport, sent: [exchange] + full_requests[k, j], resumed: true)
          expect(rereport.outstanding).to eq(outstanding_second)
          expect(rereport.state).not_to equal(state)
          expect(rereport.state).not_to eq(state)
          expect(outstanding_second.values.sum(&:size)).to be < outstanding_first.values.sum(&:size)
          # Requirement 17.4 across the two: everything the first found, and
          # what the second added.
          expect(union(report, rereport)).to eq(result_of(rereport))
          expect(rereport.services.size).to be >= report.services.size
          expect(rereport.characteristics.size).to be >= report.characteristics.size

          third, third_walker, third_report = walk(plan: resume_plan(rereport.state))
          expect_resumed_to_end(third, third_walker, third_report, sent: full_requests.drop(k + j - 1))
          expect(handles_paged(third) & (handles_paged(first) + handles_paged(second))).to be_empty
          expect(reads_in(request_summaries(third)) & reads_in(full_requests.first(k + j - 1))).to be_empty
          expect(union(report, rereport, third_report)).to eq(result_of(full_report))
          expect(result_of(third_report)).to eq(result_of(full_report))
        end
      end
    end

    # The resumed Walk works on a deep copy of the plan's state (Requirement
    # 17.2's one Resume_State per address stays the Gatt_Tracker's): the
    # plan's state is byte for byte what it was, however far the Walk gets,
    # and shares no Array or record with the Walk's.
    it "leaves the plan's state as it was, sharing nothing with it, when the resumed Walk discovers and reads" do
      _, _, report = interrupted_at(7)
      state    = report.state
      snapshot = Marshal.dump(state)
      services_before = state.services.size
      characteristics_before = state.characteristics.size

      _, rewalker, rereport = walk(plan: resume_plan(state))

      expect(rereport.outcome).to eq(:complete)
      expect(Marshal.dump(state)).to eq(snapshot)
      expect(state.services.size).to eq(services_before)
      expect(state.characteristics.size).to eq(characteristics_before)
      expect(state.outstanding?).to be(true)
      worked = walked_state(rewalker)
      expect(worked).not_to equal(state)
      expect(worked.services).not_to equal(state.services)
      expect(worked.characteristics).not_to equal(state.characteristics)
      expect(worked.characteristics.first).not_to equal(state.characteristics.first)
      expect(worked.characteristics.first.read_status).to eq(:read)
      expect(state.characteristics.first.read_status).to be_nil
    end

    # A resumed Walk holds its WalkState from run's entry, so one cut short
    # before it could send a discovery or read request reports that state's
    # outstanding work unchanged, on a copy: the Gatt_Scanner replaces
    # Resume_State with it rather than clearing it (Requirement 17.5). What
    # the state holds is reported as found, as a resumed Walk reports
    # everything found so far.
    describe "a resumed Walk cut short before its first discovery or read request (Requirement 17.5)" do
      [
        [:disconnected, "no Link is up",                             [],         nil,
         { link_up: ->(_address) { nil } }],
        [:disconnected, "the connect does not complete within 1 s",  [],         ->(served) { served.connect_outcome(:never) },
         {}],
        [:disconnected, "the Link drops as the exchange is sent",    [[:mtu, 517]], ->(served) { served.drop_link_after(0) },
         {}],
        [:timeout,      "the exchange goes unanswered to Walk_Bound", [[:mtu, 517]], ->(served) { served.delay_response(0, Float::INFINITY) },
         {}]
      ].each do |outcome, why, sent, script, overrides|
        it "reports #{outcome} with the plan's outstanding work, equal and not the same object, when #{why}" do
          _, _, report = interrupted_at(7)
          state    = report.state
          snapshot = Marshal.dump(state)

          second, rewalker, rereport = walk(plan: resume_plan(state), **overrides) { |served| script&.call(served) }

          expect(rereport.outcome).to eq(outcome)
          expect(rereport.resumed).to be(true)
          expect(request_summaries(second)).to eq(sent)
          expect(rereport.requests_sent).to eq(sent.size)
          expect(rereport.state).to equal(walked_state(rewalker))
          expect(rereport.state).to eq(state)
          expect(rereport.state).not_to equal(state)
          expect(rereport.outstanding).to eq(report.outstanding)
          expect(Marshal.dump(state)).to eq(snapshot)
          expect(result_of(rereport)).to eq(result_of(report))
          expect(rereport.database_hash).to be_nil
          expect_bearer_closed(rewalker, rereport, second)
        end
      end

      it "reports busy with no state when the connect raises EBUSY: Resume_State is left as it is" do
        _, _, report = interrupted_at(7)
        state    = report.state
        snapshot = Marshal.dump(state)

        second, rewalker, rereport = walk(plan: resume_plan(state)) { |served| served.connect_outcome(Errno::EBUSY) }

        expect(rereport.outcome).to eq(:busy)
        expect(rereport.resumed).to be(true)
        expect(rereport.state).to be_nil
        expect(rereport.outstanding).to eq(procedures: [], reads: [])
        expect(second.requests).to be_empty
        expect(Marshal.dump(state)).to eq(snapshot)
        expect_bearer_closed(rewalker, rereport, second)
      end
    end

    # The value at 0x0006 is 50 octets: a Read of 22, a Read Blob at 22 of 22
    # and a Read Blob at 44 of 6. A Walk cut after the first or second has the
    # read at the head of its reads with the octets so far collected and its
    # offset at their count; the resumed Walk sends the Read Blob at that
    # offset first, no Read, and ends with the whole value.
    describe "a pending Read Blob (Requirement 17.3)" do
      [[25, 22], [26, 44]].each do |k, offset|
        it "resumes the value at offset #{offset} with the #{offset} octets collected, sending no Read for it" do
          _, _, report = interrupted_at(k)
          task = report.state.reads.first
          expect([task.kind, task.handle, task.offset, task.collected])
            .to eq([:value, 0x0006, offset, long_value.byteslice(0, offset)])
          expect(report.outstanding).to eq(procedures: [], reads: [{ kind: :value, value_handle: 0x0006 }])
          expect(read_entry(report, 0x0006)).to eq(read_status: "not-read")

          second, rewalker, rereport = walk(plan: resume_plan(report.state))

          requests = request_summaries(second)
          expect(requests).to eq([exchange] + (offset...50).step(22).map { |at| [:read_blob, 0x0006, at] })
          expect(requests[1]).to eq([:read_blob, 0x0006, offset])
          expect(response_to(1, second).value).to eq(long_value.byteslice(offset, 22))
          expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(k))
          record = walked_state(rewalker).characteristics.find { |char| char.value_handle == 0x0006 }
          expect(record.value_bytes).to eq(long_value)
          expect(read_entry(rereport, 0x0006))
            .to eq(read_status: "read", value: long_value.unpack1("H*"), value_encoding: "hex")
        end
      end
    end

    # A server judges "long" against the current ATT_MTU (Core 6.3 Vol 3 Part
    # F 3.4.4.5): the 50-octet value at 0x0006 needs Read Blobs at ATT_MTU 23
    # but fits one Read Response at 517, where a Read Blob for it is answered
    # 0x0B Attribute Not Long (the harness does so for any value of at most
    # ATT_MTU - 1 octets). A Walk resumed at the larger MTU with that blob at
    # the head of its reads would otherwise store the 22 or 44 octets
    # collected at 23 as the whole value. Plan.resume flags the task carried
    # on the Walk's copy; the 0x0B then puts it back to a Read Request, once.
    describe "a carried Read Blob answered 0x0B at a larger ATT_MTU (Requirement 7.19)" do
      let(:not_long)   { codec::ErrorResponse.new(request_opcode: 0x0C, handle: 0x0006, error_code: 0x0B) }
      let(:whole)      { { read_status: "read", value: long_value.unpack1("H*"), value_encoding: "hex" } }
      let(:full_report) { walk.last }

      # The one debug line the re-read logs, for the blob at +offset+ at +mtu+.
      def reread_line(offset, mtu)
        format("gatt: %s value read at 0x0006: 0x0B to the carried Read Blob at offset %d with ATT_MTU %d, " \
               "re-reading from the start", address, offset, mtu)
      end

      def reread_lines
        logged(:debug).select { |line| line.include?("to the carried Read Blob") }
      end

      [[25, 22], [26, 44]].each do |k, offset|
        it "re-reads the value with a Read Request when the blob at offset #{offset} is answered 0x0B at 517, and stores all of it" do
          _, _, report = interrupted_at(k)
          state    = report.state
          snapshot = Marshal.dump(state)
          expect(state.reads.first.to_h).to include(kind: :value, handle: 0x0006, offset: offset, carried: false,
                                                    restarted: false)

          second, rewalker, rereport = walk(plan: resume_plan(state), server_rx: 517)

          # The carried blob, its 0x0B, the Read Request from the start, and
          # the whole value in its one Read Response: no third request for
          # the value and no other request repeated.
          expect(request_summaries(second)).to eq([exchange, [:read_blob, 0x0006, offset], [:read, 0x0006]])
          expect(response_to(1, second)).to eq(not_long)
          expect(response_to(2, second)).to be_a(codec::ReadResponse)
          expect(response_to(2, second).value).to eq(long_value)
          expect(rereport.mtu).to eq(517)
          expect_resumed_to_end(second, rewalker, rereport, sent: [[:read_blob, 0x0006, offset], [:read, 0x0006]])
          record = walked_state(rewalker).characteristics.find { |char| char.value_handle == 0x0006 }
          expect(record.value_bytes).to eq(long_value)
          expect(read_entry(rereport, 0x0006)).to eq(whole)
          expect(reread_lines).to eq([reread_line(offset, 517)])
          expect(logged(:warn) + logged(:error)).to be_empty
          # The plan's state is as reported, carried flag included: the
          # Gatt_Tracker's Resume_State is not what the Walk marks.
          expect(Marshal.dump(state)).to eq(snapshot)
          expect(state.reads.first.carried).to be(false)
          expect(union(report, rereport)).to eq(result_of(full_report))
        end
      end

      it "is unchanged at the same ATT_MTU: the carried blob is answered with its part and nothing is re-read" do
        _, _, report = interrupted_at(25)

        second, rewalker, rereport = walk(plan: resume_plan(report.state))

        expect(request_summaries(second)).to eq([exchange, [:read_blob, 0x0006, 22], [:read_blob, 0x0006, 44]])
        expect(response_to(1, second)).to be_a(codec::ReadBlobResponse)
        expect(response_to(1, second).value).to eq(long_value.byteslice(22, 22))
        expect(rereport.mtu).to eq(23)
        expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(25))
        expect(read_entry(rereport, 0x0006)).to eq(whole)
        expect(reread_lines).to be_empty
      end

      # [Server Rx MTU, requests scripted 0x0B (index => code), the requests
      # after the exchange, octets stored, how the second 0x0B comes about].
      # restarted is set by the first re-read, so the second 0x0B ends the
      # read under Requirement 7.1 with what the re-read collected, and
      # nothing is sent for the value after it.
      [
        [51, {}, [[:read_blob, 0x0006, 22], [:read, 0x0006], [:read_blob, 0x0006, 50]], 50,
         "the re-read's Read Response is one full part of 50, and the server answers the blob after it 0x0B"],
        [33, { 1 => 0x0B, 3 => 0x0B }, [[:read_blob, 0x0006, 22], [:read, 0x0006], [:read_blob, 0x0006, 32]], 32,
         "a server answers 0x0B to the carried blob and again to the blob after the re-read's full part of 32"]
      ].each do |server_rx, scripted, sent, stored, how|
        it "ends the read on a second 0x0B with the #{stored} octets the re-read collected and no third attempt, when #{how}" do
          _, _, report = interrupted_at(25)
          state    = report.state
          snapshot = Marshal.dump(state)

          second, rewalker, rereport = walk(plan: resume_plan(state), server_rx: server_rx) do |served|
            scripted.each { |index, code| served.answer_with_error(index, code) }
          end

          expect(request_summaries(second)).to eq([exchange] + sent)
          expect(response_to(1, second)).to eq(not_long)
          expect(response_to(2, second)).to be_a(codec::ReadResponse)
          expect(response_to(2, second).value).to eq(long_value.byteslice(0, server_rx - 1))
          expect(response_to(3, second)).to eq(not_long)
          expect(rereport.mtu).to eq(server_rx)
          expect_resumed_to_end(second, rewalker, rereport, sent: sent)
          record = walked_state(rewalker).characteristics.find { |char| char.value_handle == 0x0006 }
          expect(record.value_bytes).to eq(long_value.byteslice(0, stored))
          expect(read_entry(rereport, 0x0006))
            .to eq(read_status: "read", value: long_value.byteslice(0, stored).unpack1("H*"), value_encoding: "hex")
          expect(reread_lines).to eq([reread_line(22, server_rx)])
          expect(Marshal.dump(state)).to eq(snapshot)
        end
      end

      # A Read Blob of the resumed Walk's own, for a read whose offset was 0
      # when the Walk resumed, is not carried: 0x0B to it ends the value with
      # the octets collected, as in a fresh Walk (the Requirement 7.1
      # examples under "a read ended by an Error Response"), whatever the
      # ATT_MTU of the Walk that found the characteristic.
      it "leaves a Read Blob that was not carried to end the value on 0x0B with the octets collected" do
        _, _, report = interrupted_at(22)
        expect(report.state.reads.map(&:offset)).to all(eq(0))

        second, rewalker, rereport = walk(plan: resume_plan(report.state)) { |served| served.answer_with_error(5, 0x0B) }

        expect(request_summaries(second)).to eq([
          exchange, [:read, 0x0004], [:read, 0x0003], [:read, 0x0006], [:read_blob, 0x0006, 22], [:read_blob, 0x0006, 44]
        ])
        expect(response_to(5, second)).to eq(not_long)
        expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(22))
        expect(read_entry(rereport, 0x0006))
          .to eq(read_status: "read", value: long_value.byteslice(0, 44).unpack1("H*"), value_encoding: "hex")
        expect(reread_lines).to be_empty
      end

      # The re-read is one more request the Link can drop. The state then
      # reported holds the task back at offset 0 with nothing collected,
      # carried and restarted, so the Walk resumed from it sends a Read
      # Request and, restarted holding across the resume, re-reads no second
      # time when a blob of its own is answered 0x0B.
      it "reports the read at offset 0, carried and restarted, when the Link drops as the re-read is sent, and a further resume re-reads no second time" do
        _, _, report = interrupted_at(25)
        state    = report.state
        snapshot = Marshal.dump(state)

        second, rewalker, rereport = walk(plan: resume_plan(state), server_rx: 517, drop_after: 2)

        expect_interrupted(second, rewalker, rereport, sent: [exchange, [:read_blob, 0x0006, 22], [:read, 0x0006]],
                                                       resumed: true)
        expect(response_to(1, second)).to eq(not_long)
        expect(rereport.state.reads.size).to eq(1)
        expect(rereport.state.reads.first.to_h)
          .to include(kind: :value, handle: 0x0006, offset: 0, collected: "", carried: true, restarted: true)
        expect(rereport.outstanding).to eq(procedures: [], reads: [{ kind: :value, value_handle: 0x0006 }])
        expect(read_entry(rereport, 0x0006)).to eq(read_status: "not-read")
        expect(reread_lines).to eq([reread_line(22, 517)])
        expect(Marshal.dump(state)).to eq(snapshot)

        # At Server Rx MTU 51 the Read brings one full part of 50 and the
        # blob after it is answered 0x0B: the read ends there with the whole
        # value.
        third, third_walker, third_report = walk(plan: resume_plan(rereport.state), server_rx: 51)

        expect(request_summaries(third)).to eq([exchange, [:read, 0x0006], [:read_blob, 0x0006, 50]])
        expect(response_to(2, third)).to eq(not_long)
        expect_resumed_to_end(third, third_walker, third_report, sent: [[:read, 0x0006], [:read_blob, 0x0006, 50]])
        expect(read_entry(third_report, 0x0006)).to eq(whole)
        expect(reread_lines).to eq([reread_line(22, 517)])
        expect(union(report, rereport, third_report)).to eq(result_of(full_report))
        expect(result_of(third_report)).to eq(result_of(full_report))
      end
    end

    # The report's database_hash is the hash read most recently across the
    # Walks a state links (Requirement 4.8): the one the state was built
    # against until the resumed Walk reads one itself.
    describe "the Database Hash across Walks (Requirements 4.8, 17.3)" do
      it "carries the hash the interrupted Walk read and reads 0x2B2A no second time" do
        _, _, report = interrupted_at(22)
        expect(report.database_hash).to eq(served_hash)
        expect(report.state.database_hash).to eq(served_hash)
        expect(report.identity).to eq(identity)

        second, rewalker, rereport = walk(plan: resume_plan(report.state))

        expect(request_summaries(second)).to eq([
          exchange, [:read, 0x0004], [:read, 0x0003], [:read, 0x0006], [:read_blob, 0x0006, 22], [:read_blob, 0x0006, 44]
        ])
        expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(22))
        expect(rereport.database_hash).to eq(served_hash)
        expect(rereport.hash_changed).to be(false)
        expect(rereport.identity).to eq(identity)
        expect(read_entry(rereport, 0x0013)).to eq(read_status: "read", value: served_hash, value_encoding: "identity")
      end

      # A hash check whose read finds a hash other than the recorded one
      # starts a fresh WalkState built against that hash (Requirement 17.6)
      # and walks on; cut short, its state carries it. The resumed Walk's
      # own 0x2B2A read, of the hash the database serves, then replaces it in
      # the report, while the plan's state keeps the one it was built
      # against.
      it "replaces the hash its state was built against with the one the resumed Walk reads" do
        recorded = "ffeeddccbbaa99887766554433221100"
        checked  = "0f" * 16
        first, walker, report = walk(plan: BlueHydra::GattWalker::Plan.hash_check(recorded), drop_after: 6) do |served|
          served.answer_with(1, codec::ReadByTypeResponse.new(length: 18, entries: [[0x0013, [checked].pack("H*")]]))
        end

        # The exchange, the hash check, then full requests 1 to 5, the last
        # lost.
        expect_interrupted(first, walker, report, sent: [exchange, [:hash, 0x0001, 0xFFFF]] + full_requests[1, 5],
                                                  resumed: false)
        expect(report.hash_changed).to be(true)
        expect(report.database_hash).to eq(checked)
        expect(report.state.database_hash).to eq(checked)
        state    = report.state
        snapshot = Marshal.dump(state)

        second, rewalker, rereport = walk(plan: resume_plan(state))

        expect_resumed_to_end(second, rewalker, rereport, sent: full_requests.drop(5))
        expect(rereport.database_hash).to eq(served_hash)
        expect(rereport.hash_changed).to be(false)
        expect(walked_state(rewalker).database_hash).to eq(served_hash)
        expect(Marshal.dump(state)).to eq(snapshot)
        expect(state.database_hash).to eq(checked)
      end
    end

    # Requirement 6.7 names the first primary-service request of a full Walk.
    # A resumed Walk's first primary request, even one from 0x0001 with no
    # service yet found, continues a Walk that has already begun, so a
    # Security_Error to it ends the procedure as any later one does
    # (Requirement 6.5): partial, with the Walk run to its end.
    describe "a Security_Error on the first primary request of a resumed Walk (Requirement 6.7)" do
      it "ends the Walk partial, not protected, where a fresh Walk would be protected" do
        _, _, fresh = walk { |served| served.security_error_on_first_primary(0x05) }
        expect(fresh.outcome).to eq(:protected)

        _, _, report = interrupted_at(1)
        expect(report.outstanding[:procedures].first).to eq(kind: :primary, start: 0x0001, end: 0xFFFF, next: 0x0001)
        expect(report.services).to be_empty

        second, rewalker, rereport = walk(plan: resume_plan(report.state)) do |served|
          served.security_error_on_first_primary(0x05)
        end

        expect(rereport.outcome).to eq(:partial)
        expect(rereport.resumed).to be(true)
        expect(rereport.state).to be_nil
        expect(request_summaries(second)).to eq([exchange, [:primary, 0x0001, 0xFFFF], [:secondary, 0x0001, 0xFFFF]])
        expect(response_to(1, second))
          .to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x05))
        worked = walked_state(rewalker)
        expect(worked.protected_root).to be(false)
        expect(worked.partial).to be(true)
        expect(worked.procedures).to be_empty
        expect([rereport.services, rereport.characteristics, rereport.identity]).to eq([[], [], {}])
        expect_bearer_closed(rewalker, rereport, second)
      end
    end

    # Feature: gatt-service-scanning, Property 15: A resumed Walk never repeats finished work
    #
    # For any database GattDatabase.generate draws at a size that keeps a
    # case quick (0 to 8 services, 0 to 6 characteristics each, 0 to 2
    # descriptors, values of 0 to 100 octets, so Read Blobs occur at ATT_MTU
    # 23; Security_Errors on some reads or, half the time, 0x0E Unlikely
    # Error on a fifth of them, which on an Identity_Set read leaves the Walk
    # partial and on any other read leaves that value error), any Server Rx
    # MTU for the fresh Walk and, three times in four, another one the peer
    # of every resumed Walk answers with, read_all true or false, and any chain
    # of one to three interruptions, each a Link drop or a Walk_Bound expiry
    # (the response never arriving) at that Walk's k-th request, with R the
    # requests of the uninterrupted Walk:
    # - the fresh Walk sends R.first(k + 1), the last of them unanswered,
    #   ends disconnected or timeout and reports its WalkState with work
    #   outstanding (Requirement 17.1);
    # - a Walk resumed from a reported state sends [:mtu, 517] and then
    #   exactly the requests of R from the unanswered one on, up to its own
    #   cut: no request R had answered, no handle an earlier page delivered,
    #   no value whose read an earlier Walk finished, no 0x2B2A hash check
    #   (17.3); it ends within its Walk_Bound (17.9) with resumed true; cut
    #   short again it reports a state with strictly fewer of R's requests
    #   left to send, and so not the state it resumed from, when any request
    #   of R was answered, and one equal to it, a pending Read Blob flagged
    #   carried, when none was (17.5);
    # - every plan's state is byte for byte as it was after the Walk (17.2);
    # - the last Walk, run to the end, ends with the uninterrupted Walk's
    #   outcome (complete, or partial), no state, and a result equal to the
    #   uninterrupted Walk's, and the chain's results union to it (17.4);
    # - across the chain every request of R is answered exactly once, the
    #   fresh Walk's exchange included, and nothing else is.
    # A cut whose k lies past the requests its Walk has left lets that Walk
    # finish, which ends the chain there (the first Walk's then equals the
    # uninterrupted Walk).
    #
    # When the resumed Walks' peers answer with another Server Rx MTU, pages
    # hold a different number of entries and values come in a different
    # number of parts from the first resumed Walk on, so R stops describing
    # the work left. R' takes its place: the requests of a Walk resumed from
    # the same state at the new MTU and left uninterrupted, which must end as
    # the uninterrupted Walk did and with its result. The chain then answers
    # exactly R up to the switch and R' after its exchange, each once. The
    # one repeat permitted is the Requirement 7.19 re-read: a Read Blob
    # carried over from a smaller ATT_MTU and answered 0x0B at the larger one
    # is followed by a Read Request for a value R had already read, which
    # happens only across a rise in ATT_MTU and at most once per value, and
    # the whole value is still in the result. At the same or a smaller
    # ATT_MTU nothing is ever repeated.
    #
    # The input is [seed, other_errors, Server Rx MTU, read_all, cuts,
    # resumed Server Rx MTU]: GattDatabase.generate(seed, services: 0..8,
    # chars: 0..6, descriptors: 0..2, values: 0..100) rebuilds the database,
    # with read_errors: 0.2, read_error_codes: [0x0E] when other_errors.
    # Each cut is [where, mode]: where in 0..1000 places k among the
    # requests the Walk has left (0 the first of them, which for a resumed
    # Walk is its exchange; 1000 past them all), or is [:blob, where], the
    # first Read Blob the Walk has left and where when it has none, which
    # weights the cuts, the first above all, towards a pending value read,
    # the only way into the 7.19 re-read; mode is :drop or :timeout. The
    # resumed Server Rx MTU is nil to keep the fresh Walk's, and is mostly
    # one above 100, at which every value fits one Read Response. A plain
    # Array is not shrinkable in rantly, so a failing case is printed as
    # generated. The inputs under regressions once found a resumed Walk's
    # reported state differing from the plan's by the carried flag alone;
    # they run first.
    it "Property 15: a resumed Walk sends the exchange and then only the work left; the chain's results union to the uninterrupted Walk's" do
      walk_bound      = 10.0
      outcome_of      = { drop: :disconnected, timeout: :timeout }
      discovery_kinds = %i[primary secondary includes characteristics descriptors]
      full_plan       = BlueHydra::GattWalker::Plan.full
      # The ATT_MTU a Walk settles at for Server Rx MTU +rx+ (Requirement 5.7).
      att_mtu         = ->(rx) { [[rx, 517].min, 23].max }

      # Walks +db+ on a fresh peer sharing +clock+ at +server_rx+, cut as
      # +cut+ ([mode, k]: the Link dropping as request k is sent, or request
      # k's response never arriving) says, not at all for nil:
      # [peer, walker, report, deadline].
      run_walk = lambda do |db, clock, server_rx, read_all, plan, cut|
        served = FakeAttPeer.new(db, clock: clock, server_rx_mtu: server_rx)
        if cut
          mode, k = cut
          mode == :drop ? served.drop_link_after(k) : served.delay_response(k, Float::INFINITY)
        end
        deadline = clock.now + walk_bound
        walker   = served.build_walker(plan: plan, read_all: read_all, deadline: deadline)
        report   = walker.run
        expect(served.calls.map(&:name)).not_to include(:setsockopt)
        expect(served.violations).to be_empty
        [served, walker, report, deadline]
      end

      # The value handles the Read and Read Blob Requests among +requests+ name.
      read_handles = ->(requests) { reads_in(requests).map { |_kind, handle, _offset| handle } }

      # +state+ as a Walk resumed from it adopts it: a copy with every read
      # at an offset flagged carried (GattWalker#adopt_resume_state). A Walk
      # that answered nothing reports this, not the plan's state itself.
      as_adopted = lambda do |state|
        copy = state.deep_dup
        copy.reads.each { |task| task.carried = true if task.offset.positive? }
        copy
      end

      # The handle the Walk on +served+ re-read under Requirement 7.19, nil
      # for none: its first request after the exchange a Read Blob answered
      # 0x0B, the next a Read of the same handle. Only the head of the reads
      # can be carried, so a re-read happens nowhere else in a Walk.
      reread_on = lambda do |served, requests|
        kind, handle, _offset = requests[1]
        next nil unless kind == :read_blob && requests[2] == [:read, handle]
        response = response_to(1, served)
        response.is_a?(codec::ErrorResponse) && response.error_code == 0x0B ? handle : nil
      end

      seen = Hash.new(0)
      # Procs, because rantly instance_evals generators on itself.
      mtu = proc {
        freq([3, proc { 23 }], [2, proc { range(24, 100) }], [2, proc { range(101, 517) }],
             [1, proc { choose(0, 22, 518, 0xFFFF) }])
      }
      cut_mode  = proc { freq([3, proc { :drop }], [1, proc { :timeout }]) }
      cut_where = proc { freq([6, proc { range(0, 999) }], [1, proc { 0 }], [1, proc { 1000 }]) }
      # The first cut leans on the first Read Blob, the only way into a 7.19
      # re-read (a pending Read Blob in the fresh Walk's state); later cuts
      # less so.
      first_cut = proc { [freq([1, cut_where], [1, proc { [:blob, call(cut_where)] }]), call(cut_mode)] }
      cut       = proc { [freq([9, cut_where], [1, proc { [:blob, call(cut_where)] }]), call(cut_mode)] }
      resumed_mtu = proc { freq([1, proc { nil }], [2, proc { range(101, 517) }], [1, mtu]) }

      check_case = lambda do |seed, other_errors, server_rx, read_all, cuts, resumed_rx|
        options = { services: 0..8, chars: 0..6, descriptors: 0..2, values: 0..100 }
        options.merge!(read_errors: 0.2, read_error_codes: [0x0E]) if other_errors
        db    = GattDatabase.generate(seed, **options)
        clock = FakeClock.new

        full_peer, _, full, = run_walk.(db, clock, server_rx, read_all, full_plan, nil)
        full_requests = request_summaries(full_peer)
        expect(%i[complete partial]).to include(full.outcome)
        expect(full.state).to be_nil
        expect(full_requests.first).to eq(exchange)
        # Every request of the uninterrupted Walk is distinct, so "none R had
        # answered" below is a statement about requests, not positions.
        expect(full_requests.uniq.size).to eq(full_requests.size)

        reports   = []            # the interrupted Walks' reports, in order
        answered  = []            # requests answered so far across the chain, the fresh Walk's exchange first
        paged     = Set.new       # handles the pages delivered so far carried
        state     = nil           # the Resume_State the next Walk resumes from
        snapshot  = nil           # Marshal.dump(state) when it was reported
        reference = full_requests # the requests a Walk's are a slice of: R, then R' from the switch on
        p         = nil           # index in reference of the request still unanswered
        switched  = false         # whether reference is R'
        prefix    = nil           # the requests of R answered when the switch to R' was made
        rx        = server_rx     # the Server Rx MTU the next Walk's peer answers with
        rereads   = Set.new       # value handles re-read under Requirement 7.19 so far
        final_cut = nil           # a cut past the requests the final Walk has left

        # Once, at the first resumed Walk, when the resumed Server Rx MTU
        # settles another ATT_MTU: R' from a Walk resumed from state at it
        # and left uninterrupted, which must end as the uninterrupted Walk
        # did, with its result; p then indexes R' at its first request after
        # the exchange, and every later Walk is at the new MTU.
        switch_reference = lambda do
          next if switched || resumed_rx.nil? || att_mtu.(resumed_rx) == att_mtu.(server_rx)
          switched, prefix, rx = true, full_requests.first(p), resumed_rx
          served, _, report, = run_walk.(db, clock, rx, read_all, resume_plan(state), nil)
          reference = request_summaries(served)
          label = "R' Walk (resumed from R[#{p}] at Server Rx MTU #{rx})"
          expect(Marshal.dump(state)).to eq(snapshot), "#{label}: the plan's state changed"
          expect(report.outcome).to eq(full.outcome),
                                    "#{label}: outcome #{report.outcome.inspect}, uninterrupted #{full.outcome.inspect}"
          expect(report.state).to be_nil, label
          expect(result_of(report)).to eq(result_of(full)), "#{label}: result differs from the uninterrupted Walk's"
          expect(reference.first).to eq(exchange), label
          expect(reference.uniq.size).to eq(reference.size), label
          p = 1
          seen[:resumed_mtu_changed] += 1
        end

        # Records the Requirement 7.19 re-read the Walk on +served+ made, if
        # any, checking it was due: only on a resumed Walk at a larger
        # ATT_MTU than the fresh Walk's, of the state's head read with its
        # offset above 0, fewer octets collected than one part at this
        # ATT_MTU and no re-read used yet, and once per value.
        note_reread = lambda do |served, requests, label|
          handle = reread_on.(served, requests)
          next unless handle
          head = state&.reads&.first
          expect(switched).to be(true), "#{label}: re-read 0x#{format('%04x', handle)} with no change of Server Rx MTU"
          expect(att_mtu.(rx)).to be > att_mtu.(server_rx), "#{label}: re-read at an ATT_MTU no larger than the fresh Walk's"
          expect(head&.to_h).to include(handle: handle, restarted: false),
                                "#{label}: re-read 0x#{format('%04x', handle)}, the head read being #{head.inspect}"
          expect(head.offset).to be_positive, label
          expect(head.collected.bytesize).to be < att_mtu.(rx) - 1, label
          expect(rereads).not_to include(handle), "#{label}: 0x#{format('%04x', handle)} re-read a second time"
          rereads << handle
          seen[:carried_reread] += 1
        end

        # Requirement 17.3 across the chain: after the exchange no request
        # already answered is sent again, the one permitted repeat being the
        # Read Request of a Requirement 7.19 re-read.
        expect_no_repeat = lambda do |requests, label|
          repeated = (requests.drop(1) & answered) - rereads.map { |handle| [:read, handle] }
          expect(repeated).to be_empty, "#{label}: sent #{repeated.inspect} again"
        end

        cuts.each_with_index do |(where, mode), step|
          resumed = !p.nil?
          switch_reference.() if resumed
          # The requests this Walk has left after its exchange, and k among
          # them: where in 0..1000 scaled over them (a fresh Walk's exchange
          # is never the cut); for [:blob, where] the first Read Blob among
          # them, where when there is none.
          left_requests = resumed ? reference.drop(p) : full_requests.drop(1)
          left = left_requests.size
          blob_at = where.is_a?(Array) ? left_requests.index { |kind, *| kind == :read_blob } : nil
          where   = where.last if where.is_a?(Array)
          k =
            if blob_at then blob_at + 1
            elsif resumed then (where * (left + 1)) / 1000
            else 1 + (where * left) / 1000
            end
          if k > left
            final_cut = [mode, k]
            break
          end
          plan, sent = resumed ? [resume_plan(state), [exchange] + reference[p, k]] : [full_plan, full_requests.first(k + 1)]
          from  = resumed ? "resumed from #{switched ? "R'" : 'R'}[#{p}]" : 'fresh'
          label = "Walk #{step + 1} (#{from} at Server Rx MTU #{rx}, #{mode} at its request #{k})"

          served, walker, report, deadline = run_walk.(db, clock, rx, read_all, plan, [mode, k])
          requests = request_summaries(served)

          # Requirement 17.1: cut at request k, having sent exactly the
          # requests up to it, with its state and work outstanding.
          expect(report.outcome).to eq(outcome_of[mode]), "#{label}: outcome #{report.outcome.inspect}"
          expect(report.resumed).to be(resumed), label
          expect(requests).to eq(sent), "#{label}: sent #{requests.inspect}, expected #{sent.inspect}"
          lost = mode == :drop ? [false] * k + [true] : [false] * (k + 1)
          expect(served.requests.map(&:lost)).to eq(lost), label
          expect(response_to(k, served)).to be_nil, "#{label}: request #{k} was answered"
          expect(report.requests_sent).to eq(k + 1), label
          expect(report.state).to equal(walked_state(walker)), label
          expect(report.state.outstanding?).to be(true), label
          expect(report.outstanding).not_to eq(procedures: [], reads: []), label
          expect(report.ended_at).to be <= deadline, "#{label}: ended #{report.ended_at - deadline} s past Walk_Bound"
          expect_bearer_closed(walker, report, served)

          # Requirement 17.3: after the exchange, only requests not yet
          # answered (the 7.19 re-read aside), for handles no page had
          # delivered and values no read had finished, and no hash check.
          note_reread.(served, requests, label)
          expect_no_repeat.(requests, label)
          expect(handles_paged(served) & paged.to_a).to be_empty, "#{label}: paged handles already delivered"
          expect(requests.map(&:first)).not_to include(:hash), label
          if resumed
            expect(read_handles.(requests) & finished_reads(state)).to be_empty, "#{label}: read a finished value"
            # Requirement 17.2 and 17.5: the plan's state untouched, the
            # report's its own, with strictly less left when any request was
            # answered (its first request after the exchange being the lost
            # one again) and the same work when none was. The report's
            # state flags a pending Read Blob carried where the plan's does
            # not (GattWalker#adopt_resume_state marks the Walk's copy), so
            # the comparison is against the plan's state as adopted.
            expect(Marshal.dump(state)).to eq(snapshot), "#{label}: the plan's state changed"
            expect(report.state).not_to equal(state), label
            adopted = as_adopted.(state)
            if k >= 2
              expect(report.state).not_to eq(adopted), "#{label}: #{k - 1} answered, state unchanged"
            else
              expect(report.state).to eq(adopted), "#{label}: nothing answered, state changed"
              expect(report.outstanding).to eq(reports.last.outstanding), label
            end
            # Requirement 17.4: a resumed Walk reports all found so far.
            expect(union(reports.last, report)).to eq(result_of(report)), label
          end

          # The request still unanswered after this Walk: the one it lost,
          # or the same one when its exchange was.
          cut_at = resumed ? (k.zero? ? p : p + k - 1) : k
          seen[mode] += 1
          seen[resumed ? (k.zero? ? :exchange_lost : (k == 1 ? :no_progress : :progress)) : :fresh_cut] += 1
          if resumed && report.outstanding.values.sum(&:size) > reports.last.outstanding.values.sum(&:size)
            seen[:outstanding_count_grew] += 1 # procedures appended: the count is no measure of the work left
          end
          kind = reference[cut_at].first
          seen[discovery_kinds.include?(kind) ? :cut_at_discovery : :"cut_at_#{kind}"] += 1
          seen[:timeout_on_resumed] += 1 if mode == :timeout && resumed
          seen[:cut_at_first_blob_left] += 1 if blob_at
          seen[:restarted_read_carried_over] += 1 if report.state.reads.first&.restarted

          answered.concat(requests[(resumed ? 1 : 0)...-1])
          paged.merge(handles_paged(served))
          reports << report
          p        = cut_at
          state    = report.state
          snapshot = Marshal.dump(state)
        end

        if p.nil?
          # The fresh Walk's cut lies past its requests: it is the
          # uninterrupted Walk over again, and nothing is left to resume.
          served, walker, report, deadline = run_walk.(db, clock, server_rx, read_all, full_plan, final_cut)
          expect(report.outcome).to eq(full.outcome)
          expect(report.state).to be_nil
          expect(request_summaries(served)).to eq(full_requests)
          expect(result_of(report)).to eq(result_of(full))
          expect(report.ended_at).to be <= deadline
          expect_bearer_closed(walker, report, served)
          seen[:never_cut] += 1
        else
          # The last Walk, to the end (Requirements 17.3, 17.4, 17.7, 17.9).
          switch_reference.()
          label = "final Walk (resumed from #{switched ? "R'" : 'R'}[#{p}] at Server Rx MTU #{rx}" \
                  "#{final_cut ? ", #{final_cut.first} armed past its requests" : ''})"
          served, walker, report, deadline = run_walk.(db, clock, rx, read_all, resume_plan(state), final_cut)
          requests = request_summaries(served)
          worked   = walked_state(walker)

          expect(report.outcome).to eq(full.outcome),
                                    "#{label}: outcome #{report.outcome.inspect}, uninterrupted #{full.outcome.inspect}"
          expect(report.resumed).to be(true), label
          expect(report.state).to be_nil, label
          expect(report.outstanding).to eq(procedures: [], reads: []), label
          expect(requests).to eq([exchange] + reference.drop(p)), "#{label}: sent #{requests.inspect}"
          expect(requests.map(&:first)).not_to include(:hash), label
          expect(served.requests.map(&:lost)).to all(be(false)), label
          expect(report.requests_sent).to eq(requests.size), label
          expect(report.ended_at).to be <= deadline, "#{label}: ended #{report.ended_at - deadline} s past Walk_Bound"
          expect_bearer_closed(walker, report, served)
          expect(worked.outstanding?).to be(false), label
          expect(worked.partial).to be(full.outcome == :partial), label
          expect(Marshal.dump(state)).to eq(snapshot), "#{label}: the plan's state changed"

          note_reread.(served, requests, label)
          expect_no_repeat.(requests, label)
          expect(handles_paged(served) & paged.to_a).to be_empty, "#{label}: paged handles already delivered"
          expect(read_handles.(requests) & finished_reads(state)).to be_empty, "#{label}: read a finished value"
          answered.concat(requests.drop(1))
          # Every request of R (or of R up to the switch and R' after its
          # exchange) answered exactly once, the re-read Reads twice, and
          # nothing else.
          expected_answered = switched ? prefix + reference.drop(1) : full_requests
          expect(answered).to eq(expected_answered),
                              "#{label}: the chain answered #{answered.size} requests, expected #{expected_answered.size}"
          repeats = answered.tally.select { |_request, count| count > 1 }
          expect(repeats).to eq(rereads.to_h { |handle| [[:read, handle], 2] }),
                             "#{label}: answered more than once across the chain: #{repeats.inspect}"

          expect(union(*reports, report)).to eq(result_of(full)),
                                            "#{label}: the chain's union differs from the uninterrupted result"
          expect(result_of(report)).to eq(result_of(full)), "#{label}: result differs from the uninterrupted Walk's"
          expect(report.identity).to eq(full.identity), label
          expect(report.database_hash).to eq(full.database_hash), label
          expect(report.hash_changed).to be(false), label
          seen[:"interruptions_#{reports.size}"] += 1
          seen[:resumed_cut_past] += 1 if final_cut
          seen[switched ? :chain_mtu_changed : :chain_mtu_same] += 1
          seen[att_mtu.(rx) > att_mtu.(server_rx) ? :resumed_mtu_larger : :resumed_mtu_not_larger] += 1
        end

        seen[server_rx == 23 ? :mtu_23 : (server_rx.between?(24, 517) ? :negotiable : :out_of_range)] += 1
        seen[read_all ? :read_all : :identity_only] += 1
        seen[full.outcome] += 1
        seen[:empty_db] += 1 if db.services.empty?
        statuses = full.characteristics.map { |entry| entry[:read_status] }
        seen[:protected_read] += 1 if statuses.include?("protected")
        seen[:error_read] += 1 if statuses.include?("error")
        seen[:blob_in_walk] += 1 if full_requests.any? { |kind, *| kind == :read_blob }
      end

      regressions = [
        [1547971967, false, 23, true, [[849, :drop], [61, :drop]], nil],
        [1628955547, false, 23, true, [[989, :drop], [0, :drop]], nil]
      ]
      regressions.each { |input| check_case.(*input) }

      property_of {
        [range(0, GattDatabase::Generator::SEED_MAX), boolean, call(mtu), boolean,
         [call(first_cut)] + array(range(0, 2)) { call(cut) }, call(resumed_mtu)]
      }.check(200) { |input| check_case.(*input) }

      expect(seen.keys).to include(:drop, :timeout, :fresh_cut, :never_cut, :exchange_lost, :no_progress, :progress,
                                   :timeout_on_resumed, :outstanding_count_grew, :cut_at_discovery, :cut_at_read,
                                   :cut_at_read_blob, :resumed_cut_past, :interruptions_1, :interruptions_2,
                                   :interruptions_3, :mtu_23, :negotiable, :out_of_range, :read_all, :identity_only,
                                   :complete, :partial, :empty_db, :protected_read, :error_read, :blob_in_walk,
                                   :cut_at_first_blob_left, :resumed_mtu_changed, :chain_mtu_changed,
                                   :chain_mtu_same, :resumed_mtu_larger, :resumed_mtu_not_larger, :carried_reread)
    end
  end
end
