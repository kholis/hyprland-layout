#!/usr/bin/env bash
# Removes hyprland-layout: unwires the require line, removes the module (with
# backup), the hyprland-layout-set CLI, and the Omarchy menu entries. Hyprland
# returns to stock Omarchy behavior (dwindle/scrolling toggle).
set -euo pipefail

HYPR_DIR="${HOME}/.config/hypr"
TARGET="${HYPR_DIR}/workspaces.lua"
MAIN="${HYPR_DIR}/hyprland.lua"
BIN_DST="${HOME}/.local/bin/hyprland-layout-set"
EXT_FILE="${HOME}/.config/omarchy/extensions/omarchy-menu.jsonc"
STAMP="$(date +%s)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

if [ -f "${EXT_FILE}" ] && grep -q 'hyprland-layout' "${EXT_FILE}"; then
  tmp="$(mktemp)"
  awk -v begin='// >>> hyprland-layout >>>' -v end='// <<< hyprland-layout <<<' '
    BEGIN { inblock = 0; pending_blank = 0 }
    index($0, begin) > 0 { inblock = 1; pending_blank = 0; next }
    index($0, end) > 0 { inblock = 0; next }
    inblock { next }
    # Defer blank lines so the one above the removed block disappears too.
    /^[[:space:]]*$/ { pending_blank++; next }
    {
      for (i = 0; i < pending_blank; i++) print ""
      pending_blank = 0
      print
    }
    END { for (i = 0; i < pending_blank; i++) print "" }
  ' "${EXT_FILE}" >"${tmp}"
  cp "${EXT_FILE}" "${EXT_FILE}.bak.${STAMP}"
  mv "${tmp}" "${EXT_FILE}"
  say "removed menu entries from ${EXT_FILE} (backup: omarchy-menu.jsonc.bak.${STAMP})"
fi

if [ -f "${BIN_DST}" ]; then
  rm -f "${BIN_DST}"
  say "removed ${BIN_DST}"
fi

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
say "note: the stock dwindle/scrolling toggle returns in the Omarchy menu."
