module BlueHydra
  # Validates the four GATT options. It returns its warnings instead of logging
  # them because it runs from the config-loading block in lib/blue_hydra.rb,
  # before the logger exists; the caller logs them once update_logger has run.
  #
  # A rejected value falls back to the default with one warning rather than
  # aborting startup: a mistyped GATT option should not stop the sensor scanning.
  module GattConfig
    DEFAULTS = {
      "gatt_scan"          => true,
      "gatt_walk_timeout"  => 10,
      "gatt_walk_parallel" => 3,
      "gatt_read_all"      => true
    }.freeze

    WALK_TIMEOUT_RANGE  = (1..60).freeze
    WALK_PARALLEL_RANGE = (1..8).freeze

    # Psych loads YAML 1.1 booleans, so `yes`, `on` and `True` arrive here as
    # true and are accepted; only a quoted "true" stays a String and is rejected.
    #
    # The numeric rules reject booleans before testing the type. Ruby's true and
    # false are not Integers today, but the explicit check keeps a bare `on`
    # from ever becoming a timeout or a Walk count if the type test is widened.
    #
    # gatt_walk_parallel rejects every Float, 3.0 included, so the value is
    # always an Integer and the warning can state the rule as a type.
    #
    # `.nan` and `.inf` load as Floats; both fail Range#cover?, so they are
    # rejected as out of range.
    RULES = {
      "gatt_scan" => {
        accepts:  ->(v) { boolean?(v) },
        expected: "true or false"
      },
      "gatt_walk_timeout" => {
        accepts:  ->(v) { !boolean?(v) && (v.is_a?(Integer) || v.is_a?(Float)) && WALK_TIMEOUT_RANGE.cover?(v) },
        expected: "an Integer or Float from #{WALK_TIMEOUT_RANGE.min} to #{WALK_TIMEOUT_RANGE.max}"
      },
      "gatt_walk_parallel" => {
        accepts:  ->(v) { !boolean?(v) && v.is_a?(Integer) && WALK_PARALLEL_RANGE.cover?(v) },
        expected: "an Integer from #{WALK_PARALLEL_RANGE.min} to #{WALK_PARALLEL_RANGE.max}"
      },
      "gatt_read_all" => {
        accepts:  ->(v) { boolean?(v) },
        expected: "true or false"
      }
    }.freeze

    # raw: the Hash loaded from blue_hydra.yml, which may lack any of the keys.
    # Returns [Hash with exactly the DEFAULTS keys, Array<String> warnings],
    # one warning per present, non-nil value that was rejected. raw is not
    # modified.
    def self.normalise(raw)
      values   = {}
      warnings = []

      DEFAULTS.each do |key, default|
        value = raw[key]
        rule  = RULES.fetch(key)

        if value.nil?
          values[key] = default
        elsif rule[:accepts].call(value)
          values[key] = value
        else
          values[key] = default
          warnings << "#{key}: rejected #{value.inspect} " \
                      "(expected #{rule[:expected]}), using default #{default.inspect}"
        end
      end

      [values, warnings]
    end

    def self.boolean?(value)
      value.equal?(true) || value.equal?(false)
    end
    private_class_method :boolean?
  end
end
