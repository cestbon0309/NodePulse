#!/usr/bin/env python3
"""Offline checks of actual installer functions against ip/ifconfig/firewall fixtures."""
import os
from itertools import permutations
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / "install.sh").read_text()
shell = sys.argv[1:] or ["/bin/dash"]


def function(name):
    return re.search(r"^" + name + r"\(\) \{.*?^\}", source, re.M | re.S).group(0)


with tempfile.TemporaryDirectory(prefix="npulse-interfaces-") as directory:
    tools = Path(directory)
    for name in ("awk", "grep"):
        (tools / name).symlink_to(shutil.which(name))
    def tool(name, body):
        path = tools / name
        path.write_text("#!/bin/sh\n" + body + "\n"); path.chmod(0o755)
    tool("ip", '[ "${IP_FAIL:-0}" = 0 ] || exit 1\nprintf "%s\\n" "$ADDRESSES"')
    tool("ifconfig", 'printf "%s\\n" "$IFCONFIG"')
    def run(addresses="", choice="", expression="public_addresses", ok=True, **settings):
        env = dict(os.environ, PATH=str(tools), ADDRESSES=addresses, IFCONFIG="", CHOICE=choice)
        env.update(settings)
        script = '\n'.join(function(n) for n in ("public_addresses", "select_bind", "bind_endpoint", "firewall_plan", "open_firewall"))
        script += '\nfail() { printf "%s\\n" "$*" >&2; exit 1; }\nask() { printf "%s\\n" "$1" >&2; ANSWER=${CHOICE:-$2}; }\n'
        script += 'BIND=; PORT=9527; MODE=1; LISTEN=yes; YES=0; INIT=${TEST_INIT:-systemd}\n' + expression
        result = subprocess.run([*shell, "-c", script], env=env, text=True, capture_output=True, timeout=5)
        assert (result.returncode == 0) == ok, result.stderr
        return result
    one = "2: eth0 inet 8.8.4.4/24 scope global eth0"
    selected = 'select_bind; printf "%s|%s|%s|" "$MODE" "$LISTEN" "$BIND"; bind_endpoint'
    result = run(one, expression=selected)
    assert result.stdout == "1|yes|8.8.4.4|8.8.4.4:9527"
    assert "检测到公网地址 8.8.4.4（网卡 eth0）" in result.stderr
    result = run(one + "\n3: eth1 inet6 2001:db8::7/64 scope global", "2", selected)
    assert result.stdout.endswith("2001:db8::7|[2001:db8::7]:9527")
    assert run(one + "\n3: eth1 inet 9.9.9.9/24", "0", selected).stdout.endswith("0.0.0.0|0.0.0.0:9527")
    run(one + "\n3: eth1 inet 9.9.9.9/24", "4", selected, ok=False)
    excluded = "10.1.2.3 172.16.0.1 172.31.255.254 192.168.5.2 100.64.0.1 100.127.255.254 127.1.2.3 169.254.2.3 0.1.2.3 224.0.0.1 255.255.255.255 ::1 :: fe80::1 febf::1 fc00::1 fdff::1 ff02::1".split()
    for address in excluded:
        assert not run(f"2: eth0 {'inet6' if ':' in address else 'inet'} {address}/64").stdout, address
    for address in "172.15.0.1 172.32.0.1 100.63.255.254 100.128.0.1 2001:db8::1".split():
        assert run(f"2: eth0 {'inet6' if ':' in address else 'inet'} {address}/24").stdout.strip() == address + " eth0", address
    assert run("2: eth0 inet 100.90.0.2/24", expression=selected).stdout.endswith("4|no||0.0.0.0:9527")
    assert run("", "1", selected).stdout.endswith("0.0.0.0|0.0.0.0:9527")
    fixture = "eth0 Link encap:Ethernet\n          inet addr:8.8.8.8 Bcast:8.8.8.255\nen0: flags=8863\n\tinet6 2001:db8::8 prefixlen 64\n"
    assert run(IP_FAIL="1", IFCONFIG=fixture).stdout.splitlines() == ["8.8.8.8 eth0", "2001:db8::8 en0"]
    print("PASS interface fixtures: single/multiple/none, IPv4 exclusions and CGNAT boundaries, IPv6 public/link-local/ULA/multicast, ip and BusyBox/BSD ifconfig; IPv6 binding; NAT defaults to relay")
    for name, body, expected in [
        ("iptables", "exit 0", "iptables -I INPUT -p tcp --dport 9527 -j ACCEPT"),
        ("nft", "exit 0", "nft add rule inet npulse input tcp dport 9527 accept"),
        ("firewall-cmd", "printf 'running\\n'", "firewall-cmd --permanent --add-port=9527/tcp"),
        ("ufw", "printf 'Status: active\\n'", "ufw allow 9527/tcp")]:
        tool(name, body)
        assert expected in run(expression="firewall_plan").stdout
    (tools / "ufw").unlink(); (tools / "firewall-cmd").unlink()
    tool("nft", "printf 'table inet filter {\\n chain input {\\n type filter hook input priority 0; policy drop;\\n }\\n}\\n'")
    assert "nft insert rule inet filter input tcp dport 9527 accept" in run(expression="firewall_plan").stdout
    def rules(family, table=None, chains=("input",), kind="filter", hook="input"):
        return f"table {family} {table or 'filter_' + family} {{\n" + "".join(f" chain {chain} {{\n type {kind} hook {hook} priority 0; policy drop;\n }}\n" for chain in chains) + "}\n"
    calls = tools / "nft-calls"
    tool("nft", 'if [ "$1" = list ]; then printf "%s\\n" "$RULESET"; else printf "%s\\n" "$*" >> "$NFT_CALLS"; if [ "$*" = "${NFT_FAIL:-}" ]; then exit 1; fi; fi')
    def check_nft(bind, ruleset, expected, **settings):
        calls.write_text("")
        plan = run(expression=f'BIND={bind}; DRY_RUN=0; OPEN_FIREWALL=yes; open_firewall', RULESET=ruleset, NFT_CALLS=str(calls), **settings).stdout
        assert calls.read_text().splitlines() == expected, (bind, plan)
        assert all(command in plan.replace("'", "") for command in expected)
    create = ["add table inet npulse", "add chain inet npulse input { type filter hook input priority 0; policy accept; }", "add rule inet npulse input tcp dport 9527 accept"]
    for bind, ruleset, expected in [
        ("8.8.4.4", rules("ip6") + rules("ip"), ["insert rule ip filter_ip input tcp dport 9527 accept"]),
        ("2001:db8::7", rules("ip") + rules("ip6"), ["insert rule ip6 filter_ip6 input tcp dport 9527 accept"]),
        ("8.8.4.4", rules("ip6"), create),
        ("2001:db8::7", rules("ip"), create),
        *[(bind, "", create) for bind in ("", "0.0.0.0", "::", "8.8.4.4", "2001:db8::7")],
        ("::", rules("ip"), ["insert rule ip filter_ip input tcp dport 9527 accept"]),
        ("0.0.0.0", rules("ip6"), ["insert rule ip6 filter_ip6 input tcp dport 9527 accept"]),
        ("8.8.4.4", rules("inet", chains=("input", "second")) + rules("inet", table="extra", chains=("guard",)) + rules("ip", kind="nat") + rules("ip", hook="forward"), [f"insert rule {family} {table} {chain} tcp dport 9527 accept" for family, table, chain in [("inet", "filter_inet", "input"), ("inet", "filter_inet", "second"), ("inet", "extra", "guard"), ("ip", "filter_ip", "input")]]),
    ]:
        check_nft(bind, ruleset, expected)
    for families in [("inet", "ip"), ("inet", "ip6"), ("inet", "ip", "ip6"), ("ip", "ip6")]:
        for order in permutations(families):
            for bind in ("8.8.4.4", "2001:db8::7", "0.0.0.0", "::", ""):
                covering = ("inet", "ip6" if ":" in bind else "ip") if bind not in ("", "0.0.0.0", "::") else families
                expected = [f"insert rule {family} filter_{family} input tcp dport 9527 accept" for family in order if family in covering]
                check_nft(bind, "".join(rules(family) for family in order), expected)
    failed = "insert rule inet filter_inet input tcp dport 9527 accept"
    check_nft("8.8.4.4", rules("inet") + rules("ip"), [failed], NFT_FAIL=failed, ok=False)
    print("PASS nft bind-family fixtures: every covering inet/ip/ip6 input base chain in every mixed-family order; multiple chains/tables and NAT input hooks; no creation unless none cover; execution failure stops; printed/executed commands agree")
    tool("uci", "exit 0")
    plan = run(expression="firewall_plan", TEST_INIT="procd").stdout
    assert "uci add firewall rule" in plan and 'dest_port=9527' in plan and "/etc/init.d/firewall reload" in plan
    print("PASS firewall fixtures: active ufw > running firewalld > OpenWrt uci > nft > iptables; existing nft input chain; exact TCP allow commands (none executed)")
print("ALL INTERFACE/FIREWALL CHECKS PASSED (" + " ".join(shell) + ")")
