require 'socket'
require 'thread'

module BlueHydra
  # Dedicated raw-HCI client whose sole job is to systematically read the remote
  # version of LE connections.
  #
  # The kernel mgmt auto-connect path (BlueHydra::Mgmt Add Device) interrogates
  # LE *features* but never issues Read Remote Version Information for LE links -
  # only classic ACLs are auto-interrogated by the kernel. As a result LE
  # devices never get an LMP version and show "BTLE" instead of "LEx.x". mgmt
  # has no "read remote version" primitive, so we reach past it with a raw HCI
  # command socket.
  #
  # A single dedicated reader thread owns a raw HCI socket (HCI_CHANNEL_RAW) for
  # the life of the process. It watches for LE (Enhanced) Connection Complete
  # events and, the instant it sees a new connection handle, issues Read Remote
  # Version Information for that handle - reaching the controller inside the
  # brief window the kernel holds the link open for its own feature read. We do
  # not consume the reply here: the resulting Read Remote Version Complete is
  # captured by the existing btmon -> parser pipeline (LMP version -> VERS
  # column), exactly like the classic version reads.
  #
  # The socket is opened lazily by the reader thread and transparently reopened
  # if it is ever closed/errors, mirroring how BlueHydra::Mgmt manages its
  # control socket. Sending is fire-and-forget - we never block waiting on a
  # reply, to stay as close to real time as possible.
  class HciCommand
    # socket constants (AF_BLUETOOTH is not exposed as a Socket:: const). The raw
    # channel (0) binds to a specific controller index and, unlike the control
    # channel, both receives HCI events and lets us inject HCI commands.
    AF_BLUETOOTH    = 31
    BTPROTO_HCI     = 1
    HCI_CHANNEL_RAW = 0

    # setsockopt to install the receive filter (struct hci_filter):
    #   __u32 type_mask; __u32 event_mask[2]; __u16 opcode;
    SOL_HCI       = 0
    HCI_FILTER    = 2
    HCI_EVENT_PKT = 0x04   # packet type byte prefixed on received event packets
    HCI_COMMAND_PKT = 0x01 # packet type byte we prefix on commands we send

    # HCI event code + LE meta subevents we care about
    EVT_LE_META                    = 0x3e
    SUB_LE_CONNECTION_COMPLETE     = 0x01
    SUB_LE_ENH_CONNECTION_COMPLETE = 0x0a

    # Read Remote Version Information: OGF 0x01 (Link Control), OCF 0x001D.
    # Wire opcode is (OGF << 10) | OCF = 0x041D. Its one parameter is the 2-byte
    # connection handle (12 significant bits).
    OPCODE_READ_REMOTE_VERSION = 0x041D
    HANDLE_MASK                = 0x0fff

    # how long the reader thread blocks in select before re-checking @running
    READER_POLL = 0.5

    # backoff after a failed (re)open so we don't spin on a missing adapter
    REOPEN_BACKOFF = 0.5

    # == Parameters
    #   hci_index :: controller index (the N in hciN), e.g. 0 for hci0
    #   socket    :: optional pre-opened socket, primarily for testing
    def initialize(hci_index, socket: nil)
      @index         = hci_index
      @sock          = socket
      @io_mutex      = Mutex.new
      @running       = false
      @reader_thread = nil
    end

    # Launch the dedicated reader thread. The socket itself is opened (and
    # reopened on error) inside the reader loop, so a controller that is not yet
    # ready never blocks or crashes the caller - the loop just retries.
    def start
      @io_mutex.synchronize do
        unless @reader_thread && @reader_thread.alive?
          @running       = true
          @reader_thread = Thread.new { reader_loop }
        end
      end
    end

    # Stop the reader thread and close the socket.
    def close
      @running = false
      thread = @reader_thread
      thread.join(READER_POLL * 4) if thread && thread != Thread.current
      @reader_thread = nil
      close_socket
    end

    # Issue Read Remote Version Information for a connection handle. Fire and
    # forget - the completion arrives asynchronously as an HCI event that btmon
    # captures and the parser turns into lmp_version.
    def read_remote_version(handle)
      send_command(OPCODE_READ_REMOTE_VERSION, [handle & HANDLE_MASK].pack("S<"))
    end

    # hciN device name for this controller index.
    def device
      "hci#{@index}"
    end

    # Encode a raw HCI command packet: packet-type byte + opcode(__le16) +
    # parameter length(__u8) + parameters.
    def self.encode_command(opcode, params = "")
      [HCI_COMMAND_PKT, opcode, params.bytesize].pack("CS<C") + params.b
    end

    # Parse an LE connection handle out of a raw HCI event packet, or nil if the
    # packet is not a successful LE (Enhanced) Connection Complete. Layout (after
    # the leading packet-type byte): [1]=event code, [2]=param len, [3]=subevent,
    # [4]=status, [5..6]=handle (both connection-complete variants share this).
    def self.le_connection_handle(bytes)
      bytes = bytes.b
      return nil if bytes.bytesize < 7
      return nil unless bytes.getbyte(0) == HCI_EVENT_PKT
      return nil unless bytes.getbyte(1) == EVT_LE_META
      sub = bytes.getbyte(3)
      return nil unless sub == SUB_LE_CONNECTION_COMPLETE || sub == SUB_LE_ENH_CONNECTION_COMPLETE
      return nil unless bytes.getbyte(4) == 0x00 # status success
      bytes[5, 2].unpack1("S<") & HANDLE_MASK
    end

    private

    # React to one received packet: if it announces a new LE connection, fire a
    # version read for its handle. Never raises out to the reader loop.
    def handle_packet(data)
      handle = self.class.le_connection_handle(data)
      return unless handle
      BlueHydra.logger.debug("hci: LE connection handle 0x%04x up, reading remote version" % handle)
      read_remote_version(handle)
    rescue => e
      BlueHydra.logger.error("hci: failed handling LE connection event: #{e.message}")
    end

    def reader_loop
      while @running
        sock = ensure_socket_open
        unless sock
          sleep REOPEN_BACKOFF
          next
        end
        begin
          next unless IO.select([sock], nil, nil, READER_POLL)
          data = sock.recv(1024)
        rescue IOError, SystemCallError => e
          next unless @running
          BlueHydra.logger.warn("hci: raw socket error on #{device} (#{e.message}), reopening")
          close_socket
          next
        end
        next if data.nil? || data.empty?
        handle_packet(data)
      end
    end

    # Open the raw socket if needed; returns the socket or nil on failure (the
    # reader loop backs off and retries). Single owner (reader thread), guarded
    # by @io_mutex against close.
    def ensure_socket_open
      @io_mutex.synchronize do
        if @sock.nil? || @sock.closed?
          begin
            @sock = open_socket
          rescue => e
            BlueHydra.logger.error("hci: cannot open raw socket on #{device}: #{e.message}")
            @sock = nil
          end
        end
        @sock
      end
    end

    def close_socket
      @io_mutex.synchronize do
        @sock.close if @sock && !@sock.closed?
        @sock = nil
      end
    end

    def open_socket
      sock = Socket.new(AF_BLUETOOTH, Socket::SOCK_RAW, BTPROTO_HCI)
      # Bind FIRST. The HCI_FILTER socket option is only valid once the socket is
      # bound to the RAW channel; setting it on an unbound socket returns EINVAL.
      # struct sockaddr_hci { __u16 family; __u16 dev; __u16 channel; }
      begin
        sock.bind([AF_BLUETOOTH, @index, HCI_CHANNEL_RAW].pack("S!S!S!"))
      rescue => e
        sock.close rescue nil
        raise "bind(#{device}, RAW) failed: #{e.class}: #{e.message}"
      end
      # Install the receive filter (HCI event packets, every event code). Report
      # the failing syscall distinctly so a filter problem is not confused with
      # a bind problem in the logs.
      begin
        sock.setsockopt(SOL_HCI, HCI_FILTER, self.class.event_filter)
      rescue => e
        sock.close rescue nil
        raise "setsockopt(HCI_FILTER) on #{device} failed: #{e.class}: #{e.message}"
      end
      sock
    end

    # The receive filter as a full 16-byte struct hci_filter, matching what
    # hcitool sends byte-for-byte:
    #   __u32 type_mask; __u32 event_mask[2]; __u16 opcode; (+ 2 pad bytes)
    # type_mask selects HCI event packets; both event_mask words are all-ones so
    # every event is delivered (LE Meta is event 0x3e = 62, in the second word).
    # The kernel copies sizeof(struct hci_filter) = 16 bytes, so we send exactly
    # 16 rather than the 14 bytes of packed fields.
    def self.event_filter
      [1 << HCI_EVENT_PKT, 0xffffffff, 0xffffffff, 0x0000].pack("VVVv") + "\x00\x00"
    end

    def send_command(opcode, params = "")
      sock = @sock
      raise IOError, "hci raw socket not open" if sock.nil? || sock.closed?
      sock.send(self.class.encode_command(opcode, params), 0)
    rescue IOError, SystemCallError => e
      # fire-and-forget: a send failure just means we missed this one read; the
      # reader loop will reopen the socket on its own next error/select pass.
      BlueHydra.logger.warn(format("hci: failed to send command 0x%04x on %s: %s", opcode, device, e.message))
    end
  end
end
