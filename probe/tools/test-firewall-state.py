#!/usr/bin/env python3
"""Exercise recorded ownership and removal using actual shell functions and mock managers."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "install.sh").read_text()
functions = "\n".join(re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group()
                      for name in ("open_firewall", "record_firewall", "remove_firewall"))
with tempfile.TemporaryDirectory(prefix="firewall-", dir=root / "probe/dist") as directory:
    base = Path(directory)
    (base / "etc/npulse").mkdir(parents=True)
    state = base / "rules.json"; trace = base / "trace"
    mock = base / "manager"
    mock.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
s=Path(os.environ["MOCK_STATE"]); d=json.loads(s.read_text()); args=sys.argv[1:]; name=Path(sys.argv[0]).name
with open(os.environ["MOCK_TRACE"],"a") as f: f.write(name+" "+" ".join(args)+"\\n")
active=d.get("active",False); rc=0
if name=="ufw":
    if args[:2]==["show","added"]:
        if d.get("logged"): print('ufw allow log 9527/tcp')
        elif active: print('ufw allow 9527/tcp comment '+d.get("tag","foreign"))
    elif "delete" in args: d["active"]=False
    else: d.update(active=True,tag=args[-1])
elif name=="firewall-cmd":
    if "--get-default-zone" in args: print("public")
    else:
        key="perm" if "--permanent" in args else "rt"
        d.setdefault("perm",active); d.setdefault("rt",active)
        if any(x.startswith("--query-port") for x in args): rc=0 if d[key] else 1
        elif any(x.startswith("--add-port") for x in args): d[key]=True
        elif any(x.startswith("--remove-port") for x in args): d[key]=False
        d["active"]=d["perm"] or d["rt"]
elif name=="nft":
    if "list" in args:
        if active: print('tcp dport 9527 accept comment "'+d["tag"]+'" # handle 7')
    elif "delete" in args: assert args[-1]=="7"; d["active"]=False
    else: d.update(active=True,tag=args[-1].strip('"'))
elif name in ("iptables","ip6tables"):
    if "-C" in args: rc=0 if active else 1
    elif "-D" in args: d["active"]=False
    else: d.update(active=True,tag=args[-3])
elif name=="uci":
    if args[0]=="set" and ".name=" in args[1]: d.update(active=True,tag=args[1].split("=",1)[1])
    elif "get" in args:
        if active: print(d["tag"] if args[-1].endswith(".name") else "rule")
        else: rc=1
    elif args[0]=="delete": d["active"]=False
s.write_text(json.dumps(d)); sys.exit(rc)
''')
    mock.chmod(0o755)
    for name in ("ufw", "firewall-cmd", "nft", "iptables", "ip6tables", "uci"):
        (base / name).symlink_to(mock)
    env = dict(os.environ, PATH=str(base) + ":" + os.environ["PATH"], DESTDIR=str(base),
               MOCK_STATE=str(state), MOCK_TRACE=str(trace))
    shell = sys.argv[1:] or ["/bin/dash"]
    setup = '''
set -eu
fail() { echo "$*" >&2; exit 1; }
say() { :; }
random() { echo fixture; }
firewall_reload() { :; }
firewall_plan() { FW=$BACKEND; NFT_CHAIN='inet filter input'; }
PORT=9527; BIND=0.0.0.0; OPEN_FIREWALL=yes; DRY_RUN=0
'''
    records = base / "etc/npulse/firewall.state"
    def run(backend, command):
        return subprocess.run([*shell, "-c", functions + setup + command], env=dict(env, BACKEND=backend),
                              text=True, capture_output=True, timeout=10)
    for backend in ("ufw", "firewalld", "nft", "iptables", "uci"):
        state.write_text('{}'); trace.write_text("")
        result = run(backend, "open_firewall")
        assert result.returncode == 0, (backend, result.stderr)
        assert records.exists() and records.stat().st_mode & 0o777 == 0o600
        assert records.read_text().startswith(backend + "|")
        assert json.loads(state.read_text())["active"]
        result = run(backend, "remove_firewall")
        assert result.returncode == 0, (backend, result.stderr)
        assert not json.loads(state.read_text())["active"] and not records.exists()
        assert run(backend, "remove_firewall").returncode == 0
        if backend in ("ufw", "firewalld"):
            state.write_text('{"active":true,"tag":"foreign"}')
            assert run(backend, "open_firewall").returncode == 0
            assert not records.exists() and json.loads(state.read_text())["active"]
        if backend in ("ufw", "nft", "uci"):
            state.write_text('{}')
            assert run(backend, "open_firewall").returncode == 0
            state.write_text('{"active":true,"tag":"foreign"}')
            assert run(backend, "remove_firewall").returncode == 0
            assert json.loads(state.read_text())["active"], "removed somebody else's rule"
    state.write_text('{"logged":true,"active":true}'); trace.write_text("")
    assert run("ufw", "open_firewall").returncode == 0
    assert not records.exists() and "comment" not in trace.read_text(), "replaced a preexisting logged ufw rule"
    state.write_text('{"perm":true,"rt":false}'); trace.write_text("")
    assert run("firewalld", "open_firewall").returncode == 0
    assert json.loads(state.read_text())["rt"] and not records.exists(), "staged permanent port not applied at runtime"
    state.write_text('{"perm":false,"rt":true}'); trace.write_text("")
    assert run("firewalld", "open_firewall").returncode == 0 and records.read_text() == "firewalld|public|9527|0\n"
    assert run("firewalld", "remove_firewall").returncode == 0
    final = json.loads(state.read_text())
    assert not final["perm"] and final["rt"], "removed a preexisting runtime allowance"
    state.write_text('{}'); trace.write_text("")
    assert run("firewalld", "open_firewall; remove_firewall").returncode == 0
    assert not json.loads(state.read_text())["active"] and "--reload" not in trace.read_text()
    state.write_text('{}')
    assert run("iptables", "BIND=::; open_firewall").returncode == 0
    assert records.read_text().startswith("ip6tables|")
    assert run("iptables", "remove_firewall").returncode == 0
    records.write_text("unknown|unsafe\n")
    assert run("nft", "remove_firewall").returncode != 0 and records.exists()
    assert run("nft", "DRY_RUN=1; remove_firewall").returncode == 0 and records.exists()
    print("PASS recorded ufw/firewalld/nft/iptables/ip6tables/UCI add/remove, missing records, foreign ownership, preexisting rules, strict metadata permissions and dry-run")
