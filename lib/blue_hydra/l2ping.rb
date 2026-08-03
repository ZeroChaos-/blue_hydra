require 'socket'

module BlueHydra
  # Native, in-process replacement for the external `l2ping` subprocess. It
  # opens a raw kernel L2CAP socket and connects to a classic BD_ADDR to page
  # the device and raise the ACL link as a reachability test - WITHOUT sending
  # any L2CAP echo requests (their responses are not needed; the link coming up
  # is the proof of reachability). It returns as soon as reachability is known
  # and always closes the socket.
  #
  # Classic devices cannot be reached through the mgmt API (they do not
  # advertise, so mgmt Add Device auto-connect is LE-only, and the only mgmt
  # outbound-classic primitive, Pair Device, bonds the device). An L2CAP socket
  # connect is the simplest non-bonding way to page a classic device. This is
  # the data channel, not the mgmt control channel, so it deliberately lives in
  # its own class rather than on BlueHydra::Mgmt.
  class L2Ping
    BTPROTO_L2CAP   = 0
    # PSM to target. SDP (0x0001) is near-universal on classic devices; even if
    # the peer refuses the PSM the ACL link still came up during paging, so a
    # refusal still proves reachability.
    SDP_PSM         = 0x0001
    # mgmt/L2CAP BR/EDR address type for the sockaddr_l2 bdaddr_type field.
    ADDR_TYPE_BREDR = 0x00
    # default bounded connect timeout (seconds)
    DEFAULT_CONNECT_TIMEOUT = 4

    # connect outcomes a raised ACL link implies the device is present for
    AF_BLUETOOTH = BlueHydra::Mgmt::AF_BLUETOOTH

    # errors that mean the device answered paging (reachable). A refused PSM
    # still means the ACL link came up.
    REACHABLE_ERRORS   = [Errno::ECONNREFUSED, Errno::EISCONN].freeze
    # errors that mean paging did not complete (device not reachable).
    UNREACHABLE_ERRORS = [
      Errno::EHOSTDOWN, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::ECONNABORTED
    ].freeze

    def initialize(hci_index, connect_timeout: DEFAULT_CONNECT_TIMEOUT)
      @index           = hci_index
      @connect_timeout = connect_timeout
    end

    # Probe a classic address. Returns :reachable, :unreachable, or :error.
    def reach?(address)
      sock = open_socket
      attempt_connect(sock, sockaddr(address))
    rescue IOError, SystemCallError => e
      BlueHydra.logger.debug("l2ping probe error for #{address}: #{e.message}")
      :error
    ensure
      sock.close if sock && !sock.closed?
    end

    private

    # Non-blocking connect. connect_nonblock raises IO::WaitWritable while the
    # ACL page is in flight; we then wait (bounded) and re-check.
    def attempt_connect(sock, addr)
      sock.connect_nonblock(addr)
      :reachable
    rescue IO::WaitWritable
      return :unreachable unless wait_writable(sock)
      finish_connect(sock, addr)
    rescue *REACHABLE_ERRORS
      :reachable
    rescue *UNREACHABLE_ERRORS
      :unreachable
    end

    # Complete a non-blocking connect once the socket is writable. Re-issuing
    # connect_nonblock reports the final result (EISCONN once connected).
    def finish_connect(sock, addr)
      sock.connect_nonblock(addr)
      :reachable
    rescue *REACHABLE_ERRORS
      :reachable
    rescue *UNREACHABLE_ERRORS
      :unreachable
    end

    # Wait (bounded by @connect_timeout) for the connect to complete. Returns
    # true if the socket became writable, false on timeout. Extracted so it can
    # be stubbed in unit tests.
    def wait_writable(sock)
      !IO.select(nil, [sock], nil, @connect_timeout).nil?
    end

    # Extracted so unit tests can inject a fake socket.
    def open_socket
      Socket.new(AF_BLUETOOTH, Socket::SOCK_SEQPACKET, BTPROTO_L2CAP)
    end

    # struct sockaddr_l2 { family; psm; bdaddr[6]; cid; bdaddr_type }.
    # Native packing is correct on the little-endian sensor (matches the
    # sockaddr_hci packing in BlueHydra::Mgmt).
    def sockaddr(address)
      [AF_BLUETOOTH, SDP_PSM, BlueHydra::Mgmt.pack_address(address), 0, ADDR_TYPE_BREDR]
        .pack("S!S!a6S!C")
    end
  end
end
