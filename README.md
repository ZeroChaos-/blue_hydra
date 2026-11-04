# BlueHydra

BlueHydra is a Bluetooth device discovery service built on top of the `bluez` 
library. BlueHydra makes use of ubertooth where available and attempts to track
both classic and low energy (LE) bluetooth devices over time. 

## Installation

The files in this repository can be run directly.

Ensure that the following packages are installed: 

```
bluez
ubertooth # where applicable
sqlite3
libsqlite3-dev
```

If your chosen distro is still on bluez 4 please choose a more up to date distro.  Bluez 5 was released in 2012 and is required.

BlueHydra now drives discovery, resets, and connections through the kernel
Bluetooth management (mgmt) API and raw HCI/L2CAP sockets directly, so the
dbus `test-discovery` helper and the external `l2ping` binary are no longer
used. The `bluez-test-scripts`, `python3-bluez`, and `python3-dbus` packages
that those relied on are therefore no longer required.

On Debian-based systems, these packages can be installed with the following command line:

```sudo apt-get install bluez libsqlite3-dev ubertooth```

To install the needed gems it may be helpful (but not required) to use bundler:

```
sudo apt-get install ruby-dev bundler
(from inside the blue_hydra directory)
bundle install
```

In addition to the Bluetooth packages listed above you will need to have Ruby
version 3.3 or newer installed, as well as Ruby development headers for gem compilation (on
Debian based systems, this is the `ruby-dev` package). Ruby 3.2 can run the
service itself but not the test suite. With ruby installed add the `bundler` gem and
then run `bundle install` inside the checkout directory. 

Once all dependencies are met simply run `./bin/blue_hydra` to start discovery.
If you experience gem inconsistency try running `bundle exec ./bin/blue_hydra` instead.

There are a few flags that can be passed to this script: 

* `-d` or `--daemonize`: suppress CLI output and run in background
* `-z` or `--demo`: run with CLI output but mask displayed macs for demo purposes
* `-p` or `--pulse`: attempt to send data to Pwn Pulse
* `--pulse-debug`: store what would be sent to Pulse in a file for review
* `--stream-builder`: send device data to Stream Builder and metrics to CloudWatch via Greengrass; if the optional Stream Builder support is not installed a warning is logged and the flag has no effect
* `--stream-builder-debug`: store what would be sent to Stream Builder in a file for review
* `--no-db`: keep the database in memory only, nothing is written to disk
* `--rssi-api`: open 127.0.0.1:1124 so other processes can poll for seen devices and RSSI (same as `signal_spitter: true` in the config file)
* `--no-info`: skip info scans, for fox hunting; some device details will be missing but tracking has fewer gaps
* `--mohawk-api`: write the CLI table as JSON to `/dev/shm/blue_hydra.json`
* `-v` or `--version`: print the version and exit
* `-h` or `--help`: show the option summary and exit


## Recommended Hardware
BlueHydra should function with most internal bluetooth cards but we recommend 
using the Sena UD100 adapter.

Additionally you can make use of Ubertooth One hardware to detect active devices
not in discoverable mode.

**Note:** using an Ubertooth One is _not_ a replacement for a conventional
bluetooth dongle. 

## Configuring Options

The config file `blue_hydra.yml` is located in the install directory, unless /etc/blue_hydra exists,
then it is in /etc/blue_hydra. (Pwnie Express sensor images used to keep it under
`/opt/pwnix/data/blue_hydra/`; the current code does not look there.) On startup blue_hydra
rewrites the file, adding any option it lacks with the default value, so new options show up in
the file after pulling new code.

The following options can be set:

* `log_level`: defaults to info level, can be set to debug for much more verbosity. If set to `false` no log or rssi log will be created.
* `bt_device`: specify device to use as main bluetooth interface, defaults to `hci0`
* `ubertooth_index`: defaults to `"0"`, the `-U` device index passed to `ubertooth-util`, `ubertooth-rx` and `ubertooth-scan`
* `info_scan_rate`: rate at which to run info scan in seconds, defaults to 600.  Values too small will be set to 45.  Value of 0 disables info scanning.
* `btmon_log`: `true|false`, if set to true will log filtered btmon output
* `btmon_rawlog`: `true|false`, if set to true will log unfiltered btmon output
* `file`: if set to a filepath that file will be read in rather than doing live device interactions
* `rssi_log`: `true|false`, if set will log serialized RSSI values
* `aggressive_rssi`: `true|false`, if set will agressively send RSSIs to Pulse
* `signal_spitter`: `true|false`, defaults to false; same effect as the `--rssi-api` flag
* `chunker_debug`: `true|false`, defaults to false; writes chunks of btmon output that carry no address or more than one address in full to `blue_hydra_chunk.log` for debugging
* `le_connect_parallel`: how many direct LE connects to private-address devices run at once, defaults to 10
* `connect_to_nonconnectable`: `true|false`, defaults to false; when true blue_hydra also attempts to connect to devices that have only ever advertised as non-connectable (such attempts cannot succeed, which is why this is off by default)
* `ui_inc_filter_mode`: `:disabled|:hilight|:exclusive`, set ui filtering to this mode by default
* `ui_inc_filter_mac`: `- FF:FF:00:00:59:25`, set inclusive filter on this mac, each goes on a newline preceded by a hyphen and space
* `ui_inc_filter_prox`: `- 669a0c20-0008-9191-e411-1b11d05d7707-9001-3364`, set inclusive filter on this proximity_uuid-major_number-minor_number, each goes on a newline preceded by a hyphen and space
* `ui_exc_filter_mac`: same syntax as ui_inc_filter_mac, but exclude instead
* `ui_exc_filter_prox`: same syntax as ui_inc_filter_prox, but exclude instead
* `ignore_mac`: same syntax as ui_inc_filter mac, but entirely ignore device, both db and ui
* `gatt_scan`: `true|false`, defaults to true; read once at startup. `false` turns GATT scanning off entirely (see below)
* `gatt_walk_timeout`: seconds allowed for one GATT walk, defaults to 10; accepted values are 1 to 60 (integer or decimal)
* `gatt_walk_parallel`: how many GATT walks run at once, defaults to 3; accepted values are integers 1 to 8
* `gatt_read_all`: `true|false`, defaults to true; `false` reads only the identity characteristics (Device Name, Appearance, Device Information strings, System ID, PnP ID, Database Hash) and skips every other value

A `gatt_*` option set to a value outside its accepted type or range falls back to its default and
blue_hydra logs one warning at startup; the sensor keeps running.

## GATT scanning

After an LE device has been connected, whether through auto-connect or a direct connect,
blue_hydra reads its GATT database. The read is read-only and unauthenticated: no pairing,
no writes, no subscriptions.

* What is read is stored in the `gatt_*` columns of the device record: service UUIDs, the
  characteristic list, Device Name, Appearance, the Device Information strings (manufacturer
  name, model number, serial number, firmware, hardware and software revision), System ID,
  PnP ID and Database Hash.
* These columns never overwrite the advertised `name`, `appearance`, `manufacturer` or
  `firmware`; both sets are kept.
* An attribute the device keeps behind security (pairing, encryption or authorization) is
  recorded as `protected`, with no value stored.
* In the CLI the NAME column shows the complete advertised name if one has been seen,
  otherwise the GATT Device Name, otherwise the shortened advertised name.
* `gatt_scan: false` in `blue_hydra.yml` turns GATT scanning off; `gatt_walk_timeout`,
  `gatt_walk_parallel` and `gatt_read_all` tune it (see Configuring Options).

How the scan works internally is described in `AGENTS.md`.

## Usage

It may also be useful to check blue_hydra --help for additional command line options.  At this time it looks like this:

```
Usage: BlueHydra [options]
    -d, --daemonize                  Suppress output and run in daemon mode
    -z, --demo                       Hide mac addresses in CLI UI
    -p, --pulse                      Send results to hermes
        --pulse-debug                Store results in a file for review
        --stream-builder             Send device data to Stream Builder and metrics to CloudWatch via Greengrass
        --stream-builder-debug       Store Stream Builder results in a file for review
        --no-db                      Keep db in ram only
        --rssi-api                   Open 127.0.0.1:1124 to allow other processes to poll for seen devices and rssi
        --no-info                    For the purposes for fox hunting, don't info scan.  Some info may be missing, but there will be less gaps during tracking
        --mohawk-api                 For the purposes of making a hat to cover a mohawk, shit out the ui as json at /dev/shm/blue_hydra.json
    -v, --version                    Show version and quit
    -h, --help                       Show this message
```

## Logging

All data is logged to an sqlite database (unless --no-db) is passed at the command line.  The database `blue_hydra.db` is placed in /etc/blue_hydra if that
directory exists, otherwise in the directory blue_hydra was started from. (Pwnie Express sensors used to keep it under /opt/pwnix/data; the current code does not look there.)

The log file `blue_hydra.log`, and `blue_hydra_rssi.log` and `blue_hydra_chunk.log` when enabled, go to /var/log/blue_hydra if that directory exists, otherwise to the checkout directory.

The database will automatically be cleaned of older devices to ensure performance: a device record that has not been updated for two weeks is removed.  If you want to keep information about such devices it is your responsibility to offload data using one of the available options (`--pulse`, `--pulse-debug`, `--stream-builder`, `--stream-builder-debug`) or back up the database regularly.

An example for a script wrapping blue_hydra and creating a csv output after run is available here:
https://github.com/pwnieexpress/pwn_pad_sources/blob/develop/scripts/blue_hydra.sh
This script will simply take a timestamp before blue_hydra starts, and then again after it exits, then grab a few interesting values from the db and output in csv format.

## Troubleshooting

### `Parser thread "\xC3" on US-ASCII` 

If you encounter an error like `Parser Thread "\xC3" on US-ASCII` it may be due
to an encoding misconfiguration on your system. 

On Debian like systems, this can be resolved by setting locale encodings as follows:

```
sudo locale-gen en_US.UTF-8 
sudo locale-gen en en_US en_US.UTF-8
sudo dpkg-reconfigure locales
export LC_ALL="en_US.UTF-8"
```

This issue and solution brought up by [llazzaro](https://github.com/llazzaro)
[here](https://github.com/pwnieexpress/blue_hydra/issues/65).
