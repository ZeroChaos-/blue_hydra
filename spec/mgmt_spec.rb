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
