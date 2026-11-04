# this is the bluetooth Device model stored in the DB
class BlueHydra::Device

  attr_accessor :filthy_attributes

  # this is a DataMapper model...
  include DataMapper::Resource

  # Attributes for the DB
  property :id,                            Serial

  # TODO: migrate this column to be called sync_id
  # unique_index enforces sync-id uniqueness at the DB level (created by
  # DataMapper.auto_upgrade! on startup) so we don't need a per-new-device
  # existence query on the hot path. See #set_uuid and #save for how a (wildly
  # unlikely) collision is handled. unique_index (rather than :unique) is used
  # deliberately: it only adds the index, it does not add a dm-validations
  # uniqueness check that would re-introduce a query on every save.
  property :uuid,                          String, unique_index: true

  property :name,                          String
  property :status,                        String
  property :address,                       String
  property :uap_lap,                       String

  property :vendor,                        Text
  property :appearance,                    String
  property :company,                       String
  property :company_type,                  String
  property :lmp_version,                   String
  property :manufacturer,                  String
  property :firmware,                      String

  # classic mode specific attributes
  property :classic_mode,                  Boolean, default: false
  property :classic_service_uuids,         Text
  property :classic_channels,              Text
  property :classic_major_class,           String
  property :classic_minor_class,           String
  property :classic_class,                 Text
  property :classic_rssi,                  Text
  property :classic_tx_power,              Text
  property :classic_features,              Text
  property :classic_features_bitmap,       Text

  # low energy mode specific attributes
  property :le_mode,                       Boolean, default: false
  property :le_service_uuids,              Text
  property :le_address_type,               String
  property :le_random_address_type,        String
  property :le_company_data,               String, :length => 255
  property :le_company_uuid,               String
  property :le_proximity_uuid,             String
  property :le_major_num,                  String
  property :le_minor_num,                  String
  property :le_flags,                      Text
  property :le_rssi,                       Text
  property :le_tx_power,                   Text
  property :le_features,                   Text
  property :le_features_bitmap,            Text
  # Whether the advertisement said a connect to this device could succeed, taken
  # from the Connectable bit of an extended advertising report's Props bitmask.
  #
  # Boolean rather than the Text most le_* columns use, because it is one bit off
  # one bitmask and not an accumulated set - so it is deliberately absent from
  # is_serialized? and from the "update array attributes" list.
  #
  # No default, unlike le_mode/classic_mode: nil means "no advertisement has
  # carried a Props block yet", which is a different claim from an observed
  # false. EMPTY_SYNC_VALUES drops nil but not false, so an unobserved device
  # sends nothing while an observed non-connectable one sends false.
  property :le_connectable,                Boolean
  # Distance estimate, derived from le_ibeacon_measured_power and the RSSI we
  # received. Deliberately NOT synced: it is a pure function of two values that
  # ARE synced, so anything downstream can derive it - and derive it better, from
  # the whole le_rssi series rather than one scalar, with a path loss exponent of
  # its choosing rather than the free-space 2 baked in here. Kept as a column
  # because the CUI's range field reads it.
  property :ibeacon_range,                 String
  # An iBeacon's calibrated RSSI at one metre, which is what it broadcasts in
  # place of a TX power. Kept apart from le_tx_power because it is a different
  # quantity in different units (dB, not dBm) - conflating the two is what put a
  # reference RSSI in the TX power column.
  #
  # Synced, and cheap to sync: it is a per-beacon calibration constant, so it goes
  # clean after the first sighting and the change gate never sends it again. It is
  # the half of the distance calculation the cloud could not otherwise get.
  property :le_ibeacon_measured_power,     String

  # GATT, populated only by Walk results on LE devices (see BlueHydra::GattWalker).
  # Text throughout: identity values may be 512 chars decoded / 1,024 hex chars,
  # over the 255 String default, and the two lists are JSON. Never written from
  # advertisement results and never overwriting name/appearance/manufacturer/firmware.
  #
  # The two lists carry an explicit length because dm-validations infers a
  # validates_length_of from a Text's default length of 65,535, and valid? would
  # then refuse the lists Requirement 11.13 says must store: gatt_characteristics
  # runs to the 262,144-byte cap, and 1,000 service UUIDs with the longest Nordic
  # names run to some 95,000 characters. The cap is the bound for both; the
  # column type in SQLite is TEXT either way.
  property :gatt_service_uuids,     Text, length: BlueHydra::GattCharacteristics::MAX_BYTES   # JSON array of Uuid_Formatter strings, merged union, ordered by 128-bit value
  property :gatt_characteristics,   Text, length: BlueHydra::GattCharacteristics::MAX_BYTES   # JSON array of entry objects (GattCharacteristics schema), ordered by value_handle
  property :gatt_database_hash,     Text   # 32 lowercase hex chars
  property :gatt_device_name,       Text
  property :gatt_appearance,        Text   # "0xNNNN"
  property :gatt_manufacturer_name, Text
  property :gatt_model_number,      Text
  property :gatt_serial_number,     Text
  property :gatt_firmware_revision, Text
  property :gatt_hardware_revision, Text
  property :gatt_software_revision, Text
  property :gatt_system_id,         Text   # 16 lowercase hex chars
  property :gatt_pnp_id,            Text   # "0xSS 0xVVVV 0xPPPP 0xRRRR"

  # Every Gatt_Columns entry: the allowlist a Walk result may write, and what
  # update_or_create_from_result, syncable_attributes and is_serialized? draw on
  # below. The two JSON lists, the Database Hash, then the ten identity strings.
  GATT_COLUMNS = %i[gatt_service_uuids gatt_characteristics gatt_database_hash gatt_device_name
                    gatt_appearance gatt_manufacturer_name gatt_model_number gatt_serial_number
                    gatt_firmware_revision gatt_hardware_revision gatt_software_revision
                    gatt_system_id gatt_pnp_id].freeze

  # Walk result identity key (a GattWalker::IDENTITY_SET value, the key under
  # which the Walk reports that characteristic's decoded value) => the column
  # holding it. One column per Identity_Set characteristic, Database Hash
  # included: the Walk reports a read 0x2B2A both here and as the result's
  # top-level database_hash.
  GATT_IDENTITY_COLUMNS = {
    device_name:       :gatt_device_name,
    appearance:        :gatt_appearance,
    manufacturer_name: :gatt_manufacturer_name,
    model_number:      :gatt_model_number,
    serial_number:     :gatt_serial_number,
    firmware_revision: :gatt_firmware_revision,
    hardware_revision: :gatt_hardware_revision,
    software_revision: :gatt_software_revision,
    system_id:         :gatt_system_id,
    pnp_id:            :gatt_pnp_id,
    database_hash:     :gatt_database_hash
  }.freeze

  # The identity keys are the walker's, so a key renamed or added on one side
  # only would silently leave a column unwritten. Fail at load instead.
  unless GATT_IDENTITY_COLUMNS.keys.sort == BlueHydra::GattWalker::IDENTITY_SET.values.sort
    raise "GATT_IDENTITY_COLUMNS keys #{GATT_IDENTITY_COLUMNS.keys.inspect} do not match " \
          "GattWalker::IDENTITY_SET values #{BlueHydra::GattWalker::IDENTITY_SET.values.inspect}"
  end

  property :created_at,                    DateTime
  property :updated_at,                    DateTime
  property :last_seen,                     Integer

  # regex to validate macs
  MAC_REGEX    = /^((?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2})$/i

  # validate the address. the only validation currently
  validates_format_of :address, with: MAC_REGEX

  # before saving set the vendor info and the mode flags (le/classic)
  before :save, :set_vendor
  before :save, :set_uap_lap
  before :save, :set_uuid
  before :save, :prepare_the_filth

  # after saving send up to pulse
  after  :save, :sync_to_pulse

  # after saving send up to stream builder
  after  :save, :sync_to_stream_builder

  # 1 week in seconds == 7 * 24 * 60 * 60 == 604800
  def self.sync_all_to_pulse(since=Time.at(Time.now.to_i - 604800))
    BlueHydra::Device.all(:updated_at.gte => since).each do |dev|
      dev.sync_to_pulse(true)
    end
  end

  # sync all recently updated devices to stream builder. Mirrors
  # sync_all_to_pulse. Also emits a gauge metric of how many devices were
  # synced so we have visibility into the size of each bulk sync.
  #
  # 1 week in seconds == 7 * 24 * 60 * 60 == 604800
  def self.sync_all_to_stream_builder(since=Time.at(Time.now.to_i - 604800))
    return unless BlueHydra.stream_builder || BlueHydra.stream_builder_debug
    count = 0
    BlueHydra::Device.all(:updated_at.gte => since).each do |dev|
      dev.sync_to_stream_builder(true)
      count += 1
    end
    BlueHydra::StreamBuilder.send_event("devices_synced_bulk", count)
  end

  # mark hosts as 'offline' if we haven't seen for a while
  def self.mark_old_devices_offline(startup=false)
    if startup
      # efficiently kill old things with fire
      if DataMapper.repository.adapter.select("select uuid from blue_hydra_devices where updated_at between \"1970-01-01\" AND \"#{Time.at(Time.now.to_i-1209600).to_s.split(" ")[0]}\" limit 5000;").count == 5000
        DataMapper.repository.adapter.select("delete from blue_hydra_devices where updated_at between \"1970-01-01\" AND \"#{Time.at(Time.now.to_i-1209600).to_s.split(" ")[0]}\" ;")
        BlueHydra::Pulse.hard_reset
      end

      # unknown mode devices have 15 min timeout (SHOULD NOT EXIST, BUT WILL CLEAN
      # OLD DBS)
      BlueHydra::Device.all(
        le_mode:          false,
        classic_mode:     false,
        status:           "online",
        :last_seen.lt  => (Time.now.to_i - (15*60))
      ).each{|device|
        mark_offline(device)
        device.save
      }
    end

    # Kill old things with fire
    BlueHydra::Device.all(:updated_at.lte => Time.at(Time.now.to_i - 604800*2)).each do |dev|
      mark_offline(dev)
      dev.sync_to_pulse(true)
      BlueHydra.logger.debug("Destroying #{dev.address} #{dev.uuid}")
      dev.destroy
    end

    # classic mode devices have 15 min timeout
    BlueHydra::Device.all(
      classic_mode:    true,
      status:          "online",
      :last_seen.lt => (Time.now.to_i - (15*60))
    ).each{|device|
      mark_offline(device)
      device.save
    }

    # le mode devices have 3 min timeout
    BlueHydra::Device.all(
      le_mode:         true,
      status:          "online",
      :last_seen.lt => (Time.now.to_i - (60*3))
    ).each{|device|
      mark_offline(device)
      device.save
    }
  end

  # Mark a device offline and drop the in-memory connect policy we hold for it.
  #
  # Strikes must not outlive the sighting that earned them: a device that goes
  # away and comes back - power cycled, moved, or simply a private address that
  # has rotated - gets a clean slate rather than inheriting a write-off from
  # before. This is the only expiry mechanism the strike counter has besides a
  # successful connect, which is why every offline transition goes through here.
  #
  # Deliberately does NOT save; each caller owns its own save/destroy/sync.
  def self.mark_offline(device)
    device.status = 'offline'
    BlueHydra::ConnectTracker.forget(device.address)
    # Drops the Resume_State only (Requirement 17.8); the Finished_Walk record
    # stays so a device that comes back inside info_scan_rate is still
    # rate-limited to a hash check or a skip rather than a full re-walk.
    BlueHydra::GattTracker.forget(device.address)
  end

  # this class method is take a result Hash and convert it into a new or update
  # an existing record
  #
  # == Parameters :
  #   result ::
  #     Hash of results from parser, or a Walk result from GattScanner#walk_result
  def self.update_or_create_from_result(result)
    # A Walk result travels on the same result_queue as parser output but is
    # a different shape (its address is a String, the parser's an Array) and
    # may only update a record that already exists, so it takes its own path
    # before anything below reads the hash.
    return apply_gatt_result(result) if result[:gatt_walk]

    result = result.dup

    address = result[:address].first

    lpu  = result[:le_proximity_uuid].first if result[:le_proximity_uuid]
    lmn  = result[:le_major_num].first      if result[:le_major_num]
    lmn2 = result[:le_minor_num].first      if result[:le_minor_num]

    c = result[:company].first              if result[:company]
    d = result[:le_company_data].first      if result[:le_company_data]

    record = self.all(address: address).first ||
             self.find_by_uap_lap(address) ||
             (lpu && lmn && lmn2 && self.all(
               le_proximity_uuid: lpu,
               le_major_num: lmn,
               le_minor_num: lmn2
             ).first) ||
             (c && d && c =~ /Gimbal/i && self.all(
               le_company_data: d
             ).first) ||
             self.new

    # if we are processing things here we have, implicitly seen them so
    # mark as online?
    record.status = "online"

    # set last_seen or default value if missing
    if result[:last_seen] &&
      result[:last_seen].class == Array &&
      !result[:last_seen].empty?
      record.last_seen = result[:last_seen].sort.last # latest value
    else
      record.last_seen = Time.now.to_i
    end

    # update normal attributes
    #
    # The eleven scalar Gatt_Columns (GATT_IDENTITY_COLUMNS.values) are accepted
    # here as single-valued attributes like name or manufacturer, which makes
    # them part of the result-key allowlist (Requirement 11.3). Nothing feeds
    # them through this loop today: the parser's advertisement results carry no
    # gatt_* key, and a Walk result reports its identity values under its own
    # keys (identity, database_hash; see GattWalker), not under column names.
    (%w{
      address name manufacturer short_name lmp_version firmware
      classic_major_class classic_minor_class le_tx_power classic_tx_power
      le_address_type company appearance
      le_random_address_type le_company_uuid le_company_data le_proximity_uuid
      le_major_num le_minor_num classic_mode le_mode le_ibeacon_measured_power
    }.map(&:to_sym) + GATT_IDENTITY_COLUMNS.values).each do |attr|
      if result[attr]
        # we should only get a single value for these so we need to warn if
        # we are getting multiple values for these keys.. it should NOT be...
        if result[attr].uniq.count > 1
          BlueHydra.logger.debug(
            "#{address} multiple values detected for #{attr}: #{result[attr].inspect}. Using first value..."
          )
        end
        record.send("#{attr.to_s}=", result.delete(attr).uniq.sort.first)
      end
    end

    # The distance estimate, which until now the parser computed (when it computed
    # it at all) into a result key nothing ever read - it was in neither list
    # below, so the column stayed NULL and the CUI's range field stayed blank.
    #
    # Takes the LAST value rather than the .sort.first the loop above applies,
    # because these are successive estimates of a moving target: sorting would
    # pick the smallest number in the batch, i.e. the closest the beacon ever got
    # rather than where it is now.
    if result[:ibeacon_range]
      record.ibeacon_range = result.delete(:ibeacon_range).last
    end

    # le_connectable fits neither list above. The normal-attribute loop reduces
    # with .uniq.sort.first, and booleans are not Comparable - a batch carrying
    # both values raises "comparison of TrueClass with false failed". The array
    # loop hands the whole array to the setter, which is wrong for a scalar
    # Boolean column.
    #
    # So: OR-reduce. "Advertised connectable at least once in this batch" is also
    # the reading that matches how the runner feeds ConnectTracker.
    unless result[:le_connectable].nil?
      record.le_connectable = result[:le_connectable].any?
    end

    # this is probably a band-aie, likely devices have multiple company type elements
    #update flappy company_type
    if result[:company_type]
      data = result.delete(:company_type).uniq.sort.first
      if data =~ /Unknown/
        data = "Unknown"
        record.send("#{:company_type}=", data)
      end
    end

    # update array attributes
    #
    # The two list Gatt_Columns sit here because their setters below take the
    # whole Array and store it as JSON, like le_service_uuids. Same as above,
    # no result reaches this loop with these keys today.
    %w{
      classic_features le_features le_flags classic_channels classic_class le_rssi
      classic_rssi le_service_uuids classic_service_uuids le_features_bitmap classic_features_bitmap
      gatt_service_uuids gatt_characteristics
    }.map(&:to_sym).each do |attr|
      if result[attr]
        record.send("#{attr.to_s}=", result.delete(attr))
      end
    end

    if record.valid?
      record.save
      if self.all(uap_lap: record.uap_lap).count > 1
        BlueHydra.logger.warn("Duplicate UAP/LAP detected: #{record.uap_lap}.")
      end
    else
      BlueHydra.logger.warn("#{address} can not save.")
      record.errors.keys.each do |key|
        BlueHydra.logger.warn("#{key.to_s}: #{record.errors[key].inspect} (#{record[key]})")
      end
    end

    record
  end

  # Apply a Walk result (the hash GattScanner#walk_result builds, tagged
  # gatt_walk: true) to the Device record with its address, writing the
  # Gatt_Columns, status and last_seen and nothing else. Returns the record, or
  # nil when no record has the address. Reached through
  # update_or_create_from_result on the Result_Thread, which is therefore the
  # only writer of Gatt_Columns (Requirement 11.2).
  #
  # == Which record
  #
  # The one whose address equals the result's, compared case-insensitively,
  # and no other. The Walk ran over a Link to this address, so the
  # advertisement that got it connected already made its record; without one
  # the result is logged at debug and dropped. There is no UAP/LAP fallback
  # and no record is created (Requirement 11.14): an LE private address
  # shares its lower octets with nothing in particular, and a record made
  # here would carry none of the advertisement data every other record has.
  #
  # == What changes
  #
  # status becomes online and last_seen the later of its stored value and the
  # Walk's end (11.4). name, appearance, manufacturer, firmware, lmp_version
  # and every classic_* and le_* column are not touched: the GATT identity
  # values go to their own gatt_* columns (11.4).
  #
  # gatt_service_uuids becomes the ordered, de-duplicated union of the stored
  # list and the result's service UUIDs (11.5), cut to MAX_ENTRIES with one
  # warning naming the address, the column and the count dropped (11.17). A
  # result adding no UUID leaves the text byte-identical (12.7).
  #
  # gatt_characteristics, by Walk_Outcome, after the Database Hash rule below
  # has or has not cleared the stored list:
  #
  #   complete                  replaced by the result's list (11.6)
  #   partial, non-empty list   replaced (11.7): the Walk reached the database
  #                             end, so its list is the whole structure less
  #                             what it could not read
  #   timeout, disconnected     merged by value handle, the result's entry
  #                             winning and no stored entry dropped (11.8,
  #                             17.4), so resumed Walks accumulate
  #   protected, empty partial  left as it is (11.16)
  #
  # A replaced or merged list is trimmed to the caps before it is stored, raw_hex
  # largest-first and then whole entries from the top handle down, with one
  # warning naming the address, the bytes before and after, the raw_hex fields
  # removed and the entries dropped, only when something was (11.18, 11.19).
  #
  # == Database Hash (11.9, 17.6)
  #
  # gatt_database_hash is the hash the stored gatt_characteristics were built
  # for, written whenever a result carries one. The stored list is cleared,
  # before the outcome rule above runs, when either
  #
  #   * the result's hash_changed is true: the Walk's hash check read a hash
  #     other than the one the Gatt_Tracker had recorded and walked the
  #     changed database from scratch (17.6), or
  #   * the result carries a hash, the record holds one, and they differ: a
  #     Walk with no hash check read a hash other than the stored list's. That
  #     is every address's first Walk after a restart, the Gatt_Tracker being
  #     in memory, and a hash check whose read was unavailable, which walks in
  #     full with hash_changed false.
  #
  # Nothing is cleared while either hash is missing. A result without one
  # proves no change: hash_changed false means the check did not run or
  # could not read, not that the hashes matched. A stored list without one
  # was built by Walks that had not reached the hash yet, and a resumed Walk
  # that reaches it continues that structure rather than contradicting it.
  # The clear applies whatever the outcome, protected and empty partial
  # included: the list is for a database that no longer exists.
  # gatt_service_uuids is never cleared; the union keeps accumulating.
  #
  # == Identity columns (11.12, 11.15)
  #
  # result[:identity] holds, under GATT_IDENTITY_COLUMNS' keys, each Identity_Set
  # value the Walk read that is non-empty and well-formed (GattWalker#identity_values
  # leaves out malformed and empty values, and reads that were protected or
  # not made have no entry). Each key present overwrites its column, each key
  # absent leaves its column; the check for an empty value is repeated here
  # because the rule is this method's (11.15). gatt_database_hash also takes
  # result[:database_hash], which a hash check reads without a characteristic
  # entry to carry it into identity.
  #
  # == Sync (12.3, 12.4, 12.7)
  #
  # Every column is assigned through its setter, so DataMapper's dirty tracking
  # (prepare_the_filth, before save) puts in the filthy set exactly the columns
  # whose stored value changed. A list that serialises to the text already
  # stored, an identity value equal to the stored one, or a status already
  # online is not dirty and Sync does not ship it.
  #
  # == Parameters :
  #   result ::
  #     Hash from GattScanner#walk_result; see the Walk result hash in the design
  def self.apply_gatt_result(result)
    address = result[:address]
    outcome = result[:outcome]
    unless BlueHydra::GattScanner::OUTCOMES_WITH_RESULT.include?(outcome)
      raise ArgumentError, "gatt: #{address} Walk result has outcome #{outcome.inspect}, not one of " \
                           "#{BlueHydra::GattScanner::OUTCOMES_WITH_RESULT.join(', ')}"
    end

    record = self.first(conditions: ["lower(address) = ?", address.downcase])
    if record.nil?
      BlueHydra.logger.debug("gatt: #{address} has no Device record, Walk result discarded")
      return nil
    end

    record.status    = "online"
    record.last_seen = [record.last_seen.to_i, result[:ended_at]].max

    stored_uuids = stored_gatt_list(record, :gatt_service_uuids) do |text|
      list = JSON.parse(text)
      raise ArgumentError, "#{list.class} is not an Array" unless list.is_a?(Array)
      list
    end
    uuids, dropped = BlueHydra::GattCharacteristics.union_service_uuids(stored_uuids, result[:service_uuids])
    if dropped > 0
      BlueHydra.logger.warn("gatt: #{address} gatt_service_uuids over " \
                            "#{BlueHydra::GattCharacteristics::MAX_ENTRIES} entries: #{dropped} dropped")
    end
    record.gatt_service_uuids = uuids

    new_hash    = result[:database_hash]
    stored_hash = record.gatt_database_hash
    cleared     = result[:hash_changed] == true || (!new_hash.nil? && !stored_hash.nil? && new_hash != stored_hash)
    stored      = []
    unless cleared
      stored = stored_gatt_list(record, :gatt_characteristics) { |text| BlueHydra::GattCharacteristics.parse(text) }
    end
    incoming = result[:characteristics]

    entries =
      case outcome
      when :complete then incoming
      when :partial  then incoming.empty? ? nil : incoming
      when *BlueHydra::GattWalker::INTERRUPTED_OUTCOMES
        BlueHydra::GattCharacteristics.merge_by_value_handle(stored, incoming)
      else nil # protected
      end

    if entries
      entries, stats = BlueHydra::GattCharacteristics.fit_to_caps(entries)
      if stats[:raw_hex_removed] > 0 || stats[:entries_dropped] > 0
        BlueHydra.logger.warn("gatt: #{address} gatt_characteristics over cap: " \
                              "#{stats[:bytes_before]} -> #{stats[:bytes_after]} bytes, " \
                              "#{stats[:raw_hex_removed]} raw_hex removed, #{stats[:entries_dropped]} entries dropped")
      end
      record.gatt_characteristics = entries
    elsif cleared
      record.gatt_characteristics = []
    end

    (result[:identity] || {}).each do |key, value|
      next if value.nil? || value.empty?
      record.send("#{GATT_IDENTITY_COLUMNS.fetch(key)}=", value)
    end
    record.gatt_database_hash = new_hash if new_hash

    if record.valid?
      record.save
    else
      BlueHydra.logger.warn("#{address} can not save.")
      record.errors.keys.each do |key|
        BlueHydra.logger.warn("#{key.to_s}: #{record.errors[key].inspect} (#{record[key]})")
      end
    end

    record
  end

  # The parsed value of one of the two list Gatt_Columns, the block doing the
  # parsing; [] for a column never written. A stored text the block refuses,
  # not JSON or entries outside GattCharacteristics' schema, which a column
  # written by another version of this code or a damaged row can hold, is
  # logged at warn and treated as empty, so the result being applied replaces
  # it. The alternative, raising, would end the Result_Thread on every result
  # for that address and leave every other device unprocessed too.
  def self.stored_gatt_list(record, column)
    text = record[column]
    return [] if text.nil? || text.empty?
    yield text
  rescue JSON::ParserError, ArgumentError => e
    BlueHydra.logger.warn("gatt: #{record.address} stored #{column} unreadable, treated as empty: #{e.message}")
    []
  end
  private_class_method :stored_gatt_list

  # look up the vendor for the address in the Louis gem
  # and set it
  def set_vendor(force=false)
    if self.le_address_type == "Random"
      self.vendor = "N/A - Random Address"
    else
      if self.vendor == nil || self.vendor == "Unknown" || force
        vendor = Louis.lookup(address)
        self.vendor = vendor["long_vendor"] ? vendor["long_vendor"] : vendor["short_vendor"]
      end
    end
  end

  # set a sync id as a UUID
  #
  # Uniqueness is guaranteed by the unique index on the uuid column rather than
  # a pre-insert existence query on the hot path. SecureRandom.uuid is a 122-bit
  # random value, so a collision is astronomically unlikely; on the off chance
  # the DB rejects the insert, #save regenerates and retries.
  def set_uuid
    self.uuid ||= SecureRandom.uuid
  end

  # Persist the record, regenerating the sync id and retrying once if the DB
  # rejects the write because of a uuid uniqueness collision.
  #
  # This is the "belt" to the unique index's "suspenders": the index guarantees
  # correctness, while this rescue keeps a (practically impossible) collision
  # from ever surfacing as an error on the processing thread. Any other
  # integrity error is re-raised unchanged, and a second collision (which will
  # never happen) is allowed to propagate rather than looping forever.
  def save(*)
    super
  rescue DataObjects::IntegrityError => e
    raise unless e.message =~ /uuid/i
    BlueHydra.logger.warn("UUID collision for #{self.address}, regenerating sync id and retrying save")
    self.uuid = SecureRandom.uuid
    super
  end


  # set the last 4 octets of the mac as the uap_lap values
  #
  # These values are from mac addresses for bt devices as follows
  #
  # |NAP    |UAP |LAP
  # DE : AD : BE : EF : CA : FE
  def set_uap_lap
    self[:uap_lap] = self.address.split(":")[2,4].join(":")
  end

  # lookup helper method for uap_lap
  def self.find_by_uap_lap(address)
    uap_lap = address.split(":")[2,4].join(":")
    self.all(uap_lap: uap_lap).first
  end

  def syncable_attributes
    [
      :name, :vendor, :appearance, :company, :le_company_data, :company_type,
      :lmp_version, :manufacturer, :le_features_bitmap, :firmware,
      :classic_mode, :classic_features_bitmap, :classic_major_class,
      :classic_minor_class, :le_mode, :le_address_type,
      :le_random_address_type, :le_tx_power, :last_seen, :classic_tx_power,
      :le_features, :classic_features, :le_service_uuids,
      :classic_service_uuids, :classic_channels, :classic_class, :classic_rssi,
      :le_flags, :le_rssi, :le_company_uuid, :le_ibeacon_measured_power,
      :le_connectable,
      # every Gatt_Columns entry ships in the data object under its column name
      # (Requirement 12.1), change-gated like the rest
      *GATT_COLUMNS
    ]
  end

  # Attributes stored as JSON, which a sync payload therefore parses back into a
  # structure instead of shipping the encoded string.
  #
  # The two features bitmaps belong here and were missing, so they alone went on
  # the wire as JSON strings - "{\"0\":\"0x1f\"}" - while their nine siblings went
  # as parsed structures, leaving a consumer to double-parse exactly those two.
  # Their setters JSON.generate like all the rest and they sit in the same "update
  # array attributes" list in update_or_create_from_result; only this list had been
  # missed.
  #
  # They are the only hash-backed members. That matters for EMPTY_SYNC_VALUES,
  # which has to know about "{}" as well as "[]".
  #
  # The two list Gatt_Columns are array-backed JSON and ship parsed, an array of
  # strings and an array of entry objects (Requirement 12.2). The other eleven
  # Gatt_Columns are plain strings and are deliberately not here.
  def is_serialized?(attr)
    [
      :classic_channels,
      :classic_class,
      :classic_features,
      :classic_features_bitmap,
      :le_features,
      :le_features_bitmap,
      :le_flags,
      :le_service_uuids,
      :classic_service_uuids,
      :classic_rssi,
      :le_rssi,
      :gatt_service_uuids,
      :gatt_characteristics
    ].include?(attr)
  end

  # Stored values that carry no information and so are left out of a sync payload.
  #
  # "[]" and "{}" are the empty forms of the is_serialized? attributes - the
  # array-backed ones and the two hash-backed features bitmaps. Only "[]" was
  # listed, so an empty bitmap was sent as the literal string "{}" while an empty
  # array-backed attribute was correctly omitted.
  EMPTY_SYNC_VALUES = [nil, "[]", "{}"].freeze

  # Shared by sync_to_pulse and stream_builder_data, which build the same payload
  # from two copies of this loop. One predicate so the two cannot disagree about
  # what "empty" means - the bug above was in both.
  def empty_for_sync?(val)
    EMPTY_SYNC_VALUES.include?(val)
  end


  # This is a helper method to track what attributes change because all
  # attributes lose their 'dirty' status after save and the sync method is an
  # after save so we need to keep a record of what changed to only sync relevant
  def prepare_the_filth
    @filthy_attributes ||= []
    syncable_attributes.each do |attr|
      @filthy_attributes << attr if self.attribute_dirty?(attr)
    end
  end

  # sync record to pulse
  def sync_to_pulse(sync_all=false)
    if BlueHydra.pulse || BlueHydra.pulse_debug

      send_data = {
        type:   "bluetooth",
        source: "blue-hydra",
        version: BlueHydra::VERSION,
        data: {}
      }

      # always include uuid, address, status
      send_data[:data][:sync_id]    = self.uuid
      send_data[:data][:status]     = self.status
      send_data[:data][:sync_version] = BlueHydra::SYNC_VERSION

      # The beacon triple is an IDENTITY KEY on the far side: the cloud matches
      # records on (le_proximity_uuid, le_major_num, le_minor_num), which is why it
      # goes on every message rather than only when it changes. Same reason address
      # does.
      #
      # It looks like three redundant fields per sync for an immutable value, and
      # moving it into syncable_attributes would indeed send it once - after which
      # every later message would be unmatchable. Do not make that optimisation.
      if self.le_proximity_uuid
        send_data[:data][:le_proximity_uuid] = self.le_proximity_uuid
      end

      if self.le_major_num
        send_data[:data][:le_major_num] = self.le_major_num
      end

      if self.le_minor_num
        send_data[:data][:le_minor_num] = self.le_minor_num
      end

      # always include both of these if they are both set, otherwise they will
      # be set as part of syncable_attributes below
      if self.le_company_data && self.company
        send_data[:data][:le_company_data] = self.le_company_data
        send_data[:data][:company] = self.company
      end


      # TODO once pulse is using uuid to lookup records we can move
      # address into the syncable_attributes list and only include it if
      # changes, unless of course we want to handle the case where the db gets
      # reset and we have to resync hosts based on address alone or something
      # but, like, that'll never happen right?
      #
      # XXX for cases like Gimbal the only thing that prevents us from sending 60
      # address updates a minute is the fact that address is *not* in syncable attributes
      # and it only gets sent when something else changes (like rssi).
      # This was originally unintentional but it's really saving out bacon, don't change this for now
      send_data[:data][:address] = self.address

      @filthy_attributes ||= []

      syncable_attributes.each do |attr|
        # ignore nil value attributes
        if @filthy_attributes.include?(attr) || sync_all
          val = self.send(attr)
          unless empty_for_sync?(val)
            if is_serialized?(attr)
              send_data[:data][attr] = JSON.parse(val)
            else
              send_data[:data][attr] = val
            end
          end
        end
      end

      # create the json
      json_msg = JSON.generate(send_data)
      # send the json
      BlueHydra::Pulse.do_send(json_msg)
    end
  end

  # sync record to stream builder
  #
  # This is the Stream Builder counterpart to sync_to_pulse. It builds the same
  # device data payload and ships it to the local Stream Builder ingestor, then
  # emits a metric so we can track how many devices are flowing upstream.
  def sync_to_stream_builder(sync_all=false)
    return unless BlueHydra.stream_builder || BlueHydra.stream_builder_debug

    BlueHydra::StreamBuilder.sync_device(stream_builder_data(sync_all))
  end

  # build the device data payload sent to stream builder. Mirrors the :data
  # section of the pulse sync payload so the two stay consistent.
  def stream_builder_data(sync_all=false)
    data = {}

    # always include uuid, address, status and sync version
    data[:sync_id]      = self.uuid
    data[:status]       = self.status
    data[:sync_version] = BlueHydra::SYNC_VERSION

    # An identity key on the far side, sent on every message, not change-gated.
    # See the same block in sync_to_pulse for why moving it into
    # syncable_attributes would break matching.
    data[:le_proximity_uuid] = self.le_proximity_uuid if self.le_proximity_uuid
    data[:le_major_num]      = self.le_major_num if self.le_major_num
    data[:le_minor_num]      = self.le_minor_num if self.le_minor_num

    # always include both of these if they are both set, otherwise they will
    # be set as part of syncable_attributes below
    if self.le_company_data && self.company
      data[:le_company_data] = self.le_company_data
      data[:company]         = self.company
    end

    data[:address] = self.address

    @filthy_attributes ||= []

    syncable_attributes.each do |attr|
      if @filthy_attributes.include?(attr) || sync_all
        val = self.send(attr)
        unless empty_for_sync?(val)
          if is_serialized?(attr)
            data[attr] = JSON.parse(val)
          else
            data[attr] = val
          end
        end
      end
    end

    data
  end

  # set the :name attribute from the :short_name key only if name is not already
  # set
  #
  # == Parameters
  #   new ::
  #     new short name value
  def short_name=(new)
    unless ["",nil].include?(new) || self.name
      self.name = new
    end
  end

  # set the :classic_channels attribute by merging with previously seen values
  #
  # == Parameters
  #   channels ::
  #     new channels
  def classic_channels=(channels)
    new = channels.map{|x| x.split(", ").reject{|x| x =~ /^0x/}}.flatten.sort.uniq
    current = JSON.parse(self.classic_channels || '[]')
    self[:classic_channels] = JSON.generate((new + current).uniq)
  end

  # set the :classic_class attribute by merging with previously seen values
  #
  # == Parameters
  #   new_classes ::
  #     new classes
  def classic_class=(new_classes)
    new = new_classes.flatten.uniq.reject{|x| x =~ /^0x/}
    current = JSON.parse(self.classic_class || '[]')
    self[:classic_class] = JSON.generate((new + current).uniq)
  end

  # set the :classic_features attribute by merging with previously seen values
  #
  # == Parameters
  #   new_features ::
  #     new features
  def classic_features=(new_features)
    new = new_features.map{|x| x.split(", ").reject{|x| x =~ /^0x/}}.flatten.sort.uniq
    current = JSON.parse(self.classic_features || '[]')
    self[:classic_features] = JSON.generate((new + current).uniq)
  end

  # set the :le_features attribute by merging with previously seen values
  #
  # == Parameters
  #   new_features ::
  #     new features
  def le_features=(new_features)
    new = new_features.map{|x| x.split(", ").reject{|x| x =~ /^0x/}}.flatten.sort.uniq
    current = JSON.parse(self.le_features || '[]')
    self[:le_features] = JSON.generate((new + current).uniq)
  end

  # set the :le_flags attribute by merging with previously seen values
  #
  # == Parameters
  #   new_flags ::
  #     new flags
  def le_flags=(flags)
    new = flags.map{|x| x.split(", ").reject{|x| x =~ /^0x/}}.flatten.sort.uniq
    current = JSON.parse(self.le_flags || '[]')
    self[:le_flags] = JSON.generate((new + current).uniq)
  end

  # set the :le_service_uuids attribute by merging with previously seen values
  #
  # == Parameters
  #   new_uuids ::
  #     new uuids
  def le_service_uuids=(new_uuids)
    current = JSON.parse(self.le_service_uuids || '[]')

    #first we fix our old data if needed
    current_fixed = current.map do |x|
      if x.split(':')[1]
        #example x "(UUID 0xfe9f): 0000000000000000000000000000000000000000"
        # this split/scan handles removing the service data we used to capture and normalizing it to just show uuid
        x.split(':')[0].scan(/\(([^)]+)\)/).flatten[0].split('UUID ')[1]
      else
        x
      end
    end

    new = (new_uuids + current_fixed)

    new.map! do |uuid|
      if uuid =~ /\(/
        uuid
      else
        "Unknown (#{ uuid })"
      end
    end

    self[:le_service_uuids] = JSON.generate(new.uniq)
  end

  # set the :cassic_service_uuids attribute by merging with previously seen values
  #
  # Wrap some uuids in Unknown(uuid) as needed
  #
  # == Parameters
  #   new_uuids ::
  #     new uuids
  def classic_service_uuids=(new_uuids)
    current = JSON.parse(self.classic_service_uuids || '[]')
    new = (new_uuids + current)

    new.map! do |uuid|
      if uuid =~ /\(/
        uuid
      else
        "Unknown (#{ uuid })"
      end
    end

    self[:classic_service_uuids] = JSON.generate(new.uniq)
  end

  # Store a list of Uuid_Formatter strings as the :gatt_service_uuids JSON text.
  #
  # Unlike le_service_uuids= this does not merge: which entries the column ends
  # up holding (the ordered, de-duplicated, capped union of Requirements 11.5
  # and 11.17) is decided by the caller with GattCharacteristics.union_service_uuids,
  # and this stores exactly what it is given. A Text column given an Array
  # directly would store Array#to_s, which is not JSON.
  #
  # == Parameters
  #   uuids ::
  #     Array of "Name (uuid)" strings
  def gatt_service_uuids=(uuids)
    self[:gatt_service_uuids] = JSON.generate(uuids)
  end

  # Store a list of characteristic entries as the :gatt_characteristics JSON
  # text in its canonical form: GattCharacteristics' key order, ascending
  # value_handle (Requirements 11.10, 11.11), so equal lists always produce
  # byte-identical text and the filthy-attribute gate sees no change for them.
  #
  # Does not merge, for the same reason as gatt_service_uuids=: replace, merge by
  # value handle or leave alone depends on the Walk outcome and is the caller's
  # decision. Raises ArgumentError for an entry outside the schema rather than
  # storing text that parse would later refuse.
  #
  # == Parameters
  #   entries ::
  #     Array of entry Hashes in GattCharacteristics' in-memory form
  def gatt_characteristics=(entries)
    self[:gatt_characteristics] = BlueHydra::GattCharacteristics.serialize(entries)
  end

  # set the :classic_rss attribute by merging with previously seen values
  #
  # limit to last 100 rssis
  #
  # == Parameters
  #   rssis ::
  #     new rssis
  def classic_rssi=(rssis)
    current = JSON.parse(self.classic_rssi || '[]')
    new = current + rssis

    until new.count <= 100
      new.shift
    end

    self[:classic_rssi] = JSON.generate(new)
  end

  # set the :le_rssi attribute by merging with previously seen values
  #
  # limit to last 100 rssis
  #
  # == Parameters
  #   rssis ::
  #     new rssis
  def le_rssi=(rssis)
    current = JSON.parse(self.le_rssi || '[]')
    new = current + rssis

    until new.count <= 100
      new.shift
    end

    self[:le_rssi] = JSON.generate(new)
  end

  # set the :le_address_type carefully , may also result in the
  # le_random_address_type being nil'd out if the type value is "public"
  #
  # == Parameters
  #   type ::
  #     new type to set
  def le_address_type=(type)
    type = type.split(' ')[0]
    if type =~ /Public/
      self[:le_address_type] = type
      self[:le_random_address_type] = nil if self.le_address_type
    elsif type =~ /Random/
      self[:le_address_type] = type
    end
  end

  # set the :le_random_address_type unless the le_address_type is set
  #
  # == Parameters
  #   type ::
  #     new type to set
  def le_random_address_type=(type)
    unless le_address_type && le_address_type =~ /Public/
      self[:le_random_address_type] = type
    end
  end

  # set the addres field but only conditionally set vendor based on some whether
  # or not we have an appropriate address to use for vendor lookup. Don't do
  # vendor lookups if address starts with 00:00
  def address=(new)
    if new
      current = self.address

      self[:address] = new

      if current =~ /^00:00/ || new !~ /^00:00/
        set_vendor(true)
      end
    end
  end

  def le_features_bitmap=(arr)
    current = JSON.parse(self.le_features_bitmap||'{}')
    arr.each do |(page, bitmap)|
      current[page] = bitmap
    end
    self[:le_features_bitmap] = JSON.generate(current)
  end

  def classic_features_bitmap=(arr)
    current = JSON.parse(self.classic_features_bitmap||'{}')
    arr.each do |(page, bitmap)|
      current[page] = bitmap
    end
    self[:classic_features_bitmap] = JSON.generate(current)
  end
end
