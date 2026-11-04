require 'socket'
require 'monitor'
require 'json'
require 'blue_hydra/att_codec'
require 'blue_hydra/uuid_names'

# Spec harness for the Att_Bearer (Requirement 16.1): a fake of the socket
# GattWalker#open_socket would create, with a compliant GATT server behind it,
# all on a fake clock. No real socket of any kind is opened here.
#
#   clock  = FakeClock.new
#   db     = GattDatabase.build { primary(0x1800) { characteristic 0x2A00, value: "Name" } }
#   peer   = FakeAttPeer.new(db, clock: clock)
#   walker = peer.build_walker(read_all: false)   # or peer.install(any_walker)
#   report = walker.run
#   peer.requests.map(&:opcode)                   # every client request, in order
#
# FakeAttPeer is the socket. It provides exactly the surface GattWalker::Bearer
# uses (bind, connect_nonblock, getsockopt(SOL_SOCKET, SO_ERROR), send,
# recv_nonblock(maxlen, exception: false), wait_readable, wait_writable, close,
# closed?), plus recv for completeness. The Bearer's wait seams call
# wait_readable / wait_writable on the socket, so the fake's waits are what
# drive the clock: a wait returns at once when something is ready, jumps the
# clock to the moment a scripted delay ends, or, when nothing will be ready in
# time, moves the clock by the whole timeout and returns nil. Walk_Bound and the
# 30 s transaction timeout therefore run without sleeping.
#
# Request indices in every scripting hook count client requests only, from 0,
# so `requests[i]` is the request a hook keyed `i` acts on. The walker's first
# request is its Exchange MTU Request, index 0. Replies the walker sends to
# PDUs the peer injected are not client requests; they go to peer_received.

# The walker's clock: seam (an object with #now), moved only by advance and
# advance_to - in practice by FakeAttPeer's waits.
class FakeClock
  def initialize(start = 1_000.0)
    @now   = Float(start)
    @mutex = Mutex.new
  end

  def now
    @mutex.synchronize { @now }
  end

  def advance(seconds)
    unless seconds.is_a?(Numeric) && seconds >= 0 && seconds.finite?
      raise ArgumentError, "advance needs finite seconds >= 0, got #{seconds.inspect}"
    end
    @mutex.synchronize { @now += seconds }
  end

  # Moves to +time+; a time already passed leaves the clock where it is, since a
  # monotonic clock never goes back.
  def advance_to(time)
    raise ArgumentError, "advance_to needs a finite time, got #{time.inspect}" unless time.is_a?(Numeric) && time.finite?
    @mutex.synchronize { @now = [@now, time.to_f].max }
  end
end

# A GATT database and the server-side answers to the client's discovery and
# read requests, per Core 6.3 Vol 3 Part F (ATT) section 3.4 and Part G (GATT)
# sections 3 and 4.
#
# The model is plain Structs, so a spec can compare a Walk's result against it:
#   Service        type (:primary | :secondary), uuid, start, end, includes, characteristics
#   Include        handle (of the include declaration), start, end, uuid
#                  (the included service's UUID, nil when unknown). On air the
#                  declaration carries the UUID only when it is 16-bit (6
#                  octets); otherwise it is the 4-octet form and a client has to
#                  resolve the UUID itself (see resolved_include_uuid).
#   Characteristic decl_handle, value_handle (always decl_handle + 1), properties
#                  (bit field), uuid, value, read_error, descriptors
#   Descriptor     handle, uuid, value, read_error
# UUIDs are BlueHydra::AttCodec::Uuid and keep the width they are given: a
# 16-bit UUID written as 128 bits goes on air as 16 octets.
#
# read_error is the ATT error code a Read, Read Blob or Read By Type of that
# attribute is answered with (0x05 Insufficient Authentication to model a
# Protected_Attribute). A characteristic value without the Read property and
# no explicit read_error answers 0x02 Read Not Permitted.
#
# reject_secondary? models a server that refuses the secondary-service sweep:
# every Read By Group Type for 0x2801 is answered Error Response 0x10
# Unsupported Group Type, as Android's GATT server does (gatt_sr.cc,
# gatts_process_primary_service_req). FakeAttPeer reads the flag and
# answers so (its reject_secondary_services! hook does the same for a database
# built without the flag). The database still holds its secondary services:
# they are what the Walk must not record, and what a 4-octet include can no
# longer resolve (Requirement 6.4), so discovered_services, expected_discovery
# and resolved_include_uuid leave them out when the flag is set.
#
# Build one with the DSL (GattDatabase.build, see Builder), hand
# GattDatabase.new a list of Services, or draw a random one with
# GattDatabase.generate (see Generator), the generator behind Properties 1, 2,
# 15 and 16. Every route ends in GattDatabase.new, which validates the
# Structs. expected_discovery is what a correct full Walk of the database
# discovers, as plain data.
class GattDatabase
  Codec = BlueHydra::AttCodec

  PRIMARY_SERVICE   = Codec.uuid16(0x2800)
  SECONDARY_SERVICE = Codec.uuid16(0x2801)
  INCLUDE           = Codec.uuid16(0x2802)
  CHARACTERISTIC    = Codec.uuid16(0x2803)
  SERVICE_TYPES     = { primary: PRIMARY_SERVICE, secondary: SECONDARY_SERVICE }.freeze

  # Characteristic Properties bits (Core 6.3 Vol 3 Part G 3.3.1.1).
  PROPERTIES = {
    broadcast: 0x01, read: 0x02, write_without_response: 0x04, write: 0x08,
    notify: 0x10, indicate: 0x20, authenticated_signed_writes: 0x40, extended_properties: 0x80
  }.freeze

  # ATT error codes the server answers with (Core 6.3 Vol 3 Part F 3.4.1.1).
  INVALID_HANDLE         = 0x01
  READ_NOT_PERMITTED     = 0x02
  INVALID_PDU            = 0x04
  REQUEST_NOT_SUPPORTED  = 0x06
  INVALID_OFFSET         = 0x07
  ATTRIBUTE_NOT_FOUND    = 0x0A
  ATTRIBUTE_NOT_LONG     = 0x0B
  UNSUPPORTED_GROUP_TYPE = 0x10

  # UUIDs compare as 128-bit values (Core 6.3 Vol 3 Part B 2.5.1): a 16-bit
  # UUID is the Bluetooth Base UUID with bits 96..111 replaced.
  BASE_UUID_SUFFIX = "00001000800000805f9b34fb".freeze

  Service        = Struct.new(:type, :uuid, :start, :end, :includes, :characteristics)
  Include        = Struct.new(:handle, :start, :end, :uuid)
  Characteristic = Struct.new(:decl_handle, :value_handle, :properties, :uuid, :value, :read_error, :descriptors)
  Descriptor     = Struct.new(:handle, :uuid, :value, :read_error)

  # One row of the attribute table the server answers from. group_end is set
  # for service declarations only; kind is :service, :include, :characteristic,
  # :value or :descriptor.
  Attribute = Struct.new(:handle, :type, :value, :read_error, :group_end, :kind)

  class << self
    def build(&block)
      builder = Builder.new
      builder.run(block)
      builder.database
    end

    def empty
      new([])
    end

    # An Integer (16-bit), a 4- or 32-hex-digit String (hyphens allowed, any
    # case) or a Uuid -> Uuid.
    def uuid(value)
      case value
      when Codec::Uuid then value
      when Integer then Codec.uuid16(value)
      when String
        hex = value.delete("-").downcase
        case hex
        when /\A[0-9a-f]{4}\z/  then Codec::Uuid.new(bits: 16, hex: hex)
        when /\A[0-9a-f]{32}\z/ then Codec::Uuid.new(bits: 128, hex: hex)
        else raise ArgumentError, "not a 16- or 128-bit UUID: #{value.inspect}"
        end
      else raise ArgumentError, "not a UUID: #{value.inspect}"
      end
    end

    # An Integer bit field or an Array of PROPERTIES names -> Integer.
    def properties(value)
      case value
      when Integer
        raise ArgumentError, "properties must fit one octet, got #{value}" unless value.between?(0, 0xFF)
        value
      when Array
        value.sum { |name| PROPERTIES.fetch(name) { raise ArgumentError, "unknown property #{name.inspect}" } }
      else raise ArgumentError, "properties must be an Integer or an Array of names, got #{value.inspect}"
      end
    end

    # A String or an Array of octets -> binary String.
    def value(bytes)
      case bytes
      when String then bytes.b
      when Array then bytes.pack("C*")
      else raise ArgumentError, "a value must be a String or an Array of octets, got #{bytes.inspect}"
      end
    end

    # On-air (little-endian) octets of a Uuid.
    def uuid_bytes(uuid)
      [uuid.hex].pack("H*").reverse
    end

    def uuid128(uuid)
      uuid.bits == 128 ? uuid.hex : "0000#{uuid.hex}#{BASE_UUID_SUFFIX}"
    end

    def same_uuid?(a, b)
      uuid128(a) == uuid128(b)
    end

    # 0x2a00 for a 16-bit Uuid, 8-4-4-4-12 for a 128-bit one.
    def uuid_text(uuid)
      return "0x#{uuid.hex}" if uuid.bits == 16
      uuid.hex.unpack("a8a4a4a4a12").join("-")
    end

    # A random database for the model-based properties; see Generator for
    # what it contains and for using it under rantly. +rng+ is an Integer
    # seed (recommended: the database's inspect then carries the call that
    # reproduces it) or an object answering rand like Random.
    #
    #   generate(rng, services: 0..32, chars: 0..16, descriptors: 0..4, values: 0..600,
    #            end_at_ffff: :random, read_errors: 0.05, read_error_codes: [0x05, 0x08, 0x0C, 0x0F],
    #            reject_secondary: false)
    #
    # Counts and value lengths take an Integer or a Range; Generator::DEFAULTS
    # is the one copy of the defaults.
    def generate(rng, **options)
      Generator.new(rng, **Generator::DEFAULTS.merge(options)).database
    end
  end

  # generated_by is the GattDatabase.generate call that reproduces this
  # database, nil for one built any other way.
  attr_reader :services, :attributes, :generated_by

  # +reject_secondary+: the server answers every Read By Group Type for 0x2801
  # with Error Response 0x10 (see the class comment).
  def initialize(services, generated_by: nil, reject_secondary: false)
    unless [true, false].include?(reject_secondary)
      raise ArgumentError, "reject_secondary must be true or false, got #{reject_secondary.inspect}"
    end
    @services         = services
    @attributes       = build_attributes(services)
    @by_handle        = @attributes.to_h { |attribute| [attribute.handle, attribute] }
    @generated_by     = generated_by
    @reject_secondary = reject_secondary
  end

  def reject_secondary?
    @reject_secondary
  end

  # The services a correct full Walk records, in start order: every service,
  # or only the primary ones when the server refuses the 0x2801 sweep
  # (Requirement 6.4). A characteristic's service_index in expected_discovery
  # indexes this list, as GattWalker::WalkState#services holds only what the
  # service procedures found.
  def discovered_services
    reject_secondary? ? services.select { |service| service.type == :primary } : services
  end

  def characteristics
    services.flat_map(&:characteristics)
  end

  def descriptors
    characteristics.flat_map(&:descriptors)
  end

  # One short line, with the reproducing call for a generated database and
  # never an attribute value, so a failing example or rantly's failure output
  # (which interpolates its generated value, i.e. calls to_s) stays readable
  # for a 32-service database with 600-octet values.
  def inspect
    primaries = services.count { |service| service.type == :primary }
    span = attributes.empty? ? "none" : format("0x%04x..0x%04x", attributes.first.handle, services.last.end)
    format("#<GattDatabase%s services=%d (%d primary, %d secondary) includes=%d characteristics=%d descriptors=%d handles=%s>",
           generated_by ? " #{generated_by}" : "", services.size, primaries, services.size - primaries,
           services.sum { |service| service.includes.size }, characteristics.size, descriptors.size, span)
  end
  alias to_s inspect

  # The handle layout, one line per service, include and characteristic, with
  # value lengths but no values.
  def summary
    lines = [inspect]
    services.each do |service|
      lines << format("0x%04x..0x%04x %-9s %s", service.start, service.end, service.type, self.class.uuid_text(service.uuid))
      service.includes.each do |include|
        resolved = resolved_include_uuid(include)
        lines << format("  0x%04x include 0x%04x..0x%04x %s (%d-octet)", include.handle, include.start, include.end,
                        resolved ? self.class.uuid_text(resolved) : "unresolved", attribute(include.handle).value.bytesize)
      end
      service.characteristics.each do |char|
        lines << format("  0x%04x/0x%04x props=0x%02x %s value=%d octets%s descriptors=[%s]", char.decl_handle,
                        char.value_handle, char.properties, self.class.uuid_text(char.uuid), char.value.bytesize,
                        char.read_error ? format(" read_error=0x%02x", char.read_error) : "",
                        char.descriptors.map { |d| format("0x%04x %s", d.handle, self.class.uuid_text(d.uuid)) }.join(", "))
      end
    end
    lines.join("\n")
  end

  # What a correct full Walk of this database discovers (Requirements 6.1 to
  # 6.4, Property 1), shaped like GattWalker::WalkState:
  #
  #   services:        [{type:, uuid:, start:, end:, includes: [{start:, end:, uuid:}]}]
  #                    discovered_services in ascending start: primaries and
  #                    secondaries together, or the primaries alone when the
  #                    server refuses the 0x2801 sweep; an include's uuid is
  #                    resolved_include_uuid (nil for a 4-octet include no
  #                    discovered service starts at)
  #   characteristics: [{service_index:, decl_handle:, value_handle:, properties:, uuid:,
  #                     descriptors: [{handle:, uuid:}]}]
  #                    ascending value_handle; service_index indexes services
  #
  # UUIDs are AttCodec::Uuid at their on-air width. With a block, each non-nil
  # UUID is replaced by block.call(role, uuid), role being :service (includes
  # too), :characteristic or :descriptor, so
  # `expected_discovery { |role, uuid| BlueHydra::UuidNames.render(role, uuid) }`
  # gives the Uuid_Formatter strings a WalkReport carries.
  def expected_discovery(&render)
    render ||= ->(_role, uuid) { uuid }
    discovered = discovered_services
    {
      services: discovered.map do |service|
        { type: service.type, uuid: render.call(:service, service.uuid), start: service.start, end: service.end,
          includes: service.includes.map do |include|
            resolved = resolved_include_uuid(include)
            { start: include.start, end: include.end, uuid: resolved && render.call(:service, resolved) }
          end }
      end,
      characteristics: discovered.each_with_index.flat_map do |service, index|
        service.characteristics.map do |char|
          { service_index: index, decl_handle: char.decl_handle, value_handle: char.value_handle,
            properties: char.properties, uuid: render.call(:characteristic, char.uuid),
            descriptors: char.descriptors.map { |d| { handle: d.handle, uuid: render.call(:descriptor, d.uuid) } } }
        end
      end
    }
  end

  def attribute(handle)
    @by_handle[handle]
  end

  # The UUID a correct client records for +include+ (Requirement 6.2): the one
  # on air in the 6-octet form, otherwise the UUID of the discovered service
  # that starts at the include's start handle, otherwise nil. A secondary
  # service the server kept from the 0x2801 sweep is not discovered, so a
  # 4-octet include of it stays unresolved (Requirement 6.4).
  def resolved_include_uuid(include)
    return include.uuid if include.uuid && include.uuid.bits == 16
    discovered_services.find { |service| service.start == include.start }&.uuid
  end

  # The server's answers. Each takes the decoded request and the ATT_MTU in
  # force and returns the response PDU, an AttCodec ErrorResponse included.

  # Core 6.3 Vol 3 Part F 3.4.4.9 / 3.4.4.10: only grouping types, one value
  # length per page, as many entries as fit in ATT_MTU.
  def read_by_group_type(request, mtu)
    check_mtu(mtu)
    opcode = 0x10
    return error(opcode, request.start_handle, INVALID_HANDLE) unless valid_range?(request)
    unless SERVICE_TYPES.values.any? { |type| self.class.same_uuid?(type, request.uuid) }
      return error(opcode, request.start_handle, UNSUPPORTED_GROUP_TYPE)
    end

    found = in_range(request.start_handle, request.end_handle)
            .select { |attribute| attribute.group_end && self.class.same_uuid?(attribute.type, request.uuid) }
    return error(opcode, request.start_handle, ATTRIBUTE_NOT_FOUND) if found.empty?

    width  = found.first.value.bytesize
    length = 4 + width
    page   = found.take_while { |attribute| attribute.value.bytesize == width }.first((mtu - 2) / length)
    Codec::ReadByGroupTypeResponse.new(
      length: length,
      entries: page.map { |attribute| [attribute.handle, attribute.group_end, Codec.uuid_from_bytes(attribute.value)] }
    )
  end

  # Core 6.3 Vol 3 Part F 3.4.4.1 / 3.4.4.2: every attribute of the type in
  # range, values cut to min(ATT_MTU - 4, 253) octets so an entry fits ATT_MTU -
  # 2 and the one-octet length, one value length per page. An attribute that
  # cannot be read ends the page before it, or is answered with its error when
  # it is the first.
  def read_by_type(request, mtu)
    check_mtu(mtu)
    opcode = 0x08
    return error(opcode, request.start_handle, INVALID_HANDLE) unless valid_range?(request)

    found = in_range(request.start_handle, request.end_handle)
            .select { |attribute| self.class.same_uuid?(attribute.type, request.uuid) }
    return error(opcode, request.start_handle, ATTRIBUTE_NOT_FOUND) if found.empty?
    return error(opcode, found.first.handle, found.first.read_error) if found.first.read_error

    max_value = [mtu - 4, 253].min
    width     = [found.first.value.bytesize, max_value].min
    entries   = []
    found.each do |attribute|
      value = attribute.value.byteslice(0, max_value)
      break if attribute.read_error || value.bytesize != width
      break if 2 + (entries.size + 1) * (width + 2) > mtu
      entries << [attribute.handle, value]
    end
    Codec::ReadByTypeResponse.new(length: width + 2, entries: entries)
  end

  # Core 6.3 Vol 3 Part F 3.4.3.1 / 3.4.3.2: every attribute in range, whatever
  # its type, one UUID width (format) per page.
  def find_information(request, mtu)
    check_mtu(mtu)
    opcode = 0x04
    return error(opcode, request.start_handle, INVALID_HANDLE) unless valid_range?(request)

    found = in_range(request.start_handle, request.end_handle)
    return error(opcode, request.start_handle, ATTRIBUTE_NOT_FOUND) if found.empty?

    bits = found.first.type.bits
    page = found.take_while { |attribute| attribute.type.bits == bits }.first((mtu - 2) / (2 + bits / 8))
    Codec::FindInformationResponse.new(format: bits == 16 ? 0x01 : 0x02,
                                       entries: page.map { |attribute| [attribute.handle, attribute.type] })
  end

  # Core 6.3 Vol 3 Part F 3.4.4.3 / 3.4.4.4: the first ATT_MTU - 1 octets.
  def read(request, mtu)
    check_mtu(mtu)
    attribute = @by_handle[request.handle] or return error(0x0A, request.handle, INVALID_HANDLE)
    return error(0x0A, attribute.handle, attribute.read_error) if attribute.read_error
    Codec::ReadResponse.new(value: attribute.value.byteslice(0, mtu - 1))
  end

  # Core 6.3 Vol 3 Part F 3.4.4.5 / 3.4.4.6: up to ATT_MTU - 1 octets from the
  # offset; an offset equal to the length gets an empty part, one past it 0x07
  # Invalid Offset. A server may answer 0x0B Attribute Not Long for a value
  # short enough to have come whole in one Read Response; with
  # attribute_not_long true this one does so for any offset above 0.
  def read_blob(request, mtu, attribute_not_long: true)
    check_mtu(mtu)
    attribute = @by_handle[request.handle] or return error(0x0C, request.handle, INVALID_HANDLE)
    return error(0x0C, attribute.handle, attribute.read_error) if attribute.read_error

    length = attribute.value.bytesize
    return error(0x0C, attribute.handle, INVALID_OFFSET) if request.offset > length
    if attribute_not_long && request.offset.positive? && length <= mtu - 1
      return error(0x0C, attribute.handle, ATTRIBUTE_NOT_LONG)
    end
    Codec::ReadBlobResponse.new(value: attribute.value.byteslice(request.offset, mtu - 1))
  end

  private

  def check_mtu(mtu)
    raise ArgumentError, "ATT_MTU must be an Integer >= 23, got #{mtu.inspect}" unless mtu.is_a?(Integer) && mtu >= 23
  end

  # Core 6.3 Vol 3 Part F 3.4.3.1 et al.: a Starting Handle of 0x0000 or above
  # the Ending Handle is answered with Invalid Handle.
  def valid_range?(request)
    !request.start_handle.zero? && request.start_handle <= request.end_handle
  end

  def in_range(first, last)
    from = @attributes.bsearch_index { |attribute| attribute.handle >= first } or return []
    @attributes[from..].take_while { |attribute| attribute.handle <= last }
  end

  def error(opcode, handle, code)
    Codec::ErrorResponse.new(request_opcode: opcode, handle: handle, error_code: code)
  end

  def build_attributes(services)
    attributes   = []
    previous_end = 0
    services.each do |service|
      type = SERVICE_TYPES.fetch(service.type) do
        raise ArgumentError, "service type must be :primary or :secondary, got #{service.type.inspect}"
      end
      check_handle(service.start, "service start")
      check_handle(service.end, "service end")
      if service.start <= previous_end || service.end < service.start
        raise ArgumentError, format("service 0x%04x..0x%04x overlaps or is out of order", service.start, service.end)
      end
      previous_end = service.end

      rows = [Attribute.new(handle: service.start, type: type, value: self.class.uuid_bytes(service.uuid),
                            read_error: nil, group_end: service.end, kind: :service)]
      service.includes.each do |include|
        check_handle(include.start, "include start")
        check_handle(include.end, "include end")
        value = [include.start, include.end].pack("S<S<")
        value << self.class.uuid_bytes(include.uuid) if include.uuid && include.uuid.bits == 16
        rows << Attribute.new(handle: include.handle, type: INCLUDE, value: value, kind: :include)
      end
      service.characteristics.each do |char|
        # Core 6.3 Vol 3 Part G 3.3: the value declaration immediately follows
        # the characteristic declaration.
        unless char.value_handle == char.decl_handle + 1
          raise ArgumentError, format("characteristic 0x%04x: value handle must be 0x%04x", char.decl_handle, char.decl_handle + 1)
        end
        declaration = [char.properties, char.value_handle].pack("CS<") + self.class.uuid_bytes(char.uuid)
        readable    = char.properties.anybits?(PROPERTIES[:read])
        rows << Attribute.new(handle: char.decl_handle, type: CHARACTERISTIC, value: declaration, kind: :characteristic)
        rows << Attribute.new(handle: char.value_handle, type: char.uuid, value: char.value.b,
                              read_error: char.read_error || (readable ? nil : READ_NOT_PERMITTED), kind: :value)
        char.descriptors.each do |descriptor|
          rows << Attribute.new(handle: descriptor.handle, type: descriptor.uuid, value: descriptor.value.b,
                                read_error: descriptor.read_error, kind: :descriptor)
        end
      end

      rows.each_cons(2) do |a, b|
        raise ArgumentError, format("handle 0x%04x does not follow 0x%04x", b.handle, a.handle) unless b.handle > a.handle
      end
      unless rows.last.handle <= service.end
        raise ArgumentError, format("handle 0x%04x is past its service's end 0x%04x", rows.last.handle, service.end)
      end
      attributes.concat(rows)
    end
    attributes
  end

  def check_handle(handle, what)
    return if handle.is_a?(Integer) && handle.between?(0x0001, 0xFFFF)
    raise ArgumentError, "#{what} must be a handle in 0x0001..0xFFFF, got #{handle.inspect}"
  end

  # The DSL behind GattDatabase.build. Handles ascend from 0x0001 with no gaps
  # unless asked for: `gap n` leaves n handles unused, and `at:` places a
  # service, include, characteristic or descriptor at a given handle (which
  # must be free and ascending). A service ends at its last attribute, or at
  # `end_at:` (0xFFFF for a database that ends there); a `gap` at the end of a
  # service block widens the service. Includes come first in a service (Core
  # 6.3 Vol 3 Part G 3.2) and may name a service declared later.
  #
  # A block with no parameter runs with the builder as self, so example
  # methods (let, helpers) are out of reach inside it; a block taking one
  # parameter is passed the builder instead (`build { |db| db.primary ... }`).
  #
  #   GattDatabase.build do
  #     primary 0x1800 do
  #       characteristic 0x2A00, props: [:read], value: "Name"
  #       characteristic 0x2A01, props: [:read], value: [0x80, 0x00]
  #     end
  #     gap 0x0B
  #     primary "0000fe95-0000-1000-8000-00805f9b34fb", end_at: 0x002F do
  #       include_service :battery          # 16-bit: the 6-octet form
  #       include_range 0x0100, 0x0104      # unresolvable 4-octet form
  #       characteristic 0x2A19, props: %i[read notify], value: "\x64" do
  #         descriptor 0x2902, value: "\x00\x00"
  #       end
  #     end
  #     secondary 0x180F, name: :battery
  #   end
  class Builder
    def initialize
      @cursor   = 0x0001
      @services = []
      @names    = {}
      @pending  = []
      @service  = nil
      @char     = nil
    end

    def database
      @pending.each do |include, name|
        target = @names.fetch(name) { raise ArgumentError, "include_service #{name.inspect}: no service has that name" }
        include.start = target.start
        include.end   = target.end
        include.uuid  = target.uuid
      end
      GattDatabase.new(@services)
    end

    def primary(uuid, at: nil, end_at: nil, name: nil, &block)
      service(:primary, uuid, at, end_at, name, &block)
    end

    def secondary(uuid, at: nil, end_at: nil, name: nil, &block)
      service(:secondary, uuid, at, end_at, name, &block)
    end

    def gap(count)
      raise ArgumentError, "gap needs an Integer >= 0, got #{count.inspect}" unless count.is_a?(Integer) && count >= 0
      @cursor += count
    end

    # An include of the service declared (anywhere) with name: +name+.
    def include_service(name, at: nil)
      include = new_include(at)
      @pending << [include, name]
      include
    end

    # An include of an arbitrary range, e.g. one no discovered service starts at.
    def include_range(start_handle, end_handle, uuid: nil, at: nil)
      include = new_include(at)
      include.start = start_handle
      include.end   = end_handle
      include.uuid  = uuid && GattDatabase.uuid(uuid)
      include
    end

    def characteristic(uuid, props: [:read], value: "", read_error: nil, at: nil, &block)
      raise ArgumentError, "characteristic outside a service block" unless @service
      raise ArgumentError, "characteristics do not nest" if @char
      decl = allocate(at)
      char = Characteristic.new(decl_handle: decl, value_handle: allocate(nil), properties: GattDatabase.properties(props),
                                uuid: GattDatabase.uuid(uuid), value: GattDatabase.value(value),
                                read_error: read_error, descriptors: [])
      @service.characteristics << char
      @char = char
      run(block)
      @char = nil
      char
    end

    def descriptor(uuid, value: "", read_error: nil, at: nil)
      raise ArgumentError, "descriptor outside a characteristic block" unless @char
      descriptor = Descriptor.new(handle: allocate(at), uuid: GattDatabase.uuid(uuid),
                                  value: GattDatabase.value(value), read_error: read_error)
      @char.descriptors << descriptor
      descriptor
    end

    def run(block)
      return unless block
      block.arity == 1 ? block.call(self) : instance_eval(&block)
    end

    private

    def service(type, uuid, at, end_at, name, &block)
      raise ArgumentError, "services do not nest" if @service
      service = Service.new(type: type, uuid: GattDatabase.uuid(uuid), start: allocate(at), end: nil,
                            includes: [], characteristics: [])
      @service = service
      run(block)
      @service = nil
      last = @cursor - 1
      service.end = end_at || last
      if service.end < last
        raise ArgumentError, format("end_at 0x%04x is below the service's last handle 0x%04x", service.end, last)
      end
      @cursor = service.end + 1
      @names[name] = service if name
      @services << service
      service
    end

    def new_include(at)
      raise ArgumentError, "include outside a service block" unless @service
      unless @service.characteristics.empty?
        raise ArgumentError, "includes precede a service's characteristics (Core 6.3 Vol 3 Part G 3.2)"
      end
      include = Include.new(handle: allocate(at), start: nil, end: nil, uuid: nil)
      @service.includes << include
      include
    end

    def allocate(at)
      handle = at || @cursor
      if handle < @cursor
        raise ArgumentError, format("handle 0x%04x is below the next free handle 0x%04x", handle, @cursor)
      end
      raise ArgumentError, format("handle 0x%04x is past 0xFFFF", handle) if handle > 0xFFFF
      @cursor = handle + 1
      handle
    end
  end

  # GattDatabase.generate's work: a random database inside the 16-bit handle
  # space, the input of the model-based Properties 1, 2, 15 and 16
  # (Requirements 6.11, 16.10).
  #
  # Under rantly, draw an Integer seed inside property_of and generate from it
  # in the check block. The failing input rantly prints is then the seed, and
  # GattDatabase.generate(seed) rebuilds that very database:
  #
  #   property_of { [range(0, GattDatabase::Generator::SEED_MAX), range(23, 517)] }.check(100) do |seed, mtu|
  #     db = GattDatabase.generate(seed)
  #     ...
  #   end
  #
  # property_of instance_evals its block on a Rantly, so name constants in full
  # there; example lets and helpers are out of reach. Generating inside
  # property_of (`property_of { GattDatabase.generate(range(0, GattDatabase::Generator::SEED_MAX)) }`)
  # also reproduces, since the printed database's inspect starts with the call
  # that made it. Shrinking a seed only finds another failing seed, which
  # reproduces just as well. Every draw comes from the one rng in a fixed
  # order, so an equal seed and keywords give an equal database. An rng other
  # than an Integer must answer rand(), rand(Integer) and rand(Range) as Random
  # does; the database's inspect then cannot name a seed.
  #
  # What a database contains:
  #   services         a count in services: (its bounds drawn more often), each
  #                    primary or, three times in ten, secondary; UUID from
  #                    Nordic's service list (16- or 128-bit), random 16- or
  #                    128-bit, or now and then a Nordic 16-bit one in its
  #                    128-bit Base UUID form
  #   includes         on a quarter of the services, 1 to 3: mostly of another
  #                    service (on air 6 octets when that service's UUID is
  #                    16-bit, 4 octets otherwise), otherwise of a range no
  #                    service starts at (4 octets, so the Walk records uuid
  #                    nil, or 6 octets with a made-up 16-bit UUID). A service
  #                    includes only services ranked below it in a random
  #                    order, so includes never form a cycle
  #   characteristics  a count in chars: per service; UUID from the
  #                    Identity_Set (a third of the time one the database
  #                    already has, so duplicates across services are common),
  #                    Nordic's characteristic list or random; properties a
  #                    random octet with Read set three times in four
  #   descriptors      a count in descriptors: per characteristic, at most one
  #                    0x2904 (7 octets: random Format, Exponent and Unit) and
  #                    one 0x2902, the rest from Nordic's descriptor list or
  #                    random UUIDs
  #   values           lengths in values:, mostly short, sometimes 512, 513,
  #                    a page boundary (22, 246) or the maximum. Identity_Set
  #                    fixed-size values (Appearance 2, System ID 8, PnP ID 7,
  #                    Database Hash 16 octets; Requirement 7.13) the right
  #                    length three times in four; Identity_Set strings ASCII,
  #                    multi-byte UTF-8, NUL-padded, invalid UTF-8 or empty; a
  #                    value under a fixed-size 0x2904 Format often that size.
  #                    values: bounds characteristic values only: a 0x2904 is
  #                    always 7 octets, a 0x2902 2, other descriptors 0 to 20
  #   read_error       on a read_errors fraction of readable values and of
  #                    descriptors, one of read_error_codes. The default codes
  #                    are the Security_Errors, after which a Walk is still
  #                    complete (Requirement 6.8); another code on an
  #                    Identity_Set value makes it partial
  #   handles          ascending from 0x0001 with random gaps between services,
  #                    inside them, and after a service's last attribute (an
  #                    End Group Handle beyond it). end_at_ffff: true ends the
  #                    last service at 0xFFFF, half the time with its last
  #                    attribute there too, and asks for one service even when
  #                    services: allows none; false keeps every handle below
  #                    0xFFFF; :random picks true for a third of the databases
  #                    that have a service
  #   reject_secondary true marks the database as served by a peer that
  #                    answers every 0x2801 Read By Group Type with 0x10
  #                    (GattDatabase#reject_secondary?, which FakeAttPeer
  #                    honours); the secondary services are still generated,
  #                    so expected_discovery leaves them out and resolves no
  #                    4-octet include against them. Default false
  #
  # No characteristic UUID falls in 0x2800..0x29FF and no descriptor UUID in
  # the declarations' 0x2800..0x28FF; 0x2902 and 0x2904 come only from their
  # own branch, at most once per characteristic. No descriptor and only the
  # Identity_Set branch's characteristics carry an Identity_Set UUID, and no
  # random 128-bit UUID lies on the Base UUID. So nothing but the declarations
  # and the intended values answers the Read By Type Requests a Walk sends
  # (0x2802, 0x2803, 0x2B2A).
  #
  # Counts the handle space cannot hold (beyond the defaults, whose maximum is
  # 32 services x (1 + 3 includes + 16 x (2 + 4)) = 3,200 handles) are cut from
  # the end: the last service's characteristics, then its includes, then the
  # service, until the attributes fit. Gaps take only the handles left over.
  class Generator
    SEED_MAX = 2**31 - 1

    # Core 6.3 Vol 3 Part F 3.4.1.1: Insufficient Authentication,
    # Authorization, Encryption Key Size, Encryption.
    SECURITY_ERRORS = [0x05, 0x08, 0x0C, 0x0F].freeze

    DEFAULTS = {
      services: 0..32, chars: 0..16, descriptors: 0..4, values: 0..600, end_at_ffff: :random,
      read_errors: 0.05, read_error_codes: SECURITY_ERRORS, reject_secondary: false
    }.freeze

    # Requirements 7.10, 7.11 and 7.13, restated rather than taken from
    # GattWalker so the generator does not lean on the code it tests.
    IDENTITY_UUIDS   = [0x2A00, 0x2A01, 0x2A23, 0x2A24, 0x2A25, 0x2A26, 0x2A27, 0x2A28, 0x2A29, 0x2A50, 0x2B2A].freeze
    IDENTITY_LENGTHS = { 0x2A01 => 2, 0x2A23 => 8, 0x2A50 => 7, 0x2B2A => 16 }.freeze

    CCCD                = 0x2902
    PRESENTATION_FORMAT = 0x2904

    # Declarations (0x2800..0x2803) and descriptors (0x2900..): kept away from
    # random characteristic and descriptor UUIDs.
    RESERVED = (0x2800..0x29FF).freeze

    # Characteristic Presentation Format Format codes (Bluetooth Assigned
    # Numbers 2.4.1) => octets, nil for the variable-length utf8s, utf16s and
    # struct.
    FORMAT_OCTETS = {
      0x01 => 1, 0x02 => 1, 0x03 => 1, 0x04 => 1, 0x05 => 2, 0x06 => 2, 0x07 => 3, 0x08 => 4, 0x09 => 6,
      0x0A => 8, 0x0B => 16, 0x0C => 1, 0x0D => 2, 0x0E => 2, 0x0F => 3, 0x10 => 4, 0x11 => 6, 0x12 => 8,
      0x13 => 16, 0x14 => 4, 0x15 => 8, 0x16 => 2, 0x17 => 4, 0x18 => 4, 0x19 => nil, 0x1A => nil, 0x1B => nil
    }.freeze

    UTF8_SAMPLES = %w[é ß Ж € 東 京 🙂].map(&:b).freeze
    INVALID_UTF8 = [0xFF, 0xFE, 0xC3, 0x80, 0xED].freeze

    # One page (ATT_MTU - 1) at MTU 23, 247 and 517 and one octet past it, two
    # pages at MTU 23, and the 512-octet Read Blob cut-off and its neighbours.
    SPECIAL_LENGTHS = [0, 1, 22, 23, 44, 246, 247, 511, 512, 513, 516].freeze

    # Gap sizes as [percent, sizes].
    BETWEEN_SERVICES = [[45, 0..0], [30, 1..16], [20, 17..1024], [5, 1025..0x2000]].freeze
    INSIDE_SERVICE   = [[80, 0..0], [17, 1..4], [3, 5..64]].freeze
    AFTER_SERVICE    = [[70, 0..0], [25, 1..8], [5, 9..256]].freeze

    READ = PROPERTIES[:read]

    # Nordic's 16-bit UUIDs (Integers) and 128-bit ones (hex) for +role+,
    # sorted so a seed means the same database whatever the file order,
    # without the UUIDs this generator keeps to dedicated branches.
    def self.nordic(role)
      @nordic ||= {}
      @nordic[role] ||= begin
        file    = File.join(BlueHydra::UuidNames::DATA_DIR, BlueHydra::UuidNames::FILES.fetch(role))
        entries = JSON.parse(File.read(file)).map { |entry| entry.fetch("uuid").delete("-").downcase }.uniq.sort
        short, long = entries.partition { |hex| hex.size == 4 }
        short = short.map { |hex| hex.to_i(16) }
        short.reject! { |n| RESERVED.cover?(n) || IDENTITY_UUIDS.include?(n) } if role == :characteristic
        short.reject! { |n| n < 0x2900 && RESERVED.cover?(n) } if role == :descriptor
        short -= IDENTITY_UUIDS + [CCCD, PRESENTATION_FORMAT] unless role == :service
        long.reject! { |hex| hex.end_with?(BASE_UUID_SUFFIX) }
        { 16 => short.freeze, 128 => long.freeze }.freeze
      end
    end

    def initialize(rng, services:, chars:, descriptors:, values:, end_at_ffff:, read_errors:, read_error_codes:,
                   reject_secondary:)
      @seed = rng if rng.is_a?(Integer)
      @rng  = @seed ? Random.new(@seed) : rng
      raise ArgumentError, "rng must be an Integer seed or answer rand like Random, got #{rng.inspect}" unless @rng.respond_to?(:rand)

      @given = { services: services, chars: chars, descriptors: descriptors, values: values, end_at_ffff: end_at_ffff,
                 read_errors: read_errors, read_error_codes: read_error_codes, reject_secondary: reject_secondary }
      @services    = count_range(:services, services)
      @chars       = count_range(:chars, chars)
      @descriptors = count_range(:descriptors, descriptors)
      @values      = count_range(:values, values)
      unless [true, false, :random].include?(end_at_ffff)
        raise ArgumentError, "end_at_ffff must be true, false or :random, got #{end_at_ffff.inspect}"
      end
      @end_at_ffff = end_at_ffff
      unless read_errors.is_a?(Numeric) && read_errors.between?(0, 1)
        raise ArgumentError, "read_errors must be a fraction in 0..1, got #{read_errors.inspect}"
      end
      @read_errors = read_errors
      unless read_error_codes.is_a?(Array) && read_error_codes.all? { |code| code.is_a?(Integer) && code.between?(0x01, 0xFF) }
        raise ArgumentError, "read_error_codes must be ATT error codes 0x01..0xFF, got #{read_error_codes.inspect}"
      end
      raise ArgumentError, "read_errors above 0 needs read_error_codes" if read_error_codes.empty? && read_errors.positive?
      @read_error_codes = read_error_codes
      unless [true, false].include?(reject_secondary)
        raise ArgumentError, "reject_secondary must be true or false, got #{reject_secondary.inspect}"
      end
      @reject_secondary = reject_secondary
      @identity_used    = []
    end

    def database
      count  = draw_count(@services)
      to_top = @end_at_ffff == :random ? !count.zero? && @rng.rand(3).zero? : @end_at_ffff
      if to_top && count.zero?
        if @services.max.zero?
          raise ArgumentError, "end_at_ffff: true needs a service, but services: #{@given[:services].inspect} allows none"
        end
        count = 1
      end

      services = Array.new(count) { new_service }
      top      = to_top ? 0xFFFF : 0xFFFE
      needed   = fit(services, top)
      targets  = plan_includes(services)
      allocate(services, top - needed)
      reach_top(services.last) if to_top
      link(services, targets)
      GattDatabase.new(services, generated_by: call_text, reject_secondary: @reject_secondary)
    end

    private

    def count_range(name, value)
      range = value.is_a?(Integer) ? value..value : value
      bounded = range.is_a?(Range) && range.begin.is_a?(Integer) && range.end.is_a?(Integer)
      unless bounded && !range.min.nil? && range.min >= 0
        raise ArgumentError, "#{name} must be an Integer >= 0 or a non-empty Range of them, got #{value.inspect}"
      end
      range.min..range.max
    end

    # The call that rebuilds this database: the seed and every keyword not
    # left at its default.
    def call_text
      arguments = [@seed ? @seed.to_s : "<#{@rng.class}>"]
      @given.each { |key, value| arguments << "#{key}: #{value.inspect}" unless DEFAULTS[key] == value }
      "GattDatabase.generate(#{arguments.join(', ')})"
    end

    def pick(list)
      list[@rng.rand(list.size)]
    end

    # A count in +range+, at either bound one time in ten each.
    def draw_count(range)
      case @rng.rand(10)
      when 0 then range.min
      when 1 then range.max
      else @rng.rand(range)
      end
    end

    def new_service
      type     = @rng.rand(10) < 7 ? :primary : :secondary
      uuid     = service_uuid
      includes = @rng.rand(4).zero? ? Array.new(1 + @rng.rand(3)) { Include.new(handle: nil, start: nil, end: nil, uuid: nil) } : []
      chars    = Array.new(draw_count(@chars)) { new_characteristic }
      Service.new(type: type, uuid: uuid, start: nil, end: nil, includes: includes, characteristics: chars)
    end

    def new_characteristic
      uuid        = characteristic_uuid
      readable    = @rng.rand(4) < 3
      properties  = readable ? @rng.rand(256) | READ : @rng.rand(256) & ~READ
      descriptors = new_descriptors(draw_count(@descriptors))
      layout      = descriptors.find { |descriptor| descriptor.uuid == Codec.uuid16(PRESENTATION_FORMAT) }
      value       = characteristic_value(uuid, layout && FORMAT_OCTETS[layout.value.getbyte(0)])
      read_error  = readable ? maybe_read_error : nil
      Characteristic.new(decl_handle: nil, value_handle: nil, properties: properties, uuid: uuid, value: value,
                         read_error: read_error, descriptors: descriptors)
    end

    def new_descriptors(count)
      taken = []
      Array.new(count) do
        roll = @rng.rand(100)
        kind = if roll < 25 then :format
               elsif roll < 45 then :cccd
               elsif roll < 75 then :nordic
               elsif roll < 88 then :random16
               else :random128
               end
        kind = :nordic if %i[format cccd].include?(kind) && taken.include?(kind)
        taken << kind
        uuid, value =
          case kind
          when :format    then [Codec.uuid16(PRESENTATION_FORMAT), presentation_format]
          when :cccd      then [Codec.uuid16(CCCD), [@rng.rand(4), 0].pack("CC")]
          when :nordic    then [@rng.rand(20).zero? ? base_form(pick(self.class.nordic(:descriptor)[16])) : nordic16(:descriptor), short_bytes]
          when :random16  then [Codec.uuid16(random16), short_bytes]
          else                 [random128, short_bytes]
          end
        Descriptor.new(handle: nil, uuid: uuid, value: value, read_error: maybe_read_error)
      end
    end

    # Format, Exponent (sint8), Unit, Name Space, Description (Core 6.3 Vol 3
    # Part G 3.3.3.5): 7 octets.
    def presentation_format
      code        = @rng.rand(100) < 85 ? pick(FORMAT_OCTETS.keys) : @rng.rand(256)
      exponent    = case @rng.rand(10)
                    when 0..4 then 0
                    when 5..8 then @rng.rand(-3..3)
                    else @rng.rand(-128..127)
                    end
      unit        = @rng.rand(10) < 3 ? 0x2700 : 0x2700 + @rng.rand(0x100)
      namespace   = @rng.rand(10).zero? ? @rng.rand(256) : 0x01
      description = @rng.rand(5).zero? ? @rng.rand(0x10000) : 0x0000
      [code, exponent, unit, namespace, description].pack("CcS<CS<")
    end

    def maybe_read_error
      @rng.rand < @read_errors ? pick(@read_error_codes) : nil
    end

    def service_uuid
      roll = @rng.rand(100)
      if roll < 45 then nordic16(:service)
      elsif roll < 50 then base_form(pick(self.class.nordic(:service)[16]))
      elsif roll < 65 then nordic128(:service)
      elsif roll < 80 then Codec.uuid16(random16)
      else random128
      end
    end

    def characteristic_uuid
      roll = @rng.rand(100)
      if roll < 22 then identity_uuid
      elsif roll < 55 then nordic16(:characteristic)
      elsif roll < 58 then base_form(pick(self.class.nordic(:characteristic)[16]))
      elsif roll < 68 then nordic128(:characteristic)
      elsif roll < 80 then Codec.uuid16(random16)
      else random128
      end
    end

    def identity_uuid
      number = !@identity_used.empty? && @rng.rand(3).zero? ? pick(@identity_used) : pick(IDENTITY_UUIDS)
      @identity_used << number unless @identity_used.include?(number)
      Codec.uuid16(number)
    end

    def nordic16(role)
      Codec.uuid16(pick(self.class.nordic(role)[16]))
    end

    def nordic128(role)
      pool = self.class.nordic(role)[128]
      pool.empty? ? random128 : Codec::Uuid.new(bits: 128, hex: pick(pool))
    end

    def base_form(number)
      Codec::Uuid.new(bits: 128, hex: format("0000%04x", number) + BASE_UUID_SUFFIX)
    end

    def random16
      loop do
        number = @rng.rand(0x10000)
        return number unless RESERVED.cover?(number) || IDENTITY_UUIDS.include?(number)
      end
    end

    def random128
      loop do
        hex = format("%032x", @rng.rand(2**128))
        return Codec::Uuid.new(bits: 128, hex: hex) unless hex.end_with?(BASE_UUID_SUFFIX)
      end
    end

    def characteristic_value(uuid, format_octets)
      number = uuid.bits == 16 ? uuid.hex.to_i(16) : nil
      if (fixed = IDENTITY_LENGTHS[number])
        random_bytes(@rng.rand(4) < 3 && @values.cover?(fixed) ? fixed : wrong_length(fixed))
      elsif IDENTITY_UUIDS.include?(number)
        string_value
      elsif format_octets && @rng.rand(5) < 3 && @values.cover?(format_octets)
        random_bytes(format_octets)
      else
        random_bytes(value_length)
      end
    end

    def wrong_length(fixed)
      choices = [fixed - 1, fixed + 1, 0, value_length].uniq.select { |n| n != fixed && @values.cover?(n) }
      choices.empty? ? fixed : pick(choices)
    end

    def value_length
      lo, hi = @values.min, @values.max
      roll = @rng.rand(100)
      if roll < 10
        special = (SPECIAL_LENGTHS + [hi]).select { |n| @values.cover?(n) }
        special.empty? ? lo : pick(special)
      elsif roll < 70 then @rng.rand(lo..[hi, lo + 24].min)
      elsif roll < 90 then @rng.rand(lo..[hi, [lo, 100].max].min)
      else @rng.rand(lo..hi)
      end
    end

    def string_value
      bytes =
        case @rng.rand(6)
        when 0 then Array.new(@rng.rand(0..24)) { 0x20 + @rng.rand(0x5F) }.pack("C*")
        when 1 then Array.new(1 + @rng.rand(12)) { @rng.rand(3).zero? ? pick(UTF8_SAMPLES) : (0x61 + @rng.rand(26)).chr }.join.b
        when 2 then Array.new(@rng.rand(0..24)) { 0x41 + @rng.rand(26) }.pack("C*") + ("\x00".b * (1 + @rng.rand(3)))
        when 3 then Array.new(1 + @rng.rand(16)) { @rng.rand(3).zero? ? pick(INVALID_UTF8) : 0x61 + @rng.rand(26) }.pack("C*")
        when 4 then "\x00".b * @rng.rand(3)
        else random_bytes(value_length)
        end
      bytes = bytes.byteslice(0, @values.max)
      bytes + random_bytes([@values.min - bytes.bytesize, 0].max)
    end

    def short_bytes
      random_bytes(@rng.rand(0..20))
    end

    def random_bytes(count)
      Array.new(count) { @rng.rand(256) }.pack("C*")
    end

    # Cuts counts from the end until the attributes fit at or below +top+;
    # returns the handles the attributes need.
    def fit(services, top)
      needed = services.sum { |service| 1 + service.includes.size + service.characteristics.sum { |char| 2 + char.descriptors.size } }
      while needed > top
        service = services.last
        if (char = service.characteristics.pop)
          needed -= 2 + char.descriptors.size
        elsif service.includes.pop
          needed -= 1
        elsif services.size > 1
          services.pop
          needed -= 1
        else
          break
        end
      end
      needed
    end

    # [[include, index of the included service or nil]]. Service i may include
    # j only when j ranks below i, so includes are acyclic.
    def plan_includes(services)
      ranks = (0...services.size).to_a.shuffle(random: @rng)
      services.each_with_index.flat_map do |service, index|
        candidates = (0...services.size).select { |other| ranks[other] < ranks[index] }
        service.includes.map do |include|
          [include, candidates.empty? || @rng.rand(100) < 15 ? nil : pick(candidates)]
        end
      end
    end

    # Assigns ascending handles with gaps drawn from +slack+, the handles the
    # attributes leave free below the top.
    def allocate(services, slack)
      @slack = slack
      cursor = 0x0001
      services.each do |service|
        cursor += gap(BETWEEN_SERVICES)
        service.start = cursor
        cursor += 1
        service.includes.each do |include|
          cursor += gap(INSIDE_SERVICE)
          include.handle = cursor
          cursor += 1
        end
        service.characteristics.each do |char|
          cursor += gap(INSIDE_SERVICE)
          char.decl_handle  = cursor
          char.value_handle = cursor + 1
          cursor += 2
          char.descriptors.each do |descriptor|
            cursor += gap(INSIDE_SERVICE)
            descriptor.handle = cursor
            cursor += 1
          end
        end
        service.end = cursor - 1 + gap(AFTER_SERVICE)
        cursor = service.end + 1
      end
    end

    def gap(table)
      roll = @rng.rand(100)
      _percent, sizes = table.find { |percent, _sizes| (roll -= percent).negative? }
      size = [@rng.rand(sizes), @slack].min
      @slack -= size
      size
    end

    # Ends +service+ at 0xFFFF, half the time moving its attributes up so the
    # last one is at 0xFFFF too.
    def reach_top(service)
      if @rng.rand(2).zero?
        last  = [service.start, *service.includes.map(&:handle),
                 *service.characteristics.flat_map { |char| [char.value_handle, *char.descriptors.map(&:handle)] }].max
        shift = 0xFFFF - last
        service.start += shift
        service.includes.each { |include| include.handle += shift }
        service.characteristics.each do |char|
          char.decl_handle  += shift
          char.value_handle += shift
          char.descriptors.each { |descriptor| descriptor.handle += shift }
        end
      end
      service.end = 0xFFFF
    end

    # Fills each include with its service's range and UUID, or with a range no
    # service starts at.
    def link(services, targets)
      starts = services.map(&:start)
      targets.each do |include, target|
        if target
          service = services[target]
          include.start = service.start
          include.end   = service.end
          include.uuid  = service.uuid
        else
          include.start = loop do
            handle = 1 + @rng.rand(0xFFFF)
            break handle unless starts.include?(handle)
          end
          include.end  = [include.start + @rng.rand(0..32), 0xFFFF].min
          include.uuid = @rng.rand(10) < 3 ? Codec.uuid16(random16) : nil
        end
      end
    end
  end
end

# The fake Att_Bearer socket and the GATT server behind it. See the comment at
# the top of this file.
class FakeAttPeer
  Codec = BlueHydra::AttCodec

  # A misused harness, or a call the Bearer must never make. Not a
  # SystemCallError, so it gets past GattWalker#run's rescue and fails the
  # example instead of turning into a Walk_Outcome.
  HarnessError = Class.new(StandardError)

  DEFAULT_MTU = 23

  # Requirement 7.7: everything the walker and its Att_Server may send.
  ALLOWED_CLIENT_OPCODES = [0x01, 0x02, 0x03, 0x04, 0x08, 0x0A, 0x0C, 0x10, 0x1E].freeze

  # Requests the codec decodes; a Malformed one is answered Invalid PDU.
  DECODED_REQUESTS = [0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x10].freeze

  NOTIFICATION          = 0x1B
  INDICATION            = 0x1D
  CONFIRMATION          = 0x1E
  MULTIPLE_NOTIFICATION = 0x23 # Multiple Handle Value Notification (Core 5.2); the codec does not decode it

  PAGE_OPCODES = [0x05, 0x09, 0x11].freeze # Find Information, Read By Type, Read By Group Type Responses

  # corrupt_page modes (Requirements 6.5 and 6.6):
  #   :handle_below_start  first entry's handle one below the request's Starting Handle
  #   :handle_above_end    last entry's handle one above the request's Ending
  #                        Handle (not possible for an Ending Handle of 0xFFFF)
  #   :non_increasing      first two entries swapped, or a lone entry repeated
  #   :end_before_start    (Read By Group Type) first entry's End Group Handle
  #                        one below its handle
  #   :non_advancing       the earlier page answering the same request type
  #                        resent unchanged, as a peer that ignores the Starting
  #                        Handle does; needs such an earlier page
  #   :bad_declaration     (Read By Type) one octet added to every value, so a
  #                        declaration is 6/20 or 5/7 octets instead of 5/19 or 4/6
  #   :no_entries          length or format octet with no entries (Malformed)
  #   :bad_length          length or format octet no entry can have (Malformed)
  #   :truncated           last octet dropped: a ragged page, or a short PDU
  #   :wrong_opcode        a response opcode that does not answer the request
  # :truncated and :wrong_opcode work on any response. The others need the
  # answer to be a page (0x05, 0x09 or 0x11), :non_advancing an earlier one;
  # anything else is a HarnessError when the response is read.
  CORRUPT_MODES = %i[handle_below_start handle_above_end non_increasing end_before_start non_advancing
                     bad_declaration no_entries bad_length truncated wrong_opcode].freeze

  WRONG_OPCODE = { 0x01 => 0x0B, 0x03 => 0x0B, 0x05 => 0x09, 0x09 => 0x11, 0x0B => 0x0D, 0x0D => 0x0B, 0x11 => 0x09 }.freeze
  BAD_LENGTH   = { 0x05 => 0x03, 0x09 => 0x01, 0x11 => 0x07 }.freeze

  # A PDU the walker sent: index into its log, raw bytes, AttCodec.decode of
  # them, first octet, fake-clock time, and lost (sent after the Link had
  # already dropped, so it never reached the peer and got no response).
  Received = Struct.new(:index, :raw, :pdu, :opcode, :at, :lost)
  # A PDU the walker read: :response (to request_index) or :peer (injected).
  Delivered = Struct.new(:kind, :raw, :at, :request_index)
  # A scripted peer-initiated PDU and what became of it; reply is the walker's
  # Received reply, nil when none was sent or none is due.
  Injection = Struct.new(:raw, :pdu, :before_request, :queued_at, :delivered_at, :reply)
  Call = Struct.new(:name, :args, :at)
  Wait = Struct.new(:kind, :timeout, :at)
  Outbound = Struct.new(:kind, :request, :injection, :ready_at)
  private_constant :Outbound

  attr_reader :database, :clock, :server_rx_mtu,
              # client requests, in order (Received)
              :requests,
              # the walker's replies to injected PDUs (Received)
              :peer_received,
              # every PDU the walker sent, both kinds, in order (Received)
              :received,
              # every PDU the walker read, in order (Delivered)
              :delivered,
              # every inject_peer_pdu, in scripting order (Injection)
              :injections,
              # socket calls in order (Call): :open, :bind, :connect_nonblock,
              # :getsockopt, :setsockopt, :send, :close
              :calls,
              # every wait_readable / wait_writable (Wait), timeout as passed
              :waits,
              # ATT rules the client broke (Strings); empty for a correct walker
              :violations,
              :open_count

  # +server_rx_mtu+ is the Server Rx MTU answered to an Exchange MTU Request;
  # any 0..65535 is accepted, the ATT_MTU never goes below 23.
  # +attribute_not_long+: see GattDatabase#read_blob.
  def initialize(database = GattDatabase.empty, clock: FakeClock.new, server_rx_mtu: 517, attribute_not_long: true)
    unless server_rx_mtu.is_a?(Integer) && server_rx_mtu.between?(0, 0xFFFF)
      raise ArgumentError, "server_rx_mtu must be an Integer in 0..65535, got #{server_rx_mtu.inspect}"
    end
    @database           = database
    @clock              = clock
    @server_rx_mtu      = server_rx_mtu
    @attribute_not_long = attribute_not_long
    @monitor            = Monitor.new

    @requests      = []
    @peer_received = []
    @received      = []
    @delivered     = []
    @injections    = []
    @calls         = []
    @waits         = []
    @violations    = []
    @open_count    = 0

    @state         = :unconnected
    @closed        = false
    @connect       = { outcome: :immediate, after: 0.0, so_error: 0 }
    @connect_ready_at = nil
    @so_error      = 0
    @bind_error    = nil
    @bound         = nil
    @connected_to  = nil

    @outbound            = []
    @responses_delivered = 0
    @exchanges           = []
    @awaiting_reply      = []
    @pages               = {}

    @drop_after          = nil
    @recv_error          = nil
    @recv_error_after    = 0
    @recv_error_raised   = false
    @dead                = false
    @dead_observed       = false

    @delays              = {}
    @injections_at       = {}
    @error_answers       = {}
    @raw_answers         = {}
    @corruptions         = {}
    @security_first_primary = nil
    @first_primary_index = nil
    @reject_secondary    = false
    reject_secondary_services! if database.reject_secondary?
  end

  # The ATT_MTU the server pages at: 23 until an Exchange MTU completes, then
  # the smallest floor-23 result of every exchange in either direction, as the
  # walker computes it (Requirements 5.7, 8.9).
  def att_mtu
    sync { @exchanges.min || DEFAULT_MTU }
  end

  # == Walker installation

  # Replaces +walker+'s open_socket seam so it opens this fake. Returns walker.
  def install(walker)
    peer = self
    walker.define_singleton_method(:open_socket) { peer.open! }
    walker
  end

  # A GattWalker on this peer's clock with this peer installed. Defaults: a
  # private address, Plan.full, Walk_Bound 10 s from now, read_all true, the
  # Link up since now, never stopping. Any keyword overrides its default.
  def build_walker(**overrides)
    require 'blue_hydra/gatt_walker'
    clock = @clock
    arguments = {
      address: "7A:BB:CC:DD:EE:FF", address_type: BlueHydra::Mgmt::LE_RANDOM, hci_index: 0,
      local_address: "00:11:22:33:44:55", plan: BlueHydra::GattWalker::Plan.full,
      deadline: clock.now + 10.0, read_all: true,
      link_up: ->(_address) { clock.now }, stopping: -> { false }, on_peer_request: -> {},
      clock: clock
    }.merge(overrides)
    install(BlueHydra::GattWalker.new(**arguments))
  end

  # What the installed open_socket returns.
  def open!
    sync do
      @open_count += 1
      record_call(:open, [])
      self
    end
  end

  # struct sockaddr_l2 as Bearer#sockaddr packs it, unpacked for assertions.
  def self.parse_sockaddr(bytes)
    family, psm, address, cid, type = bytes.unpack("S!S!a6S!C")
    { family: family, psm: psm, address: address.bytes.reverse.map { |b| format("%02X", b) }.join(":"),
      cid: cid, address_type: type }
  end

  def bound_sockaddr
    @bound && self.class.parse_sockaddr(@bound)
  end

  def connected_sockaddr
    @connected_to && self.class.parse_sockaddr(@connected_to)
  end

  # == Scripting hooks. Each returns self.

  # How connect_nonblock resolves:
  #   :immediate (default)  returns 0, as on a Link already BT_CONNECTED
  #   :pending              raises IO::EINPROGRESSWaitWritable; the socket turns
  #                         writable +after+ seconds later on the fake clock, and
  #                         SO_ERROR then reads +so_error+ (0 is connected)
  #   :never                raises IO::EINPROGRESSWaitWritable and never turns
  #                         writable, so every wait_writable runs its full timeout
  #   an errno              (Errno class, SystemCallError or Integer) raised by
  #                         connect_nonblock itself; Errno::EBUSY is an ATT
  #                         channel already on the Link
  def connect_outcome(outcome, after: 0.0, so_error: 0)
    unless %i[immediate pending never].include?(outcome) || errno_spec?(outcome)
      raise ArgumentError, "connect outcome must be :immediate, :pending, :never or an errno, got #{outcome.inspect}"
    end
    raise ArgumentError, "after must be finite seconds >= 0" unless after.is_a?(Numeric) && after >= 0 && after.finite?
    sync { @connect = { outcome: outcome, after: after, so_error: errno_number(so_error) } }
    self
  end

  # bind raises +errno+.
  def bind_raises(errno)
    raise ArgumentError, "not an errno: #{errno.inspect}" unless errno_spec?(errno)
    sync { @bind_error = errno }
    self
  end

  # The Link drops once +count+ responses have been read: from then on recv
  # finds EOF (recv_nonblock nil, recv ""), requests are lost and get no
  # response, and once the walker has seen the EOF send fails with ENOTCONN.
  def drop_link_after(count)
    check_index(count, "drop_link_after")
    sync { @drop_after = count }
    self
  end

  # Once +after+ responses have been read, the socket turns readable and the
  # next recv raises +errno+ (as the kernel reports sk_err once); the Link is
  # gone after that, as with drop_link_after.
  def raise_on_recv(errno, after: 0)
    raise ArgumentError, "not an errno: #{errno.inspect}" unless errno_spec?(errno)
    check_index(after, "raise_on_recv after:")
    sync do
      @recv_error       = errno
      @recv_error_after = after
    end
    self
  end

  # The response to request +index+ becomes readable +seconds+ after the
  # request arrives (Float::INFINITY: never). A delay past the walker's wait
  # makes that wait expire with the clock moved by its whole timeout.
  def delay_response(index, seconds)
    check_index(index, "delay_response")
    raise ArgumentError, "delay must be seconds >= 0, got #{seconds.inspect}" unless seconds.is_a?(Numeric) && seconds >= 0
    sync { @delays[index] = seconds }
    self
  end

  # +bytes+ (a String, sent verbatim and so possibly malformed, or an AttCodec
  # PDU) arrives from the peer once request +before_request+ has, ahead of that
  # request's response: a peer request, indication, notification or command
  # interleaved with an outstanding client request. A request or indication
  # among them expects the walker's reply, recorded in peer_received and in
  # the Injection. An Exchange MTU Request answered with an Exchange MTU
  # Response caps att_mtu like any exchange.
  def inject_peer_pdu(bytes, before_request:)
    check_index(before_request, "inject_peer_pdu before_request:")
    raw = bytes.is_a?(String) ? bytes.b : Codec.encode(bytes)
    sync do
      injection = Injection.new(raw: raw, pdu: Codec.decode(raw), before_request: before_request)
      @injections << injection
      (@injections_at[before_request] ||= []) << injection
    end
    self
  end

  # Request +index+ is answered with Error Response +code+ naming the request's
  # opcode and its Starting Handle or Attribute Handle (0x0000 for one with
  # neither), or +handle+.
  def answer_with_error(index, code, handle: nil)
    check_index(index, "answer_with_error")
    raise ArgumentError, "error code must be 0x00..0xFF" unless code.is_a?(Integer) && code.between?(0, 0xFF)
    sync { @error_answers[index] = [code, handle] }
    self
  end

  # Request +index+ is answered with +bytes+ verbatim (or an AttCodec PDU).
  def answer_with(index, bytes)
    check_index(index, "answer_with")
    raw = bytes.is_a?(String) ? bytes.b : Codec.encode(bytes)
    sync { @raw_answers[index] = raw }
    self
  end

  # The response to request +index+ is corrupted per +mode+ (CORRUPT_MODES).
  def corrupt_page(index, mode)
    check_index(index, "corrupt_page")
    raise ArgumentError, "unknown corrupt_page mode #{mode.inspect}" unless CORRUPT_MODES.include?(mode)
    sync { @corruptions[index] = mode }
    self
  end

  # The first Read By Group Type Request for 0x2800, whatever its index, is
  # answered with Error Response +code+ (a Security_Error, Requirement 6.7).
  def security_error_on_first_primary(code = 0x05)
    raise ArgumentError, "error code must be 0x00..0xFF" unless code.is_a?(Integer) && code.between?(0, 0xFF)
    sync { @security_first_primary = code }
    self
  end

  # Every Read By Group Type Request for 0x2801, whatever its index, is
  # answered with Error Response 0x10 Unsupported Group Type carrying its
  # Starting Handle, as Android's GATT server answers any group type other
  # than Primary Service (gatt_sr.cc, gatts_process_primary_service_req;
  # Requirement 6.4). On by construction for a database whose
  # reject_secondary? is set, which is how GattDatabase.generate's
  # reject_secondary: reaches the peer. answer_with_error(index, 0x10) does
  # the same for one request when its index is known.
  def reject_secondary_services!
    sync { @reject_secondary = true }
    self
  end

  # == The socket surface GattWalker::Bearer uses

  def bind(sockaddr)
    sync do
      ensure_open!
      record_call(:bind, [sockaddr])
      raise build_error(@bind_error) if @bind_error
      @bound = sockaddr.b
      0
    end
  end

  def connect_nonblock(sockaddr, exception: true)
    sync do
      ensure_open!
      record_call(:connect_nonblock, [sockaddr])
      unless @state == :unconnected
        # A second connect never reaches the kernel's address checks: a
        # torn-down channel is SOCK_ZAPPED and answers EINVAL, a live one
        # EISCONN or EALREADY.
        @violations << "connect_nonblock called again (state #{@state}); the result is read from SO_ERROR"
        raise({ connected: Errno::EISCONN, connecting: Errno::EALREADY }.fetch(@state, Errno::EINVAL).new)
      end
      @connected_to = sockaddr.b
      case @connect[:outcome]
      when :immediate
        @state = :connected
        0
      when :pending, :never
        @state = :connecting
        @connect_ready_at = @connect[:outcome] == :never ? Float::INFINITY : @clock.now + @connect[:after]
        raise IO::EINPROGRESSWaitWritable, "connect(2) would block" if exception
        :wait_writable
      else
        @state = :failed
        raise build_error(@connect[:outcome])
      end
    end
  end

  def getsockopt(level, optname)
    sync do
      ensure_open!
      record_call(:getsockopt, [level, optname])
      unless level == Socket::SOL_SOCKET && optname == Socket::SO_ERROR
        raise HarnessError, "getsockopt(#{level}, #{optname}): the Bearer reads only SOL_SOCKET/SO_ERROR"
      end
      @violations << "SO_ERROR read while the connect was still pending" if @state == :connecting
      errno = @so_error
      @so_error = 0 # reading SO_ERROR clears it
      Socket::Option.int(:UNSPEC, :SOCKET, :ERROR, errno)
    end
  end

  # Requirements 5.2 and 5.11: no socket option, BT_SECURITY above all, is ever
  # set on the Att_Bearer.
  def setsockopt(*args)
    sync do
      record_call(:setsockopt, args)
      @violations << "setsockopt#{args.inspect}"
    end
    raise HarnessError, "setsockopt#{args.inspect}: the Att_Bearer sets no socket option (Requirements 5.2, 5.11)"
  end

  def send(bytes, flags = 0, *_destination)
    sync do
      ensure_open!
      record_call(:send, [bytes, flags])
      raise Errno::ENOTCONN unless @state == :connected
      raise Errno::ENOTCONN if @dead_observed

      raw    = bytes.b
      opcode = raw.getbyte(0)
      if opcode && (Codec.response_opcode?(opcode) || opcode == CONFIRMATION)
        peer_reply(raw, opcode)
      else
        client_request(raw, opcode)
      end
      raw.bytesize
    end
  end

  # One PDU, :wait_readable when none is ready (or IO::EAGAINWaitReadable with
  # exception: true), nil at EOF; raises the raise_on_recv errno when due.
  def recv_nonblock(maxlen, _flags = 0, _buffer = nil, exception: true)
    sync do
      ensure_open!
      if ready_head
        deliver(maxlen)
      elsif recv_error_due?
        @recv_error_raised = true
        mark_dead
        raise build_error(@recv_error)
      elsif link_down?
        mark_dead
        nil
      elsif exception
        raise IO::EAGAINWaitReadable, "recvfrom(2) would block"
      else
        :wait_readable
      end
    end
  end

  # A blocking recv: "" at EOF. On the fake clock it jumps to the next delayed
  # PDU; with nothing that will ever arrive it raises HarnessError rather than
  # block for ever.
  def recv(maxlen, flags = 0)
    sync do
      unless wait_readable(nil)
        raise HarnessError, "recv would block for ever: nothing is queued or scripted to arrive"
      end
      recv_nonblock(maxlen, flags, exception: false) || ""
    end
  end

  # Truthy (self) once a PDU, EOF or a scripted recv error is ready, moving the
  # clock to that moment; otherwise moves the clock by +timeout+ and returns
  # nil. A timeout at or below 0 only polls; nil waits for ever (HarnessError
  # if nothing will ever be ready). Raises IOError once closed, as IO#wait_* do.
  def wait_readable(timeout = nil)
    sync do
      ensure_open!
      @waits << Wait.new(kind: :readable, timeout: timeout, at: @clock.now)
      next self if readable_now?
      wait_until(@outbound.first&.ready_at, timeout) ? self : nil
    end
  end

  # Truthy (self) once the connect has resolved, moving the clock to when it
  # did; for a :never or still-pending connect moves the clock by +timeout+ and
  # returns nil. Raises IOError once closed.
  def wait_writable(timeout = nil)
    sync do
      ensure_open!
      @waits << Wait.new(kind: :writable, timeout: timeout, at: @clock.now)
      next self unless @state == :connecting
      next nil unless wait_until(@connect_ready_at, timeout)
      @so_error = @connect[:so_error]
      @state    = @so_error.zero? ? :connected : :failed
      self
    end
  end

  def close
    sync do
      next nil if @closed
      record_call(:close, [])
      @closed = true
      nil
    end
  end

  def closed?
    sync { @closed }
  end

  private

  def sync(&block)
    @monitor.synchronize(&block)
  end

  def ensure_open!
    raise IOError, "closed stream" if @closed
  end

  def record_call(name, args)
    @calls << Call.new(name: name, args: args, at: @clock.now)
  end

  def check_index(value, what)
    raise ArgumentError, "#{what} needs an Integer >= 0, got #{value.inspect}" unless value.is_a?(Integer) && value >= 0
  end

  def errno_spec?(value)
    value.is_a?(Integer) || value.is_a?(SystemCallError) || (value.is_a?(Class) && value < SystemCallError)
  end

  def errno_number(value)
    case value
    when Integer then value
    when SystemCallError then value.errno
    when Class then value::Errno
    else raise ArgumentError, "not an errno: #{value.inspect}"
    end
  end

  def build_error(spec)
    case spec
    when Integer then SystemCallError.new(nil, spec)
    when SystemCallError then spec
    else spec.new
    end
  end

  # Moves the clock to +ready_at+ when it falls within +timeout+ and returns
  # true; otherwise moves it by the whole timeout and returns false.
  def wait_until(ready_at, timeout)
    now = @clock.now
    if ready_at&.finite? && (timeout.nil? || ready_at <= now + [timeout, 0].max)
      @clock.advance_to(ready_at)
      return true
    end
    raise HarnessError, "a wait with no timeout would block for ever: nothing is scheduled" if timeout.nil?
    @clock.advance(timeout) if timeout.positive?
    false
  end

  def ready_head
    head = @outbound.first
    head if head && head.ready_at <= @clock.now
  end

  def readable_now?
    return true if ready_head
    @outbound.empty? && link_down?
  end

  def drop_due?
    !@drop_after.nil? && @responses_delivered >= @drop_after
  end

  def recv_error_due?
    !@recv_error.nil? && !@recv_error_raised && @responses_delivered >= @recv_error_after
  end

  def link_down?
    @dead || drop_due? || recv_error_due?
  end

  def mark_dead
    @dead          = true
    @dead_observed = true
  end

  def client_request(raw, opcode)
    request = Received.new(index: @requests.size, raw: raw, pdu: Codec.decode(raw), opcode: opcode,
                           at: @clock.now, lost: link_down?)
    @requests << request
    @received << request
    check_client_rules(request)
    return if request.lost

    if @security_first_primary && @first_primary_index.nil? && primary_request?(request.pdu)
      @first_primary_index = request.index
    end
    @injections_at.fetch(request.index, []).each do |injection|
      injection.queued_at = @clock.now
      @outbound << Outbound.new(kind: :peer, injection: injection, ready_at: @clock.now)
    end
    # A command (Command Flag set) is never answered (Core 6.3 Vol 3 Part F
    # 3.3), and an empty PDU has no opcode an Error Response could name.
    return if opcode.nil? || Codec.command?(opcode)
    @outbound << Outbound.new(kind: :response, request: request, ready_at: @clock.now + @delays.fetch(request.index, 0))
  end

  def check_client_rules(request)
    unless ALLOWED_CLIENT_OPCODES.include?(request.opcode)
      @violations << format("request %d: opcode %s is outside the Requirement 7.7 allowlist",
                            request.index, request.opcode ? format("0x%02x", request.opcode) : "(empty)")
    end
    pending = @outbound.find { |item| item.kind == :response }
    if pending
      # Core 6.3 Vol 3 Part F 3.3.2: one outstanding request per client, and
      # none at all after a transaction has timed out.
      @violations << "request #{request.index} sent before the response to request #{pending.request.index} was read"
    end
    if request.pdu.is_a?(Codec::ExchangeMtuRequest) &&
       @requests[0...-1].any? { |earlier| earlier.pdu.is_a?(Codec::ExchangeMtuRequest) }
      @violations << "request #{request.index}: a second Exchange MTU Request on one bearer"
    end
  end

  def primary_request?(pdu)
    pdu.is_a?(Codec::ReadByGroupTypeRequest) && GattDatabase.same_uuid?(pdu.uuid, GattDatabase::PRIMARY_SERVICE)
  end

  def secondary_request?(pdu)
    pdu.is_a?(Codec::ReadByGroupTypeRequest) && GattDatabase.same_uuid?(pdu.uuid, GattDatabase::SECONDARY_SERVICE)
  end

  # The walker's reply to an injected PDU: a Confirmation answers the oldest
  # unanswered indication, anything else the oldest unanswered request.
  def peer_reply(raw, opcode)
    reply = Received.new(index: @peer_received.size, raw: raw, pdu: Codec.decode(raw), opcode: opcode, at: @clock.now,
                         lost: link_down?)
    @peer_received << reply
    @received << reply
    wanted  = opcode == CONFIRMATION ? :indication : :request
    pending = @awaiting_reply.index { |kind, _injection| kind == wanted }
    unless pending
      @violations << format("unsolicited reply 0x%02x: no injected %s awaits one", opcode, wanted)
      return
    end
    _kind, injection = @awaiting_reply.delete_at(pending)
    injection.reply = reply
    if injection.pdu.is_a?(Codec::ExchangeMtuRequest) && reply.pdu.is_a?(Codec::ExchangeMtuResponse)
      @exchanges << [DEFAULT_MTU, [injection.pdu.mtu, reply.pdu.mtu].min].max
    end
  end

  # Responses are built when read rather than when the request arrives, so a
  # page honours an MTU an exchange settled in between (an injected Exchange
  # MTU Request queued ahead of it).
  def deliver(maxlen)
    item = @outbound.shift
    if item.kind == :peer
      raw = item.injection.raw
      item.injection.delivered_at = @clock.now
      kind = reply_due(raw.getbyte(0))
      @awaiting_reply << [kind, item.injection] if kind
    else
      raw = response_for(item.request)
      @responses_delivered += 1
    end
    @delivered << Delivered.new(kind: item.kind, raw: raw, at: @clock.now, request_index: item.request&.index)
    # SOCK_SEQPACKET: a datagram longer than the buffer is cut, the rest lost.
    raw.bytesize > maxlen ? raw.byteslice(0, maxlen) : raw
  end

  # Which reply an injected PDU is owed, mirroring the Att_Server's rules
  # (Requirement 8): none for a command, notification (0x1B or 0x23),
  # confirmation or response; a Confirmation for an indication; an answer for
  # anything else. 0x23 is listed by opcode because the codec does not decode
  # it and it carries neither the command flag nor a response opcode: filed as
  # owed a :request reply, it would sit in @awaiting_reply and absorb the
  # walker's next Error Response to some later injected request, crediting
  # that reply to the wrong Injection.
  def reply_due(opcode)
    return nil if opcode.nil? || Codec.command?(opcode) || Codec.response_opcode?(opcode)
    return nil if [NOTIFICATION, MULTIPLE_NOTIFICATION, CONFIRMATION].include?(opcode)
    opcode == INDICATION ? :indication : :request
  end

  def response_for(request)
    raw = @raw_answers.fetch(request.index) { scripted_response(request) }
    if request.pdu.is_a?(Codec::ExchangeMtuRequest)
      answer = Codec.decode(raw)
      @exchanges << [DEFAULT_MTU, [request.pdu.mtu, answer.mtu].min].max if answer.is_a?(Codec::ExchangeMtuResponse)
    end
    raw
  end

  # The answer a compliant server gives, or the one a hook scripted, encoded
  # and then corrupted when corrupt_page asks.
  def scripted_response(request)
    pdu =
      if @error_answers.key?(request.index)
        code, handle = @error_answers[request.index]
        error_for(request, code, handle)
      elsif request.index == @first_primary_index
        error_for(request, @security_first_primary, nil)
      elsif @reject_secondary && secondary_request?(request.pdu)
        error_for(request, GattDatabase::UNSUPPORTED_GROUP_TYPE, nil)
      else
        serve(request)
      end
    raw  = Codec.encode(pdu)
    mode = @corruptions[request.index]
    return corrupt(raw, pdu, request, mode) if mode

    key = page_key(request.pdu)
    @pages[key] = raw if key && PAGE_OPCODES.include?(raw.getbyte(0))
    raw
  end

  def serve(request)
    pdu = request.pdu
    mtu = att_mtu
    case pdu
    when Codec::ExchangeMtuRequest     then Codec::ExchangeMtuResponse.new(mtu: @server_rx_mtu)
    when Codec::ReadByGroupTypeRequest then @database.read_by_group_type(pdu, mtu)
    when Codec::ReadByTypeRequest      then @database.read_by_type(pdu, mtu)
    when Codec::FindInformationRequest then @database.find_information(pdu, mtu)
    when Codec::ReadRequest            then @database.read(pdu, mtu)
    when Codec::ReadBlobRequest        then @database.read_blob(pdu, mtu, attribute_not_long: @attribute_not_long)
    when Codec::Malformed
      code = DECODED_REQUESTS.include?(request.opcode) ? GattDatabase::INVALID_PDU : GattDatabase::REQUEST_NOT_SUPPORTED
      error_for(request, code, 0x0000)
    else
      # Find By Type Value and anything else decodable but not served here.
      error_for(request, GattDatabase::REQUEST_NOT_SUPPORTED, 0x0000)
    end
  end

  def error_for(request, code, handle)
    handle ||= request_handle(request.pdu)
    Codec::ErrorResponse.new(request_opcode: request.opcode || 0x00, handle: handle, error_code: code)
  end

  def request_handle(pdu)
    if pdu.respond_to?(:start_handle) then pdu.start_handle
    elsif pdu.respond_to?(:handle) then pdu.handle
    else 0x0000
    end
  end

  def page_key(pdu)
    case pdu
    when Codec::ReadByGroupTypeRequest, Codec::ReadByTypeRequest
      [Codec.opcode_of(pdu), GattDatabase.uuid128(pdu.uuid)]
    when Codec::FindInformationRequest
      [Codec.opcode_of(pdu)]
    end
  end

  def corrupt(raw, pdu, request, mode)
    case mode
    when :truncated
      return raw.byteslice(0, raw.bytesize - 1)
    when :wrong_opcode
      return [WRONG_OPCODE.fetch(raw.getbyte(0))].pack("C") + raw.byteslice(1..)
    when :non_advancing
      return @pages.fetch(page_key(request.pdu)) do
        raise HarnessError, "corrupt_page(#{request.index}, :non_advancing): no earlier page of this request type to resend"
      end
    end

    unless PAGE_OPCODES.include?(raw.getbyte(0))
      raise HarnessError, "corrupt_page(#{request.index}, #{mode.inspect}) needs a page, but the answer is #{pdu.inspect}"
    end
    entries = pdu.entries.map(&:dup)
    case mode
    when :no_entries then raw.byteslice(0, 2)
    when :bad_length then raw.byteslice(0, 1) + [BAD_LENGTH.fetch(raw.getbyte(0))].pack("C") + raw.byteslice(2..)
    when :handle_below_start
      entries.first[0] = [request.pdu.start_handle - 1, 0].max
      Codec.encode(pdu.with(entries: entries))
    when :handle_above_end
      if request.pdu.end_handle >= 0xFFFF
        raise HarnessError, "corrupt_page(#{request.index}, :handle_above_end): nothing is above an Ending Handle of 0xFFFF"
      end
      entries.last[0] = request.pdu.end_handle + 1
      Codec.encode(pdu.with(entries: entries))
    when :non_increasing
      if entries.size >= 2
        entries[0], entries[1] = entries[1], entries[0]
      else
        entries << entries.first.dup
      end
      Codec.encode(pdu.with(entries: entries))
    when :end_before_start
      unless pdu.is_a?(Codec::ReadByGroupTypeResponse)
        raise HarnessError, "corrupt_page(#{request.index}, :end_before_start) needs a Read By Group Type page"
      end
      entries.first[1] = entries.first[0] - 1
      Codec.encode(pdu.with(entries: entries))
    when :bad_declaration
      unless pdu.is_a?(Codec::ReadByTypeResponse)
        raise HarnessError, "corrupt_page(#{request.index}, :bad_declaration) needs a Read By Type page"
      end
      Codec.encode(pdu.with(length: pdu.length + 1, entries: entries.map { |handle, value| [handle, value + "\x00".b] }))
    end
  end
end
