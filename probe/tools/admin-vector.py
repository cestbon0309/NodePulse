#!/usr/bin/env python3
"""Fixed public test fixture; never use these ephemeral/private bytes in production."""
import hashlib
import hmac
import json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305


def public(key):
    return key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)


client = X25519PrivateKey.from_private_bytes(bytes(range(1, 33)))
probe = X25519PrivateKey.from_private_bytes(bytes(range(161, 193)))
secret, rid = "admin-vector-秘密", "00112233445566778899aabbccddeeff"
epk_c, epk_p = public(client), public(probe)
id_key = hashlib.sha512(b"npulse-admin-id:" + secret.encode()).digest()[:32]
message = f"npulse-admin-ack\n{rid}\n{epk_c.hex()}\n{epk_p.hex()}".encode()
mac = hmac.digest(id_key, message, "sha512")[:32]
keys = hashlib.sha512(b"npulse-admin-sess" + client.exchange(probe.public_key()) + epk_c + epk_p).digest()
plain = b'{"t":"ping","id":1}'
length = len(plain).to_bytes(4, "big")
frame = length + ChaCha20Poly1305(keys[:32]).encrypt(bytes(12), plain, length)
print(json.dumps({"secret": secret, "rid": rid, "client_public": epk_c.hex(), "probe_public": epk_p.hex(),
                  "mac": mac.hex(), "keys": keys.hex(), "frame": frame.hex()}, ensure_ascii=False, indent=2))
