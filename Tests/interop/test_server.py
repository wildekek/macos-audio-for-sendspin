# /// script
# requires-python = ">=3.12"
# dependencies = ["aiosendspin==10.2.1", "aiohttp>=3.13"]
# ///
"""Scripted Sendspin servers that test the Mac's source client, as `sendspin-bridge --source`
runs it. The handshakes are aiosendspin's, the reference implementation's; after them each
server sends exactly what a scenario calls for, wrong where the scenario says, and the
scenario checks what the client answers. A real server never misbehaves on purpose, so this
is how those paths get tested.

    uv run Tests/interop/test_server.py --bridge PATH [SCENARIO...]    # all by default

Each scenario starts its own `sendspin-bridge --source --tone --no-advertise` with a fresh
`--config-dir` and dials the port it logs: nothing is announced on the network, and Music
Assistant and the app are left alone.

Scenarios:

    rehandshake-bad-method   After a re-handshake to the pairing PSK, an activation for a
                             method the client doesn't offer under it is answered with
                             pair/abort method_not_supported, and the connection carries on
                             (connection.md, Re-handshake; messaging.md, server/activate).
    admission-race           Two servers' first activations, at the same moment, displace an
                             idle one: one is admitted, the other refused, never both
                             (connection.md, Multiple servers).
"""

import argparse
import asyncio
import contextlib
import json
import re
import shutil
import sys
import tempfile
import time

import aiohttp
from aiosendspin.noise.constants import SENTINEL_PSK
from aiosendspin.noise.driver import run_handshake_server, run_rehandshake_server
from aiosendspin.noise.keys import Identity, psk_id_for
from aiosendspin.noise.pairing_token import decode_psk_token
from aiosendspin.noise.trust_store import PskCategory, ResolvedPsk
from aiosendspin.noise.wire import QueuedEncryptedWebSocket

T0 = time.monotonic()
SENTINEL = ResolvedPsk(psk_id_for(SENTINEL_PSK), SENTINEL_PSK, PskCategory.SENTINEL)


def log(*args):
    print(f"{time.monotonic() - T0:7.2f}", *args, flush=True)


def now_us() -> int:
    return time.monotonic_ns() // 1000


class Failure(Exception):
    pass


class Bridge:
    """`sendspin-bridge --source` on a port of its own, with a fresh config directory."""

    def __init__(self, path: str):
        self.path = path
        self.config = tempfile.mkdtemp(prefix="sendspin-test-server-")
        self.process: asyncio.subprocess.Process | None = None
        self.token = None
        self.port = None
        self.lines: list[str] = []

    async def start(self):
        self.process = await asyncio.create_subprocess_exec(
            self.path, "--source", "--tone", "--no-advertise", "--name", "Test Source",
            "--config-dir", self.config, "-v",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        deadline = time.monotonic() + 15
        while self.token is None or self.port is None:
            if time.monotonic() > deadline:
                raise Failure("the bridge didn't print its pairing token and port")
            line = (await asyncio.wait_for(self.process.stdout.readline(), 15)).decode().rstrip()
            self.lines.append(line)
            if match := re.search(r"Pairing token: (SP:\S+)", line):
                self.token = decode_psk_token(match.group(1))
            if match := re.search(r"Listening for servers on port (\d+)", line):
                self.port = int(match.group(1))
        asyncio.ensure_future(self._drain())

    async def _drain(self):
        while line := await self.process.stdout.readline():
            self.lines.append(line.decode().rstrip())

    @property
    def url(self) -> str:
        return f"ws://127.0.0.1:{self.port}/sendspin"

    async def stop(self):
        if self.process and self.process.returncode is None:
            self.process.terminate()
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(self.process.wait(), 5)
        shutil.rmtree(self.config, ignore_errors=True)


class Server:
    """One scripted server connection: the handshake, then messages by hand. client/time is
    answered as it comes; everything else waits in the inbox for the scenario."""

    def __init__(self, name: str):
        self.name = name
        self.identity = Identity.generate()
        self.inbox: asyncio.Queue[dict] = asyncio.Queue()
        self.handshakes: asyncio.Queue = asyncio.Queue()
        self.time_requests = 0
        self.closed = asyncio.Event()

    async def connect(self, url: str):
        self.http = aiohttp.ClientSession()
        self.ws = await self.http.ws_connect(url)

        async def sentinel(_client_id: str) -> ResolvedPsk:
            return SENTINEL

        result = await run_handshake_server(self.ws, local_identity=self.identity, psk_provider=sentinel)
        self.enc, self.client_id, self.suite = result.encrypted_ws, result.peer_id, result.suite
        self.handshake_hash = result.handshake_hash
        self.reader = asyncio.ensure_future(self._read())

    async def _read(self):
        try:
            async for message in self.enc:
                if message.type != aiohttp.WSMsgType.TEXT:
                    continue
                body = json.loads(message.data)
                if body["type"] == "noise/handshake":
                    self.handshakes.put_nowait(message)
                elif body["type"] == "client/time":
                    received = now_us()
                    self.time_requests += 1
                    await self.send("server/time", {
                        "client_transmitted": body["payload"]["client_transmitted"],
                        "server_received": received, "server_transmitted": now_us()})
                else:
                    log(f"{self.name} <- {body['type']} {json.dumps(body.get('payload', {}))}")
                    self.inbox.put_nowait(body)
        finally:
            self.closed.set()

    async def send(self, type_: str, payload: dict):
        if type_ != "server/time":
            log(f"{self.name} -> {type_} {json.dumps(payload)}")
        await self.enc.send_str(json.dumps({"type": type_, "payload": payload}))

    async def expect(self, type_: str, timeout: float) -> dict:
        """The next message of this type; others before it are skipped."""
        deadline = time.monotonic() + timeout
        while (left := deadline - time.monotonic()) > 0:
            try:
                body = await asyncio.wait_for(self.inbox.get(), left)
            except asyncio.TimeoutError:
                break
            if body["type"] == type_:
                return body.get("payload", {})
        raise Failure(f"{self.name}: no {type_} within {timeout:g} s")

    async def hello(self):
        await self.send("server/hello", {"name": self.name, "source@v1_support": {"supported_codecs": ["flac", "pcm"]}})
        await self.expect("client/hello", 5)

    async def activate(self, activities: list[str], pairing: dict | None = None):
        payload = {"activities": activities, "active_roles": []}
        if pairing:
            payload["pairing"] = pairing
        await self.send("server/activate", payload)

    async def rehandshake(self, psk: ResolvedPsk):
        """Our message 1 under the current keys, the client's message 2 back, then new keys."""
        view = QueuedEncryptedWebSocket(self.enc, self.handshakes)
        result = await run_rehandshake_server(view, local_identity=self.identity, client_id=self.client_id,
                                              suite=self.suite, prologue=self.handshake_hash, psk=psk)
        self.handshake_hash = result.handshake_hash
        log(f"{self.name}: re-handshake to the {psk.category.value} PSK done")

    async def close(self):
        with contextlib.suppress(Exception):
            await self.ws.close()
        await self.http.close()


async def rehandshake_bad_method(bridge: Bridge):
    server = Server("Re-handshake Server")
    await server.connect(bridge.url)
    await server.hello()
    await server.activate([])
    await asyncio.sleep(1)
    pairing_psk = ResolvedPsk(psk_id_for(bridge.token.pairing_psk), bridge.token.pairing_psk, PskCategory.PAIRING)
    await server.rehandshake(pairing_psk)
    # On the pairing PSK only the pairing-PSK method is admissible.
    await server.activate(["pairing"], {"method": "dynamic_pairing_code", "format": "digits"})
    abort = await server.expect("pair/abort", 3)
    if abort.get("reason") != "method_not_supported":
        raise Failure(f"pair/abort with reason {abort.get('reason')!r}, not method_not_supported")
    # The connection stays open and in use: time sync goes on (bursts at most 10 s apart).
    before = server.time_requests
    deadline = time.monotonic() + 12
    while server.time_requests == before and time.monotonic() < deadline and not server.closed.is_set():
        await asyncio.sleep(0.2)
    if server.closed.is_set():
        raise Failure("the client closed the connection after pair/abort")
    if server.time_requests == before:
        raise Failure("no client/time within 12 s after the re-handshake: the client went quiet")
    await server.close()


async def admission_race(bridge: Bridge):
    idle = Server("Idle Server")
    await idle.connect(bridge.url)
    await idle.hello()
    await idle.activate([])
    await asyncio.sleep(1)
    first, second = Server("Pairing Server 1"), Server("Pairing Server 2")
    await asyncio.gather(first.connect(bridge.url), second.connect(bridge.url))
    await asyncio.gather(first.hello(), second.hello())
    pairing = {"method": "dynamic_pairing_code", "format": "digits"}
    await asyncio.gather(first.activate(["pairing"], pairing), second.activate(["pairing"], pairing))
    goodbye = await idle.expect("client/goodbye", 5)
    if goodbye.get("reason") != "another_server":
        raise Failure(f"the idle server got goodbye {goodbye.get('reason')!r}, not another_server")

    async def outcome(server: Server) -> str:
        """'admitted' when its attempt starts, else the reason it was turned away."""
        deadline = time.monotonic() + 5
        while (left := deadline - time.monotonic()) > 0:
            try:
                body = await asyncio.wait_for(server.inbox.get(), left)
            except asyncio.TimeoutError:
                break
            if body["type"] == "client/pair-init":
                return "admitted"
            if body["type"] in ("pair/abort", "client/goodbye"):
                return f"{body['type']} {body['payload'].get('reason')}"
        return "no answer"

    outcomes = await asyncio.gather(outcome(first), outcome(second))
    log(f"outcomes: {outcomes}")
    if outcomes.count("admitted") != 1:
        raise Failure(f"{outcomes.count('admitted')} servers admitted at once: {outcomes}")
    refused = next(o for o in outcomes if o != "admitted")
    if refused != "pair/abort concurrent_attempt":
        raise Failure(f"the other server got {refused!r}, not pair/abort concurrent_attempt")
    for server in (idle, first, second):
        await server.close()


SCENARIOS = {"rehandshake-bad-method": rehandshake_bad_method, "admission-race": admission_race}


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--bridge", required=True, help="the sendspin-bridge binary")
    parser.add_argument("scenarios", nargs="*", metavar="SCENARIO", help=", ".join(SCENARIOS))
    args = parser.parse_args()
    if unknown := [name for name in args.scenarios if name not in SCENARIOS]:
        parser.error(f"unknown scenario {', '.join(unknown)}; there are {', '.join(SCENARIOS)}")
    failed = 0
    for name in args.scenarios or SCENARIOS:
        bridge = Bridge(args.bridge)
        log(f"=== {name}")
        try:
            await bridge.start()
            await SCENARIOS[name](bridge)
            log(f"PASS {name}")
        except (Failure, OSError, asyncio.TimeoutError) as error:
            failed += 1
            log(f"FAIL {name}: {error}")
            log("bridge log:\n  " + "\n  ".join(bridge.lines[-30:]))
        finally:
            await bridge.stop()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
