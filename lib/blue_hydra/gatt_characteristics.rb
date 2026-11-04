require 'json'
require 'blue_hydra/uuid_names'

module BlueHydra
  # Merge, cap and serialisation rules for the two list Gatt_Columns,
  # gatt_characteristics and gatt_service_uuids. They live outside Device so
  # they can be tested without DataMapper. Pure functions with no state; in
  # production only the Result_Thread calls them.
  #
  # In memory, a gatt_characteristics entry is a Hash with Symbol keys at every
  # level, including inside service_includes and descriptors. That is the form
  # the Gatt_Walker puts on result_queue. Values are as in the JSON schema:
  # Strings, Integers, true, nil, and Arrays of those or of such Hashes
  # (read_status is "read", not :read). parse returns this form and serialize
  # accepts only this form. For a list already in ascending value_handle
  # order, parse(serialize(list)) == list (Requirement 11.11). serialize
  # sorts, so an unsorted list comes back sorted.
  #
  # parse and serialize check every entry against the schema and raise
  # ArgumentError on the first violation; they never drop or repair anything.
  # serialize writes the schema's keys only, so without the check a stray key
  # would vanish from the stored text and break the round trip silently: a
  # misspelt :raw_hex_truncate, say, or the String keys of a JSON.parse
  # without symbolize_names. The caller decides what a stored column that
  # fails parse means.
  #
  # No function modifies its arguments. A returned list may share entry Hashes
  # with the lists passed in.
  module GattCharacteristics
    # Kinesis and Firehose cap a record at 1 MiB and drop an oversize record
    # without telling anyone, so the serialised list is held well below that
    # (Requirement 11.18).
    MAX_BYTES = 262_144

    # Applies to gatt_characteristics and gatt_service_uuids alike
    # (Requirements 11.17, 11.18).
    MAX_ENTRIES = 1_000

    # Serialisation order of an entry's keys, from the design's entry schema.
    KEY_ORDER = %i[
      uuid service_uuid service_type service_start service_end service_includes
      decl_handle value_handle properties descriptors read_status error_code
      value value_encoding raw_hex raw_hex_truncated
    ].freeze

    # Keys that appear only under the conditions check_entry! enforces.
    CONDITIONAL_KEYS = %i[error_code value value_encoding raw_hex raw_hex_truncated].freeze
    REQUIRED_KEYS    = (KEY_ORDER - CONDITIONAL_KEYS).freeze

    INCLUDE_KEY_ORDER    = %i[uuid start end].freeze
    DESCRIPTOR_KEY_ORDER = %i[uuid handle].freeze

    READ_STATUSES       = %w[read protected not-read not-readable error malformed].freeze
    ERROR_CODE_STATUSES = %w[protected error].freeze

    # Uuid_Formatter output: "Name (uuid)". The name is greedy because Nordic
    # names carry parentheses of their own ("Ranging Service (RAS) (0x185b)");
    # the uuid group cannot hold one, so it is always the last group.
    FORMATTED_UUID_RE = /\A(.+) \(([^()]+)\)\z/m

    class << self
      # json_or_nil: a stored gatt_characteristics column. nil and "" are a
      # column never written and mean the empty list. Raises ArgumentError for
      # text that is not JSON, whose top level is not an Array, or that holds
      # an entry serialize would refuse.
      def parse(json_or_nil)
        return [] if json_or_nil.nil? || json_or_nil.empty?
        begin
          entries = JSON.parse(json_or_nil, symbolize_names: true)
        rescue JSON::ParserError => e
          raise ArgumentError, "GattCharacteristics.parse: not valid JSON (#{e.message})"
        end
        unless entries.is_a?(Array)
          raise ArgumentError, "GattCharacteristics.parse: top level is #{entries.class}, not an Array"
        end
        check_entries!(entries, "GattCharacteristics.parse")
        entries
      end

      # entries: Array of entries in the in-memory form, in any order. Returns
      # compact JSON with the entries in ascending value_handle and the keys
      # in KEY_ORDER, include and descriptor keys likewise. Two equal lists
      # therefore serialise to identical text whatever order their keys were
      # inserted in (Requirement 11.11).
      def serialize(entries)
        check_entries!(entries, "GattCharacteristics.serialize")
        sorted = entries.sort_by { |entry| entry[:value_handle] }
        JSON.generate(sorted.map { |entry| ordered_entry(entry) })
      end

      # stored: the Device's current list, as parse returns it. incoming: the
      # list from a timeout or disconnected Walk result. Returns their union
      # keyed by value_handle, in ascending value_handle order. Where both have
      # an entry for a value handle the incoming one is kept, so successive
      # resumed Walks add to what earlier ones stored and never lose any of it
      # (Requirement 11.8).
      def merge_by_value_handle(stored, incoming)
        merged = index_by_value_handle(stored, "GattCharacteristics.merge_by_value_handle stored")
                 .merge(index_by_value_handle(incoming, "GattCharacteristics.merge_by_value_handle incoming"))
        merged.keys.sort.map { |handle| merged[handle] }
      end

      # entries: a list as parse returns it, in any order. Returns [list,
      # stats], list meeting both caps of Requirement 11.18: serialised text
      # of at most MAX_BYTES and at most MAX_ENTRIES entries. A list already
      # within both is returned as it was passed, the same Array. Any other
      # comes back in ascending value_handle order, trimmed in two steps
      # (Requirement 11.19):
      #
      # 1. While the text exceeds MAX_BYTES, raw_hex is removed from entries
      #    in descending raw_hex length, each such entry gaining
      #    raw_hex_truncated: true. Of two raw_hex of equal length, the one at
      #    the higher value_handle goes first. Step 2 drops from that end, so
      #    a list over both caps loses raw_hex from entries it may drop anyway
      #    rather than from those it keeps.
      #    A raw_hex of 12 characters or fewer does not shrink the text when
      #    removed: the 25-byte ,"raw_hex_truncated":true replaces
      #    ,"raw_hex":"" plus its hex. It is removed all the same, because
      #    Requirement 11.19 drops no entry for size while a raw_hex remains.
      # 2. While the text still exceeds MAX_BYTES, or the list holds more than
      #    MAX_ENTRIES entries, the entry with the highest value_handle is
      #    dropped. A list whose every entry is too large ends up empty.
      #
      # stats: bytes_before and bytes_after, the serialised sizes of entries
      # and of the returned list; raw_hex_removed, the number of returned
      # entries step 1 marked; entries_dropped. An entry stripped in step 1
      # and then dropped in step 2 counts in entries_dropped only, so
      # raw_hex_removed equals the markers this call adds to the stored text.
      #
      # Raises ArgumentError for a list serialize would refuse.
      def fit_to_caps(entries)
        check_entries!(entries, "GattCharacteristics.fit_to_caps")
        kept  = entries.sort_by { |entry| entry[:value_handle] }
        sizes = kept.map { |entry| entry_bytesize(entry) }
        sum   = sizes.sum
        bytes_before = list_bytesize(sum, kept.size)
        if bytes_before <= MAX_BYTES && kept.size <= MAX_ENTRIES
          return [entries, { bytes_before: bytes_before, bytes_after: bytes_before,
                             raw_hex_removed: 0, entries_dropped: 0 }]
        end

        stripped = []
        kept.each_index.select { |i| kept[i].key?(:raw_hex) }
            .sort_by { |i| [-kept[i][:raw_hex].length, -kept[i][:value_handle]] }
            .each do |i|
              break if list_bytesize(sum, kept.size) <= MAX_BYTES
              # Copied, because the Hash may be an entry of the caller's list.
              kept[i] = kept[i].dup.tap do |copy|
                copy.delete(:raw_hex)
                copy[:raw_hex_truncated] = true
              end
              size = entry_bytesize(kept[i])
              sum += size - sizes[i]
              sizes[i] = size
              stripped << i
            end

        while kept.size > MAX_ENTRIES || list_bytesize(sum, kept.size) > MAX_BYTES
          kept.pop
          sum -= sizes.pop
        end

        [kept, { bytes_before: bytes_before, bytes_after: serialize(kept).bytesize,
                 raw_hex_removed: stripped.count { |i| i < kept.size },
                 entries_dropped: entries.size - kept.size }]
      end

      # stored: the parsed gatt_service_uuids column. incoming: a Walk result's
      # service_uuids. Both are Arrays of Uuid_Formatter strings. Returns
      # [list, dropped]: one entry per distinct UUID in ascending 128-bit order
      # (UuidNames.sort_key), cut to the first MAX_ENTRIES, with dropped the
      # number of entries cut (Requirements 11.5, 11.17).
      #
      # Entries are distinct by UUID, not by text. A UUID rendered under two
      # names counts once, and the stored rendering is kept. That happens when
      # a Nordic database update names a UUID that an earlier run stored as
      # Unknown. Keeping the incoming rendering would rewrite the column, and
      # make Sync ship it, for a result that adds no UUID; Requirements 11.5
      # and 12.7 forbid both. Within one list the first rendering wins.
      #
      # Raises ArgumentError for a list that is not an Array or an entry that
      # is not in Uuid_Formatter form.
      def union_service_uuids(stored, incoming)
        by_key = {}
        { "stored" => stored, "incoming" => incoming }.each do |label, list|
          where = "GattCharacteristics.union_service_uuids #{label}"
          raise ArgumentError, "#{where}: #{list.class} is not an Array" unless list.is_a?(Array)
          list.each_with_index do |rendered, i|
            key = formatted_uuid_key(rendered)
            raise ArgumentError, "#{where}: entry #{i} #{rendered.inspect} is not in Uuid_Formatter form" unless key
            by_key[key] = rendered unless by_key.key?(key)
          end
        end
        ordered = by_key.keys.sort.map { |key| by_key[key] }
        [ordered.first(MAX_ENTRIES), [ordered.size - MAX_ENTRIES, 0].max]
      end

      private

      # A copy of entry with its keys, and its includes' and descriptors'
      # keys, in serialisation order. Ruby Hashes keep insertion order and
      # JSON.generate follows it.
      def ordered_entry(entry)
        KEY_ORDER.each_with_object({}) do |key, ordered|
          next unless entry.key?(key)
          ordered[key] =
            case key
            when :service_includes then entry[key].map { |inc| inc.slice(*INCLUDE_KEY_ORDER) }
            when :descriptors      then entry[key].map { |desc| desc.slice(*DESCRIPTOR_KEY_ORDER) }
            else entry[key]
            end
        end
      end

      # fit_to_caps keeps the text's size as a running total of these instead
      # of re-serialising the list after every removal, which is quadratic in
      # the list's length. The total is exact: compact JSON.generate writes an
      # Array as "[", its elements' texts joined by ",", then "]", and an
      # element's text does not depend on its neighbours.
      def entry_bytesize(entry)
        JSON.generate(ordered_entry(entry)).bytesize
      end

      # The serialised size of count entries whose own sizes sum to sum.
      def list_bytesize(sum, count)
        count.zero? ? 2 : sum + count + 1
      end

      # The 128-bit sort key of a Uuid_Formatter string, or nil when s is not
      # one. The uuid must already be canonical (lowercase, Base UUID folded
      # to 16 bits): "Generic Access (0X1800)" is not Uuid_Formatter output.
      def formatted_uuid_key(s)
        return nil unless s.is_a?(String) && (m = FORMATTED_UUID_RE.match(s))
        return nil unless UuidNames.canonical(m[2]) == m[2]
        UuidNames.sort_key(m[2])
      rescue ArgumentError
        nil
      end

      # { value_handle => entry }. Raises ArgumentError unless entries is an
      # Array of Hashes, each with an Integer :value_handle in 0x0001..0xFFFF
      # that no other entry in the list shares. Two entries for one value
      # handle cannot come from one GATT database, and merging would keep one
      # of them without saying so.
      def index_by_value_handle(entries, where)
        raise ArgumentError, "#{where}: #{entries.class} is not an Array" unless entries.is_a?(Array)
        entries.each_with_index.each_with_object({}) do |(entry, i), index|
          raise ArgumentError, "#{where}: entry #{i} is a #{entry.class}, not a Hash" unless entry.is_a?(Hash)
          handle = entry[:value_handle]
          unless handle.is_a?(Integer) && handle.between?(0x0001, 0xFFFF)
            raise ArgumentError, "#{where}: entry #{i} has value_handle #{handle.inspect}, " \
                                 "not an Integer in 0x0001..0xFFFF"
          end
          if index.key?(handle)
            raise ArgumentError, "#{where}: value_handle #{format('0x%04x', handle)} appears more than once"
          end
          index[handle] = entry
        end
      end

      def check_entries!(entries, where)
        index_by_value_handle(entries, where).each_value { |entry| check_entry!(entry, where) }
      end

      # The schema rules of the design's entry schema (Requirements 10.9,
      # 11.10). Value types are checked only where a rule depends on them.
      def check_entry!(entry, where)
        handle = entry[:value_handle]
        where  = "#{where}: entry at value_handle #{format('0x%04x', handle)}"

        stray = entry.keys - KEY_ORDER
        raise ArgumentError, "#{where}: unknown keys #{stray.inspect}" unless stray.empty?
        missing = REQUIRED_KEYS - entry.keys
        raise ArgumentError, "#{where}: missing keys #{missing.inspect}" unless missing.empty?

        status = entry[:read_status]
        unless READ_STATUSES.include?(status)
          raise ArgumentError, "#{where}: read_status #{status.inspect} is not one of #{READ_STATUSES.join(', ')}"
        end
        read = status == "read"
        %i[value value_encoding].each do |key|
          next if entry.key?(key) == read
          raise ArgumentError, "#{where}: #{key} must be present exactly when read_status is \"read\" " \
                               "(read_status #{status.inspect})"
        end
        if entry.key?(:error_code) != ERROR_CODE_STATUSES.include?(status)
          raise ArgumentError, "#{where}: error_code must be present exactly when read_status is " \
                               "#{ERROR_CODE_STATUSES.join(' or ')} (read_status #{status.inspect})"
        end
        # raw_hex is kept beside a decoded value, so it needs a read value.
        # raw_hex_truncated marks an entry whose raw_hex was removed, so it
        # never sits beside one.
        if entry.key?(:raw_hex) && !(read && entry[:raw_hex].is_a?(String))
          raise ArgumentError, "#{where}: raw_hex must be a String on a read entry"
        end
        if entry.key?(:raw_hex_truncated) &&
           !(read && entry[:raw_hex_truncated].equal?(true) && !entry.key?(:raw_hex))
          raise ArgumentError, "#{where}: raw_hex_truncated must be true, on a read entry without raw_hex"
        end

        %i[uuid service_uuid].each do |key|
          next if formatted_uuid_key(entry[key])
          raise ArgumentError, "#{where}: #{key} #{entry[key].inspect} is not in Uuid_Formatter form"
        end
        # An include's uuid is nil when no discovered service starts at its
        # handle, so its 128-bit UUID could not be read.
        check_nested!(entry[:service_includes], INCLUDE_KEY_ORDER, "#{where}: service_includes", nil_uuid: true)
        check_nested!(entry[:descriptors], DESCRIPTOR_KEY_ORDER, "#{where}: descriptors", nil_uuid: false)
      end

      def check_nested!(list, keys, where, nil_uuid:)
        raise ArgumentError, "#{where} is a #{list.class}, not an Array" unless list.is_a?(Array)
        list.each_with_index do |item, i|
          unless item.is_a?(Hash) && item.keys.sort == keys.sort
            raise ArgumentError, "#{where} item #{i} must be a Hash with exactly the keys #{keys.inspect}"
          end
          uuid = item[:uuid]
          next if (nil_uuid && uuid.nil?) || formatted_uuid_key(uuid)
          raise ArgumentError, "#{where} item #{i}: uuid #{uuid.inspect} is not in Uuid_Formatter form"
        end
      end
    end
  end
end
