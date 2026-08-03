# Default Claude Code settings for every COI container

How to make **every** COI container start Claude Code with a chosen set of
runtime settings (reasoning effort, ultracode, model, commit attribution, …).

> **Version note.** Facts below were verified against **coi 0.9.0** and the
> **Claude Code 2.1.x** native binary (grepping the installed bundle + coi's
> embedded launcher). Claude Code setting keys and coi's config surface both
> drift across versions — re-verify (`claude --help`, grep the bundle,
> `coi profile info default`, `coi health`) after a `claude update` or
> `coi update`. Recipe for re-verifying is at the bottom.

## The problem

Each container boots with a **fresh** `/home/code/.claude`. The host's
`~/.claude/settings.json` is **not** a bind mount, so none of your host Claude
settings reach the sandbox by default. `coi shell` also has **no flag to pass
extra CLI args to `claude`** (`[tool]` only accepts `name` + `permission_mode`).
So there are exactly two channels to get settings into every container:

| Channel | Vehicle | Applies to | Timing |
|---|---|---|---|
| **Environment variables** | **`[defaults.environment]`** in the trusted `~/.coi/config.toml` (merges into every `coi shell`, no `--profile`) | settings with an env-var form (`CLAUDE_CODE_*`, `DISABLE_*`, `MAX_THINKING_TOKENS`, …) | **container creation** — recreate persistent containers to pick up changes |
| **A pushed `settings.json`** | The Makefile `_coi-post-start` runs `incus file push … → /home/code/.claude/settings.json` on **every** `make coi` | any settings.json key (`effortLevel`, `ultracode`, `includeCoAuthoredBy`, `cleanupPeriodDays`, …) | **every `make coi`** — re-pushed each launch, so no recreate needed for settings.json-only changes |

> ### ⚠ `[environment]` vs `[defaults.environment]`
>
> `~/.coi/config.toml` is **not** parsed with the profile schema. A top-level
> `[environment]` table there parses without error and is then **silently ignored** —
> the classic symptom is a `DISABLE_TELEMETRY = "1"` that has never once applied.
> The key that works is `[defaults.environment]`. Verified on coi 0.9.0 by setting
> both forms and reading them back inside a container. Same trap in a project
> `.coi/config.toml` (skill §2.1).

## The pattern: a dedicated `~/.claude/coi-settings.json`

Do **not** push your host `~/.claude/settings.json` wholesale — it drags
host-UI-only keys (`enabledPlugins`/figma, `tui: fullscreen`, `voice`) into
headless sandboxes, and it couples container behavior to your host (e.g. turning
`ultracode` on for the sandbox would also turn it on for every host session).

Instead keep a **container-only** file, `~/.claude/coi-settings.json`, with just
the sandbox-appropriate keys, and have the Makefile push **that**:

```jsonc
// ~/.claude/coi-settings.json  (host file; pushed to /home/code/.claude/settings.json)
{
  "effortLevel": "xhigh",              // reasoning effort; enum low|medium|high|xhigh
  "ultracode": true,                   // multi-agent-orchestration standing mode (boolean key)
  "model": "opus",                     // belt-and-suspenders; also set in ~/.coi (see Model below)
  "includeCoAuthoredBy": false,        // no "Co-Authored-By: Claude" trailer on in-container commits
  "skipDangerousModePermissionPrompt": true,  // belt-and-suspenders; coi already seeds bypass acceptance
  "cleanupPeriodDays": 365             // keep transcript history (default 30)
}
```

The Makefile push (in `references/Makefile.snippet`, target `_coi-post-start`)
prefers the dedicated file and falls back to the host settings.json so it stays
backward-compatible:

```make
SETTINGS_SRC=$(HOME)/.claude/coi-settings.json; [ -f "$$SETTINGS_SRC" ] || SETTINGS_SRC=$(HOME)/.claude/settings.json; \
incus file push "$$SETTINGS_SRC" $$CONTAINER$(COI_CLAUDE_HOME)/settings.json --uid 1000 --gid 1000 2>/dev/null || true; \
```

Because the push is a **copy** (not a mount), it needs no `coi trust`, and Claude
can still edit its own settings.json inside the container.

## Host-wide env defaults in `~/.coi/config.toml`

`~/.coi/config.toml` is trusted and merges into every container. Put env-capable
settings here — under `[defaults.environment]`, **not** `[environment]`:

```toml
model = "opus"                 # see the model caveat below — verify before relying on this

[network]
mode = "open"

[defaults.environment]
DISABLE_TELEMETRY = "1"        # opt every container out of telemetry + feature-flag fetch
# DISABLE_AUTOUPDATER = "1"    # optional: pin claude to the image build, no in-container self-update
```

## Verified facts (the non-obvious ones)

- **`ultracode` is a real top-level `settings.json` boolean** (`ultracode: E.boolean()`
  in the bundle) — it **can** be persisted as a default; it is *not* CLI-flag-only.
  It is independent of `effortLevel`, so you set **both** `effortLevel: "xhigh"`
  and `ultracode: true`.
- **`effortLevel` settings.json enum is `["low","medium","high","xhigh"]`** —
  `xhigh` is the ceiling there (`max`/`ultracode` are not valid `effortLevel`
  values). There is also an env form, **`CLAUDE_CODE_EFFORT_LEVEL`**, which
  *overrides* settings.json and prints a "overrides this session" notice — prefer
  the settings.json key to avoid the notice.
- **Model: UNRESOLVED on 0.9.0 — verify before relying on either channel.** The
  built-in profile does declare a model (`coi profile info default` →
  `model = "claude-sonnet-4-5"`), which is why earlier revisions of this file said
  "coi manages `--model` itself" and told you to set `model` in `~/.coi/config.toml`.
  That claim does not survive inspection: on a live 0.9.0 container the launched
  process is
  ```
  claude --dangerously-skip-permissions --enable-auto-mode
  ```
  — **no `--model` flag**, and no model-related variable in its environment. So the
  profile's model is not reaching the CLI by either route observed here. Until this
  is pinned down, treat `model` in `coi-settings.json` as the channel most likely to
  work (it is read by Claude Code directly), keep `model` in `~/.coi/config.toml` as
  harmless belt-and-braces, and **check what actually launched**:
  ```bash
  incus exec <container> -- bash -c 'for p in /proc/[0-9]*; do tr "\0" " " < $p/cmdline 2>/dev/null | grep -m1 "^claude "; done'
  ```
- **coi has no classifier "auto" permission mode.** `[tool] permission_mode`
  accepts only **`"bypass"`** (→ `--permission-mode bypassPermissions`) and
  **`"interactive"`** (prompts). Inside a COI sandbox `bypass` is the intended
  mode — the sandbox (fs isolation + threat monitor + read-only git hooks) is the
  safety layer, so Claude's classifier `defaultMode: "auto"` is largely redundant
  here. If you genuinely want classifier auto: set `permission_mode = "interactive"`
  **and** `permissions.defaultMode: "auto"` in the pushed settings.json — but coi
  only pre-seeds onboarding/trust-acceptance (`hasCompletedOnboarding`,
  `bypassPermissionsModeAccepted`) in **bypass** mode, so a fresh interactive
  container may **stall on Claude's first-run "trust this folder?" prompt**.
  Validate on a throwaway slot before committing to it.
- **The dangerous-mode first-run prompt is already suppressed** in bypass mode:
  coi pre-seeds `.claude.json` with `allowDangerouslySkipPermissions`,
  `bypassPermissionsModeAccepted`, `hasCompletedOnboarding` and launches with
  `--permission-mode bypassPermissions`. You do not need to configure this; keep
  `permission_mode = "bypass"` and don't override the coi-seeded `.claude.json`.

## Rollout

1. Write `~/.claude/coi-settings.json` (container-only keys).
2. Add `model` + `[environment]` to `~/.coi/config.toml` (edit while no `make coi`
   is launching — coi may `chattr +i` workspace `.coi` dirs during a session; the
   host `~/.coi` is normally mutable, verify with `lsattr -d ~/.coi`).
3. Ensure the Makefile push points at `coi-settings.json` (the snippet already
   does; existing project Makefiles copied from an older snippet need the one-line
   retarget above).
4. **Recreate** running persistent containers to pick up creation-time env/model:
   `cd <worktree> && make coi-clean && make coi`. settings.json-only changes land
   on the next `make coi` without a recreate (the watcher re-pushes).

## Verifying

- **Never infer one key from another.** `coi health` → `Config loaded` +
  `Network mode` proves only that the *file* was found and that `[network]` merged.
  It says nothing about the other tables: on 0.9.0 `[network] mode = "open"` from
  `~/.coi/config.toml` applies while a top-level `[environment]` in the same file is
  dropped. "The file is merging, therefore its env applies" is exactly the reasoning
  that hid that bug — check each channel on its own. (`coi profile info default`
  shows the **built-in** profile, `Source: (built-in)` — it is *not* the merged
  effective config, so don't use it to check your overrides either.)
- **A concrete container check:** `coi run 'bash -lc "printenv DISABLE_TELEMETRY; cat ~/.claude/settings.json"'`
  in a scratch workspace spins up a throwaway container (does not touch persistent
  slots). Note: if the workspace's `.coi/config.toml` has `persistent = true`,
  `coi run` leaves a stopped container — remove it with the workspace-scoped
  `make coi-clean` (or `coi kill <name>`), never a global `coi clean`.
- **Re-verify keys after upgrades:** `claude --help`; grep the installed native
  bundle (`~/.local/share/claude/versions/<ver>`) for exact spellings, e.g.
  `grep -aoE 'effortLevel|ultracode:E\.[a-z]+|CLAUDE_CODE_[A-Z_]+|includeCoAuthoredBy' <bin>`.
