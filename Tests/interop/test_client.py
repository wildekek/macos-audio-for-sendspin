# /// script
# requires-python = ">=3.12"
# dependencies = ["aiosendspin==10.2.1", "aiohttp>=3.13"]
# ///
"""Scripted Sendspin players that test the server side, as `sendspin-bridge` runs it. The
handshakes are aiosendspin's, the reference implementation's; after them each player sends
exactly what a scenario calls for, wrong where the scenario says, and the scenario checks what
the server does. A real player never misbehaves on purpose, so this is how those paths get
tested.

    uv run Tests/interop/test_client.py --bridge PATH [SCENARIO...]    # all by default

Each scenario listens on a free port on 127.0.0.1, and starts `sendspin-bridge --tone` with a
fresh `--config-dir`, dialing it by URL: nothing is announced, and the app is left alone.

Scenarios:

    message2-payload        A Noise message 2 whose payload isn't `{}` is a silent failure:
                            the server closes without server/hello (messaging.md,
                            noise/handshake).
    shutdown-reconnects     A player that says goodbye with `shutdown` is connected to again
                            (messaging.md, client/goodbye).
    silent-close-backoff    A player that closes every connection right after its handshake
                            is tried ever less often, not every second (messaging.md,
                            client/goodbye: backoff on repeated handshake failures).
    rehandshake-timeout     Paired by its pairing token, a player that never answers the
                            re-handshake to its new long-term PSK is closed after the
                            handshake timeout (connection.md, Failure Handling).
"""

import argparse
import asyncio
import contextlib
import json
import os
import shutil
import socket
import sys
import tempfile
import time

import aiohttp
from aiohttp import web
import aiosendspin.noise.driver as driver
from aiosendspin.noise.constants import SENTINEL_PSK
from aiosendspin.noise.driver import run_handshake_client, run_rehandshake_client
from aiosendspin.noise.keys import Identity, b64url_encode, psk_id_for
from aiosendspin.noise.pairing_token import PSKPairingToken, encode_psk_token
from aiosendspin.noise.session import NoiseCipherSuite
from aiosendspin.noise.trust_store import PskCategory, ResolvedPsk
from aiosendspin.noise.wire import QueuedEncryptedWebSocket

T0 = time.monotonic()
SENTINEL = ResolvedPsk(psk_id_for(SENTINEL_PSK), SENTINEL_PSK, PskCategory.SENTINEL)


def log(*args):
    print(f"{time.monotonic() - T0:7.2f}", *args, flush=True)


class Failure(Exception):
    pass


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Player:
    """A WebSocket endpoint the bridge dials; each connection goes to the scenario."""

    def __init__(self):
        self.identity = Identity.generate()
        self.pairing_psk = os.urandom(32)
        self.long_term: bytes | None = None
        self.port = free_port()
        self.connections: asyncio.Queue[tuple[web.WebSocketResponse, asyncio.Event]] = asyncio.Queue()
        self.connected_at: list[float] = []
        self.handlers: list[asyncio.Event] = []

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}/sendspin"

    @property
    def token(self) -> str:
        return encode_psk_token(PSKPairingToken(client_id=self.identity.peer_id, pairing_psk=self.pairing_psk))

    async def start(self):
        async def handle(request):
            ws = web.WebSocketResponse()
            await ws.prepare(request)
            self.connected_at.append(time.monotonic())
            done = asyncio.Event()
            self.handlers.append(done)
            self.connections.put_nowait((ws, done))
            await done.wait()  # the scenario owns the connection until it's done with it
            return ws

        app = web.Application()
        app.router.add_get("/sendspin", handle)
        self.runner = web.AppRunner(app)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port).start()

    async def next_connection(self, timeout: float):
        try:
            return await asyncio.wait_for(self.connections.get(), timeout)
        except asyncio.TimeoutError:
            raise Failure(f"the server didn't connect within {timeout:g} s") from None

    async def handshake(self, ws):
        return await run_handshake_client(ws, local_identity=self.identity, suite=NoiseCipherSuite.CHACHAPOLY,
                                          psk_resolver=self.resolve)

    async def resolve(self, psk_id: str, category: PskCategory) -> ResolvedPsk | None:
        if category is PskCategory.PAIRING and psk_id == psk_id_for(self.pairing_psk):
            return ResolvedPsk(psk_id, self.pairing_psk, PskCategory.PAIRING)
        if category is PskCategory.LONG_TERM and self.long_term and psk_id == psk_id_for(self.long_term):
            return ResolvedPsk(psk_id, self.long_term, PskCategory.LONG_TERM)
        if category is PskCategory.SENTINEL:
            return SENTINEL
        return None

    async def stop(self):
        # Connections the server made meanwhile end too, rather than hold up the shutdown.
        for done in self.handlers:
            done.set()
        await self.runner.cleanup()


class Session:
    """The application messages of one connection, after the handshake."""

    def __init__(self, result):
        self.result = result
        self.enc = result.encrypted_ws
        self.handshake_hash = result.handshake_hash
        self.inbox: asyncio.Queue[dict] = asyncio.Queue()
        self.handshakes: asyncio.Queue = asyncio.Queue()
        self.closed = asyncio.Event()
        self.reader = asyncio.ensure_future(self._read())

    async def _read(self):
        try:
            async for message in self.enc:
                if message.type == aiohttp.WSMsgType.TEXT:
                    body = json.loads(message.data)
                    if body["type"] == "noise/handshake":
                        log("player <- noise/handshake (a re-handshake's message 1)")
                        self.handshakes.put_nowait(message)
                        continue
                    if body["type"] != "server/time":
                        log(f"player <- {body['type']}")
                    self.inbox.put_nowait(body)
        finally:
            self.closed.set()

    async def send(self, type_: str, payload: dict):
        log(f"player -> {type_} {json.dumps(payload)}")
        await self.enc.send_str(json.dumps({"type": type_, "payload": payload}))

    async def expect(self, type_: str, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try:
                body = await asyncio.wait_for(self.inbox.get(), left)
            except asyncio.TimeoutError:
                break
            if body["type"] == type_:
                return body.get("payload", {})
        raise Failure(f"no {type_} within {timeout:g} s")

    async def rehandshake(self, player: "Player"):
        """Answer the server's re-handshake: message 2 under the current keys, then new ones."""
        view = QueuedEncryptedWebSocket(self.enc, self.handshakes)
        result = await run_rehandshake_client(view, local_identity=player.identity, server_id=self.result.peer_id,
                                              suite=self.result.suite, prologue=self.handshake_hash,
                                              psk_resolver=player.resolve)
        self.handshake_hash = result.handshake_hash
        log(f"player: re-handshake to the {result.psk.category.value} PSK done")

    async def hello(self):
        await self.expect("server/hello", 5)
        await self.send("client/hello", {
            "name": "Test Player", "supported_roles": ["player@v1"],
            "player@v1_support": {"supported_formats": [{"codec": "pcm", "channels": 2, "sample_rate": 48000,
                                                         "bit_depth": 16}], "buffer_capacity": 1_000_000},
            "unpaired_access": {"enabled": True},
            "supported_pair_methods": {"pairing_psk": {"locations": ["device"]}}})


class Bridge:
    def __init__(self, path: str):
        self.path = path
        self.config = tempfile.mkdtemp(prefix="sendspin-test-client-")
        self.process = None
        self.lines: list[str] = []

    async def start(self, *args: str):
        self.process = await asyncio.create_subprocess_exec(
            self.path, "--tone", "--name", "Test Server", "--config-dir", self.config, "-v", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        asyncio.ensure_future(self._drain())

    async def _drain(self):
        while line := await self.process.stdout.readline():
            self.lines.append(line.decode().rstrip())

    async def stop(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.process.wait(), 5)
        shutil.rmtree(self.config, ignore_errors=True)


class WrongMessage2Payload:
    """Stands in for aiosendspin's message 2 payload: a JSON object, but not `{}`."""

    def to_json(self) -> str:
        return '{"extra": 1}'


async def message2_payload(bridge: Bridge, player: Player):
    await bridge.start(player.url)
    ws, done = await player.next_connection(10)
    original = driver.NoiseMsg2Payload
    driver.NoiseMsg2Payload = WrongMessage2Payload
    try:
        result = await player.handshake(ws)
    finally:
        driver.NoiseMsg2Payload = original
    session = Session(result)
    try:
        body = await asyncio.wait_for(session.inbox.get(), 3)
        raise Failure(f"the server answered a malformed message 2 with {body['type']}")
    except asyncio.TimeoutError:
        pass
    if not session.closed.is_set() and not ws.closed:
        raise Failure("the server kept the connection open after a malformed message 2")
    done.set()


async def shutdown_reconnects(bridge: Bridge, player: Player):
    await bridge.start(player.url)
    ws, done = await player.next_connection(10)
    session = Session(await player.handshake(ws))
    await session.hello()
    await session.expect("server/activate", 5)
    await session.send("client/goodbye", {"reason": "shutdown"})
    await ws.close()
    done.set()
    _, again = await player.next_connection(10)
    log(f"connected again {player.connected_at[-1] - player.connected_at[-2]:.1f} s after the goodbye")
    again.set()


async def silent_close_backoff(bridge: Bridge, player: Player):
    await bridge.start(player.url)
    for _ in range(5):
        ws, done = await player.next_connection(20)
        await player.handshake(ws)
        await ws.close()
        done.set()
    gaps = [round(b - a, 1) for a, b in zip(player.connected_at, player.connected_at[1:])]
    log(f"gaps between connections: {gaps} s")
    if gaps[-1] < 3:
        raise Failure(f"still retrying every {gaps[-1]} s after {len(gaps)} handshakes that closed at once")


async def rehandshake_timeout(bridge: Bridge, player: Player):
    await bridge.start("--pair", player.token, player.url)
    ws, done = await player.next_connection(10)
    session = Session(await player.handshake(ws))
    await session.hello()
    # On the Sentinel first: an idle activation, then a re-handshake to the pairing PSK before
    # the pairing one (pairing.md, Pairing PSK Flow).
    await session.expect("server/activate", 5)
    await session.rehandshake(player)
    activate = await session.expect("server/activate", 5)
    if activate.get("pairing", {}).get("method") != "pairing_psk":
        raise Failure(f"expected a pairing_psk activation, got {activate}")
    long_term = os.urandom(32)
    await session.send("client/pair-init", {"pairing_index": 1})
    await session.send("client/pair-finalize", {"long_term_psk": b64url_encode(long_term)})
    await session.expect("server/pair-finalize", 5)
    player.long_term = long_term
    try:
        await asyncio.wait_for(session.handshakes.get(), 5)
    except asyncio.TimeoutError:
        raise Failure("no re-handshake to the long-term PSK after server/pair-finalize") from None
    started = time.monotonic()
    log("got the re-handshake's message 1; not answering it")
    try:
        await asyncio.wait_for(session.closed.wait(), 45)
    except asyncio.TimeoutError:
        raise Failure("the server kept the connection 45 s without message 2") from None
    log(f"the server closed {time.monotonic() - started:.1f} s after message 1")
    done.set()


SCENARIOS = {"message2-payload": message2_payload, "shutdown-reconnects": shutdown_reconnects,
             "silent-close-backoff": silent_close_backoff, "rehandshake-timeout": rehandshake_timeout}


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bridge", required=True, help="the sendspin-bridge binary")
    parser.add_argument("scenarios", nargs="*", metavar="SCENARIO", help=", ".join(SCENARIOS))
    args = parser.parse_args()
    if unknown := [name for name in args.scenarios if name not in SCENARIOS]:
        parser.error(f"unknown scenario {', '.join(unknown)}; there are {', '.join(SCENARIOS)}")
    failed = 0
    for name in args.scenarios or SCENARIOS:
        bridge, player = Bridge(args.bridge), Player()
        log(f"=== {name}")
        try:
            await player.start()
            await SCENARIOS[name](bridge, player)
            log(f"PASS {name}")
        except (Failure, OSError, asyncio.TimeoutError) as error:
            failed += 1
            log(f"FAIL {name}: {error}")
            log("bridge log:\n  " + "\n  ".join(bridge.lines[-30:]))
        finally:
            await bridge.stop()
            await player.stop()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
