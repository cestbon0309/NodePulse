# Admin protocol v1 (C1 direct, C2 shared relay)

Admin is a **full operating-system account capability**, not a sandbox. It runs as
the probe's uid; root is required for real power actions. Keep the probe secret
and the Ed25519 private admin key separate. Anyone with only the probe secret can
monitor, but cannot start an admin session without an allowlisted signing key.
C1 uses the direct channel; C2 adds a realtime TCP pipe through the shared relay
(specified below). HTTP does not support admin. The iOS client
supports direct TCP and group TCP endpoints. Direct get and shared-relay
monitoring frames are unchanged; legacy direct push has been removed.

## Build and enable

`ADMIN=1` is the default. `make ADMIN=0` excludes admin code. `probe/build.sh`
produces both `npulse-linux-<arch>` and `npulse-linux-<arch>-lite` for all seven
architectures. Lite keeps monitoring and E2E group relay; it rejects admin hello
silently and does not accept `-A` / `admin_keys`. Lite also excludes C2 rendezvous,
listener and pipe code; use the full build for both ends of admin relay piping.

Admin is disabled unless `-A <public key>[,<public key>...]` (or config
`admin_keys=...`) is supplied. Up to 32 Ed25519 public keys, each exactly 64
lowercase hex characters, comma-separated without spaces. `-A` requires `-l`
or `-R` (C2). `-R -A` without `-l` is supported and opens no inbound admin port.
Allowlisting is identical across all authorized keys; there are no per-key roles.
Direct mode uses the existing direct TCP port, with no extra admin port. C2 uses
the existing relay TCP port and needs no inbound port on the publishing probe.

```sh
python3 -m pip install cryptography
python3 probe/tools/npulse-admin.py keygen --out "$HOME/nodepulse-admin.json"
# Copy only the printed public key to the probe (never the seed/private file).
npulse -k 'PROBE_SECRET' -l 9000 -A '64_LOWERCASE_HEX_PUBLIC_KEY'

python3 probe/tools/npulse-admin.py --host PROBE_HOST --port 9000 \
  --secret 'PROBE_SECRET' --key "$HOME/nodepulse-admin.json" info
# Other subcommands: ls PATH, stat PATH, get REMOTE LOCAL, put LOCAL REMOTE
# [--overwrite], rm PATH [--recursive], mkdir PATH, mv FROM TO [--force|-f], shell,
# power reboot|poweroff. Power actually acts on the machine: use with care.
```

The private file is created exclusively with mode 0600. No overwrite or seed is
printed by keygen. `--node ID` pins the intended node. Without it the reference
client discovers the self node using a rid-bound direct get first. Secrets on a
command line can appear in process listings: use a trusted local environment.

## Handshake (inside the existing probe-key AEAD)

All hash inputs are raw concatenations; all signed/MAC messages are UTF-8 with
LF separators and **no trailing LF**. Hex is lowercase. Byte-length notation:
X25519/Ed25519 public keys = 32 bytes / 64 hex chars; Ed25519 signature = 64 bytes /
128 hex chars; RID = 16 random bytes / 32 hex chars; ACK MAC = 32 bytes / 64 hex chars.

1. Client sends one existing direct outer frame:

   ```json
   {"op":"admin","v":1,"node":"NODE_ID","ts":1700000000,"rid":"HEX16","epk":"CLIENT_X25519_PUBLIC_HEX32","apk":"ADMIN_ED25519_PUBLIC_HEX32","sig":"SIGNATURE_HEX64"}
   ```

   Signature: Ed25519(admin private key,
   `npulse-admin-hello\n{node}\n{ts}\n{rid}\n{epk}`). Probe requires v=1, apk in
   allowlist, valid signature, exact own node id, ts within ±120s, fresh outer
   nonce and RID. Invalid requests silently close with no bytes. The bounded RID
   cache retains 256 successful hellos for 240s and rejects new hellos when full
   rather than evicting unexpired RIDs. Retrying requires a fresh RID/ephemeral key.

2. Probe creates a fresh X25519 key pair and sends one existing outer frame:

   ```json
   {"ok":true,"rid":"SAME_RID","epk":"PROBE_X25519_PUBLIC_HEX32","mac":"MAC_HEX32"}
   ```

   `id_key = SHA512("npulse-admin-id:" || UTF8(probe -k secret))[0:32]`.
   `mac = HMAC-SHA512(id_key, UTF8("npulse-admin-ack\n{rid}\n{epk_c}\n{epk_p}"))[0:32]`.
   Client must verify RID, key/MAC lengths and constant-time MAC equality before
   sending any admin messages. This proves possession of the probe secret, not a
   separate hardware identity: anyone who knows `-k` can impersonate the probe.

3. `shared = X25519(ephemeral_private, peer_ephemeral_public)`; reject all-zero
   shared secrets. `k = SHA512("npulse-admin-sess" || shared || epk_c || epk_p)`.
   The domain string has **no colon, newline or NUL terminator**.
   `c2p = k[0:32]`, `p2c = k[32:64]`. Probe wipes ephemeral private/shared/KDF
   buffers. Python drops references; Python cannot guarantee secure memory wiping.

## Session framing and lifetime

After the outer ACK the **same connection** carries only session frames:

`len (4-byte BE plaintext/ciphertext length) | ciphertext | tag16`.

ChaCha20-Poly1305 IETF; AD is the four length bytes. No nonce is transmitted.
Each direction independently starts at counter 0. Nonce is
`LE64(counter) || 00 00 00 00`; increment after each authenticated frame.
Authentication failure (including replay, reordering or wrong implicit counter),
counter exhaustion, invalid JSON/NUL, zero length or length >131072 silently closes.
Do not retry ciphertext or reset a counter on a live connection.

The five-second one-frame direct timeout no longer applies after the ACK.
Session idle timeout is 600s of no network reads/writes; client sends ping every
30s (including while a terminal is open). The CLI interactive bridge does so and
restores the local terminal even on error. Session output is queued nonblocking;
PTY reads and incoming requests pause when unsent session output exceeds 256KB.
PTY reads are coalesced to <=16KB raw data per event. Bulk filesystem operations
are synchronous OS calls; slow storage can delay the probe loop.

## JSON messages

Request: `{"id":<signed int64>,"t":"...",...}`. Response echoes id:
`{"id":N,"ok":true,...}` or `{"id":N,"ok":false,"err":"strerror text"}`.
IDs need not be contiguous, but clients should not reuse outstanding IDs.
Unknown fields are ignored. Malformed session envelope/id closes; operation/OS
errors use the error response. Only `pty_in` may omit id; it produces no response,
including on invalid input. Never infer ACKs from notification sequence numbers.

| t | Request fields | Successful response fields / behavior |
|---|---|---|
| ping | none | ok |
| info | none | hostname, uid, shell, home, admin_version:1 |
| power | action: reboot or poweroff | root only; queue ok first, then >=1s after it is written, sync() + Linux reboot(RB_AUTOBOOT/RB_POWER_OFF); on EPERM fork/exec /sbin/reboot or /sbin/poweroff; later errors go to stderr |
| ls | path | entries:[{name,type,size,mode,mtime,target?}], truncated:bool; <=5000 entries, also truncates before the 128KB session frame bound; listing is not sorted |
| stat | path | type,size,mode,mtime,target? (lstat, does not follow final symlink) |
| get | path, offset>=0, len:0...65536, identity?:string | Returns data:base64,size,eof,identity. Identity contains dev/ino/size/mtime (nanoseconds). Clients MUST echo identity for offset>0; absent or changed identity returns ESTALE and fails the download. A zero-byte read is EOF even when stat reports a larger size (sysfs). |
| put_begin | path,size>=0,mode?:0...07777,overwrite:bool | handle:int; exclusive 0600 `<path>.npulse-part`; default final mode 0600 |
| put | handle,offset,data:base64 (<=65536 decoded bytes) | ok; offset must equal bytes written; cannot exceed declared size |
| put_end | handle | exact size required; fchmod + fsync + atomic publish; overwrite uses rename, no-overwrite uses exclusive link + unlink to prevent a race |
| put_abort | handle | close + unlink owned part |
| rm | path,recursive:bool | own fd-relative walker, never follows final/descendant symlinks, recursion depth <=65; non-recursive empty directories supported |
| mkdir | path | mkdir mode 0755 (subject to umask); parent must exist |
| mv | from,to,overwrite?:bool | Fails with EEXIST for an existing destination (including symlinks), unless overwrite:true is explicit. iOS surfaces the error without retrying destructively. |
| pty_open | cols,rows:1...65535 | pty:int; forkpty login shell; max 4 per session |
| pty_in | pty,data:base64 (<=65536 decoded bytes) | no response; nonblocking input queue <=128KB per PTY |
| pty_resize | pty,cols,rows:1...65535 | TIOCSWINSZ |
| pty_close | pty | SIGHUP to shell/foreground groups, SIGKILL after 2s if still present; exit notification follows |

Filesystem paths are UTF-8 OS paths, not sandboxed; relative paths use the probe's
working directory (not shell cwd). stat/ls types: `f` regular, `d` directory,
`l` symlink, `o` other. Size is bytes, mode is an integer permission bitmask,
mtime is Unix seconds. Symlink target is the readlink text. Ordinary reads and
explicit ancestor components follow OS symlink semantics. rm never follows a
final or descendant symlink, including a symlink supplied with trailing slash.
Root, empty and final `.`/`..` names are rejected by upload/rm. Upload filenames
must leave room for `.npulse-part` in the filesystem's NAME_MAX.

At most four upload handles per session. They are session-local, never reused
during that session. Offset/validation errors leave the handle for retry/abort;
I/O write errors abort it. Closing a session aborts all owned parts and terminates
all its PTYs. An existing part is never deleted by a failed put_begin.

PTY child: forkpty establishes a session/controlling terminal; TERM is
`xterm-256color`, HOME/SHELL from getpwuid (fallback HOME `/`); executable passwd
shell, else `/bin/ash`, else `/bin/sh`, invoked with `-l`. Working directory is
HOME (fallback `/`). Normal signals are reset before exec. Descriptors are
close-on-exec. SIGCHLD wakes the poll loop; waitpid(WNOHANG) reaps children.
There are at most 128 active/terminating PTY records probe-wide to bound cleanup.

Unsolicited notifications (no id):

```json
{"t":"pty_out","pty":1,"data":"BASE64"}
{"t":"pty_exit","pty":1,"code":3}
```

code is shell exit status, or 128+signal. Output drains before pty_exit. Clients
must handle these while awaiting any request response, and decode binary output
as terminal bytes (not independent UTF-8 strings per event).

Audit lines on stderr have `admin who=<16 hex apk prefix> op="..." path="..."`
(plus destination for mv). Paths/control characters are quoted. File bytes,
base64 payloads and terminal input/output are never logged. No persistent session
keys are stored. Root admin can of course alter logs and the whole operating
system; signing authenticates access, not the consequences of authorized commands.

## Host-only verification

```sh
make -C probe host-test
make -C probe host-test ADMIN=0 HOST_OUT=dist/npulse-host-lite
python3 probe/tools/test-admin.py probe/npulse-host probe/dist/npulse-host-lite
python3 probe/tools/test-admin-relay.py probe/npulse-host
python3 probe/tools/test-probe.py probe/npulse-host
```

Only `host-test` defines `NPULSE_ADMIN_TEST`. With `NPULSE_TEST_POWER_FILE=PATH`,
power is recorded to that file instead of calling sync/reboot/exec and root is
not required. `info` then advertises `power_test_hook:true`; integration tests
**refuse power testing unless this field is present**. Do not deploy host-test
binaries. Production full/lite builds contain no runtime test-hook bypass.

## C2: shared relay realtime TCP pipe

The pure relay `-S ... -T TOKEN` keeps the C2 registry independently of its opaque
snapshot cache. A publishing probe configured with `-R relay:port -T TOKEN
-G GROUP_SECRET -A ADMIN_PUBLIC_KEY` additionally maintains a persistent control
connection. `-G` still defaults to `-k`; `-k` is not necessary for an outbound-only
probe when `-G` is given. Monitoring publication continues independently of admin.

```sh
# Relay (no metrics, no admin key or group secret):
npulse -S 9010 -T 'RELAY_TOKEN'
# Probe (outbound only, or add -l/-k to also serve direct monitoring/admin):
npulse -R relay.example.com:9010 -T 'RELAY_TOKEN' -G 'GROUP_SECRET' \
  -A '64_LOWERCASE_HEX_ADMIN_PUBLIC_KEY'
# Phone/reference client knows node id from an earlier decrypted snapshot:
python3 probe/tools/npulse-admin.py --relay relay.example.com:9010 \
  --token 'RELAY_TOKEN' --group 'GROUP_SECRET' --node NODE_ID \
  --key "$HOME/nodepulse-admin.json" info
# The same relay options work for ls/stat/get/put/rm/mkdir/mv/shell/power.
```

### Rendezvous messages

Each message below is one existing TOKEN-keyed outer frame (random transmitted
nonce, length AD), not an admin session frame. Initial glisten/gconnect/gaccept
require ts ±120s, random 16-byte RID, group Ed25519 signature and normal nonce/RID
replay checks. gid and slot derivation is unchanged from E2E snapshots. All hex is
lowercase; the CID is 16 random bytes / 32 hex characters. Domain messages have
LF separators and no trailing LF:

| op | JSON fields (besides op) | Ed25519 message signed by group key |
|---|---|---|
| glisten | ts,rid,gid,slot,sig | `npulse-glisten\n{gid}\n{slot}\n{ts}\n{rid}` |
| gconnect | ts,rid,gid,slot,sig | `npulse-gconnect\n{gid}\n{slot}\n{ts}\n{rid}` |
| gaccept | ts,rid,gid,slot,cid,sig | `npulse-gaccept\n{gid}\n{slot}\n{cid}\n{ts}\n{rid}` |

Bad formats/signatures, wrong or already-used CID, replay and exhausted limits
silently close. These ops are TCP-only; `/api/relay` still only serves snapshot
requests, never connection upgrades.

1. Probe sends glisten. Relay returns `{"ok":true,"rid":"SAME_RID"}` and keeps
   the connection. A new registration for the same gid+slot closes/replaces the
   older listener, even at listener capacity. Replacement does not interrupt
   already-paired pipes; already-offered CIDs retain their original 30s deadline.
   Identically configured competing probes can keep replacing each other, so
   node IDs must remain unique.
2. Probe sends `{"op":"gping"}` in a TOKEN frame every 30s; relay replies
   `{"ok":true}` in a TOKEN frame. These keepalives deliberately have no ts, RID
   or group signature: only an already-authenticated listener may send them.
   Relay expires listeners with >90s without a valid gping. Probe reconnects
   after connection/registration failures with 2,4,8,16,32,60,60... second delays;
   successful registration resets backoff to 2s. Connect/registration timeout is
   10s overall (tries alternate resolved addresses on errors or after 3s per
   address), and lack of received control traffic for 90s also triggers reconnect.
3. Phone sends gconnect. If no listener, relay returns
   `{"ok":false,"err":"offline"}` then closes. Otherwise it reserves a pipe,
   creates a CID, sends listener `{"op":"incoming","cid":"..."}` in a TOKEN
   frame, and holds the phone for at most 30s. Phone must send no bytes yet.
4. Probe opens a **new** TCP connection and sends signed gaccept for that exact
   gid+slot+cid. CID is single-use. Relay sends `{"ok":true}` in separate TOKEN
   frames to both phone and probe. Once both ACKs are written it stops framing
   and becomes a bidirectional **raw byte pipe**. An incomplete ACK flush is
   bounded to 10s. The control connection remains available for new offers.

Limits: 256 listeners, 64 reserved/active pipes total, 4 reserved/active pipes per
gid (across slots). Pending gconnect offers count against quotas. Accepted pipes
consume two sockets. Buffers are bounded to 262144 bytes **per direction**; a full
destination buffer disables source reads until drained. Raw bytes are never
parsed, authenticated or logged by the relay. Either endpoint EOF/error closes
both immediately (no half-close semantics); idle >600s closes both. Activity on
either direction refreshes that pipe's idle clock. Snapshot requests and other
pipes remain serviceable under stalled/large streams.

### Admin handshake inside the pipe

After receiving the rendezvous ACK, phone sends the **same signed C1 hello JSON**
but framed only as `BE32(JSON byte length) | UTF8(JSON)` — no TOKEN frame, nonce
or AEAD tag around it. Probe replies with the same C1 ACK JSON in that same
length+plaintext format. Handshake lengths are bounded to 256KB and have the 5s
handshake deadline. `node` must be the probe's own node ID and the independent
admin apk must still be allowlisted by `-A`.

For this transport only,
`id_key = SHA512("npulse-admin-id:" || UTF8(group secret S))[0:32]`.
ACK MAC message and session-key derivation are otherwise exactly C1. In
particular, do **not** use TOKEN or the direct probe secret for this MAC. Verify
RID/MAC before sending a session frame. Subsequent frames are C1 session AEAD
frames, with fresh counters starting at zero, and the C1 idle/ping/cleanup rules.
Both direct and relay transports use the same fd-based admin session engine.

The relay sees gid/slot, timing, sizes, IP addresses and the public hello/ACK
metadata (including **node ID**, admin public key and ephemeral public keys).
Unlike snapshot-only relay usage, admin handshake metadata is not anonymous.
It cannot derive the session keys or modify commands/data without detection.
It can deny service, drop connections and replay public handshake bytes; replay
and key confirmation are checked at the probe/client. Possession of group S can
impersonate probe identity, but does not replace the separately authorized admin
private key needed to issue a valid hello to a real probe.

Control/accept connects and forwarding are nonblocking. Hostname resolution
still uses the system's synchronous resolver, as does existing snapshot pushing;
a slow resolver or filesystem can delay the single probe event loop.

## iOS implementation and live checks

The iOS `AdminSession` uses CryptoKit and Network.framework. For C2 the **phone
only sends gconnect**; the probe's persistent listener receives `incoming` and
the probe opens the separate gaccept connection. The phone waits for the relay's
token-framed `ok` before sending the plaintext hello on its existing socket.
No phone-side glisten/gaccept or extra socket is needed. The pairing ACK does
not echo a RID; the subsequent admin ACK must echo and authenticate the hello RID.

Requests are correlated by id, sent in counter order, and cancelled requests
leave the connection's counters intact. A request timeout closes the session
and resumes every waiter. PTY notifications use a bounded AsyncStream; output
overflow closes rather than silently corrupting terminal output. Ping runs
every 30 seconds. Dismissal/background closes the socket, ending PTYs and
aborting outstanding uploads at the probe. Explicit upload cancellation sends
put_abort; if put_begin was cancelled before its handle arrived, closing the
session provides the cleanup fallback. Committed files are not rolled back.

Admin private keys use WhenUnlockedThisDeviceOnly Keychain storage. Optional
local device authentication gates sessions and key regeneration, defaults on,
uses passcode fallback, and skips simulator/devices with no passcode. It is an
app-side authorization gate, not a Secure Enclave/user-presence key ACL. Remove
old public keys from probe allowlists when rotating a device's key.

`probe/tools/admin-vector.py` emits the fixed X25519/ACK/KDF/session-frame vector
hardcoded in AdminTests. Test-only ephemeral private bytes are deterministic;
production generates fresh keys for every connection. Live XCTest is opt-in:

```sh
make -C probe host-test
# In a separate shell with cryptography installed; stop with Ctrl-C afterwards:
python3 probe/tools/ios-admin-fixtures.py
# Generate the iOS project, then run on an installed simulator:
xcodegen generate --spec ios/project.yml
NPULSE_ADMIN_E2E=1 xcodebuild test -project ios/NodePulse.xcodeproj \
  -scheme NodePulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The fixture enables an explicitly public test signing seed only, binds localhost
19094/19095, and uses temporary UUID-named test directories under the probe user's
home. It never sends power requests. `NPULSE_E2E=1` additionally enables the
existing monitoring tests, which need their separate 19090–19093 fixtures.
