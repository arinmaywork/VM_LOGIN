# ============================================================
# config.example.sh
# Copy this to config.sh and fill in your real values.
# config.sh is gitignored - it never gets committed, so your
# personal Tailscale IPs, hostnames, and MAC address stay local.
#
# This file is sourced, not executed, so it has no shebang.
# After copying:  chmod 600 config.sh
# ============================================================

# --- Raspberry Pi (wake relay) ---
# Pi must be joined to the same Tailscale network (tailscale up) so this SSH
# works with no port forwarding and no Raspberry Pi Connect browser login.
PI_SSH_TARGET="youruser@100.x.x.x"                      # Pi's Tailscale IP
ETHERWAKE_CMD="sudo /usr/sbin/etherwake -i eth0 AA:BB:CC:DD:EE:FF"

# --- Proxmox ---
PROXMOX_HOST="https://100.x.x.x:8006"                   # Proxmox host's Tailscale IP
PROXMOX_NODE="pve"
VM_ID="100"
PROXMOX_TOKEN_ID="automation@pve!wakeup"                # user@realm!tokenname
KEYCHAIN_SERVICE="proxmox-api-token"

# Optional: path to the Proxmox root CA, copied from /etc/pve/pve-root-ca.pem
# on the host. If set, TLS is properly verified. If left empty, the script
# falls back to curl -k (no verification). Tailscale already authenticates and
# encrypts the transport, so -k is not a disaster here, just unnecessary.
PROXMOX_CACERT=""

# --- VM / RustDesk ---
VM_TAILSCALE_IP="100.x.x.x"                             # the VM's own Tailscale IP
RUSTDESK_PORT="21118"                                   # RustDesk direct-connect port
KEYCHAIN_SERVICE_RUSTDESK="rustdesk-password"

# --- Secrets ---
# Never put the values in this file or in a command line. Run these ONCE, with
# no -w value, so `security` prompts for the secret instead of it landing in
# ~/.zsh_history and in `ps` output:
#
#   security add-generic-password -U -s proxmox-api-token  -a automation -w
#   security add-generic-password -U -s rustdesk-password  -a automation -w
#
# Each prompts twice, echoes nothing. -U updates an existing entry rather than
# erroring, so re-running is safe.

# --- Timeouts (seconds) ---
# These are real wall-clock budgets, measured against a deadline rather than
# accumulated per poll.
MAX_WAIT_HOST_BOOT=240       # Proxmox API to respond (real hardware boot is slow)
MAX_WAIT_VM_RUNNING=60       # Proxmox to report VM as "running"
MAX_WAIT_RUSTDESK_PORT=120   # RustDesk's port to open on the VM
POLL_INTERVAL=5

# --- Behaviour ---
SKIP_WAKE_IF_UP=1            # 0 to always send the magic packet even if host is up
WAKE_ATTEMPTS=3              # magic packet is UDP and can be dropped
LOG_FILE="$HOME/Library/Logs/work-pc-launcher.log"
