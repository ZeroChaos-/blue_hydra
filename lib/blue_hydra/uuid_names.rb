require 'json'

module BlueHydra
  # The Uuid_Formatter: renders a GATT UUID as "Name (uuid)" from the vendored
  # Nordic bluetooth-numbers-database (data/bluetooth-numbers-database, see
  # SOURCE.md there), or "Unknown (uuid)" when the database does not list it.
  # Nordic is the only name source; Bluetooth SIG Assigned Numbers are not used
  # (TODO item 16).
  #
  # The uuid is written the way le_service_uuids already writes it: "0x" plus 4
  # lowercase hex digits for a 16-bit UUID, 8-4-4-4-12 lowercase hex for a
  # 128-bit one. A 128-bit UUID on the Bluetooth Base UUID with zero upper 16
  # bits is the same UUID as its 16-bit form, so it is folded to that form for
  # both lookup and output. A peer may put either width on air, and the Nordic
  # files list 16-bit UUIDs only in their 4-digit form.
  #
  # Lookup is per role: a service UUID is looked up in service_uuids.json only,
  # and so on, and a UUID listed only under another role renders Unknown. One
  # UUID can carry a different name per role: at the pinned commit
  # 8e400001-f315-4f60-9fb8-838830daea50 is "Experimental Buttonless DFU
  # Service" as a service and "Experimental Buttonless DFU" as a
  # characteristic.
  #
  # A file that is missing, unreadable or not a JSON array leaves its role's
  # table empty, so every UUID of that role renders Unknown, and logs one error
  # naming the file for the life of the process. Names are decoration on a
  # Walk result: losing them must not lose the Walk, and one Walk renders
  # hundreds of UUIDs, so logging per lookup would flood the log.
  #
  # THREADING: Walk threads call render concurrently. Each role's table is
  # loaded once under @load_mutex, so two threads cannot both load a bad file
  # and both log it, and is frozen afterwards. name-unknown is counted under
  # @count_mutex. Nothing is persisted; the counter starts at 0 with the
  # process and only reset! (a test hook) clears it.
  module UuidNames
    DATA_DIR = File.expand_path("data/bluetooth-numbers-database/v1", __dir__)

    FILES = {
      service:        "service_uuids.json",
      characteristic: "characteristic_uuids.json",
      descriptor:     "descriptor_uuids.json",
    }.freeze

    # A 128-bit UUID that is a 16-bit UUID on the Bluetooth Base UUID. The upper
    # 16 bits must be zero: 0001xxxx-0000-1000-8000-00805f9b34fb is a 32-bit
    # UUID, which ATT never carries, so it stays in 128-bit form.
    BASE_UUID_RE = /\A0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb\z/

    # 00000000-0000-1000-8000-00805f9b34fb as an Integer. A 16-bit UUID sits in
    # bits 96..111 of it.
    BASE_UUID_VALUE = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb

    HEX_DIGITS_RE = /\A(?:\h{4}|\h{32})\z/

    # The uuid of a rendered "Name (uuid)". Anchored on the last group because
    # Nordic names carry parentheses of their own ("Ranging Service (RAS)").
    RENDERED_UUID_RE = /\(([^()]+)\)\z/

    @load_mutex   = Mutex.new
    @count_mutex  = Mutex.new
    @data_dir     = DATA_DIR
    @tables       = {}   # role => frozen { canonical uuid => name }
    @logged_paths = {}   # absolute path => true once its load error is logged
    @name_unknown = 0

    class << self
      # role is :service (also used for included services), :characteristic
      # or :descriptor. uuid is anything canonical accepts. Raises
      # ArgumentError for an unknown role or an unparseable uuid; the Walk only
      # ever passes UUIDs AttCodec decoded, so either is a caller bug.
      def render(role, uuid)
        key  = canonical(uuid)
        name = table(role)[key]
        return "#{name} (#{key})" if name
        @count_mutex.synchronize { @name_unknown += 1 }
        "Unknown (#{key})"
      end

      def service(uuid)
        render(:service, uuid)
      end

      def characteristic(uuid)
        render(:characteristic, uuid)
      end

      def descriptor(uuid)
        render(:descriptor, uuid)
      end

      # The uuid part of a rendered name: "0x1800" or
      # "6e400001-b5a3-f393-e0a9-e50e24dcca9e". Accepts an AttCodec::Uuid, a
      # 16-bit Integer, or a String of 4 or 32 hex digits in any case, with or
      # without hyphens and an optional 0x prefix.
      def canonical(uuid)
        hex = hex_digits(uuid)
        return "0x#{hex}" if hex.length == 4
        long = "#{hex[0, 8]}-#{hex[8, 4]}-#{hex[12, 4]}-#{hex[16, 4]}-#{hex[20, 12]}"
        (m = BASE_UUID_RE.match(long)) ? "0x#{m[1]}" : long
      end

      # The 128-bit value of a UUID, for ordering gatt_service_uuids
      # (Requirement 11.5). Takes a rendered "Name (uuid)" / "Unknown (uuid)"
      # or anything canonical accepts. A 16-bit UUID is expanded onto the Base
      # UUID so it sorts where its 128-bit spelling would.
      def sort_key(rendered_or_uuid)
        uuid = rendered_or_uuid
        if uuid.is_a?(String) && (m = RENDERED_UUID_RE.match(uuid))
          uuid = m[1]
        end
        key = canonical(uuid)
        return BASE_UUID_VALUE | (key[2..].to_i(16) << 96) if key.start_with?("0x")
        key.delete("-").to_i(16)
      end

      def name_unknown_count
        @count_mutex.synchronize { @name_unknown }
      end

      # test hook: read the tables from another directory. Already-loaded
      # tables are dropped so the next lookup loads from path. A path whose
      # load error was already logged is not logged again.
      def data_dir=(path)
        @load_mutex.synchronize do
          @data_dir = File.expand_path(path)
          @tables   = {}
        end
      end

      # test hook only
      def reset!
        @load_mutex.synchronize do
          @data_dir     = DATA_DIR
          @tables       = {}
          @logged_paths = {}
        end
        @count_mutex.synchronize { @name_unknown = 0 }
      end

      private

      def table(role)
        file = FILES.fetch(role) { raise ArgumentError, "unknown UUID role: #{role.inspect}" }
        @load_mutex.synchronize do
          @tables[role] ||= load_table(role, File.join(@data_dir, file))
        end
      end

      # Runs under @load_mutex.
      def load_table(role, path)
        entries = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        raise TypeError, "top level is #{entries.class}, not an Array" unless entries.is_a?(Array)
        names   = {}
        skipped = 0
        entries.each do |entry|
          key, name = entry_key_and_name(entry)
          if key.nil?
            skipped += 1
            next
          end
          # First entry in file order wins. At the pinned commit
          # characteristic_uuids.json lists 0x2B1D..0x2B28 twice, each pair
          # with the same name, so the rule only shows if a later commit lets
          # the pairs diverge.
          names[key] = name unless names.key?(key)
        end
        if skipped > 0
          BlueHydra.logger.warn(
            "uuid_names: #{path}: skipped #{skipped} entries without a String name and a 16/128-bit String uuid"
          )
        end
        names.freeze
      rescue StandardError => e
        # StandardError rather than a list: whatever is wrong with the file,
        # the Walk carries on with Unknown names (Requirement 10.6).
        unless @logged_paths[path]
          @logged_paths[path] = true
          BlueHydra.logger.error(
            "uuid_names: cannot load #{path} (#{e.class}: #{e.message}); every #{role} UUID renders Unknown"
          )
        end
        {}.freeze
      end

      # [canonical uuid, name], or nil when the entry is not usable. The uuid
      # must be a String: canonical would read a JSON number as a 16-bit
      # Integer, which is not how Nordic writes UUIDs.
      def entry_key_and_name(entry)
        return nil unless entry.is_a?(Hash)
        name = entry["name"]
        uuid = entry["uuid"]
        return nil unless name.is_a?(String) && !name.empty? && uuid.is_a?(String)
        [canonical(uuid), name]
      rescue ArgumentError
        nil
      end

      # 4 or 32 lowercase hex digits, no hyphens.
      def hex_digits(uuid)
        hex =
          case uuid
          when Integer
            raise ArgumentError, "16-bit UUID out of range: #{uuid.inspect}" unless uuid.between?(0, 0xFFFF)
            format("%04x", uuid)
          when String
            uuid.downcase.delete("-").delete_prefix("0x")
          else
            # AttCodec::Uuid by duck typing, so this file need not require
            # att_codec. Both methods are checked because String responds to
            # #hex as well.
            unless uuid.respond_to?(:hex) && uuid.respond_to?(:bits)
              raise ArgumentError, "not a UUID: #{uuid.inspect}"
            end
            uuid.hex.to_s.downcase
          end
        raise ArgumentError, "not a 16- or 128-bit UUID: #{uuid.inspect}" unless HEX_DIGITS_RE.match?(hex)
        hex
      end
    end
  end
end
