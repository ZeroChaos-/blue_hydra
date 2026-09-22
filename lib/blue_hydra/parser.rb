module BlueHydra

  # class responsible for parsing a group of message chunks into a serialized
  # hash appropriate to generate or update a device record.
  class Parser
    BLEEE_PACKET_TYPES = {
      '0b': 'watch_c',
      '0c': 'handoff',
      '0d': 'wifi_set',
      '0e': 'hotspot',
      '0f': 'wifi_join',
      '10': 'nearby',
      '07': 'airpods',
      '05': 'airdrop'
    }.freeze

    # btmon prints the label "TX power:" for FOUR unrelated quantities, and the
    # only thing separating them in the text is the unit it suffixes. From bluez
    # monitor/packet.c:
    #
    #   "N dBm"          BT_EIR_TX_POWER, AD type 0x0a - the device's own
    #                    advertised TX power, and the only one of the four that
    #                    belongs in *_tx_power.
    #   "N dB"           print_manufacturer_apple - an iBeacon's measured power,
    #                    i.e. its calibrated RSSI at one metre. Not a TX power at
    #                    all; the missing "m" is bluez saying so.
    #   "N dbm (0xNN)"   print_power_level - OUR controller answering an HCI read
    #                    such as Read Inquiry Response TX Power Level. Never a
    #                    remote device's. Currently dropped upstream by the
    #                    Command Complete filter in BtmonHandler#enqueue, so it
    #                    does not reach here; matched on anyway so that filter is
    #                    not load-bearing for correctness.
    #
    # One regex for all four meant every advertising report fed two different
    # quantities into one Text column, which then resolved them by LEXICAL sort
    # in Device.update_or_create_from_result - so "127 dBm" beat "3 dBm".
    ADVERTISED_TX_POWER_RE     = /\A(-?\d+) dBm\z/.freeze
    IBEACON_MEASURED_POWER_RE  = /\A(-?\d+) dB\z/.freeze

    # The fourth quantity: the LE (Extended) Advertising Report's own TX power
    # field holding 0x7f, which the spec defines as "information not available".
    # It shares its printed form with the real AD element above, so it can only be
    # recognised by value.
    #
    # Measured on a 9 minute capture: that field read 127 in all 974 samples
    # across 25 devices and never once anything else - exactly one per legacy PDU
    # carried in an extended report, because a legacy ADV_IND has no TX power to
    # report and the controller fills in the sentinel (like the "SID: no ADI
    # field (0xff)" printed beside it).
    #
    # Rejected for every source rather than just that field, because no Bluetooth
    # transmitter emits +127 dBm - that is 5x10^12 mW - so the value is junk
    # wherever it comes from.
    TX_POWER_UNAVAILABLE = 127

    attr_accessor :attributes

    # initializer which takes an Array of chunks to be parsed
    #
    # == Parameters :
    #   chunks ::
    #     Array of message chunks which are arrays of lines of btmon output
    def initialize(chunks=[])
      @chunks     = chunks
      @attributes = {}

      # the first chunk  will determine the mode (le/classic) these message
      # fall into. This mode will be used to differentiate between setting
      # le or classic attributes during the parsing of this batch of chunks
      if @chunks[0] && @chunks[0][1]
        @bt_mode = @chunks[0][1] =~ /^\s+LE/ ? "le" : "classic"
      end

      # Some HCI events (second line "Status:") carry NO transport indication,
      # so @bt_mode defaults to "classic". They must NOT assert a mode:
      #   * Read Remote Version/Supported Features/Extended Features Complete
      #   * Disconnect Complete - shared by BR/EDR *and* LE ACL links (the LE
      #     auto-connect churn produces a Disconnect Complete per attempt, each
      #     now carrying Handle+Address), so treating it as classic would stamp
      #     classic_mode=true on LE devices, flooding the classic info_scan_queue
      #     with LE devices and mislabeling them CL/BR.
      # For these events lmp_version/features are transport-agnostic and still
      # set; only the le_mode/classic_mode assertion is skipped. (Connect
      # Complete 0x03 is BR/EDR-only, so it legitimately asserts classic.)
      @mode_agnostic = !!(@chunks[0] && @chunks[0][0] &&
        @chunks[0][0] =~ /Read Remote (?:Version|Supported Features|Extended Features)|Disconnect Complete/)
    end

    # this ithe main work method which processes the @chunks Array
    # and populates the @attributes
    def parse
      @chunks.each do |chunk|

        # the first line is no longer useful as we have extracted the mode and
        # timestamp at other points in the pipeline. Time to discard it - but keep
        # it long enough to tell which event this chunk is (see @failed_status)
        header = chunk.shift

        # the last message will always be a timestamp from the chunker, this
        # value is used throughout during this parsing process but should
        # also be set to last_seen
        timestamp = chunk.pop
        set_attr(:last_seen, timestamp.split(': ')[1].to_i)

        unless @mode_agnostic
          if @bt_mode == "le"
            set_attr(:le_mode, true)
          elsif @bt_mode == "classic"
            set_attr(:classic_mode, true)
          end
        end

        # A failed Read Remote * Complete still carries a full payload, and it is
        # junk: status "Connection Failed to be Established" comes with LMP
        # version Reserved (0xff) and Manufacturer 65535. Recording that
        # overwrites a device's real version (observed on-device: 26 of 65 version
        # reads came back this way, every one with a failure status).
        #
        # Scoped to the Read Remote family so an unrelated event carrying a
        # Status cannot suppress good data, and checked per chunk.
        @failed_status = !!(header.to_s =~ /Read Remote/) &&
                         chunk.any? { |l| l =~ /^\s*Status:/ && l !~ /Status:\s+Success/ }

        # group the chunk of lines into nested / related groups of data
        # containing 1 or more lines
        grouped_chunk = group_by_depth(chunk)

        # handle each chunk of grouped data individually. The measured power is
        # per chunk, so it is cleared before each one rather than carried between
        # them - a beacon's calibration is not another chunk's to borrow.
        @ibeacon_measured_power = nil
        handle_grouped_chunk(grouped_chunk, @bt_mode, timestamp)

        # Derived once the chunk has been read, not inline with the RSSI line it
        # needs, because btmon prints RSSI first. See set_ibeacon_range.
        set_ibeacon_range(@bt_mode)
      end
    end

    # Estimate how far away an iBeacon is, from its measured power (the RSSI it
    # calibrates to one metre) and the RSSI we actually received.
    #
    # Called per chunk from #parse rather than from the RSSI line, which is what
    # made this dead code: in both report forms btmon prints RSSI before the
    # manufacturer data carrying the measured power, so the inline version was
    # reading a value that had not been parsed yet. Measured on a 9 minute
    # capture, 0 of 64 iBeacon chunks produced a range - and the CUI has a column
    # for it, so that column was permanently blank.
    #
    # Uses the RSSI this chunk just recorded (the last one appended), so the two
    # halves of the ratio come from the same advertising report.
    def set_ibeacon_range(bt_mode)
      return unless @ibeacon_measured_power

      rssi_entry = (@attributes["#{bt_mode}_rssi".to_sym] || []).last
      return unless rssi_entry && rssi_entry[:rssi]

      # Log-distance path loss with a path loss exponent of 2 (free space): the
      # measured power is the expected RSSI at 1m, so the shortfall against it in
      # dB converts to a power ratio and the distance is its square root.
      ratio_db     = @ibeacon_measured_power.to_i - rssi_entry[:rssi].to_i
      ratio_linear = 10 ** (ratio_db.to_f / 10)
      set_attr(:ibeacon_range, Math.sqrt(ratio_linear).round(2))
    end

    # An iBeacon proximity UUID in wire order, grouped 8-4-4-4-12, or nil if the
    # value is not a 16-byte UUID.
    #
    # The byte reversal is deliberate and correct: bluez prints this UUID reversed
    # from the wire (print_manufacturer_apple reads it back to front with
    # get_le32/get_le16 per group), so reversing the pairs recovers the wire bytes
    # exactly. Verified byte for byte against a raw capture payload - do not
    # "simplify" it away.
    #
    # Only the regrouping was ever wrong. It used to use four capture groups where
    # a UUID has five, emitting the trailing 16 characters as one blob -
    # "74278bda-b644-4520-8f0c720eaf059935" for what should be
    # "74278bda-b644-4520-8f0c-720eaf059935". The hex was right; a dash was
    # missing. Every iBeacon sighting was affected (64 of 64 in a 9 minute
    # capture). Existing records keep the old shape until each beacon is seen
    # again, which is accepted.
    #
    # Returns nil rather than a partial string on a value that does not fit,
    # because a truncated or empty UUID is worse than none: it is one of the keys
    # Device.update_or_create_from_result matches on when an address has rotated,
    # so two unrelated beacons that both failed to parse would collapse into one
    # record.
    PROXIMITY_UUID_GROUPS = /\A(\h{8})(\h{4})(\h{4})(\h{4})(\h{12})\z/.freeze

    def proximity_uuid(value)
      wire  = value.to_s.gsub('-', '').scan(/.{2}/).reverse.join
      match = PROXIMITY_UUID_GROUPS.match(wire)
      return nil unless match
      match.captures.join('-')
    end

    # The device's own advertised TX power for a "TX power:" value, or nil when
    # the line is one of the other three things wearing that label - see
    # ADVERTISED_TX_POWER_RE and TX_POWER_UNAVAILABLE.
    #
    # Returns the value unchanged rather than the parsed integer: the column is
    # Text and holds "3 dBm", and normalising it to a number is a separate change
    # (it would also fix Device.update_or_create_from_result resolving duplicates
    # by lexical sort).
    def advertised_tx_power(value)
      match = ADVERTISED_TX_POWER_RE.match(value.to_s)
      return nil unless match
      return nil if match[1].to_i == TX_POWER_UNAVAILABLE
      value
    end

    # The main parser case statement to handle grouped message data from a
    # given chunk
    #
    # == Parameters
    #   grouped_chunk ::
    #     Array of lines to be processed
    #   bt_mode ::
    #     String of "le" or "classic"
    #   timestamp ::
    #     Unix timestamp for when this message data was created
    def handle_grouped_chunk(grouped_chunk, bt_mode, timestamp)
      grouped_chunk.each do |grp|

        # when we only have a single line in a group we can handle simply
        if grp.count == 1
          line = grp[0]

          # next line was not nested, treat as single line
          parse_single_line(line, bt_mode, timestamp)

        # if we have multiple lines in our group of lines determine how to
        # process and set
        else
          case

          # these special messags had effectively duplicate header lines
          # which is be shifted off and then re-grouped
          when grp[0] =~ /^\s+(LE|ATT|L2CAP)/
            grp.shift
            grp = group_by_depth(grp)
            grp.each do |entry|
              if entry.count == 1
                line = entry[0]
                parse_single_line(line, bt_mode, timestamp)
              else
                handle_grouped_chunk(grp, bt_mode, timestamp)
              end
            end

          # Attribute type: Primary Service (0x2800)
          #  UUID: Unknown (7905f431-b5ce-4e99-a40f-4b1e122d00d0)
          when grp[0] =~ /^\s+Attribute type: Primary Service/
            vals = grp.map(&:strip)
            uuid = vals.select{|x| x =~ /^UUID/}[0]
            set_attr("#{bt_mode}_service_uuids".to_sym, uuid.split(': ')[1])

          when grp[0] =~ /^\s+Flags:/
            grp.shift
            vals = grp.map(&:strip)
            set_attr("#{bt_mode}_flags".to_sym, vals.join(", "))

          # An EXTENDED advertising report states the PDU's properties as a
          # bitmask with the bits named underneath:
          #
          #   Event type: 0x0013
          #     Props: 0x0013
          #       Connectable
          #       Scannable
          #       Use legacy advertising PDUs
          #
          # The Connectable bit is what decides whether a connect to this device
          # could ever succeed, so it is worth recording: an ADV_NONCONN_IND /
          # ADV_SCAN_IND advertiser cannot accept one. btmon carries the bit over
          # onto a scan response as well, so the flag is usable as-is without
          # having to special-case SCAN_RSP here.
          #
          # Matched on the group CONTAINING a Props bitmask rather than starting
          # with one: by the time the report's outer "LE Extended Advertising
          # Report" line has been shifted and the remainder re-grouped, this
          # group's first line is "Entry 0", with Event type and Props nested
          # under it.
          when grp.any? { |l| l =~ /^\s+Props: 0x/ }
            set_attr("#{bt_mode}_connectable".to_sym, grp.any? { |l| l.strip == "Connectable" })


          # Page: 1/1
          # Features: 0x07 0x00 0x00 0x00 0x00 0x00 0x00 0x00
          #   Secure Simple Pairing (Host Support)
          #   LE Supported (Host)
          #   Simultaneous LE and BR/EDR (Host)
          when grp[0] =~ /^\s+Page/
            page   = grp.shift.split(':')[1].strip.split('/')[0]
            bitmap = grp.shift.split(':')[1].strip
            vals = grp.map(&:strip)
            set_attr("#{bt_mode}_features_bitmap".to_sym, [page, bitmap])
            set_attr("#{bt_mode}_features".to_sym, vals.join(", "))

          # Features: 0x07 0x00 0x00 0x00 0x00 0x00 0x00 0x00
          #   Secure Simple Pairing (Host Support)
          #   LE Supported (Host)
          #   Simultaneous LE and BR/EDR (Host)
          when grp[0] =~ /^\s+Features/
            bitmap = grp.shift.split(':')[1].strip
            vals = grp.map(&:strip)

            # default page value is here set to '0'
            set_attr("#{bt_mode}_features_bitmap".to_sym, ['0',bitmap])
            set_attr("#{bt_mode}_features".to_sym, vals.join(", "))

          when grp[0] =~ /^\s+Channels/
            header = grp.shift.split(':')[1].strip
            vals = grp.map(&:strip)
            vals.unshift(header)
            set_attr("#{bt_mode}_channels".to_sym, vals.join(", "))

            # not in spec fixtures...
            # "        128-bit Service UUIDs (complete): 2 entries\r\n",
            # "          00000000-deca-fade-deca-deafdecacafe\r\n",
            # "          2d8d2466-e14d-451c-88bc-7301abea291a\r\n",
           when grp[0] =~ /128-bit Service UUIDs \((complete|partial)\):/
             grp.shift # header line
             vals = grp.map(&:strip)
             vals.each do |uuid|
               set_attr("#{bt_mode}_service_uuids".to_sym, uuid)
             end

           # Company: Apple, Inc. (76)
           #   Type: iBeacon (2)
           #   UUID: 7988f2b6-dc41-1291-8746-ecf83cc7a06c
           #   Version: 15104.61591
           #   TX power: -56 dB
           #   Data: 01adddd439aed386c76574e9ab9e11958e25c1f70ae203

           when grp[0] =~ /Company:/
             vals = grp.map(&:strip)

             #hack because datamapper doesn't respect varchar255 setting
             company_tmp = vals.shift.split(': ')[1]
             company_hex = company_tmp.scan(/\(([^)]+)\)/).flatten[0].to_i.to_s(16)
             if company_tmp.length > 49
               # Handle double paren companies
               if company_tmp.scan(/\(/).count == 2
                 company_tmp = company_tmp.split('(')
                 company_tmp.delete_at(1)
                 company_tmp = company_tmp.join('(')
               end
             end
             # Still too long? Cut the (number) off the end
             if company_tmp.length > 49
               if company_tmp.scan(/\(/).count == 1
                 company_tmp = company_tmp.split('(')
                 company_tmp = company_tmp[0]
               end
             end
             if company_tmp.length > 49
               BlueHydra.logger.warn("Attempted to handle long company and still too long:")
               BlueHydra.logger.warn("company_tmp: #{company_tmp}")
               BlueHydra.logger.warn("Truncating company...")
               company_tmp = company_tmp[0,49]
             end

             set_attr(:company, company_tmp)

             # Company can also contain multiple types....
             # so we need to reset the parsing on every Type line

             # Company: Apple, Inc. (76)
             #   Type: Unknown (12)
             #   Data: 00188218be794011f7678726540b
             #   Type: Unknown (16)
             #   Data: 1b1ca2bea2

             company_type = nil
             company_type_last_set = nil
             vals.each do |company_line|
               case
               when company_line =~ /^Type:/
                 company_type = company_line.split(': ')[1]
                 company_type_hex = company_type.scan(/\(([^)]+)\)/).flatten[0].to_i.to_s(16)
                 company_type_last_set = timestamp.split(': ')[1].to_f
                 set_attr(:company_type, company_type)
                 flipped_prox_uuid = nil
                 major = nil
                 minor = nil
               when company_line =~ /^UUID:/
                 if company_type && company_type =~ /\(2\)/ && company_type_last_set && company_type_last_set == timestamp.split(': ')[1].to_f
                   flipped_prox_uuid = proximity_uuid(company_line.split(': ')[1])
                   set_attr("#{bt_mode}_proximity_uuid".to_sym, flipped_prox_uuid) if flipped_prox_uuid
                 else
                   set_attr("#{bt_mode}_company_uuid".to_sym, company_line.split(': ')[1])
                 end
               when company_line =~/^Version:/
                 if company_type && company_type =~ /\(2\)/ && company_type_last_set && company_type_last_set == timestamp.split(': ')[1].to_f
                   #bluez decodes this as little endian but it's actually big so we have to reverse it
                   major = company_line.split(': ')[1].split('.')[0].to_i.to_s(16).rjust(4, '0').scan(/.{2}/).map { |i| i.to_i(16).chr }.join.unpack('S<*').first
                   minor = company_line.split(': ')[1].split('.')[1].to_i.to_s(16).rjust(4, '0').scan(/.{2}/).map { |i| i.to_i(16).chr }.join.unpack('S<*').first
                   set_attr("#{bt_mode}_major_num".to_sym, major)
                   set_attr("#{bt_mode}_minor_num".to_sym, minor)
                 else
                   set_attr("#{bt_mode}_company_version".to_sym, company_line.split(': ')[1])
                 end
               # An iBeacon's measured power - its calibrated RSSI at one metre -
               # which used to be stored as the device's TX power. It is neither
               # the same quantity nor the same unit (see
               # IBEACON_MEASURED_POWER_RE), and on a beacon that advertises no AD
               # Tx Power element it was the ONLY thing in le_tx_power, so that
               # column held a reference RSSI. It keeps its own attribute now and
               # feeds the range estimate in set_ibeacon_range.
               when company_line =~ /^TX power:/
                 measured = company_line.split(': ')[1]
                 if IBEACON_MEASURED_POWER_RE.match(measured.to_s)
                   @ibeacon_measured_power = measured
                   set_attr("#{bt_mode}_ibeacon_measured_power".to_sym, measured)
                 end
               when company_line =~ /^Data:/
                 set_attr("#{bt_mode}_company_data".to_sym, company_line.split(': ')[1])
               end
             end

           # not in spec fixtures...
           # "        16-bit Service UUIDs (complete): 7 entries\r\n",
           # "          PnP Information (0x1200)\r\n",
           # "          Handsfree Audio Gateway (0x111f)\r\n",
           # "          Phonebook Access Server (0x112f)\r\n",
           # "          Audio Source (0x110a)\r\n",
           # "          A/V Remote Control Target (0x110c)\r\n",
           # "          NAP (0x1116)\r\n",
           # "          Message Access Server (0x1132)\r\n",
           when grp[0] =~ /16-bit Service UUIDs \(complete\):/
             grp.shift # header line
             vals = grp.map(&:strip)
             vals.each do |uuid|
               set_attr("#{bt_mode}_uuids".to_sym, uuid)
             end

           # not in spec fixtures...
           # "        Class: 0x7a020c\r\n",
           # "          Major class: Phone (cellular, cordless, payphone, modem)\r\n",
           # "          Minor class: Smart phone\r\n",
           # "          Networking (LAN, Ad hoc)\r\n",
           # "          Capturing (Scanner, Microphone)\r\n",
           # "          Object Transfer (v-Inbox, v-Folder)\r\n",
           # "          Audio (Speaker, Microphone, Headset)\r\n",
           # "          Telephony (Cordless telephony, Modem, Headset)\r\n",
           when grp[0] =~ /Class:/
             grp = grp.map(&:strip)
             vals = []

             grp.each do |line|
               case
               when line =~ /^Class:/
                 vals << line.split(':')[1].strip
               when line =~ /^Major class:/
                 set_attr("#{bt_mode}_major_class".to_sym, line.split(':')[1].strip)
               when line =~ /^Minor class:/
                 set_attr("#{bt_mode}_minor_class".to_sym, line.split(':')[1].strip)
               else
                 vals << line
               end
             end

             set_attr("#{bt_mode}_class".to_sym, vals) unless vals.empty?

           when grp[0] =~ /^\s+Manufacturer/
             grp.map do |line|
              parse_single_line(line, bt_mode, timestamp)
            end

          else
            set_attr("#{bt_mode}_unknown".to_sym, grp.inspect)
          end
        end
      end
    end

    # Determine the depth of the whitespace characters in a line
    #
    # == Parameters
    #   line ::
    #     the line to test]
    # == Returns
    #   Integer value for number of whitespace chars
    def line_depth(line)
      whitespace = line.scan(/^([\s]+)/).flatten.first
      if whitespace
        whitespace.length
      else
        0
      end
    end

    def parse_single_line(line, bt_mode, timestamp)
      line = line.strip
      case

      # TODO make use of handle
      when line =~ /^Handle:/
        # The current btmon format can combine handle + address on ONE line:
        #   "Handle: 256 Address: AA:BB:CC:DD:EE:FF (Vendor)"
        # This case is matched before the Address case, so it MUST also pull the
        # address out here. Otherwise events that carry the device address only
        # on this combined line (Read Remote Version Complete, Read Remote
        # Supported/Extended Features, the LE connection-management subevents)
        # yield no :address, and the whole result is dropped in the parser thread
        # (address = (attrs[:address]||[]).uniq.first is nil) - which is exactly
        # why remote versions never reached the device record or the VERS column.
        set_attr("#{bt_mode}_handle".to_sym, line.split(': ')[1].split(' ').first)
        if line =~ /ddress: ((?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})/
          set_attr("address".to_sym, $1)
        end

      when line =~ /^Address:/ || line =~ /^Peer address:/ || line =~ /^LE Address:/
        addr, *addr_type = line.split(': ')[1].split(" ")
        set_attr("address".to_sym, addr)

        if bt_mode == "le"
          set_attr("le_random_address_type".to_sym, addr_type.join(' '))
        end

      when line =~ /^LMP version:/
        # only trust the version if the event carrying it succeeded (see
        # @failed_status) - a failed read reports Reserved (0xff)
        set_attr("lmp_version".to_sym, line.split(': ')[1]) unless @failed_status

      when line =~ /^Manufacturer:/
        # same event, same problem: a failed read reports 65535 here
        set_attr("manufacturer".to_sym, line.split(': ')[1]) unless @failed_status

      when line =~ /^UUID:/
        set_attr("#{bt_mode}_service_uuids".to_sym, line.split(': ')[1])

      when line =~ /^Address type:/
        set_attr("#{bt_mode}_address_type".to_sym, line.split(': ')[1])

      # A LEGACY advertising report names the PDU type on one line instead of
      # nesting a Props bitmask (see the grouped Event type case in
      # handle_grouped_chunk for the extended form):
      #
      #   Event type: Connectable undirected - ADV_IND (0x00)
      #   Event type: Non connectable undirected - ADV_NONCONN_IND (0x03)
      #   Event type: Scannable undirected - ADV_SCAN_IND (0x02)
      #   Event type: Scan response - SCAN_RSP (0x04)
      #
      # Only a name starting with "Connectable" means connectable - "Non
      # connectable" and "Scannable" (ADV_SCAN_IND) both do not. A scan response
      # says nothing either way, so it records nothing rather than recording
      # false. A bare "0x...." value is the extended form's bitmask arriving here
      # ungrouped; the flags are not on this line, so it is skipped too.
      when line =~ /^Event type:/
        value = line.split(': ', 2)[1].to_s
        unless value =~ /\A0x/ || value =~ /Scan response/i
          set_attr("#{bt_mode}_connectable".to_sym, !!(value =~ /\AConnectable/))
        end

      when line =~ /^TX power:/
        value = advertised_tx_power(line.split(': ')[1])
        set_attr("#{bt_mode}_tx_power".to_sym, value) if value

      when line =~ /^Name \(short\):/
        set_attr("short_name".to_sym, line.split(': ')[1])

      when line =~ /^Name:/ || line =~ /^Name \(complete\):/
        set_attr("name".to_sym, line.split(': ')[1])

      when line =~ /^Firmware:/
        set_attr(:firmware, line.split(': ')[1])

      when line =~ /^Service Data \(/
        #this has a lot of data, data that can change, data we don't really care about
        #(UUID 0xfe9f): 0000000000000000000000000000000000000000
        full_service_data = line.split('Service Data ')[1]
        extracted_service_uuid = full_service_data.scan(/\(([^)]+)\)/).flatten[0]
        #"UUID 0xfe9f"
        just_uuid = extracted_service_uuid.split('UUID ')[1]
        #0xfe9f
        # We are throwing multiple very different values into this field.  To normalize the output we *should*
        # do a lookup on this uuid and reformat to be "Information (0xefef)" to match the other sources
        # This gets wrapped as "Unknown (0xfe9f)" by device model, but we should do a lookup, probably in device
        # model, to read who registered this if possible.
        set_attr("#{bt_mode}_service_uuids".to_sym, just_uuid)

      #  "Appearance: Watch (0x00c0)"
      when line =~ /^Appearance:/
        set_attr(:appearance, line.split(': ')[1])

      # The iBeacon range used to be derived here, from a tx_power threaded in by
      # handle_grouped_chunk. It never fired: btmon prints RSSI BEFORE the
      # manufacturer data that carries the measured power, in both report forms,
      # so the value was always still nil at this point. See set_ibeacon_range,
      # which runs once the whole chunk has been read.
      when line =~ /^RSSI:/
        set_attr("#{bt_mode}_rssi".to_sym, {
          t: timestamp.split(': ')[1].to_i,
          rssi: line.split(': ')[1].split(' ')[0,2].join(' ')
        })


      else
        # we only might need to see this in debug mode, no need to take up the
        # memory
        if BlueHydra.config["log_level"] == 'debug'
          set_attr("#{bt_mode}_unknown".to_sym, line)
        end
        #BlueHydra.logger.warn("Unhandled line: #{line}")
      end
    end

    # group the lines of an array of lines in a chunk together by there depth
    #
    # == Parameters:
    #   arr ::
    #     Array of lines
    # == Returns:
    #   Array of arrays of grouped lines
    def group_by_depth(arr)
      output = []

      nested = false
      arr.each do |x|

        if output.last

          last_line = output.last[-1]

          if line_depth(last_line) == line_depth(x)

            if x =~ /Features:/ && last_line =~ /Page: \d/
              nested = true
            end

            if nested
              output.last << x
            else
              output << [x]
            end

          elsif line_depth(last_line) > line_depth(x)
            # we are outdenting
            nested = false
            output << [x]

          elsif line_depth(last_line) < line_depth(x)
            # we are indenting further
            nested = true
            output.last << x
          end
        else
          output << [x]
        end
      end

      output
    end

    # set an attribute key with a value in the @attributes hash
    #
    # This defaults the values in the @attributes to be an array of (ideally 1)
    # value so that we can test for mismatched messages
    #
    # == Parameters:
    #   key ::
    #     key to set
    #   val ::
    #     value to inject into the key in @attributes
    def set_attr(key, val)
      @attributes[key] ||= []
      @attributes[key] << val
    end
  end
end
