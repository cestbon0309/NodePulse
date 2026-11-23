#!/usr/bin/env python3
"""Both publisher streams must stay on one of two independent DNS backends."""
import importlib.util
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("monitor", ROOT / "npulse-cli.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
host, *publishers = [str(Path(value).resolve()) for value in sys.argv[1:]]
processes, logs = [], []


def wait(fn, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = fn()
            if result: return result
        except (OSError, EOFError, KeyError): pass
        time.sleep(.05)
    raise AssertionError("affinity timeout")


def get(address, port, group):
    request = m.group_request(group); request["since"] = {}
    request["sig"] = m.group_keys(group)[2].sign(m.group_message(request)).hex()
    return m.exchange(address, port, "affinity", request)["blobs"]


def start(root, binary, *args, state=None):
    log = (root / f"process-{len(processes)}.log").open("w+b"); logs.append(log)
    env = dict(os.environ)
    if state: env["NPULSE_TEST_DNS"] = str(state)
    process = subprocess.Popen([binary, *args], stdout=log, stderr=log, env=env)
    processes.append(process); return process


output = ROOT.parent / "dist/upstream-tests"
output.mkdir(exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="affinity-", dir=output))
try:
    for index, binary in enumerate(publishers):
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0)); port = sock.getsockname()[1]
        group = f"affinity-{index}"
        first = start(root, host, "-S", f"127.0.0.1:{port}", "-T", "affinity")
        start(root, host, "-S", f"[::1]:{port}", "-T", "affinity")
        wait(lambda: m.exchange("127.0.0.1", port, "affinity", m.group_request(group)))
        wait(lambda: m.exchange("::1", port, "affinity", m.group_request(group)))
        state = root / f"dns-{index}"; state.write_text("0 both")
        publisher = start(root, binary, "-R", f"relay.test:{port}", "-T", "affinity", "-G", group,
                          "-i", "2", "-E", "off", state=state)
        time.sleep(7)
        a, b = get("127.0.0.1", port, group), get("::1", port, group)
        print(f"{Path(binary).name}: backend snapshots={len(a)}/{len(b)}, history sequences="
              f"{[[row[0] for row in blob.get('history', {}).get('samples', [])] for blob in a + b]}", flush=True)
        assert len(a) == 1 and not b, "snapshot/history streams diverged across independent relay addresses"
        sequences = [row[0] for row in a[0]["history"]["samples"]]
        assert len(sequences) >= 5 and sequences == list(range(1, sequences[-1] + 1))
        first.terminate(); first.wait(timeout=5)
        recovered = wait(lambda: get("::1", port, group))
        latest = recovered[0]["history"]["seq"]
        wait(lambda: get("::1", port, group)[0]["history"]["seq"] > latest + 2)
        assert publisher.poll() is None
        print(f"PASS {Path(binary).name}: co-located snapshots/complete 1 Hz history, shared failover and continued increments", flush=True)
    print("ALL RELAY AFFINITY CHECKS PASSED")
finally:
    for process in reversed(processes):
        if process.poll() is None: process.terminate()
    for process in reversed(processes):
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
    for log in logs: log.close()
