#!/usr/bin/env python3
"""Local PTY pairing fixture (19096), with explicit HTTP terminal approval."""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import socketserver
import time

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("pair_test", root / "probe/tools/test-pair.py")
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
state = None
relay = subprocess.Popen([str(root / "probe/npulse-host"), "-S", "127.0.0.1:19098", "-T", "ios-pair-token"])
expected = 0


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        global state, expected
        try:
            if self.path in ("/start", "/start-relay"):
                if state:
                    try: os.kill(state.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                    state.wait(None)
                is_relay = self.path == "/start-relay"
                state = module.Server(str(root / "probe/npulse-host"), timeout=600, relay=19098 if is_relay else None, token="ios-pair-token", secret="ios-pair-secret")
                value = {"port": 19098 if is_relay else state.port, "url": state.url, "code": state.query.get("c")}
                (root / "ios/build/screens/pair-server-qr.txt").write_text(state.art.decode().replace("\r\n", "\n"))
            elif self.path == "/art":
                capture = state.until("是否一致")
                art = re.search(r"\+---\[NodePulse\]---\+\n(?:\|[^\n]{17}\|\n){9}\+-----\[PAIR\]------\+\n", capture).group(0)
                code = re.search(r"\n(\d{3} \d{3})\n", capture).group(1)
                value = {"art": art, "code": code}
                (root / "ios/build/screens/pair-server-terminal.txt").write_text(capture)
            elif self.path in ("/approve", "/reject"):
                expected = 0 if self.path == "/approve" else 1
                state.answer("y" if self.path == "/approve" else "n"); value = {"ok": True}
            elif self.path == "/finish":
                state.wait(expected); state = None; value = {"ok": True}
            else: raise ValueError("unknown path")
            self.send_response(200)
        except Exception as error:
            value = {"error": str(error)}; self.send_response(500)
        data = json.dumps(value).encode(); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)


class FixtureServer(http.server.HTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "localhost", self.server_address[1]


server = FixtureServer(("127.0.0.1", 19096), Handler)
print("Pairing fixture ready: http://127.0.0.1:19096/start (PTY approval only via /approve)", flush=True)
try: server.serve_forever()
finally:
    relay.terminate(); relay.wait(timeout=5)
    if state:
        try: os.kill(state.pid, signal.SIGTERM); os.close(state.fd)
        except ProcessLookupError: pass
