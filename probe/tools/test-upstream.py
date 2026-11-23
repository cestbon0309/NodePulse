#!/usr/bin/env python3
"""Offline DDNS rollover without hosts-file changes: full/lite publishing and admin/pair pipes."""
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / filename)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


m, a = load("monitor", "npulse-cli.py"), load("admin", "npulse-admin.py")
TOKEN = "dns-token"
host, full, lite = [str(Path(value).resolve()) for value in sys.argv[1:4]]
processes, handles = [], []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0)); return sock.getsockname()[1]


def wait(fn, seconds=12):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = fn()
            if value: return value
        except (OSError, EOFError, ValueError, AssertionError):
            pass
        time.sleep(.05)
    raise AssertionError("DDNS fixture timed out")


def start(root, binary, *args, dns=None):
    log = root / f"process-{len(processes)}.log"
    handle = log.open("w+b"); handles.append(handle)
    env = dict(os.environ)
    if dns: env["NPULSE_TEST_DNS"] = str(dns)
    process = subprocess.Popen([binary, *args], stdout=handle, stderr=handle, env=env)
    processes.append(process)
    return process, log


def calls(path):
    log = Path(str(path) + ".calls")
    return [float(line.split()[0]) for line in log.read_text().splitlines()] if log.exists() else []


def get(p):
    return m.exchange("127.0.0.1", p, TOKEN, {"op": "get", "ts": int(time.time())})


def group(address, p, secret):
    request = m.group_request(secret)
    request["since"] = {}
    request["sig"] = m.group_keys(secret)[2].sign(m.group_message(request)).hex()
    return m.exchange(address, p, TOKEN, request)


try:
    output = ROOT.parent / "dist/upstream-tests"
    output.mkdir(exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="run-", dir=output))
    for binary, name in ((full, "full"), (lite, "lite")):
        state = root / f"unit-{name}"
        subprocess.run([binary, "--dns-unit"], env=dict(os.environ, NPULSE_TEST_DNS=str(state)), check=True, timeout=20)

    relay_port, pair_port = port(), port()
    old, _ = start(root, host, "-S", f"127.0.0.1:{relay_port}", "-T", TOKEN)
    start(root, host, "-S", f"[::1]:{relay_port}", "-T", TOKEN)
    start(root, host, "-S", f"[::1]:{pair_port}", "-T", TOKEN)
    wait(lambda: group("127.0.0.1", relay_port, "ready"))
    wait(lambda: group("::1", relay_port, "ready"))
    wait(lambda: group("::1", pair_port, "ready"))
    signing = Ed25519PrivateKey.generate()
    publishers = []
    for binary, name in ((full, "full"), (lite, "lite")):
        state, direct = root / name, port()
        state.write_text("0 127.0.0.1")
        secret = "dns-" + name
        args = ["-l", f"127.0.0.1:{direct}", "-k", TOKEN, "-R", f"relay.test:{relay_port}",
                "-T", TOKEN, "-G", secret, "-i", "2", "-E", "off"]
        if name == "full": args += ["-A", a.public(signing).hex()]
        process, _ = start(root, binary, *args, dns=state)
        node = wait(lambda: get(direct))["nodes"][0]["id"]
        wait(lambda: group("127.0.0.1", relay_port, secret)["blobs"])
        publishers.append((name, state, direct, secret, node, process))

    name, state, direct, secret, node, process = publishers[0]

    def info(address):
        with a.AdminClient(None, None, None, signing, node=node,
                           relay=(address, relay_port), token=TOKEN, group=secret) as client:
            return client.request("info")

    wait(lambda: info("127.0.0.1"))
    pair_state = root / "pair"
    pair_state.write_text("0 127.0.0.1")
    pair, pair_log = start(root, full, "--pair-dns", f"relay.test:{pair_port}", dns=pair_state)
    wait(lambda: calls(pair_state))
    for _, state, *_ in publishers:
        assert len(calls(state)) == 1
        state.write_text("2 ::1")
    pair_state.write_text("2 ::1")
    old.terminate(); old.wait(timeout=10)
    began = time.monotonic()
    points = {name: {} for name, *_ in publishers}
    latencies = []
    pair_socket = None
    while time.monotonic() - began < 38:
        for name, state, direct, _, _, process in publishers:
            before = time.monotonic(); response = get(direct); latencies.append(time.monotonic() - before)
            assert process.poll() is None
            for row in response["history"]["samples"]: points[name][int(row[0])] = row[1]
        text = pair_log.read_text()
        match = re.search(r"中转配对码：([0-9A-Z]{4}-[0-9A-Z]{4})", text)
        if match and pair_socket is None:
            pair_socket = socket.create_connection(("::1", pair_port), timeout=3)
            pair_socket.sendall(m.encode(TOKEN, {"op": "pconnect", "code": match[1],
                                               "rid": os.urandom(16).hex(), "ts": int(time.time())}))
            assert a.outer_receive(pair_socket, TOKEN)["ok"]
        time.sleep(.15)
    if pair_socket: pair_socket.close()
    assert pair.wait(timeout=5) == 0, pair_log.read_text()
    print("PASS pairing DDNS: actual ppair/pconnect pipe recovered from refused IPv4 address to IPv6 after rate-limited async refresh")
    for name, state, direct, secret_for_node, _, _ in publishers:
        stamps = calls(state)
        assert len(stamps) == 2 and stamps[1] - stamps[0] >= 29.9, stamps
        history = wait(lambda: group("::1", relay_port, secret_for_node)["blobs"])[0]["history"]
        assert history["samples"]
        seq = history["seq"]
        wait(lambda: group("::1", relay_port, secret_for_node)["blobs"][0]["history"]["seq"] > seq)
        values = points[name]
        ordered = sorted(values)
        assert len(ordered) >= 35 and all(right == left + 1 for left, right in zip(ordered, ordered[1:]))
        assert all(0 <= values[right] - values[left] <= 2 for left, right in zip(ordered, ordered[1:]))
        print(f"PASS {name} DDNS: snapshot + encrypted history resumed on changed address; {len(ordered)} contiguous 1 Hz samples; DNS calls={len(stamps)}, spacing={stamps[1] - stamps[0]:.2f}s")
    assert max(latencies) < .8, max(latencies)
    wait(lambda: info("::1"), seconds=15)
    print(f"PASS admin DDNS: listener and gaccept/info recovered; direct max latency {max(latencies):.3f}s during slow DNS/outage")
    print("ALL UPSTREAM DNS CHECKS PASSED")
    print("Artifacts:", root)
finally:
    for process in reversed(processes):
        if process.poll() is None: process.terminate()
    for process in reversed(processes):
        try: process.wait(timeout=10)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    for handle in handles: handle.close()
