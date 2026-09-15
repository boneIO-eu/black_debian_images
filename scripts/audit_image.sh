#!/usr/bin/env bash
#
# audit_image.sh — report what a boneIO Black image actually ships.
#
# The pentest findings that remain open are image-side (F-04, F-05, F-10, and
# SSH throttling), and none of them can be settled by reading the build
# scripts: the production path may differ from the USB bring-up path, and a
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
            local method
            method="$(awk -F: -v u="$BONEIO_USER" '$1==u {print $2}' /etc/shadow 2>/dev/null | cut -d'$' -f2)"
            record FAIL "F-04" "$title" \
                "A password is set (hash method \$${method:-?}\$). Target state is no password at all; \
the image must not ship one. Confirm whether it is still the published default from a workstation: \
sshpass -p 'Black' ssh -o PreferredAuthentications=password ${BONEIO_USER}@<device> true"
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
check_setup_leftover
check_docker_group
check_full_sudo
check_mqtt_default_password
check_mosquitto_passwd_perms
check_exposed_ports
check_plaintext_panel
check_certificate_lifetime
check_sshd
check_ssh_throttling
check_account_store
check_api_requires_auth
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
