# /// script
# requires-python = ">=3.12"
# dependencies = ["aiosendspin==10.2.1", "numpy>=2.5.4", "sounddevice>=0.5.6"]
# ///
"""A Sendspin player built on aiosendspin, the reference implementation, for testing the app
and sendspin-bridge against it. It takes PCM at every rate the Sendspin device offers
(44.1-192 kHz, 16 or 24 bit).

    uv run Tests/interop/test_player.py play [--port 8950] [--output "MacBook Pro Speakers"]

        Plays what it gets on the Mac's own speakers (not the default output: that's
        Sendspin), logging each stream/start, format and timestamp jump. It announces itself on
        this Mac only (mDNS on lo0), so the app lists it straight away and drops it when it
        exits; Music Assistant on the network doesn't see it. Tick it in the app to play.

    uv run Tests/interop/test_player.py rate-switch --bridge PATH [--formats 48000/16,96000/24,…]

        Runs `sendspin-bridge --cycle-formats` against itself and checks that each format
        switch gives exactly one stream/start, in that format, with no timestamp jumps within
        a stream, and that each new format starts no earlier than the previous one ended, at
        the same rate exactly there. Quit the app first: it would switch the device's rate too.
"""

import argparse
import asyncio
import base64
import collections
import contextlib
import os
import pathlib
import shlex
import socket
import subprocess
import sys
import threading
import time

from aiosendspin.client.client import SendspinClient
from aiosendspin.client.listener import ClientListener
from aiosendspin.models.player import ClientHelloPlayerSupport, SupportedAudioFormat
from aiosendspin.models.types import AudioCodec, Roles
from aiosendspin.noise.keys import Identity
from aiosendspin.noise.trust_store import InMemoryClientPairingStore

RATES = [44100, 48000, 88200, 96000, 176400, 192000]
DEFAULT_FORMATS = "48000/16,44100/24,96000/16,192000/24,48000/24,48000/16"
T0 = time.monotonic()


def log(*args):
    print(f"{time.monotonic() - T0:7.2f}", *args, flush=True)


def player_client(identity: Identity, name: str) -> SendspinClient:
    return SendspinClient(
        identity, name, [Roles.PLAYER], pairing_store=InMemoryClientPairingStore(),
        player_support=ClientHelloPlayerSupport(
            supported_formats=[SupportedAudioFormat(codec=AudioCodec.PCM, channels=2, sample_rate=rate,
                                                    bit_depth=depth)
                               for rate in RATES for depth in (24, 16)],
            buffer_capacity=8_000_000),
        min_buffer_ms=300, required_lead_time_ms=300)


class Streams:
    """What arrives: one entry per stream/start, with its format, chunks and timestamp jumps."""

    def __init__(self):
        self.streams: list[dict] = []

    def start(self):
        self.streams.append({"format": None, "chunks": 0, "jumps": [], "first_ts": None, "end_ts": None})

    def chunk(self, ts: int, data: bytes, fmt) -> tuple[bool, float | None]:
        """Record a chunk; returns (whether the format is new, timestamp jump in ms or None)."""
        if not self.streams:
            self.start()
        stream = self.streams[-1]
        pcm = fmt.pcm_format
        key = (pcm.sample_rate, pcm.bit_depth)
        new_format = key != stream["format"]
        if new_format and stream["chunks"]:
            # A format change without stream/start counts as a stream of its own.
            self.start()
            stream = self.streams[-1]
        stream["format"] = key
        jump = None
        if stream["end_ts"] is not None and abs(ts - stream["end_ts"]) > 1000:
            jump = (ts - stream["end_ts"]) / 1000
            stream["jumps"].append(jump)
        frames = len(data) // (pcm.bit_depth // 8 * pcm.channels)
        if stream["first_ts"] is None:
            stream["first_ts"] = ts
        stream["end_ts"] = ts + frames * 1_000_000 // pcm.sample_rate
        stream["chunks"] += 1
        return new_format, jump


# MARK: play


def load_identity(name: str) -> Identity:
    """One identity across runs: a new one each start shows as "Identity changed" in the app."""
    path = pathlib.Path.home() / ".config" / "sendspin-test-player" / f"{name}.key"
    if path.exists():
        return Identity.from_private_bytes(base64.b64decode(path.read_text()))
    identity = Identity.generate()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(base64.b64encode(identity.private_bytes).decode())
    path.chmod(0o600)
    return identity


@contextlib.contextmanager
def announced(name: str, port: int):
    """Announce the player over mDNS on lo0 only, at 127.0.0.1, for as long as it runs. The
    announcement watches this process, so it goes when the player does, even when killed."""
    host = f"sendspin-test-player-{port}.local"
    register = shlex.join(["dns-sd", "-i", "lo0", "-P", name, "_sendspin._tcp", "local", str(port), host,
                           "127.0.0.1", "path=/sendspin", f"name={name}"])
    script = (f"{register} >/dev/null 2>&1 & registration=$!; trap 'kill $registration' EXIT; "
              f"while kill -0 {os.getpid()} 2>/dev/null; do sleep 1; done")
    process = subprocess.Popen(["/bin/sh", "-c", script])
    try:
        yield
    finally:
        process.terminate()


class Output:
    """A PortAudio stream on the Mac's speakers, fed from a queue of decoded chunks."""

    def __init__(self, device: str):
        import sounddevice
        self.sd = sounddevice
        self.device = device
        self.lock = threading.Lock()
        self.queue: collections.deque = collections.deque()
        self.pending = None
        self.stream = None
        self.rate = None
        self.underruns = 0

    def open(self, rate: int):
        import numpy as np
        self.close()
        self.rate = rate
        self.pending = np.zeros((0, 2), dtype=np.float32)

        def stream():
            return self.sd.OutputStream(device=self.device, samplerate=rate, channels=2, dtype="float32",
                                        callback=self.callback, latency="high")
        try:
            self.stream = stream()
        except self.sd.PortAudioError:
            # PortAudio reads the device list once; after a coreaudiod restart it's stale.
            self.sd._terminate()
            self.sd._initialize()
            self.stream = stream()
        log(f"output open: {self.device} at {rate} Hz")

    def close(self):
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
            self.rate = None
        with self.lock:
            self.queue.clear()

    def push(self, frames):
        with self.lock:
            self.queue.append(frames)

    def start(self):
        if self.stream and not self.stream.active:
            self.stream.start()

    def callback(self, out, frames, _time, _status):
        import numpy as np
        with self.lock:
            while len(self.pending) < frames and self.queue:
                self.pending = np.concatenate([self.pending, self.queue.popleft()])
            n = min(frames, len(self.pending))
            out[:n] = self.pending[:n]
            out[n:] = 0
            self.pending = self.pending[n:]
        if n < frames:
            self.underruns += 1


def decode(data: bytes, bit_depth: int):
    import numpy as np
    if bit_depth == 16:
        return np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
    raw = np.frombuffer(data, dtype=np.uint8).reshape(-1, 3).astype(np.int32)
    value = raw[:, 0] | (raw[:, 1] << 8) | (raw[:, 2] << 16)
    value = np.where(value & 0x800000, value - 0x1000000, value)
    return value.astype(np.float32) / 8388608.0


async def play(args):
    identity = load_identity(args.name)
    loop = asyncio.get_running_loop()
    output = Output(args.output)

    async def on_connection(ws):
        client = player_client(identity, args.name)
        await client.set_unpaired_access(enabled=True)
        streams = Streams()

        def stream_start(_message):
            log("stream/start")
            streams.start()

        def stream_end(roles):
            log("stream/end", roles, f"(underruns so far {output.underruns})")
            loop.call_soon(output.close)

        def chunk(ts, data, fmt, _send_ahead):
            new_format, jump = streams.chunk(ts, data, fmt)
            pcm = fmt.pcm_format
            if new_format:
                log(f"format {pcm.sample_rate} Hz {pcm.bit_depth}-bit")
            # A new rate needs a new output; a new bit depth plays on, so what's queued stays
            # and any gap heard is the stream's, not this player's.
            if pcm.sample_rate != output.rate:
                output.open(pcm.sample_rate)
                # Start playing when the first chunk is due.
                delay = max(0, client.compute_play_time(ts) - client.now_us()) / 1e6
                loop.call_later(delay, output.start)
            if jump is not None:
                log(f"timestamp jump {jump:+.1f} ms")
            output.push(decode(data, pcm.bit_depth).reshape(-1, pcm.channels))

        client.add_stream_start_listener(stream_start)
        client.add_stream_end_listener(stream_end)
        client.add_audio_chunk_listener(chunk)
        disconnected = asyncio.Event()
        client.add_disconnect_listener(disconnected.set)
        await client.attach_websocket(ws)
        log("server connected")
        await disconnected.wait()
        output.close()
        log("server disconnected")

    listener = ClientListener(identity.peer_id, on_connection, port=args.port, host="127.0.0.1",
                              advertise_mdns=False)
    await listener.start()
    with announced(args.name, args.port):
        log(f"listening on ws://127.0.0.1:{args.port}/sendspin as {args.name!r}, playing on {args.output}")
        await asyncio.Event().wait()


# MARK: rate-switch


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


async def rate_switch(args) -> int:
    formats = [tuple(int(part) for part in item.split("/")) for item in args.formats.split(",")]
    expected = [f for i, f in enumerate(formats) if i == 0 or f != formats[i - 1]]
    port = free_port()
    streams = Streams()
    done = asyncio.Event()

    async def on_connection(ws):
        client = player_client(Identity.generate(), "Rate switch test player")
        await client.set_unpaired_access(enabled=True)
        client.add_stream_start_listener(lambda _message: streams.start())
        client.add_audio_chunk_listener(lambda ts, data, fmt, _send_ahead: streams.chunk(ts, data, fmt))
        disconnected = asyncio.Event()
        client.add_disconnect_listener(disconnected.set)
        await client.attach_websocket(ws)
        await asyncio.wait([asyncio.create_task(disconnected.wait()), asyncio.create_task(done.wait())],
                           return_when=asyncio.FIRST_COMPLETED)
        await client.disconnect()

    listener = ClientListener(Identity.generate().peer_id, on_connection, port=port, host="127.0.0.1",
                              advertise_mdns=False)
    await listener.start()
    bridge = await asyncio.create_subprocess_exec(
        args.bridge, "--cycle-formats", args.formats, "--every", str(args.every), "--lead-ms", "400",
        f"ws://127.0.0.1:{port}/sendspin",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
    bridge_log, _ = await bridge.communicate()
    done.set()
    await asyncio.sleep(0.2)
    await listener.stop()

    received = [s for s in streams.streams if s["chunks"]]
    print(f"expected {len(expected)} streams: " + ", ".join(f"{r}/{b}" for r, b in expected))
    for i, stream in enumerate(received):
        rate, depth = stream["format"]
        gap = ""
        if i:
            previous = received[i - 1]
            gap = f", {(stream['first_ts'] - previous['end_ts']) / 1000:.0f} ms after the previous one"
        print(f"  stream {i + 1}: {rate}/{depth}, {stream['chunks']} chunks, "
              f"{len(stream['jumps'])} timestamp jumps{gap}")
    failures = []
    if bridge.returncode != 0:
        failures.append(f"sendspin-bridge exited with {bridge.returncode}")
    if [s["format"] for s in received] != expected:
        failures.append("the streams aren't one per format switch, in order")
    if any(s["jumps"] for s in received):
        failures.append("timestamps jump within a stream")
    # A new format starts where the previous one ended, never before it (player/v1.md,
    # stream/start); a rate switch may leave a gap, as the device's timeline restarts, but a
    # bit depth switch keeps the rate and must not.
    for previous, stream in zip(received, received[1:]):
        gap_ms = (stream["first_ts"] - previous["end_ts"]) / 1000
        if gap_ms < -0.05:
            failures.append(f"{stream['format']} starts {-gap_ms:.1f} ms before the previous format ended")
        elif stream["format"][0] == previous["format"][0] and gap_ms > 0.05:
            failures.append(f"a {gap_ms:.1f} ms gap switching to {stream['format']} at the same rate")
    for failure in failures:
        print("FAIL:", failure)
    if failures:
        print("sendspin-bridge said:\n" + bridge_log.decode(errors="replace"))
    print("FAIL" if failures else "PASS")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    play_args = commands.add_parser("play", help="play on the Mac's speakers")
    play_args.add_argument("--port", type=int, default=8950)
    play_args.add_argument("--name", default="Rate test player")
    play_args.add_argument("--output", default="MacBook Pro Speakers")
    switch_args = commands.add_parser("rate-switch", help="check format switches against sendspin-bridge")
    switch_args.add_argument("--bridge", required=True)
    switch_args.add_argument("--formats", default=DEFAULT_FORMATS)
    switch_args.add_argument("--every", type=float, default=3)
    args = parser.parse_args()
    if args.command == "play":
        with contextlib.suppress(KeyboardInterrupt):
            asyncio.run(play(args))
        return 0
    return asyncio.run(rate_switch(args))


if __name__ == "__main__":
    sys.exit(main())
