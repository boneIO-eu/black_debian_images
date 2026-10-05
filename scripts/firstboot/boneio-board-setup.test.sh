#!/bin/sh
#
# boneio-board-setup.test.sh — run boneio-board-setup against a fake rootfs.
#
# No hardware and no root: i2cdetect/i2cget are stubs on PATH, and the script
# is given a ROOT, so it never reboots or writes outside the scratch dir.
#
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SETUP="$HERE/boneio-board-setup"
FAILS=0

check() {  # check "what" command...
    what="$1"; shift
    if "$@"; then echo "  ok    $what"; else echo "  FAIL  $what"; FAILS=$((FAILS + 1)); fi
}

# make_root DS2484(yes|no) RELAYS_ACTIVE_LOW(yes|no) "boneio.txt lines"
make_root() {
    T="$(mktemp -d)"
    R="$T/root"; B="$T/boot"; BIN="$T/bin"
    mkdir -p "$R/home/boneio/boneio" "$R/boot/dtbs/6.18/overlays" "$R/var/lib" "$B" "$BIN"
    for v in 0.8 1.0 1.1; do
        for t in base 32x10 cover; do
            mkdir -p "$R/home/boneio/.cache/boneio_configs/$v/$t"
            printf 'boneio:\n  version: %s\n# %s\n' "$v" "$t" > "$R/home/boneio/.cache/boneio_configs/$v/$t/config.yaml"
            echo "mqtt_password: boneio123" > "$R/home/boneio/.cache/boneio_configs/$v/$t/secrets.yaml"
            touch "$R/home/boneio/.cache/boneio_configs/$v/$t/config.yaml.cache.pkl"
        done
    done
    touch "$R/boot/dtbs/6.18/overlays/BONEIO-BLACK-PINS-v0.4-v0.8.dtbo" \
          "$R/boot/dtbs/6.18/overlays/BONEIO-BLACK-PINS-v1.0.dtbo"
    printf 'uname_r=6.18\nuboot_overlay_addr0=BONEIO-BLACK-PINS-v1.0.dtbo\n' > "$R/boot/uEnv.txt"
    # The image's own config, as sealed: 32x10 1.1 and a per-device password.
    printf 'boneio:\n  version: 1.1\n' > "$R/home/boneio/boneio/config.yaml"
    echo "output: x" > "$R/home/boneio/boneio/output32x10A.yaml"
    echo 'mqtt_password: "device-own"' > "$R/home/boneio/boneio/secrets.yaml"
    printf '%s\n' "$3" > "$B/boneio.txt"
    if [ "$1" = yes ]; then row='10: -- -- -- -- -- -- -- -- 18 -- -- -- -- -- -- --'; else row='10: -- -- -- -- -- -- -- -- -- -- -- -- -- -- -- --'; fi
    printf '#!/bin/sh\necho "     0  1  2"\necho "%s"\n' "$row" > "$BIN/i2cdetect"
    if [ "$2" = yes ]; then printf '#!/bin/sh\necho 0xff\n' > "$BIN/i2cget"; else printf '#!/bin/sh\necho 0x00\n' > "$BIN/i2cget"; fi
    printf '#!/bin/sh\nexit 0\n' > "$BIN/modprobe"
    chmod +x "$BIN"/*
}

run() { PATH="$BIN:$PATH" sh "$SETUP" "$R" "$B" >/dev/null; }
overlay() { grep -q "^uboot_overlay_addr0=$1\$" "$R/boot/uEnv.txt"; }
config_is() { grep -q "^  version: $1\$" "$R/home/boneio/boneio/config.yaml" && grep -q "^# $2\$" "$R/home/boneio/boneio/config.yaml"; }

echo "0.8 board, no boneio.txt settings"
make_root no no "# BOARD_VERSION=1.1"
run
check "probed as 0.8, base config"          config_is 0.8 base
check "wizard asked to pick the type"        grep -qx 0.8 "$R/home/boneio/boneio/.board-type-pending"
check "0.8 overlay"                           overlay BONEIO-BLACK-PINS-v0.4-v0.8.dtbo
check "image's leftover output file gone"    test ! -e "$R/home/boneio/boneio/output32x10A.yaml"
check "device's broker password kept"        grep -q device-own "$R/home/boneio/boneio/secrets.yaml"
check "warm cache copied"                     test -e "$R/home/boneio/boneio/config.yaml.cache.pkl"
check "no 1-Wire modules on 0.8"              test ! -e "$R/etc/modules-load.d/onewire.conf"
check "marked done"                           test -e "$R/var/lib/boneio/board-setup.done"

echo "second run does nothing"
echo "edited" >> "$R/home/boneio/boneio/config.yaml"
run
check "config untouched"                      grep -q edited "$R/home/boneio/boneio/config.yaml"

echo "1.x board, DEVICE_TYPE=cover, active-low relays"
make_root yes yes "DEVICE_TYPE=cover"
run
check "probed as 1.1, cover config"           config_is 1.1 cover
check "no wizard question"                    test ! -e "$R/home/boneio/boneio/.board-type-pending"
check "overlay unchanged (already v1.0)"      overlay BONEIO-BLACK-PINS-v1.0.dtbo
check "1-Wire modules enabled"                grep -q ds2482 "$R/etc/modules-load.d/onewire.conf"
check "active-low relays recorded"            grep -q '"mcp_0x23_inverted": true' "$R/home/boneio/boneiostate.json"

echo "boneio.txt overrides the probe; garbage is ignored"
make_root yes no "$(printf 'BOARD_VERSION=1.0\r\nDEVICE_TYPE=$(reboot)\n')"
run
check "BOARD_VERSION=1.0 taken, CRLF stripped" config_is 1.0 base
check "bad DEVICE_TYPE falls back to asking"  test -e "$R/home/boneio/boneio/.board-type-pending"

echo "a controller with accounts keeps its configuration"
make_root no no "DEVICE_TYPE=32x10"
echo '{"users":[1]}' > "$R/home/boneio/boneio/users.json"
run
check "config left alone"                     test -e "$R/home/boneio/boneio/output32x10A.yaml"
check "overlay still fitted to the board"     overlay BONEIO-BLACK-PINS-v0.4-v0.8.dtbo

[ "$FAILS" -eq 0 ] && echo "all passed" || { echo "$FAILS failed"; exit 1; }
