#!/bin/bash
## boneIO Black — buzzer probe
##
## Drive the buzzer pin to a chosen PHYSICAL level and report what the hardware
## actually does, so buzzer polarity can be established by looking rather than
## by counting beeps.
##
## The point of working in physical levels: /sys/class/leds/.../brightness is a
## LOGICAL value. What it does to the pin depends on the GPIO_ACTIVE_* flag in
## the device tree overlay, which is exactly the thing under investigation. This
## script reads that flag and converts, so "high" always means 3.3 V on P9_12.
##
## Usage (needs root):
##   ./buzzer_probe.sh status     # polarity, pinmux pull, current pin level
##   ./buzzer_probe.sh high       # drive P9_12 HIGH,  print confirmation
##   ./buzzer_probe.sh low        # drive P9_12 LOW,   print confirmation
##   ./buzzer_probe.sh walk       # step HIGH/LOW, waiting for Enter each time
##
## P9_12 = GPMC_BEN1 = gpio1[28].  GPIO1 base 0x4804C000, DATAOUT +0x13C.
## Pad control register: 0x44E10878.

set -u

LED="/sys/class/leds/boneio:buzzer"
DT="/proc/device-tree/buzzer/buzzer0"
PADCONF=0x44E10878

if [ "$(id -u)" != "0" ]; then
    echo "Needs root: sudo $0 $*" >&2
    exit 1
fi

if [ ! -d "$LED" ]; then
    echo "ERROR: $LED missing — the boneIO overlay is not applied." >&2
    echo "Check: ls /proc/device-tree/chosen/overlays/" >&2
    exit 1
fi

# --- read device tree polarity -------------------------------------------

# gpios = <phandle, line, flags>; flags bit0 = 1 means GPIO_ACTIVE_LOW.
read_active_low() {
    local flags
    flags=$(od -An -tu4 --endian=big -j8 -N4 "$DT/gpios" 2>/dev/null | tr -d ' ')
    [ -z "$flags" ] && { echo "?"; return; }
    echo $(( flags & 1 ))
}

ACTIVE_LOW=$(read_active_low)

# Convert a wanted PHYSICAL level into the brightness value that produces it.
#   ACTIVE_HIGH (0): brightness 1 -> pin HIGH
#   ACTIVE_LOW  (1): brightness 1 -> pin LOW
brightness_for() {
    local want_high="$1"
    if [ "$ACTIVE_LOW" = "1" ]; then
        [ "$want_high" = "1" ] && echo 0 || echo 1
    else
        echo "$want_high"
    fi
}

datout_bit28() {
    python3 - <<'PY'
import mmap, os
f = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x4804C000)
m.seek(0x13C)
v = int.from_bytes(m.read(4), "little")
print((v >> 28) & 1)
PY
}

pad_pull() {
    local reg
    reg=$(python3 - <<PY
import mmap, os
f = os.open("/dev/mem", os.O_RDONLY | os.O_SYNC)
m = mmap.mmap(f, 4096, mmap.MAP_SHARED, mmap.PROT_READ, offset=0x44E10000)
m.seek(0x878)
print(int.from_bytes(m.read(4), "little"))
PY
)
    # bit3 = pull disabled, bit4 = 1 pull-up / 0 pull-down
    if [ $(( (reg >> 3) & 1 )) = 1 ]; then
        echo "disabled (raw 0x$(printf '%x' "$reg"))"
    elif [ $(( (reg >> 4) & 1 )) = 1 ]; then
        echo "PULL-UP (raw 0x$(printf '%x' "$reg"))"
    else
        echo "PULL-DOWN (raw 0x$(printf '%x' "$reg"))"
    fi
}

set_level() {
    local want_high="$1" b actual
    b=$(brightness_for "$want_high")
    echo "$b" > "$LED/brightness"
    sleep 0.2
    actual=$(datout_bit28)
    printf 'wrote brightness=%s  ->  P9_12 is now %s' "$b" \
        "$([ "$actual" = 1 ] && echo 'HIGH (3.3V)' || echo 'LOW (0V)')"
    if [ "$actual" != "$want_high" ]; then
        printf '   *** MISMATCH: asked for %s ***' \
            "$([ "$want_high" = 1 ] && echo HIGH || echo LOW)"
    fi
    echo
}

# --- commands -------------------------------------------------------------

case "${1:-status}" in
    status)
        echo "buzzer probe — P9_12 / gpio1[28]"
        echo
        printf '  %-28s %s\n' "device tree polarity" \
            "$([ "$ACTIVE_LOW" = 1 ] && echo GPIO_ACTIVE_LOW || echo GPIO_ACTIVE_HIGH)"
        printf '  %-28s %s\n' "default-state" "$(tr -d '\0' < "$DT/default-state" 2>/dev/null)"
        printf '  %-28s %s\n' "pinmux pull on P9_12" "$(pad_pull)"
        printf '  %-28s %s\n' "brightness (logical)" "$(cat "$LED/brightness")"
        printf '  %-28s %s\n' "P9_12 physical level" \
            "$([ "$(datout_bit28)" = 1 ] && echo 'HIGH (3.3V)' || echo 'LOW (0V)')"
        echo
        echo "The pinmux pull only decides the level between pinmux setup and"
        echo "leds-gpio taking the pin over. It does not invert the polarity."
        ;;
    high) set_level 1 ;;
    low)  set_level 0 ;;
    walk)
        echo "Listen, and note which physical level makes it sound."
        echo
        for level in 1 0 1 0; do
            [ "$level" = 1 ] && echo "--- driving HIGH (3.3V) ---" || echo "--- driving LOW (0V) ---"
            set_level "$level"
            printf 'sounding? press Enter for the next step... '
            read -r _
        done
        echo
        echo "Whichever level sounded is the ACTIVE level."
        echo "  sounds at LOW  -> buzzer is active-LOW  -> silent state is HIGH"
        echo "  sounds at HIGH -> buzzer is active-HIGH -> silent state is LOW"
        ;;
    *)
        sed -n '2,25p' "$0" | sed 's/^## \?//'
        exit 2
        ;;
esac
