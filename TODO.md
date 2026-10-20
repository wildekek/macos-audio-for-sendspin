# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

## Sendspin 1: required, not done

1. **Pairing.** Servers must implement all three methods: the pairing PSK token (`SP:0…`), the
   static and the dynamic pairing code (CPace). Playback works unpaired today (Noise on the
   Sentinel PSK, allowed by ticking the speaker), and speakers that only admit paired servers
   show "Needs pairing". Not started; deliberately left until a speaker needs it.

## The app

2. **Start at login.** After a restart of the Mac the app doesn't come back by itself.
3. **Missing permissions.** The welcome window explains the microphone (nothing is recorded)
   and the local network. Without Local Network access the app still looks for speakers forever:
   detect it (Bonjour reports "policy denied") and show a notice with a button to the settings.
   Later, look into a capture method that doesn't need the microphone permission.
4. **No CoreAudio calls on the main thread.** Switching the output and starting capture run off
   it; reading the device after device, volume and format changes doesn't yet. When coreaudiod
   is slow (for minutes after many restarts without a reboot), that freezes the menu.
5. **README for end users.** Install and the screenshot lead now; the protocol, build and
   `defaults write` details should move to a "For developers" section.

## Audio: recommended or optional

6. **The player's preferred format** (`format` in `client/state`, a SHOULD): honour it when we
   can produce it.
7. **44.1 kHz-only speakers:** the resampler should already convert 48 → 44.1 kHz; add a test.
8. **Opus** (optional; smaller, lossy, patent-encumbered) and **`set_output_delay`** (optional;
   a per-speaker delay for external amplifiers).

## Loose ends

- The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new ones and
  replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
- The app icon uses the Sendspin logo; that needs the Open Home Foundation's OK.
- Release builds print a harmless "failed with exit code 0" line from an Xcode build step.
- "Move to Applications" now copies in the background ("Moving…"); not yet tested by hand.

Done: the signed, notarized disk image with a welcome window that installs the driver (each
`v*` tag builds a draft release), the AirPlay-style speaker list, FLAC, Sendspin 1 over Noise, and
client-initiated connections (speakers that connect to us wait, unticked, until allowed).
