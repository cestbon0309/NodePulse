set -eu
umask 077
fail() { echo "npulse: $*" >&2; exit 1; }
base=https://github.com/cestbon0309/NodePulse/releases
case "$NPULSE_CURRENT_VERSION" in v[0-9]*) base=$base/download/$NPULSE_CURRENT_VERSION ;; *) base=$base/latest/download ;; esac
base=${NPULSE_MIRROR:-$base}
base=${base%/}
case "$base" in https://*) ;; http://*) [ "${NPULSE_INSECURE:-0}" = 1 ] || fail 'HTTP mirror requires NPULSE_INSECURE=1' ;; *) fail 'Invalid mirror URL' ;; esac
work=$(mktemp -d "${TMPDIR:-/tmp}/npulse-ctl.XXXXXX") || fail 'Cannot create temporary directory'
trap 'rm -rf "$work"' 0
trap 'exit 130' HUP INT TERM
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --connect-timeout 15 --max-time 180 "$base/$1" -o "$work/$1"
    elif command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -e '-T' -e '--timeout' >/dev/null; then
            wget -q -T 180 -O "$work/$1" "$base/$1"
        else wget -q -O "$work/$1" "$base/$1"; fi
    else fail 'Install curl or wget to manage lite online'; fi
}
if ! fetch install.sh || ! fetch SHA256SUMS; then fail 'Installer download failed; check network, TLS certificates and mirror'; fi
expected=$(awk '$2=="install.sh" || $2=="*install.sh" {print $1}' "$work/SHA256SUMS")
[ "${#expected}" = 64 ] || fail 'Missing or ambiguous installer checksum'
case "$expected" in *[!0-9a-fA-F]*) fail 'Invalid installer checksum' ;; esac
if command -v sha256sum >/dev/null 2>&1; then actual=$(sha256sum "$work/install.sh")
elif command -v shasum >/dev/null 2>&1; then actual=$(shasum -a 256 "$work/install.sh")
elif command -v openssl >/dev/null 2>&1; then actual=$(openssl dgst -sha256 "$work/install.sh"); actual=${actual##* }
else fail 'Install sha256sum, shasum or openssl'; fi
[ "${actual%% *}" = "$(printf '%s' "$expected" | tr A-F a-f)" ] || fail 'Installer SHA256 mismatch'
script=$(cat "$work/install.sh"; printf '.')
script=${script%.}
rm -rf "$work"
trap - 0 HUP INT TERM
exec sh -c "$script" npulse "$@"
