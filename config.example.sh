#!/bin/bash
# ============================================================
# config.example.sh
# Copy this to config.sh and fill in your real values.
# config.sh is gitignored - it never gets committed, so your
# personal Tailscale IPs, hostnames, and MAC address stay local.
# ============================================================

# Pi must be joined to the same Tailscale network (tailscale up) so this SSH
# works with no port forwarding and no Raspberry Pi Connect browser login.
PI_SSH_TARGET="youruser@100.x.x.x"                      # Pi's Tailscale IP
ETHERWAKE_CMD="sudo /usr/sbin/etherwake -i eth0 AA:BB:CC:DD:EE:FF"

PROXMOX_HOST="https://100.x.x.x:8006"                   # Proxmox host's Tailscale IP
PROXMOX_NODE="pve"
VM_ID="100"
PROXMOX_TOKEN_ID="automation@pve!wakeup"                # user@realm!tokenname
# Secret is pulled from Keychain, NOT hardcoded here:
#   security add-generic-password -s proxmox-api-token -a automation -w 'YOUR_SECRET'
KEYCHAIN_SERVICE="proxmox-api-token"

VM_TAILSCALE_IP="100.x.x.x"                             # the VM's own Tailscale IP
RUSTDESK_PORT="21118"                                    # RustDesk direct-connect port
KEYCHAIN_SERVICE_RUSTDESK="rustdesk-password"
# Secret is pulled from Keychain, NOT hardcoded here:
#   security add-generic-password -s rustdesk-password -a automation -w 'YOUR_PASSWORD'

MAX_WAIT_HOST_BOOT=240       # seconds to wait for Proxmox API to respond (real hardware boot can be slow)
MAX_WAIT_VM_RUNNING=60       # seconds to wait for Proxmox to report VM as "running"
MAX_WAIT_RUSTDESK_PORT=120   # seconds to wait for RustDesk's port to open on the VM
POLL_INTERVAL=5
