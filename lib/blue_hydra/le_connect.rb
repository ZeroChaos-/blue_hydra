require 'socket'

module BlueHydra
  # Direct ("manual") LE connects for devices the kernel auto-connect list
  # cannot accept.
  #
  # mgmt Add Device only takes identity addresses - LE public, or LE random
  # STATIC - and answers INVALID_PARAMS for a resolvable or non-resolvable
  # private address (see BlueHydra::Mgmt.identity_address?). Most privacy-enabled
  # LE hardware therefore cannot be auto-connected at all, and never gets an LMP
  # version.
  #
  # The restriction is on that mgmt command, not on connecting. The kernel's own
  # connect path (l2cap_chan_connect -> hci_connect_le_scan ->
  # hci_explicit_conn_params_set) has no identity-address check and marks the
  # entry HCI_AUTO_CONN_EXPLICIT, so a private address is perfectly legal there.
  # Opening an L2CAP socket to the device is the supported way to reach it.
  #
  # We only need the ACL link, not an L2CAP channel: BlueHydra::HciCommand is
  # watching for LE Connection Complete on its own raw HCI socket and issues Read
  # Remote Version Information the instant a handle appears, whoever raised the
  # link.
  #
  # Hence SOCK_RAW (L2CAP_CHAN_RAW) with no PSM. A connection-oriented socket
  # cannot work here: l2cap_sock_connect only selects L2CAP_MODE_LE_FLOWCTL when
  # bdaddr_type_is_le(chan->src_type), and src_type is BDADDR_BREDR unless the
  # socket was bound LE-side first - so an unbound PSM socket attempts a
  # BR/EDR-style channel on an LE link and fails the moment the link is up. That
  # is exactly what an earlier on-device run did: the ACL came up, the version
  # read succeeded, and then our socket errored and tore the link down ~12ms
  # later, so every device was reported failed despite having answered. RAW skips
  # the PSM validity check and attempts no channel signalling at all.
  #
  # Connects are issued concurrently (see #connect_batch), but be clear about
  # what that does and does not buy. The controller can only have ONE LE
  # connection attempt outstanding, so the kernel serialises the actual LE
  # Extended Create Connection commands regardless - on-device captures show a
  # strict create -> connected -> next create cycle. What concurrency gives us is
  # queue depth: the next attempt starts ~1ms after the previous one completes,
  # with our link hold and socket teardown happening off the radio path instead
  # of between attempts.
  #
  # What a batch COSTS in wall clock is a separate question from that
  # serialisation, and easy to get wrong. The per-device timeouts are wall-clock
  # and run concurrently, so a batch of devices that all fail to answer costs
  # about ONE timeout, not the sum of them. Serialisation only stretches a batch
  # where devices actually connect, since each link-up waits its turn on the
  # radio. A 17 hour device run recorded 1103 attempts with zero abandoned at the
  # deadline, which is the evidence that batches finish well inside the budget.
  #
  # #connect_batch still takes a deadline, as a bound on the case that motivated
  # it (a 36s discovery-off window against a 6s budget) rather than as something
  # expected to fire routinely.
  class LeConnect
    BTPROTO_L2CAP = 0
    AF_BLUETOOTH  = BlueHydra::Mgmt::AF_BLUETOOTH

    # No PSM and no CID: on a RAW channel the kernel skips is_valid_psm() and
    # never sends a connection request, so the connect completes on the ACL alone.
    NO_PSM = 0x0000
    NO_CID = 0x0000

    # Bounded per-device connect timeout (seconds). The kernel has to scan for
    # the device's advertisement before it can connect, so this needs to cover an
    # advertising interval, not just a round trip.
    DEFAULT_CONNECT_TIMEOUT = 4

    # How long to hold a connected link open before closing, giving HciCommand's
    # Read Remote Version Information time to complete on it. The command is
    # issued at link-up, so this only has to cover the exchange itself.
    DEFAULT_LINK_HOLD = 1.0

    # How long to wait for a killed straggler to actually die. Deliberately short:
    # these joins run in series with discovery off, so a generous timeout here is
    # paid once per abandoned device. A thread that ignores this is leaked to the
    # GC rather than holding the radio hostage - it only has a socket to close.
    ABANDON_JOIN_TIMEOUT = 0.1

    # Connect outcomes that mean the link came up (the device is present and we
    # got what we came for). A refused PSM still means the ACL was established.
    CONNECTED_ERRORS = [Errno::ECONNREFUSED, Errno::EISCONN].freeze

    # Errors that mean the device never answered.
    #
    # ENOSYS is in here for a non-obvious reason. bt_to_errno() (net/bluetooth/
    # lib.c) translates the HCI status onto an errno and returns ENOSYS for any
    # code it has no entry for - and it has no entry for 0x3e, "Connection Failed
    # to be Established", which is THE ordinary LE outcome when we send a connect
    # and the peer never answers. So ENOSYS on a connect reads as "function not
    # implemented" while actually meaning "unreachable". A 47 hour device run
    # produced 243 of them, every one filed as a local error until this entry, and
    # 0x3e was the most common status in the matching capture at 2368 occurrences.
    #
    # Be clear that this is a BLANKET mapping, not one scoped to 0x3e, and that it
    # cannot be scoped here: bt_to_errno collapses every code it does not know
    # onto the same ENOSYS before we ever see it, so getsockopt(SO_ERROR) hands
    # back 38 with the original status already discarded.
    #
    # That makes it deliberately lossy. Most unmapped codes really are "asked, no
    # answer" (0x22 LL Response Timeout, 0x3f MAC Connection Failed), but a few
    # are not: 0x3a Controller Busy and 0x44 Operation Cancelled by Host are local
    # conditions that belong in error, and 0x2f Insufficient Security, 0x3b
    # Unacceptable Connection Parameters and 0x3d MIC Failure all mean the device
    # DID answer. Calling those unreachable is wrong in principle and accepted
    # here because every one of these outcomes is handled identically downstream -
    # no version read this time - and because 0x3e dominates by orders of
    # magnitude.
    #
    # If that ever needs to be exact, the status does survive somewhere: the mgmt
    # Connect Failed event carries it as a byte after the address, which
    # Mgmt#dispatch_event currently drops on the floor (it keeps params[0,6] and
    # nothing else). Surfacing it and matching it to the in-flight connect by
    # address would give the real code instead of this approximation.
    UNREACHABLE_ERRORS = [
      Errno::EHOSTDOWN, Errno::EHOSTUNREACH, Errno::ETIMEDOUT,
      Errno::ECONNABORTED, Errno::ENETUNREACH, Errno::ECONNRESET,
      Errno::ENOSYS
    ].freeze

    # == Parameters
    #   hci_index       :: controller index (the N in hciN)
    #   connect_timeout :: per-device bound on the connect attempt
    #   link_hold       :: how long to hold a live link open
    def initialize(hci_index, connect_timeout: DEFAULT_CONNECT_TIMEOUT,
                   link_hold: DEFAULT_LINK_HOLD)
      @index           = hci_index
      @connect_timeout = connect_timeout
      @link_hold       = link_hold
    end

    # Connect to every device in +entries+ (an address => mgmt address_type map),
    # one thread per device, and return {address => outcome} where outcome is
    # :connected, :unreachable, :error or :abandoned.
    #
    # +deadline+ is positional rather than a keyword on purpose: the first
    # parameter is a Hash, and adding any keyword to such a method silently
    # changes how Ruby binds callers that pass a bare `k => v` list - they become
    # keywords and the method gets no positional argument at all.
    #
    # +deadline+ (a Time) caps the whole batch, bounding the caller's
    # discovery-off budget however long the batch turns out to take. At the
    # deadline we stop collecting and abandon whatever is still in flight -
    # reachable devices answer in tens of milliseconds, so a spent budget almost
    # always means the remainder were not going to answer anyway. Abandoned
    # devices are reported as :abandoned rather than omitted, so the caller can
    # still account for every device it handed us. In practice this does not fire
    # (see the class comment): it is a bound, not the normal path.
    #
    # The caller sets the batch size (Runner::LE_DIRECT_CONNECT_PARALLEL, config
    # le_connect_parallel), which is the queue depth rather than a true
    # parallelism factor - see the class comment.
    #
    # A thread that somehow escapes its own rescue must not take the batch down,
    # and no thread may outlive this call: a leaked thread would hold a socket
    # open (and thus a live ACL) into the next scan window.
    def connect_batch(entries, deadline = nil)
      return {} if entries.nil? || entries.empty?

      # Keyed by address so an outcome can always be attributed, even when the
      # thread dies without returning one.
      threads = {}
      entries.each do |address, address_type|
        thread = Thread.new { connect(address, address_type) }
        # We collect every thread's outcome below and log anything unexpected, so
        # Ruby's default dump-the-backtrace-to-stderr would be duplicate noise -
        # and on a sensor stderr is not where errors are meant to go.
        thread.report_on_exception = false
        threads[address] = thread
      end

      results = {}
      begin
        threads.each do |address, thread|
          # join(nil) waits indefinitely, which is what we want with no deadline
          remaining = deadline ? deadline - Time.now : nil
          break if remaining && remaining <= 0

          begin
            # NB: join re-raises the thread's exception just as value does, so it
            # has to be inside this rescue too
            next unless thread.join(remaining)
            results[address] = thread.value
          rescue => e
            BlueHydra.logger.error("le_connect: #{address} raised: #{e.message}")
            results[address] = :error
          end
        end
      ensure
        # Timed because this is a prime suspect for dead time: it kills and joins
        # each straggler in turn, so a batch of ten that all need killing pays for
        # ten joins back to back, with discovery still off the whole while. An
        # on-device capture had an 18s stretch of no radio activity that the
        # counters could not account for.
        abandon_started = Time.now
        stragglers = threads.select { |_address, thread| thread.alive? }
        stragglers.each_value do |thread|
          thread.kill
          thread.join(ABANDON_JOIN_TIMEOUT)
        end
        abandon_took = Time.now - abandon_started

        if abandon_took > 1.0
          BlueHydra.logger.warn(
            "le_connect: abandoning %d connect(s) took %.2fs - that time is spent with discovery off" %
            [stragglers.size, abandon_took]
          )
        end

        # Anything with no outcome by now was still in flight at the deadline (or
        # never reached, because the deadline passed first). Reported rather than
        # omitted so the caller can account for every device it handed us.
        missing = threads.keys - results.keys
        missing.each { |address| results[address] = :abandoned }

        unless missing.empty?
          BlueHydra.logger.debug(
            "le_connect: abandoned #{missing.size} connect(s) at the discovery-off deadline"
          )
        end
      end

      results
    end

    # Connect to a single device and hold the link briefly. Returns :connected,
    # :unreachable or :error. Never raises, and always closes the socket - an
    # open socket keeps the ACL up, which would compete with the next scan.
    def connect(address, address_type)
      sock = open_socket
      outcome = attempt_connect(sock, sockaddr(address, address_type))
      hold_link if outcome == :connected
      outcome
    rescue IOError, SystemCallError => e
      BlueHydra.logger.debug("le_connect: #{address} failed: #{e.message}")
      :error
    ensure
      sock.close if sock && !sock.closed?
    end

    private

    # Non-blocking connect. connect_nonblock raises IO::WaitWritable while the
    # kernel is scanning for the device and establishing the link; we then wait
    # (bounded) and re-check.
    def attempt_connect(sock, addr)
      sock.connect_nonblock(addr)
      :connected
    rescue IO::WaitWritable
      return :unreachable unless wait_writable(sock)
      finish_connect(sock)
    rescue *CONNECTED_ERRORS
      :connected
    rescue *UNREACHABLE_ERRORS
      :unreachable
    end

    # Read the result of a completed non-blocking connect from SO_ERROR.
    #
    # NOT by calling connect a second time. That idiom works on TCP, where a
    # completed connect answers EISCONN, but an L2CAP channel that has been torn
    # down is SOCK_ZAPPED and l2cap_sock_connect rejects it at its very first
    # check, before it looks at anything else:
    #
    #   zapped = sock_flag(sk, SOCK_ZAPPED);
    #   if (zapped) return -EINVAL;
    #
    # EINVAL there says nothing about whether the device answered, and it is
    # indistinguishable from a malformed address. On device that was 112 of 1103
    # attempts recorded as local errors with no recoverable outcome. SO_ERROR
    # reports what the attempt actually did.
    #
    # Reading SO_ERROR clears it, so it is read exactly once.
    def finish_connect(sock)
      errno = sock.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
      return :connected if errno.zero?
      classify_errno(errno)
    end

    # Map a raw errno onto an outcome using the same tables as the exception
    # paths, so both routes agree on what a given errno means.
    def classify_errno(errno)
      error = SystemCallError.new(nil, errno)
      return :connected   if CONNECTED_ERRORS.any?   { |klass| error.is_a?(klass) }
      return :unreachable if UNREACHABLE_ERRORS.any? { |klass| error.is_a?(klass) }
      BlueHydra.logger.debug(
        "le_connect: unclassified connect errno #{errno} (#{error.class}: #{error.message})"
      )
      :error
    end

    # Extracted so tests can drive the timeout path without real sockets.
    def wait_writable(sock)
      !IO.select(nil, [sock], nil, @connect_timeout).nil?
    end

    # Extracted so tests do not have to actually sleep.
    def hold_link
      sleep @link_hold
    end

    # Extracted so unit tests can inject a fake socket. SOCK_RAW, not
    # SOCK_SEQPACKET - see the class comment for why a channel socket cannot work
    # for an unbound LE connect.
    def open_socket
      Socket.new(AF_BLUETOOTH, Socket::SOCK_RAW, BTPROTO_L2CAP)
    end

    # struct sockaddr_l2 { family; psm; bdaddr[6]; cid; bdaddr_type }. Same
    # packing as BlueHydra::L2Ping, but with the LE address type so the kernel
    # takes the LE connect path instead of paging for a classic device, and with
    # no PSM/CID so no channel is requested.
    def sockaddr(address, address_type)
      [AF_BLUETOOTH, NO_PSM, BlueHydra::Mgmt.pack_address(address), NO_CID, address_type]
        .pack("S!S!a6S!C")
    end
  end
end
