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
        Errno::EMLINK::Errno       => :conn_limit,  # HCI 0x09, our controller is full
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

  # EMLINK is the LOCAL controller out of LE connection slots: bt_to_errno maps
  # HCI 0x09 Connection Limit Exceeded onto it, and nothing else on the LE
  # connect path raises it. It says nothing about the device, so it gets its own
  # outcome - the Runner counts it as conn-limit and records no ConnectTracker
  # strike. Until it did, both routes below filed it as :error.
  describe "#connect at the controller's connection limit" do
    it "reports :conn_limit when connect_nonblock raises EMLINK" do
      allow(sock).to receive(:connect_nonblock).and_raise(Errno::EMLINK)
      expect(connector).not_to receive(:hold_link)

      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:conn_limit)
      expect(sock).to have_received(:close)
    end

    it "reports :conn_limit when EMLINK arrives via SO_ERROR, ahead of the unclassified fallback" do
      allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
      allow(connector).to receive(:wait_writable).and_return(true)
      allow(sock).to receive(:getsockopt).and_return(so_error(Errno::EMLINK::Errno))
      expect(connector).not_to receive(:hold_link)
      # the fallback is the only thing in classify_errno that logs
      allow(BlueHydra.logger).to receive(:debug)
      expect(BlueHydra.logger).not_to receive(:debug).with(/unclassified/)

      expect(connector.connect("7A:BB:CC:DD:EE:FF", BlueHydra::Mgmt::LE_RANDOM)).to eq(:conn_limit)
      expect(sock).to have_received(:close)
    end
  end

  describe "#gatt_scanner" do
    it "is nil unless one is injected - which is how gatt_scan false reaches this class" do
      expect(connector.gatt_scanner).to be_nil
    end

    it "exposes the injected scanner, so the Runner wiring can be checked" do
      scanner = instance_double("BlueHydra::GattScanner")
      wired   = BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0, gatt_scanner: scanner)
      expect(wired.gatt_scanner).to be(scanner)
    end
  end

  # The Direct_Connect_Path handoff. A Link that came up is handed to the
  # Gatt_Scanner BEFORE the hold, so the Walk's Att_Bearer connect lands while
  # our socket is still holding the Link up. The handoff is bookkeeping only, so
  # the hold, the close and the outcome must be exactly what they are with no
  # scanner at all - a Walk must never lengthen a direct-connect batch.
  describe "#connect handoff to the Gatt_Scanner" do
    let(:scanner) { instance_double("BlueHydra::GattScanner") }
    let(:connector) do
      BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0, gatt_scanner: scanner)
    end
    let(:address) { "7A:BB:CC:DD:EE:FF" }

    before { allow(scanner).to receive(:handoff) }

    it "hands off the address and the address type it connected with, tagged :direct" do
      allow(sock).to receive(:connect_nonblock).and_return(0)

      connector.connect(address, BlueHydra::Mgmt::LE_PUBLIC)

      expect(scanner).to have_received(:handoff)
        .with(address, BlueHydra::Mgmt::LE_PUBLIC, source: :direct).once
    end

    it "hands off after the connect resolves and before the hold begins" do
      order = []
      allow(sock).to receive(:connect_nonblock) { order << :connect; 0 }
      allow(scanner).to receive(:handoff)      { order << :handoff }
      allow(connector).to receive(:hold_link)  { order << :hold }

      connector.connect(address, BlueHydra::Mgmt::LE_RANDOM)

      expect(order).to eq([:connect, :handoff, :hold])
    end

    it "hands off on every route to :connected, not only the immediate one" do
      routes = {
        "immediate"             => -> { allow(sock).to receive(:connect_nonblock).and_return(0) },
        "ECONNREFUSED raised"   => -> { allow(sock).to receive(:connect_nonblock).and_raise(Errno::ECONNREFUSED) },
        "SO_ERROR 0"            => lambda do
          allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
          allow(connector).to receive(:wait_writable).and_return(true)
          allow(sock).to receive(:getsockopt).and_return(so_error(0))
        end,
        "SO_ERROR ECONNREFUSED" => lambda do
          allow(sock).to receive(:connect_nonblock).and_raise(wait_writable_error)
          allow(connector).to receive(:wait_writable).and_return(true)
          allow(sock).to receive(:getsockopt).and_return(so_error(Errno::ECONNREFUSED::Errno))
        end
      }

      handoffs = 0
      allow(scanner).to receive(:handoff) { handoffs += 1 }

      routes.each_with_index do |(route, arrange), i|
        arrange.call
        expect(connector.connect(address, BlueHydra::Mgmt::LE_RANDOM))
          .to eq(:connected), "#{route} should reach :connected"
        expect(handoffs).to eq(i + 1), "#{route} should hand off exactly once"
      end
    end

    it "makes no handoff for a Link that did not come up" do
      allow(sock).to receive(:connect_nonblock).and_raise(Errno::EHOSTDOWN)
      expect(connector.connect(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(:unreachable)

      allow(sock).to receive(:connect_nonblock).and_raise(Errno::EMLINK)
      expect(connector.connect(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(:conn_limit)

      expect(scanner).not_to have_received(:handoff)
    end

    # Requirements 2.2 and 3.8, checked by direct comparison: the same link_hold
    # slept and no longer, the socket closed once, the same outcome. sleep is
    # recorded rather than hold_link stubbed so the DURATION is what is compared.
    it "holds, closes and returns exactly as it does with no scanner" do
      allow(sock).to receive(:connect_nonblock).and_return(0)

      observe = lambda do |le_connect|
        slept = []
        allow(le_connect).to receive(:open_socket).and_return(sock)
        allow(le_connect).to receive(:sleep) { |seconds| slept << seconds }
        [le_connect.connect(address, BlueHydra::Mgmt::LE_RANDOM), slept]
      end

      without = observe.call(BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0.25))
      with    = observe.call(BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0.25,
                                                      gatt_scanner: scanner))

      expect(without).to eq([:connected, [0.25]])
      expect(with).to eq(without)
      expect(sock).to have_received(:close).twice
      expect(scanner).to have_received(:handoff).once
    end

    it "logs a scanner that raises and still holds, closes and returns :connected" do
      allow(sock).to receive(:connect_nonblock).and_return(0)
      allow(scanner).to receive(:handoff).and_raise(RuntimeError, "boom")
      allow(BlueHydra.logger).to receive(:error)
      expect(connector).to receive(:hold_link).once

      expect(connector.connect(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
      expect(sock).to have_received(:close)
      expect(BlueHydra.logger).to have_received(:error)
        .with("gatt: handoff for #{address} raised RuntimeError: boom")
    end

    # The rescue has to live in the handoff itself. #connect's own rescue maps
    # SystemCallError to :error and skips the hold, which would charge a scanner
    # fault to a Link that came up fine.
    it "does not let a scanner raising a SystemCallError turn the connect into :error" do
      allow(sock).to receive(:connect_nonblock).and_return(0)
      allow(scanner).to receive(:handoff).and_raise(Errno::EBADF)
      allow(BlueHydra.logger).to receive(:error)
      expect(connector).to receive(:hold_link).once

      expect(connector.connect(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
      expect(BlueHydra.logger).to have_received(:error).with(/gatt: handoff for #{address} raised Errno::EBADF/)
    end

    it "makes no call at all with gatt_scanner nil" do
      plain = BlueHydra::LeConnect.new(0, connect_timeout: 1, link_hold: 0)
      allow(plain).to receive(:open_socket).and_return(sock)
      allow(sock).to receive(:connect_nonblock).and_return(0)
      # a call on nil would raise NoMethodError into the handoff's rescue and be
      # logged there, so a silent connect is the proof that nothing was called
      expect(BlueHydra.logger).not_to receive(:error)

      expect(plain.connect(address, BlueHydra::Mgmt::LE_RANDOM)).to eq(:connected)
      expect(scanner).not_to have_received(:handoff)
    end

    it "hands off only the Links that came up in a mixed connect_batch" do
      up      = "7A:00:00:00:00:01"
      limited = "7A:00:00:00:00:02"
      allow(sock).to receive(:connect_nonblock) do |addr|
        # struct sockaddr_l2 { family; psm; bdaddr[6]; cid; bdaddr_type }
        _family, _psm, bdaddr, _cid, _type = addr.unpack("S!S!a6S!C")
        raise Errno::EMLINK if bdaddr == BlueHydra::Mgmt.pack_address(limited)
        0
      end

      results = connector.connect_batch({
        up      => BlueHydra::Mgmt::LE_RANDOM,
        limited => BlueHydra::Mgmt::LE_RANDOM
      })

      expect(results).to eq(up => :connected, limited => :conn_limit)
      expect(scanner).to have_received(:handoff).once
      expect(scanner).to have_received(:handoff).with(up, BlueHydra::Mgmt::LE_RANDOM, source: :direct)
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
