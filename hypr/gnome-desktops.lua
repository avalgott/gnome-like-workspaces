-- GNOME-style desktops: one keypress moves every monitor at once.
-- Mechanism code for the avalgott.gnome-like-workspaces plugin.
--
-- This file is installed by install.sh to ~/.config/hypr/gnome-desktops.lua
-- and OVERWRITTEN on every install.sh run, so it carries no settings.
-- Settings live in ~/.config/hypr/desktops.lua (the user's file). The bar
-- toggle's state lives in ~/.config/hypr/desktops.enabled ("false" makes
-- this module register nothing, restoring stock Omarchy behavior):
--
--     local settings = {
--       count    = 5,          -- number of desktops
--       stride   = 10,         -- workspace ids per monitor block (count < stride)
--       monitors = { "eDP-2", "HDMI-A-1" },  -- pinned slot order
--     }
--     require("hypr.gnome-desktops").setup(settings)
--
-- Hyprland puts a workspace on exactly one monitor, so a "desktop" here is a
-- set of workspaces -- one per monitor -- that get switched together. Each
-- monitor owns a block of ids: workspace = slot * stride + desktop.
--
--   eDP-2    (slot 0)  desktops 1-5 -> workspaces  1-5
--   HDMI-A-1 (slot 1)  desktops 1-5 -> workspaces 11-15

local M = {}

-- The bar toggle writes ~/.config/hypr/desktops.enabled ("true"/"false",
-- written only by toggle.sh). "false" makes setup() register nothing, so
-- Omarchy's stock bindings and workspace behavior stay in charge. A missing
-- file means enabled, so machines that never used the toggle are unaffected.
local function toggle_disabled()
  local home = os.getenv("HOME")
  if not home or home == "" then
    return false
  end

  local file = io.open(home .. "/.config/hypr/desktops.enabled", "r")
  if not file then
    return false
  end

  local content = file:read("*a")
  file:close()
  return content ~= nil and content:match("^%s*false%s*$") ~= nil
end

function M.setup(settings)
  if M._configured then
    return
  end
  M._configured = true

  -- Disabled via the bar toggle: register nothing. Stock Omarchy bindings
  -- and workspace behavior stay in charge.
  if toggle_disabled() then
    return
  end

  settings = settings or {}
  local count = settings.count or 5
  local stride = settings.stride or 10
  local monitors = settings.monitors or {}

  -- Monitors named in `monitors` keep their slot across replugs. Anything
  -- else takes the next free slot, ordered left to right, so an unrecognized
  -- display still gets its own desktops without a config change.
  local function slots()
    local taken, slot_of = {}, {}

    for index, name in ipairs(monitors) do
      taken[index - 1] = true
      slot_of[name] = index - 1
    end

    local unlisted = {}
    for _, monitor in ipairs(hl.get_monitors()) do
      if not slot_of[monitor.name] then
        unlisted[#unlisted + 1] = monitor
      end
    end
    table.sort(unlisted, function(left, right) return left.position.x < right.position.x end)

    local next_slot = 0
    for _, monitor in ipairs(unlisted) do
      while taken[next_slot] do
        next_slot = next_slot + 1
      end
      taken[next_slot] = true
      slot_of[monitor.name] = next_slot
    end

    return slot_of
  end

  local function clamp(desktop)
    return math.max(1, math.min(count, desktop))
  end

  local function desktop_of(workspace_id)
    return ((workspace_id - 1) % stride) + 1
  end

  -- Exposed as a global so the bar widget can reach it with `hyprctl eval`.
  Desktops = {}

  local last_desktop = 1

  function Desktops.current()
    local workspace = hl.get_active_workspace()

    -- Special workspaces (scratchpad) carry negative ids and aren't desktops.
    if not workspace or workspace.id < 1 then
      return last_desktop
    end

    return desktop_of(workspace.id)
  end

  function Desktops.switch(desktop)
    desktop = clamp(desktop)

    -- Read this before dispatching anything: focusing a monitor below moves the
    -- active workspace out from under us.
    local previous = Desktops.current()

    local slot_of = slots()
    local monitors = hl.get_monitors()

    -- Monitor fields read live rather than from a snapshot, so `monitor.focused`
    -- flips to false the moment we focus somebody else. Take the name now.
    local active = hl.get_active_monitor()
    local focused = active and active.name or (monitors[1] and monitors[1].name)
    if not focused then
      return
    end

    local function show(name)
      local workspace = (slot_of[name] or 0) * stride + desktop
      hl.dispatch(hl.dsp.focus({ monitor = name }))
      hl.dispatch(hl.dsp.focus({ workspace = tostring(workspace) }))
    end

    -- Non-focused monitors first, the focused one last. Omarchy sets
    -- cursor.warp_on_change_workspace, so ending on the monitor the user was
    -- already using leaves both the pointer and keyboard focus where they were.
    for _, monitor in ipairs(monitors) do
      if monitor.name ~= focused then
        show(monitor.name)
      end
    end

    show(focused)

    if previous ~= desktop then
      last_desktop = previous
    end

    return desktop
  end

  function Desktops.cycle(delta)
    return Desktops.switch(Desktops.current() + delta)
  end

  function Desktops.former()
    return Desktops.switch(last_desktop)
  end

  function Desktops.move_window(desktop, follow)
    desktop = clamp(desktop)

    local window = hl.get_active_window()
    if not window then
      return
    end

    -- Send the window to this desktop on the monitor it already occupies, so a
    -- window never hops screens just because you filed it away.
    local monitor = window.monitor
    local slot = monitor and slots()[monitor.name] or 0
    local workspace = slot * stride + desktop

    hl.dispatch(hl.dsp.window.move({ workspace = tostring(workspace), follow = false }))

    if follow then
      Desktops.switch(desktop)
    end

    return desktop
  end

  -- Unplugging a monitor leaves its block behind: Hyprland parks workspaces
  -- 11-15 on the surviving screen, but no desktop key reaches them, so those
  -- windows are stranded until the monitor comes back. Pull them onto the
  -- matching desktop of a monitor that still exists -- desktop 3 of the dead
  -- screen merges into desktop 3 of the live one, which is what GNOME does.
  -- They stay there on replug; only empty workspaces go home on their own.
  function Desktops.reclaim()
    local monitors = hl.get_monitors()
    if #monitors == 0 then
      return
    end

    local slot_of = slots()

    local live = {}
    for _, monitor in ipairs(monitors) do
      live[slot_of[monitor.name] or 0] = true
    end

    local active = hl.get_active_monitor() or monitors[1]
    local home = slot_of[active.name] or 0
    local rescued = 0

    for _, window in ipairs(hl.get_windows()) do
      local workspace = window.workspace

      if workspace and workspace.id > 0 then
        local slot = math.floor((workspace.id - 1) / stride)

        if not live[slot] then
          hl.dispatch(hl.dsp.window.move({
            window = window,
            workspace = tostring(home * stride + desktop_of(workspace.id)),
            follow = false,
          }))
          rescued = rescued + 1
        end
      end
    end

    return rescued
  end

  -- Toggle: handing the screens back to stock behavior. Stock keys reach
  -- workspaces 1..10, so pull every window off the secondary blocks (slot
  -- >= 1) onto the primary monitor's desktop-number workspace while the
  -- workspace rules still pin 1..count there. Runs BEFORE the state flip
  -- and reload, so the rules are still in force.
  function Desktops.flatten()
    local moved = 0

    for _, window in ipairs(hl.get_windows()) do
      local workspace = window.workspace

      if workspace and workspace.id > 0
        and math.floor((workspace.id - 1) / stride) >= 1 then
        hl.dispatch(hl.dsp.window.move({
          window = window,
          workspace = tostring(desktop_of(workspace.id)),
          follow = false,
        }))
        moved = moved + 1
      end
    end

    return moved
  end

  -- Toggle: coming back from stock behavior. Stock keys cover workspaces
  -- 1..10, so windows parked in the pool past `count` (6..10, 16..20, ...)
  -- would be invisible to the desktop keys. Fold each onto its own block's
  -- last desktop. Runs AFTER the state flip and reload, retried by toggle.sh
  -- until the fresh Lua state (where Desktops exists) is live.
  function Desktops.merge_stock()
    local moved = 0

    for _, window in ipairs(hl.get_windows()) do
      local workspace = window.workspace

      if workspace and workspace.id > 0 then
        local desktop = desktop_of(workspace.id)

        if desktop > count then
          hl.dispatch(hl.dsp.window.move({
            window = window,
            workspace = tostring(math.floor((workspace.id - 1) / stride) * stride + count),
            follow = false,
          }))
          moved = moved + 1
        end
      end
    end

    return moved
  end

  -- The event fires while the monitor is still being torn down, so let Hyprland
  -- finish reassigning workspaces before deciding which slots are still live.
  hl.on("monitor.removed", function()
    hl.timer(function()
      Desktops.reclaim()
    end, { timeout = 250, type = "oneshot" })
  end)

  -- Pin each block to its monitor so new windows land on the right screen and
  -- workspaces come home after a replug. Persistent keeps every desktop present
  -- in `hyprctl workspaces`, which is what lets the bar count them.
  for slot, name in ipairs(monitors) do
    for desktop = 1, count do
      hl.workspace_rule({
        workspace = tostring((slot - 1) * stride + desktop),
        monitor = name,
        default = true,
        persistent = true,
      })
    end
  end

  -- A monitor that appears mid-session should arrive on the desktop already showing.
  hl.on("monitor.added", function()
    Desktops.switch(Desktops.current())
  end)

  -- Replace Omarchy's per-workspace bindings with desktop-wide ones.
  -- See /usr/share/omarchy/default/hypr/bindings/tiling.lua -- keycode = workspace + 9.
  for workspace = 1, 10 do
    local key = "code:" .. tostring(workspace + 9)

    hl.unbind("SUPER + " .. key)
    hl.unbind("SUPER + SHIFT + " .. key)
    hl.unbind("SUPER + SHIFT + ALT + " .. key)

    -- Keys past `count` stay unbound; they would otherwise strand you on
    -- a workspace no monitor owns.
    if workspace <= count then
      local desktop = workspace

      o.bind("SUPER + " .. key, "Switch to desktop " .. desktop, function()
        Desktops.switch(desktop)
      end)

      o.bind("SUPER + SHIFT + " .. key, "Move window to desktop " .. desktop, function()
        Desktops.move_window(desktop, true)
      end)

      o.bind("SUPER + SHIFT + ALT + " .. key, "Move window silently to desktop " .. desktop, function()
        Desktops.move_window(desktop, false)
      end)
    end
  end

  for keys, delta in pairs({ ["SUPER + TAB"] = 1, ["SUPER + SHIFT + TAB"] = -1 }) do
    hl.unbind(keys)
    o.bind(keys, (delta > 0 and "Next" or "Previous") .. " desktop", function()
      Desktops.cycle(delta)
    end)
  end

  hl.unbind("SUPER + CTRL + TAB")
  o.bind("SUPER + CTRL + TAB", "Former desktop", function()
    Desktops.former()
  end)

  for keys, delta in pairs({ ["SUPER + mouse_down"] = 1, ["SUPER + mouse_up"] = -1 }) do
    hl.unbind(keys)
    o.bind(keys, "Scroll desktop " .. (delta > 0 and "forward" or "backward"), function()
      Desktops.cycle(delta)
    end)
  end
end

return M
