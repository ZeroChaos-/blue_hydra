require 'spec_helper'

describe BlueHydra::Command do
  it 'executes a shell command and returns a hash of output' do
    result = BlueHydra::Command.execute3("echo 'hello world'")
    expect(result[:exit_code]).to eq(0)
    expect(result[:stdout]).to eq("hello world")
    expect(result[:stderr]).to eq(nil)
  end

  it 'captures stderr separately' do
    result = BlueHydra::Command.execute3("echo 'oops' >&2")
    expect(result[:stdout]).to eq(nil)
    expect(result[:stderr]).to eq("oops")
  end

  it 'reports a non-zero exit code' do
    expect(BlueHydra::Command.execute3("exit 3")[:exit_code]).to eq(3)
  end

  it 'closes the command pipes rather than leaving them to the GC' do
    ios = []
    allow(Open3).to receive(:popen3).and_wrap_original do |original, *args|
      result = original.call(*args)
      ios = result[0, 3]
      result
    end

    BlueHydra::Command.execute3("echo done")

    expect(ios.map(&:closed?)).to eq([true, true, true])
  end

  # A timed command that finishes in time is not a timeout. The wait loop exits on
  # either condition, so this used to be logged for every command that completed.
  it 'does not report a timeout for a command that finished in time' do
    allow(BlueHydra.logger).to receive(:debug)
    BlueHydra::Command.execute3("echo quick", 10)
    expect(BlueHydra.logger).not_to have_received(:debug).with(/Timeout on command/)
  end

  it 'reports and kills a command that runs past its timeout' do
    allow(BlueHydra.logger).to receive(:debug)
    result = BlueHydra::Command.execute3("sleep 10", 1)
    expect(BlueHydra.logger).to have_received(:debug).with(/Timeout on command: sleep 10/)
    expect(result[:exit_code]).to be_nil # killed, so no exit status
  end

  # Running out of memory is not recoverable here, so it notifies and exits
  # rather than returning a result the caller would have to interpret.
  it 'notifies and exits when the system cannot allocate memory for a command' do
    allow(BlueHydra.logger).to receive(:fatal)
    allow(BlueHydra).to receive(:send_event)
    allow(Open3).to receive(:popen3).and_raise(Errno::ENOMEM)

    expect { BlueHydra::Command.execute3("echo hi") }.to raise_error(SystemExit)

    expect(BlueHydra).to have_received(:send_event).with(
      'blue_hydra', hash_including(key: 'blue_hydra_oom', severity: 'FATAL')
    )
  end
end

# Runner#stop kills the discovery and ubertooth threads wherever they happen to
# be, which is usually blocked reading a child's output. The child is not signalled
# by that, so before this it carried on holding the controller (hcitool info) or
# the USB radio (ubertooth-rx, up to its 60s timeout) after we had exited.
describe BlueHydra::Command, "child cleanup on an abandoned command" do
  # Capture the pid execute3 is about to work with, without reimplementing it.
  def spawn_in_thread(command)
    pid = nil
    thread = Thread.new do
      allow_pid = lambda { |p| pid = p }
      allow(Open3).to receive(:popen3).and_wrap_original do |original, *args|
        result = original.call(*args)
        allow_pid.call(result[3].pid)
        result
      end
      BlueHydra::Command.execute3(command)
    end
    # wait for the child to actually exist
    30.times { break if pid; sleep 0.1 }
    [thread, pid]
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  before { allow(BlueHydra.logger).to receive(:debug) }

  it 'kills the child when the calling thread is killed mid-command' do
    thread, pid = spawn_in_thread("sleep 30")
    expect(pid).not_to be_nil
    expect(alive?(pid)).to eq(true)

    thread.kill
    thread.join(BlueHydra::Command::CHILD_TERM_GRACE + 2)

    expect(alive?(pid)).to eq(false)
  ensure
    begin
      Process.kill("KILL", pid) if pid
    rescue Errno::ESRCH, Errno::EPERM
    end
  end

  it 'says which command it abandoned' do
    thread, pid = spawn_in_thread("sleep 30")
    thread.kill
    thread.join(BlueHydra::Command::CHILD_TERM_GRACE + 2)

    expect(BlueHydra.logger).to have_received(:debug)
      .with(/Abandoning command, terminating child: sleep 30/)
  ensure
    begin
      Process.kill("KILL", pid) if pid
    rescue Errno::ESRCH, Errno::EPERM
    end
  end

  # the normal path has already reaped the child, so cleanup must cost nothing and
  # must not claim it abandoned anything
  it 'stays quiet and does no work for a command that completed' do
    BlueHydra::Command.execute3("echo fine")
    expect(BlueHydra.logger).not_to have_received(:debug).with(/Abandoning command/)
  end

  it 'escalates to KILL for a child that ignores TERM' do
    thread, pid = spawn_in_thread("trap '' TERM; sleep 30")
    expect(alive?(pid)).to eq(true)

    thread.kill
    thread.join(BlueHydra::Command::CHILD_TERM_GRACE +
                BlueHydra::Command::CHILD_KILL_GRACE + 2)

    expect(alive?(pid)).to eq(false)
  ensure
    begin
      Process.kill("KILL", pid) if pid
    rescue Errno::ESRCH, Errno::EPERM
    end
  end

  # bounded on purpose: a shutdown that hangs waiting on a child is worse than a
  # child we failed to reap
  it 'bounds how long it waits' do
    expect(BlueHydra::Command::CHILD_TERM_GRACE).to be_between(1, 5)
    expect(BlueHydra::Command::CHILD_KILL_GRACE).to be_between(1, 5)
  end
end

describe "local adapter address enumeration (mgmt Read Controller Information)" do
  it "returns an array of at most one mac address" do
    begin
      result = BlueHydra::EnumLocalAddr.call
      expect(result).to be_an(Array)
      expect(result.count).to be <= 1
      if result.first
        expect(result.first).to match(/\A(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\z/)
      end
    rescue BluezNotReadyError, MgmtSocketError, SystemCallError, IOError
      # No usable Bluetooth adapter in the test environment; acceptable.
      expect(1).to eq(1)
    end
  end
end
