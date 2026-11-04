require 'spec_helper'

# The Runner's side of GATT scanning: building the GattScanner, handing
# auto-connected Links to it off the Mgmt reader thread through the callback
# it installs (with the Auto_Connect_Mirror behind it), deferring controller
# resets for Walks in flight, stopping it at shutdown, counting conn_limit and
# routing Walk results on the Result_Thread. Driven without btmon or a
# controller, the way spec/ai_spec.rb drives process_connection_events and
# the result thread: Runner.new, assign the collaborators, call the method.
# The real GattScanner is used where the Reset_Deferral's timing is what is
# asserted, with a latch walker standing in for GattWalker so no socket is
# opened (Requirement 16.1); everywhere else the scanner is a double. The
# handoff examples use a real Mgmt with no socket, so the reader path runs as
# shipped from dispatch_event.
module RunnerGattHarness
  def self.mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # GattWalker's stand-in inside a real GattScanner. Built by the scanner on
  # the Walk thread with GattWalker.new's keywords; run blocks until the
  # example releases it with an outcome. close_bearer before the Walk has
  # ended releases it as disconnected, the way closing a real bearer wakes a
  # Walk blocked in its read with IOError, so GattScanner#shutdown ends it.
  class LatchWalker
    attr_reader :keywords

    def initialize(**keywords)
      @keywords = keywords
      @latch    = Queue.new
      @mutex    = Mutex.new
      @changed  = ConditionVariable.new
      @running  = false
      @finished = false
    end

    def address
      @keywords[:address]
    end

    def run
      @mutex.synchronize do
        @running = true
        @changed.broadcast
      end
      @latch.pop.call
    ensure
      @mutex.synchronize { @finished = true }
    end

    def close_bearer
      finished = @mutex.synchronize { @finished }
      release(:disconnected) unless finished
    end

    def release(outcome)
      @latch.push(-> { report(outcome) })
    end

    def finished?
      @mutex.synchronize { @finished }
    end

    def await_run(timeout = 2)
      deadline = RunnerGattHarness.mono + timeout
      @mutex.synchronize do
        until @running
          remaining = deadline - RunnerGattHarness.mono
          raise "the Walk thread for #{address} did not enter run within #{timeout} s" if remaining <= 0

          @changed.wait(@mutex, remaining)
        end
      end
    end

    private

    # A WalkReport for a Walk that learnt nothing, on the real monotonic clock
    # the scanner under test runs on.
    def report(outcome)
      now = RunnerGattHarness.mono
      BlueHydra::GattWalker::WalkReport.new(
        address: address, outcome: outcome, resumed: false, started_at: now, ended_at: now,
        mtu: BlueHydra::GattWalker::DEFAULT_MTU, requests_sent: 0, services: [], characteristics: [],
        identity: {}, database_hash: nil, hash_changed: false, state: nil,
        outstanding: { procedures: [], reads: [] }, handoff_lag: nil
      )
    end
  end

  # The walker_class seam: GattWalker.new's keyword interface, keeping every
  # walker built so the example can release it.
  class LatchWalkers
    def initialize
      @mutex   = Mutex.new
      @changed = ConditionVariable.new
      @built   = []
    end

    def new(**keywords)
      walker = LatchWalker.new(**keywords)
      @mutex.synchronize do
        @built << walker
        @changed.broadcast
      end
      walker
    end

    def built
      @mutex.synchronize { @built.dup }
    end

    def await_built(count, timeout: 2)
      deadline = RunnerGattHarness.mono + timeout
      @mutex.synchronize do
        while @built.size < count
          remaining = deadline - RunnerGattHarness.mono
          raise "#{@built.size} walker(s) built within #{timeout} s, wanted #{count}" if remaining <= 0

          @changed.wait(@mutex, remaining)
        end
        @built[count - 1]
      end
    end
  end

  # The Mgmt seen by hci_reset and stop: records every call with the real
  # monotonic time it was made, answers the allowed ones with STATUS_SUCCESS
  # and raises on anything else, so a Stop Discovery or any other command
  # slipped in around the reset fails the example on the spot as well as
  # showing in the call list (Requirement 3.10).
  class RecordingMgmt
    attr_reader :calls

    def initialize(*allowed)
      @allowed = allowed
      @mutex   = Mutex.new
      @calls   = []
    end

    def method_missing(name, *args)
      @mutex.synchronize { @calls << [name, *args, RunnerGattHarness.mono] }
      return BlueHydra::Mgmt::STATUS_SUCCESS if @allowed.include?(name)

      raise "mgmt.#{name}#{args.inspect} must not be issued here"
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end

    # The calls without their timestamps.
    def commands
      @mutex.synchronize { @calls.map { |call| call[0..-2] } }
    end

    def time_of(*command)
      @mutex.synchronize { @calls.find { |call| call[0..-2] == command }&.last }
    end
  end

  # What Runner#stop kills and joins. status nil reads as a thread that has
  # exited, which ends the result-queue drain at once.
  class FakeThread
    def initialize(name, order)
      @name  = name
      @order = order
    end

    def kill
      @order << [@name, :kill]
      self
    end

    def join(_timeout = nil)
      @order << [@name, :join]
      self
    end

    def status
      nil
    end

    def alive?
      false
    end
  end
end

describe "BlueHydra::Runner GATT integration" do
  let(:le_public)    { BlueHydra::Mgmt::LE_PUBLIC }
  let(:le_random)    { BlueHydra::Mgmt::LE_RANDOM }
  let(:success)      { BlueHydra::Mgmt::STATUS_SUCCESS }
  let(:tracker)      { BlueHydra::CliUserInterfaceTracker }
  let(:zero)         { BlueHydra::GattScanner::ZERO_COUNTERS }
  let(:runner)       { BlueHydra::Runner.new }
  let(:walkers)      { RunnerGattHarness::LatchWalkers.new }
  let(:walk_results) { Queue.new }

  def mono
    RunnerGattHarness.mono
  end

  before do
    @saved_config = BlueHydra.config.dup
    BlueHydra::GattTracker.reset!

    @log_mutex = Mutex.new
    @log       = {}
    %i[debug info warn error fatal].each do |level|
      allow(BlueHydra.logger).to receive(level) do |message|
        @log_mutex.synchronize { (@log[level] ||= []) << message }
      end
    end
  end

  after do
    BlueHydra.config.replace(@saved_config)
    BlueHydra::GattTracker.reset!
  end

  def logs(level)
    @log_mutex.synchronize { (@log[level] || []).dup }
  end

  def gatt_logs(level)
    logs(level).grep(/\Agatt/)
  end

  def wait_until(what, timeout: 2)
    deadline = mono + timeout
    until yield
      raise "timed out after #{timeout} s waiting for #{what}" if mono > deadline

      sleep 0.005
    end
  end

  # A real GattScanner on the real monotonic clock, walking with latch
  # walkers, pushing to its own queue (not the Runner's).
  def real_scanner(**overrides)
    BlueHydra::GattScanner.new(
      hci_index: 0, result_queue: walk_results, link_up: ->(_address) { nil },
      walk_parallel: 2, walk_timeout: 10, read_all: true, info_scan_rate: 300,
      tracker: BlueHydra::GattTracker, walker_class: walkers,
      clock: BlueHydra::GattWalker::MONOTONIC, **overrides
    )
  end

  # A handoff that starts a Walk; returns its walker once the Walk thread is
  # blocked in run.
  def start_walk(scanner, address, type = le_public)
    seen = walkers.built.size
    expect(scanner.handoff(address, type, source: :auto)).to eq(:attempted)
    walker = walkers.await_built(seen + 1)
    walker.await_run
    walker
  end

  # Cleanup: end every Walk still blocked and wait for the scanner to count it.
  def end_walks(scanner)
    walkers.built.each { |walker| walker.release(:disconnected) unless walker.finished? }
    wait_until("every Walk to finish") { scanner.in_flight.zero? }
  end

  #############################################################################
  # The Auto_Connect_Path handoff (Requirement 2): the callback the Runner
  # installs on the Mgmt reader, the Auto_Connect_Mirror it consults, and the
  # discovery pass over connection_events that no longer hands off.
  #
  # The Mgmt is real, with no socket (it opens lazily, and nothing here issues
  # a command): dispatch_event only reads its params, so a Device Connected
  # takes the shipped reader path - record_link_state, the connection_events
  # push, then the callback - on a thread standing in for the reader. The two
  # commands the Runner's list mutators issue, Add Device and Remove Device,
  # are stubbed, there being no kernel.
  #############################################################################
  describe "the Auto_Connect_Path handoff" do
    let(:tracked_random) { "AA:BB:CC:DD:EE:A1" }
    let(:tracked_public) { "AA:BB:CC:DD:EE:A2" }
    let(:untracked)      { "AA:BB:CC:DD:EE:A3" } # an identity address this cycle never Add Device'd
    let(:direct_link)    { "7A:BB:CC:DD:EE:A3" } # a private address: a Link the Direct_Connect_Path raised
    let(:classic)        { "02:00:15:00:00:42" } # a BR/EDR Device Connected
    let(:addresses)      { [tracked_random, tracked_public, untracked, direct_link, classic] }
    let(:mgmt)           { BlueHydra::Mgmt.new(0) }
    let(:scanner)        { instance_double(BlueHydra::GattScanner) }
    # One entry per GattScanner#handoff, recording how the Runner looked from
    # the calling thread at that instant: which thread, the real monotonic
    # time, how many events connection_events held (the one being dispatched
    # is already among them) and whether the discovery pass had marked the
    # entry connected yet. Appended on the reader thread, read after it is
    # joined.
    let(:handoffs)       { [] }

    before do
      allow(mgmt).to receive(:add_device).and_return(success)
      allow(mgmt).to receive(:remove_device).and_return(success)
      allow(scanner).to receive(:handoff) do |address, address_type, source:|
        handoffs << {
          address: address, address_type: address_type, source: source,
          thread: Thread.current, at: mono, queued: mgmt.connection_events.size,
          connected: runner.auto_connect_list.dig(address, :connected)
        }
        :attempted
      end
      runner.mgmt              = mgmt
      runner.gatt_scanner      = scanner
      runner.auto_connect_list = {}
      runner.send(:install_gatt_handoff)
    end

    after do
      mgmt.close rescue nil
      addresses.each { |a| BlueHydra::ConnectTracker.forget(a) }
    end

    # The parameters of a mgmt connection-lifecycle event: mgmt_addr_info
    # (address, type), then zero bytes standing in for the rest of the body -
    # flags and eir_len for Device Connected (no EIR), reason or status for
    # Disconnected and Connect Failed. dispatch_event decodes only the address.
    def event_params(address, address_type)
      BlueHydra::Mgmt.pack_address(address) + [address_type, 0, 0].pack("CVv")
    end

    def connection_event(address, address_type, event = BlueHydra::Mgmt::EV_DEVICE_CONNECTED)
      mgmt.send(:dispatch_event, event, event_params(address, address_type))
    end

    # Run the block as the Mgmt reader thread runs dispatch_event: on a thread
    # of its own. Joined before returning, so the assertions that follow see
    # everything the dispatch did; a dispatch that raised fails the example
    # here, as it would end the real reader. Returns the thread.
    def on_reader_thread
      thread = Thread.new { yield }
      raise "the fake reader thread did not finish dispatching within 2 s" unless thread.join(2)
      thread
    end

    def handed_off
      handoffs.map { |h| h.values_at(:address, :address_type, :source) }
    end

    # A copy of the Auto_Connect_Mirror, taken the way the callback reads it.
    def mirror
      runner.instance_variable_get(:@auto_connect_mirror_mutex).synchronize do
        runner.instance_variable_get(:@auto_connect_mirror).dup
      end
    end

    it "hands off on the reader thread as the Device Connected is read, with the address type recorded at " \
       "Add Device and tagged :auto, before process_connection_events has run (2.1)" do
      runner.add_to_auto_connect(tracked_random, "Random")
      runner.add_to_auto_connect(tracked_public, "Public")
      connected_before = tracker.auto_connect_connected_count

      reader = on_reader_thread do
        connection_event(tracked_random, le_random)
        connection_event(tracked_public, le_public)
      end

      expect(handed_off).to eq([[tracked_random, le_random, :auto], [tracked_public, le_public, :auto]])
      expect(handoffs.map { |h| h[:thread] }).to all(equal(reader))
      # Each handoff saw its own event already queued and nothing drained: the
      # discovery thread has not had the pass that marks the entry connected.
      expect(handoffs.map { |h| h[:queued] }).to eq([1, 2])
      expect(handoffs.map { |h| h[:connected] }).to eq([false, false])
      expect(mgmt.connection_events.size).to eq(2)
      expect(runner.auto_connect_list.transform_values { |e| e[:connected] })
        .to eq(tracked_random => false, tracked_public => false)
      expect(tracker.auto_connect_connected_count - connected_before).to eq(0)
      expect(logs(:error)).to be_empty
    end

    it "hands off within 50 ms of the read while the discovery thread is blocked inside a mgmt Add Device " \
       "for another address (2.10)" do
      runner.add_to_auto_connect(tracked_random, "Random")

      entered = Queue.new # add_device reports it has been entered...
      latch   = Queue.new # ...and blocks here until the example releases it
      allow(mgmt).to receive(:add_device).with(tracked_public, le_public) do
        entered << true
        latch.pop
        success
      end
      discovery = Thread.new { runner.add_to_auto_connect(tracked_public, "Public") }
      begin
        entered.pop # the discovery thread is now inside add_device

        read_at = nil
        on_reader_thread do
          read_at = mono
          connection_event(tracked_random, le_random)
        end

        expect(handed_off).to eq([[tracked_random, le_random, :auto]])
        expect(handoffs.first[:at] - read_at).to be < 0.05
        # and the Add Device was still blocked when it happened: nothing the
        # reader did waited on the discovery thread or its command
        expect(discovery).to be_alive
        expect(latch).to be_empty
        expect(mirror).to eq(tracked_random => le_random)
      ensure
        latch << true
        discovery.join(2)
      end

      # released, the add completes and the mirror follows
      expect(discovery).not_to be_alive
      expect(mirror).to eq(tracked_random => le_random, tracked_public => le_public)
      expect(runner.auto_connect_list.keys).to contain_exactly(tracked_random, tracked_public)
    end

    it "makes no handoff for an address not in the mirror - untracked, a Direct_Connect_Path Link, BR/EDR - " \
       "while every event still reaches connection_events and the tracked Link read among them is handed " \
       "off (2.6, 2.7)" do
      runner.add_to_auto_connect(tracked_random, "Random")

      on_reader_thread do
        connection_event(untracked, le_public)
        connection_event(direct_link, le_random)
        connection_event(classic, BlueHydra::Mgmt::ADDR_TYPE_BREDR)
        connection_event(tracked_random, le_random)
      end

      expect(handed_off).to eq([[tracked_random, le_random, :auto]])
      expect(mgmt.connection_events.size).to eq(4)
      # the reader's own bookkeeping is untouched by the decision
      expect([untracked, direct_link, classic, tracked_random].map { |a| mgmt.link_up?(a) }).to all(be_a(Float))
      expect(logs(:error)).to be_empty
    end

    it "makes no handoff for a Disconnected or a Connect Failed of a tracked address, and the discovery pass " \
       "that removes the entry takes the mirror entry with it" do
      runner.add_to_auto_connect(tracked_random, "Random")
      runner.add_to_auto_connect(tracked_public, "Public")

      on_reader_thread do
        connection_event(tracked_random, le_random, BlueHydra::Mgmt::EV_DEVICE_DISCONNECTED)
        connection_event(tracked_public, le_public, BlueHydra::Mgmt::EV_CONNECT_FAILED)
      end
      expect(handoffs).to be_empty
      expect(mirror).to eq(tracked_random => le_random, tracked_public => le_public)

      runner.process_connection_events

      expect(handoffs).to be_empty
      expect(runner.auto_connect_list).to be_empty
      expect(mirror).to be_empty
      expect(mgmt).to have_received(:remove_device).with(tracked_random, le_random).once
      expect(mgmt).to have_received(:remove_device).with(tracked_public, le_public).once
    end

    it "logs a scanner that raises at error level, keeps the reader dispatching and the event queued, and " \
       "the discovery pass still marks connected, counts it and records the success (2.8)" do
      runner.add_to_auto_connect(tracked_random, "Random")
      runner.add_to_auto_connect(tracked_public, "Public")
      allow(scanner).to receive(:handoff).with(tracked_random, le_random, source: :auto).and_raise(RuntimeError, "boom")
      BlueHydra::ConnectTracker.strike(tracked_random)
      BlueHydra::ConnectTracker.strike(tracked_public)
      connected_before = tracker.auto_connect_connected_count

      reader = on_reader_thread do
        connection_event(tracked_random, le_random)
        connection_event(tracked_public, le_public)
      end

      expect(reader.status).to be(false) # ended normally, not by the exception
      # the Runner's own rescue, so Mgmt's backstop line never appears
      expect(logs(:error)).to eq(["gatt: handoff for #{tracked_random} raised RuntimeError: boom"])
      expect(handed_off).to eq([[tracked_public, le_public, :auto]])
      expect(mgmt.connection_events.size).to eq(2)
      expect(mgmt.link_up?(tracked_random)).to be_a(Float)

      runner.process_connection_events

      expect(tracker.auto_connect_connected_count - connected_before).to eq(2)
      expect(BlueHydra::ConnectTracker.strikes(tracked_random)).to eq(0)
      expect(BlueHydra::ConnectTracker.strikes(tracked_public)).to eq(0)
      expect(runner.auto_connect_list.transform_values { |e| e[:connected] })
        .to eq(tracked_random => true, tracked_public => true)
      expect(logs(:error).size).to eq(1)
    end

    it "process_connection_events marks the entry connected, counts it and records the success, and makes " \
       "no handoff of its own: one Device Connected is one GattScanner#handoff (2.11)" do
      runner.add_to_auto_connect(tracked_random, "Random")
      BlueHydra::ConnectTracker.strike(tracked_random)
      connected_before = tracker.auto_connect_connected_count

      on_reader_thread { connection_event(tracked_random, le_random) }

      expect(handed_off).to eq([[tracked_random, le_random, :auto]])
      # the three discovery-pass effects have not happened yet
      expect(runner.auto_connect_list[tracked_random][:connected]).to be(false)
      expect(tracker.auto_connect_connected_count - connected_before).to eq(0)
      expect(BlueHydra::ConnectTracker.strikes(tracked_random)).to eq(1)

      runner.process_connection_events

      expect(scanner).to have_received(:handoff).once
      expect(runner.auto_connect_list[tracked_random][:connected]).to be(true)
      expect(tracker.auto_connect_connected_count - connected_before).to eq(1)
      expect(BlueHydra::ConnectTracker.strikes(tracked_random)).to eq(0)
      expect(mgmt.connection_events).to be_empty
      # connected keeps the entry pending, as before the feature
      expect(runner.auto_connect_list.keys).to eq([tracked_random])
    end

    it "process_connection_events hands off nothing even for a :connected event no reader callback preceded " \
       "(2.11)" do
      runner.add_to_auto_connect(tracked_random, "Random")
      mgmt.connection_events << { type: :connected, address: tracked_random }

      runner.process_connection_events

      expect(scanner).not_to have_received(:handoff)
      expect(runner.auto_connect_list[tracked_random][:connected]).to be(true)
      expect(logs(:error)).to be_empty
    end

    it "keeps the mirror at exactly auto_connect_list's addresses and types: written on Add Device success " \
       "only, dropped by remove_from_auto_connect, emptied by clear_auto_connect (2.12)" do
      allow(mgmt).to receive(:add_device).with(untracked, le_public).and_return(BlueHydra::Mgmt::STATUS_REJECTED)

      runner.add_to_auto_connect(tracked_random, "Random")
      runner.add_to_auto_connect(tracked_public, "Public")
      runner.add_to_auto_connect(untracked, "Public") # refused by the kernel: no entry in either
      expect(runner.auto_connect_list.transform_values { |e| e[:address_type] })
        .to eq(tracked_random => le_random, tracked_public => le_public)
      expect(mirror).to eq(tracked_random => le_random, tracked_public => le_public)
      expect(logs(:error)).to eq(["mgmt add device failed for #{untracked} (status 0x0b (REJECTED))"])

      runner.remove_from_auto_connect(tracked_random)
      expect(mirror).to eq(tracked_public => le_public)
      # and the reader stops handing it off at once
      on_reader_thread do
        connection_event(tracked_random, le_random)
        connection_event(tracked_public, le_public)
      end
      expect(handed_off).to eq([[tracked_public, le_public, :auto]])

      runner.process_connection_events # marks tracked_public connected, so clear counts no timeout
      runner.clear_auto_connect
      expect(runner.auto_connect_list).to be_empty
      expect(mirror).to be_empty
      on_reader_thread { connection_event(tracked_public, le_public) }
      expect(handed_off).to eq([[tracked_public, le_public, :auto]]) # unchanged
      expect(mgmt).to have_received(:remove_device).with(tracked_random, le_random).once
      expect(mgmt).to have_received(:remove_device).with(tracked_public, le_public).once
    end

    it "with no scanner (gatt_scan false) the reader queues the event and the discovery pass counts " \
       "connected and records the success, with nothing logged (1.3)" do
      BlueHydra.config["gatt_scan"] = false
      runner.gatt_scanner = nil
      mgmt.on_device_connected = nil     # undo the outer before's install, then
      runner.send(:install_gatt_handoff) # install with no scanner: sets nothing (2.13)
      expect(mgmt.on_device_connected).to be_nil
      runner.add_to_auto_connect(tracked_random, "Random")
      BlueHydra::ConnectTracker.strike(tracked_random)
      connected_before = tracker.auto_connect_connected_count

      on_reader_thread { connection_event(tracked_random, le_random) }
      expect(mgmt.connection_events.size).to eq(1)

      runner.process_connection_events

      expect(handoffs).to be_empty
      expect(tracker.auto_connect_connected_count - connected_before).to eq(1)
      expect(BlueHydra::ConnectTracker.strikes(tracked_random)).to eq(0)
      expect(runner.auto_connect_list[tracked_random][:connected]).to be(true)
      expect(logs(:error)).to be_empty
      expect(logs(:warn)).to be_empty
    end

    # The Walk end line's handoff_lag_ms field (Requirement 13.6), which the
    # scanner renders from the WalkReport's handoff_lag whichever thread made
    # the handoff, is asserted in spec/gatt_scanner_spec.rb ("logs one debug
    # line per Walk with the Requirement 13.6 fields"), with both a measured
    # lag and the "-" of a Walk without one. Not repeated here.
  end

  #############################################################################
  # start_discovery_thread: building the scanner (Requirements 1.2, 1.3, 1.7)
  #############################################################################
  describe "#start_discovery_thread scanner construction" do
    # A real Mgmt, never opened (the first command it is asked for raises,
    # below), so what install_gatt_handoff set on it - or did not - can be read
    # back and exercised.
    let(:mgmt) { BlueHydra::Mgmt.new(0) }
    let(:hci)  { instance_double(BlueHydra::HciCommand, start: nil) }
    let(:le_connect) { instance_double(BlueHydra::LeConnect) }
    let(:le_connect_calls) { [] }
    let(:tracked) { "AA:BB:CC:DD:EE:02" }

    before do
      runner.result_queue = Queue.new
      allow(BlueHydra::Mgmt).to receive(:new).and_return(mgmt)
      allow(BlueHydra::HciCommand).to receive(:new).and_return(hci)
      allow(BlueHydra::L2Ping).to receive(:new).and_return(instance_double(BlueHydra::L2Ping))
      allow(BlueHydra::LeConnect).to receive(:new) do |*args, **keywords|
        le_connect_calls << [args, keywords]
        le_connect
      end
      allow(BlueHydra::GattScanner).to receive(:new).and_call_original
      # End the thread right after the collaborators are built: the first mgmt
      # command raises, the thread's outer rescue logs it and sends an event.
      allow(mgmt).to receive(:ensure_transports_enabled).and_raise(RuntimeError, "harness: stop here")
      allow(mgmt).to receive(:add_device).and_return(success)
      allow(BlueHydra).to receive(:send_event)
    end

    after do
      mgmt.close rescue nil
      BlueHydra::ConnectTracker.forget(tracked)
    end

    def device_connected(address, address_type)
      BlueHydra::Mgmt.pack_address(address) + [address_type, 0, 0].pack("CVv")
    end

    def run_discovery_thread
      runner.start_discovery_thread
      expect(runner.discovery_thread.join(5)).not_to be_nil
      expect(logs(:error).first).to eq("Discovery thread harness: stop here")
      expect(BlueHydra).to have_received(:send_event)
        .with('blue_hydra', hash_including(key: 'blue_hydra_discovery_thread_error'))
    end

    it "builds a GattScanner on the controller index and the Runner's result_queue, whose link_up asks " \
       "the Runner's current mgmt, and gives it to LeConnect (1.2)" do
      allow(mgmt).to receive(:link_up?).with("AA:BB:CC:DD:EE:01").and_return(42.5)

      run_discovery_thread

      scanner = runner.gatt_scanner
      expect(scanner).to be_a(BlueHydra::GattScanner)
      expect(BlueHydra::GattScanner).to have_received(:new)
        .with(hci_index: runner.mgmt_index, result_queue: runner.result_queue, link_up: kind_of(Proc)).once
      expect(scanner.instance_variable_get(:@hci_index)).to eq(runner.mgmt_index)
      expect(scanner.instance_variable_get(:@result_queue)).to equal(runner.result_queue)

      link_up = scanner.instance_variable_get(:@link_up)
      expect(link_up.call("AA:BB:CC:DD:EE:01")).to eq(42.5)
      expect(mgmt).to have_received(:link_up?).with("AA:BB:CC:DD:EE:01").once

      # The Auto_Connect_Path callback is installed on this mgmt (2.1, 2.13)
      # and is the Runner's: a mirrored address reaches this scanner's handoff
      # with its Add Device type. (Stubbed: the real handoff would start a Walk
      # thread against a socket.)
      callback = mgmt.on_device_connected
      expect(callback).to be_a(Proc)
      allow(scanner).to receive(:handoff).and_return(:attempted)
      runner.auto_connect_list = {}
      runner.add_to_auto_connect(tracked, "Public")
      callback.call(tracked)
      expect(scanner).to have_received(:handoff).with(tracked, le_public, source: :auto).once

      # routed through the accessor, so it follows whatever mgmt the runner holds
      replacement = instance_double(BlueHydra::Mgmt, link_up?: nil)
      runner.mgmt = replacement
      expect(link_up.call("AA:BB:CC:DD:EE:01")).to be_nil
      expect(replacement).to have_received(:link_up?).with("AA:BB:CC:DD:EE:01").once

      expect(le_connect_calls).to eq([[[runner.mgmt_index],
                                       { connect_timeout: BlueHydra::Runner::L2CAP_CONNECT_TIMEOUT,
                                         gatt_scanner: scanner }]])
      expect(runner.le_connect).to be(le_connect)
      expect(scanner.counters).to eq(zero)
    end

    it "builds no scanner with gatt_scan false: LeConnect gets nil, the CUI's GATT counters are the zero " \
       "set, no Device Connected callback is installed and a connected Link puts nothing on result_queue " \
       "(1.3, 1.7, 2.13, 13.10)" do
      BlueHydra.config["gatt_scan"] = false

      run_discovery_thread

      expect(BlueHydra::GattScanner).not_to have_received(:new)
      expect(runner.gatt_scanner).to be_nil
      expect(le_connect_calls).to eq([[[runner.mgmt_index],
                                       { connect_timeout: BlueHydra::Runner::L2CAP_CONNECT_TIMEOUT,
                                         gatt_scanner: nil }]])
      expect(mgmt.on_device_connected).to be_nil

      # what CliUserInterface#render_cui reads for the GATT line
      cui_scanner  = runner.respond_to?(:gatt_scanner) && runner.gatt_scanner
      cui_counters = cui_scanner ? cui_scanner.counters : BlueHydra::GattScanner::ZERO_COUNTERS
      expect(cui_counters).to eq(zero)
      expect(cui_counters.values).to all(eq(0))

      # The Auto_Connect_Path end to end on the discovery thread's own mgmt: a
      # Device Connected for a tracked address takes the pre-feature reader
      # path (Link recorded, event queued, nothing else) and the discovery pass
      # marks it connected with nothing for the result thread.
      runner.auto_connect_list = {}
      runner.add_to_auto_connect(tracked, "Public")
      mgmt.send(:dispatch_event, BlueHydra::Mgmt::EV_DEVICE_CONNECTED, device_connected(tracked, le_public))
      expect(mgmt.link_up?(tracked)).to be_a(Float)
      expect(mgmt.connection_events.size).to eq(1)

      runner.process_connection_events

      expect(runner.auto_connect_list[tracked][:connected]).to be(true)
      expect(runner.result_queue).to be_empty
      expect(gatt_logs(:error)).to be_empty
    end
  end

  #############################################################################
  # hci_reset: the Reset_Deferral (Requirements 1.9, 3.1, 3.9 to 3.12)
  #############################################################################
  describe "#hci_reset" do
    let(:mgmt)    { RunnerGattHarness::RecordingMgmt.new(:set_powered) }
    let(:scanner) { real_scanner }
    let(:address) { "AA:BB:CC:DD:EE:B1" }
    let(:power_cycle) { [[:set_powered, false], [:set_powered, true]] }

    before do
      runner.mgmt = mgmt
      allow(runner).to receive(:sleep) # the two 1 s pauses of the power cycle
    end

    after { end_walks(scanner) }

    it "waits until the last Walk ends, then power-cycles with nothing else on the mgmt socket, counting " \
       "one reset-deferred and logging no still-in-flight line (3.9, 3.10, 3.13)" do
      runner.gatt_scanner = scanner
      walker      = start_walk(scanner, address)
      released_at = nil
      releaser    = Thread.new do
        sleep 0.2
        released_at = mono
        walker.release(:disconnected)
      end

      before = mono
      runner.hci_reset
      elapsed = mono - before
      releaser.join(2)

      expect(mgmt.commands).to eq(power_cycle)
      expect(mgmt.time_of(:set_powered, false)).to be > released_at
      expect(elapsed).to be_between(0.2, 2.0)
      expect(scanner.in_flight).to eq(0)
      expect(scanner.counters[:"reset-deferred"]).to eq(1)
      expect(gatt_logs(:debug).grep(/\Agatt: reset-deferred waited_ms=\d+ in_flight=0 cap_ms=10000\z/).size).to eq(1)
      expect(gatt_logs(:debug).grep(/\Agatt: reset after/)).to be_empty
    end

    it "caps the wait at Walk_Bound (gatt_walk_timeout) with a Walk still in flight, logs the count and " \
       "the wait, then power-cycles (3.11, 3.13)" do
      BlueHydra.config["gatt_walk_timeout"] = 0.25
      runner.gatt_scanner = scanner
      start_walk(scanner, address)

      before = mono
      runner.hci_reset
      elapsed = mono - before

      expect(mgmt.commands).to eq(power_cycle)
      expect(elapsed).to be_between(0.25, 2.0)
      expect(scanner.in_flight).to eq(1)
      expect(scanner.counters[:"reset-deferred"]).to eq(1)

      deferred = gatt_logs(:debug).grep(/\Agatt: reset-deferred/)
      runner_line = gatt_logs(:debug).grep(/\Agatt: reset after/)
      expect(deferred).to match([match(/\Agatt: reset-deferred waited_ms=\d+ in_flight=1 cap_ms=250\z/)])
      expect(runner_line).to match([match(/\Agatt: reset after \d+\.\d\ds wait with 1 walk\(s\) still in flight\z/)])
      waited_ms = deferred.first[/waited_ms=(\d+)/, 1].to_i
      expect(waited_ms).to be_between(250, 2000)
      expect(runner_line.first[/after (\d+\.\d\d)s/, 1].to_f).to be_within(0.05).of(waited_ms / 1000.0)
      # the scanner's line first (it is logged inside wait_for_idle), the Runner's after
      expect(gatt_logs(:debug).index(deferred.first)).to be < gatt_logs(:debug).index(runner_line.first)
    end

    it "adds no wait when no Walk is in flight: no counter moves and nothing is logged (3.12)" do
      runner.gatt_scanner = scanner

      before = mono
      runner.hci_reset
      elapsed = mono - before

      expect(mgmt.commands).to eq(power_cycle)
      expect(elapsed).to be < 0.1
      expect(scanner.counters).to eq(zero)
      expect(gatt_logs(:debug)).to be_empty
      expect(gatt_logs(:error)).to be_empty
    end

    it "adds no wait with gatt_scan false: no scanner is consulted and the sequence is the two Set " \
       "Powered commands (1.9)" do
      BlueHydra.config["gatt_scan"] = false
      runner.gatt_scanner = nil
      allow_any_instance_of(BlueHydra::GattScanner).to receive(:wait_for_idle) do
        raise "wait_for_idle must not be called with gatt_scan false"
      end
      expect(runner).not_to receive(:defer_reset_for_walks)

      before = mono
      runner.hci_reset
      elapsed = mono - before

      expect(mgmt.commands).to eq(power_cycle)
      expect(elapsed).to be < 0.1
      expect(gatt_logs(:debug)).to be_empty
      expect(gatt_logs(:error)).to be_empty
    end

    it "adds no wait with defer_for_walks: false even with a Walk in flight (the shutdown reset, 14.2)" do
      runner.gatt_scanner = scanner
      start_walk(scanner, address)

      before = mono
      runner.hci_reset(defer_for_walks: false)
      elapsed = mono - before

      expect(mgmt.commands).to eq(power_cycle)
      expect(elapsed).to be < 0.1
      expect(scanner.in_flight).to eq(1)
      expect(scanner.counters[:"reset-deferred"]).to eq(0)
      expect(gatt_logs(:debug)).to be_empty
    end
  end

  #############################################################################
  # stop: shutdown ordering (Requirements 14.2, 14.4)
  #############################################################################
  describe "#stop" do
    let(:order) { [] }
    let(:mgmt) do
      m = double("mgmt")
      allow(m).to receive(:stopping!)   { order << [:mgmt, :stopping!] }
      allow(m).to receive(:set_powered) { |flag| order << [:mgmt, :set_powered, flag]; success }
      allow(m).to receive(:close)       { order << [:mgmt, :close] }
      m
    end
    let(:hci) do
      h = double("hci")
      allow(h).to receive(:stopping!) { order << [:hci, :stopping!] }
      allow(h).to receive(:close)     { order << [:hci, :close] }
      h
    end
    let(:scanner) do
      s = double("gatt_scanner")
      allow(s).to receive(:stopping!) { order << [:scanner, :stopping!] }
      allow(s).to receive(:shutdown)  { order << [:scanner, :shutdown]; 0 }
      s
    end

    before do
      expect(BlueHydra.config["file"]).to be_falsey # the branch stop takes on a sensor
      runner.mgmt             = mgmt
      runner.hci              = hci
      runner.gatt_scanner     = scanner
      runner.result_queue     = Queue.new
      runner.btmon_thread     = RunnerGattHarness::FakeThread.new(:btmon, order)
      runner.discovery_thread = RunnerGattHarness::FakeThread.new(:discovery, order)
      runner.ubertooth_thread = RunnerGattHarness::FakeThread.new(:ubertooth, order)
      runner.chunker_thread   = RunnerGattHarness::FakeThread.new(:chunker, order)
      runner.parser_thread    = RunnerGattHarness::FakeThread.new(:parser, order)
      runner.result_thread    = RunnerGattHarness::FakeThread.new(:result, order)
      allow(runner).to receive(:sleep)
      allow(BlueHydra::StreamBuilder).to receive(:flush_device_sync_counts!)
    end

    it "tells the scanner to stop beside mgmt and hci, shuts it down after the discovery thread is joined " \
       "and before the shutdown reset, which does not defer, then closes and kills the rest (14.2)" do
      expect(runner).to receive(:hci_reset).with(defer_for_walks: false).and_call_original

      runner.stop

      expect(order.first(3)).to contain_exactly([:mgmt, :stopping!], [:hci, :stopping!], [:scanner, :stopping!])
      expect(order[3..]).to eq([
        [:btmon, :kill], [:btmon, :join],
        [:discovery, :kill], [:ubertooth, :kill], [:discovery, :join], [:ubertooth, :join],
        [:scanner, :shutdown],
        [:mgmt, :set_powered, false], [:mgmt, :set_powered, true],
        [:mgmt, :close], [:hci, :close],
        [:chunker, :kill], [:parser, :kill], [:result, :kill]
      ])
      expect(logs(:error)).to be_empty
    end

    it "logs a shutdown that raises and still performs the reset and the closes" do
      allow(scanner).to receive(:shutdown) { order << [:scanner, :shutdown]; raise "walker wedged" }

      runner.stop

      expect(logs(:error)).to eq(["gatt scanner shutdown failed: walker wedged"])
      shutdown_at = order.index([:scanner, :shutdown])
      power_off   = order.index([:mgmt, :set_powered, false])
      expect(shutdown_at).to be < power_off
      expect(order).to include([:mgmt, :set_powered, true], [:mgmt, :close], [:hci, :close], [:result, :kill])
    end

    it "is the pre-feature sequence with no scanner (gatt_scan false)" do
      runner.gatt_scanner = nil
      expect(runner).to receive(:hci_reset).with(defer_for_walks: false).and_call_original

      runner.stop

      expect(order.map(&:first)).not_to include(:scanner)
      expect(order.first(2)).to contain_exactly([:mgmt, :stopping!], [:hci, :stopping!])
      expect(order).to include([:mgmt, :set_powered, false], [:mgmt, :set_powered, true], [:mgmt, :close])
      expect(logs(:error)).to be_empty
    end
  end

  #############################################################################
  # record_le_direct_results: conn_limit (Requirement 18.2)
  #############################################################################
  describe "#record_le_direct_results" do
    let(:limited)     { "7A:BB:CC:DD:EE:C1" }
    let(:unreachable) { "7A:BB:CC:DD:EE:C2" }
    let(:errored)     { "7A:BB:CC:DD:EE:C3" }
    let(:connected)   { "7A:BB:CC:DD:EE:C4" }

    def counters
      %i[le_direct_connected_count le_direct_failed_count le_direct_error_count
         le_direct_abandoned_count le_direct_conn_limit_count].to_h { |c| [c, tracker.public_send(c)] }
    end

    after { [limited, unreachable, errored, connected].each { |a| BlueHydra::ConnectTracker.forget(a) } }

    it "counts :conn_limit on its own counter, records no strike and logs the controller limit (18.2)" do
      expect(BlueHydra::ConnectTracker).not_to receive(:strike)
      before = counters

      runner.record_le_direct_results(limited => :conn_limit)

      expect(counters.to_h { |c, v| [c, v - before[c]] }).to eq(
        le_direct_connected_count: 0, le_direct_failed_count: 0, le_direct_error_count: 0,
        le_direct_abandoned_count: 0, le_direct_conn_limit_count: 1
      )
      expect(BlueHydra::ConnectTracker.strikes(limited)).to eq(0)
      expect(logs(:debug)).to eq(["le_connect: #{limited} -> conn_limit (controller connection limit)"])
    end

    it "strikes only the unreachable and error outcomes of a mixed batch" do
      before = counters

      runner.record_le_direct_results(
        limited => :conn_limit, unreachable => :unreachable, errored => :error, connected => :connected
      )

      expect(counters.to_h { |c, v| [c, v - before[c]] }).to eq(
        le_direct_connected_count: 1, le_direct_failed_count: 1, le_direct_error_count: 1,
        le_direct_abandoned_count: 0, le_direct_conn_limit_count: 1
      )
      expect(BlueHydra::ConnectTracker.strikes(limited)).to eq(0)
      expect(BlueHydra::ConnectTracker.strikes(connected)).to eq(0)
      expect(BlueHydra::ConnectTracker.strikes(unreachable)).to eq(1)
      expect(BlueHydra::ConnectTracker.strikes(errored)).to eq(1)
    end
  end

  #############################################################################
  # the result thread: Walk results (Requirements 11.1, 11.2)
  #############################################################################
  describe "result thread Walk result dispatch" do
    let(:walked)     { "AA:BB:CC:DD:EE:D1" }
    let(:advertised) { "AA:BB:CC:DD:EE:D2" }
    let(:applied)    { [] }
    let(:pushed)     { [] }

    def walk_result(address, outcome)
      {
        gatt_walk: true, address: address, outcome: outcome, resumed: false, ended_at: Time.now.to_i,
        database_hash: nil, hash_changed: false, service_uuids: [], characteristics: [], identity: {},
        outstanding: { procedures: [], reads: [] }
      }
    end

    def advertisement(address)
      {
        address: [address], name: ["RunnerGattDevice"], last_seen: [Time.now.to_i],
        le_mode: [true], le_address_type: ["Random"], le_connectable: [true]
      }
    end

    before do
      runner.result_queue       = Queue.new
      runner.info_scan_queue    = Queue.new
      runner.l2ping_queue       = Queue.new
      runner.le_info_scan_queue = Queue.new
      runner.query_history      = {}
      allow(BlueHydra).to receive(:send_event)
      # push_to_queue is the last thing the advertisement branch does, so a
      # recorded call means that result has been processed to the end
      allow(runner).to receive(:push_to_queue) { |*args| pushed << args }
      allow(BlueHydra::ConnectTracker).to receive(:record_connectable).and_call_original
      allow(BlueHydra::Device).to receive(:update_or_create_from_result).and_wrap_original do |m, result|
        applied << result
        m.call(result)
      end
    end

    after do
      thread = runner.result_thread
      if thread
        thread.kill
        thread.join(2)
      end
      [walked, advertised].each { |a| BlueHydra::ConnectTracker.forget(a) }
    end

    it "passes a gatt_walk result to Device.update_or_create_from_result and skips record_connectable and " \
       "push_to_queue for it, while an advertisement still takes the old path (11.1, 11.2)" do
      runner.start_result_thread
      runner.result_queue.push(walk_result(walked, :complete))
      runner.result_queue.push(advertisement(advertised))

      wait_until("the advertisement to be processed to its end") { pushed.size == 1 }

      expect(applied.size).to eq(2)
      expect(BlueHydra::Device.all(address: advertised).count).to be >= 1
      expect(applied.first).to include(gatt_walk: true, address: walked, outcome: :complete)
      expect(applied.last[:address]).to eq([advertised])
      # no record carries the walked address: discarded at debug, nothing created (11.14)
      expect(BlueHydra::Device.all(address: walked).count).to eq(0)
      expect(gatt_logs(:debug)).to include("gatt: #{walked} has no Device record, Walk result discarded")

      expect(BlueHydra::ConnectTracker).to have_received(:record_connectable).with(advertised, true).once
      expect(BlueHydra::ConnectTracker).not_to have_received(:record_connectable).with(walked, anything)
      expect(runner).to have_received(:push_to_queue).with(:le, advertised, "Random").once
      expect(runner).not_to have_received(:push_to_queue).with(anything, walked, anything)

      expect(runner.result_thread).to be_alive
      expect(logs(:error)).to be_empty
      expect(BlueHydra).not_to have_received(:send_event)
    end

    it "logs a Walk result the Device refuses (an outcome outside its contract) at error with the " \
       "backtrace and keeps the thread processing the next result" do
      runner.start_result_thread
      runner.result_queue.push(walk_result(walked, :busy))
      runner.result_queue.push(advertisement(advertised))

      wait_until("the advertisement to be processed to its end") { pushed.size == 1 }

      expect(applied.size).to eq(2)
      errors = logs(:error)
      expect(errors.first).to match(/\Agatt: #{walked} Walk result not applied, ArgumentError: gatt: #{walked} Walk result has outcome :busy, not one of /)
      expect(errors.first).not_to start_with("Result thread")
      expect(errors.size).to be > 1 # the backtrace lines follow
      expect(errors.grep(/\AResult thread/)).to be_empty
      expect(runner.result_thread).to be_alive
      expect(BlueHydra).not_to have_received(:send_event)
      expect(runner).to have_received(:push_to_queue).with(:le, advertised, "Random").once
    end
  end
end
