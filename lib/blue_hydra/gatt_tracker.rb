module BlueHydra
  # Per-address memory for the Gatt_Scanner's "walk this device, check its hash,
  # resume it, or leave it alone" decision. Follows ConnectTracker: one mutex,
  # address-keyed, in memory only, no database access.
  #
  # Three maps with different lifetimes, on purpose:
  #
  #   @finished  address => { finished_at:, database_hash: }
  #     The last Finished_Walk (complete, partial or protected). Pruned on
  #     info_scan_rate each time a Walk finishes, because the addresses walked
  #     are mostly private ones that rotate and would otherwise accumulate
  #     forever. forget does NOT touch it: a device that flaps offline and back
  #     within info_scan_rate should get a hash check or a skip, not a full
  #     re-walk of a database we read minutes ago.
  #
  #   @resume    address => Resume_State (a GattWalker::WalkState, opaque here)
  #     The outstanding worklist of an interrupted Walk. Never pruned on age: it
  #     must survive until the device goes away or its database changes, so a
  #     long Walk progresses across handoffs instead of being skipped by the
  #     cadence. It is bounded by the online device set instead, because the
  #     Result_Thread calls forget from Device.mark_offline exactly as it calls
  #     ConnectTracker.forget.
  #
  #   @forgotten address => monotonic time of the last forget
  #     The forget-before-store guard (Requirement 17.11). Device.mark_offline
  #     can forget an address while its Walk is still in flight; the Walk then
  #     ends timeout or disconnected and would store Resume_State for a device
  #     just marked offline, an orphan that only the device coming back would
  #     clear. A store that names the time its Walk was planned is refused when
  #     a forget for the address is at or after that time. Pruned with
  #     @finished on info_scan_rate: a Walk lasts at most gatt_walk_timeout
  #     (60 s ceiling), so a forget older than info_scan_rate cannot race any
  #     Walk's store.
  #
  # Ages are measured on a monotonic clock. A wall-clock step would otherwise
  # make every record look ancient (one burst of full re-walks) or brand new
  # (nothing re-walked until the clock catches up).
  #
  # Nothing is persisted, so after a restart every address gets a full Walk; a
  # stale hash would only cost one extra hash check, but a stale Resume_State
  # would resume a worklist built against a database we can no longer vouch for.
  #
  # RESUME_STATE CONTRACT: the tracker never shares a stored Resume_State with
  # a running Walk. store_resume_state keeps a copy, and plan_for/resume_state
  # hand out a copy, both made with state.deep_dup when the object responds to
  # it. deep_dup must return a copy that shares no mutable object with the
  # original (every nested Struct, Array, Hash and String copied);
  # Marshal.load(Marshal.dump(self)) meets that while the state holds only
  # Structs, Data, Arrays, Hashes, Strings, Symbols, numbers, booleans and nil.
  # An object without deep_dup is stored and returned as given, and the caller
  # then owns any aliasing. Copying on read as well as on store means a Walk
  # that ends `error` (which leaves the tracker unchanged, Requirement 4.9)
  # cannot leave a half-updated worklist behind for the next resume.
  #
  # THREADING: Walk threads write (record_finished, store_resume_state,
  # clear_resume_state); the Discovery_Thread and the connect_batch threads
  # read through GattScanner#handoff (plan_for); the Result_Thread writes
  # (forget). Every map access goes through the mutex. deep_dup runs outside
  # it, so the critical section stays a few hash operations inside a handoff
  # that must return within 100 ms, and walker code never runs under the lock.
  module GattTracker
    MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

    @mutex     = Mutex.new
    @finished  = {}
    @resume    = {}
    @forgotten = {}
    @clock     = MONOTONIC

    class << self
      # -> Float monotonic seconds. Used wherever a caller passes now = nil;
      # tests inject a fake.
      attr_writer :clock

      def clock
        @clock || MONOTONIC
      end

      # The Walk plan for a handoff, in the Requirement 4 order:
      #
      #   [:resume, state]     Resume_State exists, whatever the finish age (4.1)
      #   [:full]              no Finished_Walk, or one at least info_scan_rate
      #                        seconds old (4.2, 4.3)
      #   [:hash_check, hash]  a younger Finished_Walk that recorded a hash (4.4)
      #   [:skip]              a younger Finished_Walk with no hash (4.7)
      #
      # An age of exactly info_scan_rate is due (4.3 "at least"), while the
      # prune in record_finished only drops ages above it (4.10 "more than"), so
      # an entry at the boundary is still held but already planned :full.
      #
      # +now+ is monotonic seconds on the same clock record_finished was given,
      # or nil to read #clock.
      def plan_for(address, now, info_scan_rate)
        now ||= clock.call
        state, entry = @mutex.synchronize { [@resume[address], @finished[address]] }

        return [:resume, copy_state(state)] if state
        return [:full] if entry.nil? || now - entry[:finished_at] >= info_scan_rate
        return [:hash_check, entry[:database_hash]] if entry[:database_hash]
        [:skip]
      end

      # A Walk ended as a Finished_Walk (4.8): record its finish time and the
      # Database Hash it read most recently, replacing any earlier hash, and
      # clearing it when this Walk read none (nil). Then drop every record more
      # than info_scan_rate seconds old (4.10), and in the same pass every
      # forget time that old, which bounds @forgotten (17.11). Resume_State is
      # untouched; outcomes that are not Finished_Walks must not call this (4.9).
      #
      # The hash is kept as a frozen copy so a later change to the walker's
      # buffer cannot alter what the next hash check compares against.
      def record_finished(address, database_hash, now, info_scan_rate)
        return if address.nil?
        now ||= clock.call
        hash = database_hash.nil? ? nil : database_hash.dup.freeze

        @mutex.synchronize do
          @finished[address] = { finished_at: now, database_hash: hash }
          @finished.delete_if { |_, entry| now - entry[:finished_at] > info_scan_rate }
          @forgotten.delete_if { |_, forgotten_at| now - forgotten_at > info_scan_rate }
        end
        nil
      end

      # { finished_at:, database_hash: } for the last Finished_Walk, or nil.
      def finished(address)
        @mutex.synchronize { (entry = @finished[address]) ? entry.dup : nil }
      end

      # A copy of the stored Resume_State, or nil.
      def resume_state(address)
        state = @mutex.synchronize { @resume[address] }
        state.nil? ? nil : copy_state(state)
      end

      # Record or replace the Resume_State for an address (17.1, 17.5); one per
      # address (17.2). nil clears it rather than storing a nil entry.
      #
      # +planned_at+ is the monotonic time the Walk was planned (the now the
      # Gatt_Scanner gave plan_for at handoff). When a forget for the address
      # is at or after it, the store is refused (17.11): nothing is stored, any
      # Resume_State for the address is dropped, and a debug line names the
      # address. Equality refuses because a forget and a handoff on the same
      # clock reading leave the device's online state in doubt, and holding no
      # Resume_State is the safe side. The check and the write share the one
      # critical section, so a forget cannot slip between them. nil planned_at
      # stores unconditionally.
      #
      # Returns true when a Resume_State was stored, false otherwise: refused,
      # nil state (cleared, nothing stored) or nil address.
      def store_resume_state(address, state, planned_at: nil)
        return false if address.nil?
        if state.nil?
          clear_resume_state(address)
          return false
        end

        copy = copy_state(state)
        stored = @mutex.synchronize do
          forgotten_at = @forgotten[address]
          if planned_at && forgotten_at && forgotten_at >= planned_at
            @resume.delete(address)
            false
          else
            @resume[address] = copy
            true
          end
        end

        unless stored
          BlueHydra.logger.debug("gatt: #{address} Resume_State not stored: device forgotten after the Walk was planned")
        end
        stored
      end

      # Discard the Resume_State: nothing left to resume (17.7) or the
      # database changed under it (17.6).
      def clear_resume_state(address)
        return if address.nil?
        @mutex.synchronize { @resume.delete(address) }
        nil
      end

      # Called from Device.mark_offline on the Result_Thread (17.8). Drops the
      # Resume_State and records the forget time, +now+ or a clock reading, for
      # the forget-before-store guard (17.11); the finish record ages out
      # through the prune.
      def forget(address, now = nil)
        return if address.nil?
        now ||= clock.call

        @mutex.synchronize do
          @forgotten[address] = now
          @resume.delete(address)
        end
        nil
      end

      # Distinct addresses holding either kind of state about the device, a
      # finish record or a Resume_State, for the specs and for a sanity check
      # that those maps are not growing without bound. Forget times are not
      # counted: they are a guard, not state about the device, and the prune
      # in record_finished bounds them (covered by its own specs).
      def tracked_count
        @mutex.synchronize { (@finished.keys | @resume.keys).size }
      end

      # test hook only: drops all state and restores the monotonic clock, so an
      # injected clock cannot leak into the next example.
      def reset!
        @mutex.synchronize do
          @finished  = {}
          @resume    = {}
          @forgotten = {}
          @clock     = MONOTONIC
        end
      end

      private

      def copy_state(state)
        state.respond_to?(:deep_dup) ? state.deep_dup : state
      end
    end
  end
end
