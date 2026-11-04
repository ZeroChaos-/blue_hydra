require 'spec_helper'

# Replays spec/fixtures/btmon_gatt_walk.log through the shipped BtmonHandler,
# Chunker and Parser, twice: verbatim, and with every message whose first line
# matches BtmonHandler::ACL_DATA_RE removed. A Walk's ATT traffic rides the
# Att_Bearer's LE link as ACL data and btmon decodes it, so if any of it reached
# raw_queue it would merge into whichever chunk is open and the two runs would
# diverge. Requirements 15.3 and 15.5 of the gatt-service-scanning spec.
#
# The fixture is described in spec/fixtures/btmon_gatt_walk.README.md: three
# Walks interleaving on handles 2048 to 2050 while discovery reports other
# devices, full-width (--columns 170) so nothing is truncated. The numbers the
# sanity examples pin (65 messages on raw_queue, 63 results, 129 ACL messages
# in 708 lines) are the ones recorded there under "Replay result" and "Line
# prefixes".
module GattReplayHarness
  # btmon's own ANSI colour codes (the fixture carries them on 20 "Data status:
  # Complete" lines). BtmonHandler#spawn strips a fixed list of them from each
  # line before anything else looks at it; this matches the same codes.
  COLOR_CODE_RE = /\e\[[0-9;]*m/

  # BtmonHandler#spawn's new-message rule: a line whose first character is not
  # whitespace starts a message. That covers the bare "> ", "< ", "@ " markers
  # and the "toolname[pid]: " / "[pid]: " prefixed forms alike.
  NEW_MESSAGE_RE = /^\S/

  # one replay: the messages the handler let through to raw_queue (pristine,
  # before the chunker and parser mutate their copies), the parser's attribute
  # hashes in chunk order, and how far each tracker counter moved
  Run = Struct.new(:raw_messages, :results, :counter_deltas)
end

describe "GATT walk capture replay (BtmonHandler -> Chunker -> Parser)" do
  let(:fixture_path) { File.expand_path('../fixtures/btmon_gatt_walk.log', __FILE__) }
  let(:fixture_lines) { File.readlines(fixture_path) }

  # The chunker counters and the handler's truncation counter are class-level
  # state on CliUserInterfaceTracker. Each replay measures its own deltas, so
  # the two runs in one example do not bleed into each other, and the values
  # are restored afterwards so this spec is invisible to the others.
  let(:counters) do
    %i[truncation_detected_count
       multi_address_chunk_count
       multi_unique_address_chunk_count
       zero_address_chunk_count]
  end

  let(:chunk_log) { double("chunk_logger", info: nil) }

  before do
    @saved_counters = counter_snapshot
    counters.each { |c| BlueHydra::CliUserInterfaceTracker.send("#{c}=", 0) }

    @orig_debug  = BlueHydra.config["chunker_debug"]
    @orig_ignore = BlueHydra.config["ignore_mac"]
    BlueHydra.config["chunker_debug"] = false
    BlueHydra.config["ignore_mac"]    = []

    # The chunker writes the chunk log only when a counter increments with
    # chunker_debug on, and the handler/chunker send events on truncation,
    # zero-address and multi-unique chunks. None of that may touch the repo
    # root's blue_hydra_chunk.log or leave the process (Requirement 16.4).
    allow(BlueHydra).to receive(:chunk_logger).and_return(chunk_log)
    allow(BlueHydra).to receive(:send_event)
  end

  after do
    @saved_counters.each { |c, v| BlueHydra::CliUserInterfaceTracker.send("#{c}=", v) }
    BlueHydra.config["chunker_debug"] = @orig_debug
    BlueHydra.config["ignore_mac"]    = @orig_ignore
  end

  def counter_snapshot
    counters.to_h { |c| [c, BlueHydra::CliUserInterfaceTracker.send(c)] }
  end

  # ---- replay harness --------------------------------------------------------

  # group lines into messages the way the handler's read loop does
  def messages(lines)
    lines.slice_before { |line| line =~ GattReplayHarness::NEW_MESSAGE_RE }.to_a
  end

  # true when a message is one ACL_DATA_RE claims, prefix stripped first as
  # BtmonHandler#enqueue does (the fixture's ATT frames sent by the Walk
  # threads carry an empty-tool-name "[672192]: " prefix)
  def acl_message?(message)
    !!(message.first.sub(BlueHydra::BtmonHandler::TOOL_PREFIX_RE, "") =~ BlueHydra::BtmonHandler::ACL_DATA_RE)
  end

  # Feed lines through the shipped handler as BtmonHandler#spawn's PTY read
  # loop does: strip colour codes, run check_for_truncation on each header
  # line, hand each completed message to enqueue, and enqueue the last one at
  # end of input (spawn's Errno::EIO path). The handler is built with allocate
  # so initialize never spawns a PTY, and the queue it pushes to is injected
  # the way Runner hands it raw_queue. Returns the messages that got through.
  def handler_replay(lines)
    handler   = BlueHydra::BtmonHandler.allocate
    raw_queue = Queue.new
    handler.instance_variable_set(:@parse_queue, raw_queue)

    buffer = []
    lines.each do |line|
      line = line.gsub(GattReplayHarness::COLOR_CODE_RE, "")
      if line =~ GattReplayHarness::NEW_MESSAGE_RE
        handler.check_for_truncation(line)
        handler.enqueue(buffer) unless buffer.empty?
        buffer = []
      end
      buffer << line
    end
    handler.enqueue(buffer) unless buffer.empty?

    raw_queue.close
    enqueued = []
    enqueued << raw_queue.pop until raw_queue.empty?
    enqueued
  end

  # the real Chunker over a closed queue, as spec/chunker_spec.rb drives it;
  # chunk_it_up returns when the queue is drained
  def chunk(raw_messages)
    incoming = Queue.new
    outgoing = Queue.new
    raw_messages.each { |m| incoming.push(m) }
    incoming.close
    BlueHydra::Chunker.new(incoming, outgoing).chunk_it_up
    chunks = []
    chunks << outgoing.pop until outgoing.empty?
    chunks
  end

  # the real Parser over each chunk, as Runner#start_parser_thread runs it
  def parse(chunks)
    chunks.map do |c|
      parser = BlueHydra::Parser.new(c.dup)
      parser.parse
      parser.attributes
    end
  end

  # The chunker appends a last_seen line to each message and the parser then
  # shifts the header and pops that line off, so they get copies and the
  # messages reported on the Run stay as the handler pushed them.
  def replay(lines)
    before  = counter_snapshot
    raw     = handler_replay(lines)
    results = parse(chunk(raw.map(&:dup)))
    after   = counter_snapshot
    GattReplayHarness::Run.new(raw, results, after.to_h { |c, v| [c, v - before[c]] })
  end

  # event name from a raw_queue message's header, for the per-type tally
  def event_name(message)
    header = message.first.sub(BlueHydra::BtmonHandler::TOOL_PREFIX_RE, "")
    case header
    when /^> HCI Event: (.+?) \(0x[0-9a-f]+\)/ then $1
    when /^@ MGMT Event: (.+?) \(0x[0-9a-f]+\)/ then "MGMT Event: #{$1}"
    else header.strip
    end
  end

  let(:verbatim) { replay(fixture_lines) }

  let(:acl_messages)   { messages(fixture_lines).select { |m| acl_message?(m) } }
  let(:stripped_lines) { messages(fixture_lines).reject { |m| acl_message?(m) }.flatten }
  let(:stripped)       { replay(stripped_lines) }

  # ---- examples --------------------------------------------------------------

  # Pins the fixture to the capture the README describes. A reformat (a
  # different --columns, CRLF endings, a prefix change) or a handler filter
  # change shows up here by name rather than as an opaque diff below.
  it "is the capture the README describes: 65 messages reach raw_queue, 63 results, every counter 0" do
    expect(verbatim.raw_messages.size).to eq(65)

    tally = verbatim.raw_messages.map { |m| event_name(m) }.tally
    expect(tally).to eq(
      "LE Meta Event"                => 42,
      "MGMT Event: Device Found"     => 14,
      "Read Remote Version Complete" => 4,
      "Disconnect Complete"          => 4,
      "Inquiry Complete"             => 1
    )

    # 64 of the 65 are chunk starts (Inquiry Complete is not and carries no
    # address, so it merges silently); the chunker flushes a working set only
    # when the next start arrives, so the final one is never flushed and 63
    # chunks reach the parser, each resolving to one device
    expect(verbatim.results.size).to eq(63)
    expect(verbatim.results.map { |r| (r[:address] || []).uniq.size }).to all(eq(1))

    # full-width capture, no address-bearing event missing from the start
    # lists: the steering file's "should all read 0"
    expect(verbatim.counter_deltas).to eq(
      truncation_detected_count:        0,
      multi_address_chunk_count:        0,
      multi_unique_address_chunk_count: 0,
      zero_address_chunk_count:         0
    )
  end

  # The strip is only a meaningful second run if it removed something, and
  # only a complete one if TOOL_PREFIX_RE accepts the empty tool name on the
  # "[672192]: < ACL Data TX" frames the Walk threads sent (README, "Line
  # prefixes"). A prefix regex requiring a non-empty name would leave those 63
  # frames in the stripped variant, and enqueue would push them onto raw_queue.
  it "removes every ACL_DATA_RE message, including the empty-tool-name prefixed ATT frames" do
    removed_lines = fixture_lines.size - stripped_lines.size
    expect(removed_lines).to be > 0
    expect(removed_lines).to eq(708)

    expect(acl_messages.size).to eq(129)
    prefixed_tx = acl_messages.select { |m| m.first =~ /^\[\d+\]: < ACL Data TX:/ }
    expect(prefixed_tx.size).to eq(63)

    expect(messages(stripped_lines).any? { |m| acl_message?(m) }).to eq(false)
  end

  # Requirement 15.3: the chunker reports the same counts with and without
  # the ACL data, and neither run saw a truncated line.
  it "reports zero truncation and identical chunker counters with and without ACL data" do
    expect(verbatim.counter_deltas[:truncation_detected_count]).to eq(0)
    expect(stripped.counter_deltas[:truncation_detected_count]).to eq(0)

    %i[multi_address_chunk_count multi_unique_address_chunk_count zero_address_chunk_count].each do |c|
      expect(stripped.counter_deltas[c]).to eq(verbatim.counter_deltas[c]),
        "#{c}: verbatim #{verbatim.counter_deltas[c]}, ACL-stripped #{stripped.counter_deltas[c]}"
    end
  end

  # Requirement 15.5: the parser produces the same results, in the same order,
  # with the same attribute values, so the handler's ACL drop is the whole
  # story and nothing downstream ever sees a Walk.
  it "produces identical parser results in count, order and attribute values with and without ACL data" do
    expect(stripped.raw_messages.map(&:first)).to eq(verbatim.raw_messages.map(&:first))
    expect(stripped.results.size).to eq(verbatim.results.size)

    verbatim.results.zip(stripped.results).each_with_index do |(expected, actual), i|
      expect(actual).to eq(expected),
        "result #{i} (#{(expected[:address] || []).first}) differs:\n" \
        "  verbatim:     #{expected.inspect}\n" \
        "  ACL-stripped: #{actual.inspect}"
    end
    expect(stripped.results).to eq(verbatim.results)

    # neither run wrote the chunk log
    expect(chunk_log).not_to have_received(:info)
  end
end
