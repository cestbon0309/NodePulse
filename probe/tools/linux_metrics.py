#!/usr/bin/env python3
"""Linux snapshot assertions and encrypted-get smoke runner (optionally QEMU)."""
import json
import pathlib
import socket
import subprocess
import sys
import time


def check(node):
    for field in ("cpu_cores", "mem_total", "disk_total", "uptime"):
        assert node[field] > 0, (field, node[field])
    assert node["ips"], node["ips"]
    assert 0 <= node["cpu_usage"] <= 100, node["cpu_usage"]
    assert 0 <= node["mem_used"] <= node["mem_total"]
    assert 0 <= node["disk_used"] <= node["disk_total"]
    assert len(node["load"]) == 3 and all(value >= 0 for value in node["load"])
    assert abs(node["ts"] - time.time()) < 120
    print("PASS Linux metrics: " + json.dumps({key: node[key] for key in
          ("arch", "cpu_cores", "mem_total", "disk_total", "ips", "uptime")}), flush=True)


def main():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    command = sys.argv[1:]
    assert command, "expected [qemu-*] path/to/npulse"
    process = subprocess.Popen(command + ["-k", "ci-smoke", "-l", f"127.0.0.1:{port}"])
    try:
        deadline = time.monotonic() + 30
        while True:
            assert process.poll() is None, f"probe exited: {process.returncode}"
            result = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name("npulse-cli.py")),
                                     "127.0.0.1", str(port), "-k", "ci-smoke"],
                                    capture_output=True, text=True, timeout=10)
            if result.returncode == 0:
                break
            assert time.monotonic() < deadline, result.stderr
            time.sleep(0.1)
        response = json.loads(result.stdout)
        assert response["ok"] and len(response["nodes"]) == 1
        check(response["nodes"][0])
        print("SNAPSHOT " + json.dumps(response, ensure_ascii=False), flush=True)
        print("PASS QEMU encrypted get: " + " ".join(command), flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


if __name__ == "__main__":
    main()
