#!/usr/bin/env python3
"""Application-wire bandwidth proxy for measure-history.sh. Excludes TCP/IP headers."""
import collections
import importlib.util
import json
from pathlib import Path
import socket
import socketserver
import struct
import sys
import threading
import time

spec = importlib.util.spec_from_file_location("client", Path(__file__).with_name("npulse-cli.py"))
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)
relay = int(sys.argv[1])
proxy = int(sys.argv[2])
seconds = int(sys.argv[3]) if len(sys.argv) > 3 else 130
counts = collections.Counter()
sizes = collections.Counter()
slots = collections.defaultdict(set)
lock = threading.Lock()


def wire(sock):
    header = c.exact(sock, 4)
    length = struct.unpack("!I", header)[0]
    assert 0 < length <= 2 * 1024 * 1024
    return header + c.exact(sock, length + 28)


class Push(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            frame = wire(self.request)
            obj = c.decode("measurement", frame)
            with socket.create_connection(("127.0.0.1", relay), timeout=4) as target:
                target.sendall(frame)
                wire(target)
            with lock:
                counts[obj["op"]] += 1
                sizes[obj["op"]] += len(frame)
                if obj["op"] == "hpush": slots[obj["slot"]].add(obj["seq"])
        except (OSError, EOFError):
            with lock: counts["errors"] += 1


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


server = Server(("127.0.0.1", proxy), Push)
threading.Thread(target=server.serve_forever, daemon=True).start()
end = time.monotonic() + 60
while time.monotonic() < end:
    if counts["hpush"] >= 10: break
    time.sleep(.1)
else: raise RuntimeError("ten publishers did not start")
began = time.monotonic()
initial_counts, initial_sizes = counts.copy(), sizes.copy()
get_up = get_down = 0
cursors = {}
max_records = 0
while time.monotonic() - began < seconds:
    request = c.group_request("measurement-group")
    request["since"] = cursors
    request["sig"] = c.group_keys("measurement-group")[2].sign(c.group_message(request)).hex()
    frame = c.encode("measurement", request)
    with socket.create_connection(("127.0.0.1", relay), timeout=4) as target:
        target.sendall(frame)
        response = wire(target)
    get_up += len(frame); get_down += len(response)
    result = c.decode("measurement", response)
    for item in result["blobs"]:
        if "history" in item:
            h = item["history"]
            cursors[item["slot"]] = {"epoch": h["epoch"], "since": h["seq"]}
            max_records = max(max_records, len(h["samples"]))
    time.sleep(max(0, 1 - ((time.monotonic() - began) % 1)))
elapsed = time.monotonic() - began
request = c.group_request("measurement-group"); request["since"] = {}
request["sig"] = c.group_keys("measurement-group")[2].sign(c.group_message(request)).hex()
full = c.exchange("127.0.0.1", relay, "measurement", request)
retained = [len(item.get("history", {}).get("samples", [])) for item in full["blobs"]]
assert len(retained) == 10 and min(retained) == 120, retained
with lock:
    result = {"platform": "Linux aarch64 under QEMU TCG", "seconds": round(elapsed, 2),
              "publishers": len(slots), "retained_records": retained,
              "pushes": {op: counts[op] - initial_counts[op] for op in ("hpush", "gpush")},
              "publisher_bytes_per_second_per_node": {op: round((sizes[op] - initial_sizes[op]) / elapsed / 10, 2) for op in ("hpush", "gpush")},
              "get_request_bytes_per_second_per_node": round(get_up / elapsed / 10, 2),
              "get_response_bytes_per_second_per_node": round(get_down / elapsed / 10, 2),
              "errors": counts["errors"], "unique_samples_per_node": sorted(len(value) for value in slots.values())}
print(json.dumps(result, indent=2), flush=True)
server.shutdown()
