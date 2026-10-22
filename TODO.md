# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

## Sendspin 1: required, not done

1. **Pairing.** Servers must implement all three methods: the pairing PSK token (`SP:0…`), the
   static and the dynamic pairing code (CPace). Playback works unpaired today (Noise on the
   Sentinel PSK, allowed by ticking the speaker), and speakers that only admit paired servers
   show "Needs pairing". Deliberately left until a speaker needs it. As a client (a source for
   Music Assistant) the Mac pairs by token (Pairing PSK) or by a dynamic pairing code it shows
   on screen (CPace); the static pairing code is still to do there. Spec proposal Sendspin/spec#333
   would let servers say which methods they support, so the menu could stop offering the token
   to servers that ask for a code.
2. **The other roles.** "All servers MUST implement all versions of these roles": besides
   `player`, that's `controller` (play/pause/next, group volume by the spec's algorithm,
   `switch`), `metadata` and `artwork` (what's playing; needs macOS's Now Playing info),
   `color` (derived colours, with contrast rules), `visualizer` (loudness, beat, spectrum from
   the captured audio) and `source` (audio from capture devices). A server may decline to
   activate a role, so speakers that offer them play fine today; this is conformance, not a
   bug. `controller` and `visualizer` fit the app best. Also log requests for roles we don't
   implement (a SHOULD: it's how a server notices it's out of date).

## The app

3. **Capture without the microphone permission.** The welcome window explains it (nothing is
   recorded), but a capture method that doesn't need it would be one prompt fewer.
4. **No CoreAudio calls on the main thread.** Switching the output and starting capture run off
   it; reading the device after device, volume and format changes doesn't yet. When coreaudiod
   is slow (for minutes after many restarts without a reboot), that freezes the menu.
5. **README for end users.** Install and the screenshot lead now; the protocol, build and
   `defaults write` details should move to a "For developers" section.
6. **More under Music Assistant.** Show and control what Music Assistant does with the
   Mac's input (where it plays, its volume, stop): a source can't, so this needs Music
   Assistant's own API.

## Audio: recommended or optional

7. **The player's preferred format** (`format` in `client/state`, a SHOULD): honour it when we
   can produce it.
8. **44.1 kHz-only speakers:** the resampler should already convert 48 → 44.1 kHz; add a test.
9. **Opus** (optional; smaller, lossy, patent-encumbered) and **`set_output_delay`** (optional;
   a per-speaker delay for external amplifiers).

## Loose ends

- The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new ones and
  replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
- The output device is named "Sendspin". That names the protocol, as "AirPlay" does in the same
  list, but confirm with the Open Home Foundation (the logo is already gone from the icons).
- Release builds print a harmless "failed with exit code 0" line from an Xcode build step.
- "Move to Applications" now copies in the background ("Moving…"); not yet tested by hand.

Done: the signed, notarized disk image with a welcome window that installs the driver (each
`v*` tag builds a draft release), the AirPlay-style speaker list, FLAC, Sendspin 1 over Noise,
client-initiated connections (speakers that connect to us wait, unticked, until allowed), a
notice when Local Network access is denied, opening at login, speakers that leave the
group (unavailable or `client/leave`) staying out until the user ticks them again, and playing
through Music Assistant (the Mac as a paired source).
