require 'spec_helper'
require 'timeout'

describe BlueHydra::Mgmt do
  describe "packet framing (pure helpers)" do
    it "encodes a packet as a 6 byte little-endian header plus params" do
      params = [0x07].pack("C")
      packet = BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::CMD_START_DISCOVERY, 0, params)

      # opcode 0x0023, index 0x0000, param length 0x0001, then the param byte
      expect(packet.bytes).to eq([0x23, 0x00, 0x00, 0x00, 0x01, 0x00, 0x07])
    end

    it "round-trips through decode_packet" do
      params = [0x01].pack("C")
      packet = BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::CMD_STOP_DISCOVERY, 2, params)
      opcode, index, decoded = BlueHydra::Mgmt.decode_packet(packet)

      expect(opcode).to eq(BlueHydra::Mgmt::CMD_STOP_DISCOVERY)
      expect(index).to eq(2)
      expect(decoded.b).to eq(params.b)
    end

    it "extracts [command_opcode, status] from command result params" do
      params  = [BlueHydra::Mgmt::CMD_START_DISCOVERY, BlueHydra::Mgmt::STATUS_SUCCESS].pack("S<C")
      command, status = BlueHydra::Mgmt.command_result(params)

      expect(command).to eq(BlueHydra::Mgmt::CMD_START_DISCOVERY)
      expect(status).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
    end

    it "parses a little-endian BD_ADDR into an uppercase MAC" do
      le = [0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA].pack("C*")
      expect(BlueHydra::Mgmt.parse_address(le)).to eq("AA:BB:CC:DD:EE:FF")
    end

    it "returns nil for a wrong-size address" do
      expect(BlueHydra::Mgmt.parse_address("\x01\x02")).to be_nil
      expect(BlueHydra::Mgmt.parse_address(nil)).to be_nil
    end

    it "packs a MAC into little-endian and round-trips with parse_address" do
      packed = BlueHydra::Mgmt.pack_address("AA:BB:CC:DD:EE:FF")
      expect(packed.bytes).to eq([0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA])
      expect(BlueHydra::Mgmt.parse_address(packed)).to eq("AA:BB:CC:DD:EE:FF")
    end
  end

  # These exercise the real command path: the Mgmt reader thread reads replies
  # off the socket and hands them back to the (blocking) command caller. We
  # simulate the kernel end with a small responder thread that reads each issued
  # command and replies with a Command Complete for that command's opcode.
  describe "commands over an injected socket (async reader thread)" do
    let(:pair)   { Socket.pair(:UNIX, :SOCK_DGRAM, 0) }
    let(:ours)   { pair[0] }
    let(:kernel) { pair[1] }
    let(:mgmt)   { BlueHydra::Mgmt.new(0, socket: ours) }

    after do
      mgmt.close rescue nil
      @kernel_thread&.kill
    end

    # Reply to +replies.size+ commands read from the +k+ end. Each reply is a
    # hash {status:, extra: ""}. Records received commands in @received.
    def serve_on(k, *replies)
      @received = []
      @kernel_thread = Thread.new do
        replies.each do |reply|
          packet = k.recv(4096)
          opcode, _index, params = BlueHydra::Mgmt.decode_packet(packet)
          @received << { opcode: opcode, params: params }
          body = [opcode, reply.fetch(:status)].pack("S<C") + (reply[:extra] || "").b
          k.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_CMD_COMPLETE, 0, body), 0)
        end
      end
    end

    def serve(*replies)
      serve_on(kernel, *replies)
    end

    it "start_discovery sends the start opcode and returns the reply status" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)

      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)

      @kernel_thread.join(2)
      expect(@received.first[:opcode]).to eq(BlueHydra::Mgmt::CMD_START_DISCOVERY)
      expect(@received.first[:params].bytes).to eq([BlueHydra::Mgmt::ADDR_TYPE_ALL])
    end

    it "stop_discovery returns the reply status" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt.stop_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
    end

    it "set_powered returns the reply status" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt.set_powered(true)).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
    end

    it "add_device sends Add Device with packed address, type and auto-connect action" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)

      expect(mgmt.add_device("AA:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM))
        .to eq(BlueHydra::Mgmt::STATUS_SUCCESS)

      @kernel_thread.join(2)
      expect(@received.first[:opcode]).to eq(BlueHydra::Mgmt::CMD_ADD_DEVICE)
      expect(@received.first[:params][0, 6]).to eq(BlueHydra::Mgmt.pack_address("AA:BB:CC:DD:EE:FF"))
      expect(@received.first[:params].bytes[6, 2])
        .to eq([BlueHydra::Mgmt::LE_RANDOM, BlueHydra::Mgmt::ACTION_AUTO_CONNECT])
    end

    it "remove_device sends Remove Device with packed address and type" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)

      expect(mgmt.remove_device("AA:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_PUBLIC))
        .to eq(BlueHydra::Mgmt::STATUS_SUCCESS)

      @kernel_thread.join(2)
      expect(@received.first[:opcode]).to eq(BlueHydra::Mgmt::CMD_REMOVE_DEVICE)
      expect(@received.first[:params].bytes[6]).to eq(BlueHydra::Mgmt::LE_PUBLIC)
    end

    it "set_bondable sends Set Bondable with the flag byte" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt.set_bondable(false)).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      @kernel_thread.join(2)
      expect(@received.first[:opcode]).to eq(BlueHydra::Mgmt::CMD_SET_BONDABLE)
      expect(@received.first[:params].bytes).to eq([0x00])
    end

    it "set_io_capability sends Set IO Capability with NoInputNoOutput" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt.set_io_capability).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      @kernel_thread.join(2)
      expect(@received.first[:opcode]).to eq(BlueHydra::Mgmt::CMD_SET_IO_CAPABILITY)
      expect(@received.first[:params].bytes).to eq([BlueHydra::Mgmt::IO_CAP_NO_INPUT_NO_OUTPUT])
    end

    it "read_address returns the adapter MAC on success" do
      info = [0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA].pack("C*") + ("\x00" * 20)
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS, extra: info)

      expect(mgmt.read_address).to eq("AA:BB:CC:DD:EE:FF")
    end

    it "read_address returns nil when the controller info read is unsuccessful" do
      # STATUS_BUSY is not a not-ready status, so it comes back as a plain
      # unsuccessful result rather than triggering rfkill recovery
      serve(status: BlueHydra::Mgmt::STATUS_BUSY, extra: "\x00" * 6)
      expect(mgmt.read_address).to be_nil
    end

    it "recovers via rfkill and retries when the controller reports not-ready" do
      allow(mgmt).to receive(:rfkill_recover).and_return(true)
      serve({ status: BlueHydra::Mgmt::STATUS_NOT_POWERED },
            { status: BlueHydra::Mgmt::STATUS_SUCCESS })

      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt).to have_received(:rfkill_recover).once

      @kernel_thread.join(2)
      expect(@received.map { |r| r[:opcode] })
        .to eq([BlueHydra::Mgmt::CMD_START_DISCOVERY, BlueHydra::Mgmt::CMD_START_DISCOVERY])
    end

    it "raises BluezNotReadyError when rfkill recovery fails" do
      allow(mgmt).to receive(:rfkill_recover).and_return(false)
      serve(status: BlueHydra::Mgmt::STATUS_RFKILLED)

      expect { mgmt.start_discovery }.to raise_error(BluezNotReadyError)
    end

    it "raises BluezNotReadyError when the controller stays not-ready after recovery" do
      allow(mgmt).to receive(:rfkill_recover).and_return(true)
      serve({ status: BlueHydra::Mgmt::STATUS_NOT_POWERED },
            { status: BlueHydra::Mgmt::STATUS_NOT_POWERED })

      expect { mgmt.start_discovery }.to raise_error(BluezNotReadyError)
    end

    it "reopens the control socket if it is found closed before a command" do
      new_ours, new_kernel = Socket.pair(:UNIX, :SOCK_DGRAM, 0)
      allow(mgmt).to receive(:open_socket).and_return(new_ours)
      ours.close # simulate the socket having closed unexpectedly
      serve_on(new_kernel, status: BlueHydra::Mgmt::STATUS_SUCCESS)

      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt).to have_received(:open_socket)
    end

    it "emits one event and raises MgmtSocketError if the socket error persists" do
      allow(mgmt).to receive(:open_socket).and_return(ours)
      allow(mgmt).to receive(:send_command).and_raise(IOError.new("closed stream"))
      expect(BlueHydra).to receive(:send_event).once.with(
        'blue_hydra', hash_including(key: 'blue_hydra_mgmt_socket_error', severity: 'ERROR')
      )

      expect { mgmt.stop_discovery }.to raise_error(MgmtSocketError)
    end

    it "ignores unrelated events while waiting for the matching completion" do
      @kernel_thread = Thread.new do
        opcode, _i, _p = BlueHydra::Mgmt.decode_packet(kernel.recv(4096))
        # an unrelated event (Device Found-ish)
        kernel.send(BlueHydra::Mgmt.encode_packet(0x0012, 0, "\x00\x01\x02".b), 0)
        # a Command Status for a DIFFERENT opcode
        other = [BlueHydra::Mgmt::CMD_STOP_DISCOVERY, BlueHydra::Mgmt::STATUS_SUCCESS].pack("S<C")
        kernel.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_CMD_STATUS, 0, other), 0)
        # then the real completion for the command we actually issued
        body = [opcode, BlueHydra::Mgmt::STATUS_SUCCESS].pack("S<C")
        kernel.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_CMD_COMPLETE, 0, body), 0)
      end

      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
    end

    it "re-issues start discovery when the kernel reports discovery stopped" do
      serve(status: BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      @kernel_thread.join(2)

      # kernel signals discovery wound down (Discovering, state = off)
      off = [BlueHydra::Mgmt::ADDR_TYPE_ALL, 0].pack("CC")
      kernel.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_DISCOVERING, 0, off), 0)

      # the reader thread should re-send Start Discovery to keep scanning alive
      packet = nil
      Timeout.timeout(3) { packet = kernel.recv(4096) }
      opcode, _index, _params = BlueHydra::Mgmt.decode_packet(packet)
      expect(opcode).to eq(BlueHydra::Mgmt::CMD_START_DISCOVERY)
    end

    it "does NOT re-issue discovery after stop_discovery" do
      serve({ status: BlueHydra::Mgmt::STATUS_SUCCESS },
            { status: BlueHydra::Mgmt::STATUS_SUCCESS })
      mgmt.start_discovery
      mgmt.stop_discovery
      @kernel_thread.join(2)

      # a Discovering-off after stop should NOT trigger a restart
      off = [BlueHydra::Mgmt::ADDR_TYPE_ALL, 0].pack("CC")
      kernel.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_DISCOVERING, 0, off), 0)

      expect { Timeout.timeout(1) { kernel.recv(4096) } }.to raise_error(Timeout::Error)
    end

    it "start_discovery clears the suppression flag and stop_discovery sets it" do
      serve({ status: BlueHydra::Mgmt::STATUS_SUCCESS },
            { status: BlueHydra::Mgmt::STATUS_SUCCESS })
      mgmt.start_discovery
      expect(mgmt.instance_variable_get(:@discovery_suppressed)).to be false
      mgmt.stop_discovery
      expect(mgmt.instance_variable_get(:@discovery_suppressed)).to be true
    end
  end

  # The reader thread decodes unsolicited connection events and forwards them to
  # the discovery thread via the connection_events queue. Exercise the decode
  # path directly (no socket needed): dispatch_event only reads its params.
  describe "connection event decoding (dispatch_event -> connection_events)" do
    let(:mgmt) { BlueHydra::Mgmt.new(0) }
    after { mgmt.close rescue nil }

    # 6 byte LE address + address_type + trailing bytes (flags/reason/status/eir)
    def conn_params(mac, trailing = "\x01".b + ("\x00" * 8).b)
      BlueHydra::Mgmt.pack_address(mac) + trailing.b
    end

    def dispatch(code, params)
      mgmt.send(:dispatch_event, code, params)
    end

    it "forwards Device Connected as {type: :connected, address:}" do
      dispatch(BlueHydra::Mgmt::EV_DEVICE_CONNECTED, conn_params("AA:BB:CC:DD:EE:FF"))
      expect(mgmt.connection_events.pop).to eq(type: :connected, address: "AA:BB:CC:DD:EE:FF")
    end

    it "forwards Device Disconnected as {type: :disconnected, address:}" do
      dispatch(BlueHydra::Mgmt::EV_DEVICE_DISCONNECTED, conn_params("11:22:33:44:55:66"))
      expect(mgmt.connection_events.pop).to eq(type: :disconnected, address: "11:22:33:44:55:66")
    end

    it "forwards Connect Failed as {type: :failed, address:}" do
      dispatch(BlueHydra::Mgmt::EV_CONNECT_FAILED, conn_params("AA:BB:CC:DD:EE:FF"))
      expect(mgmt.connection_events.pop).to eq(type: :failed, address: "AA:BB:CC:DD:EE:FF")
    end

    it "drops an undecodable (too-short) connection event without raising or enqueuing" do
      expect { dispatch(BlueHydra::Mgmt::EV_DEVICE_CONNECTED, "\x01\x02".b) }.not_to raise_error
      expect(mgmt.connection_events.empty?).to be true
    end

    # addr(6) + addr_type(1) prefix shared by the pairing-request events
    def pairing_params(mac, type = 0x00, trailing = "")
      BlueHydra::Mgmt.pack_address(mac) + [type].pack("C") + trailing.b
    end

    it "auto-rejects a PIN Code Request with a PIN Code Negative Reply" do
      allow(mgmt).to receive(:send_command)
      params = pairing_params("AA:BB:CC:DD:EE:FF", 0x00, "\x00")
      dispatch(BlueHydra::Mgmt::EV_PIN_CODE_REQUEST, params)
      expect(mgmt).to have_received(:send_command)
        .with(BlueHydra::Mgmt::CMD_PIN_CODE_NEG_REPLY, params[0, 7])
    end

    it "auto-rejects a User Confirmation Request with a negative reply" do
      allow(mgmt).to receive(:send_command)
      params = pairing_params("11:22:33:44:55:66", 0x01, "\x00\x00\x00\x00\x00")
      dispatch(BlueHydra::Mgmt::EV_USER_CONFIRM_REQUEST, params)
      expect(mgmt).to have_received(:send_command)
        .with(BlueHydra::Mgmt::CMD_USER_CONFIRM_NEG_REPLY, params[0, 7])
    end

    it "auto-rejects a User Passkey Request with a negative reply" do
      allow(mgmt).to receive(:send_command)
      params = pairing_params("11:22:33:44:55:66", 0x01)
      dispatch(BlueHydra::Mgmt::EV_USER_PASSKEY_REQUEST, params)
      expect(mgmt).to have_received(:send_command)
        .with(BlueHydra::Mgmt::CMD_USER_PASSKEY_NEG_REPLY, params[0, 7])
    end

    it "does not reject (or raise) on a malformed too-short pairing request" do
      allow(mgmt).to receive(:send_command)
      expect { dispatch(BlueHydra::Mgmt::EV_PIN_CODE_REQUEST, "\x01\x02".b) }.not_to raise_error
      expect(mgmt).not_to have_received(:send_command)
    end
  end

  describe "scanning uptime tracking" do
    let(:mgmt) { BlueHydra::Mgmt.new(0) }
    after { mgmt.close rescue nil }

    it "computes the percentage from the on/off accumulators" do
      mgmt.instance_variable_set(:@discovering, false)
      mgmt.instance_variable_set(:@discovering_since, Time.now)
      mgmt.instance_variable_set(:@scan_on_time,  3.0)
      mgmt.instance_variable_set(:@scan_off_time, 1.0)
      expect(mgmt.scanning_percentage).to be_within(1.0).of(75.0)
    end

    it "returns 0 before any time has accumulated" do
      mgmt.instance_variable_set(:@discovering_since, Time.now)
      expect(mgmt.scanning_percentage).to eq(0.0)
    end

    it "folds elapsed on-time into the accumulator on a Discovering transition" do
      mgmt.instance_variable_set(:@discovering, true)
      mgmt.instance_variable_set(:@discovering_since, Time.now - 2)
      mgmt.send(:record_discovering_transition, false) # was on ~2s, now off

      expect(mgmt.instance_variable_get(:@scan_on_time)).to be >= 2.0
      expect(mgmt.instance_variable_get(:@discovering)).to eq(false)
    end

    it "a Discovering event drives the transition through dispatch_event" do
      # discovering = on
      mgmt.send(:dispatch_event, BlueHydra::Mgmt::EV_DISCOVERING, [BlueHydra::Mgmt::ADDR_TYPE_ALL, 1].pack("CC"))
      expect(mgmt.instance_variable_get(:@discovering)).to eq(true)
    end
  end
end

# Mirrors the kernel's hci_is_identity_address. mgmt Add Device rejects anything
# else with INVALID_PARAMS, so getting this classification wrong means either
# wasted round-trips (false positives) or devices that never get a version read
# (false negatives).
describe "BlueHydra::Mgmt.identity_address?" do
  it "accepts any public address" do
    # public addresses are identity addresses whatever the bits look like
    ["7A:BB:CC:DD:EE:FF", "18:BB:CC:DD:EE:FF", "FF:BB:CC:DD:EE:FF"].each do |address|
      expect(BlueHydra::Mgmt.identity_address?(address, BlueHydra::Mgmt::LE_PUBLIC)).to eq(true)
    end
  end

  it "accepts a random STATIC address (top two bits of the first octet set)" do
    # 0xC0..0xFF
    ["C0:BB:CC:DD:EE:FF", "CA:BB:CC:DD:EE:FF", "FF:BB:CC:DD:EE:FF"].each do |address|
      expect(BlueHydra::Mgmt.identity_address?(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(true)
    end
  end

  it "rejects a resolvable private address (top two bits 01)" do
    # 0x40..0x7F
    ["40:BB:CC:DD:EE:FF", "55:BB:CC:DD:EE:FF", "7F:BB:CC:DD:EE:FF"].each do |address|
      expect(BlueHydra::Mgmt.identity_address?(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(false)
    end
  end

  it "rejects a non-resolvable private address (top two bits 00)" do
    # 0x00..0x3F
    ["00:BB:CC:DD:EE:FF", "18:BB:CC:DD:EE:FF", "3F:BB:CC:DD:EE:FF"].each do |address|
      expect(BlueHydra::Mgmt.identity_address?(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(false)
    end
  end

  it "rejects the boundary just below static (0xBF) and accepts 0xC0" do
    expect(BlueHydra::Mgmt.identity_address?("BF:00:00:00:00:00", BlueHydra::Mgmt::LE_RANDOM)).to eq(false)
    expect(BlueHydra::Mgmt.identity_address?("C0:00:00:00:00:00", BlueHydra::Mgmt::LE_RANDOM)).to eq(true)
  end

  it "rejects a BR/EDR address type (Add Device auto-connect is LE only)" do
    expect(BlueHydra::Mgmt.identity_address?("CA:BB:CC:DD:EE:FF", BlueHydra::Mgmt::ADDR_TYPE_BREDR)).to eq(false)
  end
end

# The kernel stops discovery itself to service a connect, so re-arming on every
# Discovering=0 fights the connection. An on-device capture showed Discovering=0
# followed by Start Discovery a millisecond later, repeatedly.
describe "BlueHydra::Mgmt discovery re-arm rate limiting" do
  let(:sock) { instance_double("Socket") }
  let(:mgmt) { BlueHydra::Mgmt.new(0, socket: sock) }

  before do
    allow(sock).to receive(:closed?).and_return(false)
    allow(sock).to receive(:send)
    allow(BlueHydra.logger).to receive(:debug)
  end

  # a Discovering event payload: address type + discovering flag
  def discovering_event(on)
    [BlueHydra::Mgmt::ADDR_TYPE_ALL, on ? 1 : 0].pack("CC")
  end

  def deliver_stopped
    mgmt.send(:dispatch_event, BlueHydra::Mgmt::EV_DISCOVERING, discovering_event(false))
  end

  it "re-arms on the first kernel stop" do
    deliver_stopped
    expect(mgmt.rearm_count).to eq(1)
    expect(mgmt.rearm_skipped_count).to eq(0)
  end

  it "rate-limits a burst of stops instead of fighting the connect" do
    10.times { deliver_stopped }
    expect(mgmt.rearm_count).to eq(1)
    expect(mgmt.rearm_skipped_count).to eq(9)
  end

  it "re-arms again once the interval has passed" do
    deliver_stopped
    # pretend the last re-arm was longer ago than the interval
    mgmt.instance_variable_set(:@last_rearm_at,
                               Time.now - (BlueHydra::Mgmt::REARM_MIN_INTERVAL + 0.1))
    deliver_stopped
    expect(mgmt.rearm_count).to eq(2)
  end

  it "does not re-arm at all while discovery is deliberately suppressed" do
    mgmt.instance_variable_set(:@discovery_suppressed, true)
    5.times { deliver_stopped }
    expect(mgmt.rearm_count).to eq(0)
  end
end

# The discovery-off budget has to be measured against the kernel's own state. A
# phase timing from its own entry cannot see time an earlier phase already spent
# with discovery off, which is how a 6s budget produced a 35s window on device.
describe "BlueHydra::Mgmt#discovery_off_for" do
  let(:mgmt) { BlueHydra::Mgmt.new(0, socket: instance_double("Socket")) }

  it "reports 0 while discovery is on" do
    mgmt.instance_variable_set(:@discovering, true)
    expect(mgmt.discovery_off_for).to eq(0.0)
    expect(mgmt.discovering?).to eq(true)
  end

  it "reports how long discovery has been off" do
    mgmt.instance_variable_set(:@discovering, false)
    mgmt.instance_variable_set(:@discovering_since, Time.now - 9.0)
    expect(mgmt.discovery_off_for).to be_within(0.5).of(9.0)
    expect(mgmt.discovering?).to eq(false)
  end
end

# Start Discovery's address-type mask is validated against the transports the
# controller has ENABLED, not the ones it supports, and a request naming a
# disabled transport fails WHOLLY (status 0x0b REJECTED) rather than partially.
# A production DART showed supported BREDR+LE / current BREDR only, so every
# interleaved Start Discovery was rejected and nothing scanned at all. So:
# enable what is capable-but-off, then ask only for what is really enabled.
describe "BlueHydra::Mgmt transport enablement" do
  let(:pair)   { Socket.pair(:UNIX, :SOCK_DGRAM, 0) }
  let(:ours)   { pair[0] }
  let(:kernel) { pair[1] }
  let(:mgmt)   { BlueHydra::Mgmt.new(0, socket: ours) }

  before do
    allow(BlueHydra.logger).to receive(:info)
    allow(BlueHydra.logger).to receive(:warn)
    allow(BlueHydra.logger).to receive(:error)
  end

  after do
    mgmt.close rescue nil
    @kernel_thread&.kill
  end

  # what the DART reports: everything capable, only BR/EDR switched on
  let(:dart_supported)    { 0x004ffeff }
  let(:powered_bredr)     { BlueHydra::Mgmt::SETTING_POWERED | BlueHydra::Mgmt::SETTING_BREDR }
  let(:powered_bredr_le)  { powered_bredr | BlueHydra::Mgmt::SETTING_LE }
  let(:bredr_supported)   { dart_supported & ~BlueHydra::Mgmt::SETTING_LE }

  # Read Controller Information response body: bdaddr(6), version(1),
  # manufacturer(2), supported_settings(4), current_settings(4), then class of
  # device / name, which we don't read (included to prove trailing data is fine).
  def controller_info(supported, current)
    BlueHydra::Mgmt.pack_address("AA:BB:CC:DD:EE:FF") +
      [0x0c].pack("C") +
      [0x000f].pack("S<") +
      [supported].pack("V") +
      [current].pack("V") +
      ("\x00" * 6).b
  end

  def reply(status, extra = "")
    { status: status, extra: extra }
  end

  def ok(extra = "")
    reply(BlueHydra::Mgmt::STATUS_SUCCESS, extra)
  end

  # Answer +replies.size+ commands in order, recording what was asked.
  def serve(*replies)
    @received = []
    @kernel_thread = Thread.new do
      replies.each do |r|
        opcode, _index, params = BlueHydra::Mgmt.decode_packet(kernel.recv(4096))
        @received << { opcode: opcode, params: params }
        body = [opcode, r.fetch(:status)].pack("S<C") + (r[:extra] || "").b
        kernel.send(BlueHydra::Mgmt.encode_packet(BlueHydra::Mgmt::EV_CMD_COMPLETE, 0, body), 0)
      end
    end
  end

  def opcodes
    @kernel_thread.join(3)
    @received.map { |r| r[:opcode] }
  end

  describe "#read_settings" do
    it "decodes supported and current settings out of Read Controller Information" do
      serve(ok(controller_info(0x004ffeff, 0x00000081))) # verbatim from the DART

      expect(mgmt.read_settings).to eq([0x004ffeff, 0x00000081])
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
    end

    it "returns nil when the read fails" do
      serve(reply(BlueHydra::Mgmt::STATUS_BUSY))
      expect(mgmt.read_settings).to be_nil
    end

    it "returns nil on a truncated response rather than unpacking garbage" do
      serve(ok("\x00" * 8))
      expect(mgmt.read_settings).to be_nil
    end
  end

  describe ".settings_label" do
    it "names the bits that are set" do
      expect(BlueHydra::Mgmt.settings_label(0x00000081)).to eq("0x00000081 (POWERED BREDR)")
    end

    # Enabling LE on the DART moved current settings from 0x00000081 to
    # 0x004c0281: the kernel brings up the LE-dependent settings along with it.
    # An incomplete name table printed that as "POWERED BREDR LE" and silently
    # dropped three set bits.
    it "names the LE-dependent bits the kernel brings up with LE" do
      expect(BlueHydra::Mgmt.settings_label(0x004c0281)).to eq(
        "0x004c0281 (POWERED BREDR LE CIS_CENTRAL CIS_PERIPHERAL LL_PRIVACY)"
      )
    end

    # The property that matters is that the label accounts for the WHOLE mask:
    # every set bit is named, and every name maps back to a set bit. That catches
    # a missing entry without pinning a 20-name string into the spec.
    it "leaves no set bit unnamed" do
      [0x00000081,  # DART, LE off
       0x004c0281,  # DART, LE on
       0x004ffeff,  # DART supported
       0x03ffffff   # every bit the kernel defines
      ].each do |mask|
        named   = BlueHydra::Mgmt.settings_label(mask)[/\((.*)\)/, 1].split(" ")
        rebuilt = named.sum { |name| BlueHydra::Mgmt::SETTING_NAMES.key(name).to_i }
        expect(rebuilt).to eq(mask), "#{format('0x%08x', mask)} decoded as #{named.join(' ')}"
      end
    end

    it "says none rather than printing an empty list" do
      expect(BlueHydra::Mgmt.settings_label(0)).to eq("0x00000000 (none)")
    end
  end

  describe "#ensure_transports_enabled" do
    # exactly the DART: both transports capable, LE switched off
    it "enables LE when it is supported but disabled, and scans both afterwards" do
      serve(ok(controller_info(dart_supported, powered_bredr)),    # initial read
            ok,                                                   # Set LE
            ok(controller_info(dart_supported, powered_bredr_le))) # re-read

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                             BlueHydra::Mgmt::CMD_SET_LE,
                             BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
      expect(@received[1][:params].bytes).to eq([0x01]) # enable, not disable
    end

    it "does not touch a transport that is already enabled" do
      serve(ok(controller_info(dart_supported, powered_bredr_le)),
            ok(controller_info(dart_supported, powered_bredr_le)))

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                             BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
    end

    # The kernel rejects Set BR/EDR while LE is disabled (a dual-mode controller
    # may not be made BR/EDR-only through mgmt), so the order is not arbitrary.
    it "enables LE before BR/EDR when both are off" do
      serve(ok(controller_info(dart_supported, BlueHydra::Mgmt::SETTING_POWERED)),
            ok, # Set LE
            ok, # Set BR/EDR
            ok(controller_info(dart_supported, powered_bredr_le)))

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                             BlueHydra::Mgmt::CMD_SET_LE,
                             BlueHydra::Mgmt::CMD_SET_BREDR,
                             BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
    end

    it "skips a transport the controller does not support and scans the other one" do
      serve(ok(controller_info(bredr_supported, powered_bredr)),
            ok(controller_info(bredr_supported, powered_bredr)))

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                             BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
      expect(BlueHydra.logger).to have_received(:warn).with(/does not support LE/)
    end

    it "derives LE-only on a single-mode LE controller" do
      le_only = BlueHydra::Mgmt::SETTING_POWERED | BlueHydra::Mgmt::SETTING_LE
      serve(ok(controller_info(le_only, le_only)), ok(controller_info(le_only, le_only)))

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::LE_TYPE_BITS)
    end

    # The whole point of re-reading: a Set that failed (or silently did nothing)
    # must not leave us asking for that transport, or every Start Discovery after
    # it is REJECTED.
    it "excludes a transport whose enable failed" do
      serve(ok(controller_info(dart_supported, powered_bredr)),
            reply(BlueHydra::Mgmt::STATUS_REJECTED),          # Set LE refused
            ok(controller_info(dart_supported, powered_bredr))) # LE still off

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT)
      expect(BlueHydra.logger).to have_received(:warn).with(/LE enable refused/)
      # and does NOT power cycle: LE provably takes while powered, so a refusal
      # there means something else, and a power cycle would be a shot in the dark
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                             BlueHydra::Mgmt::CMD_SET_LE,
                             BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
    end

    it "excludes a transport whose enable reported success but did not take" do
      serve(ok(controller_info(dart_supported, powered_bredr)),
            ok,                                                 # Set LE said fine
            ok(controller_info(dart_supported, powered_bredr))) # ...but LE is still off

      expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT)
    end

    # Measured on a DART: Set BR/EDR on a POWERED controller answers 0x0b
    # REJECTED in both directions. The flag is only writable with the radio down,
    # so that is the only way to bring BR/EDR up on a unit that has it capable but
    # off. LE behaves differently (it takes while powered), hence the retry is
    # BR/EDR only.
    describe "BR/EDR needing the radio powered down" do
      let(:powered_le) { BlueHydra::Mgmt::SETTING_POWERED | BlueHydra::Mgmt::SETTING_LE }

      it "powers down, enables BR/EDR, and powers back up" do
        serve(ok(controller_info(dart_supported, powered_le)), # BREDR off, LE on
              reply(BlueHydra::Mgmt::STATUS_REJECTED),        # Set BR/EDR while powered
              ok,                                             # Set Powered off
              ok,                                             # Set BR/EDR, radio down
              ok,                                             # Set Powered on
              ok(controller_info(dart_supported, powered_bredr_le)))

        expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
        expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                               BlueHydra::Mgmt::CMD_SET_BREDR,
                               BlueHydra::Mgmt::CMD_SET_POWERED,
                               BlueHydra::Mgmt::CMD_SET_BREDR,
                               BlueHydra::Mgmt::CMD_SET_POWERED,
                               BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
        expect(@received[2][:params].bytes).to eq([0x00]) # power off
        expect(@received[4][:params].bytes).to eq([0x01]) # power back on
      end

      # Leaving the radio down would take the unit off the air entirely, which is
      # far worse than the missing transport we came here to fix.
      it "powers back up even when the powered-down enable also fails" do
        serve(ok(controller_info(dart_supported, powered_le)),
              reply(BlueHydra::Mgmt::STATUS_REJECTED), # Set BR/EDR while powered
              ok,                                      # Set Powered off
              reply(BlueHydra::Mgmt::STATUS_REJECTED), # Set BR/EDR, radio down
              ok,                                      # Set Powered on
              ok(controller_info(dart_supported, powered_le)))

        expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::LE_TYPE_BITS)
        expect(opcodes.last(2)).to eq([BlueHydra::Mgmt::CMD_SET_POWERED,
                                       BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
        expect(@received[4][:params].bytes).to eq([0x01]) # powered back up regardless
      end

      it "gives up without touching the transport if it cannot power down" do
        serve(ok(controller_info(dart_supported, powered_le)),
              reply(BlueHydra::Mgmt::STATUS_REJECTED), # Set BR/EDR while powered
              reply(BlueHydra::Mgmt::STATUS_BUSY),     # Set Powered off refused
              ok(controller_info(dart_supported, powered_le)))

        expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::LE_TYPE_BITS)
        expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                               BlueHydra::Mgmt::CMD_SET_BREDR,
                               BlueHydra::Mgmt::CMD_SET_POWERED,
                               BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
        expect(BlueHydra.logger).to have_received(:error).with(/could not power down to enable BREDR/)
      end

      # An already-powered-down controller takes the Set directly, so a REJECTED
      # there is about something else and a power cycle would not help.
      it "does not power cycle a controller that is already powered down" do
        le_only = BlueHydra::Mgmt::SETTING_LE
        serve(ok(controller_info(dart_supported, le_only)),
              reply(BlueHydra::Mgmt::STATUS_REJECTED),
              ok(controller_info(dart_supported, le_only)))

        expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::LE_TYPE_BITS)
        expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                               BlueHydra::Mgmt::CMD_SET_BREDR,
                               BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
      end

      # Only REJECTED means "not while the radio is up"; anything else is a real
      # failure and a power cycle is not the answer.
      it "does not power cycle on a non-REJECTED failure" do
        serve(ok(controller_info(dart_supported, powered_le)),
              reply(0x0c), # NOT_SUPPORTED
              ok(controller_info(dart_supported, powered_le)))

        expect(mgmt.ensure_transports_enabled).to eq(BlueHydra::Mgmt::LE_TYPE_BITS)
        expect(opcodes).to eq([BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO,
                               BlueHydra::Mgmt::CMD_SET_BREDR,
                               BlueHydra::Mgmt::CMD_READ_CONTROLLER_INFO])
      end
    end

    # Both transports are expected to work. Either one ending up unusable halves
    # what the sensor can see and is invisible in the device data itself, so it
    # gets a warning AND a notification, not just a log line.
    describe "reporting an unusable transport" do
      before { allow(BlueHydra).to receive(:send_event) }

      it "warns and notifies when a transport is not supported at all" do
        serve(ok(controller_info(bredr_supported, powered_bredr)),
              ok(controller_info(bredr_supported, powered_bredr)))
        mgmt.ensure_transports_enabled

        expect(BlueHydra.logger).to have_received(:warn).with(/hci0 does not support LE/)
        expect(BlueHydra).to have_received(:send_event).with(
          'blue_hydra',
          hash_including(key: 'blue_hydra_transport_unsupported',
                         severity: 'WARN',
                         message: /does not support LE/)
        )
      end

      it "warns and notifies when a transport is supported but could not be enabled" do
        serve(ok(controller_info(dart_supported, powered_bredr)),
              reply(BlueHydra::Mgmt::STATUS_REJECTED),
              ok(controller_info(dart_supported, powered_bredr)))
        mgmt.ensure_transports_enabled

        expect(BlueHydra).to have_received(:send_event).with(
          'blue_hydra',
          hash_including(key: 'blue_hydra_transport_disabled',
                         severity: 'WARN',
                         message: /LE supported but disabled and it could not be enabled/)
        )
      end

      # The ordinary success path: we found LE off, turned it on, and that is an
      # info line and nothing more. Notifying here would train people to ignore
      # the event.
      it "stays quiet when a disabled transport was successfully enabled" do
        serve(ok(controller_info(dart_supported, powered_bredr)),
              ok,
              ok(controller_info(dart_supported, powered_bredr_le)))
        mgmt.ensure_transports_enabled

        expect(BlueHydra.logger).to have_received(:info).with(/LE enabled/)
        expect(BlueHydra).not_to have_received(:send_event)
      end

      it "stays quiet when both transports were already enabled" do
        serve(ok(controller_info(dart_supported, powered_bredr_le)),
              ok(controller_info(dart_supported, powered_bredr_le)))
        mgmt.ensure_transports_enabled

        expect(BlueHydra).not_to have_received(:send_event)
      end

      it "reports both transports when neither is usable" do
        powered_only = BlueHydra::Mgmt::SETTING_POWERED
        serve(ok(controller_info(powered_only, powered_only)),
              ok(controller_info(powered_only, powered_only)))
        mgmt.ensure_transports_enabled

        expect(BlueHydra).to have_received(:send_event).with(
          'blue_hydra', hash_including(message: /does not support LE/)
        )
        expect(BlueHydra).to have_received(:send_event).with(
          'blue_hydra', hash_including(message: /does not support BREDR/)
        )
      end
    end

    describe "#enabled_transports" do
      it "is nil until the transports have been determined" do
        expect(mgmt.enabled_transports).to be_nil
      end

      it "names both transports when both are on" do
        serve(ok(controller_info(dart_supported, powered_bredr_le)),
              ok(controller_info(dart_supported, powered_bredr_le)))
        mgmt.ensure_transports_enabled
        expect(mgmt.enabled_transports).to eq(["BREDR", "LE"])
      end

      it "names just the one transport that is on" do
        serve(ok(controller_info(bredr_supported, powered_bredr)),
              ok(controller_info(bredr_supported, powered_bredr)))
        mgmt.ensure_transports_enabled
        expect(mgmt.enabled_transports).to eq(["BREDR"])
      end

      # Empty is meaningful and distinct from nil: determined, and nothing is on.
      it "is empty when no transport is usable" do
        powered_only = BlueHydra::Mgmt::SETTING_POWERED
        serve(ok(controller_info(powered_only, powered_only)),
              ok(controller_info(powered_only, powered_only)))
        mgmt.ensure_transports_enabled
        expect(mgmt.enabled_transports).to eq([])
      end
    end

    it "logs the controller's supported and current settings at startup" do
      # the DART's own numbers, before and after LE comes on
      serve(ok(controller_info(0x004ffeff, 0x00000081)),
            ok,
            ok(controller_info(0x004ffeff, 0x00000281)))
      mgmt.ensure_transports_enabled

      expect(BlueHydra.logger).to have_received(:info).with(/supported settings 0x004ffeff \(POWERED /)
      expect(BlueHydra.logger).to have_received(:info).with(/current settings\s+0x00000081 \(POWERED BREDR\)/)
      expect(BlueHydra.logger).to have_received(:info).with(/discovery type 0x07 \(BREDR\+LE\)/)
    end

    # Best effort, like configure_no_pairing: a controller we cannot interrogate
    # should still be asked to scan rather than not scanned at all.
    it "falls back to asking for everything when the settings read fails" do
      serve(reply(BlueHydra::Mgmt::STATUS_BUSY))

      expect(mgmt.ensure_transports_enabled).to be_nil
      expect(mgmt.discovery_type).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(BlueHydra.logger).to have_received(:error).with(/could not read controller settings/)
    end

    # A failed re-read is not evidence that the transports are off. Folding it to
    # zero would claim both are dead on a controller that is in fact scanning:
    # two bogus WARN events, and a CUI reading "NO TRANSPORT ENABLED" while
    # devices stream in.
    it "stays undetermined when the re-read fails rather than claiming nothing is enabled" do
      allow(BlueHydra).to receive(:send_event)
      serve(ok(controller_info(dart_supported, powered_bredr_le)), # both already on
            reply(BlueHydra::Mgmt::STATUS_BUSY))                  # re-read fails

      expect(mgmt.ensure_transports_enabled).to be_nil
      expect(mgmt.discovery_type).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(mgmt.enabled_transports).to be_nil # NOT [], which the CUI reads as "none"
      expect(BlueHydra.logger).to have_received(:error).with(/could not re-read controller settings/)
      expect(BlueHydra).not_to have_received(:send_event)
    end

    it "falls back to asking for everything when a command raises" do
      allow(mgmt).to receive(:read_settings).and_raise(MgmtSocketError, "boom")

      expect(mgmt.ensure_transports_enabled).to be_nil
      expect(mgmt.discovery_type).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(BlueHydra.logger).to have_received(:error).with(/transport setup failed/)
    end
  end

  describe "#discovery_type" do
    it "asks for everything until the transports have been determined" do
      expect(mgmt.discovery_type).to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
    end

    it "maps enabled transports onto the kernel's discovery types" do
      bredr = BlueHydra::Mgmt::SETTING_BREDR
      le    = BlueHydra::Mgmt::SETTING_LE
      expect(mgmt.send(:discovery_type_for, bredr)).to eq(0x01)       # BR/EDR only
      expect(mgmt.send(:discovery_type_for, le)).to eq(0x06)          # LE public + random
      expect(mgmt.send(:discovery_type_for, bredr | le)).to eq(0x07)  # interleaved
    end

    # Returning 0 here would be a silent no-op; a rejected Start Discovery at
    # least names the controller in the log.
    it "still asks for everything (loudly) when no transport is enabled" do
      expect(mgmt.send(:discovery_type_for, BlueHydra::Mgmt::SETTING_POWERED))
        .to eq(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(BlueHydra.logger).to have_received(:error).with(/no usable transport enabled/)
    end
  end

  describe "discovery commands using the derived type" do
    before do
      # BR/EDR-capable only, so nothing needs enabling and no command is issued
      # here - the socket responder below is all about the discovery commands.
      allow(mgmt).to receive(:read_settings).and_return([bredr_supported, powered_bredr])
      mgmt.ensure_transports_enabled # settles on BR/EDR only
    end

    it "start_discovery asks only for the enabled transports" do
      serve(ok)
      expect(mgmt.start_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_START_DISCOVERY])
      expect(@received.first[:params].bytes).to eq([BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT])
    end

    # The kernel answers INVALID_PARAMS when the stop type does not match the
    # type discovery was started with.
    it "stop_discovery reuses the type discovery was started with" do
      serve(ok, ok)
      mgmt.start_discovery
      expect(mgmt.stop_discovery).to eq(BlueHydra::Mgmt::STATUS_SUCCESS)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_START_DISCOVERY,
                             BlueHydra::Mgmt::CMD_STOP_DISCOVERY])
      expect(@received.last[:params].bytes).to eq([BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT])
    end

    it "the reader thread re-arms with the derived type too" do
      allow(mgmt).to receive(:send_command)
      mgmt.send(:dispatch_event, BlueHydra::Mgmt::EV_DISCOVERING,
                [BlueHydra::Mgmt::ADDR_TYPE_ALL, 0].pack("CC"))

      expect(mgmt).to have_received(:send_command).with(
        BlueHydra::Mgmt::CMD_START_DISCOVERY,
        [BlueHydra::Mgmt::ADDR_TYPE_BREDR_BIT].pack("C")
      )
    end

    it "an explicit type still overrides the derived one" do
      serve(ok)
      mgmt.start_discovery(BlueHydra::Mgmt::ADDR_TYPE_ALL)
      expect(opcodes).to eq([BlueHydra::Mgmt::CMD_START_DISCOVERY])
      expect(@received.first[:params].bytes).to eq([BlueHydra::Mgmt::ADDR_TYPE_ALL])
    end
  end
end
