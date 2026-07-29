require 'spec_helper'

describe BlueHydra::Chunker do
  it "can determine if a message indicates a new host" do
    yep1 = ["> HCI Event: Connect Complete (0x03) plen 11         2015-12-10 11:30:24.387882\r\n",
            "        Status: Page Timeout (0x04)\r\n",
            "        Handle: 65535\r\n",
            "        Address: D6:87:40:44:B1:4F (OUI D6-87-40)\r\n",
            "        Link type: ACL (0x01)\r\n",
            "        Encryption: Disabled (0x00)\r\n"]
    yep2 = ["> HCI Event: Role Change (0x12) plen 8               2015-12-10 11:31:08.667931\r\n",
            "        Status: Success (0x00)\r\n",
            "        Address: 8C:2D:AA:7F:58:8C (Apple)\r\n",
            "        Role: Slave (0x01)\r\n"]
    yep3 = ["> HCI Event: LE Meta Event (0x3e) plen 19            2015-12-10 11:30:58.880870\r\n",
             "      LE Connection Complete (0x01)\r\n",
             "        Status: Success (0x00)\r\n",
             "        Handle: 3585\r\n",
             "        Role: Master (0x00)\r\n",
             "        Peer address type: Public (0x00)\r\n",
             "        Peer address: 80:EA:CA:68:02:C1 (Dialog Semiconductor Hellas SA)\r\n",
             "        Connection interval: 18.75 msec (0x000f)\r\n",
             "        Connection latency: 0.00 msec (0x0000)\r\n",
             "        Supervision timeout: 32000 msec (0x0c80)\r\n",
             "        Master clock accuracy: 0x00\r\n"]

    nope1 = ["Bluetooth monitor ver 5.35\r\n"]
    nope2 = ["= New Index: 5C:C5:D4:11:33:79 (BR/EDR,USB,hci1)     2015-12-10 11:29:46.064195\r\n"]
    nope3 = ["> HCI Event: Disconnect Complete (0x05) plen 4       2015-12-10 11:30:58.970878\r\n",
             "        Status: Success (0x00)\r\n",
             "        Handle: 3585\r\n",
             "        Reason: Connection Terminated By Local Host (0x16)\r\n"]

    q1 = Queue.new
    q2 = Queue.new
    chunker = BlueHydra::Chunker.new(q1, q2)
    expect(chunker.starting_chunk?(yep1)).to eq(true)
    expect(chunker.starting_chunk?(yep2)).to eq(true)
    expect(chunker.starting_chunk?(yep3)).to eq(true)

    expect(chunker.starting_chunk?(nope1)).to eq(false)
    expect(chunker.starting_chunk?(nope2)).to eq(false)
    expect(chunker.starting_chunk?(nope3)).to eq(false)
  end

  it "treats an MGMT Device Found event as a chunk start" do
    chunker = BlueHydra::Chunker.new(Queue.new, Queue.new)

    device_found = ["@ MGMT Event: Device Found (0x0012) plen 14\r\n",
                    "        LE Address: DE:AD:BE:EF:CA:FE (Resolvable)\r\n"]
    expect(chunker.starting_chunk?(device_found)).to eq(true)

    # a different MGMT event is not a chunk start
    other_mgmt = ["@ MGMT Event: Discovering (0x0013) plen 2\r\n"]
    expect(chunker.starting_chunk?(other_mgmt)).to eq(false)
  end

  it "can chunk up a queue of message blocks" do
    filepath = File.expand_path('../fixtures/btmon.stdout', __FILE__)
    command = "cat #{filepath} && sleep 1"
    queue1 = Queue.new
    queue2 = Queue.new

    begin
      handler = BlueHydra::BtmonHandler.new(command, queue1)
    rescue BtmonExitedError
      # will be raised in file mode
    end

    chunker = BlueHydra::Chunker.new(queue1, queue2)

    t = Thread.new do
      chunker.chunk_it_up
    end

    expect(chunker.starting_chunk?(queue2.pop.first)).to eq(true)
  end

  it "injects a last_seen timestamp parsed from the btmon header" do
    header_ts = "2015-12-10 11:31:08.667931"
    msg1 = ["> HCI Event: Role Change (0x12) plen 8               #{header_ts}\r\n",
            "        Status: Success (0x00)\r\n",
            "        Address: 8C:2D:AA:7F:58:8C (Apple)\r\n"]
    # a second starting chunk is what causes msg1's working set to be flushed
    msg2 = ["> HCI Event: Role Change (0x12) plen 8               2015-12-10 11:32:00.123456\r\n",
            "        Status: Success (0x00)\r\n",
            "        Address: 8C:2D:AA:7F:58:8C (Apple)\r\n"]

    incoming = Queue.new
    outgoing = Queue.new
    incoming.push(msg1)
    incoming.push(msg2)

    chunker = BlueHydra::Chunker.new(incoming, outgoing)
    t = Thread.new { chunker.chunk_it_up }

    begin
      working_set = Timeout.timeout(5) { outgoing.pop }
    ensure
      t.kill
    end

    # the chunker appends "last_seen: <epoch>" as the final line of the message
    last_seen_line = working_set.first.last
    expect(last_seen_line).to match(/^last_seen: \d+$/)

    # strptime must produce the same integer epoch the original Time.parse did,
    # including the same local-time interpretation
    expected = Time.parse(header_ts).to_i
    expect(last_seen_line.split(': ')[1].to_i).to eq(expected)
  end

  describe "#chunk_it_up flushing, routing and chunk logging" do
    let(:chunk_log) { double("chunk_logger", info: nil) }

    before do
      @orig_debug  = BlueHydra.config["chunker_debug"]
      @orig_ignore = BlueHydra.config["ignore_mac"]
      BlueHydra.config["chunker_debug"] = false
      BlueHydra.config["ignore_mac"]    = []
      allow(BlueHydra).to receive(:chunk_logger).and_return(chunk_log)
      allow(BlueHydra).to receive(:send_event)
      allow(BlueHydra.logger).to receive(:warn)
    end

    after do
      BlueHydra.config["chunker_debug"] = @orig_debug
      BlueHydra.config["ignore_mac"]    = @orig_ignore
    end

    # Feed `messages` as one chunk, then a trailing start block to force that
    # working set to flush. Returns the chunks pushed to the parser (the
    # trailing block itself is never flushed, so it does not affect assertions).
    def flush_chunk(messages)
      incoming = Queue.new
      outgoing = Queue.new
      messages.each { |m| incoming.push(m) }
      incoming.push([
        "> HCI Event: Inquiry Result with RSSI (0x22) plen 1   #999 2026-07-28 16:07:59.999999\r\n",
        "        Address: 99:99:99:99:99:99 (OUI 99-99-99)\r\n"
      ])
      incoming.close
      BlueHydra::Chunker.new(incoming, outgoing).chunk_it_up
      pushed = []
      pushed << outgoing.pop until outgoing.empty?
      pushed
    end

    # ---- message building blocks -------------------------------------------
    # a start block (Inquiry Result with RSSI, 0x22) carrying one address line
    def inquiry(mac)
      ["> HCI Event: Inquiry Result with RSSI (0x22) plen 1   #1 2026-07-28 16:07:00.100000\r\n",
       "        Address: #{mac} (OUI AA-BB-CC)\r\n"]
    end

    # a non-start block (Read Remote Supported Features, 0x0b) whose new-format
    # line carries an address, so it merges into the current chunk and adds an
    # address line
    def remote_features(mac)
      ["> HCI Event: Read Remote Supported Features (0x0b) plen 11   #2 2026-07-28 16:07:00.200000\r\n",
       "        Status: Success (0x00)\r\n",
       "        Handle: 256 Address: #{mac} (OUI AA-BB-CC)\r\n"]
    end

    # a start block (Command Complete, 0x0e) with no address line at all
    def no_address
      ["> HCI Event: Command Complete (0x0e) plen 4   #1 2026-07-28 16:07:00.100000\r\n",
       "        Some Field: 0x00\r\n"]
    end

    def counter
      BlueHydra::CliUserInterfaceTracker.multi_address_chunk_count
    end

    def zero_counter
      BlueHydra::CliUserInterfaceTracker.zero_address_chunk_count
    end

    def unique_counter
      BlueHydra::CliUserInterfaceTracker.multi_unique_address_chunk_count
    end

    it "pushes a normal single-address chunk without counting or chunk-logging it" do
      before_count = counter
      pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA")])

      expect(pushed.size).to eq(1)
      expect(counter - before_count).to eq(0)
      expect(chunk_log).not_to have_received(:info)
      expect(BlueHydra).not_to have_received(:send_event)
      expect(BlueHydra.logger).not_to have_received(:warn)
    end

    it "processes and counts a same-MAC multi-line chunk without chunk-logging when debug is off" do
      before_count = counter
      pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA"), remote_features("AA:AA:AA:AA:AA:AA")])

      expect(pushed.size).to eq(1)                       # still processed
      expect(counter - before_count).to eq(1)            # counted
      expect(chunk_log).not_to have_received(:info)      # chunk log only in debug
      expect(BlueHydra).not_to have_received(:send_event) # not treated as corrupt
      expect(BlueHydra.logger).not_to have_received(:warn)
    end

    it "chunk-logs a same-MAC multi-line chunk when chunker_debug is on (still processed and counted)" do
      BlueHydra.config["chunker_debug"] = true
      before_count = counter
      pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA"), remote_features("AA:AA:AA:AA:AA:AA")])

      expect(pushed.size).to eq(1)                       # still processed
      expect(counter - before_count).to eq(1)            # counted
      expect(chunk_log).to have_received(:info).at_least(:once) # chunk-logged in debug
      expect(BlueHydra).not_to have_received(:send_event)
      expect(BlueHydra.logger).not_to have_received(:warn)
    end

    it "does not push a chunk whose address is in ignore_mac" do
      BlueHydra.config["ignore_mac"] = ["AA:AA:AA:AA:AA:AA"]
      pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA")])
      expect(pushed).to be_empty
    end

    context "a chunk with no addresses" do
      it "warns and does not chunk-log when chunker_debug is off" do
        before_count = counter
        before_zero  = zero_counter
        pushed = flush_chunk([no_address])

        expect(pushed).to be_empty
        expect(counter - before_count).to eq(0)        # not a multi-address-line chunk
        expect(zero_counter - before_zero).to eq(1)    # counted as a 0-address chunk
        expect(chunk_log).not_to have_received(:info)
        expect(BlueHydra.logger).to have_received(:warn).with(/no addresses/)
        expect(BlueHydra).to have_received(:send_event).with('blue_hydra', hash_including(key: 'bluehydra_chunk_0_address'))
      end

      it "chunk-logs and does not warn when chunker_debug is on" do
        BlueHydra.config["chunker_debug"] = true
        before_zero = zero_counter
        pushed = flush_chunk([no_address])

        expect(pushed).to be_empty
        expect(zero_counter - before_zero).to eq(1)
        expect(chunk_log).to have_received(:info).at_least(:once)
        expect(BlueHydra.logger).not_to have_received(:warn)
        expect(BlueHydra).to have_received(:send_event).with('blue_hydra', hash_including(key: 'bluehydra_chunk_0_address'))
      end
    end

    context "a chunk with more than one unique address (missing start block)" do
      it "counts, warns and discards but does NOT chunk-log when chunker_debug is off" do
        before_count  = counter
        before_unique = unique_counter
        pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA"), remote_features("BB:BB:BB:BB:BB:BB")])

        expect(pushed).to be_empty                              # discarded
        expect(counter - before_count).to eq(1)                 # counted as multi-address-line
        expect(unique_counter - before_unique).to eq(1)         # and as multi-unique-address
        expect(chunk_log).not_to have_received(:info)           # chunk log only in debug
        expect(BlueHydra.logger).to have_received(:warn).with(/multiple address/)  # warn is unconditional
        expect(BlueHydra).to have_received(:send_event).with('blue_hydra', hash_including(key: 'bluehydra_chunk_2_address'))
      end

      it "counts, chunk-logs, warns and discards when chunker_debug is on" do
        BlueHydra.config["chunker_debug"] = true
        before_count  = counter
        before_unique = unique_counter
        pushed = flush_chunk([inquiry("AA:AA:AA:AA:AA:AA"), remote_features("BB:BB:BB:BB:BB:BB")])

        expect(pushed).to be_empty
        expect(counter - before_count).to eq(1)
        expect(unique_counter - before_unique).to eq(1)
        expect(chunk_log).to have_received(:info).at_least(:once)  # chunk-logged in debug
        expect(BlueHydra.logger).to have_received(:warn).with(/multiple address/)  # warn is unconditional
        expect(BlueHydra).to have_received(:send_event).with('blue_hydra', hash_including(key: 'bluehydra_chunk_2_address'))
      end
    end
  end
end
