# SendspinServerKit

A Swift implementation of the server side of the [Sendspin](https://www.sendspin-audio.com/)
protocol, plus `sendspin-bridge`, a CLI that streams an input device to Sendspin players.

Status (milestone 1):
- the legacy unencrypted handshake (current HA Connect AUX-2 firmware);
- time sync replies;
- PCM streaming with channel and bit-depth conversion;
- multiple players in one group, synced by capture host time;
- mDNS discovery;
- volume and mute commands (API only).

Not yet implemented: Noise encryption and pairing, FLAC/Opus, sample-rate conversion, and the
client-initiated listener.

```sh
swift build
swift test
.build/debug/sendspin-bridge --list
.build/debug/sendspin-bridge connect-aux              # capture BlackHole → player
.build/debug/sendspin-bridge --tone --lead-ms 300 -v ws://127.0.0.1:8929/sendspin
```

Each audio chunk's play time is its capture time (CoreAudio host time) plus `--lead-ms`, on
the same `mach_absolute_time` clock the players sync to. The timeline therefore follows the
capture clock exactly, without drift correction.

Reference implementation: [aiosendspin](https://github.com/Sendspin/aiosendspin) (Apache-2.0).
