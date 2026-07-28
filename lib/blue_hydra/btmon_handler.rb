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

    # spawn a PTY to run @command
    def spawn
      PTY.spawn(@command) do |stdout, stdin, pid|

        # lines of output will be stacked up here until a message is complete
        # and pushed into @parse_queue
        buffer = []

        begin
          # handle the streaming output line by line
          stdout.each do |line|

            # log used btmon output for review if we are in debug mode
            if BlueHydra.config["btmon_rawlog"] && !BlueHydra.config["file"]
              @rawlog_writer.puts(line.chomp)
            end

            # strip out color codes
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
            if line =~ /^\S/

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
