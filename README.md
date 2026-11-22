# NodePulse

## iOS app core

Requires Xcode and XcodeGen, no third-party packages. Generate the project with
`cd ios && xcodegen`, then open `NodePulse.xcodeproj`. The generated project is
ignored; `project.yml` is the source of truth. Minimum iOS 17, Swift 5 mode.
Simulator builds disable signing. Run tests with:

```
cd ios
xcodegen
xcodebuild test -scheme NodePulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

For the live client test, run the host probe with `-k integration-secret
-l 127.0.0.1:19090 -H 127.0.0.1:19091` and set `NPULSE_E2E=1` for both
`xcodegen` and `xcodebuild test`. Unsigned simulator apps cannot access Keychain
on this Xcode/runtime (`-34018`); the Security integration test explicitly skips
in that case. Store CRUD uses an injected in-memory secret store in tests;
production always defaults to Keychain. Sign the app to verify real Keychain CRUD.

Endpoints and preferences are stored in UserDefaults; secrets only in Keychain
(service `nodepulse`, account endpoint UUID). Direct uses CryptoKit IETF
ChaChaPoly framing. HTTP permits insecure transport only to localhost/127.0.0.1
for development. Redirects are rejected to avoid forwarding bearer secrets.
The placeholder list supports demo mode; endpoint forms come in the UI step.
The probe does not transmit its configured interval, so relay freshness uses a
5-second initial estimate, then the observed snapshot timestamp cadence.

`probe/npulse` is a small, single-process Linux monitoring probe. Version 0.1.0.
No threads or runtime libraries beyond libc; cryptography is vendored Monocypher
4.0.2 from <https://monocypher.org/download/monocypher-4.0.2.tar.gz>.
Only its four source/header files are retained; each carries the upstream
BSD-2-Clause/CC0 dual-license notice. SHA-512 uses the optional Ed25519 module;
unused algorithms are removed by LTO and section garbage collection.

## Build

```
cd probe
make CC=musl-gcc                  # native Linux static build
./build.sh                       # Zig cross-builds all seven variants
make host-test                   # macOS network/crypto test binary npulse-host
```

The build script requires `zig` (`brew install zig` on macOS). Outputs are
`probe/dist/npulse-linux-{x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel}`.
ARM builds target ARMv7 Cortex-A7; `armv7` uses hard-float and `armv7-soft`
uses the soft-float ABI. MIPS builds target MIPS32 with soft float and musl's
O32 ABI (`musleabi` in current Zig). All use static musl, `-Os`, LTO,
function/data sections, linker garbage collection and stripping. Build failures
and warnings are errors. `make` supports `CC`, `CFLAGS`, and `LDFLAGS` overrides.

## Run

```
npulse -k 'shared-secret' -l 9000 -H 8080 -n router
npulse -k 'shared-secret' -u upstream.example:9000 -i 5 -n satellite
npulse -c /etc/npulse.conf
```

`-k` is required. `-l [addr:]port` is the encrypted direct listener (default
address `0.0.0.0`). `-H [addr:]port` is plain HTTP (default `127.0.0.1`), intended
**only behind a TLS reverse proxy**. `-u host:port` pushes upstream every `-i`
seconds (default 5); all three modes may be combined. IPv6 endpoints use
`[address]:port`. `-n` defaults to hostname. `-h` prints usage. At least one
listener or upstream is required. Config is unquoted `key=value`, with blank
lines and `#` comment lines; keys are `secret`, `listen`, `http`, `upstream`,
`interval`, `name`. CLI values override configuration regardless of order.
Protect the config file and command-line secret from other local users.

Direct requests are IETF ChaCha20-Poly1305 frames:
`uint32_be(ciphertext length) | random nonce[12] | ciphertext | tag[16]`.
The length bytes are authenticated additional data, with no magic or other
framing. Key is SHA-512 of the UTF-8 secret, truncated to 32 bytes. Maximum
ciphertext length is 262144. Each connection accepts one request and sends one
response, then closes. Invalid requests receive no bytes. Read/write deadlines
are five seconds. Timestamps must be within 120 seconds. The last 256 accepted
nonces are cached (up to 240 seconds). Use a high-entropy secret: this protocol
does not offer forward secrecy or password stretching.

Requests: `{"op":"get","ts":UNIX_SECONDS}` or
`{"op":"push","ts":UNIX_SECONDS,"node":SNAPSHOT}`. Push snapshots require a
nonempty string id and must not contain server-owned `relay`/`last_seen` fields.
Successful push returns `{"ok":true}`. Get returns
`{"ok":true,"nodes":[...]}`. Self comes first only when `-l` is enabled and has
`relay:false`. Up to 64 relayed nodes are stored by id, with `relay:true` and
`last_seen`; entries expire after ten minutes. A fixed 32-client pool limits
resource use; slow peers do not block other inbound clients. Upstream DNS and
connect/send attempts are synchronous (connect/send waits capped at one second
each, DNS resolution follows the system resolver).

HTTP: `GET /api/nodes`, with `Authorization: Bearer SECRET` or `?key=SECRET`,
returns the same JSON. All other requests return an empty 404. The query key
is literal, not URL-decoded; prefer Bearer for secrets containing special URL
characters and to avoid query-string logging. HTTP headers are limited to 8KB.

Metrics are sampled from Linux procfs/sysfs once per second, plus statvfs and
getifaddrs. Missing metrics are zero/empty except absent temperature is null.
macOS host-test deliberately tolerates missing Linux files (zero-valued procfs
metrics); it is for protocol verification, not macOS monitoring.

## Verify

```
python3 -m venv .venv
.venv/bin/pip install cryptography
.venv/bin/python probe/tools/npulse-cli.py 127.0.0.1 9000 -k shared-secret get
.venv/bin/python probe/tools/npulse-cli.py 127.0.0.1 9000 -k shared-secret push --node snapshot.json
cd probe
../.venv/bin/python tools/test-probe.py ./npulse-host
# On Linux, substitute ./dist/npulse-linux-<arch> for ./npulse-host.
```

The integration check covers direct AEAD interoperability with Python's
ChaCha20Poly1305, snapshot fields and string escaping, silent error handling,
replay rejection, timeout, HTTP auth, relay-only operation, replacement by id,
empty node lists, config and CLI precedence.
