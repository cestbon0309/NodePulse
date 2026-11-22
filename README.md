# NodePulse

## 远程管理（C1 直连 / C2 共享中继实时管道）

默认构建包含管理功能，但**默认关闭**。只有显式配置 `-A 公钥[,公钥...]`
（配置键 `admin_keys`，需要 `-l` 或 `-R`）才允许独立 Ed25519 管理密钥开启会话。
持有普通探针密钥只能监控；管理会话使用临时 X25519 + 独立双向 AEAD 密钥。
支持文件管理、交互 PTY 和重启/关机；权限等同探针运行用户，真实电源操作需要 root。
现有 DynamicUser systemd 示例刻意保留低权限，不能用于 root 文件/电源管理；
不要为了管理功能直接取消系统加固，而应单独评估部署用户和授权范围。

`probe/build.sh` 为每种架构生成完整版及 `-lite` 版；`make ADMIN=0` 完全排除管理代码，
适合体积优先的设备。Lite 保留原有监控及端到端共享中继。完整版新增系统功能会更大。
C2 支持 `-R -A` 探针通过共享中继保持控制连接并自动重连，不需要开放探针入站端口。
Python 客户端使用 `--relay host:port --token T --group S --node ID --key 私钥文件`。
端到端管理握手之后使用 C1 会话加密，中继仅做有界、非阻塞字节转发；
握手公开元数据会暴露节点 ID 和管理公钥，但不会暴露终端或文件内容。
Lite 不包含实时管道功能。HTTP/HTTPS 接入点与旧中继不支持远程管理。

### iOS 管理

在「设置 → 管理密钥」生成设备独立的 Ed25519 密钥，将显示的 `-A <公钥>`
或 `admin_keys=<公钥>` 复制到探针配置后重启探针。私钥保存在本机 Keychain
（仅设备解锁时可用、不随备份迁移），不会上传到中继。重新生成不会自动撤销旧公钥：
请先更新每台探针的 allowlist，并移除旧公钥。

直连 TCP / 共享中继 TCP 节点详情中的「管理」提供终端、文件、重启和关机。
默认要求设备身份验证（Face ID / Touch ID，不可用时回退设备密码；模拟器和没有设备密码时跳过）；
可在密钥设置关闭。电源操作先确认、再验证身份，只有 root 探针可以执行。
终端使用 SwiftTerm，提供 Esc/Tab、一次性 Ctrl、方向键和常用符号，退出后可重新连接；
文件管理从用户 home 开始，支持目录、重命名、递归删除及分块上传/下载。
上传不覆盖现有文件，取消发送 `put_abort`；会话断开也会清理未完成上传。
下载完成弹出系统分享面板，可选择「存储到文件」。App 进入后台会关闭管理会话，
不会提供后台传输或保活终端。终端不自动开放远程剪贴板访问或打开远程链接。

管理会话不能通过 HTTPS 接入点建立。若探针未配置 `-A`，监控仍可使用，
但管理握手会被静默拒绝，界面提示检查公钥、密钥与探针时间。

协议、完整命令及安全/测试说明见 [docs/admin-protocol.md](docs/admin-protocol.md)。
Python 客户端 `probe/tools/npulse-admin.py` 提供 `keygen/info/ls/stat/get/put/rm/mkdir/mv/shell/power`。
**power 命令会真实重启或关机；不要在生产机器上作为测试运行。**

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

Requires Xcode and XcodeGen; SwiftTerm is pinned to stable 1.18.0 via SPM
(no build-plugin approval required). Generate the project with
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
The icon source is `design/icon.svg`. Render it with `rsvg-convert -w 1024 -h 1024 design/icon.svg -o design/icon.png`
(install `librsvg` first), then copy the PNG into the AppIcon asset catalog.
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
./build.sh                       # Zig cross-builds seven architectures, full + lite
make host-test                   # macOS network/crypto test binary npulse-host
```

The build script requires `zig` (`brew install zig` on macOS). Outputs are
`probe/dist/npulse-linux-{x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel}`.
ARM builds target ARMv7 Cortex-A7; `armv7` uses hard-float and `armv7-soft`
uses the soft-float ABI. MIPS builds target MIPS32 with soft float and musl's
O32 ABI (`musleabi` in current Zig). All use static musl, `-Os`, LTO,
function/data sections, linker garbage collection and stripping. Build failures
and warnings are errors. `make` supports `CC`, `CFLAGS`, and `LDFLAGS` overrides.

## 共享中继（端到端加密）

共享中继只保存、转发不透明密文，不需要组密钥，也不采集自身指标。
每个组使用独立的高熵组密钥；同组成员互信，可以解密或发布本组节点。
`TOKEN` 只控制中继访问，不提供节点身份隔离，也不能代替组密钥。
中继可见组公钥 `gid`、匿名槽位及其数量、密文大小与通信时间；无法读取或
伪造节点内容，但可拒绝服务、隐藏节点或重放旧密文。接收端须检查密文内已认证的
快照 `ts`，并结合 `age` 提示陈旧状态；`age` 本身由中继提供，并非端到端可信。
协议没有前向保密，也没有口令拉伸，请使用随机长密钥并限制 TOKEN 的分发。

### 部署纯中继

```sh
sudo install -m 0755 probe/dist/npulse-linux-x86_64 /usr/local/bin/npulse
sudo install -m 0600 probe/deploy/npulse-relay.conf /etc/npulse-relay.conf
sudo install -m 0644 probe/deploy/npulse-relay.service /etc/systemd/system/
sudoedit /etc/npulse-relay.conf  # 替换 token；不要放入组密钥
sudo systemctl daemon-reload
sudo systemctl enable --now npulse-relay
sudo ufw allow 9010/tcp  # 探针 gpush 的加密 TCP 端口；仅 HTTPS 访问时可不开放
```

等价命令：`npulse -S 0.0.0.0:9010 -T TOKEN -H 127.0.0.1:9011`。
HTTP 端口不应对公网开放。Nginx 示例中的精确匹配 `location = /api/relay`
代理到 9011，按已有证书配置部署并开放 `443/tcp`。
仅 HTTP 中继可运行 `npulse -H 127.0.0.1:9011 -T TOKEN`（不带 `-k`）。
`-S` 存在时，`-H` 提供中继 API；普通探针的 `-H` 仍提供 `/api/nodes`。
纯中继的启动和循环都跳过指标初始化及 `/proc` 采样。

### 发布节点与读取分组

在每台受监控主机上运行（同组使用同一 GROUP_SECRET）：

```sh
npulse -R relay.example.com:9010 -T TOKEN -G GROUP_SECRET -i 5 -n router
# 可同时保留本机直连、旧式中继或 HTTP；省略 -G 时采用 -k 的值：
npulse -k GROUP_SECRET -R relay.example.com:9010 -T TOKEN -l 9000 -n server
```

发布端只需允许出站 TCP 9010，无需开放入站端口（启用 `-l` 时另行开放 9000）。
对应配置键为 `relay_upstream`、`token`、`group_secret`、`interval`、`name`。

```sh
python3 -m pip install cryptography
python3 probe/tools/npulse-cli.py relay.example.com 9010 -T TOKEN -G GROUP_SECRET gget
python3 probe/tools/npulse-cli.py relay.example.com 9010 -T TOKEN -G GROUP_SECRET gget --raw
python3 probe/tools/npulse-cli.py relay.example.com 9010 -T TOKEN -G GROUP_SECRET gpush --node snapshot.json
```

默认 `gget` 解密并检查快照 id 的槽位派生，输出节点、`age` 和槽位；`--raw`
只输出不透明槽位。iOS 可选择「中继服务器（TCP）」或「中继服务器（HTTPS）」；
分别填写中继令牌和组密钥，二者作为独立钥匙串项目保存。HTTPS 使用 `/api/relay`。
组密钥生成按钮生成 32 字符随机密钥，并复制到仅本机、两分钟后过期的剪贴板。
节点的「端到端」徽章表示来自分组中继；接入点列表会报告忽略的无效密文数量。
新鲜度主要依据 `age > max(30秒, 4×观察到的采样间隔)`；同时将快照时间与手机时间
相差超过十分钟的节点标为离线，防范中继伪造 age 后重放很旧的数据。

### 协议与边界

所有字符串按 UTF-8 编码。`enc_key = SHA512("npulse-e2e-enc:" || S)[0:32]`；
Ed25519 种子为 `SHA512("npulse-e2e-sign:" || S)[0:32]`，使用 RFC 8032，
`gid` 为其 32 字节公钥的小写十六进制。
`slot = hex(SHA512("npulse-e2e-slot:" || enc_key || node_id)[0:16])`。
`blob = base64(nonce12 || ChaChaPoly(enc_key, snapshot, AD=gid+":"+slot).ciphertext || tag16)`。
中继外层沿用现有帧，密钥为 `SHA512(TOKEN)[0:32]`，密文上限 262144 字节，
整帧多 32 字节；无 magic。每个连接一问一答。

`gpush` 字段为 `op,ts,rid,gid,slot,blob,sig`，签名消息为
`"npulse-gpush\n{gid}\n{slot}\n{ts}\n{rid}\n{blob}"`；
`gget` 字段为 `op,ts,rid,gid,sig`，签名消息为
`"npulse-gget\n{gid}\n{ts}\n{rid}"`，均无末尾换行。
`rid` 为随机 16 字节的小写 hex，`sig` 为 64 字节签名的 128 字符小写 hex。
响应回显 `rid`；get 额外返回 `blobs:[{slot,blob,age}]`，push 仅返回 `ok:true,rid`。
时间戳必须在 ±120 秒内；维护最近 256 个外层 nonce 和最近 256 个已验证的
`(gid,rid)`，缓存窗口 240 秒。签名、格式、容量、令牌或认证失败均静默关闭。

最多 256 组，每组 32 个槽位，十分钟后过期并按需清理，容量满时拒绝新增，
已有槽位仍可更新。单个 base64 blob 上限 **7168 字节**。
已有快照上限为 3840 字节（16 个 IP 及有界字符串），封装成 blob 最多
`4×ceil((3840+28)/3) = 5160` 字节，留有 2008 字节余量。
编译期同时断言快照封装预算和 `32×(7168+128)+256 < 262144` 的响应预算。
纯中继不会解密 blob；通过验证的恶意组成员仍能在本组发布任意密文。

HTTP 使用 `POST /api/relay`，Content-Type 为 `application/octet-stream`，
Content-Length 必填且不超过 262176；body 为一整帧，成功返回 200 和响应帧。
支持 HTTP/1.0、1.1，不接受 chunked、重复 Content-Length 或其他路由；
HTTP 格式/路由错误返回空 404，外层加密或签名错误仍静默关闭。

固定跨语言向量：`probe/tools/e2e-vector.json`（测试用组密钥、TOKEN、种子、派生密钥、
gid、slot、固定 nonce/blob 和 push/get 消息签名）。向量由独立 Node crypto 生成，
Python cryptography 与 C Monocypher 测试逐字节核对，供 CryptoKit 测试直接作为资源复用。
运行 `python3 probe/tools/test-probe.py probe/npulse-host` 会连同分组集成测试一起执行。

## Run

```
npulse -k 'shared-secret' -l 9000 -H 8080 -n router
npulse -k 'shared-secret' -u upstream.example:9000 -i 5 -n satellite
npulse -c /etc/npulse.conf
```

`-k` is required for normal direct/HTTP/upstream modes, not for pure shared
relays or `-R` with an explicit `-G`. `-l [addr:]port` is the encrypted direct listener (default
address `0.0.0.0`). `-H [addr:]port` is plain HTTP (default `127.0.0.1`), intended
**only behind a TLS reverse proxy**. `-u host:port` pushes upstream every `-i`
seconds (default 5); all three modes may be combined. IPv6 endpoints use
`[address]:port`. `-n` defaults to hostname. `-h` prints usage. At least one
listener or upstream is required. Config is unquoted `key=value`, with blank
lines and `#` comment lines; keys are `secret`, `listen`, `http`, `upstream`,
`interval`, `name`, `relay_listen` (`-S`), `token` (`-T`), `group_secret` (`-G`),
`relay_upstream` (`-R`); single-letter flag names are also accepted as keys.
CLI values override configuration regardless of order.
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
