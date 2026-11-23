#!/usr/bin/env python3
"""Native dispatch and real ephemeral download/verification, without root operations."""
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading

root = Path(__file__).resolve().parents[2]
subprocess.run([sys.executable, str(root / "probe/tools/embed-installer.py")],
               env=dict(os.environ, NPULSE_VERSION="v9.8.7"), check=True)
with tempfile.TemporaryDirectory(prefix="ctl-", dir=root / "probe/dist") as directory:
    base = Path(directory)
    state = base / "install.state"
    captured = base / "captured"
    tools = base / "tools"; tools.mkdir()
    work = base / "work"; work.mkdir()
    mirror = base / "mirror"; mirror.mkdir()
    payload = (root / "install.sh").read_bytes()
    (mirror / "install.sh").write_bytes(payload)
    checksum = hashlib.sha256(payload).hexdigest() + "  install.sh\n"
    (mirror / "SHA256SUMS").write_text(checksum)
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *_): pass
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=str(mirror)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(os.environ, NPULSE_MIRROR=f"http://127.0.0.1:{server.server_port}", NPULSE_INSECURE="1",
               CAPTURE=str(captured), PATH=str(tools), TMPDIR=str(work))
    shell = shutil.which("dash") or "/bin/sh"
    for name in "awk cat chmod grep mktemp rm tr curl wget sha256sum shasum openssl".split():
        path = shutil.which(name)
        if path: (tools / name).symlink_to(path)
    wrapper = tools / "sh"
    wrapper.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
if sys.argv[2].startswith("#!/bin/sh"):
    Path(os.environ["CAPTURE"]).write_bytes(sys.argv[2].encode())
    print(json.dumps([sys.argv[3:], sys.stdin.read(), os.environ["NPULSE_CURRENT_VERSION"]]))
else:
    os.execv(SHELL, [SHELL, *sys.argv[1:]])
'''.replace("SHELL", repr(shell)))
    wrapper.chmod(0o755)
    manager = base / "init"
    manager.write_text('#!/bin/sh\nprintf "%s\\n" "$*"\nexit 17\n'); manager.chmod(0o755)
    (tools / "systemctl").symlink_to(manager)
    source = base / "ctl.c"
    source.write_text('#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#include "ctl.h"\nint main(int n,char **v) { int r=ctl(n,v); return r<0 ? 42 : r; }\n')
    def run(binary, *args, **changes):
        return subprocess.run([str(binary), *args], env=dict(env, **changes), input="terminal-input\n",
                              text=True, capture_output=True, timeout=15)
    try:
        for admin in (1, 0):
            binary = base / f"ctl-{admin}"
            subprocess.run([os.environ.get("CC", "cc"), "-std=gnu99", "-Wall", "-Wextra", "-Werror",
                            f"-DADMIN={admin}", f'-DNPULSE_CTL_STATE="{state}"', f'-DNPULSE_CTL_INIT="{manager}"',
                            f'-DNPULSE_CTL_SHELL="{wrapper}"', f'-DNPULSE_CTL_SYSTEMD="{manager}"',
                            "-I" + str(root / "probe"), str(source), "-o", str(binary)], check=True)
            assert run(binary, "version").stdout.startswith("v9.8.7 " + ("full" if admin else "lite") + " ")
            assert run(binary, "help").returncode == 0
            assert run(binary, "-h").returncode == 42 and run(binary, "unknown").returncode == 42
            for bad in ("", "init=systemd\n", "ctl=1\ninit=unknown\n"):
                state.write_text(bad)
                result = run(binary, "upgrade")
                assert result.returncode == 2 and "install.sh upgrade once" in result.stderr
            for init in ("systemd", "procd"):
                state.write_text(f"ctl=1\ninit={init}\n")
                for command in ("status", "restart"):
                    result = run(binary, command)
                    assert result.returncode == 17 and command in result.stdout, result
                    result = run(binary, command, "--fixture")
                    expected = f"{command} " + ("npulse " if init == "systemd" else "") + "--fixture\n"
                    assert result.returncode == 17 and result.stdout == expected, result
            for command, options in (("upgrade", ["--force"]), ("uninstall", ["--purge", "--yes"]), ("pair", ["--lang", "en"])):
                result = run(binary, command, *options)
                assert result.returncode == 0, result.stderr
                assert captured.read_bytes() == payload, "embedded/downloaded script differs from install.sh"
                args, stdin, version = json.loads(result.stdout)
                assert args == ["npulse", command, *options] and stdin == "terminal-input\n" and version == "v9.8.7"
                assert not list(work.iterdir()), "temporary installer leaked"
            if not admin:
                captured.unlink()
                (mirror / "SHA256SUMS").write_text("0" * 64 + "  install.sh\n")
                result = run(binary, "upgrade")
                assert result.returncode and "SHA256 mismatch" in result.stderr and not captured.exists()
                assert not list(work.iterdir())
                (mirror / "SHA256SUMS").write_text(checksum)
                result = run(binary, "upgrade", NPULSE_MIRROR=env["NPULSE_MIRROR"] + "/missing")
                assert result.returncode and "Installer download failed" in result.stderr and not list(work.iterdir())
                (tools / "curl").rename(tools / "curl.saved")
                (tools / "curl").write_text('#!/bin/sh\nkill -TERM "$PPID"\nexit 143\n')
                (tools / "curl").chmod(0o755)
                result = run(binary, "pair")
                assert result.returncode and not list(work.iterdir()), "interruption leaked temporary files"
                (tools / "curl").unlink(); (tools / "curl.saved").rename(tools / "curl")
                hidden = []
                for name in ("curl", "wget"):
                    path = tools / name
                    if path.exists(): path.rename(tools / (name + ".hidden")); hidden.append(name)
                result = run(binary, "pair")
                assert result.returncode and "curl or wget" in result.stderr and not list(work.iterdir())
                for name in hidden: (tools / (name + ".hidden")).rename(tools / name)
                if (tools / "curl").exists() and (tools / "wget").exists():
                    (tools / "curl").rename(tools / "curl.hidden")
                    assert run(binary, "pair").returncode == 0
                    (tools / "curl.hidden").rename(tools / "curl")
                for name in ("sha256sum", "shasum", "openssl"):
                    path = tools / name
                    if path.exists():
                        assert run(binary, "pair").returncode == 0, name + " fallback failed"
                        path.unlink()
                result = run(binary, "upgrade")
                assert result.returncode and "sha256sum, shasum or openssl" in result.stderr
                assert not list(work.iterdir())
        print("PASS native full/lite version/help, dispatch fallback, legacy-state hint, offline systemd/procd status/restart and exit propagation")
        print("PASS embedded installer byte equality; upgrade/pair/uninstall argv and terminal stdin preserved")
        print("PASS lite real HTTP mirror + SHA256 verification, tamper rejection, curl/wget fallback, missing tools and temporary-file cleanup")
    finally:
        server.shutdown(); server.server_close()
