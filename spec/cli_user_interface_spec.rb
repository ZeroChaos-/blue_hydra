require 'spec_helper'
require 'stringio'

# The debug CUI health lines added by GATT service scanning (Requirements 13.5,
# 13.10, 13.12): the GATT line's exact text and position, and conn-limit on
# the Direct LE line. The broader render_cui behaviour (table, sorts, filters)
# is covered in spec/ai_spec.rb's CliUserInterface group; this file captures
# stdout rather than silencing it because the assertions are on exact lines.
describe BlueHydra::CliUserInterface do
  describe "debug counter lines" do
    # Stand-in for a Runner carrying everything render_cui's debug block reads.
    # le_direct_pending and gatt_scanner are the two accessors the block needs
    # beyond what the table rendering uses; render_cui rescues every exception
    # and logs it, so a missing accessor would silently drop the lines rather
    # than fail, which is why the render helper below also checks the logger.
    class CuiCountersFakeRunner
      attr_accessor :cui_status, :scanner_status, :result_queue,
                    :info_scan_queue, :l2ping_queue, :query_history,
                    :processing_speed, :stunned, :mgmt,
                    :le_direct_pending, :gatt_scanner

      def initialize
        @cui_status        = {}
        @scanner_status    = {}
        @result_queue      = Queue.new
        @info_scan_queue   = Queue.new
        @l2ping_queue      = Queue.new
        @query_history     = {}
        @processing_speed  = 1.0
        @stunned           = false
        @mgmt              = nil
        @le_direct_pending = nil # a real Runner before start_discovery_thread
        @gatt_scanner      = nil # gatt_scan false, or discovery not started
      end
    end

    # A Runner from before the gatt_scanner accessor existed: the line must
    # still render, as all zeros.
    class CuiCountersLegacyFakeRunner < CuiCountersFakeRunner
      undef_method :gatt_scanner, :gatt_scanner=
    end

    let(:ansi_escape_re) { /\e\[[0-9;]*[A-Za-z]/ }
    let(:printable_keys) { [:_seen, :vers, :address, :rssi, :name, :manuf, :type, :range] }
    let(:tracker)        { BlueHydra::CliUserInterfaceTracker }

    # Requirement 13.5: the 15 Gatt_Scanner counters in Requirement 13.1 order,
    # then name-unknown, as comma-separated name: value pairs.
    let(:zero_gatt_line) do
      "GATT: attempted: 0, in-flight: 0, complete: 0, partial: 0, " \
      "protected: 0, unchanged: 0, busy: 0, timeout: 0, disconnected: 0, " \
      "error: 0, skipped: 0, deferred: 0, resumed: 0, peer-req: 0, " \
      "reset-deferred: 0, name-unknown: 0"
    end

    around do |example|
      original_level = BlueHydra.config["log_level"]
      BlueHydra::UuidNames.reset!
      begin
        example.run
      ensure
        BlueHydra.config["log_level"] = original_level
        BlueHydra::UuidNames.reset!
      end
    end

    def with_log_level(level)
      BlueHydra.config["log_level"] = level
      yield
    end

    # Render once and return the screen as plain text lines, with the ANSI
    # cursor and colour sequences removed. Fails the example if render_cui
    # rescued anything, since that would otherwise just read as missing lines.
    def render_lines(runner)
      rescued = []
      allow(BlueHydra.logger).to receive(:error) { |message| rescued << message }
      cui = BlueHydra::CliUserInterface.new(runner)
      original_stdout = $stdout
      $stdout = StringIO.new
      begin
        cui.render_cui(40, :_seen, "ascending", printable_keys.dup, :disabled)
        screen = $stdout.string
      ensure
        $stdout = original_stdout
      end
      expect(rescued).to eq([])
      screen.gsub(ansi_escape_re, "").split("\n")
    end

    def direct_le_line(lines)
      lines.grep(/\ADirect LE: /)
    end

    def gatt_line(lines)
      lines.grep(/\AGATT: /)
    end

    # The Direct LE line as render_cui must print it for the counters now in
    # the tracker and the given backlog size.
    def expected_direct_le_line(queued)
      "Direct LE: connected: #{tracker.le_direct_connected_count}, " \
      "unreachable: #{tracker.le_direct_failed_count}, " \
      "error: #{tracker.le_direct_error_count}, " \
      "abandoned: #{tracker.le_direct_abandoned_count}, " \
      "conn-limit: #{tracker.le_direct_conn_limit_count}, " \
      "dropped: #{tracker.le_direct_dropped_count}, " \
      "queued: #{queued}"
    end

    describe "the GATT line (Requirement 13.5, 13.10)" do
      it "renders all zeros when the runner has no scanner" do
        runner = CuiCountersFakeRunner.new
        lines  = with_log_level("debug") { render_lines(runner) }

        expect(gatt_line(lines)).to eq([zero_gatt_line])
      end

      it "renders all zeros for a runner without a gatt_scanner accessor" do
        runner = CuiCountersLegacyFakeRunner.new
        expect(runner).not_to respond_to(:gatt_scanner)

        lines = with_log_level("debug") { render_lines(runner) }

        expect(gatt_line(lines)).to eq([zero_gatt_line])
      end

      it "renders the scanner's counters in COUNTERS order, then name-unknown" do
        counters = {
          attempted: 15, :"in-flight" => 2, complete: 5, partial: 3, protected: 1,
          unchanged: 1, busy: 1, timeout: 1, disconnected: 1, error: 0,
          skipped: 7, deferred: 4, resumed: 2, :"peer-req" => 9, :"reset-deferred" => 1
        }
        expect(counters.keys).to match_array(BlueHydra::GattScanner::COUNTERS)
        scanner = instance_double(BlueHydra::GattScanner, counters: counters)
        runner  = CuiCountersFakeRunner.new
        runner.gatt_scanner = scanner

        # name-unknown is the Uuid_Formatter's counter, read from UuidNames
        2.times { BlueHydra::UuidNames.service(0xFFFF) }
        expect(BlueHydra::UuidNames.name_unknown_count).to eq(2)

        lines = with_log_level("debug") { render_lines(runner) }

        expect(gatt_line(lines)).to eq([
          "GATT: attempted: 15, in-flight: 2, complete: 5, partial: 3, protected: 1, " \
          "unchanged: 1, busy: 1, timeout: 1, disconnected: 1, error: 0, skipped: 7, " \
          "deferred: 4, resumed: 2, peer-req: 9, reset-deferred: 1, name-unknown: 2"
        ])
      end

      it "takes a fresh counters snapshot on every refresh" do
        first  = BlueHydra::GattScanner::ZERO_COUNTERS.merge(attempted: 1, :"in-flight" => 1)
        second = BlueHydra::GattScanner::ZERO_COUNTERS.merge(attempted: 1, complete: 1)
        scanner = instance_double(BlueHydra::GattScanner)
        allow(scanner).to receive(:counters).and_return(first, second)
        runner = CuiCountersFakeRunner.new
        runner.gatt_scanner = scanner

        with_log_level("debug") do
          expect(gatt_line(render_lines(runner)).first).to include("attempted: 1, in-flight: 1, complete: 0,")
          expect(gatt_line(render_lines(runner)).first).to include("attempted: 1, in-flight: 0, complete: 1,")
        end
        expect(scanner).to have_received(:counters).twice
      end

      it "sits on the line immediately after Direct LE" do
        runner = CuiCountersFakeRunner.new
        lines  = with_log_level("debug") { render_lines(runner) }

        direct_le_index = lines.index { |line| line.start_with?("Direct LE: ") }
        gatt_index      = lines.index { |line| line.start_with?("GATT: ") }
        expect(direct_le_index).not_to be_nil
        expect(gatt_index).to eq(direct_le_index + 1)
      end
    end

    describe "conn-limit (Requirement 13.12)" do
      it "renders on the Direct LE line between abandoned and dropped" do
        before = tracker.le_direct_conn_limit_count
        2.times { tracker.increment_le_direct_conn_limit_count }
        runner = CuiCountersFakeRunner.new
        runner.le_direct_pending = { "7A:00:00:00:00:01" => 2, "7A:00:00:00:00:02" => 2 }

        lines = with_log_level("debug") { render_lines(runner) }

        expect(direct_le_line(lines)).to eq([expected_direct_le_line(2)])
        expect(direct_le_line(lines).first).to include("abandoned: #{tracker.le_direct_abandoned_count}, conn-limit: #{before + 2}, dropped: ")
      end

      it "renders queued: 0 when the direct backlog does not exist yet" do
        runner = CuiCountersFakeRunner.new
        runner.le_direct_pending = nil

        lines = with_log_level("debug") { render_lines(runner) }

        expect(direct_le_line(lines)).to eq([expected_direct_le_line(0)])
      end

      it "does not appear on the GATT line" do
        tracker.increment_le_direct_conn_limit_count
        scanner = instance_double(BlueHydra::GattScanner,
                                  counters: BlueHydra::GattScanner::ZERO_COUNTERS.merge(attempted: 3, complete: 3))
        runner  = CuiCountersFakeRunner.new
        runner.gatt_scanner = scanner

        lines = with_log_level("debug") { render_lines(runner) }

        expect(gatt_line(lines).size).to eq(1)
        expect(gatt_line(lines).first).not_to include("conn-limit")
        expect(direct_le_line(lines).first).to include("conn-limit: ")
      end
    end

    describe "at log_level info" do
      it "renders neither the Direct LE line nor the GATT line" do
        runner = CuiCountersFakeRunner.new
        runner.gatt_scanner = instance_double(BlueHydra::GattScanner, counters: BlueHydra::GattScanner::ZERO_COUNTERS)

        lines = with_log_level("info") { render_lines(runner) }

        expect(direct_le_line(lines)).to be_empty
        expect(gatt_line(lines)).to be_empty
        expect(lines.grep(/\AChunker: /)).to be_empty
      end
    end
  end
end
