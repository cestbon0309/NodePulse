#!/usr/bin/env python3
"""Generate an unattended deploy file from a local release directory and run it in DRY_RUN."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
shell = sys.argv[1:] or ["/bin/dash"]
with tempfile.TemporaryDirectory(prefix="mkdeploy-", dir=root / "probe/dist") as directory:
    base = Path(directory); mirror = base / "mirror"; mirror.mkdir()
    binary = bytes(range(256)) * 40 + b"\n\n__NPULSE_BINARY__\nNPULSE_INSTALLER_END\n\x00tail"
    files = {"npulse-linux-mips": binary, "npulse-linux-mips-lite": binary[::-1],
             "install.sh": (root / "install.sh").read_bytes(), "VERSION": b"v9.9.9\n"}
    for name, data in files.items(): (mirror / name).write_bytes(data)
    (mirror / "SHA256SUMS").write_text("".join(f"{hashlib.sha256(d).hexdigest()}  {n}\n" for n, d in files.items()))
    env = {k: v for k, v in os.environ.items() if not k.startswith("NPULSE_")}
    env.update(NPULSE_MIRROR=str(mirror), NPULSE_LANG="en")
    def generate(*args, ok=True, stdin=subprocess.DEVNULL):
        result = subprocess.run([*shell, str(root / "mkdeploy.sh"), *args], env=env, cwd=base, text=True,
                                capture_output=True, timeout=30, stdin=stdin)
        assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
        return result
    secret = ["--relay", "relay.example.com:9000", "--token", "tok $en\"`x", "--group", "group\\key$(id)"]
    generate(*secret, "--arch", "mips", "--interval", "1", "--admin-keys", "AB" * 32)
    output = base / "npulse-deploy-mips.sh"
    assert output.stat().st_mode & 0o777 == 0o700
    assert output.read_bytes().endswith(b"__NPULSE_BINARY__\n" + binary)
    def deploy(target, *args, ok=True):
        result = subprocess.run([*shell, str(output), *args], env=dict(env, DESTDIR=str(target), DRY_RUN="1", NPULSE_INIT="procd",
                                TMPDIR=str(base), NPULSE_MIRROR="https://invalid.invalid"), text=True,
                                capture_output=True, timeout=30, stdin=subprocess.DEVNULL)
        assert (result.returncode == 0) == ok, (result.stdout, result.stderr)
        return result
    target = base / "target"; target.mkdir()
    result = deploy(target)
    assert "tok $en" not in result.stdout + result.stderr, "deploy output leaked a secret"
    config = dict(line.split("=", 1) for line in (target / "etc/npulse/npulse.conf").read_text().splitlines())
    assert config["relay_upstream"] == "relay.example.com:9000" and config["token"] == "tok $en\"`x"
    assert config["group_secret"] == "group\\key$(id)" and config["interval"] == "1" and config["admin_keys"] == "ab" * 32
    assert "listen" not in config and (target / "usr/bin/npulse").read_bytes() == binary
    state = (target / "etc/npulse/install.state").read_text()
    assert "ctl=1\n" in state and "version=v9.9.9\n" in state and "flavor=full\n" in state
    assert not list(base.glob("npulse-deploy.*")) and not list(base.glob("npulse-install.*")), "temporary files left behind"
    (target / "etc/npulse/npulse.conf").write_text("sentinel\n")
    assert "already installed" in deploy(target).stdout
    assert (target / "etc/npulse/npulse.conf").read_text() == "sentinel\n"
    deploy(target, "--force")
    assert "relay_upstream=relay.example.com:9000" in (target / "etc/npulse/npulse.conf").read_text()
    deploy(target, "--bogus", ok=False)
    truncated = base / "truncated.sh"; truncated.write_bytes(output.read_bytes()[:-100]); output = truncated
    broken = base / "broken"; broken.mkdir(); deploy(broken, ok=False)
    assert not (broken / "usr/bin/npulse").exists(), "installed a corrupted payload"
    generate(*secret, "--arch", "mips", "--lite", "-o", "lite.sh")
    output = base / "lite.sh"; lite = base / "lite"; lite.mkdir(); deploy(lite)
    assert (lite / "usr/bin/npulse").read_bytes() == binary[::-1]
    generate(*secret, "--arch", "sparc", ok=False)
    generate(*secret[:4], "--arch", "mips", ok=False)
    generate("--relay", "relay.example.com", *secret[2:], "--arch", "mips", ok=False)
    generate("--relay", "r:1", "--token", "it's", "--group", "g", "--arch", "mips", ok=False)
    generate(*secret, "--arch", "mips", "--lite", "--admin-keys", "ab" * 32, ok=False)
    (mirror / "npulse-linux-mips").write_bytes(binary + b"x")
    generate(*secret, "--arch", "mips", ok=False)
    print(f"PASS unattended deploy generation, dry-run install, rerun/--force, truncation and tamper rejection ({shell[0]})")
