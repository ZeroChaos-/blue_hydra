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
