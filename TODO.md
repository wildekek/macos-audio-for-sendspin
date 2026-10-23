# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

## Sendspin 1: required, not done

1. **Pairing.** Servers must implement all three methods: the pairing PSK token (`SP:0…`), the
   static and the dynamic pairing code (CPace); clients the token plus at most one code method. Playback works unpaired today (Noise on the
   Sentinel PSK, allowed by ticking the speaker), and speakers that only admit paired servers
   show "Needs pairing". Deliberately left until a speaker needs it. As a client (a source for
   Music Assistant) it's done: a dynamic pairing code shown on screen; the Pairing PSK is
   implemented for automated pairing, but its token isn't shown in the app. Never add the static code to the client: the
   implementation guide says to offer exactly one code method. Its display could also offer
   the code as a QR code (`qr_code` format, a SHOULD).
2. **The other roles.** "All servers MUST implement all versions of these roles": besides
   `player`, that's `controller` (play/pause/next, group volume by the spec's algorithm,
   `switch`), `metadata` and `artwork` (what's playing; needs macOS's Now Playing info),
   `color` (derived colours, with contrast rules), `visualizer` (loudness, beat, spectrum from
   the captured audio) and `source` (audio from capture devices). A server may decline to
   activate a role, so speakers that offer them play fine today; this is conformance, not a
   bug. `controller` and `visualizer` fit the app best. Also log requests for roles we don't
   implement (a SHOULD: it's how a server notices it's out of date).

## The app

3. **No CoreAudio calls on the main thread.** Switching the output and starting capture run off
   it; reading the device after device, volume and format changes doesn't yet, and neither does
   setting the device's sample rate. When coreaudiod is slow (for minutes after many restarts
   without a reboot), that freezes the menu.
4. **README for end users.** Install and the screenshot lead now; the protocol, build and
   `defaults write` details should move to a "For developers" section.
5. **More under Music Assistant.** Show and control what Music Assistant does with the
   Mac's input (where it plays, its volume, stop): a source can't, so this needs Music
   Assistant's own API.
6. **More than one server.** The spec allows one admitted connection at a time (Multiple
   servers, server-initiated): playback outranks pairing outranks idle, a pairing attempt is
   never displaced, and between two idle servers only the last one that played may take over.
   The displaced server gets `another_server` and SHOULD NOT reconnect by itself, so pairing a
   second server takes the Mac away from an idle Music Assistant until someone picks the Mac
   there again. That's by the spec; what's missing is the menu: it shows one server row, named
   after the first paired server even when that one is gone. Show every paired server, which
   one holds the connection and which were set aside, each with Forget. Also consider the
   spec's MAY: holding one pairing connection alongside a playing one, so pairing another
   server doesn't interrupt what plays.
7. **Auto-updater.** Today every update is a manual download and drag to Applications, as the
   release notes explain. AirPlay never asks for that. Check for new releases and install them
   from the app (Sparkle is the usual choice: an EdDSA-signed appcast, which the release
   workflow would publish next to the disk image). An update that changes the audio driver
   still needs the administrator password; say so before installing rather than surprising
   the user mid-update.

## Audio: recommended or optional

8. **The player's preferred format** (`format` in `client/state`, a SHOULD): honour it when we
   can produce it.
9. **44.1 kHz-only speakers:** the resampler should already convert 48 → 44.1 kHz; add a test.
   The interop test player can offer only 44.1 kHz, which makes it a check in
   `Tests/device-tests.sh`.
10. **Opus** (optional; smaller, lossy, patent-encumbered) and **`set_output_delay`** (optional;
    a per-speaker delay for external amplifiers).
11. **Follow what Apple Music plays.** Switch the sample rate and bit depth to the track's, as
    AirPlay never would. The switching is ready: a rate set from outside (as LosslessSwitcher
    does) already goes through `FormatSwitch`, with one stream restart and no gap for a bit
    depth. What's missing is knowing the track's format: there's no public API, and reading
    Apple Music's log messages, as those tools do, depends on a private format. The bit depth
    is the app's choice: the device runs 32-bit float.

## Loose ends

- The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new ones and
  replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
- The output device is named "Sendspin". That names the protocol, as "AirPlay" does in the same
  list, but confirm with the Open Home Foundation (the logo is already gone from the icons).
- Release builds print a harmless "failed with exit code 0" line from an Xcode build step.
- "Move to Applications" now copies in the background ("Moving…"); not yet tested by hand.
- Idle sleep: while a speaker is ticked, capture runs, its silent output keeps the device
  running, and coreaudiod holds a PreventUserIdleSystemSleep assertion all along. Check
  whether the Mac still sleeps by itself with the app open (the input capture of 0.6 likely
  did the same), and whether capture should rest while nothing plays.
- `Driver/install.sh` without a terminal (the admin dialog) fails on a driver path with spaces
  or parentheses, such as the dev app's: the `printf %q` escapes aren't valid in an AppleScript
  string.
- CI (`.github/workflows/test.yml`) hasn't run yet; the device tests are local only. Find out
  whether a GitHub macOS runner can install the driver and restart coreaudiod.

Done: the signed, notarized disk image with a welcome window that installs the driver (each
`v*` tag builds a draft release), capture straight from the driver with no microphone
permission, unit tests in CI, device and interop tests, the AirPlay-style speaker list, FLAC,
Sendspin 1 over Noise,
client-initiated connections (speakers that connect to us wait, unticked, until allowed), a
notice when Local Network access is denied, opening at login, speakers that leave the
group (unavailable or `client/leave`) staying out until the user ticks them again, and playing
through Music Assistant (the Mac as a paired source).
