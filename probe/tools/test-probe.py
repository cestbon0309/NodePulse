#!/usr/bin/env python3
"""Integration checks: python tools/test-probe.py ./npulse-host (or Linux binary)."""
import importlib.util
import json
import os
import pathlib
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

spec = importlib.util.spec_from_file_location("client", pathlib.Path(__file__).with_name("npulse-cli.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
secret = 'integration-key-"\\'
processes = []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(*args):
    proc = subprocess.Popen([os.path.abspath(sys.argv[1]), *args])
    processes.append(proc)
    return proc


def get(p):
    return client.exchange("127.0.0.1", p, secret, {"op": "get", "ts": int(time.time())})


def wait_for(fn):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result:
                return result
        except (ConnectionError, EOFError, urllib.error.URLError):
            pass
        time.sleep(0.05)
    raise AssertionError("timed out waiting for probe")


def silent(p, data, timeout=2, half_close=False):
    with socket.create_connection(("127.0.0.1", p), timeout=timeout) as sock:
        sock.sendall(data)
        if half_close:
            sock.shutdown(socket.SHUT_WR)
        try:
            assert sock.recv(1) == b"", "invalid request received response bytes"
        except ConnectionResetError:
            pass


def raw_frame(payload):
    payload = payload.encode()
    length = struct.pack("!I", len(payload))
    nonce = os.urandom(12)
    cipher = client.ChaCha20Poly1305(client.hashlib.sha512(secret.encode()).digest()[:32])
    return length + nonce + cipher.encrypt(nonce, payload, length)


def http(p, path, key=None):
    req = urllib.request.Request(f"http://127.0.0.1:{p}{path}")
    if key is not None:
        req.add_header("Authorization", "Bearer " + key)
    try:
        with urllib.request.urlopen(req, timeout=2) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


try:
    with tempfile.TemporaryDirectory() as directory:
        root = pathlib.Path(directory)
        for interface, address in (("lo", "00:00:00:00:00:00"), ("eth0", "02:00:00:00:00:01")):
            (root / interface).mkdir()
            (root / interface / "address").write_text(address + "\n")
        probe = pathlib.Path(__file__).resolve().parent.parent
        binary = root / "test-identity"
        subprocess.run([os.environ.get("CC", "cc"), str(probe / "tools/test-identity.c"),
                        str(probe / "vendor/monocypher-ed25519.c"),
                        str(probe / "vendor/monocypher.c"), "-o", str(binary)], check=True)
        subprocess.run([str(binary), str(root)], check=True)
        binary = root / "test-snapshot"
        subprocess.run([os.environ.get("CC", "cc"), str(probe / "tools/test-snapshot.c"),
                        str(probe / "vendor/monocypher-ed25519.c"),
                        str(probe / "vendor/monocypher.c"), "-o", str(binary)], check=True)
        worst_snapshot = json.loads(subprocess.check_output([str(binary)], text=True))
        assert len(worst_snapshot["ips"]) == 16
        for field, limit in (("name", 64), ("hostname", 64), ("os", 64),
                             ("cpu_model", 96), ("kernel", 32), ("arch", 16)):
            assert len(worst_snapshot[field].encode()) == limit
    rid = "0123456789abcdef" * 2
    client.validate_response({"rid": rid}, rid)
    for captured in ({}, {"rid": "0" * 32}):
        try:
            client.validate_response(captured, rid)
            raise AssertionError("replayed/missing response ID accepted")
        except ValueError as error:
            assert str(error) == "响应校验失败"
    direct, web = port(), port()
    start("-k", secret, "-l", f"127.0.0.1:{direct}", "-H", str(web), "-n", 'self"\\\n雪')
    obj = wait_for(lambda: get(direct))
    node = obj["nodes"][0]
    expected = "id name hostname os kernel arch cpu_model cpu_cores cpu_usage load mem_total mem_used swap_total swap_used disk_total disk_used net_rx net_tx net_rx_rate net_tx_rate uptime procs tcp_conns temp ips ts version relay".split()
    assert set(node) == set(expected), set(expected) - set(node)
    assert node["name"] == 'self"\\\n雪' and node["relay"] is False
    assert len(node["load"]) == 3 and node["version"] == "0.1.0"
    if os.environ.get("NPULSE_ASSERT_LINUX") == "1":
        from linux_metrics import check
        check(node)
    print("PASS direct get: complete snapshot schema, JSON escaping and CryptoKit-compatible IETF AEAD")
    assert len(obj["rid"]) == 32
    assert get(direct)["rid"] != obj["rid"]
    print("PASS response binding: fresh request IDs echoed; missing/mismatched IDs rejected")
    request = {"op": "get", "ts": int(time.time())}
    silent(direct, client.encode("wrong", request))
    broken = bytearray(client.encode(secret, request)); broken[-1] ^= 1
    silent(direct, broken)
    for size in (0, 256 * 1024 + 1, 0xffffffff):
        silent(direct, struct.pack("!I", size))
    silent(direct, client.encode(secret, {"op": "get", "ts": int(time.time()) - 121}))
    silent(direct, client.encode(secret, {"op": "unknown", "ts": int(time.time())}))
    silent(direct, client.encode(secret, {"op": "push", "ts": int(time.time()), "node": {}}))
    for malformed in ('', '{', '{"op":"get",}', '{"op":"\\u12', '[1,]', '{"ts":01}'):
        silent(direct, raw_frame(malformed))
    escaped = '{"op":"g\\u0065t","ts":%d}' % int(time.time())
    with socket.create_connection(("127.0.0.1", direct)) as sock:
        sock.sendall(raw_frame(escaped))
        assert client.exact(sock, 4)
    silent(direct, b"\0\0", timeout=7)
    silent(direct, struct.pack("!I", 100), half_close=True)
    replay = client.encode(secret, request)
    with socket.create_connection(("127.0.0.1", direct)) as sock:
        sock.sendall(replay)
        assert client.exact(sock, 4)
    silent(direct, replay)
    print("PASS silent rejection: wrong key, altered tag, invalid sizes, stale timestamp, unknown op, malformed JSON, empty node, timeout, truncated frame and replay; escaped JSON keys/values accepted")
    status, body = http(web, "/api/nodes", secret)
    assert status == 200 and json.loads(body)["ok"]
    with socket.create_connection(("127.0.0.1", web), timeout=2) as sock:
        sock.sendall(("GET /api/nodes HTTP/1.0\r\nAuthorization: Bearer " + secret + "\r\n\r\n").encode())
        response = b""
        while chunk := sock.recv(65536):
            response += chunk
        headers, payload = response.split(b"\r\n\r\n", 1)
        assert headers.startswith(b"HTTP/1.1 200") and json.loads(payload)["ok"]
    print("PASS HTTP/1.0 authenticated request")
    for path, key in (("/api/nodes", None), ("/api/nodes", "wrong"), ("/", secret)):
        assert http(web, path, key) == (404, b"")
    query_port = port()
    start("-k", "simple-key", "-H", str(query_port))
    wait_for(lambda: http(query_port, "/api/nodes?key=simple-key")[0] == 200)
    assert json.loads(http(query_port, "/api/nodes?key=simple-key")[1])["nodes"] == []
    print("PASS HTTP: Bearer/query auth 200, missing/wrong key and wrong route empty 404, HTTP-only empty nodes")
    start("-k", secret, "-u", f"127.0.0.1:{direct}", "-i", "1", "-n", "relay-only")
    relayed = wait_for(lambda: next((n for n in get(direct)["nodes"] if n.get("relay")), None))
    assert relayed["name"] == "relay-only" and abs(relayed["last_seen"] - time.time()) < 5
    manual = {"op": "push", "ts": int(time.time()), "node": {"id": "manual", "name": "first"}}
    assert client.exchange("127.0.0.1", direct, secret, manual) == {"ok": True}
    manual["node"]["name"] = "updated"
    assert client.exchange("127.0.0.1", direct, secret, manual) == {"ok": True}
    assert [n["name"] for n in get(direct)["nodes"] if n["id"] == "manual"] == ["updated"]
    print("PASS relay-only periodic upstream push, last_seen metadata, push ACK and replacement by id")
    assert client.exchange("127.0.0.1", direct, secret,
                           {"op": "push", "ts": int(time.time()), "node": worst_snapshot})["ok"]
    accepted = next(node for node in get(direct)["nodes"] if node["id"] == worst_snapshot["id"])
    assert accepted["ips"] == worst_snapshot["ips"] and accepted["name"] == worst_snapshot["name"]
    print("PASS worst-case generated snapshot: 64 source IPs capped to 16, escaped bounded strings and extreme metrics accepted by push")
    bounded = port()
    start("-k", secret, "-l", f"127.0.0.1:{bounded}")
    wait_for(lambda: get(bounded))
    for size in (3841, 8192):
        node = {"id": "oversized", "padding": ""}
        node["padding"] = "x" * (size - len(json.dumps(node, separators=(",", ":"))))
        silent(bounded, client.encode(secret, {"op": "push", "ts": int(time.time()), "node": node}))
    assert len(get(bounded)["nodes"]) == 1
    for index in range(64):
        node = {"id": f"bounded-{index}", "padding": ""}
        node["padding"] = "x" * (3840 - len(json.dumps(node, separators=(",", ":"))))
        assert client.exchange("127.0.0.1", bounded, secret,
                               {"op": "push", "ts": int(time.time()), "node": node})["ok"]
    full = get(bounded)
    assert len(full["nodes"]) == 65
    assert len(json.dumps(full).encode()) < 256 * 1024
    print("PASS relay frame budget: oversized pushes silent; 64 boundary-size nodes plus self fit one get")
    with tempfile.TemporaryDirectory() as directory:
        config_port = port()
        config = pathlib.Path(directory) / "probe.conf"
        config.write_text(f"# example\nsecret=ignored\nlisten=127.0.0.1:{config_port}\nname=config-name\ninterval=2\n")
        start("-k", secret, "-c", str(config), "-n", "cli-wins")
        assert wait_for(lambda: get(config_port))["nodes"][0]["name"] == "cli-wins"
    print("PASS key=value configuration and CLI precedence")
    print("ALL INTEGRATION CHECKS PASSED")
finally:
    for proc in processes:
        proc.terminate()
    for proc in processes:
        proc.wait(timeout=8)
