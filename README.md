# macOS HDMI LPCM Restore

**Automatically restore multichannel HDMI audio when your Mac returns to stereo after TV or receiver standby.**

[![macOS checks](https://github.com/igorsko/macos-hdmi-lpcm-restore/actions/workflows/test.yml/badge.svg)](https://github.com/igorsko/macos-hdmi-lpcm-restore/actions/workflows/test.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

HDMI LPCM Restore is a personal project developed for a Mac mini M4, a Sony BRAVIA Theatre Quad and a Philips 55PUS7503/12 TV. This small native macOS utility restores an HDMI output to **8-channel LPCM at 48, 96 or 192 kHz**. It listens for CoreAudio changes and runs in the background as a per-user LaunchAgent.

It is designed for setups where multichannel audio works correctly until the TV or receiver is switched off, then macOS reconnects using a two-channel format. The utility restores the selected format while checking that your existing speaker mapping remains unchanged.

## Features

- Detects HDMI device reconnections and audio format changes without periodic polling.
- Selects only formats advertised by the connected device.
- Checks the saved speaker mapping before and after changing the format.
- Supports an existing 5.1 mapping with rear speakers assigned to channels 7 and 8.
- Offers idle-only operation or automatic stereo recovery while audio applications remain open.
- Provides status diagnostics, configuration backups and an explicit command to accept speaker-mapping changes.
- Starts automatically when you log in to macOS.
- Uses Apple Swift, CoreAudio and launchd; no Homebrew, third-party drivers or Accessibility access.

The utility restores LPCM output. It does not encode Dolby Digital or Dolby Atmos, or create a surround speaker configuration.

## Requirements

- macOS with Apple Swift 6 or newer and the CoreAudio SDK.
- Apple Command Line Tools or Xcode.
- An HDMI output with a single output stream and support for 8-channel LPCM at the selected sample rate.
- An existing explicit eight-channel speaker mapping in **Audio MIDI Setup**.

Install from your normal macOS login session. Do not run the installer with `sudo`.

## Quick start

### 1. Download and build

If Apple Command Line Tools are not installed, run:

```sh
xcode-select --install
```

Once installation is complete:

```sh
git clone https://github.com/igorsko/macos-hdmi-lpcm-restore.git
cd macos-hdmi-lpcm-restore
sh ./build.sh
./build/hdmi-lpcm list
```

The build script uses the standalone Apple Command Line Tools when available without changing your global Xcode selection.

### 2. Prepare your HDMI output

In **Audio MIDI Setup**, select your HDMI device, choose an eight-channel format and confirm your speaker assignments. This is the configuration the utility will preserve.

Stop playback and close applications holding the audio output open. In the output of `list`, find your HDMI device and copy its exact `uid`. The device may appear under the TV's name even when a receiver handles the sound.

### 3. Install

Replace the placeholder with your HDMI device UID:

```sh
sh ./install.sh 'YOUR_HDMI_DEVICE_UID' 48000
```

The second argument is the sample rate in hertz:

| Argument | Target format |
| --- | --- |
| `48000` | 8-channel LPCM, 48 kHz |
| `96000` | 8-channel LPCM, 96 kHz |
| `192000` | 8-channel LPCM, 192 kHz |

Choose a rate supported by your equipment. The installer captures the current speaker mapping and original audio formats, then starts the listener immediately. It refuses to overwrite an existing installation.

## Usage

After installation, switch your TV and receiver off and on normally. The listener allows time for the HDMI connection to settle, then restores the configured format. New installations default to the conservative `idle` policy.

### Restore stereo audio while players remain open

Browsers and players can keep HDMI audio busy even while paused. Enable `reconnect` mode to recover a stereo fallback without closing those applications:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/manage.sh" policy reconnect
```

The output and advertised target formats must remain stable for at least eight seconds. Recovery while busy is limited to an LPCM stereo fallback, with at most one format-change attempt per minute. An exclusively owned device or a speaker-mapping mismatch still blocks changes. A format change may briefly interrupt playback; some applications may need playback restarted afterward.

To return to idle-only operation:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/manage.sh" policy idle
```

### Accept a speaker-mapping change

If you intentionally change speaker assignments in Audio MIDI Setup, select the configured eight-channel format and sample rate, verify the assignments, then explicitly accept the new mapping:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/manage.sh" accept-mapping
```

This updates only the saved reference, backs up the previous configuration, and restarts the listener. It never assigns speakers or accepts mapping changes automatically. Original stream formats are retained for rollback.

### Diagnose the current state

```sh
sh "$HOME/Library/Application Support/HDMILPCM/manage.sh" status
```

Status reports both stream formats, the active policy, audio client bundle IDs when available, and the result of the mapping guard. A temporary stereo layout can be valid during recovery.

To check the current physical and virtual formats and compare the speaker mapping with the saved configuration:

```sh
base="$HOME/Library/Application Support/HDMILPCM"
"$base/hdmi-lpcm" check "$base/config.json"
```

### Installation locations

| Location | Contents |
| --- | --- |
| `~/Library/Application Support/HDMILPCM/` | Program, saved configuration and logs |
| `~/Library/LaunchAgents/local.hdmi-lpcm.plist` | Automatic startup for your macOS user |

The program runs locally and does not send telemetry. Its saved configuration contains your HDMI device identifier and speaker mapping.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Audio remains in stereo | Close applications using HDMI audio. Confirm that eight-channel LPCM is available in Audio MIDI Setup. |
| `Audio device busy` or waiting for idle | In `idle` mode, close the player. Alternatively, enable `reconnect` mode to recover a stable stereo fallback while the device is busy. |
| Device absent | Check the HDMI connection. Changing ports or equipment may change the device UID. |
| Mapping mismatch | Verify the assignments in Audio MIDI Setup. If the change was intentional, use `accept-mapping`; otherwise restore your intended assignments manually. |
| Requested format not advertised | Select a sample rate supported by the HDMI device. The utility will not force an unsupported format. |

Read recent diagnostic messages:

```sh
base="$HOME/Library/Application Support/HDMILPCM"
tail -n 30 "$base/service.log" "$base/service-error.log"
```

Inspect the background service:

```sh
launchctl print "gui/$(id -u)/local.hdmi-lpcm"
```

The utility never selects a replacement device automatically. A changed HDMI UID requires a separate configuration review. Mapping failures suspend writes; the listener remains subscribed to changes and rechecks the guard on subsequent events.

### Update an existing installation

From an updated project checkout, run:

```sh
sh ./manage.sh update
```

The update builds and tests the new program, keeps the previous binary as `hdmi-lpcm.previous`, preserves your configuration and restarts the listener. Configuration changes keep private backups in `config-backups/` inside the installation directory.

## Uninstall and restore

Stop the listener and remove automatic startup:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/uninstall.sh"
```

The program, saved configuration and logs remain available for review. To also attempt restoration of the original audio formats **after uninstalling**, reconnect the same HDMI device, close audio players and run:

```sh
base="$HOME/Library/Application Support/HDMILPCM"
"$base/hdmi-lpcm" restore "$base/config.json"
```

Restoration checks the device identity and speaker mapping. If it cannot proceed, select the required format manually in Audio MIDI Setup.

## How it works

CoreAudio notifications trigger a bounded recovery window of up to 75 seconds while the HDMI connection settles. Events join the current window instead of indefinitely postponing recovery. Mapping and format events reset the stability check; the write cooldown remains in effect across event bursts. The utility updates the physical and virtual stream formats only when needed, then reads them back and verifies the speaker mapping. A failed change triggers a best-effort rollback to the previous formats.

It does not write speaker layouts, stereo channel assignments, volume, mute or the default audio output. Mapping checks include a read-only comparison with a macOS audio preferences file. That file is an undocumented implementation detail, so future macOS updates may require changes to the utility. If the saved mapping cannot be read or verified, format changes are blocked.

## Tested setup

This utility was developed for personal use with the following equipment:

| Component | Tested device or setting |
| --- | --- |
| Computer | Apple Mac mini with M4 chip |
| Operating system | macOS 27.0.1 |
| Audio system | Sony BRAVIA Theatre Quad |
| Television | Philips 55PUS7503/12 (reported by macOS as `Philips FTV`) |
| Target audio format | 8-channel LPCM at 192 kHz |
| Speaker configuration | Existing 5.1 mapping, with rear speakers on channels 7 and 8 |

Hardware validation is limited to this personal setup.

Switching the TV off and on reproduced a fallback to two-channel LPCM at 96 kHz. The listener restored eight-channel LPCM at 192 kHz and verified that the saved speaker mapping was unchanged.

Recovery was also observed in `reconnect` mode with Chrome left open and reported as an active audio client before and after the change. The log did not record a write while the device was busy, so it may have briefly become idle during the HDMI handshake. A format change with the device continuously busy has not yet been confirmed on hardware. Physical speaker routing was not acoustically tested.

### Software checks

```sh
sh ./Tests/run.sh
```

The checks cover format selection, mapping comparisons, recovery timing and the cooldown between write attempts. GitHub Actions runs these checks on macOS; hardware results are described separately above.

## License

Copyright (c) 2026 HDMI LPCM Restore contributors.

Licensed under the [GNU General Public License v3.0](LICENSE), **GPL-3.0-only**.

Not affiliated with Apple or any TV or audio equipment manufacturer.
