---
name: coi
description: Set up, onboard, or operate code-on-incus (COI) — an Incus-based sandbox for running Claude Code and similar coding agents with --dangerously-skip-permissions safely. Use when the user asks to add COI to a project, create `.coi/config.toml`, wire COI into a Makefile, run Claude in a sandbox, forward SSH agent into the container, debug COI SSH/Docker/clipboard/microphone integration, pass an NVIDIA GPU into the sandbox, upgrade the COI image or the coi binary, or set up Incus for COI on a new host.
---

# COI — sandboxed Claude Code via Incus

[Coi / code-on-incus](https://github.com/coipond/coi) (`coi`; formerly `mensfeld/code-on-incus`) runs AI coding agents inside Incus containers so they can work autonomously (`--dangerously-skip-permissions`) without putting the host at risk. The project files are bind-mounted, SSH access goes through an agent proxy (no private keys in the container), Docker-in-container works, and the network can be either open or restricted to an allowlist.

This skill covers three tasks:

1. **Host setup** (one-time per machine) — §1.
2. **Per-project onboarding** (drop COI into a new project) — §2.
3. **Daily operation + troubleshooting** — §3–§5.

Before acting on anything `sudo`-level or on a file outside the target project, confirm with the user.

> ### ⚠ Version compatibility — verified against `coi 0.15.0`
>
> **COI makes breaking changes across versions**, and this skill's exact paths, flags, and config
> keys track a specific one. Known examples between 0.7 and 0.9 alone: `[defaults] persistent` was
> **removed in 0.8.0** and is now a hard load error; config discovery moved from a flat `.coi.toml`
> to the directory form **`.coi/config.toml`**; an **untrusted-project-config trust model** was added
> (`coi trust`, mount gating, security-downgrade gating); the per-session **`--network` flag was
> removed**; SSH-agent forwarding became **fully native** (device + `SSH_AUTH_SOCK`, §3.3); and
> `coi update` was added.
>
> **0.9 → 0.15 (verified on a live 0.15.0 upgrade):** see §3.12 for the upgrade procedure. The ones
> that bite: `coi update` on ≤ 0.11.0 **wrongly reports "already on the latest version"** (manual
> install); **trust approvals made by 0.9 are not honored** — every project needs `coi trust` again
> or its mounts are silently dropped; root-level `model` moved to **`[tool.claude] model`** (0.11);
> direct commits/pushes to **`main`/`master` are blocked by default** (0.14); `managed-settings.json`
> is now written readable (0.9.0's unreadable copy caused an org-login prompt, §3.12); config-shaped
> CLI flags (`--image`, `--persistent`, …) were removed (0.10); the project moved to `coipond/coi`.
> Re-verified on 0.15.0: config discovery, `[[mounts.default]]`, trust gating, native SSH forwarding,
> `[defaults.environment]`, open network from `~/.coi`, `coi list --format json` shape, and the
> `--slot`/`--resume`/`--debug`/`-w` flags the Makefile uses. **Not** re-verified: restricted network
> mode (§4) and the X11/Docker details beyond what §3.4 states.
>
> **The dangerous drift is the silent kind.** A removed key errors loudly and gets fixed. A key that
> moved to a different *table* (`[environment]` → `[defaults.environment]`) parses fine and does
> nothing, and guidance built on top of it keeps looking correct while the feature is dead. When
> validating this skill against a new coi, don't just check that things *load* — check that they
> *applied* (§2.7).
>
> **Whenever `coi` is (or may have been) upgraded** — `coi update`, re-running the installer, a
> distro/package bump, or a fresh machine — treat this skill as *possibly stale* and re-verify before
> relying on specifics:
>
> 1. `coi version` — note the number. If it's **newer than 0.15.x**, every exact path/flag/key below
>    is "needs re-verification"; prefer `coi --help`, `coi health`, and the upstream README.
> 2. `coi health` — the fastest one-shot check; its `CONFIGURATION` (`Config loaded`, `Network mode`)
>    and `NETWORKING` rows surface most breakage immediately.
> 3. `coi profile info default` — shows the built-in profile (image, persistence, network allowlist).
>    Useful context, but **not a statement of what a container will get**: its `[[mounts]]` list the
>    two `~/.claude` paths that a project run does *not* actually receive unless the project config
>    declares them (§2.1). Treat it as documentation of defaults, not as effective config.
> 4. Re-read **§2.1** (config schema + discovery), **§2.4** (trust model), **§3.3** (SSH), and **§4**
>    (network) — these are the surfaces that have actually broken across versions.
> 5. If a documented command errors *or a setting is silently ignored*, suspect version drift first,
>    check `coi <cmd> --help`, and flag the contradiction rather than forcing the old behavior.

---

## 1. Host setup (one-time)

Skip this section if `coi health` reports no `[FAIL]` entries in the CRITICAL block.

### 1.1 Requirements

- Linux host (Ubuntu 24.04 and 26.04 tested; other distros should work if Incus ≥ 6.1 is available).
- **Incus ≥ 6.1.** Ubuntu noble's main/ESM repo ships 6.0, which is too old — install from [Zabbly's stable repo](https://github.com/zabbly/incus).
- User in the `incus-admin` group (log out/in after adding).
- An SSH agent running (any flavour — `ssh-agent`, `gnome-keyring`, `keychain`).

### 1.2 Install order

1. Install Incus from Zabbly. If `apt-cache policy incus` shows 6.0 as Candidate even with Zabbly configured, a priority pin is needed — see `references/troubleshooting.md` §1.
2. `sudo incus admin init --minimal` — creates the default storage pool + bridge + root disk profile. **Skipping this makes every `coi build` fail with `No root device could be found`.**
3. `sudo usermod -aG incus-admin $USER` → log out + back in.
4. Install COI:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/coipond/coi/master/install.sh | bash
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

> ### ⚠ The project config and a profile config are DIFFERENT schemas
>
> Both are TOML, both live in a `.coi` directory, and the table names overlap just enough to be
> dangerous. Writing a project config in profile syntax is the most common way to produce a file that
> silently does nothing:
>
> | Setting | `<repo>/.coi/config.toml` **and** `~/.coi/config.toml` | profile file (`coi profile`, `--profile`) |
> |---|---|---|
> | Env vars | `[defaults.environment]` | `[environment]` |
> | Extra mounts | `[[mounts.default]]` (flat `[[mounts]]` also accepted since 0.12) | `[[mounts]]` |
> | Persistence | `[container] persistent` | `[container] persistent` |
>
> A top-level `[environment]` in a project or user-global config **parses without error and is then
> ignored**. Flat `[[mounts]]` there was a hard load error up to 0.11 (`type mismatch for
> config.MountsConfig`); 0.12 made mount blocks read the same in config and profiles. Keep
> `[[mounts.default]]` in project configs anyway — it loads on every 0.9+ version.
> **`coi schema profile` prints the PROFILE schema — do not validate `.coi/config.toml` against it.**
> Verify a project config empirically instead (§2.7).

Template at `references/config.toml.template`. Minimal production-ready version:

```toml
[tool]
name = "claude"
permission_mode = "bypass"          # --dangerously-skip-permissions equivalent

[container]
persistent = true                   # survives across shells; false = ephemeral
                                    # NOT [defaults] persistent — removed in 0.8.0, see below

[ssh]
forward_agent = true                # fully native in 0.9 — no Makefile help needed (§3.3)

[monitoring]
enabled = true                      # threat-detection auto-pause

# [network] omitted on purpose — see §4. "open" is ignored from this untrusted
# file; "restricted" IS honored and will refuse to boot on a host without nft
# sudo. Check `coi health` → "nft firewall" before adding it.

# Bind mounts — applied at container creation. UID shift is on by default, so
# files appear owned by the container's `code` user (uid 1000) regardless of
# host ownership, which avoids the classic nobody:nogroup problem.
[[mounts.default]]
host = "~/.claude/projects"              # Claude history survives across containers
container = "/home/code/.claude/projects"

[[mounts.default]]
host = "~/.claude/skills"                # required by `make coi-self-bootstrap`
container = "/home/code/.claude/skills"
```

Copy, adjust, explain each line to the user before writing to `<project>/.coi/config.toml`.

**Two keys that will bite you.** Both verified on 0.9.0:

- **`[defaults] persistent` is gone.** It was removed in **0.8.0** and is now a *hard load error*, not a warning:
  ```
  Error: failed to load project config …
    [defaults] persistent = true is no longer supported in 0.8.0.
    Move it under [container]:
  ```
  A config carrying it cannot launch at all. Use `[container] persistent`.
- **Env vars must go in `[defaults.environment]`.** A top-level `[environment]` table is silently dropped. This also applies to the trusted `~/.coi/config.toml` — a `[environment] DISABLE_TELEMETRY = "1"` there has never applied.

**Mount caveats to flag when onboarding:**

- **The two `~/.claude` mounts are load-bearing — keep them.** `coi profile info default` lists the same two paths under the built-in profile's `[[mounts]]`, which makes declaring them here look redundant. It isn't: verified on 0.9.0, a project whose config declares no mounts gets **no mount device at all** (launch logs only `Device workspace` + the `protect-*` set) and `/home/code/.claude/{projects,skills}` are empty container-local directories. Declared and trusted, they attach as `mount-0` / `mount-1` with real host content. Don't drop them on the strength of the profile listing.
- **Verify mounts by device, not from inside.** `Device mount-N added to <container>` in the launch output and `incus config device show <container>` are authoritative. Probing with `mountpoint` inside the container can report a path as mounted when no device backs it — that false signal is exactly what makes the previous bullet tempting to get wrong.
- Mounts are **only applied on container creation.** With `[container] persistent = true` and an existing container, editing `[[mounts.default]]` has no effect until the container is recreated (`make coi-recreate`, or `make coi-clean` then `make coi`). coi logs `"Reusing existing workspace and mount configurations"` on the reuse path.
- Fields per entry: `host` (supports `~` expansion), `container` (must be absolute), `readonly` (bool, optional).
- To hot-attach a mount to an already-running container without destroying it: `incus config device add <container> <name> disk source=<host> path=<container> shift=true` — `shift=true` is critical or the files show as `nobody:nogroup`.
- **Out-of-workspace mounts are trust-gated (0.9)** — including both `~/.claude` entries above. They are dropped with a `WARNING: ignoring untrusted mount` until approved with `coi trust` in the repo dir, which makes `coi trust` a **required** onboarding step. **Approvals do not survive a coi upgrade** (verified 0.9 → 0.15: every previously trusted project silently lost its mounts) — re-run `coi trust` per project after upgrading. See §2.4 and §3.12.
- Never mount `~/.ssh` or `$HOME`. See §5.

### 2.2 Wire Makefile targets

Copy the snippet from `references/Makefile.snippet` into the project's Makefile under a dedicated `# ── Sandboxed Claude (COI) ─` section. It provides:

- `make coi` — launches Claude in a sandbox, always in slot `$(COI_SLOT)` (default 1, see below). If the project has no container yet it runs `coi-create` first. (The SSH-agent proxy is coi's job, not the Makefile's — see §3.3.)
- `make coi-create` — create the container with all host integrations: creates slot `$(COI_SLOT)` **stopped** via `coi run -- true`, attaches the GPU before first boot (`coi-gpu`, only when `COI_GPU` is set — auto-on if the host has `nvidia-container-cli`), boots it once to run `coi-x11` and `coi-ssh-fix`, then stops it so the next `make coi` starts it through coi. A failing integration prints a `WARNING` and creation continues. It also surfaces coi's own `WARNING` lines, which the captured output would otherwise hide — notably `ignoring untrusted mount` (→ `coi trust`, then `coi-recreate`).
- `make coi-recreate` — delete this project's container(s) (any status), then `coi-create`. The way to apply mount/config changes to a persistent container.
- `make coi-gpu` — attach the host NVIDIA GPU (§3.11). Restarts the container if it is running.
- `make coi-resume` — resume the last session.
- `make coi-debug` — bash shell, no Claude (for diagnosing the container itself). Starts a **new** `coi shell --debug` session.
- `make coi-bash` — interactive bash **inside the container that is already running**, via `incus exec … runuser -u code`. Use this to inspect or work alongside a live sandbox; `coi-debug` can't, because it launches a separate session.
- `make coi-bash-claude` — Claude in the already-running container **without tmux**, so scrollback is your terminal's native buffer instead of tmux copy-mode. Extra flags via `ARGS=…`.
- `make coi-containers` — list only this project's containers (workspace-scoped).
- `make coi-ssh-fix` — idempotent re-attach of the SSH-agent proxy device *at coi's own path*, for when the host agent was restarted mid-session. Run once by `coi-create`, never on every launch — coi re-points the device itself at session start (it keeps an unchanged device, otherwise removes and re-adds it). See §3.3.
- `make coi-docker-fix` — fix `/var/run/docker.sock` perms inside the container.
- `make coi-git-fix` — bind-mount the main worktree's `.git/` into the container so `git` resolves worktree paths. No-op in the main worktree; idempotent re-attach in a child worktree. See §3.10.
- `make coi-hosts` — write the running container's IP into `/etc/hosts` for `*.<project>.test`-style local domains (adapt `COI_LOCAL_DOMAIN` per project). Slug-aware (see §3.10): tags each line with a `# coi-hosts:<project>:<slug>` sentinel so multiple worktrees — and multiple projects — coexist safely.
- `make coi-hosts-clean` — remove only this worktree's `/etc/hosts` lines (matched by sentinel tag). Idempotent; safe to run when nothing is registered.
- `make coi-x11` — attach X11 clipboard + PulseAudio (microphone) to the running container. Enables Ctrl+V image paste and `/voice` dictation. Run automatically by `coi-create`; by hand, **run before `make coi`**, or restart Claude after.
- `make coi-extras` — install **generic, project-agnostic** terminal/navigation tools (mc, htop, rsync, pv, bash-completion, aria2, unzip, fzf-make) + apply the IPv4 gai.conf fix for the Incus bridge. Language runtimes (PHP, Node, Go, Python, Ruby) and project-scope tools (Playwright, AWS CLI, DB clients) are **not** installed here — they live in project-owned targets (see §2.3).
- `make coi-self-bootstrap` — **the one target that runs INSIDE the container, not on the host.** Re-applies fixes that don't survive `coi build` / container recreation: currently the Playwright headless-shell wrapper (see §3.9). Idempotent — invoked from `/workspace` inside a coi shell. Every other target on this list runs on the host; this one is the exception.
- `make coi-clean` — stop & delete **only this project's** COI container(s), running or stopped; never touches other projects.
- `make coi-update` — `coi build` with a clear message, for cadence-based image refreshes. After this completes, run `make coi-self-bootstrap` from inside the new container (see §3.9).

The snippet is parameterised via `$(USER)` and has no project-specific names baked in. Two vars worth explaining: `COI_SSH_SOCK` (host agent path, defaults to `/tmp/ssh-agent-$(USER).sock`, used only as a precondition check and by the repair target) and `COI_SSH_SOCK_CONTAINER` (`/tmp/ssh-agent.sock` — **coi's** path, not one the Makefile chooses). Bind mounts are not defined in the Makefile — they live in `[[mounts.default]]` in `.coi/config.toml` (see §2.1). Never add `~/.ssh` or `$HOME` to either the mounts or the Makefile.

**Do not reintroduce startup-time SSH-agent churn.** The background helper is `_coi-post-start`; it fixes `docker.sock` perms, pushes `settings.json`, and (in a child worktree) attaches the main `.git`. An earlier revision of this snippet also removed and re-created coi's `ssh-agent` device on a different socket path at every launch — that broke agent forwarding outright (§3.3). If you are copying an older project Makefile forward, rename `_coi-ssh-watcher` → `_coi-post-start` and delete the two `ssh-agent` device lines.

**Multi-project isolation invariant — don't break it.** One host's Incus daemon is shared by every project the user runs through COI. Containers from different projects only differ in the 8-hex suffix of their name (`coi-<workspace-hash>-<slot>`), so a naive `grep '^coi-'` filter matches **everyone's** containers — running `make coi-clean` with that pattern will delete another project's in-flight work. The snippet enforces workspace scoping via a single helper:

```make
COI_THIS_JQ := (.active_containers // [])[] | select(.workspace==$$ws and .status=="Running") | .name
coi-this-container = coi list --format json 2>/dev/null | jq -r --arg ws '$(CURDIR)' '$(COI_THIS_JQ)'
```

Every recipe that targets a container calls `$(coi-this-container)` — it returns only **running** containers whose COI workspace equals `$(CURDIR)`. Recipes that create, delete or configure a possibly-stopped container (`coi-create`, `coi-recreate`, `coi-clean`, `coi-gpu`) use the sibling `$(coi-any-container)`, same filter without the status check. Requires `jq` on the host. When adding new container-targeting recipes, **never `grep '^coi-'` alone** — always go through the workspace filter. `coi-clean` also intentionally skips the global `coi clean` command, because that sweeps orphaned firewall rules across *all* projects.

**Slot pinning (`COI_SLOT ?= 1`).** coi's slot auto-allocation treats a *stopped* persistent container as occupied: a plain `coi shell` / `coi run` next to a stopped slot 1 creates a fresh slot 2 without the GPU and integrations `coi-create` attached (observed with `coi run` on 0.9.0; not re-tested on 0.15 — keep the pin). So the launch targets pass `--slot $(COI_SLOT)`. For a parallel session use `make coi COI_SLOT=2` — that slot gets no `coi-create` setup.

**`make -n` is not a safe dry run for these targets.** GNU make executes any recipe line containing `$(MAKE)` even under `-n`. A line that combined `incus start …; $(MAKE) coi-x11; incus stop …` really started and stopped the container during a dry run. The snippet keeps every `$(MAKE)` call on a recipe line of its own; preserve that when editing `coi-create` / `coi-recreate` / `_coi-ensure`.

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

- **PHP** — Ubuntu 24.04 (noble, the COI base image) ships PHP 8.3; use `ondrej/php` for other versions:
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

1. **Out-of-workspace bind mounts and forwarded sockets.** Any `[[mounts.default]]` whose host path
   resolves outside `/workspace` is **ignored at launch** until you approve it:

   ```bash
   coi trust            # run in the repo dir — approves this project's out-of-workspace mounts
   coi trust --list     # -> <fingerprint>  /abs/path/.coi/config.toml
   coi untrust          # revoke
   ```

   Approval is **pinned to a fingerprint of the approved mounts** — changing a mount's host path,
   container path, or `readonly` flag requires re-approval; changing unrelated settings (base image,
   network mode) does not. In-workspace mounts, and mounts from the trusted `~/.coi/config.toml` /
   `$COI_CONFIG`, are never gated. On 0.15 the approval also covers forwarded sockets, credential
   entries and published ports.
   - **Approvals don't carry across coi upgrades.** Verified 0.9.0 → 0.15.0: a config trusted by
     0.9 (still listed by `coi trust --list` with the same fingerprint) launches on 0.15 with
     `WARNING: ignoring untrusted mount`. After upgrading coi, re-run `coi trust` in **every**
     project, then recreate its container — mounts only attach at creation.
   - **Onboarding consequence:** the standard `~/.claude/projects` + `~/.claude/skills` mounts are
     out-of-workspace, so the **first `make coi` boots without them until `coi trust`**. The full
     onboarding sequence is: write config → `coi trust` → `make coi`. Don't try to dodge this by
     deleting the mounts — coi's built-in profile lists them but does not actually attach them (§2.1).

2. **Security-downgrading settings.** `[network] mode = "open"` in the *project* file is ignored
   with `WARNING: ignoring security-downgrading "network.mode=open" …`; it only applies from the
   trusted `~/.coi/config.toml` or a `$COI_CONFIG`-referenced file (see §4). Since 0.11 **every**
   protection-weakening field is trusted-scope only — e.g. `[git] protected_branches` (§5) can't be
   shrunk or emptied from a project file; coi falls back to the default instead.

**`COI_TRUST_ALL=1`** bypasses the mount gate — **CI/automation only**, never interactive on a host
where you clone untrusted repos. A `$COI_CONFIG` file is trusted, so don't point `$COI_CONFIG` at an
untrusted repo's own `.coi/config.toml`.

### 2.5 `.gitignore` & secrets

`.coi/config.toml` is safe to commit — it contains no secrets. But verify with the user before committing: some projects put real values in `[defaults.environment]`.

### 2.6 Default Claude Code settings for every container

Each container boots a **fresh** `/home/code/.claude` — the host's
`~/.claude/settings.json` is not mounted in, and `coi shell` can't pass extra
CLI args to `claude`. To make every container start Claude with chosen defaults
(reasoning effort, `ultracode`, `includeCoAuthoredBy: false`, …) there are two
channels: **env vars** in the trusted `~/.coi/config.toml` under
**`[defaults.environment]`** (host-wide, applied at container creation — note the
table name, a top-level `[environment]` there is silently ignored, §2.1) and a
**pushed `settings.json`** (the `_coi-post-start` target copies
`~/.claude/coi-settings.json` → the container on every `make coi`). Keep a
**dedicated `~/.claude/coi-settings.json`** rather than pushing your host
settings.json, so sandbox-only keys (like `ultracode: true`) don't leak into your
host sessions and host-UI cruft (figma/voice/tui) doesn't leak into the sandbox.

Key gotchas: `ultracode` is a real settings.json **boolean** (persistable, not
CLI-only); `effortLevel` enum tops out at `xhigh`; and **coi has no classifier
"auto" permission mode** (only `bypass`/`interactive` — `bypass` is the right
choice inside the sandbox). **Model:** since 0.11 the key is **`[tool.claude] model`**
in `~/.coi/config.toml`, delivered as `ANTHROPIC_MODEL` to the Claude that `coi shell`
launches (not to `coi run` commands). A root-level `model` — where 0.9 docs put it,
and where it never reached the CLI — is silently ignored. Confirmed in the 0.15.0
source; check `echo $ANTHROPIC_MODEL` in a live `make coi` session. **Attribution:**
0.15 writes `{"includeCoAuthoredBy": false}` into the root-owned
`/etc/claude-code/managed-settings.json` and installs a commit-message strip hook, so
sandbox commits carry no Claude co-author line by default. Full recipe, verified key/flag/env names, and the
rollout/verification steps are in `references/claude-settings.md`.

### 2.7 Verifying a config actually applied

`coi health` proves *discovery* (`Config loaded`, `Network mode`) but not that
individual keys landed — and the failure mode that matters here is **silent**: a
key in a table coi doesn't read produces no error. Check empirically with a
throwaway container from a scratch workspace:

```bash
mkdir -p /tmp/coi-check/.coi && cp <project>/.coi/config.toml /tmp/coi-check/.coi/
coi run -w /tmp/coi-check -- bash -lc 'echo "SSH=[$SSH_AUTH_SOCK]"; printenv MY_FLAG; mountpoint /home/code/.claude/skills'
```

Expect `SSH=[/tmp/ssh-agent.sock]`. An empty value for something you set means
wrong table (§2.1). Two cleanup notes: `coi run` inherits `[container]
persistent`, so it leaves a **stopped** container behind — delete it by name
(`incus delete <name> --force`), never with a global `coi clean`, which sweeps
other projects' orphans. And `coi run` needs `--` before the command, otherwise
flags like `bash -c` are parsed by coi itself. The scratch dir is a different
workspace, so its copied config is **untrusted** until you run `coi trust` there too
(`coi untrust` afterwards) — otherwise every out-of-workspace mount is dropped and the
check proves nothing about mounts.

---

## 3. Daily operation

### 3.1 Start / stop / resume

```bash
make coi                  # start a sandboxed Claude session (creates the container first if none)
make coi-resume           # resume the most recent session (--resume=auto)
make coi-recreate         # fresh container: GPU + X11/mic + SSH agent attached before first use
# Detach without killing:  Ctrl+B d  (tmux detach)
# Reattach:                make coi  (or coi shell) from same project
```

### 3.2 Parallel sessions

COI supports multiple slots per workspace. The Makefile pins its own launches to `COI_SLOT` (default 1, §2.2); launch a second one explicitly:

```bash
make coi COI_SLOT=2       # second parallel sandbox (no coi-create setup)
coi shell --slot 2        # same, without the Makefile
coi list                  # show active containers
```

Different projects are isolated automatically by workspace (`-w` / `--workspace`). Each slot gets its own container, its own bridge IP, and its own tmux session.

### 3.3 SSH agent lifecycle

**Forwarding is native in 0.9 — leave it alone.** With `[ssh] forward_agent = true`, coi does the whole job at container start:

```
Forwarding socket: /tmp/ssh-agent-<user>.sock -> /tmp/ssh-agent.sock
Device ssh-agent added to coi-xxxxxxxx-1
```

It attaches the proxy device (`connect=unix:<host agent>`, `listen=unix:/tmp/ssh-agent.sock`, `bind=container`, `uid=1000 gid=1000 mode=0600`) **and** exports `SSH_AUTH_SOCK=/tmp/ssh-agent.sock` inside the container. Nothing else is required — `ssh-add -l` lists the host's keys on first launch.

> **Do not "help" it.** Pre-0.9 guidance (including earlier versions of this skill) had the Makefile tear the device down at startup and re-create it at `/tmp/ssh-auth.sock`, with a config entry meant to repoint `SSH_AUTH_SOCK` to match. Both variants of that config entry fail, in different ways:
>
> - **Top-level `[environment]`** (what this skill's old template used) sits in a table coi doesn't read (§2.1). The variable keeps coi's value or none at all, so the re-created socket is one **no process knows about** — `ssh-add -l` → `Could not open a connection to your authentication agent`.
> - **`[defaults.environment]`** *is* read, and that's worse: it genuinely overrides coi's exported value. Verified on 0.9.0 — with `forward_agent = true` and `SSH_AUTH_SOCK = "/tmp/ssh-auth.sock"` in `[defaults.environment]`, coi still creates its socket at `/tmp/ssh-agent.sock`, the variable points at the other path, and `ssh-add` fails. The pair only works while the Makefile half also runs and wins its startup race; remove or mis-time either half and forwarding silently dies.
>
> Either way the fix is the same: delete both halves and let coi own it. If you inherit a Makefile that does this, strip it (§2.2) — don't paper over it with a `~/.bashrc` export.

If `ssh-add -l` does fail inside the container, work through:

1. **Host:** `ssh-add -l` — the agent must be live and hold keys. Restarting it on the host orphans the container-side proxy.
2. **Host:** `incus config device show <container> | grep -A6 '^ssh-agent:'` — confirm `listen: unix:/tmp/ssh-agent.sock`. A different `listen` path means something re-created the device; find and remove that code.
3. **Container:** `echo $SSH_AUTH_SOCK` — should be `/tmp/ssh-agent.sock`. Empty means coi's env injection didn't happen (usually `forward_agent` missing/false, or the whole config failed to load — check `coi health` → `Config loaded`).
4. **Host:** `make coi-ssh-fix` — re-attaches the device at coi's path. Run once by `coi-create`; otherwise repair only, never on every launch.

### 3.4 X11 clipboard, image paste & microphone (optional)

`make coi-x11` attaches the host's X11 display, clipboard, and PulseAudio socket to the running container. After running it, Claude Code's Ctrl+V image paste and `/voice` dictation work natively inside the sandbox. `make coi-create` runs it automatically for a new container (a failure warns and creation continues).

Verified on an Ubuntu 26.04 KDE **Wayland** host (X0 served by Xwayland, audio by PipeWire's pulse server): text both ways, `image/png` host → container, mic capture. The host needs nothing beyond the desktop defaults (`xhost`, `xauth`, the `X0` and `pulse/native` sockets).

What it does:
1. Attaches `/tmp/.X11-unix/X0` as an Incus **`proxy`** device (`bind=container uid=1000 gid=1000 mode=0600`) — **not** a disk mount. A disk-mounted X0 shows up as `nobody:nogroup 0775` inside, so `code` has no write permission on the socket and every client fails with `Can't open display: :0`. The proxy connects host-side as root, which step 7's grant admits.
2. Copies the host's `$XAUTHORITY` file into `/home/code/.Xauthority` with correct ownership (disk-mount causes `nobody:nogroup` — use `incus file push --uid 1000 --gid 1000` instead).
3. Mounts the PulseAudio socket (`/run/user/<uid>/pulse/native`) for microphone access.
4. Runs `apt-get update` then installs `xclip` + `pulseaudio-utils` + `libasound2-plugins` inside the container, failing loudly. A fresh container has **empty apt lists**; the old recipe skipped the update and sent output to `/dev/null`, so the install failed silently and left sockets attached but no tools. Using the host's binaries instead isn't viable — `pactl` alone pulls ~24 host libraries, and the ALSA plugin must match the container's libasound.
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
- **Persistent slots** (`[container] persistent = true`): run `claude update` inside the container; the upgrade sticks because the container state survives.
- **Don't** `npm install -g @anthropic-ai/claude-code@latest` inside the container — installs a parallel copy that fights the native install on `$PATH`.
- **The `coi` binary itself:** `coi update` updates coi and its threat-detection databases (`coi update core` / `coi update patterns` for one of them) — distinct from `coi build`, which rebuilds the container *image*. **On ≤ 0.11.0 `coi update` is broken** (it parses its own version as `vv0.9.0` and reports "already on the latest version") — upgrade manually, §3.12.

Rebuild cadence: weekly is a reasonable default; more often if Claude ships a feature you need.

### 3.8 Bridging host services into the container

Some services can't run in COI — memory-heavy data engines, anything relying on host-only hardware, or GPU workloads you'd rather keep on the host than pass the GPU through (§3.11). The pattern: **run the service on the host, bridge its port into the container via an Incus `proxy` device.**

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

This is the alternative to GPU passthrough (§3.11) — the container gets no GPU, but a stable path to a host service that has one.

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
COI_HOSTS_PROJECT ?= $(firstword $(subst ., ,$(COI_LOCAL_DOMAIN)))
COI_HOSTS_SENTINEL := coi-hosts:$(COI_HOSTS_PROJECT):$(if $(WORKTREE_SLUG),$(WORKTREE_SLUG),main)
ifneq ($(WORKTREE_SLUG),)
export COMPOSE_PROJECT_NAME := <project>-$(WORKTREE_SLUG)
endif
```

| Where the slug shows up | Why it matters |
|---|---|
| `COMPOSE_PROJECT_NAME` | Docker namespaces containers, networks, **and named volumes** by project name. A non-empty slug → each worktree's stack gets its own `postgres_data` volume. |
| `WORKTREE_HOST_PREFIX` in `/etc/hosts` lines | `<slug>.<project>.test`, `api.<slug>.<project>.test`, etc. — distinct entries per worktree, no clobbering. |
| `COI_HOSTS_SENTINEL` trailing comment | `coi-hosts-clean` deletes by sentinel, not by hostname regex. Safe regardless of how many worktrees share `/etc/hosts`. The `<project>` segment keeps it safe across projects too. |
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

**The sentinel must be project-scoped, not just worktree-scoped.** `/etc/hosts` is shared by every project on the host, and every project that adopts this snippet deletes-then-appends by sentinel. With a bare `coi-hosts:main`, the main worktree of *every* project carries the same tag, so `make coi-hosts` in project B deletes project A's line; A's local domain stops resolving while its container and Traefik stay perfectly healthy (see `references/troubleshooting.md` §11). Hence `coi-hosts:<project>:<slug>`. Changing the format orphans lines written under the old tag — remove those once by hand.

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

The `_coi-post-start` recipe applies this automatically when `make coi` runs from a non-main worktree, so the standalone target only matters when re-attaching after `coi-clean` / container recreation.

**Known limitation: hardcoded Traefik Host rules.** If a project's local compose hardcodes `Host(\`<project>.test\`)` rather than templating from a var, slug-prefixed `/etc/hosts` entries resolve to the right container but Traefik inside that container won't route them. Either template those rules or accept that "two stacks serving HTTP at the local domain" is serialized until templating lands. Volume isolation and sandboxed Claude per worktree work regardless.

Reference implementation: a worktree ADR in your own project (covers slug derivation rules, the `.env` rewrites, the `setup-state` symlink, and the `worktree-add` / `worktree-remove` flow end-to-end).

### 3.11 GPU passthrough (NVIDIA)

coi has no GPU config key (checked through 0.15.0), so the GPU is attached with plain Incus config on the container. Verified with a GTX 1080 Ti, driver 580, on an Ubuntu 26.04 host and the 24.04 coi image:

```bash
incus config set <container> nvidia.runtime=true            # injects the host driver userspace (nvidia-smi, libcuda)
incus config device add <container> gpu gpu gputype=physical
incus restart <container>                                   # nvidia.runtime only applies at start
```

- **Host requirement:** `nvidia-container-cli` (libnvidia-container) — that is what `nvidia.runtime` calls. No driver install inside the container; the host's driver version shows up in `nvidia-smi` there.
- **`make coi-gpu`** does this idempotently on a running *or stopped* container and restarts it only if running (which ends the Claude session in it). `make coi-create` applies it while the container is still stopped, before first boot — so the normal path never restarts anything. The snippet's `COI_GPU` defaults to on exactly when the host has `nvidia-container-cli`; force with `COI_GPU=1`, disable with `COI_GPU=`.
- **Survives coi's reuse path.** Both the `gpu` device and `nvidia.runtime` persisted across coi stopping/restarting a persistent container (0.9.0 and 0.15.0). They do **not** survive deletion — that's why creation goes through `coi-create`, and why the launch slot is pinned (§2.2): an auto-allocated slot 2 has no GPU.
- **Shared, not exclusive.** The card's memory is shared with whatever the host already runs on it.
- **Tradeoff:** the container gets direct access to the GPU driver (a larger kernel/driver attack surface than the proxy approach of §3.8). Fine for your own code; prefer §3.8 for untrusted workloads.

### 3.12 Upgrading the `coi` binary (0.9 → 0.15 runbook)

Done for real on 2026-10-19. In order:

1. **Read the upstream CHANGELOG** for every version you skip — `[Breaking]` entries are explicit there.
2. **Install.** On ≤ 0.11.0, `coi update` is broken (`vv0.9.0` self-version → "already on the latest version"), so install the release by hand. The project moved to **`coipond/coi`** (old links redirect):
   ```bash
   cd "$(mktemp -d)"
   curl -fsSLO https://github.com/coipond/coi/releases/download/vX.Y.Z/coi-linux-amd64
   curl -fsSLO https://github.com/coipond/coi/releases/download/vX.Y.Z/checksums.txt
   grep ' coi-linux-amd64$' checksums.txt | sha256sum -c -
   sudo cp /usr/local/bin/coi /usr/local/bin/coi-OLD.bak     # keep a rollback
   sudo install -m 755 coi-linux-amd64 /usr/local/bin/coi
   sudo setcap cap_linux_immutable=ep /usr/local/bin/coi     # replacing the file drops this capability
   ```
   Without the `setcap`, `coi health` warns `Immutable cap` and launches print *"Protected paths rely on read-only bind mounts only (bypassable with root in container)"*.
3. **Migrate config keys** (they fail silently): root-level `model` → `[tool.claude] model` (0.11); check for removed flags in Makefiles (`--image`, `--persistent`, `--tmux`, `--tool` → config, 0.10).
4. **Re-trust every project** — `coi trust` in each repo listed by `coi trust --list`. 0.9 approvals are not honored (§2.4).
5. **`coi update patterns`**, then `coi health` in a project dir (`Config loaded`, `Network mode`).
6. **`coi build --force`** and recreate containers (`make coi-recreate`) — image-level changes (e.g. 0.15's masked guest AppArmor, cloud-init disabled in the image) only reach containers built from the new image, and mounts only re-attach at creation.
7. **Verify in a fresh container** (§2.7) — device list (`mount-N`, `gpu`, `x11-socket`, `pulse-audio`, `ssh-agent`), then GPU, mounts, clipboard, mic, `ssh-add -l`.

**0.9.0 bug this fixes — "Unable to read managed policy settings".** 0.9.0 writes `/etc/claude-code/managed-settings.json` by pushing a 0600 host temp file at every session start. When it lands `root:root 0600`, Claude (running as `code`) gets `EACCES`, treats the unreadable policy as possible org-login enforcement, and demands `/login`. A post-start `chmod 644` loses the race against Claude's startup. 0.11+ writes it `root:root 0644` in-container — upgrading is the only clean fix.

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
4. **Do not commit `.coi/config.toml` to a public repo without reviewing `[defaults.environment]`** — it's a common place to accidentally paste secrets.
5. **Ephemeral by default, persistent by choice.** Long-running persistent slots accumulate state (shell history, downloaded tools) that an attacker could probe. Prefer ephemeral unless the upgrade/time cost is meaningful.
6. **Keep `coi` and the image current.** `coi update` refreshes the binary + threat databases; `coi build` rebuilds the image. Weekly is reasonable — old base images accumulate CVEs.
7. **Don't remove or override the `protect-git-config` / `protect-git-hooks` devices.** COI adds these read-only bind mounts over `/workspace/.git/config` and `/workspace/.git/hooks/` automatically — visible in `incus config device show <container>`. They block the classic git-hook escape vector: an agent writes `[core] hooksPath = /tmp/evil` into `.git/config` or drops a `post-commit` into `.git/hooks/`, and the next `git commit` **you** run on the host executes attacker-controlled code under your host identity, with your SSH agent and your shell. The mounts make those writes fail with `EROFS` while leaving the rest of `.git/` (refs, objects, index) writable so normal git operations inside the container still work. If you see a failing `git config --local` or a hook-install step that errors, that's the protection doing its job — don't "fix" it by removing the device. The full 0.9.0 set is wider than the two devices in this heading — a launch logs `Protected paths (mounted read-only): .git/hooks, .git/config, .git/config.worktree, .git/info/attributes, .husky, .vscode, .coi`; on 0.15 the list also includes `.claude/settings.json`, `.claude/settings.local.json` and `.codex/config.toml` (all workspace-relative — `/home/code/.claude/settings.json`, where `_coi-post-start` pushes settings, is not affected). 0.9 also applies **host-side immutable protection** (`chattr +i`, visible via `lsattr -d`) to the protected dirs **while a session/container is running**, so a host-side edit of `.coi/config.toml` mid-session can fail with `EPERM`. Same protection, not a bug — edit config when no session is running, or use the trusted `~/.coi/config.toml`.
8. **Don't blanket-set `COI_TRUST_ALL=1`.** It bypasses the 0.9 mount-trust gate that stops a cloned repo from mounting your home dir or opening the network. Approve per-project with `coi trust` on a host; reserve `COI_TRUST_ALL=1` for CI. (§2.4)
9. **Keep the protected-branch guard (0.14+).** coi installs root-owned pre-commit/pre-push hooks refusing commits on, and pushes to, `main`/`master` — the agent works on a feature branch (`git switch -c <branch>`) and opens a PR. Configure it only in the trusted `~/.coi/config.toml` (`[git] protected_branches`: absent → main+master, a list → that set, `[]` → off); a project file can't weaken it. It's client-side — `--no-verify` or a repo-local `core.hooksPath` (husky) bypasses it — so server-side branch protection stays the real backstop.
10. **Keep `cap_linux_immutable` on the coi binary.** It enables the host-side `chattr +i` protection of §5.7; reinstalling the binary drops it (§3.12).

---

## 6. When *not* to use COI

- Tasks that need a GPU **and** run untrusted code — passthrough (§3.11) exposes the host driver; bridge a host service in instead (§3.8). Hosts without NVIDIA's container CLI can't pass a GPU through at all.
- Tasks where the agent must write outside the mounted workspace (it can't by design).
- Projects where the 5–10 minute `coi build` cost dominates a 30-second task.
- CI/CD — COI is a local sandbox. Use proper CI infrastructure for automated pipelines.

---

## References

- `references/config.toml.template` — drop-in `.coi/config.toml`.
- `references/Makefile.snippet` — drop-in Makefile section.
- `references/claude-settings.md` — make every container start Claude with chosen defaults (effort, `ultracode`, model, attribution) via `~/.coi` env + a dedicated `coi-settings.json` push (§2.6).
- `references/troubleshooting.md` — install-time pitfalls, SSH/Docker/clipboard debugging, IPv6/apt slowness fix (§6), performance baseline, Incus reset procedure.
- Upstream: https://github.com/coipond/coi (formerly `mensfeld/code-on-incus`; README and CHANGELOG are authoritative — if this skill contradicts them, trust upstream and flag the drift).