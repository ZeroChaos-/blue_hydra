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
end
