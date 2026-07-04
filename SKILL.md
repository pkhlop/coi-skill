---
name: coi
description: Set up, onboard, or operate code-on-incus (COI) — an Incus-based sandbox for running Claude Code and similar coding agents with --dangerously-skip-permissions safely. Use when the user asks to add COI to a project, create `.coi/config.toml`, wire COI into a Makefile, run Claude in a sandbox, forward SSH agent into the container, debug COI SSH/Docker/clipboard integration, upgrade the COI image, or set up Incus for COI on a new host.
---

# COI — sandboxed Claude Code via Incus

[code-on-incus](https://github.com/mensfeld/code-on-incus) (`coi`) runs AI coding agents inside Incus containers so they can work autonomously (`--dangerously-skip-permissions`) without putting the host at risk. The project files are bind-mounted, SSH access goes through an agent proxy (no private keys in the container), Docker-in-container works, and the network can be either open or restricted to an allowlist.

This skill covers three tasks:

1. **Host setup** (one-time per machine) — §1.
2. **Per-project onboarding** (drop COI into a new project) — §2.
3. **Daily operation + troubleshooting** — §3–§5.

Before acting on anything `sudo`-level or on a file outside the target project, confirm with the user.

> ### ⚠ Version compatibility — verified against `coi 0.9.x`
>
> **COI makes breaking changes across versions**, and this skill's exact paths, flags, and config
> keys track a specific one. Known examples between 0.7 and 0.9 alone: config discovery moved from a
> flat `.coi.toml` to the directory form **`.coi/config.toml`**; an **untrusted-project-config trust
> model** was added (`coi trust`, mount gating, security-downgrade gating); the per-session
> **`--network` flag was removed**; and `coi update` was added.
>
> **Whenever `coi` is (or may have been) upgraded** — `coi update`, re-running the installer, a
> distro/package bump, or a fresh machine — treat this skill as *possibly stale* and re-verify before
> relying on specifics:
>
> 1. `coi version` — note the number. If it's **newer than 0.9.x**, every exact path/flag/key below
>    is "needs re-verification"; prefer `coi --help`, `coi health`, and the upstream README.
> 2. `coi health` — the fastest one-shot check; its `CONFIGURATION` (`Config loaded`, `Network mode`)
>    and `NETWORKING` rows surface most breakage immediately.
> 3. Re-read **§2.1** (config discovery), **§2.4** (trust model), and **§4** (network) — these are the
>    surfaces that have actually broken across versions.
> 4. If a documented command errors or a setting is silently ignored, suspect version drift first,
>    check `coi <cmd> --help`, and flag the contradiction rather than forcing the old behavior.

---

## 1. Host setup (one-time)

Skip this section if `coi health` reports no `[FAIL]` entries in the CRITICAL block.

### 1.1 Requirements

- Linux host (Ubuntu 24.04 tested; other distros should work if Incus ≥ 6.1 is available).
- **Incus ≥ 6.1.** Ubuntu noble's main/ESM repo ships 6.0, which is too old — install from [Zabbly's stable repo](https://github.com/zabbly/incus).
- User in the `incus-admin` group (log out/in after adding).
- An SSH agent running (any flavour — `ssh-agent`, `gnome-keyring`, `keychain`).

### 1.2 Install order

1. Install Incus from Zabbly. If `apt-cache policy incus` shows 6.0 as Candidate even with Zabbly configured, a priority pin is needed — see `references/troubleshooting.md` §1.
2. `sudo incus admin init --minimal` — creates the default storage pool + bridge + root disk profile. **Skipping this makes every `coi build` fail with `No root device could be found`.**
3. `sudo usermod -aG incus-admin $USER` → log out + back in.
4. Install COI:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/mensfeld/code-on-incus/master/install.sh | bash
   ```
   (Review the installer before piping to bash; confirm with user.)
5. `coi build` — 5–10 minutes, pulls Claude Code's native installer (`claude.ai/install.sh`) at build time. **Don't kill it early**; don't poll.
6. `coi health` — verify every CRITICAL entry is `[OK]`.

### 1.3 SSH agent host socket

COI proxies the host's SSH agent into the container via an Incus `proxy` device. The host socket path matters because the Makefile targets (§2.2) reference it.

**Recommended one-time setup in the user's shell rc** (`~/.bashrc` / `~/.zshrc`):

```bash
# Long-lived agent on a known path, so COI's Incus proxy device can find it.
export SSH_AUTH_SOCK=/tmp/ssh-agent-$USER.sock
if [ ! -S "$SSH_AUTH_SOCK" ]; then
  ssh-agent -a "$SSH_AUTH_SOCK" > /dev/null
fi
```

Then `ssh-add` once per login to load keys. Consider `ssh-add -t 8h` to auto-expire, or `ssh-add -c` to require confirmation on every use — both trade convenience for defence in depth.

### 1.4 If installation hits problems

`references/troubleshooting.md` covers the three most common failures: apt pin for Incus version, the "container only gets IPv6" problem (firewalld/Docker netfilter conflicts), and the AppArmor-on-dnsmasq edge case. Walk it top-to-bottom if `coi build` hangs on "Waiting for network..." or a `coi shell` container can't reach the internet.

---

## 2. Per-project onboarding

Per-project setup is two files: a `.coi/config.toml` and a handful of Makefile targets. Both are reusable — templates live in `references/`.

### 2.1 Create `.coi/config.toml`

**File location + trust (coi ≥ 0.9).** The project config is a **directory-form** file at
`<repo>/.coi/config.toml`, and 0.9 treats it as **untrusted** — it can arrive via a cloned repo.
That trust split governs which settings actually take effect (see §2.4).

| Path | Scope | Trust |
|---|---|---|
| `<repo>/.coi/config.toml` | project (committed with the repo) | **untrusted** — out-of-workspace mounts and security-downgrading settings are gated |
| `~/.coi/config.toml` | user-global | **trusted** — the place for `[network] mode = "open"` and host-wide defaults |
| `$COI_CONFIG` (file path) | explicit override | **trusted** — but never point it at an untrusted repo's own config |

Verify discovery with `coi health` → `Config loaded: <path>` and `Network mode: <mode>`.

> **0.9 changed this.** Pre-0.9 used a flat `<repo>/.coi.toml`; 0.9 uses the directory form
> `<repo>/.coi/config.toml` **and** adds the trust model. If you have an old flat file, move it into
> `.coi/config.toml`. Do **not** put a security-downgrade like `mode = "open"` in the project file —
> 0.9 ignores it with a warning, and it only applies from the trusted `~/.coi/config.toml` or
> `$COI_CONFIG` (see §2.4 and §4). The directory form is canonical and is what `coi trust`,
> `coi shell`, and the config warnings all key on.

Template at `references/config.toml.template`. Minimal production-ready version:

```toml
[tool]
name = "claude"
permission_mode = "bypass"          # --dangerously-skip-permissions equivalent

[ssh]
forward_agent = true                # requires Makefile target to attach the proxy

[network]
mode = "restricted"                 # project file may only REQUEST restricted; "open" is a
                                    # security-downgrade → must live in ~/.coi/config.toml (§2.4/§4)

[monitoring]
enabled = true                      # threat-detection auto-pause

[environment]
SSH_AUTH_SOCK = "/tmp/ssh-auth.sock"  # must match listen path in Makefile proxy command

[defaults]
persistent = true                   # survives across shells; set false for ephemeral

# Bind mounts — applied at container creation. UID shift on by default
# (see [incus] disable_shift), so files appear as owned by the container's
# `code` user (uid 1000) regardless of host ownership — fixes the classic
# `nobody:nogroup` / Operation-not-permitted problem on bind-mounted paths.
[[mounts.default]]
host = "~/.claude/projects"              # Claude history survives across containers
container = "/home/code/.claude/projects"

[[mounts.default]]
host = "~/.claude/skills"
container = "/home/code/.claude/skills"
```

Copy, adjust, explain each line to the user before writing to `<project>/.coi/config.toml`.

**Mount caveats to flag when onboarding:**

- Mounts are **only applied on container creation.** If `[defaults] persistent = true` and a container already exists, editing `[[mounts.default]]` has no effect until the container is destroyed (`make coi-clean`) and recreated (`make coi`). coi logs `"Reusing existing workspace and mount configurations"` on the reuse path.
- Fields per entry: `host` (supports `~` expansion), `container` (must be absolute), `readonly` (bool, optional).
- To hot-attach a mount to an already-running container without destroying it: `incus config device add <container> <name> disk source=<host> path=<container> shift=true` — `shift=true` is critical or the files show as `nobody:nogroup`.
- **Out-of-workspace mounts are trust-gated (0.9).** Any `[[mounts.default]]` whose host path resolves outside `/workspace` — including the `~/.claude/projects` and `~/.claude/skills` mounts above — is silently dropped on first launch until approved with **`coi trust`** (run once in the repo dir). Re-approve whenever those mounts' host/container/`readonly` change. So the **first `make coi` boots without them until you `coi trust`**. See §2.4.
- Never mount `~/.ssh` or `$HOME`. See §5.

### 2.2 Wire Makefile targets

Copy the snippet from `references/Makefile.snippet` into the project's Makefile under a dedicated `# ── Sandboxed Claude (COI) ─` section. It provides:

- `make coi` — launches Claude in a sandbox with SSH-agent proxy attached.
- `make coi-resume` — resume the last session.
- `make coi-debug` — bash shell, no Claude (for diagnosing the container itself).
- `make coi-containers` — list only this project's containers (workspace-scoped).
- `make coi-ssh-fix` — idempotent re-attach of the SSH-agent proxy device. **Run this whenever `ssh-add -l` fails inside the container.**
- `make coi-docker-fix` — fix `/var/run/docker.sock` perms inside the container.
- `make coi-git-fix` — bind-mount the main worktree's `.git/` into the container so `git` resolves worktree paths. No-op in the main worktree; idempotent re-attach in a child worktree. See §3.10.
- `make coi-hosts` — write the running container's IP into `/etc/hosts` for `*.<project>.test`-style local domains (adapt `COI_LOCAL_DOMAIN` per project). Slug-aware (see §3.10): tags each line with a `# coi-hosts:<slug>` sentinel so multiple worktrees coexist safely.
- `make coi-hosts-clean` — remove only this worktree's `/etc/hosts` lines (matched by sentinel tag). Idempotent; safe to run when nothing is registered.
- `make coi-x11` — attach X11 clipboard + PulseAudio (microphone) to the running container. Enables Ctrl+V image paste and `/voice` dictation. **Run before `make coi`**, or restart Claude after.
- `make coi-extras` — install **generic, project-agnostic** terminal/navigation tools (mc, htop, rsync, pv, bash-completion, aria2, unzip, fzf-make) + apply the IPv4 gai.conf fix for the Incus bridge. Language runtimes (PHP, Node, Go, Python, Ruby) and project-scope tools (Playwright, AWS CLI, DB clients) are **not** installed here — they live in project-owned targets (see §2.3).
- `make coi-self-bootstrap` — **the one target that runs INSIDE the container, not on the host.** Re-applies fixes that don't survive `coi build` / container recreation: currently the Playwright headless-shell wrapper (see §3.9). Idempotent — invoked from `/workspace` inside a coi shell. Every other target on this list runs on the host; this one is the exception.
- `make coi-clean` — stop & delete **only this project's** COI container(s); never touches other projects.
- `make coi-update` — `coi build` with a clear message, for cadence-based image refreshes. After this completes, run `make coi-self-bootstrap` from inside the new container (see §3.9).

The snippet is parameterised via `$(USER)` and has no project-specific names baked in. One var worth explaining: `COI_SSH_SOCK` (host agent path, defaults to `/tmp/ssh-agent-$(USER).sock`). Bind mounts are not defined in the Makefile — they live in `[[mounts.default]]` in `.coi/config.toml` (see §2.1). Never add `~/.ssh` or `$HOME` to either the mounts or the Makefile.

**Multi-project isolation invariant — don't break it.** One host's Incus daemon is shared by every project the user runs through COI. Containers from different projects only differ in the 8-hex suffix of their name (`coi-<workspace-hash>-<slot>`), so a naive `grep '^coi-'` filter matches **everyone's** containers — running `make coi-clean` with that pattern will delete another project's in-flight work. The snippet enforces workspace scoping via a single helper:

```make
COI_THIS_JQ := (.active_containers // [])[] | select(.workspace==$$ws and .status=="Running") | .name
coi-this-container = coi list --format json 2>/dev/null | jq -r --arg ws '$(CURDIR)' '$(COI_THIS_JQ)'
```

Every recipe that targets a container calls `$(coi-this-container)` — it returns only containers whose COI workspace equals `$(CURDIR)`. Requires `jq` on the host. When adding new container-targeting recipes, **never `grep '^coi-'` alone** — always go through the workspace filter. `coi-clean` also intentionally skips the global `coi clean` command, because that sweeps orphaned firewall rules across *all* projects.

### 2.3 Project-specific toolchains

The skill deliberately keeps `coi-extras` generic: infrastructure glue (IPv4 fix, SSH agent, Docker socket) and universal terminal tools. **Language runtimes, package managers, and project-scope binaries belong in a project-owned Makefile target** — typically a `coi-project-setup` target added alongside `coi-extras`, or by extending `coi-extras` inside the project's own Makefile (not the skill's snippet).

**When onboarding COI into a project, inspect the repo to derive versions:**

| Language | Version sources (highest-precedence first) |
|---|---|
| PHP | `composer.json` → `require.php` / `config.platform.php`; `.php-version` |
| Node | `package.json` → `engines.node`; `.nvmrc`; `.node-version`; `volta.node` |
| Go | `go.mod` → `go <version>` directive; `go.work` |
| Python | `pyproject.toml` → `requires-python` or `[tool.poetry.dependencies].python`; `.python-version`; `runtime.txt` |
| Ruby | `.ruby-version`; `Gemfile` → `ruby '...'`; `.tool-versions` |
| Rust | `rust-toolchain.toml` / `rust-toolchain` file |
| Java | `pom.xml` → `maven.compiler.release`; `build.gradle(.kts)`; `.java-version` |

If the project declares a lower bound (e.g. `"php": ">=8.2"`), prefer the **newest stable** in that line (e.g. PHP 8.3). If nothing is declared, ask the user rather than guessing.

**Install patterns — reference recipes, apply only what the project needs:**

- **PHP** — Ubuntu 22.04 (jammy, the COI base) ships PHP 8.1; use `ondrej/php` for newer:
  ```bash
  add-apt-repository -y ppa:ondrej/php
  apt-get update -qq
  apt-get install -y php<VER>-{cli,mbstring,xml,curl,zip,intl,bcmath}   # pick extensions per project
  update-alternatives --set php /usr/bin/php<VER>
  # Composer (version-agnostic):
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  ```

- **Node** — prefer `fnm` (faster than nvm, no shell-rc hook needed):
  ```bash
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --install-dir /usr/local/fnm --skip-shell
  /usr/local/fnm/fnm install <VER> && /usr/local/fnm/fnm default <VER>
  ln -sf /usr/local/fnm/aliases/default/bin/{node,npm,npx} /usr/local/bin/
  ```

- **Go** — tarball from go.dev (apt's version lags):
  ```bash
  curl -fsSL https://go.dev/dl/go<VER>.linux-amd64.tar.gz | tar -C /usr/local -xz
  ln -sf /usr/local/go/bin/{go,gofmt} /usr/local/bin/
  ```

- **Python** — apt for 3.10/3.11/3.12 if available; `deadsnakes/ppa` for others; `pyenv` only if the project pins a specific 3.X.Y:
  ```bash
  add-apt-repository -y ppa:deadsnakes/ppa
  apt-get install -y python<VER> python<VER>-venv python<VER>-dev
  ```

- **Ruby** — `rbenv` (apt's ruby is usually stale):
  ```bash
  git clone --depth 1 https://github.com/rbenv/rbenv.git /usr/local/rbenv
  /usr/local/rbenv/bin/rbenv install <VER>
  ```

- **Playwright, AWS CLI, DB clients, protoc, etc.** — all project-scoped. Install in the project's target, not `coi-extras`.

**When wiring a new project, Claude should:**
1. Read the version files above; if none exist, ask the user what the project targets.
2. Pick a specific major.minor version (newest stable that satisfies the project's lower bound).
3. Add a project-owned target (`coi-project-setup` or extend `coi-extras` in the project's Makefile). Do **not** edit the skill's reference snippet.
4. Include the `update-alternatives --set php`-style default-binary step so `php`, `node`, etc. resolve without version suffixes.
5. Bake version pins into Make variables (e.g. `COI_PHP_VERSION ?= 8.3`) so upgrades are a one-line change.

### 2.4 Trust model (coi ≥ 0.9)

0.9 treats a repo-committed `.coi/config.toml` as **untrusted** — a cloned repo could otherwise
mount your home directory or open the network on you. Two classes of setting are gated:

1. **Out-of-workspace bind mounts.** Any `[[mounts.default]]` whose host path resolves outside
   `/workspace` is **ignored at launch** until you approve it:

   ```bash
   coi trust            # run in the repo dir — approves this project's out-of-workspace mounts
   coi trust --list     # -> <fingerprint>  /abs/path/.coi/config.toml
   coi untrust          # revoke
   ```

   Approval is **pinned to a fingerprint of the approved mounts** — changing a mount's host path,
   container path, or `readonly` flag requires re-approval; changing unrelated settings (base image,
   network mode) does not. In-workspace mounts and mounts from the trusted `~/.coi/config.toml` /
   `$COI_CONFIG` are never gated.
   - **Onboarding consequence:** the standard `~/.claude/projects` + `~/.claude/skills` mounts are
     out-of-workspace, so the **first `make coi` boots without them until `coi trust`**. The full
     onboarding sequence is: write config → `coi trust` → `make coi`.

2. **Security-downgrading settings.** `[network] mode = "open"` in the *project* file is ignored
   with `WARNING: ignoring security-downgrading "network.mode=open" …`; it only applies from the
   trusted `~/.coi/config.toml` or a `$COI_CONFIG`-referenced file (see §4).

**`COI_TRUST_ALL=1`** bypasses the mount gate — **CI/automation only**, never interactive on a host
where you clone untrusted repos. A `$COI_CONFIG` file is trusted, so don't point `$COI_CONFIG` at an
untrusted repo's own `.coi/config.toml`.

### 2.5 `.gitignore` & secrets

`.coi/config.toml` is safe to commit — it contains no secrets. But verify with the user before committing: some projects override `[environment]` with real values.

---

## 3. Daily operation

### 3.1 Start / stop / resume

```bash
make coi                  # start fresh sandboxed Claude session
make coi-resume           # resume the most recent session (--resume=auto)
# Detach without killing:  Ctrl+B d  (tmux detach)
# Reattach:                make coi  (or coi shell) from same project
```

### 3.2 Parallel sessions

COI supports multiple slots per workspace. Launch a second one explicitly:

```bash
coi shell --slot 2        # second parallel sandbox for this project
coi list                  # show active containers
```

Different projects are isolated automatically by workspace (`-w` / `--workspace`). Each slot gets its own container, its own bridge IP, and its own tmux session.

### 3.3 SSH agent lifecycle

If `ssh-add -l` fails inside the container, the proxy device either never attached (timing race on startup) or got disconnected (agent restarted on host). Fix in order:

1. From host: `ssh-add -l` — confirm the agent is live and has keys.
2. From host: `make coi-ssh-fix` — idempotent re-attach.
3. From inside container: `export SSH_AUTH_SOCK=/tmp/ssh-auth.sock && ssh-add -l`.

Put the export into the container user's `~/.bashrc` (survives `--persistent` mode) so it's automatic:

```bash
echo 'export SSH_AUTH_SOCK=/tmp/ssh-auth.sock' >> ~/.bashrc
```

### 3.4 X11 clipboard, image paste & microphone (optional)

`make coi-x11` attaches the host's X11 display, clipboard, and PulseAudio socket to the running container. After running it, Claude Code's Ctrl+V image paste and `/voice` dictation work natively inside the sandbox.

What it does:
1. Mounts `/tmp/.X11-unix/X0` (X11 socket) into the container.
2. Copies the host's `$XAUTHORITY` file into `/home/code/.Xauthority` with correct ownership (disk-mount causes `nobody:nogroup` — use `incus file push --uid 1000 --gid 1000` instead).
3. Mounts the PulseAudio socket (`/run/user/<uid>/pulse/native`) for microphone access.
4. Installs `xclip` + `pulseaudio-utils` + `libasound2-plugins` inside the container.
5. Writes `/etc/asound.conf` to route ALSA through PulseAudio (Claude Code's audio uses ALSA, which fails without a sound card unless routed through PulseAudio).
6. Writes `/etc/profile.d/x11-audio.sh` (sets `DISPLAY`, `XAUTHORITY`, `PULSE_SERVER`) and sources it from `/etc/bash.bashrc` for non-login shells.
7. Runs `xhost +si:localuser:root` on the host to allow container X connections.

**Important**: Claude Code must be (re)started **after** `make coi-x11` — the env vars are only picked up by new shells. If you run `make coi-x11` while Claude is already running, exit and re-enter with `make coi`.

**Fallback (file-based paste):** if X11 forwarding is unwanted, save clipboard images to a bind-mounted path on the host and reference by filename inside Claude. See `references/troubleshooting.md` §4.1.

**Tradeoff:** container gains full X-clipboard + keylog reach + microphone access of the host. Fine for own-code sandbox; weakens isolation for untrusted workloads.

### 3.5 Performance note — first-connection slowness

If `apt`, `curl`, `npm install`, or `git clone` feel very slow (9+ second pauses before bytes start flowing) but Cloudflare-backed downloads are fast, the cause is almost always the **IPv6 happy-eyeballs timeout**: the Incus bridge advertises IPv6 but the host has no IPv6 internet route, so every connection waits for IPv6 to time out before falling back to IPv4.

Symptom check:
```bash
# On host — if empty, host has no IPv6 internet → containers will hit the timeout
ip -6 route show default
```

One-line fix inside the container (or bake into `coi-extras` / image):
```bash
printf '%s\n' \
  'precedence  ::1/128       50' \
  'precedence  ::/0          40' \
  'precedence  2002::/16     30' \
  'precedence ::/96          20' \
  'precedence ::ffff:0:0/96 100' > /etc/gai.conf
```

See `references/troubleshooting.md` §6 for diagnosis, expected performance profile (container vs host), and the Ubuntu-mirror flakiness follow-up.

### 3.6 Security monitor paused the container

If Claude's terminal prints `*** SECURITY: Container coi-XXXX PAUSED due to security threat. Resume with: incus start coi-XXXX ***`, the container is frozen — state preserved, not killed. **Investigate before resuming.**

Evidence is at `~/.coi/audit/<container>.jsonl` (JSONL of ~10 s snapshots; the one with `.threats != null` is the offender):

```bash
jq -c 'select(.threats != null) | {ts:.timestamp, threats:.threats}' \
  ~/.coi/audit/<container>.jsonl
```

The most common false positive on JS/TS monorepos is `filesystem` / "Large workspace write detected" during first-session `pnpm install` — the detector's workspace-write threshold is 50 MB and `node_modules/` blows past it in seconds. Fix by running `pnpm install` on the **host** before `make coi` (the bind-mounted `node_modules/` appears inside the container, no write burst).

Other categories the monitor watches: `network` (suspicious connections), `processes` (reverse-shell patterns), `resources` (CPU/mem/I/O spikes). Network and process flags should be treated as real until proven otherwise.

Resume with `incus start <container>` once the cause is understood.

See `references/troubleshooting.md` §8 for the full schema, mitigation order, and non-benign-trigger playbook.

### 3.7 Upgrading Claude / the image

Claude Code is baked into the `coi-default` image at `coi build` time via `claude.ai/install.sh`. Running containers are frozen at whatever Claude version was current when the image was built.

- **Ephemeral containers** (default): `make coi-update` rebuilds the image — next `coi shell` gets the new Claude. 5–10 min.
- **Persistent slots** (`[defaults] persistent = true`): run `claude update` inside the container; the upgrade sticks because the container state survives.
- **Don't** `npm install -g @anthropic-ai/claude-code@latest` inside the container — installs a parallel copy that fights the native install on `$PATH`.
- **The `coi` binary itself:** `coi update` (0.9) updates coi and its threat-detection databases — distinct from `coi build`, which rebuilds the container *image*. Re-running the upstream install script also upgrades the binary.

Rebuild cadence: weekly is a reasonable default; more often if Claude ships a feature you need.

### 3.8 Bridging host services into the container

Some services can't run in COI — GPU-dependent workloads (PyTorch/CUDA inference), memory-heavy data engines, anything relying on host-only hardware. The pattern: **run the service on the host, bridge its port into the container via an Incus `proxy` device.**

Topology:
- Host service listens on `127.0.0.1:<PORT>` (loopback only — the proxy is the only path in).
- Incus proxy device listens on `0.0.0.0:<PORT>` **inside** the container and forwards to the host's loopback.
- Container processes reach it at `localhost:<PORT>`.
- Docker-in-container processes reach it at `host.docker.internal:<PORT>` — Docker's `host-gateway` already resolves that name to the Docker host (= the Incus container = where the proxy listens), so no extra plumbing is needed beyond adding `extra_hosts: - "host.docker.internal:host-gateway"` to the dependent service's compose file.

One-time attachment:

```bash
incus config device add <container> <name>-proxy proxy \
    listen=tcp:0.0.0.0:<PORT> \
    connect=tcp:127.0.0.1:<PORT> \
    bind=container
```

Verify from each layer:

```bash
# From host
curl -s 127.0.0.1:<PORT>/health

# From inside the Incus container
incus exec <container> -- curl -s localhost:<PORT>/health

# From inside a nested Docker service
docker exec <svc> curl -s host.docker.internal:<PORT>/health
```

**Persistence caveat.** Incus devices live on the container, not on the image — they don't survive `make coi-clean` + recreate. For anything project-critical, wrap the `incus config device add` in an idempotent Makefile target (`coi-<name>-proxy`) in the project's Makefile, so a single `make` invocation reattaches after recreation:

```make
coi-nlp-proxy: ## (Re)attach host nlp-service (:8000) proxy to this project's COI container
	@CONTAINER=$$($(coi-this-container) | head -1); \
	test -n "$$CONTAINER" || { echo "ERROR: no running COI container for this project ($(CURDIR))"; exit 1; }; \
	incus config device remove $$CONTAINER nlp-proxy 2>/dev/null || true; \
	incus config device add $$CONTAINER nlp-proxy proxy \
		listen=tcp:0.0.0.0:8000 \
		connect=tcp:127.0.0.1:8000 \
		bind=container >/dev/null; \
	echo "==> nlp-proxy attached to $$CONTAINER. Host nlp-service must be listening on 127.0.0.1:8000."
```

Use the workspace-scoped `$(coi-this-container)` helper from §2.2 so a mis-timed invocation can't attach a device to another project's container.

This complements §6's "GPU access" limitation — the container still has no GPU, but it has a stable path to a host service that does.

### 3.9 Self-bootstrap inside the container (per-rebuild fixes)

A handful of fixes can't live in the COI image and don't survive a `coi build` / container recreation: they touch `~/.claude.json` (per-container, not bind-mounted), `~/.local/bin/` (overlay state), or otherwise need to run as the `code` user *inside* the container. The convention for these is a single inside-container Make target — `make coi-self-bootstrap` — that re-applies them idempotently. **It is the only `coi-*` target that runs inside the container; every other one runs on the host.**

**When to invoke it.**

- **Once per fresh container.** After `make coi` boots a new container (first launch on a project, or after `make coi-clean` / `make coi-update`), open a coi shell, `cd /workspace`, and run `make coi-self-bootstrap`. Then restart Claude Code so MCP picks up any config changes.
- **Whenever Playwright MCP fails with `chrome_crashpad_handler: --database is required`** or "browser closed before MCP could attach" — see troubleshooting.md §9.
- **As a "doctor" call before reporting a sandbox bug.** It re-asserts the known-good baseline; if symptoms persist after a clean run of `coi-self-bootstrap`, the issue is something new.

**What it currently fixes.**

- *Playwright headless-shell wrapper.* Installs `~/.local/bin/playwright-headless-shell` — a tiny shell script that resolves the newest cached `chromium_headless_shell-*` binary at run time and execs it. Then patches `~/.claude.json` so the `playwright` MCP server uses `--executable-path <wrapper>`. This routes around the chrome-for-testing 1217+ crashpad-handler crash where the parent Chrome doesn't pass `--database` to the crashpad child, which exits, and the renderer dies with `SIGTRAP` before Playwright can attach. The headless_shell binary doesn't ship the broken handler, so launches succeed. The wrapper resolves the cache lazily, so a Playwright version bump (new `chromium_headless_shell-NNNN` directory in `~/.cache/ms-playwright/`) is picked up automatically — no re-pinning needed.

**Extending it.** When another inside-container fix appears (e.g. a similar quirk in another MCP, a perms tweak that has to be `code`-side, a project's Playwright cache warmup), add a step to `references/coi-self-bootstrap.sh` modeled on the Playwright block. Keep each step idempotent: detect "already current", skip silently, only print on change. Don't add inside-container fixes to host-side targets like `coi-extras` — `incus exec` runs as root, fights UID-shifting on home-dir writes, and confuses what's truly per-container vs. per-image.

**Detection note.** The script refuses to run unless `$HOME == /home/code` AND `~/.cache/ms-playwright/` exists. That keeps an accidental host-side `make coi-self-bootstrap` from clobbering host config. The corresponding host-side target (in `references/Makefile.snippet`) just `exec`s the bind-mounted script — there's no host-vs-container branching in the Makefile itself, the script is the gate.

### 3.10 Parallel git worktrees

COI was designed to play well with multiple checkouts of the same repo: `coi list` keys containers by workspace path, and the `$(coi-this-container)` helper in `Makefile.snippet` filters by `$(CURDIR)`. So a worktree at a different path automatically gets its own container with no extra flags. What still needs project-level coordination is everything *else* the project pins to the working directory — Docker volume names, `/etc/hosts` entries, local hostnames.

**The pattern: one slug, one file, one truth.** Put a `.worktree-slug` file (gitignored, one line, DNS-safe, ≤30 chars) at the worktree root. The main worktree has no file → empty slug → unprefixed behavior. Non-main worktrees have a file → everything namespacing-related reads from it.

Read it in the Makefile once, then propagate to the four places that would otherwise collide:

```make
WORKTREE_SLUG := $(strip $(shell test -f .worktree-slug && cat .worktree-slug 2>/dev/null))
WORKTREE_HOST_PREFIX := $(if $(WORKTREE_SLUG),$(WORKTREE_SLUG).,)
COI_HOSTS_SENTINEL := coi-hosts:$(if $(WORKTREE_SLUG),$(WORKTREE_SLUG),main)
ifneq ($(WORKTREE_SLUG),)
export COMPOSE_PROJECT_NAME := <project>-$(WORKTREE_SLUG)
endif
```

| Where the slug shows up | Why it matters |
|---|---|
| `COMPOSE_PROJECT_NAME` | Docker namespaces containers, networks, **and named volumes** by project name. A non-empty slug → each worktree's stack gets its own `postgres_data` volume. |
| `WORKTREE_HOST_PREFIX` in `/etc/hosts` lines | `<slug>.<project>.test`, `api.<slug>.<project>.test`, etc. — distinct entries per worktree, no clobbering. |
| `COI_HOSTS_SENTINEL` trailing comment | `coi-hosts-clean` deletes by sentinel, not by hostname regex. Safe regardless of how many worktrees share `/etc/hosts`. |
| Worktree directory name (by convention) | `../<project>-<slug>` keeps `git worktree list` legible. |

**Don't bake hostname-pattern deletion into `coi-hosts`.** The old shape (`sed -i '/\.<project>\.test/d' /etc/hosts`) wipes every sibling worktree's lines too. Use a sentinel:

```make
coi-hosts:
	@... compute $$IP, $$HOSTS ...; \
	sudo sed -i '/# $(COI_HOSTS_SENTINEL)$$/d' /etc/hosts; \
	echo "$$IP  $$HOSTS  # $(COI_HOSTS_SENTINEL)" | sudo tee -a /etc/hosts >/dev/null

coi-hosts-clean:
	@sudo sed -i '/# $(COI_HOSTS_SENTINEL)$$/d' /etc/hosts
```

**Volume-vs-secret tradeoff.** Worktrees almost always want **isolated volumes** (so a destructive migration on one branch doesn't trash another's data) but **shared secrets** (one rotation should flow everywhere). The pattern: copy generated env files into the new worktree but **symlink** the canonical `.setup-state/` (or equivalent secret store) back to the main worktree. `worktree-add` does this; `worktree-remove` never deletes through the symlink because `git worktree remove` operates on the worktree dir, not the symlink target.

**`worktree-add` and `worktree-remove` belong in the project Makefile**, not the skill's generic snippet — the copy/rewrite steps depend on project-specific filenames (which env files exist, what compose file is rendered, whether DOMAIN/LOCAL_DOMAIN are templated). The skill provides the primitives (`coi-hosts`, `coi-hosts-clean`, slug-aware vars); the project composes them.

**Child worktrees need the main worktree's `.git/` bind-mounted into the container.** A child worktree's `.git` is a *file* containing `gitdir: <absolute-host-path>` pointing into the main worktree's `.git/worktrees/<name>/`. COI bind-mounts only `$CWD` at `/workspace`, so that absolute path doesn't exist inside the container and `git status` fails with `fatal: not a git repository: …`. The fix is one Incus disk device that exposes the main worktree's `.git/` at the same absolute path inside the container, with `shift=true` so UID-shift treats it like the rest of the workspace (without `shift=true` the dir appears as `nobody:nogroup` and git's safe-directory check fires):

```make
coi-git-fix:
	@test -n "$(WORKTREE_SLUG)" || { echo "Main worktree — nothing to fix."; exit 0; }
	@CONTAINER=$$($(coi-this-container) | head -1); \
	MAIN_GIT=$$(realpath $$(git rev-parse --git-common-dir)); \
	incus config device remove $$CONTAINER main-git-dir 2>/dev/null || true; \
	incus config device add $$CONTAINER main-git-dir disk \
		source=$$MAIN_GIT path=$$MAIN_GIT shift=true
```

The `_coi-ssh-watcher` recipe applies this automatically when `make coi` runs from a non-main worktree, so the standalone target only matters when re-attaching after `coi-clean` / container recreation.

**Known limitation: hardcoded Traefik Host rules.** If a project's local compose hardcodes `Host(\`<project>.test\`)` rather than templating from a var, slug-prefixed `/etc/hosts` entries resolve to the right container but Traefik inside that container won't route them. Either template those rules or accept that "two stacks serving HTTP at the local domain" is serialized until templating lands. Volume isolation and sandboxed Claude per worktree work regardless.

Reference implementation: a worktree ADR in your own project (covers slug derivation rules, the `.env` rewrites, the `setup-state` symlink, and the `worktree-add` / `worktree-remove` flow end-to-end).

---

## 4. Firewall modes

COI supports `restricted` (allowlist egress) and `open` (unrestricted egress), set via
`[network] mode`. **There is no per-session `--network` flag in 0.9 — network mode is config-only**
(the old `coi shell --network …` flag was removed).

- **`restricted`** is the default and the security-conscious choice: allowlist for
  `api.anthropic.com`, package registries, common git hosts; other egress blocked. It's enforced
  with an `nft` table + iptables rules, which need **passwordless sudo for `/usr/sbin/nft`** (and
  iptables for bridge forwarding) — without it 0.9 **refuses to boot** ("boot network block failed
  in restricted mode"). `coi health` prints the exact sudoers one-liners; see
  `references/troubleshooting.md §10`. `restricted` may live in the project `.coi/config.toml`.
- **`open`** is for agents that need unknown egress (scraping, rotating-endpoint APIs, WebRTC) and
  needs no nft. But `open` is a **security downgrade**, so 0.9 **ignores it from the project file** —
  it must come from the trusted `~/.coi/config.toml` or a `$COI_CONFIG` file:

  ```toml
  # ~/.coi/config.toml  (trusted, applies host-wide)
  [network]
  mode = "open"
  ```

  For per-project open scope instead of host-wide, `export COI_CONFIG=$PWD/.coi/config.toml` (a
  `$COI_CONFIG` file is trusted) — only for a repo you own and review.

Modes merge (trusted global + project file). Verify the effective mode with `coi health` →
`Network mode:`. Note that even in `open` mode a non-fatal bridge-forward iptables step still runs,
so `coi health` may `[WARN]` on `iptables sudo` without blocking the boot.

---

## 5. Security invariants

These MUST hold. If a setup step would violate one, refuse and surface the conflict:

1. **Never mount `~/.ssh` into the container.** SSH access is agent-forwarded only. The agent proxy exposes the *ability to sign*, not the private key.
2. **Never mount the full `$HOME`.** Mount specific subdirectories (`~/.claude/projects`, `~/.claude/skills`) explicitly.
3. **Do not disable `[monitoring] enabled`** to make a smoke test pass. The threat detector auto-pauses containers on suspicious patterns — that's the feature, not the bug.
4. **Do not commit `.coi/config.toml` to a public repo without reviewing `[environment]`** — it's a common place to accidentally paste secrets.
5. **Ephemeral by default, persistent by choice.** Long-running persistent slots accumulate state (shell history, downloaded tools) that an attacker could probe. Prefer ephemeral unless the upgrade/time cost is meaningful.
6. **Keep `coi` and the image current.** `coi update` refreshes the binary + threat databases; `coi build` rebuilds the image. Weekly is reasonable — old base images accumulate CVEs.
7. **Don't remove or override the `protect-git-config` / `protect-git-hooks` devices.** COI adds these read-only bind mounts over `/workspace/.git/config` and `/workspace/.git/hooks/` automatically — visible in `incus config device show <container>`. They block the classic git-hook escape vector: an agent writes `[core] hooksPath = /tmp/evil` into `.git/config` or drops a `post-commit` into `.git/hooks/`, and the next `git commit` **you** run on the host executes attacker-controlled code under your host identity, with your SSH agent and your shell. The mounts make those writes fail with `EROFS` while leaving the rest of `.git/` (refs, objects, index) writable so normal git operations inside the container still work. If you see a failing `git config --local` or a hook-install step that errors, that's the protection doing its job — don't "fix" it by removing the device. 0.9 also applies **host-side immutable protection** (`chattr +i`, visible via `lsattr`) to protected dirs (`.coi`, `.husky`, `.vscode`) **while a session/container is running**, so a host-side edit of `.coi/config.toml` mid-session can fail with `EPERM`. Same protection, not a bug — edit config when no session is running, or use the trusted `~/.coi/config.toml`.
8. **Don't blanket-set `COI_TRUST_ALL=1`.** It bypasses the 0.9 mount-trust gate that stops a cloned repo from mounting your home dir or opening the network. Approve per-project with `coi trust` on a host; reserve `COI_TRUST_ALL=1` for CI. (§2.4)

---

## 6. When *not* to use COI

- Tasks that need GPU access *inside* the container. (GPU-dependent services can still run on the host and be bridged in via an Incus proxy device — see §3.8.)
- Tasks where the agent must write outside the mounted workspace (it can't by design).
- Projects where the 5–10 minute `coi build` cost dominates a 30-second task.
- CI/CD — COI is a local sandbox. Use proper CI infrastructure for automated pipelines.

---

## References

- `references/config.toml.template` — drop-in `.coi/config.toml`.
- `references/Makefile.snippet` — drop-in Makefile section.
- `references/troubleshooting.md` — install-time pitfalls, SSH/Docker/clipboard debugging, IPv6/apt slowness fix (§6), performance baseline, Incus reset procedure.
- Upstream: https://github.com/mensfeld/code-on-incus (README is authoritative; if this skill contradicts it, trust the README and flag the drift).