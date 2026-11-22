#!/usr/bin/env python3
"""Shared relay admin integration: test-admin-relay.py ./npulse-host."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import resource
import socket
import subprocess
import sys
import tempfile
import threading
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


c = load("admin", "npulse-admin.py")
m = load("monitor", "npulse-cli.py")
TOKEN, GROUP = "pipe-integration-token", "pipe-integration-group"
processes, logs = [], []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0)); return sock.getsockname()[1]


def wait_for(fn, seconds=20):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            result = fn()
            if result:
                return result
        except (OSError, EOFError):
            pass
        time.sleep(.05)
    raise AssertionError("timed out waiting for relay admin")


def start(root, *args):
    log = open(root / f"process-{len(logs)}.log", "w+b"); logs.append(log)
    proc = subprocess.Popen([str(Path(sys.argv[1]).resolve()), *args], stdout=log, stderr=log)
    processes.append(proc); return proc


def open_request(p, obj, token=TOKEN):
    sock = socket.create_connection(("127.0.0.1", p), 5)
    sock.sendall(c.outer_encode(token, obj)); return sock


def closed(sock):
    try:
        assert sock.recv(1) == b"", "expected silent close"
    except ConnectionResetError:
        pass


def listener(p, node, group=GROUP):
    obj = c.relay_request("glisten", group, node)
    sock = open_request(p, obj)
    assert c.outer_receive(sock, TOKEN) == {"ok": True, "rid": obj["rid"]}
    return sock


def main(root):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft < 1024:
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(1024, hard) if hard != resource.RLIM_INFINITY else 1024, hard))
    fixture = root / "test-pipe"
    subprocess.run([os.environ.get("CC", "cc"), "-Os", "-std=gnu99", "-Wall", "-Wextra", "-Werror",
                    str(ROOT / "tools/test-pipe.c"), str(ROOT / "vendor/monocypher.c"),
                    str(ROOT / "vendor/monocypher-ed25519.c"), str(ROOT / "vendor/qrcodegen.c"), "-o", str(fixture)], check=True)
    subprocess.run([str(fixture)], check=True)
    p = port(); relay = start(root, "-S", f"127.0.0.1:{p}", "-T", TOKEN)
    wait_for(lambda: m.exchange("127.0.0.1", p, TOKEN, m.group_request(GROUP)))
    signing = Ed25519PrivateKey.generate()
    start(root, "-R", f"localhost:{p}", "-T", TOKEN, "-G", GROUP, "-A", c.public(signing).hex(), "-i", "1", "-n", "relay-admin-test")

    def nodes():
        raw = m.exchange("127.0.0.1", p, TOKEN, m.group_request(GROUP))
        return m.open_blobs(GROUP, raw)["nodes"]

    node = wait_for(nodes)[0]["node"]["id"]

    def connect(key=signing):
        return c.AdminClient(None, None, None, key, node=node, relay=("127.0.0.1", p), token=TOKEN, group=GROUP)

    def info():
        with connect() as client:
            return client.request("info")

    assert wait_for(info)["admin_version"] == 1
    remote = root / "remote"; remote.mkdir()
    source, destination, downloaded = root / "source", remote / "300k.bin", root / "downloaded"
    source.write_bytes(os.urandom(300 * 1024))
    with connect() as client:
        assert client.request("ls", path=str(remote))["entries"] == []
        client.upload(source, str(destination)); client.download(str(destination), downloaded)
        assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(downloaded.read_bytes()).digest()
        assert client.request("stat", path=str(destination))["size"] == 307200
        pty = client.request("pty_open", cols=80, rows=24)["pty"]
        client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(b"echo hi; exit 3\n").decode())
        output = bytearray()
        while True:
            event = client.receive()
            if event.get("t") == "pty_out":
                output.extend(base64.b64decode(event["data"], validate=True))
            elif event.get("t") == "pty_exit":
                assert event["code"] == 3; break
        assert b"hi" in output
    key_file = root / "key.json"
    key_file.write_text(json.dumps({"seed": signing.private_bytes_raw().hex()})); key_file.chmod(0o600)
    cli = subprocess.run([sys.executable, str(ROOT / "tools/npulse-admin.py"), "--relay", f"127.0.0.1:{p}",
                          "--token", TOKEN, "--group", GROUP, "--node", node, "--key", str(key_file), "info"], check=True, capture_output=True, text=True)
    assert json.loads(cli.stdout)["admin_version"] == 1
    print("PASS relay-only -R/-A probe (no -l or -k), localhost multi-address fallback: group-secret identity MAC, Python CLI/info/empty ls/stat, 300KB put/get SHA256, PTY echo hi + exit 3")
    with open_request(p, c.relay_request("gconnect", GROUP, "offline-node")) as sock:
        assert c.outer_receive(sock, TOKEN) == {"ok": False, "err": "offline"}; closed(sock)
    for op in ("glisten", "gconnect", "gaccept"):
        obj = c.relay_request(op, GROUP, "fake-node", "00" * 16 if op == "gaccept" else None)
        obj["sig"] = ("01" if obj["sig"][:2] != "01" else "02") + obj["sig"][2:]
        with open_request(p, obj) as sock:
            closed(sock)
    with open_request(p, c.relay_request("gaccept", GROUP, node, "ff" * 16)) as sock:
        closed(sock)
    try:
        connect(Ed25519PrivateKey.generate())
    except (EOFError, OSError):
        pass
    else:
        raise AssertionError("unauthorized admin accepted through pipe")
    print("PASS offline node returns err=offline; wrong group signatures on glisten/gconnect/gaccept and wrong cid close silently; separate admin allowlist still enforced")

    old = listener(p, "manual-node"); new = listener(p, "manual-node")
    closed(old); old.close()
    new.sendall(c.outer_encode(TOKEN, {"op": "gping"})); assert c.outer_receive(new, TOKEN) == {"ok": True}
    phone = open_request(p, c.relay_request("gconnect", GROUP, "manual-node"))
    incoming = c.outer_receive(new, TOKEN); assert incoming["op"] == "incoming" and len(incoming["cid"]) == 32
    with open_request(p, c.relay_request("gaccept", GROUP, "manual-node", "00" * 16)) as wrong:
        closed(wrong)
    accepted = open_request(p, c.relay_request("gaccept", GROUP, "manual-node", incoming["cid"]))
    assert c.outer_receive(accepted, TOKEN) == c.outer_receive(phone, TOKEN) == {"ok": True}
    with open_request(p, c.relay_request("gaccept", GROUP, "manual-node", incoming["cid"])) as duplicate:
        closed(duplicate)
    payload = b"\x00\xffnot-json-not-a-frame" + os.urandom(2 * 1024 * 1024)
    errors = []

    def send(sock, data):
        try:
            sock.sendall(data)
        except BaseException as error:
            errors.append(error)

    for origin, target in ((phone, accepted), (accepted, phone)):
        thread = threading.Thread(target=send, args=(origin, payload)); thread.start()
        assert c.read_exact(target, len(payload)) == payload
        thread.join(5); assert not thread.is_alive() and not errors
    phone.close(); closed(accepted); accepted.close(); new.close()
    print("PASS listener replacement closes old fd; unadorned gping ACK; one-use cid pairing and >2MB opaque binary traffic both directions with bounded buffering/paired close")
    with connect() as client:
        frame = bytearray(client.encode({"t": "ping", "id": 1})); frame[-1] ^= 1
        client.sock.sendall(frame); closed(client.sock)
    assert info()["admin_version"] == 1
    print("PASS tampered session byte traverses raw pipe and causes AEAD rejection/paired close; listener remains usable")

    reserved, listeners = [], []
    try:
        for group in range(17):
            secret = f"limits-{group}"
            listen = listener(p, "limits-node", secret); listeners.append(listen)
            if group < 16:
                for _ in range(4):
                    reserved.append(open_request(p, c.relay_request("gconnect", secret, "limits-node")))
                    assert c.outer_receive(listen, TOKEN)["op"] == "incoming"
                if group == 0:
                    with open_request(p, c.relay_request("gconnect", secret, "limits-node")) as fifth:
                        closed(fifth)
        for group in (0, 16):
            with open_request(p, c.relay_request("gconnect", f"limits-{group}", "limits-node")) as sock:
                closed(sock)
    finally:
        for sock in reserved + listeners:
            sock.close()
    print("PASS relay reserves at most 64 pipes total / 4 per gid (pending offers count against quota)")

    relay.terminate(); relay.wait(timeout=5)
    relay = start(root, "-S", f"127.0.0.1:{p}", "-T", TOKEN)
    assert wait_for(info, seconds=25)["admin_version"] == 1
    print("PASS relay dies/restarts on same port: persistent probe reconnects, re-listens and serves a new authenticated admin session")
    listeners = []
    try:
        # The live probe owns one listener already.
        for i in range(255):
            listeners.append(listener(p, f"listener-limit-{i}"))
        with open_request(p, c.relay_request("glisten", GROUP, "listener-over-limit")) as sock:
            closed(sock)
        replaced = listener(p, "listener-limit-0"); closed(listeners[0]); listeners[0].close(); listeners[0] = replaced
    finally:
        for sock in listeners:
            sock.close()
    print("PASS 256-listener bound including live probe; same gid+slot replacement still succeeds at capacity")
    for log in logs:
        log.flush(); log.seek(0); data = log.read()
        assert b"echo hi; exit 3" not in data
    print("ALL RELAY ADMIN CHECKS PASSED")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    with tempfile.TemporaryDirectory(prefix="npulse-admin-relay-") as directory:
        try:
            main(Path(directory))
        except BaseException:
            for log in logs:
                log.flush(); log.seek(0); print(log.read()[-12000:].decode(errors="replace"), file=sys.stderr)
            raise
        finally:
            for proc in processes:
                if proc.poll() is None:
                    proc.terminate()
            for proc in processes:
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
            for log in logs:
                log.close()
