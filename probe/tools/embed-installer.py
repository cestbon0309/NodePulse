#!/usr/bin/env python3
"""Generate management payloads from their release sources."""
import os
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
version = os.environ.get("NPULSE_VERSION", "dev")
if not re.fullmatch(r"[A-Za-z0-9._-]+", version):
    raise SystemExit("Invalid NPULSE_VERSION")


def literal(data):
    return '"' + ''.join(chr(c) if 32 <= c < 127 and c not in (34, 63, 92)
                         else '\\%03o' % c for c in data) + '"'


script = (root / "install.sh").read_bytes()
if len(script) >= 120000:
    raise SystemExit("Installer exceeds portable sh -c argument budget")
output = root / "probe/dist/installer.h"
output.parent.mkdir(exist_ok=True)
output.write_text('#define NPULSE_VERSION ' + literal(version.encode()) + '\n#if ADMIN\n'
                  'static const char ctl_script[] = ' + literal(script) + ';\n#else\n'
                  'static const char ctl_script[] = ' + literal((root / "probe/ctl-bootstrap.sh").read_bytes())
                  + ';\n#endif\n')
