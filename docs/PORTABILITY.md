# Portability — what's generic, what's yours, and where every knob lives

This skill is designed so that **nothing about a specific machine or a specific project is
hard-coded**. Everything that varies is either:

- a field in the project's **`.coi.toml`** (the single per-project config file), or
- a **Makefile variable** with a `?=` default you can override per host or per project, or
- a documented **host-OS step** (Incus install, a couple of container tweaks).

The `SKILL.md` prose uses `<project>`, `<slug>`, and `example`/`*.<project>.test` as placeholders —
never a real project or domain name.

## Classification

Legend: **Generic** = works everywhere unchanged · **Host** = varies per machine ·
**Project** = varies per repo · **OS** = varies per host operating system.

| Knob / behaviour | Class | Lives in | Default | How to override |
|---|---|---|---|---|
| Coding agent (`claude`/`opencode`/`aider`) | Project | `.coi.toml` `[tool] name` | `claude` | edit `.coi.toml` |
| `--dangerously-skip-permissions` mode | Generic | `.coi.toml` `[tool] permission_mode` | `bypass` | `normal` for prompts |
| Network policy (restricted/open) | Project | `.coi.toml` `[network] mode` | `restricted` | edit / `coi shell --network` |
| Threat monitoring | Generic | `.coi.toml` `[monitoring] enabled` | `true` | leave on (security invariant) |
| Container persistence | Project | `.coi.toml` `[defaults] persistent` | `true` | `false` for ephemeral |
| Resource limits | Project | `.coi.toml` `[limits]` | unset | uncomment + set |
| **SSH agent socket path** | **Host** | `coi.mk` `COI_SSH_SOCK` | `/tmp/ssh-agent-$USER.sock` | `make coi COI_SSH_SOCK=…` or shell rc |
| Claude history / skills mounts | Generic | `.coi.toml` `[[mounts.default]]` | `~/.claude/{projects,skills}` | Claude-Code-user paths; rarely changed |
| Project-specific mounts | Project | `.coi.toml` `[[mounts.default]]` | none | add entries |
| **Local dev domain** | **Project** | `coi.mk` `COI_LOCAL_DOMAIN` | `<dirname>.test` | set per repo |
| `/etc/hosts` hostnames (`api.`/`admin.`) | Project | `coi.mk` `coi-hosts` target | `api.`/`admin.` prefixes | edit the `HOSTS=` line |
| Worktree namespacing | Project | `.worktree-slug` file + `coi.mk` | empty (main worktree) | one-line slug file |
| `COMPOSE_PROJECT_NAME` | Project | project Makefile | `<project>-<slug>` | project-owned |
| Language runtimes + versions | Project | project-owned `coi-project-setup` | none (not in skill) | detect from repo (SKILL §2.3) |
| UID/GID shift | OS | `.coi.toml` `[incus] disable_shift` | on (auto-off on Lima/Colima) | auto |
| Incus install method | OS | host setup | — | `docs/HOST_SETUP.md` |
| IPv4-preference (`/etc/gai.conf`) fix | OS | `coi-extras` target | applied per run | idempotent |
| firewalld / Docker-netfilter DHCP fix | OS | host setup | — | `references/troubleshooting.md §1.3` |
| Playwright headless-shell workaround | Generic | `references/coi-self-bootstrap.sh` | applied inside container | `make coi-self-bootstrap` |
| All `make coi*` container targets | Generic | `coi.mk` | workspace-scoped via `jq` | — |

### The only genuinely per-host knob: `COI_SSH_SOCK`

Everything else is either project config or automatic. The one value that reliably differs between
machines is where your SSH agent listens. The Makefile defaults to `/tmp/ssh-agent-$USER.sock`
(the path the recommended shell-rc setup in `docs/HOST_SETUP.md` creates). If your agent lives
elsewhere (gnome-keyring, a distro default, a forwarded socket inside another sandbox), override it:

```bash
make coi COI_SSH_SOCK=/run/user/1000/keyring/ssh
# or export it once in your shell rc so every project picks it up.
```

### Project-owned, deliberately *not* in the skill

Language runtimes (Node/PHP/Go/Python/Ruby), Playwright/AWS-CLI/DB-client installs, Traefik Host
rules, and `COMPOSE_PROJECT_NAME` are **project-specific** and live in a project-owned Makefile
target (typically `coi-project-setup`), not in the shared skill. `SKILL.md §2.3` gives the
version-detection recipe (read `package.json`/`go.mod`/`pyproject.toml`/etc., pick newest stable
that satisfies the lower bound, pin into a Make variable). Keeping these out of the skill is what
makes the skill reusable across unrelated repos.

## Deploy on a brand-new machine — checklist

1. **Host setup** (once): install Incus ≥ 6.1 + the `coi` binary + `jq`; set up the SSH agent.
   → `docs/HOST_SETUP.md`, then `./install.sh --check`.
2. **Install the skill:** `./install.sh` → `~/.claude/skills/coi/`.
3. **Per project:** `./install.sh --project /path/to/repo`, add `include coi.mk` to its Makefile,
   review `.coi.toml`.
4. **Optional per project:** add a `coi-project-setup` target for the repo's language runtimes.
5. `make coi`.

Steps 2–5 are machine-agnostic. Only step 1 touches host packages, and it's the same short list on
every Linux; on macOS/Windows it's "install Lima/Colima or WSL2 first" (see `docs/HOST_SETUP.md`).

## What was generalized from the original private copy

This repo was extracted from a working private setup. The generalization removed every
project/host-specific reference so the skill is safe to reuse and publish:

- **Example domains** `runails.test` → `<project>.test` throughout `SKILL.md` (the `coi-hosts`
  description, the worktree hostname table, the `/etc/hosts` sentinel-regex example, and the
  Traefik `Host(...)` limitation note).
- **The worktree reference implementation** ("ADR-0016 in the `runails` codebase") → a generic
  "worktree ADR in your own project" pointer.
- No host paths, usernames, private git hosts, credentials, or client/business names were ever in
  the skill payload — the reference files were already parameterized (`$(USER)`, `$(notdir
  $(CURDIR))`, `$(HOME)`), so they were published unchanged.
