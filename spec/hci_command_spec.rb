require 'spec_helper'
require 'timeout'

describe BlueHydra::HciCommand do
  describe "command framing (pure helpers)" do
    it "encodes Read Remote Version as pkt-type + le16 opcode + plen + params" do
      packet = BlueHydra::HciCommand.encode_command(
        BlueHydra::HciCommand::OPCODE_READ_REMOTE_VERSION, [0x0040].pack("S<")
      )
      # 0x01 command pkt, opcode 0x041D (1d 04), plen 0x02, handle 0x0040 (40 00)
      expect(packet.bytes).to eq([0x01, 0x1d, 0x04, 0x02, 0x40, 0x00])
    end

    it "encodes an empty-parameter command with plen 0" do
      packet = BlueHydra::HciCommand.encode_command(0x0c03)
      expect(packet.bytes).to eq([0x01, 0x03, 0x0c, 0x00])
    end

    it "builds a full 16-byte hci_filter selecting event packets and all events" do
      f = BlueHydra::HciCommand.event_filter
      # sizeof(struct hci_filter) == 16; the kernel copies exactly this many
      expect(f.bytesize).to eq(16)
      type_mask, ev0, ev1 = f.unpack("VVV")
      expect(type_mask).to eq(1 << BlueHydra::HciCommand::HCI_EVENT_PKT)
      expect(ev0).to eq(0xffffffff)
      expect(ev1).to eq(0xffffffff) # LE Meta (0x3e) lives in this second word
    end
  end

  describe ".le_connection_handle" do
    # LE event packet layout: [pkt, evt, plen, subevent, status, handle_lo, handle_hi, ...]
    def le_event(subevent, status, handle, evt: 0x3e)
      [0x04, evt, 0x13, subevent, status, handle].pack("CCCCCS<") + ("\x00" * 6)
    end

    it "returns the handle for a successful LE Connection Complete (0x01)" do
      pkt = le_event(BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE, 0x00, 0x0040)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to eq(0x0040)
    end

    it "returns the handle for a successful LE Enhanced Connection Complete (0x0a)" do
      pkt = le_event(BlueHydra::HciCommand::SUB_LE_ENH_CONNECTION_COMPLETE, 0x00, 0x0801)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to eq(0x0801)
    end

    it "masks the handle to its 12 significant bits" do
      pkt = le_event(BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE, 0x00, 0xF040)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to eq(0x0040)
    end

    it "returns nil for a non-success status" do
      pkt = le_event(BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE, 0x3e, 0x0040)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to be_nil
    end

    it "returns nil for a non LE-connection subevent (e.g. advertising report)" do
      pkt = le_event(0x02, 0x00, 0x0040)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to be_nil
    end

    it "returns nil for a non LE-meta event" do
      pkt = le_event(BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE, 0x00, 0x0040, evt: 0x0e)
      expect(BlueHydra::HciCommand.le_connection_handle(pkt)).to be_nil
    end

    it "returns nil for a truncated packet" do
      expect(BlueHydra::HciCommand.le_connection_handle("\x04\x3e\x01")).to be_nil
    end
  end

  describe "reader thread over an injected socket" do
    let(:pair)   { Socket.pair(:UNIX, :SOCK_DGRAM, 0) }
    let(:ours)   { pair[0] }
    let(:kernel) { pair[1] }
    let(:hci)    { BlueHydra::HciCommand.new(0, socket: ours) }

    after do
      hci.close rescue nil
    end

    it "issues Read Remote Version when a new LE connection is reported" do
      hci.start

      handle = 0x0040
      event  = [0x04, 0x3e, 0x13, BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE,
                0x00, handle].pack("CCCCCS<") + ("\x00" * 6)
      kernel.send(event, 0)

      cmd = nil
      Timeout.timeout(3) { cmd = kernel.recv(64) }
      expect(cmd.bytes).to eq([0x01, 0x1d, 0x04, 0x02, 0x40, 0x00])
    end

    it "does not issue a command for a failed connection" do
      hci.start

      event = [0x04, 0x3e, 0x13, BlueHydra::HciCommand::SUB_LE_CONNECTION_COMPLETE,
               0x3e, 0x0040].pack("CCCCCS<") + ("\x00" * 6)
      kernel.send(event, 0)

      expect { Timeout.timeout(1) { kernel.recv(64) } }.to raise_error(Timeout::Error)
    end
  end
end
