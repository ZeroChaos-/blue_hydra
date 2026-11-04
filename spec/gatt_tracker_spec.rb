require 'spec_helper'
require 'blue_hydra/gatt_tracker'
require 'blue_hydra/gatt_walker'

describe BlueHydra::GattTracker do
  let(:mac)    { "7A:BB:CC:DD:EE:FF" }
  let(:other)  { "4C:11:22:33:44:55" }
  let(:rate)   { 300 }                 # info_scan_rate, seconds
  let(:t0)     { 1_000.0 }             # monotonic seconds at the first record
  let(:hash_a) { "00112233445566778899aabbccddeeff" }
  let(:hash_b) { "ffeeddccbbaa99887766554433221100" }
  let(:walk_state) { BlueHydra::GattWalker::WalkState }

  # Stand-ins for Device and DataMapper that raise on any message and record it,
  # in case a raise were swallowed on the way out. The 17.10 group runs every
  # public method against them; Property 19 runs its generated sequences
  # against them.
  let(:db_calls) { [] }
  let(:tripwire_class) do
    Class.new(BasicObject) do
      def initialize(name, calls)
        @name  = name
        @calls = calls
      end

      def method_missing(message, *_args, &_block)
        @calls << "#{@name}.#{message}"
        ::Kernel.raise ::RuntimeError, "GattTracker touched the database: #{@name}.#{message}"
      end
    end
  end

  # Every example runs on an injected clock it moves by hand, and reset! on both
  # sides keeps both the maps and that clock out of the other spec files.
  before do
    described_class.reset!
    @now = t0
    described_class.clock = -> { @now }
  end

  after { described_class.reset! }

  def at(seconds)
    @now = seconds
  end

  # The calls the Gatt_Scanner makes, with now = nil so the tracker reads the
  # injected clock itself.
  def plan(address = mac)
    described_class.plan_for(address, nil, rate)
  end

  def record(address, hash)
    described_class.record_finished(address, hash, nil, rate)
  end

  def state_with_hash(hash)
    walk_state.fresh.tap { |state| state.database_hash = hash }
  end

  describe ".plan_for decision table (Requirements 4.1 to 4.4, 4.7)" do
    # Age of the Finished_Walk at the handoff, in terms of info_scan_rate.
    def age_for(name)
      { fresh: 0, just_under: rate - 0.001, exactly: rate, over: rate + 1, long_over: 10 * rate }.fetch(name)
    end

    # expected, Resume_State?, finish age (nil: no Finished_Walk), hash recorded?, criterion
    [
      [:full,       false, nil,         false, "4.2: no Finished_Walk"],
      [:hash_check, false, :fresh,      true,  "4.4: just finished, hash recorded"],
      [:hash_check, false, :just_under, true,  "4.4: just under info_scan_rate, hash recorded"],
      [:full,       false, :exactly,    true,  "4.3: exactly info_scan_rate old ('at least'), hash recorded"],
      [:full,       false, :over,       true,  "4.3: older than info_scan_rate, hash recorded"],
      [:skip,       false, :fresh,      false, "4.7: just finished, no hash"],
      [:skip,       false, :just_under, false, "4.7: just under info_scan_rate, no hash"],
      [:full,       false, :exactly,    false, "4.3: exactly info_scan_rate old ('at least'), no hash"],
      [:full,       false, :over,       false, "4.3: older than info_scan_rate, no hash"],
      [:resume,     true,  nil,         false, "4.1: Resume_State with no Finished_Walk"],
      [:resume,     true,  :fresh,      true,  "4.1: Resume_State beats a young hash check"],
      [:resume,     true,  :fresh,      false, "4.1: Resume_State beats the 4.7 skip"],
      [:resume,     true,  :exactly,    true,  "4.1: Resume_State beats a due full Walk"],
      [:resume,     true,  :long_over,  false, "4.1: Resume_State whatever the finish age"]
    ].each do |expected, resume, age, hashed, label|
      it "plans #{expected} for #{label}" do
        stored = state_with_hash(hash_b)
        described_class.store_resume_state(mac, stored) if resume
        unless age.nil?
          at(t0)
          record(mac, hashed ? hash_a : nil)
          at(t0 + age_for(age))
        end

        case expected
        when :resume     then expect(plan).to eq([:resume, stored])
        when :hash_check then expect(plan).to eq([:hash_check, hash_a])
        else                  expect(plan).to eq([expected])
        end
      end
    end

    it "keeps addresses apart" do
      record(mac, hash_a)
      described_class.store_resume_state(other, walk_state.fresh)

      expect(plan(mac)).to eq([:hash_check, hash_a])
      expect(plan(other).first).to eq(:resume)
      expect(plan("C0:FF:EE:00:00:01")).to eq([:full])
    end

    # 4.3 says "at least", 4.10 says "more than": at exactly info_scan_rate the
    # record is already due a full Walk but a prune at that moment keeps it.
    it "plans :full at exactly info_scan_rate while a prune at that instant keeps the record" do
      record(mac, hash_a)
      at(t0 + rate)
      record(other, nil)                        # prunes with mac exactly rate old

      expect(described_class.finished(mac)).to eq(finished_at: t0, database_hash: hash_a)
      expect(plan(mac)).to eq([:full])
    end

    it "applies the same boundary to an explicit now" do
      described_class.record_finished(mac, hash_a, 50.0, rate)

      expect(described_class.plan_for(mac, 50.0 + rate - 0.001, rate)).to eq([:hash_check, hash_a])
      expect(described_class.plan_for(mac, 50.0 + rate, rate)).to eq([:full])
    end

    it "is read-only: planning creates no entry (4.9)" do
      expect(plan).to eq([:full])
      expect(described_class.finished(mac)).to be_nil
      expect(described_class.resume_state(mac)).to be_nil
      expect(described_class.tracked_count).to eq(0)
    end
  end

  describe "ages on the monotonic clock (Requirement 4.13)" do
    it "measures age as the injected clock's now minus the recorded finish time" do
      at(5_000.0)
      record(mac, hash_a)
      expect(described_class.finished(mac)[:finished_at]).to eq(5_000.0)

      at(5_000.0 + rate - 1)
      expect(plan).to eq([:hash_check, hash_a])
      at(5_000.0 + rate)
      expect(plan).to eq([:full])
    end

    it "uses an explicit now instead of reading the clock" do
      described_class.clock = -> { raise "the clock must not be read when now is given" }

      described_class.record_finished(mac, hash_a, 10.0, rate)
      expect(described_class.plan_for(mac, 11.0, rate)).to eq([:hash_check, hash_a])
      expect(described_class.finished(mac)[:finished_at]).to eq(10.0)
    end

    it "defaults to CLOCK_MONOTONIC and ignores a wall-clock step" do
      described_class.reset!
      expect(described_class.clock).to be(described_class::MONOTONIC)

      mono = 7_000.0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { mono }
      record(mac, hash_a)
      expect(described_class.finished(mac)[:finished_at]).to eq(7_000.0)

      # the wall clock jumps a day forward and then back to the epoch; the plan
      # follows only the monotonic reading
      a_day_ahead = Time.now + 86_400
      allow(Time).to receive(:now).and_return(a_day_ahead)
      mono = 7_000.0 + rate - 1
      expect(plan).to eq([:hash_check, hash_a])

      allow(Time).to receive(:now).and_return(Time.at(0))
      mono = 7_000.0 + rate
      expect(plan).to eq([:full])
    end

    it "reads the real CLOCK_MONOTONIC by default" do
      described_class.reset!
      before_read = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reading     = described_class.clock.call
      after_read  = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(reading).to be_between(before_read, after_read)
    end

    it "falls back to the monotonic clock when the injected clock is cleared" do
      described_class.clock = nil
      expect(described_class.clock).to be(described_class::MONOTONIC)
    end
  end

  describe ".record_finished (Requirement 4.8)" do
    it "records the finish time and the hash" do
      record(mac, hash_a)
      expect(described_class.finished(mac)).to eq(finished_at: t0, database_hash: hash_a)
    end

    it "replaces an earlier hash and finish time" do
      record(mac, hash_a)
      at(t0 + 10)
      record(mac, hash_b)

      expect(described_class.finished(mac)).to eq(finished_at: t0 + 10, database_hash: hash_b)
      expect(plan).to eq([:hash_check, hash_b])
    end

    it "clears the hash when the Walk read none, so the next young handoff skips" do
      record(mac, hash_a)
      at(t0 + 10)
      record(mac, nil)

      expect(described_class.finished(mac)).to eq(finished_at: t0 + 10, database_hash: nil)
      expect(plan).to eq([:skip])
    end

    it "keeps a frozen copy of the hash, so the caller's buffer cannot change it" do
      buffer = +hash_a
      record(mac, buffer)
      buffer.replace(hash_b)

      expect(plan).to eq([:hash_check, hash_a])
      expect(described_class.finished(mac)[:database_hash]).to be_frozen
    end

    it "leaves Resume_State alone" do
      stored = state_with_hash(hash_b)
      described_class.store_resume_state(mac, stored)
      record(mac, hash_a)

      expect(described_class.resume_state(mac)).to eq(stored)
    end

    it "ignores a nil address" do
      described_class.record_finished(nil, hash_a, nil, rate)
      expect(described_class.tracked_count).to eq(0)
    end
  end

  describe "pruning (Requirement 4.10)" do
    # Feature: gatt-service-scanning, Property 18: Pruning keeps only Finished_Walks younger than info_scan_rate
    #
    # 4.10 prunes ages of "more than" info_scan_rate, so "younger" here means
    # "not more than": a record exactly info_scan_rate old survives the prune
    # (and is already planned :full by 4.3, which the unit specs above cover).
    #
    # The model is the history, not a second prune: since times never go
    # backwards, an age that exceeded the rate at one prune exceeds it at every
    # later one, so the records held after any call are exactly the addresses
    # whose latest record_finished is at most info_scan_rate before the last
    # record_finished's now, each with that call's hash. Resume_State follows
    # store_resume_state and forget alone. Every expectation is derived from the
    # generated input, so the input rantly prints for a failing case reproduces it.
    #
    # Rates are Integers, Floats exact in binary (multiples of 0.25) and
    # arbitrary Floats. Start times are exact or arbitrary Floats, and each gap
    # is zero (equal timestamps), a fraction of the rate, exactly the time that
    # makes an earlier record info_scan_rate old, one ulp either side of that,
    # or far beyond the rate. With exact values the boundary ages are exactly
    # info_scan_rate, which is where a >= in place of > would show.
    it "Property 18: after each record_finished holds exactly the finishes at most info_scan_rate old" do
      pool = %w[7A:BB:CC:DD:EE:01 7A:BB:CC:DD:EE:02 4C:11:22:33:44:55 C0:FF:EE:00:00:01
                D2:00:00:00:00:02 5E:AA:BB:CC:DD:EE 02:00:15:00:00:41 F8:12:34:56:78:9A]
      seen = Hash.new(0)

      # Procs, because rantly instance_evals generators on itself.
      hex32 = proc { format("%032x", range(0, 0xFFFF_FFFF)) }

      property_of {
        info_scan_rate = branch(
          proc { range(1, 3600) },
          proc { range(4, 14_400) / 4.0 },
          proc { 1 + float * 3599 },
          proc { choose(1, 3600, 1.0, 3600.0) }
        )
        addresses = pool.first(range(1, pool.size))
        now = branch(proc { range(0, 10**7).to_f }, proc { range(0, 4 * 10**7) / 4.0 }, proc { float * 10**6 })
        times = []
        ops = []

        range(1, 60).times do
          freq([6, :literal, 0], [2, :literal, 1], [1, :literal, 2]).times do
            address = choose(*addresses)
            # a forget carries its time like a record_finished does; stores
            # here pass no planned_at, so the 17.11 guard never refuses them
            ops << (boolean ? [:store_resume_state, address, call(hex32)] : [:forget, address, nil, now])
          end

          unless times.empty?
            # the time at which some earlier record is exactly info_scan_rate
            # old; the latest record always qualifies, so this never goes back
            edge = choose(*times.select { |t| t + info_scan_rate >= now }) + info_scan_rate
            now =
              case freq([3, :literal, :same], [6, :literal, :within], [3, :literal, :edge],
                        [2, :literal, :past_edge], [1, :literal, :before_edge], [2, :literal, :far])
              when :same        then now
              when :within      then now + info_scan_rate * range(1, 8) / 8.0
              when :edge        then edge
              when :past_edge   then edge.next_float
              when :before_edge then [edge.prev_float, now].max
              else                   now + info_scan_rate * range(2, 1000) + range(0, 3600)
              end
          end
          times << now
          ops << [:record_finished, choose(*addresses), freq([1, :literal, nil], [3, hex32]), now]
        end

        { info_scan_rate: info_scan_rate, ops: ops }
      }.check(100) { |input|
        info_scan_rate = input[:info_scan_rate]
        seen[info_scan_rate.is_a?(Integer) ? :integer_rate : :float_rate] += 1

        described_class.reset!
        # every call passes now, so the tracker must never need its clock
        described_class.clock = -> { raise "Property 18 passes now explicitly; the clock must not be read" }

        latest   = {}   # address => [now, hash] of its latest record_finished, never pruned
        resume   = {}   # address => the hex the stored Resume_State was built with
        last_now = nil
        held     = {}   # what the model says is held after the previous call

        begin
          input[:ops].each_with_index do |(op, address, arg, now), step|
            case op
            when :record_finished
              seen[:equal_timestamps] += 1 if now == last_now
              seen[:nil_hash] += 1 if arg.nil?
              seen[:repeat_held] += 1 if held.key?(address)
              seen[:repeat_pruned] += 1 if latest.key?(address) && !held.key?(address)

              described_class.record_finished(address, arg, now, info_scan_rate)
              latest[address] = [now, arg]
              last_now = now
            when :store_resume_state
              described_class.store_resume_state(address, state_with_hash(arg))
              resume[address] = arg
              seen[:store_resume_state] += 1
            when :forget
              described_class.forget(address, now)
              resume.delete(address)
              seen[:forget] += 1
            end

            expected = latest.select { |_, (at, _)| last_now - at <= info_scan_rate }
            if op == :record_finished
              ages = latest.to_h { |a, (at, _)| [a, last_now - at] }
              seen[:boundary_kept] += 1 if expected.any? { |a, _| ages[a] == info_scan_rate }
              dropped = held.keys - expected.keys
              seen[:pruned] += 1 unless dropped.empty?
              seen[:just_past_boundary_pruned] += 1 if dropped.any? { |a| ages[a] - info_scan_rate < 1e-6 }
            end
            seen[:resume_outlives_finish] += 1 if resume.keys.any? { |a| latest.key?(a) && !expected.key?(a) }
            held = expected

            where = "after step #{step} #{[op, address, arg, now].inspect} (info_scan_rate #{info_scan_rate.inspect})"

            want = expected.to_h { |a, (at, hash)| [a, { finished_at: at, database_hash: hash }] }
            got  = pool.to_h { |a| [a, described_class.finished(a)] }.compact
            expect(got).to eq(want), -> { "#{where}: finish records #{got.inspect}, expected #{want.inspect}" }

            want_resume = resume.transform_values { |hex| state_with_hash(hex) }
            got_resume  = pool.to_h { |a| [a, described_class.resume_state(a)] }.compact
            expect(got_resume).to eq(want_resume),
                                  -> { "#{where}: Resume_State held for #{got_resume.keys.inspect}, expected #{want_resume.keys.inspect}" }

            count = (expected.keys | resume.keys).size
            tracked = described_class.tracked_count
            expect(tracked).to eq(count), -> { "#{where}: tracked_count #{tracked}, expected #{count}" }
          end
        ensure
          described_class.reset!
        end
      }

      # A generator that never reached one of these would let the property pass
      # without testing it.
      expect(%i[integer_rate float_rate equal_timestamps nil_hash repeat_held repeat_pruned
                store_resume_state forget boundary_kept pruned just_past_boundary_pruned
                resume_outlives_finish] - seen.keys).to eq([])
    end
  end

  # Outcomes that are not Finished_Walks never call record_finished (the
  # Gatt_Scanner's side of 4.9); the tracker's side is that nothing else it
  # offers moves a finish record or creates one.
  describe "leaving the finish record unchanged (Requirement 4.9)" do
    it "is not moved by Resume_State writes" do
      record(mac, hash_a)
      at(t0 + 30)
      described_class.store_resume_state(mac, walk_state.fresh)
      described_class.clear_resume_state(mac)
      described_class.store_resume_state(mac, nil)

      expect(described_class.finished(mac)).to eq(finished_at: t0, database_hash: hash_a)
    end

    it "is not created by a Resume_State write" do
      described_class.store_resume_state(mac, walk_state.fresh)
      expect(described_class.finished(mac)).to be_nil
    end

    it "hands out a copy of the finish record" do
      record(mac, hash_a)
      described_class.finished(mac)[:database_hash] = hash_b

      expect(described_class.finished(mac)[:database_hash]).to eq(hash_a)
    end
  end

  describe "Resume_State (Requirements 17.2, 17.8)" do
    it "holds at most one per address, the latest replacing the earlier" do
      expect(described_class.store_resume_state(mac, state_with_hash(hash_a))).to be(true)
      expect(described_class.store_resume_state(mac, state_with_hash(hash_b))).to be(true)

      expect(described_class.resume_state(mac).database_hash).to eq(hash_b)
      expect(plan).to eq([:resume, state_with_hash(hash_b)])
      expect(described_class.tracked_count).to eq(1)
    end

    it "keeps each address's Resume_State separate" do
      described_class.store_resume_state(mac, state_with_hash(hash_a))
      described_class.store_resume_state(other, state_with_hash(hash_b))
      described_class.clear_resume_state(other)

      expect(described_class.resume_state(mac).database_hash).to eq(hash_a)
      expect(described_class.resume_state(other)).to be_nil
    end

    it "treats store_resume_state(nil) as a clear, not a stored nil, and returns false (nothing stored)" do
      described_class.store_resume_state(mac, walk_state.fresh)
      expect(described_class.store_resume_state(mac, nil)).to be(false)

      expect(described_class.resume_state(mac)).to be_nil
      expect(plan).to eq([:full])
      expect(described_class.tracked_count).to eq(0)
    end

    it "clear_resume_state drops the Resume_State and keeps the finish record" do
      record(mac, hash_a)
      described_class.store_resume_state(mac, walk_state.fresh)
      described_class.clear_resume_state(mac)

      expect(described_class.resume_state(mac)).to be_nil
      expect(plan).to eq([:hash_check, hash_a])
    end

    it "ignores a nil address" do
      expect(described_class.store_resume_state(nil, walk_state.fresh)).to be(false)
      described_class.clear_resume_state(nil)
      expect(described_class.tracked_count).to eq(0)
    end

    describe "copies (the RESUME_STATE CONTRACT)" do
      let(:pristine) { walk_state.fresh }

      it "stores a copy that shares nothing with the caller's state" do
        caller_state = walk_state.fresh
        described_class.store_resume_state(mac, caller_state)

        # what a Walk thread might still do to the state it handed over
        caller_state.procedures.first.next = 0x0042
        caller_state.procedures.pop
        caller_state.services << { uuid: nil, type: :primary, start: 1, end: 5, includes: [] }
        caller_state.database_hash = hash_a
        caller_state.reads_generated = true

        expect(described_class.resume_state(mac)).to eq(pristine)
      end

      it "hands out a fresh copy on every read, so a Walk cannot write into the stored state" do
        described_class.store_resume_state(mac, walk_state.fresh)

        first  = described_class.resume_state(mac)
        second = described_class.resume_state(mac)
        expect(first).to eq(second)
        expect(first).not_to be(second)
        expect(first.procedures).not_to be(second.procedures)
        expect(first.procedures.first).not_to be(second.procedures.first)

        first.procedures.first.next = 0x1234
        first.procedures.shift
        expect(described_class.resume_state(mac)).to eq(pristine)
      end

      # A Walk that ends `error` changes nothing in the tracker (4.9), so
      # whatever it did to its working state must not show up on the next resume.
      it "is unaffected by a Walk mutating the state plan_for gave it" do
        described_class.store_resume_state(mac, walk_state.fresh)

        kind, planned = plan
        expect(kind).to eq(:resume)
        planned.procedures.first.next = 0x0100
        planned.procedures.clear
        planned.reads_generated = true
        planned.partial = true

        expect(plan).to eq([:resume, pristine])
      end

      it "does not alias the stored copy with the caller's object or the returned one" do
        caller_state = walk_state.fresh
        described_class.store_resume_state(mac, caller_state)
        returned = described_class.resume_state(mac)
        _, planned = plan

        [returned, planned].each do |copy|
          expect(copy).not_to be(caller_state)
          expect(copy.procedures).not_to be(caller_state.procedures)
          expect(copy.procedures.last).not_to be(caller_state.procedures.last)
        end
        expect(planned).not_to be(returned)
      end

      it "stores and returns an object without deep_dup as given" do
        opaque = Object.new
        described_class.store_resume_state(mac, opaque)

        expect(described_class.resume_state(mac)).to be(opaque)
        expect(plan.last).to be(opaque)
      end
    end
  end

  describe ".forget (Requirement 17.8)" do
    it "drops the Resume_State but keeps the finish record" do
      record(mac, hash_a)
      described_class.store_resume_state(mac, walk_state.fresh)
      described_class.forget(mac)

      expect(described_class.resume_state(mac)).to be_nil
      expect(described_class.finished(mac)).to eq(finished_at: t0, database_hash: hash_a)
      # back within info_scan_rate: a hash check, not a full re-walk
      expect(plan).to eq([:hash_check, hash_a])
      expect(described_class.tracked_count).to eq(1)
    end

    it "leaves nothing behind for an address with only a Resume_State" do
      described_class.store_resume_state(mac, walk_state.fresh)
      described_class.forget(mac)

      expect(described_class.tracked_count).to eq(0)
      expect(plan).to eq([:full])
    end

    it "is harmless for an unknown or nil address" do
      expect { described_class.forget(mac) }.not_to raise_error
      expect { described_class.forget(nil) }.not_to raise_error
      expect(described_class.tracked_count).to eq(0)
    end
  end

  # Device.mark_offline can forget an address while its Walk is in flight. The
  # Walk's store names the time it was planned (the now the handoff gave
  # plan_for); a forget at or after that time refuses it, so a device marked
  # offline mid-Walk leaves no Resume_State behind.
  describe "forget-before-store guard (Requirement 17.11)" do
    let(:planned_at) { t0 }
    let(:state)      { state_with_hash(hash_a) }
    let(:refusal)    { "gatt: #{mac} Resume_State not stored: device forgotten after the Walk was planned" }

    before { allow(BlueHydra.logger).to receive(:debug) }

    def store(address = mac, planned_at: self.planned_at)
      described_class.store_resume_state(address, state, planned_at: planned_at)
    end

    it "refuses the store when the forget is after planned_at: false, nothing held, a debug line" do
      described_class.forget(mac, planned_at + 5)

      expect(store).to be(false)
      expect(described_class.resume_state(mac)).to be_nil
      expect(plan).to eq([:full])
      expect(described_class.tracked_count).to eq(0)
      expect(BlueHydra.logger).to have_received(:debug).with(refusal).once
    end

    it "refuses when the forget is at exactly planned_at" do
      described_class.forget(mac, planned_at)

      expect(store).to be(false)
      expect(described_class.resume_state(mac)).to be_nil
      expect(BlueHydra.logger).to have_received(:debug).with(refusal)
    end

    it "accepts when the forget is before planned_at, logging nothing" do
      described_class.forget(mac, planned_at - 0.001)

      expect(store).to be(true)
      expect(described_class.resume_state(mac)).to eq(state)
      expect(plan).to eq([:resume, state])
      expect(BlueHydra.logger).not_to have_received(:debug)
    end

    it "stores unconditionally with planned_at nil, forget or not (the existing callers)" do
      described_class.forget(mac, planned_at + 5)

      expect(described_class.store_resume_state(mac, state)).to be(true)
      expect(described_class.resume_state(mac)).to eq(state)
      expect(BlueHydra.logger).not_to have_received(:debug)
    end

    it "a refused store also drops a Resume_State held for the address" do
      described_class.forget(mac, planned_at + 5)
      described_class.store_resume_state(mac, state_with_hash(hash_b))      # unconditional
      expect(described_class.resume_state(mac)).not_to be_nil

      expect(store).to be(false)
      expect(described_class.resume_state(mac)).to be_nil
    end

    it "guards per address" do
      described_class.forget(other, planned_at + 5)

      expect(store(mac)).to be(true)
      expect(store(other)).to be(false)
      expect(described_class.resume_state(mac)).to eq(state)
      expect(described_class.resume_state(other)).to be_nil
    end

    it "the latest forget is the one compared" do
      described_class.forget(mac, planned_at - 10)
      expect(store).to be(true)

      described_class.forget(mac, planned_at + 1)
      expect(described_class.resume_state(mac)).to be_nil           # 17.8 still clears
      expect(store).to be(false)
    end

    it "forget reads the injected clock when now is nil" do
      at(planned_at + 5)
      described_class.forget(mac)

      expect(store(planned_at: planned_at)).to be(false)
      expect(store(planned_at: planned_at + 5)).to be(false)       # equality
      expect(store(planned_at: planned_at + 5.001)).to be(true)
    end

    it "forget with an explicit now does not read the clock" do
      described_class.clock = -> { raise "the clock must not be read when now is given" }
      described_class.forget(mac, 7.0)

      expect(store(planned_at: 7.0)).to be(false)
      expect(store(planned_at: 7.5)).to be(true)
    end

    it "leaves the finish record alone, refused or not (4.9)" do
      record(mac, hash_a)
      described_class.forget(mac, planned_at + 5)
      store

      expect(described_class.finished(mac)).to eq(finished_at: t0, database_hash: hash_a)
      expect(plan).to eq([:hash_check, hash_a])
    end

    describe "pruning with the finish records (4.10)" do
      it "a forget older than info_scan_rate no longer refuses" do
        described_class.forget(mac, planned_at)
        described_class.record_finished(other, nil, planned_at + rate + 0.001, rate)   # prunes

        expect(store).to be(true)
        expect(described_class.resume_state(mac)).to eq(state)
        expect(BlueHydra.logger).not_to have_received(:debug)
      end

      it "a forget exactly info_scan_rate old survives the prune (4.10 'more than') and still refuses" do
        described_class.forget(mac, planned_at)
        described_class.record_finished(other, nil, planned_at + rate, rate)

        expect(store).to be(false)
      end

      it "prunes on the now record_finished is given, keeping younger forgets" do
        described_class.forget(mac, planned_at)
        described_class.forget(other, planned_at + 100)
        described_class.record_finished("C0:FF:EE:00:00:01", hash_a, planned_at + rate + 1, rate)

        expect(store(mac)).to be(true)
        expect(store(other, planned_at: planned_at + 100)).to be(false)
      end

      it "is not pruned by anything but record_finished" do
        described_class.forget(mac, planned_at)
        at(planned_at + 10 * rate)
        plan
        described_class.clear_resume_state(mac)
        described_class.finished(mac)
        described_class.resume_state(mac)
        described_class.tracked_count

        expect(store).to be(false)
      end
    end

    it "reset! clears the forget times" do
      described_class.forget(mac, planned_at + 5)
      described_class.reset!

      expect(store).to be(true)
    end

    # Feature: gatt-service-scanning, Property 19: A forget between plan and store leaves no Resume_State
    #
    # Validates: Requirements 17.1, 17.8, 17.11
    #
    # The tracker is driven directly, the way the Gatt_Scanner (plan_for at the
    # handoff, store_resume_state with that handoff's time as planned_at), the
    # Result_Thread (forget from Device.mark_offline) and a Walk's end
    # (clear_resume_state, record_finished) drive it, every call carrying an
    # explicit time. Each case is a sequence of events over one to three
    # addresses:
    #
    #   [:plan, a, t]           the handoff: plan_for at t, and t is the
    #                           planned_at the address's next guarded store passes
    #   [:forget, a, t]         Device.mark_offline on the Result_Thread (17.8)
    #   [:store, a, mode]       a Walk ending timeout or disconnected with work
    #                           outstanding (17.1): :planned passes the latest plan
    #                           time (nil before any plan), :unconditional passes
    #                           nil, the existing callers' path
    #   [:clear, a]             a Walk ending complete or protected (17.7)
    #   [:finish, a, t, hash]   record_finished, whose prune drops forget times
    #                           more than info_scan_rate old (4.10)
    #
    # plus a :race motif, the 17.11 scenario end to end: forget, plan on the same
    # or a slightly later reading, a finish exactly info_scan_rate or one ulp
    # past it after the forget, then the guarded store. Times are monotonic
    # (non-decreasing with repeated readings, so a forget and a plan on one
    # reading occur) or arbitrary (each drawn on its own, so a forget delivered
    # after a plan can carry an earlier time, as a Result_Thread clock reading
    # that reached the tracker late would). Every time is an exact binary
    # fraction, so the equality cases are exact.
    #
    # The model keeps, per address, the latest forget time still held (dropped
    # when a finish at now has now - forget > info_scan_rate), the latest plan
    # time and whether Resume_State is held. A guarded store is accepted iff no
    # held forget is at or after its planned_at; an unconditional store is
    # always accepted; forget, clear and a refused store drop the held state.
    # After every event the tracker's Resume_State for every address, plan_for's
    # :resume, the store's return value and the debug log must match the model,
    # and no event may raise or touch Device or DataMapper.
    it "Property 19: Resume_State is held after a store iff no forget at or after planned_at, and a refused store returns false" do
      pool = %w[7A:BB:CC:DD:EE:01 7A:BB:CC:DD:EE:02 4C:11:22:33:44:55]
      seen = Hash.new(0)
      refusal_for = ->(address) { "gatt: #{address} Resume_State not stored: device forgotten after the Walk was planned" }

      # Procs, because rantly instance_evals generators on itself.
      hex32 = proc { format("%032x", range(0, 0xFFFF_FFFF)) }

      debug_lines = []
      allow(BlueHydra.logger).to receive(:debug) { |line| debug_lines << line }
      stub_const("BlueHydra::Device", tripwire_class.new("BlueHydra::Device", db_calls))
      stub_const("DataMapper", tripwire_class.new("DataMapper", db_calls)) if defined?(::DataMapper)

      property_of {
        info_scan_rate = branch(proc { range(1, 600) }, proc { range(4, 2400) / 4.0 })
        addresses = pool.first(range(1, pool.size))
        mode = freq([3, :literal, :monotonic], [1, :literal, :arbitrary])
        now = branch(proc { range(0, 10**6).to_f }, proc { range(0, 4 * 10**6) / 4.0 })
        forgets = []
        events = []

        # the next time for a timed event; monotonic times never go back, and
        # for a finish may land exactly where a forget becomes info_scan_rate
        # old or one ulp past it
        next_time = proc do |kind|
          if mode == :arbitrary
            branch(proc { range(0, (8 * info_scan_rate).to_i) / 4.0 }, proc { float * 2 * info_scan_rate })
          else
            edges = forgets.map { |f| f + info_scan_rate }.select { |edge| edge >= now }
            steps = [[3, :literal, :same], [4, :literal, :tick], [2, :literal, :within]]
            if kind == :finish
              steps << [1, :literal, :far]
              steps += [[2, :literal, :edge], [2, :literal, :past_edge]] unless edges.empty?
            end
            now =
              case freq(*steps)
              when :same      then now
              when :tick      then now + range(1, 256) / 256.0
              when :within    then now + info_scan_rate * range(1, 8) / 8.0
              when :edge      then choose(*edges)
              when :past_edge then choose(*edges).next_float
              else                 now + info_scan_rate * range(2, 10) + range(0, 60)
              end
          end
        end

        range(2, 40).times do
          kind = freq([3, :literal, :plan], [3, :literal, :forget], [4, :literal, :store],
                      [1, :literal, :clear], [2, :literal, :finish], [1, :literal, :race])
          address = choose(*addresses)
          case kind
          when :store
            events << [:store, address, freq([4, :literal, :planned], [1, :literal, :unconditional])]
          when :clear
            events << [:clear, address]
          when :race
            # forget; plan on the same reading or up to 1 s later; sometimes an
            # unconditional store in between (a Resume_State for the refusal to
            # drop); a finish exactly info_scan_rate or one ulp past it after
            # the forget (kept, or pruned); then the guarded store
            forget_at = mode == :arbitrary ? next_time.call(:forget) : now
            plan_at   = boolean ? forget_at : forget_at + range(1, 256) / 256.0
            finish_at = choose(forget_at + info_scan_rate, (forget_at + info_scan_rate).next_float)
            now = finish_at if mode == :monotonic
            forgets << forget_at
            events << [:forget, address, forget_at] << [:plan, address, plan_at]
            events << [:store, address, :unconditional] if boolean
            events << [:finish, choose(*addresses), finish_at, call(hex32)] << [:store, address, :planned]
          else
            t = next_time.call(kind)
            forgets << t if kind == :forget
            events << (kind == :finish ? [:finish, address, t, freq([1, :literal, nil], [2, hex32])] : [kind, address, t])
          end
        end

        { info_scan_rate: info_scan_rate, mode: mode, events: events }
      }.check(200) { |input|
        info_scan_rate = input[:info_scan_rate]
        seen[input[:mode]] += 1
        seen[:multiple_addresses] += 1 if input[:events].map { |event| event[1] }.uniq.size > 1

        described_class.reset!
        # every call passes its time, so the tracker must never need its clock
        described_class.clock = -> { raise "Property 19 passes every time explicitly; the clock must not be read" }
        debug_lines.clear
        state = state_with_hash(hash_a)

        forgotten   = {}   # address => time of its latest forget the prune has not dropped
        pruned      = {}   # address => time of its latest forget the prune did drop
        planned     = {}   # address => time of its latest plan
        plan_step   = {}   # address => index of that plan event
        forget_step = {}   # address => index of its latest forget event
        held        = {}   # address => true while the model says Resume_State is held
        refusals    = 0

        begin
          input[:events].each_with_index do |event, step|
            op, address, arg, hash = event
            where = "after step #{step} #{event.inspect} (#{input[:mode]} times, info_scan_rate #{info_scan_rate.inspect})"

            # the model's verdict on a store, before the tracker moves
            planned_at = nil
            accept     = nil
            if op == :store
              planned_at = planned[address] if arg == :planned
              forgot = forgotten[address]
              accept = planned_at.nil? || forgot.nil? || forgot < planned_at

              if planned_at.nil?
                seen[forgot ? :nil_planned_at_after_forget : :nil_planned_at] += 1
              elsif forgot.nil?
                seen[:no_forget_accepted] += 1
                seen[:pruned_forget_then_accepted] += 1 if pruned[address] && pruned[address] >= planned_at
              elsif forgot > planned_at
                seen[:forget_after_plan_refused] += 1
              elsif forgot == planned_at
                seen[:forget_equal_refused] += 1
              else
                seen[:forget_before_accepted] += 1
                seen[:later_forget_earlier_time_accepted] += 1 if forget_step[address] > plan_step[address]
              end
              seen[:refused_store_dropped_existing] += 1 if !accept && held[address]
            end

            returned =
              begin
                case op
                when :plan   then described_class.plan_for(address, arg, info_scan_rate).first
                when :forget then described_class.forget(address, arg)
                when :store  then described_class.store_resume_state(address, state, planned_at: planned_at)
                when :clear  then described_class.clear_resume_state(address)
                when :finish then described_class.record_finished(address, hash, arg, info_scan_rate)
                end
              rescue StandardError => e
                RSpec::Expectations.fail_with("#{where}: #{op} raised #{e.class}: #{e.message}")
              end

            case op
            when :plan
              planned[address]   = arg
              plan_step[address] = step
              resumes = returned == :resume
              expect(resumes).to be(held.key?(address)),
                                 -> { "#{where}: plan_for #{returned.inspect} with Resume_State #{held.key?(address) ? 'held' : 'not held'}" }
            when :forget
              forgotten[address]   = arg
              forget_step[address] = step
              held.delete(address)
            when :store
              expect(returned).to be(accept), -> { "#{where}: store_resume_state returned #{returned.inspect}, expected #{accept}" }
              if accept
                held[address] = true
              else
                held.delete(address)
                refusals += 1
              end
            when :clear
              held.delete(address)
              seen[:clear] += 1
            when :finish
              seen[:forget_exactly_rate_old_kept] += 1 if forgotten.any? { |_, f| arg - f == info_scan_rate }
              forgotten.each { |a, f| pruned[a] = f if arg - f > info_scan_rate }
              forgotten.delete_if { |_, f| arg - f > info_scan_rate }
            end

            got  = pool.select { |a| !described_class.resume_state(a).nil? }
            want = held.keys.sort
            expect(got.sort).to eq(want), -> { "#{where}: Resume_State held for #{got.inspect}, expected #{want.inspect}" }

            expect(debug_lines.size).to eq(refusals),
                                        -> { "#{where}: #{debug_lines.size} debug lines for #{refusals} refused stores: #{debug_lines.inspect}" }
            if op == :store && !accept
              expect(debug_lines.last).to eq(refusal_for.(address)), -> { "#{where}: refusal logged as #{debug_lines.last.inspect}" }
            end
          end
        ensure
          described_class.reset!
        end
      }

      expect(db_calls).to eq([])
      # A generator that never reached one of these would let the property pass
      # without testing it. The rarest, a forget delivered after the plan but
      # carrying an earlier time, lands in about 17 of 200 cases (arbitrary
      # times only), so a run misses it about once in 10^7; the 200 cases take
      # about 0.2 s.
      expect(%i[monotonic arbitrary multiple_addresses
                forget_after_plan_refused forget_equal_refused forget_before_accepted no_forget_accepted
                later_forget_earlier_time_accepted nil_planned_at nil_planned_at_after_forget
                pruned_forget_then_accepted forget_exactly_rate_old_kept refused_store_dropped_existing
                clear] - seen.keys).to eq([])
    end
  end

  describe ".tracked_count" do
    it "counts distinct addresses holding either kind of state" do
      expect(described_class.tracked_count).to eq(0)
      record(mac, hash_a)
      described_class.store_resume_state(mac, walk_state.fresh)
      expect(described_class.tracked_count).to eq(1)

      described_class.store_resume_state(other, walk_state.fresh)
      expect(described_class.tracked_count).to eq(2)
    end
  end

  # Nothing is persisted: reset! stands in for a restart, after which every
  # address gets a full Walk.
  describe ".reset! (Requirement 4.12)" do
    it "returns every address to :full" do
      addresses = [mac, other, "C0:FF:EE:00:00:01"]
      record(mac, hash_a)
      record(other, nil)
      described_class.store_resume_state(other, walk_state.fresh)
      described_class.store_resume_state(addresses.last, walk_state.fresh)

      described_class.reset!

      addresses.each do |address|
        expect(described_class.plan_for(address, t0, rate)).to eq([:full])
        expect(described_class.finished(address)).to be_nil
        expect(described_class.resume_state(address)).to be_nil
      end
      expect(described_class.tracked_count).to eq(0)
    end

    it "restores the monotonic clock" do
      expect(described_class.clock).not_to be(described_class::MONOTONIC)
      described_class.reset!
      expect(described_class.clock).to be(described_class::MONOTONIC)
    end
  end

  # Walk threads record and store, the Discovery_Thread and connect_batch
  # threads plan, the Result_Thread forgets; all through the one mutex.
  it "survives concurrent recording, planning, storing and forgetting" do
    allow(BlueHydra.logger).to receive(:debug)   # guarded stores refuse once a forget has landed
    macs  = (1..20).map { |i| format("7A:BB:CC:DD:EE:%02X", i) }
    plans = Queue.new
    threads = []
    threads << Thread.new { 100.times { |i| macs.each { |m| described_class.record_finished(m, hash_a, t0 + i, rate) } } }
    threads << Thread.new { 100.times { |i| macs.each { |m| described_class.record_finished(m, nil, t0 + i, rate) } } }
    threads << Thread.new { 100.times { macs.each { |m| described_class.store_resume_state(m, walk_state.fresh) } } }
    threads << Thread.new { 100.times { macs.each { |m| described_class.store_resume_state(m, walk_state.fresh, planned_at: t0) } } }
    threads << Thread.new { 100.times { macs.each { |m| described_class.forget(m) } } }
    2.times do
      threads << Thread.new { 100.times { macs.each { |m| plans << described_class.plan_for(m, t0 + 50, rate) } } }
    end
    threads << Thread.new { 100.times { described_class.tracked_count; macs.each { |m| described_class.resume_state(m) } } }

    expect { threads.each(&:join) }.not_to raise_error

    kinds = []
    kinds << plans.pop until plans.empty?
    expect(kinds.size).to eq(2 * 100 * macs.size)
    expect(kinds.map(&:first).uniq - [:full, :hash_check, :skip, :resume]).to eq([])
    # every finish record is younger than info_scan_rate, so none was pruned
    expect(described_class.tracked_count).to eq(macs.size)
  end

  # The Gatt_Tracker decides eligibility and resumption with no database query
  # (17.10). Device and DataMapper are swapped for objects that raise on any
  # message and record it, in case a raise were swallowed on the way out.
  describe "database access (Requirement 17.10)" do
    # Every public method, so a new one added without being exercised here
    # fails the first example below.
    let(:public_methods) do
      %i[clock clock= plan_for record_finished finished resume_state store_resume_state
         clear_resume_state forget tracked_count reset!]
    end

    before do
      stub_const("BlueHydra::Device", tripwire_class.new("BlueHydra::Device", db_calls))
      stub_const("DataMapper", tripwire_class.new("DataMapper", db_calls)) if defined?(::DataMapper)
    end

    it "runs every public method, down every plan, without touching Device or DataMapper" do
      expect(described_class.singleton_methods(false)).to match_array(public_methods)
      allow(BlueHydra.logger).to receive(:debug)

      described_class.clock = -> { @now }
      described_class.clock.call
      expect(plan).to eq([:full])
      record(mac, hash_a)
      expect(plan).to eq([:hash_check, hash_a])
      record(other, nil)
      expect(plan(other)).to eq([:skip])
      described_class.store_resume_state(mac, walk_state.fresh)
      expect(plan.first).to eq(:resume)
      described_class.finished(mac)
      described_class.resume_state(mac)
      described_class.clear_resume_state(mac)
      described_class.store_resume_state(mac, walk_state.fresh)
      described_class.store_resume_state(mac, nil)
      described_class.forget(other)
      # the 17.11 guard, both ways: accepted, then refused after a forget
      expect(described_class.store_resume_state(mac, walk_state.fresh, planned_at: @now)).to be(true)
      described_class.forget(mac, @now)
      expect(described_class.store_resume_state(mac, walk_state.fresh, planned_at: @now)).to be(false)
      record(mac, hash_a)                                 # prunes @forgotten too
      described_class.tracked_count
      described_class.reset!
      described_class.plan_for(mac, nil, rate)            # on the real monotonic clock

      expect(db_calls).to eq([])
    end

    # positive control: the stubs do fire, so the empty list above means something
    it "would catch a Device or DataMapper call" do
      expect { BlueHydra::Device.first }.to raise_error(RuntimeError, /BlueHydra::Device\.first/)
      expect { DataMapper.repository }.to raise_error(RuntimeError, /DataMapper\.repository/)
      expect(db_calls).to eq(["BlueHydra::Device.first", "DataMapper.repository"])
    end
  end
end
