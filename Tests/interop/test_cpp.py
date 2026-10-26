# /// script
# requires-python = ">=3.12"
# ///
"""The server side against sendspin-cpp-cli, the reference player: `sendspin-bridge` pairs with
it by each method it offers, plays to it, follows its controller, takes its input, and hands it
over to a second server. sendspin-cpp-cli runs the library ESPHome speakers run, so this is what
most speakers in the field will do.

    uv run Tests/interop/test_cpp.py --bridge PATH --sendspin-cli PATH [SCENARIO...]    # all by default

Each scenario starts a fresh player (`-o null`, no mDNS, its own state directory and port on
127.0.0.1) and `sendspin-bridge` with a fresh `--config-dir`, dialing it by URL: nothing is
announced, and the app is left alone. Codes and tokens come from the player's log and control
socket; what each side reports comes from the bridge's log and the player's `status`.

Scenarios:

    unpaired-refused        A player that only plays for paired servers gets no audio from
                            a server it isn't paired with (pairing.md, Unpaired Access).
    unpaired-allowed        With --allow-unpaired it plays at once.
    controller              The player's group volume and mute (`vol`, `mute`) reach the
                            server and come back as the player's own (roles/controller).
    dynamic-code            Paired by the 6-digit code the player shows, after a wrong one
                            (pairing.md, Dynamic Pairing Code Flow).
    static-code             Paired by its 8-digit code, once `pair confirm` opens its pairing
                            window (pairing.md, Static Pairing Code Flow).
    token                   Paired by its pairing token (pairing.md, Pairing PSK Flow).
    stays-paired            A server that paired plays again later without pairing.
    unpair                  `--unpair` makes both sides forget the pairing (server/unpair).
    source                  The player's input plays on the speakers: on itself
                            (roles/source).
    another-server          A second server takes the player over; the first stays away
                            (connection.md, Multiple servers; client/goodbye another_server).
"""

import argparse
import asyncio
import contextlib
import re
import shutil
import socket
import sys
import tempfile
import time

T0 = time.monotonic()
NAME = "Cpp Speaker"
STATIC_CODE = "12345678"


def log(*args):
    print(f"{time.monotonic() - T0:7.2f}", *args, flush=True)


class Failure(Exception):
    pass


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Output:
    """A process's output as it comes, searchable while it runs."""

    def __init__(self):
        self.text = ""
        self.changed = asyncio.Event()

    async def drain(self, stream):
        while chunk := await stream.read(4096):
            self.text += chunk.decode(errors="replace")
            self.changed.set()

    async def wait(self, pattern: str, timeout: float, after: int = 0) -> re.Match:
        """The first match of `pattern` past `after`, waiting for it."""
        deadline = time.monotonic() + timeout
        while True:
            if match := re.compile(pattern).search(self.text, after):
                return match
            if (left := deadline - time.monotonic()) <= 0:
                raise Failure(f"no /{pattern}/ within {timeout:g} s")
            self.changed.clear()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.changed.wait(), left)

    def tail(self, lines: int = 25) -> str:
        return "\n  ".join(self.text.rstrip().splitlines()[-lines:])


class Player:
    """sendspin-cpp-cli, on a port of its own."""

    def __init__(self, path: str):
        self.path = path
        self.port = free_port()
        self.state = tempfile.mkdtemp(prefix="sendspin-test-cpp-")
        self.process = None
        self.output = Output()

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}/sendspin"

    async def start(self, *args: str):
        self.process = await asyncio.create_subprocess_exec(
            self.path, "-n", NAME, "--port", str(self.port), "--state-dir", self.state, "--no-mdns", "-o", "null",
            "-d", "info", *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        asyncio.ensure_future(self.output.drain(self.process.stdout))
        await self.output.wait(r"listening on port", 10)

    async def cli(self, *args: str) -> str:
        """A subcommand, over the player's control socket."""
        process = await asyncio.create_subprocess_exec(self.path, *args, "--port", str(self.port),
                                                       stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        out, _ = await process.communicate()
        if process.returncode != 0:
            raise Failure(f"sendspin-cli {' '.join(args)} exited {process.returncode}: {out.decode().strip()}")
        return out.decode()

    async def status(self) -> dict[str, str]:
        lines = (await self.cli("status")).splitlines()
        return dict(line.split(": ", 1) for line in lines if ": " in line)

    async def expect_status(self, key: str, value: str, timeout: float = 10):
        """`status` says `key: <value…>` within `timeout`."""
        deadline = time.monotonic() + timeout
        while True:
            now = (await self.status()).get(key, "")
            if now.startswith(value):
                log(f"player status {key}: {now}")
                return
            if time.monotonic() > deadline:
                raise Failure(f"player status {key} is {now!r}, not {value!r}")
            await asyncio.sleep(0.5)

    async def stop(self):
        await stop(self.process)
        shutil.rmtree(self.state, ignore_errors=True)


class Bridge:
    """sendspin-bridge with a config directory of its own, codes typed on stdin."""

    def __init__(self, path: str, name: str = "Test Server"):
        self.path = path
        self.name = name
        self.config = tempfile.mkdtemp(prefix="sendspin-test-cpp-bridge-")
        self.process = None
        self.output = Output()

    async def start(self, *args: str):
        self.output = Output()
        self.process = await asyncio.create_subprocess_exec(
            self.path, "--name", self.name, "--config-dir", self.config, "-v", *args,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        asyncio.ensure_future(self.output.drain(self.process.stdout))

    async def type(self, text: str):
        log(f"bridge <- {text}")
        self.process.stdin.write(f"{text}\n".encode())
        await self.process.stdin.drain()

    async def stop(self):
        await stop(self.process)

    def remove(self):
        shutil.rmtree(self.config, ignore_errors=True)


async def stop(process):
    if process and process.returncode is None:
        process.terminate()
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(process.wait(), 5)


async def plays(bridge: Bridge, player: Player):
    """The bridge streams, and the player receives it."""
    match = await bridge.output.wait(rf"{NAME}: streaming (\S+ \d+ Hz)", 15)
    log(f"bridge streams {match.group(1)}")
    await player.expect_status("stream", "receiving")


async def paired(bridge: Bridge, player: Player):
    await bridge.output.wait(rf"{NAME}: paired", 30)
    await player.expect_status("trust", "paired")
    await plays(bridge, player)


async def unpaired_refused(bridge: Bridge, player: Player):
    await player.start()
    await bridge.start("--tone", player.url)
    match = await bridge.output.wait(rf"{NAME}: (pairing required|.*needs pairing.*)", 15)
    log(f"bridge: {match.group(0)}")
    await asyncio.sleep(3)
    if re.search(rf"{NAME}: streaming", bridge.output.text):
        raise Failure("the bridge streamed to a player it isn't paired with")
    await player.expect_status("stream", "idle")


async def unpaired_allowed(bridge: Bridge, player: Player):
    await player.start("--allow-unpaired")
    await bridge.start("--tone", player.url)
    await plays(bridge, player)
    await player.expect_status("trust", "unpaired")


async def controller(bridge: Bridge, player: Player):
    await player.start("--allow-unpaired")
    await bridge.start("--tone", player.url)
    await plays(bridge, player)
    await player.cli("vol", "30")
    await bridge.output.wait(rf"{NAME}: controller volume 30", 10)
    await player.expect_status("player volume", "30")
    await player.cli("mute", "on")
    await bridge.output.wait(rf"{NAME}: controller mute true", 10)
    await player.expect_status("player volume", "30 (muted)")
    await player.cli("mute", "off")
    await player.expect_status("player volume", "30")


async def dynamic_code(bridge: Bridge, player: Player):
    await player.start()
    await bridge.start("--tone", "--pair", "dynamic", player.url)
    code = (await player.output.wait(r"\*\*\* Pairing code: (\d{3}-?\d{3}) \*\*\*", 20)).group(1)
    log(f"the player shows {code}")
    wrong = "000000" if code.replace("-", "") != "000000" else "111111"
    await bridge.type(wrong)
    await bridge.output.wait(r"That code didn't match", 20)
    # The same code for every round of an attempt (pairing.md, Rounds).
    await bridge.type(code)
    await paired(bridge, player)


async def static_code(bridge: Bridge, player: Player):
    await player.start("--pairing-code", STATIC_CODE)
    await bridge.start("--tone", "--pair", "static", player.url)
    await player.output.wait(r"A server is waiting to pair", 20)
    await player.cli("pair", "confirm")
    await bridge.type(STATIC_CODE)
    await paired(bridge, player)


async def pairing_token(player: Player) -> str:
    return re.search(r"SP:[0-9A-Za-z]+", await player.cli("pair-token")).group(0)


async def token(bridge: Bridge, player: Player):
    await player.start()
    await bridge.start("--tone", "--pair", await pairing_token(player), player.url)
    await paired(bridge, player)


async def stays_paired(bridge: Bridge, player: Player):
    await token(bridge, player)
    await bridge.stop()
    await bridge.start("--tone", player.url)
    await plays(bridge, player)
    if re.search(rf"{NAME}: paired", bridge.output.text):
        raise Failure("the bridge paired again")
    await player.expect_status("trust", "paired")


async def unpair(bridge: Bridge, player: Player):
    await player.start()
    await bridge.start("--tone", "--pair", await pairing_token(player), "--unpair", player.url)
    await bridge.output.wait(rf"{NAME}: paired", 30)
    await bridge.output.wait(rf"{NAME}: pairing forgotten", 15)
    # It drops its record and hangs up (messaging.md, server/unpair).
    await player.output.wait(r"server/unpair: dropping record", 10)


async def source(bridge: Bridge, player: Player):
    await player.start("--allow-unpaired", "--input", "tone")
    await bridge.start("--input", player.url, player.url)
    await bridge.output.wait(rf"{NAME}: input streaming (\S+ \d+ Hz)", 15)
    await player.expect_status("input", "tone")
    if "streaming" not in (await player.status()).get("input", ""):
        raise Failure("the player's input isn't streaming")
    await plays(bridge, player)


async def another_server(bridge: Bridge, player: Player):
    await player.start("--allow-unpaired")
    await bridge.start("--tone", player.url)
    await plays(bridge, player)
    second = Bridge(bridge.path, "Second Server")
    try:
        await second.start("--tone", player.url)
        await second.output.wait(rf"{NAME}: streaming", 15)
        await bridge.output.wait(rf"{NAME}: taken", 10)
        await player.expect_status("server", "Second Server")
        # another_server: the server SHOULD NOT reconnect by itself (messaging.md, client/goodbye).
        taken = len(bridge.output.text)
        await asyncio.sleep(10)
        if re.search(rf"{NAME}: (connecting|hello)", bridge.output.text[taken:]):
            raise Failure("the first server connected again by itself")
        await player.expect_status("server", "Second Server")
    finally:
        await second.stop()
        second.remove()


SCENARIOS = {"unpaired-refused": unpaired_refused, "unpaired-allowed": unpaired_allowed, "controller": controller,
             "dynamic-code": dynamic_code, "static-code": static_code, "token": token, "stays-paired": stays_paired,
             "unpair": unpair, "source": source, "another-server": another_server}


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bridge", required=True, help="the sendspin-bridge binary")
    parser.add_argument("--sendspin-cli", required=True, help="sendspin-cpp-cli's sendspin-cli binary")
    parser.add_argument("scenarios", nargs="*", metavar="SCENARIO", help=", ".join(SCENARIOS))
    args = parser.parse_args()
    if unknown := [name for name in args.scenarios if name not in SCENARIOS]:
        parser.error(f"unknown scenario {', '.join(unknown)}; there are {', '.join(SCENARIOS)}")
    failed = 0
    for name in args.scenarios or SCENARIOS:
        bridge, player = Bridge(args.bridge), Player(args.sendspin_cli)
        log(f"=== {name}")
        try:
            await SCENARIOS[name](bridge, player)
            log(f"PASS {name}")
        except (Failure, OSError, asyncio.TimeoutError) as error:
            failed += 1
            log(f"FAIL {name}: {error}")
            log("bridge log:\n  " + bridge.output.tail())
            log("player log:\n  " + player.output.tail())
        finally:
            await bridge.stop()
            bridge.remove()
            await player.stop()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
