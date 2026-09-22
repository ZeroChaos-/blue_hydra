require 'spec_helper'

describe BlueHydra::Parser do

  it "can calculate the indentation of a given line" do
    p = BlueHydra::Parser.new

    lines = [
      'test line',
      ' test line',
      '  test line',
      '   test line',
      '    test line',
      '     test line'
    ]

    lines.each_with_index do |ln, i|
      expect(p.line_depth(ln)).to eq(i)
    end
  end

  it "groups arrays of strings by whitespace depth" do
    p = BlueHydra::Parser.new
    x, y, z = "x", " y", "  z"

    a = [ x, x ]
    b = [ x, y ]
    c = [ x, x, y, y, z, x, y]

    ra = p.group_by_depth(a)
    rb = p.group_by_depth(b)
    rc = p.group_by_depth(c)
    expect(ra).to eq([[x],[x]])
    expect(rb).to eq([[x,y]])
    expect(rc).to eq([[x], [x, y, y, z], [x, y]])
  end


  it "converts a chunk of info about a device into a hash of attributes" do
    filepath = File.expand_path('../fixtures/btmon.stdout', __FILE__)
    command = "cat #{filepath} && sleep 1"
    queue1  = Queue.new
    queue2  = Queue.new

    begin
      handler = BlueHydra::BtmonHandler.new(command, queue1)
    rescue BtmonExitedError
      # will be raised in file mode
    end

    chunker = BlueHydra::Chunker.new(queue1, queue2)

    t = Thread.new do
      chunker.chunk_it_up
    end

    chunks = []

    sleep 2 # let the chunker chunk

    until queue2.empty?
      chunks << queue2.pop
    end

    parsers = chunks.map do |c|
      p = BlueHydra::Parser.new(c)
      p.parse
      p
    end

    addrs = parsers.map do |p|
      p.attributes[:address]
    end.reject{|x| x == nil }

    addrs_per_device = addrs.map(&:uniq).map(&:count).uniq
    expect(addrs_per_device).to eq([1]) # 1 addr per device :)
  end

  it "extracts the address and lmp_version from a combined 'Handle: N Address: MAC' version event" do
    # Current btmon puts the handle and address on one line. The /^Handle:/ case
    # is matched before /^Address:/, so it must also pull the address out - else
    # attributes[:address] is nil and the whole result (incl. the version) is
    # dropped in the parser thread, which is why remote versions never reached
    # the VERS column.
    chunk = [[
      "> HCI Event: Read Remote Version Complete (0x0c) plen 8   #5 2026-07-31 14:00:00.000000",
      "        Status: Success (0x00)",
      "        Handle: 256 Address: B0:D5:FB:98:FE:21 (Google, Inc.)",
      "        LMP version: Bluetooth 6.0 (0x0e) - Subversion 16904 (0x4208)",
      "        Manufacturer: Broadcom Corporation (15)",
      "last_seen: 1785521070"
    ]]

    p = BlueHydra::Parser.new(chunk)
    p.parse

    expect(p.attributes[:address]).to eq(["B0:D5:FB:98:FE:21"])
    expect(p.attributes[:lmp_version]).to eq(["Bluetooth 6.0 (0x0e) - Subversion 16904 (0x4208)"])
    expect(p.attributes[:classic_handle]).to eq(["256"]) # handle without the "Address" suffix

    # a version read is transport-agnostic; it must NOT assert classic_mode
    # (which would mislabel an LE device and make it a wasted l2ping candidate)
    expect(p.attributes[:classic_mode]).to be_nil
    expect(p.attributes[:le_mode]).to be_nil
  end

  it "does NOT assert classic_mode for a Disconnect Complete (transport-agnostic) event" do
    # Disconnect Complete (0x05) is shared by BR/EDR and LE ACL links and now
    # carries Handle+Address. Its second line is "Status:", so @bt_mode defaults
    # to classic - but stamping classic_mode=true here would mislabel every LE
    # device we auto-connect (each attempt produces a Disconnect Complete) and
    # flood the classic info_scan_queue with LE devices. It must only refresh
    # last_seen / address, never assert a transport.
    chunk = [[
      "> HCI Event: Disconnect Complete (0x05) plen 4   #190 2026-07-31 14:04:45.235779",
      "        Status: Success (0x00)",
      "        Handle: 2049 Address: F4:40:D1:9D:5A:63 (Static)",
      "        Reason: Connection Failed to be Established (0x3e)",
      "last_seen: 1785521085"
    ]]

    p = BlueHydra::Parser.new(chunk)
    p.parse

    expect(p.attributes[:address]).to eq(["F4:40:D1:9D:5A:63"])
    expect(p.attributes[:last_seen]).to eq([1785521085])
    expect(p.attributes[:classic_mode]).to be_nil
    expect(p.attributes[:le_mode]).to be_nil
  end
end

# A failed Read Remote Version Complete still carries a full payload, filled with
# Reserved (0xff) / Manufacturer 65535. Recording it overwrites a device's real
# version with junk, which is what happened on-device to 26 of 65 version reads.
describe "BlueHydra::Parser failed remote-version reads" do
  def version_chunk(status)
    [[
      "> HCI Event: Read Remote Version Complete (0x0c) plen 8",
      "        Status: #{status}",
      "        Handle: 2048 (LE-ACL) Address: EC:81:93:14:EC:07 (Logitech, Inc)",
      "        LMP version: #{status =~ /Success/ ? 'Bluetooth 5.0 (0x09) - Subversion 22 (0x0016)' : 'Reserved (0xff) - Subversion 65535 (0xffff)'}",
      "        Manufacturer: #{status =~ /Success/ ? 'Broadcom Corporation (15)' : 'Ericsson Technology Licensing (65535)'}",
      "last_seen: 1449747024"
    ]]
  end

  it "records the version when the read succeeded" do
    parser = BlueHydra::Parser.new(version_chunk("Success (0x00)"))
    parser.parse
    expect(parser.attributes[:lmp_version].first).to eq("Bluetooth 5.0 (0x09) - Subversion 22 (0x0016)")
    expect(parser.attributes[:address].first).to eq("EC:81:93:14:EC:07")
  end

  it "ignores the version when the read failed" do
    parser = BlueHydra::Parser.new(version_chunk("Connection Failed to be Established (0x3e)"))
    parser.parse
    expect(parser.attributes[:lmp_version]).to be_nil
    expect(parser.attributes[:manufacturer]).to be_nil
    # the address is still good - only the payload the failure invalidates is dropped
    expect(parser.attributes[:address].first).to eq("EC:81:93:14:EC:07")
  end

  it "does not suppress payloads on unrelated events that carry a status" do
    # an LE Connection Complete failure must not stop us recording other data
    chunk = [[
      "> HCI Event: LE Meta Event (0x3e) plen 19",
      "        LE Connection Complete (0x01)",
      "        Status: Unknown Connection Identifier (0x02)",
      "        Address: EC:81:93:14:EC:07 (Logitech, Inc)",
      "last_seen: 1449747024"
    ]]
    parser = BlueHydra::Parser.new(chunk)
    parser.parse
    expect(parser.attributes[:address].first).to eq("EC:81:93:14:EC:07")
  end
end

# Whether an advertiser declared itself connectable decides whether a connect to
# it could ever succeed. Over a 47 hour run 733 of 1329 attempted addresses had
# never once advertised as connectable - attempts that could not have worked. See
# BlueHydra::ConnectTracker and the connect_to_nonconnectable config.
describe "BlueHydra::Parser advertising connectability" do
  def parse(lines)
    chunk  = lines + ["last_seen: #{Time.now.to_i}"]
    parser = BlueHydra::Parser.new([chunk])
    parser.parse
    parser.attributes
  end

  # the extended form: a Props bitmask with the bits named underneath
  def extended(props, *flags)
    ["> HCI Event: LE Meta Event (0x3e) plen 57   #1 2026-09-21 08:52:19.588311\r\n",
     "      LE Extended Advertising Report (0x0d)\r\n",
     "        Num reports: 1\r\n",
     "        Entry 0\r\n",
     "          Event type: #{props}\r\n",
     "            Props: #{props}\r\n"] +
      flags.map { |f| "              #{f}\r\n" } +
      ["          Address type: Random (0x01)\r\n",
       "          Address: 7A:BB:CC:DD:EE:FF (Static)\r\n"]
  end

  context "extended advertising reports (0x0d)" do
    it "records connectable when the Connectable bit is named" do
      attrs = parse(extended("0x0013", "Connectable", "Scannable", "Use legacy advertising PDUs"))
      expect(attrs[:le_connectable]).to eq([true])
      expect(attrs[:address]).to eq(["7A:BB:CC:DD:EE:FF"])
    end

    it "records NOT connectable when the bit is absent" do
      attrs = parse(extended("0x0012", "Scannable", "Use legacy advertising PDUs"))
      expect(attrs[:le_connectable]).to eq([false])
    end

    it "records NOT connectable for a bare non-connectable beacon" do
      attrs = parse(extended("0x0010", "Use legacy advertising PDUs"))
      expect(attrs[:le_connectable]).to eq([false])
    end

    # btmon carries the Connectable bit onto the scan response of a connectable
    # advertiser, so SCAN_RSP needs no special case in the extended form
    it "records connectable from a scan response that kept the bit" do
      attrs = parse(extended("0x001b", "Connectable", "Scannable", "Scan response",
                             "Use legacy advertising PDUs"))
      expect(attrs[:le_connectable]).to eq([true])
    end
  end

  context "legacy advertising reports (0x02), which name the PDU on one line" do
    def legacy(event_type)
      ["> HCI Event: LE Meta Event (0x3e) plen 42   #1 2026-09-21 08:52:19.588311\r\n",
       "      LE Advertising Report (0x02)\r\n",
       "        Num reports: 1\r\n",
       "        Event type: #{event_type}\r\n",
       "        Address type: Random (0x01)\r\n",
       "        Address: 7A:BB:CC:DD:EE:FF (Static)\r\n"]
    end

    it "reads ADV_IND as connectable" do
      expect(parse(legacy("Connectable undirected - ADV_IND (0x00)"))[:le_connectable]).to eq([true])
    end

    it "reads ADV_DIRECT_IND as connectable" do
      expect(parse(legacy("Connectable directed - ADV_DIRECT_IND (0x01)"))[:le_connectable]).to eq([true])
    end

    # "Non connectable" must not match a naive search for "Connectable"
    it "reads ADV_NONCONN_IND as not connectable" do
      expect(parse(legacy("Non connectable undirected - ADV_NONCONN_IND (0x03)"))[:le_connectable])
        .to eq([false])
    end

    it "reads ADV_SCAN_IND as not connectable" do
      expect(parse(legacy("Scannable undirected - ADV_SCAN_IND (0x02)"))[:le_connectable]).to eq([false])
    end

    # a scan response says nothing either way, so it must record nothing rather
    # than record false
    it "records nothing for a bare scan response" do
      expect(parse(legacy("Scan response - SCAN_RSP (0x04)"))[:le_connectable]).to be_nil
    end

    # the extended form's bitmask arriving ungrouped carries no flags on the line
    it "records nothing for a bare hex Event type with no flags" do
      expect(parse(legacy("0x0013"))[:le_connectable]).to be_nil
    end
  end

  it "records nothing for a chunk with no advertising report at all" do
    attrs = parse([
      "> HCI Event: Read Remote Version Complete (0x0c) plen 8   #1 2026-09-21 08:52:19.588311\r\n",
      "        Status: Success (0x00)\r\n",
      "        Handle: 256 Address: 7A:BB:CC:DD:EE:FF (OUI AA-BB-CC)\r\n",
      "        LMP version: Bluetooth 5.4 (0x0d) - Subversion 1 (0x0001)\r\n"
    ])
    expect(attrs[:le_connectable]).to be_nil
    expect(attrs[:classic_connectable]).to be_nil
  end
end
