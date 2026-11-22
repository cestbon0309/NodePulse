#!/usr/bin/env python3
"""Combined direct/shared-relay monitoring, admin and server RSS benchmark."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(sys.argv[1]).resolve()
OUTPUT = ROOT / "dist/combined-tests"
OUTPUT.mkdir(exist_ok=True)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


monitor, admin = load("monitor", "npulse-cli.py"), load("admin", "npulse-admin.py")
SECRET, TOKEN, GROUP = "combined-direct-key", "combined-relay-token", "combined-group-key"
signing = Ed25519PrivateKey.generate()
public = admin.public(signing).hex()
processes, logs = [], []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def start(*args, binary=BINARY):
    log = (OUTPUT / f"process-{len(logs)}.log").open("w+b")
    logs.append(log)
    proc = subprocess.Popen([str(binary), *args], stdout=log, stderr=log)
    processes.append(proc)
    return proc


def wait_for(function):
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            result = function()
            if result:
                return result
        except (OSError, EOFError):
            pass
        time.sleep(.1)
    raise AssertionError("combined probe timed out")


def direct(p):
    return monitor.exchange("127.0.0.1", p, SECRET, {"op": "get", "ts": int(time.time())})["nodes"]


def relayed(p):
    return monitor.open_blobs(GROUP, monitor.exchange("127.0.0.1", p, TOKEN, monitor.group_request(GROUP)))["nodes"]


def rss(proc):
    status = Path(f"/proc/{proc.pid}/status")
    if status.exists():
        return int(next(line.split()[1] for line in status.read_text().splitlines() if line.startswith("VmRSS:")))
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(proc.pid)], text=True).strip())


def stop_all():
    for proc in processes:
        if proc.poll() is None:
            proc.terminate()
    for proc in processes:
        proc.wait(timeout=8)
    processes.clear()


try:
    direct_port, relay_port = port(), port()
    a = start("-l", f"127.0.0.1:{direct_port}", "-k", SECRET, "-S", f"127.0.0.1:{relay_port}",
              "-T", TOKEN, "-A", public, "-n", "combined-A")
    wait_for(lambda: direct(direct_port))
    start("-R", f"127.0.0.1:{relay_port}", "-T", TOKEN, "-G", GROUP, "-A", public, "-i", "1", "-n", "combined-B")
    node = wait_for(lambda: relayed(relay_port))[0]["node"]
    assert [item["name"] for item in direct(direct_port)] == ["combined-A"]
    assert node["name"] == "combined-B"
    cli = [sys.executable, str(ROOT / "tools/npulse-cli.py"), "127.0.0.1"]
    assert json.loads(subprocess.check_output([*cli, str(direct_port), "-k", SECRET, "get"]))["nodes"][0]["name"] == "combined-A"
    assert json.loads(subprocess.check_output([*cli, str(relay_port), "-T", TOKEN, "-G", GROUP, "gget"]))["nodes"][0]["node"]["name"] == "combined-B"
    with admin.AdminClient("127.0.0.1", direct_port, SECRET, signing) as client:
        assert client.request("info")["admin_version"] == 1

    def relay_admin():
        with admin.AdminClient(None, None, None, signing, node=node["id"], relay=("127.0.0.1", relay_port), token=TOKEN, group=GROUP) as client:
            return client.request("info")["admin_version"] == 1

    assert wait_for(relay_admin)
    assert len(direct(direct_port)) == 1 and a.poll() is None
    print("PASS ONE -l+-S+-A process A: CLI direct monitoring A and relay monitoring B; direct admin A and end-to-end relay-pipe admin B; B never merged into A", flush=True)
    stop_all()
    harness = OUTPUT / "publisher"
    subprocess.run([os.environ.get("CC", "cc"), "-Os", "-std=gnu99", "-DNPULSE_ADMIN_TEST=1", str(ROOT / "tools/test-group.c"),
                    str(ROOT / "vendor/monocypher.c"), str(ROOT / "vendor/monocypher-ed25519.c"), str(ROOT / "vendor/qrcodegen.c"),
                    "-o", str(harness)], check=True)
    for count in (-1, 0, 1, 10):
        direct_port, relay_port = port(), port()
        args = ["-l", f"127.0.0.1:{direct_port}", "-k", SECRET, "-A", public]
        if count >= 0:
            args += ["-S", f"127.0.0.1:{relay_port}", "-T", TOKEN]
        server = start(*args)
        wait_for(lambda: direct(direct_port))
        for index in range(max(0, count)):
            start("--publisher", "-R", f"127.0.0.1:{relay_port}", "-T", TOKEN, "-G", GROUP,
                  "-i", "1", "-n", f"rss-{index}", binary=harness)
        if count > 0:
            wait_for(lambda: len(relayed(relay_port)) == count)
        time.sleep(2)
        samples = []
        for _ in range(5):
            samples.append(rss(server))
            time.sleep(.2)
        label = "-l only" if count < 0 else f"-l+-S N={count}"
        print(f"RSS {sys.platform} {label}: {sorted(samples)[2]} KiB (median of 5; min={min(samples)}, max={max(samples)}; server only)", flush=True)
        stop_all()
    print("ALL COMBINED DIRECT/RELAY/ADMIN CHECKS PASSED", flush=True)
finally:
    stop_all()
    for log in logs:
        log.close()
