# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

1. **Signed, notarized disk image** (in progress). Drag the app to Applications; on first launch a
   welcome window installs the driver the app carries and asks for the permissions, each
   explained. `Release/build-dmg.sh` builds it, and `.github/workflows/release.yml` signs and
   notarizes it for each `v*` tag (the workflow's DMG step is untested until the next tag).
   Settings → Uninstall removes the driver and the app. Neither needs a restart: both restart
   coreaudiod, as SoundSource and Loopback do. Follow-up: start at login.
   - The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new
     ones and replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
2. **Pairing.** Sendspin 1 playback works unpaired (Noise on the Sentinel PSK, allowed by
   ticking the speaker). Speakers that only admit paired servers show "Needs pairing".
   Pairing would add a mutually authenticated connection: first the pairing PSK token
   (`SP:0…`), later the pairing codes (CPace). Not started.
3. **Missing permissions.** The welcome window explains the microphone (nothing is recorded)
   and the local network. Without Local Network access the app still looks for speakers forever:
   detect it (Bonjour reports "policy denied") and show a notice with a button to the settings.
   Later, look into a capture method that doesn't need the microphone permission.
4. **README for end users.** Lead with: install, pick **Sendspin** in the Sound menu, choose your
   speakers. Move the protocol, build and `defaults write` details to a "For developers" section.
5. **Speaker selection front and centre.** macOS can't show speakers as sub-items of one output
   device in Control Center, so the menu bar app's speaker list has to be the obvious place to
   pick them.
6. **No CoreAudio calls on the main thread.** Switching the output already runs off it; the
   reads after device, volume and format changes still don't. When coreaudiod is slow (for
   minutes after many restarts without a reboot), each of those freezes the menu.

Other protocol work (FLAC/Opus, …) is listed under Status in the README.
