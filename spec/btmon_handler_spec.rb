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
      _handler = BlueHydra::BtmonHandler.new(command, queue)
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

    # btmon decodes connection payloads instead of hex-dumping them, and the
    # decoded L2CAP field names collide with device attributes the parser stores.
    # See BtmonHandler::ACL_DATA_RE.
    it "drops connection payload (ACL/SCO/ISO data) messages" do
      l2cap_info_response = [
        "> BR-ACL: Handle 256 [02:00:13:00:00:39 (OUI 02-00-13)] flags 0x02 dlen 16\r\n",
        "      L2CAP: Information Response (0x0b) ident 1 len 8\r\n",
        "        Features: 0x000000b8\r\n",
        "          Enhanced Retransmission Mode\r\n",
        "          Streaming Mode\r\n"
      ]
      expect(enqueued?(l2cap_info_response)).to eq(false)

      expect(enqueued?(["> LE-ACL: Handle 2048 [AA:BB:CC:DD:EE:FF] flags 0x02 dlen 7\r\n",
                        "      ATT: Read Request (0x0a) len 2\r\n"])).to eq(false)
      # the older directional spelling, still used for SCO/ISO
      expect(enqueued?(["> ACL Data RX: Handle 256 flags 0x02 dlen 10\r\n"])).to eq(false)
      expect(enqueued?(["> SCO Data RX: Handle 257 flags 0x00 dlen 48\r\n"])).to eq(false)
      expect(enqueued?(["> ISO Data RX: Handle 258 flags 0x00 dlen 20\r\n"])).to eq(false)
      expect(enqueued?(["> ISO Data: Handle 258 flags 0x00 dlen 20\r\n"])).to eq(false)

      # and a real HCI event still gets through, i.e. the rule is not too greedy
      expect(enqueued?(["> HCI Event: Extended Inquiry Result (0x2f) plen 255\r\n",
                        "        Address: AA:BB:CC:DD:EE:FF\r\n"])).to eq(true)
    end

    # the exact corruption this drop exists to prevent: those L2CAP "Features:"
    # lines are stored by the parser as the DEVICE's LMP feature set
    it "keeps L2CAP channel features out of the device's feature attributes" do
      chunk = [
        "      L2CAP: Information Response (0x0b) ident 1 len 8\r\n",
        "        Features: 0x000000b8\r\n",
        "          Enhanced Retransmission Mode\r\n",
        "          Streaming Mode\r\n",
        "last_seen: #{Time.now.to_i}"
      ]
      # shown against the parser directly, since the point is what WOULD happen
      # if such a message ever reached it
      parser = BlueHydra::Parser.new([["> BR-ACL: Handle 256 [AA:BB:CC:DD:EE:FF] dlen 16\r\n"] + chunk])
      parser.parse
      expect(parser.attributes[:classic_features])
        .to eq(["Enhanced Retransmission Mode, Streaming Mode"])

      # ...which is why the handler never lets one through
      expect(enqueued?(["> BR-ACL: Handle 256 [AA:BB:CC:DD:EE:FF] dlen 16\r\n"] + chunk[0..-2])).to eq(false)
    end

    # A GATT Walk's ATT traffic rides the Att_Bearer's LE link as ACL data, so
    # every request we send and every response the peer returns appears in
    # btmon decoded (L2CAP / ATT), and the decoded field names ("UUID:",
    # "Handle range:") are exactly what parser branches key on. None of it may
    # reach raw_queue - the queue injected by enqueued? is what Runner hands the
    # handler as raw_queue - whichever way bluez spells the header, whichever
    # direction the data flowed, and with or without the "toolname[pid]: "
    # prefix. Requirements 15.1 and 15.4 of the gatt-service-scanning spec.
    describe "ATT traffic from a GATT Walk" do
      # decoded ATT bodies as btmon prints them, quoted from
      # spec/fixtures/btmon.stdout (BlueZ 5.3x) and btmon_raw_1789672574.log
      # (BlueZ 5.8x, a bluetoothd-driven walk): the MTU exchange, primary
      # service discovery, a Device Name read and an Error Response, both ends
      let(:att_bodies) do
        [
          ["      ATT: Exchange MTU Request (0x02) len 2\r\n",
           "        Client RX MTU: 517\r\n"],
          ["      ATT: Exchange MTU Response (0x03) len 2\r\n",
           "        Server RX MTU: 23\r\n"],
          ["      ATT: Read By Group Type Request (0x10) len 6\r\n",
           "        Handle range: 0x0001-0xffff\r\n",
           "        Attribute group type: Primary Service (0x2800)\r\n"],
          ["      ATT: Read By Group Type Response (0x11) len 19\r\n",
           "        Attribute data length: 6\r\n",
           "        Attribute group list: 3 entries\r\n",
           "        Handle range: 0x0001-0x0009\r\n",
           "        UUID: Generic Access Profile (0x1800)\r\n",
           "        Handle range: 0x000a-0x000f\r\n",
           "        UUID: Generic Attribute Profile (0x1801)\r\n",
           "        Handle range: 0x0010-0x001c\r\n",
           "        UUID: Device Information (0x180a)\r\n"],
          ["      ATT: Read By Group Type Response (0x11) len 21\r\n",
           "        Attribute data length: 20\r\n",
           "        Attribute group list: 1 entry\r\n",
           "        Handle range: 0x0006-0x0010\r\n",
           "        UUID: Vendor specific (00000211-b2d1-43f0-9b88-960cebf8b91e)\r\n"],
          ["      ATT: Read By Type Request (0x08) len 6\r\n",
           "        Handle range: 0x0001-0xffff\r\n",
           "        Attribute type: Device Name (0x2a00)\r\n"],
          ["      ATT: Read Request (0x0a) len 2\r\n",
           "        Handle: 0x0005 Type: Appearance (0x2a01)\r\n"],
          ["      ATT: Read Response (0x0b) len 15\r\n",
           "        Handle: 0x0003 Type: Device Name (0x2a00)\r\n",
           "        Value[15]:\r\n",
           "        44 45 56 49 43 45 2d 42 30 30 30 30 30 30 31     DEVICE-B0000001 \r\n"],
          ["      ATT: Error Response (0x01) len 4\r\n",
           "        Read By Type Request (0x08)\r\n",
           "        Handle: 0x0001\r\n",
           "        Error: Attribute Not Found (0x0a)\r\n"]
        ]
      end

      # decoded L2CAP bodies on the same links: LE signalling (CID 5) quoted
      # from btmon_raw_1790024381.log, the classic Information Response whose
      # "Features:" motivated ACL_DATA_RE, and the undecoded channel line btmon
      # falls back to when it has no decoder for a CID
      let(:l2cap_bodies) do
        [
          ["      LE L2CAP: Connection Parameter Update Request (0x12) ident 69 len 8\r\n",
           "        Min interval: 12\r\n",
           "        Max interval: 12\r\n",
           "        Peripheral latency: 0\r\n",
           "        Timeout multiplier: 400\r\n"],
          ["      L2CAP: Information Response (0x0b) ident 1 len 8\r\n",
           "        Features: 0x000000b8\r\n",
           "          Enhanced Retransmission Mode\r\n",
           "          Streaming Mode\r\n"],
          ["      Channel: 4 len 7 [PSM 0 mode Basic (0x00)] {chan 0}\r\n",
           "        02 17 00                                         ...\r\n"]
        ]
      end

      # the header after the spelling: the link-type forms bracket the peer
      # address, the older directional forms carry only the handle
      let(:header_tails) do
        {
          "LE-ACL"      => "Handle 2048 [C2:00:00:00:00:18 (Static)] flags 0x02 dlen 7",
          "BR-ACL"      => "Handle 256 [02:00:13:00:00:39 (OUI 02-00-13)] flags 0x02 dlen 16",
          "ACL Data RX" => "Handle 3585 flags 0x02 dlen 7",
          "ACL Data TX" => "Handle 3585 flags 0x00 dlen 7"
        }
      end

      # every spelling x direction x prefix form, so a header that should have
      # matched ACL_DATA_RE but did not shows up by name
      def each_acl_header
        header_tails.each do |spelling, tail|
          [">", "<"].each do |direction|
            ["", "ruby[2062621]: ", "bluetoothd[1210]: "].each do |prefix|
              yield "#{prefix}#{direction} #{spelling}: #{tail}\r\n"
            end
          end
        end
      end

      it "every spelling, direction and prefix form is one ACL_DATA_RE claims" do
        each_acl_header do |first|
          stripped = first.sub(BlueHydra::BtmonHandler::TOOL_PREFIX_RE, "")
          expect(stripped).to match(BlueHydra::BtmonHandler::ACL_DATA_RE),
            "ACL_DATA_RE does not match #{first.inspect}"
        end
      end

      it "pushes nothing onto raw_queue for ACL data carrying decoded ATT lines" do
        each_acl_header do |first|
          att_bodies.each do |body|
            expect(enqueued?([first] + body)).to eq(false),
              "expected nothing on raw_queue for #{first.inspect} + #{body.first.strip.inspect}"
          end
        end
      end

      it "pushes nothing onto raw_queue for ACL data carrying decoded L2CAP lines" do
        each_acl_header do |first|
          l2cap_bodies.each do |body|
            expect(enqueued?([first] + body)).to eq(false),
              "expected nothing on raw_queue for #{first.inspect} + #{body.first.strip.inspect}"
          end
        end
      end

      # the exact text two btmon generations print for a Walk's opening
      # exchange, trailing frame/timestamp columns included
      it "drops a Walk's MTU exchange and service discovery as btmon prints them" do
        # BlueZ 5.3x directional spelling, spec/fixtures/btmon.stdout
        expect(enqueued?([
          "< ACL Data TX: Handle 3585 flags 0x00 dlen 7         2015-12-10 11:30:58.881165\r\n",
          "      ATT: Exchange MTU Request (0x02) len 2\r\n",
          "        Client RX MTU: 517\r\n"])).to eq(false)
        expect(enqueued?([
          "> ACL Data RX: Handle 3585 flags 0x02 dlen 7         2015-12-10 11:30:58.913518\r\n",
          "      ATT: Exchange MTU Response (0x03) len 2\r\n",
          "        Server RX MTU: 23\r\n"])).to eq(false)
        expect(enqueued?([
          "> ACL Data RX: Handle 3585 flags 0x02 dlen 24        2015-12-10 11:30:58.951169\r\n",
          "      ATT: Read By Group Type Response (0x11) len 19\r\n",
          "        Attribute data length: 6\r\n",
          "        Attribute group list: 3 entries\r\n",
          "        Handle range: 0x0001-0x0009\r\n",
          "        UUID: Generic Access Profile (0x1800)\r\n",
          "        Handle range: 0x000a-0x000f\r\n",
          "        UUID: Generic Attribute Profile (0x1801)\r\n",
          "        Handle range: 0x0010-0x001c\r\n",
          "        UUID: Device Information (0x180a)\r\n"])).to eq(false)

        # BlueZ 5.8x link-type spelling, with the tool prefix bluez adds on
        # the sending side, spec/fixtures/btmon_raw_1789672574.log
        expect(enqueued?([
          "bluetoothd[5287]: < LE-ACL: Handle 2048 [1/6] [02:00:14:00:00:40 (OUI 02-00-14)    ] flags 0x00 dlen 11                                   #305 2026-09-17 15:16:36.985921\r\n",
          "      ATT: Read By Group Type Request (0x10) len 6\r\n",
          "        Handle range: 0x0001-0xffff\r\n",
          "        Attribute group type: Primary Service (0x2800)\r\n"])).to eq(false)
        expect(enqueued?([
          "> LE-ACL: Handle 2050 [02:00:04:00:00:14 (OUI 02-00-04)  ] flags 0x02 dlen 20                                                             #424 2026-09-17 15:16:38.148555\r\n",
          "      ATT: Read Response (0x0b) len 15\r\n",
          "        Handle: 0x0003 Type: Device Name (0x2a00)\r\n",
          "        Value[15]:\r\n",
          "        44 45 56 49 43 45 2d 42 30 30 30 30 30 30 31     DEVICE-B0000001 \r\n"])).to eq(false)
      end

      # Every ATT PDU the controller sends is acknowledged with a Number of
      # Completed Packets event, and bluez monitor resolves the handle to the
      # peer's address on the handle line. It is not a chunk start, so one that
      # reached raw_queue would merge the walked device's address into whichever
      # chunk is open. HCI_DROP_CODES already carries 0x13; this pins it for the
      # address-bearing form a Walk produces (Requirement 15.4).
      it "pushes nothing for Number of Completed Packets whose handle line carries the walked device's address" do
        # the acknowledgement of a Read By Type Request, as printed in
        # spec/fixtures/btmon_raw_1789672574.log, frame/timestamp columns included
        expect(enqueued?([
          "> HCI Event: Number of Completed Packets (0x13) plen 5                                                                                    #303 2026-09-17 15:16:36.895169\r\n",
          "        Num handles: 1\r\n",
          "        Handle: 2048 (LE-ACL) Address: 02:00:14:00:00:40 (OUI 02-00-14)\r\n",
          "        Count: 1\r\n"])).to eq(false)

        # a walked private-address device, tool-prefixed header
        expect(enqueued?([
          "ruby[2062621]: > HCI Event: Number of Completed Packets (0x13) plen 5\r\n",
          "        Num handles: 1\r\n",
          "        Handle: 3584 (LE-ACL) Address: 7A:BB:CC:DD:EE:FF (Resolvable)\r\n",
          "        Count: 1\r\n"])).to eq(false)

        # two Walks in flight: one event acknowledging packets on both links
        expect(enqueued?([
          "> HCI Event: Number of Completed Packets (0x13) plen 9\r\n",
          "        Num handles: 2\r\n",
          "        Handle: 2048 (LE-ACL) Address: C2:00:00:00:00:18 (Static)\r\n",
          "        Count: 1\r\n",
          "        Handle: 2049 (LE-ACL) Address: 7A:BB:CC:DD:EE:FF (Resolvable)\r\n",
          "        Count: 2\r\n"])).to eq(false)
      end
    end
  end

  describe "btmon --color=never handling" do
    it "detects color-never support from the real btmon --help format" do
      handler = BlueHydra::BtmonHandler.allocate

      # BlueZ 5.86 advertises the option as "-c, --color [mode]" with the modes
      # listed separately (auto/always/never) - the literal "--color=never" is
      # never printed, which is why the old exact-substring check missed it.
      allow(handler).to receive(:btmon_help).and_return(
        "Usage:\n\tbtmon [options]\nOptions:\n\t-c, --color [mode]     Output color: auto/always/never\n\t-w, --write <file>     Save traces\n"
      )
      expect(handler.color_never_supported?).to eq(true)

      # also match an explicit "--color=never" spelling if a build uses it
      allow(handler).to receive(:btmon_help).and_return(
        "Options:\n\t--color=never  Disable colored output\n"
      )
      expect(handler.color_never_supported?).to eq(true)

      # older btmon with no color option at all
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

  describe "truncated/wrapped btmon output detection" do
    before { BlueHydra::CliUserInterfaceTracker.truncation_detected_count = 0 }

    it "counts every truncated line but warns/alerts only once" do
      handler = BlueHydra::BtmonHandler.allocate
      logger  = double("logger")
      allow(BlueHydra).to receive(:logger).and_return(logger)

      # the warn log and event are gated so they fire once, not per line
      expect(logger).to receive(:warn).once
      expect(BlueHydra).to receive(:send_event).once.with(
        'blue_hydra', hash_including(key: 'blue_hydra_btmon_truncated_output', severity: 'WARN')
      )

      # btmon truncates the name with ".." and wraps when --columns is too small
      handler.check_for_truncation("< HCI Command: Write Scan.. (0x03|0x001a) plen 1")
      handler.check_for_truncation("< HCI Command: LE Set Ext.. (0x08|0x0039) plen 2")
      handler.check_for_truncation("< HCI Command: LE Clear A.. (0x08|0x003d) plen 0")

      # the counter is NOT gated - every truncated line is counted
      expect(BlueHydra::CliUserInterfaceTracker.truncation_detected_count).to eq(3)
    end

    it "does not count, warn, or alert on full-width (untruncated) output" do
      handler = BlueHydra::BtmonHandler.allocate
      logger  = double("logger")
      allow(BlueHydra).to receive(:logger).and_return(logger)

      expect(logger).not_to receive(:warn)
      expect(BlueHydra).not_to receive(:send_event)

      handler.check_for_truncation("< HCI Command: Write Scan Enable (0x03|0x001a) plen 1")
      handler.check_for_truncation("        Status: Success (0x00)")

      expect(BlueHydra::CliUserInterfaceTracker.truncation_detected_count).to eq(0)
    end
  end

  describe "gzip log durability" do
    # flush_writer uses Zlib::SYNC_FLUSH, which raises Zlib::BufError when there
    # is nothing new to flush (e.g. an interval where every line was filtered
    # out). That previously crashed the btmon thread; flush_writer must swallow
    # it.
    it "flush_writer swallows Zlib::BufError when there is nothing new to flush" do
      require 'zlib'
      require 'tempfile'
      handler = BlueHydra::BtmonHandler.allocate
      file = Tempfile.new(['bh_flush', '.gz'])
      gz   = Zlib::GzipWriter.wrap(File.open(file.path, 'wb'))

      gz.puts("first line")
      handler.flush_writer(gz)                                 # flush real data - fine
      expect { handler.flush_writer(gz) }.not_to raise_error   # nothing new -> BufError guarded
      expect { handler.flush_writer(gz) }.not_to raise_error

      gz.close
      file.unlink
    end

    # opening the gzip log in binary mode ('wb') avoids the ASCII-8BIT -> UTF-8
    # conversion crash; here we confirm the resulting file is a valid,
    # decodable gzip after periodic flushes + close.
    it "writes a valid, decodable gzip log through periodic flushes" do
      require 'zlib'
      require 'tempfile'
      handler = BlueHydra::BtmonHandler.allocate
      file = Tempfile.new(['bh_valid', '.gz'])
      gz   = Zlib::GzipWriter.wrap(File.open(file.path, 'wb'))

      gz.puts("line one"); handler.flush_writer(gz)
      gz.puts("line two"); handler.flush_writer(gz)
      gz.close

      expect(Zlib::GzipReader.open(file.path, &:read)).to eq("line one\nline two\n")
      file.unlink
    end
  end
end
