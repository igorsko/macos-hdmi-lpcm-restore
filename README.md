# macOS HDMI LPCM Restore

**Automatically restore multichannel HDMI audio when your Mac returns to stereo after TV or receiver standby.**

[![macOS checks](https://github.com/igorsko/macos-hdmi-lpcm-restore/actions/workflows/test.yml/badge.svg)](https://github.com/igorsko/macos-hdmi-lpcm-restore/actions/workflows/test.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

HDMI LPCM Restore is a small native macOS utility that restores an HDMI output to **8-channel LPCM at 48, 96 or 192 kHz**. It listens for CoreAudio changes and runs in the background as a per-user LaunchAgent.

It is designed for setups where multichannel audio works correctly until the TV or receiver is switched off, then macOS reconnects using a two-channel format. The utility restores the selected format while checking that your existing speaker mapping remains unchanged.

## Features

- Detects HDMI device reconnections and audio format changes without periodic polling.
- Selects only formats advertised by the connected device.
- Checks the saved speaker mapping before and after changing the format.
- Supports an existing 5.1 mapping with rear speakers assigned to channels 7 and 8.
- Defers changes while an application is using the audio device.
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

After installation, switch your TV and receiver off and on normally. The listener allows time for the HDMI connection to settle, then restores the configured format when the output is idle.

An application can keep the audio device busy even when playback is paused. In that case, restoration waits until the device is released; closing the player may be necessary.

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
| `Audio device busy` | A player or another application still has the device open. Pausing may not release it. |
| Device absent | Check the HDMI connection. Changing ports or equipment may change the device UID. |
| Mapping mismatch or `STOP` in the log | Review your speaker assignments. Automatic changes stop when the mapping guard fails. |
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

If the device UID or intended speaker mapping has changed, review the setup before creating a new configuration. The utility deliberately avoids selecting a replacement device automatically.

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

CoreAudio notifications trigger a short, bounded sequence of checks while the HDMI connection settles. The utility updates the physical and virtual stream formats only when needed, then reads them back and verifies the speaker mapping. A failed change triggers a best-effort rollback to the previous formats.

It does not write speaker layouts, stereo channel assignments, volume, mute or the default audio output. Mapping checks include a read-only comparison with a macOS audio preferences file. That file is an undocumented implementation detail, so future macOS updates may require changes to the utility. If the saved mapping cannot be read or verified, format changes are blocked.

## Tested behavior

A TV power-cycle test on an **Apple M4 Mac mini** reproduced a fallback to two-channel LPCM at 96 kHz. After the player released the output, the listener automatically restored eight-channel LPCM at 192 kHz. The complete speaker mapping matched the original configuration, including rear channels 7 and 8.

This confirms one observed recovery on that setup. Other TVs, receivers and macOS versions have not been comprehensively validated. Physical speaker routing was not acoustically tested.

Run the software checks locally:

```sh
sh ./Tests/run.sh
```

GitHub Actions runs the build and software checks on macOS. These checks do not replace testing with real HDMI equipment.

## Reporting issues

[Open an issue](https://github.com/igorsko/macos-hdmi-lpcm-restore/issues) with your macOS version, Mac model, TV/receiver models, selected sample rate and steps to reproduce the problem.

Review diagnostic output before sharing it. Remove personal paths and device identifiers, and do not upload your saved `config.json` or system audio preference files.

## License

Copyright (c) 2026 HDMI LPCM Restore contributors.

Licensed under the [GNU General Public License v3.0](LICENSE), **GPL-3.0-only**.

Not affiliated with Apple or any TV or audio equipment manufacturer.
