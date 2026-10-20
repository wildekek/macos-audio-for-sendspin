# TODO

Goal: people who use AirPlay, and don't know Home Assistant or Music Assistant, can use Sendspin
speakers just as easily. If AirPlay doesn't make the user do something, this app shouldn't either.

1. **Signed, notarized installer** (in progress). A `.pkg` with the app and the driver, published
   on GitHub Releases, so nobody has to build anything. `Installer/build-pkg.sh` builds it, and
   `.github/workflows/release.yml` signs and notarizes it for each `v*` tag. Follow-ups: open the
   app after installing, start at login, an uninstaller.
   - The Developer ID certificates (G2) expire on 19 November 2027. Before then, create new
     ones and replace the `DEVELOPER_ID_P12` and `P12_PASSWORD` secrets (README → Release).
2. **Explain the microphone prompt.** AirPlay never asks for the microphone. On first launch,
   explain why it's needed (to pick up the audio sent to the Sendspin device; nothing is
   recorded). Later, look into a capture method that doesn't need the permission.
3. **README for end users.** Lead with: install, pick **Sendspin** in the Sound menu, choose your
   speakers. Move the protocol, build and `defaults write` details to a "For developers" section.
4. **Speaker selection front and centre.** macOS can't show speakers as sub-items of one output
   device in Control Center, so the menu bar app's speaker list has to be the obvious place to
   pick them.

Protocol work (Noise encryption, FLAC/Opus, …) is listed under Status in the README.
