#!/usr/bin/env python3
"""Service-safe installer pair lifecycle using a fake probe; no privileged actions."""
import os
import functools
import hashlib
import http.server
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
source = (root / "install.sh").read_text()
shell = sys.argv[1] if len(sys.argv) > 1 else "/bin/dash"
functions = "\n".join(re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)
                      for name in ("pair_installed", "fetch_binary", "download", "bind_endpoint", "cleanup", "safe_value", "port", "fail"))
functions += "\n" + re.search(r"^write_unit\(\) \{.*?(?=^pair_installed\(\) \{)", source, re.M | re.S).group(0)

with tempfile.TemporaryDirectory(prefix="npulse-pair-installer-") as directory:
    base = Path(directory)
    binary = base / "fake-probe"
    binary.write_text('''#!/bin/sh
set -eu
[ "$1" = -P ] && [ "$2" = -c ]
cp "$3" "$BASE/captured.conf"
printf '%s\\n' "$0" > "$BASE/executed"
if [ "${INTERRUPT:-0}" = 1 ]; then kill -INT "$PPID"; exit 130; fi
if [ "${RETRY:-0}" = 1 ] && [ ! -f "$BASE/retried" ]; then touch "$BASE/retried"; exit 3; fi
if [ -n "${PUBLIC:-}" ]; then printf 'admin_pk=%s\\n' "$PUBLIC"; fi
exit "${RESULT:-0}"
''')
    binary.chmod(0o755)
    def run(mode=1, public="", result=0, retry=False, flavor="full", interrupt=False, mirror="", insecure="1", deferred=False):
        work = base / "work"; work.mkdir(exist_ok=True)
        config = base / "npulse.conf"
        config.write_text("listen=0.0.0.0:9527\nsecret=fixture-secret\nrelay_upstream=old.example:9010\ntoken=old-token\ngroup_secret=fixture-group\n" + ("" if deferred else "admin_keys=" + "b" * 64 + "\n"))
        for name in ("trace", "retried", "captured.conf", "executed"):
            path = base / name
            if path.exists(): path.unlink()
        unit_stub = "" if deferred else "\nwrite_unit() { printf 'root-unit:%s\\n' \"$ADMIN_KEYS\" >> \"$BASE/trace\"; }\n"
        script = "set -eu\numask 077\n" + functions + unit_stub + '''
service() { printf '%s\n' "$1" >> "$BASE/trace"; }
ask() { case "$1" in 重新*) ANSWER=y ;; *) ANSWER=new.example:9020 ;; esac; }
credentials() { ANSWER=new-token; }
WORK=$BASE/work; CONFIG=$BASE/npulse.conf; BIN=$BASE/fake-probe; DESTDIR=
DRY_RUN=0; YES=0; NAME=fixture; BIND=2001:db8::1; PORT=9527; VERSION=; ARCH=mipsel
UPSTREAM=old.example:9010; TOKEN=old-token; GROUP=fixture-group; SECRET=fixture-secret
PAIR_STOPPED=0; ECHO_OFF=0; ADMIN_KEYS=
ADMIN_VIA_PAIR=no; INIT=systemd; UNIT=$BASE/npulse.service; PRIVILEGED_PORT=no
LISTEN=yes; if [ "$MODE" = 4 ]; then LISTEN=no; fi
if [ "$DEFERRED" = 1 ]; then
    ADMIN_VIA_PAIR=yes
    write_unit
    cp "$UNIT" "$BASE/initial-unit"
fi
trap cleanup 0
trap 'exit 130' HUP INT TERM
pair_installed
if [ "$DEFERRED" = 1 ]; then summary; fi
'''
        env = dict(os.environ, BASE=str(base), MODE=str(mode), PUBLIC=public, RESULT=str(result), RETRY=str(int(retry)), FLAVOR=flavor,
                   INTERRUPT=str(int(interrupt)), NPULSE_MIRROR=mirror, NPULSE_INSECURE=insecure, DEFERRED=str(int(deferred)))
        output = subprocess.run([shell, "-c", script], env=env, text=True, capture_output=True, timeout=5)
        captured = base / "captured.conf"
        assert not work.exists(), "pairing temporary files leaked: " + output.stderr
        return output, config.read_text(), captured.read_text() if captured.exists() else "", (base / "trace").read_text().splitlines()
    output, config, captured, trace = run(public="A" * 64)
    assert output.returncode == 0, output.stderr
    assert "listen=[2001:db8::1]:9527" in captured and "relay_upstream=" not in captured
    assert "admin_keys=" + "b" * 64 + "," + "a" * 64 in config
    assert trace[0] == "stop" and trace[-2:] == ["reload", "start"] and trace[1].startswith("root-unit:")
    output, config, captured, trace = run(mode=4, retry=True)
    assert output.returncode == 0 and "中转密码错误或无法连接" in output.stdout
    assert "relay_upstream=new.example:9020" in config and "token=new-token" in config
    assert "group_secret=fixture-group" in config and "listen=" not in captured and "secret=" not in captured.split("group_secret=")[0]
    assert trace == ["stop", "start"]
    for public, result, status in [("", 0, 0), ("a" * 64, 1, 0), ("invalid", 0, 1)]:
        output, config, captured, trace = run(public=public, result=result)
        assert output.returncode == status and trace == ["stop", "start"], (output, trace)
        assert "admin_keys=" + "b" * 64 + "\n" in config
        assert "fixture-secret" not in output.stdout and "fixture-group" not in output.stdout and "old-token" not in output.stdout
    for mode in (1, 4):
        for public, result, interrupt, status in [("A" * 64, 0, False, 0), ("", 0, False, 0), ("a" * 64, 1, False, 0), ("invalid", 0, False, 1), ("", 0, True, 130)]:
            output, config, captured, trace = run(mode=mode, public=public, result=result, interrupt=interrupt, deferred=True)
            assert output.returncode == status, output.stderr
            assert "DynamicUser=yes" in (base / "initial-unit").read_text()
            unit = (base / "npulse.service").read_text()
            if public and result == 0 and status == 0:
                assert "admin_keys=" + "a" * 64 in config and "User=root" in unit and "DynamicUser=yes" not in unit
                assert trace == ["stop", "reload", "start"]
            else:
                assert "admin_keys=" not in config and "DynamicUser=yes" in unit and "User=root" not in unit
                assert trace == ["stop", "start"] and "管理尚未启用" in output.stdout + output.stderr and "sh install.sh pair" in output.stdout + output.stderr
    mirror = base / "mirror"; mirror.mkdir()
    full = mirror / "npulse-linux-mipsel"; full.write_bytes(binary.read_bytes())
    sums = mirror / "SHA256SUMS"
    sums.write_text(hashlib.sha256(full.read_bytes()).hexdigest() + "  npulse-linux-mipsel\n")
    binary.write_text("#!/bin/sh\nexit 97\n")
    installed = binary.read_bytes()
    class Handler(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=str(mirror)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}"
    try:
        for mode, public, result, interrupt in [(1, "a" * 64, 0, False), (4, "", 0, False), (1, "", 1, False), (1, "", 0, True)]:
            output, config, captured, trace = run(mode=mode, public=public, result=result, interrupt=interrupt, flavor="lite", mirror=url)
            assert output.returncode == (130 if interrupt else 0), output.stderr
            assert "lite 版不支持管理" in output.stdout
            assert trace == ["stop", "start"] and binary.read_bytes() == installed
            assert (base / "executed").read_text().strip() == str(base / "work/binary")
            assert config == "listen=0.0.0.0:9527\nsecret=fixture-secret\nrelay_upstream=old.example:9010\ntoken=old-token\ngroup_secret=fixture-group\nadmin_keys=" + "b" * 64 + "\n"
        for insecure, checksum in [("0", hashlib.sha256(full.read_bytes()).hexdigest()), ("1", "0" * 64)]:
            sums.write_text(checksum + "  npulse-linux-mipsel\n")
            output, config, captured, trace = run(flavor="lite", mirror=url, insecure=insecure)
            assert output.returncode != 0 and not captured and trace == ["stop", "start"]
            assert not (base / "executed").exists() and binary.read_bytes() == installed
    finally:
        server.shutdown(); server.server_close()
print("PASS installer pair lifecycle: direct IPv6/relay-only temporary config; stop/pair/root-admin append/reload/restart; relay password exit-3 retry preserves local group; empty/reject/invalid-key paths restore service and preserve keys")
print("PASS deferred direct/relay admin: initial DynamicUser with no admin_keys; authorized key writes allowlist and root unit; phone/root refusal or pairing failure preserves DynamicUser, no admin_keys, and later-pair guidance")
print("PASS lite pairing via same-arch SHA256-verified temporary full: installed lite/config unchanged, admin key ignored, success/rejection/Ctrl-C cleanup restores service; insecure mirror and corrupt checksum rejected")
