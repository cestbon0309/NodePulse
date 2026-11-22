#!/usr/bin/env python3
"""Pairing vector and PTY-based, dual-consent full/lite integration checks."""
import hashlib
import importlib.util
import json
import os
import base64
from pathlib import Path
import pty
import re
import select
import signal
import socket
import struct
import subprocess
import sys
import time
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("client", ROOT / "tools/npulse-cli.py")
c = importlib.util.module_from_spec(spec); spec.loader.exec_module(c)


def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]


def qr_check(server, ascii_mode=False):
    import cv2
    import numpy as np
    rows = []
    for line in server.art.decode().replace("\r\n", "\n").splitlines():
        if ascii_mode:
            if len(line) >= 42 and len(line) % 2 == 0 and set(line) <= {"#", " "}:
                rows.append([int(line[x:x+2] == "##") for x in range(0, len(line), 2)])
        elif line.startswith("\033[30;107m"):
            text = re.sub(r"\x1b\[[0-9;]*m", "", line)
            cells = [{" ": (0, 0), "▀": (1, 0), "▄": (0, 1), "█": (1, 1)}[char] for char in text]
            rows.extend([[cell[i] for cell in cells] for i in (0, 1)])
    assert rows
    rows = rows[:len(rows[0])]
    matrix = (1 - np.array(rows, dtype=np.uint8)) * 255
    assert matrix.shape[0] == matrix.shape[1]
    image = np.repeat(np.repeat(matrix, 10, axis=0), 10, axis=1)
    decoded, points, _ = cv2.QRCodeDetector().detectAndDecode(image)
    if decoded != server.url:
        decoded, points, _ = cv2.QRCodeDetectorAruco().detectAndDecode(image)
    if decoded != server.url:
        import qrcode
        from qrcode.util import QRData, MODE_8BIT_BYTE
        matched = False
        for mask in range(8):
            qr = qrcode.QRCode(version=(len(rows) - 25) // 4, error_correction=qrcode.constants.ERROR_CORRECT_M, box_size=1, border=4, mask_pattern=mask)
            qr.add_data(QRData(server.url.encode(), mode=MODE_8BIT_BYTE), optimize=0); qr.make(fit=False)
            if np.array_equal(np.array(qr.get_matrix(), dtype=np.uint8), np.array(rows, dtype=np.uint8)): matched = True
        assert matched, "terminal QR does not match independent byte-mode ECC-M encoding of printed URL"
        print("PASS QR decoder fallback: OpenCV did not decode this mask; independent Python byte-mode ECC-M encoder matches every module")
    cv2.imwrite(str(ROOT / "dist" / ("pair-qr-ascii.png" if ascii_mode else "pair-qr-halfblocks.png")), image)


class Server:
    def __init__(self, binary, timeout=8, relay=None, token="pair-relay-token", qr_ascii=False, secret="paired-test-key"):
        self.port, self.art = port(), b""
        self.output, output = os.pipe()
        self.pid, self.fd = pty.fork()
        if not self.pid:
            os.close(self.output); os.dup2(output, 1); os.close(output)
            args = ["-R", f"127.0.0.1:{relay}", "-T", token, "-G", "paired-group"] if relay else ["-l", f"127.0.0.1:{self.port}", "-k", secret]
            os.execv(binary, [binary, "-P", *args, "-n", "配对测试", "-W", str(timeout), *(["-Q", "ascii"] if qr_ascii else [])])
        os.close(output)
        capture = self.until("扫码仅填写")
        self.url = re.search(r"nodepulse://pair[^\s]+", capture).group(0)
        self.query = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.url).query).items()}
    def until(self, text):
        end = time.monotonic() + 10
        while text.encode() not in self.art:
            assert time.monotonic() < end, self.art.decode(errors="replace")
            if select.select([self.fd], [], [], 0.1)[0]:
                try: self.art += os.read(self.fd, 8192)
                except OSError: raise AssertionError(self.art.decode(errors="replace"))
        return self.art.decode().replace("\r\n", "\n")
    def answer(self, value):
        self.until("是否一致"); os.write(self.fd, (value + "\n").encode())
    def wait(self, expected):
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], 0.02)[0]:
                try: self.art += os.read(self.fd, 8192)
                except OSError: pass
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                assert expected is None or os.waitstatus_to_exitcode(status) == expected, self.art
                os.close(self.fd); self.stdout = os.read(self.output, 4096).decode(); os.close(self.output); return
            time.sleep(0.02)
        os.close(self.fd); os.kill(self.pid, signal.SIGKILL)
        raise AssertionError("pairing server did not exit: " + self.art.decode(errors="replace"))


def main():
    vector = json.loads((ROOT / "tools/pair-vector.json").read_text())
    for binary in sys.argv[1:]:
        binary = str(Path(binary).resolve())
        actual = json.loads(subprocess.check_output([binary, "--vector"]))
        subprocess.run([binary, "--pair-timers"], check=True)
        assert all(actual[k] == vector[k] for k in actual)
        private = c.X25519PrivateKey.from_private_bytes(bytes.fromhex(vector["sk_c"]))
        keys, sas, art, code = c.pair_material(private, bytes.fromhex(vector["epk_p"]))
        assert keys.hex() == vector["k"] and sas.hex() == vector["sas"] and art == vector["art"] and code == vector["code"]
        keys, sas, _, _ = c.pair_material(private, bytes.fromhex(vector["epk_p"]), bytes.fromhex(vector["psk"]))
        assert keys.hex() == vector["k_psk"] and sas.hex() == vector["sas_psk"]
        s = Server(binary); client = c.PairClient("127.0.0.1", s.port)
        capture = s.until("是否一致")
        assert client.art in capture and client.code in capture
        client.send({"op": "confirm", "name": "Python", "admin_pk": "AB" * 32}, True)
        supported = b"Admin (disabled by default)" in subprocess.check_output([binary, "-h"])
        s.answer("y")
        if supported:
            s.until("是否授权"); s.answer("y")
        result = client.receive(True); client.close(); s.wait(0)
        assert result["admin"] is supported
        assert s.stdout == ("admin_pk=" + "AB" * 32 + "\n" if supported else "")
        assert result["ok"] and result["key"] == "paired-test-key" and result["name"] == "配对测试" and len(result["node"]) == 64
        assert result["port"] == s.port
        if supported:
            for early_sas, admin_answer in [(True, "n"), (False, "n"), (False, "")]:
                pending = Server(binary)
                if early_sas: os.write(pending.fd, b"y\ny\n")
                phone = c.PairClient("127.0.0.1", pending.port)
                pending.until("是否一致")
                if not early_sas: os.write(pending.fd, b"y\ny\n")
                phone.send({"op": "confirm", "admin_pk": "ab" * 32}, True)
                if early_sas:
                    assert not select.select([phone.sock], [], [], .15)[0], "input before SAS prompt approved pairing"
                    pending.answer("y")
                pending.until("该手机请求管理权限（root 级控制），是否授权？[y/N]")
                assert not select.select([phone.sock], [], [], .15)[0], "buffered SAS answers granted admin"
                pending.answer(admin_answer)
                monitoring = phone.receive(True); phone.close(); pending.wait(0)
                assert monitoring["ok"] and monitoring["key"] == "paired-test-key" and monitoring["admin"] is False
                assert not pending.stdout
            print(f"PASS {Path(binary).name}: pre-buffered y/y cannot grant SAS or admin; fresh separate root prompt; n/empty admin response still pairs for monitoring with admin:false and no stdout key")
        normal = subprocess.Popen([binary, "-l", f"127.0.0.1:{s.port}", "-k", result["key"]])
        try:
            deadline = time.monotonic() + 3
            while True:
                try:
                    response = c.exchange("127.0.0.1", s.port, result["key"], {"op": "get", "ts": int(time.time())}); break
                except OSError:
                    assert time.monotonic() < deadline; time.sleep(0.02)
            assert response["nodes"]
        finally: normal.terminate(); normal.wait(timeout=5)
        for server_yes, client_yes in [(False, True), (True, False)]:
            s = Server(binary); client = c.PairClient("127.0.0.1", s.port)
            client.send({"op": "confirm" if client_yes else "reject"}, True)
            if client_yes: s.answer("y" if server_yes else "n")
            assert client.receive(True) == {"ok": False}; client.close(); s.wait(1)
        s = Server(binary)
        qr_check(s)
        for _ in range(5):
            with socket.create_connection(("127.0.0.1", s.port)) as sock:
                sock.settimeout(2)
                obj = json.dumps({"op": "pair", "v": 1, "commit": "00" * 32}).encode()
                sock.sendall(struct.pack("!I", len(obj)) + obj)
                n = struct.unpack("!I", c.exact(sock, 4))[0]; c.exact(sock, n)
                obj = json.dumps({"epk": vector["epk_c"]}).encode(); sock.sendall(struct.pack("!I", len(obj)) + obj)
                assert sock.recv(1) == b""
        s.wait(1)
        s = Server(binary, timeout=1); s.wait(1)
        print(f"PASS {Path(binary).name}: fixed C/Python commit/keys/SAS/art/code; identical PTY art; dual consent/key delivery; stdout only authorized admin key (lite ignores); direct get; both rejections; bad commit silent/5-attempt cap; window timeout")
        for approved, correct in [(True, True), (False, True), (False, False)]:
            s = Server(binary, timeout=3)
            psk = base64.urlsafe_b64decode(s.query["s"] + "==") if correct else bytes(16)
            client = c.PairClient("127.0.0.1", s.port, psk=psk)
            client.send({"op": "confirm"}, True)
            if approved: s.answer("y")
            try:
                result = client.receive(True)
                assert approved and correct and result["key"] == "paired-test-key"
            except (OSError, EOFError): assert not approved or not correct
            client.close(); s.wait(0 if approved and correct else 1)
            assert not s.stdout
        print(f"PASS {Path(binary).name}: PSK still requires BOTH manual confirmations; no server y means no key; wrong PSK silently rejected")
        s = Server(binary, timeout=1, qr_ascii=True); qr_check(s, True); s.wait(1)
        print(f"PASS {Path(binary).name}: actual Unicode-half-block and ASCII terminal QR verified against printed URL/PSK by OpenCV (independent encoder fallback), with quiet zone")
        relay_port = port()
        relay = subprocess.Popen([binary, "-S", f"127.0.0.1:{relay_port}", "-T", "pair-relay-token"])
        try:
            time.sleep(.15)
            for psk_mode in (False, True):
                s = Server(binary, relay=relay_port)
                qr_check(s)
                client = c.PairClient("127.0.0.1", relay_port, token="pair-relay-token", code=s.query["c"].lower(), psk=base64.urlsafe_b64decode(s.query["s"] + "==") if psk_mode else None)
                capture = s.until("是否一致"); assert client.art in capture and client.code in capture
                client.send({"op": "confirm"}, True); s.answer("y"); result = client.receive(True); client.close(); s.wait(0)
                assert result["mode"] == "relay" and result["group"] == "paired-group" and "key" not in result
                for code in (s.query["c"], "ZZZZ-ZZZZ"):
                    try: c.PairClient("127.0.0.1", relay_port, token="pair-relay-token", code=code)
                    except (OSError, EOFError): pass
                    else: raise AssertionError("code reuse/unknown code accepted")
            for relay_mode in (False, True):
                s = Server(binary, relay=relay_port if relay_mode else None)
                process = subprocess.Popen([sys.executable, str(ROOT / "tools/npulse-cli.py"), "pair", "--url", s.url], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                process.stdin.write("y\ny\n"); process.stdin.flush(); s.answer("y")
                output, error = process.communicate(timeout=5); assert process.returncode == 0, error
                assert json.loads(output[output.index("{"):])["ok"] is True; s.wait(0)
            s = Server(binary, timeout=2, relay=relay_port)
            client = c.PairClient("127.0.0.1", relay_port, token="pair-relay-token", code=s.query["c"], psk=bytes(16))
            client.send({"op": "confirm"}, True)
            try: client.receive(True)
            except (OSError, EOFError): pass
            else: raise AssertionError("wrong relay PSK accepted")
            client.close(); s.wait(1); assert not s.stdout
            print(f"PASS {Path(binary).name}: Python pair --url direct/relay still prompts twice and needs server y; relay QR decodes; wrong relay PSK rejected and window timeout exits 1")
            normal = subprocess.Popen([binary, "-R", f"127.0.0.1:{relay_port}", "-T", "pair-relay-token", "-G", result["group"], "-n", "配对测试"])
            try:
                deadline = time.monotonic() + 8
                while True:
                    nodes = c.open_blobs(result["group"], c.exchange("127.0.0.1", relay_port, "pair-relay-token", c.group_request(result["group"])))
                    if nodes["nodes"]: break
                    assert time.monotonic() < deadline; time.sleep(.1)
                assert len(nodes["nodes"]) == 1 and nodes["nodes"][0]["node"]["id"] == result["node"]
            finally: normal.terminate(); normal.wait(timeout=5)
            wrong = subprocess.run([binary, "-P", "-R", f"127.0.0.1:{relay_port}", "-T", "wrong-token", "-G", "g", "-W", "2"], capture_output=True, timeout=5)
            assert wrong.returncode == 3 and not wrong.stdout
            pending = Server(binary, relay=relay_port)
            relay.terminate(); relay.wait(timeout=5); pending.wait(3)
            relay = subprocess.Popen([binary, "-S", f"127.0.0.1:{relay_port}", "-T", "pair-relay-token"]); time.sleep(.15)
            s = Server(binary, relay=relay_port); client = c.PairClient("127.0.0.1", relay_port, token="pair-relay-token", code=s.query["c"])
            client.send({"op": "reject"}, True); assert client.receive(True) == {"ok": False}; client.close(); s.wait(1)
        finally: relay.terminate(); relay.wait(timeout=5)
        print(f"PASS {Path(binary).name}: relay + QR/PSK opaque pairing/art match, manual dual consent, single-use/unknown codes, wrong-token exit 3, restart/re-registration, and normal E2E relay fetch")
    print("ALL PAIRING CHECKS PASSED")


if __name__ == "__main__": main()
