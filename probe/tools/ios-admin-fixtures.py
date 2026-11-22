#!/usr/bin/env python3
"""Live iOS admin fixture on 19094 (direct) / 19095 (relay). Ctrl-C stops both."""
import argparse
from pathlib import Path
import signal
import subprocess
import threading
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--public-key", help="optional UI-generated admin public key")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
fixtures = root / "ios/build/admin-host"
fixtures.mkdir(exist_ok=True)
(fixtures / "配置文件").mkdir(exist_ok=True)
(fixtures / "日志").mkdir(exist_ok=True)
(fixtures / "README.md").write_text("# NodePulse\n实时管理文件测试目录。\n", encoding="utf-8")
(fixtures / "系统状态.json").write_text('{"status":"online","encrypted":true}\n', encoding="utf-8")
(fixtures / "运行日志.log").write_text("NodePulse admin session ready\n" * 24, encoding="utf-8")
key = Ed25519PrivateKey.from_private_bytes(bytes([0x42]) * 32)
public = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
if args.public_key:
    if len(args.public_key) != 64 or len(bytes.fromhex(args.public_key)) != 32:
        parser.error("invalid public key")
    public += "," + args.public_key
stop = threading.Event()
for sig in (signal.SIGINT, signal.SIGTERM):
    signal.signal(sig, lambda *_: stop.set())
processes = []
with (fixtures / "fixture.log").open("ab") as log:
    try:
        binary = str(root / "probe/npulse-host")
        processes.append(subprocess.Popen([binary, "-S", "127.0.0.1:19095", "-T", "admin-relay-token"], stdout=log, stderr=log))
        processes.append(subprocess.Popen([binary, "-k", "integration-admin-secret", "-l", "127.0.0.1:19094",
            "-R", "127.0.0.1:19095", "-T", "admin-relay-token", "-G", "admin-relay-group", "-A", public,
            "-n", "NodePulse 开发主机", "-i", "2"], stdout=log, stderr=log))
        print("LIVE ADMIN fixtures: direct=19094 relay=19095; files=" + str(fixtures), flush=True)
        while not stop.wait(1):
            if any(proc.poll() is not None for proc in processes):
                raise SystemExit("fixture exited; inspect " + str(fixtures / "fixture.log"))
    finally:
        for proc in processes:
            if proc.poll() is None:
                proc.terminate()
        for proc in processes:
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill(); proc.wait()
