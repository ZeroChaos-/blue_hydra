require 'spec_helper'

describe BlueHydra::BtmonHandler do
  it "a class" do
    expect(BlueHydra::BtmonHandler.class).to eq(Class)
  end

  it "will break the output of bluetooth data into chunks to be parsed" do
    filepath = File.expand_path('../fixtures/btmon.stdout', __FILE__)
    command = "cat #{filepath} && sleep 1"
    queue = Queue.new

    begin
      handler = BlueHydra::BtmonHandler.new(command, queue)
    rescue BtmonExitedError
      # will be raised in file mode
    end

    expect(queue.empty?).to eq(false)
  end

  describe "#enqueue filtering" do
    # build a handler without running initialize (which would spawn a PTY) so
    # we can exercise the filter chain in isolation
    def enqueued?(buffer)
      handler = BlueHydra::BtmonHandler.allocate
      queue   = Queue.new
      handler.instance_variable_set(:@parse_queue, queue)
      handler.enqueue(buffer)
      !queue.empty?
    end

    it "drops host->controller command lines, bare and tool-prefixed" do
      expect(enqueued?(["< HCI Command: LE Create Connection (0x08|0x000d)\r\n"])).to eq(false)
      expect(enqueued?(["hcitool[123]: < HCI Command: LE Set Scan Enable (0x08|0x000c)\r\n"])).to eq(false)
    end

    it "keeps MGMT Device Found but drops other @ events, bare and prefixed" do
      expect(enqueued?(["@ MGMT Event: Device Found (0x0012) plen 14\r\n", "        LE Address: AA:BB:CC:DD:EE:FF\r\n"])).to eq(true)
      expect(enqueued?(["@ MGMT Event: Discovering (0x0013) plen 2\r\n"])).to eq(false)
      expect(enqueued?(["bluetoothd[123]: @ MGMT Open: bluetoothd (privileged) version 1.23\r\n"])).to eq(false)
      expect(enqueued?(["bluetoothd[123]: @ MGMT Command: Start Discovery (0x0023) plen 1\r\n"])).to eq(false)
    end

    it "drops noisy HCI events by code" do
      expect(enqueued?(["> HCI Event: Command Status (0x0f) plen 4\r\n"])).to eq(false)
      expect(enqueued?(["> HCI Event: Number of Completed Packets (0x13) plen 5\r\n"])).to eq(false)
      expect(enqueued?(["> HCI Event: Unknown (0x00) plen 0\r\n"])).to eq(false)
    end

    it "keeps interesting HCI events like inquiry and advertising results" do
      expect(enqueued?(["> HCI Event: Extended Inquiry Result (0x2f) plen 255\r\n", "        Address: AA:BB:CC:DD:EE:FF\r\n"])).to eq(true)
      expect(enqueued?(["> HCI Event: LE Meta Event (0x3e) plen 42\r\n", "      LE Advertising Report (0x02)\r\n"])).to eq(true)
    end

    it "applies the second-line condition for Command Complete (0x0e)" do
      expect(enqueued?(["> HCI Event: Command Complete (0x0e) plen 4\r\n", "        Foo\r\n"])).to eq(false)
      expect(enqueued?(["> HCI Event: Command Complete (0x0e) plen 4\r\n", "        Remote Name blah\r\n"])).to eq(true)
    end

    it "drops non-success connect/remote-name complete (0x03/0x07) so it can time out" do
      expect(enqueued?(["> HCI Event: Connect Complete (0x03) plen 11\r\n", "        Status: Page Timeout (0x04)\r\n"])).to eq(false)
      expect(enqueued?(["> HCI Event: Connect Complete (0x03) plen 11\r\n", "        Status: Success (0x00)\r\n"])).to eq(true)
    end

    it "drops monitor notes and index bookkeeping, bare and prefixed = Note" do
      expect(enqueued?(["= New Index: AA:BB:CC:DD:EE:FF (BR/EDR,USB,hci0)\r\n"])).to eq(false)
      expect(enqueued?(["= Index Info: AA:BB:CC:DD:EE:FF (BR/EDR)\r\n"])).to eq(false)
      expect(enqueued?(["= Note: Linux version 6.1\r\n"])).to eq(false)
      expect(enqueued?(["foo[12]: = Note: Linux version 6.1\r\n"])).to eq(false)
    end

    it "drops the monitor version banner" do
      expect(enqueued?(["Bluetooth monitor ver 5.72\r\n"])).to eq(false)
    end
  end
end
