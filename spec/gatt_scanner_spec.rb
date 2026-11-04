require 'spec_helper'
require 'blue_hydra/gatt_scanner'
require 'blue_hydra/gatt_tracker'
require 'blue_hydra/gatt_walker'
require_relative 'support/fake_att_peer'

# GattScanner with scripted walkers standing in for GattWalker (Requirement
# 16.1): no socket is opened and no peer exists. The scanner builds one walker
# per Walk through walker_class.new with GattWalker's keywords; the scripted
# walker records them, blocks in run on a latch until the example releases it
# with a WalkReport (or an exception), and records every close_bearer with the
# thread that made it. Walk_Bound, the tracker's ages and the Reset_Deferral's
# waited run on an injected FakeClock the examples move by hand; the handoff,
# bearer-connect and shutdown bounds are checked on the real monotonic clock
# as well, since they bound real time.
module ScriptedGatt
  def self.mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # One Walk's walker, built by the scanner on the Walk thread with
  # GattWalker.new's keywords.
  #
  #   run           blocks until released, then returns the report it was
  #                 released with, raises the error it was released with, or
  #                 runs the block (which may move the clock first)
  #   close_bearer  records the calling thread; a walker scripted with
  #                 release_on_close ends its Walk with that report, the way a
  #                 real bearer close wakes a Walk blocked in its connect or
  #                 read wait with IOError; one scripted with close_raises
  #                 raises on every close, as a failing socket close would
  class ScriptedWalker
    attr_reader :keywords, :built_at, :built_real, :build_thread, :bearer

    def initialize(keywords, clock)
      @keywords     = keywords
      @clock        = clock
      @built_at     = clock.now
      @built_real   = ScriptedGatt.mono
      @build_thread = Thread.current
      @bearer       = Object.new
      @latch        = Queue.new          # the Proc run performs once released
      @mutex        = Mutex.new
      @changed      = ConditionVariable.new
      @thread       = nil
      @run_at       = nil
      @run_real     = nil
      @closes       = []
      @on_close     = nil
      @close_error  = nil
      @finished     = false
    end

    def address
      @keywords[:address]
    end

    # GattWalker#run: block until the example says how this Walk ends.
    def run
      @mutex.synchronize do
        @thread   = Thread.current
        @run_at   = @clock.now
        @run_real = ScriptedGatt.mono
        @changed.broadcast
      end
      @latch.pop.call
    ensure
      @mutex.synchronize { @finished = true }
    end

    # GattWalker#close_bearer, from the Walk thread (finish_walk) or the
    # shutdown thread.
    def close_bearer
      wake  = nil
      error = nil
      @mutex.synchronize do
        @closes << Thread.current
        wake  = @on_close unless @finished
        error = @close_error
      end
      @latch.push(wake) if wake
      raise error if error
    end

    def release(report = nil, &action)
      @latch.push(action || -> { report })
    end

    def release_raising(error)
      release { raise error }
    end

    def release_on_close(report)
      @mutex.synchronize { @on_close = -> { report } }
    end

    def close_raises(error)
      @mutex.synchronize { @close_error = error }
    end

    def thread
      @mutex.synchronize { @thread }
    end

    def run_at
      @mutex.synchronize { @run_at }
    end

    def run_real
      @mutex.synchronize { @run_real }
    end

    def closes
      @mutex.synchronize { @closes.dup }
    end

    def finished?
      @mutex.synchronize { @finished }
    end

    # Wait until the Walk thread has entered run.
    def await_run(timeout = 2)
      deadline = ScriptedGatt.mono + timeout
      @mutex.synchronize do
        while @thread.nil?
          remaining = deadline - ScriptedGatt.mono
          raise "the Walk thread for #{address} did not enter run within #{timeout} s" if remaining <= 0

          @changed.wait(@mutex, remaining)
        end
      end
    end

    # Wait for the Walk thread to exit; re-raises what it died with.
    def join(timeout = 2)
      await_run(timeout)
      thread.join(timeout) || raise("the Walk thread for #{address} did not end within #{timeout} s")
    end

    # Cleanup: end a Walk still blocked in run with +report+ and join its thread.
    def abandon(report)
      release(report) unless finished?
      thread&.join(2) || (thread && raise("the Walk thread for #{address} leaked past its example"))
    end
  end

  # The walker_class double: a factory whose new has GattWalker.new's keyword
  # interface, keeping every walker it built in order.
  class ScriptedWalkers
    attr_accessor :on_new

    def initialize(clock)
      @clock   = clock
      @mutex   = Mutex.new
      @changed = ConditionVariable.new
      @built   = []
      @on_new  = nil
    end

    def new(**keywords)
      walker = ScriptedWalker.new(keywords, @clock)
      @mutex.synchronize do
        @built << walker
        @changed.broadcast
      end
      @on_new&.call(walker)
      walker
    end

    def built
      @mutex.synchronize { @built.dup }
    end

    # The +count+th walker built, waiting for the Walk thread to build it.
    def await_built(count, timeout: 2)
      deadline = ScriptedGatt.mono + timeout
      @mutex.synchronize do
        while @built.size < count
          remaining = deadline - ScriptedGatt.mono
          raise "#{@built.size} walker(s) built within #{timeout} s, wanted #{count}" if remaining <= 0

          @changed.wait(@mutex, remaining)
        end
        @built[count - 1]
      end
    end
  end

  # The tracker seam. Each call the scanner makes is recorded, then forwarded
  # to the real GattTracker, so plans come from real state (a young
  # Finished_Walk with no hash really plans :skip) and the examples assert the
  # effects both on the call list and on what the tracker then holds. A call
  # is recorded as [name, *positional] with the keywords, when any, as one
  # trailing Hash: [:store_resume_state, address, state, { planned_at: t }].
  # Keywords are forwarded as keywords; in Ruby 3 a *args-only forwarder would
  # re-send planned_at: as a positional Hash and the real tracker would refuse
  # it with an ArgumentError.
  class RecordingTracker
    def initialize
      @mutex = Mutex.new
      @calls = []
    end

    %i[plan_for record_finished store_resume_state clear_resume_state].each do |name|
      define_method(name) do |*args, **kwargs|
        @mutex.synchronize { @calls << (kwargs.empty? ? [name, *args] : [name, *args, kwargs]) }
        BlueHydra::GattTracker.public_send(name, *args, **kwargs)
      end
    end

    def calls
      @mutex.synchronize { @calls.dup }
    end

    def calls_for(address)
      calls.select { |call| call[1] == address }
    end
  end
end

describe BlueHydra::GattScanner do
  let(:mac)          { "7A:BB:CC:DD:EE:FF" }
  let(:other)        { "4C:11:22:33:44:55" }
  let(:third)        { "C0:FF:EE:00:00:01" }
  let(:local)        { "02:00:15:00:00:41" }
  let(:rate)         { 300 }                 # info_scan_rate, seconds
  let(:walk_timeout) { 10 }                  # Walk_Bound, seconds
  let(:t0)           { 1_000.0 }             # the fake clock at the start of every example
  let(:hash_a)       { "00112233445566778899aabbccddeeff" }
  let(:hash_b)       { "ffeeddccbbaa99887766554433221100" }
  let(:le_public)    { BlueHydra::Mgmt::LE_PUBLIC }
  let(:le_random)    { BlueHydra::Mgmt::LE_RANDOM }
  let(:clock)        { FakeClock.new(t0) }
  let(:results)      { Queue.new }
  let(:walkers)      { ScriptedGatt::ScriptedWalkers.new(clock) }
  let(:tracker)      { ScriptedGatt::RecordingTracker.new }
  let(:real_tracker) { BlueHydra::GattTracker }
  let(:link_up)      { ->(_address) { t0 - 0.1 } }
  let(:walk_state)   { BlueHydra::GattWalker::WalkState }
  let(:plan)         { BlueHydra::GattWalker::Plan }
  let(:zero)         { described_class::ZERO_COUNTERS }
  let(:scanner)      { new_scanner }

  # The keywords GattWalker.new accepts, so the double is held to the real
  # walker's interface.
  let(:gatt_walker_keywords) do
    BlueHydra::GattWalker.instance_method(:initialize).parameters
                         .select { |kind, _| %i[keyreq key].include?(kind) }.map(&:last)
  end

  # The scanner never references Device or DataMapper; these record and raise
  # on any message so a call from a Walk thread, where the scanner's rescues
  # would swallow the raise, still shows up in db_calls (Requirement 17.10).
  let(:db_calls) { [] }
  let(:tripwire_class) do
    Class.new(BasicObject) do
      def initialize(name, calls)
        @name  = name
        @calls = calls
      end

      def method_missing(message, *_args, &_block)
        @calls << "#{@name}.#{message}"
        ::Kernel.raise ::RuntimeError, "GattScanner touched the database: #{@name}.#{message}"
      end
    end
  end

  before do
    real_tracker.reset!
    # The scanner passes its own clock reading as now to plan_for and
    # record_finished (design: Clocks), so the tracker's clock is never read.
    real_tracker.clock = -> { raise "the scanner passes now explicitly; the tracker's clock must not be read" }

    @scanners  = []
    @log_mutex = Mutex.new
    @log       = {}
    %i[debug info warn error fatal].each do |level|
      allow(BlueHydra.logger).to receive(level) do |message|
        @log_mutex.synchronize { (@log[level] ||= []) << message }
      end
    end

    stub_const("BlueHydra::Device", tripwire_class.new("BlueHydra::Device", db_calls))
    stub_const("DataMapper", tripwire_class.new("DataMapper", db_calls)) if defined?(::DataMapper)
  end

  # No Walk thread may outlive its example: every walker still blocked in run
  # is released and joined, which also ends any Reset_Deferral still waiting.
  after do
    walkers.built.each { |walker| walker.abandon(report(:disconnected, address: walker.address)) }
    @scanners.each { |s| wait_until("every Walk of #{s} to finish") { s.in_flight.zero? } }
    real_tracker.reset!
    expect(db_calls).to eq([])
  end

  def mono
    ScriptedGatt.mono
  end

  def new_scanner(**overrides)
    described_class.new(hci_index: 0, result_queue: results, link_up: link_up, local_address: local,
                        walk_parallel: 2, walk_timeout: walk_timeout, read_all: true, info_scan_rate: rate,
                        tracker: tracker, walker_class: walkers, clock: clock, **overrides)
                   .tap { |s| @scanners << s }
  end

  def logs(level)
    @log_mutex.synchronize { (@log[level] || []).dup }
  end

  def all_logs
    @log_mutex.synchronize { @log.values.flatten }
  end

  def wait_until(what, timeout: 2)
    deadline = mono + timeout
    until yield
      raise "timed out after #{timeout} s waiting for #{what}" if mono > deadline

      sleep 0.005
    end
  end

  # A real WalkReport; the fields default to a Walk that learnt nothing.
  def report(outcome, address: mac, **fields)
    BlueHydra::GattWalker::WalkReport.new(**{
      address: address, outcome: outcome, resumed: false, started_at: t0, ended_at: clock.now,
      mtu: BlueHydra::GattWalker::DEFAULT_MTU, requests_sent: 0, services: [], characteristics: [],
      identity: {}, database_hash: nil, hash_changed: false, state: nil,
      outstanding: { procedures: [], reads: [] }, handoff_lag: nil
    }.merge(fields))
  end

  # WalkStates: one with its whole worklist ahead of it, one that has done a
  # page, one with nothing left (possible only when resumed, GattWalker's
  # WalkReport comment).
  def outstanding_state
    walk_state.fresh
  end

  def advanced_state
    walk_state.fresh.tap { |state| state.procedures.shift }
  end

  def drained_state
    walk_state.fresh.tap do |state|
      state.procedures.clear
      state.reads_generated = true
    end
  end

  # A handoff that starts a Walk: returns its walker once the Walk thread has
  # built it and entered run (where a real walker binds and connects).
  def start_walk(address, type = le_public, source: :auto, on: scanner)
    seen = walkers.built.size
    expect(on.handoff(address, type, source: source)).to eq(:attempted)
    walker = walkers.await_built(seen + 1)
    expect(walker.address).to eq(address)
    walker.await_run
    walker
  end

  # Release a Walk and wait for the scanner to have counted it.
  def finish(walker, report = nil, &action)
    walker.release(report, &action)
    walker.join
  end

  describe "#initialize" do
    it "rejects a walk_parallel that is not an Integer of at least 1" do
      [0, -1, 2.0, "3", nil].each do |value|
        expect { new_scanner(walk_parallel: value) }.to raise_error(ArgumentError, /walk_parallel/)
      end
    end

    it "rejects a walk_timeout that is not a positive number of seconds" do
      [0, -5, "10", nil].each do |value|
        expect { new_scanner(walk_timeout: value) }.to raise_error(ArgumentError, /walk_timeout/)
      end
    end

    it "starts every counter at 0 with nothing in flight (13.1)" do
      expect(scanner.counters).to eq(zero)
      expect(scanner.counters.keys).to eq(described_class::COUNTERS)
      expect(scanner.in_flight).to eq(0)
      expect(scanner.stopping?).to be(false)
    end

    it "takes the GattTracker's kind of clock, a callable, as well as an object with #now" do
      callable = new_scanner(clock: -> { 5.0 })
      walker   = start_walk(mac, on: callable)
      expect(walker.keywords[:deadline]).to eq(5.0 + walk_timeout)
      expect(walker.keywords[:clock].now).to eq(5.0)
      finish(walker, report(:complete))

      expect { new_scanner(clock: Object.new) }.to raise_error(ArgumentError, /clock/)
    end

    # The scanner is built without a Mgmt: nothing in it can stop or start
    # discovery, during a Walk or while a reset is deferred.
    it "has no Mgmt to command (3.2, 3.10)" do
      keywords = described_class.instance_method(:initialize).parameters.map(&:last)
      expect(keywords).not_to include(:mgmt)
    end
  end

  describe "#handoff" do
    it "returns :attempted within 100 ms and runs the Walk on a thread of its own (2.3, 2.4)" do
      before  = mono
      outcome = scanner.handoff(mac, le_public, source: :auto)
      elapsed = mono - before

      expect(outcome).to eq(:attempted)
      expect(elapsed).to be < 0.1
      expect(all_logs).to be_empty                   # the handoff logs nothing

      walker = walkers.await_built(1).tap(&:await_run)
      expect(walker.thread).not_to be(Thread.current)
      expect(walker.build_thread).to be(walker.thread)   # built on the Walk thread, not the caller's
      # the handoff is back while the Walk has neither opened a bearer nor ended
      expect(scanner.counters).to eq(zero.merge(attempted: 1, :"in-flight" => 1))
      expect(scanner.in_flight).to eq(1)
      expect(results).to be_empty

      finish(walker, report(:complete))
      expect(scanner.counters).to eq(zero.merge(attempted: 1, complete: 1))
    end

    it "builds the walker with GattWalker's keywords: the handoff, the plan, Walk_Bound from the handoff " \
       "time, and the shared callables and clock (3.4)" do
      walker = start_walk(mac, le_random, source: :direct)
      keywords = walker.keywords

      expect(keywords.keys).to match_array(gatt_walker_keywords)
      expect(keywords).to include(address: mac, address_type: le_random, hci_index: 0, local_address: local,
                                  read_all: true)
      expect(keywords[:plan]).to eq(plan.full)
      expect(keywords[:deadline]).to eq(t0 + walk_timeout)
      expect(keywords[:link_up]).to be(link_up)
      expect(keywords[:clock]).to be(clock)
      expect(keywords[:stopping].call).to be(false)
      scanner.stopping!
      expect(keywords[:stopping].call).to be(true)

      finish(walker, report(:complete))
    end

    it "passes read_all through as configured (1.8)" do
      identity_only = new_scanner(read_all: false)
      walker = start_walk(mac, on: identity_only)
      expect(walker.keywords[:read_all]).to be(false)
      finish(walker, report(:complete))
    end

    # The fake clock stands still between the handoff and the walker, so on it
    # the gap is 0; the real-clock reading is what shows the thread is spawned
    # at the handoff rather than queued.
    it "has the walker built and in run, where its bearer binds and connects, within 200 ms of the " \
       "handoff on the fake clock (2.9, 16.15)" do
      handoff_at   = clock.now
      handoff_real = mono
      walker = start_walk(mac)

      expect(walker.built_at - handoff_at).to be <= 0.2
      expect(walker.run_at - handoff_at).to be <= 0.2
      expect(walker.run_real - handoff_real).to be < 0.2

      finish(walker, report(:complete))
    end

    it "counts attempted and in-flight before the walker, and so its Att_Bearer, exists (13.2)" do
      seen = Queue.new
      s = scanner
      walkers.on_new = ->(_walker) { seen << s.counters }

      walker = start_walk(mac)
      expect(seen.pop(timeout: 1)).to eq(zero.merge(attempted: 1, :"in-flight" => 1))
      finish(walker, report(:complete))
    end

    it "skips an address already in flight, whatever the capacity, and consults the tracker only " \
       "once (4.11, 13.4)" do
      first = start_walk(mac)
      expect(scanner.handoff(mac, le_public, source: :direct)).to eq(:skipped)
      expect(tracker.calls_for(mac).size).to eq(1)            # the in-flight check comes first

      second = start_walk(other)                              # now at Walk_Parallel
      expect(scanner.handoff(mac, le_public, source: :auto)).to eq(:skipped)
      expect(scanner.counters).to eq(zero.merge(attempted: 2, :"in-flight" => 2, skipped: 2))
      expect(walkers.built.size).to eq(2)

      finish(first, report(:complete))
      finish(second, report(:complete, address: other))
    end

    it "skips a young Finished_Walk with no hash, even at capacity, counting skipped and not " \
       "deferred (4.7, 13.4)" do
      real_tracker.record_finished(mac, nil, t0, rate)
      clock.advance(rate - 1)                                 # still younger than info_scan_rate

      expect(scanner.handoff(mac, le_public, source: :auto)).to eq(:skipped)
      expect(walkers.built).to be_empty

      first  = start_walk(other)
      second = start_walk(third)
      expect(scanner.handoff(mac, le_public, source: :auto)).to eq(:skipped)
      expect(scanner.counters).to eq(zero.merge(attempted: 2, :"in-flight" => 2, skipped: 2))
      expect(tracker.calls_for(mac)).to eq([[:plan_for, mac, t0 + rate - 1, rate]] * 2)

      finish(first, report(:complete, address: other))
      finish(second, report(:complete, address: third))
    end

    it "defers at Walk_Parallel with the tracker untouched, so a later handoff stays eligible (3.6)" do
      first  = start_walk(mac)
      second = start_walk(other)

      expect(scanner.handoff(third, le_random, source: :direct)).to eq(:deferred)
      expect(scanner.counters).to eq(zero.merge(attempted: 2, :"in-flight" => 2, deferred: 1))
      expect(walkers.built.size).to eq(2)
      expect(tracker.calls_for(third)).to eq([[:plan_for, third, t0, rate]])   # a lookup, no write
      expect(real_tracker.tracked_count).to eq(0)

      finish(first, report(:complete))
      expect(scanner.handoff(third, le_random, source: :direct)).to eq(:attempted)
      later = walkers.await_built(3).tap(&:await_run)
      expect(later.keywords[:plan]).to eq(plan.full)

      finish(second, report(:complete, address: other))
      finish(later, report(:complete, address: third))
      expect(scanner.counters).to eq(zero.merge(attempted: 3, complete: 3, deferred: 1))
    end

    it "counts resumed for a :resume plan only, and hands each walker the tracker's plan (13.11, 4.1)" do
      stored = walk_state.fresh.tap { |state| state.database_hash = hash_b }
      real_tracker.store_resume_state(mac, stored)
      real_tracker.record_finished(third, hash_a, t0, rate)
      three = new_scanner(walk_parallel: 3)

      resumed = start_walk(mac, on: three)
      expect(three.counters).to include(attempted: 1, resumed: 1)
      full = start_walk(other, on: three)
      checked = start_walk(third, on: three)
      expect(three.counters).to include(attempted: 3, resumed: 1)

      expect(resumed.keywords[:plan]).to eq(plan.resume(stored))
      expect(full.keywords[:plan]).to eq(plan.full)
      expect(checked.keywords[:plan]).to eq(plan.hash_check(hash_a))

      finish(resumed, report(:complete, resumed: true))
      finish(full, report(:complete, address: other))
      finish(checked, report(:unchanged, address: third))
      expect(three.counters).to include(resumed: 1, complete: 2, unchanged: 1)
    end

    it "resolves handoffs racing for the last slot, or for one address, one at a time (3.7)" do
      one_slot = new_scanner(walk_parallel: 1)
      race = lambda do |addresses|
        go       = Queue.new
        outcomes = Queue.new
        threads  = addresses.map do |address|
          Thread.new do
            go.pop
            outcomes << one_slot.handoff(address, le_public, source: :direct)
          end
        end
        addresses.size.times { go << true }
        threads.each { |thread| thread.join(2) || raise("a handoff thread hung") }
        Array.new(addresses.size) { outcomes.pop }.tally
      end

      six = (1..6).map { |i| format("7A:00:00:00:00:%02X", i) }
      expect(race.call(six)).to eq(attempted: 1, deferred: 5)
      expect(one_slot.counters).to eq(zero.merge(attempted: 1, :"in-flight" => 1, deferred: 5))
      taken = walkers.await_built(1).tap(&:await_run)
      expect(six).to include(taken.address)
      finish(taken, report(:complete, address: taken.address))

      expect(race.call([mac] * 6)).to eq(attempted: 1, skipped: 5)
      expect(one_slot.counters).to eq(zero.merge(attempted: 2, :"in-flight" => 1, complete: 1, deferred: 5,
                                                 skipped: 5))
      expect(walkers.built.size).to eq(2)
      finish(walkers.await_built(2).tap(&:await_run), report(:complete))
    end

    it "returns nil and moves no counter once stopping! has been called (14.1)" do
      walker = start_walk(mac)
      scanner.stopping!

      expect(scanner.stopping?).to be(true)
      expect(scanner.handoff(other, le_public, source: :auto)).to be_nil
      expect(scanner.handoff(mac, le_public, source: :auto)).to be_nil     # not even skipped
      expect(scanner.counters).to eq(zero.merge(attempted: 1, :"in-flight" => 1))
      expect(walkers.built.size).to eq(1)
      expect(tracker.calls.size).to eq(1)                                 # the first handoff's plan_for

      finish(walker, report(:complete))
      expect(scanner.counters).to eq(zero.merge(attempted: 1, complete: 1))
      expect(results).to be_empty                                         # 14.3
    end
  end

  describe "counting the Walk_Outcome (13.9) and delivering the result (11.1)" do
    BlueHydra::GattScanner::OUTCOMES.each do |outcome|
      with_result = BlueHydra::GattScanner::OUTCOMES_WITH_RESULT.include?(outcome)

      it "#{outcome}: in-flight down by 1, #{outcome} up by 1, #{with_result ? 'one result' : 'no result'}" do
        walker = start_walk(mac)
        finish(walker, report(outcome))

        expect(scanner.counters).to eq(zero.merge(attempted: 1, outcome => 1))
        expect(results.size).to eq(with_result ? 1 : 0)
        expect(results.pop[:outcome]).to eq(outcome) if with_result
        expect(walker.closes).to eq([walker.thread])                      # 5.6: closed as it is counted
      end
    end

    # The Runner drops parser output while stunned (runner.rb: result_queue.push
    # unless self.stunned). The scanner takes no such flag, so there is nothing
    # a stunned Runner could set here: a Walk result is pushed whether the
    # Runner is stunned or not.
    it "carries the address, outcome, end time, services, characteristics, identity and outstanding " \
       "work, stunned or not (11.1)" do
      services = [{ uuid: "Generic Access (0x1800)", type: :primary, start: 1, end: 9, includes: [] },
                  { uuid: "Device Information (0x180a)", type: :primary, start: 10, end: 20, includes: [] }]
      characteristics = [{ uuid: "Device Name (0x2a00)", value_handle: 3, read_status: "read", value: "Pixel" },
                         { uuid: "Model Number String (0x2a24)", value_handle: 12, read_status: "protected",
                           error_code: 5 }]
      identity    = { device_name: "Pixel" }
      outstanding = { procedures: [{ kind: :characteristics, start: 10, end: 20, next: 10 }], reads: [] }
      walker = start_walk(mac)

      before = Time.now.to_i
      finish(walker, report(:timeout, resumed: true, database_hash: hash_a, hash_changed: true,
                                      services: services, characteristics: characteristics,
                                      identity: identity, state: advanced_state, outstanding: outstanding))
      after = Time.now.to_i

      result = results.pop
      expect(result).to include(gatt_walk: true, address: mac, outcome: :timeout, resumed: true,
                                database_hash: hash_a, hash_changed: true,
                                service_uuids: ["Generic Access (0x1800)", "Device Information (0x180a)"],
                                characteristics: characteristics, identity: identity, outstanding: outstanding)
      expect(result[:ended_at]).to be_between(before, after)
      expect(result.keys).to match_array(%i[gatt_walk address outcome resumed ended_at database_hash
                                            hash_changed service_uuids characteristics identity outstanding])
    end

    it "logs one debug line per Walk with the Requirement 13.6 fields (13.6)" do
      services = [{ uuid: "Generic Access (0x1800)" }, { uuid: "Battery (0x180f)" }]
      characteristics = [{ read_status: "read" }, { read_status: "read" }, { read_status: "protected" }]

      direct = start_walk(mac, le_random, source: :direct)
      finish(direct, report(:complete, ended_at: t0 + 1.5, requests_sent: 7, mtu: 185, services: services,
                                       characteristics: characteristics, handoff_lag: 0.05))
      resumed = start_walk(other)
      finish(resumed, report(:partial, address: other, resumed: true, ended_at: t0 + 0.2, requests_sent: 2))

      expect(logs(:debug)).to eq([
        "gatt: walk #{mac} outcome=complete resumed=false duration_ms=1500 requests=7 mtu=185 services=2 " \
        "characteristics=3 values_read=2 source=direct handoff_lag_ms=50",
        "gatt: walk #{other} outcome=partial resumed=true duration_ms=200 requests=2 mtu=23 services=0 " \
        "characteristics=0 values_read=0 source=auto handoff_lag_ms=-"
      ])
    end

    it "counts peer-req through the on_peer_request callable, outside the invariant (8.7, 13.4)" do
      walker = start_walk(mac)
      on_peer_request = walker.keywords[:on_peer_request]
      done = report(:complete)

      finish(walker) do                                   # what the Att_Server does per reply, on the Walk thread
        3.times { on_peer_request.call }
        done
      end

      expect(scanner.counters).to eq(zero.merge(attempted: 1, complete: 1, :"peer-req" => 3))
    end
  end

  describe "an exception escaping run (13.7)" do
    it "is counted error and logged with class, message and backtrace while the other Walk and new " \
       "handoffs go on" do
      raising = start_walk(mac)
      steady  = start_walk(other)

      finish(raising) { raise RuntimeError, "boom" }

      expect(scanner.counters).to eq(zero.merge(attempted: 2, :"in-flight" => 1, error: 1))
      line = logs(:error).find { |message| message.start_with?("gatt: #{mac} walking raised") }
      expect(line).to start_with("gatt: #{mac} walking raised RuntimeError: boom\n  ")
      expect(line).to include(File.basename(__FILE__))                    # the backtrace names the raise
      expect(raising.closes).to eq([raising.thread])                      # the bearer is still closed
      expect(results).to be_empty
      expect(logs(:debug)).to eq([
        "gatt: walk #{mac} outcome=error resumed=false duration_ms=0 requests=0 mtu=23 services=0 " \
        "characteristics=0 values_read=0 source=auto handoff_lag_ms=-"
      ])
      expect(tracker.calls_for(mac)).to eq([[:plan_for, mac, t0, rate]])  # 4.9

      expect(scanner.handoff(third, le_public, source: :direct)).to eq(:attempted)
      extra = walkers.await_built(3).tap(&:await_run)
      finish(steady, report(:complete, address: other, database_hash: hash_a))
      finish(extra, report(:complete, address: third))

      expect(scanner.counters).to eq(zero.merge(attempted: 3, complete: 2, error: 1))
      expect(results.size).to eq(2)
      expect(real_tracker.finished(other)).to eq(finished_at: t0, database_hash: hash_a)
    end

    it "counts a return value that is no WalkReport as error and says so" do
      walker = start_walk(mac)
      finish(walker) { :done }

      expect(scanner.counters).to eq(zero.merge(attempted: 1, error: 1))
      expect(logs(:error)).to eq(["gatt: #{mac} walker returned :done; counted as error"])
      expect(results).to be_empty
    end
  end

  describe "the counter invariant under concurrency (13.3, 13.8)" do
    # Feature: gatt-service-scanning, Property 14: Counter invariant under concurrency
    #
    # For any Walk_Parallel 1..4, any pool of 2..5 addresses each pre-seeded
    # with one of the tracker's four plans (nothing: full; a young
    # Finished_Walk without a hash: skip; one with a hash: hash_check; a stored
    # Resume_State: resume), and any script of 6..30 actions in 3..6 rounds,
    # where each action is a handoff of a pool address from a thread of its
    # own, the ending of a Walk in flight (any of the eight Walk_Outcomes, an
    # exception escaping run, or a return that is no WalkReport; optionally
    # with a Database Hash, a Resume_State, or an on_peer_request call from the
    # Walk thread first), or an on_peer_request call, with stopping! fired
    # during some round in some cases: every counters snapshot taken by a
    # sampler thread spinning throughout, every one a Walk thread takes as
    # its Walk is about to end, and every one taken between rounds,
    # satisfies attempted == in-flight + complete + partial + protected +
    # unchanged + busy + timeout + disconnected + error and
    # 0 <= in-flight <= Walk_Parallel; and once every Walk has ended, in-flight
    # is 0, attempted equals the number of :attempted returns and of walkers
    # built, skipped and deferred equal their returns, each outcome counter
    # equals the number of Walks ended with it (error counting the raises and
    # the garbage returns), resumed equals the walkers built with a :resume
    # plan, peer-req equals the on_peer_request calls made, reset-deferred is
    # 0, a handoff returned nil only once stopping! had been called, and every
    # handoff after the stopping round returned nil.
    #
    # The actions of a round all fire at once behind one latch, so handoffs
    # race each other for the last slot and for one address, and race the
    # ends of the Walks they may be skipped for; which handoff wins is the
    # scheduler's and is not asserted, only that whatever each returned is
    # what was counted. Between rounds everything is joined, so in-flight is
    # also checked against the in-flight map and against the walkers not yet
    # ended. Which Walk an ending targets is drawn from those in flight at the
    # round's start; an ending with none to target does nothing. A plain
    # Array is not shrinkable in rantly, so a failing case is printed as
    # generated.
    it "Property 14: attempted == in-flight + the outcome counters and 0 <= in-flight <= Walk_Parallel in " \
       "every snapshot, with each handoff and each Walk end moving exactly one counter" do
      outcomes = described_class::OUTCOMES
      types    = [le_public, le_random]
      tracker_guard = -> { raise "the scanner passes now explicitly; the tracker's clock must not be read" }
      outcome_of = ->((kind, _extra)) { outcomes.include?(kind) ? kind : :error }

      # The thunk that ends +walker+'s Walk per +ending+, built on the example
      # thread so the round thread only pushes it. The Walk thread takes a
      # +sample+ of the counters just before run returns or raises: the
      # instant its Walk is still in flight while its ending is under way.
      release_for = lambda do |walker, (kind, extra), sample|
        body =
          case kind
          when :raise   then -> { raise RuntimeError, "boom from #{walker.address}" }
          when :garbage then -> { :garbage }
          else
            done = report(kind, address: walker.address,
                                database_hash: extra == :hash ? hash_a : nil,
                                state: extra == :state ? advanced_state : nil)
            -> { done }
          end
        if extra == :peer
          on_peer = walker.keywords[:on_peer_request]
          inner   = body
          body    = -> { on_peer.call; inner.call }
        end
        ending_body = body
        -> { walker.release { sample.call; ending_body.call } }
      end

      seen = Hash.new(0)
      # A proc, because rantly instance_evals generators on itself.
      ending = proc {
        [freq([8, proc { choose(*outcomes) }], [1, :literal, :raise], [1, :literal, :garbage]),
         freq([2, :literal, nil], [2, :literal, :hash], [1, :literal, :state], [1, :literal, :peer])]
      }

      property_of {
        wp     = range(1, 4)
        pool   = range(2, 5)
        plans  = array(pool) { freq([3, :literal, :full], [1, :literal, :skip], [2, :literal, :hash_check],
                                    [2, :literal, :resume]) }
        rounds = array(range(3, 6)) {
          array(range(2, 5)) {
            freq([5, proc { [:handoff, range(0, pool - 1), range(0, 1), choose(:auto, :direct)] }],
                 [4, proc { [:finish, range(0, 99), call(ending)] }],
                 [1, :literal, [:peer_request]])
          }
        }
        stop_at  = freq([3, :literal, nil], [2, proc { range(0, rounds.size - 1) }])
        stop_pos = range(0, 5)
        tail     = array(wp) { call(ending) }
        [wp, pool, plans, rounds, stop_at, stop_pos, tail]
      }.check(100) { |wp, pool, plans, rounds, stop_at, stop_pos, tail|
        addresses = Array.new(pool) { |i| format("7A:14:00:00:00:%02X", i) }
        real_tracker.reset!
        real_tracker.clock = tracker_guard
        plans.each_with_index do |kind, i|
          case kind
          when :skip       then real_tracker.record_finished(addresses[i], nil, t0, rate)
          when :hash_check then real_tracker.record_finished(addresses[i], hash_a, t0, rate)
          when :resume     then real_tracker.store_resume_state(addresses[i], outstanding_state)
          end
        end

        factory = ScriptedGatt::ScriptedWalkers.new(clock)
        counted = new_scanner(walk_parallel: wp, walker_class: factory)

        sample_mutex  = Mutex.new
        violations    = []
        max_in_flight = 0
        samples       = 0
        sampling      = true
        check_snapshot = lambda do |snap, where|
          sum = snap[:"in-flight"] + outcomes.sum { |outcome| snap[outcome] }
          sample_mutex.synchronize do
            max_in_flight = [max_in_flight, snap[:"in-flight"]].max
            unless snap[:attempted] == sum
              violations << "#{where}: attempted #{snap[:attempted]} != in-flight + outcomes #{sum} in #{snap}"
            end
            unless snap[:"in-flight"].between?(0, wp)
              violations << "#{where}: in-flight #{snap[:"in-flight"]} outside 0..#{wp} in #{snap}"
            end
          end
        end
        sample   = -> { check_snapshot.(counted.counters, "Walk thread, about to end") }
        observer = Thread.new do
          while sampling
            check_snapshot.(counted.counters, "sampler")
            samples += 1
            Thread.pass
          end
        end

        expected        = Hash.new(0)   # :attempted, :skipped, :deferred and the outcome counters
        nil_returns     = 0
        peer_calls      = 0
        handoff_results = []
        finished        = {}.compare_by_identity
        stop_seen       = false
        begin
          rounds.each_with_index do |actions, round_index|
            actions = actions.dup
            actions.insert([stop_pos, actions.size].min, [:stopping]) if stop_at == round_index
            built     = factory.built
            available = built.reject { |walker| finished.key?(walker) }
            peer      = built.first&.keywords&.fetch(:on_peer_request)
            stopped_before_round = stop_seen

            prepared = actions.map do |action|
              case action[0]
              when :handoff
                _, i, type_index, source = action
                seen[:young_finished_walk_handoff] += 1 if plans[i] == :skip
                [:handoff, -> { counted.handoff(addresses[i], types[type_index], source: source) }]
              when :finish
                _, pick, finish_ending = action
                if available.empty?
                  [:finish_noop, -> {}]
                else
                  walker = available.delete_at(pick % available.size)
                  [:finish, release_for.(walker, finish_ending, sample), walker, finish_ending]
                end
              when :peer_request
                peer ? [:peer_request, -> { peer.call }] : [:peer_noop, -> {}]
              when :stopping
                [:stopping, -> { counted.stopping! }]
              end
            end

            # Fire the whole round at once, as 3.7's race does.
            go      = Queue.new
            results = Array.new(prepared.size)
            threads = prepared.each_with_index.map do |(_kind, thunk), index|
              Thread.new do
                go.pop
                results[index] = thunk.call
              end
            end
            prepared.size.times { go << true }
            threads.each { |thread| thread.join(5) || raise("a round thread hung") }

            round_handoffs = []
            round_finishes = 0
            prepared.each_with_index do |(kind, _thunk, walker, finish_ending), index|
              case kind
              when :handoff
                result = results[index]
                round_handoffs << result
                handoff_results << result
                if result.nil?
                  nil_returns += 1
                else
                  expected[result] += 1
                end
              when :finish
                walker.join(5)                        # the scanner has counted it once the thread is gone
                finished[walker] = true
                expected[outcome_of.(finish_ending)] += 1
                peer_calls += 1 if finish_ending[1] == :peer
                round_finishes += 1
                seen[finish_ending[0]] += 1
                seen[:"ending_with_#{finish_ending[1]}"] += 1 if finish_ending[1]
              when :finish_noop   then seen[:finish_noop] += 1
              when :peer_request  then peer_calls += 1
              when :stopping      then stop_seen = true
              end
            end
            seen[:concurrent_handoffs] += 1 if round_handoffs.size >= 2
            seen[:handoff_races_finish] += 1 if round_handoffs.any? && round_finishes.positive?
            expect(round_handoffs).to all(be_nil) if stopped_before_round

            # Quiescent: every handoff returned, every ended Walk is counted,
            # every started one has its walker.
            factory.await_built(expected[:attempted], timeout: 5)
            snap = counted.counters
            check_snapshot.(snap, "after round #{round_index}")
            still = factory.built.count { |walker| !finished.key?(walker) }
            expect(snap[:"in-flight"]).to eq(still)
            expect(counted.in_flight).to eq(still)
          end

          # End every Walk still in flight, all at once, then wait for each.
          pending = factory.built.reject { |walker| finished.key?(walker) }
          expect(pending.size).to be <= wp
          pending.zip(tail).each { |walker, finish_ending| release_for.(walker, finish_ending, sample).call }
          pending.zip(tail).each do |walker, finish_ending|
            walker.join(5)
            finished[walker] = true
            expected[outcome_of.(finish_ending)] += 1
            peer_calls += 1 if finish_ending[1] == :peer
            seen[finish_ending[0]] += 1
          end
          sampling = false
          observer.join(5) || raise("the sampler thread hung")

          built   = factory.built
          resumed = built.count { |walker| walker.keywords[:plan].kind == :resume }
          expect(violations).to eq([])
          expect(samples).to be > 0
          expect(counted.counters).to eq(zero.merge(expected).merge(:"in-flight" => 0, resumed: resumed,
                                                                     :"peer-req" => peer_calls))
          expect(counted.in_flight).to eq(0)
          expect(built.size).to eq(expected[:attempted])
          expect(built.map(&:address) - addresses).to eq([])
          expect(handoff_results - [:attempted, :skipped, :deferred, nil]).to eq([])
          expect(expected[:attempted] + expected[:skipped] + expected[:deferred] + nil_returns)
            .to eq(handoff_results.size)
          expect(nil_returns).to eq(0) if stop_at.nil?
          expect(counted.stopping?).to eq(!stop_at.nil?)
          expect(max_in_flight).to be <= wp
        ensure
          sampling = false
          observer.join(5)
          factory.built.each { |walker| walker.abandon(report(:disconnected, address: walker.address)) }
        end

        seen[:"parallel_#{wp}"] += 1
        handoff_results.tally.each { |result, _n| seen[result || :stopped_nil] += 1 }
        built.map { |walker| walker.keywords[:plan].kind }.uniq.each { |kind| seen[:"plan_#{kind}"] += 1 }
        seen[:peer_req] += 1 if peer_calls.positive?
        seen[:at_capacity] += 1 if max_in_flight == wp
        seen[:resumed_counted] += 1 if resumed.positive?
      }

      expect(seen.keys).to include(:attempted, :skipped, :deferred, :stopped_nil, *outcomes, :raise, :garbage,
                                   :ending_with_hash, :ending_with_state, :ending_with_peer, :peer_req,
                                   :plan_full, :plan_hash_check, :plan_resume, :resumed_counted,
                                   :young_finished_walk_handoff, :at_capacity, :concurrent_handoffs,
                                   :handoff_races_finish, :parallel_1, :parallel_4)
    end
  end

  describe "Gatt_Tracker effects" do
    %i[complete partial protected].each do |outcome|
      it "#{outcome}: clears Resume_State, then records the finish time and the hash as reported, " \
         "nil included (4.8, 4.14, 17.7)" do
        real_tracker.record_finished(mac, hash_b, t0 - 50, rate)
        real_tracker.store_resume_state(mac, outstanding_state)
        hash = outcome == :protected ? nil : hash_a
        walker = start_walk(mac)
        expect(walker.keywords[:plan].kind).to eq(:resume)

        done = report(outcome, database_hash: hash)
        finish(walker) do
          clock.advance(2.5)
          done
        end

        expect(tracker.calls_for(mac).drop(1)).to eq([[:clear_resume_state, mac],
                                                      [:record_finished, mac, hash, t0 + 2.5, rate]])
        expect(real_tracker.resume_state(mac)).to be_nil
        expect(real_tracker.finished(mac)).to eq(finished_at: t0 + 2.5, database_hash: hash)
        expect(scanner.counters).to include(outcome => 1, resumed: 1, :"in-flight" => 0)
      end
    end

    %i[timeout disconnected].each do |outcome|
      describe outcome.to_s do
        let(:old_state) { walk_state.fresh.tap { |state| state.database_hash = hash_b } }

        before do
          real_tracker.record_finished(mac, hash_b, t0 - 50, rate)
          real_tracker.store_resume_state(mac, old_state)
        end

        it "stores the report's state as Resume_State when work is outstanding, leaving the finish " \
           "record alone (17.1, 17.5, 4.9)" do
          walker = start_walk(mac)
          finish(walker, report(outcome, state: advanced_state))

          expect(tracker.calls_for(mac).drop(1)).to eq([[:store_resume_state, mac, advanced_state,
                                                         { planned_at: t0 }]])
          expect(real_tracker.resume_state(mac)).to eq(advanced_state)
          expect(real_tracker.finished(mac)).to eq(finished_at: t0 - 50, database_hash: hash_b)
        end

        it "clears Resume_State when the state has nothing outstanding (17.1)" do
          walker = start_walk(mac)
          finish(walker, report(outcome, state: drained_state))

          expect(tracker.calls_for(mac).drop(1)).to eq([[:clear_resume_state, mac]])
          expect(real_tracker.resume_state(mac)).to be_nil
        end

        it "leaves Resume_State alone when the report carries no state (4.15)" do
          walker = start_walk(mac)
          finish(walker, report(outcome, state: nil))

          expect(tracker.calls_for(mac).drop(1)).to eq([])
          expect(real_tracker.resume_state(mac)).to eq(old_state)
        end

        it "clears Resume_State when the hash changed, storing nothing for a report without state (17.6)" do
          walker = start_walk(mac)
          finish(walker, report(outcome, hash_changed: true, database_hash: hash_a, state: nil))

          expect(tracker.calls_for(mac).drop(1)).to eq([[:clear_resume_state, mac]])
          expect(real_tracker.resume_state(mac)).to be_nil
          expect(real_tracker.finished(mac)).to eq(finished_at: t0 - 50, database_hash: hash_b)
        end
      end
    end

    it "a hash-changed Walk cut short with work outstanding clears the old Resume_State, then stores " \
       "the new one (17.6, 17.5)" do
      real_tracker.store_resume_state(mac, outstanding_state)
      walker = start_walk(mac)
      finish(walker, report(:disconnected, hash_changed: true, database_hash: hash_a, state: advanced_state))

      expect(tracker.calls_for(mac).drop(1)).to eq([[:clear_resume_state, mac],
                                                    [:store_resume_state, mac, advanced_state, { planned_at: t0 }]])
      expect(real_tracker.resume_state(mac)).to eq(advanced_state)
    end

    # Device.mark_offline's forget on the Result_Thread while the Walk is in
    # flight. The scanner never calls forget; the examples call it on the real
    # tracker, with an explicit time, as the Result_Thread would.
    describe "the forget-before-store guard (17.11)" do
      let(:refused_line) { "gatt: #{mac} Resume_State not stored: device forgotten after the Walk was planned" }

      it "passes planned_at equal to the Walk's started_at, the handoff's clock reading (17.5, 17.11)" do
        clock.advance(7)                                   # the handoff is not at the example's t0
        walker = start_walk(mac)
        clock.advance(3)                                   # and the Walk ends later still
        finish(walker, report(:timeout, state: advanced_state))

        expect(tracker.calls_for(mac)).to eq([[:plan_for, mac, t0 + 7, rate],
                                              [:store_resume_state, mac, advanced_state, { planned_at: t0 + 7 }]])
        expect(real_tracker.resume_state(mac)).to eq(advanced_state)
      end

      [[:timeout, 0], [:disconnected, 2]].each do |outcome, after|
        it "#{outcome}: a forget #{after.zero? ? 'at the handoff time' : "#{after} s after the handoff"} " \
           "leaves no Resume_State, while the Walk is still counted, its result pushed and its end line " \
           "written" do
          walker = start_walk(mac)
          clock.advance(after)
          real_tracker.forget(mac, t0 + after)
          finish(walker, report(outcome, state: advanced_state))

          expect(tracker.calls_for(mac).drop(1)).to eq([[:store_resume_state, mac, advanced_state,
                                                         { planned_at: t0 }]])
          expect(real_tracker.resume_state(mac)).to be_nil
          expect(real_tracker.tracked_count).to eq(0)
          expect(scanner.counters).to eq(zero.merge(attempted: 1, outcome => 1))
          expect(results.size).to eq(1)
          expect(results.pop).to include(gatt_walk: true, address: mac, outcome: outcome)
          expect(logs(:debug).size).to eq(2)
          expect(logs(:debug).first).to eq(refused_line)   # the tracker's, before the Walk end line
          expect(logs(:debug).last).to start_with("gatt: walk #{mac} outcome=#{outcome} ")
          expect(logs(:error)).to be_empty
        end
      end

      it "does not refuse for a forget strictly before the handoff: that Walk was planned after it" do
        real_tracker.forget(mac, t0)
        clock.advance(1)
        walker = start_walk(mac)
        finish(walker, report(:disconnected, state: advanced_state))

        expect(tracker.calls_for(mac).drop(1)).to eq([[:store_resume_state, mac, advanced_state,
                                                       { planned_at: t0 + 1 }]])
        expect(real_tracker.resume_state(mac)).to eq(advanced_state)
        expect(logs(:debug)).not_to include(refused_line)
      end
    end

    %i[unchanged busy error].each do |outcome|
      it "#{outcome}: leaves the tracker as it was, whatever the report carries (4.9)" do
        old_state = walk_state.fresh.tap { |state| state.database_hash = hash_b }
        real_tracker.record_finished(mac, hash_b, t0 - 50, rate)
        real_tracker.store_resume_state(mac, old_state)
        walker = start_walk(mac)

        finish(walker, report(outcome, database_hash: hash_a, hash_changed: true, state: advanced_state))

        expect(tracker.calls_for(mac)).to eq([[:plan_for, mac, t0, rate]])
        expect(real_tracker.finished(mac)).to eq(finished_at: t0 - 50, database_hash: hash_b)
        expect(real_tracker.resume_state(mac)).to eq(old_state)
      end
    end
  end

  describe "#wait_for_idle (the Reset_Deferral)" do
    it "returns [0, 0.0] at once when nothing is in flight, moving no counter and logging nothing (3.12)" do
      before = mono
      expect(scanner.wait_for_idle(walk_timeout)).to eq([0, 0.0])
      expect(mono - before).to be < 0.05
      expect(scanner.counters).to eq(zero)
      expect(all_logs).to be_empty
    end

    it "rejects a timeout that is not a positive number of seconds" do
      [0, -1, nil, "10"].each do |value|
        expect { scanner.wait_for_idle(value) }.to raise_error(ArgumentError, /timeout/)
      end
    end

    it "returns when the last Walk ends, with the seconds waited on the clock, and counts the " \
       "deferral once (3.9, 3.13)" do
      first  = start_walk(mac)
      second = start_walk(other)
      waiter = Thread.new { scanner.wait_for_idle(walk_timeout) }

      begin
        wait_until("the Reset_Deferral to block") { waiter.status == "sleep" }

        # the first Walk ending is not the last
        first_done = report(:complete)
        finish(first) do
          clock.advance(0.5)
          first_done
        end
        expect(waiter).to be_alive
        expect(scanner.counters[:"reset-deferred"]).to eq(0)

        before = mono
        second_done = report(:complete, address: other)
        finish(second) do
          clock.advance(0.25)
          second_done
        end
        expect(waiter.join(2)).not_to be_nil
        expect(waiter.value).to eq([0, 0.75])
        expect(mono - before).to be < 1.0

        expect(scanner.counters[:"reset-deferred"]).to eq(1)
        expect(logs(:debug)).to include("gatt: reset-deferred waited_ms=750 in_flight=0 cap_ms=10000")
      ensure
        waiter.join(1)
      end
    end

    # The Runner passes gatt_walk_timeout, Walk_Bound; a shorter cap here keeps
    # the example quick. The fake clock stands still, so the cap is the real
    # clock's and waited reads 0.0 on the fake one.
    it "is capped with Walks still in flight, reporting their count and counting reset-deferred " \
       "once per wait (3.11, 3.13)" do
      first  = start_walk(mac)
      second = start_walk(other)

      before = mono
      expect(scanner.wait_for_idle(0.2)).to eq([2, 0.0])
      expect(mono - before).to be_between(0.2, 1.0)
      expect(scanner.counters).to include(:"reset-deferred" => 1, :"in-flight" => 2)
      expect(logs(:debug)).to eq(["gatt: reset-deferred waited_ms=0 in_flight=2 cap_ms=200"])

      expect(scanner.wait_for_idle(0.1)).to eq([2, 0.0])
      expect(scanner.counters[:"reset-deferred"]).to eq(2)
      expect(logs(:debug).last).to eq("gatt: reset-deferred waited_ms=0 in_flight=2 cap_ms=100")

      finish(first, report(:complete))
      finish(second, report(:complete, address: other))
    end
  end

  describe "#shutdown" do
    it "returns 0 and warns nothing with no Walk in flight" do
      expect(scanner.shutdown).to eq(0)
      expect(scanner.stopping?).to be(true)
      expect(all_logs).to be_empty
    end

    it "closes every bearer from the calling thread, one whose connect is pending included, pushes " \
       "no result and returns at once (14.2, 14.3, 14.4)" do
      # blocked in its connect wait: the close wakes it before a WalkState exists
      pending = start_walk(mac)
      pending.release_on_close(report(:disconnected))
      # mid-Walk: the close wakes it with work outstanding
      walking = start_walk(other)
      walking.release_on_close(report(:disconnected, address: other, state: advanced_state, handoff_lag: 0.02))

      before = mono
      expect(scanner.shutdown).to eq(0)
      expect(mono - before).to be < 1.0

      [pending, walking].each do |walker|
        expect(walker.closes.first).to be(Thread.current)
        expect(walker.closes.last).to be(walker.thread)
        expect(walker.thread).not_to be_alive
      end
      expect(scanner.stopping?).to be(true)
      expect(scanner.counters).to eq(zero.merge(attempted: 2, disconnected: 2))
      expect(results).to be_empty
      expect(logs(:warn)).to be_empty
      # the tracker is still kept: Resume_State for the Walk cut mid-way,
      # nothing for the one that never began
      expect(real_tracker.resume_state(other)).to eq(advanced_state)
      expect(real_tracker.resume_state(mac)).to be_nil

      expect(scanner.handoff(third, le_public, source: :auto)).to be_nil     # 14.1
      expect(scanner.counters).to eq(zero.merge(attempted: 2, disconnected: 2))
    end

    it "warns for a Walk thread still running after 1 s and leaves it to end on its own, counted " \
       "but without a result (14.4, 14.5, 14.3)" do
      straggler = start_walk(mac)                              # ignores the close: nothing wakes it

      before = mono
      expect(scanner.shutdown).to eq(1)
      expect(mono - before).to be_between(1.0, 2.0)

      expect(straggler.thread).to be_alive
      expect(straggler.closes).to eq([Thread.current])
      expect(logs(:warn)).to eq([
        "gatt: shutdown: 1 Walk thread(s) still running after 1000 ms; left to exit on their own"
      ])
      expect(scanner.counters).to eq(zero.merge(attempted: 1, :"in-flight" => 1))

      finish(straggler, report(:disconnected, state: advanced_state))
      expect(scanner.counters).to eq(zero.merge(attempted: 1, disconnected: 1))
      expect(results).to be_empty
      expect(real_tracker.resume_state(mac)).to eq(advanced_state)
    end

    it "logs a close that raises at debug and goes on closing the rest (14.7)" do
      raising = start_walk(mac)
      raising.close_raises(IOError.new("closed already"))
      raising.release_on_close(report(:disconnected))
      quiet = start_walk(other)
      quiet.release_on_close(report(:disconnected, address: other))

      expect(scanner.shutdown).to eq(0)

      expect(quiet.closes.first).to be(Thread.current)
      # once from shutdown's close, and again when finish_walk closes it
      expect(logs(:debug).count("gatt: #{mac} closing bearer raised IOError: closed already")).to be_between(1, 2)
      expect(scanner.counters).to eq(zero.merge(attempted: 2, disconnected: 2))
      expect(results).to be_empty
      expect(logs(:warn)).to be_empty
    end
  end

  describe "database access (Requirement 17.10)" do
    it "runs handoffs, every finish path, a deferred reset and shutdown without touching Device" do
      first  = start_walk(mac)
      second = start_walk(other)
      expect(scanner.handoff(third, le_public, source: :auto)).to eq(:deferred)

      finish(first, report(:complete, database_hash: hash_a))
      finish(second, report(:disconnected, address: other, state: advanced_state))
      expect(scanner.wait_for_idle(walk_timeout)).to eq([0, 0.0])

      resumed = start_walk(other)
      resumed.release_on_close(report(:timeout, address: other, state: drained_state))
      expect(scanner.shutdown).to eq(0)

      expect(scanner.counters).to include(attempted: 3, complete: 1, disconnected: 1, timeout: 1, deferred: 1,
                                          resumed: 1)
      expect(db_calls).to eq([])
    end

    # positive control: the tripwire does fire, so an empty db_calls means something
    it "would catch a Device or DataMapper call" do
      expect { BlueHydra::Device.update_or_create_from_result({}) }
        .to raise_error(RuntimeError, /BlueHydra::Device\.update_or_create_from_result/)
      expect(db_calls).to eq(["BlueHydra::Device.update_or_create_from_result"])
      db_calls.clear                                           # not the scanner's doing
    end
  end
end
