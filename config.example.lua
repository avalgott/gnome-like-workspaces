-- GNOME-like desktops: settings for the avalgott.gnome-like-workspaces plugin.
--
-- This file is YOURS: install.sh creates it once and never overwrites it.
-- The bar widget parses `count` and `stride` out of this file, so keep each
-- of those on its own line in the `key = value` form below.
--
-- Constraint: count < stride. A desktop is workspace `slot * stride + number`,
-- so the stride must leave room for every desktop number.
--
-- To change the number of desktops: edit `count`, then run `hyprctl reload`
-- followed by `omarchy restart shell` (the bar only reads the workspace list
-- on startup). The keybindings and workspace rules regenerate on reload.
--
-- The bar's toggle menu keeps its on/off state in ~/.config/hypr/
-- desktops.enabled ("false" = stock Omarchy behavior; written only by
-- toggle.sh). This file never carries it.

local settings = {
  count = 5,
  stride = 10,
  -- Pinned monitor order: slot 0 = first entry (workspaces 1..count),
  -- slot 1 = second (workspaces stride+1..stride+count), and so on.
  -- Monitors not listed here still get a slot automatically, left to right.
  monitors = { "eDP-2", "HDMI-A-1" },
}

require("hypr.gnome-desktops").setup(settings)
