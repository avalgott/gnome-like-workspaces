#!/usr/bin/env bash
# Install the Hyprland side of the avalgott.gnome-like-workspaces plugin.
#
# Installs ~/.config/hypr/gnome-desktops.lua (mechanism code, always
# overwritten -- this is the update path), creates ~/.config/hypr/desktops.lua
# (settings; never overwritten; legacy monolithic versions are migrated) and
# wires the widget into the bar in place of the stock omarchy.workspaces.
# Safe to re-run. `install.sh uninstall` removes the Hyprland side.
#
# Usage: install.sh [--yes] | uninstall

set -euo pipefail

ID="avalgott.gnome-like-workspaces"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HYPR_DIR="$HOME/.config/hypr"
SETTINGS_FILE="$HYPR_DIR/desktops.lua"
CODE_FILE="$HYPR_DIR/gnome-desktops.lua"
HYPRLAND_LUA="$HYPR_DIR/hyprland.lua"
STATE_FILE="$HYPR_DIR/desktops.enabled"

TOGGLE_ID="avalgott.gnome-like-workspaces-toggle"
TOGGLE_DIR="$HOME/.config/omarchy/plugins/$TOGGLE_ID"

ASSUME_YES=0
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --yes | -y) ASSUME_YES=1 ;;
    uninstall) UNINSTALL=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 1 ;;
  esac
done

confirm() {
  local prompt="$1"
  (( ASSUME_YES )) && return 0
  if [[ -t 0 ]]; then
    local answer
    read -r -p "$prompt [y/N] " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
  else
    echo "refusing to continue without confirmation; pass --yes" >&2
    exit 1
  fi
}

# --- environment probes -------------------------------------------------------

HL_UP=0
MONITORS_JSON=""
if hyprctl monitors -j >/dev/null 2>&1; then
  HL_UP=1
  MONITORS_JSON="$(hyprctl monitors -j)"
fi

SHELL_UP=0
if omarchy-shell shell ping >/dev/null 2>&1; then
  SHELL_UP=1
fi

SETTINGS_CHANGED=0

# --- helpers ------------------------------------------------------------------

# "{ \"name1\", \"name2\" }" for the settings file, or "{}" when unknown.
detect_monitors_list() {
  local names
  names="$(printf '%s' "$MONITORS_JSON" |
    jq -r '[.[] | select((.disabled != true) and (.name != "HEADLESS-1"))] | sort_by(.x) | map(.name)' || true)"
  if [[ -z "$names" || "$names" == "[]" ]]; then
    printf '{}'
  else
    printf '%s' "$names" |
      jq -r '"{ " + (map("\"" + . + "\"") | join(", ")) + " }"'
  fi
}

# Value of `FIELD = <digits>` in the (legacy or new) settings file, or "".
settings_number() {
  local field="$1"
  grep -oE "^[[:space:]]*${field}[[:space:]]*=[[:space:]]*[0-9]+" "$SETTINGS_FILE" 2>/dev/null |
    head -1 | grep -oE '[0-9]+$' || true
}

# "{ \"name1\", \"name2\" }" from a legacy `MONITOR_ORDER = { ... }` line, or "{}".
legacy_monitors_list() {
  local names
  names="$(grep 'MONITOR_ORDER' "$SETTINGS_FILE" 2>/dev/null | grep -oE '"[^"]+"' |
    jq -R -s -c 'split("\n") | map(select(length > 0))' || true)"
  if [[ -z "$names" || "$names" == "[]" ]]; then
    printf '{}'
  else
    printf '%s' "$names" | jq -c '"{ " + join(", ") + " }"'
  fi
}

# Render the settings template with the given values.
generate_settings() {
  local count="$1" stride="$2" monitors_list="$3"
  sed -E \
    -e "s/(^[[:space:]]*count[[:space:]]*=[[:space:]]*)[0-9]+/\1${count}/" \
    -e "s/(^[[:space:]]*stride[[:space:]]*=[[:space:]]*)[0-9]+/\1${stride}/" \
    -e "s|(^[[:space:]]*monitors[[:space:]]*=[[:space:]]*)\{[^}]*\},|\1${monitors_list},|" \
    "$SRC_DIR/config.example.lua"
}

validate_settings() {
  local count="$1" stride="$2"
  if [[ -z "$count" || -z "$stride" ]]; then
    echo "warning: could not read count/stride from $SETTINGS_FILE." >&2
    echo "         The bar widget parses `count = N` / `stride = N` lines; keep" >&2
    echo "         each on its own line in the documented form." >&2
    return
  fi
  if (( count >= stride )); then
    echo "warning: count ($count) must be less than stride ($stride)." >&2
    echo "         workspace = slot * stride + desktop, so the stride must leave" >&2
    echo "         room for every desktop number." >&2
  fi
}

# --- uninstall ----------------------------------------------------------------

uninstall() {
  echo "Uninstalling $ID (Hyprland side)..."
  if (( SHELL_UP )); then
    omarchy plugin disable "$ID" >/dev/null 2>&1 && echo "Disabled $ID in the bar." || true
    omarchy plugin disable "$TOGGLE_ID" >/dev/null 2>&1 && echo "Disabled $TOGGLE_ID in the bar." || true
  fi
  if [[ -d "$TOGGLE_DIR" && ! -L "$TOGGLE_DIR" ]]; then
    if [[ -d "$TOGGLE_DIR/.git" ]]; then
      echo "Leaving $TOGGLE_DIR alone: it is a git repository." >&2
    else
      rm -rf -- "$TOGGLE_DIR"
      echo "Removed $TOGGLE_DIR."
    fi
  elif [[ -L "$TOGGLE_DIR" ]]; then
    rm -f -- "$TOGGLE_DIR"
    echo "Removed symlink $TOGGLE_DIR."
  fi
  if [[ -f "$STATE_FILE" ]]; then
    rm -f "$STATE_FILE"
    echo "Removed $STATE_FILE."
  fi
  local ts
  ts="$(date +%s)"
  if [[ -f "$SETTINGS_FILE" ]]; then
    mv "$SETTINGS_FILE" "$SETTINGS_FILE.bak.$ts"
    echo "Moved $SETTINGS_FILE to $SETTINGS_FILE.bak.$ts"
  fi
  if [[ -f "$CODE_FILE" ]]; then
    mv "$CODE_FILE" "$CODE_FILE.bak.$ts"
    echo "Moved $CODE_FILE to $CODE_FILE.bak.$ts"
  fi
  if [[ -f "$HYPRLAND_LUA" ]] && grep -q '^require("hypr\.desktops")$' "$HYPRLAND_LUA"; then
    sed -i '/^require("hypr\.desktops")$/d' "$HYPRLAND_LUA"
    echo "Removed the require line from $HYPRLAND_LUA."
  fi
  if (( HL_UP )); then
    hyprctl reload
  fi
  echo
  echo "To remove the bar widget entirely:"
  echo "  omarchy plugin remove $ID --yes"
  echo "To get the stock workspace buttons back:"
  echo "  omarchy plugin enable omarchy.workspaces"
  exit 0
}

(( UNINSTALL )) && uninstall

# --- install ------------------------------------------------------------------

[[ -f "$SRC_DIR/config.example.lua" && -f "$SRC_DIR/hypr/gnome-desktops.lua" ]] || {
  echo "error: $SRC_DIR does not look like the $ID repo (missing config.example.lua or hypr/gnome-desktops.lua)" >&2
  exit 1
}

echo "Installing $ID from $SRC_DIR"
mkdir -p "$HYPR_DIR"

# 1. Mechanism code -- always overwritten; this is how updates reach Hyprland.
cp "$SRC_DIR/hypr/gnome-desktops.lua" "$CODE_FILE"

# 2. Settings file, three ways:
if [[ -f "$SETTINGS_FILE" ]] &&
  grep -q 'MONITOR_STRIDE' "$SETTINGS_FILE" &&
  grep -q 'function Desktops' "$SETTINGS_FILE"; then
  # Legacy: the old monolithic mechanism. Back up, convert to settings-only.
  confirm "$SETTINGS_FILE is the old monolithic mechanism. Back it up and convert it to a settings-only file?" || exit 0
  ts="$(date +%s)"
  cp "$SETTINGS_FILE" "$SETTINGS_FILE.bak.$ts"
  COUNT="$(settings_number DESKTOP_COUNT)"; COUNT="${COUNT:-5}"
  STRIDE="$(settings_number MONITOR_STRIDE)"; STRIDE="${STRIDE:-10}"
  generate_settings "$COUNT" "$STRIDE" "$(legacy_monitors_list)" > "$SETTINGS_FILE"
  SETTINGS_CHANGED=1
  echo "Migrated: backed up to $SETTINGS_FILE.bak.$ts with count=$COUNT stride=$STRIDE."
  echo "To roll back: cp $SETTINGS_FILE.bak.$ts $SETTINGS_FILE && rm $CODE_FILE && hyprctl reload"
elif [[ -f "$SETTINGS_FILE" ]] &&
  grep -q 'require("hypr.gnome-desktops")' "$SETTINGS_FILE"; then
  # New format: user-owned, left untouched.
  echo "Settings file already in place; leaving it untouched."
  validate_settings "$(settings_number count)" "$(settings_number stride)"
else
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    COUNT=5
    STRIDE=10
    MONITORS_LIST="$(detect_monitors_list)"
    if [[ "$MONITORS_LIST" == "{}" ]]; then
      echo "warning: could not detect monitors (Hyprland not running or no displays)."
      echo "         monitors = {} means every display gets a slot automatically, left to right."
    fi
  else
    # Exists but unrecognized -- ask rather than clobber.
    confirm "$SETTINGS_FILE exists but is not recognized (not legacy, not new-format). Overwrite it with a fresh settings file?" || exit 0
    COUNT=5
    STRIDE=10
    MONITORS_LIST="$(detect_monitors_list)"
  fi
  generate_settings "$COUNT" "$STRIDE" "$MONITORS_LIST" > "$SETTINGS_FILE"
  SETTINGS_CHANGED=1
  echo "Wrote settings to $SETTINGS_FILE (count=$COUNT stride=$STRIDE monitors=$MONITORS_LIST)."
fi

# 3. Load it from hyprland.lua (after Omarchy defaults, so unbinds win).
if [[ -f "$HYPRLAND_LUA" ]]; then
  if grep -Fq 'require("hypr.desktops")' "$HYPRLAND_LUA"; then
    echo "require(\"hypr.desktops\") already present in hyprland.lua."
  else
    printf '\n-- GNOME-like desktops (%s): loads after Omarchy defaults\n-- so it can unbind the per-workspace bindings it replaces.\nrequire("hypr.desktops")\n' "$ID" >> "$HYPRLAND_LUA"
    echo "Added require(\"hypr.desktops\") to hyprland.lua."
  fi
else
  echo "warning: $HYPRLAND_LUA not found; add: require(\"hypr.desktops\")" >&2
fi

# 4. Reload Hyprland and fail loudly on config errors.
if (( HL_UP )); then
  hyprctl reload
  errors="$(hyprctl configerrors)"
  if [[ -n "$(printf '%s' "$errors" | tr -d '[:space:]')" ]]; then
    echo "hyprctl configerrors after reload:" >&2
    printf '%s\n' "$errors" >&2
    echo "Restore the previous settings file and re-run, or fix the settings." >&2
    exit 1
  fi
  echo "Hyprland config clean."
else
  echo "Hyprland is not running; reload deferred to login."
fi

# 4b. Toggle widget plugin: a plain directory (no git), so install.sh is its
#     update path. A full replace means no stale files can survive an update;
#     the dir holds only shipped files, never user data. Never touch a git
#     repository the user may have swapped in.
if [[ -d "$SRC_DIR/toggle" ]]; then
  if [[ -d "$TOGGLE_DIR" && ! -L "$TOGGLE_DIR" && -d "$TOGGLE_DIR/.git" ]]; then
    echo "warning: $TOGGLE_DIR is a git repository; leaving it untouched." >&2
  else
    [[ -L "$TOGGLE_DIR" ]] && rm -f -- "$TOGGLE_DIR"
    rm -rf -- "$TOGGLE_DIR"
    mkdir -p "$TOGGLE_DIR"
    cp -r "$SRC_DIR/toggle/." "$TOGGLE_DIR/"
    # The repo ships the toggle manifest as manifest.json.in (the marketplace
    # rule is one plugin manifest per repository, so the toggle dir must not
    # carry a second manifest.json while it sits in the repo). Install it as
    # the real thing here; the fallback covers pre-rename checkouts.
    if [[ -f "$SRC_DIR/toggle/manifest.json.in" ]]; then
      cp "$SRC_DIR/toggle/manifest.json.in" "$TOGGLE_DIR/manifest.json"
    elif [[ -f "$SRC_DIR/toggle/manifest.json" ]]; then
      cp "$SRC_DIR/toggle/manifest.json" "$TOGGLE_DIR/manifest.json"
    fi
    rm -f "$TOGGLE_DIR/manifest.json.in"
    chmod +x "$TOGGLE_DIR/toggle.sh"
    if omarchy plugin validate "$TOGGLE_DIR" >/dev/null 2>&1; then
      echo "Installed $TOGGLE_ID (toggle menu)."
    else
      echo "warning: omarchy plugin validate failed for $TOGGLE_DIR" >&2
    fi
  fi
else
  echo "warning: $SRC_DIR/toggle not found; the toggle menu will not be installed." >&2
fi

# 4c. Toggle state: a missing file means enabled.
if [[ ! -f "$STATE_FILE" ]]; then
  printf 'true\n' > "$STATE_FILE"
  echo "Created $STATE_FILE (GNOME-like desktops enabled)."
fi

# 5. Bar widget: put ours in place, then retire the stock workspaces widget
#    (and any clone of it) so the bar shows exactly one set of buttons. The
#    toggle menu is placed in both modes; the workspace-widget swap only
#    happens while the plugin is toggled ON (a machine toggled OFF keeps the
#    stock widget -- the state file is the user's choice).
if (( SHELL_UP )); then
  omarchy-shell shell rescanPlugins >/dev/null

  # The toggle menu sits left of omarchy.agents: right section, after the
  # tray. `bar put` falls back gracefully when omarchy.tray is absent.
  omarchy bar put "$TOGGLE_ID" --section right --after omarchy.tray >/dev/null 2>&1 || \
    omarchy bar put "$TOGGLE_ID" --section right >/dev/null 2>&1 || \
    echo "warning: could not place $TOGGLE_ID in the bar" >&2
  # put only adds; it leaves a widget already on the bar wherever it is, so
  # enforce the position with move (e.g. an earlier `plugin add` answer put
  # the widget somewhere else).
  omarchy bar move "$TOGGLE_ID" --section right --after omarchy.tray >/dev/null 2>&1 || \
    omarchy bar move "$TOGGLE_ID" --section right >/dev/null 2>&1 || true

  if grep -qE '^[[:space:]]*false[[:space:]]*$' "$STATE_FILE" 2>/dev/null; then
    echo "$ID is toggled off; leaving the stock workspaces widget in place."
  else
    # put only adds; move enforces the section (a `plugin add` placement
    # answer, or anything else, may have left the widget elsewhere).
    omarchy bar put "$ID" --section left || true
    omarchy bar move "$ID" --section left || true

    for _ in 1 2 3 4 5; do
      stale="$(omarchy plugin list --json | jq -r \
        '.[] | select(.enabled == true) | select(.id == "omarchy.workspaces" or .clonedFrom == "omarchy.workspaces") | .id' || true)"
      [[ -z "$stale" ]] && break
      for sid in $stale; do
        echo "Disabling $sid (replaced by $ID)..."
        omarchy plugin disable "$sid" >/dev/null
      done
    done

    if omarchy plugin list --json | jq -e --arg id "$ID" 'any(.[]; .id == $id and .enabled == true)' >/dev/null; then
      echo "$ID enabled in the bar."
    else
      echo "warning: $ID does not report as enabled; check: omarchy plugin list --json" >&2
    fi
  fi
else
  echo "omarchy-shell is not running; bar setup deferred."
  echo "Run this script again in a graphical session to finish."
fi

# 6. The shell only reads the workspace list at startup, so a settings change
#    (new workspaces) needs a restart of the bar shell.
if (( SETTINGS_CHANGED && SHELL_UP )); then
  echo "Settings changed; restarting the shell so the bar re-reads the workspace list..."
  omarchy restart shell
fi

# 7. Summary.
echo
echo "Done. Settings live in $SETTINGS_FILE (yours to edit):"
echo "  - change count/stride/monitors, then: hyprctl reload"
echo "  - after changing the desktop count, also: omarchy restart shell"
echo "Toggling stock vs GNOME-like behavior:"
echo "  click the toggle icon next to the agents (or: bash $TOGGLE_DIR/toggle.sh enable|disable|status)"
echo "Updates:"
echo "  omarchy plugin update $ID --yes && bash ~/.config/omarchy/plugins/$ID/install.sh"
echo "  (install.sh also refreshes the toggle widget -- no separate update step)"
echo "Uninstall:"
echo "  bash ~/.config/omarchy/plugins/$ID/install.sh uninstall"
echo "  omarchy plugin remove $ID --yes"
