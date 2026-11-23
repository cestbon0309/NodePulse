#!/usr/bin/env python3
"""History integration. Run with host probe + test-history-server binaries."""
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
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("client", ROOT / "npulse-cli.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
TOKEN, SECRET, EPOCH = "history-token", "history-group", "1234567890abcdef"
processes = []


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def start(binary, *args):
    p = subprocess.Popen([binary, *args], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    processes.append(p)
    return p


def wait(fn):
    end = time.monotonic() + 8
    while time.monotonic() < end:
        try:
            result = fn()
            if result:
                return result
        except (OSError, EOFError):
            pass
        time.sleep(.03)
    raise AssertionError("history fixture timed out")


def get(p, **fields):
    return c.exchange("127.0.0.1", p, TOKEN, {"op": "get", "ts": int(time.time()), **fields})


def http_get(p, cursor=None, token=TOKEN):
    connection = http.client.HTTPConnection("127.0.0.1", p, timeout=3)
    headers = {"Authorization": "Bearer " + token}
    if cursor is not None:
        headers["X-Npulse-History"] = cursor if isinstance(cursor, str) else json.dumps(cursor)
    try:
        connection.request("GET", "/api/nodes", headers=headers)
        response = connection.getresponse()
        return response.status, response.read()
    finally:
        connection.close()


def sign(obj, secret=SECRET):
    obj["sig"] = c.group_keys(secret)[2].sign(c.group_message(obj)).hex()
    return obj


def request(op="gget", secret=SECRET, **fields):
    return sign({"op": op, "gid": c.group_keys(secret)[3], "ts": int(time.time()),
                 "rid": os.urandom(16).hex(), **fields}, secret)


def exchange(p, obj):
    return c.exchange("127.0.0.1", p, TOKEN, obj)


def rejected(p, obj):
    with socket.create_connection(("127.0.0.1", p), timeout=3) as sock:
        sock.sendall(c.encode(TOKEN, obj))
        try:
            assert sock.recv(1) == b"", "invalid history signature/cap accepted"
        except ConnectionResetError:
            pass


def record(slot, seq, epoch=EPOCH):
    enc, _, _, gid = c.group_keys(SECRET)
    row = [seq, int(time.time()), 10, 20, 0, 30, .1, .2, .3, 40, 50]
    nonce = os.urandom(12)
    ad = f"npulse-history-v1:{gid}:{slot}:{epoch}:{seq}".encode()
    raw = json.dumps({"epoch": epoch, "sample": row}, separators=(",", ":")).encode()
    blob = base64.b64encode(nonce + c.ChaCha20Poly1305(enc).encrypt(nonce, raw, ad)).decode()
    return request("hpush", slot=slot, seq=seq, epoch=epoch, blob=blob)


try:
    host, fixture = map(lambda s: str(Path(s).resolve()), sys.argv[1:3])
    direct, relay, http_port = port(), port(), port()
    start(fixture, "--prefill", "-l", f"127.0.0.1:{direct}", "-H", f"127.0.0.1:{http_port}", "-k", TOKEN, "-E", "off")
    first = wait(lambda: get(direct))
    h = first["history"]
    assert first["ok"] and first["nodes"] and h["full"] and len(h["samples"]) == 120
    assert all(len(row) == 11 for row in h["samples"])
    epoch, seq = h["epoch"], h["seq"]
    assert not get(direct, epoch=epoch, since=seq)["history"]["samples"]
    boundary = get(direct, epoch=epoch, since=h["samples"][0][0] - 1)["history"]
    assert not boundary["full"] and len(boundary["samples"]) == 120
    assert get(direct, epoch=epoch, since=0)["history"]["full"]
    assert get(direct, epoch="ffffffffffffffff", since=seq)["history"]["full"]
    later = wait(lambda: (x if (x := get(direct, epoch=epoch, since=seq))["history"]["samples"] else None))
    assert not later["history"]["full"] and all(row[0] > seq for row in later["history"]["samples"])
    latest = later["history"]["samples"][-1]
    assert abs(latest[2] - later["nodes"][0]["cpu_usage"]) < .02
    print("PASS direct history: full 120, incremental, empty, start-1, stale/future epoch recovery, latest snapshot and old-client nodes shape")

    status, body = http_get(http_port)
    old = json.loads(body)
    assert status == 200 and old["nodes"] and old["history"]["full"]
    cursor = {"epoch": old["history"]["epoch"], "since": old["history"]["seq"]}
    status, body = http_get(http_port, cursor)
    increment = json.loads(body)["history"]
    assert status == 200 and not increment["full"]
    assert all(row[0] > cursor["since"] for row in increment["samples"])
    status, body = http_get(http_port, {"epoch": cursor["epoch"], "since": increment["seq"]})
    assert status == 200 and not json.loads(body)["history"]["samples"]
    for invalid in ("{", {"since": 1}, {"epoch": "ffffffffffffffff", "since": 1}):
        status, body = http_get(http_port, invalid)
        assert status == 200 and json.loads(body)["history"]["full"]
    assert http_get(http_port, cursor, token="wrong") == (404, b"")
    print("PASS HTTP history header: full, incremental/empty, malformed/missing/changed epoch recovery, old shape and unauthenticated empty 404")

    start(host, "-S", f"127.0.0.1:{relay}", "-T", TOKEN, "-E", "off")
    wait(lambda: exchange(relay, request()))
    node = {"id": "history-node", "name": "fixture", "ts": int(time.time())}
    push = c.group_request(SECRET, "gpush", node)
    exchange(relay, push)
    slot = push["slot"]
    for n in range(1, 126):
        exchange(relay, record(slot, n))
    result = exchange(relay, request(since={}))
    h = result["blobs"][0]["history"]
    assert h["full"] and len(h["samples"]) == 120 and h["samples"][0][0] == 6
    assert "history" not in exchange(relay, request())["blobs"][0]
    enc, _, _, gid = c.group_keys(SECRET)
    for n, blob in h["samples"]:
        raw = base64.b64decode(blob)
        plain = json.loads(c.ChaCha20Poly1305(enc).decrypt(raw[:12], raw[12:], f"npulse-history-v1:{gid}:{slot}:{EPOCH}:{n}".encode()))
        assert plain["sample"][0] == n and plain["epoch"] == EPOCH
    def history(since, epoch=EPOCH):
        return exchange(relay, request(since={slot: {"epoch": epoch, "since": since}}))["blobs"][0]["history"]
    assert [row[0] for row in history(123)["samples"]] == [124, 125]
    assert not history(125)["samples"] and not history(125)["full"]
    assert history(4)["full"] and not history(5)["full"] and history(126)["full"]
    tamper = record(slot, 126); tamper["seq"] = 127; rejected(relay, tamper)
    tamper = record(slot, 126); tamper["epoch"] = "ffffffffffffffff"; rejected(relay, tamper)
    tamper = request(since={}); tamper["since"][slot] = {"epoch": EPOCH, "since": 1}; rejected(relay, tamper)
    oversize = record(slot, 126); oversize["blob"] = "A" * 388; rejected(relay, sign(oversize))
    exchange(relay, record(slot, 128))
    assert [r[0] for r in history(125)["samples"]] == [128]
    exchange(relay, record(slot, 1, "abcdef1234567890"))
    assert history(128)["full"] and len(history(128)["samples"]) == 1
    print("PASS relay: opaque authenticated records, 120 cap, incremental/empty/stale/wrap boundaries, gaps, epoch reset, signed seq/epoch/since tamper rejection, 384-byte cap and old get")

    for n in range(1, 32):
        exchange(relay, request("hpush", slot=f"{n:032x}", epoch=EPOCH, seq=1, blob=record(slot, 1)["blob"]))
    rejected(relay, request("hpush", slot=f"{32:032x}", epoch=EPOCH, seq=1, blob=record(slot, 1)["blob"]))
    for n in range(32):
        exchange(relay, request("hpush", secret="second", slot=f"{n:032x}", epoch=EPOCH, seq=1, blob=record(slot, 1)["blob"]))
    rejected(relay, request("hpush", secret="third", slot="0" * 32, epoch=EPOCH, seq=1, blob=record(slot, 1)["blob"]))
    assert exchange(relay, c.group_request("third", "gpush", {"id": "snapshot-only"}))["ok"]
    print("PASS relay caps: 32 slots/group, 64 history slots globally; capped publishers retain snapshot-only interoperability")

    publisher = port()
    start(fixture, "-l", f"127.0.0.1:{publisher}", "-k", TOKEN, "-R", f"127.0.0.1:{relay}", "-T", TOKEN, "-G", "publisher", "-i", "5", "-E", "off")
    # This relay is deliberately history-full: a second relay exercises live publishing.
    live = port()
    start(host, "-S", f"127.0.0.1:{live}", "-T", TOKEN, "-E", "off")
    start(fixture, "-R", f"127.0.0.1:{live}", "-T", TOKEN, "-G", SECRET, "-i", "5", "-E", "off")
    live_response = wait(lambda: (r if (r := exchange(live, request(since={})))["blobs"] and len(r["blobs"][0].get("history", {}).get("samples", [])) >= 3 else None))
    rows = live_response["blobs"][0]["history"]["samples"]
    assert all(b[0] == a[0] + 1 for a, b in zip(rows, rows[1:]))
    print("PASS live publisher: encrypted 1 Hz history arrives between 5-second snapshots")
    print("ALL HISTORY INTEGRATION CHECKS PASSED")
finally:
    for p in processes:
        p.terminate()
    for p in processes:
        try:
            p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            p.kill(); p.wait()
