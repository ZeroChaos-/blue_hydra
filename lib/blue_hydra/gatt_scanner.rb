require 'thread'
require 'blue_hydra/gatt_tracker'
require 'blue_hydra/gatt_walker'

module BlueHydra
  # Takes LE Links from both connect paths and walks their GATT databases: it
  # decides eligibility against the Gatt_Tracker, keeps at most walk_parallel
  # Walks in flight, runs each Walk on a thread of its own, keeps the counters,
  # and puts each Walk's result on the Result_Thread's queue.
  #
  # One thread per Walk rather than a pool. A handoff arriving at capacity is
  # deferred and dropped, never queued, because the Link it names is unheld:
  # the kernel drops an auto-connected Link HCI_DISCONN_TIMEOUT (2 s) after its
  # own feature read (net/bluetooth/hci_event.c, hci_le_remote_feat_complete_evt
  # -> hci_conn_drop), so a queued Walk would connect after the Link had gone.
  # A spawned thread connects within milliseconds of the handoff instead.
  #
  # == Counters (Requirement 13)
  #
  # attempted == in-flight + complete + partial + protected + unchanged + busy
  # + timeout + disconnected + error in every snapshot, and in-flight stays in
  # 0..walk_parallel. Both hold because in-flight is changed only together with
  # the in-flight map, under @mutex: incremented with attempted when handoff
  # inserts a Walk, decremented with its outcome counter when finish_walk
  # removes it. in-flight therefore always equals @walks.size, which is what
  # the capacity check reads. skipped, deferred, resumed, peer-req and
  # reset-deferred sit outside the invariant.
  #
  # == Clocks
  #
  # One clock, the GattWalker's kind: an object with #now returning monotonic
  # Float seconds (GattWalker::MonotonicClock by default). A callable, the
  # GattTracker's kind, is accepted too and wrapped. Every walker gets this
  # same object, and the Gatt_Tracker gets readings of it as the explicit now
  # of plan_for and record_finished, so the tracker's own clock is never read
  # on these paths. Walk_Bound (started_at + walk_timeout), each walker's
  # transaction waits and report.ended_at, the Requirement 13.6 duration, and
  # every Finished_Walk age therefore share one time base. In production both
  # defaults are CLOCK_MONOTONIC, the clock Mgmt#link_up? stamps Links with,
  # so a walker's handoff lag is measured on it too.
  #
  # == Gatt_Tracker updates (Requirements 4.8, 4.9, 4.14, 17.1, 17.5 to 17.7, 17.11)
  #
  #   complete, partial, protected  clear Resume_State, then record_finished
  #                                 with report.database_hash as reported
  #   timeout, disconnected         clear Resume_State if report.hash_changed;
  #                                 then store report.state (planned_at: the
  #                                 Walk's started_at) if it has work
  #                                 outstanding, clear it if it has none, and
  #                                 leave Resume_State alone if it is nil
  #   unchanged, busy, error        nothing
  #
  # report.database_hash is recorded as reported, never inferred from
  # hash_changed: a hash check whose read was unavailable walks in full with
  # hash_changed false, and that full Walk may then read a hash other than the
  # recorded one. A nil report.state on timeout or disconnected is a fresh or
  # hash-check Walk cut short before its worklist began, which has nothing to
  # keep; a resumed Walk always reports its state (GattWalker#adopt_resume_state).
  #
  # == forget racing a Walk (Requirement 17.11)
  #
  # Device.mark_offline calls GattTracker.forget on the Result_Thread, and can
  # do so while a Walk for that address is in flight; the Walk may then end
  # timeout or disconnected and try to store Resume_State for a device just
  # marked offline, which would leave an orphan entry the online device set no
  # longer bounds. The tracker's forget-before-store guard closes this. forget
  # records the time it ran for the address, and every store here passes
  # planned_at: walk.started_at, the clock reading handoff gave plan_for, so
  # "planned" is the instant the Walk was decided. The tracker refuses a store
  # whose planned_at is at or before the address's last forget (equality
  # refuses): it stores nothing, drops any Resume_State for the address,
  # returns false and writes one debug line naming the address. The check and
  # the write share the tracker's mutex, so a forget cannot land between them.
  # A forget strictly before the handoff does not refuse: that Walk was
  # planned after the device went offline, on a Link that came up since.
  # Nothing else about a refused Walk changes: it is counted in its outcome
  # counter, its result is pushed (applying it sets the Device online again,
  # Requirement 11.4, and the next offline transition forgets it again) and
  # its end line is written.
  #
  # == Threading
  #
  # handoff runs on the Discovery_Thread and the LeConnect connect_batch
  # threads. It takes @mutex, consults the tracker (whose mutex nests inside
  # @mutex; nothing takes them the other way round), and starts a thread.
  # It logs nothing and touches no socket, so it returns in microseconds
  # (Requirement 2.3). Each Walk thread builds and runs its walker and
  # finishes the Walk; it takes @mutex only for short bookkeeping and never
  # while the walker runs. The CUI thread reads counters. The Discovery_Thread
  # blocks in wait_for_idle before a controller reset, which releases @mutex
  # while it waits. Runner#stop, on the signal-handling thread, calls
  # stopping! and later shutdown, which closes the walkers' bearers and joins
  # the Walk threads with @mutex released, so a Walk finishing meanwhile can
  # still take it to be counted. Nothing here touches the database or the
  # CUI's cui_status; the queues written are result_queue and, when the CUI
  # is active, cui_name_queue; never raw_queue or chunk_queue (Requirement
  # 15.6).
  class GattScanner
    # Requirement 13.1, in the Debug_CUI's GATT line order (13.5).
    COUNTERS = %i[attempted in-flight complete partial protected unchanged busy timeout
                  disconnected error skipped deferred resumed peer-req reset-deferred].freeze

    # What the CUI renders when gatt_scan is false and no scanner exists.
    ZERO_COUNTERS = COUNTERS.to_h { |counter| [counter, 0] }.freeze

    # Every Walk_Outcome, each also the name of its counter (Requirement 13.9).
    OUTCOMES = %i[complete partial protected unchanged busy timeout disconnected error].freeze

    # Finished_Walks (Glossary): learnt everything available without pairing.
    FINISHED_OUTCOMES = %i[complete partial protected].freeze

    # Walks that did not reach their end, whose outstanding work becomes
    # Resume_State.
    INTERRUPTED_OUTCOMES = GattWalker::INTERRUPTED_OUTCOMES

    # Outcomes that put a result on result_queue (Requirement 11.1). unchanged
    # learnt nothing new, busy and error never got to ask.
    OUTCOMES_WITH_RESULT = %i[complete partial protected timeout disconnected].freeze

    # Seconds shutdown waits for the Walk threads, in total across all of them
    # (Requirement 14.4). Real time, not @clock: it bounds how long the Runner
    # is held, not anything a Walk measures.
    SHUTDOWN_JOIN_TOTAL = 1.0

    # Wraps a callable clock (GattTracker's style) as an object with #now
    # (GattWalker's style).
    CallableClock = Struct.new(:callable) do
      def now
        callable.call
      end
    end
    private_constant :CallableClock

    # What a Walk thread is started with: the handoff, the tracker's plan for
    # it ([:full], [:hash_check, hash] or [:resume, state]) and the clock
    # reading at which attempted was counted.
    Walk = Struct.new(:address, :address_type, :source, :plan, :started_at)
    private_constant :Walk

    # == Parameters
    #   hci_index       controller index, passed to each walker
    #   result_queue    the Runner's result_queue, where every Walk result
    #                   goes (Requirement 11.1)
    #   cui_name_queue  the Runner's Cui_Name_Queue, a Queue, or nil (the
    #                   default) when the operator CUI is inactive. Each
    #                   result whose identity carries a Device Name also puts
    #                   [address, device_name] here, for the NAME cell of the
    #                   CUI's device table (Requirement 13.13). The name takes
    #                   a queue of its own because the table is written by the
    #                   parser thread, while the result goes to the
    #                   Result_Thread, whose database writes make it too slow
    #                   for a table the operator watches live; the parser
    #                   thread drains this queue between chunks.
    #   link_up         callable(address) -> monotonic time the Link came up, or
    #                   nil when it is down; ->(a) { mgmt.link_up?(a) }
    #   local_address   the controller's identity address, the bearer's source
    #   walk_parallel   gatt_walk_parallel: Walks in flight at most
    #   walk_timeout    gatt_walk_timeout: Walk_Bound in seconds
    #   read_all        gatt_read_all
    #   info_scan_rate  seconds a Finished_Walk stays young (Requirement 4)
    #   tracker         the Gatt_Tracker (module interface of GattTracker)
    #   walker_class    builds one walker per Walk with GattWalker's keywords
    #   clock           see Clocks in the class comment
    def initialize(hci_index:, result_queue:, link_up:, cui_name_queue: nil,
                   local_address: BlueHydra::LOCAL_ADAPTER_ADDRESS,
                   walk_parallel: BlueHydra.config["gatt_walk_parallel"],
                   walk_timeout: BlueHydra.config["gatt_walk_timeout"],
                   read_all: BlueHydra.config["gatt_read_all"],
                   info_scan_rate: BlueHydra.config["info_scan_rate"].to_i,
                   tracker: BlueHydra::GattTracker,
                   walker_class: BlueHydra::GattWalker,
                   clock: GattWalker::MONOTONIC)
      unless walk_parallel.is_a?(Integer) && walk_parallel >= 1
        raise ArgumentError, "walk_parallel must be an Integer >= 1, got #{walk_parallel.inspect}"
      end
      unless walk_timeout.is_a?(Numeric) && walk_timeout > 0
        raise ArgumentError, "walk_timeout must be a positive number of seconds, got #{walk_timeout.inspect}"
      end

      @hci_index      = hci_index
      @result_queue   = result_queue
      @cui_name_queue = cui_name_queue
      @link_up        = link_up
      @local_address  = local_address
      @walk_parallel  = walk_parallel
      @walk_timeout   = walk_timeout
      @read_all       = read_all
      @info_scan_rate = info_scan_rate
      @tracker        = tracker
      @walker_class   = walker_class
      @clock          = self.class.clock_object(clock)

      @mutex    = Mutex.new
      # Broadcast by finish_walk when the last in-flight Walk leaves @walks:
      # the Reset_Deferral's wait_for_idle waits on it.
      @idle     = ConditionVariable.new
      @counters = ZERO_COUNTERS.dup
      # address => { thread:, walker:, started_at:, source:, plan: }. walker is
      # nil until the Walk thread has built it.
      @walks    = {}
      # One-way shutdown flag (Requirement 14), set under @mutex by stopping!.
      # Read under @mutex by handoff, by register_walker and before each result
      # push, and without it by every walker's stopping callable, which only
      # ever sees it go from false to true.
      @stopping = false

      @stopping_check       = -> { @stopping }
      @peer_request_counter = -> { @mutex.synchronize { @counters[:"peer-req"] += 1 } }
    end

    # +clock+ as an object with #now.
    def self.clock_object(clock)
      return clock if clock.respond_to?(:now)
      return CallableClock.new(clock) if clock.respond_to?(:call)
      raise ArgumentError, "clock must respond to #now or #call, got #{clock.inspect}"
    end

    # A Link to +address+ is up; walk it if it is due. +address_type+ is the
    # mgmt LE address type it was connected with, +source+ :auto or :direct.
    #
    # Returns :attempted, :skipped or :deferred, naming the one counter
    # incremented (Requirement 13.4), or nil once shutdown has begun, when
    # nothing is counted (14.1). The decision order (design, GattScanner):
    #   1. shutdown begun                      -> nil
    #   2. a Walk of this address in flight    -> skipped, whatever the
    #                                             capacity (4.11)
    #   3. the tracker's plan; :skip           -> skipped, even at capacity
    #                                             (4.7, 13.4)
    #   4. walk_parallel Walks in flight       -> deferred, tracker untouched
    #                                             (3.6)
    #   5. otherwise                           -> attempted and in-flight, and
    #                                             resumed for a :resume plan
    #                                             (13.2, 13.11), started_at
    #                                             read, Walk thread started
    #
    # All of it under @mutex, so two handoffs racing for the last slot, or for
    # the same address, from the Discovery_Thread and a connect_batch thread
    # resolve one at a time (3.7). The only work is a tracker lookup (a
    # Resume_State copy for :resume) and Thread.new; the thread blocks on
    # @mutex in register_walker before it runs the walker, so attempted and
    # in-flight are counted before its Att_Bearer can open (13.2) and it
    # cannot finish before its entry exists.
    def handoff(address, address_type, source:)
      @mutex.synchronize do
        return nil if @stopping

        if @walks.key?(address)
          @counters[:skipped] += 1
          return :skipped
        end

        started_at = @clock.now
        plan = @tracker.plan_for(address, started_at, @info_scan_rate)
        if plan.first == :skip
          @counters[:skipped] += 1
          return :skipped
        end

        if @walks.size >= @walk_parallel
          @counters[:deferred] += 1
          return :deferred
        end

        # Thread first: if it cannot be created nothing has been counted, and
        # the caller's rescue logs it (Requirement 2.8).
        walk   = Walk.new(address, address_type, source, plan, started_at)
        thread = Thread.new { run_walk(walk) }
        # finish_walk accounts for every exit, and run_walk logs what escapes
        # the walker; Ruby's stderr dump would only duplicate it (as in
        # LeConnect#connect_batch).
        thread.report_on_exception = false
        thread.name = "gatt-walk #{address}"

        @counters[:attempted]   += 1
        @counters[:"in-flight"] += 1
        @counters[:resumed]     += 1 if plan.first == :resume
        @walks[address] = { thread: thread, walker: nil, started_at: started_at, source: source, plan: plan.first }
        :attempted
      end
    end

    # A snapshot of every counter, in COUNTERS order, taken under @mutex so the
    # Requirement 13.3 invariant holds in it.
    def counters
      @mutex.synchronize { @counters.dup }
    end

    # Walks in flight: started and not yet counted.
    def in_flight
      @mutex.synchronize { @walks.size }
    end

    # The Reset_Deferral (Requirements 3.9, 3.11 to 3.13): block until no Walk
    # is in flight or +timeout+ seconds have passed, whichever comes first.
    #
    # Returns [in_flight, waited]: the Walks still in flight at return (0 when
    # the wait drained, the count when the cap hit) and the seconds waited on
    # @clock. With nothing in flight it returns [0, 0.0] at once, moves no
    # counter and logs nothing (3.12); Runner#defer_reset_for_walks takes a
    # waited of 0.0 as that case. Otherwise reset-deferred goes up by exactly
    # one per call, however the wait ended, and one debug line records it
    # (3.13):
    #
    #   gatt: reset-deferred waited_ms=<n> in_flight=<n> cap_ms=<n>
    #
    # waited_ms is what Device_Validation's walk_durations script sums for the
    # total deferred seconds; in_flight is 0 when the wait drained and the
    # count still in flight when the cap hit; cap_ms is +timeout+. It is
    # logged after @mutex is released, like the Walk end line.
    #
    # Called on the Discovery_Thread by Runner#hci_reset, before set_powered
    # false. It issues no mgmt command (3.10), so discovery stays as the
    # preceding phase left it and the wait is scanning time, not a scan gap.
    # It waits on @idle, which finish_walk broadcasts under @mutex when the
    # last entry leaves @walks, and re-checks @walks after every wakeup: a
    # handoff can insert a Walk between that broadcast and this thread
    # reacquiring @mutex, and ConditionVariable#wait may return early.
    #
    # Two clocks are involved. The deadline and waited are on @clock, the time
    # base of everything else here. ConditionVariable#wait's timeout is real
    # seconds on the VM's clock, which in production is the same
    # CLOCK_MONOTONIC, so the remaining time on @clock is passed as the real
    # wait. With an injected clock the two can disagree: a fake clock that
    # stands still would leave remaining unchanged after every timed-out wait
    # and the loop would never end. So the loop is capped on the real clock as
    # well: each wait is for the lesser of the two remainders and the loop ends
    # when either reaches zero. waited stays @clock's reading, so with a fake
    # clock nobody advances it is 0.0 after a real wait of +timeout+ seconds; a
    # spec that wants waited to show the wait advances the fake clock, from the
    # scripted walker before it returns or from a helper thread.
    def wait_for_idle(timeout)
      unless timeout.is_a?(Numeric) && timeout > 0
        raise ArgumentError, "timeout must be a positive number of seconds, got #{timeout.inspect}"
      end

      in_flight = nil
      waited    = nil
      @mutex.synchronize do
        return [0, 0.0] if @walks.empty?

        started       = @clock.now
        deadline      = started + timeout
        real_deadline = GattWalker::MONOTONIC.now + timeout
        loop do
          remaining = [deadline - @clock.now, real_deadline - GattWalker::MONOTONIC.now].min
          break if remaining <= 0

          @idle.wait(@mutex, remaining)
          break if @walks.empty?
        end
        in_flight = @walks.size
        waited    = (@clock.now - started).to_f
        @counters[:"reset-deferred"] += 1
      end
      log_reset_deferred(in_flight, waited, timeout)
      [in_flight, waited]
    end

    # Runner shutdown has begun: refuse every handoff from now on (Requirement
    # 14.1), push no further result (14.3) and have every walker stop sending
    # (14.6, through its stopping callable). One-way, like Mgmt#stopping!, and
    # idempotent; nothing else happens here. Runner#stop calls it beside
    # mgmt.stopping! and hci.stopping! before it kills the Discovery_Thread,
    # and shutdown calls it again first thing, so the flag is set before
    # shutdown reads the in-flight map. Returns nil.
    def stopping!
      @mutex.synchronize { @stopping = true }
      nil
    end

    # Whether Runner shutdown has begun.
    def stopping?
      @stopping
    end

    # Stop every Walk in flight and wait briefly for its thread (Requirements
    # 14.2, 14.4, 14.5, 14.7). Runner#stop calls it after the discovery and
    # connect threads are joined, so no handoff can follow, and before the
    # shutdown hci_reset, so no Att_Bearer is open when the controller powers
    # down. Returns the number of Walk threads still running when it gives up
    # waiting: 0 when every Walk thread has exited. The Runner needs nothing
    # from it; the count is for the warning and for specs.
    #
    # In order:
    #   1. stopping!, then a snapshot of the in-flight map under @mutex. Setting
    #      the flag first is what covers a Walk thread that has not registered
    #      its walker yet (walker nil in the snapshot): register_walker reads
    #      the flag under the same mutex and closes that walker's bearer itself.
    #   2. GattWalker#close_bearer on every walker in the snapshot, from this
    #      thread and outside @mutex. It is idempotent, takes only the walker's
    #      own bearer mutex (never held across socket I/O), and closes the
    #      bearer whether its connect is pending or complete, including one the
    #      Walk thread installs afterwards. A Walk thread blocked in the
    #      bearer's wait_readable, wait_writable, recv or send is woken with
    #      IOError and ends disconnected (see the Bearer's comments); one
    #      blocked on nothing sees @stopping at its next transact. finish_walk
    #      then counts the Walk and, with @stopping set, pushes no result. A
    #      close that raises is logged at debug and the loop goes on (14.7).
    #   3. Thread#join on each snapshot thread with SHUTDOWN_JOIN_TOTAL seconds
    #      shared between them: each join gets what is left of the budget, and
    #      once it is spent the remaining threads are only checked for alive?.
    #      A join re-raises what its thread died with; that thread is not
    #      running, so it is logged and not counted. Nothing is killed (14.5):
    #      a killed thread could leak a half-closed socket or a Walk the
    #      counters never saw end.
    #   4. One warning when any thread is still running, then return:
    #
    #        gatt: shutdown: <n> Walk thread(s) still running after <ms> ms;
    #        left to exit on their own
    #
    # Nothing here moves a counter. Calling it again is harmless: the flag is
    # already set, closed bearers stay closed, and the join waits only for
    # threads still in the map.
    def shutdown
      stopping!
      snapshot = @mutex.synchronize do
        @walks.map { |address, entry| [address, entry[:thread], entry[:walker]] }
      end

      snapshot.each { |address, _thread, walker| close_walker_bearer(address, walker) }

      deadline      = GattWalker::MONOTONIC.now + SHUTDOWN_JOIN_TOTAL
      still_running = snapshot.count { |address, thread, _walker| !thread_exited?(address, thread, deadline) }
      if still_running.positive?
        BlueHydra.logger.warn(
          format("gatt: shutdown: %d Walk thread(s) still running after %d ms; left to exit on their own",
                 still_running, (SHUTDOWN_JOIN_TOTAL * 1000).round)
        )
      end
      still_running
    end

    # test hook only: zero the counters, forget the in-flight map and clear the
    # stopping flag. Call it with no Walk in flight; a Walk finishing after it
    # finds its entry gone and leaves the new counters and result_queue alone.
    # The tracker is not touched (GattTracker.reset! is its own hook).
    def reset!
      @mutex.synchronize do
        @counters = ZERO_COUNTERS.dup
        @walks    = {}
        @stopping = false
      end
    end

    private

    # The body of one Walk thread.
    #
    # Walk_Bound runs from started_at, the reading handoff took when it counted
    # attempted (Requirement 3.4). Any StandardError escaping the walker,
    # including one raised building it, is logged here and counted error by
    # finish_walk (Requirement 13.7); finish_walk runs from ensure, so even a
    # killed thread is counted and the invariant cannot lose a Walk.
    def run_walk(walk)
      walker = nil
      report = nil
      begin
        walker = @walker_class.new(
          address: walk.address, address_type: walk.address_type, hci_index: @hci_index,
          local_address: @local_address, plan: walker_plan(walk.plan),
          deadline: walk.started_at + @walk_timeout, read_all: @read_all,
          link_up: @link_up, stopping: @stopping_check, on_peer_request: @peer_request_counter,
          clock: @clock
        )
        register_walker(walk.address, walker)
        report = walker.run
      rescue StandardError => e
        log_escape(walk.address, e)
      ensure
        finish_walk(walk, walker, report)
      end
    end

    # The GattWalker::Plan for a tracker plan. Built on the Walk thread, so a
    # tracker answer the Plan refuses is that Walk's error rather than an
    # exception out of handoff.
    def walker_plan(plan)
      kind, argument = plan
      case kind
      when :full       then GattWalker::Plan.full
      when :hash_check then GattWalker::Plan.hash_check(argument)
      when :resume     then GattWalker::Plan.resume(argument)
      else raise ArgumentError, "unknown Gatt_Tracker plan #{plan.inspect}"
      end
    end

    # Record the walker in its in-flight entry before run, so shutdown can
    # reach its bearer from the moment one exists: GattWalker#close_bearer
    # closes the current bearer and any the Walk installs afterwards. A walker
    # built after shutdown began is closed here, before it can open a socket.
    def register_walker(address, walker)
      stopping = @mutex.synchronize do
        entry = @walks[address]
        entry[:walker] = walker if own_entry?(entry)
        @stopping
      end
      walker.close_bearer if stopping
    end

    # Finish one Walk, in this order:
    #   1. close the bearer if still open (Requirement 5.6: closed before the
    #      outcome is counted; the walker closes it itself on every return)
    #   2. update the Gatt_Tracker (table in the class comment)
    #   3. build the result for OUTCOMES_WITH_RESULT
    #   4. write the Requirement 13.6 line
    #   5. under @mutex: in-flight down and the outcome counter up, the entry
    #      removed, the idle condition broadcast when none is left, and,
    #      unless shutdown has begun, the result pushed and then, with the
    #      CUI active and a Device Name in the result, [address, name] pushed
    #      onto cui_name_queue
    #
    # The tracker is updated while the Walk is still in @walks, so a handoff
    # of the same address meanwhile is skipped (4.11) instead of planning from
    # the record this Walk is about to replace. The counters move last, in
    # one critical section with the map and the push: once a caller sees the
    # outcome counted, the tracker, the log line and result_queue already
    # reflect the Walk, and in-flight never disagrees with @walks.size. The
    # pushes are decided under @mutex, as stopping! sets the flag under it, so
    # neither a result nor a CUI name follows the start of shutdown (14.3);
    # both queues are the Runner's unbounded Queues, so the pushes never
    # block. The result push ignores the Runner's stunned flag (11.1):
    # stunning sheds cheap, repeated parser output, and a Walk result is rare
    # and costly to get again.
    #
    # Each step before the last rescues its own StandardError, so the last
    # always runs and every Walk is counted exactly once. Within the last, the
    # pushes come after the bookkeeping and each rescues for itself, so a
    # queue that refuses its push (closed at shutdown, say) cannot strand the
    # entry in @walks, which would hold its slot and skip the address for
    # good, nor keep the other queue's push from happening.
    def finish_walk(walk, walker, report)
      address = walk.address
      report  = checked_report(address, report)
      outcome = report ? report.outcome : :error

      close_walker_bearer(address, walker)
      update_tracker(walk, outcome, report) if report
      result = walk_result(address, report) if OUTCOMES_WITH_RESULT.include?(outcome)
      log_walk_end(walk, outcome, report)
    ensure
      @mutex.synchronize do
        entry = @walks[address]
        # Not ours only after reset!; the counters it zeroed are left alone.
        if own_entry?(entry)
          @counters[:"in-flight"]      -= 1
          @counters[outcome || :error] += 1
          @walks.delete(address)
          @idle.broadcast if @walks.empty?
          if result && !@stopping
            push_result(address, result)
            push_cui_name(address, result)
          end
        end
      end
    end

    # The one write to result_queue. Called under @mutex; see finish_walk.
    # With push_cui_name below, the whole list of queue writes (Requirement
    # 15.6: never raw_queue or chunk_queue).
    def push_result(address, result)
      @result_queue.push(result)
    rescue StandardError => e
      log_escape(address, e, "pushing the result")
    end

    # The one write to cui_name_queue: [address, device_name] for the NAME
    # cell of the CUI's device table (Requirement 13.13), when the queue
    # exists (nil with the CUI inactive) and the result's identity carries a
    # non-empty Device Name. Called under @mutex straight after push_result
    # and under its condition, so no pair follows the start of shutdown
    # either (14.3). Rescues for itself as push_result does: a refused push
    # is logged and the Walk's in-flight entry is still gone.
    def push_cui_name(address, result)
      return if @cui_name_queue.nil?

      name = result.dig(:identity, :device_name)
      return unless name.is_a?(String) && !name.empty?

      @cui_name_queue.push([address, name])
    rescue StandardError => e
      log_escape(address, e, "pushing the CUI name")
    end

    # Whether +entry+ is the in-flight entry of the calling Walk thread.
    # handoff stores the thread before releasing @mutex, and the thread takes
    # @mutex before it reads @walks, so a Walk always finds its own entry
    # unless reset! has dropped it.
    def own_entry?(entry)
      !entry.nil? && entry[:thread].equal?(Thread.current)
    end

    # +report+ when it carries a Walk_Outcome, otherwise nil (counted error).
    # A real walker cannot return anything else (GattWalker#finish refuses an
    # unknown outcome); a nil report means walker.run raised, already logged.
    def checked_report(address, report)
      return nil if report.nil?
      return report if report.respond_to?(:outcome) && OUTCOMES.include?(report.outcome)

      BlueHydra.logger.error("gatt: #{address} walker returned #{report.inspect[0, 200]}; counted as error")
      nil
    end

    # Close a walker's bearer from whichever thread is finishing or shutting
    # down the Walk; a nil walker (not built yet) is nothing to close. A close
    # that raises is logged at debug and swallowed (Requirement 14.7), so the
    # caller's loop over the other Walks goes on.
    def close_walker_bearer(address, walker)
      walker&.close_bearer
    rescue StandardError => e
      BlueHydra.logger.debug("gatt: #{address} closing bearer raised #{e.class}: #{e.message}")
    end

    # shutdown's wait for one Walk thread: true once it has exited, false if it
    # is still running when +deadline+ (real monotonic seconds) passes. Waits
    # only for what is left of the budget, so the joins of every thread add up
    # to SHUTDOWN_JOIN_TOTAL at most; with the budget spent this only asks
    # alive?. Thread#join re-raises an exception the thread died with (its
    # Walk was still counted, from run_walk's ensure); that thread has exited.
    def thread_exited?(address, thread, deadline)
      remaining = deadline - GattWalker::MONOTONIC.now
      return !thread.alive? if remaining <= 0

      !thread.join(remaining).nil?
    rescue StandardError => e
      log_escape(address, e, "exiting its Walk thread")
      true
    end

    # The Gatt_Tracker side of a counted outcome; see the class comment.
    def update_tracker(walk, outcome, report)
      address = walk.address
      if FINISHED_OUTCOMES.include?(outcome)
        # 4.14, 17.7: nothing left to resume. Then 4.8: the hash this Walk
        # read most recently, nil when it read none, at a reading of @clock so
        # the age plan_for measures from it (4.13) is on the handoff's clock.
        @tracker.clear_resume_state(address)
        @tracker.record_finished(address, report.database_hash, @clock.now, @info_scan_rate)
      elsif INTERRUPTED_OUTCOMES.include?(outcome)
        # 17.6: a Resume_State built against the old database is never
        # resumed, whatever this Walk leaves.
        @tracker.clear_resume_state(address) if report.hash_changed
        state = report.state
        if state.nil?
          # Nothing of this Walk's to keep; any Resume_State stays (4.15).
        elsif state.outstanding?
          # 17.1, 17.5. planned_at is the reading handoff gave plan_for, so a
          # forget at or after it refuses the store (17.11; the tracker logs
          # the refusal). The return value is not consulted: refused or not,
          # the Walk is counted and its result pushed the same way.
          @tracker.store_resume_state(address, state, planned_at: walk.started_at)
        else
          @tracker.clear_resume_state(address)        # 17.1: nothing outstanding
        end
      end
      # unchanged, busy, error: the record stays as it was (4.9).
    rescue StandardError => e
      log_escape(address, e, "updating the Gatt_Tracker")
    end

    # The result hash for the Result_Thread (design: Walk result hash). The
    # service, characteristic and identity lists are everything the Walk's
    # state holds, which for a resumed Walk includes the Walks it continues;
    # the Device merges or replaces by outcome (Requirements 11.5 to 11.8).
    # hash_changed rides along for the Device's Requirement 11.9 check.
    def walk_result(address, report)
      {
        gatt_walk:       true,
        address:         address,
        outcome:         report.outcome,
        resumed:         report.resumed,
        ended_at:        Time.now.to_i,
        database_hash:   report.database_hash,
        hash_changed:    report.hash_changed,
        service_uuids:   report.services.map { |service| service[:uuid] },
        characteristics: report.characteristics,
        identity:        report.identity,
        outstanding:     report.outstanding
      }
    rescue StandardError => e
      log_escape(address, e, "building the result")
      nil
    end

    # The one debug line per Walk (Requirement 13.6), as key=value pairs for
    # Device_Validation's walk_durations script. duration_ms runs from the
    # attempted increment (started_at) to the bearer close (report.ended_at),
    # both on @clock. For a resumed Walk, services, characteristics and
    # values_read are cumulative across the Walks it continues, as its report
    # is. A Walk whose walker raised has no report: its counts are 0 and its
    # MTU the default, and the error line before it says why. source and
    # handoff_lag_ms (Link up to bearer connect, "-" when the Walk never got
    # that far) are extra fields for checking the 2 s HCI_DISCONN_TIMEOUT
    # window on device.
    def log_walk_end(walk, outcome, report)
      ended_at = walk_ended_at(report)
      characteristics = report ? report.characteristics : []
      lag = report&.handoff_lag
      BlueHydra.logger.debug(
        format("gatt: walk %s outcome=%s resumed=%s duration_ms=%d requests=%d mtu=%d services=%d " \
               "characteristics=%d values_read=%d source=%s handoff_lag_ms=%s",
               walk.address, outcome, report ? report.resumed : walk.plan.first == :resume,
               ((ended_at - walk.started_at) * 1000).round,
               report ? report.requests_sent : 0,
               report ? report.mtu : GattWalker::DEFAULT_MTU,
               report ? report.services.size : 0,
               characteristics.size,
               characteristics.count { |entry| entry[:read_status] == "read" },
               walk.source,
               lag.is_a?(Numeric) ? (lag * 1000).round.to_s : "-")
      )
    rescue StandardError => e
      log_escape(walk.address, e, "logging the Walk end")
    end

    # The one debug line per deferred reset (Requirement 3.13), as key=value
    # pairs for Device_Validation's walk_durations script; see wait_for_idle
    # for the fields. Milliseconds, as the Walk end line's duration_ms is.
    def log_reset_deferred(in_flight, waited, timeout)
      BlueHydra.logger.debug(
        format("gatt: reset-deferred waited_ms=%d in_flight=%d cap_ms=%d",
               (waited * 1000).round, in_flight, (timeout * 1000).round)
      )
    end

    # When the Walk's bearer closed, on @clock: the report's ended_at, or the
    # clock now for a Walk that has no report (its walker raised).
    def walk_ended_at(report)
      ended_at = report&.ended_at
      ended_at.is_a?(Numeric) ? ended_at : @clock.now
    end

    # One error entry naming the address, the exception's class and message,
    # and its backtrace (Requirement 13.7). One entry rather than one per
    # backtrace line, because concurrent Walk threads would interleave lines.
    def log_escape(address, error, during = "walking")
      backtrace = (error.backtrace || []).join("\n  ")
      BlueHydra.logger.error("gatt: #{address} #{during} raised #{error.class}: #{error.message}\n  #{backtrace}")
    rescue StandardError
      nil
    end
  end
end
