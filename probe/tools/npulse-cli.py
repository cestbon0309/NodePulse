#!/usr/bin/env python3
"""Direct protocol reference client; pip install cryptography."""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import time
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

MAX_BLOB = 7168


def group_keys(secret):
    secret = secret.encode()
    enc = hashlib.sha512(b"npulse-e2e-enc:" + secret).digest()[:32]
    seed = hashlib.sha512(b"npulse-e2e-sign:" + secret).digest()[:32]
    signing = Ed25519PrivateKey.from_private_bytes(seed)
    gid = signing.public_key().public_bytes(serialization.Encoding.Raw,
                                           serialization.PublicFormat.Raw).hex()
    return enc, seed, signing, gid


def group_slot(enc, node_id):
    return hashlib.sha512(b"npulse-e2e-slot:" + enc + node_id.encode()).digest()[:16].hex()


def seal_blob(secret, node, nonce=None):
    enc, _, _, gid = group_keys(secret)
    slot = group_slot(enc, node["id"])
    nonce = os.urandom(12) if nonce is None else nonce
    payload = json.dumps(node, separators=(",", ":"), ensure_ascii=False).encode()
    blob = base64.b64encode(nonce + ChaCha20Poly1305(enc).encrypt(
        nonce, payload, f"{gid}:{slot}".encode())).decode()
    if len(blob) > MAX_BLOB:
        raise ValueError("blob exceeds 7168 bytes")
    return slot, blob


def open_blobs(secret, response):
    enc, _, _, gid = group_keys(secret)
    nodes = []
    for item in response["blobs"]:
        slot, blob = item["slot"], item["blob"]
        if len(blob) > MAX_BLOB:
            raise ValueError("blob exceeds 7168 bytes")
        raw = base64.b64decode(blob, validate=True)
        node = json.loads(ChaCha20Poly1305(enc).decrypt(
            raw[:12], raw[12:], f"{gid}:{slot}".encode()))
        if group_slot(enc, node["id"]) != slot:
            raise ValueError("slot does not match snapshot id")
        nodes.append({"node": node, "age": item["age"], "slot": slot})
    return {"ok": response["ok"], "nodes": nodes}


def group_message(obj):
    if obj["op"] == "gpush":
        return (f'npulse-gpush\n{obj["gid"]}\n{obj["slot"]}\n{obj["ts"]}\n'
                f'{obj["rid"]}\n{obj["blob"]}').encode()
    return f'npulse-gget\n{obj["gid"]}\n{obj["ts"]}\n{obj["rid"]}'.encode()


def group_request(secret, op="gget", node=None, ts=None, rid=None):
    _, _, signing, gid = group_keys(secret)
    obj = {"op": op, "ts": int(time.time()) if ts is None else ts,
           "rid": os.urandom(16).hex() if rid is None else rid, "gid": gid}
    if op == "gpush":
        obj["slot"], obj["blob"] = seal_blob(secret, node)
    obj["sig"] = signing.sign(group_message(obj)).hex()
    return obj


def decode(secret, frame):
    if len(frame) < 33:
        raise ValueError("truncated frame")
    length = frame[:4]
    size = struct.unpack("!I", length)[0]
    if not 0 < size <= 256 * 1024 or len(frame) != size + 32:
        raise ValueError("invalid frame length")
    cipher = ChaCha20Poly1305(hashlib.sha512(secret.encode()).digest()[:32])
    return json.loads(cipher.decrypt(frame[4:16], frame[16:], length))


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
    rid = obj.get("rid")
    if obj.get("op") == "get":
        rid = os.urandom(16).hex()
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
    parser.add_argument("-k", "--key")
    parser.add_argument("-T", "--token")
    parser.add_argument("-G", "--group-secret")
    parser.add_argument("--raw", action="store_true", help="print opaque gget response")
    parser.add_argument("op", choices=["get", "push", "gget", "gpush"], default="get", nargs="?")
    parser.add_argument("--node", help="snapshot JSON file, required for push")
    args = parser.parse_intermixed_args()
    obj = {"op": args.op, "ts": int(time.time())}
    if args.op in ("push", "gpush"):
        if not args.node:
            parser.error("push/gpush requires --node")
        with open(args.node, encoding="utf-8") as src:
            obj["node"] = json.load(src)
    if args.op in ("gget", "gpush"):
        group = args.group_secret or args.key
        if not args.token or not group:
            parser.error("gget/gpush require -T TOKEN and -G SECRET (or -k SECRET)")
        obj = group_request(group, args.op, obj.get("node"))
        result = exchange(args.host, args.port, args.token, obj)
        if args.op == "gget" and not args.raw:
            result = open_blobs(group, result)
    else:
        if not args.key:
            parser.error("get/push require -k SECRET")
        result = exchange(args.host, args.port, args.key, obj)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
