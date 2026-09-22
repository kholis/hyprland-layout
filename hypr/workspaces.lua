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
--              Every window's size/position and maximized/fullscreen state is
--              also REMEMBERED (see remember_windows below): after the screen
--              locks (suspend/screensaver) and you log back in, windows keep
--              their maximized state instead of coming back as plain floats —
--              and the first window of an app reopens at its remembered
--              size/position/state, like the WMs of old.
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
-- Window state memory: every window's size, position and maximized/fullscreen
-- state is remembered. This matters most around the lock screen: Omarchy locks
-- before suspend, and when the machine wakes the monitor re-arrangement makes
-- Hyprland forget that floating windows were maximized (Super+Alt+F) — after
-- login they'd come back as plain floating windows. The layout re-applies each
-- window's remembered state a moment after monitors (re)appear. In float/own
-- mode the first window of an app also reopens at its remembered
-- size/position/state, like the WMs of old. The memory survives crashes.
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

-- Remember every window's size, position and maximized/fullscreen state, and
-- restore it after monitor re-arrangements (suspend/resume, docking, screen
-- changes) and when an app reopens its first window. Set to false to disable.
local remember_windows = true

-- Window titles that are never remembered: overlay windows like Firefox's
-- Picture-in-Picture would otherwise overwrite the app's remembered geometry.
local remember_skip_titles = { "Picture-in-Picture" }

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
  -- Workspace objects, like windows, can arrive expired (nil reads) when the
  -- event fires for a workspace being torn down; `ws.id == nil` catches that
  -- before it corrupts the history below.
  if ws == nil or ws.id == nil or ws.special then
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

-- Any fullscreen state (real fullscreen or maximized) — such windows own
-- the top render layer of their workspace and must not be z-swapped
-- lightly: alter_zorder on them desyncs input from rendering.
local function window_is_fullscreen(w)
  return w ~= nil and (w.fullscreen or 0) ~= 0
end

-- Hyprland 0.56 fires `window.active` with a NULL window when focus is
-- cleared (last window on a workspace closed, focus moved to a layer-shell
-- surface) and hands Lua an EXPIRED HL.Window userdata instead of nil:
-- every property read silently returns nil, and dispatching it raises
-- "runtime error in lua: window selector: window object is expired".
-- Properties of a live window are never nil, so a nil read marks a dead
-- object — treat it as "no window".
local function window_is_alive(w)
  return w ~= nil and w.mapped ~= nil
end

-- ------------------------------------------------ window state memory -----
-- Every window's size/position (while plain-floating) and maximized/fullscreen
-- state is tracked live. Records live in memory keyed by window address
-- (exact, per-instance) and are mirrored per app class, persisted to
-- windows.db so the memory even survives a compositor crash.
local memory_db = state_dir .. "/windows.db"
local mem_by_address = {}
local mem_by_class = {}
local memory_dirty = false
local memory_last_flush = 0
local memory_frozen_until = 0

local function window_memory_skipped(win)
  local title = win.title or ""
  for _, needle in ipairs(remember_skip_titles) do
    if needle ~= "" and title:find(needle, 1, true) then
      return true
    end
  end
  return false
end

-- Take a sample of a window's current state. Geometry is only recorded while
-- the window is a plain float: a maximized/fullscreen window's at/size is the
-- work area, not the app's own size — the last normal geometry is kept then.
-- `force` records even while memory is frozen (see restore_after_monitor_event).
local function sample_window(win, force)
  if not remember_windows or not window_is_alive(win) or win.pinned or window_memory_skipped(win) then
    return
  end
  if not force and os.time() < memory_frozen_until then
    -- A monitor re-arrangement is in progress: Hyprland is about to (or just
    -- did) drop maximized/fullscreen state, and the dropped state must NOT
    -- overwrite what we remember — the restore passes need it.
    return
  end

  local class = win.initial_class or win.class
  if class == nil or class == "" then
    return
  end

  local fs = win.fullscreen or 0 -- 0 normal, 1 maximized, 2 fullscreen
  local floating = win.floating == true
  local mon = win.monitor
  local mon_name = (mon ~= nil and mon.name) or ""

  local prev = mem_by_address[win.address]
  local rec = {
    fs = fs,
    fl = floating,
    mon = mon_name,
    x = prev ~= nil and prev.x or nil,
    y = prev ~= nil and prev.y or nil,
    w = prev ~= nil and prev.w or nil,
    h = prev ~= nil and prev.h or nil,
    -- fs before the last recorded change + when it changed: lets the freeze
    -- handler undo a maximized/fullscreen loss that was recorded a moment
    -- BEFORE the monitor event fired (drop and events race each other).
    pfs = nil,
    changed = nil,
  }
  if prev ~= nil and prev.fs ~= fs then
    rec.pfs, rec.changed = prev.fs, os.time()
  elseif prev ~= nil then
    rec.pfs, rec.changed = prev.pfs, prev.changed
  end

  if fs == 0 and floating then
    local at, size = win.at, win.size
    if at ~= nil and size ~= nil and (size.x or 0) > 0 and (size.y or 0) > 0 then
      rec.x, rec.y, rec.w, rec.h = at.x, at.y, size.x, size.y
    end
  end

  mem_by_address[win.address] = rec
  mem_by_class[class] = rec
  memory_dirty = true
end

local function sample_all_windows()
  if not remember_windows then
    return
  end
  local windows = hl.get_windows() or {}
  for _, win in ipairs(windows) do
    sample_window(win)
  end
  -- Drop records of windows that are gone (their final state was already
  -- merged into the per-class memory by sample_window/close handling).
  local alive = {}
  for _, win in ipairs(windows) do
    alive[win.address] = true
  end
  for addr in pairs(mem_by_address) do
    if not alive[addr] then
      mem_by_address[addr] = nil
    end
  end
end

local function flush_memory(force)
  if not remember_windows or not memory_dirty then
    return
  end
  if not force and os.time() - memory_last_flush < 3 then
    return
  end
  local file = io.open(memory_db, "w")
  if file == nil then
    return
  end
  for class, r in pairs(mem_by_class) do
    file:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
      (class:gsub("[\t\r\n]", " ")),
      r.fs or 0,
      r.fl and 1 or 0,
      r.x or 0, r.y or 0, r.w or 0, r.h or 0,
      ((r.mon or ""):gsub("[\t\r\n]", ""))))
  end
  file:close()
  memory_dirty = false
  memory_last_flush = os.time()
end

local function load_memory()
  local file = io.open(memory_db, "r")
  if file == nil then
    return
  end
  for line in file:lines() do
    local class, fs, fl, x, y, w, h, mon =
      line:match("^([^\t]+)\t(%d+)\t(%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(%-?%d+)\t(.*)$")
    if class ~= nil and class ~= "" then
      mem_by_class[class] = {
        fs = tonumber(fs) or 0,
        fl = fl == "1",
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
        w = tonumber(w) or 0,
        h = tonumber(h) or 0,
        mon = mon or "",
      }
    end
  end
  file:close()
end

local function ensure_float(win)
  if not win.floating then
    hl.dispatch(hl.dsp.window.float({ action = "set", window = win }))
  end
end

-- Put a window back at a remembered geometry. Only when the monitor it was on
-- still exists — otherwise Hyprland's own re-placement is the better guess.
local function apply_remembered_geometry(win, r)
  if r.w == nil or r.w <= 0 or r.h == nil or r.h <= 0 then
    return
  end
  local mon = (r.mon ~= nil and r.mon ~= "") and hl.get_monitor(r.mon) or nil
  if mon == nil then
    return
  end
  -- Resize first, then move, so the window lands on its exact old spot.
  hl.dispatch(hl.dsp.window.resize({ x = r.w, y = r.h, window = win }))
  hl.dispatch(hl.dsp.window.move({ x = r.x or 0, y = r.y or 0, window = win }))
end

local function apply_remembered_state(win, r)
  if r.fs ~= 0 then
    if mode == "float" then
      ensure_float(win)
    end
    hl.dispatch(hl.dsp.window.fullscreen({
      mode = r.fs == 2 and "fullscreen" or "maximized",
      action = "set",
      window = win,
    }))
  elseif r.w ~= nil and r.w > 0 then
    apply_remembered_geometry(win, r)
  end
end

-- Re-apply remembered state where a window no longer matches it. Runs a few
-- times after monitor events, because the re-arrangement settles
-- asynchronously over a couple of seconds (and passes that find nothing to do
-- are cheap no-ops).
local function restore_pass()
  if not remember_windows then
    return
  end
  for _, win in ipairs(hl.get_windows() or {}) do
    if window_is_alive(win) and not win.pinned then
      local r = mem_by_address[win.address]
      if r ~= nil then
        local fs_now = win.fullscreen or 0
        -- The lock-screen bug: maximized/fullscreen before the monitor event,
        -- plain floating afterwards — put the state back.
        if r.fs ~= 0 and fs_now ~= r.fs then
          apply_remembered_state(win, r)
        elseif r.fs == 0 and fs_now == 0 and win.floating then
          -- Plain float driven off its monitor (or collapsed to nothing)
          -- by the re-arrangement: put it back where it was.
          local at, size, mon = win.at, win.size, win.monitor
          if at ~= nil and size ~= nil and mon ~= nil and r.w ~= nil and r.w > 0 then
            local outside = at.x + size.x <= mon.x or at.x >= mon.x + mon.width
                or at.y + size.y <= mon.y or at.y >= mon.y + mon.height
            local collapsed = (size.x or 0) <= 1 or (size.y or 0) <= 1
            if outside or collapsed then
              apply_remembered_geometry(win, r)
            end
          end
        end
      end
    end
  end
end

-- Debug/manual use: `hyprctl eval "hyprland_layout_restore_windows"`.
function hyprland_layout_restore_windows()
  restore_pass()
  return true
end

-- Monitors (dis)appear on suspend/resume, docking and screen changes — and
-- that re-arrangement is what forgets maximized/fullscreen state. Freeze live
-- sampling while the passes run, so the dropped state never overwrites what
-- we remember, then re-apply a few times (the re-arrangement settles
-- asynchronously over a couple of seconds).
local function restore_after_monitor_event()
  if not remember_windows then
    return
  end
  -- If a maximized/fullscreen state was lost a moment BEFORE this event
  -- arrived (the drop races the events), the sampler already recorded the
  -- loss: undo it, then freeze so late drops can't be recorded either.
  local now = os.time()
  for _, r in pairs(mem_by_address) do
    if r.pfs ~= nil and r.pfs ~= 0 and r.fs == 0 and (now - (r.changed or 0)) <= 3 then
      r.fs, r.pfs, r.changed = r.pfs, nil, nil
      memory_dirty = true
    end
  end
  memory_frozen_until = os.time() + 8
  for _, delay in ipairs({ 300, 900, 2200, 4000 }) do
    hl.timer(restore_pass, { timeout = delay, type = "oneshot" })
  end
end

hl.on("monitor.added", restore_after_monitor_event)
hl.on("monitor.removed", restore_after_monitor_event)
hl.on("monitor.layout_changed", restore_after_monitor_event)
hl.on("workspace.move_to_monitor", restore_after_monitor_event)

-- Reopen at the remembered size/position/state: only for the FIRST window of
-- an app (dialogs and overlays of an already-running app keep their own ideas
-- about where they belong). Geometry only applies to floating windows; the
-- maximized/fullscreen state applies in float and own modes.
local function schedule_open_restore(win)
  if not remember_windows or (mode ~= "float" and mode ~= "own") then
    return
  end
  local class = win.initial_class or win.class
  if class == nil or class == "" then
    return
  end
  for _, other in ipairs(hl.get_windows() or {}) do
    if other.address ~= win.address and (other.initial_class or other.class) == class then
      return
    end
  end

  local addr = win.address
  local remembered = mem_by_class[class]
  if remembered == nil then
    return
  end

  local applied = false
  local function pass()
    if applied then
      return
    end
    local target = nil
    for _, w in ipairs(hl.get_windows() or {}) do
      if w.address == addr then
        target = w
        break
      end
    end
    if not window_is_alive(target) or (target.fullscreen or 0) ~= 0 then
      return -- gone again, or the app made it fullscreen itself: leave it be
    end
    if mode == "float" then
      ensure_float(target)
    end
    apply_remembered_state(target, remembered)
    sample_window(target)
    applied = true
  end

  -- Apps often adjust themselves right after mapping; two short passes catch
  -- windows that weren't ready on the first try without re-fighting later
  -- app-initiated changes.
  hl.timer(pass, { timeout = 150, type = "oneshot" })
  hl.timer(pass, { timeout = 700, type = "oneshot" })
end

hl.on("window.open", function(w)
  if w ~= nil then
    sample_window(w)
    schedule_open_restore(w)
  end
end)

hl.on("window.fullscreen", function(w)
  if w ~= nil then
    sample_window(w)
  end
end)

hl.on("window.active", function(w)
  if window_is_alive(w) then
    sample_window(w)
  end
end)

hl.on("window.close", function(w)
  if w ~= nil then
    sample_window(w, true) -- deliberate close: capture the final state even mid-freeze
    flush_memory(true)
  end
end)

hl.on("window.destroy", function()
  flush_memory(true)
end)

hl.on("hyprland.shutdown", function()
  sample_all_windows()
  flush_memory(true)
end)

if remember_windows then
  os.execute("mkdir -p " .. state_dir)
  load_memory()
  -- No move/resize Lua events exist, so poll: cheap live tracking of drags
  -- and resizes, plus debounced persistence.
  hl.timer(function()
    sample_all_windows()
    flush_memory(false)
  end, { timeout = 2000, type = "repeat" })
end

-- ------------------------------------------------------ window cycling ----
-- Plain cycle_next does not work under Monocle; cycle with layout messages.
-- It also only alternates between windows of the same kind as the focused
-- one (floating vs tiled), so a tiled straggler — an app opened before float
-- mode was enabled, like a browser from a tiling session — can never be
-- reached: the cycle sticks on the focused float and the straggler stays
-- covered. In float mode every window is floating by definition, so float
-- the stragglers before cycling (and on focus, below) to keep Alt+Tab able
-- to reach and surface every window on the workspace.
local function float_all_on_workspace()
  local active = hl.get_active_workspace()
  if active == nil then
    return
  end
  for _, win in ipairs(hl.get_workspace_windows(active.id) or {}) do
    if not win.floating then
      hl.dispatch(hl.dsp.window.float({ action = "set", window = win }))
    end
  end
end

-- Replaces Omarchy's Alt+Tab binds with mode-aware versions.
hl.unbind("ALT + TAB")
hl.unbind("ALT + SHIFT + TAB")

o.bind("ALT + TAB", "Focus on next window", function()
  if mode == "stacked" then
    hl.dispatch(hl.dsp.layout("cyclenext"))
  else
    if mode == "float" then
      float_all_on_workspace()
    end
    hl.dispatch(hl.dsp.window.cycle_next())
    local win = hl.get_active_window()
    if win ~= nil and win.floating and not window_is_fullscreen(win) then
      hl.dispatch(hl.dsp.window.bring_to_top())
    end
  end
end)
o.bind("ALT + SHIFT + TAB", "Focus on previous window", function()
  if mode == "stacked" then
    hl.dispatch(hl.dsp.layout("cycleprev"))
  else
    if mode == "float" then
      float_all_on_workspace()
    end
    hl.dispatch(hl.dsp.window.cycle_next({ next = false }))
    local win = hl.get_active_window()
    if win ~= nil and win.floating and not window_is_fullscreen(win) then
      hl.dispatch(hl.dsp.window.bring_to_top())
    end
  end
end)

-- Blind Hyper-key cycling. Stacked uses layout messages; other modes cycle
-- windows normally and raise the focused one on top.
local function cycle_window(forward)
  return function()
    if mode == "stacked" then
      hl.dispatch(hl.dsp.layout(forward and "cyclenext" or "cycleprev"))
    else
      if mode == "float" then
        float_all_on_workspace()
      end
      hl.dispatch(hl.dsp.window.cycle_next({ next = forward }))
      local win = hl.get_active_window()
      if win ~= nil and win.floating and not window_is_fullscreen(win) then
        hl.dispatch(hl.dsp.window.bring_to_top())
      end
    end
  end
end

o.bind("MOD3 + TAB", "Next window", cycle_window(true))
o.bind("MOD3 + SHIFT + TAB", "Previous window", cycle_window(false))

-- -------------------------------------------- raise focused window --------
hl.on("window.active", function(w)
  if not window_is_alive(w) then
    return
  end

  if mode ~= "float" then
    -- Other modes: raise only ordinary floating windows — z-swapping
    -- fullscreen/tiled windows desyncs input from rendering.
    if w.floating and not window_is_fullscreen(w) then
      hl.dispatch(hl.dsp.window.alter_zorder({ mode = "top", window = w }))
    end
    return
  end

  -- float mode: the focused window must end up visible, whatever it is.
  -- Tiled stragglers (opened in other modes) adopt the mode when focused.
  if not w.floating then
    hl.dispatch(hl.dsp.window.float({ action = "set", window = w }))
  end

  if window_is_fullscreen(w) then
    -- Fullscreen windows own the top render layer, but a float raised
    -- earlier (by a previous focus) can stay stuck above it — the input/
    -- rendering desync. Sink the other floats so the fullscreen window
    -- shows through and stays clickable.
    local ws = w.workspace
    if ws ~= nil then
      for _, win in ipairs(hl.get_workspace_windows(ws.id) or {}) do
        if win.address ~= w.address and win.floating and not window_is_fullscreen(win) then
          hl.dispatch(hl.dsp.window.alter_zorder({ mode = "bottom", window = win }))
        end
      end
    end
  else
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
  if win == nil then
    return
  end
  -- Remember the normal size/position right before toggling: while maximized
  -- the window shows work-area geometry, and this is what a later restore
  -- (lock-screen wake, app reopen) brings back. User-initiated: sample even
  -- if a monitor-event freeze is active.
  sample_window(win, true)
  if mode == "float" and not win.floating then
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
