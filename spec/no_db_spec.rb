require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'json'

# lib/blue_hydra.rb chooses the database while `require 'blue_hydra'` runs, so
# --no-db only takes effect if bin/blue_hydra applies it before that require.
# An in-process spec cannot see this ordering: spec_helper sets BLUE_HYDRA=test,
# which selects the in-memory db by itself. So these examples run the real bin
# in a child process with BLUE_HYDRA unset, inside a scratch cwd (where the
# default on-disk db lands), with the root/hardware touch points stubbed by
# spec/support/bin_blue_hydra_harness.rb.
#
# The default-mode example is the positive control for the --no-db ones: it
# proves the same harness and cwd do produce, open and reuse blue_hydra.db, so
# "no file" in the --no-db examples is not a vacuous pass.
#
# The same holds for --pulse and --stream-builder: lib can send an event and
# exit while it is being required, so the MAC-read context checks that event
# reaches the service the flags select.
describe "bin/blue_hydra flags applied before require 'blue_hydra'" do
  let(:bin)           { File.expand_path('../../bin/blue_hydra', __FILE__) }
  let(:harness)       { File.expand_path('../support/bin_blue_hydra_harness.rb', __FILE__) }
  let(:memory_uri)    { "sqlite::memory:?cache=shared" }
  let(:child_timeout) { 60 }
  # the exact flags AnemoiBlueHydraImage's bluehydra-wrapper.sh runs with
  let(:anemoi_flags)  { %w[--daemonize --no-db --stream-builder] }

  around do |example|
    Dir.mktmpdir("bh-db-cwd") do |cwd|
      Dir.mktmpdir("bh-db-report") do |report_dir|
        @cwd        = cwd
        @report_dir = report_dir
        @runs       = 0
        example.run
      end
    end
  end

  def db_files_in_cwd
    Dir.glob(File.join(@cwd, "*.db*")).map { |f| File.basename(f) }
  end

  def basenames(files)
    files.map { |f| File.basename(f.is_a?(Hash) ? f["path"] : f) }
  end

  # Runs bin/blue_hydra up to Runner.new (or until it exits on its own) and
  # returns the harness report.
  def run_bin(*flags, env: {}, expect_status: 0)
    @runs += 1
    report_path = File.join(@report_dir, "report-#{@runs}.json")
    child_env   = { "BLUE_HYDRA" => nil, "BH_HARNESS_REPORT" => report_path }.merge(env)
    label       = "bin/blue_hydra #{flags.join(' ')}"

    output = status = nil
    Open3.popen2e(child_env, RbConfig.ruby, "-r", harness, bin, *flags, chdir: @cwd) do |stdin, out, wait_thr|
      stdin.close
      reader = Thread.new { out.read }
      unless wait_thr.join(child_timeout)
        begin
          Process.kill("KILL", wait_thr.pid)
        rescue Errno::ESRCH
        end
        wait_thr.join
        raise "#{label} did not exit within #{child_timeout}s:\n#{reader.value}"
      end
      output = reader.value
      status = wait_thr.value
    end

    unless status.exitstatus == expect_status && File.exist?(report_path)
      raise "#{label} exited #{status.exitstatus.inspect} (expected #{expect_status}), " \
            "report #{File.exist?(report_path) ? 'written' : 'missing'}:\n#{output}"
    end

    JSON.parse(File.read(report_path))
  end

  def setup_args(report)
    setups = report["events"].select { |e| e["event"] == "DataMapper.setup" }
    expect(setups.size).to eq(1)
    setups.first["args"]
  end

  def no_db_at_setup(report)
    report["events"].find { |e| e["event"] == "DataMapper.setup" }["no_db_at_setup"]
  end

  it "keeps the db in memory with the Anemoi wrapper's flags (--daemonize --no-db --stream-builder)" do
    report = run_bin(*anemoi_flags)

    expect(setup_args(report)).to eq(["default", memory_uri])
    expect(no_db_at_setup(report)).to eq(true)
    expect(report["adapter_path"]).to eq(":memory:")
    expect(report["open_db_files_after_save"]).to eq([])
    expect(basenames(report["db_files_in_cwd"])).to eq([])
    expect(basenames(report["db_files_after_save"])).to eq([])
    expect(db_files_in_cwd).to eq([])
    expect(report["no_db"]).to eq(true)
    expect(report["daemon_mode"]).to eq(true)
    expect(report["argv_after_parse"]).to eq([])
  end

  # This is what a DART running the harness in --mode service does: STOP and
  # START blue_hydra inside one long-lived container, so the same cwd.
  it "starts every --no-db run empty, with a new sync_version and device sync_id" do
    first  = run_bin(*anemoi_flags)
    second = run_bin(*anemoi_flags)

    expect(second["device_count_at_start"]).to eq(0)
    expect(second["replays_previous_rows"]).to eq(false)
    expect(second["sync_version"]).not_to eq(first["sync_version"])
    expect(second["device_sync_id"]).not_to eq(first["device_sync_id"])
    expect(db_files_in_cwd).to eq([])
  end

  it "persists to blue_hydra.db in the cwd without --no-db, and the next start inherits it" do
    first  = run_bin("--daemonize")
    second = run_bin("--daemonize")

    [first, second].each do |report|
      expect(setup_args(report)).to eq(["default", "sqlite:blue_hydra.db"])
      expect(no_db_at_setup(report)).to eq(false)
      expect(report["no_db"]).to eq(false)
      expect(report["adapter_path"]).to eq("blue_hydra.db")
      expect(basenames(report["open_db_files_after_save"])).to include("blue_hydra.db")
      expect(basenames(report["db_files_after_save"])).to include("blue_hydra.db")
    end
    expect(basenames(second["db_files_in_cwd"])).to include("blue_hydra.db")
    expect(first["device_count_at_start"]).to eq(0)
    expect(second["device_count_at_start"]).to eq(1)
    expect(second["replays_previous_rows"]).to eq(true)
    expect(second["sync_version"]).to eq(first["sync_version"])
    expect(second["device_sync_id"]).to eq(first["device_sync_id"])
    expect(db_files_in_cwd).to include("blue_hydra.db")
  end

  it "keeps the db in memory under BLUE_HYDRA=test when started through bin" do
    report = run_bin("--daemonize", env: { "BLUE_HYDRA" => "test" })

    expect(setup_args(report)).to eq(["default", memory_uri])
    expect(report["adapter_path"]).to eq(":memory:")
    expect(report["open_db_files_after_save"]).to eq([])
    expect(basenames(report["db_files_after_save"])).to eq([])
    expect(db_files_in_cwd).to eq([])
  end

  context "when the hci MAC read fails while lib is being required" do
    let(:mac_read_error) { "blue_hydra_bt_device_mac_read_error" }

    # Runs bin until lib exits 1 on the failed MAC read, checks that is the exit
    # it took, and returns the report. The harness records every service call
    # as it happens, so anything in the report was sent before that exit.
    def fatal_mac_read_exit(*flags)
      report = run_bin(*flags, env: { "BH_HARNESS_MAC_READ_FAILS" => "1" }, expect_status: 1)

      expect(report["runner_reached"]).to eq(false)
      expect(report["exit"]["class"]).to eq("SystemExit")
      expect(report["exit"]["status"]).to eq(1)
      # lib's own top level called exit, inside bin's `require 'blue_hydra'`
      frames = report["exit"]["frames"]
      expect(frames.first).to match([a_string_ending_with("lib/blue_hydra.rb"), "Kernel#exit"])
      expect(frames).to include(
        [a_string_ending_with("lib/blue_hydra.rb"), "<top (required)>"],
        [a_string_ending_with("bin/blue_hydra"), a_string_ending_with("require")]
      )

      sends = report["events"].select { |e| e["event"] == "BlueHydra.send_event" }
      expect(sends.size).to eq(1)
      expect(sends.first["caller"]).to match([a_string_ending_with("lib/blue_hydra.rb"), "<top (required)>"])
      expect(sends.first["hash"]).to include(
        "key"      => mac_read_error,
        "severity" => "FATAL",
        "message"  => a_string_starting_with("Unable to read the mac address")
      )
      # lib exited before it set up the database, so on the MAC-read path
      expect(report["events"].map { |e| e["event"] }).not_to include("DataMapper.setup")

      report
    end

    def flags_at_send(report)
      report["events"].find { |e| e["event"] == "BlueHydra.send_event" }["flags"]
    end

    def service_calls(report, service)
      report["events"].select { |e| e["event"] == "#{service}.send_event" }
    end

    it "sends the FATAL event to Stream Builder with the Anemoi wrapper's flags" do
      report = fatal_mac_read_exit(*anemoi_flags)

      expect(flags_at_send(report)).to include("stream_builder" => true)
      expect(service_calls(report, "StreamBuilder")).to eq([{
        "event"      => "StreamBuilder.send_event",
        "name"       => mac_read_error,
        "value"      => 1,
        "dimensions" => [{ "name" => "severity", "value" => "FATAL" }]
      }])
      expect(service_calls(report, "Pulse")).to eq([])
    end

    it "sends it nowhere without --stream-builder or --pulse" do
      report = fatal_mac_read_exit("--daemonize", "--no-db")

      expect(flags_at_send(report)).to eq(
        "pulse" => false, "stream_builder" => false, "stream_builder_debug" => false
      )
      expect(service_calls(report, "StreamBuilder")).to eq([])
      expect(service_calls(report, "Pulse")).to eq([])
    end

    it "sends it to Pulse with --pulse" do
      report = fatal_mac_read_exit("--daemonize", "--no-db", "--pulse")

      expect(flags_at_send(report)).to include("pulse" => true)
      pulse = service_calls(report, "Pulse").map { |e| [e["key"], e["hash"]["key"], e["hash"]["severity"]] }
      expect(pulse).to eq([["blue_hydra", mac_read_error, "FATAL"]])
      expect(service_calls(report, "StreamBuilder")).to eq([])
    end

    it "sends it to Stream Builder with --stream-builder-debug" do
      report = fatal_mac_read_exit("--daemonize", "--no-db", "--stream-builder-debug")

      expect(flags_at_send(report)).to include("stream_builder_debug" => true)
      expect(service_calls(report, "StreamBuilder").map { |e| e["name"] }).to eq([mac_read_error])
    end
  end
end
