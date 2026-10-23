# SendspinServerKit

A Swift package for the [Sendspin](https://www.sendspin-audio.com/) protocol on macOS.

| Target | What |
| --- | --- |
| `SendspinServerKit` | The protocol: a server for players, and a client with the source role. No CoreAudio. |
| `SendspinAudio` | CoreAudio: device control, capture from the Sendspin driver and from input devices, and the latency, loopback and sync probes. |
| `sendspin-bridge` | A CLI on both. `sendspin-bridge --help` lists what it does. |

```sh
swift build
swift test
.build/debug/sendspin-bridge --help
```

Reference implementation: [aiosendspin](https://github.com/Sendspin/aiosendspin) (Apache-2.0).
