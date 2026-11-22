# Direct admin protocol v1 (C1)

Admin is a **full operating-system account capability**, not a sandbox. It runs as
the probe's uid; root is required for real power actions. Keep the probe secret
and the Ed25519 private admin key separate. Anyone with only the probe secret can
monitor, but cannot start an admin session without an allowlisted signing key.
There is no admin over HTTP, legacy relay or E2E relay in C1. iOS/relay piping are
later steps. The existing direct get/push and monitoring frame format are unchanged.

## Build and enable

`ADMIN=1` is the default. `make ADMIN=0` excludes admin code. `probe/build.sh`
produces both `npulse-linux-<arch>` and `npulse-linux-<arch>-lite` for all seven
architectures. Lite keeps monitoring and E2E group relay; it rejects admin hello
silently and does not accept `-A` / `admin_keys`.

Admin is disabled unless `-A <public key>[,<public key>...]` (or config
`admin_keys=...`) is supplied. Up to 32 Ed25519 public keys, each exactly 64
lowercase hex characters, comma-separated without spaces. `-A` requires `-l`.
Allowlisting is identical across all authorized keys; there are no per-key roles.
Only open the existing direct TCP port in the firewall; no extra admin port.

```sh
python3 -m pip install cryptography
python3 probe/tools/npulse-admin.py keygen --out "$HOME/nodepulse-admin.json"
# Copy only the printed public key to the probe (never the seed/private file).
npulse -k 'PROBE_SECRET' -l 9000 -A '64_LOWERCASE_HEX_PUBLIC_KEY'

python3 probe/tools/npulse-admin.py --host PROBE_HOST --port 9000 \
  --secret 'PROBE_SECRET' --key "$HOME/nodepulse-admin.json" info
# Other subcommands: ls PATH, stat PATH, get REMOTE LOCAL, put LOCAL REMOTE
# [--overwrite], rm PATH [--recursive], mkdir PATH, mv FROM TO, shell,
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
| get | path, offset>=0, len:0...65536 | data:base64,size:<current file size>,eof:bool; regular files only; arbitrary-offset read |
| put_begin | path,size>=0,mode?:0...07777,overwrite:bool | handle:int; exclusive 0600 `<path>.npulse-part`; default final mode 0600 |
| put | handle,offset,data:base64 (<=65536 decoded bytes) | ok; offset must equal bytes written; cannot exceed declared size |
| put_end | handle | exact size required; fchmod + fsync + atomic publish; overwrite uses rename, no-overwrite uses exclusive link + unlink to prevent a race |
| put_abort | handle | close + unlink owned part |
| rm | path,recursive:bool | own fd-relative walker, never follows final/descendant symlinks, recursion depth <=65; non-recursive empty directories supported |
| mkdir | path | mkdir mode 0755 (subject to umask); parent must exist |
| mv | from,to | OS rename semantics (can replace destination) |
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
python3 probe/tools/test-probe.py probe/npulse-host
```

Only `host-test` defines `NPULSE_ADMIN_TEST`. With `NPULSE_TEST_POWER_FILE=PATH`,
power is recorded to that file instead of calling sync/reboot/exec and root is
not required. `info` then advertises `power_test_hook:true`; integration tests
**refuse power testing unless this field is present**. Do not deploy host-test
binaries. Production full/lite builds contain no runtime test-hook bypass.
