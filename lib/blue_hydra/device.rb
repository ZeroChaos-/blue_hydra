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
  end

  # this class method is take a result Hash and convert it into a new or update
  # an existing record
  #
  # == Parameters :
  #   result ::
  #     Hash of results from parser
  def self.update_or_create_from_result(result)

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
    %w{
      address name manufacturer short_name lmp_version firmware
      classic_major_class classic_minor_class le_tx_power classic_tx_power
      le_address_type company appearance
      le_random_address_type le_company_uuid le_company_data le_proximity_uuid
      le_major_num le_minor_num classic_mode le_mode le_ibeacon_measured_power
    }.map(&:to_sym).each do |attr|
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
    %w{
      classic_features le_features le_flags classic_channels classic_class le_rssi
      classic_rssi le_service_uuids classic_service_uuids le_features_bitmap classic_features_bitmap
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
      :le_flags, :le_rssi, :le_company_uuid, :le_ibeacon_measured_power
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
      :le_rssi
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
    current = JSON.parse(self.classic_class || '[]')
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
