#!/usr/bin/env bash
# hyprland-layout installer for Omarchy (https://omarchy.org)
# Deploys the workspaces.lua module and wires it into ~/.config/hypr/hyprland.lua.
# Safe to re-run: backs up any previous copy, never duplicates the require line.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HYPR_DIR="${HOME}/.config/hypr"
TARGET="${HYPR_DIR}/workspaces.lua"
MAIN="${HYPR_DIR}/hyprland.lua"
BIN_SRC="${REPO_DIR}/bin/hyprland-layout-set"
BIN_DST="${HOME}/.local/bin/hyprland-layout-set"
FRAGMENT="${REPO_DIR}/omarchy/menu-fragment.jsonc"
EXT_DIR="${HOME}/.config/omarchy/extensions"
EXT_FILE="${EXT_DIR}/omarchy-menu.jsonc"
BLOCK_BEGIN='// >>> hyprland-layout >>>'
BLOCK_END='// <<< hyprland-layout <<<'
STAMP="$(date +%s)"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- requirements -----------------------------------------------------------
[ -n "${XDG_CURRENT_DESKTOP:-}" ] || command -v hyprctl >/dev/null 2>&1 \
  || die "not running under Hyprland (no hyprctl). Install from a Hyprland session."
[ -d /usr/share/omarchy ] || [ -n "${OMARCHY_PATH:-}" ] \
  || die "Omarchy not found. This module uses Omarchy's Lua helpers (o.bind/o.notify)."
[ -f "${REPO_DIR}/hypr/workspaces.lua" ] || die "run from the repository root."
[ -f "${BIN_SRC}" ] || die "bin/hyprland-layout-set missing; run from the repository root."
[ -f "${FRAGMENT}" ] || die "omarchy/menu-fragment.jsonc missing; run from the repository root."

# --- deploy module ----------------------------------------------------------
mkdir -p "${HYPR_DIR}"
if [ -f "${TARGET}" ]; then
  cp "${TARGET}" "${TARGET}.bak.${STAMP}"
  say "backed up existing ${TARGET} -> workspaces.lua.bak.${STAMP}"
fi
cp "${REPO_DIR}/hypr/workspaces.lua" "${TARGET}"
say "installed ${TARGET}"

# --- deploy CLI --------------------------------------------------------------
# hyprland-layout-set <tiling|scrolling|float|own|stacked> — used by the Omarchy
# menu (Trigger > Toggle > Workspace Layout) and usable from the shell.
mkdir -p "${HOME}/.local/bin"
install -m 0755 "${BIN_SRC}" "${BIN_DST}"
say "installed ${BIN_DST}"

# --- deploy menu entries -----------------------------------------------------
# Merges omarchy/menu-fragment.jsonc (between the >>> hyprland-layout >>>
# sentinels) into the Omarchy menu extension file, replacing any previously
# managed block. Re-running never duplicates the entries.
inject_menu_entries() {
  mkdir -p "${EXT_DIR}"

  if [ ! -f "${EXT_FILE}" ]; then
    {
      echo '{'
      echo "${BLOCK_BEGIN}"
      cat "${FRAGMENT}"
      echo "${BLOCK_END}"
      echo '}'
    } >"${EXT_FILE}"
    say "created ${EXT_FILE}"
    return
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v begin="${BLOCK_BEGIN}" -v end="${BLOCK_END}" -v fragment="${FRAGMENT}" '
    BEGIN { inblock = 0; replaced = 0 }
    # Replace a previously managed block in place: flush the lines seen
    # before it, emit the fresh block, and keep scanning past the old one.
    index($0, begin) > 0 {
      inblock = 1
      if (!replaced) {
        # Repair a missing comma on the last real entry above the block.
        for (i = n; i >= 1; i--) {
          if (lines[i] ~ /^[[:space:]]*$/ || lines[i] ~ /^[[:space:]]*\/\//) continue
          if (lines[i] !~ /(,|\{|\[|:)[[:space:]]*$/) lines[i] = lines[i] ","
          break
        }
        for (i = 1; i <= n; i++) print lines[i]
        n = 0
        print begin
        while ((getline line < fragment) > 0) print line
        print end
        replaced = 1
      }
      next
    }
    index($0, end) > 0 { inblock = 0; next }
    inblock { next }
    { lines[++n] = $0 }
    END {
      if (replaced) {
        for (i = 1; i <= n; i++) print lines[i]
        exit
      }
      # First install: insert before the last closing brace.
      last = 0
      for (i = n; i >= 1; i--) if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) { last = i; break }
      if (last == 0) { print "NOBRACE"; exit }
      # Comma-separate from the last real entry above, if any.
      prev = 0
      for (i = last - 1; i >= 1; i--) {
        if (lines[i] ~ /^[[:space:]]*$/ || lines[i] ~ /^[[:space:]]*\/\//) continue
        prev = i; break
      }
      if (prev > 0 && lines[prev] !~ /(,|\{|\[|:)[[:space:]]*$/) lines[prev] = lines[prev] ","
      for (i = 1; i <= n; i++) {
        if (i == last) {
          print ""
          print begin
          while ((getline line < fragment) > 0) print line
          print end
        }
        print lines[i]
      }
    }
  ' "${EXT_FILE}" >"${tmp}"

  if grep -q '^NOBRACE$' "${tmp}"; then
    rm -f "${tmp}"
    cp "${EXT_FILE}" "${EXT_FILE}.bak.${STAMP}"
    die "${EXT_FILE} has no closing brace to insert before; backed it up and skipped the menu entries."
  fi

  if ! cmp -s "${EXT_FILE}" "${tmp}"; then
    cp "${EXT_FILE}" "${EXT_FILE}.bak.${STAMP}"
    mv "${tmp}" "${EXT_FILE}"
    say "merged menu entries into ${EXT_FILE} (backup: omarchy-menu.jsonc.bak.${STAMP})"
  else
    rm -f "${tmp}"
    say "menu entries in ${EXT_FILE} already up to date"
  fi
}
inject_menu_entries

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

say "done. Default mode: float. Cycle with Hyper+Space, or pick a layout in the Omarchy menu (Trigger > Toggle > Workspace Layout) or with hyprland-layout-set."
