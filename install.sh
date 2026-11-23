#!/bin/sh
set +x
set -eu
umask 077

DISPLAY_LANG=${NPULSE_LANG:-}
LANG_EXPLICIT=no
if [ -n "$DISPLAY_LANG" ]; then LANG_EXPLICIT=yes
else case "${LC_ALL:-${LANG:-}}" in zh*) DISPLAY_LANG=zh ;; *) DISPLAY_LANG=en ;; esac; fi
msg() {
    if [ "${DISPLAY_LANG:-${NPULSE_LANG:-en}}" = zh ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}
say() {
    format=$(msg "$1" "$2"); shift 2
    # shellcheck disable=SC2059
    printf "$format" "$@"
}
fail() { say '错误：%s\n' 'Error: %s\n' "$*" >&2; exit 1; }
help() {
    if [ "$DISPLAY_LANG" = en ]; then
        cat <<'HELP'
NodePulse installer (root required; POSIX sh / OpenWrt ash)
Usage: sh install.sh [install|upgrade|uninstall|status|pair] [options]
  --lang zh|en          Display language (NPULSE_LANG; otherwise LC_ALL/LANG)
  --yes                Unattended: use environment/defaults; never purge implicitly
  --mode 1|2|3|4        Direct / HTTP+Nginx / E2E publisher / relay-only
  --arch ARCH          x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel
  --full | --lite      Full / compact (lite cannot administer or forward admin pipes)
  --public-ip IP|auto  Advertised public IP (cloud external/elastic IP); HTTPS discovery
  --port PORT          Direct or relay-only port (default 9000)
  --bind IP            Override listener; external cloud IPs default to wildcard bind
  --open-firewall      Consent to TCP firewall rules (not executed in DRY_RUN)
  --http-port PORT     HTTP loopback port (default 9001); enables HTTP in relay mode
  --upstream HOST:PORT Mode 3 shared relay (IPv6: [address]:port)
  --name NAME          Node name
  --admin-keys HEX,... Allow administration: up to 32 comma-separated Ed25519 keys
  --admin-via-pair     Use full and pair with phone; both sides must authorize admin
  --also-relay PORT    Mode 1: same process also relays; use a distinct port
  --purge              Remove configuration on uninstall (otherwise preserved)
  --force              Upgrade even if already at the target release
  --help

Environment: NPULSE_YES=1, NPULSE_LANG=zh|en, NPULSE_MODE, NPULSE_ARCH,
NPULSE_FLAVOR=full|lite, NPULSE_PORT, NPULSE_HTTP_PORT, NPULSE_UPSTREAM,
NPULSE_NAME, NPULSE_ADMIN_KEYS, NPULSE_ADMIN=yes|no|pair (pair: --admin-via-pair),
NPULSE_ALSO_RELAY=PORT, NPULSE_PURGE=yes|no, NPULSE_BIND, NPULSE_OPEN_FIREWALL=yes,
NPULSE_PUBLIC_IP (advertised for pairing/QR; need not exist on a local interface).
pair stops the service, runs SAS pairing, saves explicitly authorized admin keys,
then restarts. Keys use environment only: NPULSE_SECRET, NPULSE_TOKEN,
NPULSE_GROUP_SECRET. Missing keys are securely generated (32 characters);
publishers must supply the relay token and their existing group's shared key.
NPULSE_INTERVAL defaults to 5 seconds. NPULSE_VERSION=vX.Y.Z pins a release;
otherwise latest. NPULSE_MIRROR overrides the asset/SHA256SUMS directory.
HTTP mirrors require NPULSE_INSECURE=1 (man-in-the-middle risk).
NPULSE_INIT=systemd|procd overrides detection; systemd >=247 (LoadCredential).
NPULSE_ARM_FLOAT=hard|soft helps ARM ABI detection; otherwise use --arch.

Interactive input uses /dev/tty (supports curl .../install.sh | sh).
Automation: --yes. Config: /etc/npulse/npulse.conf (0600); no eval/source,
no secrets in service arguments. systemd normally uses DynamicUser; administration
runs as root with full control. OpenWrt procd runs as root. Summaries show keys:
never publish the output. Test: DESTDIR=/absolute/path DRY_RUN=1 ... --yes --arch x86_64
Tests still download/verify, but never run the probe or service manager; non-root OK.
HELP
    else
    cat <<'HELP'
NodePulse 安装器（需要 root；POSIX sh / OpenWrt ash）
用法：sh install.sh [install|upgrade|uninstall|status|pair] [选项]
  --lang zh|en          显示语言（NPULSE_LANG；否则按 LC_ALL/LANG 选择）
  --yes                 无交互，使用环境变量与默认值；不自动删除配置
  --mode 1|2|3|4         直连 / HTTP+Nginx / E2E上报 / 纯共享中继
  --arch ARCH            x86_64,i386,aarch64,armv7,armv7-soft,mips,mipsel
  --full | --lite        完整版 / 精简版（精简版不能管理，也不能转发管理管道）
  --public-ip ADDR|auto  公网配对地址（云外部/弹性 IP）；auto 通过 HTTPS 查询
  --port PORT            直连或纯中继端口（默认 9000）
  --bind ADDR            显式覆盖监听地址；云外部 IP 不在本机时默认通配监听
  --open-firewall        同意为直连 TCP 端口添加防火墙规则（DRY_RUN 不执行）
  --http-port PORT       HTTP 模式端口（默认 9001）；纯中继设置后开启 HTTP
  --upstream HOST:PORT   模式 3 共享中继（IPv6 用 [地址]:端口）
  --name NAME            节点名称
  --admin-keys HEX,...   启用管理；64 位 Ed25519 公钥，可逗号分隔，最多 32 个
  --admin-via-pair      使用 full 并发起手机配对；仅在双方明确授权后启用管理
  --also-relay PORT      模式 1 同一进程同时提供共享中继（端口须与直连不同）
  --purge               卸载时同时删除配置（默认保留）
  --force               已是目标版本时仍强制升级
  --help

对应环境变量：NPULSE_YES=1, NPULSE_MODE, NPULSE_ARCH, NPULSE_FLAVOR=full|lite,
NPULSE_PORT, NPULSE_HTTP_PORT, NPULSE_UPSTREAM, NPULSE_NAME, NPULSE_ADMIN_KEYS,
NPULSE_ADMIN=yes|no|pair（pair 等价 --admin-via-pair）, NPULSE_ALSO_RELAY=PORT, NPULSE_PURGE=yes|no。
NPULSE_BIND 与 --bind 等价；NPULSE_OPEN_FIREWALL=yes 与 --open-firewall 等价。
NPULSE_PUBLIC_IP 与 --public-ip 等价；公网地址用于配对/二维码，不要求配置在本机网卡上。
pair 停止服务、临时运行 SAS 配对、保存明确授权的管理公钥后重启服务。
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
    fi
}

ACTION=install
YES=${NPULSE_YES:-0}
MODE=${NPULSE_MODE:-1}
ARCH=${NPULSE_ARCH:-}
FLAVOR=${NPULSE_FLAVOR:-}
PORT=${NPULSE_PORT:-9000}
BIND=${NPULSE_BIND:-}
PUBLIC_IP=${NPULSE_PUBLIC_IP:-}
OPEN_FIREWALL=${NPULSE_OPEN_FIREWALL:-no}
HTTP_PORT=${NPULSE_HTTP_PORT:-}
UPSTREAM=${NPULSE_UPSTREAM:-}
NAME=${NPULSE_NAME:-}
ADMIN_KEYS=${NPULSE_ADMIN_KEYS:-}
ADMIN=${NPULSE_ADMIN:-no}
ADMIN_VIA_PAIR=no
ALSO_RELAY=${NPULSE_ALSO_RELAY:-}
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
PAIR_STOPPED=0
SHOW_HELP=0
FORCE=0
LINK=0
INSTALLED_VERSION=unknown
TARGET_VERSION=unknown
SKIP=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        install|upgrade|uninstall|status|pair) ACTION=$1; shift ;;
        --help|-h) SHOW_HELP=1; shift ;;
        --yes|-y) YES=1; shift ;;
        --full) FLAVOR=full; shift ;;
        --lite) FLAVOR=lite; shift ;;
        --purge) PURGE=yes; shift ;;
        --force) FORCE=1; shift ;;
        --open-firewall) OPEN_FIREWALL=yes; shift ;;
        --admin-via-pair) ADMIN=pair; shift ;;
        --lang|--mode|--arch|--port|--bind|--public-ip|--http-port|--upstream|--name|--admin-keys|--also-relay)
            [ "$#" -ge 2 ] || fail "$(msg "$1 缺少参数" "$1 requires a value")"
            case "$1" in
                --lang) DISPLAY_LANG=$2; LANG_EXPLICIT=yes ;;
                --mode) MODE=$2 ;; --arch) ARCH=$2 ;; --port) PORT=$2 ;;
                --bind) BIND=$2 ;;
                --public-ip) PUBLIC_IP=$2 ;;
                --also-relay) ALSO_RELAY=$2 ;;
                --http-port) HTTP_PORT=$2 ;; --upstream) UPSTREAM=$2 ;;
                --name) NAME=$2 ;; --admin-keys) ADMIN_KEYS=$2 ;;
            esac
            shift 2 ;;
        *) fail "$(msg "未知参数（使用 --help）" "Unknown option (use --help)")" ;;
    esac
done
case "$DISPLAY_LANG" in zh|en) ;; *) fail 'NPULSE_LANG / --lang: 请选择 zh 或 en / choose zh or en' ;; esac
if [ "$SHOW_HELP" = 1 ]; then help; exit 0; fi
case "$ADMIN" in yes|no) ;; pair) ADMIN=yes; ADMIN_VIA_PAIR=yes ;; *) fail "$(msg 'NPULSE_ADMIN 须为 yes、no 或 pair' 'NPULSE_ADMIN must be yes, no or pair')" ;; esac
if [ "$ADMIN_VIA_PAIR" = yes ] && [ -n "$ADMIN_KEYS" ]; then fail "$(msg '手机配对授权不能同时指定 --admin-keys / NPULSE_ADMIN_KEYS' 'Phone pairing authorization cannot be combined with --admin-keys / NPULSE_ADMIN_KEYS')"; fi
for setting in "$PURGE" "$OPEN_FIREWALL"; do case "$setting" in yes|no) ;; *) fail "$(msg '开关须为 yes 或 no' 'Switches must be yes or no')" ;; esac; done
case "$YES:$DRY_RUN" in 0:0|0:1|1:0|1:1) ;; *) fail "$(msg 'NPULSE_YES 和 DRY_RUN 须为 0 或 1' 'NPULSE_YES and DRY_RUN must be 0 or 1')" ;; esac
for utility in awk cat chmod cp dirname grep id mkdir mv rm tr uname wc; do
    command -v "$utility" >/dev/null 2>&1 || fail "$(msg "缺少必需命令 ${utility}；请安装对应工具或启用 BusyBox applet" "Required command $utility is missing; install it or enable the BusyBox applet")"
done
NAME=${NAME:-$(uname -n)}
if [ "$DRY_RUN" = 1 ]; then
    case "$DESTDIR" in /*) ;; *) fail "$(msg 'DRY_RUN 必须指定绝对 DESTDIR' 'DRY_RUN requires an absolute DESTDIR')" ;; esac
    [ "$DESTDIR" != / ] || fail "$(msg 'DESTDIR 不能为 /' 'DESTDIR must not be /')"
else
    [ -z "$DESTDIR" ] || fail "$(msg 'DESTDIR 仅用于 DRY_RUN=1' 'DESTDIR is only supported with DRY_RUN=1')"
    [ "$(id -u)" = 0 ] || fail "$(msg '请以 root 运行（例如 sudo sh install.sh）' 'Run as root (for example sudo sh install.sh)')"
    [ "$(uname -s)" = Linux ] || fail "$(msg '仅支持 Linux；主机测试请使用 DESTDIR / DRY_RUN' 'Linux only; use DESTDIR / DRY_RUN for host tests')"
fi
case "$DESTDIR" in *'/../'*|*/..|*'/./'*|*/.|*'//'*) fail "$(msg 'DESTDIR 必须为规范绝对路径' 'DESTDIR must be a canonical absolute path')" ;; esac
DESTDIR=${DESTDIR%/}
if [ "$DRY_RUN" = 1 ]; then
    [ -d "$DESTDIR" ] || fail "$(msg '测试 DESTDIR 必须是已存在的目录' 'Test DESTDIR must be an existing directory')"
    DESTDIR=$(CDPATH='' cd "$DESTDIR" && pwd -P)
    [ "$DESTDIR" != / ] || fail "$(msg 'DESTDIR 不能指向根目录' 'DESTDIR must not resolve to the root directory')"
fi
CONFIG=$DESTDIR/etc/npulse/npulse.conf
STATE=$DESTDIR/etc/npulse/install.state
cleanup() {
    if [ "$PAIR_STOPPED" = 1 ]; then
        service start || say '警告：恢复服务失败，请手动启动 npulse。\n' 'Warning: service recovery failed; start npulse manually.\n' >&2
        if [ "$ADMIN_VIA_PAIR" = yes ] && [ -z "$ADMIN_KEYS" ]; then say '管理尚未启用；请稍后运行 sh install.sh pair 完成手机及服务器的管理授权。\n' 'Administration is not enabled; run sh install.sh pair later to authorize it on both phone and server.\n' >&2; fi
    fi
    if [ "$ECHO_OFF" = 1 ]; then stty echo </dev/tty 2>/dev/null || :; fi
    if [ -n "$WORK" ]; then rm -rf "$WORK"; fi
}
trap cleanup 0
trap 'exit 130' HUP INT TERM
ask() {
    ANSWER=$2
    [ "$YES" = 0 ] || return 0
    [ -r /dev/tty ] && [ -w /dev/tty ] || fail "$(msg '没有交互终端，请使用 --yes 与环境变量' 'No interactive terminal; use --yes and environment variables')"
    if [ "${3:-}" = secret ]; then
        if command -v stty >/dev/null 2>&1 && stty -echo </dev/tty 2>/dev/null; then
            ECHO_OFF=1
        else
            say '警告：无法关闭终端回显，输入将会显示在屏幕上；请勿让旁人查看或录屏。\n' 'Warning: terminal echo cannot be disabled; input will be visible. Avoid onlookers and screen recording.\n' >/dev/tty
        fi
    fi
    printf '%s ' "$1" >/dev/tty
    IFS= read -r response </dev/tty || fail "$(msg '未读取到输入' 'Could not read input')"
    if [ "$ECHO_OFF" = 1 ]; then
        if stty echo </dev/tty 2>/dev/null; then ECHO_OFF=0
        else say '警告：无法恢复终端回显，请运行 stty echo。\n' 'Warning: could not restore terminal echo; run stty echo.\n' >/dev/tty; fi
        printf '\n' >/dev/tty
    fi
    if [ -n "$response" ]; then ANSWER=$response; fi
}
if [ "$YES" = 0 ] && [ "$LANG_EXPLICIT" = no ]; then
    language_default=2; if [ "$DISPLAY_LANG" = zh ]; then language_default=1; fi
    ask "语言 / Language: 1 中文 / 2 English [默认 / default $language_default]:" "$language_default"
    case "$ANSWER" in 1|zh) DISPLAY_LANG=zh ;; 2|en) DISPLAY_LANG=en ;; *) fail '请选择 1 或 2 / Choose 1 or 2' ;; esac
fi
safe_value() {
    [ "$(printf '%s' "$1" | wc -c | tr -d ' ')" -le "${2:-1024}" ] || fail "$(msg '配置字段过长' 'Configuration field is too long')"
    case "$1" in *'
'*|[[:space:]]*|*[[:space:]]) fail "$(msg '配置字段不能含换行或首尾空白' 'Configuration fields cannot contain newlines or leading/trailing whitespace')" ;; esac
    if printf '%s' "$1" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then fail "$(msg '配置字段不能含控制字符' 'Configuration fields cannot contain control characters')"; fi
}
port() { case "$1" in ''|*[!0-9]*|0*) fail "$(msg '端口须为 1–65535（不含前导零）' 'Ports must be 1-65535 without leading zeros')" ;; esac; [ "${#1}" -le 5 ] && [ "$1" -le 65535 ] || fail "$(msg '端口超出范围' 'Port is out of range')"; }
public_addresses() {
    addresses=
    if command -v ip >/dev/null 2>&1; then addresses=$(ip -o addr show 2>/dev/null || :); fi
    if [ -z "$addresses" ] && command -v ifconfig >/dev/null 2>&1; then addresses=$(ifconfig -a 2>/dev/null || :); fi
    printf '%s\n' "$addresses" | awk '
    function public(a, p,n,i,s) {
        if (index(a, ":")) {
            s=tolower(a)
            if (s=="::" || s=="::1" || s=="0:0:0:0:0:0:0:1" || s ~ /^fe[89ab]/ || s ~ /^f[cd]/ || s ~ /^ff/) return 0
            if (s ~ /^::ffff:/) {sub(/^::ffff:/,"",s); return public(s)}
            return 1
        }
        n=split(a,p,"."); if(n!=4) return 0
        for(i=1;i<=4;i++) if(p[i] !~ /^[0-9]+$/ || p[i]+0>255) return 0
        return !(p[1]==0 || p[1]==10 || p[1]==127 || p[1]>=224 || (p[1]==172 && p[2]>=16 && p[2]<=31) || (p[1]==192 && p[2]==168) || (p[1]==100 && p[2]>=64 && p[2]<=127) || (p[1]==169 && p[2]==254))
    }
    /^[^ \t]/ {iface=$1; sub(/:$/,"",iface)}
    $1 ~ /^[0-9]+:$/ {iface=$2; sub(/:$/,"",iface); sub(/@.*/,"",iface)}
    {for(i=1;i<=NF;i++) if($i=="inet" || $i=="inet6") {
        a=$(i+1); sub(/^addr:/,"",a); sub(/\/.*/,"",a); sub(/%.*/,"",a)
        if(public(a) && !seen[a]++) print a,iface
    }}'
}
valid_public_ip() {
    printf '%s\n' "$1" | awk '
    function hex(s, i,v) {v=0; for(i=1;i<=length(s);i++) v=v*16+index("0123456789abcdef",substr(s,i,1))-1; return v}
    function groups(s, a,n,i) {
        if(s=="") return 0
        n=split(s,a,":"); for(i=1;i<=n;i++) if(length(a[i])<1 || length(a[i])>4 || a[i] ~ /[^0-9a-f]/) return -100
        return n
    }
    function public(s, a,n,i,b,l,r) {
        s=tolower(s)
        if(index(s,":")) {
            if(index(s,":")!=5 || s !~ /^[23][0-9a-f]*:/ || s ~ /[^0-9a-f:]/) return 0
            if(index(s,"::")) {n=split(s,b,"::"); if(n!=2) return 0; l=groups(b[1]); r=groups(b[2]); if(l<0 || r<0 || l+r>=8) return 0}
            else if(groups(s)!=8) return 0
            split(s,a,":"); return !(hex(a[1])==8193 && hex(a[2])==3512)
        }
        n=split(s,a,"."); if(n!=4) return 0
        for(i=1;i<=4;i++) if(a[i] !~ /^[0-9]+$/ || length(a[i])>3 || a[i]+0>255 || (length(a[i])>1 && substr(a[i],1,1)=="0")) return 0
        return !(a[1]==0 || a[1]==10 || a[1]==127 || a[1]>=224 || (a[1]==172 && a[2]>=16 && a[2]<=31) || (a[1]==192 && (a[2]==168 || (a[2]==0 && (a[3]==0 || a[3]==2)))) || (a[1]==100 && a[2]>=64 && a[2]<=127) || (a[1]==169 && a[2]==254) || (a[1]==198 && (a[2]==18 || a[2]==19 || (a[2]==51 && a[3]==100))) || (a[1]==203 && a[2]==0 && a[3]==113))
    }
    {if(NR!=1 || !public($0)) bad=1} END {exit (NR!=1 || bad)}'
}
discover_public_ip() {
    for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://api6.ipify.org; do
        if command -v curl >/dev/null 2>&1; then
            family=-4; if [ "$url" = https://api6.ipify.org ]; then family=-6; fi
            found=$(curl "$family" -fsS --connect-timeout 2 --max-time 4 --max-filesize 128 "$url" 2>/dev/null) || found=
        elif command -v wget >/dev/null 2>&1; then
            command -v dd >/dev/null 2>&1 || return 1
            wget_help=$(wget --help 2>&1 || :)
            printf '%s' "$wget_help" | grep -e '-T' -e '--timeout' >/dev/null || return 1
            set --
            case "$wget_help" in *--tries*|*'-t '*) set -- -t 1 ;; esac
            family=
            if printf '%s' "$wget_help" | grep -e '-4' >/dev/null; then
                family=-4; if [ "$url" = https://api6.ipify.org ]; then family=-6; fi
            fi
            found=$(wget ${family:+"$family"} -q -T 4 "$@" -O - "$url" 2>/dev/null | dd bs=1 count=129 2>/dev/null) || found=
        else return 1; fi
        if [ "$url" != https://api6.ipify.org ]; then case "$found" in *:*) continue ;; esac; fi
        if valid_public_ip "$found"; then printf '%s' "$found"; return 0; fi
    done
    return 1
}
resolve_public_ip() {
    if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = auto ]; then
        PUBLIC_IP=$(discover_public_ip) || PUBLIC_IP=
        if [ -z "$PUBLIC_IP" ]; then say '公网 IP 查询失败，请手动填写云控制台的外部/弹性 IP。\n' 'Public IP lookup failed; enter the external/elastic IP from your cloud console.\n'; fi
    fi
    if [ "$YES" = 0 ]; then
        ask "$(msg "公网 IP（留空确认 ${PUBLIC_IP}，或输入其他公网 IP）：" "Public IP (Enter to confirm $PUBLIC_IP, or enter another public IP):")" "$PUBLIC_IP"; PUBLIC_IP=$ANSWER
    fi
    valid_public_ip "$PUBLIC_IP" || fail "$(msg '请输入有效公网 IPv4/IPv6；可使用 --public-ip ADDR' 'Enter a valid public IPv4/IPv6 address; you can use --public-ip ADDR')"
}
persist_public_ip() {
    printf '%s\n' "$PUBLIC_IP" > "$DESTDIR/etc/npulse/public-ip.new"
    chmod 600 "$DESTDIR/etc/npulse/public-ip.new"
    mv "$DESTDIR/etc/npulse/public-ip.new" "$DESTDIR/etc/npulse/public-ip"
}
select_bind() {
    candidates=$(public_addresses)
    if [ "$YES" = 0 ]; then
        if [ -n "$candidates" ]; then say '网卡地址提示（不代表外部可达）：\n%s\n' 'NIC address hint (not proof of external reachability):\n%s\n' "$candidates"; fi
        ask "$(msg '这台机器有公网 IP 吗？（云服务器的外部 IP/弹性 IP 也算）[Y/n]' 'Does this machine have a public IP (including a cloud external/elastic IP)? [Y/n]')" y
        case "$ANSWER" in
            y|Y|yes|YES) ;;
            n|N|no|NO)
                say '没有公网 IP 时，外网手机无法直连；推荐共享中继（模式 3），无需公网 IP。\n' 'Without a public IP, phones outside your network cannot connect directly. Recommended: shared-relay publisher (mode 3), no public IP needed.\n'
                ask "$(msg '切换到共享中继模式 3，或输入 1 仍使用直连？[3/1，默认 3]' 'Switch to shared-relay mode 3, or enter 1 to keep direct mode? [3/1, default 3]')" 3
                case "$ANSWER" in 3) MODE=3; LISTEN=no; BIND=; PUBLIC_IP= ;; 1) PUBLIC_IP=; BIND=${BIND:-0.0.0.0} ;; *) fail "$(msg '请选择 3 或 1' 'Choose 3 or 1')" ;; esac
                return ;;
            *) fail "$(msg '请输入 y 或 n' 'Enter y or n')" ;;
        esac
        resolve_public_ip
    elif [ -n "$PUBLIC_IP" ]; then resolve_public_ip
    fi
    if [ -n "$BIND" ]; then return; fi
    BIND=0.0.0.0
    if [ -n "$PUBLIC_IP" ]; then
        case "$PUBLIC_IP" in *:*) BIND=:: ;; esac
        if printf '%s\n' "$candidates" | awk -v ip="$PUBLIC_IP" 'tolower($1)==tolower(ip) {found=1} END {exit !found}'; then BIND=$PUBLIC_IP; fi
    fi
}
bind_endpoint() {
    case "$BIND" in *:*) printf '[%s]:%s' "$BIND" "$PORT" ;; *) printf '%s:%s' "${BIND:-0.0.0.0}" "$PORT" ;; esac
}
firewall_plan() {
    FW=none
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; then FW=ufw
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state 2>/dev/null | grep '^running' >/dev/null; then FW=firewalld
    elif [ "$INIT" = procd ] && command -v uci >/dev/null 2>&1; then FW=uci
    elif command -v nft >/dev/null 2>&1; then
        FW=nft
        NFT_CHAIN=$(nft list ruleset 2>/dev/null | awk -v bind="$BIND" '
            BEGIN {
                wildcard=(bind=="" || bind=="0.0.0.0" || bind=="::")
                target=(index(bind, ":") ? "ip6" : "ip")
            }
            $1=="table" {family=$2; table=$3} $1=="chain" {chain=$2}
            /^[[:space:]]*type[[:space:]]+[^[:space:]]+[[:space:]]+hook[[:space:]]+input[[:space:];]/ {
                if(family ~ /^(inet|ip|ip6)$/ && (wildcard || family=="inet" || family==target) && table ~ /^[a-zA-Z0-9_-]+$/ && chain ~ /^[a-zA-Z0-9_-]+$/) {
                    print family,table,chain
                    found=1
                }
            }
            END {if(!found) print "inet npulse input create"}' || :)
    elif command -v iptables >/dev/null 2>&1; then FW=iptables
    fi
    case "$FW" in
        ufw) printf 'ufw allow %s/tcp\n' "$PORT" ;;
        firewalld) printf 'firewall-cmd --permanent --add-port=%s/tcp && firewall-cmd --add-port=%s/tcp\n' "$PORT" "$PORT" ;;
        nft) printf '%s\n' "$NFT_CHAIN" | while read -r family table chain create; do
                 operation=insert
                 if [ "$create" = create ]; then
                     printf 'nft add table %s %s\nnft '\''add chain %s %s %s { type filter hook input priority 0; policy accept; }'\''\n' "$family" "$table" "$family" "$table" "$chain"
                     operation=add
                 fi
                 printf 'nft %s rule %s %s %s tcp dport %s accept\n' "$operation" "$family" "$table" "$chain" "$PORT"
             done ;;
        iptables) case "$BIND" in *:*) printf 'ip6tables -I INPUT -p tcp --dport %s -j ACCEPT\n' "$PORT" ;; *) printf 'iptables -I INPUT -p tcp --dport %s -j ACCEPT\n' "$PORT" ;; esac ;;
        uci) printf "rule=\$(uci add firewall rule)\nuci set \"firewall.\$rule.name=NodePulse\"\nuci set \"firewall.\$rule.src=wan\"\nuci set \"firewall.\$rule.proto=tcp\"\nuci set \"firewall.\$rule.dest_port=%s\"\nuci set \"firewall.\$rule.target=ACCEPT\"\nuci commit firewall\n/etc/init.d/firewall reload\n" "$PORT" ;;
        none) say '未检测到防火墙管理工具；请手动允许 TCP %s。\n' 'No firewall manager detected; allow TCP %s manually.\n' "$PORT" ;;
    esac
}
open_firewall() {
    say '云服务器还须在安全组/云防火墙放行 TCP %s，例如 GCP：gcloud compute firewall-rules create nodepulse --allow=tcp:%s（请按需限制来源和目标实例）。\n' 'Cloud servers also need TCP %s allowed in security groups/cloud firewalls. GCP example: gcloud compute firewall-rules create nodepulse --allow=tcp:%s (restrict sources and target instances as appropriate).\n' "$PORT" "$PORT"
    firewall_plan
    [ "$FW" != none ] || return 0
    if [ "$OPEN_FIREWALL" != yes ]; then ask "$(msg '是否现在执行？[y/N]' 'Apply these firewall rules now? [y/N]')" n; case "$ANSWER" in y|Y|yes) OPEN_FIREWALL=yes ;; esac; fi
    [ "$OPEN_FIREWALL" = yes ] || return 0
    if [ "$DRY_RUN" = 1 ]; then say '[DRY_RUN] 不执行防火墙命令。\n' '[DRY_RUN] Firewall commands are not executed.\n'; return; fi
    tag=npulse-$(random)
    case "$FW" in
        ufw)
            added=$(ufw show added) || fail 'Cannot query ufw'
            if printf '%s\n' "$added" | awk -v port="$PORT" '$1=="ufw" && $2=="allow" {i=3; if($i=="log" || $i=="log-all") i++; if($i=="in") i++; if($i==port || $i==port"/tcp") found=1} END {exit !found}'; then return; fi
            ufw allow "$PORT/tcp" comment "$tag"
            record_firewall "ufw|$PORT|$tag" ;;
        firewalld)
            zone=$(firewall-cmd --get-default-zone)
            case "$zone" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid firewalld zone' ;; esac
            permanent=1; runtime=0
            if firewall-cmd --permanent --zone="$zone" --query-port="$PORT/tcp" >/dev/null; then permanent=0; else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query firewalld'; fi
            if firewall-cmd --zone="$zone" --query-port="$PORT/tcp" >/dev/null; then :; else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query firewalld'; runtime=1; fi
            if [ "$permanent" = 1 ]; then firewall-cmd --permanent --zone="$zone" --add-port="$PORT/tcp"; record_firewall "firewalld|$zone|$PORT|$runtime"; fi
            if [ "$runtime" = 1 ]; then firewall-cmd --zone="$zone" --add-port="$PORT/tcp"; fi ;;
        nft) printf '%s\n' "$NFT_CHAIN" | while read -r family table chain create; do
                 operation=insert
                 if [ "$create" = create ]; then
                     nft add table "$family" "$table" && nft "add chain $family $table $chain { type filter hook input priority 0; policy accept; }" || exit 1
                     operation=add
                 fi
                 nft "$operation" rule "$family" "$table" "$chain" tcp dport "$PORT" accept comment "\"$tag\"" || exit 1
                 handle=$(nft -a list chain "$family" "$table" "$chain" | awk -v tag="$tag" 'index($0,"\""tag"\"") {for(i=1;i<NF;i++) if($i=="handle") print $(i+1)}')
                 case "$handle" in ''|*[!0-9]*) fail 'Cannot identify added nft rule' ;; esac
                 record_firewall "nft|$family|$table|$chain|$handle|$tag"
             done ;;
        iptables)
            backend=iptables; case "$BIND" in *:*) backend=ip6tables ;; esac
            "$backend" -I INPUT -p tcp --dport "$PORT" -m comment --comment "$tag" -j ACCEPT
            record_firewall "$backend|$PORT|$tag" ;;
        uci) rule=npulse_${tag#npulse-}
             if uci -q get "firewall.$rule" >/dev/null; then fail 'UCI rule already exists'; fi
             uci set "firewall.$rule=rule"
             uci set "firewall.$rule.name=$tag"; uci set "firewall.$rule.src=wan"; uci set "firewall.$rule.proto=tcp"
             record_firewall "uci|$rule|$tag"
             uci set "firewall.$rule.dest_port=$PORT"; uci set "firewall.$rule.target=ACCEPT"; uci commit firewall; firewall_reload ;;
    esac
}
record_firewall() {
    printf '%s\n' "$1" >> "$DESTDIR/etc/npulse/firewall.state"
    chmod 600 "$DESTDIR/etc/npulse/firewall.state"
}
firewall_reload() {
    /etc/init.d/firewall reload
}
remove_firewall() {
    records=$DESTDIR/etc/npulse/firewall.state
    [ -f "$records" ] || return 0
    if [ "$DRY_RUN" = 1 ]; then printf '[DRY_RUN] remove recorded firewall rules\n'; return; fi
    while IFS='|' read -r backend a b c d e; do
        case "$backend" in
            ufw)
                added=$(ufw show added)
                if printf '%s\n' "$added" | awk -v port="$a" -v tag="$b" '$1=="ufw" && $2=="allow" && $3==port"/tcp" && index($0,tag) {found=1} END {exit !found}'; then ufw --force delete allow "$a/tcp" comment "$b"; fi ;;
            firewalld)
                if firewall-cmd --permanent --zone="$a" --query-port="$b/tcp" >/dev/null; then
                    firewall-cmd --permanent --zone="$a" --remove-port="$b/tcp"
                else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query firewalld'; fi
                if [ "$c" = 1 ]; then
                    if firewall-cmd --zone="$a" --query-port="$b/tcp" >/dev/null; then
                        firewall-cmd --zone="$a" --remove-port="$b/tcp"
                    else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query firewalld'; fi
                fi ;;
            nft)
                rules=$(nft -a list ruleset)
                if printf '%s\n' "$rules" | grep -F "\"$e\"" >/dev/null; then
                    rule=$(nft -a list chain "$a" "$b" "$c")
                    if printf '%s\n' "$rule" | awk -v tag="$e" -v handle="$d" 'index($0,"\""tag"\"") {for(i=1;i<NF;i++) if($i=="handle" && $(i+1)==handle) found=1} END {exit !found}'; then
                        nft delete rule "$a" "$b" "$c" handle "$d"
                    fi
                fi ;;
            iptables|ip6tables)
                if "$backend" -C INPUT -p tcp --dport "$a" -m comment --comment "$b" -j ACCEPT 2>/dev/null; then
                    "$backend" -D INPUT -p tcp --dport "$a" -m comment --comment "$b" -j ACCEPT
                else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query iptables'; fi ;;
            uci)
                if name=$(uci -q get "firewall.$a.name"); then
                    if [ "$name" = "$b" ]; then uci delete "firewall.$a"; uci commit firewall; firewall_reload; fi
                else rc=$?; [ "$rc" = 1 ] || fail 'Cannot query UCI'; fi ;;
            *) fail 'Unknown recorded firewall backend' ;;
        esac
    done < "$records"
    rm -f "$records"
}
random() {
    [ -r /dev/urandom ] || fail "$(msg '缺少安全随机源 /dev/urandom' 'Secure random source /dev/urandom is missing')"
    if command -v od >/dev/null 2>&1; then bytes=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    elif command -v hexdump >/dev/null 2>&1; then bytes=$(hexdump -v -n 16 -e '1/1 "%02x"' /dev/urandom)
    else fail "$(msg '需要 od 或 hexdump 以读取安全随机数' 'od or hexdump is required to read secure random bytes')"; fi
    [ "${#bytes}" -eq 32 ] || fail "$(msg '安全随机数生成失败' 'Secure random generation failed')"
    printf '%s' "$bytes"
}
elf_byte() {
    if command -v od >/dev/null 2>&1; then od -An -tu1 -j "$1" -N1 /bin/sh 2>/dev/null | tr -d ' '
    elif command -v hexdump >/dev/null 2>&1; then hexdump -v -s "$1" -n 1 -e '1/1 "%u"' /bin/sh 2>/dev/null
    fi
}
credentials() {
    ANSWER=$2
    if [ -z "$2" ] || [ "${3:-}" = edit ]; then
        ask "$(msg "$1：密钥来源 1) 保留已有值或自动生成 2) 手动输入 [默认 1]：" "$1: key source 1) Keep existing or generate 2) Enter manually [default 1]:")" 1
        case "$ANSWER" in
            1) ANSWER=$2 ;;
            2) ask "$(msg "$1：手动输入（留空保留已有值或自动生成）：" "$1: enter manually (Enter to keep existing or generate):")" "$2" secret ;;
            *) fail "$(msg '密钥来源须为 1 或 2' 'Key source must be 1 or 2')" ;;
        esac
    fi
    if [ -z "$ANSWER" ]; then ANSWER=$(random); fi
    [ "${#ANSWER}" -eq 32 ] || [ -n "$2" ] || printf '%s\n' "$(msg '提示：使用自定义密钥。' 'Note: using a custom key.')" >&2
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
                case "$endian:$machine" in 1:*) ARCH=mipsel ;; 2:*) ARCH=mips ;; *:mipsel*|*:mipsle*) ARCH=mipsel ;; *) fail "$(msg '无法检测 MIPS 字节序，请指定 --arch mips 或 mipsel' 'Cannot detect MIPS byte order; specify --arch mips or mipsel')" ;; esac ;;
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
                    [ "$YES" = 0 ] || fail "$(msg '无法确认 ARM 浮点 ABI；指定 --arch armv7 或 armv7-soft' 'Cannot determine ARM float ABI; specify --arch armv7 or armv7-soft')"
                    ask "$(msg '无法检测 ARM ABI，请输入 hard（硬浮点）或 soft（软浮点）：' 'Cannot detect ARM ABI; enter hard (hard-float) or soft (soft-float):')" ''; abi=$ANSWER
                fi
                case "$abi" in hard) ARCH=armv7 ;; soft) ARCH=armv7-soft ;; *) fail "$(msg 'ARM ABI 须为 hard 或 soft' 'ARM ABI must be hard or soft')" ;; esac ;;
            *) fail "$(msg '不支持此架构；支持列表见 --help' 'Unsupported architecture; see --help for supported targets')" ;;
        esac
    fi
    case "$ARCH" in x86_64|i386|aarch64|armv7|armv7-soft|mips|mipsel) ;; *) fail "$(msg '不支持的 --arch' 'Unsupported --arch')" ;; esac
}
detect_init() {
    if [ -z "$INIT" ]; then
        if [ -f /etc/openwrt_release ] && [ -f /etc/rc.common ]; then INIT=procd
        elif [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then INIT=systemd
        else fail "$(msg '未检测到 systemd/OpenWrt procd；测试可用 NPULSE_INIT + DESTDIR/DRY_RUN' 'No systemd/OpenWrt procd detected; tests can use NPULSE_INIT + DESTDIR/DRY_RUN')"; fi
    fi
    case "$INIT" in
        systemd) BIN=/usr/local/bin/npulse; UNIT=/etc/systemd/system/npulse.service ;;
        procd) BIN=/usr/bin/npulse; UNIT=/etc/init.d/npulse ;;
        *) fail "$(msg 'NPULSE_INIT 须为 systemd 或 procd' 'NPULSE_INIT must be systemd or procd')" ;;
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
    [ -f "$STATE" ] || fail "$(msg '没有找到安装状态，请先 install' 'No installation state found; run install first')"
    ARCH=; FLAVOR=; INIT=
    while IFS='=' read -r key value; do
        case "$key" in arch) ARCH=$value ;; flavor) FLAVOR=$value ;; init) INIT=$value ;; link) LINK=$value ;; version) INSTALLED_VERSION=$value ;; ctl) [ "$value" = 1 ] || fail 'Invalid management state' ;; *) fail "$(msg '安装状态无效' 'Invalid installation state')" ;; esac
    done < "$STATE"
    [ -n "$ARCH" ] && [ -n "$INIT" ] || fail "$(msg '安装状态不完整' 'Incomplete installation state')"
    detect_arch; detect_init
    case "$FLAVOR" in full|lite) ;; *) fail "$(msg '安装状态版本类型无效' 'Invalid build flavor in installation state')" ;; esac
    case "$LINK" in 0|1) ;; *) fail 'Invalid symlink state' ;; esac
}
write_state() {
    printf 'arch=%s\nflavor=%s\ninit=%s\nctl=1\nlink=%s\nversion=%s\n' "$ARCH" "$FLAVOR" "$INIT" "$LINK" "$TARGET_VERSION" > "$STATE.new"
    chmod 600 "$STATE.new"; mv "$STATE.new" "$STATE"
}
install_link() {
    [ "$INIT" = systemd ] || return 0
    link=$DESTDIR/usr/bin/npulse
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then
        mkdir -p "$DESTDIR/usr/bin"
        ln -s /usr/local/bin/npulse "$link"
        LINK=1
    fi
}
remove_link() {
    link=$DESTDIR/usr/bin/npulse
    if [ "$LINK" = 1 ] && [ -L "$link" ] && [ "$(readlink "$link")" = /usr/local/bin/npulse ]; then rm -f "$link"; fi
}
download() {
    case "$1" in file:///*) cp "${1#file://}" "$2" 2>/dev/null || fail "$(msg '离线包缺少文件' 'Offline bundle is missing a file')"; return ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 180 "$1" -o "$2" 2>/dev/null || fail "$(msg '下载失败，请检查版本、网络或镜像' 'Download failed; check the version, network or mirror')"
    elif command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -e '-T' -e '--timeout' >/dev/null; then
            wget -q -T 180 -O "$2" "$1" 2>/dev/null || fail "$(msg '下载失败，请检查版本、网络或镜像' 'Download failed; check the version, network or mirror')"
        else
            wget -q -O "$2" "$1" 2>/dev/null || fail "$(msg '下载失败，请检查版本、网络或镜像' 'Download failed; check the version, network or mirror')"
        fi
    else fail "$(msg '需要 curl 或 wget' 'curl or wget is required')"; fi
}
fetch_binary() {
    case "$VERSION" in ''|v[0-9]*) ;; *) fail "$(msg 'NPULSE_VERSION 应形如 v1.0.0' 'NPULSE_VERSION must look like v1.0.0')" ;; esac
    case "$VERSION" in *[!A-Za-z0-9._-]*) fail "$(msg '版本含非法字符' 'Version contains invalid characters')" ;; esac
    base=https://github.com/cestbon0309/NodePulse/releases
    if [ -n "$VERSION" ]; then base=$base/download/$VERSION; else base=$base/latest/download; fi
    base=${NPULSE_MIRROR:-$base}; base=${base%/}
    case "$base" in
        https://*|file:///*) ;;
        http://*) [ "${NPULSE_INSECURE:-0}" = 1 ] || fail "$(msg '拒绝 HTTP 镜像；仅可信测试可设置 NPULSE_INSECURE=1' 'HTTP mirror refused; only trusted tests may set NPULSE_INSECURE=1')"
            say '警告：NPULSE_INSECURE=1，HTTP 镜像可被中间人替换二进制及校验清单！\n' 'Warning: NPULSE_INSECURE=1; an HTTP mirror permits interception and replacement of both binaries and checksums!\n' >&2 ;;
        *) fail "$(msg '下载目录必须为 HTTPS URL' 'Download directory must be an HTTPS URL')" ;;
    esac
    asset=npulse-linux-$ARCH
    if [ "${1:-$FLAVOR}" = lite ]; then asset=$asset-lite; fi
    if [ -z "$WORK" ]; then
        command -v mktemp >/dev/null 2>&1 || fail "$(msg '需要 mktemp（BusyBox applet）以安全创建临时目录' 'mktemp (BusyBox applet) is required for secure temporary directories')"
        WORK=$(mktemp -d "${TMPDIR:-/tmp}/npulse-install.XXXXXX") || fail "$(msg '无法创建临时目录，请检查 TMPDIR 和剩余空间' 'Cannot create temporary directory; check TMPDIR and free space')"
    fi
    TARGET_VERSION=${VERSION:-unknown}
    if (download "$base/VERSION" "$WORK/VERSION") >/dev/null 2>&1; then
        IFS= read -r target < "$WORK/VERSION" || :
        case "$target" in v[0-9]*) case "$target" in *[!A-Za-z0-9._-]*) ;; *) TARGET_VERSION=$target ;; esac ;; esac
    fi
    if [ "${ACTION:-install}" = upgrade ] && [ "${FORCE:-0}" = 0 ]; then
        case "$TARGET_VERSION" in v[0-9]*)
            if [ "$TARGET_VERSION" = "${NPULSE_CURRENT_VERSION:-${INSTALLED_VERSION:-unknown}}" ]; then SKIP=yes; return; fi ;;
        esac
    fi
    download "$base/SHA256SUMS" "$WORK/SHA256SUMS"
    download "$base/$asset" "$WORK/binary"
    expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name {print $1}' "$WORK/SHA256SUMS")
    [ "${#expected}" -eq 64 ] || fail "$(msg 'SHA256SUMS 缺少唯一匹配项' 'SHA256SUMS has no unique matching entry')"
    case "$expected" in *[!0-9a-fA-F]*) fail "$(msg '校验清单格式无效' 'Invalid checksum manifest format')" ;; esac
    if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$WORK/binary")
    elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$WORK/binary")
    elif command -v openssl >/dev/null 2>&1; then actual=$(openssl dgst -sha256 "$WORK/binary"); actual=${actual##* }
    else fail "$(msg '需要 sha256sum、shasum 或 openssl' 'sha256sum, shasum or openssl is required')"; fi
    actual=${actual%% *}
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    [ "$actual" = "$expected" ] || fail "$(msg 'SHA256 校验失败，未安装任何下载内容' 'SHA256 verification failed; no downloaded content was installed')"
    say '已校验 %s（%s）\n' 'Verified %s (%s)\n' "$asset" "${VERSION:-latest}"
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
        if [ "$MODE" != 4 ]; then printf 'name=%s\n' "$NAME"; fi
        if [ -n "$SECRET" ]; then printf 'secret=%s\n' "$SECRET"; fi
        if [ -n "$TOKEN" ]; then printf 'token=%s\n' "$TOKEN"; fi
        if [ -n "$GROUP" ]; then printf 'group_secret=%s\n' "$GROUP"; fi
        if [ "$LISTEN" = yes ]; then printf 'listen=%s\n' "$(bind_endpoint)"; fi
        if [ -n "$ALSO_RELAY" ]; then printf 'relay_listen=%s\n' "$(PORT=$ALSO_RELAY bind_endpoint)"; fi
        case "$MODE" in
            2) printf 'http=127.0.0.1:%s\n' "$HTTP_PORT" ;;
            3) printf 'relay_upstream=%s\n' "$UPSTREAM" ;;
            4) printf 'relay_listen=0.0.0.0:%s\n' "$PORT"
               if [ -n "$HTTP_PORT" ]; then printf 'http=127.0.0.1:%s\n' "$HTTP_PORT"; fi ;;
        esac
        if [ -n "$ADMIN_KEYS" ]; then printf 'admin_keys=%s\n' "$ADMIN_KEYS"; fi
    } > "$CONFIG.new"
    chmod 600 "$CONFIG.new"; mv "$CONFIG.new" "$CONFIG"
    if [ -n "$PUBLIC_IP" ]; then
        persist_public_ip
    fi
    install_link
    write_state
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
    say '\nNodePulse 已安装：%s / %s；配置 /etc/npulse/npulse.conf\n' '\nNodePulse installed: %s / %s; config /etc/npulse/npulse.conf\n' "$ARCH" "$FLAVOR"
    address=${PUBLIC_IP:-$BIND}
    case "$address" in 0.0.0.0|::) address= ;; esac
    if [ -z "$address" ] && command -v ip >/dev/null 2>&1; then
        address=$(ip -4 addr show scope global 2>/dev/null | awk '$1 == "inet" {split($2,a,"/"); print a[1]; exit}')
        if [ -z "$address" ]; then address=$(ip -6 addr show scope global 2>/dev/null | awk '$1 == "inet6" {split($2,a,"/"); print a[1]; exit}'); fi
    fi
    if [ -z "$address" ]; then address=$(uname -n); fi
    say 'App 参考地址：%s（NAT 后请改用可达公网地址/域名，并配置端口转发）。\n' 'App address: %s (behind NAT, use a reachable public address/domain and configure port forwarding).\n' "$address"
    if [ "$LISTEN" = yes ]; then say '直连 TCP 端口：%s；防火墙放行 TCP %s。\n' 'Direct TCP port: %s; allow TCP %s in the firewall.\n' "$PORT" "$PORT"; fi
    case "$MODE" in
        2) say 'App：HTTPS https://probe.example.com；放行 TCP 443，不开放 HTTP 后端端口。\n' 'App: HTTPS https://probe.example.com; allow TCP 443, do not expose the HTTP backend.\n' ;;
        3) say 'App：中继服务器 TCP %s；本机主动连出。\n' 'App: relay server TCP %s; this probe connects outbound.\n' "$UPSTREAM" ;;
        4) say 'App：中继服务器 TCP，端口 %s；防火墙放行 TCP %s。\n' 'App: relay server TCP, port %s; allow TCP %s in the firewall.\n' "$PORT" "$PORT" ;;
    esac
    if [ -n "$SECRET" ]; then say '探针密钥：%s\n' 'Probe key: %s\n' "$SECRET"; fi
    if [ -n "$TOKEN" ] && [ -z "$ALSO_RELAY" ]; then say '中继令牌：%s\n' 'Relay token: %s\n' "$TOKEN"; fi
    say '下一步：在 App 添加接入点，或运行 sh install.sh pair 扫码配对；务必在两端核对 SAS。\n' 'Next: add an endpoint in the app, or run sh install.sh pair to scan and pair; always compare SAS on both devices.\n'
    if [ -n "$ALSO_RELAY" ]; then
        case "$address" in *:*) relay_host=[$address] ;; *) relay_host=$address ;; esac
        say '中转地址：%s:%s\n中转密码：%s\n下游请选择模式 3（共享中继上报）；本机管理走直连，下游管理走中继管道。\n' 'Relay address: %s:%s\nRelay password: %s\nDownstream nodes: choose mode 3 (shared-relay publisher). Manage this node directly and downstream nodes through the relay pipe.\n' "$relay_host" "$ALSO_RELAY" "$TOKEN"
    fi
    if [ -n "$GROUP" ]; then say '组密钥：%s\n' 'Group key: %s\n' "$GROUP"; fi
    if [ "$MODE" = 4 ]; then say '组密钥由各组自行生成，中继不需要也不应保存组密钥。\n' 'Each group generates its own group key; the relay neither needs nor should store it.\n'; fi
    if [ "$MODE" = 3 ]; then say '注意：令牌必须与已有共享中继配置匹配。\n' 'Note: the token must match the existing shared relay.\n'; fi
    if [ "$INIT" = procd ]; then say 'OpenWrt：服务以 root 运行。\n' 'OpenWrt: the service runs as root.\n'; fi
    if [ -n "$ADMIN_KEYS" ]; then say '警告：管理已启用，探针以 root 运行；授权设备可控制整台机器。\n' 'Warning: administration is enabled and the probe runs as root; authorized devices control the entire machine.\n'; fi
    if [ "$ADMIN_VIA_PAIR" = yes ] && [ -z "$ADMIN_KEYS" ]; then
        say '管理尚未启用；请稍后运行 sh install.sh pair，在手机打开「同时授权本机管理」，并在服务器单独确认管理授权。\n' 'Administration is not enabled. Run sh install.sh pair later, enable phone administration authorization, and confirm it separately on the server.\n'
    fi
    if [ "$MODE" = 2 ] || { [ "$MODE" = 4 ] && [ -n "$HTTP_PORT" ]; }; then
        route=nodes; if [ "$MODE" = 4 ]; then route=relay; fi
        if [ "$MODE" = 4 ]; then say 'App 也可使用中继服务器 HTTPS：https://probe.example.com；开放 TCP 443。\n' 'The app can also use relay HTTPS: https://probe.example.com; allow TCP 443.\n'; fi
        say '\nNginx server 示例（先设置域名并用 certbot 配置以下证书）：\n' '\nNginx server example (set your domain and configure these certificates with certbot first):\n'
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
        say 'HTTPS 接入点不支持管理；需要管理时请保留 TCP 端口。\n' 'HTTPS endpoints do not support administration; retain the TCP port if administration is needed.\n'
    fi
}

pair_installed() {
    if [ -z "$WORK" ]; then
        command -v mktemp >/dev/null 2>&1 || fail "$(msg '需要 mktemp（BusyBox applet）以安全创建临时目录' 'mktemp (BusyBox applet) is required for secure temporary directories')"
        WORK=$(mktemp -d "${TMPDIR:-/tmp}/npulse-pair.XXXXXX") || fail "$(msg '无法创建临时目录，请检查 TMPDIR 和剩余空间' 'Cannot create temporary directory; check TMPDIR and free space')"
    fi
    if [ "$DRY_RUN" = 1 ]; then say '[DRY_RUN] 配对：不执行下载的二进制。\n' '[DRY_RUN] Pairing: downloaded binaries are not executed.\n'; return; fi
    PAIR_STOPPED=1
    service stop
    pair_binary=$DESTDIR$BIN
    if [ "$FLAVOR" = lite ]; then
        say 'lite 版不支持管理；将下载已校验的临时完整版进行配对，服务仍使用 lite。\n' 'lite does not support administration; a verified temporary full build will be downloaded for pairing. The service remains lite.\n'
        fetch_binary full
        chmod 700 "$WORK/binary"
        pair_binary=$WORK/binary
    fi
    paired=no
    pair_upstream=$UPSTREAM; pair_token=$TOKEN
    while :; do
        {
            printf 'name=%s\n' "$NAME"
            if [ "$MODE" = 3 ]; then printf 'relay_upstream=%s\ntoken=%s\ngroup_secret=%s\n' "$UPSTREAM" "$TOKEN" "$GROUP"
            else printf 'listen=%s\nsecret=%s\n' "$(bind_endpoint)" "$SECRET"; fi
        } > "$WORK/pair.conf"
        pair_status=0
        NPULSE_PAIR_HOST=${PUBLIC_IP:-} "$pair_binary" -P -c "$WORK/pair.conf" > "$WORK/pair-output" || pair_status=$?
        if [ "$pair_status" = 0 ]; then paired=yes; break; fi
        if [ "$pair_status" != 3 ] || [ "$MODE" != 3 ]; then break; fi
        say '中转密码错误或无法连接。\n' 'Incorrect relay password or unable to connect.\n'
        [ "$YES" = 0 ] || break
        ask "$(msg '重新填写中转地址和密码？[Y/n]' 'Re-enter relay address and password? [Y/n]')" y
        case "$ANSWER" in y|Y|yes) ;; *) break ;; esac
        ask "$(msg '中转地址 host:port（IPv6 用 [地址]:端口）：' 'Relay address host:port (IPv6: [address]:port):')" "$UPSTREAM"; UPSTREAM=$ANSWER; safe_value "$UPSTREAM"
        case "$UPSTREAM" in *:*) port "${UPSTREAM##*:}" ;; *) fail "$(msg '缺少中转 host:port' 'Missing relay host:port')" ;; esac
        credentials "$(msg '中转密码（访问令牌）' 'Relay password (access token)')" "$TOKEN" edit; TOKEN=$ANSWER
    done
    if [ "$paired" = yes ] && [ "$MODE" = 3 ] && { [ "$UPSTREAM" != "$pair_upstream" ] || [ "$TOKEN" != "$pair_token" ]; }; then
        awk '!/^(relay_upstream|token|group_secret)=/' "$CONFIG" > "$CONFIG.new"
        printf 'relay_upstream=%s\ntoken=%s\ngroup_secret=%s\n' "$UPSTREAM" "$TOKEN" "$GROUP" >> "$CONFIG.new"
        chmod 600 "$CONFIG.new"; mv "$CONFIG.new" "$CONFIG"
    fi
    if [ "$paired" = yes ] && [ "$FLAVOR" = full ]; then
        public=$(awk -F= '$1=="admin_pk" && NF==2 {print $2}' "$WORK/pair-output")
        if [ -n "$public" ]; then
            [ "${#public}" = 64 ] || fail "$(msg '配对返回了无效公钥' 'Pairing returned an invalid public key')"
            case "$public" in *[!0-9a-fA-F]*) fail "$(msg '配对返回了无效公钥' 'Pairing returned an invalid public key')" ;; esac
            public=$(printf '%s' "$public" | tr 'A-F' 'a-f')
            old=$(awk -F= '$1=="admin_keys" {print $2}' "$CONFIG")
            case ",$old," in *",$public,"*) ;; *)
                if [ -n "$old" ]; then public=$old,$public; fi
                printf '%s\n' "$public" | awk -F, 'NF>32 {exit 1}' || fail "$(msg '管理公钥已达 32 个上限' 'The 32-key administration limit has been reached')"
                awk '!/^admin_keys=/' "$CONFIG" > "$CONFIG.new"
                printf 'admin_keys=%s\n' "$public" >> "$CONFIG.new"; chmod 600 "$CONFIG.new"; mv "$CONFIG.new" "$CONFIG" ;;
            esac
            ADMIN_KEYS=$public; write_unit; service reload
        fi
    fi
    service start
    PAIR_STOPPED=0
    if [ "$paired" != yes ]; then say '配对未完成；服务已恢复，可稍后运行 pair 或使用手动密钥。\n' 'Pairing was not completed; service restored. Run pair later or use a manual key.\n'; fi
    rm -rf "$WORK"; WORK=
}

if [ "$ACTION" != install ]; then
    load_state
    case "$ACTION" in
        pair) [ -f "$CONFIG" ] && [ -f "$DESTDIR$BIN" ] || fail "$(msg '现有安装不完整' 'Existing installation is incomplete')"
              BIND=; PORT=9000; ADMIN_KEYS=; MODE=1; LISTEN=no; UPSTREAM=; TOKEN=; GROUP=; SECRET=; ALSO_RELAY=
              while IFS='=' read -r key value; do
                  case "$key" in listen) LISTEN=yes; BIND=${value%:*}; BIND=${BIND#\[}; BIND=${BIND%\]}; PORT=${value##*:} ;;
                      admin_keys) ADMIN_KEYS=$value ;; relay_upstream) UPSTREAM=$value; MODE=3 ;; token) TOKEN=$value ;;
                      group_secret) GROUP=$value ;; secret) SECRET=$value ;; name) NAME=$value ;; esac
                  if [ "$key" = relay_listen ]; then ALSO_RELAY=${value##*:}; fi
              done < "$CONFIG"
              [ -n "$BIND" ] || [ "$MODE" = 3 ] || fail "$(msg '此安装没有可配对的直连或中转配置' 'This installation has no direct or relay configuration for pairing')"
              if [ "$MODE" != 3 ]; then
                  if [ -z "$PUBLIC_IP" ] && [ -f "$DESTDIR/etc/npulse/public-ip" ]; then IFS= read -r PUBLIC_IP < "$DESTDIR/etc/npulse/public-ip"; fi
                  if [ -n "$PUBLIC_IP" ]; then resolve_public_ip; persist_public_ip; fi
              fi
              if [ "$MODE" = 3 ] && [ -z "$GROUP" ]; then GROUP=$SECRET; fi
              PRIVILEGED_PORT=no; if [ "$PORT" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
              pair_installed; summary; exit ;;
        status) service status; exit ;;
        upgrade)
            [ -f "$CONFIG" ] && [ -f "$DESTDIR$BIN" ] || fail "$(msg '现有安装不完整' 'Existing installation is incomplete')"
            if grep -e '^[[:space:]]*upstream[[:space:]]*=' -e '^[[:space:]]*u[[:space:]]*=' "$CONFIG" >/dev/null; then
                fail "$(msg '旧式 upstream 上报已移除；请备份配置，改用共享中继（-R/-S、relay_upstream/relay_listen），选择安装器模式 3 后重新安装；本次未升级或重启服务' 'Legacy upstream publishing was removed; back up the config and switch to shared relay (-R/-S, relay_upstream/relay_listen), then reinstall using mode 3. No upgrade or service restart was performed')"
            fi
            if [ "$FLAVOR" = lite ] && grep '^admin_keys=' "$CONFIG" >/dev/null; then fail "$(msg '精简版配置不能包含管理密钥' 'lite configuration cannot contain administration keys')"; fi
            fetch_binary
            if [ "$SKIP" = yes ]; then install_link; write_state; say '已是最新版本；使用 --force 强制升级。\n' 'Already current; use --force to upgrade anyway.\n'; exit; fi
            replace_binary; install_link; write_state; service restart
            say '升级完成；配置与服务权限未改变。\n' 'Upgrade complete; configuration and service privileges are unchanged.\n'; exit ;;
        uninstall)
            service stop; service disable
            remove_firewall
            remove_link
            rm -f "$DESTDIR$BIN" "$DESTDIR$UNIT" "$STATE"
            service reload
            if [ "$PURGE" != yes ]; then ask "$(msg '同时删除配置和密钥？[yes/no，默认 no]' 'Also delete configuration and keys? [yes/no, default no]')" no; PURGE=$ANSWER; fi
            if [ "$PURGE" != yes ]; then PURGE=no; fi
            if [ "$PURGE" = yes ]; then rm -f "$CONFIG" "$DESTDIR/etc/npulse/public-ip"; rmdir "$DESTDIR/etc/npulse" 2>/dev/null || :; fi
            say '已卸载；配置删除：%s。\n' 'Uninstalled; configuration deleted: %s.\n' "$PURGE"; exit ;;
    esac
fi

detect_arch; detect_init
[ ! -e "$CONFIG" ] && [ ! -e "$DESTDIR$BIN" ] && [ ! -e "$DESTDIR$UNIT" ] || fail "$(msg '已有安装或配置；请使用 upgrade，或备份并卸载旧安装' 'Installation or configuration already exists; use upgrade, or back up and uninstall first')"
if [ "$INIT" = systemd ] && [ "$DRY_RUN" != 1 ]; then
    systemd_version=$(systemctl --version | awk 'NR == 1 {print $2}')
    case "$systemd_version" in ''|*[!0-9]*) fail "$(msg '无法检测 systemd 版本' 'Cannot detect systemd version')" ;; esac
    [ "$systemd_version" -ge 247 ] || fail "$(msg '需要 systemd 247+，以安全加载 0600 配置' 'systemd 247+ is required to securely load mode-0600 configuration')"
fi
say '选择指南：有公网 IP → 1；NAT/家宽/路由器后面 → 3；只当中继 → 4；已有 Nginx/HTTPS → 2。\n请选择模式：\n1 直连探针：公网服务器（推荐）；可同时提供共享中继\n2 HTTP + Nginx：已有 HTTPS/反向代理\n3 共享中继上报：NAT、家宽、路由器；只需主动连出\n4 纯共享中继：公网服务器，只转发不透明密文\n' 'Decision guide: public IP → 1; behind NAT/home/router → 3; relay only → 4; existing Nginx/HTTPS → 2.\nChoose a mode:\n1 Direct probe: public-IP servers (recommended); can also host a shared relay\n2 HTTP + Nginx: existing HTTPS/reverse-proxy deployments\n3 Shared-relay publisher: NAT, home networks and routers; outbound only\n4 Relay server only: public-IP host forwarding opaque ciphertext\n'
ask "$(msg "模式 [默认 $MODE]：" "Mode [default $MODE]:")" "$MODE"; MODE=$ANSWER
case "$MODE" in 1|2|3|4) ;; *) fail "$(msg '模式须为 1–4' 'Mode must be 1-4')" ;; esac
LISTEN=no
if [ "$MODE" = 1 ]; then LISTEN=yes; fi
if [ "$LISTEN" = yes ] || [ "$MODE" = 4 ]; then ask "$(msg "TCP 监听端口 [默认 $PORT]：" "TCP listen port [default $PORT]:")" "$PORT"; PORT=$ANSWER; port "$PORT"; fi
if [ "$MODE" = 1 ]; then select_bind; else PUBLIC_IP=; fi
if [ "$MODE" != 1 ] && [ -n "$ALSO_RELAY" ]; then fail "$(msg '--also-relay PORT 仅支持直连模式 1' '--also-relay PORT requires direct mode 1')"; fi
if [ "$MODE" = 1 ]; then
    relay_enabled=no; if [ -n "$ALSO_RELAY" ]; then relay_enabled=yes; fi
    ask "$(msg "同时作为共享中继？[yes/no，默认 $relay_enabled]" "Also host a shared relay? [yes/no, default $relay_enabled]")" "$relay_enabled"; relay_enabled=$ANSWER
    case "$relay_enabled" in
        yes)
            relay_default=${ALSO_RELAY:-$((PORT + 1))}
            ask "$(msg "共享中继端口 [默认 $relay_default]：" "Shared-relay port [default $relay_default]:")" "$relay_default"; ALSO_RELAY=$ANSWER
            port "$ALSO_RELAY"; [ "$ALSO_RELAY" != "$PORT" ] || fail "$(msg '共享中继端口须与直连端口不同' 'Shared-relay port must differ from direct port')" ;;
        no) ALSO_RELAY= ;;
        *) fail "$(msg '共享中继开关须为 yes 或 no' 'Shared-relay switch must be yes or no')" ;;
    esac
fi
if [ -n "$BIND" ]; then safe_value "$BIND" 128; case "$BIND" in *[!0-9a-fA-F:.%_-]*) fail "$(msg '绑定地址须为 IP 地址' 'Bind address must be an IP address')" ;; esac; fi
if [ "$MODE" = 2 ]; then
    ask "$(msg "HTTP 回环端口 [默认 ${HTTP_PORT:-9001}]：" "HTTP loopback port [default ${HTTP_PORT:-9001}]:")" "${HTTP_PORT:-9001}"; HTTP_PORT=$ANSWER; port "$HTTP_PORT"
elif [ "$MODE" = 4 ]; then
    use_http=no; if [ -n "$HTTP_PORT" ]; then use_http=yes; fi
    ask "$(msg "开启 HTTP /api/relay（仅回环）？[yes/no，默认 $use_http]" "Enable HTTP /api/relay (loopback only)? [yes/no, default $use_http]")" "$use_http"; use_http=$ANSWER
    case "$use_http" in yes) ask "$(msg "HTTP 回环端口 [默认 ${HTTP_PORT:-9001}]：" "HTTP loopback port [default ${HTTP_PORT:-9001}]:")" "${HTTP_PORT:-9001}"; HTTP_PORT=$ANSWER; port "$HTTP_PORT" ;; no) HTTP_PORT= ;; *) fail "$(msg 'HTTP 开关须为 yes 或 no' 'HTTP switch must be yes or no')" ;; esac
fi
if [ -n "$HTTP_PORT" ] && { [ "$LISTEN" = yes ] || [ "$MODE" = 4 ]; }; then [ "$PORT" != "$HTTP_PORT" ] || fail "$(msg 'TCP 与 HTTP 端口不能相同' 'TCP and HTTP ports must differ')"; fi
if [ "$MODE" = 3 ]; then
    ask "$(msg '上游地址 host:port（IPv6 用 [地址]:端口）：' 'Upstream relay host:port (IPv6: [address]:port):')" "$UPSTREAM"; UPSTREAM=$ANSWER
    case "$UPSTREAM" in *:*) remote_port=${UPSTREAM##*:}; port "$remote_port"; [ -n "${UPSTREAM%:*}" ] || fail "$(msg '上游主机不能为空' 'Upstream host must not be empty')" ;; *) fail "$(msg '缺少上游 host:port' 'Missing upstream host:port')" ;; esac
fi
if [ "$LISTEN" = yes ] || [ "$MODE" = 2 ]; then credentials "$(msg '探针密钥' 'Probe key')" "$SECRET"; SECRET=$ANSWER; else SECRET=; fi
if [ "$MODE" = 3 ] || [ "$MODE" = 4 ] || [ -n "$ALSO_RELAY" ]; then credentials "$(msg '中转密码 / 中继访问令牌（需与中继一致）' 'Relay password / access token (must match relay)')" "$TOKEN"; TOKEN=$ANSWER; else TOKEN=; fi
if [ "$MODE" = 3 ]; then credentials "$(msg '组密钥（仅可信组成员持有）' 'Group key (trusted group members only)')" "$GROUP"; GROUP=$ANSWER; else GROUP=; fi
if [ -n "$ADMIN_KEYS" ]; then ADMIN=yes; fi
if [ "$MODE" != 4 ]; then ask "$(msg "启用远程管理？[yes/no，默认 $ADMIN]（警告：root 级控制权）" "Enable remote administration? [yes/no, default $ADMIN] (warning: root-level control)")" "$ADMIN"; ADMIN=$ANSWER; fi
case "$ADMIN" in yes|no) ;; *) fail "$(msg '管理开关须为 yes 或 no' 'Administration switch must be yes or no')" ;; esac
if [ "$ADMIN" = yes ]; then
    [ "$MODE" != 4 ] || fail "$(msg '纯中继不使用 -A；请选择 full 以转发管理管道' 'Relay-only mode does not use -A; choose full to forward administration pipes')"
    [ "$LISTEN" = yes ] || [ "$MODE" = 3 ] || fail "$(msg '管理需要直连 -l 或共享中继 -R' 'Administration requires direct -l or shared relay -R')"
    if [ "$YES" = 0 ]; then
        admin_source=1; if [ -n "$ADMIN_KEYS" ]; then admin_source=2; fi
        ask "$(msg "管理公钥来源：1) 配对时由手机自动提供（推荐） 2) 手动粘贴 [默认 $admin_source]：" "Administration public-key source: 1) Supplied by phone during pairing (recommended) 2) Paste manually [default $admin_source]:")" "$admin_source"
        case "$ANSWER" in 1) ADMIN_VIA_PAIR=yes ;; 2) ADMIN_VIA_PAIR=no ;; *) fail "$(msg '管理公钥来源须为 1 或 2' 'Administration public-key source must be 1 or 2')" ;; esac
    fi
    if [ "$ADMIN_VIA_PAIR" = yes ]; then ADMIN_KEYS=
    else
        ask "$(msg '粘贴 Ed25519 公钥（64 位十六进制，多个用逗号分隔）：' 'Paste Ed25519 public keys (64 hex characters each, comma-separated):')" "$ADMIN_KEYS"; ADMIN_KEYS=$ANSWER
        printf '%s\n' "$ADMIN_KEYS" | awk -F, 'NF < 1 || NF > 32 {exit 1} {for(i=1;i<=NF;i++) if(length($i)!=64 || $i ~ /[^0-9a-fA-F]/) exit 1}' || fail "$(msg '管理公钥格式无效' 'Invalid administration public-key format')"
        ADMIN_KEYS=$(printf '%s' "$ADMIN_KEYS" | tr 'A-F' 'a-f')
    fi
else ADMIN_KEYS=; ADMIN_VIA_PAIR=no; fi
[ -n "$FLAVOR" ] || FLAVOR=full
say '完整版 full（约 250–355 KB，随架构变化）：支持管理、实时管道、配对和二维码。\nlite（约 120–200 KB）：节省空间，但无管理/实时管道；配对需临时下载 full（纯中继转发管理也必须 full）。\n' 'full (~250-355 KB, architecture-dependent): administration, live pipes, pairing and QR.\nlite (~120-200 KB): space-saving, no administration/live pipes; pairing temporarily downloads full. Relays forwarding administration also need full.\n'
ask "$(msg "构建类型 full/lite（完整版/精简版）[默认 $FLAVOR]：" "Build full/lite [default $FLAVOR]:")" "$FLAVOR"; FLAVOR=$ANSWER
case "$FLAVOR" in full) ;; lite) [ "$ADMIN" = no ] || fail "$(msg 'lite 不允许启用管理，请选择 full' 'lite cannot enable administration; choose full')" ;; *) fail "$(msg '构建类型须为 full 或 lite' 'Build must be full or lite')" ;; esac
if [ "$ADMIN_VIA_PAIR" = yes ]; then
    say '手机配对授权需要 full；收到手机公钥并在服务器明确授权前，管理保持关闭。\n' 'Phone administration pairing requires full; administration stays disabled until the phone key is received and separately authorized on the server.\n'
fi
for value in "$NAME" "$UPSTREAM" "$SECRET" "$TOKEN" "$GROUP"; do safe_value "$value"; done
safe_value "$ADMIN_KEYS" 2080
case "$INTERVAL" in ''|*[!0-9]*|0*) fail "$(msg 'NPULSE_INTERVAL 须为 1–86400' 'NPULSE_INTERVAL must be 1-86400')" ;; esac
[ "${#INTERVAL}" -le 5 ] && [ "$INTERVAL" -le 86400 ] || fail "$(msg '间隔超出范围' 'Interval is out of range')"
PRIVILEGED_PORT=no
if { [ "$LISTEN" = yes ] || [ "$MODE" = 4 ]; } && [ "$PORT" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
if [ -n "$HTTP_PORT" ] && [ "$HTTP_PORT" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
if [ -n "$ALSO_RELAY" ] && [ "$ALSO_RELAY" -lt 1024 ]; then PRIVILEGED_PORT=yes; fi
fetch_binary
replace_binary; write_config; write_unit
service enable
if [ "$MODE" = 4 ]; then relay_bind=$BIND; BIND=0.0.0.0; open_firewall; BIND=$relay_bind; fi
if [ "$LISTEN" = yes ] || [ "$MODE" = 3 ]; then
    if [ "$MODE" = 1 ]; then
        open_firewall
        if [ -n "$ALSO_RELAY" ]; then (PORT=$ALSO_RELAY; open_firewall); fi
    fi
    pair_default=yes; if [ "$YES" = 1 ]; then pair_default=no; fi
    if [ "$ADMIN_VIA_PAIR" = yes ]; then
        pair_default=yes
        say '请在手机打开「同时授权本机管理」，核对图案后在服务器单独授权；跳过配对、配对失败或拒绝授权，管理将保持关闭。\n' 'Enable administration authorization on the phone, compare the pattern, then authorize separately on the server. Skipping, failure or refusal leaves administration disabled.\n'
    fi
    ask "$(msg '现在与手机配对？[Y/n]' 'Pair with the phone now? [Y/n]')" "$pair_default"
    case "$ANSWER" in y|Y|yes) pair_installed ;; *) service start ;; esac
else service start; fi
say '服务已启用并启动。\n' 'Service enabled and started.\n'
say '管理命令：npulse upgrade / pair / uninstall / status / restart / version。\n' 'Manage with: npulse upgrade / pair / uninstall / status / restart / version.\n'
summary
