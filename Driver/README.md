# Sendspin audio driver

An Audio Server plug-in (HAL driver) built on [libASPL](https://github.com/gavv/libASPL)
(MIT). It adds an output device named **Sendspin**: 48 kHz stereo float32, with volume and
mute controls. Whatever is played into it is looped back to the device's input, where the
macOS Audio for Sendspin app captures it.

- The ring buffer is indexed by device sample time. Unwritten frames read as silence.
- Volume and mute are **not** applied to the audio. The app forwards them to the players.
- The device can be the default output, but not the system-sounds device.
- Custom property `'sslt'` (CFNumber, frames): the app sets the speakers' buffer here, and the
  driver reports it as output-stream latency so video players keep lip sync.

```sh
cmake -S Driver -B Driver/build && cmake --build Driver/build   # universal, ad-hoc signed
Driver/tests/run_ring_test.sh                                   # ring buffer unit test
Driver/install.sh            # sudo; installs to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
Driver/install.sh -u         # uninstall
uv run Driver/tests/loopback_check.py                           # loopback is sample-exact
swift Driver/tests/volume.swift Sendspin 0.25                   # set/read device volume
```

Restarting coreaudiod briefly interrupts all audio. For a release build, pass
`-DCODESIGN_ID="Developer ID Application: …"`.
