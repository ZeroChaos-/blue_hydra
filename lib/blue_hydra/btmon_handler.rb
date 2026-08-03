module BlueHydra

  # This class is responsible for running the Bluetooth monitor. It can also be
  # passed other commands such as "cat btmonoutput.txt" to allow replaying of
  # recorded bluetooth scans.
  class BtmonHandler

    # optional "toolname[pid]: " prefix that newer bluez prepends ahead of the
    # line marker (e.g. "hcitool[123]: < HCI Command..."). Stripped so prefixed
    # and unprefixed lines dispatch the same way.
    TOOL_PREFIX_RE = /^\w*\[\d*\]: /.freeze

    # pulls the "(0xNN)" event code out of a "> HCI Event:" header, once,
    # instead of scanning the line with a regex per drop code
    HCI_EVENT_CODE_RE = /\(0x([0-9a-f]+)\)/.freeze

    # HCI event codes dropped unconditionally (no second-line condition):
    #   0f Command Status, 13 Number of Completed Packets
    # bluez monitor/packet.c static const struct event_data event_table
    HCI_DROP_CODES = ["0f", "13"].to_set.freeze

    # MGMT "Device Found" (0x0012) is the only "@" line we keep; it carries an
    # address the chunker needs. Every other local/MGMT event is noise.
    MGMT_DEVICE_FOUND_RE = /^@ MGMT Event: .* \(0x0012\)/.freeze

    # bluez monitor "= ..." notes / index bookkeeping we drop
    NOTE_DROP_RE = /^= (bluetoothd: Unable to|New Index:|Delete Index:|Open Index:|Close Index:|Index Info:|Note:)/.freeze

    # btmon truncates a message name with ".." (and wraps the timestamp onto the
    # next line) when its column width is too small, e.g. run with --columns 80:
    #   < HCI Command: Write Scan.. (0x03|0x001a) plen 1
    #   < HCI Command: LE Set Ext.. (0x08|0x0039) plen 2
    # The ".." immediately before the " (0xNN|0xNNNN)" opcode is a reliable
    # marker of truncated/wrapped output that would otherwise break parsing. It
    # never appears in full-width output.
    TRUNCATION_RE = /\.\.\s+\(0x[0-9a-f]/i.freeze

    # Flush the gzip log(s) to disk once at least this many seconds have elapsed
    # since the previous flush completed. Zlib::GzipWriter buffers, and its
    # trailer is only written on close, so an ungraceful stop can truncate the
    # file; periodic SYNC_FLUSH keeps everything written so far recoverable.
    LOG_FLUSH_INTERVAL = 60

    # initialize an instance of the class to run a command and push filtered
    # output into the parsing and processing pipeline
    #
    # == Parameters:
    #   command ::
    #     the command to get data from, in most cases this is `btmon -T`
    #   parse_queue ::
    #     Queue object to push results into
    def initialize(command, parse_queue)
      @command = command
      @parse_queue = parse_queue

      # decide whether btmon will emit color codes (and thus whether we need to
      # strip them per line) before we spawn
      configure_color_handling

      # # log used btmon output for review if requested
      if BlueHydra.config["btmon_log"]
        @log_file = if Dir.exist? ('/var/log/blue_hydra')
                        File.open("/var/log/blue_hydra/btmon_#{Time.now.to_i}.log.gz",'wb')
                      else
                        File.open("btmon_#{Time.now.to_i}.log.gz",'wb')
                      end
        @log_writer = Zlib::GzipWriter.wrap(@log_file)
      end
      # # log raw btmon output for review if requested
      if BlueHydra.config["btmon_rawlog"]
        @rawlog_file = if Dir.exist?('/var/log/blue_hydra')
                         File.open("/var/log/blue_hydra/btmon_raw_#{Time.now.to_i}.log.gz",'wb')
                       else
                         File.open("btmon_raw_#{Time.now.to_i}.log.gz",'wb')
                       end
        @rawlog_writer = Zlib::GzipWriter.wrap(@rawlog_file)
      end

      # initialize itself calls the method that spanws the PTY which runs the
      # command
      begin
        spawn
      ensure
        @log_writer.close if @log_writer
        @rawlog_writer.close if @rawlog_writer
      end
    end

    # Flush the active gzip log writer(s) to disk if at least LOG_FLUSH_INTERVAL
    # seconds have elapsed since the previous flush *completed*. Using
    # Zlib::SYNC_FLUSH pushes a decompressable boundary to disk so the file
    # stays recoverable even if the process is killed before the writer is
    # closed. The interval is measured from completion so a slow flush can't
    # cause back-to-back flushing.
    def flush_logs_if_due
      return unless @log_writer || @rawlog_writer

      now = Time.now.to_i
      @last_log_flush ||= now
      return if (now - @last_log_flush) < LOG_FLUSH_INTERVAL

      flush_writer(@log_writer)
      flush_writer(@rawlog_writer)

      # stamp *after* flushing so the next flush is at least LOG_FLUSH_INTERVAL
      # seconds from when this one completed (and so a no-op flush doesn't retry
      # on every subsequent line)
      @last_log_flush = Time.now.to_i
    end

    # SYNC_FLUSH raises Zlib::BufError ("buffer error") when there is nothing
    # new to flush -- e.g. a whole interval where every line was filtered out so
    # nothing reached this writer. That is harmless, so swallow it rather than
    # letting it kill the btmon thread.
    def flush_writer(writer)
      return unless writer
      writer.flush(Zlib::SYNC_FLUSH)
    rescue Zlib::BufError
      nil
    end

    # Decide how to handle btmon color codes. If we are actually running btmon
    # and it supports "--color=never", ask it to emit no ANSI color codes and
    # skip the per-line color-stripping gsub. For file replay (cat/xzcat/zcat)
    # or an older btmon without the flag we keep stripping, since the input may
    # still contain color codes.
    def configure_color_handling
      if @command.start_with?("btmon") && color_never_supported?
        @command = "#{@command} --color=never" unless @command.include?("--color=never")
        @strip_colors = false
      else
        @strip_colors = true
      end
    end

    # true when the installed btmon can disable colored output. btmon advertises
    # this as an option that takes a mode, e.g. BlueZ 5.86 prints:
    #   -c, --color [mode]     Output color: auto/always/never
    # so the literal "--color=never" never appears in the help. We instead look
    # for a --color option line that lists a "never" mode. The argument is
    # optional ([mode]), so it must be passed attached as "--color=never" (see
    # configure_color_handling), which is what we do. Any failure or an older
    # btmon without the flag returns false so we keep stripping colors ourselves.
    def color_never_supported?
      !!(btmon_help =~ /--color\b.*\bnever\b/)
    end

    # capture `btmon --help` output (stderr merged, since btmon prints usage
    # there). Returns "" on failure.
    def btmon_help
      `btmon --help 2>&1`
    rescue
      ""
    end

    # Count btmon output lines that have been truncated/wrapped because the
    # column width is too small (see TRUNCATION_RE). Such output silently drops
    # the tail of message names and pushes the timestamp onto a wrapped line,
    # which breaks the chunker/parser. Every occurrence bumps the shared
    # truncation counter (surfaced on the debug CUI chunker line). The warn log
    # and event fire only once per run (gated by @truncation_warned) since the
    # condition is constant for a given btmon invocation and would otherwise
    # spam. The fix is a wider btmon --columns / PTY width.
    def check_for_truncation(line)
      return unless line =~ TRUNCATION_RE

      # count every truncated line (ungated)
      BlueHydra::CliUserInterfaceTracker.increment_truncation_detected_count

      # alert once
      return if @truncation_warned
      @truncation_warned = true
      msg = "btmon output appears truncated/wrapped - its column width is too " \
            "small and message names/timestamps are being cut, which breaks " \
            "parsing. Increase btmon --columns. Example line: #{line.strip}"
      BlueHydra.logger.warn(msg)
      BlueHydra.send_event('blue_hydra',
        {key: 'blue_hydra_btmon_truncated_output',
        title: 'Blue Hydra btmon Output Truncated',
        message: msg,
        severity: 'WARN'
        })
    end

    # spawn a PTY to run @command
    def spawn
      PTY.spawn(@command) do |stdout, stdin, pid|

        # lines of output will be stacked up here until a message is complete
        # and pushed into @parse_queue
        buffer = []

        begin
          # handle the streaming output line by line
          stdout.each do |line|

            # periodically flush the gzip log(s) so an ungraceful stop leaves a
            # recoverable file rather than a trailer-less, truncated one
            flush_logs_if_due

            # log used btmon output for review if we are in debug mode
            if BlueHydra.config["btmon_rawlog"] && !BlueHydra.config["file"]
              @rawlog_writer.puts(line.chomp)
            end

            # strip out color codes, unless we asked btmon not to emit them
            # (--color=never), in which case there is nothing to strip
            if @strip_colors
              known_colors = [
                "\e[0;30m", "\e[1;30m",
                "\e[0;31m", "\e[1;31m",
                "\e[0;32m", "\e[1;32m",
                "\e[0;33m", "\e[1;33m",
                "\e[0;34m", "\e[1;34m",
                "\e[0;35m", "\e[1;35m",
                "\e[0;36m", "\e[1;36m",
                "\e[0;37m", "\e[1;37m",
                "\e[0m",
              ]

              begin
                known_colors.each do |c|
                  line = line.gsub(c, "")
                end
              rescue ArgumentError
                BlueHydra.logger.warn("Non UTF-8 encoding in line: #{line.chomp}")
                next
              end
            end

            # A new message starts on a non-whitespace line. Compute once and
            # reuse it for both the truncation check and the buffer flush below.
            new_message = line =~ /^\S/

            # Count btmon lines that look truncated/wrapped from too small a
            # column width (which silently breaks parsing). Only message header
            # lines carry the ".. (0x..)" marker, so gating on new_message keeps
            # the regex off the (far more numerous) nested data lines.
            check_for_truncation(line) if new_message

            # Messages are indented under a header as follows
            #
            #   Message A
            #     Data A1
            #     Data A2
            #   Message B
            #     Data B1
            #       Data B1a
            #     Data B2
            #
            # If the line starts with whitespace we are still in a nested
            # message otherwise we hit a new message and should empy the buffer
            #
            # \s == whitespace
            # \S == non whitespace
            #
            # When we get a line that starts with non-whitespace we are dealing
            # with a new message starting
            if new_message

              # if we have nothing in the buffer its our first message of the
              # run so we dont need to do anything but if we have a non-zero
              # sized buffer we push the contents of the buffer into the
              # @parse_queue
              if buffer.size > 0
                enqueue(buffer)
              end

              # reset the buffer
              buffer = []
            end

            buffer << line
          end
        rescue Errno::EIO
          # File has completed or command has crashed, either way flush last
          # chunks to buffer
          enqueue(buffer)

          raise BtmonExitedError
        end
      end
    end

    # filter and then push an array of lines into the @parse_queue
    #
    # Most drop rules key off the leading marker of the first line (<, @, >, =)
    # once the optional "toolname[pid]: " prefix newer bluez adds is stripped.
    # We dispatch on that marker so a message only runs the handful of rules for
    # its group instead of the whole list. Stripping the prefix also unifies the
    # bare and "bluetoothd[pid]:"-prefixed variants: e.g. every "@" line except
    # MGMT Device Found is dropped whether or not it carries a tool prefix.
    #
    # numbers from bluez monitor/packet.c static const struct event_data event_table
    def enqueue(buffer)
      first_line = buffer.first

      if first_line
        # strip the optional "toolname[pid]: " prefix so prefixed and unprefixed
        # lines dispatch the same way
        marker = first_line.sub(TOOL_PREFIX_RE, "")

        # Branches are ordered by observed frequency (see
        # spec/fixtures/btmon.stdout): received events (>) and sent commands (<)
        # dominate the stream, "@" is uncommon, and "=" / the banner are rare.
        case marker[0]
        when ">"
          # controller -> host; only "> HCI Event:" lines carry drop rules
          if marker.start_with?("> HCI Event:")
            code = (m = HCI_EVENT_CODE_RE.match(marker)) && m[1]

            # "Command Complete" (0x0e) is by far the most common event, so
            # check it first. Filters out local command responses but keeps
            # remote replies.
            return if code == "0e" && buffer[1] !~ /Remote/

            # Command Status (0x0f) / Number of Completed Packets (0x13)
            return if HCI_DROP_CODES.include?(code)

            # Unknown event (0x00 only ever appears as "> HCI Event: Unknown")
            return if code == "00"

            # l2ping against a gone host yields a Connect Complete / Remote Name
            # Req Complete with a non-Success status; do not send it to the
            # parser as it would 'online' the record when we actually want to
            # let it time out. (Page Timeout, ACL Connection Already Exists,
            # Command Disallowed, LMP/LL Response Timeout, Connection Timeout...)
            return if (code == "03" || code == "07") && buffer[1] !~ /\sStatus: Success \(0x00\)/
          end

        when "<"
          # anything we sent to the controller (host -> controller)
          return

        when "@"
          # local / MGMT events are noise except MGMT Device Found (0x0012)
          return unless marker =~ MGMT_DEVICE_FOUND_RE

        when "="
          # bluez monitor notes / index bookkeeping
          return if marker =~ NOTE_DROP_RE

        else
          return if marker.start_with?("Bluetooth monitor ver")
        end
      end

      # log used btmon output for review
      if BlueHydra.config["btmon_log"] && !BlueHydra.config["file"] && !BlueHydra.config["btmon_rawlog"]
        buffer.each do |line|
          @log_writer.puts(line.chomp)
        end
      end

      # unless this is a filtered message enqueue the buffer for realz.
      @parse_queue.push(buffer)
    end
  end
end
