module BlueHydra
  # this class take incoming and outgoing queues and batches messages coming
  # out of the btmon handler
  class Chunker

    # HCI event codes (first line) that on their own indicate the start of a new
    # device chunk. bluez monitor/packet.c static const struct event_data
    # event_table. Frozen set so membership is O(1) and adding a code neither
    # slows the check nor forces a per-call regex rebuild.
    HCI_EVENT_START_CODES = [
      "03", # Connect Complete
      "04", # Connect Request
      "07", # Remote Name Req Complete
      "0e", # Command Complete
      "12", # Role Change
      "22", # Inquiry Result with RSSI
      "2f", # Extended Inquiry Result
      "3d", # Remote Host Supported Features
    ].to_set.freeze

    # Pulls the "(0xNN)" event/subevent code out of a monitor header line once,
    # so we can dispatch on it instead of scanning the line with a regex per
    # case. Compiled once here rather than rebuilt on every call.
    EVENT_CODE_RE = /\(0x([0-9a-f]+)\)/.freeze

    # LE Meta Event (first line) code; the deciding subevent is on the second
    # line. bluez monitor/packet.h static const struct subevent_data
    # le_meta_event_table: LE Connection Complete (0x01) /
    # LE Advertising Report (0x02) / LE Extended Advertising Report (0x0d)
    LE_META_EVENT_CODE     = "3e".freeze
    LE_META_START_SUBEVENT = /\(0x0[12d]\)/.freeze

    # name has been moved into the MGMT "Device Found" event in newer bluez
    MGMT_DEVICE_FOUND_RE   = /@ MGMT Event: .* \(0x0012\)/.freeze

    # initialize with incoming (from btmon) and outgoing (to parser) queues
    def initialize(incoming_q, outgoing_q)
      @incoming_q = incoming_q
      @outgoing_q = outgoing_q
    end

    # Worker method which takes in  batches of data from the incoming queue,
    # treating the messages as chunks of a set of data this method will
    # group the chunked messages into a bigger set and then flush to the
    # parser when a new device starts to appear
    def chunk_it_up

      # start with an empty working set before any messages have been received
      working_set = []

      # pop a chunk (array of lines of filtered btmon output) off the
      # incoming queue
      while current_msg = @incoming_q.pop

        # test if the message indicates the start of a new message
        #
        # also bypass if our working set is empty as this indicates we are
        # receiving our first device of the run
        if starting_chunk?(current_msg) && !working_set.empty?

          # if we just got a new message shovel the working set into the
          # outgoing queue and reset it
          address_lines = working_set.flatten.reject{|x| x =~ /Direct address/}.join("").scan(/^\s*.*ddress: ((?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2})/).flatten
          address_list  = address_lines.uniq
          address_count = address_list.count

          # Count every chunk that carries more than one address line - even
          # when they are all the same MAC. blue_hydra currently processes one
          # device at a time so message order is reliable; the plan to process
          # multiple devices concurrently will make that order unreliable, so we
          # need visibility into any chunk holding more than one address line.
          # This is orthogonal to the routing below: a valid single-address
          # chunk is still pushed for processing. The full chunk is only dropped
          # to the chunk log when chunker_debug is enabled.
          if address_lines.count > 1
            BlueHydra::CliUserInterfaceTracker.increment_multi_address_chunk_count
            if BlueHydra.config["chunker_debug"]
              working_set.flatten.each{|msg| BlueHydra.chunk_logger.info(msg.chomp) }
              BlueHydra.chunk_logger.info("-------------------------------------------------------------------------------")
            end
          end

          if address_count == 1
            unless BlueHydra.config["ignore_mac"].include?(address_list[0])
              @outgoing_q.push working_set
            end
          elsif address_count < 1
            BlueHydra::CliUserInterfaceTracker.increment_zero_address_chunk_count
            if BlueHydra.config["chunker_debug"]
              working_set.flatten.each{|msg| BlueHydra.chunk_logger.info(msg.chomp) }
              BlueHydra.chunk_logger.info("-------------------------------------------------------------------------------")
            else
              BlueHydra.logger.warn("Got a chunk with no addresses, dazed and confused, discarding...")
            end
            BlueHydra.send_event('blue_hydra',
            {
              key: 'bluehydra_chunk_0_address',
              title: 'BlueHydra chunked a chunk with 0 addresses.',
              message: 'BlueHydra chunked a chunk with 0 addresses',
              severity: 'WARN'
            })
          else
            # more than one unique address: a start block was almost certainly
            # missed and two devices' data got merged, so discard it. The warn
            # is always emitted; the full chunk is dropped to the chunk log
            # above only when chunker_debug is on.
            BlueHydra::CliUserInterfaceTracker.increment_multi_unique_address_chunk_count
            BlueHydra.logger.warn("Got a chunk with multiple addresss, missing a start block. Discarding corrupted data...")
            BlueHydra.send_event('blue_hydra',
            {
              key: 'bluehydra_chunk_2_address',
              title: 'BlueHydra chunked a chunk with more than 1 uniq address.',
              message: 'BlueHydra chunked a chunk with more than 1 uniq address.',
              severity: 'WARN'
            })
          end
          #always clear the working set
          working_set = []
        end

        # inject a timestamp onto the message parsed out of the first line of
        # btmon output
        #
        # Original used the general-purpose Time.parse, which is much slower for
        # this fixed, known format and runs once per message on the chunker
        # thread. Kept for reference:
        #   ts = Time.parse(current_msg.first.strip.scan(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d*$/)[0]).to_i
        #
        # Time.strptime parses the known format directly. It keeps the same
        # local-time interpretation as Time.parse (no zone in the string), and
        # the fractional seconds are discarded by to_i just as before.
        ts = Time.strptime(
          current_msg.first.strip.scan(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}.\d*$/)[0],
          "%Y-%m-%d %H:%M:%S.%N"
        ).to_i
        current_msg << "last_seen: #{ts}"

        # add the current message to the working set
        working_set << current_msg
      end
    end

    # test if the message indicates the start of a new message
    def starting_chunk?(chunk=[])
      line = chunk[0]
      return false unless line

      # Nearly every message reaching the chunker is a "> HCI Event:" line (see
      # spec/fixtures/btmon.stdout), so handle those first. Single-line HCI
      # events and the LE Meta Event share this header, so extract the event
      # code once and dispatch on it rather than running the line through a
      # separate regex for each case.
      if line.start_with?("> HCI Event:")
        code = (m = EVENT_CODE_RE.match(line)) && m[1]

        # LE Meta events (advertising / connection reports) are the most common
        # chunk start in practice, so check the second-line subevent first:
        # LE Connection Complete / LE Advertising Report / LE Extended
        # Advertising Report
        return true if code == LE_META_EVENT_CODE && chunk[1] =~ LE_META_START_SUBEVENT

        # otherwise a bare classic start code is enough on its own. An HCI event
        # line is never an MGMT event, so this is the final word for these lines.
        return HCI_EVENT_START_CODES.include?(code)
      end

      # name has been moved into the MGMT Device Found event, at least it has an
      # address (may be tool-prefixed, so this is matched unanchored)
      return true if line =~ MGMT_DEVICE_FOUND_RE

      # otherwise this will get grouped with the current working set in the
      # chunk it up method
      false
    end
  end
end
