# macOS Audio for Sendspin

Play your Mac's audio on [Sendspin](https://www.sendspin-audio.com/) speakers, in sync.
macOS Audio for Sendspin adds an output device named **Sendspin**, plus a menu bar app to
choose speakers and control their volume.

> Sendspin is a protocol of the Open Home Foundation; this project is not affiliated with
> or endorsed by it.

## Install

Download the `.pkg` from [Releases](https://github.com/wildekek/macos-audio-for-sendspin/releases)
and open it. Then pick **Sendspin** as the output in the Sound menu or Control Center, and choose
your speakers in the menu bar app. The current release is a beta.

## How it fits together

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
| `Installer/` | Builds the `.pkg` with the app and the driver; signs and notarizes it for releases. |

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

## Release

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Push a tag `v<version>`,
and the workflow builds, signs and notarizes the `.pkg`, then attaches it to a **draft** release.
Check the draft and publish it by hand. The version comes from `MARKETING_VERSION` in
`App/project.yml`, and must match the tag and `DRIVER_VERSION` in `Driver/CMakeLists.txt`.

One-time setup, with a paid Apple Developer membership:
1. On developer.apple.com → Certificates, create a *Developer ID Application* and a
   *Developer ID Installer* certificate, both with the **G2 Sub-CA** profile type (the previous
   sub-CA expires on 1 February 2027). Export both identities together as one `.p12`:
   `security export -t identities -f pkcs12 -P <password> -o developer-id.p12`.
2. App Store Connect → Users and Access → Integrations → Team Keys: create a key with the
   *Developer* role for notarization. Download the `.p8`, and note its Key ID and the Issuer ID.
3. GitHub → Settings → Environments: create `release`, limited to tags `v*`, with these secrets:

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_P12` | `base64 -i developer-id.p12` |
   | `P12_PASSWORD` | the `.p12` password |
   | `NOTARY_KEY` | contents of the `.p8` |
   | `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | from step 2 |

### Local builds

`Installer/build-pkg.sh` builds `build/release/macOS-Audio-for-Sendspin-<version>.pkg`. Without
signing variables, the package is unsigned: install it on your own Mac with
`sudo installer -pkg … -target /`, but don't distribute it. To sign and notarize locally, with
the certificates from step 1 in your keychain and a notarytool profile
(`xcrun notarytool store-credentials notary --key … --key-id … --issuer …`):

```sh
DEVELOPER_ID_APP="Developer ID Application: <Name> (<TEAMID>)" \
DEVELOPER_ID_INSTALLER="Developer ID Installer: <Name> (<TEAMID>)" \
NOTARY_PROFILE=notary \
Installer/build-pkg.sh
```

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
