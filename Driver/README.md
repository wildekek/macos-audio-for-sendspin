# Sendspin audio driver

An Audio Server plug-in (HAL driver) built on [libASPL](https://github.com/gavv/libASPL)
(MIT). It adds an output-only device named **Sendspin**: 48 kHz stereo float32, with volume
and mute controls. Whatever is played into it, the Sendspin app reads back
from the driver. There is no input stream: recording an input needs microphone permission,
and this is a speaker.

- The ring buffer is indexed by device sample time. Unwritten frames read as silence.
- Custom property `'ssau'` (CFDictionary): the audio from a sample time on. The qualifier is
  the sample time (CFNumber; negative for the newest frame). The value has `start` (the first
  frame's sample time), `session` (changes when the device's timeline restarts), `rate` (the
  device's sample rate) and `frames` (CFData, float32 interleaved). The app keeps the device running with a silent output
  callback, and turns sample times into host times with `AudioDeviceTranslateTime`.
- Only the app (release or dev build) and `sendspin-bridge` get `'ssau'`; anyone else gets
  `kAudioHardwareIllegalOperationError`. The driver goes by the kernel's record of the
  client's signature (`csops`: the Security framework can't run in the driver's sandbox).
  Signed with a team, the driver wants clients of that team. Signed ad hoc, as a local
  build is, it can only go by their identifier, which an ad-hoc signature can claim. So
  `sendspin-bridge`, built ad hoc, only works with an ad-hoc driver (or sign it with the
  team). Refusals are logged: `log show --predicate 'subsystem ==
  "com.sendspin-audio.mac.driver"'`.
- Volume and mute are **not** applied to the audio. The app forwards them to the players.
- The device can be the default output, but not the system-sounds device.
- Custom property `'sslu'` (CFNumber, µs): the app sets the speakers' buffer here, and the
  driver reports it as output-stream latency (in frames at the current rate) so video
  players keep lip sync. It's a duration so that a rate change needs no latency change:
  each configuration change restarts the device's IO, a gap in the audio.

```sh
cmake -S Driver -B Driver/build && cmake --build Driver/build   # universal, ad-hoc signed
Driver/tests/run_ring_test.sh                                   # ring buffer unit test
Driver/install.sh            # sudo; installs to /Library/Audio/Plug-Ins/HAL, restarts coreaudiod
Driver/install.sh -u         # uninstall
sendspin-bridge --check-loopback                                # audio comes back sample-exact
swift Driver/tests/volume.swift Sendspin 0.25                   # set/read device volume
```

Restarting coreaudiod briefly interrupts all audio. For a release build, pass
`-DCODESIGN_ID="Developer ID Application: …"`.
