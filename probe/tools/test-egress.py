#!/usr/bin/env python3
"""Offline discovery fixtures; full binary then optional lite binary."""
import http.server
import importlib.util
import pathlib
import socket
import subprocess
import sys
import threading
import time

spec = importlib.util.spec_from_file_location("client", pathlib.Path(__file__).with_name("npulse-cli.py"))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
hits = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits.append(self.path)
        if self.path == "/slow":
            time.sleep(4)
        bodies = {"/v4": b"1.1.1.1\n", "/v6": b"2606:4700:4700::1111\n", "/private": b"192.168.1.1", "/bad": b"<html>no</html>", "/empty": b"", "/slow": b"8.8.8.8"}
        body = bodies.get(self.path, b"no")
        self.send_response(500 if self.path == "/error" else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"


def run(service, expected, duration=3, binary=None):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    proc = subprocess.Popen([binary or sys.argv[1], "-l", f"127.0.0.1:{port}", "-k", "egress-test", "-E", service], stdout=subprocess.DEVNULL)
    try:
        end = time.monotonic() + duration
        count = 0
        last = None
        while time.monotonic() < end:
            start = time.monotonic()
            try:
                node = client.exchange("127.0.0.1", port, "egress-test", {"op": "get", "ts": int(time.time())})["nodes"][0]
            except (ConnectionError, OSError, EOFError):
                time.sleep(0.05)
                continue
            assert time.monotonic() - start < 0.8, "discovery stalled monitoring"
            last = node.get("egress_ip")
            count += 1
            time.sleep(0.05)
        assert count >= 10 and last == expected, (service, count, last, expected)
    finally:
        proc.terminate()
        proc.wait(timeout=10)


try:
    for path, expected in [("/v4", "1.1.1.1"), ("/v6", "2606:4700:4700::1111"), ("/private", None), ("/bad", None), ("/empty", None), ("/error", None)]:
        before = len(hits)
        run(base + path, expected)
        assert len(hits) == before + 1, "success/failure discovery refetched every poll"
    run(base + "/private," + base + "/v4", "1.1.1.1", duration=4)
    run(base + "/slow", "8.8.8.8", duration=6)
    before = len(hits)
    run("off", None)
    assert len(hits) == before
    if len(sys.argv) > 2:
        run(base + "/v4", None, binary=sys.argv[2])
        assert len(hits) == before
    invalid = subprocess.run([sys.argv[1], "-E", "https://example.com"], capture_output=True, timeout=3)
    assert invalid.returncode == 2 and b"http://" in invalid.stderr
    print("PASS offline egress HTTP: IPv4/IPv6, private/malformed/empty/error rejection, fallback, slow discovery keeps monitoring responsive, cached schedule, disable and lite omission")
finally:
    server.shutdown()
