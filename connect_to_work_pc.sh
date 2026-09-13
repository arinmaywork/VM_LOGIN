#!/bin/bash
# ============================================================
# connect_to_work_pc.sh
# One-click: Tailscale -> WOL via Pi -> Proxmox API start VM -> RustDesk
#
# Reads its settings from config.sh in the same folder.
# First time setup: cp config.example.sh config.sh, then edit config.sh.
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

# ---------------- HELPERS ----------------
notify() {
  osascript -e "display notification \"$1\" with title \"Work PC Launcher\"" 2>/dev/null
  echo "[INFO] $1"
}

fail() {
  osascript -e "display notification \"$1\" with title \"Work PC Launcher [FAIL]\" sound name \"Basso\"" 2>/dev/null
  echo "[ERROR] $1" >&2
  exit 1
}

wait_until() {
  # wait_until "description" max_seconds command...
  local desc="$1"; local max="$2"; shift 2
  local elapsed=0
  until "$@" >/dev/null 2>&1; do
    echo "[INFO]   ...still waiting on: $desc (${elapsed}s / ${max}s)"
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
    if [ "$elapsed" -ge "$max" ]; then
      fail "Timed out waiting for: $desc"
    fi
  done
}

# Handles both Tailscale variants: standalone (CLI on PATH after enabling
# CLI integration in Settings) and Mac App Store (CLI bundled inside the app).
TAILSCALE_BIN="tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  if [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
    TAILSCALE_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
  else
    fail "Tailscale CLI not found (checked PATH and App Store bundle location)"
  fi
fi

# ---------------- 1. TAILSCALE ----------------
if ! "$TAILSCALE_BIN" status >/dev/null 2>&1; then
  notify "Connecting Tailscale..."
  "$TAILSCALE_BIN" up || fail "Tailscale failed to connect"
else
  notify "Tailscale already connected"
fi

# ---------------- 2. WAKE HOME PC VIA PI (over Tailscale SSH) ----------------
notify "Sending wake-on-LAN via Raspberry Pi..."
ssh -o ConnectTimeout=10 -o BatchMode=yes "$PI_SSH_TARGET" \
  "$ETHERWAKE_CMD" \
  || fail "Could not reach Pi over Tailscale / etherwake failed (check SSH key + sudoers)"

# ---------------- 3. WAIT FOR PROXMOX HOST TO BOOT ----------------
notify "Waiting for Proxmox host to come online..."
wait_until "Proxmox API reachable" "$MAX_WAIT_HOST_BOOT" \
  curl -sk --max-time 6 "$PROXMOX_HOST/api2/json/version"

# ---------------- 4. AUTH + CHECK/START VM ----------------
TOKEN_SECRET=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) \
  || fail "Proxmox API token not found in Keychain (see setup notes)"

AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_TOKEN_ID}=${TOKEN_SECRET}"

VM_STATUS=$(curl -sk -H "$AUTH_HEADER" \
  "$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/current" \
  | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p')

if [ "$VM_STATUS" != "running" ]; then
  notify "Starting VM $VM_ID..."
  curl -sk -X POST -H "$AUTH_HEADER" \
    "$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/start" \
    >/dev/null || fail "Failed to start VM via Proxmox API"
else
  notify "VM already running"
fi

# ---------------- 5. WAIT FOR PROXMOX TO REPORT VM RUNNING ----------------
vm_is_running() {
  curl -sk -H "$AUTH_HEADER" \
    "$PROXMOX_HOST/api2/json/nodes/$PROXMOX_NODE/qemu/$VM_ID/status/current" \
    | grep -q '"status":"running"'
}

notify "Waiting for Proxmox to report VM running..."
wait_until "VM status = running" "$MAX_WAIT_VM_RUNNING" vm_is_running

# ---------------- 6. WAIT FOR RUSTDESK'S PORT TO ACTUALLY OPEN ----------------
notify "Waiting for RustDesk to be ready on the VM..."
wait_until "RustDesk port $RUSTDESK_PORT open on $VM_TAILSCALE_IP" "$MAX_WAIT_RUSTDESK_PORT" \
  nc -z -w 3 "$VM_TAILSCALE_IP" "$RUSTDESK_PORT"

# ---------------- 7. LAUNCH RUSTDESK (direct Tailscale IP) ----------------
RUSTDESK_PASSWORD=$(security find-generic-password -s "$KEYCHAIN_SERVICE_RUSTDESK" -w 2>/dev/null) \
  || fail "RustDesk password not found in Keychain (see setup notes)"

notify "Launching RustDesk..."
open -a "RustDesk" --args --connect "$VM_TAILSCALE_IP" --password "$RUSTDESK_PASSWORD" \
  || fail "Failed to launch RustDesk"

notify "[OK] Connected - you're good to go"
