#!/usr/bin/env bash
# install.sh — deploy the COI skill and/or onboard a project.
#
# Usage:
#   ./install.sh                 Install the skill into ~/.claude/skills/coi/
#   ./install.sh --check         Check host prerequisites (Incus, coi, jq, ssh-agent)
#   ./install.sh --project DIR   Scaffold .coi.toml + coi.mk into a project (implies skill install)
#   ./install.sh --help
#
# Environment:
#   CLAUDE_HOME   Override the Claude Code home (default: $HOME/.claude)
#
# No sudo required. Host-package installation (Incus etc.) is intentionally NOT
# automated here — see docs/HOST_SETUP.md; run --check to see what's missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILL_DEST="$CLAUDE_HOME/skills/coi"

# The skill payload (what Claude Code loads). Everything else in this repo is
# repo-meta (README, docs, install.sh, LICENSE) and is NOT copied into the skill.
PAYLOAD=(SKILL.md references)

c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '  %s[OK]%s   %s\n'   "$c_green"  "$c_off" "$*"; }
warn() { printf '  %s[WARN]%s %s\n'   "$c_yellow" "$c_off" "$*"; }
fail() { printf '  %s[FAIL]%s %s\n'   "$c_red"    "$c_off" "$*"; }
info() { printf '%s\n' "$*"; }

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

install_skill() {
  info "==> Installing skill into $SKILL_DEST"
  mkdir -p "$SKILL_DEST"
  for item in "${PAYLOAD[@]}"; do
    if [ ! -e "$SCRIPT_DIR/$item" ]; then
      fail "missing payload item: $item (run from the repo root)"; exit 1
    fi
    cp -a "$SCRIPT_DIR/$item" "$SKILL_DEST/"
  done
  chmod +x "$SKILL_DEST/references/coi-self-bootstrap.sh" 2>/dev/null || true
  ok "skill installed — Claude Code will discover it as 'coi'"
  info "${c_dim}    ($SKILL_DEST/SKILL.md)${c_off}"
}

check_prereqs() {
  info "==> Host prerequisite check"
  local missing=0

  if command -v incus >/dev/null 2>&1; then
    local iv; iv="$(incus version 2>/dev/null | head -1 || true)"
    # Incus prints "Client version: X.Y" or just the number depending on release.
    ok "Incus present ($iv)"
    info "${c_dim}      need >= 6.1; verify with 'incus version'${c_off}"
  else
    fail "Incus not found — see docs/HOST_SETUP.md"; missing=1
  fi

  if command -v coi >/dev/null 2>&1; then
    ok "coi binary present ($(coi version 2>/dev/null | head -1 || echo '?'))"
  else
    fail "coi binary not found — curl -fsSL https://raw.githubusercontent.com/mensfeld/code-on-incus/master/install.sh | bash"; missing=1
  fi

  if command -v jq >/dev/null 2>&1; then ok "jq present"
  else fail "jq not found — the Makefile targets need it (apt/dnf/pacman/brew install jq)"; missing=1; fi

  local sock="${SSH_AUTH_SOCK:-}"
  if [ -n "$sock" ] && [ -S "$sock" ]; then
    if command -v ssh-add >/dev/null 2>&1 && ssh-add -l >/dev/null 2>&1; then
      ok "SSH agent live at \$SSH_AUTH_SOCK ($sock) with keys loaded"
    else
      warn "SSH agent socket present ($sock) but no keys loaded — run 'ssh-add'"
    fi
  else
    warn "no SSH agent at \$SSH_AUTH_SOCK — set one up (docs/HOST_SETUP.md §SSH agent)"
  fi

  if [ "$missing" -eq 0 ]; then
    info "==> ${c_green}Prerequisites satisfied.${c_off}"
  else
    info "==> ${c_red}Some prerequisites are missing — see docs/HOST_SETUP.md.${c_off}"
    return 1
  fi
}

scaffold_project() {
  local dir="$1"
  [ -d "$dir" ] || { fail "project dir does not exist: $dir"; exit 1; }
  dir="$(cd "$dir" && pwd)"
  info "==> Onboarding project: $dir"

  # .coi.toml (never overwrite an existing one)
  if [ -e "$dir/.coi.toml" ]; then
    warn ".coi.toml already exists — left untouched"
  else
    cp "$SCRIPT_DIR/references/config.toml.template" "$dir/.coi.toml"
    ok "wrote $dir/.coi.toml (from template — review [[mounts.default]] and [network])"
  fi

  # coi.mk (Makefile targets as an includable fragment)
  if [ -e "$dir/coi.mk" ]; then
    warn "coi.mk already exists — left untouched"
  else
    cp "$SCRIPT_DIR/references/Makefile.snippet" "$dir/coi.mk"
    ok "wrote $dir/coi.mk"
  fi

  info ""
  info "==> Final step — add this line to $dir/Makefile:"
  info "${c_green}    include coi.mk${c_off}"
  info ""
  info "    Then:  cd $dir && make coi"
  info "    (If the project has no Makefile, 'echo \"include coi.mk\" > Makefile' is enough to start.)"
}

main() {
  local do_check=0 project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --check)   do_check=1 ;;
      --project) shift; project="${1:-}"; [ -n "$project" ] || { fail "--project needs a DIR"; exit 1; } ;;
      -h|--help) usage; exit 0 ;;
      *) fail "unknown arg: $1"; usage; exit 1 ;;
    esac
    shift
  done

  if [ "$do_check" -eq 1 ]; then
    check_prereqs
    exit $?
  fi

  install_skill
  if [ -n "$project" ]; then
    info ""
    scaffold_project "$project"
  fi
  info ""
  info "Done. Next: './install.sh --check' to verify the host, or 'make coi' in an onboarded project."
}

main "$@"
