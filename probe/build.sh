#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p dist
for pair in x86_64:x86_64-linux-musl i386:x86-linux-musl aarch64:aarch64-linux-musl armv7:arm-linux-musleabihf armv7-soft:arm-linux-musleabi mips:mips-linux-musleabi mipsel:mipsel-linux-musleabi; do
    arch=${pair%%:*}
    target=${pair#*:}
    cpu=
    case "$arch" in
        armv7*) cpu='-mcpu=cortex_a7' ;;
        mips*) cpu='-mcpu=mips32 -msoft-float' ;;
    esac
    zig cc -target "$target" $cpu -Os -flto -std=gnu99 -Wall -Wextra -Werror \
        -ffunction-sections -fdata-sections -static -Wl,--gc-sections -s \
        npulse.c vendor/monocypher.c vendor/monocypher-ed25519.c -o "dist/npulse-linux-$arch"
    printf '%-32s %s bytes\n' "npulse-linux-$arch" "$(wc -c < "dist/npulse-linux-$arch" | tr -d ' ')"
done
