#!/usr/bin/env python3
"""Direct protocol reference client; pip install cryptography."""
import argparse
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time
import urllib.parse
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives import serialization

MAX_BLOB = 7168


def pair_art(sas):
    cells = [[0] * 17 for _ in range(9)]
    x, y = 8, 4
    for byte in sas:
        for bit in range(0, 8, 2):
            x = max(0, min(16, x + (1 if byte & (1 << bit) else -1)))
            y = max(0, min(8, y + (1 if byte & (2 << bit) else -1)))
            cells[y][x] = min(14, cells[y][x] + 1)
    cells[4][8], cells[y][x] = 15, 16
    table = " .o+=*BOX@%&#/^SE"
    return "+---[NodePulse]---+\n" + "".join("|" + "".join(table[c] for c in row) + "|\n" for row in cells) + "+-----[PAIR]------+\n"


def pair_material(private, peer, psk=None):
    pub = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    shared = private.exchange(X25519PublicKey.from_public_bytes(peer))
    k = hashlib.sha512(b"npulse-pair" + shared + pub + peer + (psk or b"")).digest()
    sas = hashlib.sha512(b"npulse-pair-sas" + k).digest()[:16]
    code = f"{int.from_bytes(sas[:4], 'big') % 1000000:06d}"
    return k, sas, pair_art(sas), code[:3] + " " + code[3:]


class PairClient:
    def __init__(self, host, port, private=None, psk=None, token=None, code=None):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(35)
        self.private = private or X25519PrivateKey.generate()
        self.rx = self.tx = 0
        try:
            if token is not None:
                request = {"op": "pconnect", "code": code, "ts": int(time.time()), "rid": os.urandom(16).hex()}
                self.sock.sendall(encode(token, request))
                header = exact(self.sock, 4); n = struct.unpack("!I", header)[0]
                if not 0 < n <= 4096 or decode(token, header + exact(self.sock, n + 28)).get("ok") is not True:
                    raise ValueError("relay pairing rejected")
            pub = self.private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
            self.send({"op": "pair", "v": 1, "commit": hashlib.sha512(b"npulse-pair-commit" + pub).digest()[:32].hex(), "psk": psk is not None})
            peer = bytes.fromhex(self.receive()["epk"])
            if len(peer) != 32:
                raise ValueError("invalid pairing public key")
            self.send({"epk": pub.hex()})
            self.k, self.sas, self.art, self.code = pair_material(self.private, peer, psk)
            self.private = None
            self.sock.settimeout(185)
        except BaseException:
            self.sock.close()
            raise

    def send(self, obj, encrypted=False):
        data = json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode()
        if not 0 < len(data) <= 4096:
            raise ValueError("pair frame too large")
        header = struct.pack("!I", len(data))
        if encrypted:
            data = ChaCha20Poly1305(self.k[:32]).encrypt(self.tx.to_bytes(8, "little") + bytes(4), data, header)
            self.tx += 1
        self.sock.sendall(header + data)

    def receive(self, encrypted=False):
        header = exact(self.sock, 4)
        size = struct.unpack("!I", header)[0]
        if not 0 < size <= 4096:
            raise ValueError("invalid pair frame")
        data = exact(self.sock, size + (16 if encrypted else 0))
        if encrypted:
            data = ChaCha20Poly1305(self.k[32:]).decrypt(self.rx.to_bytes(8, "little") + bytes(4), data, header)
            self.rx += 1
        return json.loads(data)

    def confirm(self, accepted, name="Python", admin_pk=None):
        self.send({"op": "confirm", "name": name, "admin_pk": admin_pk} if accepted else {"op": "reject"}, True)
        return self.receive(True)

    def close(self):
        self.sock.close()


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
    if obj["op"] == "hpush":
        return (f'npulse-hpush\n{obj["gid"]}\n{obj["slot"]}\n{obj["ts"]}\n'
                f'{obj["rid"]}\n{obj["epoch"]}\n{obj["seq"]}\n{obj["blob"]}').encode()
    if obj["op"] == "gpush":
        return (f'npulse-gpush\n{obj["gid"]}\n{obj["slot"]}\n{obj["ts"]}\n'
                f'{obj["rid"]}\n{obj["blob"]}').encode()
    message = f'npulse-gget\n{obj["gid"]}\n{obj["ts"]}\n{obj["rid"]}'
    if "since" in obj:
        message += "\n" + json.dumps(obj["since"], ensure_ascii=False, separators=(",", ":"))
    return message.encode()


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
    if not 0 < size <= 2 * 1024 * 1024 or len(frame) != size + 32:
        raise ValueError("invalid frame length")
    cipher = ChaCha20Poly1305(hashlib.sha512(secret.encode()).digest()[:32])
    return json.loads(cipher.decrypt(frame[4:16], frame[16:], length))


def encode(secret, obj, nonce=None):
    payload = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
    if not 0 < len(payload) <= 2 * 1024 * 1024:
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
        if not 0 < size <= 2 * 1024 * 1024:
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
    if len(sys.argv) > 1 and sys.argv[1] in ("pair", "pair-relay"):
        relay = sys.argv[1] == "pair-relay"
        parser = argparse.ArgumentParser(description="Temporary direct SAS pairing")
        parser.add_argument("address", nargs="?", help="HOST:PORT or [IPv6]:PORT")
        parser.add_argument("--url", help="nodepulse://pair URL; still requires matching art and dual approval")
        parser.add_argument("--token", help="relay token (prefer NPULSE_TOKEN environment variable)")
        parser.add_argument("--code", help="relay pairing code XXXX-XXXX")
        parser.add_argument("--admin-pk", help="optional Ed25519 public key to authorize (full probe)")
        args = parser.parse_args(sys.argv[2:])
        token, code, psk = args.token or os.environ.get("NPULSE_TOKEN"), args.code, None
        if args.url:
            url = urllib.parse.urlparse(args.url)
            query = urllib.parse.parse_qs(url.query, keep_blank_values=True)
            if url.scheme != "nodepulse" or url.netloc != "pair" or url.path not in ("", "/") or any(len(v) != 1 for v in query.values()) or query.get("v") != ["1"]:
                parser.error("invalid pairing URL")
            q = {k: v[0] for k, v in query.items()}
            try:
                text = q["s"]
                if len(text) != 22 or any(ch not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for ch in text):
                    raise ValueError("PSK must be 16-byte base64url")
                psk = base64.urlsafe_b64decode(text + "==")
                if "r" in q:
                    if "h" in q or not q.get("t") or not q.get("c"): raise ValueError("invalid relay URL")
                    relay, token, code, args.address = True, q["t"], q["c"], q["r"]
                else:
                    host, port = q["h"], int(q["p"])
                    args.address = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
            except (KeyError, ValueError): parser.error("invalid pairing URL fields")
        if not args.address or (relay and (not token or not code)):
            parser.error("provide HOST:PORT; relay pairing requires --token/NPULSE_TOKEN and --code")
        host, port = args.address.rsplit(":", 1)
        if args.admin_pk and (len(args.admin_pk) != 64 or any(c not in "0123456789abcdefABCDEF" for c in args.admin_pk)):
            parser.error("--admin-pk must be 32-byte hex")
        print(f"连接{'中转' if relay else '探针'} {args.address}；扫码仅填写连接信息，仍须核对图案。", file=sys.stderr)
        if input("继续连接？[y/N] ").strip().lower() != "y": raise SystemExit(1)
        client = PairClient(host.strip("[]"), int(port), psk=psk, token=token if relay else None, code=code)
        try:
            print(client.art + "\n" + client.code, file=sys.stderr, flush=True)
            accepted = input("服务器上的图案和数字是否一致？[y/N] ").strip().lower() == "y"
            result = client.confirm(accepted, admin_pk=args.admin_pk.lower() if args.admin_pk else None)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            if not result.get("ok"):
                raise SystemExit(1)
        finally:
            client.close()
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("port", type=int)
    parser.add_argument("-k", "--key")
    parser.add_argument("-T", "--token")
    parser.add_argument("-G", "--group-secret")
    parser.add_argument("--raw", action="store_true", help="print opaque gget response")
    parser.add_argument("op", choices=["get", "gget", "gpush"], default="get", nargs="?")
    parser.add_argument("--node", help="snapshot JSON file, required for gpush")
    args = parser.parse_intermixed_args()
    obj = {"op": args.op, "ts": int(time.time())}
    if args.op == "gpush":
        if not args.node:
            parser.error("gpush requires --node")
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
            parser.error("get requires -k SECRET")
        result = exchange(args.host, args.port, args.key, obj)
    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
