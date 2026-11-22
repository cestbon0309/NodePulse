#!/usr/bin/env python3
"""Direct protocol reference client; pip install cryptography."""
import argparse
import hashlib
import json
import os
import socket
import struct
import time
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305


def encode(secret, obj, nonce=None):
    payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
    if not 0 < len(payload) <= 256 * 1024:
        raise ValueError("frame length out of range")
    length = struct.pack("!I", len(payload))
    nonce = os.urandom(12) if nonce is None else nonce
    cipher = ChaCha20Poly1305(hashlib.sha512(secret.encode()).digest()[:32])
    return length + nonce + cipher.encrypt(nonce, payload, length)


def exact(sock, size):
    chunks = bytearray()
    while len(chunks) < size:
        data = sock.recv(size - len(chunks))
        if not data:
            raise EOFError("peer closed without a complete frame")
        chunks.extend(data)
    return bytes(chunks)


def exchange(host, port, secret, obj):
    rid = os.urandom(16).hex() if obj.get("op") == "get" else None
    if rid is not None:
        obj = dict(obj, rid=rid)
    with socket.create_connection((host, port), timeout=6) as sock:
        sock.sendall(encode(secret, obj))
        length = exact(sock, 4)
        size = struct.unpack("!I", length)[0]
        if not 0 < size <= 256 * 1024:
            raise ValueError("invalid response length")
        nonce = exact(sock, 12)
        cipher = ChaCha20Poly1305(hashlib.sha512(secret.encode()).digest()[:32])
        response = json.loads(cipher.decrypt(nonce, exact(sock, size + 16), length))
        validate_response(response, rid)
        return response


def validate_response(response, rid):
    if rid is not None and response.get("rid") != rid:
        raise ValueError("响应校验失败")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("-k", "--key", required=True)
    parser.add_argument("op", choices=["get", "push"], default="get", nargs="?")
    parser.add_argument("--node", help="snapshot JSON file, required for push")
    args = parser.parse_args()
    obj = {"op": args.op, "ts": int(time.time())}
    if args.op == "push":
        if not args.node:
            parser.error("push requires --node")
        with open(args.node, encoding="utf-8") as src:
            obj["node"] = json.load(src)
    print(json.dumps(exchange(args.host, args.port, args.key, obj), indent=2))


if __name__ == "__main__":
    main()
