# Installer reference / 安装器参考

Run as root on Linux or OpenWrt. Interactive input comes from `/dev/tty`, including
when the script is piped into `sh`. The first prompt selects `1 中文 / 2 English`;
the default follows `LC_ALL`, then `LANG` (`zh*` → Chinese, otherwise English).
`--lang zh|en` or `NPULSE_LANG` skips that prompt; the flag overrides the environment.
`--yes` never prompts and uses the selected language for diagnostics and summaries.

在 Linux / OpenWrt 的 root shell 运行。交互从 `/dev/tty` 读取，支持管道安装。
首次选择中文或英文；`--lang` 优先于 `NPULSE_LANG`，然后按 `LC_ALL` / `LANG` 默认。
`--yes` 不提问；节点名称默认使用主机名，可用 `--name` / `NPULSE_NAME` 修改。

| Mode / 模式 | Use / 用途 | Network / 网络 |
|---|---|---|
| 1 | Direct / 公网直连 | TCP 9000 by default / 默认 9000 |
| 2 | HTTP + your Nginx / 已有 HTTPS | Public 443; backend loopback only / 后端仅回环 |
| 3 | Shared-relay publisher / NAT、家宽、路由器 | Outbound to relay / 仅主动连出 |
| 4 | Relay server only / 纯共享中继 | Public relay TCP port / 公网中继端口 |

Mode 1 can also host a relay in the **same process**: answer yes to the relay
question (default no), then accept `PORT+1`, or use `--also-relay PORT`.
Ports must differ. The summary prints both ports, relay address/password and next
pairing steps. Allow both ports in local firewalls **and cloud security groups**.

模式 1 可同时提供共享中继：默认不开启，选 yes 后默认端口为直连端口加一；也可用
`--also-relay PORT`。单进程、单配置，两个端口必须不同。本机管理走直连，下游管理走中继管道。

## Unattended / 自动化

```sh
sh install.sh --yes --lang en --mode 1 --public-ip auto --also-relay 9001
NPULSE_TOKEN='relay-token' NPULSE_GROUP_SECRET='random-group-secret' \
  sh install.sh --yes --lang zh --mode 3 --upstream relay.example:9001 --name router
sh install.sh upgrade --yes --lang en
sh install.sh status --lang en
sh install.sh uninstall --yes          # preserve configuration / 保留配置
sh install.sh uninstall --yes --purge  # delete it explicitly / 明确删除
```

Secrets: `NPULSE_SECRET`, `NPULSE_TOKEN`, `NPULSE_GROUP_SECRET`. Missing values are
securely generated. **Existing relay tokens/group keys must match your deployment.**
Interactive Enter keeps or generates a key without changing terminal echo; manual
entry hides input if possible, otherwise warns and reads visibly. Supplied keys
skip the prompt. Summaries contain keys: do not publish transcripts from real hosts.

密钥通过上述环境变量传入；首次自动生成高熵密钥。已有中继或组必须填写一致的令牌/组密钥。
回车保留或生成密钥，不依赖 stty；自定义输入无法关闭回显时会明确警告后继续。
**真实安装摘要包含密钥，不要公开日志。**

`--full` is the default everywhere. `--lite` saves space but omits administration,
live pipes, pairing/QR and egress discovery. `install.sh pair` temporarily downloads
and SHA256-verifies the same-architecture full build, then removes it; lite is unchanged.
Relays forwarding administration need full, too.

`--admin-via-pair` requires full and two-sided consent: enable administration on
the phone, compare SAS, then independently authorize root access on the server.
Until successful authorization the systemd service remains DynamicUser, with no
admin allowlist. `--admin-keys HEX,...` directly installs an existing allowlist instead.

默认 full；lite 无管理/管道、内置配对/二维码和出口发现。lite 配对临时下载校验 full，
不替换原服务。管理转发中继也须 full。手机配对授权须在手机及服务器分别确认，成功前不启用管理。

## Public IP, compatibility / 公网地址与兼容性

`--public-ip ADDR|auto` is advertised for pairing, not assumed to be on a local NIC.
Cloud external IPs use wildcard listening unless locally present; `--bind` overrides
that. Confirmed public addresses persist separately in `/etc/npulse/public-ip`.
Only `--open-firewall` explicitly authorizes automatic firewall changes.

公网地址可为云外部 IP，不强行绑定不存在的网卡地址；确认后保存供后续配对复用。
本机放行后仍须配置云安全组。模式 3 无需公网 IP。

Legacy `upstream=` / `u=` configs are rejected **before download/replacement/restart**.
Back up and reinstall using mode 3 / `relay_upstream` (shared E2E relay); no silent migration.
旧式配置须先备份，再选择共享中继重新安装；升级失败不会破坏正在运行的服务。

POSIX sh / BusyBox ash; systemd >=247 or procd. Required basic applets are checked
by name. Secure randomness: od or hexdump; hashing: sha256sum, shasum or openssl;
downloads: curl or wget; secure temporary directories require mktemp. Public-IP
discovery uses bounded requests; missing dd on wget-only hosts falls back to manual
input. No head/timeout dependency. Missing stty is nonfatal.

`sh install.sh --help --lang en` lists every flag/environment variable, including
version pinning (`NPULSE_VERSION`), HTTPS mirrors (`NPULSE_MIRROR`) and ARM ABI hints.
An HTTP mirror needs explicit `NPULSE_INSECURE=1` and is unsafe outside isolated tests.
`DESTDIR=/existing/absolute/path DRY_RUN=1` generates fixtures without executing
downloaded binaries or calling real service/firewall managers.
