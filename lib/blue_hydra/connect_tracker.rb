module BlueHydra
  # Per-device policy for "should we bother trying to connect to this address",
  # held in memory only and deliberately not persisted.
  #
  # Two independent questions, both answered here because both are keyed on
  # address and both are consulted at the same decision point (Runner#
  # request_leinfo):
  #
  #   1. Did the device ever advertise itself as connectable? A device
  #      advertising ADV_NONCONN_IND / ADV_SCAN_IND cannot accept a connection at
  #      all, so attempting one is a guaranteed failure. Measured over a 47 hour
  #      run: 733 of 1329 addresses we attempted had never once advertised as
  #      connectable, about 27% of all direct-connect attempts thrown away on
  #      devices that could not have answered. Gated by the
  #      connect_to_nonconnectable config so the old behaviour is one flag away.
  #
  #   2. How many times in a row have we failed to connect? Some devices
  #      advertise as connectable and still never complete a connection. The same
  #      run had one such device: 15195 advertising sightings, 107 connect
  #      attempts, zero successes, zero version reads - 42% of all the direct-
  #      connect errors in the run came from that single address. Nothing in its
  #      advertising predicted it, so the only available signal is our own
  #      history.
  #
  # Nothing here is persisted on purpose. Both signals are cheap to rebuild from
  # a few advertisements, a stale strike count would silently suppress a device
  # that has since been power-cycled or replaced, and the addresses in question
  # are mostly private ones that rotate anyway. Strikes are dropped outright when
  # a device is marked offline (Device.mark_old_devices_offline), so a device that
  # goes away and comes back starts clean.
  #
  # THREADING: the result thread records connectability and forgets offline
  # devices; the discovery thread records strikes and reads both. Every access
  # goes through the mutex.
  module ConnectTracker
    # Consecutive failed connects before we stop attempting an address. Three, so
    # a device gets two retries past a first failure before being written off -
    # single failures are common and usually transient (the device stopped
    # advertising, the controller was busy).
    STRIKE_LIMIT = 3

    # Minimum seconds before re-queueing a device whose last connect FAILED.
    #
    # Those retries must not wait the full info_scan_rate (default 600s). Two
    # reasons, both measured:
    #   * A first failure is usually transient, and 600s later the device may be
    #     gone. In a 47 hour run the gap between consecutive failures of the same
    #     address was min 571s / median 617s - i.e. exactly info_scan_rate, so
    #     every retry in that run was paying the full success cadence.
    #   * Most of these addresses are private and rotate (RPA default ~15 min), so
    #     a 600s wait often means the retry lands after the identity we wanted has
    #     already changed. We never actually got a second attempt at that device.
    #
    # Only safe BECAUSE of STRIKE_LIMIT: prompt retries are bounded at three
    # attempts, so a device resolves in ~30s instead of ~30 minutes, rather than
    # being hammered forever.
    FAILED_RETRY_INTERVAL = 15

    @mutex = Mutex.new
    # address => { connectable: bool_seen, nonconnectable: bool_seen, strikes: n }
    @devices = {}
    @nonconnectable_skipped = 0
    @struck_out_skipped     = 0

    class << self
      attr_reader :nonconnectable_skipped, :struck_out_skipped

      # Record what one advertisement said about connectability. +connectable+ is
      # true, false, or nil when the advertisement carried no opinion (a scan
      # response, or any chunk that is not an advertising report) - nil is
      # ignored rather than recorded as "not connectable".
      def record_connectable(address, connectable)
        return if address.nil? || connectable.nil?
        @mutex.synchronize do
          entry = (@devices[address] ||= new_entry)
          if connectable
            entry[:connectable] = true
          else
            entry[:nonconnectable] = true
          end
        end
      end

      # true when this address has told us it is not connectable and has NEVER
      # told us it is.
      #
      # Deliberately not "has ever sent a non-connectable advertisement": a device
      # that advertises both ways (an ADV_IND plus a non-connectable beacon frame)
      # is genuinely connectable, and suppressing it would lose real data. Such a
      # device, if it never actually connects, is caught by the strike rule
      # instead - which is the signal that does not care what it advertised.
      def unconnectable?(address)
        @mutex.synchronize do
          entry = @devices[address]
          !!(entry && entry[:nonconnectable] && !entry[:connectable])
        end
      end

      # nil when we have never seen an advertisement that said either way, so
      # callers can distinguish "not connectable" from "do not know yet".
      def connectable(address)
        @mutex.synchronize do
          entry = @devices[address]
          next nil unless entry
          next true  if entry[:connectable]
          next false if entry[:nonconnectable]
          nil
        end
      end

      # Count one failed connect. Returns the new consecutive-failure count.
      def strike(address)
        return 0 if address.nil?
        @mutex.synchronize do
          entry = (@devices[address] ||= new_entry)
          entry[:strikes] += 1
        end
      end

      # A connect succeeded: the device is reachable after all, so the streak
      # resets. Connectability observations are left alone - they are facts about
      # what it advertised, not a running tally.
      def success(address)
        return if address.nil?
        @mutex.synchronize do
          entry = @devices[address]
          entry[:strikes] = 0 if entry
        end
      end

      def strikes(address)
        @mutex.synchronize { (e = @devices[address]) ? e[:strikes] : 0 }
      end

      def struck_out?(address)
        @mutex.synchronize do
          entry = @devices[address]
          !!(entry && entry[:strikes] >= STRIKE_LIMIT)
        end
      end

      # true when this address is mid-streak: its last connect failed and it has
      # attempts left. Such a device is re-queued on FAILED_RETRY_INTERVAL instead
      # of the full info_scan_rate (see Runner#push_to_queue).
      #
      # False once struck out, so a written-off device does not spin on the short
      # interval - attempt? refuses it anyway, but there is no reason to keep
      # enqueueing work that will be thrown away. Also false at zero strikes,
      # which is both a device we have never failed on and one that has since
      # succeeded (success resets the streak).
      def retry_soon?(address)
        @mutex.synchronize do
          entry = @devices[address]
          !!(entry && entry[:strikes] > 0 && entry[:strikes] < STRIKE_LIMIT)
        end
      end

      # Drop everything we know about an address. Called when a device is marked
      # offline, so its strikes do not outlive the sighting that earned them.
      def forget(address)
        return if address.nil?
        @mutex.synchronize { @devices.delete(address) }
      end

      # Should we attempt a connect to this address at all? Returns true to
      # attempt. Logs (debug) the reason for a skip and counts it, so a run can
      # be audited afterwards without guessing.
      def attempt?(address)
        if !BlueHydra.config["connect_to_nonconnectable"] && unconnectable?(address)
          @mutex.synchronize { @nonconnectable_skipped += 1 }
          BlueHydra.logger.debug("connect_tracker: #{address} advertises non-connectable, skipping")
          return false
        end

        if struck_out?(address)
          @mutex.synchronize { @struck_out_skipped += 1 }
          BlueHydra.logger.debug(
            "connect_tracker: #{address} failed #{STRIKE_LIMIT} connects in a row, skipping"
          )
          return false
        end

        true
      end

      # size of the tracked set, for the specs and for a sanity check that this
      # is not growing without bound
      def tracked_count
        @mutex.synchronize { @devices.size }
      end

      # test hook only
      def reset!
        @mutex.synchronize do
          @devices = {}
          @nonconnectable_skipped = 0
          @struck_out_skipped     = 0
        end
      end

      private

      def new_entry
        { connectable: false, nonconnectable: false, strikes: 0 }
      end
    end
  end
end
