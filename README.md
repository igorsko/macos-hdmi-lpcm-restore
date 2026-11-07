# HDMI LPCM Restore for macOS

A small native Swift/CoreAudio listener that restores one HDMI output to **8-channel LPCM** at an explicitly configured sample rate (48, 96 or 192 kHz). Uses a per-user LaunchAgent and Apple Command Line Tools. No Homebrew, third-party audio driver, Accessibility permission, administrator service or periodic polling.

The HDMI endpoint may be named after the television even when a receiver or surround system handles the sound. Select it by its exact CoreAudio UID, never by a broad name match.

## What it changes

Only `kAudioStreamPropertyPhysicalFormat` and `kAudioStreamPropertyVirtualFormat`, and only when necessary. The sample rate and channel count are selected from the formats advertised by the device. Current bit depth and format flags are preferred where supported.

The read-only saved-mapping guard inspects the target device entry in `/Library/Preferences/Audio/com.apple.audio.SystemSettings.plist`. This file is an undocumented implementation detail: an unreadable file or unexpected schema blocks writes. Future macOS versions may require an update.

The program never writes channel layouts, stereo channel assignments, volume, mute, default output or system audio preference files. It captures the current preferred channel layout, stereo assignments and saved surround configuration. It compares these before and after a format change and refuses to write if the saved baseline differs or cannot be read. A temporary two-channel layout is accepted only when it exactly matches the first two channel descriptions of the saved eight-channel baseline, one of the LPCM streams is still stereo, and the persisted surround mapping remains unchanged. A layout mismatch locks automatic attempts until the process is restarted after review. This preserves an existing 5.1 assignment with rear channels on 7/8 **when the driver continues to expose that saved mapping**; it does not create or repair a 5.1 mapping.

CoreAudio drivers can have their own side effects. A failed write or readback triggers a best-effort rollback of the previous stream formats. No mapping is rewritten even during rollback. A missing/ambiguous UID, non-HDMI device, multiple output streams, unsupported format or active playback prevents changes. If the endpoint changes UID, review and capture a new baseline manually; the program will not guess another endpoint.

## Requirements and build

- macOS with Apple Swift 6 or newer and the CoreAudio SDK.
- Apple Command Line Tools or Xcode. Run `xcode-select --install` yourself if missing.
- A GUI login session for installation. Do not install with `sudo`.

```sh
sh ./build.sh
./build/hdmi-lpcm self-test
./build/hdmi-lpcm list
```

The build script prefers `/Library/Developer/CommandLineTools` locally when installed. It does not change the global developer selection or accept Xcode license terms.

## Install

First configure and check the desired speaker mapping in Audio MIDI Setup. Baseline capture requires an explicit eight-channel mapping (not a two-channel endpoint or a layout tag without descriptions). Stop audio playback. Copy the exact HDMI UID printed by `list`, then:

```sh
sh ./install.sh 'YOUR_HDMI_DEVICE_UID' 192000
```

Use `48000` instead for 48 kHz. The rate is explicit; no unsupported format is synthesized. Installation refuses to overwrite an existing installation or baseline.

The program and private configuration are saved under `~/Library/Application Support/HDMILPCM`. The per-user agent is `~/Library/LaunchAgents/local.hdmi-lpcm.plist`. It starts at login and restarts after process exit with a 30-second throttle. Installation immediately activates the listener and may restore the requested format if playback is idle.

## Event handling

The listener subscribes to device-list and CoreAudio service-restart events, plus the selected device's stream, alive, running and nominal-rate changes, and its stream's physical/virtual formats and available formats. It reattaches listeners after changes and schedules a bounded settling window at approximately 1, 3, 7 and 15 seconds after the latest event. New events supersede earlier attempts. There is no endless timer or playback loop. The transition to idle can trigger another attempt after playback ends.

A running application may hold the audio device open even while apparently paused; in that case restoration remains deferred. Close that application's audio session if necessary. This program restores LPCM transport, not Dolby encoding or decoding.

## Inspect and verify

```sh
base="$HOME/Library/Application Support/HDMILPCM"
"$base/hdmi-lpcm" check "$base/config.json"
launchctl print "gui/$(id -u)/local.hdmi-lpcm"
tail -n 30 "$base/service.log" "$base/service-error.log"
```

A complete physical test requires pausing playback, switching the TV off for about 15 seconds, switching it back on, waiting for the receiver and HDMI handshake, then checking both formats and the unchanged mapping. Repeat at least twice. Confirm rear-speaker routing in Audio MIDI Setup at a comfortable volume. Software tests alone cannot validate physical speaker routing or a power-cycle handshake.

## Rollback

Stop the listener and remove automatic startup, keeping private snapshots and logs:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/uninstall.sh"
```

To additionally restore the stream formats captured during installation, stop playback, reconnect the same HDMI endpoint, then run:

```sh
sh "$HOME/Library/Application Support/HDMILPCM/uninstall.sh" --restore-format
```

Restoration uses the same HDMI identity and mapping guards. If it fails, automatic startup has already stopped; inspect the error and select the format manually in Audio MIDI Setup. To remove the retained files after review:

```sh
rm -r "$HOME/Library/Application Support/HDMILPCM"
```

Do not replace global audio preference files as a routine rollback; they contain other devices' settings.

## Tests and limitations

```sh
sh ./Tests/run.sh
```

Tests cover advertised format selection, channel/rate rejection, LPCM filtering, rate ranges, snapshot validation, invalid commands and the constrained write surface. CI builds on a hosted macOS runner, which cannot validate a real HDMI handshake.

Local validation used an Apple M4 Mac mini and an HDMI TV/receiver endpoint already at 8 channels/192 kHz. Baseline capture, idempotent operation, nonexistent-device rejection, changed-mapping rejection, compilation without warnings and LaunchAgent startup were checked. A physical TV power cycle was observed to return the endpoint to two-channel LPCM at 96 kHz. The persisted 5.1 mapping was unchanged while CoreAudio exposed a temporary stereo layout. Restoration was safely deferred while an application kept the device busy. When the player released the device, the running listener automatically restored physical LPCM 8 channels/192 kHz/24 bit and virtual LPCM 8 channels/192 kHz/32 bit. The complete preferred mapping and saved surround configuration matched the original baseline, including rear channels 7/8. This is one observed power-cycle recovery, not a guarantee for every TV, receiver, app or macOS version. Physical acoustic routing was not tested by this software check.

## Privacy

Only generic source, scripts, documentation and CI belong in this repository. The baseline contains a device UID, mapping and original formats and stays in the local Application Support directory. Do not publish it, logs, system preference snapshots, hardware reports, usernames, home paths or compiled binaries. `.gitignore` excludes common generated files, but review your changes before publishing.

Apple API references: [property listeners](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)), [physical formats](https://developer.apple.com/documentation/coreaudio/kaudiostreampropertyavailablephysicalformats), [preferred channel layout](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertypreferredchannellayout).

Licensed under the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only). Copyright (c) 2026 HDMI LPCM Restore contributors. Not affiliated with Apple or any TV/audio manufacturer.
