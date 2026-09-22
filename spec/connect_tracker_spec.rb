require 'spec_helper'

describe BlueHydra::ConnectTracker do
  before do
    described_class.reset!
    BlueHydra.config["connect_to_nonconnectable"] = false
    allow(BlueHydra.logger).to receive(:debug)
  end

  after { described_class.reset! }

  let(:mac) { "7A:BB:CC:DD:EE:FF" }

  describe "connectability" do
    it "knows nothing about an address it has never seen" do
      expect(described_class.connectable(mac)).to be_nil
      expect(described_class.unconnectable?(mac)).to eq(false)
    end

    it "records a non-connectable advertisement" do
      described_class.record_connectable(mac, false)
      expect(described_class.connectable(mac)).to eq(false)
      expect(described_class.unconnectable?(mac)).to eq(true)
    end

    it "records a connectable advertisement" do
      described_class.record_connectable(mac, true)
      expect(described_class.connectable(mac)).to eq(true)
      expect(described_class.unconnectable?(mac)).to eq(false)
    end

    # A device advertising both ways is genuinely connectable; suppressing it
    # would lose real data. If it never actually connects the strike rule gets it.
    it "treats a device that advertises both ways as connectable" do
      described_class.record_connectable(mac, false)
      described_class.record_connectable(mac, true)
      expect(described_class.unconnectable?(mac)).to eq(false)

      described_class.reset!
      described_class.record_connectable(mac, true)   # other order, same answer
      described_class.record_connectable(mac, false)
      expect(described_class.unconnectable?(mac)).to eq(false)
    end

    # nil is "this advertisement had no opinion" (a scan response, a version
    # read), which must not be mistaken for "not connectable"
    it "ignores a nil observation rather than recording not-connectable" do
      described_class.record_connectable(mac, nil)
      expect(described_class.connectable(mac)).to be_nil
      expect(described_class.tracked_count).to eq(0)
    end
  end

  describe "strikes" do
    it "counts consecutive failures and strikes out at the limit" do
      expect(described_class.strike(mac)).to eq(1)
      expect(described_class.struck_out?(mac)).to eq(false)
      expect(described_class.strike(mac)).to eq(2)
      expect(described_class.struck_out?(mac)).to eq(false)
      expect(described_class.strike(mac)).to eq(3)
      expect(described_class.struck_out?(mac)).to eq(true)
    end

    it "is three strikes, not two or four" do
      expect(described_class::STRIKE_LIMIT).to eq(3)
    end

    # "in a row" is the whole point: a success in between must clear the streak
    it "resets the streak on a successful connect" do
      2.times { described_class.strike(mac) }
      described_class.success(mac)
      expect(described_class.strikes(mac)).to eq(0)
      expect(described_class.struck_out?(mac)).to eq(false)

      2.times { described_class.strike(mac) }
      expect(described_class.struck_out?(mac)).to eq(false) # 2 again, not 4
    end

    it "leaves connectability alone when a connect succeeds" do
      described_class.record_connectable(mac, true)
      described_class.strike(mac)
      described_class.success(mac)
      expect(described_class.connectable(mac)).to eq(true)
    end

    it "success on an untracked address is harmless" do
      expect { described_class.success(mac) }.not_to raise_error
      expect(described_class.tracked_count).to eq(0)
    end
  end

  # A failed connect must not cost the device the full info_scan_rate before the
  # next attempt - see FAILED_RETRY_INTERVAL and Runner#push_to_queue.
  describe "#retry_soon?" do
    it "is false for a device we have never failed on" do
      expect(described_class.retry_soon?(mac)).to eq(false)
    end

    it "is true mid-streak, with attempts still left" do
      described_class.strike(mac)
      expect(described_class.retry_soon?(mac)).to eq(true)
      described_class.strike(mac)
      expect(described_class.retry_soon?(mac)).to eq(true)
    end

    # once written off there is no point enqueueing work attempt? will refuse
    it "is false once the device has struck out" do
      3.times { described_class.strike(mac) }
      expect(described_class.retry_soon?(mac)).to eq(false)
    end

    it "is false again after a success resets the streak" do
      described_class.strike(mac)
      expect(described_class.retry_soon?(mac)).to eq(true)
      described_class.success(mac)
      expect(described_class.retry_soon?(mac)).to eq(false)
    end

    it "retries in seconds, not the info-scan cadence" do
      expect(described_class::FAILED_RETRY_INTERVAL).to be < 45 # the info_scan_rate floor
      expect(described_class::FAILED_RETRY_INTERVAL).to be > 0
    end
  end

  describe "#forget" do
    it "drops strikes and connectability together" do
      described_class.record_connectable(mac, false)
      3.times { described_class.strike(mac) }
      described_class.forget(mac)

      expect(described_class.strikes(mac)).to eq(0)
      expect(described_class.struck_out?(mac)).to eq(false)
      expect(described_class.connectable(mac)).to be_nil
      expect(described_class.tracked_count).to eq(0)
    end
  end

  describe "#attempt?" do
    it "attempts a device we know nothing about" do
      expect(described_class.attempt?(mac)).to eq(true)
    end

    it "attempts a device that advertises connectable" do
      described_class.record_connectable(mac, true)
      expect(described_class.attempt?(mac)).to eq(true)
    end

    it "skips a non-connectable device when the config is off" do
      described_class.record_connectable(mac, false)
      expect(described_class.attempt?(mac)).to eq(false)
      expect(described_class.nonconnectable_skipped).to eq(1)
    end

    it "attempts a non-connectable device when the config is on" do
      BlueHydra.config["connect_to_nonconnectable"] = true
      described_class.record_connectable(mac, false)
      expect(described_class.attempt?(mac)).to eq(true)
      expect(described_class.nonconnectable_skipped).to eq(0)
    end

    # the strike rule is unconditional - it applies to every device, including
    # ones that advertise as connectable and simply never answer
    it "skips a struck-out device even when it advertises connectable" do
      described_class.record_connectable(mac, true)
      3.times { described_class.strike(mac) }
      expect(described_class.attempt?(mac)).to eq(false)
      expect(described_class.struck_out_skipped).to eq(1)
    end

    it "skips a struck-out device even with connect_to_nonconnectable on" do
      BlueHydra.config["connect_to_nonconnectable"] = true
      3.times { described_class.strike(mac) }
      expect(described_class.attempt?(mac)).to eq(false)
    end

    it "attempts again after a success clears the strikes" do
      3.times { described_class.strike(mac) }
      expect(described_class.attempt?(mac)).to eq(false)
      described_class.success(mac)
      expect(described_class.attempt?(mac)).to eq(true)
    end

    it "attempts again after the device is forgotten (marked offline)" do
      3.times { described_class.strike(mac) }
      expect(described_class.attempt?(mac)).to eq(false)
      described_class.forget(mac)
      expect(described_class.attempt?(mac)).to eq(true)
    end
  end

  # result thread writes connectability and forgets; discovery thread strikes and
  # reads. Everything goes through one mutex, so hammering it must not corrupt
  # the counts or raise.
  it "survives concurrent access from several threads" do
    macs = (1..20).map { |i| format("7A:BB:CC:DD:EE:%02X", i) }
    threads = []
    threads << Thread.new { 200.times { macs.each { |m| described_class.strike(m) } } }
    threads << Thread.new { 200.times { macs.each { |m| described_class.record_connectable(m, true) } } }
    threads << Thread.new { 200.times { macs.each { |m| described_class.attempt?(m) } } }
    threads << Thread.new { 200.times { macs.each { |m| described_class.strikes(m) } } }
    expect { threads.each(&:join) }.not_to raise_error
    expect(described_class.tracked_count).to eq(20)
  end
end
