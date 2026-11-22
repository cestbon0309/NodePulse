# NodePulse

## Linux / OpenWrt 部署

以下命令在仓库根目录执行。先运行 `probe/build.sh`，或下载 CI / Release 的静态二进制；
按目标机器架构选择文件（OpenWrt 的 mips / mipsel 还需核对字节序及 CPU 指令集）。
示例端口为 TCP 9000（加密直连）、9001（本机 HTTP）、443（公网 HTTPS）。

### 安装服务

Linux（systemd 247+，通过服务凭据把 root-only 配置交给动态用户，不需要 root 常驻）：

```sh
sudo install -m 0755 probe/dist/npulse-linux-x86_64 /usr/local/bin/npulse
sudo install -m 0600 probe/deploy/npulse.conf /etc/npulse.conf
SECRET=$(openssl rand -hex 32)
sudo sed -i "s/CHANGE-ME/$SECRET/" /etc/npulse.conf
sudo install -m 0644 probe/deploy/npulse.service /etc/systemd/system/npulse.service
sudo systemctl daemon-reload
sudo systemctl enable --now npulse
sudo systemctl status npulse
```

在 iOS 接入点中填入 `/etc/npulse.conf` 的 `secret`，不要公开此文件或提交真实密钥。
修改配置后执行 `sudo systemctl restart npulse`，查看日志用 `sudo journalctl -u npulse -f`。
DynamicUser 不能读到部分受限指标时会保留默认值；不要为此盲目授予 root 权限。

OpenWrt（把选好的二进制和 `probe/deploy/` 中两个文件复制到路由器后执行，以下以 mipsel 为例）：

```sh
install -m 0755 npulse-linux-mipsel /usr/bin/npulse
cp npulse.conf /etc/npulse.conf
chmod 600 /etc/npulse.conf
SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
sed -i "s/CHANGE-ME/$SECRET/" /etc/npulse.conf
cp npulse.init /etc/init.d/npulse
chmod 755 /etc/init.d/npulse
/etc/init.d/npulse enable
/etc/init.d/npulse start
```

配置变更后执行 `/etc/init.d/npulse restart`，日志用 `logread -e npulse`。

### 直连

默认配置 `listen=0.0.0.0:9000` 即可；iOS 选择「直连 TCP」，填写机器地址、9000 和密钥。
仅放行 TCP 9000（可进一步限制来源 IP），不要开放 HTTP 9001。使用 UFW 的 Linux：

```sh
sudo ufw allow 9000/tcp
```

OpenWrt 默认 LAN 可访问；确需从 WAN 直连时，显式添加规则（公网风险请自行评估）：

```sh
uci set firewall.npulse=rule
uci set firewall.npulse.name='NodePulse'
uci set firewall.npulse.src='wan'
uci set firewall.npulse.proto='tcp'
uci set firewall.npulse.dest_port='9000'
uci set firewall.npulse.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
```

### HTTP + Nginx

让 HTTP 只监听本机，并保留本机直连监听：**自身节点仅在启用 listen 时出现在列表**。
以下替换默认 listen 配置，勿让探针明文 HTTP 暴露公网：

```sh
sudo sed -i 's/^listen=.*/listen=127.0.0.1:9000/; s/^# http=.*/http=127.0.0.1:9001/' /etc/npulse.conf
sudo systemctl restart npulse
sudo apt-get install -y nginx certbot
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo systemctl stop nginx
sudo certbot certonly --standalone -d probe.example.com
sudo install -m 0644 probe/deploy/nginx-probe.conf /etc/nginx/conf.d/npulse.conf
sudo nginx -t
sudo systemctl start nginx
```

先把域名解析到服务器，并把命令和配置里的 `probe.example.com` 都换成自己的域名。
80 端口用于上述 standalone 证书验证；续期需配置停止/启动 Nginx 的 certbot hooks，
或改用 webroot / DNS 验证。公网只需 443（及证书验证所需 80），不要开放 9000/9001；
若之前已放行 9000，请删除该防火墙规则。iOS 选择 HTTPS，填 `https://probe.example.com`。
Nginx 保留 Authorization，其他路径返回 404；避免在 URL 中放密钥，以免进入访问日志。

### 中继

上游采用直连配置并开放 TCP 9000；下游只主动连出，不需要任何入站防火墙规则。
下游的 secret 必须与上游相同；共享密钥意味着任一成员可向上游推送节点，应只用于同一信任域。
在下游配置中移除 listen/http，加入 upstream（替换域名）：

```sh
sudo sed -i '/^listen=/d; /^http=/d; s/^# upstream=.*/upstream=relay.example.com:9000/' /etc/npulse.conf
sudo systemctl restart npulse
```

OpenWrt 使用同样的配置键，编辑后运行 `/etc/init.d/npulse restart`。
上游可同时运行 Nginx HTTPS，iOS 连接上游即可看到中继节点。

### CI / 发布

`.github/workflows/probe.yml` 使用 Zig 0.17.1，运行真实 Linux 原生集成测试及
aarch64、armv7（硬/软浮点）、mips、mipsel 的 QEMU 加密 get 测试，并输出指标断言和快照。
QEMU 用户态测试共用宿主的 /proc 与网络，验证的是目标 ELF/系统调用/协议，不替代真实设备测试。
工作流上传 `npulse-linux` artifact；推送 `v*` 标签才会创建/更新 Release 并附加验证后的二进制。
`.github/workflows/ios.yml` 动态选择 iOS 17+ iPhone 模拟器，使用 ad-hoc 签名运行 XCTest（含真实 Keychain）。

## iOS app core

Requires Xcode and XcodeGen, no third-party packages. Generate the project with
`cd ios && xcodegen`, then open `NodePulse.xcodeproj`. The generated project is
ignored; `project.yml` is the source of truth. Minimum iOS 17, Swift 5 mode.
Simulator builds use local ad-hoc signing (`CODE_SIGN_IDENTITY=-`) so Keychain
works without a development team. Run tests with:

```
cd ios
xcodegen
xcodebuild test -scheme NodePulse -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
```

For the live client test, run the host probe with `-k integration-secret
-l 127.0.0.1:19090 -H 127.0.0.1:19091` and set `NPULSE_E2E=1` for both
`xcodegen` and `xcodebuild test`. The Security integration test verifies the
real simulator Keychain. Store CRUD also uses an injected in-memory secret
store for isolated tests; production always defaults to Keychain.

Endpoints and preferences are stored in UserDefaults; secrets only in Keychain
(service `nodepulse`, account endpoint UUID). Direct uses CryptoKit IETF
ChaChaPoly framing. HTTP permits insecure transport only to localhost/127.0.0.1
for development. Redirects are rejected to avoid forwarding bearer secrets.
The Chinese adaptive dashboard includes detail charts, endpoint management,
settings and demo mode. Debug launch arguments: `-demo YES`, `-empty YES`,
`-show-add YES`, and `-live YES` (localhost:19090 / integration-secret).
Regenerate the icon with `cd ios && swift tools/generate-icon.swift`.
The probe does not transmit its configured interval, so relay freshness uses a
5-second initial estimate, then the observed snapshot timestamp cadence.

`probe/npulse` is a small, single-process Linux monitoring probe. Version 0.1.0.
No threads or runtime libraries beyond libc; cryptography is vendored Monocypher
4.0.2 from <https://monocypher.org/download/monocypher-4.0.2.tar.gz>.
Only its four source/header files are retained; each carries the upstream
BSD-2-Clause/CC0 dual-license notice. SHA-512 uses the optional Ed25519 module;
unused algorithms are removed by LTO and section garbage collection.

## Build

```
cd probe
make CC=musl-gcc                  # native Linux static build
./build.sh                       # Zig cross-builds all seven variants
make host-test                   # macOS network/crypto test binary npulse-host
```

The build script requires `zig` (`brew install zig` on macOS). Outputs are
`probe/dist/npulse-linux-{x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel}`.
ARM builds target ARMv7 Cortex-A7; `armv7` uses hard-float and `armv7-soft`
uses the soft-float ABI. MIPS builds target MIPS32 with soft float and musl's
O32 ABI (`musleabi` in current Zig). All use static musl, `-Os`, LTO,
function/data sections, linker garbage collection and stripping. Build failures
and warnings are errors. `make` supports `CC`, `CFLAGS`, and `LDFLAGS` overrides.

## Run

```
npulse -k 'shared-secret' -l 9000 -H 8080 -n router
npulse -k 'shared-secret' -u upstream.example:9000 -i 5 -n satellite
npulse -c /etc/npulse.conf
```

`-k` is required. `-l [addr:]port` is the encrypted direct listener (default
address `0.0.0.0`). `-H [addr:]port` is plain HTTP (default `127.0.0.1`), intended
**only behind a TLS reverse proxy**. `-u host:port` pushes upstream every `-i`
seconds (default 5); all three modes may be combined. IPv6 endpoints use
`[address]:port`. `-n` defaults to hostname. `-h` prints usage. At least one
listener or upstream is required. Config is unquoted `key=value`, with blank
lines and `#` comment lines; keys are `secret`, `listen`, `http`, `upstream`,
`interval`, `name`. CLI values override configuration regardless of order.
Protect the config file and command-line secret from other local users.

Direct requests are IETF ChaCha20-Poly1305 frames:
`uint32_be(ciphertext length) | random nonce[12] | ciphertext | tag[16]`.
The length bytes are authenticated additional data, with no magic or other
framing. Key is SHA-512 of the UTF-8 secret, truncated to 32 bytes. Maximum
ciphertext length is 262144. Each connection accepts one request and sends one
response, then closes. Invalid requests receive no bytes. Read/write deadlines
are five seconds. Timestamps must be within 120 seconds. The last 256 accepted
nonces are cached (up to 240 seconds). Use a high-entropy secret: this protocol
does not offer forward secrecy or password stretching.

Requests: `{"op":"get","ts":UNIX_SECONDS}` or
`{"op":"push","ts":UNIX_SECONDS,"node":SNAPSHOT}`. Push snapshots require a
nonempty string id and must not contain server-owned `relay`/`last_seen` fields.
Successful push returns `{"ok":true}`. Get returns
`{"ok":true,"nodes":[...]}`. Self comes first only when `-l` is enabled and has
`relay:false`. Up to 64 relayed nodes are stored by id, with `relay:true` and
`last_seen`; entries expire after ten minutes. A fixed 32-client pool limits
resource use; slow peers do not block other inbound clients. Upstream DNS and
connect/send attempts are synchronous (connect/send waits capped at one second
each, DNS resolution follows the system resolver).

HTTP: `GET /api/nodes`, with `Authorization: Bearer SECRET` or `?key=SECRET`,
returns the same JSON. All other requests return an empty 404. The query key
is literal, not URL-decoded; prefer Bearer for secrets containing special URL
characters and to avoid query-string logging. HTTP headers are limited to 8KB.

Metrics are sampled from Linux procfs/sysfs once per second, plus statvfs and
getifaddrs. Missing metrics are zero/empty except absent temperature is null.
macOS host-test deliberately tolerates missing Linux files (zero-valued procfs
metrics); it is for protocol verification, not macOS monitoring.

## Verify

```
python3 -m venv .venv
.venv/bin/pip install cryptography
.venv/bin/python probe/tools/npulse-cli.py 127.0.0.1 9000 -k shared-secret get
.venv/bin/python probe/tools/npulse-cli.py 127.0.0.1 9000 -k shared-secret push --node snapshot.json
cd probe
../.venv/bin/python tools/test-probe.py ./npulse-host
# On Linux, substitute ./dist/npulse-linux-<arch> for ./npulse-host.
```

The integration check covers direct AEAD interoperability with Python's
ChaCha20Poly1305, snapshot fields and string escaping, silent error handling,
replay rejection, timeout, HTTP auth, relay-only operation, replacement by id,
empty node lists, config and CLI precedence.
