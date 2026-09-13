#!/bin/bash
# ============================================================
# wake_work_pc.sh  -  runs ON THE RASPBERRY PI
#
# Wakes the home PC, starts the Proxmox VM, and waits until RustDesk
# is accepting connections. Prints progress; exits 0 when ready.
#
# Does NOT launch a client. Whatever device called this (Android tablet,
# Mac, phone) opens RustDesk itself once this returns.
#
# Usage:   ssh pi 'wake_work_pc.sh'
# Config:  ~/.config/work-pc/config   (chmod 600)
# ============================================================

set -uo pipefail

CONFIG_FILE="${WORK_PC_CONFIG:-$HOME/.config/work-pc/config}"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: config not found at $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

: "${MAX_WAIT_HOST_BOOT:=240}"
: "${MAX_WAIT_VM_RUNNING:=60}"
: "${MAX_WAIT_RUSTDESK_PORT:=120}"
: "${POLL_INTERVAL:=5}"
: "${RUSTDESK_PORT:=21118}"
: "${PROXMOX_CACERT:=}"
: "${SKIP_WAKE_IF_UP:=1}"
: "${WAKE_ATTEMPTS:=3}"

log() {
    # Unbuffered so progress actually appears over SSH as it happens,
    # rather than arriving all at once when the script exits.
    printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
    log "ERROR: $1"
    exit 1
}

require_config() {
    local missing="" v
    for v in "$@"; do
        [ -z "${!v:-}" ] && missing="$missing $v"
    done
    [ -n "$missing" ] && fail "config is missing required values:$missing"
    return 0
}

require_config ETHERWAKE_CMD PROXMOX_HOST PROXMOX_NODE VM_ID \
               PROXMOX_TOKEN_ID PROXMOX_TOKEN_SECRET_FILE VM_TAILSCALE_IP

[ -r "$PROXMOX_TOKEN_SECRET_FILE" ] \
    || fail "cannot read token secret file: $PROXMOX_TOKEN_SECRET_FILE"

TOKEN_SECRET=$(cat "$PROXMOX_TOKEN_SECRET_FILE") \
    || fail "failed to read token secret"

wait_until() {
    local desc="$1" max="$2"
    shift 2
    local start now deadline
    start=$(date +%s)
    deadline=$(( start + max ))

    while ! "$@" >/dev/null 2>&1; do
        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            fail "timed out after $(( now - start ))s waiting for: $desc"
        fi
        log "  ...waiting on $desc ($(( now - start ))s / ${max}s)"
        sleep "$POLL_INTERVAL"
    done
}

# Token secret goes in via stdin, never argv - on a multi-user box `ps` is
# readable by everyone.
pve_curl() {
    local method="$1" path="$2"
    local tls out code body

    if [ -n "$PROXMOX_CACERT" ]; then
        tls=(--cacert "$PROXMOX_CACERT")
    else
        tls=(-k)
    fi

    out=$(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' \
              "$PROXMOX_TOKEN_ID" "$TOKEN_SECRET" \
          | curl -sS --config - "${tls[@]}" \
                 -X "$method" --max-time 10 \
                 -w '\n%{http_code}' \
                 "${PROXMOX_HOST}${path}")

    code="${out##*$'\n'}"
    body="${out%$'\n'*}"

    # stderr, not stdout: callers capture stdout as the response body.
    case "$code" in
        2*) printf '%s' "$body"; return 0 ;;
        000) log "[api] $method $path - no response" >&2; return 1 ;;
        *)   log "[api] $method $path - HTTP $code: $body" >&2; return 1 ;;
    esac
}

vm_status() {
    local body
    body=$(pve_curl GET "/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/current") || return 1
    printf '%s' "$body" | tr ',' '\n' | sed -n 's/.*"status":"\([^"]*\)".*/\1/p' | head -1
}

vm_is_running() {
    [ "$(vm_status 2>/dev/null)" = "running" ]
}

# Liveness only. /api2/json/version answers 401 without auth, and a 401 still
# proves the host has booted far enough to serve the API. Do not add -f.
proxmox_reachable() {
    curl -sk -o /dev/null --max-time 5 "$PROXMOX_HOST/api2/json/version"
}

rustdesk_ready() {
    nc -z -w 3 "$VM_TAILSCALE_IP" "$RUSTDESK_PORT"
}

# ---------------- 1. WAKE ----------------
# No SSH hop here: this script already runs on the Pi, inside the PC's
# broadcast domain, which is the whole reason the Pi is involved.
if [ "$SKIP_WAKE_IF_UP" = "1" ] && proxmox_reachable; then
    log "host already up, skipping wake"
else
    log "sending wake-on-LAN"
    wake_ok=0
    attempt=1
    while [ "$attempt" -le "$WAKE_ATTEMPTS" ]; do
        # Magic packets are UDP and get dropped; repeats are harmless.
        if $ETHERWAKE_CMD; then
            wake_ok=1
        else
            log "  wake attempt $attempt failed"
        fi
        attempt=$(( attempt + 1 ))
        [ "$attempt" -le "$WAKE_ATTEMPTS" ] && sleep 1
    done
    [ "$wake_ok" = "1" ] || fail "etherwake failed (check the sudoers rule)"

    log "waiting for Proxmox host to boot"
    wait_until "Proxmox API" "$MAX_WAIT_HOST_BOOT" proxmox_reachable
fi

# ---------------- 2. START VM ----------------
CURRENT_STATUS=$(vm_status) \
    || fail "Proxmox API rejected the status call - check token privsep and ACL"

if [ "$CURRENT_STATUS" = "running" ]; then
    log "VM $VM_ID already running"
else
    log "starting VM $VM_ID (currently: ${CURRENT_STATUS:-unknown})"
    pve_curl POST "/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/start" >/dev/null \
        || fail "failed to start VM"
    wait_until "VM status = running" "$MAX_WAIT_VM_RUNNING" vm_is_running
fi

# ---------------- 3. WAIT FOR RUSTDESK ----------------
log "waiting for RustDesk on $VM_TAILSCALE_IP:$RUSTDESK_PORT"
wait_until "RustDesk port" "$MAX_WAIT_RUSTDESK_PORT" rustdesk_ready

log "READY - connect RustDesk to $VM_TAILSCALE_IP"
