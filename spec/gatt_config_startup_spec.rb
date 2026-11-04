require 'spec_helper'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'fileutils'
require 'yaml'
require 'json'

# lib/blue_hydra.rb validates the four GATT options while it is being
# required: GattConfig.normalise runs inside the config-loading block, its
# warnings are parked until update_logger has run, and they are then written
# at warn level before any other blue_hydra/* file is required and before any
# thread or socket exists. spec_helper requires lib exactly once, with
# BLUE_HYDRA=test and the repo-root blue_hydra.yml, so an in-process spec
# cannot feed lib a different config file or watch that startup path. These
# examples run the real bin in a child process instead, following
# spec/no_db_spec.rb and its spec/support/bin_blue_hydra_harness.rb, and read
# the warnings back from the child's blue_hydra.log.
#
# The child runs from a copy of bin/ and lib/ in a scratch directory. With
# BLUE_HYDRA unset and the harness answering false for /etc/blue_hydra and
# /var/log/blue_hydra, lib derives CONFIG_FILE and every log path from
# __FILE__ (../../blue_hydra.yml relative to lib/blue_hydra.rb), so running the
# checked-out bin would read and rewrite the repo-root blue_hydra.yml that the
# in-process specs share and append to the repo-root blue_hydra.log. The copy
# keeps the real bin and lib under test and lands every file the child touches
# inside the scratch directory, which is removed afterwards.
describe "GATT config options at startup" do
  let(:repo_root)     { File.expand_path('../..', __FILE__) }
  let(:harness)       { File.expand_path('../support/bin_blue_hydra_harness.rb', __FILE__) }
  let(:child_timeout) { 60 }
  let(:gatt_keys)     { %w[gatt_scan gatt_walk_timeout gatt_walk_parallel gatt_read_all] }
  let(:gatt_defaults) do
    { "gatt_scan" => true, "gatt_walk_timeout" => 10, "gatt_walk_parallel" => 3, "gatt_read_all" => true }
  end

  around do |example|
    Dir.mktmpdir("bh-gatt-config") do |root|
      FileUtils.cp_r(File.join(repo_root, "bin"), root)
      FileUtils.cp_r(File.join(repo_root, "lib"), root)
      @root = root
      example.run
    end
  end

  def config_path
    File.join(@root, "blue_hydra.yml")
  end

  def log_path
    File.join(@root, "blue_hydra.log")
  end

  # Writes yml as the child's blue_hydra.yml and runs the copied bin/blue_hydra
  # until Runner.new, where the harness exits 0 (every option has been applied
  # and the whole of lib has been required by then). Raises unless the child
  # got that far, so a config that aborted startup fails loudly rather than
  # leaving an empty log to assert against.
  def start_with_config(yml)
    File.write(config_path, yml)
    report_path = File.join(@root, "harness-report.json")
    child_env   = { "BLUE_HYDRA" => nil, "BH_HARNESS_REPORT" => report_path }
    bin         = File.join(@root, "bin", "blue_hydra")
    flags       = %w[--daemonize --no-db]
    label       = "bin/blue_hydra #{flags.join(' ')}"

    output = status = nil
    Open3.popen2e(child_env, RbConfig.ruby, "-r", harness, bin, *flags, chdir: @root) do |stdin, out, wait_thr|
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

    report = File.exist?(report_path) ? JSON.parse(File.read(report_path)) : {}
    unless status.exitstatus == 0 && report["runner_reached"] == true
      raise "#{label} exited #{status.exitstatus.inspect} before Runner.new " \
            "(report: #{report.inspect}):\n#{output}"
    end
  end

  # Message text of every warn-level line in the child's log, in file order.
  # The default Logger format is "W, [<time> #<pid>]  WARN -- : <message>".
  def warn_messages
    File.readlines(log_path).filter_map { |line| line[/ WARN -- : (.*)$/, 1] }
  end

  def gatt_warn_messages
    warn_messages.select { |message| message.start_with?("gatt_") }
  end

  def startup_line_index
    File.readlines(log_path).index { |line| line.include?("BlueHydra Starting...") }
  end

  def rewritten_config
    YAML.load(File.read(config_path))
  end

  # Positive control for the "no warning" examples below: it shows the warn
  # lines do reach this log when a value is rejected.
  it "warns once per rejected option, naming the option, the value and the default, and applies the defaults" do
    start_with_config(<<~YML)
      log_level: info
      bt_device: hci0
      gatt_scan: "true"
      gatt_walk_timeout: 0
      gatt_walk_parallel: 3.5
      gatt_read_all: 1
    YML

    # one line per option, in GattConfig::DEFAULTS order, quoted string shown quoted
    expect(gatt_warn_messages).to eq([
      'gatt_scan: rejected "true" (expected true or false), using default true',
      'gatt_walk_timeout: rejected 0 (expected an Integer or Float from 1 to 60), using default 10',
      'gatt_walk_parallel: rejected 3.5 (expected an Integer from 1 to 8), using default 3',
      'gatt_read_all: rejected 1 (expected true or false), using default true'
    ])

    # written at startup: all four precede bin's "BlueHydra Starting..." line
    lines      = File.readlines(log_path)
    last_warn  = lines.rindex { |line| line =~ / WARN -- : gatt_/ }
    expect(startup_line_index).not_to be_nil
    expect(last_warn).to be < startup_line_index

    # the rewritten file carries the values in effect, not the rejected ones
    expect(rewritten_config).to include(gatt_defaults)
    expect(rewritten_config).to include("log_level" => "info", "bt_device" => "hci0")
  end

  it "adds the four keys with their defaults, without warning, when the file lacks them" do
    start_with_config(<<~YML)
      log_level: info
      bt_device: hci0
      info_scan_rate: 120
    YML

    expect(gatt_warn_messages).to eq([])
    expect(rewritten_config).to include(gatt_defaults)
    # existing keys preserved
    expect(rewritten_config).to include("log_level" => "info", "bt_device" => "hci0", "info_scan_rate" => 120)
  end

  it "applies the defaults silently when the four keys are set to null" do
    start_with_config(<<~YML)
      log_level: info
      bt_device: hci0
      gatt_scan: ~
      gatt_walk_timeout: null
      gatt_walk_parallel:
      gatt_read_all: ~
    YML

    expect(gatt_warn_messages).to eq([])
    expect(rewritten_config).to include(gatt_defaults)
  end

  it "keeps valid non-default values unchanged, without warning" do
    start_with_config(<<~YML)
      log_level: info
      bt_device: hci0
      gatt_scan: false
      gatt_walk_timeout: 2.5
      gatt_walk_parallel: 1
      gatt_read_all: false
    YML

    expect(gatt_warn_messages).to eq([])
    expect(rewritten_config).to include(
      "gatt_scan"          => false,
      "gatt_walk_timeout"  => 2.5,
      "gatt_walk_parallel" => 1,
      "gatt_read_all"      => false
    )
    expect(rewritten_config.keys).to include(*gatt_keys)
  end
end
