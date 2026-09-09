#!/usr/bin/env bash
# hyprland-layout installer for Omarchy (https://omarchy.org)
# Deploys the workspaces.lua module and wires it into ~/.config/hypr/hyprland.lua.
# Safe to re-run: backs up any previous copy, never duplicates the require line.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_DIR="${HOME}/.config/hypr"
TARGET="${HYPR_DIR}/workspaces.lua"
MAIN="${HYPR_DIR}/hyprland.lua"
STAMP="$(date +%s)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- requirements -----------------------------------------------------------
[ -n "${XDG_CURRENT_DESKTOP:-}" ] || command -v hyprctl >/dev/null 2>&1 \
  || die "not running under Hyprland (no hyprctl). Install from a Hyprland session."
[ -d /usr/share/omarchy ] || [ -n "${OMARCHY_PATH:-}" ] \
  || die "Omarchy not found. This module uses Omarchy's Lua helpers (o.bind/o.notify)."
[ -f "${REPO_DIR}/hypr/workspaces.lua" ] || die "run from the repository root."

# --- deploy module ----------------------------------------------------------
mkdir -p "${HYPR_DIR}"
if [ -f "${TARGET}" ]; then
  cp "${TARGET}" "${TARGET}.bak.${STAMP}"
  say "backed up existing ${TARGET} -> workspaces.lua.bak.${STAMP}"
fi
cp "${REPO_DIR}/hypr/workspaces.lua" "${TARGET}"
say "installed ${TARGET}"

# --- wire into main config --------------------------------------------------
if ! grep -q 'require("hypr.workspaces")' "${MAIN}" 2>/dev/null; then
  if grep -q 'require("hypr.autostart")' "${MAIN}"; then
    sed -i 's|require("hypr.autostart")|require("hypr.autostart")\nrequire("hypr.workspaces")|' "${MAIN}"
  else
    cp "${MAIN}" "${MAIN}.bak.${STAMP}" 2>/dev/null || true
    printf '\nrequire("hypr.workspaces")\n' >> "${MAIN}"
  fi
  say "added require(\"hypr.workspaces\") to ${MAIN}"
else
  say "require(\"hypr.workspaces\") already present in ${MAIN}"
fi

# --- apply ------------------------------------------------------------------
if command -v hyprctl >/dev/null 2>&1; then
  hyprctl reload >/dev/null
  sleep 1
  if [ -n "$(hyprctl configerrors 2>/dev/null)" ]; then
    hyprctl configerrors >&2
    die "Hyprland reported config errors — inspect the output above."
  fi
  say "reloaded Hyprland config — no errors"
else
  say "hyprctl not found; the config loads on next Hyprland start"
fi

say "done. Default mode: float. Cycle modes with Hyper+Space (Caps Lock + Space)."
