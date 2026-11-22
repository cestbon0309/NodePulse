#!/usr/bin/env python3
"""Authenticated direct admin client. Requires cryptography; see docs/admin-protocol.md."""
import argparse
import base64
from collections import deque
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import select
import signal
import socket
import struct
import sys
import termios
import time
import tty
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

MAX_FRAME = 128 * 1024


def public(key):
    return key.public_key().public_bytes(serialization.Encoding.Raw,
                                         serialization.PublicFormat.Raw)


def read_exact(sock, length):
    result = bytearray()
    while len(result) < length:
        data = sock.recv(length - len(result))
        if not data:
            raise EOFError("probe closed connection")
        result.extend(data)
    return bytes(result)


def outer_encode(secret, obj):
    plain = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
    length, nonce = struct.pack("!I", len(plain)), os.urandom(12)
    key = hashlib.sha512(secret.encode()).digest()[:32]
    return length + nonce + ChaCha20Poly1305(key).encrypt(nonce, plain, length)


def outer_receive(sock, secret):
    length = read_exact(sock, 4)
    size, = struct.unpack("!I", length)
    if not 0 < size <= 256 * 1024:
        raise ValueError("invalid outer length")
    nonce, body = read_exact(sock, 12), read_exact(sock, size + 16)
    key = hashlib.sha512(secret.encode()).digest()[:32]
    return json.loads(ChaCha20Poly1305(key).decrypt(nonce, body, length))


def hello(node, signing, ephemeral, rid=None, timestamp=None):
    obj = {"op": "admin", "v": 1, "node": node,
           "ts": int(time.time()) if timestamp is None else timestamp,
           "rid": os.urandom(16).hex() if rid is None else rid,
           "epk": public(ephemeral).hex(), "apk": public(signing).hex()}
    message = f'npulse-admin-hello\n{node}\n{obj["ts"]}\n{obj["rid"]}\n{obj["epk"]}'
    obj["sig"] = signing.sign(message.encode()).hex()
    return obj


class AdminClient:
    def __init__(self, host, port, secret, signing, node=None, timeout=8):
        self.sock = None
        self.events = deque()
        self.next_id, self.tx_seq, self.rx_seq = 1, 0, 0
        if node is None:
            with socket.create_connection((host, port), timeout) as sock:
                rid = os.urandom(16).hex()
                sock.sendall(outer_encode(secret, {"op": "get", "ts": int(time.time()), "rid": rid}))
                result = outer_receive(sock, secret)
                if result.get("rid") != rid or result.get("ok") is not True:
                    raise ValueError("node discovery response mismatch")
                own = [n for n in result["nodes"] if n.get("relay") is False]
                if len(own) != 1:
                    raise ValueError("direct endpoint must have exactly one self snapshot")
                node = own[0]["id"]
        self.sock = socket.create_connection((host, port), timeout)
        try:
            ephemeral = X25519PrivateKey.generate()
            request = hello(node, signing, ephemeral)
            self.sock.sendall(outer_encode(secret, request))
            ack = outer_receive(self.sock, secret)
            self.verify_ack(secret, request, ack)
            probe_pub = bytes.fromhex(ack["epk"])
            shared = ephemeral.exchange(X25519PublicKey.from_public_bytes(probe_pub))
            keys = hashlib.sha512(b"npulse-admin-sess" + shared + public(ephemeral) + probe_pub).digest()
            self.tx, self.rx = ChaCha20Poly1305(keys[:32]), ChaCha20Poly1305(keys[32:])
            del ephemeral, shared, keys
        except BaseException:
            self.close()
            raise

    @staticmethod
    def verify_ack(secret, request, ack):
        if ack.get("ok") is not True or ack.get("rid") != request["rid"]:
            raise ValueError("admin ACK rid mismatch")
        probe_pub, mac = bytes.fromhex(ack["epk"]), bytes.fromhex(ack["mac"])
        if len(probe_pub) != 32 or len(mac) != 32:
            raise ValueError("invalid admin ACK")
        key = hashlib.sha512(b"npulse-admin-id:" + secret.encode()).digest()[:32]
        message = f'npulse-admin-ack\n{request["rid"]}\n{request["epk"]}\n{ack["epk"]}'.encode()
        if not hmac.compare_digest(hmac.digest(key, message, "sha512")[:32], mac):
            raise ValueError("probe identity MAC verification failed")

    def encode(self, obj, counter=None):
        plain = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
        if not 0 < len(plain) <= MAX_FRAME or self.tx_seq >= 2**64 - 1:
            raise ValueError("session frame limit")
        length = struct.pack("!I", len(plain))
        nonce = struct.pack("<Q", self.tx_seq if counter is None else counter) + bytes(4)
        self.tx_seq += 1
        return length + self.tx.encrypt(nonce, plain, length)

    def send(self, t, notification=False, **fields):
        obj = {"t": t, **fields}
        if not notification:
            obj["id"] = self.next_id
            self.next_id += 1
        self.sock.sendall(self.encode(obj))
        return obj.get("id")

    def _receive(self):
        length = read_exact(self.sock, 4)
        size, = struct.unpack("!I", length)
        if not 0 < size <= MAX_FRAME or self.rx_seq >= 2**64 - 1:
            raise ValueError("invalid session length/counter")
        nonce = struct.pack("<Q", self.rx_seq) + bytes(4)
        plain = self.rx.decrypt(nonce, read_exact(self.sock, size + 16), length)
        self.rx_seq += 1
        return json.loads(plain)

    def receive(self):
        return self.events.popleft() if self.events else self._receive()

    def request(self, t, **fields):
        identifier = self.send(t, **fields)
        while True:
            obj = self._receive()
            if obj.get("id") == identifier:
                if obj.get("ok") is not True:
                    raise OSError(obj.get("err", "admin request failed"))
                return obj
            self.events.append(obj)

    def close(self):
        if self.sock:
            self.sock.close()
            self.sock = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def upload(self, local, remote, overwrite=False):
        size = os.stat(local).st_size
        handle = self.request("put_begin", path=remote, size=size, mode=os.stat(local).st_mode & 0o777,
                              overwrite=overwrite)["handle"]
        try:
            offset = 0
            with open(local, "rb") as source:
                while data := source.read(65536):
                    self.request("put", handle=handle, offset=offset,
                                 data=base64.b64encode(data).decode())
                    offset += len(data)
            self.request("put_end", handle=handle)
            return {"ok": True, "bytes": offset}
        except BaseException:
            try:
                self.request("put_abort", handle=handle)
            except (OSError, EOFError):
                pass
            raise

    def download(self, remote, local):
        offset = 0
        with open(local, "xb") as dest:
            while True:
                obj = self.request("get", path=remote, offset=offset, len=65536)
                data = base64.b64decode(obj["data"], validate=True)
                dest.write(data)
                offset += len(data)
                if obj["eof"]:
                    return {"ok": True, "bytes": offset}
                if not data:
                    raise OSError("download made no progress")


def interactive(client):
    def size():
        try:
            rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(sys.stdin.fileno(), termios.TIOCGWINSZ, bytes(8)))
            return {"cols": max(1, cols), "rows": max(1, rows)}
        except OSError:
            return {"cols": 80, "rows": 24}

    pty = client.request("pty_open", **size())["pty"]
    original = termios.tcgetattr(sys.stdin) if sys.stdin.isatty() else None
    resized = False

    def resize(signum, frame):
        nonlocal resized
        resized = True

    old_handler = signal.signal(signal.SIGWINCH, resize)
    try:
        if original:
            tty.setraw(sys.stdin)
        next_ping, stdin_open = time.monotonic() + 30, True
        while True:
            if resized:
                client.send("pty_resize", pty=pty, **size())
                resized = False
            if time.monotonic() >= next_ping:
                client.send("ping")
                next_ping = time.monotonic() + 30
            while client.events:
                obj = client.events.popleft()
                if obj.get("t") == "pty_out":
                    sys.stdout.buffer.write(base64.b64decode(obj["data"], validate=True)); sys.stdout.buffer.flush()
                elif obj.get("t") == "pty_exit":
                    return obj["code"]
            readers = [client.sock] + ([sys.stdin] if stdin_open else [])
            ready, _, _ = select.select(readers, [], [], min(1, max(0, next_ping - time.monotonic())))
            if client.sock in ready:
                obj = client._receive()
                if obj.get("ok") is False:
                    raise OSError(obj.get("err"))
                client.events.append(obj)
            if stdin_open and sys.stdin in ready:
                data = os.read(sys.stdin.fileno(), 16384)
                if not data:
                    stdin_open = False
                client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(data or b"\x04").decode())
    finally:
        if original:
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, original)
        signal.signal(signal.SIGWINCH, old_handler)
        try:
            client.request("pty_close", pty=pty)
        except (OSError, EOFError):
            pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9000)
    parser.add_argument("--secret", help="existing direct probe secret")
    parser.add_argument("--key", type=Path, help="private key file created by keygen")
    parser.add_argument("--node", help="expected node id (otherwise discover over authenticated direct get)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("keygen").add_argument("--out", type=Path, required=True)
    sub.add_parser("info")
    for command in ("ls", "stat", "mkdir"):
        sub.add_parser(command).add_argument("path")
    rm = sub.add_parser("rm"); rm.add_argument("path"); rm.add_argument("--recursive", action="store_true")
    mv = sub.add_parser("mv"); mv.add_argument("from_path"); mv.add_argument("to")
    get = sub.add_parser("get"); get.add_argument("path"); get.add_argument("local", type=Path)
    put = sub.add_parser("put"); put.add_argument("local", type=Path); put.add_argument("path"); put.add_argument("--overwrite", action="store_true")
    sub.add_parser("shell")
    sub.add_parser("power").add_argument("action", choices=("reboot", "poweroff"))
    args = parser.parse_args()
    if args.command == "keygen":
        signing = Ed25519PrivateKey.generate()
        seed = signing.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as dest:
            json.dump({"seed": seed.hex(), "public": public(signing).hex()}, dest)
            dest.write("\n")
        print("Admin public key (-A):", public(signing).hex())
        return 0
    if not args.secret or not args.key:
        parser.error("--secret and --key are required")
    signing = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(json.loads(args.key.read_text())["seed"]))
    with AdminClient(args.host, args.port, args.secret, signing, node=args.node) as client:
        if args.command == "shell":
            return interactive(client)
        if args.command == "put":
            result = client.upload(args.local, args.path, args.overwrite)
        elif args.command == "get":
            result = client.download(args.path, args.local)
        else:
            fields = {k: getattr(args, k) for k in ("path", "to", "recursive", "action") if hasattr(args, k)}
            if args.command == "mv":
                fields["from"] = args.from_path
            result = client.request(args.command, **fields)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, EOFError, ValueError) as error:
        print(f"admin: {error}", file=sys.stderr)
        sys.exit(1)
