# COI troubleshooting reference

First-install pitfalls and runtime recovery procedures. Work top-to-bottom; each section assumes the prior ones are clean.

---

## 1. Install-time

### 1.1 Incus stuck at 6.0 despite Zabbly repo configured

Ubuntu Pro/ESM ships `incus 6.0.0+esm3` at apt priority 510, which beats Zabbly's default 500. Symptom: `apt-cache policy incus` shows `6.0.x` as Candidate with Zabbly listed below it.

```bash
sudo tee /etc/apt/preferences.d/zabbly-incus.pref >/dev/null <<'EOF'
Package: incus*
Pin: origin pkgs.zabbly.com
Pin-Priority: 1001
EOF
sudo apt update
apt-cache policy incus        # Candidate must now show 6.2x
sudo apt install incus
```

### 1.2 `coi build` fails with `No root device could be found`

You skipped `sudo incus admin init --minimal`. Run it. Without this the `default` profile has no root disk attached, and every new instance launch fails.

### 1.3 Container launches but gets only IPv6, never IPv4

`coi build` hangs at "Waiting for network...". DHCPDISCOVER reaches the bridge but dnsmasq never replies.

Diagnose in order (from another terminal on the host):

```bash
# Who's the Incus bridge?
BR=$(incus network list --format csv -c n | grep '^incusbr')

# 1. dnsmasq running for the bridge?
ps aux | grep "[d]nsmasq.*$BR"

# 2. bound on UDP/67?
sudo ss -ulnp | grep -E ':67|:547'

# 3. DHCP packets reaching the bridge?
sudo tcpdump -ni $BR -e port 67 or port 68

# 4. Force DHCP from inside container (don't background — dhclient gets SIGTSTP'd)
incus exec <container> -- timeout 8 dhclient -v eth0

# 5. If tcpdump shows DISCOVER but dnsmasq's log doesn't — another nft chain dropped it
incus network set $BR raw.dnsmasq "log-dhcp
log-queries"
sudo journalctl -u incus -n 100 | grep -i dnsmasq
```

**Most common root cause #1 — Docker's bridge-netfilter intercepts DHCP:**

```bash
sysctl net.bridge.bridge-nf-call-iptables   # if 1, this is the cause
sudo tee /etc/sysctl.d/99-incus-docker.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables=0
net.bridge.bridge-nf-call-ip6tables=0
net.bridge.bridge-nf-call-arptables=0
EOF
sudo sysctl --system

# Belt-and-suspenders: whitelist the Incus bridge in Docker's user chain
sudo iptables  -I DOCKER-USER -i $BR -j ACCEPT
sudo iptables  -I DOCKER-USER -o $BR -j ACCEPT
sudo ip6tables -I DOCKER-USER -i $BR -j ACCEPT
sudo ip6tables -I DOCKER-USER -o $BR -j ACCEPT
```

**Most common root cause #2 — firewalld drops the packet.** nftables runs all chains attached to the same hook; firewalld's `filter_INPUT_POLICIES` ends with `reject with icmpx admin-prohibited` and matches before Incus's accept rule. Symptom: Incus's accept counter stays at 0 and dnsmasq's log never shows the DISCOVER.

```bash
systemctl is-active firewalld
sudo nft -a list ruleset | grep -B1 -E 'drop|reject' | grep -i 'admin-prohibited\|filter_INPUT'

sudo firewall-cmd --zone=trusted --change-interface=$BR --permanent
sudo firewall-cmd --reload
```

**Edge case — AppArmor on `usr.sbin.dnsmasq`:**

Happens on older Incus packaging. Check with:

```bash
sudo dmesg | grep -i 'apparmor.*dnsmasq'
```

On Incus 6.2x + Zabbly packages this doesn't apply — Incus loads its own per-bridge profile and the global one is inactive.

### 1.4 Stale leftovers after a failed build

A failed `coi build` leaves a `coi-build` instance behind. Always clean before retrying:

```bash
incus delete coi-build --force
```

### 1.5 Full Incus reset (when state is too messy)

```bash
# stop/delete every running instance first
incus list --format csv -c n | xargs -r -I{} incus delete {} --force
incus image list --format csv -c f | xargs -r -I{} incus image delete {}
incus profile device remove default root || true
incus profile device remove default eth0 || true
incus network list --format csv -c n,m | grep ',YES' | cut -d, -f1 | xargs -rI{} incus network delete {}
incus storage list --format csv -c n | xargs -rI{} incus storage delete {}
sudo incus admin init --minimal
```

Loop-file storage pools (`/var/lib/incus/disks/*.img`) are removed by `incus storage delete`; verify with `sudo ls -la /var/lib/incus/disks/`. Real ZFS pools elsewhere on the host are not touched.

### 1.6 `coi health` warns storage pool critically low

Default pool is a 1.8 GiB loop file that gets oversubscribed by Incus images. Either:

- Increase the loop file: `sudo incus storage set default size=30GiB` (may require recreating the pool).
- Move to a real directory or ZFS pool (recommended for daily use).

---

## 2. Runtime — SSH agent forwarding

### 2.1 `ssh-add -l` fails inside the container

Ordered fixes:

```bash
# Host
ssh-add -l                                      # agent must be live and have keys
echo "$SSH_AUTH_SOCK"                           # must be the path COI expects
make coi-ssh-fix                                # re-attaches the Incus proxy device

# Container
export SSH_AUTH_SOCK=/tmp/ssh-auth.sock
ssh-add -l
```

If `make coi-ssh-fix` errors with "Device ssh-agent already exists", the remove step was skipped — run it manually:

```bash
CONTAINER=$(incus list --format csv -c ns | grep ',RUNNING' | grep '^coi-' | tail -1 | cut -d, -f1)
incus config device remove "$CONTAINER" ssh-agent
make coi-ssh-fix
```

### 2.2 SSH works but `git push` fails with host key check

The container's `~/.ssh/known_hosts` is empty on first use. `ssh -T git@<host>` once to populate it.

---

## 3. Runtime — Docker in container

Some tasks need to pull or build Docker images inside the COI container.

### 3.1 "Permission denied" on `/var/run/docker.sock`

COI mounts the host's docker socket but its file mode can be 660 owned by `docker:docker`, and the container user may not be in the docker group with the right GID. Fix:

```bash
make coi-docker-fix        # chmod 666 on the socket (simplest)
```

Tradeoff: any process in the container can now talk to the host's Docker daemon. That's equivalent to giving the container root on the host — accept it only if the project is trusted.

### 3.2 Docker-in-docker vs. shared daemon

COI shares the host's Docker daemon by default (fast, no duplicate image cache). If a project specifically needs nested Docker-in-Docker (dind), that's a different setup — see upstream README.

---

## 4. Clipboard, image paste & microphone

Claude Code's Ctrl+V image paste needs `xclip` and a reachable X11 display. `/voice` dictation needs a PulseAudio socket. By default the COI container has neither.

### 4.1 `make coi-x11` (recommended)

The Makefile target `make coi-x11` sets up X11 clipboard + PulseAudio in one step. Run it on the host while a COI container is running, then (re)start Claude.

What it does:
1. Mounts the X11 socket (`/tmp/.X11-unix/X0`) as a disk device.
2. **Copies** (not bind-mounts) the host `$XAUTHORITY` file into `/home/code/.Xauthority` via `incus file push --uid 1000 --gid 1000 --mode 0600`.
3. Mounts the PulseAudio socket (`/run/user/<uid>/pulse/native`) as a disk device.
4. Installs `xclip` + `pulseaudio-utils` + `libasound2-plugins` inside the container.
5. Writes `/etc/asound.conf` to route ALSA through PulseAudio (without this, Claude Code's audio library hits ALSA directly and fails with "Unknown PCM default" / "cannot find card '0'" errors).
6. Writes `/etc/profile.d/x11-audio.sh` with `DISPLAY=:0`, `XAUTHORITY`, `PULSE_SERVER`.
7. Sources the profile.d script from `/etc/bash.bashrc` (for non-login shells).
8. Runs `xhost +si:localuser:root` on the host.
9. Verifies clipboard round-trip and PulseAudio connectivity.

**Gotcha — Xauthority must be copied, not bind-mounted.** Incus disk devices map file ownership to `nobody:nogroup` inside the container (UID mapping). The container user `code` (uid 1000) can't read it, so X11 auth fails silently. Use `incus file push` with `--uid 1000 --gid 1000` instead.

**Gotcha — stale xauth lock files.** If `xauth list` shows "timeout in locking authority file", delete `/home/code/.Xauthority-c` and `.Xauthority-l` (left by a prior failed root-level xauth attempt).

**Gotcha — env vars require Claude restart.** `DISPLAY` and `XAUTHORITY` are set via `/etc/profile.d/x11-audio.sh`, which only runs for new shells. If Claude was started before `make coi-x11`, exit and re-enter with `make coi`.

**Gotcha — `$XAUTHORITY` may not be `~/.Xauthority`.** Some setups (e.g. SDDM, LightDM) use a temp file like `/tmp/xauth_XXXXXX`. The Makefile reads `$XAUTHORITY` from the host environment. If `~/.Xauthority` is a directory (not a file), this is the cause.

**Gotcha — ALSA "Unknown PCM default" / "cannot find card '0'".** Claude Code's audio library uses ALSA, which fails because the container has no sound card. Install `libasound2-plugins` and write `/etc/asound.conf` to route ALSA through PulseAudio:
```
pcm.default pulse
ctl.default pulse
pcm.pulse { type pulse }
ctl.pulse { type pulse }
```
`make coi-x11` does this automatically.

### 4.2 File-based paste (simplest, most secure)

If X11 forwarding is unwanted (untrusted workloads), save clipboard images to a bind-mounted path:

```bash
# on host:
mkdir -p tmp
xclip -selection clipboard -t image/png -o > tmp/paste-$(date +%s).png   # X11
# or:
wl-paste -t image/png > tmp/paste-$(date +%s).png                        # Wayland
```

Add `tmp/` to `.gitignore`. Inside Claude: `look at ./tmp/paste-<ts>.png`.

### 4.3 Wayland note

On Plasma 6 Wayland: pass the Xwayland socket (`/tmp/.X11-unix/X0`), not the native Wayland one — Wayland passthrough has a known bug with `xwayland-satellite` (lxc/incus#1635).

**Tradeoff:** X11 + PulseAudio forwarding gives the container full clipboard + keylog reach + microphone access on the host. Fine for own-code sandbox; weakens isolation for untrusted workloads.

---

## 5. Runtime — "container never started / no coi- in list"

If `make coi` appears to hang and `incus list` shows no `coi-*` container:

1. `coi health` — any CRITICAL failure?
2. `coi images` — is the `coi` image present? If not, `coi build`.
3. `incus list` — is there a `coi-build` or other half-finished container? Delete with `incus delete <name> --force`.
4. Network: re-walk §1.3 if the container starts but sits in INIT forever.

---

## 6. Performance — "apt / curl / npm feel very slow"

### 6.1 IPv6 happy-eyeballs timeout (the big one)

**Symptom:** `apt-get update` takes minutes; `curl http://archive.ubuntu.com/...` hangs 9-36s before any bytes flow; `npm install` stalls on DNS-like delays. Cloudflare-backed downloads are fast, but Ubuntu archive / GitHub / npm registry are slow.

**Root cause:** The Incus bridge assigns IPv6 addresses from its ULA range (`fd42:...`), but the host has no IPv6 upstream route. DNS returns AAAA records, glibc's default sorting tries IPv6 first, and every connection pays a 9-36 second timeout before falling back to IPv4.

**Diagnosis:**
```bash
incus exec <container> -- bash -c '
  getent hosts archive.ubuntu.com | head -2   # if the first result is 2620: / fd42:, you will hit the timeout
  ping6 -c 2 -W 2 2620:2d:4002:1::103         # expect 100% packet loss
  time curl -sL -o /dev/null http://archive.ubuntu.com/ubuntu/ls-lR.gz
'
# Also check host-level:
ip -6 route show default                      # expect empty = no IPv6 internet
```

**Fix:** Force IPv4 preference in the container's `/etc/gai.conf`.

```bash
incus exec <container> -- bash -c 'cat > /etc/gai.conf <<EOF
precedence  ::1/128       50
precedence  ::/0          40
precedence  2002::/16     30
precedence ::/96          20
precedence ::ffff:0:0/96 100
EOF'
```

The last line gives IPv4-mapped-to-IPv6 addresses the highest precedence, so `getaddrinfo()` returns IPv4 first. Takes effect immediately, no restart needed. Verify: first curl attempt should show `connect: 0.0xs`, not `connect: 9.0xs`.

Bake into the COI image at build time by adding the same file to `/etc/gai.conf` in the Dockerfile/cloud-init, or fold into a per-project `make coi-extras` that writes it on every run (idempotent).

### 6.2 Expected performance profile (dir-driver pool)

After §6.1 is applied, measured container vs host overhead on a `dir`-backed Incus pool (ext4 host FS, NVMe SSD):

| Metric | Container overhead | Notes |
|---|---|---|
| Network throughput (Cloudflare, GitHub) | ~0% | Link-speed limited either way |
| Network latency (HTTPS, DNS) | +30-50% | Bridge + dnsmasq hops |
| CPU (SHA-256 compute) | ~1.6× slower | cgroup scheduling overhead |
| Memory bandwidth | ~20% lower | Minor |
| Disk seq read | ~0% | Page cache |
| **Disk seq write** | **~2.3× slower** | `dir` driver overhead |
| **Disk random 4K writes** | **~2.3× slower** | Same |
| Small-file metadata ops | ~2× slower | Bind mount + idmap |

For Docker-in-Docker workloads (nested storage), the disk write gap compounds. If disk-heavy workflows dominate, consider migrating the storage pool from `dir` to `btrfs` — Canonical's recommendation and the documented fast path for Incus. Cost: recreate the pool + `incus move` existing containers.

### 6.3 Slow Ubuntu mirror (archive.ubuntu.com flakiness)

Even after §6.1, `archive.ubuntu.com` can be genuinely slow — it's a DNS round-robin with some slow/overloaded IPs in the pool. Connect times vary 0.04s → 4s → 20s on consecutive runs.

**Fix:** pin a known-fast mirror in `/etc/apt/sources.list`:

```bash
# Option A — geographic auto-select (refreshed on each apt update)
sed -i 's|http://archive.ubuntu.com/|mirror://mirrors.ubuntu.com/mirrors.txt|g' /etc/apt/sources.list

# Option B — pin a specific mirror (swap in your region's)
sed -i 's|http://archive.ubuntu.com/|http://us.archive.ubuntu.com/|g' /etc/apt/sources.list
```

---

## 7. Upgrading

- `coi update` (0.9) — updates the `coi` binary + threat-detection databases. Re-running the
  upstream install script also upgrades the binary.
- `make coi-update` (alias for `coi build`) — refreshes the container *image*, next `coi shell` gets
  the new Claude.
- `claude update` — only persists in `--persistent` slots.
- Never `npm install -g @anthropic-ai/claude-code` inside the container — it shadows the native
  install and breaks future `claude update`.
- **After any `coi` version bump, re-verify the config/trust/network model** — these have broken
  across versions (see SKILL.md's "Version compatibility" callout and §10 below). Run `coi health`
  and `coi --help` first.

---

## 8. Security monitor — container auto-paused

### 8.1 The banner

With `[monitoring] enabled = true` (the recommended default), COI runs a threat detector against each container. When it flags something, the container is **frozen** (not killed — state preserved) and Claude's terminal prints:

```
*** SECURITY: Container coi-XXXXXXXX-N PAUSED due to security threat. Resume with: incus start coi-XXXXXXXX-N ***
```

Don't resume blindly — first understand what fired.

### 8.2 Where the evidence lives

Per-container audit log at `~/.coi/audit/<container>.jsonl`. It is **JSONL of periodic snapshots** (~10 s interval), not an event stream. Each line has:

```
{
  "timestamp": "...",
  "container_name": "...",
  "network":    { "active_connections": N, "connections": [...], "suspicious_count": N },
  "processes":  { "processes": [...] },
  "filesystem": { "workspace_path": "...", "total_write_mb": N, "write_rate_mb_per_sec": N, ... },
  "resources":  { "cpu_time_seconds": N, "memory_mb": N, "io_write_mb": N, ... },
  "threats":    null   // or [ { id, level, category, title, description, evidence, action } ]
}
```

The snapshot where `.threats != null` is the one that tripped the pause. Filter with jq:

```bash
jq -c 'select(.threats != null) | {ts:.timestamp, threats:.threats}' \
  ~/.coi/audit/<container>.jsonl
```

Categories the monitor watches (per `coi monitor --help`):

| Category     | Typical triggers                                               |
| ------------ | -------------------------------------------------------------- |
| `network`    | suspicious outbound connections, reverse-shell-ish endpoints   |
| `processes`  | reverse-shell / privilege-escalation process patterns          |
| `filesystem` | large workspace writes or reads (bulk exfil / ransomware-like) |
| `resources`  | CPU/mem/I/O spikes inconsistent with interactive AI work       |

`.threats[].evidence` carries the category-specific payload — for filesystem, it's `{write_bytes_mb, write_rate_mb_per_sec, threshold_mb, duration}`.

Live view (if the container is running): `coi monitor <container> --watch 2`.

### 8.3 Known benign trigger — first-session `pnpm install` / `npm ci`

The most common false positive on JS/TS monorepos: the filesystem detector's workspace-write threshold is **50 MB** (at the time of writing, not user-configurable). A `pnpm install` on a medium-sized repo writes hundreds of MB to the bind-mounted `node_modules/` in a few seconds, which looks identical to bulk exfiltration to the detector.

Recognise the signature:

```json
"category": "filesystem",
"title":    "Large workspace write detected",
"description": "Write 227.41 MB at 114.36 MB/sec (threshold: 50.00 MB)"
```

Mitigation, in order of preference:

1. **Pre-populate on host.** Run `pnpm install` (or equivalent) on the host before the first `make coi`. The bind-mounted `node_modules/` is visible inside the container unchanged — no write burst, no trigger.
2. **Batch-install with monitoring off temporarily.** For projects where host-side install is impractical, set `[monitoring] enabled = false` in config for a single session, then re-enable. (0.9 removed the per-session `--monitor` flag — monitoring is config-only now.) Leaving monitoring off is a standing invitation to miss a real event. See §5 invariant #3 in SKILL.md.
3. **Unfreeze and re-run.** `incus start <container>` resumes where it was; if the install had already written most of `node_modules` before the pause, the retry's burst may be small enough to stay under the threshold.

### 8.4 Resuming

```bash
incus start coi-XXXXXXXX-N          # unfreezes; preserves in-flight processes & FS state
# older Incus releases used:
incus unfreeze coi-XXXXXXXX-N
```

The frozen container retains all open TCP connections (state `ESTABLISHED` remains), file descriptors, and running processes. In practice, long-lived things (LSP servers, dev servers) survive the pause cleanly; shorter ones (a `curl` waiting on a socket) may time out.

### 8.5 Other real (non-benign) triggers to watch for

If the flag isn't the `pnpm install` signature, take it seriously before unfreezing:

- **`network` suspicious_count > 0** — check `.network.connections[] | select(.suspicious==true)` for the offending endpoint. Could be a malicious dependency phoning home (supply-chain attack), a prompt-injected task Claude executed, or a misconfigured tool.
- **`processes` reverse-shell pattern** — check `.processes.processes[]` for unexpected shells with network FDs.
- **`resources` burst** — often a runaway subprocess (infinite loop, fork bomb) rather than an attacker; still worth understanding before resuming.

In all three cases: inspect the audit log, identify the process/connection, decide whether to `incus delete <container> --force` (discard state) vs. `incus start` (resume) based on trust level.

Rebuild cadence: weekly by default; more often if you want new Claude features immediately. A systemd timer running `coi build` Sunday nights is a reasonable setup.

---

## 9. Playwright MCP — `chrome_crashpad_handler: --database is required`

### 9.1 Symptom

Calling any `mcp__playwright__browser_*` tool returns an error like:

```
Error: Target page, context or browser has been closed
Browser logs:
<launching> .../chromium-1222/chrome-linux64/chrome --headless --no-sandbox ... --disable-breakpad ...
<launched> pid=NNN
[pid=NNN][err] chrome_crashpad_handler: --database is required
[pid=NNN] <process did exit: exitCode=null, signal=SIGTRAP>
```

The full Chrome (chrome-for-testing 1217+) spawns its `chrome_crashpad_handler` child without the required `--database` argument; the handler exits, the renderer dies with `SIGTRAP`, and the browser closes before Playwright can attach. `--disable-breakpad` is in the launch flags but doesn't help — crashpad ≠ breakpad, and chromium has no equivalent stable disable flag for crashpad.

### 9.2 Why it bites COI specifically

Two factors line up:

1. The ms-playwright cache contains both `chromium-NNNN/chrome-linux64/chrome` (full chrome-for-testing — broken) and `chromium_headless_shell-NNNN/chrome-headless-shell-linux64/chrome-headless-shell` (Playwright-bundled headless build — works). Default Playwright MCP launches the full one.
2. Playwright MCP `--browser` only accepts `chrome | firefox | webkit | msedge`. A common attempt to dodge the issue by passing `--browser chromium` is silently ignored — MCP falls back to its default `chrome` channel, which is the broken binary.

### 9.3 Fix

`make coi-self-bootstrap` (inside the container) — the script in `references/coi-self-bootstrap.sh` installs `~/.local/bin/playwright-headless-shell` (a tiny wrapper that resolves and execs the newest cached `chromium_headless_shell-*` binary) and patches `~/.claude.json` so the playwright MCP server uses `--executable-path <wrapper>`. Idempotent; safe to re-run. After it patches the MCP config, restart Claude Code so MCP picks up the new args. SKILL.md §3.9 has the full design rationale.

### 9.4 Verifying directly without going through MCP

```bash
# Inside the container — should print "DevTools listening on ws://..." and exit 0:
~/.cache/ms-playwright/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell \
  --no-sandbox --remote-debugging-port=0 about:blank
# (Ctrl-C after a second; just checking it launches.)
```

If this command fails too, the headless_shell binary itself is broken (rare — likely a partial download). `rm -rf ~/.cache/ms-playwright/chromium_headless_shell-*` and let Playwright re-download on the next MCP call.

### 9.5 Why not just disable crashpad in the launch args

There's no stable Chrome flag for it. `--disable-features=Crashpad` doesn't exist; `--no-crash-upload` only suppresses the upload step. The crashpad handler is hard-wired into the full Chrome launch path. Routing around it via the headless_shell binary is the supported escape hatch.
---

## 10. `make coi` fatal on 0.9 — restricted-mode nft / untrusted mounts / ignored open network

coi 0.9's trust model turns a working 0.7-era `.coi/config.toml` into a hard failure. Symptom
(abridged) from `make coi`:

```
WARNING: ignoring security-downgrading "network.mode=open" in project config
  .../.coi/config.toml; move it to ~/.coi/config.toml or set COI_CONFIG to apply it.
[setup] Warning: ignoring untrusted mount from .../.coi/config.toml:
  ~/.claude/projects -> /home/code/.claude/projects (resolves outside the workspace;
  run 'coi trust' or set COI_TRUST_ALL=1)                       # ...and more mounts
Error: setup-container: failed to setup session: boot network block failed in restricted
  mode; ... failed to create nft table ip coi: nft command failed (output: sudo: a
  password is required)
```

Three independent 0.9 behaviours are stacked here:

### 10.1 `[network] mode = "open"` in the project file is IGNORED
0.9 treats a committed `.coi/config.toml` as untrusted, so a *security-downgrading* setting like
open egress is dropped. With no other source, COI falls back to `restricted`, which is what triggers
10.2. **Fix:** put the downgrade in a trusted file:

```bash
mkdir -p ~/.coi
cat > ~/.coi/config.toml <<'TOML'
[network]
mode = "open"          # trusted, applies host-wide
TOML
```

Per-project instead of host-wide: `export COI_CONFIG=$PWD/.coi/config.toml` (a `$COI_CONFIG` file is
trusted — only for a repo you own/review). The cosmetic `WARNING: ignoring security-downgrading…`
still prints on every `coi` command because the project file still carries `mode = "open"`; harmless.

### 10.2 Restricted mode needs passwordless sudo for nft (and iptables)
Restricted mode builds an `nft` table + iptables rules to enforce the allowlist. Without passwordless
sudo it can't, and 0.9 refuses to boot rather than run unprotected ("boot network block failed in
restricted mode"). `coi health` NETWORKING rows show the exact fix; apply it if you actually want
restricted mode:

```bash
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/nft"      | sudo tee /etc/sudoers.d/coi-nft
echo "$USER ALL=(ALL) NOPASSWD: /usr/sbin/iptables" | sudo tee /etc/sudoers.d/coi-iptables
sudo chmod 0440 /etc/sudoers.d/coi-nft /etc/sudoers.d/coi-iptables
```

Open-mode users can skip nft entirely (`coi health` → `nft not required for open mode`), though a
non-fatal bridge-forward iptables step still runs and may `[WARN]` on `iptables sudo`.

### 10.3 Out-of-workspace mounts are gated until `coi trust`
Any `[[mounts.default]]` whose host path resolves outside `/workspace` (e.g. `~/.claude/projects`,
`~/.claude/skills`, a creds dir) is silently dropped until approved — so even a successful boot lacks
Claude history/skills/etc. **Fix (run in the repo dir):**

```bash
coi trust
coi trust --list        # -> <fingerprint>  /abs/path/.coi/config.toml
```

Re-approval is required only when a mount's host/container/`readonly` changes (fingerprint-pinned),
not when unrelated settings change. `COI_TRUST_ALL=1` bypasses the gate — CI/automation only.

### 10.4 Clean up and verify
Remove the half-booted containers from the failed attempts, then verify without a full session:

```bash
coi kill <name> [<name> ...] --force
coi health              # CONFIGURATION + NETWORKING should be all [OK]/[WARN], no [FAIL]
```

`coi health` → `[OK] Config loaded: <path>`, `[OK] Network mode: open`, and `[OK] Container connect:
DNS and HTTP working` is proof the fix took, without launching an interactive agent.

### 10.5 Host-immutable `.coi` during a session
0.9 also `chattr +i`s protected dirs (`.coi`, `.husky`, `.vscode`) **while a container runs**, so a
host-side edit of `.coi/config.toml` mid-session fails with `EPERM`. Edit when no session is running,
or use the trusted `~/.coi/config.toml`. (`lsattr` shows the `i` flag only during an active session.)
