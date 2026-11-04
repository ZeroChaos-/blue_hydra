require 'spec_helper'
require 'blue_hydra/gatt_walker'
require_relative 'support/fake_att_peer'

# Self-check for the FakeAttPeer harness: the server is driven directly with
# AttCodec-encoded requests the way GattWalker::Bearer drives a socket (send,
# wait_readable, recv_nonblock), and the socket surface is checked against the
# real Bearer.
describe FakeAttPeer do
  let(:codec)    { BlueHydra::AttCodec }
  let(:clock)    { FakeClock.new }
  let(:sockaddr) { [BlueHydra::Mgmt::AF_BLUETOOTH, 0, "\x00".b * 6, 0x0004, 0x02].pack("S!S!a6S!C") }

  # Handles 0x0001..0x0012: four 16-bit primaries (the first and third with a
  # characteristic), a gap, a 128-bit primary, then a 16-bit primary to 0xFFFF.
  let(:services_db) do
    GattDatabase.build do
      primary(0x1800) { characteristic 0x2A00, value: "Name" }
      primary 0x1801
      primary(0x180A) { characteristic 0x2A29, value: "Acme" }
      primary 0x180F
      gap 8
      primary "0000fe95-0000-1000-8000-00805f9b34fb"
      primary 0x1812, end_at: 0xFFFF
    end
  end

  # A 40-octet value at 0x0003 and a 5-octet one at 0x0005.
  let(:values_db) do
    GattDatabase.build do
      primary 0x180A do
        characteristic 0x2A24, value: (1..40).to_a
        characteristic 0x2A25, value: "SN123"
      end
    end
  end

  # No example may reach a real socket, whatever the harness does.
  before { allow(Socket).to receive(:new).and_raise("FakeAttPeer specs must not open a real socket") }

  def connected(peer)
    peer.connect_nonblock(sockaddr)
    peer
  end

  def read_pdu(peer, timeout = 30)
    return :timeout unless peer.wait_readable(timeout)
    data = peer.recv_nonblock(672, exception: false)
    data.nil? ? :eof : codec.decode(data)
  end

  # One client transaction, as the Bearer runs it.
  def transact(peer, pdu, timeout: 30)
    peer.send(codec.encode(pdu), 0)
    read_pdu(peer, timeout)
  end

  def exchange(peer, client_rx = 517)
    transact(peer, codec::ExchangeMtuRequest.new(mtu: client_rx))
  end

  def group(start, type = 0x2800)
    codec::ReadByGroupTypeRequest.new(start_handle: start, end_handle: 0xFFFF, uuid: codec.uuid16(type))
  end

  def by_type(start, last, type)
    codec::ReadByTypeRequest.new(start_handle: start, end_handle: last, uuid: codec.uuid16(type))
  end

  def handles(response)
    response.entries.map(&:first)
  end

  describe "Exchange MTU" do
    it "answers the Server Rx MTU and settles ATT_MTU at the floor-23 minimum" do
      [[517, 517, 517], [517, 100, 100], [247, 517, 247], [10, 517, 23]].each do |server_rx, client_rx, mtu|
        peer = connected(FakeAttPeer.new(services_db, clock: clock, server_rx_mtu: server_rx))
        expect(exchange(peer, client_rx)).to eq(codec::ExchangeMtuResponse.new(mtu: server_rx))
        expect(peer.att_mtu).to eq(mtu)
      end
    end

    it "stays at 23 when the exchange is answered with an Error Response, and flags a second exchange" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock).answer_with_error(0, 0x06))
      expect(exchange(peer)).to eq(codec::ErrorResponse.new(request_opcode: 0x02, handle: 0, error_code: 0x06))
      expect(peer.att_mtu).to eq(23)

      exchange(peer)
      expect(peer.violations).to eq(["request 1: a second Exchange MTU Request on one bearer"])
    end
  end

  describe "paging" do
    it "fills a page to ATT_MTU 23 and never mixes UUID widths" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock))
      pages = [0x0001, 0x0009, 0x0012, 0x0013].map { |start| transact(peer, group(start)) }

      expect(pages[0].length).to eq(6)
      expect(pages[0].entries.map { |handle, last, _uuid| [handle, last] }).to eq([[1, 3], [4, 4], [5, 7]])
      # 0x0009 onwards: the 128-bit service alone, then the 16-bit one to 0xFFFF
      expect(pages[1].length).to eq(20)
      expect(pages[1].entries).to eq([[0x11, 0x11, codec::Uuid.new(bits: 128, hex: "0000fe9500001000800000805f9b34fb")]])
      expect(pages[2].entries).to eq([[0x12, 0xFFFF, codec.uuid16(0x1812)]])
      expect(pages[3]).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x13, error_code: 0x0A))
    end

    it "fits more of one width per page at ATT_MTU 517" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock))
      exchange(peer)
      expect(handles(transact(peer, group(0x0001)))).to eq([1, 4, 5, 8])
    end

    it "pages Read By Type and Find Information by value length and UUID width, truncating long values" do
      db = GattDatabase.build do
        primary 0x180A do
          characteristic 0x2A29, value: "A" * 30
          characteristic 0x2A24, value: "M"
          characteristic "0000aaaa-0000-1000-8000-00805f9b34fb", props: [:notify] do
            descriptor 0x2902, value: [0, 0]
            descriptor "0000bbbb-0000-1000-8000-00805f9b34fb"
          end
        end
      end
      peer = connected(FakeAttPeer.new(db, clock: clock))

      declarations = transact(peer, by_type(0x0001, 0xFFFF, 0x2803))
      expect([declarations.length, handles(declarations)]).to eq([7, [0x02, 0x04]])
      expect(handles(transact(peer, by_type(0x0005, 0xFFFF, 0x2803)))).to eq([0x06])

      long = transact(peer, by_type(0x0001, 0xFFFF, 0x2A29))
      expect(long.entries).to eq([[0x03, "A" * 19]]) # ATT_MTU - 4

      info = transact(peer, codec::FindInformationRequest.new(start_handle: 0x0008, end_handle: 0xFFFF))
      expect([info.format, info.entries]).to eq([0x01, [[0x08, codec.uuid16(0x2902)]]])
      info = transact(peer, codec::FindInformationRequest.new(start_handle: 0x0009, end_handle: 0xFFFF))
      expect([info.format, handles(info)]).to eq([0x02, [0x09]])
    end
  end

  it "answers 0x0A once nothing remains, and 0x0A for a database with no secondaries" do
    peer = connected(FakeAttPeer.new(services_db, clock: clock))
    expect(transact(peer, group(0x0001, 0x2801))).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 1, error_code: 0x0A))
    expect(transact(peer, codec::FindInformationRequest.new(start_handle: 0x0013, end_handle: 0xFFFF)))
      .to eq(codec::ErrorResponse.new(request_opcode: 0x04, handle: 0x13, error_code: 0x0A))
  end

  it "reads values with Read and Read Blob offsets, 0x07 past the end and 0x0B for a short value" do
    peer = connected(FakeAttPeer.new(values_db, clock: clock))
    value = (1..40).to_a.pack("C*")

    expect(transact(peer, codec::ReadRequest.new(handle: 0x0003)).value).to eq(value.byteslice(0, 22))
    expect(transact(peer, codec::ReadBlobRequest.new(handle: 0x0003, offset: 22)).value).to eq(value.byteslice(22..))
    expect(transact(peer, codec::ReadBlobRequest.new(handle: 0x0003, offset: 40)).value).to eq("")
    expect(transact(peer, codec::ReadBlobRequest.new(handle: 0x0003, offset: 41)))
      .to eq(codec::ErrorResponse.new(request_opcode: 0x0C, handle: 0x0003, error_code: 0x07))
    expect(transact(peer, codec::ReadBlobRequest.new(handle: 0x0005, offset: 1)))
      .to eq(codec::ErrorResponse.new(request_opcode: 0x0C, handle: 0x0005, error_code: 0x0B))

    lenient = connected(FakeAttPeer.new(values_db, clock: clock, attribute_not_long: false))
    expect(transact(lenient, codec::ReadBlobRequest.new(handle: 0x0005, offset: 1)).value).to eq("N123")
  end

  describe "scripted errors" do
    it "answers a chosen request, the first primary request and a protected attribute with their errors" do
      db = GattDatabase.build do
        primary 0x180A do
          characteristic 0x2A25, value: "SN", read_error: 0x05
          characteristic 0x2B2A, value: "\x00" * 16, read_error: 0x0F
        end
      end
      peer = connected(FakeAttPeer.new(db, clock: clock).answer_with_error(1, 0x0E).security_error_on_first_primary)

      exchange(peer)
      expect(transact(peer, by_type(0x0001, 0xFFFF, 0x2803)).error_code).to eq(0x0E)
      expect(transact(peer, group(0x0001))).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 1, error_code: 0x05))
      expect(transact(peer, group(0x0001)).entries.size).to eq(1) # only the first primary request
      expect(transact(peer, codec::ReadRequest.new(handle: 0x0003)).error_code).to eq(0x05)
      expect(transact(peer, by_type(0x0001, 0xFFFF, 0x2B2A)))
        .to eq(codec::ErrorResponse.new(request_opcode: 0x08, handle: 0x0005, error_code: 0x0F))
      expect(peer.requests.map(&:opcode)).to eq([0x02, 0x08, 0x10, 0x10, 0x0A, 0x08])
    end

    it "corrupts a page per mode" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock)
                         .corrupt_page(0, :handle_below_start).corrupt_page(1, :no_entries)
                         .corrupt_page(3, :non_advancing).corrupt_page(4, :wrong_opcode))
      expect(handles(transact(peer, group(0x0001)))).to eq([0, 4, 5])
      expect(transact(peer, group(0x0001))).to eq(codec::Malformed.new(opcode: 0x11, reason: :no_entries))
      expect(handles(transact(peer, group(0x0008)))).to eq([8])
      expect(handles(transact(peer, group(0x0009)))).to eq([8]) # the previous page again
      expect(transact(peer, group(0x0009))).to be_a(codec::ReadByTypeResponse).or be_a(codec::Malformed)
    end

    # Android's gatts_process_primary_service_req: 0x10 for any group type but
    # Primary Service, whatever the request's position or Starting Handle.
    it "answers every 0x2801 request with 0x10 Unsupported Group Type after reject_secondary_services!" do
      db = GattDatabase.build do
        primary 0x1800
        secondary 0x180F
      end
      peer = connected(FakeAttPeer.new(db, clock: clock).reject_secondary_services!)

      exchange(peer)
      expect(handles(transact(peer, group(0x0001)))).to eq([0x0001])
      expect(transact(peer, group(0x0001, 0x2801)))
        .to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x10))
      expect(transact(peer, group(0x0002, 0x2801)))
        .to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0002, error_code: 0x10))
      expect(transact(peer, group(0x0002))).to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0002, error_code: 0x0A))
      expect(peer.violations).to be_empty

      # Without the hook the same database pages its secondary service.
      plain = connected(FakeAttPeer.new(db, clock: clock))
      expect(handles(transact(plain, group(0x0001, 0x2801)))).to eq([0x0002])
    end
  end

  describe "link and timing scripts" do
    it "reports EOF once drop_link_after's responses have been read, and fails sends once EOF is seen" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock).drop_link_after(2))
      exchange(peer)
      transact(peer, group(0x0001))

      expect(transact(peer, group(0x0009))).to eq(:eof)
      expect(peer.requests.map(&:lost)).to eq([false, false, true])
      expect { peer.send(codec.encode(group(0x0009)), 0) }.to raise_error(Errno::ENOTCONN)
    end

    it "raises the raise_on_recv errno once, then reads EOF" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock).raise_on_recv(Errno::ECONNRESET, after: 1))
      exchange(peer)
      peer.send(codec.encode(group(0x0001)), 0)
      expect(peer.wait_readable(30)).to be_truthy
      expect { peer.recv_nonblock(672, exception: false) }.to raise_error(Errno::ECONNRESET)
      expect(peer.recv_nonblock(672, exception: false)).to be_nil
    end

    it "runs delays on the fake clock: an expired wait moves the clock by its whole timeout" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock).delay_response(0, 31))
      start = clock.now
      peer.send(codec.encode(codec::ExchangeMtuRequest.new(mtu: 517)), 0)

      expect(peer.wait_readable(0)).to be_nil
      expect(peer.wait_readable(30)).to be_nil
      expect(clock.now - start).to eq(30)
      expect(peer.wait_readable(5)).to be_truthy
      expect(clock.now - start).to eq(31)
      expect(peer.waits.map(&:timeout)).to eq([0, 30, 5])
    end

    it "delivers an injected peer PDU ahead of the response and records the walker's reply" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock)
                         .inject_peer_pdu(codec::ExchangeMtuRequest.new(mtu: 100), before_request: 0)
                         .inject_peer_pdu("\x1D\x03\x00\x01".b, before_request: 1))
      peer.send(codec.encode(codec::ExchangeMtuRequest.new(mtu: 517)), 0)

      expect(read_pdu(peer)).to eq(codec::ExchangeMtuRequest.new(mtu: 100))
      peer.send(codec.encode(codec::ExchangeMtuResponse.new(mtu: 517)), 0)
      expect(read_pdu(peer)).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
      expect(peer.att_mtu).to eq(100)

      peer.send(codec.encode(group(0x0001)), 0)
      expect(read_pdu(peer)).to eq(codec::HandleValueIndication.new(handle: 3, value: "\x01".b))
      peer.send(codec.encode(codec::HandleValueConfirmation.new), 0)
      expect(read_pdu(peer)).to be_a(codec::ReadByGroupTypeResponse)

      expect(peer.peer_received.map(&:opcode)).to eq([0x03, 0x1E])
      expect(peer.injections.map { |injection| injection.reply&.opcode }).to eq([0x03, 0x1E])
      expect(peer.requests.map(&:opcode)).to eq([0x02, 0x10])
      expect(peer.violations).to be_empty

      peer.send(codec.encode(codec::HandleValueConfirmation.new), 0)
      expect(peer.violations).to eq(["unsolicited reply 0x1e: no injected indication awaits one"])
    end

    # A Multiple Handle Value Notification (0x23) is owed nothing, like 0x1B.
    # Were it filed as awaiting a :request reply, the Error Response the
    # walker sends to a later injected request would be credited to it, and
    # that request would look unanswered.
    it "owes no reply to an injected 0x23 and does not let it absorb the reply to a later peer request" do
      peer = connected(FakeAttPeer.new(services_db, clock: clock)
                         .inject_peer_pdu("\x23\x03\x00\x01\x00\x41".b, before_request: 0)
                         .inject_peer_pdu(codec::ReadRequest.new(handle: 0x0003), before_request: 1))
      notification, read_request = peer.injections

      peer.send(codec.encode(codec::ExchangeMtuRequest.new(mtu: 517)), 0)
      expect(read_pdu(peer)).to be_a(codec::Malformed)
      expect(read_pdu(peer)).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
      expect(notification.delivered_at).not_to be_nil

      peer.send(codec.encode(group(0x0001)), 0)
      expect(read_pdu(peer)).to eq(codec::ReadRequest.new(handle: 0x0003))
      not_supported = codec::ErrorResponse.new(request_opcode: 0x0A, handle: 0x0000, error_code: 0x06)
      peer.send(codec.encode(not_supported), 0)
      expect(read_pdu(peer)).to be_a(codec::ReadByGroupTypeResponse)

      expect(notification.reply).to be_nil
      expect(read_request.reply).to eq(peer.peer_received.first)
      expect(read_request.reply.pdu).to eq(not_supported)
      expect(peer.peer_received.map(&:opcode)).to eq([0x01])
      expect(peer.violations).to be_empty

      # With nothing left awaiting one, a further Error Response is unsolicited.
      peer.send(codec.encode(not_supported), 0)
      expect(peer.violations).to eq(["unsolicited reply 0x01: no injected request awaits one"])
    end
  end

  describe "with the real GattWalker::Bearer" do
    let(:peer)   { FakeAttPeer.new(services_db, clock: clock) }
    let(:bearer) { BlueHydra::GattWalker::Bearer.new(peer, local_address: "00:11:22:33:44:55") }

    def connect_with(outcome, **options)
      peer.connect_outcome(outcome, **options)
      bearer.bind
      bearer.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM, 1.0)
    end

    it "binds then connects with the ATT CID and reads one PDU per recv" do
      expect(connect_with(:immediate)).to eq(:connected)
      expect(peer.calls.map(&:name)).to eq(%i[bind connect_nonblock])
      expect(peer.bound_sockaddr).to include(psm: 0, cid: 0x0004, address: "00:11:22:33:44:55", address_type: 0x01)
      expect(peer.connected_sockaddr).to include(cid: 0x0004, address: "7A:BB:CC:DD:EE:FF", address_type: 0x02)

      expect(bearer.send_pdu(codec.encode(codec::ExchangeMtuRequest.new(mtu: 517)))).to eq(:ok)
      expect(codec.decode(bearer.recv_pdu(30))).to eq(codec::ExchangeMtuResponse.new(mtu: 517))
      expect(bearer.recv_pdu(30)).to eq(:timeout)
    end

    it "classifies EBUSY raised by connect_nonblock as busy" do
      expect(connect_with(Errno::EBUSY)).to eq(:busy)
    end

    it "classifies a non-EBUSY errno as error" do
      expect(connect_with(Errno::EINVAL)).to eq(:error)
    end

    it "reads a pending connect's result from SO_ERROR once" do
      start = clock.now
      expect(connect_with(:pending, after: 0.05)).to eq(:connected)
      expect(clock.now - start).to be_within(1e-9).of(0.05)
      expect(peer.calls.map(&:name)).to eq(%i[bind connect_nonblock getsockopt])
    end

    it "reports a pending connect that fails as the SO_ERROR errno says" do
      expect(connect_with(:pending, so_error: Errno::ECONNRESET)).to eq(:disconnected)
    end

    it "lets a never-completing connect run out the connect wait on the fake clock" do
      start = clock.now
      expect(connect_with(:never)).to eq(:disconnected)
      expect(clock.now - start).to eq(1.0)
    end

    it "turns EOF and a closed socket into disconnected" do
      peer.drop_link_after(0)
      connect_with(:immediate)
      bearer.send_pdu(codec.encode(codec::ExchangeMtuRequest.new(mtu: 517)))
      expect(bearer.recv_pdu(30)).to eq(:disconnected)

      bearer.close
      expect(bearer.closed?).to be(true)
      expect(bearer.send_pdu("\x02\x05\x02".b)).to eq(:disconnected)
      expect(bearer.recv_pdu(30)).to eq(:disconnected)
    end
  end

  it "installs itself as a walker's socket" do
    peer   = FakeAttPeer.new(services_db, clock: clock)
    walker = peer.build_walker(read_all: false)
    expect(walker.__send__(:open_socket)).to be(peer)
    expect(peer.open_count).to eq(1)
  end

  it "builds ascending handles with gaps and both include forms" do
    db = GattDatabase.build do
      primary 0x1800, at: 0x0010 do
        include_service :battery
        include_service :vendor
        include_range 0x0200, 0x0204
        characteristic 0x2A00, value: "Name"
      end
      secondary 0x180F, name: :battery, at: 0x0020, end_at: 0x0024
      secondary "0000fe95-0000-1000-8000-00805f9b34fb", name: :vendor
    end
    includes = db.services.first.includes

    expect(db.services.map { |service| [service.start, service.end] }).to eq([[0x10, 0x15], [0x20, 0x24], [0x25, 0x25]])
    expect(includes.map { |include| db.attribute(include.handle).value.bytesize }).to eq([6, 4, 4])
    expect(includes.map { |include| db.resolved_include_uuid(include)&.hex })
      .to eq(["180f", "0000fe9500001000800000805f9b34fb", nil])

    peer = connected(FakeAttPeer.new(db, clock: clock))
    expect(transact(peer, by_type(0x0010, 0x0015, 0x2802)).entries).to eq([[0x11, [0x20, 0x24, 0x180F].pack("S<S<S<")]])
    expect(handles(transact(peer, by_type(0x0012, 0x0015, 0x2802)))).to eq([0x12, 0x13])
  end

  describe "GattDatabase.generate" do
    let(:generator) { GattDatabase::Generator }

    def identity?(uuid)
      uuid.bits == 16 && generator::IDENTITY_UUIDS.include?(uuid.hex.to_i(16))
    end

    # Pages one discovery procedure to its end the way Requirements 6.4 and
    # 6.12 describe (an Error Response in +ended_by+, 0x0A by default, or a
    # page reaching +last+; otherwise continue at the page's last handle + 1)
    # and returns every entry.
    def page_through(peer, first, last, ended_by: [0x0A])
      entries = []
      start   = first
      loop do
        response = transact(peer, yield(start))
        break if response.is_a?(codec::ErrorResponse) && ended_by.include?(response.error_code)
        raise "not a discovery page: #{response.inspect}" unless response.respond_to?(:entries)
        entries.concat(response.entries)
        reached = response.is_a?(codec::ReadByGroupTypeResponse) ? response.entries.last[1] : response.entries.last[0]
        break if reached >= last
        start = reached + 1
      end
      entries
    end

    # A minimal full discovery over the fake server, in expected_discovery's
    # shape: services, then each service's includes and characteristics, then
    # each characteristic's descriptor range. 0x10 ends the 0x2801 sweep as
    # Requirement 6.4 has it, so a reject_secondary? database discovers too.
    def discover(peer)
      services = { primary: 0x2800, secondary: 0x2801 }.flat_map do |type, uuid16|
        ended_by = type == :secondary ? [0x0A, 0x10] : [0x0A]
        page_through(peer, 0x0001, 0xFFFF, ended_by: ended_by) { |start| group(start, uuid16) }
          .map { |handle, last, uuid| { type: type, uuid: uuid, start: handle, end: last } }
      end.sort_by { |service| service[:start] }

      characteristics = services.each_with_index.flat_map do |service, index|
        first, last = service.values_at(:start, :end)
        service[:includes] = page_through(peer, first, last) { |start| by_type(start, last, 0x2802) }.map do |_handle, value|
          include = codec.decode_include_declaration(value)
          uuid = include.uuid || services.find { |other| other[:start] == include.start_handle }&.fetch(:uuid)
          { start: include.start_handle, end: include.end_handle, uuid: uuid }
        end
        found = page_through(peer, first, last) { |start| by_type(start, last, 0x2803) }.map do |handle, value|
          declaration = codec.decode_characteristic_declaration(value)
          { service_index: index, decl_handle: handle, value_handle: declaration.value_handle,
            properties: declaration.properties, uuid: declaration.uuid }
        end
        found.each_with_index do |char, position|
          range_end = position + 1 < found.size ? found[position + 1][:decl_handle] - 1 : last
          char[:descriptors] =
            if char[:value_handle] < range_end
              page_through(peer, char[:value_handle] + 1, range_end) do |start|
                codec::FindInformationRequest.new(start_handle: start, end_handle: range_end)
              end.map { |handle, uuid| { handle: handle, uuid: uuid } }
            else
              []
            end
        end
      end
      { services: services, characteristics: characteristics }
    end

    it "is deterministic for a seed, and its inspect is the one-line call that reproduces it" do
      db = GattDatabase.generate(1234)
      expect(GattDatabase.generate(1234).services).to eq(db.services)
      expect(GattDatabase.generate(Random.new(1234)).services).to eq(db.services)
      expect(GattDatabase.generate(1235).services).not_to eq(db.services)

      expect(db.inspect).to start_with("#<GattDatabase GattDatabase.generate(1234) services=")
      expect(db.to_s).to eq(db.inspect)
      expect(GattDatabase.generate(Random.new(1)).inspect).to start_with("#<GattDatabase GattDatabase.generate(<Random>)")

      largest = GattDatabase.generate(7, services: 32, chars: 16, descriptors: 4, values: 600)
      expect(largest.inspect).to start_with("#<GattDatabase GattDatabase.generate(7, services: 32, chars: 16, descriptors: 4, values: 600) ")
      expect(largest.inspect).not_to include("\n")
      expect(largest.inspect.size).to be < 250
      expect(largest.summary.lines.size).to eq(1 + 32 + largest.services.sum { |s| s.includes.size } + 512)
    end

    it "hands its Structs to GattDatabase.new, which validates them" do
      expect(GattDatabase).to receive(:new).once.and_call_original
      db = GattDatabase.generate(99)
      expect(db).to be_a(GattDatabase)
      expect(db.generated_by).to eq("GattDatabase.generate(99)")
      expect(db.services).to all(be_a(GattDatabase::Service))
    end

    it "keeps handles strictly ascending inside 0x0001..0xFFFF and every count within its bounds" do
      # property_of instance_evals its block on a Rantly, so lets are out of reach there.
      property_of { range(0, GattDatabase::Generator::SEED_MAX) }.check(100) do |seed|
        db = GattDatabase.generate(seed)
        handles = db.attributes.map(&:handle)
        expect(handles.each_cons(2).all? { |a, b| b > a }).to be(true)
        expect(handles).to all(be_between(0x0001, 0xFFFF))
        expect(db.services.size).to be <= 32
        db.services.each do |service|
          expect(service.characteristics.size).to be <= 16
          expect(service.includes.size).to be <= 3
          service.includes.each { |include| expect([include.start, include.end]).to all(be_between(0x0001, 0xFFFF)) }
        end
        db.characteristics.each do |char|
          expect(char.value_handle).to eq(char.decl_handle + 1)
          expect(char.descriptors.size).to be <= 4
          expect(char.value.bytesize).to be <= 600
          expect(generator::RESERVED.cover?(char.uuid.hex.to_i(16)) && char.uuid.bits == 16).to be(false)
        end
        db.descriptors.each do |descriptor|
          uuid16 = descriptor.uuid.bits == 16 ? descriptor.uuid.hex.to_i(16) : nil
          expect(uuid16 && ((0x2800..0x28FF).cover?(uuid16) || generator::IDENTITY_UUIDS.include?(uuid16))).to be_falsey
          expect(descriptor.value.bytesize).to eq(7) if uuid16 == 0x2904
        end
      end
    end

    it "covers both include forms, unresolved includes, the Identity_Set and the value shapes across seeds" do
      seen = Hash.new(0)
      (0...40).each do |seed|
        db = GattDatabase.generate(seed)
        db.services.each do |service|
          seen[service.type] += 1
          service.includes.each do |include|
            seen[:"include_#{db.attribute(include.handle).value.bytesize}_octets"] += 1
            resolved = db.resolved_include_uuid(include)
            seen[:include_unresolved] += 1 if resolved.nil?
            seen[:include_4_octets_resolved] += 1 if resolved && db.attribute(include.handle).value.bytesize == 4
          end
        end
        identity = db.services.flat_map { |s| s.characteristics.select { |c| identity?(c.uuid) }.map { |c| [c.uuid, s.start] } }
        seen[:identity_across_services] += 1 if identity.group_by(&:first).any? { |_uuid, at| at.map(&:last).uniq.size > 1 }
        db.characteristics.each do |char|
          seen[:"uuid#{char.uuid.bits}"] += 1
          seen[char.properties.anybits?(0x02) ? :readable : :not_readable] += 1
          seen[:value_over_512] += 1 if char.value.bytesize > 512
          seen[:read_error] += 1 if char.read_error
          fixed = identity?(char.uuid) ? generator::IDENTITY_LENGTHS[char.uuid.hex.to_i(16)] : nil
          seen[char.value.bytesize == fixed ? :identity_right_length : :identity_wrong_length] += 1 if fixed
          char.descriptors.each { |d| seen[:"descriptor_#{d.uuid.hex}"] += 1 if %w[2902 2904].include?(d.uuid.hex) }
        end
      end

      expect(seen.keys).to include(:primary, :secondary, :include_6_octets, :include_4_octets, :include_unresolved,
                                   :include_4_octets_resolved, :identity_across_services, :uuid16, :uuid128, :readable,
                                   :not_readable, :value_over_512, :read_error, :identity_right_length,
                                   :identity_wrong_length, :descriptor_2902, :descriptor_2904)
    end

    it "honours end_at_ffff" do
      ends = (0...30).map { |seed| GattDatabase.generate(seed, end_at_ffff: true) }
      expect(ends.map { |db| db.services.last.end }.uniq).to eq([0xFFFF])
      expect(ends.count { |db| db.attributes.last.handle == 0xFFFF }).to be_between(1, 29)

      below = (0...30).map { |seed| GattDatabase.generate(seed, end_at_ffff: false) }
      expect(below.flat_map { |db| db.services.map(&:end) + db.attributes.map(&:handle) }).to all(be < 0xFFFF)

      either = (0...30).map { |seed| GattDatabase.generate(seed).services.last&.end == 0xFFFF }
      expect(either.uniq.sort_by(&:to_s)).to eq([false, true])

      expect(GattDatabase.generate(1, services: 0, end_at_ffff: false).services).to be_empty
      expect { GattDatabase.generate(1, services: 0, end_at_ffff: true) }.to raise_error(ArgumentError, /needs a service/)
    end

    it "honours reject_secondary" do
      # A seed whose database has a 4-octet include of a secondary service,
      # the one include form a refused sweep leaves unresolved.
      seed = (0..).find do |candidate|
        db = GattDatabase.generate(candidate, services: 8..32)
        db.services.any? do |owner|
          owner.type == :primary && owner.includes.any? do |include|
            db.attribute(include.handle).value.bytesize == 4 &&
              db.services.any? { |service| service.type == :secondary && service.start == include.start }
          end
        end
      end
      refused = GattDatabase.generate(seed, services: 8..32, reject_secondary: true)
      served  = GattDatabase.generate(seed, services: 8..32)

      # The flag draws nothing: the same seed gives the same services, and
      # the secondaries stay in the database.
      expect(refused.services).to eq(served.services)
      expect(refused.services.map(&:type)).to include(:secondary)
      expect([refused.reject_secondary?, served.reject_secondary?]).to eq([true, false])
      expect(refused.inspect).to start_with("#<GattDatabase GattDatabase.generate(#{seed}, services: 8..32, reject_secondary: true) ")
      expect(served.inspect).not_to include("reject_secondary")

      # discovered_services, expected_discovery and resolved_include_uuid see
      # the primaries alone: service_index counts them, a 4-octet include of
      # a secondary has no UUID, every other include is as before.
      primaries = served.services.select { |service| service.type == :primary }
      expect(served.discovered_services).to eq(served.services)
      expect(refused.discovered_services).to eq(primaries)
      expected = refused.expected_discovery
      expect(expected[:services].map { |service| service.values_at(:type, :start) }).to eq(primaries.map { |s| [:primary, s.start] })
      expected[:services].zip(primaries).each do |found, service|
        found[:includes].zip(service.includes).each do |found_include, include|
          target = served.services.find { |other| other.start == include.start }
          wanted = if served.attribute(include.handle).value.bytesize == 6 then include.uuid
                   elsif target&.type == :primary then target.uuid
                   end
          expect(found_include[:uuid]).to eq(wanted)
          expect(refused.resolved_include_uuid(include)).to eq(wanted)
        end
      end
      expect(expected[:characteristics].map { |char| [primaries[char[:service_index]].start, char[:decl_handle]] })
        .to eq(primaries.flat_map { |service| service.characteristics.map { |char| [service.start, char.decl_handle] } })
      unresolved = expected[:services].flat_map { |service| service[:includes] }.count { |include| include[:uuid].nil? } -
                   served.expected_discovery[:services].select { |s| s[:type] == :primary }
                         .flat_map { |service| service[:includes] }.count { |include| include[:uuid].nil? }
      expect(unresolved).to be >= 1

      # A peer built on the database refuses the sweep by construction and
      # serves exactly what expected_discovery describes.
      peer = connected(FakeAttPeer.new(refused, clock: clock))
      exchange(peer)
      expect(discover(peer)).to eq(expected)
      secondaries = peer.requests.select do |request|
        request.pdu.is_a?(codec::ReadByGroupTypeRequest) && GattDatabase.same_uuid?(request.pdu.uuid, GattDatabase::SECONDARY_SERVICE)
      end
      expect(secondaries.size).to eq(1)
      expect(codec.decode(peer.delivered.find { |pdu| pdu.request_index == secondaries.first.index }.raw))
        .to eq(codec::ErrorResponse.new(request_opcode: 0x10, handle: 0x0001, error_code: 0x10))
      expect(peer.violations).to be_empty

      expect { GattDatabase.generate(1, reject_secondary: :random) }.to raise_error(ArgumentError, /reject_secondary/)
    end

    it "cuts counts the 16-bit handle space cannot hold instead of overflowing it" do
      db = GattDatabase.generate(5, services: 12, chars: 1000, descriptors: 4, values: 0, read_errors: 0, end_at_ffff: false)
      expect(db.attributes.size).to be > 0xF000
      expect(db.attributes.last.handle).to be <= 0xFFFE
      expect(db.characteristics.size).to be < 12 * 1000
    end

    it "answers a full discovery through the fake server exactly as expected_discovery describes" do
      top = (0..).lazy.map { |seed| GattDatabase.generate(seed, end_at_ffff: true) }.find { |db| db.attributes.last.handle == 0xFFFF }
      databases = [GattDatabase.generate(0, services: 4..32), GattDatabase.generate(1),
                   GattDatabase.generate(2, services: 32, chars: 16), top, GattDatabase.generate(3, services: 0)]

      databases.product([23, 517]).each do |db, mtu|
        peer = connected(FakeAttPeer.new(db, clock: clock))
        exchange(peer) if mtu == 517
        expect(peer.att_mtu).to eq(mtu)
        expect(discover(peer)).to eq(db.expected_discovery), "#{db.inspect} at ATT_MTU #{mtu}"
        expect(peer.violations).to be_empty
      end

      roles = []
      rendered = databases.first.expected_discovery do |role, uuid|
        roles << role
        GattDatabase.uuid_text(uuid)
      end
      expect(roles.uniq.sort).to eq(%i[characteristic descriptor service])
      expect(rendered[:services].map { |service| service[:uuid] })
        .to eq(databases.first.services.map { |service| GattDatabase.uuid_text(service.uuid) })
    end
  end
end
