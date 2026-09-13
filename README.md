# Work PC One-Click Launcher

One tap takes you from a powered-off home PC to a live remote Windows desktop, from a
Mac or an Android tablet:

```
wake home PC (via Pi) -> wait for Proxmox host to boot -> start the VM (Proxmox API)
   -> wait for the VM to actually be running -> wait for RustDesk's port to open
   -> open RustDesk
```

No browser logins, no manual waiting, no typing IDs or passwords by hand. A cold boot
takes about 75 seconds end to end.

## Why this exists

Working remotely against a home PC that is normally powered off means, every day,
manually: waking it, waiting, opening Proxmox's web UI, starting a VM, waiting again,
then opening RustDesk and connecting. This automates all of it.

---

## Architecture

The orchestration lives on the Raspberry Pi. It is always on, sits on both the home LAN
and the tailnet, and already holds the wake permission — so any device that can open an
SSH session becomes a client, without reimplementing the logic per platform.

```
Android tablet ---ssh--> Pi ---etherwake--> Home PC (Proxmox host)
   or Mac                 |
                          +---Proxmox API--> start VM 100
                          +---tcp probe----> VM:21118 (RustDesk ready?)

client ---RustDesk direct IP over Tailscale---> VM
```

| Stage | Mechanism | Why not the obvious alternative |
|---|---|---|
| Reach the Pi | Plain SSH over **Tailscale** | Raspberry Pi Connect's remote shell is a browser session tied to a human login (WebRTC + Raspberry Pi ID); there is no public API for individual accounts to run a one-off command non-interactively. Putting the Pi on the same tailnet gives direct, non-interactive SSH with no port forwarding and no browser. |
| Wake the PC | `etherwake`, run locally on the Pi | The magic packet must originate inside the PC's local broadcast domain. The Pi is already there. |
| Start the VM | **Proxmox REST API** with a scoped token | Automating the Proxmox web UI means browser automation, which is fragile against session timeouts, redirects and page-load timing. The API is designed to be scripted. |
| Connect to the desktop | **RustDesk direct-IP connect** to the VM's own Tailscale IP | Bypasses RustDesk's ID-based rendezvous/relay entirely. One less external dependency, and it gives a concrete TCP port to poll for readiness. |
| Every wait | Poll the real condition, with a deadline | A fixed `sleep N` is either too short or wastes time; real hardware boot time varies a lot. |

### What you need

- A Raspberry Pi, or any always-on Linux box on the same LAN as the PC.
- A PC running Proxmox VE with Wake-on-LAN capable hardware.
- A VM on that host (this guide assumes Windows).
- A Mac and/or an Android device as the client.
- A Tailscale account. The free tier is enough.

## File layout

```
wake_work_pc.sh         runs ON THE PI - wakes, starts the VM, waits for readiness
connect_to_work_pc.sh   runs on the Mac - macOS wrapper (notifications, Keychain)
config.example.sh       template config with placeholder values (committed)
config.sh               your real values (gitignored, you create this locally)
.gitignore              excludes config.sh, .DS_Store, *.log
README.md               this file
```

---

# Part 1 — Infrastructure

Work through these in order. This part is required regardless of which client you use.

## 1. Tailscale on every machine

Install and log in on the Pi, the Proxmox host, the VM, and each client device. All
must be on the same tailnet.

```bash
# Pi and Proxmox host (Debian-based)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Mac, Windows VM and Android: install the normal app and sign in.

**Then disable key expiry** on the Pi, the Proxmox host and the VM in the Tailscale
admin console (Machines -> per-machine menu -> Disable key expiry). These are
unattended machines; when a node key expires, everything silently stops working until
someone completes a browser login.

Note each machine's Tailscale IP (the `100.x.x.x` address).

### Optional but recommended: lock down the tailnet

In Access Controls, restrict reachability rather than leaving the default allow-all:

```jsonc
{
  "acls": [
    { "action": "accept", "src": ["your-mac", "your-tablet"], "dst": ["pi:22"] },
    { "action": "accept", "src": ["your-mac", "your-tablet"], "dst": ["windows-workstation:21118"] },
    { "action": "accept", "src": ["pi"], "dst": ["pve:8006"] }
  ]
}
```

Clients need `pi:22` and the VM's RustDesk port. Only the Pi needs the Proxmox API.

## 2. Wake-on-LAN on the PC

**In BIOS/UEFI:** enable Wake-on-LAN / "Power On by PCI-E" / "Resume by LAN". The name
varies by vendor. This is a setting on the physical machine, not the VM.

**In Proxmox (Debian):** Linux often disables WOL on the NIC at shutdown, so the BIOS
setting alone is not always enough:

```bash
apt install ethtool
ip -br link                        # find your NIC name, e.g. eno1
ethtool eno1 | grep -i wake-on     # want "Wake-on: g"
```

If it reports `d` (disabled), persist it by adding a `post-up` line to the interface in
`/etc/network/interfaces`:

```
iface eno1 inet manual
        post-up /sbin/ethtool -s eno1 wol g
```

Note the PC's MAC address (`ip link show eno1`).

## 3. Pi: the wake command

```bash
sudo apt install etherwake
ip -br link                        # usually eth0 or end0 on a Pi
```

Test by hand first, with the PC powered off:

```bash
sudo /usr/sbin/etherwake -i eth0 AA:BB:CC:DD:EE:FF
```

If the PC does not come on, fix that before automating it. Usual causes: wrong
interface, WOL disabled at the Proxmox layer (step 2), or a power state deeper than the
NIC can wake from.

Once it works, allow that one command without a password - scoped to exactly this
command, not blanket sudo:

```bash
echo 'YOUR_USER ALL=(ALL) NOPASSWD: /usr/sbin/etherwake -i eth0 AA\:BB\:CC\:DD\:EE\:FF' \
  | sudo tee /etc/sudoers.d/etherwake > /dev/null
sudo chmod 0440 /etc/sudoers.d/etherwake
sudo chown root:root /etc/sudoers.d/etherwake
sudo visudo -c -f /etc/sudoers.d/etherwake   # must print "parsed OK"
```

**The backslashes before each colon are required.** `:` is a grammar character in
sudoers, so an unescaped MAC address is a syntax error. Only the sudoers file needs
them - the command in your config does not.

## 4. Proxmox: a least-privilege API token

The script needs exactly two privileges: read VM status, and power it on.

Run on the Proxmox host as root:

```bash
pveum role add VMWake -privs "VM.Audit VM.PowerMgmt"
pveum user add automation@pve --password '<some-password>'
pveum user token add automation@pve wakeup --privsep 1
# ^ prints the secret ONCE. Copy it now.
pveum acl modify /vms/100 --tokens 'automation@pve!wakeup' --roles VMWake
```

Or via the web UI: Datacenter -> Permissions -> Roles -> Create (`VMWake`, with
`VM.Audit` and `VM.PowerMgmt`); Users -> Add (`automation`, realm `pve`); API Tokens ->
Add (user `automation@pve`, token ID `wakeup`, **leave Privilege Separation checked**);
then Permissions -> Add -> **API Token Permission**, path `/vms/100`, the token, role
`VMWake`.

**The critical detail:** a Proxmox API token does not inherit its owning user's
permissions while Privilege Separation is on. The fix is *not* to uncheck Privilege
Separation - that lets the token do everything the user can do, everywhere, which
defeats the point of scoping it. The fix is to grant the permission a second time with
**the token itself** as the principal, which is what `--tokens` does above. Skipping
this produces `Permission check failed (/vms/100, VM.Audit)` even though the user's own
permissions look correct.

Verify the token sees exactly what it should:

```bash
pvesh get /access/permissions --userid 'automation@pve!wakeup'
```

## 5. The VM: Tailscale and RustDesk

Inside the Windows VM:

1. Install Tailscale, sign in, note the VM's own `100.x.x.x` address.
2. Install RustDesk.
3. Settings -> Security -> unlock, then **set a permanent password**.
4. Settings -> Network -> **enable direct IP access**. Without this, port 21118 never
   opens and the readiness check waits forever.
5. Allow RustDesk through Windows Firewall on the Tailscale interface.
6. Set RustDesk to start with Windows, so the port opens without anyone logging in.

---

# Part 2 — The Pi orchestrator

This is the core. Everything else is a client that calls it.

## Install

From a machine that has the repo:

```bash
scp wake_work_pc.sh USER@PI_IP:~/
ssh USER@PI_IP 'mkdir -p ~/.config/work-pc && chmod 700 ~/.config/work-pc'
ssh -t USER@PI_IP 'sudo mv ~/wake_work_pc.sh /usr/local/bin/ && sudo chmod 755 /usr/local/bin/wake_work_pc.sh && (command -v nc || sudo apt install -y netcat-openbsd)'
```

## Configure

Create `~/.config/work-pc/config` on the Pi, `chmod 600`:

```bash
ETHERWAKE_CMD="sudo /usr/sbin/etherwake -i eth0 AA:BB:CC:DD:EE:FF"
PROXMOX_HOST="https://100.x.x.x:8006"
PROXMOX_NODE="pve"
VM_ID="100"
PROXMOX_TOKEN_ID="automation@pve!wakeup"
PROXMOX_TOKEN_SECRET_FILE="/home/YOUR_USER/.config/work-pc/token"
VM_TAILSCALE_IP="100.x.x.x"
RUSTDESK_PORT="21118"
PROXMOX_CACERT=""            # optional: path to pve-root-ca.pem
MAX_WAIT_HOST_BOOT=240
MAX_WAIT_VM_RUNNING=60
MAX_WAIT_RUSTDESK_PORT=120
POLL_INTERVAL=5
SKIP_WAKE_IF_UP=1
WAKE_ATTEMPTS=3
```

Then the token secret, in its own file:

```bash
printf '%s' 'YOUR_TOKEN_SECRET' > ~/.config/work-pc/token
chmod 600 ~/.config/work-pc/token
```

## Test

With the PC powered off:

```bash
ssh USER@PI_IP wake_work_pc.sh
```

It should end with `READY - connect RustDesk to <ip>` and exit 0.

---

# Part 3 — Clients

## Android tablet or phone

Install **Termux** and **Termux:Widget** from F-Droid. The Play Store builds are
abandoned and cannot install packages.

```bash
pkg install -y openssh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-copy-id USER@PI_IP
```

Create the shortcut:

```bash
mkdir -p ~/.shortcuts
nano ~/.shortcuts/wake-work-pc
```

```bash
#!/data/data/com.termux/files/usr/bin/bash
ssh USER@PI_IP wake_work_pc.sh || { echo "WAKE FAILED - not opening RustDesk"; read; exit 1; }
am start -n com.carriez.flutter_hbb/.MainActivity
```

```bash
chmod +x ~/.shortcuts/wake-work-pc
```

The `||` guard matters: without it, a failed wake still opens RustDesk and you get a
connection error instead of a useful message.

Verify RustDesk's launch activity on your build before trusting it:

```bash
am start -n com.carriez.flutter_hbb/.MainActivity
```

Then long-press the home screen -> Widgets -> Termux:Widget -> pick `wake-work-pc`.

In RustDesk, type the VM's Tailscale IP into the ID field rather than an ID, connect
once with the permanent password, and tick remember.

## macOS

`connect_to_work_pc.sh` does the same job natively, with macOS notifications at each
stage, secrets from Keychain, and RustDesk launched with the password supplied.

```bash
git clone https://github.com/arinmaywork/VM_LOGIN.git
cd VM_LOGIN
cp config.example.sh config.sh
chmod 600 config.sh
```

Edit `config.sh` - see the comments in `config.example.sh`. It is gitignored and never
gets committed.

Secrets go into Keychain, never into a file or a command line:

```bash
security add-generic-password -U -s proxmox-api-token -a automation -w
security add-generic-password -U -s rustdesk-password -a automation -w
```

**Note there is no value after `-w`.** That is deliberate: `security` then prompts for
the secret, twice, echoing nothing. Passing the value inline would write both secrets
into `~/.zsh_history` and expose them in `ps`, which defeats the point of using Keychain
at all. `-U` updates an existing entry, so re-running is safe.

SSH key to the Pi:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_wakepi
ssh-copy-id -i ~/.ssh/id_ed25519_wakepi.pub USER@PI_IP
ssh-add --apple-use-keychain ~/.ssh/id_ed25519_wakepi
```

Then a host block in `~/.ssh/config`, so `PI_SSH_TARGET="wakepi"` is all the script
needs:

```
Host wakepi
    HostName 100.x.x.x
    User YOUR_USER
    IdentityFile ~/.ssh/id_ed25519_wakepi
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
```

Verify it is non-interactive, exactly as the script will call it:

```bash
ssh -o BatchMode=yes wakepi 'echo ok'
```

Run it once from the terminal, then wrap it as an app:

1. Automator -> New Document -> **Application**.
2. Add **Run Shell Script**. Shell: `/bin/bash`.
3. Content: `bash /full/path/to/VM_LOGIN/connect_to_work_pc.sh`
   (`config.sh` must sit beside the script - it is located relative to the script's own
   path. Do not symlink the script: `dirname "$BASH_SOURCE"` does not follow symlinks
   and it will look for `config.sh` in the wrong place.)
4. Leave **Run as Administrator unchecked**. Running as root changes `$HOME`, which
   breaks both the SSH key and the Keychain lookups.
5. File -> Save, File Format: **Application**.
6. First launch is blocked by Gatekeeper because the app is unsigned. On macOS Sequoia
   and later the old Control-click -> Open trick no longer works: launch it, let it be
   blocked, then **System Settings -> Privacy & Security -> Open Anyway**. On older
   macOS, Control-click -> Open still works.
7. Approve the Keychain and notification prompts on first run. Both are tied to the app,
   so they reappear if you move or rebuild it.
8. Drag the app to the Dock.

**Keep the clone as the only copy of the script.** If a second copy lives somewhere like
`~/Library/Scripts`, delete it once the app points at the clone - maintaining two is how
the repo and the thing you actually run drift apart.

---

## How it behaves

- **Idempotent.** Safe to re-run at any point. Skips waking if the Proxmox host already
  answers, skips starting the VM if it is already running.
- **Real deadlines.** Each wait has a wall-clock budget measured against a deadline, not
  accumulated per poll, so `MAX_WAIT_HOST_BOOT=240` means about 240 seconds.
- **Fails loudly and specifically.** Every API call checks its HTTP status, so a 403
  from a mis-scoped token stops immediately with the reason rather than timing out later
  against a misleading message.
- **Progress you can see.** A `...waiting on X (15s / 240s)` line during long waits.
- **Secrets stay out of `ps`.** The Proxmox token is passed to curl through a config
  file on stdin, not on the command line.
- **Logged (macOS).** Timestamped, to `~/Library/Logs/work-pc-launcher.log`. Automator
  swallows stdout, so this is the only durable record when something fails.

---

## Troubleshooting

**macOS, start here:** `tail -50 ~/Library/Logs/work-pc-launcher.log`. Notification
banners disappear; the log does not.

**Android, start here:** run the shortcut from the Termux prompt rather than the widget
- `bash ~/.shortcuts/wake-work-pc` - so you can see the output.

| Symptom | Cause |
|---|---|
| `Permission check failed (/vms/N, VM.Audit)` | ACL granted to the user but not the token. See Part 1 step 4 - use an API Token Permission, not a User Permission. |
| `Method 'GET .../status/start' not implemented` | Status is `GET`, starting is `POST`. |
| Timed out waiting for Proxmox API | The PC never woke. Test etherwake by hand from the Pi, and re-check the `ethtool` WOL state - it silently resets on some kernel upgrades. |
| Timed out waiting for RustDesk port | Direct IP access not enabled in RustDesk, RustDesk not set to start with Windows, or Windows Firewall blocking the Tailscale interface. |
| `wake_work_pc.sh: command not found` | Not installed to `/usr/local/bin` on the Pi, or not `chmod 755`. |
| `pm list packages` returns nothing in Termux | Android 11+ package visibility filtering. Not an error - call `am start` with the package name directly. |
| SSH prompts for a password from Termux | `ssh-copy-id` did not complete. Re-run it. |
| `Tailscale CLI not found` (macOS) | The menu-bar app showing "Connected" does not mean a `tailscale` binary is on a script's PATH. Enable CLI integration in Tailscale's settings, or rely on the script's fallback to the App Store bundle path. |
| SSH fails after re-imaging the Pi | Host key changed. `ssh-keygen -R <pi-ip>`, then connect once by hand to accept the new key. The scripts use `BatchMode=yes` and will never prompt - by design. |
| `VM_ID?: unbound variable` or similar | A non-ASCII character (smart quote, em-dash, ellipsis) got in during a copy-paste; an ellipsis next to a variable name can misparse as `${VAR?}`. Check with `LC_ALL=C grep -n '[^ -~]' wake_work_pc.sh`. |
| Token ID breaks a hand-typed curl | zsh expands `!` as history substitution inside double quotes, and token IDs contain `!`. Use single quotes. Not an issue in the scripts - non-interactive bash does not do history expansion. |
| A `#` comment on a command line errors out | zsh does not treat `#` as a comment interactively by default. `echo 'setopt interactive_comments' >> ~/.zshrc`. |
| `visudo` syntax error pointing at the MAC | Colons need escaping as `\:`. At the "What now?" prompt, `x` exits without saving - `q` is not valid. |

## Security notes

- The Pi's sudo rule permits exactly one command with exactly these arguments. It cannot
  wake a different machine or run anything else.
- The Proxmox token can read one VM's status and power it on. It cannot reconfigure it,
  delete it, access its console, or touch any other VM. Verify with
  `pvesh get /access/permissions --userid 'automation@pve!wakeup'`.
- **The token secret lives in a file on the Pi** (`chmod 600`), not in a keystore. This
  is a deliberate tradeoff for letting non-macOS clients work. It is acceptable
  *because* the token is scoped to two privileges on one VM - the blast radius of the
  Pi being compromised is "someone can turn on a PC", and anyone with root on the Pi
  could already do that via etherwake.
- The RustDesk password never reaches the Pi. Each client holds its own.
- **One known exposure on macOS:** RustDesk's CLI accepts the password only as an
  argument, so it is briefly visible in `ps` while the app launches. Do not add `set -x`
  to that script - it would write the password into the log.
- Nothing is exposed to the public internet. Every hop is inside the tailnet, and no
  port forwarding is required anywhere.
- Turn off password SSH logins on the Pi once key auth works
  (`PasswordAuthentication no` in `/etc/ssh/sshd_config`, then
  `sudo systemctl restart ssh`).

## Possible future improvements

- A companion "shut everything down" script: `POST .../qemu/<id>/status/shutdown`
  (graceful ACPI), poll until stopped, then `POST /nodes/<node>/status` with
  `command=shutdown`. That last call needs `Sys.PowerMgmt` on `/nodes/<node>`, so it
  wants its own separately-scoped token rather than widening this one.
- Reduce `connect_to_work_pc.sh` to a thin wrapper around `ssh pi wake_work_pc.sh`, so
  there is one implementation of the logic instead of two.
- The QEMU guest agent (`agent/ping`) as a readiness signal. Probably not worth it: it
  reports that the agent is responding, which happens *earlier* than RustDesk being
  usable, so it is a less precise signal for this purpose, not a better one.
- Auto-connect RustDesk on Android via its URI scheme, rather than just opening the app
  to its main screen.
