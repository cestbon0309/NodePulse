#!/bin/sh
# NodePulse unattended deploy generator: builds one self-contained installer
# that sets up a relay publisher (mode 3) with no questions asked.
set -eu
fail() { echo "mkdeploy: $*" >&2; exit 1; }
usage() {
    cat <<'HELP'
Usage: sh mkdeploy.sh [--relay HOST:PORT] [--token TOKEN] [--group GROUP_KEY] [--arch ARCH]
                      [--lite] [--version vX.Y.Z] [--interval SECONDS] [--admin-keys HEX,...]
                      [--output FILE]
用法：缺少的必填项（中继地址、中继令牌、组密钥、架构）会逐项询问。
ARCH: x86_64 i386 aarch64 armv7 armv7-soft mips mipsel
Secrets may also come from NPULSE_TOKEN / NPULSE_GROUP_SECRET.
The output embeds the probe, the installer and both secrets: keep it private.
On the target (root): sh npulse-deploy-ARCH.sh   (add --force to replace an existing install)
NPULSE_MIRROR overrides the release asset directory (https:// or a local directory).
HELP
}
RELAY=; TOKEN=${NPULSE_TOKEN:-}; GROUP=${NPULSE_GROUP_SECRET:-}; ARCH=; FLAVOR=full
VERSION=; INTERVAL=; ADMIN_KEYS=; OUTPUT=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --lite) FLAVOR=lite; shift ;;
        --full) FLAVOR=full; shift ;;
        --relay|--token|--group|--arch|--version|--interval|--admin-keys|--output|-o)
            [ "$#" -ge 2 ] || fail "$1 requires a value"
            case "$1" in
                --relay) RELAY=$2 ;; --token) TOKEN=$2 ;; --group) GROUP=$2 ;; --arch) ARCH=$2 ;;
                --version) VERSION=$2 ;; --interval) INTERVAL=$2 ;; --admin-keys) ADMIN_KEYS=$2 ;;
                --output|-o) OUTPUT=$2 ;;
            esac
            shift 2 ;;
        *) fail "unknown option $1 (see --help)" ;;
    esac
done
ask() {
    [ -t 0 ] || fail "missing $1 (non-interactive: pass it as an option)"
    printf '%s: ' "$2" >&2
    IFS= read -r ANSWER || fail "no input"
}
[ -n "$RELAY" ] || { ask --relay '中继地址 / Relay host:port'; RELAY=$ANSWER; }
[ -n "$TOKEN" ] || { ask --token '中继令牌 / Relay token'; TOKEN=$ANSWER; }
[ -n "$GROUP" ] || { ask --group '组密钥 / Group key'; GROUP=$ANSWER; }
[ -n "$ARCH" ] || { ask --arch '架构 / Arch (x86_64 i386 aarch64 armv7 armv7-soft mips mipsel)'; ARCH=$ANSWER; }
case "$ARCH" in x86_64|i386|aarch64|armv7|armv7-soft|mips|mipsel) ;; *) fail "unsupported arch: $ARCH" ;; esac
case "$RELAY" in *:*) ;; *) fail 'relay must be host:port' ;; esac
relay_port=${RELAY##*:}
case "$relay_port" in ''|*[!0-9]*|0*) fail 'relay port must be 1-65535' ;; esac
[ "${#relay_port}" -le 5 ] && [ "$relay_port" -le 65535 ] || fail 'relay port must be 1-65535'
[ -n "${RELAY%:*}" ] || fail 'relay host is empty'
case "$VERSION" in ''|v[0-9]*) ;; *) fail 'version must look like v1.0.0' ;; esac
case "$VERSION" in *[!A-Za-z0-9._-]*) fail 'invalid version' ;; esac
case "$INTERVAL" in '') ;; *[!0-9]*|0*) fail 'interval must be 1-86400' ;; esac
if [ -n "$ADMIN_KEYS" ]; then
    [ "$FLAVOR" = full ] || fail 'administration requires the full build'
    printf '%s\n' "$ADMIN_KEYS" | awk -F, 'NF < 1 || NF > 32 {exit 1} {for(i=1;i<=NF;i++) if(length($i)!=64 || $i ~ /[^0-9a-fA-F]/) exit 1}' || fail 'admin keys must be 64 hex characters each, comma-separated'
fi
for value in "$RELAY" "$TOKEN" "$GROUP"; do
    [ -n "$value" ] || fail 'relay, token and group key must not be empty'
    case "$value" in *"'"*|*'
'*|' '*|*' ') fail 'values must not contain single quotes, newlines or leading/trailing spaces' ;; esac
    if printf '%s' "$value" | LC_ALL=C grep '[[:cntrl:]]' >/dev/null; then fail 'values must not contain control characters'; fi
done

asset=npulse-linux-$ARCH
[ "$FLAVOR" = full ] || asset=$asset-lite
base=https://github.com/cestbon0309/NodePulse/releases
if [ -n "$VERSION" ]; then base=$base/download/$VERSION; else base=$base/latest/download; fi
base=${NPULSE_MIRROR:-$base}; base=${base%/}
work=$(mktemp -d "${TMPDIR:-/tmp}/npulse-mkdeploy.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
get() {
    case "$base" in
        https://*)
            if command -v curl >/dev/null 2>&1; then curl -fLsS --connect-timeout 15 --max-time 180 "$base/$1" -o "$work/$1"
            elif command -v wget >/dev/null 2>&1; then wget -q -O "$work/$1" "$base/$1"
            else fail 'curl or wget is required'; fi ;;
        /*) cp "$base/$1" "$work/$1" ;;
        *) fail 'NPULSE_MIRROR must be an https:// URL or an absolute directory' ;;
    esac || fail "cannot fetch $1 from $base"
}
sha() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 -r "$1"
    else fail 'sha256sum, shasum or openssl is required'; fi | awk '{print $1}'
}
for file in SHA256SUMS VERSION install.sh "$asset"; do
    get "$file"
    [ "$file" = SHA256SUMS ] && continue
    expected=$(awk -v name="$file" '$2 == name || $2 == "*" name {print $1}' "$work/SHA256SUMS")
    [ "${#expected}" -eq 64 ] || fail "SHA256SUMS has no entry for $file"
    [ "$(sha "$work/$file")" = "$expected" ] || fail "SHA256 mismatch for $file"
done
IFS= read -r release < "$work/VERSION" || :
case "$release" in v[0-9]*) ;; *) fail 'release VERSION is invalid' ;; esac
case "$release" in *[!A-Za-z0-9._-]*) fail 'release VERSION is invalid' ;; esac
grep 'file:///' "$work/install.sh" >/dev/null || fail "release $release predates offline bundles; use a newer release"
for marker in NPULSE_INSTALLER_END NPULSE_SUMS_END; do
    if grep -x "$marker" "$work/install.sh" "$work/SHA256SUMS" >/dev/null; then fail 'payload collides with a marker'; fi
done
OUTPUT=${OUTPUT:-npulse-deploy-$ARCH.sh}
umask 077
{
    cat <<HEADER
#!/bin/sh
# NodePulse unattended deploy: $release $ARCH $FLAVOR -> $RELAY
# Contains the relay token and group key. Keep this file private.
set -eu
UPSTREAM='$RELAY'
TOKEN='$TOKEN'
GROUP='$GROUP'
ARCH='$ARCH'
FLAVOR='$FLAVOR'
RELEASE='$release'
INTERVAL='$INTERVAL'
ADMIN_KEYS='$ADMIN_KEYS'
ASSET='$asset'
HEADER
    cat <<'BODY'
fail() { echo "npulse-deploy: $*" >&2; exit 1; }
FORCE=0
for option in "$@"; do
    case "$option" in --force) FORCE=1 ;; *) fail "usage: sh $0 [--force]" ;; esac
done
[ "${DRY_RUN:-0}" = 1 ] || [ "$(id -u)" = 0 ] || fail 'run as root'
root=${DESTDIR:-}
work=$(mktemp -d "${TMPDIR:-/tmp}/npulse-deploy.XXXXXX") || fail 'cannot create a temporary directory'
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
start=$(awk '$0 == "__NPULSE_BINARY__" {print NR + 1; exit}' "$0")
[ -n "$start" ] || fail 'payload is missing; the file is incomplete'
tail -n +"$start" "$0" > "$work/$ASSET"
cat > "$work/install.sh" <<'NPULSE_INSTALLER_END'
BODY
    cat "$work/install.sh"
    printf '%s\n' NPULSE_INSTALLER_END "cat > \"\$work/SHA256SUMS\" <<'NPULSE_SUMS_END'"
    cat "$work/SHA256SUMS"
    cat <<'BODY'
NPULSE_SUMS_END
printf '%s\n' "$RELEASE" > "$work/VERSION"
export NPULSE_YES=1 NPULSE_MIRROR="file://$work" NPULSE_VERSION="$RELEASE"
if [ -e "$root/etc/npulse/npulse.conf" ] || [ -e "$root/usr/bin/npulse" ] || [ -e "$root/usr/local/bin/npulse" ]; then
    if [ "$FORCE" = 0 ]; then
        echo 'npulse-deploy: NodePulse is already installed; nothing changed (use --force to replace it)'
        exit 0
    fi
    sh "$work/install.sh" uninstall --purge --yes
fi
export NPULSE_MODE=3 NPULSE_UPSTREAM="$UPSTREAM" NPULSE_TOKEN="$TOKEN" NPULSE_GROUP_SECRET="$GROUP"
export NPULSE_ARCH="$ARCH" NPULSE_FLAVOR="$FLAVOR"
if [ -n "$INTERVAL" ]; then export NPULSE_INTERVAL="$INTERVAL"; fi
if [ -n "$ADMIN_KEYS" ]; then export NPULSE_ADMIN_KEYS="$ADMIN_KEYS" NPULSE_ADMIN=yes; fi
sh "$work/install.sh" install --yes > "$work/log" 2>&1 || { cat "$work/log" >&2; fail 'installation failed'; }
echo "npulse-deploy: installed $RELEASE ($ARCH $FLAVOR), reporting to $UPSTREAM"
exit 0
__NPULSE_BINARY__
BODY
    cat "$work/$asset"
} > "$work/out"
chmod 700 "$work/out"
mv "$work/out" "$OUTPUT"
echo "Generated $OUTPUT ($release $ARCH $FLAVOR, $(wc -c < "$OUTPUT" | tr -d ' ') bytes). It contains secrets: keep it private."
echo "On the target, as root: sh $(basename "$OUTPUT")"
