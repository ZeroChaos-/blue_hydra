# Vendored: Nordic Semiconductor bluetooth-numbers-database

- Repository: https://github.com/NordicSemiconductor/bluetooth-numbers-database
- Commit: `d379cc06c9c3681bc1c1cd4d61c246a0b0f80b0e` (HEAD of `master`, the default branch, at retrieval; committed 2026-09-02, "Merge pull request #180 from dinesharjani/tpms")
- Retrieved: 2026-10-27, each file from `https://raw.githubusercontent.com/NordicSemiconductor/bluetooth-numbers-database/d379cc06c9c3681bc1c1cd4d61c246a0b0f80b0e/<path>`
- Licence: BSD-3-Clause, Copyright (c) 2019 - 2020, Nordic Semiconductor ASA. The upstream `LICENSE` is vendored unmodified beside this file.

This is the sole source of GATT service, characteristic and descriptor UUID names for `BlueHydra::UuidNames` (`lib/blue_hydra/uuid_names.rb`). A UUID it does not list renders as `Unknown (<uuid>)`. Bluetooth SIG Assigned Numbers data is not used; it is deferred to `TODO` item 16 because its licence is unresolved.

## Files

The files are byte-identical to upstream at the commit above. Do not edit them; to update, re-fetch all four at a new commit and rewrite this file.

| Path | Bytes | sha256 | Entries (16-bit / 128-bit) |
|---|---|---|---|
| `LICENSE` | 1509 | `1aa0bd572f4e3aa4d958687f5e114e888614e651c476d1657dd814f2f743f9ca` | - |
| `v1/service_uuids.json` | 18707 | `fec38d7a1d24f18a3241a4cc226949be699dccb8abe804df92017a170b041a82` | 129 (76 / 53) |
| `v1/characteristic_uuids.json` | 102688 | `c9e73f84029a7def59c6e5fe326a29ef70cd7ac6cf57a14ed04b3c63a99f9017` | 689 (493 / 196) |
| `v1/descriptor_uuids.json` | 2733 | `c2475c5af2dd09ea3df5cb33f368ade5493057795aa3ddf55dc76c4ea832fd07` | 18 (18 / 0) |

Verified at retrieval: each fetched file matched a shallow clone of the commit under `cmp`, and its git blob id matched the commit's tree entry. Each JSON file parses as an array.

## Upstream format

Each JSON file is an array of `{"name", "identifier", "uuid", "source"}` objects. `uuid` is uppercase hex: 4 digits for a 16-bit UUID, or 8-4-4-4-12 with hyphens for a 128-bit UUID. No entry is a 128-bit Bluetooth Base UUID spelling of a 16-bit UUID.

At this commit `characteristic_uuids.json` lists 12 UUIDs twice (0x2B1D to 0x2B28). Both entries for each carry the same `name` and differ only in `identifier`, so either one yields the same rendered name.
