# coi-skill

A **[Claude Code](https://claude.com/claude-code) Skill** for running coding agents inside
[code-on-incus](https://github.com/mensfeld/code-on-incus) (COI) — Incus system-container
sandboxes that let an agent work autonomously (`--dangerously-skip-permissions`) without
putting the host at risk.

This repo is **not** the sandbox itself — that's the upstream `coi` binary. This is the
**operational layer** around it: a `SKILL.md` playbook, drop-in Makefile targets, a `.coi.toml`
template, an inside-container self-bootstrap script, and a battle-tested troubleshooting
reference. Install it once and Claude Code knows how to set up COI on a new host, onboard any
project, forward your SSH agent, wire X11/audio, survive git worktrees, and recover from the
common failure modes.

## What you get

| Piece | Purpose |
|---|---|
| `SKILL.md` | The skill Claude Code loads: host setup, per-project onboarding, daily ops, security invariants |
| `references/Makefile.snippet` | Drop-in `make coi*` targets (workspace-scoped, worktree-aware) |
| `references/config.toml.template` | Annotated `.coi.toml` — the single config file per project |
| `references/coi-self-bootstrap.sh` | Inside-container fixes that don't survive an image rebuild (Playwright, …) |
| `references/troubleshooting.md` | Install-time pitfalls + runtime recovery (network, SSH, Docker, clipboard, monitor) |
| `docs/PORTABILITY.md` | **Which knobs are generic vs host vs project vs OS**, and how to override each |
| `docs/HOST_SETUP.md` | Distro-aware one-time host setup (Ubuntu/Debian, Fedora, Arch, openSUSE, macOS, Windows) |
| `install.sh` | Deploy the skill and/or scaffold a project — see below |

## Is it Linux-only?

The **sandbox is always Linux** — Incus runs Linux system containers, that's the whole point.
The **host driving it** does not have to be:

| Host OS | How COI runs | Notes |
|---|---|---|
| **Linux** (native) | Incus runs directly on the host | Primary, best performance |
| **macOS** | Incus inside a Lima/Colima Linux VM | COI auto-detects; UID-shift disabled via virtiofs (`[incus] disable_shift`) |
| **Windows** | Incus inside WSL2 (a Linux env) | Effectively the Linux path, run from inside WSL2 |

So "not only Linux" = **yes for the host** (macOS/Windows via a Linux VM/WSL2), but the container
you get is Linux either way. See `docs/HOST_SETUP.md`.

## Quick start

### 1. Prerequisites (one-time per host)

- **Incus ≥ 6.1**, initialized (`sudo incus admin init --minimal`)
- The **`coi` binary** (`curl -fsSL https://raw.githubusercontent.com/mensfeld/code-on-incus/master/install.sh | bash`)
- **`jq`** on the host, and a running **SSH agent**

Run the built-in check:

```bash
./install.sh --check
```

Full distro-by-distro instructions: `docs/HOST_SETUP.md`.

### 2. Install the skill (so Claude Code can use it)

```bash
git clone git@github.com:pkhlop/coi-skill.git
cd coi-skill
./install.sh                 # copies SKILL.md + references/ into ~/.claude/skills/coi/
```

Override the target with `CLAUDE_HOME=/custom/.claude ./install.sh`.

### 3. Onboard a project

```bash
./install.sh --project /path/to/your/repo
```

This drops a `.coi.toml` (from the template) at the repo root and a `coi.mk` with the Makefile
targets, and prints the one-line `include coi.mk` to add to the project's `Makefile`. Then:

```bash
cd /path/to/your/repo
make coi          # launch sandboxed Claude Code
```

## Configuration

COI is configured by **one file per project** (`.coi.toml`) plus a handful of Makefile variables
with sane defaults. Nothing about a specific machine or project is hard-coded in the skill —
`docs/PORTABILITY.md` classifies every knob (generic / host-environment / project / host-OS) and
shows where it lives and how to override it. The short version:

- **Per host:** `COI_SSH_SOCK` (agent socket, default `/tmp/ssh-agent-$USER.sock`)
- **Per project:** `.coi.toml` (agent, network mode, mounts, persistence) + `COI_LOCAL_DOMAIN`,
  language-runtime versions
- **Per OS:** Incus install method + a couple of container tweaks (all documented, mostly automatic)

## Credits & license

- Built on **[code-on-incus](https://github.com/mensfeld/code-on-incus)** by Michał Mensfeld — the
  sandbox engine this skill drives. Install and license terms are upstream's.
- This skill/playbook: MIT (see `LICENSE`).
