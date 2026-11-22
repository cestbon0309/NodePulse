#!/usr/bin/env python3
"""Offline installer lifecycle checks; uses actual built assets, never executes them."""
import functools
import hashlib
import http.server
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / "probe/dist/installer-tests"
LOGS.mkdir(exist_ok=True)
OUTPUT = Path(tempfile.mkdtemp(prefix="run-", dir=LOGS))
MIRROR = OUTPUT / "mirror"
MIRROR.mkdir(exist_ok=True)
ARCHES = "x86_64 i386 aarch64 armv7 armv7-soft mips mipsel".split()
for arch in ARCHES:
    for suffix in ("", "-lite"):
        name = f"npulse-linux-{arch}{suffix}"
        shutil.copyfile(ROOT / "probe/dist" / name, MIRROR / name)
shutil.copyfile(ROOT / "install.sh", MIRROR / "install.sh")
sums = "".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n" for p in sorted(MIRROR.iterdir()) if p.name != "SHA256SUMS")
(MIRROR / "SHA256SUMS").write_text(sums)


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(MIRROR)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
BASE = f"http://127.0.0.1:{server.server_port}"
SHELL = sys.argv[1:] or ["/bin/dash"]
SHELL[0] = shutil.which(SHELL[0]) or sys.exit("Test shell not found")
COUNTER = 0


def new_root():
    global COUNTER
    COUNTER += 1
    path = OUTPUT / f"root-{os.getpid()}-{COUNTER}"
    path.mkdir()
    return path


def run(root, *args, ok=True, **settings):
    env = {k: v for k, v in os.environ.items() if not k.startswith("NPULSE_")}
    env.update(DESTDIR=str(root), DRY_RUN="1", NPULSE_INIT="systemd", NPULSE_ARCH="x86_64", NPULSE_MIRROR=BASE)
    env.update(NPULSE_INSECURE="1")
    env.update(settings)
    result = subprocess.run([*SHELL, str(ROOT / "install.sh"), *args], env=env, text=True, capture_output=True, timeout=30)
    assert (result.returncode == 0) == ok, (args, result.stdout, result.stderr)
    with (OUTPUT / "commands.log").open("a") as log:
        # Only test values are used; do not copy stdout summaries containing generated keys.
        log.write(f"{SHELL!r} {args!r}: exit={result.returncode}\n")
    return result


def config(root):
    path = root / "etc/npulse/npulse.conf"
    assert path.stat().st_mode & 0o777 == 0o600
    return dict(line.split("=", 1) for line in path.read_text().splitlines())


def isolated_tools(exclude=()):
    path = new_root() / "tools"
    path.mkdir()
    for name in "awk cat chmod cp df dirname grep hexdump id mkdir mktemp mv od rm rmdir sha256sum shasum stty tr uname wc wget".split():
        tool = shutil.which(name)
        if tool and name not in exclude:
            (path / name).symlink_to(tool)
    return path


def interactive(root, admin_source=None, pair="n", preset_keys=None, keys_via_env=False,
                mode=1, arch="x86_64", init="systemd", flavor=None, flavor_flag=None, flavor_answer="", public_answer="y"):
    tools = root / "tools"; tools.mkdir()
    firewall = tools / "ufw"
    firewall.write_text('#!/bin/sh\n[ "$1" = status ] || exit 99\nprintf "Status: active\\n"\n')
    firewall.chmod(0o755)
    args = ["--admin-keys", preset_keys] if preset_keys and not keys_via_env else []
    if flavor_flag: args += [flavor_flag]
    command = "cat " + shlex.quote(str(ROOT / "install.sh")) + " | " + shlex.join([*SHELL, "-s", "--", *args])
    if sys.platform == "darwin":
        argv = ["script", "-q", "/dev/null", "/bin/sh", "-c", command]
    else:
        argv = ["script", "-q", "-e", "-c", command, "/dev/null"]
    env = {k: v for k, v in os.environ.items() if not k.startswith("NPULSE_")}
    env.update(DESTDIR=str(root), DRY_RUN="1", NPULSE_INIT="systemd", NPULSE_ARCH="x86_64", NPULSE_MIRROR=BASE, NPULSE_INSECURE="1", NPULSE_BIND="0.0.0.0")
    env.update(NPULSE_MODE=str(mode), NPULSE_ARCH=arch, NPULSE_INIT=init)
    if mode == 1: env["NPULSE_PUBLIC_IP"] = "8.8.4.4"
    if flavor: env["NPULSE_FLAVOR"] = flavor
    if keys_via_env: env["NPULSE_ADMIN_KEYS"] = preset_keys
    env["PATH"] = str(tools) + os.pathsep + env["PATH"]
    prompts, responses = ["模式 [默认"], [""]
    if mode in (2, 3, 4):
        prompts += ["同时作为旧式中继"]
        responses += [""]
    if mode in (1, 5):
        prompts += ["TCP 监听端口"]
        responses += [""]
    if mode == 1:
        prompts += ["这台机器有公网 IP 吗"]
        responses += [public_answer]
        if public_answer == "n":
            prompts += ["切换到共享中继模式 4"]
            responses += [""]
            mode = 4
        else:
            prompts += ["公网 IP（留空确认"]
            responses += [""]
    if mode in (2, 5):
        prompts += ["HTTP 回环端口" if mode == 2 else "开启 HTTP /api/relay"]
        responses += [""]
    if mode in (3, 4):
        prompts += ["上游地址"]
        responses += ["relay.example:9010"]
    if mode != 5:
        prompts += ["节点名称"]
        responses += [""]
    secret = "interactive-secret-MUST-NOT-ECHO"
    prompts += ["输入不回显"]
    responses += [secret]
    if mode == 4:
        prompts += ["组密钥（仅可信组成员持有）"]
        responses += ["interactive-group-secret"]
    if mode != 5:
        prompts += ["root 级控制权"]
        responses += ["yes" if admin_source is not None and not preset_keys else ""]
    manual = admin_source == "2" or (admin_source == "" and bool(preset_keys))
    if admin_source is not None:
        prompts += ["管理公钥来源："]
        responses += [admin_source]
        if manual:
            prompts += ["粘贴 Ed25519 公钥"]
            responses += ["" if preset_keys else "A" * 64]
    prompts += ["构建类型 full/lite"]
    responses += [flavor_answer]
    if mode == 1:
        prompts += ["是否现在执行"]
        responses += ["n"]
    if mode in (1, 4):
        prompts += ["现在与手机配对"]
        responses += [pair]
    proc = subprocess.Popen(argv, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, start_new_session=True)
    transcript, step, deadline = b"", 0, time.monotonic() + 30
    try:
        while time.monotonic() < deadline:
            if select.select([proc.stdout], [], [], 0.2)[0]:
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    break
                transcript += chunk
                if step < len(prompts) and prompts[step].encode() in transcript:
                    proc.stdin.write((responses[step] + "\n").encode()); proc.stdin.flush(); step += 1
            elif proc.poll() is not None:
                break
        assert step == len(prompts), transcript.decode(errors="replace")
        assert proc.wait(timeout=3) == 0, transcript.decode(errors="replace")
        if mode == 1: assert b"ufw allow 9000/tcp" in transcript
        assert config(root)["secret" if mode in (1, 2, 3) else "token"] == secret
        assert transcript.count(secret.encode()) == 1, "secret echoed outside final summary"
        expected_flavor = flavor_answer or (flavor_flag or "").removeprefix("--") or flavor or "full"
        assert f"flavor={expected_flavor}\n" in (root / "etc/npulse/install.state").read_text()
        assert f"[默认 {(flavor_flag or '').removeprefix('--') or flavor or 'full'}]".encode() in transcript
        assert "175–270 KB".encode() in transcript and "120–195 KB".encode() in transcript
        if admin_source is not None:
            unit = (root / "etc/systemd/system/npulse.service").read_text()
            if preset_keys: assert "[默认 2]".encode() in transcript
            if manual:
                assert config(root)["admin_keys"] == (preset_keys.lower() if preset_keys else "a" * 64) and "User=root" in unit
            else:
                assert "粘贴 Ed25519 公钥".encode() not in transcript
                assert "admin_keys" not in config(root) and "DynamicUser=yes" in unit and "User=root" not in unit
                assert b"flavor=full" in (root / "etc/npulse/install.state").read_bytes()
                assert "管理将保持关闭".encode() in transcript and b"sh install.sh pair" in transcript
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGTERM); proc.wait(timeout=5)
        proc.stdin.close(); proc.stdout.close()


try:
    run(new_root(), "--yes", ok=False, NPULSE_INSECURE="0")
    for mode in range(1, 6):
        root = new_root()
        args = ["install", "--yes", "--mode", str(mode), "--upstream", "relay.example.com:9000"]
        if mode in (2, 3, 4):
            args += ["--also-relay"]
        if mode in (2, 5):
            args += ["--http-port", "9001"]
        output = run(root, *args)
        values = config(root)
        unit_path = root / "etc/systemd/system/npulse.service"
        unit = unit_path.read_text()
        assert "DynamicUser=yes" in unit and "LoadCredential=npulse.conf:/etc/npulse/npulse.conf" in unit
        assert "Restart=always" in unit and "NoNewPrivileges=yes" in unit
        assert "npulse.conf" in unit and values.get("secret", "not-a-secret") not in unit
        if mode < 5:
            assert values["listen"] == "0.0.0.0:9000"
        if mode in (2, 5):
            assert values["http"] == "127.0.0.1:9001" and "proxy_http_version 1.1" in output.stdout
        if mode == 3:
            assert values["upstream"] == "relay.example.com:9000"
        if mode == 4:
            assert values["relay_upstream"] == "relay.example.com:9000" and len(values["group_secret"]) == 32
        if mode == 5:
            assert set(values) == {"interval", "token", "relay_listen", "http"}
        for key in ("secret", "token", "group_secret"):
            if key in values:
                assert len(values[key]) == 32 and values[key] not in output.stderr
        before = (root / "etc/npulse/npulse.conf").read_bytes()
        binary = root / "usr/local/bin/npulse"
        assert binary.parent.stat().st_mode & 0o777 == 0o755
        binary.write_bytes(b"old binary")
        run(root, "upgrade", "--yes")
        assert binary.read_bytes() == (MIRROR / "npulse-linux-x86_64").read_bytes()
        assert (root / "etc/npulse/npulse.conf").read_bytes() == before and unit_path.read_text() == unit
        run(root, "status", "--yes")
        run(root, "uninstall", "--yes")
        assert not binary.exists() and not unit_path.exists() and (root / "etc/npulse/npulse.conf").exists()
    print("PASS five modes + supported -l combinations: verified binaries, 0600 config, hardened DynamicUser units, nginx snippets, upgrade preserves config, status, uninstall keeps config")

    public = "ab" * 32
    root = new_root()
    run(root, "--yes", "--mode", "4", "--upstream", "[::1]:9000", "--full", "--admin-keys", public)
    unit = (root / "etc/systemd/system/npulse.service").read_text()
    assert "User=root" in unit and "DynamicUser=" not in unit and "ProtectHome=" not in unit
    assert config(root)["admin_keys"] == public and "listen" not in config(root)
    run(root, "uninstall", "--yes", "--purge")
    assert not (root / "etc/npulse").exists()
    root = new_root()
    run(root, "--yes", "--mode", "1", "--lite", "--admin-keys", public, ok=False)
    assert not (root / "usr").exists()
    print("PASS outbound-only relay admin runs root/full; lite+admin rejected before installation; explicit purge removes config")

    root = new_root()
    run(root, "--yes", "--mode", "5", "--lite", NPULSE_INIT="procd", NPULSE_ARCH="mipsel")
    assert (root / "usr/bin/npulse").read_bytes() == (MIRROR / "npulse-linux-mipsel-lite").read_bytes()
    unit = (root / "etc/init.d/npulse").read_text()
    assert "procd_set_param respawn 3600 5 0" in unit and "-c /etc/npulse/npulse.conf" in unit
    run(root, "upgrade", "--yes")  # Uses recorded procd/arch/flavor, not new environment defaults.
    run(root, "uninstall", "--yes", "--purge")
    assert not (root / "usr/bin/npulse").exists()
    print("PASS procd install/upgrade/uninstall: /usr/bin binary, respawn, recorded mipsel/lite selection")

    for arch in ARCHES:
        root = new_root()
        run(root, "--yes", NPULSE_ARCH=arch)
        assert (root / "usr/local/bin/npulse").read_bytes() == (MIRROR / f"npulse-linux-{arch}").read_bytes()
        run(root, "uninstall", "--yes", "--purge")
    print("PASS all seven architectures default full, including MIPS/MIPSEL")

    for mode in range(1, 6):
        for arch, init in (("x86_64", "systemd"), ("mips", "procd"), ("mipsel", "procd")):
            root = new_root()
            interactive(root, mode=mode, arch=arch, init=init)
            run(root, "uninstall", "--yes", "--purge")
            root = new_root()
            run(root, "--yes", "--mode", str(mode), "--upstream", "relay.example:9010", NPULSE_ARCH=arch, NPULSE_INIT=init)
            assert "flavor=full\n" in (root / "etc/npulse/install.state").read_text()
            run(root, "uninstall", "--yes", "--purge")
    for settings in ({"flavor_answer": "lite"}, {"flavor": "lite"}, {"flavor_flag": "--lite"},
                     {"flavor": "lite", "flavor_flag": "--full"}, {"flavor": "full"}):
        root = new_root()
        interactive(root, **settings)
        run(root, "uninstall", "--yes", "--purge")
    for args, settings, expected in (([], {"NPULSE_FLAVOR": "lite"}, "lite"),
                                     (["--full"], {"NPULSE_FLAVOR": "lite"}, "full")):
        root = new_root()
        run(root, "--yes", *args, **settings)
        assert f"flavor={expected}\n" in (root / "etc/npulse/install.state").read_text()
        run(root, "uninstall", "--yes", "--purge")
    run(new_root(), "--yes", "--admin-via-pair", "--lite", ok=False)
    print("PASS interactive Enter and unattended defaults full in all five modes on systemd and OpenWrt MIPS/MIPSEL; explicit menu/flag/env lite honored, --full overrides env, lite+pair-admin rejected")

    tools = isolated_tools()
    if shutil.which("curl"):
        (tools / "curl").symlink_to(shutil.which("curl"))
    (tools / "uname").unlink()
    (tools / "uname").write_text('#!/bin/sh\ncase "$1" in -m) printf "%s\\n" "$FIXTURE_MACHINE" ;; -n) echo fixture ;; *) exec ' + shlex.quote(shutil.which("uname")) + ' "$@" ;; esac\n')
    (tools / "uname").chmod(0o755)
    (tools / "od").unlink()
    (tools / "od").write_text('#!/bin/sh\ncase "$*" in *"-j 5"*) echo "$FIXTURE_ENDIAN" ;; *"-j 37"*) echo "$FIXTURE_FLAGS" ;; *) exec ' + shlex.quote(shutil.which("od")) + ' "$@" ;; esac\n')
    (tools / "od").chmod(0o755)
    for machine, endian, flags, expected in [
        ("x86_64", "1", "0", "x86_64"), ("i686", "1", "0", "i386"),
        ("aarch64", "1", "0", "aarch64"), ("armv7l", "1", "4", "armv7"),
        ("armv7l", "1", "2", "armv7-soft"), ("mips", "2", "0", "mips"), ("mips", "1", "0", "mipsel"),
    ]:
        root = new_root()
        run(root, "--yes", NPULSE_ARCH="", PATH=str(tools), FIXTURE_MACHINE=machine, FIXTURE_ENDIAN=endian, FIXTURE_FLAGS=flags)
        assert f"arch={expected}\n" in (root / "etc/npulse/install.state").read_text()
        run(root, "uninstall", "--yes", "--purge")
    result = run(new_root(), "--yes", ok=False, NPULSE_ARCH="", PATH=str(tools), FIXTURE_MACHINE="armv7l", FIXTURE_FLAGS="0")
    assert "无法确认 ARM" in result.stderr
    print("PASS simulated uname/ELF detection: x86, i386, aarch64, ARM hard/soft, MIPS both byte orders; unknown ARM ABI refuses unattended guess")

    (tools / "df").unlink()
    (tools / "df").write_text('#!/bin/sh\nprintf "Filesystem 1024-blocks Used Available Capacity Mounted\\nfixture 4096 3072 1024 75%% /\\n"\n')
    (tools / "df").chmod(0o755)
    root = new_root()
    run(root, "--yes", PATH=str(tools))
    assert "flavor=full\n" in (root / "etc/npulse/install.state").read_text()
    run(root, "uninstall", "--yes", "--purge")
    print("PASS simulated low free space still defaults full")

    for address, bind in (("8.8.4.4", "0.0.0.0:9000"), ("2606:4700:4700::1111", "[::]:9000")):
        root = new_root()
        result = run(root, "--yes", "--public-ip", address)
        assert config(root)["listen"] == bind
        assert f"App 参考地址：{address}" in result.stdout
        assert "gcloud compute firewall-rules create" in result.stdout
        advertised = root / "etc/npulse/public-ip"
        assert advertised.read_text().strip() == address and advertised.stat().st_mode & 0o777 == 0o600
        run(root, "upgrade", "--yes")
        assert advertised.read_text().strip() == address
        run(root, "pair", "--yes")
        run(root, "uninstall", "--yes", "--purge")
        assert not advertised.exists()
    root = new_root()
    result = run(root, "--yes", "--bind", "127.0.0.1", NPULSE_PUBLIC_IP="8.8.4.4")
    assert config(root)["listen"] == "127.0.0.1:9000" and "App 参考地址：8.8.4.4" in result.stdout
    run(root, "uninstall", "--yes", "--purge")
    run(new_root(), "--yes", "--public-ip", "10.0.0.1", ok=False)
    print("PASS cloud external IPv4/IPv6: wildcard listener, public App address, cloud firewall note, private response rejected, --bind override, persisted pair host survives upgrade and is purged")
    root = new_root()
    interactive(root, public_answer="n")
    assert "relay_upstream" in config(root) and "listen" not in config(root)
    assert not (root / "etc/npulse/public-ip").exists()
    run(root, "uninstall", "--yes", "--purge")
    print("PASS interactive No public IP switches into complete shared-relay flow by default")

    (tools / "ip").write_text('#!/bin/sh\nprintf "inet 192.0.2.10/24 scope global fixture\\n"\n')
    (tools / "ip").chmod(0o755)
    root = new_root()
    output = run(root, "--yes", "--port", "443", PATH=str(tools))
    assert "192.0.2.10" in output.stdout
    assert "AmbientCapabilities=CAP_NET_BIND_SERVICE" in (root / "etc/systemd/system/npulse.service").read_text()
    run(root, "uninstall", "--yes", "--purge")
    print("PASS local address summary and least-privilege bind capability for privileged ports")

    root = new_root()
    interactive(root)
    run(root, "uninstall", "--yes", "--purge")
    print("PASS piped installer reads /dev/tty; interactive credentials have no terminal echo and appear only in final summary")

    for source, pair in [("", "n"), ("1", "y"), ("2", "n")]:
        root = new_root(); interactive(root, source, pair)
        run(root, "uninstall", "--yes", "--purge")
    for mode in ("1", "4"):
        for options, settings in [(["--admin-via-pair"], {}), ([], {"NPULSE_ADMIN": "pair"})]:
            root = new_root()
            rejected = run(new_root(), "--yes", "--mode", mode, "--upstream", "relay.example:9010", "--lite", *options, ok=False, **settings)
            assert "lite 不允许启用管理" in rejected.stderr
            result = run(root, "--yes", "--mode", mode, "--upstream", "relay.example:9010", *options, **settings)
            assert "[DRY_RUN] 配对" in result.stdout and "sh install.sh pair" in result.stdout
            assert "admin_keys" not in config(root) and "DynamicUser=yes" in (root / "etc/systemd/system/npulse.service").read_text()
            assert "flavor=full" in (root / "etc/npulse/install.state").read_text()
            run(root, "uninstall", "--yes", "--purge")
    run(new_root(), "--yes", "--admin-via-pair", "--admin-keys", "a" * 64, ok=False)
    run(new_root(), "--yes", "--mode", "2", "--admin-via-pair", ok=False)
    print("PASS admin source menu: default/choice 1 never asks for paste, forces full and warns on skipped pairing; choice 2 still pastes; flag/env direct+relay launch pairing without pre-authorizing root; conflicting keys and unsupported modes rejected")
    for keys_via_env in (False, True):
        for source in ("", "1"):
            root = new_root()
            interactive(root, source, preset_keys="B" * 64 + "," + "c" * 64, keys_via_env=keys_via_env)
            run(root, "uninstall", "--yes", "--purge")
    print("PASS preset CLI/env admin keys: Enter defaults to manual and preserves all prefilled keys/root unit; only explicit choice 1 discards keys for pairing/DynamicUser")

    if shutil.which("wget"):
        tools = isolated_tools()
        root = new_root()
        run(root, "--yes", PATH=str(tools))
        assert config(root)["listen"] == "0.0.0.0:9000"
        run(root, "uninstall", "--yes", "--purge")
        print("PASS wget-only PATH downloads and verifies real assets (curl absent)")
        (tools / "wget").unlink()
        (tools / "wget").write_text('#!/bin/sh\nif [ "$1" = --help ]; then echo "wget -q -O FILE URL"; exit 0; fi\nfor arg do [ "$arg" != -T ] || exit 99; done\nexec ' + shlex.quote(shutil.which("wget")) + ' "$@"\n')
        (tools / "wget").chmod(0o755)
        root = new_root()
        run(root, "--yes", PATH=str(tools))
        run(root, "uninstall", "--yes", "--purge")
        print("PASS minimal wget without -T support")
    if shutil.which("shasum"):
        tools = isolated_tools(exclude=("sha256sum",))
        # Preserve a real downloader even when wget is unavailable on a test host.
        if shutil.which("curl"):
            (tools / "curl").symlink_to(shutil.which("curl"))
        root = new_root()
        run(root, "--yes", PATH=str(tools))
        run(root, "uninstall", "--yes", "--purge")
        print("PASS shasum SHA256 fallback with sha256sum absent")
    if shutil.which("hexdump"):
        tools = isolated_tools(exclude=("od",))
        if shutil.which("curl"):
            (tools / "curl").symlink_to(shutil.which("curl"))
        root = new_root()
        run(root, "--yes", PATH=str(tools))
        assert len(config(root)["secret"]) == 32
        run(root, "uninstall", "--yes", "--purge")
        print("PASS hexdump random generation fallback for OpenWrt without od")
    if os.geteuid() != 0:
        run(new_root(), "--yes", ok=False, DRY_RUN="0", DESTDIR="")
        print("PASS real installation rejects non-root before filesystem changes")

    for args, settings in [
        (["--mode", "9"], {}), (["--port", "0"], {}), (["--port", "65536"], {}),
        (["--mode", "4"], {}), (["--mode", "5", "--admin-keys", public], {}),
        (["--admin-keys", "bad"], {}), (["--name", "bad\nsecret=oops"], {}),
        ([], {"NPULSE_VERSION": "../../oops"}), ([], {"NPULSE_ARCH": "unknown"}),
        ([], {"DESTDIR": "/"}), ([], {"DESTDIR": str(OUTPUT / ".." )}),
    ]:
        run(new_root(), "--yes", *args, ok=False, **settings)
    root = new_root()
    run(root, "upgrade", "--yes", ok=False)
    existing = new_root()
    run(existing, "--yes")
    installed = (existing / "usr/local/bin/npulse").read_bytes()
    saved_config = (existing / "etc/npulse/npulse.conf").read_bytes()
    (MIRROR / "SHA256SUMS").write_text(sums.replace(hashlib.sha256((MIRROR / "npulse-linux-x86_64").read_bytes()).hexdigest(), "0" * 64))
    result = run(root, "--yes", ok=False, NPULSE_SECRET="DO-NOT-LOG-THIS")
    assert "DO-NOT-LOG-THIS" not in result.stdout + result.stderr and not (root / "usr").exists()
    run(existing, "upgrade", "--yes", ok=False)
    assert (existing / "usr/local/bin/npulse").read_bytes() == installed
    assert (existing / "etc/npulse/npulse.conf").read_bytes() == saved_config
    run(existing, "uninstall", "--yes", "--purge")
    (MIRROR / "SHA256SUMS").write_text("")
    run(root, "--yes", ok=False)
    print("PASS invalid/missing inputs, unknown architecture, unsafe DESTDIR, missing installation, tampered/empty checksums: fail closed, no secret logs or installed binary")
    print("ALL INSTALLER CHECKS PASSED (" + " ".join(SHELL) + ")")
    print("Installer artifacts: " + str(OUTPUT))
finally:
    server.shutdown()
    server.server_close()
