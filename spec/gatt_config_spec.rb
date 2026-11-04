require 'spec_helper'
require 'yaml'
require 'blue_hydra/gatt_config'

describe BlueHydra::GattConfig do
  # A local, not a constant: a constant here would land on Object and be
  # shared with every other spec file. The examples close over it.
  defaults = {
    "gatt_scan"          => true,
    "gatt_walk_timeout"  => 10,
    "gatt_walk_parallel" => 3,
    "gatt_read_all"      => true
  }.freeze

  def normalise(raw)
    described_class.normalise(raw)
  end

  it "has the defaults Requirement 1.1 and 1.4 name" do
    expect(described_class::DEFAULTS).to eq(defaults)
  end

  describe "absent and nil options" do
    # Requirement 1.1 / 1.4: absent or null takes the default with no warning.
    [
      ["an empty config",               {}],
      ["every option set to nil",       defaults.keys.to_h { |k| [k, nil] }],
      ["only unrelated options",        { "info_scan_rate" => 240, "log_level" => "debug" }],
      ["gatt_scan nil",                 { "gatt_scan" => nil }],
      ["gatt_walk_timeout nil",         { "gatt_walk_timeout" => nil }],
      ["gatt_walk_parallel nil",        { "gatt_walk_parallel" => nil }],
      ["gatt_read_all nil",             { "gatt_read_all" => nil }]
    ].each do |label, raw|
      it "applies every default silently for #{label}" do
        values, warnings = normalise(raw)
        expect(values).to eq(defaults)
        expect(values.keys).to eq(defaults.keys)
        expect(warnings).to eq([])
      end
    end

    # eql? so an Integer default is not satisfied by an equal Float
    it "returns the defaults with their own types" do
      values, = normalise({})
      expect(values["gatt_scan"]).to be(true)
      expect(values["gatt_read_all"]).to be(true)
      expect(values["gatt_walk_timeout"]).to eql(10)
      expect(values["gatt_walk_parallel"]).to eql(3)
    end
  end

  describe "accepted values" do
    # false must survive: it is a real setting, not "absent".
    [
      ["gatt_scan",          false],
      ["gatt_scan",          true],
      ["gatt_read_all",      false],
      ["gatt_read_all",      true],
      ["gatt_walk_timeout",  1],
      ["gatt_walk_timeout",  60],
      ["gatt_walk_timeout",  1.0],
      ["gatt_walk_timeout",  60.0],
      ["gatt_walk_timeout",  2.5],
      ["gatt_walk_parallel", 1],
      ["gatt_walk_parallel", 8]
    ].each do |option, value|
      it "keeps #{option} #{value.inspect} unchanged with no warning" do
        values, warnings = normalise(option => value)
        expect(values[option]).to eql(value)
        expect(values).to eq(defaults.merge(option => value))
        expect(warnings).to eq([])
      end
    end
  end

  describe "rejected values" do
    # Requirements 1.5 and 1.6: the default is applied and exactly one warning
    # names the option, the rejected value (inspected) and the default. The
    # expected text is written out in full rather than rebuilt from the same
    # format string the subject uses.
    [
      # gatt_scan / gatt_read_all: anything but the booleans true and false
      ["gatt_scan", "true",  'gatt_scan: rejected "true" (expected true or false), using default true'],
      ["gatt_scan", "false", 'gatt_scan: rejected "false" (expected true or false), using default true'],
      ["gatt_scan", 1,       'gatt_scan: rejected 1 (expected true or false), using default true'],
      ["gatt_scan", 0,       'gatt_scan: rejected 0 (expected true or false), using default true'],
      ["gatt_scan", [true],  'gatt_scan: rejected [true] (expected true or false), using default true'],
      ["gatt_read_all", "false", 'gatt_read_all: rejected "false" (expected true or false), using default true'],
      ["gatt_read_all", 0,       'gatt_read_all: rejected 0 (expected true or false), using default true'],
      ["gatt_read_all", 1.0,     'gatt_read_all: rejected 1.0 (expected true or false), using default true'],
      ["gatt_read_all", [],      'gatt_read_all: rejected [] (expected true or false), using default true'],

      # gatt_walk_timeout: Integer or Float in 1..60
      ["gatt_walk_timeout", "10",   'gatt_walk_timeout: rejected "10" (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", true,   'gatt_walk_timeout: rejected true (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", false,  'gatt_walk_timeout: rejected false (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", [10],   'gatt_walk_timeout: rejected [10] (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", 0,      'gatt_walk_timeout: rejected 0 (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", 0.99,   'gatt_walk_timeout: rejected 0.99 (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", -5,     'gatt_walk_timeout: rejected -5 (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", 61,     'gatt_walk_timeout: rejected 61 (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout", 60.01,  'gatt_walk_timeout: rejected 60.01 (expected an Integer or Float from 1 to 60), using default 10'],

      # gatt_walk_parallel: Integer in 1..8, every Float rejected (3.0 included)
      ["gatt_walk_parallel", "3",   'gatt_walk_parallel: rejected "3" (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", true,  'gatt_walk_parallel: rejected true (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", false, 'gatt_walk_parallel: rejected false (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", [3],   'gatt_walk_parallel: rejected [3] (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", 2.5,   'gatt_walk_parallel: rejected 2.5 (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", 3.0,   'gatt_walk_parallel: rejected 3.0 (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", 0,     'gatt_walk_parallel: rejected 0 (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", -1,    'gatt_walk_parallel: rejected -1 (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel", 9,     'gatt_walk_parallel: rejected 9 (expected an Integer from 1 to 8), using default 3']
    ].each do |option, value, text|
      it "rejects #{option} #{value.inspect} with one warning" do
        values, warnings = normalise(option => value)
        expect(values).to eq(defaults)
        expect(values[option]).to eql(defaults[option])
        expect(warnings).to eq([text])
      end
    end

    it "warns once per rejected option, in option order, leaving accepted ones alone" do
      raw = {
        "gatt_read_all"      => "no",
        "gatt_walk_parallel" => 4,
        "gatt_walk_timeout"  => 0,
        "gatt_scan"          => "yes"
      }
      values, warnings = normalise(raw)

      expect(values).to eq(defaults.merge("gatt_walk_parallel" => 4))
      expect(warnings).to eq([
        'gatt_scan: rejected "yes" (expected true or false), using default true',
        'gatt_walk_timeout: rejected 0 (expected an Integer or Float from 1 to 60), using default 10',
        'gatt_read_all: rejected "no" (expected true or false), using default true'
      ])
    end
  end

  # What actually reaches normalise: the Hash Psych builds from blue_hydra.yml.
  # Psych loads YAML 1.1 booleans, so bare yes/on/off are booleans and only a
  # quoted "true" stays a String; .nan and .inf load as Floats.
  describe "values loaded from YAML" do
    [
      ["gatt_scan: yes",            "gatt_scan",          true],
      ["gatt_scan: on",             "gatt_scan",          true],
      ["gatt_read_all: off",        "gatt_read_all",      false],
      ["gatt_read_all: no",         "gatt_read_all",      false],
      ["gatt_walk_timeout: 2.5",    "gatt_walk_timeout",  2.5],
      ["gatt_walk_parallel: 8",     "gatt_walk_parallel", 8]
    ].each do |yaml, option, value|
      it "accepts #{yaml.inspect} as #{value.inspect}" do
        values, warnings = normalise(YAML.safe_load(yaml))
        expect(values[option]).to eql(value)
        expect(warnings).to eq([])
      end
    end

    ["gatt_scan: ~", "gatt_scan:", "gatt_walk_timeout: null"].each do |yaml|
      it "treats #{yaml.inspect} as absent" do
        values, warnings = normalise(YAML.safe_load(yaml))
        expect(values).to eq(defaults)
        expect(warnings).to eq([])
      end
    end

    [
      ['gatt_scan: "true"',         'gatt_scan: rejected "true" (expected true or false), using default true'],
      ["gatt_read_all: 'false'",    'gatt_read_all: rejected "false" (expected true or false), using default true'],
      ["gatt_scan: 1",              'gatt_scan: rejected 1 (expected true or false), using default true'],
      ["gatt_walk_timeout: .nan",   'gatt_walk_timeout: rejected NaN (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout: .inf",   'gatt_walk_timeout: rejected Infinity (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout: -.inf",  'gatt_walk_timeout: rejected -Infinity (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_timeout: '10'",   'gatt_walk_timeout: rejected "10" (expected an Integer or Float from 1 to 60), using default 10'],
      ["gatt_walk_parallel: 3.0",   'gatt_walk_parallel: rejected 3.0 (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel: [3]",   'gatt_walk_parallel: rejected [3] (expected an Integer from 1 to 8), using default 3'],
      ["gatt_walk_parallel: on",    'gatt_walk_parallel: rejected true (expected an Integer from 1 to 8), using default 3']
    ].each do |yaml, text|
      it "rejects #{yaml.inspect} with one warning" do
        values, warnings = normalise(YAML.safe_load(yaml))
        expect(values).to eq(defaults)
        expect(warnings).to eq([text])
      end
    end
  end

  describe "purity" do
    it "does not modify the raw config" do
      raw = { "gatt_scan" => "true", "gatt_walk_parallel" => 9, "other" => 1 }.freeze
      expect { normalise(raw) }.not_to raise_error
      expect(raw).to eq("gatt_scan" => "true", "gatt_walk_parallel" => 9, "other" => 1)
    end

    # It runs before the logger exists; the caller logs the returned warnings.
    it "never touches the logger, even when it rejects a value" do
      expect(BlueHydra).not_to receive(:logger)
      normalise("gatt_scan" => "true", "gatt_walk_timeout" => 0)
    end
  end

  # Feature: gatt-service-scanning, Property 17: Config normalisation always yields in-range values with one warning per rejection
  #
  # Requirements 1.4, 1.5 and 1.6. Each option is independently absent, nil, a
  # value of its own type, or a value from a pool spanning every class the rules
  # must tell apart: Strings (including "true" and "10"), booleans, Integers in
  # and out of range, Floats (integral, NaN, infinite), Arrays, Hashes and
  # Symbols. normalise takes any Hash, so the pool is wider than what YAML
  # produces. Unrelated keys, some of them near-misses of the option names, are
  # mixed in and must be ignored.
  #
  # Acceptance is restated from the requirements here rather than read from
  # GattConfig::RULES, so the subject is not graded against itself. Every
  # expectation is derived from the raw Hash alone, so the input rantly prints
  # for a failing case is all that is needed to reproduce it.
  it "Property 17: normalises any raw config to in-range values with one warning per rejection" do
    options = defaults.keys

    accepts = {
      "gatt_scan"          => ->(v) { v.equal?(true) || v.equal?(false) },
      "gatt_walk_timeout"  => ->(v) { (v.is_a?(Integer) || v.is_a?(Float)) && v >= 1 && v <= 60 },
      "gatt_walk_parallel" => ->(v) { v.is_a?(Integer) && v >= 1 && v <= 8 },
      "gatt_read_all"      => ->(v) { v.equal?(true) || v.equal?(false) }
    }

    # Procs, because rantly instance_evals generators on itself.
    own_type = {
      "gatt_scan"          => proc { boolean },
      "gatt_walk_timeout"  => proc {
        branch(proc { integer(1..60) }, proc { 1 + float * 59 }, proc { choose(1, 60, 1.0, 60.0) })
      },
      "gatt_walk_parallel" => proc { integer(1..8) },
      "gatt_read_all"      => proc { boolean }
    }
    any_value = proc {
      freq(
        [3, proc { choose("true", "false", "10", "3", "1", "60", "yes", "", " 10", "2.5") }],
        [1, proc { string }],
        [2, proc { boolean }],
        [3, proc { choose(-1, 0, 1, 3, 8, 9, 60, 61, 2**64, -2**64) }],
        [2, proc { integer(-100..100) }],
        [3, proc {
          choose(Float::NAN, Float::INFINITY, -Float::INFINITY, -0.0, 0.999,
                 1.0, 3.0, 8.0, 60.0, 60.001, Float::MAX)
        }],
        [2, proc { float * 70 }],
        [2, proc { choose([], [true], [3], [10], ["true"], [[1]]) }],
        [2, proc { choose({}, { "gatt_scan" => true }, { "value" => 10 }) }],
        [2, proc { choose(:true, :false, :"10", :gatt_scan) }]
      )
    }
    unrelated_keys = ["info_scan_rate", "log_level", "GATT_SCAN", "gatt_scan ",
                      "gatt-walk-timeout", :gatt_scan, "gatt_walk_parallel_max"]

    seen = Hash.new(0)

    property_of {
      pairs = []
      options.each do |option|
        case freq([2, :literal, :absent], [2, :literal, :nil], [3, :literal, :own], [5, :literal, :any])
        when :absent then next
        when :nil    then pairs << [option, nil]
        when :own    then pairs << [option, call(own_type[option])]
        else              pairs << [option, call(any_value)]
        end
      end
      range(0, 3).times do
        pairs << [branch(proc { choose(*unrelated_keys) }, proc { string(:alpha) }), call(any_value)]
      end
      pairs.shuffle.to_h
    }.check(100) { |raw|
      values, warnings = normalise(raw)

      expect(values.keys).to match_array(options)
      expect(values["gatt_scan"]).to be(true).or be(false)
      expect(values["gatt_read_all"]).to be(true).or be(false)
      expect(values["gatt_walk_timeout"]).to be_an(Integer).or be_a(Float)
      expect(values["gatt_walk_timeout"]).to be_between(1, 60)
      expect(values["gatt_walk_parallel"]).to be_an(Integer)
      expect(values["gatt_walk_parallel"]).to be_between(1, 8)

      # Equal counts plus a key set equal to the rejected options means each
      # rejected option has exactly one warning and no warning is unattributed
      # (an unattributed one would group under nil).
      rejected  = options.select { |o| !raw[o].nil? && !accepts[o].call(raw[o]) }
      by_option = warnings.group_by { |w| options.find { |o| w.start_with?("#{o}: ") } }
      expect(warnings.size).to eq(rejected.size)
      expect(by_option.keys).to match_array(rejected)

      options.each do |o|
        outcome =
          if !raw.key?(o)            then :absent
          elsif raw[o].nil?          then :nil
          elsif rejected.include?(o) then :rejected
          else                            :accepted
          end
        seen[[o, outcome]] += 1

        case outcome
        when :accepted
          expect(values[o]).to eql(raw[o])
        when :rejected
          expect(values[o]).to eql(defaults[o])
          expect(by_option[o].first).to include(raw[o].inspect, "default #{defaults[o].inspect}")
        else
          expect(values[o]).to eql(defaults[o])
        end
      end
    }

    # A generator that never reached one of the four cases for an option would
    # let the property pass without testing that case.
    expect(options.product(%i[absent nil accepted rejected]) - seen.keys).to eq([])
  end
end
