# Working on blue_hydra

Guidance for coding agents. `README.md` covers installation, configuration and
usage and is not repeated here. `TODO` is the real backlog: numbered open items
with design notes, measured evidence and cross-references. Read it before
changing anything, and update the item covering an area you change.

blue_hydra reads `btmon` output, parses devices out of it, and actively connects
to them for details `btmon` alone will not reveal, including a read-only walk of
each LE device's GATT database. It talks to the kernel directly through the
Bluetooth mgmt API, raw HCI and L2CAP sockets, not through the BlueZ userspace
tools. Much of the code exists because of a specific kernel behaviour measured
on a device; the comment at each such site says which, and the sections below
list the ones that are easiest to break.

## Threads and ownership

One direction, one thread per stage, queues between them. `Runner#start` wires
it up and the queue declarations name the direction:

```
btmon (PTY) -> raw_queue -> chunker -> chunk_queue -> parser -> result_queue -> result thread -> DB
```

Each piece of mutable state has exactly one writing thread. Keep it that way;
when another thread needs the data, pass it on a queue or copy it, do not reach
across.

| Thread | Owns (sole writer) | Must never |
|---|---|---|
| btmon | `raw_queue`; `BtmonHandler#enqueue` drops most messages here, which is where filtering belongs | |
| chunker | `chunk_queue`; groups messages into one chunk per device via `Chunker#starting_chunk?` | |
| parser | `result_queue`; `cui_status`, the operator's device table: rows via `update_cui_status`, GATT names via `drain_cui_names`, expired-row deletion via `prune_cui_status`, all after a chunk | touch the DB |
| result | the database, including the `gatt_*` columns | write `cui_status` (it sits behind DB writes and would delay the live table) |
| discovery | `auto_connect_list`, `le_pending`, `le_direct_pending`, the `Auto_Connect_Mirror`; the connect phases and controller resets | |
| `Mgmt` reader | the mgmt control socket, `connection_events`, the link-up set; runs the installed Device Connected callback | block waiting for a reply or issue a mgmt command from the callback (it is what delivers replies: deadlock) |
| `HciCommand` reader | raw HCI socket; Read Remote Version per LE handle | touch the DB |
| GATT walk threads (`GattScanner`) | one `Att_Bearer` each, `GattScanner` counters and `GattTracker` records under their mutexes | write anything but `result_queue` and `cui_name_queue`; touch `raw_queue`, `chunk_queue`, `cui_status` or the DB |
| CUI and file-API threads | nothing | write `cui_status`; they read a whole-Hash, whole-row `dup` (`CliUserInterface#cui_status`) |

Cross-thread state that is not a queue follows the `ConnectTracker` / `GattTracker`
pattern: one mutex, address-keyed, in memory only, forgotten when the device goes
offline. Policy state is deliberately not persisted; a stale strike or flag would
silently suppress a device that has since changed, and most of these addresses
are private ones that rotate.

Anything the `Mgmt` reader issues is fire-and-forget, which is why
`restart_discovery` cannot check its own status and `record_unawaited_completion`
exists to report it instead. The GATT handoff runs on the reader thread for the
same reason it must stay cheap: an unheld auto-connected LE link lives about 2 s,
and the discovery thread can be blocked for longer than that inside a synchronous
mgmt command.

## Kernel facts the code depends on

Verify against kernel source before changing any of these;
`git.kernel.org/.../plain/<path>` fetches fine. The comment at each site has the
detail.

- `Mgmt.status_label`: mgmt `0x0b` REJECTED is the kernel's catch-all refusal, not
  a permissions error (`0x14` is).
- `ensure_transports_enabled`: Start Discovery's address-type mask is validated
  against the *enabled* transports, and one disabled transport fails the whole
  request. `stop_discovery` must reuse the type discovery started with.
- `enable_powered_down`: `Set LE` works on a powered controller, `Set BR/EDR` needs
  the radio down.
- `Mgmt.discovery_on?`: Start Discovery answers `0x0a` BUSY when discovery is
  already running, so BUSY is success and must be neither retried nor treated as
  failure. Doing so once killed a healthy process.
- `rearm_watchdog`: a refused discovery re-arm is dropped unread and no further
  event retries it, so a timer re-arms as well, respecting `@discovery_suppressed`.
- `UNREACHABLE_ERRORS` includes `ENOSYS`: `bt_to_errno()` maps unknown HCI statuses
  to ENOSYS and has no entry for `0x3e` Connection Failed to be Established, the
  ordinary unanswered-connect outcome (about half of LE connections at the
  validation site). `GattWalker::Bearer` annotates it the same way.
- `finish_connect` reads `getsockopt(SO_ERROR)` once and never calls `connect`
  twice: a torn-down channel answers EINVAL, indistinguishable from a bad address.
- `LeConnect` uses `SOCK_RAW` with no PSM and no CID; a PSM socket on an LE link
  asks for BR/EDR flow control and fails on link-up.
- `Mgmt.identity_address?`: mgmt Add Device accepts identity addresses only;
  private addresses route to `LeConnect`.
- `Runner#add_to_auto_connect`: the kernel serialises Add Device behind an
  in-flight LE create-connection, so it can exceed the mgmt reply timeout (6 s,
  measured 4.5 s on device); that is counted as `add-err`, never fatal.
- `GattWalker::Bearer`: the ATT bearer is an L2CAP socket bound with CID 0x0004
  *before* `connect`, which attaches to the existing link and holds it open; an
  unbound connect would create a new connection. The bearer never sets
  `BT_SECURITY`; pairing is refused by the Runner's mgmt configuration.
- `GattWalker::UNSUPPORTED_GROUP_TYPE`: Android's GATT server answers the
  secondary-service sweep (Read By Group Type 0x2801) with `0x10`; that ends the
  sweep normally, since GATT has no secondary-service discovery procedure.
- `Runner#hci_reset`: the cycle-start controller reset is load-bearing (removing
  it regressed version reads), so it is deferred while GATT walks are in flight,
  never removed.

## Chunking is where most bugs have come from

`btmon`'s output format drifts between BlueZ versions and each drift silently
breaks an assumption here.

The invariant: **any event that renders a device address must be a chunk start.**
Handle-carrying events count, because btmon resolves the handle and prints the
address. An address-bearing event missing from `HCI_EVENT_START_CODES` or
`LE_META_START_SUBEVENT` is appended to whichever chunk is open and merges a
second device into it. Symptoms: the `multi-address-line` and
`multiple-unique-address` counters climb. Specs use a deliberately non-start
address-bearing event as a stand-in to exercise merging; it has been repointed
three times as each became a start code, expect to move it again.

`btmon` decodes connection payloads, and the decoded field names collide with
device attributes (an L2CAP Information Response has a `Features:` block). ACL,
SCO and ISO data is therefore dropped in the handler (`ACL_DATA_RE`, both the
`BR-ACL`/`LE-ACL` and `ACL Data RX`/`TX` spellings). That drop is also what keeps
GATT walk traffic, which rides the LE link as ACL data, out of the pipeline;
`spec/gatt_pipeline_replay_spec.rb` proves it against a real capture.

`Device.update_or_create_from_result` uses explicit attribute allowlists, so a new
result key is ignored unless added. That is deliberate: the parser can carry
non-device data on the result hash (how `le_connectable` reaches `ConnectTracker`).

## Counters are the debugging interface

Health counters live on `CliUserInterfaceTracker` and `GattScanner` and render on
the CUI's `log_level: debug` lines. They are built to reconcile:

- auto-connect: `added` = `connected + failed + timeout` once a phase settles.
- direct LE: `unreachable` (asked, no answer), `error` (never got to ask),
  `abandoned` (our budget ran out) and `conn-limit` (controller out of LE slots,
  EMLINK) are kept apart on purpose. Collapsing them hid a socket bug for a whole
  device run. Give a new outcome its own bucket.
- chunker: `multi-address-line`, `multiple-unique-address`, `zero-address`,
  `truncation-detected` should all read 0.
- discovery re-arm: read `issued`, `rate-limited`, `watchdog`, `refused` together.
- GATT: `attempted` = `in-flight` + the eight outcome counters (`complete`,
  `partial`, `protected`, `unchanged`, `busy`, `timeout`, `disconnected`, `error`)
  in every snapshot; `skipped`, `deferred`, `resumed`, `peer-req`, `reset-deferred`
  and `name-unknown` sit outside that invariant.

Counters start at 0 and are never reset while the process runs. When a fix cannot
be validated without hardware, add a counter or a debug line rather than guess;
several of the above were found that way.

## Running the specs

`btmon` must resolve on `PATH` or requiring `runner.rb` exits. Put a stub on the
path and exclude the one spec that needs hardware:

```sh
mkdir -p /tmp/fakebin && printf '#!/bin/sh\nexit 0\n' > /tmp/fakebin/btmon && chmod +x /tmp/fakebin/btmon
PATH=/tmp/fakebin:$PATH bundle exec rspec --exclude-pattern 'spec/runner_spec.rb'
```

- `spec/runner_spec.rb` asserts an LMP version that comes from a runtime HCI read
  a headless host cannot produce; the non-runner suite is the green target.
- Requiring the library has side effects: it rewrites `blue_hydra.yml` and writes
  `blue_hydra.log` and `blue_hydra_chunk.log` in the repo root. `spec_helper` sets
  `ENV["BLUE_HYDRA"] = "test"` (pins those paths, in-memory DB) and runs with
  `daemon_mode` true, so the CUI-active guard is off unless an example stubs it.
  Back the three files up and restore them around any standalone script.
- `blue_hydra_chunk.log` in the repo root must stay byte-identical across a run.
  `spec_helper` installs a `ChunkLogGuard` that fails the suite if anything writes
  it; a spec that exercises that path installs its own double.
- The library uses `Data.define` and the test group's `rantly 3.0.0` needs Ruby
  3.3 or newer, so the suite needs Ruby 3.3+ whatever `README.md` says about the
  runtime. Downstream images run `bundle install --without development` and then
  this suite at build time, so test-group gems must resolve on the deployment Ruby.
- Property tests use `rantly` with at least 100 generated cases (most run 200 or
  more) and must print the failing input. Each is named `Property N` in a comment
  that states the property in words first.
- `spec/support/fake_att_peer.rb` is the GATT harness: a scripted ATT peer and
  `GattDatabase.generate` for property tests. Walker behaviour is specified
  against it, not against a reimplementation of the walker.
- Keep `ruby -w` clean on files you touch.

## Replaying captures

`spec/fixtures/` holds `btmon_raw_*.log` captures from device runs, some very
large, and `btmon_gatt_walk.log`, a small cut with three concurrent GATT walks
(its README records the provenance and expected counts). Captures are the
strongest verification short of hardware.

- Replay through the shipped classes (`BtmonHandler.allocate` with an injected
  queue, the real `Chunker` and `Parser`), never a reimplementation. Validate a
  harness by checking it reproduces the counters the device reported.
- `btmon_chunk.log`-style fixtures are a different format and hang `chunker_spec`
  rather than fail; only `btmon.stdout` and `btmon_gatt_walk.log` are referenced
  by specs.
- Measure from ground truth. How long discovery was off comes from the capture's
  `MGMT Event: Discovering` transitions, not from our log lines, which fire only
  when we notice. Measure old and new captures with the same script before
  claiming an improvement, and prefer a statistic over a maximum: the longest
  discovery-off intervals on device were the kernel's own connection attempts,
  with nothing of ours in flight.
- Counting traps in this data: `grep -c` on an event name overcounts because
  btmon prints event masks that list subevent names; a `Status:` line may belong
  to an HCI or a MGMT event and the two use different code namespaces; one chatty
  address can dominate an aggregate, so check before generalising; a capture may
  end mid-message, which is a replay artifact.
- Chunk and GATT-walk frames may carry btmon's `tool[pid]: ` prefix with an empty
  tool name (`[1234]: `); `BtmonHandler::TOOL_PREFIX_RE` accepts it and a
  frame-boundary regex that requires a name misses those lines.
- New fixtures and capture excerpts quoted in specs have device names, addresses
  and OUI/vendor text rewritten consistently before commit, hex-encoded names,
  byte-reversed addresses in dumps and btmon's shifted-byte renderings included,
  with every line's byte length and dump/gutter agreement preserved so replay
  counts and padded-header alignment hold. The fixture's README records the rule
  and the invariants (line count, byte count, sha256), never the mapping.

## Conventions

- Comments record the non-obvious why: the kernel behaviour, the measurement, the
  failure that motivated the code. Assume the reader knows Ruby. Where a number
  came from a device run, say so and give the number.
- Best-effort paths degrade rather than raise. Transport setup, pairing
  suppression, scan resumption and GATT walks all log and carry on, because
  scanning imperfectly beats not scanning. Reserve fatal for "this process cannot
  do its job at all", and say what was enabled at the time.
- Tests land with the code they cover, and a spec that pins a device-observed
  behaviour cites the observation.
- Nothing that tracks one device is committed in specs, fixtures, `TODO` or
  comments, existing code included: addresses (colon text, spaced or packed hex,
  byte-reversed, btmon's shifted New Connection Parameter form and its Store
  hint byte), names with a serial or address, serials, System IDs, per-device
  payload fields. Synthetic public addresses use a locally administered OUI,
  random ones keep the bits their tag implies; the mapping is never committed.
- GATT reads are read-only and unauthenticated by design: no pairing, no writes,
  no CCCD subscriptions. An attribute that needs security is recorded as
  `protected`, and the Identity_Set values (Device Name, Appearance, Device
  Information strings, System ID, PnP ID, Database Hash) are stored in their own
  `gatt_*` columns and never overwrite the advertised `name`, `appearance`,
  `manufacturer` or `firmware`.
