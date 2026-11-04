require 'securerandom'

module BlueHydra
  class CliUserInterfaceTracker
    attr_accessor :runner, :chunk, :attrs, :address, :uuid

    # Process-wide chunker health counters. Incremented from the chunker thread
    # and read by the CUI layer (the visual display is added separately). Kept
    # here so the CUI owns the status values it will surface.
    #
    # multi_address_chunk_count: chunks that carried more than one address
    #   line, even when the addresses are the same MAC. Message order is
    #   reliable while blue_hydra processes one device at a time, but will not
    #   be once it processes multiple devices concurrently, so this tracks how
    #   often chunks carry more than one address line.
    # zero_address_chunk_count: chunks the chunker discarded because they had no
    #   address at all.
    # multi_unique_address_chunk_count: chunks the chunker discarded because
    #   they had more than one unique address (a likely missing start block that
    #   merged two devices' data).
    # truncation_detected_count: btmon output lines detected as truncated/wrapped
    #   because btmon's column width is too small (which silently breaks
    #   parsing). Written by the btmon thread rather than the chunker thread.
    @multi_address_chunk_count        = 0
    @zero_address_chunk_count         = 0
    @multi_unique_address_chunk_count = 0
    @truncation_detected_count        = 0

    # Auto-connect health counters (written only by the discovery thread, single
    # writer, so plain increments are safe). Surfaced on the debug CUI line so a
    # regression like "adds climbing while connects stay flat" is visible live.
    # auto_connect_added_count:      devices successfully added (mgmt Add Device)
    # auto_connect_connected_count:  mgmt Device Connected events observed
    # auto_connect_failed_count:     mgmt Connect Failed events observed. Note the
    #   kernel only emits this for an explicit connect attempt - a background
    #   auto-connect that never sees the device advertise produces no event at
    #   all, and lands in auto_connect_timeout_count instead.
    # auto_connect_add_failed_count: mgmt Add Device calls that were refused, or
    #   whose reply did not arrive within Mgmt::DEFAULT_TIMEOUT (Runner#add_to_
    #   auto_connect rescues that timeout so one slow device does not end the
    #   discovery cycle)
    # auto_connect_timeout_count:    devices added that never connected before the
    #   CONNECT phase ended (neither Connected nor Connect Failed). Without this
    #   those devices were missing from the arithmetic and added never reconciled
    #   with connected + failed.
    #
    # Direct-connect counters, for the private-address devices mgmt Add Device
    # cannot accept (see BlueHydra::LeConnect):
    # le_direct_connected_count: direct connects that raised a link
    # le_direct_failed_count:    direct connects that did not (unreachable/error)
    # le_direct_dropped_count:   requests discarded from a full backlog, never tried
    # le_direct_abandoned_count: connects still in flight when the discovery-off
    #   budget ran out. Distinct from failed on purpose: a rising number here means
    #   the budget is the binding constraint, not that devices are unreachable.
    # le_direct_conn_limit_count: connects the local controller refused with
    #   EMLINK (LeConnect outcome :conn_limit) because it had no free link slot.
    #   Distinct from failed and error on purpose, and never a ConnectTracker
    #   strike: the refusal is the controller's, not the device's. A rising number
    #   with gatt_scan on means held links are exhausting the controller, and
    #   lowering gatt_walk_parallel is the lever.
    @auto_connect_added_count         = 0
    @auto_connect_connected_count     = 0
    @auto_connect_failed_count        = 0
    @auto_connect_add_failed_count    = 0
    @auto_connect_timeout_count       = 0
    @le_direct_connected_count        = 0
    @le_direct_failed_count           = 0
    @le_direct_dropped_count          = 0
    @le_direct_abandoned_count        = 0
    @le_direct_error_count            = 0
    @le_direct_conn_limit_count       = 0

    class << self
      attr_accessor :multi_address_chunk_count,
                    :zero_address_chunk_count,
                    :multi_unique_address_chunk_count,
                    :truncation_detected_count,
                    :auto_connect_added_count,
                    :auto_connect_connected_count,
                    :auto_connect_failed_count,
                    :auto_connect_add_failed_count,
                    :auto_connect_timeout_count,
                    :le_direct_connected_count,
                    :le_direct_failed_count,
                    :le_direct_dropped_count,
                    :le_direct_abandoned_count,
                    :le_direct_error_count,
                    :le_direct_conn_limit_count
    end

    # Increment helpers. Each counter has a single writer thread (the chunker
    # for the chunk counters, the btmon thread for truncation_detected_count),
    # so plain increments are safe.
    def self.increment_multi_address_chunk_count
      @multi_address_chunk_count += 1
    end

    def self.increment_zero_address_chunk_count
      @zero_address_chunk_count += 1
    end

    def self.increment_multi_unique_address_chunk_count
      @multi_unique_address_chunk_count += 1
    end

    def self.increment_truncation_detected_count
      @truncation_detected_count += 1
    end

    def self.increment_auto_connect_added_count
      @auto_connect_added_count += 1
    end

    def self.increment_auto_connect_connected_count
      @auto_connect_connected_count += 1
    end

    def self.increment_auto_connect_failed_count
      @auto_connect_failed_count += 1
    end

    def self.increment_auto_connect_add_failed_count
      @auto_connect_add_failed_count += 1
    end

    def self.increment_auto_connect_timeout_count
      @auto_connect_timeout_count += 1
    end

    def self.increment_le_direct_connected_count
      @le_direct_connected_count += 1
    end

    def self.increment_le_direct_failed_count
      @le_direct_failed_count += 1
    end

    def self.increment_le_direct_dropped_count
      @le_direct_dropped_count += 1
    end

    def self.increment_le_direct_abandoned_count
      @le_direct_abandoned_count += 1
    end

    def self.increment_le_direct_error_count
      @le_direct_error_count += 1
    end

    def self.increment_le_direct_conn_limit_count
      @le_direct_conn_limit_count += 1
    end

    # Fill a row's NAME cell from a GATT Device Name (0x2A00) read during a
    # Walk (Requirements 13.13, 13.14).
    #
    # The NAME cell has three possible sources, recorded in the row's
    # :name_source, and they rank complete > gatt > short:
    #   :complete  btmon `Name:` / `Name (complete):`, written by
    #              update_cui_status and overwriting anything on change
    #   :gatt      this method; replaces a shortened name or an empty cell but
    #              never a complete name
    #   :short     btmon `Name (short):`, written by update_cui_status only
    #              into an empty cell
    # So a later complete name replaces either of the others, a later GATT name
    # replaces only a shortened name or an empty cell, and a later shortened
    # name fills only an empty cell.
    #
    # Rows are keyed by the tracker's internal uuid, not by address, so the row
    # is found by its :address. A row is never created here: an address the
    # table has not seen stays absent, and a nil / empty / non-String name is
    # a no-op. Only cui_status is touched; the Device `name` column is never
    # written on this path (Requirement 12.9).
    #
    # Threads. cui_status is written by the parser thread alone: rows through
    # update_cui_status, once per chunk, and names through this method, which
    # Runner#drain_cui_names calls on that same thread after every chunk and
    # every 0.5 s pop timeout, with the pairs the GATT scanner's Walk threads
    # put on cui_name_queue. The result thread never writes cui_status: it
    # sits behind database writes that would delay a table the operator
    # watches live. The CUI thread reads the rows and prunes expired ones in
    # CliUserInterface#cui_status with no mutex, the GVL-only posture that
    # exists today; Hash#values takes its snapshot atomically in MRI, and a
    # write that lands on a row the CUI thread has just pruned is harmless
    # because nothing reads that row again.
    #
    # Returns true when the cell was written, false otherwise.
    def self.apply_gatt_device_name(cui_status, address, name)
      return false unless name.is_a?(String) && !name.empty?

      row = cui_status.values.find { |r| r[:address] == address }
      return false unless row
      return false if row[:name_source] == :complete

      row[:name]        = name
      row[:name_source] = :gatt
      true
    end

    # This method initializes with a runner and some data and then handles
    # updating the cui_status to track the devices for the CUI
    #
    # == Parameters:
    #   run ::
    #     BlueHydra::Runner instance
    #   attrs ::
    #     record attributes to update with
    #   addr ::
    #     device addr
    def initialize(run, chnk, attrs, addr)
      @runner = run
      @chunk = chnk #todo, rm, deprecated
      @attrs = attrs
      @address = addr

      cui_k = cui_status.keys
      cui_v = cui_status.values

      match1 = cui_v.select{|x|
        x[:address] == @address
      }.first

      # if there is already a key with this address get the uuid from the
      # keys
      if match1
        @uuid = cui_k[cui_v.index(match1)]
      end

      # if we don't have uuid attempt a second match using le meta info
      unless @uuid
        @lpu  = attrs[:le_proximity_uuid].first if attrs[:le_proximity_uuid]
        @lmn  = attrs[:le_major_num].first      if attrs[:le_major_num]
        @lmn2 = attrs[:le_minor_num].first      if attrs[:le_minor_num]

        match2 = cui_v.select{|x|
          x[:le_proximity_uuid] && x[:le_proximity_uuid] == @lpu &&
          x[:le_major_num]      && x[:le_major_num]      == @lmn &&
          x[:le_minor_num]      && x[:le_minor_num]      == @lmn2
        }.first

        if match2
          @uuid = cui_k[cui_v.index(match2)]
        end
      end

      # if we don't have a uuid attempt a third match using company meta info
      unless @uuid
        @c = attrs[:company].first.split('(').first if attrs[:company]
        @d = attrs[:le_company_data].first          if attrs[:le_company_data]

        match3 = cui_v.select{|x|
          x[:company]          && x[:company] == @c &&
          x[:le_company_data]  && x[:le_company_data] == @d
        }.first

        if match3
          @uuid = cui_k[cui_v.index(match3)]
        end
      end

      # if still no uuid, generate a random one
      unless @uuid
        @uuid = SecureRandom.uuid
      end
    end

    # alias for cui status blob from the runner object
    def cui_status
      runner.cui_status
    end

    # update the cui_status in the runner
    def update_cui_status
      # initialize with a created timestampe or leave alone if uuid already exits
      cui_status[@uuid] ||= {created: Time.now.to_i}

      # update lap unless we have one
      cui_status[@uuid][:lap] = address.split(":")[3,3].join(":") unless cui_status[@uuid][:lap]

      # test to see if the data chunk is le or classic
      if chunk[0] && chunk[0][0]
        bt_mode = chunk[0][0] =~ /^\s+LE/ ? "le" : "classic"
      end

      # Remember which transport(s) we've actually seen this device on. A remote
      # version read arrives in a transport-agnostic chunk (parsed as classic),
      # so we must NOT label it from that chunk's mode - use the device's known
      # transport instead. Prefer LE when the device has ever been seen on LE
      # (the version chunk itself may spuriously set :classic; :le-first wins).
      cui_status[@uuid][:le]      = true if bt_mode == "le"
      cui_status[@uuid][:classic] = true if bt_mode == "classic"

      # use lmp version to make a simplified copy of the version for table
      # display, set as :vers under the uuid key
      if attrs[:lmp_version] && attrs[:lmp_version].first !~ /\(0x(00|FF)\)/i
        prefix = cui_status[@uuid][:le] ? "LE" : "CL"
        cui_status[@uuid][:vers] = "#{prefix}#{attrs[:lmp_version].first.split(" ")[1]}"
      elsif !cui_status[@uuid][:vers]
        cui_status[@uuid][:vers] = bt_mode == "le" ? "BTLE" : "CL/BR"
      end

      # update the following attributes with a little of massaging to get the
      # attributes more presentable for human consumption
      [
        :last_seen, :name, :address, :classic_rssi, :le_rssi,
        :le_proximity_uuid, :le_major_num, :le_minor_num, :ibeacon_range,
        :company, :le_company_data
      ].each do |key|
        if attrs[key] && attrs[key].first
          # A complete name (btmon `Name:` / `Name (complete):`) tops the NAME
          # precedence (see apply_gatt_device_name). Record its source even when
          # the text is unchanged below: the same text may already sit in the
          # cell from a GATT read, and :complete is what stops a later GATT
          # Device Name replacing it.
          cui_status[@uuid][:name_source] = :complete if key == :name

          if cui_status[@uuid][key] != attrs[key].first
            # The newest reading in the batch. A batch can hold many advertising
            # reports for one device, and .first showed the oldest of them - so a
            # device walking away read stronger than it was.
            if key == :le_rssi || key == :classic_rssi
              cui_status[@uuid][:rssi] = attrs[key].last[:rssi].gsub('dBm','')
            # The newest estimate, not .first like its neighbours. The parser emits
            # one range per chunk, so a batch holds a series of estimates for a
            # beacon that is probably moving, and .first is the oldest of them.
            # Device.update_or_create_from_result stores .last for the same reason;
            # the table a human watches during a run should not disagree with what
            # went into the DB.
            elsif key == :ibeacon_range
              cui_status[@uuid][:range] = "#{attrs[key].last}m"
            elsif key == :company
              cui_status[@uuid][:company] = attrs[key].first.split('(').first
            else
              cui_status[@uuid][key] = attrs[key].first
            end
          end
        end
      end

      # simplified copy of internal tracking uuid
      cui_status[@uuid][:uuid] = @uuid.split('-')[0]

      # if we have a short name set it as the name attribute, but only into an
      # empty cell: a shortened name is the bottom of the NAME precedence and
      # never displaces a complete or GATT name (see apply_gatt_device_name)
      if attrs[:short_name]
        unless attrs[:short_name] == [nil] || cui_status[@uuid][:name]
          cui_status[@uuid][:name]        = attrs[:short_name].first
          cui_status[@uuid][:name_source] = :short
          #BlueHydra.logger.warn("short name found: #{attrs[:short_name]}")
        end
      end

      # set appearance
      if attrs[:appearance]
        cui_status[@uuid][:type] = attrs[:appearance].first.split('(').first
      end

      # set minor class or as uncategorized as appropriate
      if attrs[:classic_minor_class]
        if attrs[:classic_minor_class].first =~ /Uncategorized/i
          cui_status[@uuid][:type] = "Uncategorized"
        else
          cui_status[@uuid][:type] = attrs[:classic_minor_class].first.split('(').first
        end
      end

      # set :manuf key from a few different fields or Louis gem depending on a
      # few conditions, we are overloading this field so its populated
      if [nil, "Unknown"].include?(cui_status[@uuid][:manuf])
        if bt_mode == "classic" || (attrs[:le_address_type] && attrs[:le_address_type].first =~ /public/i)
            vendor = Louis.lookup(address)

            cui_status[@uuid][:manuf] = if vendor["short_vendor"]
                                            vendor["short_vendor"]
                                          else
                                            vendor["long_vendor"]
                                          end
        else
          cmp = nil

          if attrs[:company_type] && attrs[:company_type].first !~ /unknown/i
            cmp = attrs[:company_type].first
          elsif attrs[:company] && attrs[:company].first !~ /not assigned/i
            cmp = attrs[:company].first
          elsif attrs[:manufacturer] && attrs[:manufacturer].first !~ /\(65535\)/
            cmp = attrs[:manufacturer].first
          else
            cmp = "Unknown"
          end

          if cmp
            cui_status[@uuid][:manuf] = cmp.split('(').first
          end
        end
      end
    end
  end
end
