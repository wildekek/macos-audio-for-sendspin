# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

1. **Signed, notarized installer** (in progress). A `.pkg` with the app and the driver, published
   on GitHub Releases, so nobody has to build anything. `Installer/build-pkg.sh` builds it, and
   `.github/workflows/release.yml` signs and notarizes it for each `v*` tag. The app starts after
   installing, and Settings → Uninstall removes the driver and the app. Neither needs a restart:
   both restart coreaudiod, as SoundSource and Loopback do. Follow-ups: start at login; if the
   device hasn't appeared a few seconds after installing, advise restarting the Mac.
   - The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new
     ones and replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
2. **Encrypted connections (Noise) and pairing**, next to the unencrypted protocol. Speakers on
   recent firmware (the AUX-2 since October 2026) only accept Noise, older ones only the
   unencrypted protocol, and a speaker can switch with a firmware update. Support both, and
   pick per speaker.
3. **Explain the permissions.** AirPlay never asks for the microphone. On first launch,
   explain why it's needed (to pick up the audio sent to the Sendspin device; nothing is
   recorded). Later, look into a capture method that doesn't need the permission.
   Without Local Network access the app looks for speakers forever: detect it (Bonjour reports
   "policy denied") and show a notice with a button to the settings.
   A speaker that needs something the app can't do (encryption, for now) should say so in its
   row instead of "Can't connect".
4. **README for end users.** Lead with: install, pick **Sendspin** in the Sound menu, choose your
   speakers. Move the protocol, build and `defaults write` details to a "For developers" section.
5. **Speaker selection front and centre.** macOS can't show speakers as sub-items of one output
   device in Control Center, so the menu bar app's speaker list has to be the obvious place to
   pick them.
6. **No CoreAudio calls on the main thread.** Switching the output already runs off it; the
   reads after device, volume and format changes still don't. When coreaudiod is slow (for
   minutes after many restarts without a reboot), each of those freezes the menu.

Other protocol work (FLAC/Opus, …) is listed under Status in the README.
