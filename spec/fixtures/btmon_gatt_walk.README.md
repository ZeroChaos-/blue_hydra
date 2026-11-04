# btmon_gatt_walk.log

Replay fixture for `spec/gatt_pipeline_replay_spec.rb` (gatt-service-scanning
Requirements 15.3 and 15.5): full-width btmon output in which three GATT Walks
run concurrently while discovery keeps reporting other devices. The spec
replays it through the shipped `BtmonHandler`, `Chunker` and `Parser` twice,
verbatim and with every `ACL_DATA_RE` message removed, and expects identical
chunker counters and identical parser results from both runs.

The file is a cut of a device capture. The only edits inside the frames are the
anonymization substitutions described below; do not reformat it (the `[pid]: `
prefixes, trailing spaces and column padding are part of what the pipeline has
to cope with). `.gitignore` carries an exception for this one `.log` so it ships
with the suite.

## Source

- Device_Validation run with `gatt_scan: true`, 2026-10-29 17:28:02Z to
  18:42:10Z, one DART, `btmon --columns 170 -T` (btmon 5.85, Linux 7.0.0,
  Bluetooth subsystem 2.22). Config: `log_level: debug`, `btmon_rawlog: true`,
  `gatt_walk_parallel: 3`, `gatt_walk_timeout: 10`, `gatt_read_all: true`,
  `le_connect_parallel: 10`, `info_scan_rate: 600`.
- Full capture: the 19.6 MB btmon log is kept in the developer's workspace,
  outside this repo. The fixture is lines 99461 to 102001 of that file, btmon
  frames #8242 to #8548, after the substitutions below.
- Window: every frame whose header timestamp lies in
  `2026-10-29 17:48:17.000000` .. `17:48:26.000000` (first frame 17:48:17.662194,
  last 17:48:25.977217). Cut on frame boundaries: a frame starts at a line whose
  first character is not whitespace (the `BtmonHandler` new-message rule, which
  also covers the prefixed forms below) and includes its indented continuation
  lines. The window opens on a quiet gap after 17:48:13 and closes on one before
  17:48:31.
- 2,541 lines, 142,919 bytes, LF line endings (both counts unchanged by the
  anonymization below, which keeps every line's byte length),
  sha256 `4a7e85117cfae31dc2b5e15cdc22f305b945190e9e4c4d309e9f7216082c436f`.

## Anonymization

Nothing in the fixture identifies a real device. Device addresses, OUI text and
device names were rewritten with one mapping, applied consistently across the
file and the specs that quote the same devices, and every line keeps its
original byte length, so the counts `spec/gatt_pipeline_replay_spec.rb` pins
still hold. Rewritten to match: hex-encoded names (packed `Value[n]:` hex and
the spaced dump rows with their ASCII gutters), byte-reversed addresses in hex
dumps (with their gutters), and btmon's shifted New Connection Parameter
renderings with their Store hint bytes. The vendor UUID's embedded text and one
manufacturer-specific gutter run that named a vendor were replaced by neutral
text of the same length. Synthetic public addresses use a locally administered
OUI; random addresses keep the top bits their `(Static)` or `(Non-Resolvable)`
tag implies. The real-to-synthetic mapping is not recorded anywhere.

## Line prefixes present

btmon attributes a frame to the process that caused it:

- `bundle[54160]: ` on the 7 MGMT commands blue_hydra issued (Start Discovery,
  Add Device, Remove Device).
- `[672192]: ` with an empty tool name on 67 lines: the 63 `< ACL Data TX` ATT
  frames the Walk threads sent and the 4 `< HCI Command: Read Remote Version
  Information` the HciCommand thread issued. `BtmonHandler::TOOL_PREFIX_RE`
  (`/^\w*\[\d*\]: /`) accepts the empty name; a frame-boundary regex that
  requires a non-empty name misses these lines.

## Links in the window

All four are auto-connect LE links (public addresses, LE Enhanced Connection
Complete). Handles 2048 to 2050 carry a Walk each; 2051 connected while three
Walks were in flight (`gatt_walk_parallel: 3`), so its handoff was deferred and
it carries only the L2CAP Connection Parameter Update exchange.

| Handle | Address | Name (from Device Found) | Server Rx MTU | ATT TX / RX | Connected | Ended |
|---|---|---|---|---|---|---|
| 2048 | `02:00:03:00:00:13` | `DEVICE-A00000001` | 256 | 16 / 15 | 17:48:17 | 17:48:23 Disconnect Complete, Connection Timeout (0x08) |
| 2049 | `02:00:02:00:00:12` | `DEVICE-C0001` | 517 | 23 / 23 | 17:48:19 | 17:48:23 Disconnect Complete, Terminated By Local Host (0x16) |
| 2050 | `02:00:01:00:00:11` | `DEVICE-B0000002` | 256 | 24 / 24 | 17:48:19 | 17:48:23 Disconnect Complete, Terminated By Local Host (0x16) |
| 2051 | `02:00:04:00:00:14` | `DEVICE-B0000001` | - | 0 / 0 (L2CAP only) | 17:48:19 | 17:48:25 Disconnect Complete, Terminated By Local Host (0x16) |

ATT traffic: 125 ATT frames in 129 `ACL Data` frames (the other 4 are LE L2CAP
Connection Parameter Update Request/Response). All three walked handles have
`< ACL Data TX` requests and `> ACL Data RX` responses, and the ATT frame
sequence switches handle 38 times, so the Walks genuinely interleave.
Opcodes in each direction:

- Sent by blue_hydra (`<`): Exchange MTU Request (0x02), Read By Group Type
  Request (0x10), Read By Type Request (0x08), Find Information Request (0x04),
  Read Request (0x0a), and one Error Response (0x01).
- Received (`>`): Exchange MTU Response (0x03), Read By Group Type Response
  (0x11), Read By Type Response (0x09), Find Information Response (0x05), Read
  Response (0x0b), Error Response (0x01), and one Read By Type Request (0x08).

The peer on 2049 sent its own Read By Type Request for Server Supported
Features (0x2b3a) at 17:48:19.333576 (frame #8291); blue_hydra's Att_Server
answered Error Response 0x0a Attribute Not Found at 17:48:19.761791 (frame
#8320), while its own client request on that link stayed outstanding. So the
fixture carries requests and responses in both directions on one link.

Number of Completed Packets: 65 frames, acknowledging packets on 2048 (16),
2049 (23), 2050 (25) and 2051 (1). Every handle line is address-resolved
(`Handle: 2048 Address: 02:00:03:00:00:13 ...`).

## Other devices in the window

Each has at least one `MGMT Event: Device Found` and at least one HCI
`LE Meta Event` (LE Extended Advertising Report) and is not connected in the
window:

| Address | Name | Device Found | LE Meta Event frames |
|---|---|---|---|
| `02:00:05:00:00:16` | `DEVICE-B0000004` | 1 | 2 |
| `C2:00:00:00:00:18` (Static) | - | 1 | 1 |
| `02:00:04:00:00:15` | `DEVICE-B0000003` | 2 | 2 |
| `02:00:06:00:00:17` | - | 1 | 1 |

The four connected devices above also advertise in the window (Device Found for
each), and discovery toggles four times (`MGMT Event: Discovering` at
17:48:17.668, 17:48:17.795, 17:48:18.113, 17:48:20.472).

## Replay result (measured before the replay spec existed)

Replayed through `BtmonHandler.allocate` with an injected queue (feeding lines
as the spawn loop does, `check_for_truncation` on every header line, `enqueue`
per message), then the real `Chunker` and `Parser`, with `chunk_logger` and
`send_event` stubbed:

- 65 messages reach `raw_queue`: 42 `LE Meta Event`, 14 `MGMT Event: Device
  Found`, 4 `Read Remote Version Complete`, 4 `Disconnect Complete`,
  1 `Inquiry Complete`. Every `ACL Data`, `Number of Completed Packets`,
  `Command Complete`/`Command Status`, `<` command and non-Device-Found `@`
  frame is dropped by the handler.
- 63 parser results. `Inquiry Complete` (0x01) is not a chunk start and carries
  no address, so it merges silently into the open chunk; the chunker's final
  working set is never flushed without a following start block (a replay
  artifact, as the steering file notes).
- Counters: `truncation-detected` 0, `multi-address-line` 0,
  `multiple-unique-address` 0, `zero-address` 0.
- With every `ACL_DATA_RE` message removed (708 lines): the same 65 messages,
  the same 63 results in the same order with equal attributes, the same
  counters.
- Through the PTY path (`BtmonHandler.new("cat <fixture>", queue)`) the counters
  and result count are identical; the only difference is `\r\n` inside the raw
  `le_unknown` lines, which the PTY's output translation adds. Use the allocate
  path in specs.
