# 120-second resource history

Full and lite probes retain 120 samples in a fixed ring. Sampling is 1 Hz, independent
of `interval`, which still controls snapshot publishing. Snapshots use the latest
sampled CPU, memory, swap, disk, load and network values. Sampling reuses proc streams
and fixed buffers; appending a record allocates nothing. A delayed event loop records
the current observation rather than inventing samples for missed wall-clock seconds.
Each process boot generates a nonzero random 64-bit epoch, encoded as 16 lowercase
hex digits. Sequence numbers are uint32 and wrap modulo 2^32.

## Direct TCP and HTTP

The existing authenticated `get` request accepts optional `since` (uint32) and
`epoch`. Existing `rid`, timestamp, nonce and encryption rules are unchanged.
HTTP `/api/nodes` accepts the same cursor JSON in `X-Npulse-History`.

```json
{"op":"get","ts":1700000000,"rid":"00112233445566778899aabbccddeeff","since":41,"epoch":"1234567890abcdef"}
```

The existing `nodes` response gains an additive top-level field for the local node:

```json
{"history":{"epoch":"1234567890abcdef","seq":42,"full":false,"samples":[[42,1700000000,12.5,40,0,20,0.1,0.2,0.3,100,200]]}}
```

Sample positions are `[seq, unix_seconds, cpu_percent, memory_percent, swap_percent,
disk_percent, load1, load5, load15, rx_bytes_per_second, tx_bytes_per_second]`.
Wire metrics have two decimal places. `seq` is the latest sequence even when the
sample array is empty. A missing/malformed cursor, epoch mismatch, future cursor,
or cursor older than the oldest retained sequence minus one returns the full ring
(`full:true`). Otherwise the response contains only newer samples. Unsigned serial
arithmetic handles sequence wrap. Old clients can ignore the additive field; new
clients accept old snapshot-only responses.

## Opaque shared relay

Publishers continue normal `gpush` snapshots at `interval` and send `hpush` once for
each new sample. The existing relay is one-request-per-connection, so publishers use
two nonblocking channels with a shared asynchronous DNS cache and bounded frames/deadlines,
not blocking connects in the sampling loop. There is no durable delivery ACK: a
failed/dropped sample can leave a gap, which the app detects and refreshes in full.
Both publisher channels stay on the same address candidate and advance only on
failure, so independent DNS backends do not receive round-robin fragments of history.
DNS refresh preserves that candidate by address value if still present, otherwise
it resets to the first address in the new list.

Snapshot/history and admin/pair pipe connections share up to eight resolved IPv4/IPv6
addresses. Connection errors/timeouts request a fresh lookup, at most once every
30 seconds, including startup and failed lookups. Resolution runs in one child
worker, with a five-second alarm and six-second parent deadline; IPC and child
reaping are nonblocking. Failed DNS preserves the last usable cache. Successful
refresh lets disconnected admin listeners retry without waiting for old backoff.
Pairing connections drive the same resolver within the pairing window deadline.
An initial DNS failure no longer terminates a normal publisher: monitoring continues
while the worker retries. The injected-resolver fixture is `tools/test-upstream.c`;
`tools/test-upstream.py` tests address changes without modifying system DNS/hosts.

History plaintext is `{"epoch":"...","sample":[...]}`. Encryption uses the existing
group key, a fresh ChaCha20-Poly1305 nonce, and distinct authenticated data:

```text
npulse-history-v1:<gid>:<slot>:<epoch>:<seq>
```

The base64 nonce/ciphertext/tag is `blob`; outer `epoch` and `seq` allow indexing but
never expose metrics. The Ed25519 message is UTF-8, newline-separated, with no final
newline:

```text
npulse-hpush
<gid>
<slot>
<timestamp>
<rid>
<epoch>
<seq>
<blob>
```

`gget` optionally adds `since:{"<slot>":{"epoch":"...","since":41}}`. An empty map
requests full history for all slots. The signature message is the original
`npulse-gget\n<gid>\n<timestamp>\n<rid>` followed by `\n` and the **exact serialized
since-object bytes** when present. The app uses sorted keys and unescaped slashes;
the relay verifies the received object bytes, not a reserialized dictionary.
Omitting `since` preserves the original signed message and snapshot-only response.

Each returned blob may include `history:{epoch,seq,full,samples:[[42,"..."]]}`.
Epoch changes reset a slot's opaque ring. Stale/future cursors and epoch mismatches
return the retained full ring; a gap in increments makes the app request a full
refresh. Duplicate/older history pushes do not
overwrite newer records. History-only slots may temporarily have no snapshot blob.
Snapshot age tracks the last snapshot, not the most recent history push.

Relays cannot decrypt records. The app authenticates outer epoch/sequence through
AD, verifies matching encrypted values and checks array shape, sequence order and
continuity. Old publishers remain snapshot-only. New publishers still deliver
snapshots to old relays; the app retries an unsupported history get without `since`
and remembers snapshot-only mode for that endpoint.

## App lifecycle and merging

Default foreground polling is 1 second; an explicit saved refresh setting remains
effective. Polling stops in the background. First connect, foreground, failed
connection, epoch mismatch and sequence gaps invalidate cursors for full refresh.
Per-node windows deduplicate serial sequences, sort timestamps and retain at most
120 points from the latest 120 seconds. Full responses replace the window;
increments must be contiguous. Late responses cannot roll a cursor backwards.
The detail chart has a fixed 120-second x domain. Demo mode seeds 120 1 Hz points.

## Caps, memory and measurements

- 256 groups, 32 slots/group, snapshot blob <=7,168 base64 bytes.
- Globally at most 64 opaque history rings; each holds 120 records <=384 base64
  bytes. Once exhausted, additional slots still accept snapshots.
- A 64-bit opaque ring is 47,072 bytes: all 64 rings use 3,012,608 bytes (~2.87 MiB).
  The local metric ring is 10,584 bytes. Both remain bounded after wraparound.
- At every slot's snapshot cap, strings consume 58,728,448 bytes (~56 MiB), plus
  ~0.61 MB group/index storage. This cap predates history; do not provision tiny
  routers for all 8,192 snapshot slots simultaneously.
- Monitoring input <=256 KiB/client, response <=2 MiB, at most 32 concurrent clients.
  Including all stored snapshots/history and concurrent buffers, budget roughly
  140 MiB for saturated monitoring application storage, or 160 MiB allowing allocator
  and libc overhead. Kernel socket memory and optional admin sessions are additional.
  This is a cap-derived capacity budget, not a measured worst-case RSS.

Before adding the asynchronous DNS cache (~2 KiB cache/IPC storage), measured on
Linux aarch64 (Alpine kernel, QEMU TCG, static lite, 4 KiB pages), after
120 seconds: `-l` only **200 KiB RSS**; `-l + -S`, ten actual 1 Hz encrypted publishers,
**1,460–1,468 KiB RSS**. Server RSS excludes publisher processes. All ten slots were
verified to retain 120 records. Native macOS full host regression: 1,728 KiB direct,
3,104 KiB combined with ten publishers (shorter regression window).

Over 125.01 seconds, ten publishers sent 1,250 history records and 240 five-second
snapshots, with zero proxy errors. Application-wire bandwidth per node:
history upload **584.99 B/s**, snapshot upload **223.50 B/s**; incremental 1 Hz group
get request **106.72 B/s**, response **1,134.76 B/s**. Responses include the latest
snapshot and opaque increments; a new consumer also downloads the initial ring.
These figures include encrypted framing, exclude TCP/IP headers/connection setup,
and depend on snapshot/name lengths. They are not estimates of cellular billing.

Reproduce with `tools/measure-history.sh` on Linux using a lite binary and a
`tools/test-history-server.c` fixture binary (unique publisher IDs), plus
`tools/measure-history.py RELAY_PORT PROXY_PORT 125` on the proxy host. Pass the
proxy address as the shell script's fourth argument; its default duration is 130 s.

Lite retains history, but omits unused C unwind tables and uses shorter help. All
seven builds remain below 200,000 bytes; measured MIPS/MIPSel with DNS refresh:
193,920 / 192,928 bytes.

## Regression vectors

`tools/history-vector.c` generates and verifies a C history-get fixture in
`tools/e2e-vector.json`; iOS tests verify it with CryptoKit and compare signed bytes.
Tests also emit `HISTORY_APP_REQUEST <base64>`; decode this to a JSON file and run
`history-vector --verify FILE` to pass the actual app request through C `group_request`.
Compare message bytes and verify signatures, not signature equality: observed
CryptoKit signatures across two iOS 27 simulator runs differed for identical keys
and message bytes, while both were accepted by C. The C fixture remains deterministic.
