#!/bin/sh
set -eu
case "${PAIR:-1}:${QR:-1}" in [01]:[01]) ;; *) printf 'PAIR and QR must be 0 or 1\n' >&2; exit 1 ;; esac
cd "$(dirname "$0")"
mkdir -p dist
NPULSE_VERSION=${NPULSE_VERSION:-dev}
export NPULSE_VERSION
python3 tools/embed-installer.py
printf '%s\n' "$NPULSE_VERSION" > dist/VERSION
for pair in x86_64:x86_64-linux-musl i386:x86-linux-musl aarch64:aarch64-linux-musl armv7:arm-linux-musleabihf armv7-soft:arm-linux-musleabi mips:mips-linux-musleabi mipsel:mipsel-linux-musleabi; do
    arch=${pair%%:*}
    target=${pair#*:}
    set --
    case "$arch" in
        armv7*) set -- -mcpu=cortex_a7 ;;
        mips*) set -- -mcpu=mips32 -msoft-float ;;
    esac
    for admin in 1 0; do
        suffix=
        if [ "$admin" = 0 ]; then
            suffix=-lite
            set -- "$@" -fno-unwind-tables -fno-asynchronous-unwind-tables
        fi
        pairing=${PAIR:-$admin}
        qr=${QR:-$pairing}
        zig cc -target "$target" "$@" -DADMIN="$admin" -DPAIR="$pairing" -DQR="$qr" -Os -flto -std=gnu99 -Wall -Wextra -Werror \
            -ffunction-sections -fdata-sections -static -Wl,--gc-sections -s \
            npulse.c vendor/monocypher.c vendor/monocypher-ed25519.c vendor/qrcodegen.c -o "dist/npulse-linux-$arch$suffix"
        printf '%-36s %s bytes\n' "npulse-linux-$arch$suffix" "$(wc -c < "dist/npulse-linux-$arch$suffix" | tr -d ' ')"
    done
done
