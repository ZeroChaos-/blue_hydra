require 'spec_helper'
require 'open3'
require 'tmpdir'

# bin/rfkill-reset is the shell-out behind BlueHydra::Mgmt#rfkill_recover,
# which treats any stdout as failure. These examples run the real script as a
# child process through its own `#!/bin/sh` shebang (so whatever /bin/sh is on
# this host runs it) with a fake `rfkill` first on PATH that records every
# argv it is called with and answers `list` with canned util-linux output.
#
# The script's first guard exits 2 unless /dev/rfkill is a character device,
# which a build host does not have (and creating one needs root). So the
# examples run a copy of the script with ONLY that guard block removed; the
# rfkill lookup, index lookup, rfkill_check, rfkill_reset, rfkill_unblock and
# the case dispatch all run as written. The copy is made by an exact textual
# match on the guard, and the example fails if that text is not found, so a
# future edit to the guard cannot leave these examples running a stale stub.
# The "rfkill not supported" example runs the unmodified script as the control
# that the guard really is what stands between this host and the rest of it.
describe "bin/rfkill-reset" do
  let(:script)        { File.expand_path('../../bin/rfkill-reset', __FILE__) }
  let(:device)        { "hci0" }
  let(:child_timeout) { 30 }

  # must match bin/rfkill-reset byte for byte (single-quoted heredoc: the \n
  # inside printf stays a literal backslash-n, as in the script)
  let(:dev_rfkill_guard) do
    <<~'GUARD'
      if [ ! -c /dev/rfkill ]; then
        printf "rfkill not supported\n"
        exit 2
      fi
    GUARD
  end

  around do |example|
    Dir.mktmpdir("bh-rfkill") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:fake_bin) { File.join(@dir, "bin") }
  let(:argv_log) { File.join(@dir, "rfkill-argv.log") }

  # util-linux `rfkill list` output for one device
  def rfkill_list(index: 0, name: "hci0", type: "Bluetooth", soft: "no", hard: "no")
    "#{index}: #{name}: #{type}\n\tSoft blocked: #{soft}\n\tHard blocked: #{hard}\n"
  end

  # Fake rfkill: logs "$*" per call, prints $RFKILL_FAKE_LIST for `list`, and
  # like the real binary refuses `block`/`unblock` without an identifier.
  def write_fake_rfkill
    Dir.mkdir(fake_bin)
    path = File.join(fake_bin, "rfkill")
    File.write(path, <<~'SH')
      #!/bin/sh
      printf '%s\n' "$*" >> "$RFKILL_FAKE_LOG"
      case "$1" in
        list)
          printf '%s' "$RFKILL_FAKE_LIST"
          ;;
        block|unblock)
          if [ -z "$2" ]; then
            printf "Try 'rfkill --help' for more information.\n" >&2
            exit 1
          fi
          ;;
        *)
          printf 'rfkill: unknown command\n' >&2
          exit 1
          ;;
      esac
      exit 0
    SH
    File.chmod(0755, path)
  end

  # Copy of bin/rfkill-reset with only the /dev/rfkill guard removed.
  def write_guardless_copy
    source = File.read(script)
    unless source.include?(dev_rfkill_guard)
      raise "bin/rfkill-reset no longer contains the expected /dev/rfkill guard block; " \
            "update dev_rfkill_guard in #{__FILE__} to match before trusting these examples:\n" \
            "#{dev_rfkill_guard}"
    end
    path = File.join(@dir, "rfkill-reset")
    File.write(path, source.sub(dev_rfkill_guard, ""))
    File.chmod(0755, path)
    path
  end

  # scoped with let so the spec does not define a top-level constant
  let(:run_class) { Struct.new(:stdout, :stderr, :status, :calls) }

  def run_script(path, list:)
    env = {
      "PATH"             => "#{fake_bin}:#{ENV['PATH']}",
      "RFKILL_FAKE_LOG"  => argv_log,
      "RFKILL_FAKE_LIST" => list
    }
    out = err = status = nil
    Open3.popen3(env, path, device) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless wait_thr.join(child_timeout)
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue Errno::ESRCH
        end
        wait_thr.join
        raise "#{path} #{device} did not exit within #{child_timeout}s:\n#{out_reader.value}#{err_reader.value}"
      end
      out    = out_reader.value
      err    = err_reader.value
      status = wait_thr.value
    end
    calls = File.exist?(argv_log) ? File.readlines(argv_log, chomp: true) : []
    run_class.new(out, err, status.exitstatus, calls)
  end

  before { write_fake_rfkill }

  context "with the /dev/rfkill guard removed" do
    let(:stub) { write_guardless_copy }

    it "blocks, then unblocks, the device's index when it is not blocked", :aggregate_failures do
      run = run_script(stub, list: rfkill_list(soft: "no", hard: "no"))

      expect(run.calls).to eq(["list", "list 0", "block 0", "unblock 0"])
      expect(run.stdout).to eq("")
      expect(run.status).to eq(0)
    end

    it "only unblocks when the device is soft blocked", :aggregate_failures do
      run = run_script(stub, list: rfkill_list(soft: "yes", hard: "no"))

      expect(run.calls).to eq(["list", "list 0", "unblock 0"])
      expect(run.calls.grep(/^block/)).to eq([])
      expect(run.stdout).to eq("")
      expect(run.status).to eq(0)
    end

    it "reports it cannot fix a hard block and touches nothing", :aggregate_failures do
      run = run_script(stub, list: rfkill_list(soft: "no", hard: "yes"))

      expect(run.stdout).to include("Unable to automagically fix")
      expect(run.calls).to eq(["list", "list 0"])
    end

    it "reports it cannot fix a device that is both soft and hard blocked", :aggregate_failures do
      run = run_script(stub, list: rfkill_list(soft: "yes", hard: "yes"))

      expect(run.stdout).to include("Unable to automagically fix")
      expect(run.calls).to eq(["list", "list 0"])
    end

    it "exits 187 without output when the device is not in `rfkill list`", :aggregate_failures do
      run = run_script(stub, list: rfkill_list(index: 1, name: "phy0", type: "Wireless LAN"))

      expect(run.status).to eq(187)
      expect(run.stdout).to eq("")
      expect(run.calls).to eq(["list"])
    end
  end

  # Negative control for the guard removal above: the unmodified script, same
  # fake rfkill on PATH, stops at the /dev/rfkill guard on this host.
  it "prints 'rfkill not supported' and exits 2 when /dev/rfkill is absent", :aggregate_failures do
    skip "/dev/rfkill exists on this host, so the guard passes here" if File.chardev?("/dev/rfkill")

    run = run_script(script, list: rfkill_list)

    expect(run.stdout).to eq("rfkill not supported\n")
    expect(run.status).to eq(2)
    expect(run.calls).to eq([])
  end
end
