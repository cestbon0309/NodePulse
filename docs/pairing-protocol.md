# NodePulse pairing v1

Run `npulse -P -l ADDRESS:PORT -k SECRET [-n NAME] [-W SECONDS]` while the
normal service is stopped. IPv6 uses `[address]:port`. The pairing UI defaults
to port 9527; use the actual configured direct port. The default window is 600
seconds (`-W` accepts 1..86400). There is one connection at a time, a 30-second
deadline per connection including human confirmation, and at most five failed
or disconnected attempts. Success exits 0; rejection, timeout, interruption or
exhausted attempts exits 1. Explicit rejection ends the entire window.

All strings below are UTF-8; domain strings have no terminator or trailing
newline. Hex strings are lowercase, with two digits per byte. The first three
frames are `uint32_be(JSON byte length) | JSON`, with a 4096-byte maximum JSON
body, no embedded NUL, and no outer probe-key encryption:

1. Client generates a fresh X25519 ephemeral keypair. Send
   `{"op":"pair","v":1,"commit":"HEX"}` where
   `commit = SHA512("npulse-pair-commit" || epk_c)[0:32]`.
2. Probe generates a fresh X25519 keypair; reply `{"epk":"HEX"}`.
3. Client reveals `{"epk":"HEX"}`. Probe verifies the commitment in constant
   time. Invalid commitment/encoding, malformed or oversized frames, low-order
   points/all-zero shared secrets, and authentication failures close silently.

`shared = X25519(sk_c, epk_p) = X25519(sk_p, epk_c)`.
`k = SHA512("npulse-pair" || shared || epk_c || epk_p)`.
Client-to-probe key is `k[0:32]`, probe-to-client key is `k[32:64]`.
`sas = SHA512("npulse-pair-sas" || k)[0:16]`. Wipe ephemeral secrets after use.

## SAS display

OpenSSH drunken bishop on a 17-column by 9-row grid, initially zero, starts at
`(8,4)`. Process bytes in order, each byte's two-bit groups least-significant
first. Bit 0 selects left(0)/right(1); bit 1 selects up(0)/down(1). Clamp at the
edges and increment the visited cell, saturating at 14. Render with
`" .o+=*BOX@%&#/^SE"`; overwrite the start with `S`, then the final cell with `E`
(thus E wins when they coincide). Each row has `|` at both ends.

Exact 19-character borders: `+---[NodePulse]---+` and `+-----[PAIR]------+`.
The canonical art string is 11 lines, each 19 characters plus LF, including a
final LF (220 bytes total). The code is `BE_uint32(sas[0:4]) % 1000000`, padded
to six digits and displayed as `123 456`. Compare **both** art and code via the
trusted local console, never a picture/code supplied by the network peer.

## Encrypted confirmation

From here use the admin session frame format (compiled when `ADMIN=1` or `PAIR=1`):
`len32_be | ciphertext | tag16`, ChaCha20-Poly1305 with AD equal to the four
length bytes; nonce is `uint64_le(counter) || zero32`. Each direction starts
at counter zero, increments only after a successful authenticated frame, never
wraps, and retains the 4096-byte pairing body limit.

The server prints art/code and prompts on `/dev/tty` (fallback stderr and stdin).
Pending terminal input is flushed before each new SAS display. Client sends
`{"op":"confirm","name":"iPhone…","admin_pk":"HEX"}` (or null/omitted admin
key), or `{"op":"reject"}`. Server approval requires a single `y` or `Y` plus
Enter. A management request on full builds also displays a root-control warning.
Only after **both** approvals may the probe send
`{"ok":true,"key":"SECRET","node":"ID","name":"NAME","port":9527,"admin":true}`.
Otherwise it replies `{"ok":false}` and closes. `admin` is the build capability;
lite always sends false and ignores the requested public key.

On success full builds print **only** `admin_pk=HEX` on stdout if a key was
requested. This does not itself edit the probe's permanent allowlist. The
installer validates/appends that public key, updates service permissions to root
only with this explicit consent, and starts/restarts the normal service. No
permanent monitoring/group secret is printed by pairing mode. The installer retains manual-key fallback.

## Relay rendezvous (TCP only)

Run `npulse -P -R HOST:PORT -T TOKEN -G GROUP [-n NAME] [-W 600]`.
The group secret is generated locally by the installer; it is never a relay
control-field value. Exit 3 means wrong token, unavailable relay or a dropped
rendezvous. The installer offers to re-enter address/password, retaining the
same local group secret. `sh install.sh pair` stops either direct or relay
services and restarts them even after pairing fails.

Relay control messages use the existing token-derived ChaCha20-Poly1305 outer
framing (`len32 | nonce12 | ciphertext | tag16`), timestamp window and one-use
16-byte hexadecimal `rid`, but no group signature (the phone has no group yet):

* Probe: `{"op":"ppair","v":1,"ts":UNIX,"rid":"HEX"}`.
* Relay: `{"ok":true,"code":"XXXX-XXXX"}`. Each code is 40 CSPRNG bits,
  Crockford base32 (`0123456789ABCDEFGHJKMNPQRSTVWXYZ`), unique among pending
  registrations. At most 64 pending codes; one per TCP connection. Expiration
  is 600 seconds or disconnect, whichever comes first.
* Phone: `{"op":"pconnect","code":"XXXX-XXXX","ts":UNIX,"rid":"HEX"}`.
  Case and dashes are ignored; O maps to 0, I/L to 1. Unknown, malformed,
  expired and consumed codes close silently, as do wrong tokens/replayed IDs.
  A global bucket permits a burst of 32 lookups, refilling at one per second.
* A match consumes the code, sends outer-framed `{"ok":true}` to **both**,
  then switches to opaque raw forwarding (64 concurrent pairing pipes;
  256KiB directional buffers/backpressure; 600-second raw idle timeout).

Run the identical three plaintext pairing frames and encrypted dual-confirm
protocol inside this pipe, with no outer wrapping. A failed attempt requires
a new rendezvous code (same overall window, five-attempt limit). Success is
`{"ok":true,"mode":"relay","group":"GROUP","node":"ID","name":"NAME","admin":true}`,
without direct key/port fields. The phone already knows the relay/token.
The relay never parses these raw bytes and never learns the group secret.
The iOS client merges a matching TCP relay address/port and group with its
existing endpoint. Relay HTTPS pairing is not supported.

## QR prefill and PSK

Full builds default to `PAIR=1 QR=1`. Published lite builds default to
`ADMIN=0 PAIR=0 QR=0`, excluding pairing, QR and realtime relay pipes to preserve
the size budget; `npulse -P` prints an explicit unsupported-build error.
`make ADMIN=0 PAIR=1` opts into pairing for a custom lite build (larger).
For a lite installation, both the install-time pairing prompt and `install.sh pair`
download a temporary same-architecture full binary using the configured version,
HTTPS mirror policy and SHA256SUMS verification. Only that temporary binary pairs;
the installed lite binary, service permissions and configuration remain unchanged
except explicitly retried relay connection details. Any returned `admin_pk` is
ignored with a 「lite 版不支持管理」 warning. The temporary files are removed on
success, failure and signal-triggered cleanup, and the lite service is restored.
`QR=0 ./probe/build.sh` or `make QR=0`
omits the encoder (text URLs remain available). The vendored MIT-licensed
Nayuki QR-Code-generator encodes byte mode with ECC M. Terminal output has a
four-module quiet zone and black foreground/white background ANSI half blocks
(`▀▄█`), independent of the terminal theme. `-Q ascii` emits `##` modules
without ANSI colors. The URL text is printed below:

* `nodepulse://pair?v=1&h=HOST&p=PORT&s=PSK`
* `nodepulse://pair?v=1&r=HOST%3APORT&t=TOKEN&c=XXXX-XXXX&s=PSK`

Values use URL percent encoding. PSK is 16 CSPRNG bytes per pairing window,
base64url without padding (22 characters). Wildcard direct binds select a
non-loopback interface address of the same family for the URL; a NATed/private
address may still require relay pairing. Review the address before connecting.

A QR client sets `"psk":true` in frame 1 and derives
`k = SHA512("npulse-pair" || shared || epk_c || epk_p || psk)` instead.
SAS and framing are unchanged. The first encrypted client frame implicitly
proves possession; a wrong PSK causes AEAD failure, silently closing and
counting as a failed attempt. Missing/false `psk` retains manual key derivation.
**QR only fills connection information. Both sides always display art/code;
server `y` AND phone 「一致」 are mandatory, even with PSK.** No auto-accept path
exists. iOS previews host/relay and the admin toggle before connecting; camera
scanning uses VisionKit with AVFoundation fallback, and system-camera links
open the same preview through the `nodepulse` URL scheme.

The QR/URL contains a one-time secret and, for relay mode, the relay password.
Treat terminal scrollback/screenshots/clipboard as sensitive; never publish
them. PSK expires with the window and cannot authorize a second successful
pairing (the probe exits). Do not expose the terminal to untrusted observers.
The rendezvous code alone is not authentication; a malicious token holder can
consume it or deny service, but cannot bypass SAS comparison.

Reference clients: `npulse-cli.py pair HOST:PORT`,
`NPULSE_TOKEN=... npulse-cli.py pair-relay HOST:PORT --code XXXX-XXXX`, or
`npulse-cli.py pair --url 'nodepulse://pair?...'`. Quoted URL arguments may
remain in shell history/process listings; use a trusted machine.

## Security

Commit-before-reveal prevents a MITM from choosing its ephemeral public key
after learning the client's key to grind a matching SAS. Each fresh attempt
still has a finite false-match probability: the decimal code is about 20 bits,
with additional visual comparison of the full 128-bit SAS art. These displays
are not independent cryptographic authentication factors. Never approve a
mismatch. A malicious relay/network can interrupt, consume attempts, or deny
service. A trusted local terminal and an uncompromised phone are required.
The listener exists only while pairing is explicitly running, and sends no
permanent probe/group secret before dual consent. Pairing is not available over
HTTPS. Possession of the resulting probe/group key permits monitoring; an admin
public key additionally grants the service user's control, normally root.

`probe/tools/pair-vector.json` is the canonical C/Python/CryptoKit fixture.
