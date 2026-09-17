#!/usr/bin/env bash
#
# audit_image.sh — report what a boneIO Black image actually ships.
#
# Most of what remains open is image-side (F-04, F-05, F-10 and SSH
# throttling), and none of it can be settled by reading the build scripts: the production path may differ from the USB bring-up path, and a
# device that has been upgraded is not the same as one freshly flashed. So
# this asks the running system instead.
#
# READ ONLY. It reads files, lists sockets, and opens two local connections
# (MQTT on loopback, TLS on the panel port) to see what answers. It changes
# nothing, installs nothing and starts nothing. Safe on a production device.
#
# Usage, on the device:
#   sudo bash audit_image.sh            # full coverage
#   bash audit_image.sh                 # works, but the checks that need root
#                                       # report UNKNOWN rather than guessing
#
# From a workstation or from CI:
#   ssh boneio@<device> 'sudo bash -s' < scripts/audit_image.sh
#   ssh boneio@<device> 'sudo bash -s -- --json' < scripts/audit_image.sh
#
# Exit status:
#   0  nothing failed
#   1  at least one check failed
#   2  the script itself could not run
#
# UNKNOWN never counts as a failure. A check that could not be performed is
# not a check that passed, and saying so is the whole point — an audit that
# quietly reports "fine" when it could not look is worse than no audit.

set -uo pipefail

JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) JSON=1 ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

BONEIO_USER="${BONEIO_USER:-boneio}"
WEB_PORT="${WEB_PORT:-8090}"
PROXY_HTTP_PORT="${PROXY_HTTP_PORT:-8091}"
PROXY_TLS_PORT="${PROXY_TLS_PORT:-8443}"
MQTT_PORT="${MQTT_PORT:-1883}"

#: The credentials this project has shipped. Named here because they are
#: published — in UPDATE.md and in the build scripts — which is exactly what
#: makes them worth testing for rather than treating as secret.
DEFAULT_MQTT_PASSWORD="${DEFAULT_MQTT_PASSWORD:-boneio123}"

IS_ROOT=0
[[ "$(id -u)" == "0" ]] && IS_ROOT=1

PASS_COUNT=0
FAIL_COUNT=0
UNKNOWN_COUNT=0
ROWS=()

# ---------------------------------------------------------------- reporting

# record <status> <finding> <title> <detail>
record() {
    local status="$1" finding="$2" title="$3" detail="$4"
    case "$status" in
        PASS) PASS_COUNT=$((PASS_COUNT + 1)) ;;
        FAIL) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
        *)    UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    esac
    ROWS+=("${status}|${finding}|${title}|${detail}")
}

# Escape a string for embedding in JSON.
json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g'
}

#: How to re-run with privileges. Not derived from $0 — the script is usually
#: fed to `bash -s` over SSH, where $0 is just "bash".
RERUN_HINT="ssh <device> 'sudo bash -s' < scripts/audit_image.sh"

needs_root() {
    record UNKNOWN "$1" "$2" "Needs root. Re-run as: ${RERUN_HINT}"
}

# ------------------------------------------------- F-04 privileged helpers
#
# These six describe the posture the 1.6 migration chain is supposed to leave
# behind. Without them the audit reports on the state of affairs before any of
# it existed: the docker group and the blanket sudo rule would be flagged, and
# everything meant to replace them would go unmentioned.

#: Where the trust anchors are pinned, outside the application's reach.
PINNED_DIR="/etc/boneio"
HELPER_V2="/usr/sbin/boneio-migrate-v2"
HELPER_LEGACY="/usr/sbin/boneio-migrate"
TRUSTED_DIR="/usr/lib/boneio/trusted"

# Whether a path is a regular file owned by root and not writable by others.
root_owned() {
    local path="$1" stat_out
    [ -f "$path" ] || return 1
    [ -L "$path" ] && return 1
    stat_out=$(stat -c '%u %a' "$path" 2>/dev/null) || return 1
    local uid="${stat_out%% *}" mode="${stat_out##* }"
    [ "$uid" = "0" ] || return 1
    # No write bit for group, and none for other. Checked digit by digit
    # rather than with a glob, because a glob over the whole mode cannot tell
    # a group bit from an other bit and a 4-digit mode shifts the positions.
    local group_digit="${mode: -2:1}" other_digit="${mode: -1:1}"
    case "$group_digit" in
        2|3|6|7) return 1 ;;
    esac
    case "$other_digit" in
        2|3|6|7) return 1 ;;
    esac
    return 0
}

check_legacy_migration_helper() {
    local title="Legacy migration helper removed"
    if [ -e "$HELPER_LEGACY" ]; then
        if [ -L "$HELPER_LEGACY" ]; then
            record PASS "F-04" "$title" \
                "'${HELPER_LEGACY}' is a symlink, which is how the retirement migration \
keeps old call sites working. The protocol 1 code path is gone."
        else
            record FAIL "F-04" "$title" \
                "'${HELPER_LEGACY}' is still a real file. It accepts a whole migration plan \
over stdin — actions, asset digests and a validate_cmd it runs as root — so whoever holds the \
'${BONEIO_USER}' account has root through a legitimate call (CVE-2026-77055). Migration 1.6.6 \
removes it once boneio-migrate-v2 passes its selftest; if it is still here, either the \
migrations have not run or the selftest is failing."
        fi
    else
        record PASS "F-04" "$title" "'${HELPER_LEGACY}' is gone."
    fi
}

check_signing_helper() {
    local title="Signature-verifying migration helper"
    if [ ! -x "$HELPER_V2" ]; then
        record FAIL "F-04" "$title" \
            "'${HELPER_V2}' is not installed, so migrations either do not run at all or still \
go through the helper that trusts its caller. Migration 1.6.5 installs it."
        return
    fi
    if [ "$(id -u)" -ne 0 ]; then
        record UNKNOWN "F-04" "$title" \
            "'${HELPER_V2}' is installed but its selftest needs root. Re-run as: ${RERUN_HINT}"
        return
    fi
    local output
    if output=$("$HELPER_V2" --selftest 2>&1); then
        record PASS "F-04" "$title" \
            "'${HELPER_V2}' is installed and its selftest passes: signature verification works \
in both directions and both trust anchors are pinned."
    else
        record FAIL "F-04" "$title" \
            "'${HELPER_V2}' is installed but its selftest fails, so the runner will keep using \
the legacy helper and the hardening never completes. Output: $(printf '%s' "$output" | tail -3 | tr '\n' ' ')"
    fi
}

check_trust_anchors() {
    local title="Migration trust anchors"
    local missing=() loose=()
    local anchor
    for anchor in migrations.pem migrations-recovery.pem; do
        if [ ! -e "${PINNED_DIR}/${anchor}" ]; then
            missing+=("$anchor")
        elif ! root_owned "${PINNED_DIR}/${anchor}"; then
            loose+=("$anchor")
        fi
    done
    if [ ${#missing[@]} -eq 0 ] && [ ${#loose[@]} -eq 0 ]; then
        record PASS "F-04" "$title" \
            "Both anchors are pinned in ${PINNED_DIR} and root-owned. The recovery anchor is \
what makes a lost release key survivable: re-pinning needs a migration signed by a key the \
device already trusts."
        return
    fi
    local detail=""
    [ ${#missing[@]} -gt 0 ] && detail="missing: ${missing[*]}. "
    [ ${#loose[@]} -gt 0 ] && detail="${detail}not root-owned: ${loose[*]}. "
    record FAIL "F-04" "$title" \
        "${detail}A missing release anchor means the helper refuses every migration; a missing \
recovery anchor means a lost release key would leave this device unable to accept a signed \
migration ever again. An anchor writable by anyone else is not an anchor."
}

check_dev_hatch() {
    local title="Unsigned migrations hatch"
    if [ -e "${PINNED_DIR}/allow-unsigned-migrations" ]; then
        record FAIL "F-04" "$title" \
            "'${PINNED_DIR}/allow-unsigned-migrations' exists, so the helper accepts a plan \
handed to it over stdin. That is protocol 1 behaviour and reopens CVE-2026-77055 — it is a \
development hatch and must not ship."
    else
        record PASS "F-04" "$title" "No unsigned-migration hatch present."
    fi
}

check_helper_sudo_rules() {
    local title="Helper sudo rules"
    local fragment="/etc/sudoers.d/boneio-helpers"
    if [ ! -e "$fragment" ]; then
        record FAIL "F-04" "$title" \
            "'${fragment}' is absent, so nothing can call the privileged helpers without a \
password and the application falls back to the paths being removed."
        return
    fi
    if [ "$(id -u)" -ne 0 ] && [ ! -r "$fragment" ]; then
        record UNKNOWN "F-04" "$title" "Needs root to read ${fragment}. Re-run as: ${RERUN_HINT}"
        return
    fi
    # Every NOPASSWD target in the fragment must be one of the three helpers.
    local unexpected
    unexpected=$(grep -v '^[[:space:]]*#' "$fragment" 2>/dev/null \
        | grep -oE '/usr/sbin/[A-Za-z0-9_-]+' \
        | grep -vE '^/usr/sbin/boneio-(migrate-v2|containers|system)$' || true)
    if [ -n "$unexpected" ]; then
        record FAIL "F-04" "$title" \
            "'${fragment}' grants passwordless sudo to something other than the three \
closed-vocabulary helpers: $(printf '%s' "$unexpected" | tr '\n' ' '). Each of those is a \
separate path to root."
        return
    fi
    if grep -qE 'install-helpers|reinstall' "$fragment" 2>/dev/null; then
        record FAIL "F-04" "$title" \
            "'${fragment}' contains a rule for reinstalling the helpers. A script that restores \
the trust anchors lets an attacker re-pin their own key and sign every future plan; recovery is \
supposed to go through boneio-helpers-heal.service and the root-owned pristine copy."
        return
    fi
    record PASS "F-04" "$title" \
        "'${fragment}' names only the three closed-vocabulary helpers, and there is no rule for \
reinstalling them."
}

check_pristine_copy() {
    local title="Pristine helper copy and self-heal"
    if [ ! -d "$TRUSTED_DIR" ]; then
        record FAIL "F-04" "$title" \
            "'${TRUSTED_DIR}' does not exist, so boneio-helpers-heal.service has nothing to \
restore from. A helper that goes missing then needs a console or a reflash."
        return
    fi
    local missing=()
    local name
    for name in boneio-migrate-v2 boneio-containers boneio-system \
                sudoers-boneio-helpers migrations.pem migrations-recovery.pem; do
        root_owned "${TRUSTED_DIR}/${name}" || missing+=("$name")
    done
    local unit_state="unknown"
    if command -v systemctl >/dev/null 2>&1; then
        unit_state=$(systemctl is-enabled boneio-helpers-heal.service 2>/dev/null || echo "not-enabled")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        record FAIL "F-04" "$title" \
            "Missing or not root-owned in ${TRUSTED_DIR}: ${missing[*]}. The heal unit refuses \
to restore a partial trust chain, so this is the state that needs a console."
    elif [ "$unit_state" != "enabled" ]; then
        record FAIL "F-04" "$title" \
            "The pristine copy is complete but boneio-helpers-heal.service is '${unit_state}'. \
Nothing will restore the helpers at boot, and the recovery path deliberately does not go \
through the ${BONEIO_USER} account."
    else
        record PASS "F-04" "$title" \
            "'${TRUSTED_DIR}' is complete and root-owned, and boneio-helpers-heal.service is \
enabled."
    fi
}

check_compose_ownership() {
    local title="Compose file ownership"
    local compose
    compose=$(eval echo "~${BONEIO_USER}")/docker/nodered/docker-compose.yaml
    if [ ! -e "$compose" ]; then
        record PASS "F-04" "$title" "No compose project at ${compose}."
        return
    fi
    if root_owned "$compose"; then
        record PASS "F-04" "$title" \
            "'${compose}' is root-owned. That file is what 'docker compose up' executes, so \
being able to write it is being able to run a container as root with the host filesystem \
mounted — which is why routing the commands through a helper is not enough on its own."
    else
        record FAIL "F-04" "$title" \
            "'${compose}' is writable by someone other than root: $(stat -c '%U:%G %a' "$compose" 2>/dev/null). \
Whoever can write it can start a container as root with the host filesystem mounted, no matter \
how narrow the sudo rule on docker is. Migration 1.6.5 takes it to root:root 0644."
    fi
}

# ------------------------------------------------------------ F-04 accounts

check_ssh_password_state() {
    local title="SSH password for '${BONEIO_USER}'"
    if [[ $IS_ROOT -eq 0 ]]; then
        needs_root "F-04" "$title"
        return
    fi
    if ! id "$BONEIO_USER" >/dev/null 2>&1; then
        record UNKNOWN "F-04" "$title" "No such account on this system."
        return
    fi

    local state
    state="$(passwd -S "$BONEIO_USER" 2>/dev/null | awk '{print $2}')"
    case "$state" in
        L|LK)
            record PASS "F-04" "$title" "Account is locked — password login cannot succeed."
            ;;
        NP)
            record FAIL "F-04" "$title" \
                "Account has an EMPTY password. Worse than a default one."
            ;;
        P|PS)
            # The method prefix says how it is hashed, never the hash itself.
            local method expired
            method="$(awk -F: -v u="$BONEIO_USER" '$1==u {print $2}' /etc/shadow 2>/dev/null | cut -d'$' -f2)"
            # Field 3 of /etc/shadow is the last-change day. 0 means expired,
            # so the next interactive login has to set a new one — which is
            # what the sealing step does. Worth distinguishing: a sealed image
            # and one that quietly ships a usable shared password are not the
            # same finding, even though both have a hash on disk.
            expired="$(awk -F: -v u="$BONEIO_USER" '$1==u {print $3}' /etc/shadow 2>/dev/null)"
            if [[ "$expired" == "0" ]]; then
                record FAIL "F-04" "$title" \
                    "A password is set (hash method \$${method:-?}\$) but expired, so the first \
interactive login must replace it. That stops the shipped password persisting on a device in use; \
it does not stop someone who knows it from logging in once and setting their own. Fully closing this \
means shipping no usable password — keys only, or a per-device secret."
            else
                record FAIL "F-04" "$title" \
                    "A password is set (hash method \$${method:-?}\$) and NOT expired, so it \
survives untouched on every device that ships. Confirm whether it is still the published default from \
a workstation: sshpass -p 'Black' ssh -o PreferredAuthentications=password ${BONEIO_USER}@<device> true"
            fi
            ;;
        *)
            record UNKNOWN "F-04" "$title" "passwd -S said: ${state:-nothing}"
            ;;
    esac
}

check_blanket_nopasswd() {
    local title="Passwordless full sudo"
    if [[ $IS_ROOT -eq 0 ]]; then
        needs_root "F-04" "$title"
        return
    fi
    local hits
    hits="$(grep -rhE '^[^#]*NOPASSWD:[[:space:]]*ALL' /etc/sudoers /etc/sudoers.d/ 2>/dev/null | tr -s ' ')"
    if [[ -n "$hits" ]]; then
        record FAIL "F-04" "$title" \
            "NOPASSWD: ALL is granted — root with no credential at all: $(echo "$hits" | paste -sd';' -)"
    else
        record PASS "F-04" "$title" "No NOPASSWD: ALL rule."
    fi
}

check_setup_leftover() {
    local title="Build-time sudo rule left behind"
    if [[ -e /etc/sudoers.d/boneio-setup ]]; then
        record FAIL "F-04" "$title" \
            "/etc/sudoers.d/boneio-setup exists. build_image_usb.sh writes it with NOPASSWD: ALL \
for the duration of setup and no script removes it."
    else
        record PASS "F-04" "$title" "/etc/sudoers.d/boneio-setup is absent."
    fi
}

check_docker_group() {
    local title="Docker group membership"
    if id -nG "$BONEIO_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
        record FAIL "F-04" "$title" \
            "'${BONEIO_USER}' is in the docker group, which is root without sudo and without a \
password: any container can bind-mount the host filesystem. Anything that runs code as this \
account is already root."
    else
        record PASS "F-04" "$title" "'${BONEIO_USER}' is not in the docker group."
    fi
}

check_full_sudo() {
    local title="Unrestricted sudo"
    local groups
    groups="$(id -nG "$BONEIO_USER" 2>/dev/null)"
    if echo "$groups" | tr ' ' '\n' | grep -qxE 'sudo|admin|wheel'; then
        record FAIL "F-04" "$title" \
            "'${BONEIO_USER}' is in [$(echo "$groups" | tr ' ' '\n' | grep -xE 'sudo|admin|wheel' | paste -sd, -)], \
so it may run any command (a password is still required). The service account running the web \
app should hold only the narrow NOPASSWD rules it actually uses."
    else
        record PASS "F-04" "$title" "'${BONEIO_USER}' has no blanket sudo grant."
    fi
}

# ---------------------------------------------------------------- F-05 MQTT

check_mqtt_default_password() {
    local title="Default MQTT password"
    local python=""
    for candidate in "/home/${BONEIO_USER}/venv/bin/python" "$(command -v python3 2>/dev/null)"; do
        [[ -x "$candidate" ]] && { python="$candidate"; break; }
    done
    if [[ -z "$python" ]]; then
        record UNKNOWN "F-05" "$title" "No Python available to speak MQTT."
        return
    fi

    local result
    result="$("$python" - "$MQTT_PORT" "$DEFAULT_MQTT_PASSWORD" <<'PY' 2>/dev/null
import socket, struct, sys

port, password = int(sys.argv[1]), sys.argv[2]


def encode(value: bytes) -> bytes:
    return struct.pack("!H", len(value)) + value


def connect(user: str, password: str) -> str:
    """Speak just enough MQTT 3.1.1 to learn whether the broker accepts these."""
    payload = encode(b"boneio-audit") + encode(user.encode()) + encode(password.encode())
    variable = encode(b"MQTT") + bytes([4, 0xC2]) + struct.pack("!H", 10)
    body = variable + payload
    packet = bytes([0x10]) + bytes([len(body)]) + body
    try:
        with socket.create_connection(("127.0.0.1", port), 5) as sock:
            sock.sendall(packet)
            reply = sock.recv(4)
    except OSError:
        return "unreachable"
    if len(reply) < 4 or reply[0] != 0x20:
        return "unexpected"
    return "accepted" if reply[3] == 0 else "refused"


for account in ("boneio", "homeassistant", "mqtt"):
    print(f"{account}:{connect(account, password)}")
PY
)"

    if [[ -z "$result" ]]; then
        record UNKNOWN "F-05" "$title" "Could not talk to the broker."
        return
    fi
    if grep -q "unreachable" <<<"$result"; then
        record UNKNOWN "F-05" "$title" "No broker listening on 127.0.0.1:${MQTT_PORT}."
        return
    fi

    local accepted
    accepted="$(grep ':accepted$' <<<"$result" | cut -d: -f1 | paste -sd, -)"
    if [[ -n "$accepted" ]]; then
        record FAIL "F-05" "$title" \
            "The broker accepts the published default password for: ${accepted}. It is identical on \
every device ever shipped and documented in UPDATE.md."
    else
        record PASS "F-05" "$title" "The default password is refused for every account."
    fi
}

check_mosquitto_passwd_perms() {
    local title="Mosquitto password file permissions"
    local file=/etc/mosquitto/passwd
    if [[ ! -e "$file" ]]; then
        record UNKNOWN "F-11" "$title" "$file does not exist."
        return
    fi
    local mode owner
    mode="$(stat -c '%a' "$file" 2>/dev/null)"
    owner="$(stat -c '%U:%G' "$file" 2>/dev/null)"
    if [[ "$mode" == "640" || "$mode" == "600" ]] && [[ "$owner" == root:mosquitto || "$owner" == mosquitto:mosquitto ]]; then
        record PASS "F-11" "$title" "${mode} ${owner}"
    else
        record FAIL "F-11" "$title" \
            "${mode} ${owner} — the hashes are readable beyond the broker. Expected 640 root:mosquitto."
    fi
}

# ----------------------------------------------------------- F-10 transport

check_exposed_ports() {
    local title="Services reachable from the network"
    local listing
    listing="$(ss -tlnH 2>/dev/null || netstat -tln 2>/dev/null)"
    if [[ -z "$listing" ]]; then
        record UNKNOWN "F-10" "$title" "Neither ss nor netstat is available."
        return
    fi

    local exposed=()
    local port
    for port in "$WEB_PORT" "$PROXY_HTTP_PORT" "$MQTT_PORT"; do
        if grep -qE "(0\.0\.0\.0|\[::\]|\*):${port}[[:space:]]" <<<"$listing"; then
            exposed+=("$port")
        fi
    done

    if [[ ${#exposed[@]} -eq 0 ]]; then
        record PASS "F-10" "$title" \
            "Ports ${WEB_PORT}, ${PROXY_HTTP_PORT} and ${MQTT_PORT} are not bound to every interface."
    else
        record FAIL "F-10" "$title" \
            "Bound to every interface, in clear text: $(IFS=,; echo "${exposed[*]}"). The panel should \
reach the network only through the TLS proxy on ${PROXY_TLS_PORT}."
    fi
}

check_plaintext_panel() {
    local title="Panel served over plain HTTP"
    if ! command -v curl >/dev/null 2>&1; then
        record UNKNOWN "F-10" "$title" "curl is not installed."
        return
    fi
    local code
    code="$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PROXY_HTTP_PORT}/" 2>/dev/null)"
    if [[ "$code" == "200" ]]; then
        record FAIL "F-10" "$title" \
            "http://…:${PROXY_HTTP_PORT}/ answers 200. Credentials and session tokens cross the \
network unencrypted; it should redirect to ${PROXY_TLS_PORT}."
    elif [[ "$code" =~ ^30[1278]$ ]]; then
        record PASS "F-10" "$title" "Plain HTTP redirects (${code})."
    else
        record UNKNOWN "F-10" "$title" "Plain HTTP answered ${code:-nothing}."
    fi
}

check_certificate_lifetime() {
    local title="TLS certificate"
    if ! command -v openssl >/dev/null 2>&1; then
        record UNKNOWN "F-10" "$title" "openssl is not installed."
        return
    fi
    local cert
    cert="$(echo | openssl s_client -connect "127.0.0.1:${PROXY_TLS_PORT}" 2>/dev/null \
        | openssl x509 -noout -issuer -dates 2>/dev/null)"
    if [[ -z "$cert" ]]; then
        record UNKNOWN "F-10" "$title" "Nothing answered TLS on ${PROXY_TLS_PORT}."
        return
    fi

    local issuer not_before not_after hours
    issuer="$(sed -n 's/^issuer=//p' <<<"$cert" | head -1)"
    not_before="$(sed -n 's/^notBefore=//p' <<<"$cert")"
    not_after="$(sed -n 's/^notAfter=//p' <<<"$cert")"
    hours=$(( ( $(date -d "$not_after" +%s 2>/dev/null || echo 0)
              - $(date -d "$not_before" +%s 2>/dev/null || echo 0) ) / 3600 ))

    if grep -qi "Caddy Local Authority" <<<"$issuer"; then
        record FAIL "F-10" "$title" \
            "Self-signed by Caddy's internal CA, valid ${hours}h. Browsers warn on every visit, and \
anyone who trusts it by hand re-does that $(( hours > 0 ? 24 / hours : 0 ))× a day."
    else
        record PASS "F-10" "$title" "Issued by ${issuer}, valid ${hours}h."
    fi
}

# ------------------------------------------------------------ SSH hardening

sshd_effective() {
    # sshd -T prints the effective configuration, including defaults, which a
    # grep of the file cannot see: every directive here is commented out on a
    # stock Debian and still has a value.
    if [[ $IS_ROOT -eq 1 ]] && command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null
    elif [[ $IS_ROOT -eq 1 ]] && [[ -x /usr/sbin/sshd ]]; then
        /usr/sbin/sshd -T 2>/dev/null
    fi
}

check_sshd() {
    local title="SSH login settings"
    if [[ $IS_ROOT -eq 0 ]]; then
        needs_root "F-06" "$title"
        return
    fi
    if ! command -v sshd >/dev/null 2>&1 && [[ ! -x /usr/sbin/sshd ]]; then
        record UNKNOWN "F-06" "$title" "sshd is not installed on this system."
        return
    fi

    local config
    config="$(sshd_effective)"
    if [[ -z "$config" ]]; then
        record UNKNOWN "F-06" "$title" \
            "sshd -T produced nothing — the configuration may be invalid."
        return
    fi

    local password_auth max_auth permit_root empty
    password_auth="$(awk '/^passwordauthentication /{print $2}' <<<"$config")"
    max_auth="$(awk '/^maxauthtries /{print $2}' <<<"$config")"
    permit_root="$(awk '/^permitrootlogin /{print $2}' <<<"$config")"
    empty="$(awk '/^permitemptypasswords /{print $2}' <<<"$config")"

    if [[ "$password_auth" == "no" ]]; then
        record PASS "F-04" "SSH password authentication" "Disabled; keys only."
    else
        record FAIL "F-04" "SSH password authentication" \
            "Enabled. With no shipped password this is merely unnecessary; with one it is the way in."
    fi

    if [[ "$empty" == "yes" ]]; then
        record FAIL "F-04" "Empty SSH passwords" "PermitEmptyPasswords yes."
    else
        record PASS "F-04" "Empty SSH passwords" "Refused."
    fi

    record "$([[ "$permit_root" == "no" ]] && echo PASS || echo FAIL)" \
        "F-04" "Root login over SSH" "PermitRootLogin ${permit_root}"

    if [[ -n "$max_auth" ]] && (( max_auth <= 3 )); then
        record PASS "F-06" "SSH attempts per connection" "MaxAuthTries ${max_auth}"
    else
        record FAIL "F-06" "SSH attempts per connection" \
            "MaxAuthTries ${max_auth:-unset} — the stock default. Guessing is only bounded by patience."
    fi
}

check_ssh_throttling() {
    local title="SSH brute-force throttling"
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        record PASS "F-06" "$title" "fail2ban is running."
    elif command -v fail2ban-server >/dev/null 2>&1; then
        record FAIL "F-06" "$title" "fail2ban is installed but not running."
    else
        record FAIL "F-06" "$title" \
            "Nothing throttles SSH. The web login is rate-limited since 1.6; SSH is not."
    fi
}

# ------------------------------------------------------- application state

check_account_store() {
    local title="Panel account store"
    local store
    store="$(ls /home/${BONEIO_USER}/boneio/users.json 2>/dev/null | head -1)"
    if [[ -z "$store" ]]; then
        record FAIL "F-02" "$title" \
            "users.json is absent — the device has no panel account and is waiting for whoever \
reaches the first-run wizard first."
        return
    fi
    local mode owner
    mode="$(stat -c '%a' "$store")"
    owner="$(stat -c '%U' "$store")"
    if [[ "$mode" == "600" ]]; then
        record PASS "F-02" "$title" "${store} ${mode} ${owner}"
    else
        record FAIL "F-02" "$title" "${store} is ${mode} ${owner}; the hashes should be 600."
    fi
}

check_api_requires_auth() {
    local title="API refuses anonymous callers"
    if ! command -v curl >/dev/null 2>&1; then
        record UNKNOWN "F-02" "$title" "curl is not installed."
        return
    fi
    local code
    code="$(curl -s -m 6 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${WEB_PORT}/api/outputs" 2>/dev/null)"
    case "$code" in
        401|403) record PASS "F-02" "$title" "GET /api/outputs → ${code}" ;;
        200)     record FAIL "F-02" "$title" \
                    "GET /api/outputs → 200 without a token. Either no account exists or \
web.auth.allow_anonymous is set." ;;
        *)       record UNKNOWN "F-02" "$title" "GET /api/outputs → ${code:-no answer}" ;;
    esac
}

check_api_docs() {
    local title="Interactive API docs"
    if ! command -v curl >/dev/null 2>&1; then
        record UNKNOWN "F-02" "$title" "curl is not installed."
        return
    fi

    # AuthMiddleware only gates paths under /api, so these three sit outside it
    # and cannot be protected — they have to be absent. openapi.json is the one
    # that matters: it is a complete map of every route, parameter and schema.
    local open=""
    local path code
    for path in /docs /redoc /openapi.json; do
        code="$(curl -s -m 6 -o /dev/null -w '%{http_code}' \
            "http://127.0.0.1:${WEB_PORT}${path}" 2>/dev/null)"
        [[ "$code" == "200" ]] && open="${open}${open:+, }${path}"
    done

    if [[ -n "$open" ]]; then
        record FAIL "F-02" "$title" \
            "Served without a token: ${open}. Anyone on the network gets the full API \
surface. Fixed by docs_url/redoc_url/openapi_url=None in webui/app.py; BONEIO_DEV \
restores them on purpose, so check the development-mode row too."
    else
        record PASS "F-02" "$title" "/docs, /redoc and /openapi.json do not answer."
    fi
}

check_serial_disclosure() {
    local title="Serial number in unauthenticated replies"
    if ! command -v curl >/dev/null 2>&1; then
        record UNKNOWN "F-03" "$title" "curl is not installed."
        return
    fi

    # /api/version and /api/init answer without a token by design — the panel
    # needs them to decide whether to show a login form — but the serial
    # identifies the unit and feeds its cloud subdomain and MQTT topics.
    local anon
    anon="$(curl -s -m 6 -o /dev/null -w '%{http_code}' \
        "http://127.0.0.1:${WEB_PORT}/api/outputs" 2>/dev/null)"
    if [[ "$anon" == "200" ]]; then
        record UNKNOWN "F-03" "$title" \
            "Not meaningful here: the whole API answers anonymously, so the serial is the \
least of it. See the row above about anonymous callers."
        return
    fi

    local leaking=""
    local path body
    for path in /api/version /api/init; do
        body="$(curl -s -m 6 "http://127.0.0.1:${WEB_PORT}${path}" 2>/dev/null)"
        grep -q '"serial_no"' <<<"$body" && leaking="${leaking}${leaking:+, }${path}"
    done

    if [[ -n "$leaking" ]]; then
        record FAIL "F-03" "$title" \
            "Returned without a token by: ${leaking}. The serial should reach signed-in \
callers only."
    else
        record PASS "F-03" "$title" \
            "/api/version and /api/init withhold serial_no from anonymous callers."
    fi
}

check_firewall_state() {
    local title="Firewall"
    # Resolved by path, not command -v: ufw lives in /usr/sbin, which is not on
    # a non-root user's PATH on Debian, and this script is often run unprivileged.
    local ufw_bin=""
    local candidate
    for candidate in /usr/sbin/ufw /sbin/ufw "$(command -v ufw 2>/dev/null)"; do
        [[ -n "$candidate" && -x "$candidate" ]] && { ufw_bin="$candidate"; break; }
    done
    if [[ -z "$ufw_bin" ]]; then
        record UNKNOWN "F-10" "$title" "ufw is not installed."
        return
    fi
    if [[ $IS_ROOT -eq 0 ]]; then
        needs_root "F-10" "$title"
        return
    fi

    local state
    state="$("$ufw_bin" status 2>/dev/null | head -1)"
    if [[ "$state" == *"inactive"* ]]; then
        # setup_boneio.sh stages allow rules but never enables ufw, so this is
        # the expected state. Reported rather than passed over: someone reading
        # the rule list could reasonably think the device is filtered.
        record UNKNOWN "F-10" "$title" \
            "ufw is inactive — the allow rules staged by setup are not in force and nothing is \
filtered. Enabling it is a deliberate choice; check that 22 and 8443 are in the rule list first."
    elif [[ "$state" == *"active"* ]]; then
        local missing=""
        local port
        for port in 22 8443; do
            "$ufw_bin" status 2>/dev/null | grep -qE "^${port}[[:space:]/]" || missing="${missing}${missing:+, }${port}"
        done
        if [[ -n "$missing" ]]; then
            record FAIL "F-10" "$title" \
                "ufw is active but does not allow: ${missing}. Losing 22 means losing the only way \
back in; losing 8443 means losing the TLS panel."
        else
            record PASS "F-10" "$title" "ufw is active and allows 22 and 8443."
        fi
    else
        record UNKNOWN "F-10" "$title" "ufw status said: ${state:-nothing}"
    fi
}

check_dev_mode() {
    local title="Development mode"
    if grep -rqs 'BONEIO_DEV' /etc/systemd/system/boneio.service /etc/systemd/system/boneio.service.d/ 2>/dev/null; then
        record FAIL "F-13" "$title" \
            "BONEIO_DEV is set in the unit: development routes are mounted and CORS accepts local \
dev servers. Correct on a development board, never on a shipped one."
    else
        record PASS "F-13" "$title" "Not set."
    fi
}

# --------------------------------------------------------------------- main

check_ssh_password_state
check_blanket_nopasswd
check_legacy_migration_helper
check_signing_helper
check_trust_anchors
check_dev_hatch
check_helper_sudo_rules
check_pristine_copy
check_compose_ownership
check_setup_leftover
check_docker_group
check_full_sudo
check_mqtt_default_password
check_mosquitto_passwd_perms
check_firewall_state
check_exposed_ports
check_plaintext_panel
check_certificate_lifetime
check_sshd
check_ssh_throttling
check_account_store
check_api_requires_auth
check_api_docs
check_serial_disclosure
check_dev_mode

if [[ $JSON -eq 1 ]]; then
    printf '{\n  "host": "%s",\n' "$(json_escape "$(hostname)")"
    printf '  "date": "%s",\n' "$(date -Is)"
    printf '  "root": %s,\n' "$([[ $IS_ROOT -eq 1 ]] && echo true || echo false)"
    printf '  "summary": {"pass": %d, "fail": %d, "unknown": %d},\n' \
        "$PASS_COUNT" "$FAIL_COUNT" "$UNKNOWN_COUNT"
    printf '  "checks": [\n'
    for i in "${!ROWS[@]}"; do
        IFS='|' read -r status finding title detail <<<"${ROWS[$i]}"
        printf '    {"status": "%s", "finding": "%s", "title": "%s", "detail": "%s"}' \
            "$status" "$finding" "$(json_escape "$title")" "$(json_escape "$detail")"
        [[ $i -lt $(( ${#ROWS[@]} - 1 )) ]] && printf ','
        printf '\n'
    done
    printf '  ]\n}\n'
else
    echo
    echo "boneIO Black image audit — $(hostname) — $(date -Is)"
    [[ $IS_ROOT -eq 0 ]] && echo "Running without root: some checks report UNKNOWN."
    echo
    for row in "${ROWS[@]}"; do
        IFS='|' read -r status finding title detail <<<"$row"
        printf '%-8s %-6s %s\n' "$status" "$finding" "$title"
        # Squeeze the whitespace the source line continuations leave behind,
        # then wrap and indent every line the same, so the detail reads as one
        # paragraph rather than a ragged first line.
        echo "$detail" | tr -s ' ' | fold -s -w 72 | sed 's/^/                /'
        echo
    done
    echo "pass ${PASS_COUNT}   fail ${FAIL_COUNT}   unknown ${UNKNOWN_COUNT}"
    [[ $UNKNOWN_COUNT -gt 0 ]] && echo "UNKNOWN is not a pass — it means the check could not be performed."
fi

[[ $FAIL_COUNT -gt 0 ]] && exit 1
exit 0
