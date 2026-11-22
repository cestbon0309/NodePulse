#!/usr/bin/env python3
"""E2E relay integration: python tools/test-group.py ./npulse-host."""
import base64
import copy
import http.client
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
from cryptography.exceptions import InvalidTag

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("client", ROOT / "tools/npulse-cli.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
TOKEN, A, B = "relay-access-test", "group-A-测试", "group-B-secret"
processes = []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(*args, binary=None):
    p = subprocess.Popen([str(binary or Path(sys.argv[1]).resolve()), *args],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    processes.append(p)
    return p


def exchange(p, request, token=TOKEN):
    return c.exchange("127.0.0.1", p, token, request)


def get(p, secret=A):
    return exchange(p, c.group_request(secret))


def wait_for(fn):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except (ConnectionError, EOFError):
            pass
        time.sleep(.05)
    raise AssertionError("timed out waiting for relay")


def silent(p, obj, token=TOKEN, raw=None):
    with socket.create_connection(("127.0.0.1", p), timeout=3) as sock:
        sock.sendall(c.encode(token, obj) if raw is None else raw)
        try:
            assert sock.recv(1) == b"", "rejected request received bytes"
        except ConnectionResetError:
            pass


def resign(secret, obj):
    obj["sig"] = c.group_keys(secret)[2].sign(c.group_message(obj)).hex()
    return obj


def invalid_blob(secret, response):
    try:
        c.open_blobs(secret, response)
    except InvalidTag:
        return
    raise AssertionError("invalid ciphertext accepted")


try:
    with tempfile.TemporaryDirectory() as temp:
        harness = Path(temp) / "group-test"
        subprocess.run([os.environ.get("CC", "cc"), str(ROOT / "tools/test-group.c"),
                        str(ROOT / "vendor/monocypher.c"),
                        str(ROOT / "vendor/monocypher-ed25519.c"), "-o", str(harness)], check=True)
        subprocess.run([str(harness), str(ROOT / "tools/e2e-vector.json")], check=True)
        vector = json.loads((ROOT / "tools/e2e-vector.json").read_text())
        enc, seed, signing, gid = c.group_keys(vector["S"])
        assert (enc.hex(), seed.hex(), gid) == (vector["enc_key"], vector["seed"], vector["gid"])
        assert c.seal_blob(vector["S"], vector["node"], bytes.fromhex(vector["nonce"])) == (vector["slot"], vector["blob"])
        assert signing.sign(vector["message"].encode()).hex() == vector["signature"]
        assert signing.sign(vector["gget_message"].encode()).hex() == vector["gget_signature"]
        print("PASS Python fixed vector matches C and independent Node crypto reference")

        worst_binary = Path(temp) / "worst-snapshot"
        subprocess.run([os.environ.get("CC", "cc"), str(ROOT / "tools/test-snapshot.c"),
                        str(ROOT / "vendor/monocypher.c"),
                        str(ROOT / "vendor/monocypher-ed25519.c"), "-o", str(worst_binary)], check=True)
        worst = json.loads(subprocess.check_output([str(worst_binary)], text=True))

        tcp, http_port = port(), port()
        relay = start("--relay-only", "-S", f"127.0.0.1:{tcp}", "-H", f"127.0.0.1:{http_port}",
                      "-T", TOKEN, binary=harness)
        empty = wait_for(lambda: get(tcp))
        assert empty["blobs"] == []
        assert exchange(tcp, c.group_request(A, "gpush", worst))["ok"]
        assert c.open_blobs(A, get(tcp))["nodes"][0]["node"] == worst
        # Use a fresh relay so the synthetic worst-case snapshot does not join group A.
        relay.terminate()
        relay.communicate(timeout=8)
        processes.remove(relay)
        tcp, http_port = port(), port()
        relay = start("--relay-only", "-S", f"127.0.0.1:{tcp}", "-H", f"127.0.0.1:{http_port}",
                      "-T", TOKEN, binary=harness)
        wait_for(lambda: get(tcp))
        print("PASS bounded worst-case snapshot with 16 IPs encrypts below 7168-byte blob cap and survives relay round trip")
        legacy, direct, normal_http = port(), port(), port()
        start("-l", f"127.0.0.1:{legacy}", "-k", "legacy-secret", "-n", "legacy-upstream")
        start("--publisher", "-R", f"127.0.0.1:{tcp}", "-T", TOKEN, "-k", "legacy-secret", "-G", A,
              "-l", f"127.0.0.1:{direct}", "-H", f"127.0.0.1:{normal_http}",
              "-u", f"127.0.0.1:{legacy}", "-n", "group-a-one", "-i", "1", binary=harness)
        start("--publisher", "-R", f"127.0.0.1:{tcp}", "-T", TOKEN, "-k", A, "-n", "group-a-two", "-i", "1", binary=harness)
        config = Path(temp) / "publisher.conf"
        config.write_text(f"relay_upstream=127.0.0.1:{tcp}\ntoken={TOKEN}\ngroup_secret={B}\nname=group-b-one\ninterval=1\n")
        start("--publisher", "-c", str(config), binary=harness)
        raw_a = wait_for(lambda: (r if len((r := get(tcp))["blobs"]) == 2 else None))
        raw_b = wait_for(lambda: (r if len((r := get(tcp, B))["blobs"]) == 1 else None))
        nodes_a, nodes_b = c.open_blobs(A, raw_a)["nodes"], c.open_blobs(B, raw_b)["nodes"]
        assert {n["node"]["name"] for n in nodes_a} == {"group-a-one", "group-a-two"}
        assert {n["node"]["name"] for n in nodes_b} == {"group-b-one"}
        for item in raw_a["blobs"]:
            assert set(item) == {"slot", "blob", "age"} and 0 <= item["age"] < 10
            assert "group-a" not in item["blob"]
            assert b'"id"' not in base64.b64decode(item["blob"])
        assert "nodes" not in raw_a and "group-a-one" not in json.dumps(raw_a)
        cli = [sys.executable, str(ROOT / "tools/npulse-cli.py"), "127.0.0.1", str(tcp), "-T", TOKEN, "-G", A]
        assert len(json.loads(subprocess.check_output([*cli, "gget"], text=True))["nodes"]) == 2
        assert len(json.loads(subprocess.check_output([*cli, "gget", "--raw"], text=True))["blobs"]) == 2
        node_file = Path(temp) / "cli-node.json"
        node_file.write_text('{"id":"cli-node","name":"cli"}')
        assert json.loads(subprocess.check_output([*cli, "-G", B, "gpush", "--node", str(node_file)], text=True))["ok"]
        print("PASS pure relay + 2 group A probes + 1 group B probe: isolated decrypted nodes; raw storage is opaque")
        def legacy_get(p):
            return c.exchange("127.0.0.1", p, "legacy-secret", {"op": "get", "ts": int(time.time())})
        assert legacy_get(direct)["nodes"][0]["name"] == "group-a-one"
        wait_for(lambda: len(legacy_get(legacy)["nodes"]) == 2)
        conn = http.client.HTTPConnection("127.0.0.1", normal_http, timeout=3)
        conn.request("GET", "/api/nodes", headers={"Authorization": "Bearer legacy-secret"})
        response = conn.getresponse()
        assert response.status == 200 and json.loads(response.read())["nodes"][0]["name"] == "group-a-one"
        conn.close()
        print("PASS -R combines with -l/-u/normal -H; explicit -G overrides -k; fallback -k and key=value group configuration work")

        bad = c.group_request(B)
        bad["gid"] = c.group_keys(A)[3]
        silent(tcp, bad)
        silent(tcp, c.group_request(A), token="wrong-token")
        bad = c.group_request(A)
        bad["gid"] = "Z" * 64
        silent(tcp, bad)
        silent(tcp, c.group_request(A, ts=int(time.time()) - 121))
        bad = c.group_request(A)
        del bad["rid"]
        silent(tcp, bad)
        replay = c.group_request(A)
        frame = c.encode(TOKEN, replay)
        with socket.create_connection(("127.0.0.1", tcp), timeout=3) as sock:
            sock.sendall(frame)
            size = int.from_bytes(c.exact(sock, 4), "big")
            c.exact(sock, size + 28)
        silent(tcp, replay, raw=frame)
        silent(tcp, replay)
        print("PASS silent rejection: wrong group signature/token, invalid gid, stale ts, missing rid, nonce and rid replay")

        tampered = copy.deepcopy(raw_a)
        raw = bytearray(base64.b64decode(tampered["blobs"][0]["blob"]))
        raw[15] ^= 1
        tampered["blobs"][0]["blob"] = base64.b64encode(raw).decode()
        invalid_blob(A, tampered)
        moved = copy.deepcopy(raw_a)
        moved["blobs"][0]["slot"] = "f" * 32
        invalid_blob(A, moved)
        forged = c.group_request(A, "gpush", {"id": "forged"})
        forged["blob"] = tampered["blobs"][0]["blob"]
        silent(tcp, forged)
        enc, _, _, gid = c.group_keys(A)
        wrong_slot, nonce = "0" * 32, bytes(range(12))
        sealed = nonce + c.ChaCha20Poly1305(enc).encrypt(nonce, b'{"id":"wrong-id"}', f"{gid}:{wrong_slot}".encode())
        try:
            c.open_blobs(A, {"ok": True, "blobs": [{"slot": wrong_slot, "blob": base64.b64encode(sealed).decode(), "age": 0}]})
        except ValueError as error:
            assert "slot does not match" in str(error)
        else:
            raise AssertionError("slot/id mismatch accepted")
        print("PASS tampered ciphertext and moved slot fail AEAD; forged push rejected; decrypted id/slot binding checked")

        conn = http.client.HTTPConnection("127.0.0.1", http_port, timeout=3)
        req = c.group_request(A)
        conn.request("POST", "/api/relay", body=c.encode(TOKEN, req), headers={"Content-Type": "application/octet-stream"})
        response = conn.getresponse()
        assert response.status == 200 and response.getheader("Content-Type") == "application/octet-stream"
        result = c.decode(TOKEN, response.read())
        c.validate_response(result, req["rid"])
        assert len(c.open_blobs(A, result)["nodes"]) == 2
        conn.close()
        req = c.group_request(B, "gpush", {"id": "http-node", "name": "http-only"})
        body = c.encode(TOKEN, req)
        header = f"POST /api/relay HTTP/1.0\r\nContent-Type: application/octet-stream\r\nContent-Length: {len(body)}\r\n\r\n".encode()
        with socket.create_connection(("127.0.0.1", http_port), timeout=3) as sock:
            for chunk in (header[:17], header[17:], body[:5], body[5:]):
                sock.sendall(chunk)
                time.sleep(.02)
            received = bytearray()
            while data := sock.recv(8192):
                received.extend(data)
        headers, response = received.split(b"\r\n\r\n", 1)
        assert headers.startswith(b"HTTP/1.1 200")
        c.validate_response(c.decode(TOKEN, response), req["rid"])
        for request in (b"GET /api/relay HTTP/1.1\r\n\r\n", b"POST /api/relay HTTP/1.1\r\nContent-Type: application/octet-stream\r\n\r\n",
                        b"POST /api/relay HTTP/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: 262177\r\n\r\n"):
            with socket.create_connection(("127.0.0.1", http_port), timeout=3) as sock:
                sock.sendall(request)
                assert sock.recv(8192).startswith(b"HTTP/1.1 404")
        print("PASS HTTP/1.1 gget and fragmented HTTP/1.0 gpush frames; invalid route/missing or oversized Content-Length return empty 404")

        limit_secret = "limit-group"
        for i in range(32):
            req = c.group_request(limit_secret, "gpush", {"id": str(i)})
            req["blob"] = "A" * 7168
            assert exchange(tcp, resign(limit_secret, req))["ok"]
        full = get(tcp, limit_secret)
        assert len(full["blobs"]) == 32 and len(json.dumps(full).encode()) < 256 * 1024
        silent(tcp, c.group_request(limit_secret, "gpush", {"id": "overflow"}))
        req = c.group_request(limit_secret, "gpush", {"id": "0"})
        req["blob"] = "A" * 7172
        silent(tcp, resign(limit_secret, req))
        for i in range(253):
            secret = f"capacity-{i}"
            assert exchange(tcp, c.group_request(secret, "gpush", {"id": "node"}))["ok"]
        silent(tcp, c.group_request("group-257", "gpush", {"id": "node"}))
        assert get(tcp, "empty-unallocated")["blobs"] == []
        assert relay.poll() is None
        print("PASS limits: 32 × 7168-byte blobs fit one frame; excess blob/slot/group silent; 256 groups; empty get allocates no group")

        http_only = port()
        pure = start("--relay-only", "-H", f"127.0.0.1:{http_only}", "-T", TOKEN, binary=harness)
        time.sleep(1.2)
        assert pure.poll() is None and relay.poll() is None
        print("PASS pure TCP/HTTP and HTTP-only relays skip metrics_init and every /proc sampling tick (instrumented assertions)")
    print("ALL E2E RELAY CHECKS PASSED")
finally:
    for p in processes:
        p.terminate()
    for p in processes:
        out, err = p.communicate(timeout=8)
        assert not out and not err, f"unexpected relay/probe log: {out!r} {err!r}"
