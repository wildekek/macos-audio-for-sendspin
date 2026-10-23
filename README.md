<p align="center">
  <img src="App/MacOSAudioForSendspin/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="App icon: a bookshelf speaker on a graphite tile">
</p>

<h1 align="center">macOS Audio for Sendspin</h1>

<p align="center">Play your Mac's audio on <a href="https://www.sendspin-audio.com/">Sendspin</a> speakers, in sync.</p>

Sendspin enables wireless, lossless and hi-res music streaming to your speakers. With macOS Audio for Sendspin, wireless
bit-perfect playback is finally possible on your Mac.

macOS Audio for Sendspin adds an output device named **Sendspin**, plus a menu bar app to
choose speakers and control their volume:

<img src="docs/menu.png" width="464" alt="The speaker icon in the menu bar, filled while the Mac plays, with its menu open: Sendspin speakers chosen, with a Home Assistant Connect AUX-2 ticked beneath it with its volume slider; then Music Assistant and the MacBook Pro Speakers.">

> Sendspin is a protocol of the Open Home Foundation;
> this project is not affiliated with or endorsed by it.

## What you need

Speakers or players that speak **Sendspin 1**, the encrypted version of the protocol (still a
release candidate in October 2026). Sendspin's own site keeps
[the current list](https://www.sendspin-audio.com/#whole-room).

- **[Home Assistant Voice Preview Edition](https://www.home-assistant.io/voice-pe/)** ($59).
  Plugs into any powered speaker, amplifier or receiver (3.5 mm). Needs firmware built on
  ESPHome 2026.10 or later.
- **[Apollo CAST-1](https://apolloautomation.com/blogs/news/meet-cast-1-audio-casting)**
  ($30). A small adapter with a PCM5122 DAC for powered speakers, amplifiers and receivers.
  Runs ESPHome, with the same requirement.
- **Build your own** for under $10: [SendspinZero](https://github.com/RealDeco/SendspinZero),
  an ESP32-S3 with a DAC board, on ESPHome 2026.10 or later.
- **A Raspberry Pi or any Linux computer** with a DAC or speakers:
  [the Sendspin daemon](https://github.com/Sendspin/sendspin-cli), from a release built on
  aiosendspin 10 or later (8.0.0 isn't yet).

### Already running Music Assistant?

Then **Music Assistant** shows up in the menu, next to Sendspin speakers. Set this Mac up in
Music Assistant and enter the code the Mac shows, and Music Assistant can play the Mac's
audio on any of its speakers and groups, AirPlay, Chromecast and Sonos included: choose it in
the menu, and select this Mac as an input source there. Music Assistant chooses the speakers
and the volume, and it isn't in sync with the Sendspin speakers in the menu, so the Mac plays
to one or the other.

## Install

Download the disk image from [Releases](https://github.com/wildekek/macos-audio-for-sendspin/releases),
open it and drag the app to Applications. On first launch it installs its audio driver (your
password once) and asks for local network access. Then tick your speakers in the
menu bar app: that switches the Mac to Sendspin speakers. The current release is a beta.

## Why not just AirPlay?

If your speakers have AirPlay, it is the easier choice: it's built into every Mac, needs
no driver or permissions, and works from your iPhone too. This app is for Sendspin speakers,
and if sound quality matters to you, it has a few things going for it:

- **Lossless up to 24-bit/192 kHz.** AirPlay from the Music app or an iPhone is lossy (AAC);
  only the Mac's system-wide AirPlay output is lossless, and only at 16-bit/44.1 kHz. With
  Sendspin, every speaker gets PCM or FLAC at the best sample rate and bit depth it supports.
- **No conversion to 44.1 kHz.** Most Mac audio is 48 kHz: video, games, browsers. AirPlay
  has to resample it; a 48 kHz Sendspin speaker gets it as it is.
- **Bit-perfect.** Measured: test files at 48 and 96 kHz, 16 and 24 bit, over PCM and FLAC,
  reach the speaker sample for sample. Volume sets the speakers' volume instead of scaling
  the audio.
- **Every speaker its own format.** A hi-res DAC isn't held back by a 16-bit speaker in the
  same group.
- **Tight sync, little delay.** Sendspin requires every speaker to stay within ±1 ms of the
  shared clock. The speaker buffer is 300 ms to 1 s, and macOS knows it, so video keeps lip
  sync (measured +0.5 ms on an HA Connect AUX-2).
- **Fast.** AirPlay can feel sluggish when changing volume or skipping a track: the Mac's
  system-wide AirPlay output runs about 2 s behind. Sendspin is snappy: volume reaches the
  speakers at once, and a skipped track starts after the speaker buffer, 300 ms by default.
- **Open hardware.** No licence or certification: a Raspberry Pi with a DAC board, an ESP32
  build, or a Home Assistant speaker.

Most Sendspin speakers today play 48 kHz/16-bit; for hi-res you need a hi-res player.

## How it fits together

```
apps ─► "Sendspin" output device (Driver/, HAL plug-in)
           │ read back from the driver, same host clock
           ▼
        menu bar app (App/) ── SendspinServerKit (Packages/) ── ws:// ──► speakers
                                         └── ws:// ──► Music Assistant (as a source)
```

| Path | What |
| --- | --- |
| `Driver/` | Audio Server plug-in on libASPL: the output-only Sendspin device, which hands what's played to it to the app, with volume/mute and a reported latency. |
| `Packages/SendspinServerKit/` | Sendspin server, and client with the source role, in Swift (`SendspinServerKit`); CoreAudio capture and device control (`SendspinAudio`); and the `sendspin-bridge` CLI (`--source` makes it a source for Music Assistant). |
| `App/` | SwiftUI menu bar app (XcodeGen project). It carries the driver and installs it itself. |
| `Release/` | Builds the disk image; signs and notarizes it for releases. |
| `Tests/` | Tests that need the installed driver (`device-tests.sh`), and a test player built on aiosendspin (`interop/`). |
| `docs/menu-states.md` | What the menu shows in each situation, what every state means, and the rules behind them. Keep it in step with the menu. |

## Build and run

Requirements: macOS 14+, Xcode 26+, CMake, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd App && xcodegen generate
xcodebuild -project MacOSAudioForSendspin.xcodeproj -scheme MacOSAudioForSendspin -derivedDataPath build build
open "build/Build/Products/Debug/macOS Audio for Sendspin (Dev).app"
```

The build compiles the driver with CMake and embeds it in the app
(`Contents/Library/Audio/Plug-Ins/HAL`). On first launch the welcome window installs it, which
restarts coreaudiod (audio drops for a moment), and asks for local network access (to find
speakers). When working on the driver alone, `Driver/install.sh` installs a CMake build
directly. Each install restarts coreaudiod; after many without a reboot, macOS can keep
coreaudiod busy for minutes (driven by AirPlayXPCHelper). A reboot clears it.

Debug builds are a separate app, "macOS Audio for Sendspin (Dev)" (`eu.vooijs.MacOSAudioForSendspin.dev`),
with their own settings and permissions, so they don't mix with an installed release. Both use
the same driver; don't run them at the same time. A build carrying another driver version offers
to install its own (an older release would put its old driver back): decline it there. A dev
build run from the build folder can't
advertise itself to speakers: mDNSResponder can't read its Info.plist inside your home folder,
and refuses the announcement (`NoAuth`). To test client-initiated connections, copy the dev
app to /Applications and run it from there.

Local builds are signed ad hoc, so each build is a new app to the Keychain, which asks again
for the app's keys. With a signing certificate, create `App/Local.xcconfig` (git ignores it)
and the Keychain keeps trusting your builds once you click *Always Allow*:

```
CODE_SIGN_IDENTITY = Developer ID Application: Your Name (TEAMID)
DEVELOPMENT_TEAM = TEAMID
```

### Tests

```sh
swift test --package-path Packages/SendspinServerKit   # unit tests, also run by CI on every push
Driver/tests/run_ring_test.sh                          # the driver's ring buffer (after a CMake build)
Tests/device-tests.sh                                  # needs the installed driver; quit the app first
```

The device tests check that the driver hands back its audio sample-exact, at the output
timestamps apps see, that a sample-rate switch restarts the device's timeline once, that other
programs are refused the audio, and that a format switch gives aiosendspin's player exactly one
new stream. They switch the device's rate and put it back.

`Tests/interop/test_player.py play` is a player to listen with: it plays on the Mac's speakers
at any rate, and announces itself on this Mac only, so the app lists it at once and drops it
when it exits (tick it to play). It needs [uv](https://docs.astral.sh/uv/).

## Release

Releases are built by GitHub Actions (`.github/workflows/release.yml`). Push a tag `v<version>`,
and the workflow builds, signs and notarizes the disk image, then attaches it to a **draft** release.
Check the draft and publish it by hand. The version comes from `MARKETING_VERSION` in
`App/project.yml` and must match the tag. Raise `DRIVER_VERSION` in `Driver/CMakeLists.txt` only
when the driver changes: the app asks users with another driver version to update it, which needs
their password.

One-time setup, with a paid Apple Developer membership:
1. On developer.apple.com → Certificates, create a *Developer ID Application* certificate with
   the **G2 Sub-CA** profile type (the previous sub-CA expires on 1 February 2027). Export the
   identity as a `.p12`: `security export -t identities -f pkcs12 -P <password> -o developer-id.p12`.
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

`Release/build-dmg.sh` builds `build/release/macOS-Audio-for-Sendspin-<version>.dmg`; it needs
[create-dmg](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`). Without
signing variables the app is signed ad hoc: fine on your own Mac, not for distribution.
`DEVELOPER_ID_APP` alone signs it without notarizing, which is enough on your own Mac too. To sign
and notarize, with the certificate from step 1 in your keychain and a notarytool profile
(`xcrun notarytool store-credentials notary --key … --key-id … --issuer …`):

```sh
DEVELOPER_ID_APP="Developer ID Application: <Name> (<TEAMID>)" \
NOTARY_PROFILE=notary \
Release/build-dmg.sh
```

## How it works

- **Connection.** Sendspin 1: every connection is end-to-end encrypted with Noise
  (`KKpsk2`, ChaChaPoly or AES-GCM, whichever the speaker picks). The app identifies itself
  with a Curve25519 key kept in the Keychain. Speakers are unpaired: ticking one in the menu
  allows it, bound to the identity it presents then, so another device using its name gets
  no audio until you allow it again (click it, or untick and tick). Both ways of connecting work: the app
  dials speakers that advertise `_sendspin._tcp`, and advertises itself as
  `_sendspin-server._tcp` (port 8927, or a free one) for speakers that look for a server. Those
  appear unticked and wait, with no activities, until you tick them; unticking one closes its
  connection, and it comes back unticked when it reconnects. Connections are pinged every 2 s:
  a speaker that answers nothing for 6 s shows as Unavailable while ticked, and the app keeps
  trying until it plays again. The list is what mDNS reports. A speaker that loses power can't
  say goodbye, and mDNS would keep it for up to 75 minutes, so each one is checked every 15 s:
  for one that doesn't answer, mDNSResponder is asked to verify its records, which drops it
  when it's really gone. Its announcement when it's back adds it again straight away.
- **Device.** *Sendspin* is an output only, like a speaker: the app reads what's played to it
  straight from the driver, sample-exact, so it needs no microphone permission. The driver
  hands that audio only to this app (and `sendspin-bridge`), going by the kernel's record of
  their code signatures. Its volume and mute controls aren't applied to the audio: the app
  forwards them to the speakers, so the volume keys and Control Center control the speakers
  (with Sendspin speakers chosen; with Music Assistant, its own volume applies).
- **Timing.** Each captured block is scheduled at its capture host time plus the *speaker
  buffer* (300 ms / 600 ms / 1 s), or more when a connected speaker asks for it
  (its `min_buffer_ms` plus `output_delay_ms`; Settings then shows why). Capture timestamps equal the output timestamps apps see
  (`sendspin-bridge --measure-latency` reports 0.00 ms), so the driver reports exactly the
  buffer as output latency, and video players keep lip sync.
  Verified acoustically on an HA Connect AUX-2 (`sendspin-bridge --measure-sync`): +0.5 ms.
  Safari honours it. Firefox reads the latency but doesn't delay video by it, as with
  Bluetooth headphones. Use Safari, a smaller buffer, or a video-delay extension there.
- **Format.** The device runs at 44.1–192 kHz in 32-bit float. Settings offers the
  sample rate and bit depth (16/24) combinations the selected speakers support; picking
  one switches the device rate and the stream, with one restart of each: a rate switch drops
  about 150 ms of audio, a bit-depth switch nothing. A speaker that can't take the active format
  gets the closest one it supports: resampled (96 → 48 kHz, 88.2 → 44.1 kHz) and/or at its
  own bit depth, with TPDF dither for 16-bit (only on samples that aren't 16-bit values
  already, so 16-bit sources and silence pass bit-perfect). Each speaker gets PCM or FLAC
  (20 ms frames, AudioToolbox's encoder), in its own order of preference, as long as our
  buffer of it fits the speaker's `buffer_capacity`; that limit is also enforced when sending.
- **Idle.** After 3 s of digital silence the speakers get `stream/end`. The stream restarts
  with the next sound.
- **Volume.** Group volume is the speakers' average. Changing it shifts every speaker
  equally, so their relative balance is kept (the same algorithm as aiosendspin).
- **Music Assistant.** The app is also a Sendspin client with the `source@v1` role: it
  advertises `_sendspin._tcp` (port 8928, or a free one) with its own Curve25519 identity, and
  Music Assistant connects to it. Pairing is by dynamic pairing code: the Mac shows six digits,
  derived from the Noise handshake and both sides' nonces, and CPace (X25519, SHA-512) proves
  the operator entered them. The Pairing PSK method, which every client must implement, is for
  automated pairing between systems: its token (`SP:0…`, the client key and the pairing PSK)
  isn't shown in the app, since a person never types it (`sendspin-bridge --source` prints it). The Mac offers no static code: a client offers one code method. The
  long-term keys of up to 5 servers are kept in the Keychain (Settings → Forget unpairs). Clock sync is the Sendspin
  time filter (a 2D Kalman filter) over bursts of `client/time`. When Music Assistant asks, the
  Mac streams FLAC at the device's rate in 16 bit, 20 ms chunks stamped with their capture
  time in the server's clock, and reports `signal: present` while there's sound, so Music
  Assistant can start it automatically. With Sendspin speakers chosen it sends silence instead: the
  stream stays open, like a quiet line-in, and resumes when Music Assistant is chosen again.

Hidden settings (`defaults write eu.vooijs.MacOSAudioForSendspin …`, or `….dev` for a dev build):
- `manualPlayers`: an array of `ws://host:port/path` URLs, for speakers mDNS can't find;
- `verboseLogging`: debug logs on stderr.

## Status

Implements Sendspin 1 (release candidate): as a server with unpaired access, and as a client
with the source role, paired by dynamic pairing code (or the pairing token). Tested against aiosendspin 10.2.1, Music
Assistant 2.10.7 and an HA Connect AUX-2 (firmware 2026.10.3). The pre-1.0 unencrypted protocol
isn't supported. Speakers that only admit paired servers show "Needs pairing". Not yet done:
pairing with speakers (the server side), Opus, and a test of 44.1 kHz-only speakers (the
resampler should already handle them).
