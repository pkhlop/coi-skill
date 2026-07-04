#!/usr/bin/env bash
# coi-self-bootstrap.sh — re-apply COI fixes that don't survive an image rebuild.
#
# Runs INSIDE the COI container, invoked by `make coi-self-bootstrap` from
# the bind-mounted project workspace. Idempotent — safe to re-run; reports
# "already current" when nothing changes.
#
# Currently applies:
#   1. Playwright MCP headless-shell wrapper + ~/.claude.json --executable-path
#      patch. Works around the chrome-for-testing crashpad-handler crash where
#      the parent doesn't pass --database to chrome_crashpad_handler, the
#      handler exits, and the renderer dies with SIGTRAP before MCP can attach.
#      The bundled chrome-headless-shell binary is unaffected. See
#      SKILL.md §3.9 and troubleshooting.md §9.
#
# To extend: add another step below, modeled on the Playwright block. Keep
# each step idempotent and explicit about what it changed.

set -euo pipefail

# Some non-login shells (and `make` invocations from them) don't propagate
# HOME. Derive it from passwd before any of the checks below — they all
# read $HOME and would otherwise trip set -u.
if [ -z "${HOME:-}" ]; then
  HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
  export HOME
fi

# ── Sanity: must run inside the COI container (HOME=/home/code, Playwright
# cache present). On the host neither holds.
if [ "$HOME" != "/home/code" ] || [ ! -d "$HOME/.cache/ms-playwright" ]; then
  echo "ERROR: coi-self-bootstrap must run INSIDE the COI container, not on the host." >&2
  echo "  HOME=$HOME (expected /home/code)" >&2
  echo "  Hint: open a coi shell with 'make coi', then 'cd /workspace && make coi-self-bootstrap'." >&2
  exit 1
fi

# ── Step 1: Playwright headless-shell wrapper.
WRAPPER="$HOME/.local/bin/playwright-headless-shell"
mkdir -p "$(dirname "$WRAPPER")"

NEW=$(mktemp)
trap 'rm -f "$NEW"' EXIT
cat > "$NEW" <<'WRAPPER_BODY'
#!/bin/sh
# Auto-installed by `make coi-self-bootstrap`. Resolves the newest
# chromium_headless_shell-* in the Playwright cache and execs it. Avoids
# the chrome-for-testing crashpad crash — see COI skill SKILL.md §3.9.
CACHE="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}"
BIN=$(ls -d "$CACHE"/chromium_headless_shell-*/chrome-headless-shell-linux64/chrome-headless-shell 2>/dev/null | sort -V | tail -1)
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "playwright-headless-shell: no chrome-headless-shell under $CACHE" >&2
    echo "  hint: trigger Playwright once (e.g. via MCP) so it auto-downloads" >&2
    exit 127
fi
exec "$BIN" "$@"
WRAPPER_BODY
chmod +x "$NEW"

if cmp -s "$WRAPPER" "$NEW" 2>/dev/null; then
  echo "==> playwright-headless-shell wrapper: current"
else
  mv "$NEW" "$WRAPPER"
  trap - EXIT
  echo "==> playwright-headless-shell wrapper: installed at $WRAPPER"
fi

# ── Step 2: ~/.claude.json playwright MCP --executable-path.
python3 - <<'PY'
import json, pathlib, shutil, sys
home = pathlib.Path.home()
p = home / ".claude.json"
if not p.exists():
    print("==> claude.json: not present (agent hasn't started yet — re-run after first 'claude' invocation)")
    sys.exit(0)
data = json.loads(p.read_text())
mcp = data.setdefault("mcpServers", {})
want = {
    "type": "stdio",
    "command": "npx",
    "args": [
        "-y", "@playwright/mcp@latest",
        "--headless",
        "--executable-path", str(home / ".local/bin/playwright-headless-shell"),
    ],
    "env": {},
}
cur = mcp.get("playwright")
if cur == want:
    print("==> claude.json playwright MCP: already patched")
    sys.exit(0)
bak = p.with_name(p.name + ".bak.coi-self-bootstrap")
if not bak.exists():
    shutil.copy2(p, bak)
mcp["playwright"] = want
p.write_text(json.dumps(data, indent=2))
print(f"==> claude.json playwright MCP: patched (backup at {bak.name})")
PY

echo "==> coi-self-bootstrap: done."
echo "    If the MCP entry was patched, restart Claude Code (exit + 'claude --resume' or"
echo "    detach from tmux and re-run 'make coi') so MCP picks up the new config."
