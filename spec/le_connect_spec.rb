require 'spec_helper'

describe BlueHydra::LeConnect do
  # link_hold 0 so tests never actually sleep holding a fake link
  let(:connector) { BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0) }
  let(:sock)      { instance_double("Socket") }

  before do
    allow(connector).to receive(:open_socket).and_return(sock)
    allow(sock).to receive(:closed?).and_return(false)
    allow(sock).to receive(:close)
    # guard: we only want the ACL, we must never write to the channel
    allow(sock).to receive(:write)
    allow(sock).to receive(:send)
  end

  # an IO::WaitWritable-flavoured exception like connect_nonblock raises while
  # the kernel is still scanning for the device
  def wait_writable_error
    err = Errno::EINPROGRESS.new
    err.extend(IO::WaitWritable)
    err
  end

  # what getsockopt(SOL_SOCKET, SO_ERROR) hands back: an object whose #int is the
  # raw errno, 0 meaning the connect succeeded
  def so_error(errno)
    instance_double("Socket::Option", int: errno)
  end

  describe "#connect" do
    it "reports :connected when the connect completes immediately" do
      allow(sock).to receive(:connect_nonblock).and_return(0)
      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
    end

    it "treats a refused PSM as :connected - the ACL came up, which is all we need" do
      allow(sock).to receive(:connect_nonblock).and_raise(Errno::ECONNREFUSED)
      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
    end

    it "reports :unreachable when the device never answers" do
      [Errno::EHOSTDOWN, Errno::ETIMEDOUT, Errno::EHOSTUNREACH].each do |error|
        allow(sock).to receive(:connect_nonblock).and_raise(error)
        expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:unreachable)
      end
    end

    it "reports :unreachable when the connect does not complete inside the timeout" do
      allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
      allow(connector).to receive(:wait_writable).and_return(false)
      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:unreachable)
    end

    # Once select says the socket is writable the attempt has resolved, and the
    # result is read from SO_ERROR. Calling connect a SECOND time is what produced
    # 112 unexplained EINVALs in a device run: an L2CAP channel that has been torn
    # down is SOCK_ZAPPED, and l2cap_sock_connect rejects a zapped socket at its
    # first check, before it looks at the address at all. EINVAL then says nothing
    # about whether the device answered.
    it "reads the deferred result from SO_ERROR instead of connecting again" do
      allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
      allow(connector).to receive(:wait_writable).and_return(true)
      allow(sock).to receive(:getsockopt).and_return(so_error(0))

      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
      expect(sock).to have_received(:getsockopt).with(Socket::SOL_SOCKET, Socket::SO_ERROR).once
      expect(sock).to have_received(:connect_nonblock).once
    end

    it "classifies a deferred result the same way as a raised one" do
      {
        0                          => :connected,
        Errno::ECONNREFUSED::Errno => :connected,   # ACL up, PSM refused
        Errno::EISCONN::Errno      => :connected,
        Errno::ETIMEDOUT::Errno    => :unreachable,
        Errno::EHOSTDOWN::Errno    => :unreachable,
        Errno::ECONNRESET::Errno   => :unreachable,
        Errno::ENOSYS::Errno       => :unreachable, # HCI 0x3e, see below
        Errno::EPERM::Errno        => :error        # genuinely unclassified
      }.each do |errno, expected|
        allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
        allow(connector).to receive(:wait_writable).and_return(true)
        allow(sock).to receive(:getsockopt).and_return(so_error(errno))

        expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM))
          .to eq(expected), "errno #{errno} should classify as #{expected}"
      end
    end

    # ENOSYS reads as "function not implemented" but on a connect it means the
    # peer never answered. bt_to_errno() has no entry for HCI 0x3e, "Connection
    # Failed to be Established", so it falls to that function's ENOSYS default -
    # and 0x3e is the ordinary outcome when a connect goes unanswered. A 47 hour
    # device run produced 243 of them, all filed as local errors.
    it "treats ENOSYS as unreachable, not as a local error" do
      allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
      allow(connector).to receive(:wait_writable).and_return(true)
      allow(sock).to receive(:getsockopt).and_return(so_error(Errno::ENOSYS::Errno))

      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:unreachable)
      expect(connector).not_to receive(:hold_link)
    end

    # The specific regression: EINVAL from a zapped channel must not be mistaken
    # for a device outcome, but it also must not be reported as a local error
    # after the attempt already resolved - SO_ERROR is read, so EINVAL from a
    # second connect never happens at all.
    it "never issues a second connect, so a zapped channel cannot report EINVAL" do
      allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
      allow(connector).to receive(:wait_writable).and_return(true)
      allow(sock).to receive(:getsockopt).and_return(so_error(Errno::ETIMEDOUT::Errno))

      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:unreachable)
      expect(sock).to have_received(:connect_nonblock).once
    end

    it "holds the link open only when it actually came up" do
      allow(sock).to receive(:connect_nonblock).and_return(0)
      expect(connector).to receive(:hold_link).once
      connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)

      allow(sock).to receive(:connect_nonblock).and_raise(Errno::EHOSTDOWN)
      expect(connector).not_to receive(:hold_link)
      connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)
    end

    it "always closes the socket, including on an unexpected error" do
      allow(sock).to receive(:connect_nonblock).and_raise(Errno::EBADF)
      expect(sock).to receive(:close)
      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:error)
    end

    it "never writes to the socket" do
      allow(sock).to receive(:connect_nonblock).and_return(0)
      connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)
      expect(sock).not_to have_received(:write)
      expect(sock).not_to have_received(:send)
    end

    it "packs the LE address type into the sockaddr, not the BR/EDR one" do
      captured = nil
      allow(sock).to receive(:connect_nonblock) { |addr| captured = addr; 0 }
      connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)
      # trailing byte of struct sockaddr_l2 is bdaddr_type
      expect(captured.bytes.last).to eq(BlueHydra::Mgmt::LE_RANDOM)
    end

    it "requests no PSM and no CID, so the kernel attempts no channel" do
      captured = nil
      allow(sock).to receive(:connect_nonblock) { |addr| captured = addr; 0 }
      connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)
      # struct sockaddr_l2 { family; psm; bdaddr[6]; cid; bdaddr_type }
      _family, psm, _bdaddr, cid, _type = captured.unpack("S!S!a6S!C")
      expect(psm).to eq(0)
      expect(cid).to eq(0)
    end

    it "uses a RAW L2CAP socket" do
      # a connection-oriented socket cannot select LE flow control unless it was
      # bound LE-side, and then fails on the LE link once it is up
      expect(Socket).to receive(:new).with(
        BlueHydra::Mgmt::AF_BLUETOOTH, Socket::SOCK_RAW, BlueHydra::LeConnect::BTPROTO_L2CAP
      ).and_return(sock)
      allow(sock).to receive(:connect_nonblock).and_return(0)

      fresh = BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0)
      expect(fresh.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
    end
  end

  describe "#connect_batch" do
    it "returns an empty result for no work" do
      expect(connector.connect_batch({})).to eq({})
      expect(connector.connect_batch(nil)).to eq({})
    end

    it "reports an outcome per address" do
      allow(connector).to receive(:connect) do |address, _type|
        address == "7A:00:00:00:00:01" ? :connected : :unreachable
      end

      # braces matter: connect_batch takes a keyword arg, so a bare hash here
      # would bind as keywords instead of the positional entries map
      results = connector.connect_batch({
        "7A:00:00:00:00:01" => BlueHydra::Mgmt::LE_RANDOM,
        "7A:00:00:00:00:02" => BlueHydra::Mgmt::LE_RANDOM
      })

      expect(results).to eq(
        "7A:00:00:00:00:01" => :connected,
        "7A:00:00:00:00:02" => :unreachable
      )
    end

    it "runs the whole batch concurrently rather than one device at a time" do
      size    = 8
      entries = {}
      size.times { |i| entries["7A:00:00:00:00:%02X" % i] = BlueHydra::Mgmt::LE_RANDOM }

      mutex   = Mutex.new
      current = 0
      peak    = 0

      allow(connector).to receive(:connect) do
        mutex.synchronize { current += 1; peak = current if current > peak }
        sleep 0.1 # stand in for waiting on the radio
        mutex.synchronize { current -= 1 }
        :connected
      end

      connector.connect_batch(entries)

      # serial execution would peak at 1; every device should be in flight at once
      expect(peak).to eq(size)
    end

    it "does not let one device's failure lose the rest of the batch" do
      allow(connector).to receive(:connect) do |address, _type|
        raise "boom" if address == "7A:00:00:00:00:02"
        :connected
      end
      allow(BlueHydra.logger).to receive(:error)

      results = connector.connect_batch({
        "7A:00:00:00:00:01" => BlueHydra::Mgmt::LE_RANDOM,
        "7A:00:00:00:00:02" => BlueHydra::Mgmt::LE_RANDOM,
        "7A:00:00:00:00:03" => BlueHydra::Mgmt::LE_RANDOM
      })

      expect(results["7A:00:00:00:00:01"]).to eq(:connected)
      expect(results["7A:00:00:00:00:03"]).to eq(:connected)
      # and the one that blew up is still accounted for
      expect(results["7A:00:00:00:00:02"]).to eq(:error)
    end

    it "stops at the deadline and reports the stragglers as :abandoned" do
      # one device answers immediately, the rest would outlast the deadline
      allow(connector).to receive(:connect) do |address, _type|
        sleep 5 unless address == "7A:00:00:00:00:01"
        :connected
      end

      started = Time.now
      results = connector.connect_batch(
        { "7A:00:00:00:00:01" => BlueHydra::Mgmt::LE_RANDOM,
          "7A:00:00:00:00:02" => BlueHydra::Mgmt::LE_RANDOM,
          "7A:00:00:00:00:03" => BlueHydra::Mgmt::LE_RANDOM },
        Time.now + 0.5
      )
      elapsed = Time.now - started

      expect(results["7A:00:00:00:00:01"]).to eq(:connected)
      expect(results["7A:00:00:00:00:02"]).to eq(:abandoned)
      expect(results["7A:00:00:00:00:03"]).to eq(:abandoned)
      # the whole point: we return on the deadline, not after the slow connects
      expect(elapsed).to be < 3
    end

    it "accounts for every device it was handed, even when abandoning" do
      allow(connector).to receive(:connect) { sleep 5 }
      entries = {}
      6.times { |i| entries["7A:00:00:00:00:%02X" % i] = BlueHydra::Mgmt::LE_RANDOM }

      results = connector.connect_batch(entries, Time.now + 0.2)

      expect(results.keys.sort).to eq(entries.keys.sort)
      expect(results.values.uniq).to eq([:abandoned])
    end

    it "kills abandoned threads so no socket outlives the batch" do
      before = Thread.list.size
      allow(connector).to receive(:connect) { sleep 5 }
      entries = {}
      4.times { |i| entries["7A:00:00:00:00:%02X" % i] = BlueHydra::Mgmt::LE_RANDOM }

      connector.connect_batch(entries, Time.now + 0.2)

      expect(Thread.list.size).to eq(before)
    end

    it "waits for everything when given no deadline" do
      allow(connector).to receive(:connect).and_return(:connected)
      results = connector.connect_batch({ "7A:00:00:00:00:01" => BlueHydra::Mgmt::LE_RANDOM })
      expect(results).to eq("7A:00:00:00:00:01" => :connected)
    end

    it "leaves no thread running after it returns" do
      before = Thread.list.size
      allow(connector).to receive(:connect).and_return(:connected)

      entries = {}
      5.times { |i| entries["7A:00:00:00:00:%02X" % i] = BlueHydra::Mgmt::LE_RANDOM }
      connector.connect_batch(entries)

      # a leaked thread would hold a socket, and thus a live ACL, into the next
      # scan window
      expect(Thread.list.size).to eq(before)
    end
  end
end
