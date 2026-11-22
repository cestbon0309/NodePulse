#!/usr/bin/env python3
"""Published lite builds omit pairing/QR and retain a strict 200KB budget."""
from pathlib import Path
import subprocess
import sys

binary = sys.argv[1]
for args in (["-P"], ["-P", "-l", "127.0.0.1:9527", "-k", "fixture"]):
    result = subprocess.run([binary, *args], capture_output=True, text=True, timeout=3)
    assert result.returncode == 2 and not result.stdout
    assert "PAIR=0" in result.stderr and "install.sh pair" in result.stderr
dist = Path(__file__).resolve().parents[1] / "dist"
for arch in "x86_64 i386 aarch64 armv7 armv7-soft mips mipsel".split():
    data = (dist / f"npulse-linux-{arch}-lite").read_bytes()
    assert 0 < len(data) < 200000, (arch, len(data))
    assert b"npulse-pair-commit" not in data and b"nodepulse://pair" not in data, arch
print("PASS default lite -P rejects with installer guidance; all seven lite artifacts exclude pairing/QR and stay below 200000 bytes")
