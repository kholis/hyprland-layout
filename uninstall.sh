#!/usr/bin/env bash
# Removes hyprland-layout: unwires the require line and removes the module
# (with backup). Hyprland returns to stock Omarchy behavior.
set -euo pipefail

HYPR_DIR="${HOME}/.config/hypr"
TARGET="${HYPR_DIR}/workspaces.lua"
MAIN="${HYPR_DIR}/hyprland.lua"
STAMP="$(date +%s)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

if [ -f "${MAIN}" ] && grep -q 'require("hypr.workspaces")' "${MAIN}"; then
  sed -i '/require("hypr.workspaces")/d' "${MAIN}"
  say "removed require line from ${MAIN}"
fi

if [ -f "${TARGET}" ]; then
  mv "${TARGET}" "${TARGET}.removed.${STAMP}"
  say "moved ${TARGET} aside (workspaces.lua.removed.${STAMP})"
fi

command -v hyprctl >/dev/null 2>&1 && hyprctl reload >/dev/null && say "reloaded"
say "done. Mode state kept at ~/.local/state/omarchy/screen-estate (safe to delete)."
