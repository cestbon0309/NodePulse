#!/bin/sh
set +x
set -eu
umask 077

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }
help() {
    cat <<'HELP'
NodePulse 安装器（需要 root；POSIX sh / OpenWrt ash）
用法：sh install.sh [install|upgrade|uninstall|status] [选项]
  --yes                 无交互，使用环境变量与默认值；不自动删除配置
  --mode 1|2|3|4|5       直连 / HTTP+Nginx / 旧式上报 / E2E上报 / 纯共享中继
  --arch ARCH            x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel
  --full | --lite        完整版 / 精简版（精简版不能管理，也不能转发管理管道）
  --port PORT            直连或纯中继端口（默认 9000）
  --http-port PORT       HTTP 模式端口（默认 9001）；纯中继设置后开启 HTTP
  --upstream HOST:PORT   模式 3/4 上游（IPv6 用 [地址]:端口）
  --name NAME            节点名称
  --admin-keys HEX,...   启用管理；64 位 Ed25519 公钥，可逗号分隔，最多 32 个
  --also-relay           模式 2/3/4 同时开启 -l，接收旧式探针上报
  --purge               卸载时同时删除配置（默认保留）
  --help

对应环境变量：NPULSE_YES=1, NPULSE_MODE, NPULSE_ARCH, NPULSE_FLAVOR=full|lite,
NPULSE_PORT, NPULSE_HTTP_PORT, NPULSE_UPSTREAM, NPULSE_NAME, NPULSE_ADMIN_KEYS,
NPULSE_ADMIN=yes|no, NPULSE_ALSO_RELAY=yes|no, NPULSE_PURGE=yes|no。
密钥仅通过环境变量传入：NPULSE_SECRET, NPULSE_TOKEN, NPULSE_GROUP_SECRET。
未提供的密钥自动安全生成 32 个字符。已有上游时必须填写与上游匹配的密钥。
NPULSE_INTERVAL 默认 5 秒。NPULSE_VERSION=vX.Y.Z 固定版本，否则使用 latest。
NPULSE_MIRROR 覆盖下载目录（直接包含二进制、SHA256SUMS），例如：
https://github.com/cestbon0309/NodePulse/releases/download/v1.0.0
HTTP 镜像仅允许显式设置 NPULSE_INSECURE=1（存在中间人替换风险）。
NPULSE_INIT=systemd|procd 可覆盖自动检测；systemd 需 >=247（LoadCredential）。
NPULSE_ARM_FLOAT=hard|soft 可帮助 ARM ABI 检测；无法检测时需交互或 --arch。

交互从 /dev/tty 读取，支持 curl .../install.sh | sh；自动化请用 --yes。
配置 /etc/npulse/npulse.conf（0600），不使用 eval/source，不把密钥放入服务参数。
普通 systemd 服务使用 DynamicUser；启用管理后改用 root，拥有完整系统控制权。
OpenWrt procd 服务以 root 运行。摘要会显示密钥，请勿将摘要保存到公开日志。
测试：DESTDIR=/绝对路径 DRY_RUN=1 ... --yes --arch x86_64
测试仍真实下载并校验，但不运行二进制或调用服务管理器，允许非 root。
HELP
}

ACTION=install
YES=${NPULSE_YES:-0}
MODE=${NPULSE_MODE:-1}
ARCH=${NPULSE_ARCH:-}
FLAVOR=${NPULSE_FLAVOR:-}
PORT=${NPULSE_PORT:-9000}
HTTP_PORT=${NPULSE_HTTP_PORT:-}
UPSTREAM=${NPULSE_UPSTREAM:-}
NAME=${NPULSE_NAME:-$(uname -n)}
ADMIN_KEYS=${NPULSE_ADMIN_KEYS:-}
ADMIN=${NPULSE_ADMIN:-no}
ALSO_RELAY=${NPULSE_ALSO_RELAY:-no}
PURGE=${NPULSE_PURGE:-no}
INIT=${NPULSE_INIT:-}
SECRET=${NPULSE_SECRET:-}
TOKEN=${NPULSE_TOKEN:-}
GROUP=${NPULSE_GROUP_SECRET:-}
INTERVAL=${NPULSE_INTERVAL:-5}
DESTDIR=${DESTDIR:-}
DRY_RUN=${DRY_RUN:-0}
VERSION=${NPULSE_VERSION:-}
WORK=
ECHO_OFF=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        install|upgrade|uninstall|status) ACTION=$1; shift ;;
        --help|-h) help; exit 0 ;;
        --yes|-y) YES=1; shift ;;
        --full) FLAVOR=full; shift ;;
        --lite) FLAVOR=lite; shift ;;
        --also-relay) ALSO_RELAY=yes; shift ;;
        --purge) PURGE=yes; shift ;;
        --mode|--arch|--port|--http-port|--upstream|--name|--admin-keys)
            [ "$#" -ge 2 ] || fail "$1 缺少参数"
            case "$1" in
                --mode) MODE=$2 ;; --arch) ARCH=$2 ;; --port) PORT=$2 ;;
                --http-port) HTTP_PORT=$2 ;; --upstream) UPSTREAM=$2 ;;
                --name) NAME=$2 ;; --admin-keys) ADMIN_KEYS=$2 ;;
            esac
            shift 2 ;;
        *) fail "未知参数（使用 --help）" ;;
    esac
done
for setting in "$PURGE" "$ALSO_RELAY" "$ADMIN"; do case "$setting" in yes|no) ;; *) fail '开关须为 yes 或 no' ;; esac; done
case "$YES:$DRY_RUN" in 0:0|0:1|1:0|1:1) ;; *) fail 'NPULSE_YES 和 DRY_RUN 须为 0 或 1' ;; esac
if [ "$DRY_RUN" = 1 ]; then
    case "$DESTDIR" in /*) ;; *) fail 'DRY_RUN 必须指定绝对 DESTDIR' ;; esac
    [ "$DESTDIR" != / ] || fail 'DESTDIR 不能为 /'
else
    [ -z "$DESTDIR" ] || fail 'DESTDIR 仅用于 DRY_RUN=1'
    [ "$(id -u)" = 0 ] || fail '请以 root 运行（例如 sudo sh install.sh）'
    [ "$(uname -s)" = Linux ] || fail '仅支持 Linux；主机测试请使用 DESTDIR / DRY_RUN'
fi
case "$DESTDIR" in *'/../'*|*/..|*'/./'*|*/.|*'//'*) fail 'DESTDIR 必须为规范绝对路径' ;; esac
DESTDIR=${DESTDIR%/}
if [ "$DRY_RUN" = 1 ]; then
    [ -d "$DESTDIR" ] || fail '测试 DESTDIR 必须是已存在的目录'
    DESTDIR=$(CDPATH='' cd "$DESTDIR" && pwd -P)
    [ "$DESTDIR" != / ] || fail 'DESTDIR 不能指向根目录'
fi
CONFIG=$DESTDIR/etc/npulse/npulse.conf
STATE=$DESTDIR/etc/npulse/install.state
cleanup() {
    if [ "$ECHO_OFF" = 1 ]; then stty echo </dev/tty 2>/dev/null || :; fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup 0
trap 'exit 130' HUP INT TERM
ask() {
    ANSWER=$2
    [ "$YES" = 0 ] || return 0
    [ -r /dev/tty ] && [ -w /dev/tty ] || fail '没有交互终端，请使用 --yes 与环境变量'
    if [ "${3:-}" = secret ]; then
        stty -echo </dev/tty || fail '无法关闭终端回显'
        ECHO_OFF=1
    fi
    printf '%s ' "$1" >/dev/tty
    IFS= read -r response </dev/tty || fail '未读取到输入'
    if [ "$ECHO_OFF" = 1 ]; then stty echo </dev/tty; ECHO_OFF=0; printf '\n' >/dev/tty; fi
    if [ -n "$response" ]; then ANSWER=$response; fi
}
safe_value() {
    [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -le "${2:-1024}" ] || fail '配置字段过长'
    case "$1" in *'
'*|[[:space:]]*|*[[:space:]]) fail '配置字段不能含换行或首尾空白' ;; esac
    if printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then fail '配置字段不能含控制字符'; fi
}
port() { case "$1" in ''|*[!0-9]*|0*) fail '端口须为 1–65535（不含前导零）' ;; esac; [ "${#1}" -le 5 ] && [ "$1" -le 65535 ] || fail '端口超出范围'; }
random() {
    [ -r /dev/urandom ] || fail '缺少安全随机源 /dev/urandom'
    if command -v od >/dev/null 2>&1; then bytes=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    elif command -v hexdump >/dev/null 2>&1; then bytes=$(hexdump -v -n 16 -e '1/1 "%02x"' /dev/urandom)
    else fail '需要 od 或 hexdump 以读取安全随机数'; fi
    [ "${#bytes}" -eq 32 ] || fail '安全随机数生成失败'
    printf '%s' "$bytes"
}
elf_byte() {
    if command -v od >/dev/null 2>&1; then od -An -tu1 -j "$1" -N1 /bin/sh 2>/dev/null | tr -d ' '
    elif command -v hexdump >/dev/null 2>&1; then hexdump -v -s "$1" -n 1 -e '1/1 "%u"' /bin/sh 2>/dev/null
    fi
}
credentials() {
    ask "$1（留空保留已有值或自动生成；输入不回显）：" "$2" secret
    if [ -z "$ANSWER" ]; then ANSWER=$(random); fi
    [ "${#ANSWER}" -eq 32 ] || [ -n "$2" ] || printf '%s\n' '提示：使用自定义密钥。' >&2
    safe_value "$ANSWER"
}
detect_arch() {
    if [ -z "$ARCH" ]; then
        machine=$(uname -m)
        case "$machine" in
            x86_64|amd64) ARCH=x86_64 ;;
            i386|i486|i586|i686) ARCH=i386 ;;
            aarch64|arm64) ARCH=aarch64 ;;
            mips|mipsel|mipsle|mips32*)
                endian=$(elf_byte 5) || endian=
                case "$endian:$machine" in 1:*) ARCH=mipsel ;; 2:*) ARCH=mips ;; *:mipsel*|*:mipsle*) ARCH=mipsel ;; *) fail '无法检测 MIPS 字节序，请指定 --arch mips 或 mipsel' ;; esac ;;
            armv7|armv7l|armv8l)
                abi=${NPULSE_ARM_FLOAT:-}
                if [ -z "$abi" ]; then
                    flags=$(elf_byte 37) || flags=
                    case "$flags" in ''|*[!0-9]*) ;; *)
                        if [ "$((flags & 4))" -ne 0 ]; then abi=hard
                        elif [ "$((flags & 2))" -ne 0 ]; then abi=soft; fi ;;
                    esac
                fi
                if [ -z "$abi" ]; then
                    [ "$YES" = 0 ] || fail '无法确认 ARM 浮点 ABI；指定 --arch armv7 或 armv7-soft'
                    ask '无法检测 ARM ABI，请输入 hard（硬浮点）或 soft（软浮点）：' ''; abi=$ANSWER
                fi
                case "$abi" in hard) ARCH=armv7 ;; soft) ARCH=armv7-soft ;; *) fail 'ARM ABI 须为 hard 或 soft' ;; esac ;;
            *) fail '不支持此架构；支持列表见 --help' ;;
        esac
    fi
    case "$ARCH" in x86_64|i386|aarch64|armv7|armv7-soft|mips|mipsel) ;; *) fail '不支持的 --arch' ;; esac
}
detect_init() {
    if [ -z "$INIT" ]; then
        if [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ]; then INIT=procd
        elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
        else fail '未检测到 systemd/OpenWrt procd；测试可用 NPULSE_INIT + DESTDIR/DRY_RUN'; fi
    fi
    case "$INIT" in
        systemd) BIN=/usr/local/bin/npulse; UNIT=/etc/systemd/system/npulse.service ;;
        procd) BIN=/usr/bin/npulse; UNIT=/etc/init.d/npulse ;;
        *) fail 'NPULSE_INIT 须为 systemd 或 procd' ;;
    esac
}
service() {
    if [ "$DRY_RUN" = 1 ]; then printf '[DRY_RUN] %s %s\n' "$INIT" "$1"; return; fi
    if [ "$INIT" = systemd ]; then
        case "$1" in enable) systemctl daemon-reload; systemctl enable npulse ;; reload) systemctl daemon-reload ;; *) systemctl "$1" npulse ;; esac
    else
        case "$1" in reload) : ;; *) /etc/init.d/npulse "$1" ;; esac
    fi
}
load_state() {
    [ -f "$STATE" ] || fail '没有找到安装状态，请先 install'
    ARCH=; FLAVOR=; INIT=
    while IFS='=' read -r key value; do
        case "$key" in arch) ARCH=$value ;; flavor) FLAVOR=$value ;; init) INIT=$value ;; *) fail '安装状态无效' ;; esac
    done < "$STATE"
    [ -n "$ARCH" ] && [ -n "$INIT" ] || fail '安装状态不完整'
    detect_arch; detect_init
    case "$FLAVOR" in full|lite) ;; *) fail '安装状态版本类型无效' ;; esac
}
download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 180 "$1" -o "$2" 2>/dev/null || fail '下载失败，请检查版本、网络或镜像'
    elif command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -e '-T' -e '--timeout' >/dev/null; then
            wget -q -T 180 -O "$2" "$1" 2>/dev/null || fail '下载失败，请检查版本、网络或镜像'
        else
            wget -q -O "$2" "$1" 2>/dev/null || fail '下载失败，请检查版本、网络或镜像'
        fi
    else fail '需要 curl 或 wget'; fi
}
fetch_binary() {
    case "$VERSION" in ''|v[0-9]*) ;; *) fail 'NPULSE_VERSION 应形如 v1.0.0' ;; esac
    case "$VERSION" in *[!A-Za-z0-9._-]*) fail '版本含非法字符' ;; esac
    base=https://github.com/cestbon0309/NodePulse/releases
    if [ -n "$VERSION" ]; then base=$base/download/$VERSION; else base=$base/latest/download; fi
    base=${NPULSE_MIRROR:-$base}; base=${base%/}
    case "$base" in
        https://*) ;;
        http://*) [ "${NPULSE_INSECURE:-0}" = 1 ] || fail '拒绝 HTTP 镜像；仅可信测试可设置 NPULSE_INSECURE=1'
            printf '警告：NPULSE_INSECURE=1，HTTP 镜像可被中间人替换二进制及校验清单！\n' >&2 ;;
        *) fail '下载目录必须为 HTTPS URL' ;;
    esac
    asset=npulse-linux-$ARCH
    if [ "$FLAVOR" = lite ]; then asset=$asset-lite; fi
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/npulse-install.XXXXXX") || fail '无法创建临时目录'
    download "$base/SHA256SUMS" "$WORK/SHA256SUMS"
    download "$base/$asset" "$WORK/binary"
    expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name {print $1}' "$WORK/SHA256SUMS")
    [ "${#expected}" -eq 64 ] || fail 'SHA256SUMS 缺少唯一匹配项'
    case "$expected" in *[!0-9a-fA-F]*) fail '校验清单格式无效' ;; esac
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$WORK/binary")
    elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$WORK/binary")
    elif command -v openssl >/dev/null 2>&1; then actual=$(openssl dgst -sha256 "$WORK/binary"); actual=${actual##* }
    else fail '需要 sha256sum、shasum 或 openssl'; fi
    actual=${actual%% *}
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    [ "$actual" = "$expected" ] || fail 'SHA256 校验失败，未安装任何下载内容'
    printf '已校验 %s（%s）\n' "$asset" "${VERSION:-latest}"
}
replace_binary() {
    (umask 022; mkdir -p "$(dirname "$DESTDIR$BIN")")
    cp "$WORK/binary" "$DESTDIR$BIN.new"
    chmod 755 "$DESTDIR$BIN.new"
    mv -f "$DESTDIR$BIN.new" "$DESTDIR$BIN"
}
write_config() {
    mkdir -p "$DESTDIR/etc/npulse"
    chmod 700 "$DESTDIR/etc/npulse"
    {
        printf 'interval=%s\n' "$INTERVAL"
        if [ "$MODE" != 5 ]; then printf 'name=%s\n' "$NAME"; fi
        if [ -n "$SECRET" ]; then printf 'secret=%s\n' "$SECRET"; fi
        if [ -n "$TOKEN" ]; then printf 'token=%s\n' "$TOKEN"; fi
        if [ -n "$GROUP" ]; then printf 'group_secret=%s\n' "$GROUP"; fi
        if [ "$LISTEN" = yes ]; then printf 'listen=0.0.0.0:%s\n' "$PORT"; fi
        case "$MODE" in
            2) printf 'http=127.0.0.1:%s\n' "$HTTP_PORT" ;;
            3) printf 'upstream=%s\n' "$UPSTREAM" ;;
            4) printf 'relay_upstream=%s\n' "$UPSTREAM" ;;
            5) printf 'relay_listen=0.0.0.0:%s\n' "$PORT"
               if [ -n "$HTTP_PORT" ]; then printf 'http=127.0.0.1:%s\n' "$HTTP_PORT"; fi ;;
        esac
        if [ -n "$ADMIN_KEYS" ]; then printf 'admin_keys=%s\n' "$ADMIN_KEYS"; fi
    } > "$CONFIG.new"
    chmod 600 "$CONFIG.new"; mv "$CONFIG.new" "$CONFIG"
    printf 'arch=%s\nflavor=%s\ninit=%s\n' "$ARCH" "$FLAVOR" "$INIT" > "$STATE"
    chmod 600 "$STATE"
}
write_unit() {
    (umask 022; mkdir -p "$(dirname "$DESTDIR$UNIT")")
    if [ "$INIT" = procd ]; then
        cat > "$DESTDIR$UNIT" <<'PROCD'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1
start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/npulse -c /etc/npulse/npulse.conf
    procd_set_param respawn 3600 5 0
    procd_set_param file /etc/npulse/npulse.conf
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
reload_service() { stop; start; }
PROCD
        chmod 755 "$DESTDIR$UNIT"
        return
    fi
    {
        cat <<'UNIT'
[Unit]
Description=NodePulse
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
Restart=always
RestartSec=5
UMask=0077
UNIT
        if [ -n "$ADMIN_KEYS" ]; then
            printf 'User=root\nExecStart=/usr/local/bin/npulse -c /etc/npulse/npulse.conf\n'
        else
            cat <<'HARDEN'
DynamicUser=yes
LoadCredential=npulse.conf:/etc/npulse/npulse.conf
ExecStart=/usr/local/bin/npulse -c %d/npulse.conf
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictSUIDSGID=yes
LockPersonality=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
HARDEN
            if [ "$PRIVILEGED_PORT" = yes ]; then
                printf 'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE\n'
            else printf 'CapabilityBoundingSet=\n'; fi
        fi
        printf '\n[Install]\nWantedBy=multi-user.target\n'
    } > "$DESTDIR$UNIT"
    chmod 644 "$DESTDIR$UNIT"
}
summary() {
    printf '\nNodePulse 已安装：%s / %s；配置 /etc/npulse/npulse.conf\n' "$ARCH" "$FLAVOR"
    address=
    if command -v ip >/dev/null 2>&1; then
        address=$(ip -4 addr show scope global 2>/dev/null | awk '$1 == "inet" {split($2,a,"/"); print a[1]; exit}')
        if [ -z "$address" ]; then address=$(ip -6 addr show scope global 2>/dev/null | awk '$1 == "inet6" {split($2,a,"/"); print a[1]; exit}'); fi
    fi
    if [ -z "$address" ]; then address=$(uname -n); fi
    printf 'App 参考地址：%s（NAT 后请改用可达公网地址/域名，并配置端口转发）。\n' "$address"
    if [ "$LISTEN" = yes ]; then printf '直连 TCP 端口：%s；防火墙放行 TCP %s。\n' "$PORT" "$PORT"; fi
    case "$MODE" in
        2) printf 'App：HTTPS https://probe.example.com；放行 TCP 443，不开放 HTTP 后端端口。\n' ;;
        3) printf 'App：连接上游 %s；本机主动连出。\n' "$UPSTREAM" ;;
        4) printf 'App：中继服务器 TCP %s；本机主动连出。\n' "$UPSTREAM" ;;
        5) printf 'App：中继服务器 TCP，端口 %s；防火墙放行 TCP %s。\n' "$PORT" "$PORT" ;;
    esac
    if [ -n "$SECRET" ]; then printf '探针密钥：%s\n' "$SECRET"; fi
    if [ -n "$TOKEN" ]; then printf '中继令牌：%s\n' "$TOKEN"; fi
    if [ -n "$GROUP" ]; then printf '组密钥：%s\n' "$GROUP"; fi
    if [ "$MODE" = 5 ]; then printf '组密钥由各组自行生成，中继不需要也不应保存组密钥。\n'; fi
    if [ "$MODE" = 3 ] || [ "$MODE" = 4 ]; then printf '注意：上报使用的密钥/令牌必须与已有上游配置匹配。\n'; fi
    if [ "$INIT" = procd ]; then printf 'OpenWrt：服务以 root 运行。\n'; fi
    if [ -n "$ADMIN_KEYS" ]; then printf '警告：管理已启用，探针以 root 运行；授权设备可控制整台机器。\n'; fi
    if [ "$MODE" = 2 ] || { [ "$MODE" = 5 ] && [ -n "$HTTP_PORT" ]; }; then
        route=nodes; if [ "$MODE" = 5 ]; then route=relay; fi
        if [ "$MODE" = 5 ]; then printf 'App 也可使用中继服务器 HTTPS：https://probe.example.com；开放 TCP 443。\n'; fi
        printf '\nNginx server 示例（先设置域名并用 certbot 配置以下证书）：\n'
        cat <<NGINX
server {
    listen 443 ssl;
    server_name probe.example.com;
    ssl_certificate /etc/letsencrypt/live/probe.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/probe.example.com/privkey.pem;
    location = /api/$route {
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:$HTTP_PORT;
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header Host \$host;
    }
    location / { return 404; }
}
NGINX
        printf 'HTTPS 接入点不支持管理；需要管理时请保留 TCP 端口。\n'
    fi
}

if [ "$ACTION" != install ]; then
    load_state
    case "$ACTION" in
        status) service status; exit ;;
        upgrade)
            [ -f "$CONFIG" ] && [ -f "$DESTDIR$BIN" ] || fail '现有安装不完整'
            if [ "$FLAVOR" = lite ] && grep '^admin_keys=' "$CONFIG" >/dev/null; then fail '精简版配置不能包含管理密钥'; fi
            fetch_binary; replace_binary; service restart
            printf '升级完成；配置与服务权限未改变。\n'; exit ;;
        uninstall)
            service stop; service disable
            rm -f "$DESTDIR$BIN" "$DESTDIR$UNIT" "$STATE"
            service reload
            if [ "$PURGE" != yes ]; then ask '同时删除配置和密钥？[yes/no，默认 no]' no; PURGE=$ANSWER; fi
            if [ "$PURGE" != yes ]; then PURGE=no; fi
            if [ "$PURGE" = yes ]; then rm -f "$CONFIG"; rmdir "$DESTDIR/etc/npulse" 2>/dev/null || :; fi
            printf '已卸载；配置删除：%s。\n' "$PURGE"; exit ;;
    esac
fi

detect_arch; detect_init
[ ! -e "$CONFIG" ] && [ ! -e "$DESTDIR$BIN" ] && [ ! -e "$DESTDIR$UNIT" ] || fail '已有安装或配置；请使用 upgrade，或备份并卸载旧安装'
if [ "$INIT" = systemd ] && [ "$DRY_RUN" != 1 ]; then
    systemd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
    case "$systemd_version" in ''|*[!0-9]*) fail '无法检测 systemd 版本' ;; esac
    [ "$systemd_version" -ge 247 ] || fail '需要 systemd 247+，以安全加载 0600 配置'
fi
printf '请选择模式：\n1 直连探针（也可接收旧式上报）\n2 HTTP 探针 + Nginx\n3 上报到其他探针（旧式）\n4 推送到共享中继（端到端加密）\n5 纯共享中继服务器\n'
ask "模式 [默认 $MODE]：" "$MODE"; MODE=$ANSWER
case "$MODE" in 1|2|3|4|5) ;; *) fail '模式须为 1–5' ;; esac
LISTEN=no
if [ "$MODE" = 1 ]; then LISTEN=yes
elif [ "$MODE" != 5 ]; then
    ask "同时作为旧式中继（开启 -l 接收其他探针上报）？[yes/no，默认 $ALSO_RELAY]" "$ALSO_RELAY"; ALSO_RELAY=$ANSWER
    case "$ALSO_RELAY" in yes) LISTEN=yes ;; no) ;; *) fail '中继选项须为 yes 或 no' ;; esac
fi
if [ "$LISTEN" = yes ] || [ "$MODE" = 5 ]; then ask "TCP 监听端口 [默认 $PORT]：" "$PORT"; PORT=$ANSWER; port "$PORT"; fi
if [ "$MODE" = 2 ]; then
    ask "HTTP 回环端口 [默认 ${HTTP_PORT:-9001}]：" "${HTTP_PORT:-9001}"; HTTP_PORT=$ANSWER; port "$HTTP_PORT"
elif [ "$MODE" = 5 ]; then
    use_http=no; if [ -n "$HTTP_PORT" ]; then use_http=yes; fi
    ask "开启 HTTP /api/relay（仅回环）？[yes/no，默认 $use_http]" "$use_http"; use_http=$ANSWER
    case "$use_http" in yes) ask "HTTP 回环端口 [默认 ${HTTP_PORT:-9001}]：" "${HTTP_PORT:-9001}"; HTTP_PORT=$ANSWER; port "$HTTP_PORT" ;; no) HTTP_PORT= ;; *) fail 'HTTP 开关须为 yes 或 no' ;; esac
fi
if [ -n "$HTTP_PORT" ] && { [ "$LISTEN" = yes ] || [ "$MODE" = 5 ]; }; then [ "$PORT" != "$HTTP_PORT" ] || fail 'TCP 与 HTTP 端口不能相同'; fi
if [ "$MODE" = 3 ] || [ "$MODE" = 4 ]; then
    ask '上游地址 host:port（IPv6 用 [地址]:端口）：' "$UPSTREAM"; UPSTREAM=$ANSWER
    case "$UPSTREAM" in *:*) remote_port=${UPSTREAM##*:}; port "$remote_port"; [ -n "${UPSTREAM%:*}" ] || fail '上游主机不能为空' ;; *) fail '缺少上游 host:port' ;; esac
fi
if [ "$MODE" != 5 ]; then ask "节点名称 [默认 $NAME]：" "$NAME"; NAME=$ANSWER; fi
if [ "$LISTEN" = yes ] || [ "$MODE" = 2 ] || [ "$MODE" = 3 ]; then credentials '探针密钥（旧式上报需与上游一致）' "$SECRET"; SECRET=$ANSWER; else SECRET=; fi
if [ "$MODE" = 4 ] || [ "$MODE" = 5 ]; then credentials '中继访问令牌（推送端需与中继一致）' "$TOKEN"; TOKEN=$ANSWER; else TOKEN=; fi
if [ "$MODE" = 4 ]; then credentials '组密钥（仅可信组成员持有）' "$GROUP"; GROUP=$ANSWER; else GROUP=; fi
if [ -n "$ADMIN_KEYS" ]; then ADMIN=yes; fi
if [ "$MODE" != 5 ]; then ask "启用远程管理？[yes/no，默认 $ADMIN]（警告：root 级控制权）" "$ADMIN"; ADMIN=$ANSWER; fi
case "$ADMIN" in yes|no) ;; *) fail '管理开关须为 yes 或 no' ;; esac
if [ "$ADMIN" = yes ]; then
    [ "$MODE" != 5 ] || fail '纯中继不使用 -A；请选择 full 以转发管理管道'
    [ "$LISTEN" = yes ] || [ "$MODE" = 4 ] || fail '管理需要直连 -l 或共享中继 -R'
    ask '粘贴 Ed25519 公钥（64 位十六进制，多个用逗号分隔）：' "$ADMIN_KEYS"; ADMIN_KEYS=$ANSWER
    printf '%s\n' "$ADMIN_KEYS" | awk -F, 'NF < 1 || NF > 32 {exit 1} {for(i=1;i<=NF;i++) if(length($i)!=64 || $i ~ /[^0-9a-fA-F]/) exit 1}' || fail '管理公钥格式无效'
    ADMIN_KEYS=$(printf '%s' "$ADMIN_KEYS" | tr 'A-F' 'a-f')
else ADMIN_KEYS=; fi
if [ -z "$FLAVOR" ]; then
    FLAVOR=full
    case "$ARCH" in mips|mipsel) FLAVOR=lite ;; esac
    space_path=$DESTDIR$(dirname "$BIN")
    while [ ! -d "$space_path" ]; do space_path=$(dirname "$space_path"); done
    free_kb=$(df -Pk "$space_path" | awk 'END {print $4}')
    case "$free_kb" in ''|*[!0-9]*) ;; *) if [ "$free_kb" -lt 16384 ]; then FLAVOR=lite; fi ;; esac
    if [ -n "$ADMIN_KEYS" ]; then FLAVOR=full; fi
fi
printf 'full 支持管理；lite 更小但无管理/实时管道（纯中继要转发管理也必须 full）。\n'
ask "构建类型 full/lite [默认 $FLAVOR]：" "$FLAVOR"; FLAVOR=$ANSWER
case "$FLAVOR" in full) ;; lite) [ -z "$ADMIN_KEYS" ] || fail 'lite 不允许启用管理，请选择 full' ;; *) fail '构建类型须为 full 或 lite' ;; esac
for value in "$NAME" "$UPSTREAM" "$SECRET" "$TOKEN" "$GROUP"; do safe_value "$value"; done
safe_value "$ADMIN_KEYS" 2080
case "$INTERVAL" in ''|*[!0-9]*|0*) fail 'NPULSE_INTERVAL 须为 1–86400' ;; esac
[ "${#INTERVAL}" -le 5 ] && [ "$INTERVAL" -le 86400 ] || fail '间隔超出范围'
PRIVILEGED_PORT=no
if { [ "$LISTEN" = yes ] || [ "$MODE" = 5 ]; } && [ "$PORT" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
if [ -n "$HTTP_PORT" ] && [ "$HTTP_PORT" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
fetch_binary
replace_binary; write_config; write_unit
service enable; service start
printf '服务已启用并启动。\n'
summary
