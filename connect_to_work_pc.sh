#!/bin/bash
# ============================================================
# connect_to_work_pc.sh
# One-click: Tailscale -> WOL via Pi -> Proxmox API start VM -> RustDesk
#
# Reads its settings from config.sh in the same folder.
# First time setup: cp config.example.sh config.sh, then edit config.sh.
#
# Plain ASCII on purpose. Targets macOS system bash 3.2.
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] config.sh not found next to this script." >&2
    echo "        Run: cp config.example.sh config.sh   then edit config.sh" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ---------------- DEFAULTS ----------------
# Set here so an older config.sh missing a key doesn't die with a bare
# "unbound variable" from somewhere deep in the script.
: "${MAX_WAIT_HOST_BOOT:=240}"
: "${MAX_WAIT_VM_RUNNING:=60}"
: "${MAX_WAIT_RUSTDESK_PORT:=120}"
: "${POLL_INTERVAL:=5}"
: "${RUSTDESK_PORT:=21118}"
: "${PROXMOX_CACERT:=}"          # path to pve-root-ca.pem; empty = skip TLS verify
: "${SKIP_WAKE_IF_UP:=1}"        # 0 to always send the magic packet
: "${WAKE_ATTEMPTS:=3}"
: "${LOG_FILE:=$HOME/Library/Logs/work-pc-launcher.log}"

NOTIFY_TITLE="Work PC Launcher"

# ---------------- LOGGING ----------------
# Automator swallows stdout, so everything goes to a file as well. Without
# this, a failure at 8am leaves you with a notification banner and nothing else.
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

# ---------------- HELPERS ----------------
# osascript gets the message as an argument, not interpolated into the script
# text: a quote or backslash in a message would otherwise break the AppleScript
# or, worse, run as AppleScript.
notify() {
    log "$1"
    osascript \
        -e 'on run {msg, ttl}' \
        -e 'display notification msg with title ttl' \
        -e 'end run' \
        "$1" "$NOTIFY_TITLE" >/dev/null 2>&1 || true
}

fail() {
    log "[ERROR] $1"
    osascript \
        -e 'on run {msg, ttl}' \
        -e 'display notification msg with title ttl sound name "Basso"' \
        -e 'end run' \
        "$1" "$NOTIFY_TITLE [FAIL]" >/dev/null 2>&1 || true
    log "--- run failed ---"
    exit 1
}

# Deadline is real wall-clock time. The old version accumulated POLL_INTERVAL
# per iteration and ignored how long each attempt took, so a 240 "second"
# budget could run ~528s once curl's own 6s timeout was counted.
wait_until() {
    local desc="$1"
    local max="$2"
    shift 2
    local start now deadline
    start=$(date +%s)
    deadline=$(( start + max ))

    while ! "$@" >/dev/null 2>&1; do
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            log "last attempt output for '$desc':"
            "$@" || true
            fail "Timed out after $(( now - start ))s waiting for: $desc"
        fi
        log "...still waiting on: $desc ($(( now - start ))s / ${max}s)"
        sleep "$POLL_INTERVAL"
    done
}

require_config() {
    local missing=""
    local v
    for v in "$@"; do
        if [ -z "${!v:-}" ]; then
            missing="$missing $v"
        fi
    done
    if [ -n "$missing" ]; then
        fail "config.sh is missing required values:$missing"
    fi
}

require_config PI_SSH_TARGET ETHERWAKE_CMD PROXMOX_HOST PROXMOX_NODE VM_ID \
               PROXMOX_TOKEN_ID KEYCHAIN_SERVICE VM_TAILSCALE_IP \
               KEYCHAIN_SERVICE_RUSTDESK

log "=== run started ==="

# ---------------- PROXMOX API WRAPPER ----------------
# Two things this fixes over an inline curl call:
#
# 1. The token secret goes in through a config file on stdin instead of the
#    command line, so it is not visible in `ps` for the life of the request.
# 2. HTTP status is actually checked. `curl -s` exits 0 on a 401 or 403, so
#    the old code treated "permission denied" as success and then timed out
#    later waiting for a VM that was never told to start.
pve_curl() {
    local method="$1"
    local path="$2"
    local tls out code body

    if [ -n "$PROXMOX_CACERT" ]; then
        tls=(--cacert "$PROXMOX_CACERT")
    else
        tls=(-k)
    fi

    out=$(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' \
              "$PROXMOX_TOKEN_ID" "$TOKEN_SECRET" \
          | curl -sS --config - "${tls[@]}" \
                 -X "$method" \
                 --max-time 10 \
                 -w '\n%{http_code}' \
                 "${PROXMOX_HOST}${path}")

    code="${out##*$'\n'}"
    body="${out%$'\n'*}"

    # Diagnostics go to stderr, NOT stdout. This function is called inside a
    # command substitution, so anything written to stdout is captured by the
    # caller as the response body instead of reaching the log.
    case "$code" in
        2*)
            printf '%s' "$body"
            return 0
            ;;
        000)
            log "[api] $method $path - no response (host unreachable or TLS failure)" >&2
            return 1
            ;;
        *)
            log "[api] $method $path - HTTP $code: $body" >&2
            return 1
            ;;
    esac
}

# Prints the VM's status word, or nothing if the call failed.
# Split on commas first so the pattern can only ever match the real "status"
# field. ("qmpstatus":"running" does not contain the literal "status":" that
# this matches, but splitting makes that obvious instead of subtle.)
# If you install jq, `jq -r .data.status` is the honest version of this.
vm_status() {
    local body
    body=$(pve_curl GET "/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/current") || return 1
    printf '%s' "$body" \
        | tr ',' '\n' \
        | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' \
        | head -1
}

vm_is_running() {
    [ "$(vm_status 2>/dev/null)" = "running" ]
}

# Liveness only. Deliberately does NOT check the HTTP status: /api2/json/version
# requires auth and answers 401 unauthenticated, and a 401 still proves the host
# has booted far enough to serve the API. Do not "fix" this by adding -f.
proxmox_reachable() {
    curl -sk -o /dev/null --max-time 5 "$PROXMOX_HOST/api2/json/version"
}

# ---------------- 0. TAILSCALE BINARY ----------------
# Handles both variants: standalone (CLI on PATH after enabling CLI integration
# in Settings) and Mac App Store (CLI bundled inside the app).
TAILSCALE_BIN="tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
    if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
        TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    else
        fail "Tailscale CLI not found (checked PATH and App Store bundle location)"
    fi
fi

# ---------------- 1. TAILSCALE ----------------
# BackendState is the real signal. `tailscale status` also exits nonzero when
# the daemon is up but logged out, which is a different problem.
ts_running() {
    "$TAILSCALE_BIN" status --json 2>/dev/null \
        | grep -q '"BackendState": *"Running"'
}

if ts_running; then
    notify "Tailscale already connected"
else
    notify "Connecting Tailscale..."
    # If the node key has expired this blocks on a browser login with no way to
    # time out. Disable key expiry on the Mac, Pi, PC and VM in the admin console.
    "$TAILSCALE_BIN" up || fail "Tailscale failed to connect"
    ts_running || fail "Tailscale up returned success but backend is not Running"
fi

# ---------------- 2. WAKE HOME PC VIA PI ----------------
if [ "$SKIP_WAKE_IF_UP" = "1" ] && proxmox_reachable; then
    notify "Proxmox host already up - skipping wake"
else
    notify "Sending wake-on-LAN via Raspberry Pi..."
    # The magic packet is UDP and can be dropped, so send it more than once.
    # Repeats are harmless against a machine that is already awake.
    wake_ok=0
    attempt=1
    while [ "$attempt" -le "$WAKE_ATTEMPTS" ]; do
        # No StrictHostKeyChecking override on purpose. If you re-image the Pi,
        # this will fail with a host key warning - that is the correct behaviour,
        # and the README says how to clear it.
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "$PI_SSH_TARGET" "$ETHERWAKE_CMD"; then
            wake_ok=1
        else
            log "wake attempt $attempt failed"
        fi
        attempt=$(( attempt + 1 ))
        [ "$attempt" -le "$WAKE_ATTEMPTS" ] && sleep 1
    done
    [ "$wake_ok" = "1" ] || \
        fail "Could not reach Pi over Tailscale / etherwake failed (check SSH key + sudoers)"
fi

# ---------------- 3. WAIT FOR PROXMOX HOST TO BOOT ----------------
notify "Waiting for Proxmox host to come online..."
wait_until "Proxmox API reachable" "$MAX_WAIT_HOST_BOOT" proxmox_reachable

# ---------------- 4. AUTH + CHECK/START VM ----------------
TOKEN_SECRET=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) \
    || fail "Proxmox API token not found in Keychain (service: $KEYCHAIN_SERVICE)"

CURRENT_STATUS=$(vm_status) \
    || fail "Proxmox API rejected the status call - check token privsep and ACL (see $LOG_FILE)"

if [ "$CURRENT_STATUS" = "running" ]; then
    notify "VM already running"
else
    notify "Starting VM $VM_ID (currently: ${CURRENT_STATUS:-unknown})..."
    pve_curl POST "/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/start" >/dev/null \
        || fail "Failed to start VM via Proxmox API (see $LOG_FILE)"
fi

# ---------------- 5. WAIT FOR PROXMOX TO REPORT VM RUNNING ----------------
notify "Waiting for Proxmox to report VM running..."
wait_until "VM status = running" "$MAX_WAIT_VM_RUNNING" vm_is_running

# ---------------- 6. WAIT FOR RUSTDESK'S PORT TO OPEN ----------------
notify "Waiting for RustDesk to be ready on the VM..."
wait_until "RustDesk port $RUSTDESK_PORT open on $VM_TAILSCALE_IP" "$MAX_WAIT_RUSTDESK_PORT" \
    nc -z -w 3 "$VM_TAILSCALE_IP" "$RUSTDESK_PORT"

# ---------------- 7. LAUNCH RUSTDESK ----------------
RUSTDESK_PASSWORD=$(security find-generic-password -s "$KEYCHAIN_SERVICE_RUSTDESK" -w 2>/dev/null) \
    || fail "RustDesk password not found in Keychain (service: $KEYCHAIN_SERVICE_RUSTDESK)"

notify "Launching RustDesk..."
# RustDesk's CLI offers no way to pass the password off the command line, so
# this one argument is briefly visible in `ps`. Do not add `set -x` to this
# script without removing that first - it would put the password in the log.
open -a "RustDesk" --args --connect "$VM_TAILSCALE_IP" --password "$RUSTDESK_PASSWORD" \
    || fail "Failed to launch RustDesk"

unset TOKEN_SECRET RUSTDESK_PASSWORD

notify "[OK] Connected - you're good to go"
log "=== run finished ==="
