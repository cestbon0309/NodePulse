#!/usr/bin/env python3
"""Service-safe installer pair lifecycle using a fake probe; no privileged actions."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "install.sh").read_text()
shell = sys.argv[1] if len(sys.argv) > 1 else "/bin/dash"
functions = "\n".join(re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)
                      for name in ("pair_installed", "bind_endpoint", "cleanup", "safe_value", "port", "fail"))

with tempfile.TemporaryDirectory(prefix="npulse-pair-installer-") as directory:
    base = Path(directory)
    binary = base / "fake-probe"
    binary.write_text('''#!/bin/sh
set -eu
[ "$1" = -P ] && [ "$2" = -c ]
cp "$3" "$BASE/captured.conf"
if [ "${RETRY:-0}" = 1 ] && [ ! -f "$BASE/retried" ]; then touch "$BASE/retried"; exit 3; fi
if [ -n "${PUBLIC:-}" ]; then printf 'admin_pk=%s\\n' "$PUBLIC"; fi
exit "${RESULT:-0}"
''')
    binary.chmod(0o755)
    def run(mode=1, public="", result=0, retry=False):
        work = base / "work"; work.mkdir(exist_ok=True)
        config = base / "npulse.conf"
        config.write_text("listen=0.0.0.0:9527\nsecret=fixture-secret\nrelay_upstream=old.example:9010\ntoken=old-token\ngroup_secret=fixture-group\nadmin_keys=" + "b" * 64 + "\n")
        for name in ("trace", "retried"):
            path = base / name
            if path.exists(): path.unlink()
        script = "set -eu\numask 077\n" + functions + '''
service() { printf '%s\n' "$1" >> "$BASE/trace"; }
write_unit() { printf 'root-unit:%s\n' "$ADMIN_KEYS" >> "$BASE/trace"; }
ask() { case "$1" in 重新*) ANSWER=y ;; *) ANSWER=new.example:9020 ;; esac; }
credentials() { ANSWER=new-token; }
WORK=$BASE/work; CONFIG=$BASE/npulse.conf; BIN=$BASE/fake-probe; DESTDIR=
DRY_RUN=0; YES=0; FLAVOR=full; NAME=fixture; BIND=2001:db8::1; PORT=9527
UPSTREAM=old.example:9010; TOKEN=old-token; GROUP=fixture-group; SECRET=fixture-secret
PAIR_STOPPED=0; ECHO_OFF=0; ADMIN_KEYS=
trap cleanup 0
pair_installed
'''
        env = dict(os.environ, BASE=str(base), MODE=str(mode), PUBLIC=public, RESULT=str(result), RETRY=str(int(retry)))
        output = subprocess.run([shell, "-c", script], env=env, text=True, capture_output=True, timeout=5)
        return output, config.read_text(), (base / "captured.conf").read_text(), (base / "trace").read_text().splitlines()
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
print("PASS installer pair lifecycle: direct IPv6/relay-only temporary config; stop/pair/root-admin append/reload/restart; relay password exit-3 retry preserves local group; empty/reject/invalid-key paths restore service and preserve keys")
