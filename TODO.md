# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

## Sendspin 1: required, not done

1. **Pairing.** Servers must implement all three methods: the pairing PSK token (`SP:0…`), the
   static and the dynamic pairing code (CPace). Playback works unpaired today (Noise on the
   Sentinel PSK, allowed by ticking the speaker), and speakers that only admit paired servers
   show "Needs pairing". Not started; deliberately left until a speaker needs it.

## The app

2. **Capture without the microphone permission.** The welcome window explains it (nothing is
   recorded), but a capture method that doesn't need it would be one prompt fewer.
3. **No CoreAudio calls on the main thread.** Switching the output and starting capture run off
   it; reading the device after device, volume and format changes doesn't yet. When coreaudiod
   is slow (for minutes after many restarts without a reboot), that freezes the menu.
4. **README for end users.** Install and the screenshot lead now; the protocol, build and
   `defaults write` details should move to a "For developers" section.
5. **Play through Music Assistant** (for people who already run it). The Mac becomes a Sendspin
   client with the `source@v1` role, and MA shows it as a Live Input that it can play on any of
   its players, so the app stops competing with MA for the same speakers. MA starts the stream
   (`start` → `client-stream/start` → type-12 chunks of at most 150 ms; FLAC at 48 kHz/16-bit is
   enough), and reporting `signal: present` while the Mac plays lets MA start it automatically.
   New: the client side (advertise `_sendspin._tcp` and skip ourselves when browsing, Noise as
   responder, `client/hello`, the time filter and capture times in server time) and client-side
   pairing, because MA only admits paired sources. Do it after pairing (1), which shares the
   CPace code. MA's buffering adds latency, so direct playback stays the default.

## Audio: recommended or optional

6. **The player's preferred format** (`format` in `client/state`, a SHOULD): honour it when we
   can produce it.
7. **44.1 kHz-only speakers:** the resampler should already convert 48 → 44.1 kHz; add a test.
8. **Opus** (optional; smaller, lossy, patent-encumbered) and **`set_output_delay`** (optional;
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
notice when Local Network access is denied, and opening at login.
