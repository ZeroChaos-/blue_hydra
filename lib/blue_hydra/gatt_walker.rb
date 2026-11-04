require 'socket'
require 'io/wait'
require 'thread'
# For Mgmt's constants only. Requiring it defines the class and nothing else:
# no socket, thread or file is opened until a Mgmt is constructed.
require 'blue_hydra/mgmt'
# For LeConnect::UNREACHABLE_ERRORS only; likewise defines a class and nothing
# else.
require 'blue_hydra/le_connect'
require 'blue_hydra/att_codec'
require 'blue_hydra/att_server'
require 'blue_hydra/value_decoder'
require 'blue_hydra/uuid_names'

module BlueHydra
  # The ATT client for one Walk: one Att_Bearer on a Link a connect path has
  # already raised, a read-only pass over the peer's GATT database, then value
  # reads. The Gatt_Scanner builds one per Walk and runs it on that Walk's own
  # thread.
  #
  # The Walk is a worklist over a WalkState. Discovery procedures run a page at
  # a time off the head of state.procedures, then reads off the head of
  # state.reads, and an item leaves its list only once it has finished. A Walk
  # cut short by Walk_Bound or a Link drop therefore leaves exactly its
  # outstanding work in the state, and resuming (Plan.resume) is continuing
  # that worklist on a new bearer.
  #
  # Everything a Walk reports comes from PDUs on its own bearer, plus, for a
  # resumed Walk, the Resume_State it continues, which the earlier Walks of
  # that address built from PDUs on theirs. It reads nothing from btmon, the
  # pipeline queues or another Walk's bearer, and pushes nothing onto any
  # queue: the Gatt_Scanner delivers the WalkReport.
  #
  # The callables are injected so a spec needs neither a Mgmt nor a
  # GattScanner:
  #   link_up.(address)  -> monotonic time the Link came up, or nil when it is down
  #   stopping.()        -> true once Runner shutdown has begun
  #   on_peer_request.() -> called once per Att_Server reply sent
  #
  # THREADING: run and everything under it execute on the Walk thread. The
  # Gatt_Scanner's shutdown may call close_bearer from another thread while the
  # Walk is blocked on the socket, so the bearer reference is guarded by
  # @bearer_mutex. Nothing else is shared.
  class GattWalker
    # Any object with #now returning Float seconds. Monotonic so that neither
    # Walk_Bound nor the transaction timeout moves with the wall clock; specs
    # inject a fake one.
    module MonotonicClock
      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
    MONOTONIC = MonotonicClock

    # A fixed channel on a Link that is already up is marked connected inside
    # the connect call itself (net/bluetooth/l2cap_core.c, l2cap_chan_connect:
    # hcon->state == BT_CONNECTED and a non-connection-oriented channel go
    # straight to l2cap_state_change(chan, BT_CONNECTED)). A connect still
    # pending after this long is waiting on a Link that is not up.
    CONNECT_TIMEOUT = 1.0

    # ATT transaction timeout (Core 6.3 Vol 3 Part F 3.3.3): a request with no
    # response after 30 s has failed, and nothing more may be sent on that
    # bearer.
    ATT_TRANSACTION_TIMEOUT = 30.0

    # Longest attribute value (Core 6.3 Vol 3 Part F 3.2.9; BlueZ
    # BT_ATT_MAX_VALUE_LEN, src/shared/att-types.h). A Read Blob sequence stops
    # here and any excess is discarded.
    MAX_VALUE_BYTES = 512

    # The Client Rx MTU offered in our one Exchange MTU Request, BlueZ's own
    # maximum (BT_ATT_MAX_LE_MTU, src/shared/att-types.h) and the Att_Codec's
    # MAX_PDU. At 517 a single Read Response (opcode plus ATT_MTU - 1 octets)
    # holds a whole MAX_VALUE_BYTES value.
    CLIENT_RX_MTU = 517

    # LE ATT_MTU before or without an Exchange MTU (Core 6.3 Vol 3 Part G
    # 5.2.1; BlueZ BT_ATT_DEFAULT_LE_MTU), and the floor for a negotiated one.
    DEFAULT_MTU = 23

    # Identity_Set characteristic UUID => the key its value is reported under.
    # Insertion order is read order: identity reads are queued in this order
    # ahead of every other read, so a Walk cut off after discovery still has
    # the identity values.
    IDENTITY_SET = {
      0x2A00 => :device_name,
      0x2A01 => :appearance,
      0x2A29 => :manufacturer_name,
      0x2A24 => :model_number,
      0x2A25 => :serial_number,
      0x2A26 => :firmware_revision,
      0x2A27 => :hardware_revision,
      0x2A28 => :software_revision,
      0x2A23 => :system_id,
      0x2A50 => :pnp_id,
      0x2B2A => :database_hash
    }.freeze

    # Database Hash (Core 6.3 Vol 3 Part G 7.3), the one characteristic the
    # hash check reads by type. Taken from IDENTITY_SET so that the Read By
    # Type Request it names is one Requirement 7.2 allows (0x2802, 0x2803 or
    # an Identity_Set UUID): dropping it from the set fails here at load.
    DATABASE_HASH      = IDENTITY_SET.key(:database_hash)
    DATABASE_HASH_TYPE = AttCodec.uuid16(DATABASE_HASH)

    # Security_Error codes (Core 6.3 Vol 3 Part F 3.4.1.1): 0x05 Insufficient
    # Authentication, 0x08 Insufficient Authorization, 0x0C Insufficient
    # Encryption Key Size, 0x0F Insufficient Encryption. The bearer stays at the
    # kernel's default BT_SECURITY_LOW and the Walk never pairs (Requirement
    # 5.2), so an attribute answered with one is recorded protected and never
    # retried.
    SECURITY_ERRORS = [0x05, 0x08, 0x0C, 0x0F].freeze

    # Errnos meaning the Link went away under the bearer. A Link drop reaches
    # the socket as sk_err = bt_to_errno(disconnect reason)
    # (net/bluetooth/l2cap_core.c, l2cap_disconn_cfm -> l2cap_conn_del;
    # net/bluetooth/l2cap_sock.c, l2cap_sock_teardown_cb; net/bluetooth/lib.c,
    # bt_to_errno): 0x08 Connection Timeout -> ETIMEDOUT, 0x13..0x15 remote
    # termination -> ECONNRESET, 0x16 local termination -> ECONNABORTED,
    # 0x04/0x3C -> EHOSTDOWN. sk_err is reported once; after that the channel
    # is BT_CLOSED and l2cap_sock_sendmsg answers ENOTCONN. EPIPE is the generic
    # write-to-a-dead-endpoint errno and means the same here.
    #
    # ENOSYS is here because bt_to_errno returns it for every code it has no
    # case for, and ordinary LE disconnect reasons are among them: 0x22 LL
    # Response Timeout, 0x3E Connection Failed to be Established, 0x3D MIC
    # Failure, 0x1F Unspecified Error. It is the same blanket mapping
    # LeConnect::UNREACHABLE_ERRORS makes for the connect path; here it keeps a
    # Link lost to one of those reasons mid-Walk a disconnected Walk, with
    # Resume_State, rather than an error.
    BEARER_DISCONNECT_ERRORS = [
      Errno::ECONNRESET, Errno::ENOTCONN, Errno::ECONNABORTED,
      Errno::ETIMEDOUT, Errno::EHOSTDOWN, Errno::EPIPE, Errno::ENOSYS
    ].freeze

    # Every Walk_Outcome, in the design's precedence: disconnected, busy,
    # error, timeout, unchanged, protected, complete, partial. finish refuses
    # anything else, so a misspelt outcome fails loudly instead of reaching a
    # counter that does not exist.
    #
    # A Walk records the first outcome it meets, and the precedence is how
    # the code decides when two meet at once:
    # - Bearer setup yields one of disconnected, busy, error (Requirements
    #   5.3 to 5.5, 5.10) or, when Walk_Bound cuts the connect wait short of
    #   its 1 s window and it expires, timeout (3.4). A Link already down,
    #   or shutdown, is disconnected before any connect errno can arise;
    #   EBUSY is classified ahead of every other errno; a connect wait that
    #   Walk_Bound and the 1 s window end together is disconnected.
    # - During the Walk, shutdown is disconnected ahead of an expired
    #   Walk_Bound (transact checks stopping first), and any errno other than
    #   a Link drop is error on the spot.
    # - timeout and disconnected end the Walk wherever they arise, so they
    #   win over unchanged (a hash read with no answer proves nothing) and,
    #   per Requirement 6.13, over protected, complete and partial.
    # - protected ends the Walk at the first primary-service request
    #   (Requirement 6.7), before anything could make it partial.
    # - complete needs every procedure to have ended normally and every
    #   Identity_Set read to have a value, a Security_Error or a malformed
    #   value (Requirement 6.8); otherwise the Walk is partial (6.9).
    OUTCOMES = %i[disconnected busy error timeout unchanged protected complete partial].freeze

    # Outcomes of a Walk that did not reach its end. Their report carries the
    # WalkState, whose outstanding work the Gatt_Scanner keeps as Resume_State.
    INTERRUPTED_OUTCOMES = %i[timeout disconnected].freeze

    FIRST_HANDLE = 0x0001
    LAST_HANDLE  = 0xFFFF

    # The attribute type each discovery procedure's requests name: «Primary
    # Service», «Secondary Service», «Include» and «Characteristic» (Core 6.3
    # Vol 3 Part G 3.1 to 3.3). :descriptors names none, as Find Information
    # returns every attribute in its range.
    DISCOVERY_TYPES = {
      primary:         AttCodec.uuid16(0x2800),
      secondary:       AttCodec.uuid16(0x2801),
      includes:        AttCodec.uuid16(0x2802),
      characteristics: AttCodec.uuid16(0x2803)
    }.freeze

    # The response that is a page of each procedure; any other response to its
    # request, bar an Error Response naming that request, is mismatched.
    PAGE_RESPONSES = {
      primary:         AttCodec::ReadByGroupTypeResponse,
      secondary:       AttCodec::ReadByGroupTypeResponse,
      includes:        AttCodec::ReadByTypeResponse,
      characteristics: AttCodec::ReadByTypeResponse,
      descriptors:     AttCodec::FindInformationResponse
    }.freeze

    SERVICE_KINDS = %i[primary secondary].freeze

    # The Error Response code that ends every discovery sub-procedure normally
    # (Core 6.3 Vol 3 Part G 4.4.1, 4.5.1, 4.6.1, 4.7.1).
    ATTRIBUTE_NOT_FOUND = 0x0A

    # The Error Response code that also ends the :secondary procedure normally
    # (Requirement 6.4). GATT has no secondary-service discovery sub-procedure:
    # Part G 4.4 discovers primary services only, and secondary ones are
    # reached through the Include declarations 4.5.1 finds per service. The
    # 0x2801 Read By Group Type is therefore a sweep this Walk adds, and a
    # server may refuse the group type. Android's does
    # (packages/modules/Bluetooth, system/stack/gatt/gatt_sr.cc,
    # gatts_process_primary_service_req answers every Read By Group Type whose
    # type is not Primary Service with GATT_UNSUPPORT_GRP_TYPE), so without
    # this case every Android phone, TV and head unit walks partial: a "HOME
    # THEATRE" device at MTU 517 did in Device_Validation. Nothing is lost by
    # ending the sweep: the includes procedure still finds the secondaries a
    # primary service refers to. On :primary, which every GATT server must
    # answer, 0x10 is a defect in the peer and stays partial (Requirement 6.6).
    UNSUPPORTED_GROUP_TYPE = 0x10

    # One discovery procedure, run a page at a time.
    #   kind          :primary (Read By Group Type 0x2800), :secondary (0x2801),
    #                 :includes (Read By Type 0x2802), :characteristics (0x2803)
    #                 or :descriptors (Find Information)
    #   start, end    the handle range the procedure searches
    #   next          start handle of the next page to request; it only moves
    #                 once a page has been recorded, so an interrupted page is
    #                 requested again on resume
    #   service_index the owning entry of WalkState#services, nil for the two
    #                 service procedures
    #   char_index    the owning entry of WalkState#characteristics, for
    #                 :descriptors only
    Procedure = Struct.new(:kind, :start, :end, :next, :service_index, :char_index)

    # One value read: a Read Request, then Read Blob Requests at the collected
    # offset.
    #   kind       :identity, :presentation_format (a 0x2904 descriptor) or :value
    #   handle     the attribute handle read
    #   char_index the entry of WalkState#characteristics it belongs to
    #   offset     0 for the opening Read Request, otherwise the Read Blob offset
    #   collected  binary String of the value bytes received so far
    #   carried    the task had offset > 0 when a resumed Walk adopted its
    #              state (adopt_resume_state): its collected bytes came in at
    #              the earlier Walk's ATT_MTU, which the server no longer
    #              judges "long" against. Only such a task gets the
    #              Requirement 7.19 re-read; within one Walk ATT_MTU only ever
    #              falls, so a Walk's own blobs never need it
    #   restarted  the one Requirement 7.19 re-read from offset 0 has been
    #              used, so a further 0x0B ends the read under Requirement 7.1
    ReadTask = Struct.new(:kind, :handle, :char_index, :offset, :collected, :carried, :restarted)

    # One discovered characteristic.
    #   service_index       the entry of WalkState#services it was found in
    #   decl_handle         handle of its characteristic declaration
    #   value_handle        handle of its value
    #   properties          the declaration's properties bit field
    #   uuid                AttCodec::Uuid
    #   descriptors         its descriptors, ascending handle
    #   read_status         its Read_Status (Requirement 7), one of
    #                       READ_STATUSES. nil until decided, and left nil for
    #                       a characteristic whose read is still pending and
    #                       for a readable one outside the Identity_Set when
    #                       read_all is false (no read is ever sent for it)
    #   error_code          the ATT error code when a read was answered with an
    #                       Error Response: set for protected, and for error
    #                       unless the read ended on a Malformed or mismatched
    #                       PDU, which carries no code
    #   value_bytes         the bytes of a finished read (read or malformed), at
    #                       most MAX_VALUE_BYTES; nil otherwise
    #   presentation_format ValueDecoder::PresentationFormat from its 0x2904
    #                       descriptor, nil without one
    #   decoded             ValueDecoder::Decoded, set exactly when read_status
    #                       is :read. An Identity_Set value carries its
    #                       dedicated rendering with encoding "identity" and no
    #                       raw_hex, and value nil when the string was empty
    #                       once trailing 0x00 bytes were stripped (Requirement
    #                       7.10); any other value carries ValueDecoder.decode's
    #                       result (Requirement 7.12)
    CharRecord = Struct.new(:service_index, :decl_handle, :value_handle, :properties, :uuid, :descriptors,
                            :read_status, :error_code, :value_bytes, :presentation_format, :decoded)

    # Every Read_Status (Requirement 7). Each Symbol's to_s is the entry
    # schema's read_status string.
    READ_STATUSES = %i[read protected not-read not-readable error malformed].freeze

    # The Read_Statuses whose gatt_characteristics entry carries error_code
    # (Requirement 11.10). An error read that ended on a Malformed or
    # mismatched PDU has no ATT error code, and its entry carries
    # error_code: nil: the key is the schema's marker for these two
    # statuses, and the design's read table gives such a read no code.
    ERROR_CODE_STATUSES = %i[protected error].freeze

    # The Read bit of a characteristic declaration's properties (Core 6.3 Vol 3
    # Part G 3.3.1.1).
    READ_PROPERTY = 0x02

    # Every Characteristic Properties bit (Core 6.3 Vol 3 Part G 3.3.1.1),
    # 0x01 to 0x80, by its name in a gatt_characteristics entry's properties
    # list, which lists the set ones in this order.
    PROPERTY_NAMES = {
      0x01 => "broadcast",
      0x02 => "read",
      0x04 => "write-without-response",
      0x08 => "write",
      0x10 => "notify",
      0x20 => "indicate",
      0x40 => "authenticated-signed-writes",
      0x80 => "extended-properties"
    }.freeze

    # Characteristic Presentation Format (Core 6.3 Vol 3 Part G 3.3.3.5).
    PRESENTATION_FORMAT = 0x2904

    # Error Responses that end a Read Blob sequence normally (Requirement 7.1):
    # 0x0B Attribute Not Long, which a server may answer when the whole value
    # already came in the Read Response, and 0x07 Invalid Offset, an offset
    # past the value's end (Core 6.3 Vol 3 Part F 3.4.4.5). To the opening
    # Read Request either one is an ordinary error (Requirement 7.9). The one
    # exception is 0x0B to a Read Blob carried over from an interrupted Walk
    # (ReadTask#carried), which run_read_step may answer with a re-read
    # (Requirement 7.19).
    ATTRIBUTE_NOT_LONG   = 0x0B
    READ_BLOB_END_ERRORS = [ATTRIBUTE_NOT_LONG, 0x07].freeze

    # A Walk's progress; Resume_State is a snapshot of one.
    #   database_hash   hex of the Database Hash this state was built against,
    #                   nil until one is read
    #   services        [{uuid:, type: :primary | :secondary, start:, end:,
    #                   includes: [{start:, end:, uuid: Uuid | nil}]}], ascending start
    #   characteristics [CharRecord], ascending value_handle
    #   procedures      FIFO worklist of Procedure
    #   reads           FIFO worklist of ReadTask, generated once every
    #                   procedure has ended
    #   reads_generated whether reads has been generated
    #   partial         a procedure or identity read ended with a gap
    #                   (Requirements 6.5, 6.6, 7.9)
    #   protected_root  the first primary-service request of a fresh Walk was
    #                   answered with a Security_Error (Requirement 6.7)
    #
    # Members hold plain data only: Structs, Arrays, Hashes, Integers, Strings,
    # Symbols, booleans, nil, and the AttCodec and ValueDecoder Data values.
    # That is what lets deep_dup be a Marshal round trip.
    WalkState = Struct.new(:database_hash, :services, :characteristics, :procedures, :reads,
                           :reads_generated, :partial, :protected_root) do
      # Primary then secondary service discovery over the whole handle range,
      # and nothing else yet: the include, characteristic and descriptor
      # procedures are appended as the services are found.
      def self.fresh
        new(database_hash: nil, services: [], characteristics: [],
            procedures: [
              Procedure.new(kind: :primary,   start: FIRST_HANDLE, end: LAST_HANDLE, next: FIRST_HANDLE),
              Procedure.new(kind: :secondary, start: FIRST_HANDLE, end: LAST_HANDLE, next: FIRST_HANDLE)
            ],
            reads: [], reads_generated: false, partial: false, protected_root: false)
      end

      # A copy sharing no mutable object with this one, so the Gatt_Tracker's
      # Resume_State and a Walk working from it can never write into each
      # other. Marshal copies every level (Structs, Arrays, Hashes, binary
      # Strings with their encoding) and rebuilds the Data values (Uuid,
      # PresentationFormat) as equal frozen values. A member that is not plain
      # data (a Proc, an IO, a Hash with a default proc) makes Marshal raise
      # TypeError instead of letting a shared reference through.
      def deep_dup
        Marshal.load(Marshal.dump(self))
      end

      # Whether any discovery procedure or value read is still to run: the
      # condition under which an interrupted Walk leaves Resume_State
      # (Requirement 17.1).
      def outstanding?
        !procedures.empty? || !reads_generated || !reads.empty?
      end
    end

    # What the Gatt_Scanner asks of a Walk, from the Gatt_Tracker's plan_for:
    #   Plan.full             discover everything from a fresh WalkState
    #   Plan.hash_check(hex)  read the Database Hash first; stop when it still
    #                         equals hex, otherwise walk from a fresh WalkState
    #   Plan.resume(state)    continue a Resume_State: after the exchange, no
    #                         hash check, only its outstanding procedures and
    #                         reads, on a deep copy that leaves +state+ as it
    #                         is (GattWalker#adopt_resume_state)
    Plan = Data.define(:kind, :expected_hash, :state) do
      def self.full
        new(kind: :full, expected_hash: nil, state: nil)
      end

      def self.hash_check(expected)
        unless expected.is_a?(String)
          raise ArgumentError, "hash_check needs the recorded Database Hash, got #{expected.inspect}"
        end
        new(kind: :hash_check, expected_hash: expected, state: nil)
      end

      def self.resume(state)
        raise ArgumentError, "resume needs a WalkState, got #{state.class}" unless state.is_a?(WalkState)
        new(kind: :resume, expected_hash: nil, state: state)
      end

      def full?
        kind == :full
      end

      def hash_check?
        kind == :hash_check
      end

      def resume?
        kind == :resume
      end
    end

    # What run returns.
    #   started_at, ended_at  readings of the walker's clock at run's entry and
    #                         just after the bearer closed, so a caller on the
    #                         same clock measures Requirement 13.6's duration
    #                         from its own attempted increment to ended_at
    #   mtu                   the ATT_MTU in use at the end, DEFAULT_MTU when no
    #                         Exchange MTU Response was received
    #   resumed               whether the plan was Plan.resume
    #   requests_sent         client requests only; Att_Server replies and
    #                         Handle Value Confirmations are not counted
    #   services              every primary and secondary service the WalkState
    #                         holds, ascending start: {uuid:, type:, start:,
    #                         end:, includes: [{uuid:, start:, end:}]}, uuid in
    #                         Uuid_Formatter form (nil for a 4-octet include no
    #                         discovered service starts at), type "primary" or
    #                         "secondary". Empty when the Walk built no
    #                         WalkState. The result's service_uuids are their
    #                         uuids. A resumed Walk holds its WalkState from
    #                         the start, so this and characteristics and
    #                         identity are everything found so far across the
    #                         Walks it continues, whatever its outcome
    #                         (Requirement 17.4)
    #   characteristics       one gatt_characteristics entry per characteristic
    #                         the WalkState holds, in the in-memory form
    #                         GattCharacteristics accepts (design entry schema,
    #                         Requirements 10.9, 11.10), ascending value_handle.
    #                         A characteristic with no Read_Status yet (its
    #                         read still pending when the Walk was cut short,
    #                         or readable outside the Identity_Set with
    #                         read_all false) is "not-read"
    #   identity              Identity_Set key (IDENTITY_SET's values) => value,
    #                         for each Identity_Set characteristic read with a
    #                         value: neither malformed nor a string empty once
    #                         stripped (Requirements 7.10, 7.13, 11.12)
    #   database_hash         the Database Hash read most recently in this Walk,
    #                         rendered as ValueDecoder.decode_identity renders
    #                         0x2B2A (lowercase hex, received byte order), nil
    #                         when none was read. For unchanged it is the hash
    #                         the check confirmed. For a resumed Walk it starts
    #                         as its WalkState's database_hash, the hash read by
    #                         the Walks it continues, until it reads one itself
    #                         (adopt_resume_state). What the Gatt_Tracker
    #                         records for a Finished_Walk (Requirement 4.8) and
    #                         what a later Plan.hash_check compares against
    #   hash_changed          true when this Walk's hash check (Plan.hash_check)
    #                         read a well-formed hash other than the recorded
    #                         one, so everything after it was walked from a
    #                         fresh WalkState over a changed database. On it the
    #                         Gatt_Scanner discards the address's Resume_State
    #                         before storing any new one (Requirement 17.6), and
    #                         the Device clears its stored gatt_characteristics,
    #                         but not gatt_service_uuids, before applying the
    #                         result (Requirement 11.9). False for every other
    #                         plan, and for a hash check whose read was
    #                         unavailable (an Error Response, a Malformed or
    #                         mismatched PDU, or a value not 16 octets): that
    #                         walks in full but proves no change, and records
    #                         no hash
    #   state                 for timeout and disconnected, the live WalkState
    #                         with the interrupted page or read still at the
    #                         head of its list, the work this Walk finished
    #                         gone from its lists: the still-outstanding set
    #                         that replaces Resume_State (Requirements 17.1,
    #                         17.5). For a resumed Walk that is its copy of the
    #                         plan's state, so one cut short before it sent a
    #                         discovery or read request reports that state's
    #                         outstanding work unchanged. nil for a fresh or
    #                         hash-check Walk that ended before its worklist
    #                         started (nothing new to keep), and for every
    #                         other outcome (complete, partial, protected,
    #                         unchanged, busy, error). A WalkState whose
    #                         outstanding? is false is possible only when
    #                         resumed from one: the Gatt_Scanner keeps no
    #                         Resume_State for it (Requirement 17.1)
    #   outstanding           {procedures: [{kind:, start:, end:, next:}],
    #                         reads: [{kind:, value_handle:}]}: state's
    #                         worklists, for the result (Requirement 11.1) and
    #                         debugging; state is what Resume_State is made
    #                         from. A read's value_handle is its
    #                         characteristic's, for a 0x2904 read too. Both
    #                         lists are empty whenever state is nil
    #   handoff_lag           seconds from the Link coming up to the connect,
    #                         nil when the Walk never got that far
    WalkReport = Data.define(:address, :outcome, :resumed, :started_at, :ended_at, :mtu, :requests_sent,
                             :services, :characteristics, :identity, :database_hash, :hash_changed, :state,
                             :outstanding, :handoff_lag)

    # The Att_Bearer: an L2CAP socket on fixed CID 0x0004 attached to the
    # existing Link.
    #
    # The socket surface used, which a spec fake provides: bind,
    # connect_nonblock, getsockopt(SOL_SOCKET, SO_ERROR), send,
    # recv_nonblock(maxlen, exception: false), wait_readable, wait_writable,
    # close and closed?. Both waits go through the Bearer's own wait_readable
    # and wait_writable, so a spec can drive them from a fake clock instead.
    #
    # No BT_SECURITY socket option is set, here or anywhere (Requirement 5.11),
    # so the channel keeps the level the kernel gave it: l2cap_sock_init calls
    # l2cap_chan_set_defaults, which sets BT_SECURITY_LOW
    # (net/bluetooth/l2cap_sock.c, l2cap_sock_init; net/bluetooth/l2cap_core.c,
    # l2cap_chan_set_defaults), and l2cap_sock_bind changes it only for RAW,
    # connectionless and SDP/RFCOMM channels, never for a fixed one. At LOW,
    # smp_sufficient_security answers true, so smp_conn_security, which the
    # connect reaches through l2cap_chan_check_security or l2cap_le_start,
    # starts no pairing and no encryption (net/bluetooth/smp.c). That holds
    # after a Security_Error too: nothing here ever asks for more.
    class Bearer
      BTPROTO_L2CAP = 0
      ATT_CID       = 0x0004
      NO_PSM        = 0x0000

      # recv buffer size. chan->imtu is L2CAP_DEFAULT_MTU, 672
      # (include/net/bluetooth/l2cap.h), set by l2cap_sock_init and never
      # changed here, and l2cap_data_channel (net/bluetooth/l2cap_core.c) drops
      # a BASIC-mode SDU longer than imtu. bt_sock_recvmsg
      # (net/bluetooth/af_bluetooth.c) cuts a longer datagram to the buffer and
      # discards the rest, so a 672-byte buffer never truncates a PDU, however
      # far past ATT_MTU a peer goes.
      RECV_BYTES = 672

      # Connect errnos meaning the Link is not there to attach to (Requirement
      # 5.4). See connect_failed.
      CONNECT_DISCONNECT_ERRORS = ([Errno::ENOTCONN] + BlueHydra::LeConnect::UNREACHABLE_ERRORS).freeze

      # Appended to the failure line when the errno is ENOSYS, which on a
      # Bluetooth socket is not a missing syscall: bt_to_errno
      # (net/bluetooth/lib.c) has a default case that returns ENOSYS for every
      # HCI status it has no explicit mapping for, and 0x3E Connection Failed
      # to be Established, the peer never answering the connection request
      # within the supervision window, is one of those. On the DART 17 of 36
      # disconnected Walks logged ENOSYS and the btmon capture showed 0x3E on
      # each of those links. Without this the line sends the reader to the
      # wrong place.
      ENOSYS_HINT = ", kernel: unmapped HCI status (bt_to_errno fallback), " \
                    "typically 0x3E Connection Failed to be Established"

      # One debug line per bearer failure, naming the device address and the
      # errno (Requirement 5.5). The outcome is decided before this is called
      # and the hint changes nothing about it.
      def self.log_failure(address, step, outcome, error)
        hint = error.errno == Errno::ENOSYS::Errno ? ENOSYS_HINT : ""
        BlueHydra.logger.debug(
          "gatt: #{address} bearer #{step} #{outcome}: #{error.class} (errno #{error.errno})#{hint}"
        )
      end

      def initialize(socket, local_address:, local_type: BlueHydra::Mgmt::LE_PUBLIC)
        @socket        = socket
        @local_address = local_address
        @local_type    = local_type
      end

      # Bind the source side: l2_psm 0, l2_cid 0x0004, the controller's
      # identity address and its LE type. Raises SystemCallError on failure,
      # which GattWalker#setup_bearer records as outcome error.
      #
      # This bind is what makes the socket an ATT bearer, and it has to come
      # before connect (net/bluetooth/l2cap_sock.c, l2cap_sock_bind):
      # - An l2_cid calls l2cap_add_scid (net/bluetooth/l2cap_core.c), which
      #   sets chan_type = L2CAP_CHAN_FIXED and scid = 0x0004. Unbound, the
      #   channel is still the L2CAP_CHAN_CONN_ORIENTED that l2cap_sock_init
      #   made it, and l2cap_chan_connect refuses a connection-oriented channel
      #   with no PSM (EINVAL).
      # - With an LE l2_bdaddr_type only CID 0x0004 is accepted ("We only allow
      #   ATT user space socket"), and an l2_cid with a non-zero l2_psm is
      #   EINVAL.
      # - An L2CAP_CHAN_FIXED channel gets FLAG_HOLD_HCI_CONN. Without that flag
      #   __l2cap_chan_add (net/bluetooth/l2cap_core.c) takes no hci_conn
      #   reference for a fixed channel; with it, the bearer holds the Link (see
      #   connect).
      #
      # The address and type must be the controller's identity address
      # exactly. connect finds the controller through hci_get_route
      # (net/bluetooth/hci_conn.c), which matches the bound address and type
      # against hci_copy_identity_address, and a mismatch fails the connect with
      # EHOSTUNREACH, which reads as disconnected.
      def bind
        @socket.bind(sockaddr(@local_address, @local_type))
      end

      # Attach to the Link already up to +address+ (+address_type+ the mgmt LE
      # type, which is also sockaddr_l2's: BDADDR_LE_PUBLIC 0x01,
      # BDADDR_LE_RANDOM 0x02), waiting at most +timeout+ seconds. Returns
      # :connected, :busy, :disconnected or :error, and never raises; a
      # connect still pending when +timeout+ runs out returns +expired+, which
      # is :disconnected unless the caller says the wait was Walk_Bound's
      # (GattWalker#setup_bearer).
      #
      # On a Link that is up this makes no new connection. l2cap_chan_connect
      # (net/bluetooth/l2cap_core.c) gets the hci_conn from hci_connect_le_scan
      # (net/bluetooth/hci_conn.c), which finds it with hci_conn_hash_lookup_le
      # and returns it hci_conn_hold-ed. __l2cap_chan_add then takes the
      # channel's own reference (bind set FLAG_HOLD_HCI_CONN) and the lookup's
      # is dropped, so the open bearer holds the Link until close releases it
      # (l2cap_chan_del's hci_conn_drop).
      #
      # That hold is what lets a Walk outlast an auto-connected Link's unheld
      # lifetime. The kernel holds that Link only for its own LE Read Remote
      # Features: hci_le_read_remote_features takes a reference and
      # le_read_features_complete drops it once the command has finished with
      # HCI_EV_LE_REMOTE_FEAT_COMPLETE (net/bluetooth/hci_sync.c), the event
      # hci_le_remote_feat_complete_evt handles (net/bluetooth/hci_event.c).
      # With no holder left, hci_conn_drop (include/net/bluetooth/hci_core.h)
      # queues the disconnect conn->disc_timeout later: HCI_DISCONN_TIMEOUT, 2 s
      # (include/net/bluetooth/hci.h; set in __hci_conn_add,
      # net/bluetooth/hci_conn.c), not doubled because conn->out is set on the
      # central. The connect has to land inside that window.
      #
      # On a BT_CONNECTED Link, l2cap_chan_connect marks a fixed channel
      # connected itself, so connect_nonblock returns at once. On a Link still
      # in BT_CONFIG (the feature read in progress) it answers EINPROGRESS, and
      # the channel goes ready with the Link: l2cap_connect_cfm ->
      # l2cap_conn_ready -> l2cap_le_start, which for a channel with no PSM
      # calls l2cap_chan_ready and sends no L2CAP signalling.
      #
      # ATT PDUs the peer sends before this connect lands are lost:
      # l2cap_data_channel (net/bluetooth/l2cap_core.c) finds no channel with
      # scid 0x0004 on the Link and drops them.
      def connect(address, address_type, timeout, expired: :disconnected)
        begin
          @socket.connect_nonblock(sockaddr(address, address_type))
          return :connected
        rescue IO::WaitWritable
          # Pending until the Link leaves BT_CONFIG; see above.
        end

        # The result is read from SO_ERROR, once, since reading clears it. Never
        # by a second connect: a torn-down channel is SOCK_ZAPPED and
        # l2cap_sock_connect answers EINVAL before looking at anything else
        # (net/bluetooth/l2cap_sock.c; see LeConnect#finish_connect).
        # bt_sock_poll (net/bluetooth/af_bluetooth.c) reports no EPOLLOUT while
        # the socket is BT_CONNECT, BT_CONNECT2 or BT_CONFIG, and EPOLLERR once
        # l2cap_sock_teardown_cb has set sk_err, so a writable wake means
        # connected or failed, and SO_ERROR says which.
        unless wait_writable(timeout)
          BlueHydra.logger.debug(
            "gatt: #{address} bearer connect #{expired}: not complete within #{format('%.2f', timeout)}s"
          )
          return expired
        end
        errno = @socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        return :connected if errno.zero?
        connect_failed(address, SystemCallError.new(nil, errno))
      rescue SystemCallError => e
        connect_failed(address, e)
      rescue IOError
        # close_bearer closed the socket underneath the connect: shutdown.
        BlueHydra.logger.debug("gatt: #{address} bearer connect disconnected: bearer closed")
        :disconnected
      end

      # Send one PDU. Returns :ok or :disconnected; raises SystemCallError for
      # any other errno, which GattWalker#run ends as outcome error.
      #
      # A plain send, which Ruby retries internally on EAGAIN, is safe here:
      # with one ATT request outstanding in each direction the send buffer
      # cannot fill, and close_bearer wakes a blocked send with IOError.
      def send_pdu(bytes)
        @socket.send(bytes, 0)
        :ok
      rescue *BEARER_DISCONNECT_ERRORS, Errno::EBADF, IOError
        # IOError and EBADF: close_bearer closed the socket (shutdown).
        :disconnected
      end

      # Wait at most +timeout+ seconds for one PDU. Returns it as a binary
      # String, :timeout or :disconnected; raises SystemCallError for any other
      # errno, which GattWalker#run ends as outcome error.
      #
      # One recv is one PDU: SOCK_SEQPACKET keeps datagram boundaries, and
      # bt_sock_recvmsg dequeues one skb per call (net/bluetooth/af_bluetooth.c).
      #
      # recv_nonblock rather than recv because a readable socket can still have
      # nothing to read. bt_sock_poll reports EPOLLHUP for a BT_CLOSED socket,
      # and once sk_err has been read, a non-blocking recv on it answers EAGAIN
      # (__skb_try_recv_datagram, net/core/datagram.c) where a blocking one
      # would get ENOTCONN (__skb_wait_for_more_packets). That is a closed
      # channel, so it is disconnected. recv would instead sit in Ruby's
      # internal EAGAIN wait, which has no timeout and wakes at once on
      # EPOLLHUP: a busy loop that Walk_Bound cannot end.
      #
      # EOF (bt_sock_recvmsg returns 0 once RCV_SHUTDOWN is set) is nil from
      # recv_nonblock(exception: false) and "" from recv; both are
      # disconnected.
      def recv_pdu(timeout)
        return :timeout unless wait_readable(timeout)
        data = @socket.recv_nonblock(RECV_BYTES, exception: false)
        return :disconnected if data.nil? || data == :wait_readable || data.empty?
        data
      rescue *BEARER_DISCONNECT_ERRORS, Errno::EBADF, IOError
        # IOError and EBADF: close_bearer closed the socket (shutdown).
        :disconnected
      end

      # The bearer's two waits; specs override them to run on a fake clock.
      # Each returns truthy once the socket is ready and falsy when +timeout+
      # seconds pass first, and a timeout at or below zero only polls. Both
      # raise IOError once the socket is closed, including by close_bearer on
      # another thread mid-wait; GattWalker#close_bearer records why these are
      # IO#wait_* and not IO.select.
      def wait_writable(timeout)
        @socket.wait_writable([timeout, 0].max)
      end

      def wait_readable(timeout)
        @socket.wait_readable([timeout, 0].max)
      end

      # Idempotent: the walker's finish and the Gatt_Scanner's shutdown can
      # both reach it.
      def close
        @socket.close unless @socket.closed?
      end

      def closed?
        @socket.closed?
      end

      private

      # Errno -> outcome, one table for an errno connect_nonblock raises and one
      # read back from SO_ERROR, each logged at debug with address and errno.
      #
      # A Link failing or dropping while the connect is pending reaches the
      # socket as l2cap_conn_del(hcon, bt_to_errno(status)) from
      # l2cap_connect_cfm or l2cap_disconn_cfm (net/bluetooth/l2cap_core.c),
      # which l2cap_sock_teardown_cb stores in sk_err. bt_to_errno
      # (net/bluetooth/lib.c) maps 0x08 -> ETIMEDOUT, 0x13..0x15 -> ECONNRESET,
      # 0x16 -> ECONNABORTED, 0x04 and 0x3C -> EHOSTDOWN, and anything it has no
      # case for (0x3E among them) -> ENOSYS, all in
      # LeConnect::UNREACHABLE_ERRORS, which also has hci_get_route's
      # EHOSTUNREACH: no up controller with the bound identity address.
      # ENOTCONN is bt_to_errno's 0x02 Unknown Connection Identifier.
      #
      # bt_to_errno maps 0x09 Connection Limit Exceeded (and 0x0A) to EMLINK.
      # That needs a new connection, which this connect never makes, so here
      # EMLINK is just another errno and goes to error; conn_limit is
      # LeConnect's alone (Requirement 18).
      #
      # EBUSY raised by connect is l2cap_chan_connect finding a channel with
      # dcid 0x0004 already on the Link (__l2cap_get_chan_by_dcid): bluetoothd's
      # ATT socket, or another bearer. Through SO_ERROR an EBUSY would instead
      # be bt_to_errno's 0x0C Command Disallowed; it stays busy so that both
      # routes share one table.
      def connect_failed(address, error)
        outcome =
          if error.is_a?(Errno::EBUSY)
            :busy
          elsif CONNECT_DISCONNECT_ERRORS.any? { |klass| error.is_a?(klass) }
            :disconnected
          else
            :error
          end
        Bearer.log_failure(address, "connect", outcome, error)
        outcome
      end

      # struct sockaddr_l2 { l2_family; __le16 l2_psm; bdaddr_t l2_bdaddr;
      # __le16 l2_cid; __u8 l2_bdaddr_type } (include/net/bluetooth/l2cap.h):
      # LeConnect#sockaddr's packing with no PSM and the ATT CID.
      def sockaddr(address, address_type)
        [BlueHydra::Mgmt::AF_BLUETOOTH, NO_PSM, BlueHydra::Mgmt.pack_address(address), ATT_CID, address_type]
          .pack("S!S!a6S!C")
      end
    end

    # == Parameters
    #   address, address_type  the handed-off device and its mgmt LE address type
    #   hci_index              controller index (the N in hciN)
    #   local_address          the controller's identity address, bound as the
    #                          bearer's source
    #   plan                   a Plan
    #   deadline               clock reading at which Walk_Bound expires (the
    #                          Gatt_Scanner's attempted time + gatt_walk_timeout)
    #   read_all               gatt_read_all: read every readable value, not
    #                          just the Identity_Set
    #   link_up, stopping, on_peer_request, clock  see the class comment
    def initialize(address:, address_type:, hci_index:, local_address:, plan:, deadline:,
                   read_all:, link_up:, stopping:, on_peer_request:, clock: MONOTONIC)
      @address         = address
      @address_type    = address_type
      @hci_index       = hci_index
      @local_address   = local_address
      @plan            = plan
      @deadline        = deadline
      @read_all        = read_all
      @link_up         = link_up
      @stopping        = stopping
      @on_peer_request = on_peer_request
      @clock           = clock
      @att_server      = AttServer.new

      @bearer_mutex  = Mutex.new
      @bearer        = nil
      @bearer_closed = false

      @state                 = nil
      @mtu                   = nil
      @mtu_response_seen     = false
      @peer_client_rx_mtu    = nil
      @transaction_timed_out = false
      @requests_sent         = 0
      @database_hash         = nil
      @hash_changed          = false
      @handoff_lag           = nil
    end

    # Perform the Walk and return its WalkReport. Every return goes through
    # finish, which closes the bearer first.
    def run
      @started_at = @clock.now
      adopt_resume_state if @plan.resume?

      setup = setup_bearer
      return finish(setup) unless setup == :connected

      mtu = exchange_mtu
      return finish(mtu) if interrupted?(mtu)

      planned = plan_state
      return finish(planned) unless planned.is_a?(WalkState)
      @state = planned

      until @state.procedures.empty?
        step = run_procedure_page(@state.procedures.first)
        return finish(step) if interrupted?(step)
        return finish(:protected) if @state.protected_root
      end

      generate_reads unless @state.reads_generated
      until @state.reads.empty?
        step = run_read_step(@state.reads.first)
        return finish(step) if interrupted?(step)
      end

      finish(@state.partial ? :partial : :complete)
    rescue SystemCallError => e
      # The bearer's send and recv raise any errno other than a Link drop, and
      # the bearer is the walker's only I/O.
      Bearer.log_failure(@address, "I/O", :error, e)
      finish(:error)
    end

    # Close the Att_Bearer. Idempotent and callable from any thread: the
    # Gatt_Scanner's shutdown calls it while the Walk thread may be blocked on
    # the socket. Once it has run, a bearer the Walk thread installs afterwards
    # is closed on the spot, so a shutdown that lands while the bearer is being
    # set up cannot miss it.
    #
    # A thread blocked in IO#wait_readable, IO#wait_writable or recv on the
    # socket fails out with IOError as soon as it is closed here. A thread
    # blocked in IO.select is not woken and sits out its whole timeout before
    # raising (measured on Ruby 4.0.1: 3.00 s for a 3 s select, against 0.20 s
    # for wait_readable and recv), so the bearer's waits must not use IO.select.
    def close_bearer
      @bearer_mutex.synchronize do
        @bearer_closed = true
        @bearer.close if @bearer && !@bearer.closed?
      end
    end

    # The current Att_Bearer, nil before one is opened.
    def bearer
      @bearer_mutex.synchronize { @bearer }
    end

    private

    # Open the Att_Bearer, confirm the Link is still up, bind and connect.
    # Returns :connected, or the Walk_Outcome that ends the Walk there: any
    # errno opening or binding is error (Requirement 5.5), and the connect's
    # outcome is Bearer#connect's.
    def setup_bearer
      socket =
        begin
          open_socket
        rescue SystemCallError => e
          Bearer.log_failure(@address, "open", :error, e)
          return :error
        end
      att_bearer = Bearer.new(socket, local_address: @local_address)
      return :disconnected unless install_bearer(att_bearer)

      # Requirement 5.10. A connect with no Link up does not fail: it creates
      # one. l2cap_chan_connect gets the hci_conn from hci_connect_le_scan (or
      # hci_connect_le while advertising), which finds none
      # (hci_conn_hash_lookup_le) and adds a new LE link, i.e. asks the
      # controller for a fresh connection - radio activity this feature must
      # not add (net/bluetooth/l2cap_core.c, l2cap_chan_connect;
      # net/bluetooth/hci_conn.c, hci_connect_le_scan).
      link_up_at = @link_up.call(@address)
      unless link_up_at
        BlueHydra.logger.debug("gatt: #{@address} link down before connect")
        return :disconnected
      end
      @handoff_lag = @clock.now - link_up_at if link_up_at.is_a?(Numeric)

      begin
        att_bearer.bind
      rescue SystemCallError => e
        Bearer.log_failure(@address, "bind", :error, e)
        return :error
      rescue IOError
        # close_bearer closed it between install and bind: shutdown.
        return :disconnected
      end

      # The connect waits at most CONNECT_TIMEOUT, and a connect not complete
      # by then is disconnected (Requirement 5.4). Walk_Bound covers bearer
      # setup too (Requirement 3.4), so the wait never runs past the deadline,
      # and a wait the deadline cut short of the 1 s window ends with
      # Walk_Bound expired: timeout. When the two end together the connect
      # has had its whole window, and disconnected, ahead of timeout in the
      # precedence (OUTCOMES), is recorded.
      wait = [CONNECT_TIMEOUT, remaining].min
      att_bearer.connect(@address, @address_type, wait, expired: wait < CONNECT_TIMEOUT ? :timeout : :disconnected)
    end

    # False when close_bearer has already run, in which case the new bearer is
    # closed here and never used.
    def install_bearer(new_bearer)
      @bearer_mutex.synchronize do
        if @bearer_closed
          new_bearer.close
          return false
        end
        @bearer = new_bearer
      end
      true
    end

    # Plan.resume (Requirement 17.3): the Walk continues the plan's WalkState,
    # and holds it from run's entry, before its bearer exists. A resumed Walk
    # cut short anywhere, bearer setup and the exchange included, then reports
    # that state with its outstanding work, as it now stands, for the
    # Gatt_Scanner to keep as Resume_State (Requirement 17.5); a nil state
    # would clear it (GattTracker.store_resume_state). Fresh and hash-check
    # Walks still build theirs in plan_state, after the exchange, and report
    # none when cut short before then: there is nothing of theirs to keep.
    #
    # The Walk works on a deep copy. The plan's state stays as given, so the
    # Gatt_Tracker's Resume_State and this Walk never write into each other,
    # whatever the Walk ends with.
    #
    # The report's database_hash starts as the hash the state was built
    # against, and a Database Hash this Walk reads replaces it. The state's
    # 0x2B2A value, once read, is never read again (Requirement 17.3), and
    # Requirement 4.8's "the Database Hash read most recently in that Walk",
    # for a resumed Walk, includes the reads of the Walk it continues: without
    # the seed, a resumed Walk ending finished would clear the hash the
    # Gatt_Tracker's next Plan.hash_check needs. hash_changed stays false: the
    # Walk that read the changed hash reported it.
    #
    # A read task with offset > 0 (only the head of the worklist can be one)
    # is a Read Blob in progress whose bytes were collected at the earlier
    # Walk's ATT_MTU; it is flagged carried so run_read_step may re-read it
    # from the start once if this Walk's larger ATT_MTU makes the server
    # answer 0x0B (Requirement 7.19). The flag is set on the copy: the
    # Gatt_Tracker's Resume_State is left as it is, and a Walk that resumes
    # it later flags the task again for itself.
    def adopt_resume_state
      @state         = @plan.state.deep_dup
      @database_hash = @state.database_hash
      @state.reads.each { |task| task.carried = true if task.offset.positive? }
    end

    # The WalkState this Walk works through, or the Walk_Outcome that ends it
    # before discovery starts. A resumed Walk's is the copy run adopted at its
    # entry, and it reads no Database Hash first (Requirement 17.3: after the
    # exchange, only the outstanding procedures and reads).
    def plan_state
      case @plan.kind
      when :full       then WalkState.fresh
      when :resume     then @state
      when :hash_check then hash_check_state
      else raise ArgumentError, "unknown plan kind #{@plan.kind.inspect}"
      end
    end

    # Requirements 4.4 to 4.6, after run's one exchange_mtu. :unchanged ends
    # the Walk with no further request (run finishes it unchanged with no
    # WalkState, so nothing is rendered or kept). A changed hash starts a fresh
    # WalkState built against the new hash and sets @hash_changed (Requirement
    # 17.6); an unreadable one starts a fresh WalkState with no hash, recording
    # none. Either way the full Walk continues on this bearer and nothing here
    # sends a second Exchange MTU Request. :timeout and :disconnected from the
    # hash read end the Walk like any other request's (Requirements 3.4, 6.10):
    # after an unanswered request nothing more may be sent.
    #
    # The fresh WalkState still makes first_primary_request? true for the
    # Walk's first discovery request, as the plan is not a resume: a hash check
    # that falls through is a full Walk, Requirement 6.7 included.
    def hash_check_state
      check = read_database_hash(@plan.expected_hash)
      case check
      when *INTERRUPTED_OUTCOMES then check
      when :unchanged
        @database_hash = @plan.expected_hash
        check
      when :unavailable then WalkState.fresh
      when Array
        _changed, hash = check
        @hash_changed = true
        WalkState.fresh.tap { |state| record_database_hash(state, hash) }
      else raise ArgumentError, "read_database_hash returned #{check.inspect}"
      end
    end

    # The one place a Database Hash read in this Walk is recorded: the changed
    # hash of a hash check (hash_check_state), and the value of a 0x2B2A
    # Identity_Set read that complete_read decodes during the Walk. +hex+ is
    # ValueDecoder.decode_identity's 0x2B2A rendering in both, so the report,
    # the Gatt_Tracker's record and the next Plan.hash_check's expected value
    # compare like for like. Later reads replace earlier ones: the report
    # carries the hash read most recently (Requirement 4.8), and +state+, the
    # WalkState being built, is tagged with the hash it was built against.
    def record_database_hash(state, hex)
      @database_hash = hex
      state.database_hash = hex
    end

    # Close the bearer, then build the report: Requirement 5.6 has the bearer
    # closed before the Gatt_Scanner counts the outcome, and it counts from the
    # report. A Walk ending timeout comes here straight from the wait that
    # ran out, having sent nothing since, so its bearer closes at once, well
    # inside Requirement 3.4's 1 s. ended_at is read before rendering, so the
    # Walk's duration ends at the close (Requirement 13.6).
    #
    # The report is rendered for every outcome. Only a Walk ending in error
    # can have discovered anything and still deliver no result, and its
    # counts go on the Requirement 13.6 line all the same.
    def finish(outcome)
      raise ArgumentError, "unknown Walk_Outcome #{outcome.inspect}" unless OUTCOMES.include?(outcome)

      close_bearer
      ended_at = @clock.now
      interrupted = interrupted?(outcome)
      services, characteristics, identity = rendered_results
      WalkReport.new(
        address:         @address,
        outcome:         outcome,
        resumed:         @plan.resume?,
        started_at:      @started_at,
        ended_at:        ended_at,
        mtu:             @mtu_response_seen ? @mtu : DEFAULT_MTU,
        requests_sent:   @requests_sent,
        services:        services,
        characteristics: characteristics,
        identity:        identity,
        database_hash:   @database_hash,
        hash_changed:    @hash_changed,
        state:           interrupted ? @state : nil,
        outstanding:     outstanding_work(interrupted ? @state : nil),
        handoff_lag:     @handoff_lag
      )
    end

    # [services, characteristics, identity] in their WalkReport form, from
    # @state; all three empty when the Walk built no WalkState (a fresh or
    # hash-check Walk that ended in bearer setup, the exchange or the hash
    # check). A resumed Walk always has one (adopt_resume_state).
    #
    # Each distinct UUID is rendered once per role per report, so name-unknown
    # counts an unnamed UUID once for each result it appears in rather than
    # once for every entry repeating it: a service's UUID is in each of its
    # characteristics' entries.
    def rendered_results
      return [[], [], {}] if @state.nil?

      names  = {}
      render = ->(role, uuid) { uuid && (names[[role, uuid]] ||= UuidNames.render(role, uuid)) }
      services = @state.services.map do |service|
        { uuid: render.(:service, service[:uuid]), type: service[:type].to_s, start: service[:start],
          end: service[:end],
          includes: service[:includes].map do |inc|
            { uuid: render.(:service, inc[:uuid]), start: inc[:start], end: inc[:end] }
          end }
      end
      [services, rendered_characteristics(services, render), identity_values]
    end

    # The gatt_characteristics entries, ascending value_handle.
    #
    # GattCharacteristics refuses a list with a value_handle outside
    # 0x0001..0xFFFF or one shared by two entries, as no GATT database can
    # hold either. The value handle comes from the peer's declaration, which
    # nothing else checks, so a peer can send either; such entries are left
    # out here, the first discovered of a shared handle kept, and one debug
    # line counts them. The Walk_Outcome is already decided by then.
    def rendered_characteristics(services, render)
      kept    = {}
      dropped = 0
      @state.characteristics.each do |char|
        handle = char.value_handle
        if handle < FIRST_HANDLE || kept.key?(handle)
          dropped += 1
        else
          kept[handle] = characteristic_entry(char, services.fetch(char.service_index), render)
        end
      end
      if dropped > 0
        BlueHydra.logger.debug(
          "gatt: #{@address} #{dropped} characteristic(s) left out of the result: value handle 0x0000 or repeated"
        )
      end
      kept.keys.sort.map { |handle| kept[handle] }
    end

    # +char+ as a gatt_characteristics entry (design entry schema,
    # Requirement 11.10), +service+ being its rendered service. Every UUID is
    # Uuid_Formatter output (Requirement 10.9); keys follow
    # GattCharacteristics::KEY_ORDER.
    #
    # A nil read_status is "not-read": no read of it ever finished, whether
    # it was still pending when the Walk was cut short or is a readable
    # characteristic outside the Identity_Set with read_all false
    # (Requirement 7.4), and "not-read" is the Read_Status of a readable
    # characteristic deliberately left unread (7.6).
    #
    # A read entry carries value and value_encoding even when the value is
    # nil, which is an Identity_Set string empty once stripped, carried as
    # no value (Requirement 7.10): read_status "read" is what says the read
    # succeeded, and the schema has both keys exactly on read entries.
    # raw_hex is the decoder's (ValueDecoder::Decoded#raw_hex), present for a
    # decoded non-identity value only.
    def characteristic_entry(char, service, render)
      status = char.read_status || :"not-read"
      entry = {
        uuid:             render.(:characteristic, char.uuid),
        service_uuid:     service[:uuid],
        service_type:     service[:type],
        service_start:    service[:start],
        service_end:      service[:end],
        service_includes: service[:includes].map(&:dup),
        decl_handle:      char.decl_handle,
        value_handle:     char.value_handle,
        properties:       PROPERTY_NAMES.filter_map { |bit, name| name if char.properties.anybits?(bit) },
        descriptors:      char.descriptors.map { |handle, uuid| { uuid: render.(:descriptor, uuid), handle: handle } },
        read_status:      status.to_s
      }
      entry[:error_code] = char.error_code if ERROR_CODE_STATUSES.include?(status)
      if status == :read
        entry[:value]          = char.decoded.value
        entry[:value_encoding] = char.decoded.encoding
        entry[:raw_hex]        = char.decoded.raw_hex if char.decoded.raw_hex
      end
      entry
    end

    # IDENTITY_SET key => value for every Identity_Set characteristic read
    # with a value. Malformed values (Requirement 7.13) and strings empty
    # once stripped (7.10) carry none, so they are absent and the Device
    # leaves those Gatt_Columns as they are (11.15). Of several instances of
    # one Identity_Set UUID only one is ever read (Requirement 7.6).
    def identity_values
      @state.characteristics.each_with_object({}) do |char, identity|
        next unless char.read_status == :read && (uuid = identity_uuid(char))
        value = char.decoded.value
        identity[IDENTITY_SET.fetch(uuid)] = value unless value.nil?
      end
    end

    # WalkReport#outstanding for +state+, nil giving empty lists.
    def outstanding_work(state)
      return { procedures: [], reads: [] } if state.nil?

      {
        procedures: state.procedures.map do |procedure|
          { kind: procedure.kind, start: procedure.start, end: procedure.end, next: procedure.next }
        end,
        reads: state.reads.map do |task|
          { kind: task.kind, value_handle: state.characteristics.fetch(task.char_index).value_handle }
        end
      }
    end

    def interrupted?(result)
      INTERRUPTED_OUTCOMES.include?(result)
    end

    # Seconds of Walk_Bound left; zero or negative once it has expired.
    def remaining
      @deadline - @clock.now
    end

    # The socket the Att_Bearer wraps; specs replace it with a fake.
    #
    # SOCK_SEQPACKET, unlike LeConnect's SOCK_RAW: l2cap_sock_init gives it
    # BASIC mode (it picks ERTM only for SOCK_STREAM) and BT_SECURITY_LOW
    # (net/bluetooth/l2cap_sock.c), and it keeps datagram boundaries, so each
    # recv is one ATT PDU. Bearer#bind turns it into the fixed ATT channel.
    def open_socket
      Socket.new(BlueHydra::Mgmt::AF_BLUETOOTH, Socket::SOCK_SEQPACKET, Bearer::BTPROTO_L2CAP)
    end

    # The Walk's one Exchange MTU Request, sent once per Att_Bearer by run.
    # Returns the ATT_MTU now in use, or :timeout / :disconnected from
    # transact. Sets @mtu and @mtu_response_seen.
    #
    # ATT_MTU is the smallest of our Client Rx MTU, the peer's Server Rx MTU
    # and the Client Rx MTU of any Exchange MTU Request the peer has sent
    # (cap_mtu), floored at DEFAULT_MTU: a Server Rx MTU below 23 is a peer
    # error (Core 6.3 Vol 3 Part F 3.4.2.2), and 23 is what every LE ATT
    # bearer supports without negotiation. An Error Response naming the
    # request (Requirement 5.8), a Malformed or any other response leaves the
    # bearer unnegotiated, i.e. at 23, and one debug line says which it was.
    def exchange_mtu
      request  = AttCodec::ExchangeMtuRequest.new(mtu: CLIENT_RX_MTU)
      response = transact(request)
      return response if interrupted?(response)

      @mtu_response_seen = response.is_a?(AttCodec::ExchangeMtuResponse)
      if @mtu_response_seen
        @mtu = [[CLIENT_RX_MTU, response.mtu, @peer_client_rx_mtu || CLIENT_RX_MTU].min, DEFAULT_MTU].max
      else
        reason =
          if error_response_to?(response, request)
            format("Error Response 0x%02x", response.error_code)
          else
            mismatch_reason(response)
          end
        BlueHydra.logger.debug("gatt: #{@address} Exchange MTU not negotiated (#{reason}): ATT_MTU #{DEFAULT_MTU}")
        @mtu = DEFAULT_MTU
      end
    end

    # One client request. Returns the decoded response PDU (whatever response
    # opcode arrived, a Malformed included), :timeout or :disconnected.
    # @requests_sent counts each request put on the bearer, and nothing else.
    #
    # The caller matches a response to its request, the same way in every
    # caller: the response the request expects is accepted; an Error Response
    # whose Request Opcode is the request's (error_response_to?) is that
    # request's error outcome; anything else, a Malformed, another response
    # opcode, or an Error Response naming some other request, is mismatched.
    #
    # stopping is checked before the send so that nothing goes on the bearer
    # once shutdown has begun (Requirement 14.6). The wait for the response is
    # bounded by whichever comes first, Walk_Bound or the ATT transaction
    # timeout, and every PDU the peer sends in the meantime counts against
    # that same bound (Requirement 3.5): a peer that keeps sending requests or
    # notifications cannot keep the Walk alive.
    #
    # ATT has one outstanding request per direction (Core 6.3 Vol 3 Part F
    # 3.3.2), so a PDU that is not a response is the peer acting as client or
    # server on its own account, never the answer to ours. serve_peer_pdu
    # answers it, and the request stays pending on the same wait_until,
    # neither resent nor answered by it (Requirement 8.10). The Walk thread is
    # always in this wait while a request is outstanding and sends its next
    # request as soon as a response is in, so a peer PDU is read, and
    # answered, as soon as it arrives (Requirement 8.6).
    def transact(request_pdu)
      return :disconnected if @stopping.call
      return :timeout if @transaction_timed_out || remaining <= 0

      att_bearer = bearer
      return :disconnected unless att_bearer.send_pdu(AttCodec.encode(request_pdu)) == :ok
      @requests_sent += 1

      sent_at    = @clock.now
      att_bound  = sent_at + ATT_TRANSACTION_TIMEOUT < @deadline
      wait_until = att_bound ? sent_at + ATT_TRANSACTION_TIMEOUT : @deadline
      loop do
        left = wait_until - @clock.now
        return request_unanswered(request_pdu, sent_at, att_bound) if left <= 0

        raw = att_bearer.recv_pdu(left)
        return request_unanswered(request_pdu, sent_at, att_bound) if raw == :timeout
        return :disconnected if raw == :disconnected

        # recv_pdu never returns an empty PDU, so there is always an opcode.
        opcode  = raw.getbyte(0)
        decoded = AttCodec.decode(raw)
        return decoded if AttCodec.response_opcode?(opcode)
        return :disconnected if serve_peer_pdu(att_bearer, decoded, opcode) == :disconnected
      end
    end

    # Whether +response+ is an Error Response naming +request+: the request's
    # own error outcome, as opposed to a mismatched PDU.
    def error_response_to?(response, request)
      response.is_a?(AttCodec::ErrorResponse) && response.request_opcode == AttCodec.opcode_of(request)
    end

    # The request transact sent got no response before its wait ended. From
    # then on transact refuses to send: the peer may still answer that
    # request, and a new one would be a second outstanding request
    # (Core 6.3 Vol 3 Part F 3.3.2); once 30 s have passed it is a
    # transaction timeout, after which nothing more may be sent on the bearer
    # at all (3.3.3). run then finishes the Walk as timeout.
    #
    # The debug line names which bound ended the wait, which the timeout
    # outcome alone does not say.
    def request_unanswered(request_pdu, sent_at, att_bound)
      @transaction_timed_out = true
      BlueHydra.logger.debug(
        format("gatt: %s no response to opcode 0x%02x after %.2fs: %s", @address,
               AttCodec.opcode_of(request_pdu), @clock.now - sent_at,
               att_bound ? "ATT transaction timeout" : "Walk_Bound expired")
      )
      :timeout
    end

    # A PDU that arrived during transact's wait and is not a response: a peer
    # request, command, notification, indication or confirmation. +decoded+ is
    # AttCodec.decode's result for it (a Malformed included), +opcode+ its
    # first octet. Returns :ok, or :disconnected when sending the reply found
    # the Link gone, which ends transact the same way.
    #
    # The Att_Server decides the reply (Requirements 8.1 to 8.5, 8.8). An
    # Exchange MTU Request caps ATT_MTU at its Client Rx MTU (Requirement
    # 8.9). A reply goes out on the bearer unless shutdown has begun
    # (Requirement 14.6), and each one sent, a Handle Value Confirmation
    # included, is reported through on_peer_request for the peer-req counter
    # (Requirement 8.7). Replies are not client requests: @requests_sent does
    # not count them, and they are sent while the client request is still
    # outstanding, which ATT allows, as the two are in opposite directions.
    def serve_peer_pdu(att_bearer, decoded, opcode)
      reply, event, client_rx_mtu = @att_server.handle(decoded, opcode)
      cap_mtu(client_rx_mtu) if event == :mtu_request
      return :ok if reply.nil? || @stopping.call
      return :disconnected unless att_bearer.send_pdu(AttCodec.encode(reply)) == :ok

      @on_peer_request.call
      :ok
    end

    # Caps ATT_MTU at a peer's Client Rx MTU, floored at DEFAULT_MTU, for the
    # rest of the Walk (Requirement 8.9). Before exchange_mtu has an answer
    # the cap is kept and applied there; after, it lowers @mtu directly. The
    # lowest Client Rx MTU the peer has sent is the one kept.
    def cap_mtu(peer_client_rx_mtu)
      floored = [peer_client_rx_mtu, DEFAULT_MTU].max
      @peer_client_rx_mtu = [@peer_client_rx_mtu, floored].compact.min
      @mtu = [@mtu, @peer_client_rx_mtu].min if @mtu
    end

    # The hash check's one request (Requirement 4.4): Read By Type 0x2B2A over
    # the whole handle range. Returns
    #   :unchanged          a 16-octet value equal to +expected+
    #   [:changed, hex]     a 16-octet value that differs, as hex
    #   :unavailable        an Error Response of any code (0x0A for a database
    #                       with no Database Hash, a Security_Error, anything),
    #                       a Malformed or mismatched PDU, or a value that is
    #                       not 16 octets (Requirement 4.6)
    #   :timeout, :disconnected  from transact, untouched
    #
    # +expected+ is a WalkReport#database_hash a previous Walk reported, so the
    # value read is rendered the same way, through ValueDecoder.decode_identity
    # (lowercase hex in received byte order, :malformed unless 16 octets), and
    # equal strings are equal octets.
    #
    # A database may hold more than one Database Hash characteristic; the one
    # with the lowest handle is used (Requirement 4.4). Every entry of a Read
    # By Type Response has the length its length octet gives, so its value
    # length is the page's. At the smallest ATT_MTU, 23, an entry holds up to
    # 19 value octets (Core 6.3 Vol 3 Part F 3.4.4.2), so a 16-octet hash is
    # never cut short and a longer value never passes as 16.
    #
    # One debug line says why a hash check fell through to a full Walk.
    def read_database_hash(expected)
      request  = AttCodec::ReadByTypeRequest.new(start_handle: FIRST_HANDLE, end_handle: LAST_HANDLE,
                                                 uuid: DATABASE_HASH_TYPE)
      response = transact(request)
      return response if interrupted?(response)

      unless response.is_a?(AttCodec::ReadByTypeResponse)
        reason =
          if error_response_to?(response, request)
            format("Error Response 0x%02x", response.error_code)
          else
            mismatch_reason(response)
          end
        return database_hash_unavailable(reason)
      end

      handle, value = response.entries.min_by(&:first)
      hex = ValueDecoder.decode_identity(DATABASE_HASH, value)
      if hex == :malformed
        return database_hash_unavailable(format("value at 0x%04x is %d octets, not 16", handle, value.bytesize))
      end
      return :unchanged if hex == expected

      BlueHydra.logger.debug("gatt: #{@address} Database Hash changed from #{expected} to #{hex}: full Walk")
      [:changed, hex]
    end

    def database_hash_unavailable(reason)
      BlueHydra.logger.debug("gatt: #{@address} Database Hash unavailable (#{reason}): full Walk")
      :unavailable
    end

    # One page of +procedure+, the head of @state.procedures. Returns
    # :continue, or transact's :timeout / :disconnected with the procedure
    # untouched, so a resumed Walk asks for that page again and run's finish
    # reports the interruption rather than partial (Requirement 6.13).
    #
    # Each procedure is one GATT discovery sub-procedure (Core 6.3 Vol 3 Part
    # G 4.4.1, 4.5.1, 4.6.1, 4.7.1), and the answer to a page is handled the
    # same way in all four:
    # - A page with sane handles is recorded. The procedure then ends normally
    #   when the page's last handle (the last End Group Handle for Read By
    #   Group Type) has reached the range end, and otherwise asks again from
    #   that handle + 1 (Requirements 6.4, 6.12). Those are the sub-procedures'
    #   own completion and continuation rules.
    # - Error Response 0x0A naming this request ends the procedure normally, on
    #   its first page or any later one (Requirement 6.4).
    # - Error Response 0x10 Unsupported Group Type naming a :secondary request
    #   ends that procedure normally too, the Walk no less complete for it
    #   (Requirement 6.4; see UNSUPPORTED_GROUP_TYPE). On any other procedure
    #   it is an Error Response like any other, below.
    # - A Security_Error to the first primary-service request of a fresh Walk
    #   sets @state.protected_root and leaves the worklist as it is; run ends
    #   the Walk protected with nothing more sent (Requirement 6.7). 4.4.1
    #   says a service declaration needs no authentication, so a peer refusing
    #   it is withholding its whole database until paired, which this Walk
    #   never does.
    # - Anything else discards the page and ends the procedure partial,
    #   keeping what earlier pages found (Requirements 6.5, 6.6): insane
    #   handles, a declaration value no declaration can have, any other Error
    #   Response (a later Security_Error included), a Malformed, or a response
    #   that answers some other request.
    def run_procedure_page(procedure)
      request  = request_for(procedure)
      response = transact(request)
      return response if interrupted?(response)

      if response.is_a?(PAGE_RESPONSES.fetch(procedure.kind))
        entries = page_entries(procedure, response)
        if entries.nil?
          end_procedure(procedure, partial: "declaration of a length no declaration has")
        elsif !handles_sane?(procedure, entries)
          end_procedure(procedure, partial: "handles out of order or out of range")
        else
          record(procedure, entries)
          last = last_handle(procedure, entries)
          if last >= procedure.end
            end_procedure(procedure)
          else
            procedure.next = last + 1
          end
        end
      elsif error_response_to?(response, request)
        code = response.error_code
        if code == ATTRIBUTE_NOT_FOUND
          end_procedure(procedure)
        elsif code == UNSUPPORTED_GROUP_TYPE && procedure.kind == :secondary
          end_procedure(procedure)
        elsif SECURITY_ERRORS.include?(code) && first_primary_request?(procedure)
          @state.protected_root = true
        else
          end_procedure(procedure, partial: format("Error Response 0x%02x", code))
        end
      else
        end_procedure(procedure, partial: mismatch_reason(response))
      end
      :continue
    end

    # The request for +procedure+'s next page, over next..end: 0xFFFF for the
    # service procedures, the service's end group handle for :includes and
    # :characteristics, the descriptor range's end for :descriptors.
    def request_for(procedure)
      case procedure.kind
      when :primary, :secondary
        AttCodec::ReadByGroupTypeRequest.new(start_handle: procedure.next, end_handle: procedure.end,
                                             uuid: DISCOVERY_TYPES.fetch(procedure.kind))
      when :includes, :characteristics
        AttCodec::ReadByTypeRequest.new(start_handle: procedure.next, end_handle: procedure.end,
                                        uuid: DISCOVERY_TYPES.fetch(procedure.kind))
      when :descriptors
        AttCodec::FindInformationRequest.new(start_handle: procedure.next, end_handle: procedure.end)
      else
        raise ArgumentError, "unknown discovery procedure #{procedure.kind.inspect}"
      end
    end

    # A page's entries in the form record takes: [handle, end_group, Uuid]
    # for the service procedures, [handle, Uuid] for :descriptors, and
    # [handle, IncludeDeclaration | CharacteristicDeclaration] for the Read By
    # Type procedures. nil when a declaration value is a length the Att_Codec
    # rejects (an include is 4 or 6 octets, a characteristic 5 or 19); every
    # value in one Read By Type Response has the length its length octet
    # gives, so one bad value means the whole page is.
    def page_entries(procedure, response)
      case procedure.kind
      when :includes
        decode_declarations(response) { |value| AttCodec.decode_include_declaration(value) }
      when :characteristics
        decode_declarations(response) { |value| AttCodec.decode_characteristic_declaration(value) }
      else
        response.entries
      end
    end

    def decode_declarations(response)
      entries = response.entries.map { |handle, value| [handle, yield(value)] }
      entries.any? { |_handle, declaration| declaration.is_a?(AttCodec::Malformed) } ? nil : entries
    end

    # Requirement 6.5: handles strictly increase, all fall within next..end,
    # and no End Group Handle is below its own service's handle. The codec
    # never yields an empty page, so first and last exist. These checks are
    # also what makes every procedure terminate: each recorded page moves next
    # past the handle it started from.
    def handles_sane?(procedure, entries)
      handles = entries.map(&:first)
      return false unless handles.each_cons(2).all? { |earlier, later| later > earlier }
      return false unless handles.first >= procedure.next && handles.last <= procedure.end
      return true unless SERVICE_KINDS.include?(procedure.kind)
      entries.all? { |handle, end_group, _uuid| end_group >= handle }
    end

    def last_handle(procedure, entries)
      SERVICE_KINDS.include?(procedure.kind) ? entries.last[1] : entries.last[0]
    end

    # Adds a sane page's attributes to @state.
    def record(procedure, entries)
      case procedure.kind
      when :primary, :secondary
        # Secondary services are found after every primary one but may sit
        # between them, so each is inserted at its place in start order.
        # Nothing refers to a service by index until both service procedures
        # have ended (queue_service_procedures), so inserting is safe.
        entries.each do |handle, end_group, uuid|
          at = @state.services.bsearch_index { |service| service[:start] > handle } || @state.services.size
          @state.services.insert(at, { uuid: uuid, type: procedure.kind, start: handle, end: end_group, includes: [] })
        end
      when :includes
        includes = @state.services.fetch(procedure.service_index)[:includes]
        entries.each do |_handle, declaration|
          includes << { start: declaration.start_handle, end: declaration.end_handle,
                        uuid: declaration.uuid || discovered_service_uuid(declaration.start_handle) }
        end
      when :characteristics
        entries.each do |handle, declaration|
          @state.characteristics << CharRecord.new(
            service_index: procedure.service_index, decl_handle: handle, value_handle: declaration.value_handle,
            properties: declaration.properties, uuid: declaration.uuid, descriptors: []
          )
        end
      when :descriptors
        @state.characteristics.fetch(procedure.char_index).descriptors
              .concat(entries.map { |handle, uuid| [handle, uuid] })
      end
    end

    # The UUID of a 4-octet include, which carries none because the included
    # service's UUID is 128-bit (Core 6.3 Vol 3 Part G 3.2). 4.5.1 would have
    # the client Read the included service's declaration for it; Requirement
    # 7.2 allows no such Read, and every service is already known by the time
    # includes are discovered, so it is the UUID of the discovered service
    # starting at that handle, or nil when there is none (Requirement 6.2).
    def discovered_service_uuid(start_handle)
      @state.services.find { |service| service[:start] == start_handle }&.fetch(:uuid)
    end

    # Removes +procedure+, the head of the worklist, and queues the procedures
    # its end makes possible. One ended partial (+partial+ the reason, logged
    # at debug) marks the Walk partial and still queues them, from what its
    # earlier pages found (Requirements 6.5, 6.6).
    #
    # Includes and characteristics wait for both service procedures because a
    # 4-octet include is resolved against the full service list; descriptor
    # ranges wait for their service's characteristics because each ends at the
    # next characteristic declaration.
    def end_procedure(procedure, partial: nil)
      unless @state.procedures.first.equal?(procedure)
        raise ArgumentError, "end_procedure: the #{procedure.kind} procedure is not the head of the worklist"
      end
      @state.procedures.shift

      if partial
        @state.partial = true
        BlueHydra.logger.debug(
          format("gatt: %s %s discovery 0x%04x..0x%04x ended partial at 0x%04x: %s", @address, procedure.kind,
                 procedure.start, procedure.end, procedure.next, partial)
        )
      end

      case procedure.kind
      when :primary, :secondary
        queue_service_procedures if @state.procedures.none? { |queued| SERVICE_KINDS.include?(queued.kind) }
      when :characteristics
        queue_descriptor_procedures(procedure.service_index)
      end
    end

    # Requirement 6.2: for each service in ascending start order, its includes
    # then its characteristics, both over start..end group handle. A service
    # of one handle still gets both; the server answers each with 0x0A.
    def queue_service_procedures
      @state.services.each_with_index do |service, index|
        %i[includes characteristics].each do |kind|
          @state.procedures << Procedure.new(kind: kind, start: service[:start], end: service[:end],
                                             next: service[:start], service_index: index)
        end
      end
    end

    # Requirement 6.3: a characteristic's descriptors lie from its value handle
    # + 1 to the handle before the service's next characteristic declaration,
    # or to the service end for the last one (Core 6.3 Vol 3 Part G 4.7.1).
    # An empty range, which is the usual case, gets no request.
    def queue_descriptor_procedures(service_index)
      service_end = @state.services.fetch(service_index)[:end]
      owned = @state.characteristics.each_index.select do |index|
        @state.characteristics[index].service_index == service_index
      end
      owned.each_with_index do |char_index, position|
        following = owned[position + 1]
        range_start = @state.characteristics[char_index].value_handle + 1
        range_end   = following ? @state.characteristics[following].decl_handle - 1 : service_end
        next if range_start > range_end

        @state.procedures << Procedure.new(kind: :descriptors, start: range_start, end: range_end, next: range_start,
                                           service_index: service_index, char_index: char_index)
      end
    end

    # Requirement 6.7's "first primary-service request of a full Walk". Until
    # that request is answered the primary procedure is still at 0x0001 with
    # no service found: a page would have moved next or ended it, and an
    # interruption would have ended the Walk. A resumed Walk never qualifies:
    # its first request continues a Walk that has already begun. A hash check
    # that fell through to a full Walk does: its WalkState is fresh, and the
    # Database Hash read before it is not a discovery request.
    def first_primary_request?(procedure)
      !@plan.resume? && procedure.kind == :primary && procedure.next == FIRST_HANDLE && @state.services.empty?
    end

    # For the debug line of a request answered with a mismatched PDU: neither
    # the response it expects nor an Error Response naming it.
    def mismatch_reason(response)
      case response
      when AttCodec::Malformed
        "malformed response (#{response.reason})"
      when AttCodec::ErrorResponse
        format("Error Response 0x%02x naming opcode 0x%02x", response.error_code, response.request_opcode)
      else
        format("mismatched response opcode 0x%02x", AttCodec.opcode_of(response))
      end
    end

    # Fills @state.reads and sets @state.reads_generated, once, after the last
    # discovery procedure has ended. Sends nothing; the reads run off the head
    # of the list in run_read_step.
    #
    # Identity_Set reads come first, in IDENTITY_SET order, so a Walk cut off
    # by Walk_Bound after discovery still has the identity values. Of several
    # instances of one Identity_Set UUID only the readable one with the lowest
    # value handle is read; the other readable ones are not-read
    # (Requirement 7.6). A characteristic without the Read property is
    # not-readable wherever it is (Requirement 7.5), duplicate instances
    # included, and nothing is ever sent to it.
    #
    # With read_all every other readable characteristic follows in ascending
    # value-handle order (Requirement 7.3), each preceded by a read of its
    # 0x2904 descriptor when one was discovered in its range (Requirement
    # 7.14), so its value can be decoded with that format. Core 6.3 Vol 3 Part
    # G 3.3.3.5 allows several 0x2904s only beside an Aggregate Format, which
    # this does not decode; the lowest-handle one is read. Without read_all no
    # request goes to any characteristic outside the Identity_Set
    # (Requirements 1.8, 7.4), and a readable one keeps a nil read_status.
    def generate_reads
      chars = @state.characteristics
      identity_indices = []

      IDENTITY_SET.each_key do |identity|
        instances = chars.each_index.select { |index| identity_uuid(chars[index]) == identity }
        identity_indices.concat(instances)
        chosen = instances.select { |index| readable?(chars[index]) }
                          .min_by { |index| [chars[index].value_handle, index] }
        instances.each do |index|
          next if index == chosen
          chars[index].read_status = readable?(chars[index]) ? :"not-read" : :"not-readable"
        end
        @state.reads << new_read_task(:identity, chars[chosen].value_handle, chosen) if chosen
      end

      # Sorted rather than trusting discovery order: a peer whose services
      # overlap can hand characteristics over out of value-handle order.
      others = (chars.each_index.to_a - identity_indices).sort_by { |index| [chars[index].value_handle, index] }
      others.each do |index|
        char = chars[index]
        if !readable?(char)
          char.read_status = :"not-readable"
        elsif @read_all
          format_handle, _uuid = char.descriptors.find { |_handle, uuid| uuid16_of(uuid) == PRESENTATION_FORMAT }
          @state.reads << new_read_task(:presentation_format, format_handle, index) if format_handle
          @state.reads << new_read_task(:value, char.value_handle, index)
        end
      end

      @state.reads_generated = true
    end

    def new_read_task(kind, handle, char_index)
      ReadTask.new(kind: kind, handle: handle, char_index: char_index, offset: 0, collected: String.new,
                   carried: false, restarted: false)
    end

    # One Read or Read Blob Request for +task+, the head of @state.reads
    # (Requirement 7.1). Returns :continue, or transact's :timeout /
    # :disconnected with the task left at the head, offset and collected bytes
    # as they were, so a resumed Walk asks for that same part again.
    #
    # The opening request is a Read; each response carrying exactly
    # ATT_MTU - 1 octets with fewer than MAX_VALUE_BYTES collected is followed
    # by a Read Blob at the collected offset. Anything else ends the read:
    # - A shorter part, or MAX_VALUE_BYTES reached: the value is the bytes
    #   collected, cut at MAX_VALUE_BYTES.
    # - 0x0B Attribute Not Long or 0x07 Invalid Offset to a Read Blob: the
    #   value is the bytes collected so far. One exception, Requirement 7.19:
    #   0x0B to a Read Blob the task carried over from an interrupted Walk
    #   (ReadTask#carried), with fewer than ATT_MTU - 1 octets collected and
    #   no re-read used yet, means this Walk's ATT_MTU is larger than the one
    #   those octets came in at and the server no longer sees the value as
    #   long. The octets are dropped, offset goes back to 0, restarted is set
    #   and the task stays at the head, so the next step reads the value
    #   again from the start with a Read Request; a second 0x0B ends it with
    #   whatever that re-read collected.
    # - A Security_Error: protected with its code, bytes dropped (Requirement
    #   7.8). It never makes the Walk partial (Requirement 6.8).
    # - Any other Error Response naming this request: error with its code,
    #   bytes dropped (Requirement 7.9).
    # - A Malformed or any other response: error with no code, bytes dropped.
    # Of those failures only an Identity_Set read's error marks the Walk
    # partial (Requirement 6.9); a read of any other value is recorded on its
    # characteristic and nothing more. A failed 0x2904 read is not recorded at
    # all: the value read after it still runs and decodes without a format.
    #
    # ATT_MTU is read afresh each step, so a peer's Exchange MTU Request that
    # lowers it mid-value (Requirement 8.9) moves the full-part length with it.
    def run_read_step(task)
      request =
        if task.offset.zero?
          AttCodec::ReadRequest.new(handle: task.handle)
        else
          AttCodec::ReadBlobRequest.new(handle: task.handle, offset: task.offset)
        end
      response = transact(request)
      return response if interrupted?(response)

      expected = request.is_a?(AttCodec::ReadRequest) ? AttCodec::ReadResponse : AttCodec::ReadBlobResponse
      if response.is_a?(expected)
        part = response.value
        task.collected << part
        if part.bytesize == (@mtu || DEFAULT_MTU) - 1 && task.collected.bytesize < MAX_VALUE_BYTES
          task.offset = task.collected.bytesize
          return :continue
        end
        complete_read(task, task.collected.byteslice(0, MAX_VALUE_BYTES))
      elsif error_response_to?(response, request)
        code = response.error_code
        if request.is_a?(AttCodec::ReadBlobRequest) && code == ATTRIBUTE_NOT_LONG && carried_blob_rereadable?(task)
          restart_carried_read(task)
          return :continue
        elsif request.is_a?(AttCodec::ReadBlobRequest) && READ_BLOB_END_ERRORS.include?(code)
          complete_read(task, task.collected.byteslice(0, MAX_VALUE_BYTES))
        elsif SECURITY_ERRORS.include?(code)
          read_failed(task, :protected, code, format("Error Response 0x%02x", code))
        else
          read_failed(task, :error, code, format("Error Response 0x%02x", code))
        end
      else
        read_failed(task, :error, nil, mismatch_reason(response))
      end
      end_read(task)
      :continue
    end

    # Records the value +bytes+ of a finished read on +task+'s characteristic.
    #   :presentation_format  the parsed 0x2904, nil unless 7 octets, which
    #                         the value read queued after it decodes with
    #   :identity             ValueDecoder.decode_identity. A fixed-size value
    #                         of the wrong length is malformed and carries no
    #                         value, leaving the Walk_Outcome as it is
    #                         (Requirement 7.13); a string empty once stripped
    #                         is read with no value (Requirement 7.10). A
    #                         Database Hash is recorded for the report and the
    #                         Gatt_Tracker (Requirement 4.8)
    #   :value                ValueDecoder.decode with the characteristic's
    #                         presentation format (Requirement 7.12)
    def complete_read(task, bytes)
      char = @state.characteristics.fetch(task.char_index)
      case task.kind
      when :presentation_format
        char.presentation_format = ValueDecoder.parse_presentation_format(bytes)
      when :identity
        uuid = identity_uuid(char)
        value = ValueDecoder.decode_identity(uuid, bytes)
        char.value_bytes = bytes
        if value == :malformed
          char.read_status = :malformed
          char.decoded = nil
          BlueHydra.logger.debug(
            format("gatt: %s identity 0x%04x at 0x%04x malformed: %d octets", @address, uuid, task.handle,
                   bytes.bytesize)
          )
        else
          char.read_status = :read
          char.decoded = ValueDecoder::Decoded.new(value: value, encoding: "identity", raw_hex: nil)
          record_database_hash(@state, value) if uuid == DATABASE_HASH
        end
      when :value
        char.read_status = :read
        char.value_bytes = bytes
        char.decoded = ValueDecoder.decode(char.uuid, bytes, presentation_format: char.presentation_format)
      else
        raise ArgumentError, "unknown read kind #{task.kind.inspect}"
      end
    end

    # Whether 0x0B to +task+'s Read Blob calls for the Requirement 7.19
    # re-read: the task was carried over from an interrupted Walk, has not
    # been re-read yet, and holds fewer octets than one full part at this
    # Walk's ATT_MTU. A server judges "long" against the current ATT_MTU
    # (Core 6.3 Vol 3 Part F 3.4.4.5), so that combination means the value
    # fits in one Read Response now and the collected octets are only the
    # start of it. A carried task that already holds a full part got it at
    # this ATT_MTU or a larger one, and its 0x0B is the ordinary end of the
    # value.
    def carried_blob_rereadable?(task)
      task.carried && !task.restarted && task.collected.bytesize < (@mtu || DEFAULT_MTU) - 1
    end

    # Drops what the carried-over Read Blob collected and puts +task+ back to
    # its opening Read Request, once (Requirement 7.19). The task stays at the
    # head of the worklist; the caller returns :continue without end_read.
    def restart_carried_read(task)
      BlueHydra.logger.debug(
        format("gatt: %s %s read at 0x%04x: 0x0B to the carried Read Blob at offset %d with ATT_MTU %d, " \
               "re-reading from the start", @address, task.kind, task.handle, task.offset, @mtu || DEFAULT_MTU)
      )
      task.collected = String.new
      task.offset    = 0
      task.restarted = true
    end

    # A read of +task+ ended with no value: +status+ (:protected or :error)
    # and +code+ (nil for a Malformed or mismatched PDU) on its
    # characteristic, any bytes collected for it dropped with the task. One
    # debug line says why.
    def read_failed(task, status, code, reason)
      if task.kind == :presentation_format
        BlueHydra.logger.debug(
          format("gatt: %s presentation format read at 0x%04x failed (%s): value decoded without one",
                 @address, task.handle, reason)
        )
        return
      end

      char = @state.characteristics.fetch(task.char_index)
      char.read_status = status
      char.error_code  = code
      char.value_bytes = nil
      char.decoded     = nil
      @state.partial = true if status == :error && task.kind == :identity
      BlueHydra.logger.debug(
        format("gatt: %s %s read at 0x%04x %s: %s", @address, task.kind, task.handle, status, reason)
      )
    end

    # Removes +task+, the head of the read worklist, once it has finished.
    def end_read(task)
      unless @state.reads.first.equal?(task)
        raise ArgumentError, "end_read: the read at 0x#{format('%04x', task.handle)} is not the head of the worklist"
      end
      @state.reads.shift
    end

    def readable?(char)
      char.properties.anybits?(READ_PROPERTY)
    end

    # The Identity_Set UUID +char+ carries, nil when it is not one.
    def identity_uuid(char)
      uuid = uuid16_of(char.uuid)
      uuid if IDENTITY_SET.key?(uuid)
    end

    # The 16-bit form of an AttCodec::Uuid: a 16-bit one, or a 128-bit one on
    # the Bluetooth Base UUID, which is the same UUID (Core 6.3 Vol 3 Part B
    # 2.5.1) and the form ValueDecoder folds too. nil for any other 128-bit
    # UUID.
    def uuid16_of(uuid)
      return uuid.hex.to_i(16) if uuid.bits == 16
      hex = uuid.hex
      hex[4, 4].to_i(16) if hex.length == 32 && hex.start_with?("0000") && hex.end_with?(ValueDecoder::BASE_UUID_TAIL)
    end
  end
end
