# macOS Audio for Sendspin

Play your Mac's audio on [Sendspin](https://www.sendspin-audio.com/) speakers, in sync.
macOS Audio for Sendspin adds an output device named **Sendspin**, plus a menu bar app to
choose speakers and control their volume.

> Sendspin is a protocol of the Open Home Foundation; this project is not affiliated with
> or endorsed by it.

```
apps ─► "Sendspin" output device (Driver/, HAL plug-in)
           │ loopback, same host clock
           ▼
        menu bar app (App/) ── SendspinServerKit (Packages/) ── ws:// ──► speakers
```

| Path | What |
| --- | --- |
| `Driver/` | Audio Server plug-in on libASPL: the loopback device, with volume/mute and a reported latency. |
| `Packages/SendspinServerKit/` | Sendspin server in Swift (`SendspinServerKit`), CoreAudio capture and device control (`SendspinAudio`), and the `sendspin-bridge` CLI. |
| `App/` | SwiftUI menu bar app (XcodeGen project). |

## Build and run

Requirements: macOS 14+, Xcode 26+, CMake, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cmake -S Driver -B Driver/build && cmake --build Driver/build
Driver/install.sh                  # admin; restarts coreaudiod (audio drops for a moment)

cd App && xcodegen generate
xcodebuild -project MacOSAudioForSendspin.xcodeproj -scheme MacOSAudioForSendspin -derivedDataPath build build
open "build/Build/Products/Debug/macOS Audio for Sendspin.app"
```

On first launch, allow microphone access (needed to read the Sendspin device's loopback)
and local network access (needed to find speakers).

## How it works

- **Device.** Audio played to *Sendspin* is looped back to the device's input, sample-exact.
  Its volume and mute controls aren't applied to the audio: the app forwards them to the
  speakers, so the volume keys and Control Center control the speakers.
- **Timing.** Each captured block is scheduled at its capture host time plus the *speaker
  buffer* (300 ms / 600 ms / 1 s). Capture timestamps equal the output timestamps apps see
  (`sendspin-bridge --measure-latency` reports 0.00 ms), so the driver reports exactly the
  buffer as output latency, and video players keep lip sync.
  Verified acoustically on an HA Connect AUX-2 (`sendspin-bridge --measure-sync`): +0.5 ms.
  Safari honours it. Firefox reads the latency but doesn't delay video by it, as with
  Bluetooth headphones. Use Safari, a smaller buffer, or a video-delay extension there.
- **Format.** The device runs at 44.1–192 kHz in 32-bit float. The menu offers the
  sample rate and bit depth (16/24) combinations the selected speakers support; picking
  one switches the device rate and the stream. A speaker that can't take the active format
  gets the closest one it supports: resampled (96 → 48 kHz, 88.2 → 44.1 kHz) and/or at its
  own bit depth, with TPDF dither for 16-bit.
- **Idle.** After 3 s of digital silence the speakers get `stream/end`. The stream restarts
  with the next sound.
- **Volume.** Group volume is the speakers' average. Changing it shifts every speaker
  equally, so their relative balance is kept (the same algorithm as aiosendspin).

Hidden settings (`defaults write eu.vooijs.MacOSAudioForSendspin …`):
- `manualPlayers`: an array of `ws://host:port/path` URLs, for speakers mDNS can't find;
- `verboseLogging`: debug logs on stderr.

## Status

Current HA Connect AUX-2 firmware speaks only the legacy unencrypted protocol, and that is
what's implemented. Not yet done: Noise encryption and pairing, FLAC/Opus, sample-rate
conversion for 44.1 kHz-only speakers, the client-initiated listener, and signed and
notarized releases.
