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
    ADDR_TYPE_ALL = 0x07

    # a subset of mgmt status codes (see mgmt.h).
    STATUS_SUCCESS       = 0x00
    STATUS_BUSY          = 0x0a
    STATUS_NOT_POWERED   = 0x0f
    STATUS_INVALID_INDEX = 0x11
    STATUS_RFKILLED      = 0x12

    # statuses that mean the controller isn't ready to accept commands and that
    # an rfkill unblock/reset may be able to recover from.
    NOT_READY_STATUSES = [
      STATUS_NOT_POWERED,
      STATUS_INVALID_INDEX,
      STATUS_RFKILLED
    ].freeze

    # how long to wait for a command's completion event
    DEFAULT_TIMEOUT = 5

    # how long to allow bin/rfkill-reset to run during recovery
    RFKILL_RESET_TIMEOUT = 45

    # how long the reader thread blocks in select before re-checking @running
    READER_POLL = 0.5

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
      @connection_events      = Queue.new
      @discovery_address_type = nil
      # Discovery is the default resting state. This flag, when set, tells the
      # reader thread NOT to re-arm discovery (a deliberate connect window);
      # start_discovery clears it, stop_discovery sets it.
      @discovery_suppressed   = false
      # Scanning-uptime tracking: the fraction of wall-clock time the controller
      # is actually discovering (vs stopped for a connect/info window). Driven by
      # the kernel Discovering events (ground truth), accumulated in the reader
      # thread and read by the CUI. Starts "not discovering" at process start.
      @discovering       = false
      @discovering_since = Time.now
      @scan_on_time      = 0.0
      @scan_off_time     = 0.0
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

    # Enable device discovery. The reader thread keeps it alive (re-issuing Start
    # Discovery whenever the kernel reports discovery stopped) until
    # stop_discovery is called. Returns the mgmt status byte.
    def start_discovery(address_type = ADDR_TYPE_ALL)
      @discovery_address_type = address_type
      @discovery_suppressed   = false
      status_of(exec_command(CMD_START_DISCOVERY, [address_type].pack("C")))
    end

    # Disable device discovery (and stop the reader auto-restarting it). Returns
    # the mgmt status byte.
    def stop_discovery(address_type = ADDR_TYPE_ALL)
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
      BlueHydra.logger.warn("mgmt: set_bondable(off) status 0x%02x" % status) unless status == STATUS_SUCCESS
      status = set_io_capability(IO_CAP_NO_INPUT_NO_OUTPUT)
      BlueHydra.logger.warn("mgmt: set_io_capability(NoInputNoOutput) status 0x%02x" % status) unless status == STATUS_SUCCESS
    rescue => e
      BlueHydra.logger.error("mgmt: configure_no_pairing failed: #{e.message}")
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
        format("mgmt: %s not ready (status 0x%02x), attempting rfkill recovery", device, status_of(response))
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
          next unless IO.select([sock], nil, nil, READER_POLL)
          data = sock.recv(4096)
        rescue IOError, SystemCallError
          # socket was closed/reopened under us - pick up the new one next pass
          sleep 0.05
          next
        end
        next if data.nil? || data.empty?
        begin
          handle_packet(data)
        rescue => e
          BlueHydra.logger.error("mgmt reader: #{e.message}")
        end
      end
    end

    # Route one packet: command replies go to a waiting caller, everything else
    # is an unsolicited kernel event.
    def handle_packet(data)
      event, _index, params = self.class.decode_packet(data)
      if event == EV_CMD_COMPLETE || event == EV_CMD_STATUS
        cmd_opcode, _status = self.class.command_result(params)
        @resp_mutex.synchronize do
          if @pending_opcode && cmd_opcode == @pending_opcode
            @response = params
            @resp_cv.signal
          end
          # else: unsolicited/late completion (e.g. our own discovery restart) - drop
        end
      else
        dispatch_event(event, params)
      end
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
        if discovering == 0 && !@discovery_suppressed
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
    def restart_discovery
      return if @pending_opcode
      send_command(CMD_START_DISCOVERY, [@discovery_address_type || ADDR_TYPE_ALL].pack("C"))
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
