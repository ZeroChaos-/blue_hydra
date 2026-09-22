require 'socket'
require 'timeout'
require 'thread'

module BlueHydra
  # Minimal client for the Linux Bluetooth Management (mgmt) API - the same
  # kernel interface btmgmt and bluetoothd use. It speaks the mgmt protocol
  # directly over an AF_BLUETOOTH raw socket on the control channel.
  #
  # A single dedicated reader thread owns all reads from the control socket. It
  # delivers Command Complete/Status replies back to the (serialized) command
  # caller and dispatches unsolicited kernel events. This lets us react to async
  # events immediately - in particular, when the kernel winds a discovery
  # session down (mgmt Discovering event, state off) we re-issue Start Discovery
  # so scanning stays continuous, the way bluetoothd keeps `scan on` alive.
  # Continuously reading the socket also keeps its receive buffer from filling.
  #
  # Protocol reference: Linux kernel Documentation/bluetooth-mgmt.txt.
  # Every packet (command or event) starts with a 6 byte little-endian header:
  #   opcode/event code : __le16
  #   controller index  : __le16
  #   parameter length  : __le16
  # followed by that many parameter bytes.
  class Mgmt

    # Thread-safe queue of decoded unsolicited connection events
    # ({type: :connected/:disconnected/:failed, address: "AA:.."}). The reader
    # thread pushes; the discovery thread drains it during the CONNECT phase.
    attr_reader :connection_events

    # socket constants (AF_BLUETOOTH is not always exposed as a Socket:: const)
    AF_BLUETOOTH        = 31
    BTPROTO_HCI         = 1
    HCI_DEV_NONE        = 0xffff
    HCI_CHANNEL_CONTROL = 3

    # commands we issue
    CMD_READ_CONTROLLER_INFO = 0x0004
    CMD_SET_POWERED          = 0x0005
    CMD_SET_BONDABLE         = 0x0009
    CMD_SET_LE               = 0x000D
    CMD_SET_BREDR            = 0x002A
    CMD_SET_IO_CAPABILITY    = 0x0018
    CMD_PIN_CODE_NEG_REPLY   = 0x0017
    CMD_USER_CONFIRM_NEG_REPLY = 0x001D
    CMD_USER_PASSKEY_NEG_REPLY = 0x001F
    CMD_START_DISCOVERY      = 0x0023
    CMD_STOP_DISCOVERY       = 0x0024
    CMD_ADD_DEVICE           = 0x0033
    CMD_REMOVE_DEVICE        = 0x0034

    # IO capability that has no UI path, so pairing can never prompt.
    IO_CAP_NO_INPUT_NO_OUTPUT = 0x03

    # events we consume
    EV_CMD_COMPLETE = 0x0001
    EV_CMD_STATUS   = 0x0002
    EV_DISCOVERING  = 0x0013

    # connection lifecycle events (all carry the 6 byte LE address first). Used
    # to drive the event-driven auto-connect CONNECT phase.
    EV_DEVICE_CONNECTED    = 0x000B
    EV_DEVICE_DISCONNECTED = 0x000C
    EV_CONNECT_FAILED      = 0x000D

    # pairing-request events. We never want to bond (we only read info), so we
    # auto-reject these. Each event's params begin with the 6-byte address + a
    # 1-byte address type, which is exactly the negative-reply command payload.
    EV_PIN_CODE_REQUEST     = 0x000E
    EV_USER_CONFIRM_REQUEST = 0x000F
    EV_USER_PASSKEY_REQUEST = 0x0010

    # mgmt Add/Remove Device address types (NB: these differ from the LE
    # advertising report codes - here 0x00 is BR/EDR, not LE public).
    ADDR_TYPE_BREDR = 0x00
    LE_PUBLIC       = 0x01
    LE_RANDOM       = 0x02

    # Add Device action: auto-connect (kernel background-connects when the
    # device is next seen advertising).
    ACTION_AUTO_CONNECT = 0x02

    # Start Discovery "address type" bitmask: BR/EDR (bit0) + LE Public (bit1) +
    # LE Random (bit2). 0x07 discovers classic and LE.
    #
    # The kernel names the combinations: 0x01 BR/EDR only, 0x06 LE only (public +
    # random), 0x07 interleaved. Each requested transport must be ENABLED on the
    # controller or the whole command is rejected - see ensure_transports_enabled.
    ADDR_TYPE_ALL       = 0x07
    ADDR_TYPE_BREDR_BIT = 0x01
    LE_TYPE_BITS        = 0x06

    # Controller settings bits, as returned by Read Controller Information in
    # supported_settings / current_settings. Only the ones we act on are named as
    # constants; SETTING_NAMES below carries the rest for logging.
    SETTING_POWERED = 0x00000001
    SETTING_BREDR   = 0x00000080
    SETTING_LE      = 0x00000200

    # Every settings bit the kernel defines (mgmt.h MGMT_SETTING_*, bits 0-25),
    # so a logged mask is decoded in full.
    #
    # Naming all of them is not thoroughness for its own sake: enabling LE on a
    # DART moved current settings from 0x00000081 to 0x004c0281, because the
    # kernel brings up the LE-dependent settings with it (CIS central/peripheral
    # and LL privacy). A partial table printed that as "POWERED BREDR LE" and
    # silently dropped three set bits, which makes the log look like it decoded
    # the mask when it did not.
    SETTING_NAMES = {
      0x00000001 => "POWERED",
      0x00000002 => "CONNECTABLE",
      0x00000004 => "FAST_CONNECTABLE",
      0x00000008 => "DISCOVERABLE",
      0x00000010 => "BONDABLE",
      0x00000020 => "LINK_SECURITY",
      0x00000040 => "SSP",
      0x00000080 => "BREDR",
      0x00000100 => "HS",
      0x00000200 => "LE",
      0x00000400 => "ADVERTISING",
      0x00000800 => "SECURE_CONN",
      0x00001000 => "DEBUG_KEYS",
      0x00002000 => "PRIVACY",
      0x00004000 => "CONFIGURATION",
      0x00008000 => "STATIC_ADDRESS",
      0x00010000 => "PHY_CONFIGURATION",
      0x00020000 => "WIDEBAND_SPEECH",
      0x00040000 => "CIS_CENTRAL",
      0x00080000 => "CIS_PERIPHERAL",
      0x00100000 => "ISO_BROADCASTER",
      0x00200000 => "ISO_SYNC_RECEIVER",
      0x00400000 => "LL_PRIVACY",
      0x00800000 => "PAST_SENDER",
      0x01000000 => "PAST_RECEIVER",
      0x02000000 => "SCI"
    }.freeze

    # a subset of mgmt status codes (see mgmt.h).
    STATUS_SUCCESS       = 0x00
    STATUS_BUSY          = 0x0a
    STATUS_REJECTED      = 0x0b
    STATUS_NOT_POWERED   = 0x0f
    STATUS_INVALID_INDEX = 0x11
    STATUS_RFKILLED      = 0x12

    # Full mgmt status byte -> name map (mgmt.h MGMT_STATUS_*), used only to make
    # log lines self-describing. Two things worth knowing when reading these:
    #   * 0x0b REJECTED is the kernel's catch-all for "refused this request": it
    #     is what the HCI->mgmt table maps the rejected-security / pairing-not-
    #     allowed / insufficient-security family onto, AND what mgmt_errno_status
    #     maps an internal -EPERM onto. It does NOT mean our process lacks
    #     privileges (that would be 0x14 PERMISSION_DENIED).
    #   * 0x14 PERMISSION_DENIED is the actual "not allowed to do this" code.
    STATUS_NAMES = {
      0x00 => "SUCCESS",
      0x01 => "UNKNOWN_COMMAND",
      0x02 => "NOT_CONNECTED",
      0x03 => "FAILED",
      0x04 => "CONNECT_FAILED",
      0x05 => "AUTH_FAILED",
      0x06 => "NOT_PAIRED",
      0x07 => "NO_RESOURCES",
      0x08 => "TIMEOUT",
      0x09 => "ALREADY_CONNECTED",
      0x0a => "BUSY",
      0x0b => "REJECTED",
      0x0c => "NOT_SUPPORTED",
      0x0d => "INVALID_PARAMS",
      0x0e => "DISCONNECTED",
      0x0f => "NOT_POWERED",
      0x10 => "CANCELLED",
      0x11 => "INVALID_INDEX",
      0x12 => "RFKILLED",
      0x13 => "ALREADY_PAIRED",
      0x14 => "PERMISSION_DENIED"
    }.freeze

    # Render a status byte as "0x0b (REJECTED)" for logging. Unknown codes still
    # show the raw byte so nothing is lost.
    def self.status_label(status)
      format("0x%02x (%s)", status, STATUS_NAMES.fetch(status, "UNKNOWN"))
    end

    # statuses that mean the controller isn't ready to accept commands and that
    # an rfkill unblock/reset may be able to recover from.
    NOT_READY_STATUSES = [
      STATUS_NOT_POWERED,
      STATUS_INVALID_INDEX,
      STATUS_RFKILLED
    ].freeze

    # Start Discovery outcomes that mean discovery is NOT stopped - i.e. the thing
    # the caller asked for is already true.
    #
    # BUSY belongs here. start_discovery_internal (net/bluetooth/mgmt.c) answers
    # BUSY in exactly three situations: discovery.state != DISCOVERY_STOPPED, a
    # periodic inquiry is running, or discovery is paused. A powered-down
    # controller answers NOT_POWERED instead, and a transport we cannot scan on
    # answers NOT_SUPPORTED. So BUSY is the kernel saying "already discovering",
    # never "refused to discover" - it is the one status that PROVES the radio is
    # doing what we wanted.
    #
    # This matters because we also re-arm discovery from the reader thread. A
    # re-arm that lands in the window between a cycle's hci_reset and that cycle's
    # own start_discovery leaves the cycle asking for something already running,
    # and treating that as failure killed an otherwise healthy process - see
    # retry_start_discovery.
    #
    # The sub-cases where discovery is momentarily not on (a Stop still in flight,
    # a suspend-time pause) need no special handling: reaching DISCOVERY_STOPPED
    # emits Discovering=0, which re-arms, and rearm_watchdog covers a lost one.
    DISCOVERY_ON_STATUSES = [
      STATUS_SUCCESS,
      STATUS_BUSY
    ].freeze

    # Does this Start Discovery status mean discovery is running? See
    # DISCOVERY_ON_STATUSES for why BUSY counts.
    def self.discovery_on?(status)
      DISCOVERY_ON_STATUSES.include?(status)
    end

    # How long to wait for a command's completion event. Raised from 5s: a busy
    # controller answers more slowly, and a 47 hour run produced four commands that
    # timed out here, one of which took down a discovery cycle for 20s.
    DEFAULT_TIMEOUT = 6

    # how long to allow bin/rfkill-reset to run during recovery
    RFKILL_RESET_TIMEOUT = 45

    # how long the reader thread blocks in select before re-checking @running
    READER_POLL = 0.5

    # Minimum gap between reader-thread discovery re-arms.
    #
    # The kernel stops discovery on its own whenever it needs the radio to
    # establish a connection - that is the premise the whole connect design rests
    # on. Re-arming the instant we see Discovering=0 therefore fights the very
    # connection the kernel is trying to make: it stops discovery again, we re-arm
    # again, and an on-device capture showed exactly that, Discovering=0 followed
    # by Start Discovery within a millisecond, over and over.
    #
    # Rate limiting it keeps discovery continuous (its purpose) while leaving the
    # controller room to finish a connection, and bounds the damage however the
    # suppression state is reached.
    REARM_MIN_INTERVAL = 2.0

    # == Parameters
    #   hci_index :: controller index (the N in hciN), e.g. 0 for hci0
    #   socket    :: optional pre-opened socket, primarily for testing
    #
    # The control socket is opened lazily on first use (and transparently
    # reopened if it is ever found closed); the reader thread is started at the
    # same time. A single Mgmt instance is meant to be held open for the life of
    # the process and reused across many commands.
    def initialize(hci_index, socket: nil)
      @index          = hci_index
      @sock           = socket
      @io_mutex       = Mutex.new           # guards @sock (re)open/close
      @cmd_lock       = Mutex.new           # serializes commands (one in flight)
      @resp_mutex     = Mutex.new           # guards @pending_opcode / @response
      @resp_cv        = ConditionVariable.new
      @pending_opcode = nil
      @response       = nil
      @running        = false
      @reader_thread  = nil
      # Set by ensure_transports_enabled to the transports actually enabled on
      # this controller; nil means "not determined", which falls back to asking
      # for everything.
      @enabled_discovery_type  = nil
      @enabled_transport_names = nil
      @connection_events      = Queue.new
      @discovery_address_type = nil
      # Discovery is the default resting state. This flag, when set, tells the
      # reader thread NOT to re-arm discovery (a deliberate connect window);
      # start_discovery clears it, stop_discovery sets it.
      @discovery_suppressed   = false
      # Shutdown intent, set once by #stopping! and never cleared - unlike
      # @discovery_suppressed, which start_discovery clears. The reader thread
      # outlives the decision to stop (it has to, so the shutdown reset's own
      # command replies get delivered), so without this it answers the power-off's
      # Discovering=0 by starting discovery again on a controller we are in the
      # middle of shutting down.
      @stopping               = false
      # Scanning-uptime tracking: the fraction of wall-clock time the controller
      # is actually discovering (vs stopped for a connect/info window). Driven by
      # the kernel Discovering events (ground truth), accumulated in the reader
      # thread and read by the CUI. Starts "not discovering" at process start.
      @discovering       = false
      @discovering_since = Time.now
      @scan_on_time      = 0.0
      @scan_off_time     = 0.0
      # Re-arm bookkeeping (see REARM_MIN_INTERVAL). Counters are diagnostic:
      # rearm_skipped_count climbing means the controller is being asked to stop
      # discovery far more often than the rate limit allows us to answer, which is
      # the signature of a connect fighting the scan.
      @last_rearm_at      = nil
      @rearm_count        = 0
      @rearm_skipped_count = 0
      # re-arms the watchdog had to issue because no Discovering event did it -
      # see rearm_watchdog. Climbing means re-arms are being refused and lost.
      @rearm_watchdog_count = 0
      # what the kernel said about our fire-and-forget re-arms, which used to be
      # discarded unread - see record_unawaited_completion
      @rearm_ok_count     = 0
      @rearm_failed_count = 0
    end

    attr_reader :rearm_count, :rearm_skipped_count, :rearm_watchdog_count,
                :rearm_ok_count, :rearm_failed_count

    # True when the controller is currently discovering, per the kernel's own
    # Discovering events rather than what we last asked for.
    def discovering?
      @discovering
    end

    # How long discovery has been continuously OFF, in seconds, or 0.0 when it is
    # on. Ground truth from the kernel's Discovering events.
    #
    # This is what the discovery-off budget should be measured against. A caller
    # timing its own phase cannot see time already spent with discovery off by an
    # earlier phase, and that undercounting is how a 6s budget produced a 35s
    # window on device.
    def discovery_off_for
      return 0.0 if @discovering
      Time.now - @discovering_since
    end

    # Percentage (0-100) of wall-clock time the controller has been discovering
    # since this Mgmt was created. Includes the in-progress interval so it stays
    # current between Discovering events.
    def scanning_percentage
      now     = Time.now
      elapsed = now - @discovering_since
      on      = @scan_on_time  + (@discovering ? elapsed : 0.0)
      off     = @scan_off_time + (@discovering ? 0.0 : elapsed)
      total   = on + off
      return 0.0 if total <= 0
      (on / total) * 100.0
    end

    # Read the controller's own Bluetooth address via mgmt Read Controller
    # Information. Returns an uppercase colon-separated MAC or nil.
    def read_address
      response = exec_command(CMD_READ_CONTROLLER_INFO)
      _command, status = self.class.command_result(response)
      return nil unless status == STATUS_SUCCESS
      self.class.parse_address(response[3, 6])
    end

    # [supported_settings, current_settings] from Read Controller Information, or
    # nil if the command failed.
    #
    # Response layout after the 2-byte opcode and 1-byte status: bdaddr(6),
    # version(1), manufacturer(2), supported_settings(4), current_settings(4).
    def read_settings
      response = exec_command(CMD_READ_CONTROLLER_INFO)
      _command, status = self.class.command_result(response)
      return nil unless status == STATUS_SUCCESS
      return nil unless response.bytesize >= 20
      [response[12, 4].unpack1("V"), response[16, 4].unpack1("V")]
    end

    # Render a settings bitmask as "0x000000c1 (POWERED BREDR LE)".
    def self.settings_label(settings)
      names = SETTING_NAMES.select { |bit, _name| (settings & bit) != 0 }.values
      format("0x%08x (%s)", settings, names.empty? ? "none" : names.join(" "))
    end

    # Enable/disable the LE transport (mgmt Set LE). Returns the status byte.
    def set_le(enable)
      status_of(exec_command(CMD_SET_LE, [enable ? 0x01 : 0x00].pack("C")))
    end

    # Enable/disable the BR/EDR transport (mgmt Set BR/EDR). Returns the status
    # byte. NB the kernel refuses this while LE is disabled, which is why
    # ensure_transports_enabled does LE first.
    def set_bredr(enable)
      status_of(exec_command(CMD_SET_BREDR, [enable ? 0x01 : 0x00].pack("C")))
    end

    # Turn on every transport the controller supports but currently has disabled,
    # then settle on a discovery type covering only what is actually enabled.
    #
    # Why this exists: Start Discovery's type is checked against the ENABLED
    # transports, not the supported ones. Asking for interleaved (BR/EDR + LE)
    # while either is disabled fails the whole command with REJECTED - not a
    # partial success - so one disabled transport takes down all discovery. A
    # production DART showed exactly this: supported BREDR+LE, current BREDR only,
    # and every Start Discovery answered 0x0b REJECTED, which also meant no LE
    # work of any kind could run there.
    #
    # LE is enabled before BR/EDR because the kernel rejects Set BR/EDR while LE
    # is off (a dual-mode controller is not allowed to be BR/EDR-only through this
    # interface).
    #
    # The two transports do not behave the same way, which was measured on a DART
    # rather than assumed:
    #   LE    Set while powered succeeds and the flag takes immediately
    #         (0x00000081 -> 0x004c0281, the kernel bringing up the LE-dependent
    #         settings with it).
    #   BREDR Set while powered answers 0x0b REJECTED in both directions, so it
    #         needs the radio down - see enable_powered_down.
    #
    # Returns the discovery address-type mask to use, and caches it for
    # start_discovery and the reader thread's re-arm.
    def ensure_transports_enabled
      supported, current = read_settings
      if supported.nil?
        BlueHydra.logger.error("mgmt: could not read controller settings on #{device}")
        return @enabled_discovery_type = nil
      end

      BlueHydra.logger.info("mgmt: #{device} supported settings #{self.class.settings_label(supported)}")
      BlueHydra.logger.info("mgmt: #{device} current settings   #{self.class.settings_label(current)}")

      attempted = {}
      attempted[:le] = enable_transport(:le, SETTING_LE, supported, current) { |on| set_le(on) }
      # BR/EDR is the one that needs the radio down - see enable_powered_down.
      attempted[:bredr] = enable_transport(:bredr, SETTING_BREDR, supported, current,
                                          powered_down_retry: true) { |on| set_bredr(on) }

      # Re-read rather than assume: a Set that reported success can still leave the
      # flag clear, and the whole point is to ask only for what is really enabled.
      _supported, current = read_settings
      if current.nil?
        # A failed re-read is NOT the same as "nothing is enabled". Treating it as
        # zero would claim both transports are dead on a controller that is in fact
        # scanning happily: two bogus WARN events, and a CUI reading "NO TRANSPORT
        # ENABLED" while devices stream in. Stay undetermined instead - discovery
        # falls back to asking for everything, which is what we did before any of
        # this existed.
        BlueHydra.logger.error("mgmt: could not re-read controller settings on #{device}, transports undetermined")
        return @enabled_discovery_type = nil
      end
      BlueHydra.logger.info("mgmt: #{device} settings after transport setup #{self.class.settings_label(current)}")

      @enabled_transport_names = enabled_transport_names(current)
      @enabled_discovery_type  = discovery_type_for(current)
      BlueHydra.logger.info(
        "mgmt: #{device} discovery type 0x%02x (%s)" %
        [@enabled_discovery_type, @enabled_transport_names.join("+")]
      )

      # Both transports are expected to work. Report each one that ends up
      # unusable exactly once, from the re-read rather than from what a Set
      # claimed, so the warning and its event describe the real end state.
      #
      # Last, so that a notification failure cannot cost us the discovery type we
      # just worked out - the rescue below would otherwise discard it.
      report_transport(:le, SETTING_LE, supported, current, attempted[:le])
      report_transport(:bredr, SETTING_BREDR, supported, current, attempted[:bredr])

      @enabled_discovery_type
    rescue => e
      # Best effort, like configure_no_pairing: fall back to the previous
      # behaviour of asking for everything rather than refusing to scan.
      BlueHydra.logger.error("mgmt: transport setup failed on #{device}: #{e.message}")
      @enabled_discovery_type = nil
    end

    # The discovery address-type mask to use: whatever ensure_transports_enabled
    # settled on, or everything if it never ran or could not tell.
    def discovery_type
      @enabled_discovery_type || ADDR_TYPE_ALL
    end

    # The transports actually enabled, e.g. ["BREDR", "LE"], or nil when
    # ensure_transports_enabled has not determined them. An EMPTY array is
    # meaningful and distinct from nil: the controller has neither transport on,
    # so nothing can be discovered. Read by the CUI to label what it is counting.
    def enabled_transports
      @enabled_transport_names
    end

    # Enable device discovery. The reader thread keeps it alive (re-issuing Start
    # Discovery whenever the kernel reports discovery stopped) until
    # stop_discovery is called. Returns the mgmt status byte.
    # Defaults to the transports actually enabled on this controller (see
    # ensure_transports_enabled) rather than unconditionally asking for both.
    def start_discovery(address_type = nil)
      address_type ||= discovery_type
      @discovery_address_type = address_type
      @discovery_suppressed   = false
      status_of(exec_command(CMD_START_DISCOVERY, [address_type].pack("C")))
    end

    # Disable device discovery (and stop the reader auto-restarting it). Returns
    # the mgmt status byte.
    # The type must match what discovery was STARTED with - the kernel answers
    # INVALID_PARAMS when it does not - so this defaults to the same derived type.
    def stop_discovery(address_type = nil)
      address_type ||= @discovery_address_type || discovery_type
      @discovery_suppressed = true
      status_of(exec_command(CMD_STOP_DISCOVERY, [address_type].pack("C")))
    end

    # Power the controller on/off via mgmt Set Powered. Returns status byte.
    def set_powered(powered)
      status_of(exec_command(CMD_SET_POWERED, [powered ? 0x01 : 0x00].pack("C")))
    end

    # Add a device to the controller's auto-connect list (mgmt Add Device).
    # Returns the mgmt status byte.
    def add_device(address, address_type, action = ACTION_AUTO_CONNECT)
      params = self.class.pack_address(address) + [address_type, action].pack("CC")
      status_of(exec_command(CMD_ADD_DEVICE, params))
    end

    # Remove a device from the auto-connect list (mgmt Remove Device). Returns
    # the mgmt status byte.
    def remove_device(address, address_type)
      params = self.class.pack_address(address) + [address_type].pack("C")
      status_of(exec_command(CMD_REMOVE_DEVICE, params))
    end

    # Set whether the controller will bond (mgmt Set Bondable). Returns status.
    def set_bondable(bondable)
      status_of(exec_command(CMD_SET_BONDABLE, [bondable ? 0x01 : 0x00].pack("C")))
    end

    # Set the controller's IO capability (mgmt Set IO Capability). Returns status.
    def set_io_capability(capability = IO_CAP_NO_INPUT_NO_OUTPUT)
      status_of(exec_command(CMD_SET_IO_CAPABILITY, [capability].pack("C")))
    end

    # Configure the controller so info/reachability connects never bond or
    # prompt for a PIN/passkey: non-bondable + NoInputNoOutput IO capability.
    # These are stored controller settings that persist across power cycles, so
    # this only needs to run once at startup. Best effort - a failure degrades
    # pairing suppression but must never block discovery. Combined with the
    # reader thread auto-rejecting pairing-request events (dispatch_event), no
    # bond is ever formed and nothing blocks on a prompt.
    def configure_no_pairing
      status = set_bondable(false)
      BlueHydra.logger.warn("mgmt: set_bondable(off) status #{self.class.status_label(status)}") unless status == STATUS_SUCCESS
      status = set_io_capability(IO_CAP_NO_INPUT_NO_OUTPUT)
      BlueHydra.logger.warn("mgmt: set_io_capability(NoInputNoOutput) status #{self.class.status_label(status)}") unless status == STATUS_SUCCESS
    rescue => e
      BlueHydra.logger.error("mgmt: configure_no_pairing failed: #{e.message}")
    end

    # Declare that we are shutting down: stop re-arming discovery.
    #
    # Called before the shutdown reset, not by #close, because the gap between the
    # two is the whole problem. #close cannot carry this - the reader thread must
    # still be alive through the shutdown reset to deliver its command replies, so
    # by the time #close runs the unwanted re-arms have already happened. Observed
    # on device: a Set Powered(off) during Runner#stop, answered 17ms later with
    # "kernel stopped discovery, restarting to keep scanning continuous", then a
    # watchdog re-arm 2s after that.
    #
    # One-way on purpose. There is no resume, and a flag that could be cleared
    # would eventually be cleared by start_discovery.
    def stopping!
      @stopping = true
    end

    # Stop the reader thread and close the control socket.
    def close
      @running = false
      thread = @reader_thread
      thread.join(READER_POLL * 4) if thread && thread != Thread.current
      @reader_thread = nil
      @io_mutex.synchronize do
        @sock.close if @sock && !@sock.closed?
      end
    end

    # ------------------------------------------------------------------
    # framing helpers (pure / no I/O, so they are easy to unit test)
    # ------------------------------------------------------------------

    # Encode a mgmt packet (command or event): header + params.
    def self.encode_packet(opcode, index, params = "")
      [opcode, index, params.bytesize].pack("S<S<S<") + params.b
    end

    # Decode a mgmt packet into [opcode/event, index, params].
    def self.decode_packet(bytes)
      bytes = bytes.b
      opcode, index, len = bytes[0, 6].unpack("S<S<S<")
      [opcode, index, bytes[6, len]]
    end

    # Extract [command_opcode, status] from a Command Complete / Command Status
    # event's parameters.
    def self.command_result(params)
      params.b.unpack("S<C") # command opcode (__le16), status (__u8)
    end

    # True when +address+ is an "identity address" as the kernel defines it, and
    # therefore usable with Add Device.
    #
    # Mirrors hci_is_identity_address (include/net/bluetooth/hci_core.h):
    #
    #   if (addr_type == ADDR_LE_DEV_PUBLIC)     return true;
    #   if ((addr->b[5] & 0xc0) == 0xc0)         return true;   /* random STATIC */
    #   return false;
    #
    # add_device guards on this before touching the connection parameters ("Add
    # Device allows only identity addresses") and answers INVALID_PARAMS for
    # anything else. That rejects both resolvable private addresses (top two bits
    # 01) and non-resolvable ones (top two bits 00) - which is most privacy-
    # enabled LE hardware, so calling Add Device for them is a guaranteed-failed
    # round-trip. Those devices need a direct connect instead (BlueHydra::
    # LeConnect); the kernel's own connect path has no such restriction.
    #
    # b[5] is the most significant byte, i.e. the FIRST octet of the printed MAC.
    def self.identity_address?(address, address_type)
      return true  if address_type == LE_PUBLIC
      return false unless address_type == LE_RANDOM
      msb = address.to_s.split(":").first.to_i(16)
      (msb & 0xc0) == 0xc0
    end

    # Render a 6 byte little-endian BD_ADDR into an uppercase big-endian MAC
    # string, or nil if the bytes are the wrong size.
    def self.parse_address(bytes)
      return nil unless bytes && bytes.bytesize == 6
      bytes.b.bytes.reverse.map { |byte| format("%02X", byte) }.join(":")
    end

    # Pack a MAC string ("AA:BB:CC:DD:EE:FF") into a 6 byte little-endian
    # BD_ADDR (inverse of parse_address).
    def self.pack_address(mac)
      mac.split(":").reverse.map { |hex| hex.to_i(16) }.pack("C*")
    end

    private

    # Issue a command and return the raw Command Complete/Status parameters
    # (command opcode + status + any response data). Handles rfkill recovery on
    # a not-ready status (one retry) and one socket-reopen retry on I/O error.
    def exec_command(opcode, params = "")
      response = send_and_wait(opcode, params)
      return response unless NOT_READY_STATUSES.include?(status_of(response))

      BlueHydra.logger.warn(
        format("mgmt: %s not ready (status %s), attempting rfkill recovery", device, self.class.status_label(status_of(response)))
      )
      raise BluezNotReadyError unless rfkill_recover

      response = send_and_wait(opcode, params)
      raise BluezNotReadyError if NOT_READY_STATUSES.include?(status_of(response))
      response
    end

    # Ensure the socket/reader are up, send the command, and block until the
    # reader thread delivers the matching completion. On a socket error, reopen
    # once and retry; a second failure emits one event and raises.
    def send_and_wait(opcode, params)
      attempts = 0
      begin
        ensure_running
        deliver_command(opcode, params)
      rescue IOError, SystemCallError => e
        attempts += 1
        if attempts > 1
          socket_error_event(e)
          raise MgmtSocketError, "mgmt control socket error on #{device}: #{e.message}"
        end
        BlueHydra.logger.warn("mgmt: control socket error on #{device} (#{e.message}), reopening")
        reopen
        retry
      end
    end

    def status_of(response)
      self.class.command_result(response)[1]
    end

    # Send +opcode+ and wait (up to DEFAULT_TIMEOUT) for the reader thread to
    # hand back the matching Command Complete/Status params. Only one command is
    # in flight at a time (@cmd_lock).
    def deliver_command(opcode, params)
      @cmd_lock.synchronize do
        @resp_mutex.synchronize do
          @pending_opcode = opcode
          @response       = nil
        end

        begin
          send_command(opcode, params)

          deadline = Time.now + DEFAULT_TIMEOUT
          result   = nil
          @resp_mutex.synchronize do
            while @response.nil?
              remaining = deadline - Time.now
              raise Timeout::Error, format("mgmt: timed out awaiting reply to opcode 0x%04x", opcode) if remaining <= 0
              @resp_cv.wait(@resp_mutex, remaining)
            end
            result = @response
          end
          result
        ensure
          # never leave a stale pending command for the reader to match against
          @resp_mutex.synchronize do
            @pending_opcode = nil
            @response       = nil
          end
        end
      end
    end

    # ------------------------------------------------------------------
    # reader thread: the sole reader of the control socket
    # ------------------------------------------------------------------

    def ensure_running
      @io_mutex.synchronize do
        @sock = open_socket if @sock.nil? || @sock.closed?
        unless @reader_thread && @reader_thread.alive?
          @running       = true
          @reader_thread = Thread.new { reader_loop }
        end
      end
    end

    def reader_loop
      while @running
        sock = @sock
        break unless sock
        begin
          ready = IO.select([sock], nil, nil, READER_POLL)
          data  = ready ? sock.recv(4096) : nil
        rescue IOError, SystemCallError
          # socket was closed/reopened under us - pick up the new one next pass
          sleep 0.05
          next
        end

        if data && !data.empty?
          begin
            handle_packet(data)
          rescue => e
            BlueHydra.logger.error("mgmt reader: #{e.message}")
          end
        end

        # Deliberately OUTSIDE the "did we get data" branch, and reached on a bare
        # select timeout too: the whole point is to act when nothing is arriving.
        begin
          rearm_watchdog
        rescue => e
          BlueHydra.logger.error("mgmt reader watchdog: #{e.message}")
        end
      end
    end

    # Safety net for a discovery re-arm that was lost.
    #
    # restart_discovery is fire-and-forget: its Command Complete arrives with no
    # pending command registered and is dropped, so a refused Start Discovery
    # vanishes silently. That would still recover if anything retried - but
    # re-arming is driven by the Discovering=0 EVENT, and discovery is already off
    # by then, so no further event arrives and nothing tries again. Discovery stays
    # off until the next cycle issues its own Start Discovery.
    #
    # Measured on a 47 hour run: 530 discovery-off windows ran over 20s, and 384 of
    # them opened immediately after a re-arm attempt, clustering at 20-30s against
    # a 30s discovery_time. REARM_MIN_INTERVAL did not cause that, but it did
    # expose it - before the rate limit the re-arm thrash fired many times a
    # second, which accidentally retried the lost attempts. Trading the thrash for
    # one attempt per stop traded it for silent outages.
    #
    # So re-arm on a timer as well as on the event. This covers every way discovery
    # can end up off when it should be on, not just a refused command.
    def rearm_watchdog
      return unless rearm_discovery?           # shutting down, or a connect window
      return if @discovering                   # already scanning
      return if @discovery_address_type.nil?   # never started, nothing to restore
      return if discovery_off_for < REARM_MIN_INTERVAL

      # Gate on the same interval restart_discovery enforces, so the watchdog never
      # burns a rate-limited call. Without this it would fire every READER_POLL and
      # inflate rearm_skipped_count, which exists to signal a connect fighting the
      # scan and would stop meaning that.
      return if @last_rearm_at && (Time.now - @last_rearm_at) < REARM_MIN_INTERVAL

      @rearm_watchdog_count += 1
      BlueHydra.logger.debug(
        "mgmt: discovery off %.1fs with no stop pending, re-arming (watchdog)" % discovery_off_for
      )
      restart_discovery
    end

    # Route one packet: command replies go to a waiting caller, everything else
    # is an unsolicited kernel event.
    def handle_packet(data)
      event, _index, params = self.class.decode_packet(data)
      unless event == EV_CMD_COMPLETE || event == EV_CMD_STATUS
        dispatch_event(event, params)
        return
      end

      cmd_opcode, status = self.class.command_result(params)
      delivered = false
      @resp_mutex.synchronize do
        if @pending_opcode && cmd_opcode == @pending_opcode
          @response = params
          @resp_cv.signal
          delivered = true
        end
      end
      return if delivered

      # Nobody was waiting for this one. Report it instead of dropping it: the
      # only command we deliberately fire and forget is the discovery re-arm, so
      # this is the single place the kernel ever tells us whether a re-arm was
      # accepted. Logged outside the mutex - nothing that blocks belongs in there.
      record_unawaited_completion(cmd_opcode, status)
    end

    # Status of a completion no caller was waiting for.
    #
    # restart_discovery cannot wait for its own reply: the reader thread is what
    # delivers replies, so blocking here would deadlock. The consequence was that
    # a refused re-arm was invisible - the reason a lost re-arm could leave
    # discovery off for tens of seconds with nothing in the log to say why (see
    # rearm_watchdog). Every re-arm outcome is now logged with its decoded status
    # and a running tally, so "what is the re-arm actually returning" is a grep
    # rather than an inference.
    #
    # Scoped to Start Discovery because that is the only fire-and-forget command;
    # anything else arriving unawaited is a late reply to a timed-out call and is
    # still dropped silently.
    def record_unawaited_completion(cmd_opcode, status)
      return unless cmd_opcode == CMD_START_DISCOVERY

      # BUSY counts as accepted, not refused: it means discovery was already on,
      # so this re-arm was merely redundant. The refused tally exists to say "the
      # watchdog is the only thing keeping discovery alive", and filing a BUSY
      # there would raise that alarm for the one answer that rules it out.
      if self.class.discovery_on?(status)
        @rearm_ok_count += 1
      else
        @rearm_failed_count += 1
      end

      BlueHydra.logger.debug(
        "mgmt: discovery re-arm returned #{self.class.status_label(status)} " \
        "(accepted #{@rearm_ok_count}, refused #{@rearm_failed_count})"
      )
    end

    # React to unsolicited kernel events: keep discovery alive (unless
    # suppressed) and forward connection lifecycle events to the discovery
    # thread via @connection_events. This must never raise (it runs on the
    # reader thread) and must not touch the runner's auto-connect state.
    def dispatch_event(event, params)
      case event
      when EV_DISCOVERING
        _addr_type, discovering = params.b.unpack("CC")
        record_discovering_transition(discovering == 1)
        if discovering == 0 && rearm_discovery?
          BlueHydra.logger.debug("mgmt: kernel stopped discovery, restarting to keep scanning continuous")
          restart_discovery
        end
      when EV_DEVICE_CONNECTED, EV_DEVICE_DISCONNECTED, EV_CONNECT_FAILED
        address = self.class.parse_address(params.b[0, 6])
        return unless address # drop undecodable events without disrupting the reader
        @connection_events << { type: connection_event_type(event), address: address }
      when EV_PIN_CODE_REQUEST
        reject_pairing(CMD_PIN_CODE_NEG_REPLY, params)
      when EV_USER_CONFIRM_REQUEST
        reject_pairing(CMD_USER_CONFIRM_NEG_REPLY, params)
      when EV_USER_PASSKEY_REQUEST
        reject_pairing(CMD_USER_PASSKEY_NEG_REPLY, params)
      end
    end

    # Auto-reject a pairing request from the reader thread. The event params
    # begin with a 6-byte address + 1-byte address type (mgmt_addr_info), which
    # is exactly the negative-reply command payload. Fire-and-forget like the
    # discovery restart (its Command Complete comes back with no pending command
    # and is dropped). Must never raise out of the reader loop.
    def reject_pairing(neg_reply_opcode, params)
      addr_info = params.b[0, 7]
      return unless addr_info && addr_info.bytesize == 7
      BlueHydra.logger.debug("mgmt: rejecting pairing for #{self.class.parse_address(addr_info[0, 6])}")
      send_command(neg_reply_opcode, addr_info)
    rescue => e
      BlueHydra.logger.error("mgmt: failed to reject pairing request: #{e.message}")
    end

    # Map a connection-lifecycle event code to its symbol.
    def connection_event_type(event)
      case event
      when EV_DEVICE_CONNECTED    then :connected
      when EV_DEVICE_DISCONNECTED then :disconnected
      when EV_CONNECT_FAILED      then :failed
      end
    end

    # Enable one transport if the controller supports it but has it switched off.
    # No-op when unsupported (nothing we can do) or already on.
    #
    # powered_down_retry: retry the Set with the radio powered down if it is
    # refused while powered. Only BR/EDR needs this; see enable_powered_down.
    #
    # Returns true if an enable was attempted. Whether it WORKED is not decided
    # here - report_transport settles that from a fresh read of the settings, so
    # nothing is reported on the strength of a Set's own status.
    def enable_transport(name, bit, supported, current, powered_down_retry: false, &setter)
      return false if (supported & bit).zero?  # unsupported, reported later
      return false if (current & bit) != 0     # already enabled

      BlueHydra.logger.info("mgmt: #{device} has #{name.to_s.upcase} supported but disabled, enabling")
      status = setter.call(true)
      if status == STATUS_SUCCESS
        BlueHydra.logger.info("mgmt: #{device} #{name.to_s.upcase} enabled")
        return true
      end

      retry_powered_down = powered_down_retry && status == STATUS_REJECTED &&
                           (current & SETTING_POWERED) != 0
      unless retry_powered_down
        BlueHydra.logger.warn(
          "mgmt: #{device} #{name.to_s.upcase} enable refused (status #{self.class.status_label(status)})"
        )
        return true
      end

      BlueHydra.logger.info(
        "mgmt: #{device} #{name.to_s.upcase} enable refused while powered (status " \
        "#{self.class.status_label(status)}), retrying with the radio down"
      )
      enable_powered_down(name, &setter)
      true
    end

    # Report a transport that is not usable. Both BR/EDR and LE are expected to
    # work, so either one missing is worth a warning and a notification (Pulse
    # and Stream Builder, each when enabled) rather than only a log line: it
    # halves what the sensor can see and is invisible in the device data itself.
    #
    # Says nothing when the transport is enabled - including the ordinary case of
    # having enabled it ourselves, which enable_transport already logged at info.
    def report_transport(name, bit, supported, current, attempted)
      return if (current & bit) != 0 # usable, nothing to report

      label = name.to_s.upcase
      if (supported & bit).zero?
        key     = 'blue_hydra_transport_unsupported'
        title   = "Blue Hydra #{label} Not Supported"
        message = "#{device} does not support #{label}, so no #{label} devices can be discovered"
      else
        key   = 'blue_hydra_transport_disabled'
        title = "Blue Hydra #{label} Disabled"
        message = if attempted
                    "#{device} has #{label} supported but disabled and it could not be enabled, " \
                    "so no #{label} devices can be discovered"
                  else
                    "#{device} has #{label} disabled and no enable was attempted, " \
                    "so no #{label} devices can be discovered"
                  end
      end

      BlueHydra.logger.warn("mgmt: #{message}")
      BlueHydra.send_event('blue_hydra',
        {key: key,
        title: title,
        message: message,
        severity: 'WARN'
        })
    end

    # Enable a transport the kernel refuses to change on a live radio.
    #
    # Verified on a DART: Set BR/EDR on a powered controller answers 0x0b
    # REJECTED, both directions. The flag is only writable with the controller
    # powered down, so that is the only way to bring BR/EDR up on a unit that has
    # it capable but off. LE has no such restriction - the same DART enabled LE
    # while powered and the flag took immediately - so this is BR/EDR only rather
    # than a blanket retry.
    #
    # Power-cycling here is in keeping with the rest of the runner: hci_reset
    # already power-cycles the controller before every discovery round.
    def enable_powered_down(name)
      BlueHydra.logger.info("mgmt: #{device} retrying #{name.to_s.upcase} enable with the radio powered down")
      status = set_powered(false)
      unless status == STATUS_SUCCESS
        BlueHydra.logger.error(
          "mgmt: #{device} could not power down to enable #{name.to_s.upcase} (status #{self.class.status_label(status)})"
        )
        return
      end

      begin
        status = yield(true)
        if status == STATUS_SUCCESS
          BlueHydra.logger.info("mgmt: #{device} #{name.to_s.upcase} enabled with the radio down")
        else
          BlueHydra.logger.error(
            "mgmt: #{device} could not enable #{name.to_s.upcase} powered down either (status #{self.class.status_label(status)})"
          )
        end
      ensure
        # Always bring the radio back up, whatever the Set did. Leaving it down
        # would take the unit off the air entirely, which is far worse than the
        # missing transport we came here to fix.
        status = set_powered(true)
        unless status == STATUS_SUCCESS
          BlueHydra.logger.error(
            "mgmt: #{device} FAILED to power back up after enabling #{name.to_s.upcase} (status #{self.class.status_label(status)})"
          )
        end
      end
    end

    # Map enabled transports to a Start Discovery type. The kernel's own naming:
    # BR/EDR only is 0x01, LE only is 0x06 (public + random), and 0x07 is
    # interleaved. Asking for a transport that is not enabled is rejected outright,
    # so only enabled ones go in.
    def discovery_type_for(current)
      type = 0
      type |= ADDR_TYPE_BREDR_BIT if (current & SETTING_BREDR) != 0
      type |= LE_TYPE_BITS        if (current & SETTING_LE)    != 0

      if type.zero?
        # Nothing to scan with. Keep asking for everything so the failure is loud
        # and attributable rather than silently doing nothing.
        BlueHydra.logger.error("mgmt: #{device} has no usable transport enabled, discovery will fail")
        return ADDR_TYPE_ALL
      end
      type
    end

    def enabled_transport_names(current)
      names = []
      names << "BREDR" if (current & SETTING_BREDR) != 0
      names << "LE"    if (current & SETTING_LE)    != 0
      names
    end

    # Fold the elapsed time since the last Discovering transition into the
    # on/off accumulators, then record the new state. Called from the reader
    # thread on every Discovering event.
    def record_discovering_transition(now_on)
      now     = Time.now
      elapsed = now - @discovering_since
      if @discovering
        @scan_on_time  += elapsed
      else
        @scan_off_time += elapsed
      end
      @discovering       = now_on
      @discovering_since = now
    end

    # Re-arm discovery from the reader thread. This MUST be fire-and-forget: the
    # reader thread is what delivers command replies, so it cannot block on the
    # normal command path. The resulting completion comes back to this loop with
    # no pending command registered and is dropped. Skipped while a command is
    # in flight to avoid completion ambiguity (we'll catch the next off event).
    # Should the reader thread put discovery back when it finds it off?
    #
    # Both re-arm paths ask this one question - the Discovering=0 event and
    # rearm_watchdog - so a new reason not to re-arm cannot be taught to one and
    # missed by the other. That is how the watchdog shipped without knowing about
    # shutdown while the event path did not know either.
    #
    # Asked BEFORE the callers log or count anything, so the debug line and the
    # watchdog tally describe re-arms that were actually attempted.
    def rearm_discovery?
      return false if @stopping               # shutting down; leave the radio alone
      return false if @discovery_suppressed   # a deliberate connect window
      true
    end

    def restart_discovery
      # Also checked here, at the single point that actually sends, so a future
      # caller that forgets the predicate above still cannot re-arm during
      # shutdown.
      return if @stopping
      return if @pending_opcode

      # Rate limited so a connect in progress is not fought to a standstill - see
      # REARM_MIN_INTERVAL. Skipping is safe: the kernel emits Discovering=0 for
      # every stop, so the next one past the interval re-arms.
      now = Time.now
      if @last_rearm_at && (now - @last_rearm_at) < REARM_MIN_INTERVAL
        @rearm_skipped_count += 1
        return
      end
      @last_rearm_at = now
      @rearm_count  += 1

      send_command(CMD_START_DISCOVERY, [@discovery_address_type || discovery_type].pack("C"))
    rescue => e
      BlueHydra.logger.error("mgmt: failed to restart discovery: #{e.message}")
    end

    def reopen
      @io_mutex.synchronize do
        @sock.close if @sock && !@sock.closed?
        @sock = open_socket
      end
    end

    def open_socket
      sock = Socket.new(AF_BLUETOOTH, Socket::SOCK_RAW, BTPROTO_HCI)
      # struct sockaddr_hci { __u16 family; __u16 dev; __u16 channel; }
      sock.bind([AF_BLUETOOTH, HCI_DEV_NONE, HCI_CHANNEL_CONTROL].pack("S!S!S!"))
      sock
    end

    def send_command(opcode, params)
      sock = @sock
      raise IOError, "mgmt control socket not open" if sock.nil? || sock.closed?
      sock.send(self.class.encode_packet(opcode, @index, params), 0)
    end

    # hciN device name for this controller index (used by rfkill).
    def device
      "hci#{@index}"
    end

    # Attempt to clear an rfkill (soft) block via bin/rfkill-reset. The script
    # prints nothing on success, so any output is treated as failure.
    def rfkill_recover
      command = "#{File.expand_path('../../../bin/rfkill-reset', __FILE__)} #{device}"
      output  = BlueHydra::Command.execute3(command, RFKILL_RESET_TIMEOUT)[:stdout] # no output == success
      if output && !output.empty?
        BlueHydra.logger.error("mgmt: rfkill recovery for #{device} failed: #{output}")
        return false
      end
      BlueHydra.logger.info("mgmt: rfkill recovery for #{device} completed")
      true
    end

    # Emit exactly one notification when the control socket is unrecoverable.
    def socket_error_event(error)
      BlueHydra.logger.error("mgmt: control socket unrecoverable on #{device} (#{error.message})")
      BlueHydra.send_event('blue_hydra',
        {key: 'blue_hydra_mgmt_socket_error',
        title: 'Blue Hydra mgmt Control Socket Error',
        message: "mgmt control socket error on #{device}: #{error.message}",
        severity: 'ERROR'
        })
    end
  end
end
