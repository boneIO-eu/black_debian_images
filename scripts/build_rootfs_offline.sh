#!/bin/bash
## BoneIO Black — build a new rootfs.img on the PC, without the BeagleBone.
##
## Usage:
##   sudo BONEIO_VERSION=<x> ./scripts/build_rootfs_offline.sh <previous_rootfs.img> <new_rootfs.img> [--grow 3G] [--no-shrink]
##
## Example:
##   sudo BONEIO_VERSION=1.6.0.dev14 ./scripts/build_rootfs_offline.sh \
##        rootfs-v1.6.0.dev11.img rootfs-v1.6.0.dev14.img
##   sudo ./scripts/generate_all_images.sh rootfs-v1.6.0.dev14.img 1.6.0.dev14 --emmc-flasher
##
## What it does: takes the previous release's rootfs, runs apt dist-upgrade and
## setup_boneio.sh inside systemd-nspawn (armhf binaries run through qemu-user
## binfmt), checks the result and shrinks it exactly like create_rootfs_img.sh
## does for an SD card. The manual BBB round, minus moving cards: about 20
## minutes on the first run, less once .build-cache/ holds the downloads.
##
## Requirements (Arch):  pacman -S qemu-user-static qemu-user-static-binfmt
## /proc/sys/fs/binfmt_misc/qemu-arm must say "enabled" with the F flag.
##
## What differs from running setup on a real board, and why each is handled:
##   uname -r      is the PC's kernel — stubbed to the image's, or setup would
##                 purge every bone kernel;
##   halt -f       would halt a chroot's host — nspawn, plus a stub;
##   iptables-nft  needs netlink, which qemu-user lacks — legacy during setup;
##   SSH host keys a sealed image has none, and sshd -t fails without them —
##                 temporary keys, removed again by sealing;
##   passwd expiry pre-dev13 images expire boneio's password, and su prompts —
##                 cleared, then sealing locks the account;
##   downloads     apt under qemu crawls — .debs are fetched on the host,
##                 from rcn-ee.com first, and cached with pip's files;
##   Docker        no dockerd here — images are inherited, and one the compose
##                 file names but the store lacks is pulled at first boot.
##
## Every check at the end must pass, or the image is left unshrunk for
## inspection. The previous rootfs is only read.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

BASE_IMG=""
OUT_IMG=""
GROW="3G"
SHRINK=true
BONEIO_VERSION="${BONEIO_VERSION:-}"
BOARD_CONFIG_VERSION="${BOARD_CONFIG_VERSION:-1.1}"

while [ $# -gt 0 ]; do
    case "$1" in
        --grow)      GROW="$2"; shift 2 ;;
        --no-shrink) SHRINK=false; shift ;;
        -h|--help)   grep '^##' "$0" | sed 's/^## \?//'; exit 0 ;;
        *)
            if   [ -z "$BASE_IMG" ]; then BASE_IMG="$1"
            elif [ -z "$OUT_IMG" ];  then OUT_IMG="$1"
            else echo "Unknown argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
phase() { echo -e "\n${CYAN}══ $* ══${NC}"; }

# ─── Preflight ───────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Run with sudo."
[ -n "$BASE_IMG" ] && [ -n "$OUT_IMG" ] || die "Usage: $0 <previous_rootfs.img> <new_rootfs.img>"
[ -f "$BASE_IMG" ] || die "$BASE_IMG does not exist"
[ -e "$OUT_IMG" ] && die "$OUT_IMG already exists — refusing to overwrite"

for tool in systemd-nspawn losetup sfdisk e2fsck resize2fs dumpe2fs blkid rsync; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

# binfmt must be registered with the F (fix-binary) flag, so the interpreter is
# opened on the host and works inside the container without copying qemu in.
BINFMT=/proc/sys/fs/binfmt_misc/qemu-arm
[ -r "$BINFMT" ] || die "qemu-arm binfmt not registered. Install qemu-user-static-binfmt (then: systemctl restart systemd-binfmt)."
grep -q '^enabled' "$BINFMT" || die "qemu-arm binfmt is registered but disabled"
grep -q '^flags:.*F' "$BINFMT" || die "qemu-arm binfmt lacks the F flag — the container would not find the interpreter"

MNT="$(mktemp -d /mnt/boneio-offline.XXXXXX)"
LOOP=""
LOG="${OUT_IMG%.img}.build.log"
exec > >(tee -a "$LOG") 2>&1
info "Log: $LOG"

cleanup() {
    set +e
    # Background downloads hold files open in the image, and sudo hands
    # Ctrl+C to this script alone: kill them first, or the unmount fails and
    # the image stays mounted.
    for job in $(jobs -p); do pkill -P "$job" 2>/dev/null; kill "$job" 2>/dev/null; done
    wait 2>/dev/null
    rm -f  "$MNT/etc/sudoers.d/zz-offline-build" 2>/dev/null
    rm -rf "$MNT/root/boneio-build" 2>/dev/null
    umount "$MNT/boot/firmware" 2>/dev/null
    umount "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null
    rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ─── 1. Copy + grow ──────────────────────────────────────────────────────────

phase "1/6 Copy and grow ${BASE_IMG} -> ${OUT_IMG} (+${GROW})"
cp --reflink=auto --sparse=always "$BASE_IMG" "$OUT_IMG"
truncate -s "+${GROW}" "$OUT_IMG"

# The rootfs is the last partition (p3 on BBB images). Grow it to the end.
ROOT_NUM=$(sfdisk -l "$OUT_IMG" | awk -v img="$OUT_IMG" 'index($1,img)==1{n=substr($1,length(img)+1)} END{print n}')
[ -n "$ROOT_NUM" ] || die "could not find the last partition"
echo ", +" | sfdisk -N "$ROOT_NUM" --no-reread "$OUT_IMG" >/dev/null

LOOP=$(losetup -fP --show "$OUT_IMG")
sleep 1
ROOT_PART="${LOOP}p${ROOT_NUM}"
BOOT_PART="${LOOP}p1"
[ "$(blkid -s TYPE -o value "$ROOT_PART")" = "ext4" ] || die "$ROOT_PART is not ext4"

e2fsck -f -y "$ROOT_PART" || [ $? -le 1 ] || die "e2fsck failed"
resize2fs "$ROOT_PART"

# ─── 2. Mount + stage ────────────────────────────────────────────────────────

phase "2/6 Mount and stage build files"
mount "$ROOT_PART" "$MNT"
# Mirror the device: /etc/fstab mounts p1 at /boot/firmware, and setup_boneio.sh
# edits /boot/firmware/uEnv.txt when it exists there.
mkdir -p "$MNT/boot/firmware"
if [ "$(blkid -s TYPE -o value "$BOOT_PART" 2>/dev/null)" = "vfat" ]; then
    mount "$BOOT_PART" "$MNT/boot/firmware"
fi

BUILD="$MNT/root/boneio-build"
mkdir -p "$BUILD/bin"
rsync -a --exclude '*.pkl' "$REPO_DIR/scripts" "$REPO_DIR/configs" "$BUILD/"

# Keep the image's own resolv.conf; nspawn copies the host's in for the build.
RESOLV_BAK="$BUILD/resolv.conf.orig"
cp -P "$MNT/etc/resolv.conf" "$RESOLV_BAK" 2>/dev/null || true

# Build-time only: sudo resets the environment, and the migration helpers run
# systemctl through 'sudo -n'. Without SYSTEMD_OFFLINE they would try to talk to
# a systemd that is not running here and fail. Removed again in cleanup().
printf 'Defaults env_keep += "SYSTEMD_OFFLINE"\n' > "$MNT/etc/sudoers.d/zz-offline-build"
chmod 0440 "$MNT/etc/sudoers.d/zz-offline-build"

# Downloads kept between builds, outside the image: .deb files by name and
# SHA256, and pip's cache bind-mounted where pip looks for it. A second build
# fetches only what is new. Override with BUILD_CACHE=/somewhere.
BUILD_CACHE="${BUILD_CACHE:-$REPO_DIR/.build-cache}"
mkdir -p "$BUILD_CACHE/apt" "$BUILD_CACHE/pip"

# SYSTEMD_OFFLINE=1: systemctl enable/disable edit symlinks offline, and
# start/stop/restart/reload are ignored instead of failing under set -e.
#
# stdin is /dev/null and the console a pipe: nothing in here may wait for a
# person. A prompt gets end-of-file and fails at once, with its question in
# the log, instead of hanging the build (the first run sat on passwd).
nsp() {
    systemd-nspawn -q -D "$MNT" --as-pid2 --console=pipe \
        --bind="$BUILD_CACHE/pip:/root/.cache/pip" \
        --resolv-conf=replace-host --timezone=off \
        --setenv=SYSTEMD_OFFLINE=1 \
        --setenv=DEBIAN_FRONTEND=noninteractive \
        --setenv=NEEDRESTART_MODE=a \
        --setenv=LANG=C.UTF-8 \
        "$@" </dev/null
}

# ─── 3. dist-upgrade ─────────────────────────────────────────────────────────

phase "3/6 apt dist-upgrade (armhf under qemu-user)"
nsp apt-get update

# Downloads run on the host. apt's own transfer under qemu-user crawled at
# 8-16 kB/s on the first build (a 39 MB kernel: 40 minutes) while the host
# fetched the same file at 1.4 MB/s. apt only lists what it needs, with sizes
# and SHA256; curl fetches them straight into the image's archive cache, and
# apt then verifies each one itself before installing it.
prefetch_debs() {
    local archives="$MNT/var/cache/apt/archives" list
    list=$(nsp apt-get -qq --print-uris -y "$@" 2>/dev/null | grep "^'" || true)
    [ -n "$list" ] || { info "  nothing to download"; return 0; }
    info "  prefetching $(echo "$list" | wc -l) package(s) on the host"
    fetch_deb "$archives" <<< "$list"
}

# BeagleBoard publishes the same pool under two hosts. debian.beagle.cc sits
# behind Cloudflare and throttles one address hard after a while — 10-50 kB/s
# on the second build of a day, with parallel connections slower still —
# while rcn-ee.com served the same files at ~1 MB/s. Same Filename, same
# SHA256 in both Packages files, so the mirror is tried first and the URI apt
# gave is the fallback.
# debian.beagleboard.org answers with a redirect to debian.beagle.cc, so it
# is the same throttled pool under a third name.
MIRROR_FROM=(
    "https://debian.beagle.cc/debian-trixie-armhf/"
    "https://debian.beagleboard.org/debian-trixie-armhf/"
    "http://debian.beagleboard.org/debian-trixie-armhf/"
)
MIRROR_TO="https://rcn-ee.com/repos/debian-trixie-armhf/"
PREFETCH_PARALLEL=2

# One file: each URI in turn until one delivers the right SHA256. A transfer
# slower than 50 kB/s for 15 s is abandoned for the next URI, and a file no
# URI delivers is left to apt — the prefetch only ever saves time.
fetch_one() {
    local dest="$1" hash="$2"; shift 2
    local uri
    for uri in "$@"; do
        local stats
        if stats=$(curl -fsSL --retry 1 --retry-delay 2 --connect-timeout 10 \
                --speed-limit 50000 --speed-time 15 -w '%{remote_ip} %{speed_download}' \
                -o "$dest.part" "$uri" 2>&1) \
            && echo "$hash  $dest.part" | sha256sum -c --quiet >/dev/null 2>&1; then
            mv "$dest.part" "$dest"
            cp -f "$dest" "$BUILD_CACHE/apt/" 2>/dev/null || true
            return 0
        fi
        echo "  slow or failed: ${uri%%/pool/*} ($stats)" | tr '\n' ' '; echo
        rm -f "$dest.part"
    done
    echo "  prefetch failed: $(basename "$dest") (apt will fetch it)"
    return 1
}

# Reads apt's --print-uris lines ('URI' file size SHA256:hash) on stdin and
# downloads them into $1, a couple at a time, printing progress every 5 s.
fetch_deb() {
    local archives="$1" uri file size hash total=0 names=()
    local rest
    while read -r uri file size rest; do
        # apt 3 lists every hash it knows after the size ("SHA256:… MD5Sum:…");
        # taking the rest of the line as the SHA256 rejected every download.
        [[ "$rest" =~ SHA256:([0-9a-f]{64}) ]] || continue
        hash="${BASH_REMATCH[1]}"
        uri="${uri#\'}"; uri="${uri%\'}"
        if [ -f "$archives/$file" ] && echo "$hash  $archives/$file" | sha256sum -c --quiet >/dev/null 2>&1; then
            continue
        fi
        if [ -f "$BUILD_CACHE/apt/$file" ] \
            && echo "$hash  $BUILD_CACHE/apt/$file" | sha256sum -c --quiet >/dev/null 2>&1; then
            cp -f "$BUILD_CACHE/apt/$file" "$archives/$file"
            info "  from cache: $file"
            continue
        fi
        total=$((total + size)); names+=("$archives/$file")
        while [ "$(jobs -rp | wc -l)" -ge "$PREFETCH_PARALLEL" ]; do sleep 0.3; done
        local uris=("$uri")
        local from
        for from in "${MIRROR_FROM[@]}"; do
            [[ "$uri" == "$from"* ]] && uris=("${MIRROR_TO}${uri#"$from"}" "$uri")
        done
        fetch_one "$archives/$file" "$hash" "${uris[@]}" &
    done
    local started=$SECONDS done_bytes f
    while [ -n "$(jobs -rp)" ]; do
        sleep 5
        done_bytes=0
        for f in "${names[@]}"; do
            [ -f "$f" ] && done_bytes=$((done_bytes + $(stat -c %s "$f")))
            [ -f "$f.part" ] && done_bytes=$((done_bytes + $(stat -c %s "$f.part")))
        done
        printf '  pobrano %d / %d MB (%d s, %d kB/s)\n' $((done_bytes / 1048576)) \
            $((total / 1048576)) $((SECONDS - started)) \
            $((done_bytes / 1024 / (SECONDS - started + 1)))
    done
    wait
}

prefetch_debs dist-upgrade
nsp apt-get -y dist-upgrade
# What apt fetched itself (a prefetch that failed) goes into the cache too,
# before apt-get clean empties the archive.
cp -n "$MNT"/var/cache/apt/archives/*.deb "$BUILD_CACHE/apt/" 2>/dev/null || true
nsp apt-get -y autoremove --purge
nsp apt-get clean

# The kernel the image will boot. Same rule setup_boneio.sh uses for
# NEWEST_KERNEL (ls -t), so its "kernel upgraded, reboot" check sees no change.
TARGET_KERNEL=$(ls -t "$MNT"/boot/vmlinuz-* | head -1 | sed 's|.*/vmlinuz-||')
[ -n "$TARGET_KERNEL" ] || die "no kernel in /boot"
info "Target kernel: $TARGET_KERNEL"

# ─── 4. setup_boneio.sh ──────────────────────────────────────────────────────

phase "4/6 setup_boneio.sh"

# uname -r inside the container is the HOST kernel. setup_boneio.sh purges
# every linux-image-* that does not match `uname -r` — left alone, that removes
# ALL bone kernels and bricks the image. The overlay build also installs to
# /boot/dtbs/$(uname -r). So both get the kernel the image will boot.
cat > "$BUILD/bin/uname" <<EOF
#!/bin/sh
case "\$1" in
    -r) echo "$TARGET_KERNEL" ;;
    *)  exec /usr/bin/uname "\$@" ;;
esac
EOF
# setup_boneio.sh ends with 'halt -f'. Belt and braces with nspawn.
printf '#!/bin/sh\necho "[offline build] halt stubbed"\nexit 0\n' > "$BUILD/bin/halt"
chmod +x "$BUILD/bin/uname" "$BUILD/bin/halt"

SETUP_ENV=(--setenv=PATH=/root/boneio-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
           --setenv=BOARD_CONFIG_VERSION="$BOARD_CONFIG_VERSION")
[ -n "$BONEIO_VERSION" ] && SETUP_ENV+=(--setenv=BONEIO_VERSION="$BONEIO_VERSION")

# iptables-nft opens a netlink socket even for `iptables -V`, and qemu-user
# does not emulate netlink ("Failed to initialize nft: Protocol not
# supported"), so ufw's version check fails and set -e ends setup at step 1 —
# which never happens on a BeagleBone, where the kernel is real. The legacy
# variant answers -V without netlink, and with the firewall inactive ufw only
# writes its rule files, which both variants read. nft is put back after.
IPT_ALT_IP4=$(readlink "$MNT/etc/alternatives/iptables" || true)
IPT_ALT_IP6=$(readlink "$MNT/etc/alternatives/ip6tables" || true)
nsp update-alternatives --set iptables /usr/sbin/iptables-legacy >/dev/null
nsp update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy >/dev/null

# A sealed image has no SSH host keys (they are regenerated at first boot),
# and without them `sshd -t` fails — so setup's step 1b decided the hardening
# drop-in was broken, "reverted" it and removed the one the image already had.
# Temporary keys for the build; setup's sealing deletes them again.
nsp ssh-keygen -A >/dev/null

# Images before 1.6.0.dev13 were sealed with the boneio password expired
# (chage -d 0), and setup_boneio.sh runs `su - boneio` to warm the config
# caches — which then demands a new password on the terminal. On a BeagleBone
# nobody notices, because someone logged in and changed it before running
# setup. Here, mark it changed today; setup's sealing step locks the account
# again at the end, as in every image.
nsp chage -d "$(( $(date +%s) / 86400 ))" boneio

# --force: the previous image's step markers are older than 24h anyway, but be
# explicit that every step runs.
SETUP_RC=0
nsp "${SETUP_ENV[@]}" --chdir=/root/boneio-build/scripts \
    /bin/bash ./setup_boneio.sh --force || SETUP_RC=$?

[ -n "$IPT_ALT_IP4" ] && nsp update-alternatives --set iptables "$IPT_ALT_IP4" >/dev/null
[ -n "$IPT_ALT_IP6" ] && nsp update-alternatives --set ip6tables "$IPT_ALT_IP6" >/dev/null
[ "$SETUP_RC" -eq 0 ] || die "setup_boneio.sh failed (rc=$SETUP_RC) — see the log above"

# ─── 5. Verify ───────────────────────────────────────────────────────────────

phase "5/6 Verify"
FAIL=false
check() { if eval "$2"; then info "  ✅ $1"; else echo -e "${RED}  ❌ $1${NC}"; FAIL=true; fi; }

UENV="$MNT/boot/firmware/uEnv.txt"; [ -f "$UENV" ] || UENV="$MNT/boot/uEnv.txt"
check "kernel $TARGET_KERNEL present"        "[ -f '$MNT/boot/vmlinuz-$TARGET_KERNEL' ] && [ -f '$MNT/boot/initrd.img-$TARGET_KERNEL' ]"
check "uEnv uname_r = $TARGET_KERNEL"        "grep -qx 'uname_r=$TARGET_KERNEL' '$MNT/boot/uEnv.txt'"
check "overlay in /boot/dtbs/$TARGET_KERNEL" "ls '$MNT/boot/dtbs/$TARGET_KERNEL'/BONEIO-BLACK-PINS-*.dtbo >/dev/null 2>&1"
check "exactly one overlay line"             "[ \$(grep -c '^uboot_overlay_addr0=.*BONEIO-BLACK-PINS' '$UENV') -eq 1 ]"
check "no dtbs dir for host kernel"          "[ ! -e '$MNT/boot/dtbs/$(uname -r)' ]"
check "boneio-migrate-v2 installed"          "[ -x '$MNT/usr/sbin/boneio-migrate-v2' ]"
check "legacy boneio-migrate retired"        "[ ! -e '$MNT/usr/sbin/boneio-migrate' ]"
# The expiry was cleared above so setup could run; sealing must have locked it.
check "boneio account locked by sealing"    "grep -q '^boneio:!' '$MNT/etc/shadow'"
check "build sudo rule gone"                 "[ ! -e '$MNT/etc/sudoers.d/boneio-setup' ]"
check "machine-id empty"                     "[ ! -s '$MNT/etc/machine-id' ]"
check "SSH hardening drop-in present"       "[ -s '$MNT/etc/ssh/sshd_config.d/10-boneio-hardening.conf' ]"
check "no SSH host keys"                     "! ls '$MNT'/etc/ssh/ssh_host_* >/dev/null 2>&1"
check "iptables back on nft"                  "[ \"\$(readlink '$MNT/etc/alternatives/iptables')\" = '${IPT_ALT_IP4:-/usr/sbin/iptables-nft}' ]"
check "docker store inherited"               "[ -s '$MNT/var/lib/docker/image/overlay2/repositories.json' ]"
if [ -n "$BONEIO_VERSION" ]; then
    GOT=$(nsp --chdir=/tmp /home/boneio/boneio/venv/bin/python3 -c 'import importlib.metadata as m; print(m.version("boneio"))' 2>/dev/null | tr -d '\r')
    check "boneio == $BONEIO_VERSION (got $GOT)" "[ '$GOT' = '$BONEIO_VERSION' ]"
fi

# ─── 5b. Container images the compose file needs ────────────────────────────
#
# Nothing here can pull an image: there is no dockerd in the container, and a
# host dockerd writing the image's /var/lib/docker would be a newer Docker than
# the device's. Images and containers are inherited from the previous rootfs,
# which covers everything whose reference did not change. A reference that did
# change — a release that bumps the pinned Caddy — is left to the device: a
# one-shot unit pulls it and recreates the containers at the first boot with a
# network, retrying until that works. (docker load of a saved tarball would not
# help: an image referenced by digest only counts as present when it was
# pulled, so compose would pull it again anyway.)
COMPOSE_LIVE="$MNT/home/boneio/docker/nodered/docker-compose.yaml"
REPOS_JSON="$MNT/var/lib/docker/image/overlay2/repositories.json"
MISSING_IMAGES=()
if [ -f "$COMPOSE_LIVE" ]; then
    while read -r ref; do
        name="${ref%%@*}"; digest=""
        [[ "$ref" == *@* ]] && digest="${ref#*@}"
        repo="${name%%:*}"
        if [ -n "$digest" ]; then key="${repo}@${digest}"; else key="$name"; fi
        grep -qF "\"${key}\"" "$REPOS_JSON" 2>/dev/null || MISSING_IMAGES+=("$ref")
    done < <(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$COMPOSE_LIVE")
fi
if [ ${#MISSING_IMAGES[@]} -gt 0 ]; then
    warn "Not in the inherited Docker store: ${MISSING_IMAGES[*]}"
    warn "Installing boneio-containers-firstboot.service to pull them on first boot"
    cat > "$MNT/etc/systemd/system/boneio-containers-firstboot.service" <<'UNIT'
# Installed by black_debian_images/scripts/build_rootfs_offline.sh.
#
# This image was built on a PC, where no container image can be pulled. The
# compose file names images the build could not bring along; pull them and
# recreate the containers at the first boot that has a network, then never
# again.
[Unit]
Description=boneIO: pull the container images an offline-built image lacks
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/boneio/containers-pending

[Service]
Type=oneshot
WorkingDirectory=/home/boneio/docker/nodered
ExecStart=/usr/bin/docker compose -f /home/boneio/docker/nodered/docker-compose.yaml up -d
ExecStartPost=-/usr/bin/docker image prune -af
ExecStartPost=/bin/rm -f /var/lib/boneio/containers-pending
Restart=on-failure
RestartSec=2min
CPUWeight=20

[Install]
WantedBy=multi-user.target
UNIT
    mkdir -p "$MNT/var/lib/boneio"
    printf '%s\n' "${MISSING_IMAGES[@]}" > "$MNT/var/lib/boneio/containers-pending"
    ln -sf /etc/systemd/system/boneio-containers-firstboot.service \
        "$MNT/etc/systemd/system/multi-user.target.wants/boneio-containers-firstboot.service"
else
    info "  ✅ every image the compose file names is in the inherited Docker store"
fi

# Put the image's own resolv.conf back before the build dir disappears.
if [ -e "$RESOLV_BAK" ] || [ -L "$RESOLV_BAK" ]; then
    rm -f "$MNT/etc/resolv.conf"; cp -P "$RESOLV_BAK" "$MNT/etc/resolv.conf"
fi

$FAIL && die "Verification failed — image left at $OUT_IMG for inspection, NOT shrunk."

# ─── 6. Shrink (same result as create_rootfs_img.sh on an SD card) ──────────

cleanup; trap - EXIT
if ! $SHRINK; then info "Done (not shrunk): $OUT_IMG"; exit 0; fi

phase "6/6 Shrink"
LOOP=$(losetup -fP --show "$OUT_IMG"); sleep 1
ROOT_PART="${LOOP}p${ROOT_NUM}"
e2fsck -f -y "$ROOT_PART" || [ $? -le 1 ] || die "e2fsck failed"
resize2fs -M "$ROOT_PART"
BLOCKS=$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | awk -F: '/^Block count/{gsub(/ /,"",$2);print $2}')
BSIZE=$(dumpe2fs -h "$ROOT_PART" 2>/dev/null | awk -F: '/^Block size/{gsub(/ /,"",$2);print $2}')
losetup -d "$LOOP"; LOOP=""

PART_MB=$(( BLOCKS * BSIZE / 1024 / 1024 + 32 ))
START=$(sfdisk -l "$OUT_IMG" | awk -v p="${OUT_IMG}${ROOT_NUM}" '$1==p{print $2}')
SECTORS=$(( PART_MB * 1024 * 1024 / 512 ))
echo "${START} ${SECTORS}" | sfdisk -N "$ROOT_NUM" --no-reread --force "$OUT_IMG" >/dev/null
truncate -s $(( (START + SECTORS + 2048) * 512 )) "$OUT_IMG"

info "Done: $OUT_IMG ($(du -h --apparent-size "$OUT_IMG" | cut -f1))"
info "Next: sudo ./scripts/generate_all_images.sh $OUT_IMG <version> --emmc-flasher"
