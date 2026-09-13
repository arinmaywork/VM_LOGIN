# Work PC One-Click Launcher

A single script + a one-click macOS app that automates the entire "get from my Mac to
my remote Windows desktop" chain:

```
Tailscale connect -> wake home PC (via Pi) -> wait for Proxmox host to boot
   -> start the VM (Proxmox API) -> wait for VM to actually be running
   -> wait for RustDesk's port to open -> launch RustDesk and connect
```

One click on a Dock icon. No browser logins, no manual waiting, no typing IDs or
passwords by hand.

## Why this exists

Working remotely against a home PC that's normally powered off means, every day,
manually: waking it, waiting, opening Proxmox's web UI, starting a VM, waiting again,
then opening RustDesk and connecting. This automates all of it into one script wrapped
as a double-clickable macOS app.

## Architecture

| Stage | Mechanism | Why not the obvious alternative |
|---|---|---|
| Reach the Pi | Plain SSH over **Tailscale** | Raspberry Pi Connect's remote shell is a browser session tied to a human login (WebRTC + Raspberry Pi ID) - there's no public API for individual accounts to run a one-off command non-interactively. Putting the Pi on the same tailnet as the Mac gives direct, non-interactive SSH with no port forwarding and no browser involved. |
| Wake the PC | `etherwake` run on the Pi via SSH | The magic packet needs to originate from the PC's local broadcast domain, which is why it's sent from the Pi (always-on, on the same LAN) rather than from the remote Mac. |
| Start the VM | **Proxmox REST API** with a scoped token | Automating the Proxmox web UI would mean browser automation - fragile against session timeouts, redirects, and page-load timing. The API is designed to be scripted. |
| Connect to the desktop | **RustDesk direct-IP connect**, since the VM has its own Tailscale IP | Bypasses RustDesk's ID-based rendezvous/relay system entirely - connects straight to `<tailscale-ip>:21118`, which is faster and removes an external dependency. |

## Features

- **One click**: wrapped as a macOS Automator app, pinned to the Dock.
- **Idempotent**: safe to re-run at any point. Skips Tailscale connect if already
  connected, skips waking if the host is already reachable, skips starting the VM if
  it's already running.
- **No fixed guesswork waits**: every stage polls the real signal it cares about
  (Proxmox API reachable, VM status = running, RustDesk port open) with its own
  timeout, rather than a blind `sleep N` that's either too short or wastes time.
- **Visible progress**: prints a running `...still waiting on: X (15s / 240s)` line
  during long waits, so a multi-minute cold boot never looks like it's hung.
- **Native failure/success notifications**: macOS notification banners (with a sound
  on failure) at every stage, so you don't have to babysit a terminal window.
- **No plaintext secrets**: the Proxmox API token and RustDesk password are pulled
  from **macOS Keychain** at runtime, never stored in the script or in git.
- **Personal config kept out of git**: real Tailscale IPs, hostnames, node/VM IDs, and
  the wake MAC address live in a local `config.sh` that's gitignored. The committed
  script is generic and reusable by anyone who fills in their own `config.example.sh`.
- **Least-privilege throughout**: the Pi's sudo rule is scoped to exactly one
  `etherwake` command (not full sudo), and the Proxmox API token is scoped to
  `PVEVMUser` on a single VM path (not admin).
- **Handles both Tailscale install variants** on macOS (standalone CLI-on-PATH vs. Mac
  App Store bundled CLI) by auto-detecting which is present.

## File layout

```
connect_to_work_pc.sh   the script itself - reads config.sh, contains no personal data
config.example.sh       template config with placeholder values (committed)
config.sh               your real values (gitignored, you create this locally)
.gitignore              excludes config.sh from version control
```

## One-time setup

### 1. Get the files
```bash
git clone https://github.com/arinmaywork/VM_LOGIN.git
cd VM_LOGIN
cp config.example.sh config.sh
```
Edit `config.sh` with your real Pi/Proxmox/VM/RustDesk details.

### 2. Pi: join Tailscale + allow a passwordless wake command
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```
Restrict sudo to just the wake command (least privilege). Write the file directly
rather than through an interactive editor, to avoid any risk of a pasted character
getting mangled:
```bash
echo 'YOUR_USER ALL=(ALL) NOPASSWD: /usr/sbin/etherwake -i eth0 YOUR\:MAC\:ADDR\:HERE' \
  | sudo tee /etc/sudoers.d/etherwake > /dev/null
sudo chmod 0440 /etc/sudoers.d/etherwake
sudo chown root:root /etc/sudoers.d/etherwake
sudo visudo -c -f /etc/sudoers.d/etherwake   # must print "parsed OK"
```
Note the backslash before each colon in the MAC address - sudoers treats `:` as a
grammar character, so it must be escaped there. The actual command you type elsewhere
(manually testing etherwake, or in `config.sh`) has no backslashes.

### 3. Mac: passwordless SSH key to the Pi
```bash
ssh-keygen -t ed25519           # leave the passphrase empty so it can run non-interactively
ssh-copy-id YOUR_USER@<pi-tailscale-ip>
```

### 4. Home PC (Proxmox host): enable Wake-on-LAN in BIOS/UEFI
Hardware setting on the physical machine, not the VM.

### 5. Proxmox: create a scoped API token
- Datacenter -> Permissions -> Users -> Add a dedicated automation user (not root).
- Datacenter -> Permissions -> Add -> User Permission: Path `/vms/<VMID>`, that user,
  role `PVEVMUser`.
- Datacenter -> Permissions -> API Tokens -> Add, for that user.
- **Important:** tokens don't automatically inherit their user's permissions. Either
  uncheck "Privilege Separation" when creating the token, or grant the permission a
  second time with the token itself as the principal. Skipping this causes a
  `Permission check failed` error even though the user's permissions look correct.
- Store the secret in Keychain, never in a file:
```bash
security add-generic-password -s proxmox-api-token -a automation -w 'YOUR_TOKEN_SECRET'
```

### 6. RustDesk: set a permanent password on the VM
In the RustDesk app on the VM: Settings (pencil icon) -> unlock security settings if
prompted -> "Use permanent password" -> set it. Store it in Keychain the same way:
```bash
security add-generic-password -s rustdesk-password -a automation -w 'YOUR_RUSTDESK_PASSWORD'
```

### 7. Test it
```bash
chmod +x connect_to_work_pc.sh
./connect_to_work_pc.sh
```

## Turning it into a one-click app (Automator)

1. Open Automator -> New Document -> Application.
2. Add a "Run Shell Script" action, Shell: `/bin/bash`.
3. Content: `bash /path/to/connect_to_work_pc.sh` (config.sh must sit in the same
   folder as the script - the script locates it relative to its own path).
4. Leave "Run as Administrator" **unchecked** (running as root changes the effective
   `$HOME`, which breaks SSH key and Keychain lookups tied to your normal user).
5. File -> Save, File Format: **Application**.
6. First launch will likely be blocked by Gatekeeper since it's unsigned -
   right-click -> Open once to allow it.
7. Drag the resulting app into the Dock.

## Troubleshooting / gotchas hit while building this

- **zsh + `!` in tokens**: Proxmox API token IDs contain `!`, which zsh expands as
  history substitution inside double-quoted strings at an interactive prompt. Use
  single quotes when testing curl commands by hand. Not an issue inside the script
  itself, since non-interactive bash doesn't do history expansion.
- **Tailscale CLI not on PATH**: the menu-bar app showing "Connected" doesn't
  guarantee a `tailscale` command exists for scripts. This script auto-detects both
  the standalone (PATH, after enabling CLI integration in Tailscale's Settings) and
  Mac App Store (bundled at `/Applications/Tailscale.app/Contents/MacOS/Tailscale`)
  variants.
- **GET vs POST**: checking VM status is `GET .../status/current`; starting it is
  `POST .../status/start`. The wrong verb returns "Method not implemented."
- **Non-ASCII characters**: smart quotes/em-dashes/ellipses can get mangled by
  locale/encoding differences when a script is copy-pasted or downloaded through
  different tools, occasionally producing confusing bash errors (an ellipsis sitting
  next to a variable name misparsing as `${VAR?}` "unbound variable" syntax, for
  example). The script is kept plain ASCII on purpose.
- **`sudo visudo` recovery prompt**: if it reports a syntax error, lowercase `q` is
  not a valid response at the "What now?" prompt - use `x` to exit without saving.

## Possible future improvements

- Use the Proxmox **QEMU guest agent** (`agent/ping` API endpoint) for a more precise
  "is the OS actually usable" signal, instead of/alongside the RustDesk port check.
- Add a companion "shut everything down" script for the reverse direction.
- Add retry/backoff on the SSH wake step specifically, separate from the overall
  script's fail-fast behavior, in case of a transient Tailscale route hiccup right
  after the Mac's own `tailscale up`.
