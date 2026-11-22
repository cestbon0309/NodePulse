#!/usr/bin/env python3
"""Host-only admin integration: test-admin.py ./npulse-host ./dist/npulse-host-lite.

Power is tested ONLY after the host binary advertises its compiled-in recording hook.
"""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("admin", ROOT / "tools/npulse-admin.py")
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
SECRET, TOKEN = "admin-integration-probe-secret", "admin-relay-token"
processes, logs = [], []


def port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(fn, seconds=10):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, EOFError):
            pass
        time.sleep(.05)
    raise AssertionError("timed out waiting for admin test condition")


def start(root, *args, binary=None, env=None):
    log = open(root / f"probe-{len(processes)}.log", "w+b")
    logs.append(log)
    p = subprocess.Popen([str(Path(binary or sys.argv[1]).resolve()), *args],
                         stdout=log, stderr=log, env=env)
    processes.append(p)
    return p


def node(p):
    with socket.create_connection(("127.0.0.1", p), 2) as sock:
        rid = os.urandom(16).hex()
        sock.sendall(c.outer_encode(SECRET, {"op": "get", "ts": int(time.time()), "rid": rid}))
        result = c.outer_receive(sock, SECRET)
        assert result["rid"] == rid
        return next(n["id"] for n in result["nodes"] if n.get("relay") is False)


def silent(p, payload):
    with socket.create_connection(("127.0.0.1", p), 3) as sock:
        sock.sendall(payload)
        try:
            assert sock.recv(1) == b"", "rejected request returned bytes"
        except ConnectionResetError:
            pass


def rejected(fn):
    try:
        fn()
    except OSError as error:
        assert str(error)
        return
    raise AssertionError("expected session error")


def main(root):
    private_file = root / "admin-key.json"
    command = [sys.executable, str(ROOT / "tools/npulse-admin.py")]
    result = subprocess.run([*command, "keygen", "--out", str(private_file)], check=True, capture_output=True, text=True)
    key = json.loads(private_file.read_text())
    assert key["public"] in result.stdout and private_file.stat().st_mode & 0o777 == 0o600
    signing = Ed25519PrivateKey.from_private_bytes(bytes.fromhex(key["seed"]))
    other = Ed25519PrivateKey.generate()
    p, http, relay = port(), port(), port()
    record = root / "power-record"
    env = dict(os.environ, NPULSE_TEST_POWER_FILE=str(record))
    start(root, "-l", f"127.0.0.1:{p}", "-H", f"127.0.0.1:{http}", "-S", f"127.0.0.1:{relay}",
          "-T", TOKEN, "-k", SECRET, "-A", key["public"] + "," + c.public(other).hex(), env=env)
    own = wait_for(lambda: node(p))

    def connect():
        return c.AdminClient("127.0.0.1", p, SECRET, signing, node=own)

    def hello(key=signing, **kwargs):
        return c.hello(kwargs.pop("node", own), key, X25519PrivateKey.generate(), **kwargs)

    invalid = [hello(key=Ed25519PrivateKey.generate()), hello(node="not-this-node"),
               hello(timestamp=int(time.time()) - 1000), hello(timestamp=int(time.time()) + 1000)]
    bad = hello(); bad["sig"] = ("01" if bad["sig"][:2] != "01" else "02") + bad["sig"][2:]; invalid.append(bad)
    bad = hello(); bad["v"] = 2; invalid.append(bad)
    bad = hello(); bad["epk"] = "00" * 32
    bad["sig"] = signing.sign(f'npulse-admin-hello\n{own}\n{bad["ts"]}\n{bad["rid"]}\n{bad["epk"]}'.encode()).hex()
    invalid.append(bad)
    for obj in invalid:
        silent(p, c.outer_encode(SECRET, obj))
    request = hello()
    with socket.create_connection(("127.0.0.1", p), 3) as sock:
        sock.sendall(c.outer_encode(SECRET, request))
        ack = c.outer_receive(sock, SECRET)
        c.AdminClient.verify_ack(SECRET, request, ack)
        for corrupt in ({**ack, "mac": "00" * 32}, {**ack, "rid": "00" * 16}, {**ack, "epk": "00" * 32}):
            try:
                c.AdminClient.verify_ack(SECRET, request, corrupt)
            except ValueError:
                pass
            else:
                raise AssertionError("client accepted corrupt identity ACK")
    silent(p, c.outer_encode(SECRET, request))
    silent(relay, c.outer_encode(TOKEN, hello()))
    body = c.outer_encode(TOKEN, hello())
    header = f"POST /api/relay HTTP/1.1\r\nContent-Type: application/octet-stream\r\nContent-Length: {len(body)}\r\n\r\n".encode()
    silent(http, header + body)
    print("PASS direct-only hello: allowlist, bad signature/node/version/timestamp and RID replay rejected silently; client checks ACK MAC/rid/ephemeral binding")

    for binary in (sys.argv[1], sys.argv[2]):
        q = port()
        start(root, "-l", f"127.0.0.1:{q}", "-k", SECRET, binary=binary)
        ident = wait_for(lambda: node(q))
        silent(q, c.outer_encode(SECRET, c.hello(ident, signing, X25519PrivateKey.generate())))
    invalid_config = subprocess.run([str(Path(sys.argv[1]).resolve()), "-H", str(port()), "-k", SECRET, "-A", key["public"]], capture_output=True)
    assert invalid_config.returncode == 2
    assert b"npulse-admin-hello" not in Path(sys.argv[2]).read_bytes()
    q = port(); config = root / "admin.conf"
    config.write_text(f"secret={SECRET}\nlisten=127.0.0.1:{q}\nadmin_keys={key['public']}\n")
    start(root, "-c", str(config)); ident = wait_for(lambda: node(q))
    with c.AdminClient("127.0.0.1", q, SECRET, signing, node=ident) as client:
        assert client.request("info")["admin_version"] == 1
    with c.AdminClient("127.0.0.1", p, SECRET, other, node=own) as client:
        assert client.request("ping")["ok"]
    print("PASS admin disabled without -A; ADMIN=0 lite silently rejects hello; admin_keys requires direct -l")

    for kind in ("counter", "tag", "replay", "oversize"):
        with connect() as client:
            payload = client.encode({"t": "ping", "id": 1}, counter=1 if kind == "counter" else None)
            if kind == "tag":
                payload = payload[:-1] + bytes([payload[-1] ^ 1])
            if kind == "oversize":
                payload = struct.pack("!I", c.MAX_FRAME + 1)
            if kind == "replay":
                client.sock.sendall(payload)
                assert client._receive()["ok"]
            client.sock.sendall(payload)
            try:
                assert client.sock.recv(1) == b""
            except ConnectionResetError:
                pass
    with connect() as client:
        data = client.encode({"t": "ping", "id": 900})
        client.sock.sendall(data[:4]); time.sleep(5.2); client.sock.sendall(data[4:])
        assert client._receive() == {"id": 900, "ok": True}
        assert client.request("info")["admin_version"] == 1
    print("PASS session AEAD: wrong counter, tampered tag, replay and >128KB length close; partial session frame survives original 5s deadline")

    remote, outside = root / "remote", root / "outside"
    outside.mkdir(); (outside / "keep").write_text("keep me")
    marker = b"FILE_CONTENT_MUST_NOT_BE_LOGGED_19bf"
    source = root / "source.bin"
    source.write_bytes(marker + os.urandom(300 * 1024 - len(marker))); source.chmod(0o640)
    destination, downloaded = remote / "large.bin", root / "downloaded.bin"
    with connect() as client:
        info = client.request("info")
        assert {"hostname", "uid", "shell", "home", "admin_version"} <= info.keys()
        client.request("mkdir", path=str(remote))
        listing = client.request("ls", path=str(remote)); assert listing["entries"] == [] and not listing["truncated"]
        client.upload(source, str(destination))
        client.download(str(destination), downloaded)
        assert hashlib.sha256(source.read_bytes()).digest() == hashlib.sha256(downloaded.read_bytes()).digest()
        st = client.request("stat", path=str(destination)); assert st["type"] == "f" and st["size"] == 307200 and st["mode"] == 0o640
        (remote / "link").symlink_to(outside, target_is_directory=True)
        link = client.request("stat", path=str(remote / "link")); assert link["type"] == "l" and link["target"] == str(outside)
        assert {e["type"] for e in client.request("ls", path=str(remote))["entries"]} == {"f", "l"}
        rejected(lambda: client.upload(source, str(destination)))
        rejected(lambda: client.request("stat", path=str(remote / "missing")))
        rejected(lambda: client.request("get", path=str(destination), offset=-1, len=1))
        rejected(lambda: client.request("get", path=str(destination), offset=0, len=65537))
        (remote / "moved.bin").write_bytes(b"keep")
        rejected(lambda: client.request("mv", **{"from": str(destination), "to": str(remote / "moved.bin")}))
        assert (remote / "moved.bin").read_bytes() == b"keep"
        client.request("mv", **{"from": str(destination), "to": str(remote / "moved.bin"), "overwrite": True})
        changing = remote / "rotation"
        changing.write_bytes(b"old-data")
        first = client.request("get", path=str(changing), offset=0, len=4)
        changing.rename(remote / "rotation.old")
        changing.write_bytes(b"new-data")
        rejected(lambda: client.request("get", path=str(changing), offset=4, len=4, identity=first["identity"]))
        first = client.request("get", path=str(changing), offset=0, len=4)
        changing.write_bytes(b"changed length")
        rejected(lambda: client.request("get", path=str(changing), offset=4, len=4, identity=first["identity"]))
        changing.unlink(); (remote / "rotation.old").unlink()
        handles = [client.request("put_begin", path=str(remote / f"open-{i}"), size=2, overwrite=False)["handle"] for i in range(4)]
        rejected(lambda: client.request("put_begin", path=str(remote / "fifth"), size=0, overwrite=False))
        rejected(lambda: client.request("put", handle=handles[0], offset=1, data="YQ=="))
        rejected(lambda: client.request("put", handle=handles[0], offset=0, data="%%%="))
        rejected(lambda: client.request("put_end", handle=handles[0]))
        with connect() as second:
            rejected(lambda: second.request("put_abort", handle=handles[0]))
        for handle in handles:
            client.request("put_abort", handle=handle)
        assert not list(remote.glob("*.npulse-part"))
        if os.geteuid() != 0:
            handle = client.request("put_begin", path=str(remote / "permission"), size=0, overwrite=False)["handle"]
            remote.chmod(0o500)
            try:
                rejected(lambda: client.request("put_abort", handle=handle))
            finally:
                remote.chmod(0o700)
            assert (remote / "permission.npulse-part").exists()
            client.request("put_abort", handle=handle)
        part = remote / "collision.npulse-part"; part.write_bytes(b"not owned by probe")
        rejected(lambda: client.request("put_begin", path=str(remote / "collision"), size=0, overwrite=True))
        assert part.read_bytes() == b"not owned by probe"
        part.unlink()
        handle = client.request("put_begin", path=str(remote / "race"), size=0, overwrite=False)["handle"]
        (remote / "race").write_bytes(b"new existing target")
        rejected(lambda: client.request("put_end", handle=handle))
        client.request("put_abort", handle=handle)
        assert (remote / "race").read_bytes() == b"new existing target"
        handle = client.request("put_begin", path=str(remote / "empty"), size=0, overwrite=False)["handle"]
        client.request("put_end", handle=handle)
        zero_read = client.request("get", path=str(remote / "moved.bin"), offset=0, len=0)
        assert zero_read["eof"] is True and zero_read["data"] == ""
        empty = client.request("get", path=str(remote / "empty"), offset=0, len=65536)
        assert empty["data"] == "" and empty["eof"] is True
        client.request("put_begin", path=str(remote / "disconnected"), size=10, overwrite=False)
    wait_for(lambda: not (remote / "disconnected.npulse-part").exists())
    cli = [*command, "--host", "127.0.0.1", "--port", str(p), "--secret", SECRET, "--key", str(private_file)]
    result = subprocess.run([*cli, "ls", str(remote)], check=True, capture_output=True, text=True)
    assert json.loads(result.stdout)["ok"]
    subprocess.run([*cli, "put", str(source), str(remote / "moved.bin"), "--overwrite"], check=True, capture_output=True)
    with connect() as client:
        rejected(lambda: client.request("rm", path=str(remote), recursive=False))
        client.request("rm", path=str(remote), recursive=True)
        assert not remote.exists() and (outside / "keep").read_text() == "keep me"
        many = root / "many"; many.mkdir()
        for i in range(5001):
            (many / f"entry-{i:04d}").touch()
        listing = client.request("ls", path=str(many))
        assert len(listing["entries"]) <= 5000 and listing["truncated"] is True
        client.request("rm", path=str(many), recursive=True)
    print("PASS fs: empty ls, stat/symlinks, 300KB multi-chunk upload/download SHA256, modes, overwrite/mv/mkdir, recursive rm without following links, bounded/truncated ls")
    print("PASS uploads: 4-handle/session isolation, offset/base64/size errors, atomic no-overwrite, exclusive part ownership, abort/empty file/disconnect cleanup; Python CLI keygen/ls/put")

    with connect() as client:
        pty = client.request("pty_open", cols=80, rows=24)["pty"]
        client.request("pty_resize", pty=pty, cols=101, rows=35)
        client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(b"stty size; echo hi; echo TERMINAL_CONTENT_NOT_LOGGED_83af; exit 3\n").decode())
        output = bytearray()
        while True:
            event = client.receive()
            if event.get("t") == "pty_out":
                output.extend(base64.b64decode(event["data"], validate=True))
            elif event.get("t") == "pty_exit":
                assert event["pty"] == pty and event["code"] == 3
                break
        assert b"hi" in output and b"35 101" in output
        handles = [client.request("pty_open", cols=80, rows=24)["pty"] for _ in range(4)]
        rejected(lambda: client.request("pty_open", cols=80, rows=24))
        for pty in handles:
            client.request("pty_close", pty=pty)
        exited = set()
        while len(exited) < 4:
            event = client.receive()
            if event.get("t") == "pty_exit":
                exited.add(event["pty"])
        assert exited == set(handles)
    print("PASS PTY: login shell, resize/stty 35x101, echo hi, unsolicited output and exit code 3; 4-PTY cap, close and child reap")

    with connect() as client:
        pty = client.request("pty_open", cols=80, rows=24)["pty"]
        client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(b"trap '' HUP; echo READY_TO_CLOSE; sleep 60\n").decode())
        output = bytearray()
        while b"\r\nREADY_TO_CLOSE\r\n" not in output:
            event = client.receive()
            if event.get("t") == "pty_out":
                output.extend(base64.b64decode(event["data"]))
        before = time.monotonic(); client.request("pty_close", pty=pty)
        while True:
            event = client.receive()
            if event.get("t") == "pty_exit":
                assert event["code"] == 137 and time.monotonic() - before >= 1.8
                break
    pidfile = root / "shell-pid"
    with connect() as client:
        pty = client.request("pty_open", cols=80, rows=24)["pty"]
        command_line = f"trap '' HUP; echo $$ > {shlex.quote(str(pidfile))}; sleep 60\n".encode()
        client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(command_line).decode())
        wait_for(lambda: pidfile.exists() and pidfile.read_text().strip())
        pid = int(pidfile.read_text())

    def reaped():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        return False

    wait_for(reaped)
    with connect() as client:
        client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        pty = client.request("pty_open", cols=80, rows=24)["pty"]
        done = root / "flood-finished"
        command_line = f"head -c 33554432 /dev/zero; touch {shlex.quote(str(done))}\n".encode()
        client.send("pty_in", notification=True, pty=pty, data=base64.b64encode(command_line).decode())
        time.sleep(1)
        before = time.monotonic()
        assert node(p) == own and time.monotonic() - before < 2
        assert not done.exists()
    print("PASS PTY lifecycle: SIGHUP-resistant shell/foreground killed after 2s, disconnect reaps shell; stalled 32MB terminal output does not block monitor get")

    with connect() as client:
        assert client.request("info").get("power_test_hook") is True, "refusing power test without compiled recording hook"
        before = time.monotonic()
        client.request("power", action="reboot")
        assert not record.exists(), "power ran before ACK + grace period"
        wait_for(lambda: record.exists())
        assert time.monotonic() - before >= .9 and record.read_text() == "reboot\n"
        rejected(lambda: client.request("power", action="invalid"))
    if os.geteuid() != 0:
        q = port(); start(root, "-l", f"127.0.0.1:{q}", "-k", SECRET, "-A", key["public"], env={k: v for k, v in os.environ.items() if k != "NPULSE_TEST_POWER_FILE"})
        ident = wait_for(lambda: node(q))
        with c.AdminClient("127.0.0.1", q, SECRET, signing, node=ident) as client:
            rejected(lambda: client.request("power", action="reboot"))
        print("PASS power: host-only hook records reboot after ACK + 1s; invalid action and non-root real-power denial; no machine reboot performed")
    else:
        print("PASS power: host-only hook records reboot after ACK + 1s; non-root denial not exercised as root; no machine reboot performed")
    for log in logs:
        log.flush(); log.seek(0); data = log.read()
        assert marker not in data and b"TERMINAL_CONTENT_NOT_LOGGED_83af" not in data
    logs[0].seek(0); logged = logs[0].read()
    assert b'admin who=' in logged and b'op="put" path=' in logged and b'op="pty_in"' in logged
    print("PASS action audit logs include admin key prefix/op/path and never file contents or terminal data")
    print("ALL ADMIN INTEGRATION CHECKS PASSED")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    with tempfile.TemporaryDirectory(prefix="npulse-admin-") as directory:
        try:
            main(Path(directory))
        except BaseException:
            for log in logs:
                log.flush(); log.seek(0)
                print(log.read()[-16000:].decode(errors="replace"), file=sys.stderr)
            raise
        finally:
            for proc in processes:
                proc.terminate()
            for proc in processes:
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill(); proc.wait()
            for log in logs:
                log.close()
