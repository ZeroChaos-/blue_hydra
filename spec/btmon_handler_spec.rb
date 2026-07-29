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

  describe "btmon --color=never handling" do
    it "detects --color=never support from btmon --help" do
      handler = BlueHydra::BtmonHandler.allocate

      allow(handler).to receive(:btmon_help).and_return(
        "Usage:\n\tbtmon [options]\nOptions:\n\t--color=never  Disable colored output\n"
      )
      expect(handler.color_never_supported?).to eq(true)

      # older btmon without the flag
      allow(handler).to receive(:btmon_help).and_return(
        "Usage:\n\tbtmon [options]\nOptions:\n\t-w, --write <file>  Save traces\n"
      )
      expect(handler.color_never_supported?).to eq(false)
    end

    it "disables the color-stripping gsub and adds --color=never when supported" do
      supported = BlueHydra::BtmonHandler.allocate
      supported.instance_variable_set(:@command, "btmon --columns 170 -T -i hci0")
      allow(supported).to receive(:color_never_supported?).and_return(true)

      supported.configure_color_handling

      expect(supported.instance_variable_get(:@strip_colors)).to eq(false)
      expect(supported.instance_variable_get(:@command)).to include("--color=never")

      # older btmon without the flag keeps stripping and is left unmodified
      legacy = BlueHydra::BtmonHandler.allocate
      legacy.instance_variable_set(:@command, "btmon --columns 170 -T -i hci0")
      allow(legacy).to receive(:color_never_supported?).and_return(false)

      legacy.configure_color_handling

      expect(legacy.instance_variable_get(:@strip_colors)).to eq(true)
      expect(legacy.instance_variable_get(:@command)).not_to include("--color=never")
    end

    it "still strips color codes when reading from a file" do
      require 'tempfile'
      # a color-coded btmon message (as raw btmon logs contain) that passes the
      # enqueue filter (Extended Inquiry Result, 0x2f)
      content =
        "\e[0;35m> HCI Event: Extended Inquiry Result\e[0m (0x2f) plen 255   2015-12-10 11:30:24.387882\r\n" \
        "        Address: \e[0;33mDE:AD:BE:EF:CA:FE\e[0m (OUI DE-AD-BE)\r\n"

      file = Tempfile.new(['btmon_colored', '.log'])
      file.write(content)
      file.close

      queue = Queue.new
      begin
        # file mode (command does not start with "btmon") -> should still strip
        BlueHydra::BtmonHandler.new("cat #{file.path}", queue)
      rescue BtmonExitedError
        # expected at end of file
      end

      expect(queue.empty?).to eq(false)
      joined = queue.pop.join
      expect(joined).not_to include("\e[")            # no ANSI escapes remain
      expect(joined).to include("Extended Inquiry Result")
      expect(joined).to include("DE:AD:BE:EF:CA:FE")
    ensure
      file.unlink if file
    end
  end
end
