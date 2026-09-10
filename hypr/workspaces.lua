-- hyprland-layout: workspace modes that maximize screen estate on small
-- displays. Four modes, cycled at runtime with Hyper+Space (Caps Lock + Space
-- on Omarchy) or by editing `default_mode` below:
--   (own -> float -> stacked -> tiling -> own)
--
--   "float"    (default) Traditional floating WM (XFCE/KDE/GNOME style):
--              every app opens FLOATING on the CURRENT workspace at its own
--              natural size — no forced maximize or tiling. Drag, resize,
--              overlap at will. Snaps to screen halves with Hyper+arrows,
--              maximizes with Super+Alt+F, cycles/raises with Alt+Tab.
--              Focus is click-to-focus (see float_click_to_focus below):
--              hovering never steals focus from the current window.
--              persistent_size: resize an app once and future windows of the
--              same class+title reopen at that size.
--
--   "own"      Every new app opens ALONE on its own empty workspace. A second
--              window never appears unless you move one there yourself
--              (SUPER+SHIFT+1..9). Switch apps with SUPER+1..9 (workspace
--              bar) or Hyper binds. When the last window of a workspace
--              closes (e.g. an app's transient viewer dismissed with ESC),
--              you are returned to the previously used workspace.
--
--   "stacked"  Every app opens maximized and stacked on workspace 1 using
--              Hyprland's Monocle layout (one window fills the screen at a
--              time; the rest wait behind it). Cycle with Hyper+Tab, Alt+Tab,
--              or jump with per-app binds.
--
--   "tiling"   Stock Hyprland/Omarchy dwindle tiling. Nothing is relocated
--              or floated; the fallback for purists.
--
-- "Hyper" is MOD3 (e.g. Caps Lock mapped to Hyper). If you don't have one,
-- swap "MOD3" for another modifier in the binds below.
-- Requires Omarchy's Lua config helpers (o.bind / o.notify) — Hyprland 0.55+.
--
-- Modes can also be set at runtime from the shell / Omarchy menu via
-- bin/hyprland-layout-set (see README): `hyprland-layout-set float` etc.

local default_mode = "float" -- "own" | "float" | "stacked" | "tiling"

-- Classes (substring, case-sensitive) never relocated automatically in "own"
-- mode, e.g. windows you place yourself with workspace rules: { "qemu" }
local keep_classes = {}

-- In float mode, focus a window only by CLICKING it — hovering the mouse
-- never steals focus (Hyprland follow_mouse = 0). Other modes keep Omarchy's
-- stock follow-mouse. Set to false for follow-mouse while floating too.
local float_click_to_focus = true

-- ---------------------------------------------------------------- state ----
local state_dir = (os.getenv("HOME") or "") .. "/.local/state/omarchy/screen-estate"
local state_file = state_dir .. "/mode"

local function read_mode()
  local file = io.open(state_file, "r")
  if not file then
    return nil
  end
  local value = file:read("*l")
  file:close()
  return (value == "own" or value == "float" or value == "stacked" or value == "tiling")
      and value or nil
end

local function write_mode(value)
  os.execute("mkdir -p " .. state_dir)
  local file = io.open(state_file, "w")
  if file then
    file:write(value)
    file:close()
  end
end

local mode = read_mode() or default_mode
local follow_mouse_touched = false

-- ---------------------------------------------------------------- rules ----
-- stacked: send every new window to workspace 1, monocle-stacked.
local stack_rule = hl.window_rule({
  name = "hyprland-layout-stack-on-workspace-1",
  match = { class = ".*" },
  workspace = "1",
})

-- float: every new window floats on the CURRENT workspace at its natural
-- size — the classic `windowrulev2 = float, class:.*`, with no workspace pin.
local float_rule = hl.window_rule({
  name = "hyprland-layout-float",
  match = { class = ".*" },
  float = true,
  persistent_size = true,
})

local function apply_mode()
  stack_rule:set_enabled(mode == "stacked")
  float_rule:set_enabled(mode == "float")
  -- Monocle: every window fills the whole workspace, one visible at a time.
  -- Dwindle: Omarchy's default tiling (used by own/float/tiling).
  hl.config({ general = { layout = mode == "stacked" and "monocle" or "dwindle" } })

  -- Float mode focuses on click, not on hover. Only touched while floating so
  -- a user's own follow_mouse choice (input.lua) survives otherwise; leaving
  -- float restores Omarchy's stock follow_mouse = 1.
  if mode == "float" and float_click_to_focus then
    if not follow_mouse_touched then
      hl.config({ input = { follow_mouse = 0 } })
      follow_mouse_touched = true
    end
  elseif follow_mouse_touched then
    hl.config({ input = { follow_mouse = 1 } })
    follow_mouse_touched = false
  end
end

apply_mode()

-- ------------------------------------------------- own: one app per ws ----
-- First workspace ID >= `from` that carries no windows. Workspace selectors
-- like "e+1" resolve unpredictably across versions, so compute it here.
local function next_free_workspace_id(from)
  local taken = {}
  for _, ws in ipairs(hl.get_workspaces() or {}) do
    if not ws.special and not ws.is_empty then
      taken[ws.id] = true
    end
  end

  local id = from
  while taken[id] do
    id = id + 1
  end
  return id
end

-- Move every newly opened window to its own empty workspace, so a workspace
-- never gets a second window unless you move one there yourself. Floating
-- dialogs/popups and windows already placed on another workspace (by app
-- rules or the app itself) are left alone.
hl.on("window.open", function(w)
  if mode ~= "own" or w == nil or w.floating or w.pinned then
    return
  end

  -- Windows that already cover the workspace (fullscreen/maximize requested
  -- at map time, e.g. media viewers or games) gain nothing from a workspace of
  -- their own; leaving them in place keeps ESC/close returning to the app
  -- underneath.
  if (w.fullscreen or 0) ~= 0 then
    return
  end

  local ws = w.workspace
  if ws == nil or ws.special then
    return
  end

  -- A window rule or the app itself placed it elsewhere; respect that.
  local active = hl.get_active_workspace()
  if active == nil or ws.id ~= active.id then
    return
  end

  for _, class in ipairs(keep_classes) do
    if w.class and w.class:find(class, 1, true) then
      return
    end
  end

  -- Count tiled windows on the workspace the new window landed on.
  local tiled = 0
  local windows = hl.get_workspace_windows(ws.id)
  if windows ~= nil then
    for _, win in ipairs(windows) do
      if not win.floating then
        tiled = tiled + 1
      end
    end
  end

  -- Alone on its workspace already: nothing to do.
  if tiled <= 1 then
    return
  end

  -- Move to the first free workspace after the current one; follow=true
  -- moves the view there with it. Remove follow=true to keep working where
  -- you are while it opens elsewhere.
  local target = next_free_workspace_id(ws.id + 1)
  hl.dispatch(hl.dsp.window.move({ workspace = target, follow = true, window = w }))
end)

-- --------------------------------------- auto-return on empty workspace ----
-- When the last window of a workspace closes while you are viewing it
-- (Telegram's media viewer on ESC, a closing app window, ...), switch back
-- to the previously used workspace instead of stranding you on an empty one.
-- Track the workspace we came FROM; Hyprland's "previous" selector is
-- unreliable across rapid programmatic switches, so keep our own history.
local previous_ws = nil
local current_ws = nil

local function track_active_workspace()
  local active = hl.get_active_workspace()
  current_ws = active ~= nil and active.id or nil
end

hl.on("workspace.active", function(ws)
  if ws == nil or ws.special then
    return
  end
  if current_ws ~= nil and ws.id ~= current_ws then
    previous_ws = current_ws
  end
  current_ws = ws.id
end)
track_active_workspace()

local closing_ws = nil

hl.on("window.close", function(w)
  -- The window object is already torn down by `window.destroy`, so capture
  -- where the closing window lived while its data is still valid.
  closing_ws = (w ~= nil and w.workspace ~= nil) and w.workspace.id or nil
end)

hl.on("window.destroy", function(w)
  if closing_ws == nil then
    return
  end

  local closed_ws = closing_ws
  closing_ws = nil

  if closed_ws == nil then
    return
  end

  -- Only when the workspace the window left is the one being viewed and is
  -- now empty; otherwise never touch the focus.
  local active = hl.get_active_workspace()
  if active == nil or active.special or active.id ~= closed_ws then
    return
  end

  local remaining = hl.get_workspace_windows(active.id)
  if remaining ~= nil and #remaining > 0 then
    return
  end

  -- Prefer the workspace we came from (the app underneath, e.g. Telegram
  -- under its media viewer); fall back to any workspace still holding
  -- windows.
  local target = nil
  if previous_ws ~= nil and previous_ws ~= active.id then
    local prev = hl.get_workspace(previous_ws)
    if prev ~= nil and not prev.is_empty then
      target = previous_ws
    end
  end

  if target == nil then
    for _, ws in ipairs(hl.get_workspaces() or {}) do
      if not ws.special and not ws.is_empty and ws.id ~= active.id then
        target = ws.id
        break
      end
    end
  end

  if target ~= nil then
    hl.dispatch(hl.dsp.focus({ workspace = target }))
  end
end)

-- ------------------------------------------------------ window cycling ----
-- Plain cycle_next does not work under Monocle; cycle with layout messages.
-- Replaces Omarchy's Alt+Tab binds with mode-aware versions.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")

o.bind("ALT + TAB", "Focus on next window", function()
  if mode == "stacked" then
    hl.dispatch(hl.dsp.layout("cyclenext"))
  else
    hl.dispatch(hl.dsp.window.cycle_next())
    hl.dispatch(hl.dsp.window.bring_to_top())
  end
end)
o.bind("ALT + SHIFT + TAB", "Focus on previous window", function()
  if mode == "stacked" then
    hl.dispatch(hl.dsp.layout("cycleprev"))
  else
    hl.dispatch(hl.dsp.window.cycle_next({ next = false }))
    hl.dispatch(hl.dsp.window.bring_to_top())
  end
end)

-- Blind Hyper-key cycling. Stacked uses layout messages; other modes cycle
-- windows normally and raise the focused one on top.
local function cycle_window(forward)
  return function()
    if mode == "stacked" then
      hl.dispatch(hl.dsp.layout(forward and "cyclenext" or "cycleprev"))
    else
      hl.dispatch(hl.dsp.window.cycle_next({ next = forward }))
      hl.dispatch(hl.dsp.window.bring_to_top())
    end
  end
end

o.bind("MOD3 + TAB", "Next window", cycle_window(true))
o.bind("MOD3 + SHIFT + TAB", "Previous window", cycle_window(false))

-- -------------------------------------------- raise focused window --------
-- Floating windows: focusing a window (Hyper+A/B/..., Alt+Tab, launcher,
-- click) also RAISES it to the front. NOTE: only alter_zorder on FLOATING
-- windows — doing it to tiled/maximized windows desyncs input from rendering
-- (window visually behind but eating clicks). Maximized windows are kept
-- floating in float mode via the Super+Alt+F rebind below, so they raise
-- correctly through this same path.
hl.on("window.active", function(w)
  if w ~= nil and w.floating then
    hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = w }))
  end
end)

-- Maximize/restore that stays in the floating layer in float mode: a tiled
-- window maximized with fullscreen state renders below floating windows and
-- cannot be raised. Floating it first makes maximize behave like a
-- traditional WM: full work-area size, raises on focus, restores cleanly.
hl.unbind("SUPER + ALT + F")
o.bind("SUPER + ALT + F", "Maximize / restore", function()
  local win = hl.get_active_window()
  if mode == "float" and win ~= nil and not win.floating then
    hl.dispatch(hl.dsp.window.float({ action = "set", window = win }))
  end
  hl.dispatch(hl.dsp.window.fullscreen({ mode = "maximized" }))
end)

-- ------------------------------------------- half-screen snapping --------
-- Aero/XFCE-style: Hyper+arrows snap the active FLOATING window to a half
-- of the screen. Works in any mode, but only affects floating windows
-- (tiled windows are the layout's business). Maximizing is Super+Alt+F.
local function snap_to_side(side)
  return function()
    local win = hl.get_active_window()
    if win == nil or not win.floating then
      return
    end

    local mon = hl.get_active_monitor()
    if mon == nil then
      return
    end

    -- Stay inside the work area (below the bar, beside any reserved edges).
    local reserved = type(mon.reserved) == "table" and mon.reserved or {}
    local top = reserved.top or 0
    local left = reserved.left or 0
    local right = reserved.right or 0
    local bottom = reserved.bottom or 0

    local W = mon.width - left - right
    local H = mon.height - top - bottom
    local half_w = math.floor(W / 2)
    local half_h = math.floor(H / 2)

    local x, y, w, h
    if side == "left" then
      x, y, w, h = left, top, half_w, H
    elseif side == "right" then
      x, y, w, h = left + (W - half_w), top, half_w, H
    elseif side == "top" then
      x, y, w, h = left, top, W, half_h
    else -- "bottom"
      x, y, w, h = left, top + (H - half_h), W, half_h
    end

    -- Resize first, then move: resize re-anchors the window on its center,
    -- so the absolute move must come last to land on the exact edge.
    hl.dispatch(hl.dsp.window.resize({ x = w, y = h, window = win }))
    hl.dispatch(hl.dsp.window.move({ x = x, y = y, window = win }))
  end
end

o.bind("MOD3 + LEFT", "Snap window to left half", snap_to_side("left"))
o.bind("MOD3 + RIGHT", "Snap window to right half", snap_to_side("right"))
o.bind("MOD3 + UP", "Snap window to top half", snap_to_side("top"))
o.bind("MOD3 + DOWN", "Snap window to bottom half", snap_to_side("bottom"))

-- --------------------------------------------------------- mode toggle -----
-- Hyper+Space cycles through the modes (own -> float -> stacked -> tiling)
-- and remembers the choice. Entering stacked gathers windows onto workspace
-- 1; entering float floats them IN PLACE (no workspace moves).
local function gather_on_workspace_1()
  for _, win in ipairs(hl.get_windows() or {}) do
    local ws = win.workspace
    if ws ~= nil and not ws.special and ws.id ~= 1 then
      hl.dispatch(hl.dsp.window.move({ workspace = "1", window = win }))
    end
  end
  hl.dispatch(hl.dsp.focus({ workspace = 1 }))
end

local function float_existing_windows_in_place()
  for _, win in ipairs(hl.get_windows() or {}) do
    local ws = win.workspace
    if ws ~= nil and not ws.special and not win.floating then
      hl.dispatch(hl.dsp.window.float({ action = "set", window = win }))
    end
  end
end

local mode_messages = {
  own = "Own-workspace mode: each new app gets its own workspace",
  float = "Floating mode: apps float on the current workspace",
  stacked = "Stacked mode: apps open maximized on workspace 1",
  tiling = "Tiling mode: standard dwindle tiling",
}

local next_mode = { own = "float", float = "stacked", stacked = "tiling", tiling = "own" }

-- Runtime mode switch shared by the Hyper+Space cycle below and the Omarchy
-- menu integration (bin/hyprland-layout-set reaches it through
-- `hyprctl eval "hyprland_layout_set_mode('float')"`). Global on purpose:
-- module-locals are not reachable from `hyprctl eval`.
function hyprland_layout_set_mode(new_mode)
  if new_mode == nil or next_mode[new_mode] == nil then
    return false
  end
  mode = new_mode
  write_mode(mode)
  apply_mode()
  if mode == "stacked" then
    gather_on_workspace_1()
  elseif mode == "float" then
    float_existing_windows_in_place()
  end
  hl.exec_cmd(o.notify(mode_messages[mode] or mode))
  return true
end

o.bind("MOD3 + SPACE", "Cycle mode: own / float / stacked / tiling", function()
  hyprland_layout_set_mode(next_mode[mode] or "float")
end)
