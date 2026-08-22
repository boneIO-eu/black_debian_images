#!/bin/bash
## boneIO Black — boot time report
##
## Run on the controller after a boot to get a reproducible breakdown of where
## startup time goes, plus the milestone that actually matters: when boneIO
## finished configuring GPIO and can serve I/O.
##
## Usage:
##   ./boot_report.sh                  # print report for the current boot
##   ./boot_report.sh --save baseline  # also store it for later comparison
##   ./boot_report.sh --compare baseline
##
## Reports are stored as plain text in /var/lib/boneio/boot-reports/.
##
## SCOPE: this reads systemd and the journal, so it can only see from kernel
## t0 onwards. U-Boot and zImage decompression happen before any of that exists
## and need a serial capture — see the note printed at the end.

set -u

REPORT_DIR="/var/lib/boneio/boot-reports"
SAVE_NAME=""
COMPARE_NAME=""

while [ $# -gt 0 ]; do
    case "$1" in
        --save)    SAVE_NAME="${2:-}"; shift 2 ;;
        --compare) COMPARE_NAME="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^## \?//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# --- helpers ---------------------------------------------------------------

# Monotonic timestamp of the first journal line matching a pattern for unit $1.
first_ts() {
    local unit="$1" pattern="$2"
    journalctl -b -u "$unit" -o short-monotonic --no-pager 2>/dev/null \
        | grep -m1 -- "$pattern" \
        | sed -n 's/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p'
}

# Monotonic timestamp of the LAST journal line matching a pattern for unit $1.
last_ts() {
    local unit="$1" pattern="$2"
    journalctl -b -u "$unit" -o short-monotonic --no-pager 2>/dev/null \
        | grep -- "$pattern" | tail -1 \
        | sed -n 's/^\[ *\([0-9]*\.[0-9]*\)\].*/\1/p'
}

# Monotonic timestamp from systemd's own bookkeeping, in seconds.
# Preferred over journal scraping: it does not depend on log message wording,
# and it survives journald being behind under load.
unit_ts() {
    local unit="$1" prop="$2" v
    v=$(systemctl show "$unit" -p "$prop" --value 2>/dev/null)
    # 0 means "never happened"; treat as unavailable.
    if [ -n "$v" ] && [ "$v" != "0" ]; then
        awk -v u="$v" 'BEGIN{printf "%.6f", u/1000000}'
    fi
}

fmt() {
    # "12.345" -> "12.35s", empty -> "n/a"
    [ -n "${1:-}" ] && printf '%.2fs' "$1" || printf 'n/a'
}

delta() {
    # $2 - $1, both may be empty
    if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
        awk -v a="$1" -v b="$2" 'BEGIN{printf "%.2f", b-a}'
    fi
}

# --- collect ---------------------------------------------------------------

KERNEL_TIME=$(systemd-analyze time 2>/dev/null | sed -n 's/.*Startup finished in \([0-9.]*\)s (kernel).*/\1/p')
USERSPACE_TIME=$(systemd-analyze time 2>/dev/null | sed -n 's/.*+ \(.*\) (userspace).*/\1/p')

BONEIO_EXEC=$(unit_ts boneio.service ExecMainStartTimestampMonotonic)
BONEIO_ACTIVE=$(unit_ts boneio.service ActiveEnterTimestampMonotonic)
BONEIO_JOB=$(unit_ts boneio.service InactiveExitTimestampMonotonic)
BONEIO_APP=$(first_ts boneio.service "BoneIO .* starting")
# Readiness: the app has bound every GPIO chip it was configured for.
IO_READY=$(last_ts boneio.service "Successfully configured chip")
WEB_UP=$(first_ts boneio.service "Starting HYPERCORN")
RESTARTS=$(systemctl show boneio.service -p NRestarts --value 2>/dev/null)

# Overlay state — this silently broke once and cost real debugging time.
OVERLAY_APPLIED="NO"
if [ -d /proc/device-tree/chosen/overlays ]; then
    if ls /proc/device-tree/chosen/overlays/ 2>/dev/null | grep -q '^BONEIO-BLACK-PINS'; then
        OVERLAY_APPLIED=$(ls /proc/device-tree/chosen/overlays/ | grep '^BONEIO-BLACK-PINS' | head -1)
    fi
fi
ONEWIRE="no"
[ -e /sys/bus/w1/devices/w1_bus_master1 ] && ONEWIRE="yes"

# --- render ---------------------------------------------------------------

render() {
    echo "boneIO boot report — $(date -Is)"
    echo "kernel: $(uname -r)   boot id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
    echo
    printf '%-38s %10s\n' "PHASE" "TIME"
    printf '%-38s %10s\n' "--------------------------------------" "----------"
    printf '%-38s %10s\n' "kernel (incl. initramfs)" "$(fmt "$KERNEL_TIME")"
    printf '%-38s %10s\n' "userspace (to default.target)" "${USERSPACE_TIME:-n/a}"
    echo
    printf '%-38s %10s\n' "boneio.service: job started" "$(fmt "$BONEIO_JOB")"
    printf '%-38s %10s\n' "boneio.service: exec" "$(fmt "$BONEIO_EXEC")"
    printf '%-38s %10s\n' "boneio.service: active" "$(fmt "$BONEIO_ACTIVE")"
    printf '%-38s %10s\n' "  -> pre-exec cost" "$(fmt "$(delta "$BONEIO_JOB" "$BONEIO_EXEC")")"
    printf '%-38s %10s\n' "app logged 'starting'" "$(fmt "$BONEIO_APP")"
    printf '%-38s %10s\n' "  -> python + imports + config" "$(fmt "$(delta "$BONEIO_ACTIVE" "$BONEIO_APP")")"
    printf '%-38s %10s\n' "web server starting" "$(fmt "$WEB_UP")"
    printf '%-38s %10s\n' "restarts this boot" "${RESTARTS:-?}"
    echo
    printf '%-38s %10s\n' ">>> I/O READY (all gpiochips bound)" "$(fmt "$IO_READY")"
    echo
    echo "hardware:"
    printf '  %-24s %s\n' "device tree overlay" "$OVERLAY_APPLIED"
    printf '  %-24s %s\n' "1-Wire bus master" "$ONEWIRE"
    echo
    echo "slowest units:"
    systemd-analyze blame 2>/dev/null | head -8 | sed 's/^/  /'
    echo
    echo "critical chain to boneio.service:"
    systemd-analyze critical-chain boneio.service 2>/dev/null | tail -n +4 | head -8 | sed 's/^/  /'
    echo "  (the @ value on the first line is derived from the dependency chain,"
    echo "   not when the unit actually started — use 'boneio.service: active' above)"
}

REPORT="$(render)"
echo "$REPORT"

cat <<'EOF'

NOTE: everything above is relative to kernel t0. U-Boot and zImage
decompression happen earlier and are invisible to systemd — capture them on the
serial console (115200 8N1) and measure from the U-Boot banner to
"Starting kernel ...". Reference figures for a BeagleBone Black:
U-Boot ~2.6-3.9s, decompression ~4.9-5.6s.
EOF

# --- save / compare -------------------------------------------------------

if [ -n "$SAVE_NAME" ]; then
    if mkdir -p "$REPORT_DIR" 2>/dev/null; then
        echo "$REPORT" > "${REPORT_DIR}/${SAVE_NAME}.txt"
        echo
        echo "Saved to ${REPORT_DIR}/${SAVE_NAME}.txt"
    else
        echo
        echo "WARNING: cannot write ${REPORT_DIR} (run with sudo to save)" >&2
    fi
fi

if [ -n "$COMPARE_NAME" ]; then
    BASE="${REPORT_DIR}/${COMPARE_NAME}.txt"
    if [ ! -f "$BASE" ]; then
        echo "No saved report named '${COMPARE_NAME}' in ${REPORT_DIR}" >&2
        exit 1
    fi
    echo
    echo "=== diff vs '${COMPARE_NAME}' (< saved, > current) ==="
    # Drop the header lines, which always differ (timestamp, boot id).
    diff <(tail -n +3 "$BASE") <(echo "$REPORT" | tail -n +3) || true
fi
