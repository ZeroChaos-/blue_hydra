require 'spec_helper'
require 'blue_hydra/uuid_names'
require 'blue_hydra/att_codec'
require 'digest'
require 'json'
require 'tmpdir'

describe BlueHydra::UuidNames do
  # Locals rather than constants: a constant here would land on Object and be
  # shared with every other spec file. The examples close over them. Expected
  # names are written out from the vendored files at the pinned commit rather
  # than read back through the subject.
  vendored_root = File.expand_path("../lib/blue_hydra/data/bluetooth-numbers-database", __dir__)
  vendored_v1   = File.join(vendored_root, "v1")
  json_files    = %w[service_uuids.json characteristic_uuids.json descriptor_uuids.json]

  # Listed under both service_uuids.json and characteristic_uuids.json, with a
  # different name in each, at the pinned commit.
  dfu_uuid = "8e400001-f315-4f60-9fb8-838830daea50"

  # Starts with 0000 like a Base UUID but has a different tail, so it is a
  # genuine 128-bit UUID. Its name also carries a non-ASCII character.
  lego_uuid = "00001623-1212-efde-1623-785feabcd123"

  # Not in any of the three files.
  unlisted_uuid = "12345678-9abc-def0-1234-56789abcdef0"

  # 0x1800 on the Base UUID with the upper 16 bits set: a 32-bit UUID, which ATT
  # never carries, so it must not fold to 0x1800.
  upper_bits_uuid = "00011800-0000-1000-8000-00805f9b34fb"

  # Every message the subject logs, as [level, message]. The mutex is for the
  # examples that render from several threads at once.
  let(:log)       { [] }
  let(:log_mutex) { Mutex.new }
  let(:recording_logger) do
    entries = log
    lock    = log_mutex
    Object.new.tap do |logger|
      %i[debug info warn error fatal unknown].each do |level|
        logger.define_singleton_method(level) do |message = nil, &block|
          lock.synchronize { entries << [level, message || block&.call] }
          true
        end
      end
    end
  end

  def logged(level)
    log_mutex.synchronize { log.select { |l, _| l == level }.map(&:last) }
  end

  def uuid_struct(bits, hex)
    BlueHydra::AttCodec::Uuid.new(bits: bits, hex: hex)
  end

  # Points the subject at a scratch directory holding files, a Hash of file
  # name => contents, or :directory to put a directory where the file should be
  # (File.read then raises EISDIR, an unreadable file even for root). The
  # directory is removed when the block returns.
  def with_data_dir(files)
    Dir.mktmpdir("uuid_names_spec") do |dir|
      files.each do |name, contents|
        path = File.join(dir, name)
        contents == :directory ? Dir.mkdir(path) : File.write(path, contents)
      end
      described_class.data_dir = dir
      yield File.expand_path(dir)
    end
  end

  before do
    described_class.reset!
    allow(BlueHydra).to receive(:logger).and_return(recording_logger)
  end

  after do
    described_class.reset!
  end

  describe "the vendored Uuid_Database (Requirement 10.1, 10.8)" do
    source_md = File.join(vendored_root, "SOURCE.md")

    # SOURCE.md's file table: | `path` | bytes | `sha256` | entries |
    def source_rows(source_md)
      File.read(source_md).scan(/^\| `([^`]+)` \| (\d+) \| `([0-9a-f]{64})` \|/)
          .to_h { |path, bytes, sha| [path, { bytes: Integer(bytes), sha256: sha }] }
    end

    it "is read from lib/ so it ships with the package" do
      expect(described_class::DATA_DIR).to eq(vendored_v1)
    end

    json_files.each do |file|
      it "holds v1/#{file}, a JSON array of entries with a String name and uuid" do
        path = File.join(vendored_v1, file)
        expect(File.file?(path)).to be true

        entries = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        expect(entries).to be_an(Array)
        expect(entries).not_to be_empty
        entries.each do |entry|
          expect(entry["name"]).to be_a(String).and(satisfy { |n| !n.empty? })
          expect(entry["uuid"]).to match(/\A(?:\h{4}|\h{8}-\h{4}-\h{4}-\h{4}-\h{12})\z/)
        end
      end
    end

    it "holds the upstream BSD-3 LICENSE" do
      license = File.read(File.join(vendored_root, "LICENSE"))
      expect(license).to include("Nordic Semiconductor ASA")
      expect(license).to include("Redistribution and use in source and binary forms")
    end

    it "records the upstream repository and the full commit SHA in SOURCE.md" do
      source = File.read(source_md)
      expect(source).to include("https://github.com/NordicSemiconductor/bluetooth-numbers-database")
      expect(source).to match(/^- Commit: `[0-9a-f]{40}`/)
    end

    it "matches the size and sha256 SOURCE.md records for every vendored file" do
      rows = source_rows(source_md)
      expect(rows.keys).to contain_exactly("LICENSE", *json_files.map { |f| "v1/#{f}" })

      rows.each do |path, row|
        file = File.join(vendored_root, path)
        expect([path, File.size(file)]).to eq([path, row[:bytes]])
        expect([path, Digest::SHA256.file(file).hexdigest]).to eq([path, row[:sha256]])
      end
    end

    it "loads all three tables with no error and no skipped entries" do
      described_class.service(0x1800)
      described_class.characteristic(0x2A00)
      described_class.descriptor(0x2902)

      expect(log).to be_empty
    end
  end

  describe ".render" do
    it "renders 0x1800 as Generic Access (0x1800) and logs no load error (Requirement 10.3, 10.8)" do
      expect(described_class.render(:service, 0x1800)).to eq("Generic Access (0x1800)")
      expect(logged(:error)).to be_empty
      expect(logged(:warn)).to be_empty
    end

    it "names a UUID from each role's file" do
      expect(described_class.service(0x180F)).to eq("Battery Service (0x180f)")
      expect(described_class.characteristic(0x2A00)).to eq("Device Name (0x2a00)")
      expect(described_class.descriptor(0x2902)).to eq("Client Characteristic Configuration (0x2902)")
    end

    it "has service/characteristic/descriptor agree with render for their role" do
      expect(described_class.service(0x1800)).to eq(described_class.render(:service, 0x1800))
      expect(described_class.characteristic(0x2A00)).to eq(described_class.render(:characteristic, 0x2A00))
      expect(described_class.descriptor(0x2902)).to eq(described_class.render(:descriptor, 0x2902))
    end

    it "renders a 128-bit UUID as 8-4-4-4-12 lowercase hex" do
      expect(described_class.service(dfu_uuid.upcase))
        .to eq("Experimental Buttonless DFU Service (#{dfu_uuid})")
    end

    it "keeps a non-ASCII name intact as UTF-8" do
      rendered = described_class.service(lego_uuid)
      expect(rendered).to eq("LEGO\u00AE Wireless Protocol v3 Hub Service (#{lego_uuid})")
      expect(rendered.encoding).to eq(Encoding::UTF_8)
      expect(rendered).to be_valid_encoding
    end

    it "resolves a UUID listed twice to the first entry" do
      # characteristic_uuids.json lists 0x2B1D..0x2B28 twice at the pinned commit
      expect(described_class.characteristic(0x2B1D)).to eq("RC Feature (0x2b1d)")
    end

    it "raises ArgumentError for an unknown role" do
      expect { described_class.render(:included_service, 0x1800) }.to raise_error(ArgumentError, /role/)
      expect(described_class.name_unknown_count).to eq(0)
    end

    it "raises ArgumentError for an unparseable uuid without counting it" do
      expect { described_class.service("not-a-uuid") }.to raise_error(ArgumentError)
      expect(described_class.name_unknown_count).to eq(0)
    end
  end

  describe "Unknown and the name-unknown counter (Requirement 10.2)" do
    it "renders an unlisted UUID as Unknown (<uuid>) and counts it once" do
      expect(described_class.service(0xFFFF)).to eq("Unknown (0xffff)")
      expect(described_class.name_unknown_count).to eq(1)

      expect(described_class.characteristic(unlisted_uuid.upcase)).to eq("Unknown (#{unlisted_uuid})")
      expect(described_class.name_unknown_count).to eq(2)
    end

    it "counts every Unknown render, not every distinct UUID" do
      3.times { described_class.descriptor(0xFFFF) }
      expect(described_class.name_unknown_count).to eq(3)
    end

    it "does not count a named render" do
      described_class.service(0x1800)
      described_class.service(dfu_uuid)
      described_class.characteristic(0x2A00)
      described_class.descriptor(0x2902)
      expect(described_class.name_unknown_count).to eq(0)
    end

    it "is zeroed by reset!" do
      described_class.service(0xFFFF)
      described_class.reset!
      expect(described_class.name_unknown_count).to eq(0)
    end

    it "counts every Unknown render made from concurrent threads" do
      threads = 8
      per_thread = 250
      gate = Queue.new
      workers = Array.new(threads) do
        Thread.new do
          gate.pop
          per_thread.times do
            described_class.service(0xFFFF)
            described_class.service(0x1800)
          end
        end
      end
      threads.times { gate << :go }
      workers.each(&:join)

      expect(described_class.name_unknown_count).to eq(threads * per_thread)
    end
  end

  describe "Base UUID folding (Requirement 10.4)" do
    it "folds a 128-bit Base UUID spelling to its 16-bit form for lookup and output" do
      expect(described_class.service("00001800-0000-1000-8000-00805f9b34fb")).to eq("Generic Access (0x1800)")
      expect(described_class.service("00001800-0000-1000-8000-00805F9B34FB")).to eq("Generic Access (0x1800)")
      expect(described_class.service("0000180000001000800000805f9b34fb")).to eq("Generic Access (0x1800)")
      expect(described_class.service(uuid_struct(128, "0000180000001000800000805f9b34fb")))
        .to eq("Generic Access (0x1800)")
    end

    it "folds an unlisted Base UUID to its 16-bit form in Unknown too" do
      expect(described_class.service("0000ffff-0000-1000-8000-00805f9b34fb")).to eq("Unknown (0xffff)")
    end

    it "keeps a Base UUID with non-zero upper 16 bits in 128-bit form" do
      expect(described_class.service(upper_bits_uuid)).to eq("Unknown (#{upper_bits_uuid})")
      expect(described_class.service("ffff1800-0000-1000-8000-00805f9b34fb"))
        .to eq("Unknown (ffff1800-0000-1000-8000-00805f9b34fb)")
      expect(described_class.name_unknown_count).to eq(2)
    end

    it "keeps a 0000-prefixed UUID off the Base UUID in 128-bit form" do
      expect(described_class.canonical(lego_uuid)).to eq(lego_uuid)
      expect(described_class.canonical("00001800-0000-1000-8000-00805f9b34fc"))
        .to eq("00001800-0000-1000-8000-00805f9b34fc")
    end
  end

  describe "role separation (Requirement 10.5)" do
    it "renders a UUID listed only under another role as Unknown" do
      expect(described_class.characteristic(0x2A00)).to eq("Device Name (0x2a00)")
      expect(described_class.service(0x2A00)).to eq("Unknown (0x2a00)")
      expect(described_class.descriptor(0x2A00)).to eq("Unknown (0x2a00)")

      expect(described_class.characteristic(0x1800)).to eq("Unknown (0x1800)")
      expect(described_class.descriptor(0x1800)).to eq("Unknown (0x1800)")

      expect(described_class.service(0x2902)).to eq("Unknown (0x2902)")
      expect(described_class.characteristic(0x2902)).to eq("Unknown (0x2902)")

      expect(described_class.name_unknown_count).to eq(6)
    end

    it "gives a UUID listed under two roles each role's own name" do
      expect(described_class.service(dfu_uuid)).to eq("Experimental Buttonless DFU Service (#{dfu_uuid})")
      expect(described_class.characteristic(dfu_uuid)).to eq("Experimental Buttonless DFU (#{dfu_uuid})")
      expect(described_class.descriptor(dfu_uuid)).to eq("Unknown (#{dfu_uuid})")
    end
  end

  describe "a bad Uuid_Database file (Requirement 10.6)" do
    {
      "missing"             => {},
      "unreadable"          => { "service_uuids.json" => :directory },
      "not valid JSON"      => { "service_uuids.json" => "[{\"name\": \"Generic Access\", \"uuid\": " },
      "not a JSON array"    => { "service_uuids.json" => '{"name": "Generic Access", "uuid": "1800"}' },
    }.each do |kind, files|
      it "renders Unknown without raising and logs one error naming the file when #{kind}" do
        with_data_dir(files) do |dir|
          rendered = nil
          expect { rendered = Array.new(3) { described_class.service(0x1800) } }.not_to raise_error
          expect(rendered).to all(eq("Unknown (0x1800)"))
          expect(described_class.name_unknown_count).to eq(3)

          errors = logged(:error)
          expect(errors.size).to eq(1)
          expect(errors.first).to include(File.join(dir, "service_uuids.json"))
        end
      end
    end

    it "logs the error once for the process, even when the table is reloaded" do
      with_data_dir("service_uuids.json" => "garbage") do |dir|
        described_class.service(0x1800)
        described_class.data_dir = dir   # drops the loaded tables
        described_class.service(0x1800)
        described_class.service(dfu_uuid)

        expect(logged(:error).size).to eq(1)
        expect(described_class.name_unknown_count).to eq(3)
      end
    end

    it "logs one error per bad file and leaves the other roles' good files named" do
      characteristics = File.read(File.join(vendored_v1, "characteristic_uuids.json"))
      with_data_dir("service_uuids.json" => "garbage", "characteristic_uuids.json" => characteristics) do |dir|
        expect(described_class.service(0x1800)).to eq("Unknown (0x1800)")
        expect(described_class.characteristic(0x2A00)).to eq("Device Name (0x2a00)")
        expect(described_class.descriptor(0x2902)).to eq("Unknown (0x2902)")
        expect(described_class.descriptor(0x2902)).to eq("Unknown (0x2902)")

        errors = logged(:error)
        expect(errors.size).to eq(2)
        expect(errors[0]).to include(File.join(dir, "service_uuids.json"))
        expect(errors[1]).to include(File.join(dir, "descriptor_uuids.json"))
      end
    end

    it "logs one error when several threads load the bad file at once" do
      with_data_dir("service_uuids.json" => "garbage") do
        gate = Queue.new
        workers = Array.new(8) do
          Thread.new do
            gate.pop
            described_class.service(0x1800)
          end
        end
        8.times { gate << :go }
        expect(workers.map(&:value)).to all(eq("Unknown (0x1800)"))

        expect(logged(:error).size).to eq(1)
      end
    end

    it "skips unusable entries with one warning and names the usable ones" do
      entries = [
        { "name" => "Integer uuid", "uuid" => 0x1800 },   # first, so it would win if not skipped
        { "name" => "Generic Access", "uuid" => "1800" },
        { "name" => "No uuid" },
        { "uuid" => "1801" },
        { "name" => "", "uuid" => "1802" },
        { "name" => "Bad uuid", "uuid" => "zz" },
        "not an object",
        nil
      ]
      with_data_dir("service_uuids.json" => JSON.generate(entries)) do |dir|
        expect(described_class.service(0x1800)).to eq("Generic Access (0x1800)")
        expect(described_class.service(0x1801)).to eq("Unknown (0x1801)")
        expect(described_class.service(0x1802)).to eq("Unknown (0x1802)")

        expect(logged(:error)).to be_empty
        warnings = logged(:warn)
        expect(warnings.size).to eq(1)
        expect(warnings.first).to include(File.join(dir, "service_uuids.json")).and(include("skipped 7"))
      end
    end

    it "keeps the first of two entries for one UUID and folds Base UUID spellings in the file" do
      entries = [
        { "name" => "First", "uuid" => "2B1D" },
        { "name" => "Second", "uuid" => "2b1d" },
        { "name" => "Folded", "uuid" => "00002B1E-0000-1000-8000-00805F9B34FB" }
      ]
      with_data_dir("characteristic_uuids.json" => JSON.generate(entries)) do
        expect(described_class.characteristic(0x2B1D)).to eq("First (0x2b1d)")
        expect(described_class.characteristic(0x2B1E)).to eq("Folded (0x2b1e)")
      end
    end

    it "is back on the vendored data after reset!" do
      with_data_dir({}) do
        expect(described_class.service(0x1800)).to eq("Unknown (0x1800)")
      end
      described_class.reset!
      expect(described_class.service(0x1800)).to eq("Generic Access (0x1800)")
    end
  end

  describe ".canonical (Requirement 10.3, 10.4)" do
    {
      "16-bit Integer"                     => [0x1800, "0x1800"],
      "16-bit Integer 0"                   => [0, "0x0000"],
      "16-bit Integer 0xFFFF"              => [0xFFFF, "0xffff"],
      "4 hex lowercase"                    => ["180f", "0x180f"],
      "4 hex uppercase"                    => ["180F", "0x180f"],
      "4 hex with 0x prefix"               => ["0x180F", "0x180f"],
      "4 hex with 0X prefix"               => ["0X180f", "0x180f"],
      "128-bit Base UUID, hyphens"         => ["00001800-0000-1000-8000-00805f9b34fb", "0x1800"],
      "128-bit Base UUID, uppercase"       => ["00001800-0000-1000-8000-00805F9B34FB", "0x1800"],
      "128-bit Base UUID, no hyphens"      => ["0000180000001000800000805f9b34fb", "0x1800"],
      "128-bit Base UUID, 0x prefix"       => ["0x0000180000001000800000805f9b34fb", "0x1800"],
      "128-bit, hyphens"                   => [dfu_uuid, dfu_uuid],
      "128-bit, uppercase"                 => [dfu_uuid.upcase, dfu_uuid],
      "128-bit, mixed case"                => ["8E400001-f315-4F60-9fb8-838830DAEA50", dfu_uuid],
      "128-bit, no hyphens"                => [dfu_uuid.delete("-"), dfu_uuid],
      "128-bit, upper bits set"            => [upper_bits_uuid.upcase, upper_bits_uuid],
      "AttCodec::Uuid 16-bit"              => [BlueHydra::AttCodec::Uuid.new(bits: 16, hex: "1800"), "0x1800"],
      "AttCodec::Uuid 16-bit uppercase"    => [BlueHydra::AttCodec::Uuid.new(bits: 16, hex: "2A00"), "0x2a00"],
      "AttCodec::Uuid 128-bit Base UUID"   => [BlueHydra::AttCodec::Uuid.new(bits: 128, hex: "0000180000001000800000805f9b34fb"), "0x1800"],
      "AttCodec::Uuid 128-bit"             => [BlueHydra::AttCodec::Uuid.new(bits: 128, hex: dfu_uuid.delete("-")), dfu_uuid],
    }.each do |spelling, (input, expected)|
      it "accepts a #{spelling}" do
        expect(described_class.canonical(input)).to eq(expected)
      end
    end

    it "agrees with what AttCodec decodes off the wire" do
      # Characteristic declaration: properties, value handle, then the UUID
      # little-endian on air.
      bytes = [0x02, 0x03, 0x00].pack("C*") + ["8e400001f3154f609fb8838830daea50"].pack("H*").reverse
      decl = BlueHydra::AttCodec.decode_characteristic_declaration(bytes)
      expect(described_class.canonical(decl.uuid)).to eq(dfu_uuid)
    end

    {
      "negative Integer"          => -1,
      "Integer over 16 bits"      => 0x10000,
      "empty String"              => "",
      "3 hex digits"              => "180",
      "5 hex digits"              => "18000",
      "32-bit UUID"               => "00001800",
      "31 hex digits"             => "0000180000001000800000805f9b34f",
      "33 hex digits"             => "0000180000001000800000805f9b34fb0",
      "non-hex digits"            => "18g0",
      "surrounding whitespace"    => " 1800",
      "nil"                       => nil,
      "Float"                     => 6144.0,
      "Symbol"                    => :uuid,
      "plain Object"              => Object.new,
    }.each do |what, input|
      it "raises ArgumentError for a #{what}" do
        expect { described_class.canonical(input) }.to raise_error(ArgumentError)
      end
    end

    it "raises ArgumentError for an AttCodec::Uuid of another width" do
      expect { described_class.canonical(uuid_struct(32, "00001800")) }.to raise_error(ArgumentError)
    end
  end

  describe ".sort_key (Requirement 11.5)" do
    it "is the 128-bit value, with a 16-bit UUID expanded onto the Base UUID" do
      expect(described_class.sort_key("0x1800")).to eq(0x0000180000001000800000805f9b34fb)
      expect(described_class.sort_key(0x1800)).to eq(0x0000180000001000800000805f9b34fb)
      expect(described_class.sort_key(dfu_uuid)).to eq(0x8e400001f3154f609fb8838830daea50)
    end

    it "reads the uuid out of a rendered name, including Unknown" do
      expect(described_class.sort_key("Generic Access (0x1800)")).to eq(described_class.sort_key("0x1800"))
      expect(described_class.sort_key("Unknown (0x2a00)")).to eq(described_class.sort_key(0x2A00))
      expect(described_class.sort_key("Unknown (#{dfu_uuid})")).to eq(described_class.sort_key(dfu_uuid))
    end

    it "takes the last parenthesised group when the name has parentheses of its own" do
      ras = described_class.service(0x185B)
      expect(ras).to eq("Ranging Service (RAS) (0x185b)")
      expect(described_class.sort_key(ras)).to eq(described_class.sort_key(0x185B))

      oad = described_class.service("F000FFC0-0451-4000-B000-000000000000")
      expect(oad).to eq("Texas Instruments Over-the-Air Download (OAD) Service (f000ffc0-0451-4000-b000-000000000000)")
      expect(described_class.sort_key(oad)).to eq(0xf000ffc004514000b000000000000000)
    end

    it "gives a 16-bit UUID and its 128-bit Base UUID spelling the same key" do
      expect(described_class.sort_key("Generic Access (0x1800)"))
        .to eq(described_class.sort_key("00001800-0000-1000-8000-00805F9B34FB"))
    end

    it "orders 16-bit and 128-bit UUIDs together by 128-bit value" do
      rendered = [
        "Unknown (#{dfu_uuid})",
        "Battery Service (0x180f)",
        "Unknown (#{upper_bits_uuid})",
        "Unknown (00000001-0000-0000-0000-000000000000)",
        "Generic Access (0x1800)"
      ]
      expect(rendered.sort_by { |r| described_class.sort_key(r) }).to eq([
        "Unknown (00000001-0000-0000-0000-000000000000)",
        "Generic Access (0x1800)",
        "Battery Service (0x180f)",
        "Unknown (#{upper_bits_uuid})",
        "Unknown (#{dfu_uuid})"
      ])
    end

    it "raises ArgumentError when there is no uuid to read" do
      expect { described_class.sort_key("Generic Access") }.to raise_error(ArgumentError)
      expect { described_class.sort_key("Generic Access (zz)") }.to raise_error(ArgumentError)
    end
  end

  # Feature: gatt-service-scanning, Property 9: Uuid_Formatter output is invariant under spelling
  #
  # Validates: Requirements 10.4, 10.7
  #
  # Each case is one UUID and every spelling of it the subject accepts:
  #   * a 16-bit UUID: the Integer; 4 hex digits in lower, upper and mixed
  #     case, each bare and with "0x" and "0X"; its Bluetooth Base UUID
  #     expansion in lower, upper and mixed case, with and without hyphens; and
  #     the AttCodec::Uuid the codec decodes from its 2-octet and its 16-octet
  #     on-air form.
  #   * any other 128-bit UUID: lower, upper and mixed case, with and without
  #     hyphens, and the AttCodec::Uuid decoded from its on-air octets.
  # Under each role every spelling must render the same string, whose uuid
  # part is the expected one, and canonical and sort_key must agree across the
  # spellings. The expected uuid part is built by the generator from the value
  # it drew, and the expected sort key from that, never from the subject. Every
  # Unknown render must count exactly once; canonical and sort_key count
  # nothing.
  #
  # Values are biased toward the vendored files' own keys, read straight from
  # the JSON, so named renders are exercised as well as Unknown ones: Nordic
  # 16-bit and 128-bit keys of a random role, random values, and Base UUID
  # tails with non-zero upper 16 bits, half of them over a Nordic 16-bit key so
  # that wrongly folding one would turn an Unknown into a name. Every printed
  # case is [expected uuid part, spellings], enough to reproduce it.
  it "Property 9: renders, canonicalises and sorts every spelling of a UUID identically under every role" do
    roles      = %i[service characteristic descriptor]
    base_value = 0x0000_0000_0000_1000_8000_0080_5f9b_34fb
    base_tail  = "00001000800000805f9b34fb"
    field16    = 0xFFFF << 96
    # A 128-bit value that is a 16-bit UUID on the Base UUID: with its 16-bit
    # field cleared it equals the Base UUID, so its upper 16 bits are zero.
    on_base16  = ->(value) { (value & ~field16) == base_value }

    nordic16  = {}
    nordic128 = {}
    roles.each do |role|
      path  = File.join(vendored_v1, "#{role}_uuids.json")
      uuids = JSON.parse(File.read(path, encoding: Encoding::UTF_8)).map { |entry| entry["uuid"] }
      short, long = uuids.partition { |uuid| uuid.length == 4 }
      nordic16[role]  = short.map { |uuid| uuid.to_i(16) }.uniq
      nordic128[role] = long.map { |uuid| uuid.delete("-").to_i(16) }.reject(&on_base16).uniq
    end
    # descriptor_uuids.json lists no 128-bit UUID at the pinned commit.
    roles128 = roles.reject { |role| nordic128[role].empty? }
    expect(roles.map { |role| nordic16[role].size }).to all(be > 0)
    expect(roles128).not_to be_empty

    rendered_re = /\A(.+) \(([^()]+)\)\z/
    form16      = /\A0x[0-9a-f]{4}\z/
    form128     = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
    seen        = Hash.new(0)

    # Blocks and procs here run under rantly's instance_eval: they reach the
    # locals above and rantly's generators, not the example's helper methods.
    property_of {
      mix    = ->(text) { text.chars.map { |c| boolean ? c.upcase : c }.join }
      cases  = ->(text) { [text, text.upcase, mix.call(text)] }
      dashed = ->(digits) { [digits[0, 8], digits[8, 4], digits[12, 4], digits[16, 4], digits[20, 12]].join("-") }
      # The codec reads UUIDs least-significant octet first, as they are on air.
      decoded = ->(value, octets) do
        BlueHydra::AttCodec.uuid_from_bytes([format("%0#{octets * 2}x", value)].pack("H*").reverse)
      end
      nordic16_key = proc { choose(*nordic16[choose(*roles)]) }

      if freq([3, :literal, true], [2, :literal, false])
        value = freq([3, nordic16_key],
                     [2, proc { range(0, 0xFFFF) }],
                     [1, proc { choose(0x0000, 0xFFFF, 0xABCD, 0x1800) }])
        hex4 = format("%04x", value)
        long = format("0000%04x", value) + base_tail
        spellings = [
          value,
          *cases.call(hex4).product(["", "0x", "0X"]).map { |hex, prefix| prefix + hex },
          *cases.call(dashed.call(long)),
          *cases.call(long),
          decoded.call(value, 2),
          decoded.call(base_value | (value << 96), 16)
        ]
        [format("0x%04x", value), spellings]
      else
        value = freq([3, proc { choose(*nordic128[choose(*roles128)]) }],
                     [2, proc {
                       random = range(0, 2**128 - 1)
                       on_base16.call(random) ? random | (1 << 112) : random
                     }],
                     # non-zero upper 16 bits over the Base tail: a 32-bit
                     # UUID, which must not fold to its low 16 bits
                     [2, proc {
                       (range(1, 0xFFFF) << 112) | (branch(nordic16_key, proc { range(0, 0xFFFF) }) << 96) | base_value
                     }])
        digits = format("%032x", value)
        spellings = [*cases.call(dashed.call(digits)), *cases.call(digits), decoded.call(value, 16)]
        [dashed.call(digits), spellings]
      end
    # 300 rather than 100 for the coverage assertion below: the rarest
    # combination, a Nordic 128-bit key of one role, is about 8.6% of cases, so
    # 100 cases would miss one of the two about once in 4,000 runs and 300
    # about once in 10^11. The run takes well under a second.
    }.check(300) { |expected_uuid, spellings|
      short        = expected_uuid.start_with?("0x")
      form         = short ? form16 : form128
      expected_key = short ? base_value | (expected_uuid[2..].to_i(16) << 96) : expected_uuid.delete("-").to_i(16)
      count_before = described_class.name_unknown_count
      unknown      = 0

      roles.each do |role|
        renders  = spellings.map { |spelling| described_class.render(role, spelling) }
        distinct = spellings.group_by.with_index { |_, i| renders[i] }
        expect(distinct.size).to eq(1), "#{role}: spellings render differently: #{distinct.inspect}"

        rendered = renders.first
        expect(rendered).to match(rendered_re)
        name, uuid = rendered_re.match(rendered).captures
        expect(uuid).to match(form)
        expect(uuid).to eq(expected_uuid)
        expect(described_class.sort_key(rendered)).to eq(expected_key)

        unknown += renders.count { |r| r.start_with?("Unknown (") }
        seen[[role, short ? 16 : 128, name != "Unknown"]] += 1
      end

      canonical = spellings.to_h { |spelling| [spelling, described_class.canonical(spelling)] }
      expect(canonical.reject { |_, c| c == expected_uuid }).to eq({})
      sort_key = spellings.to_h { |spelling| [spelling, described_class.sort_key(spelling)] }
      expect(sort_key.reject { |_, k| k == expected_key }).to eq({})

      expect(described_class.name_unknown_count - count_before).to eq(unknown)
    }

    # A generator that stopped reaching a combination would let the property
    # pass without testing it. Named is expected only where Nordic lists a
    # UUID of that role and width.
    expected_seen = roles.product([16, 128], [true, false]).reject do |role, width, named|
      named && (width == 16 ? nordic16 : nordic128)[role].empty?
    end
    expect(expected_seen - seen.keys).to eq([])
    # The vendored tables loaded cleanly, so the named renders came from them.
    expect(log).to be_empty
  end
end
