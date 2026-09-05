#!/usr/bin/env bash
# Toggle GNOME-like desktops on/off, both sides: the Hyprland module (bindings
# + workspace rules) and the bar widgets. Invoked by the toggle menu widget;
# installed by install.sh to
# ~/.config/omarchy/plugins/avalgott.gnome-like-workspaces-toggle/toggle.sh.
#
# Usage: toggle.sh enable|disable|status

set -euo pipefail

MAIN_ID="avalgott.gnome-like-workspaces"
STOCK_ID="omarchy.workspaces"
HYPR_DIR="$HOME/.config/hypr"
STATE_FILE="$HYPR_DIR/desktops.enabled"
SETTINGS_FILE="$HYPR_DIR/desktops.lua"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/avalgott-gnome-desktops-toggle.lock"

action="${1:-status}"

log() { echo "gnome-desktops-toggle: $*" >&2; }

hl_up() { hyprctl monitors -j >/dev/null 2>&1; }
shell_up() { omarchy-shell shell ping >/dev/null 2>&1; }

# Missing state file = enabled.
state_is() {
  local want="$1"
  [[ ! -f "$STATE_FILE" ]] && { [[ "$want" == true ]]; return; }
  grep -qE '^[[:space:]]*'"$want"'[[:space:]]*$' "$STATE_FILE"
}

stride_value() {
  grep -oE '^[[:space:]]*stride[[:space:]]*=[[:space:]]*[0-9]+' "$SETTINGS_FILE" 2>/dev/null |
    head -1 | grep -oE '[0-9]+$' || echo 10
}

set_state() {
  if ! printf '%s\n' "$1" > "$STATE_FILE"; then
    log "error: cannot write $STATE_FILE"
    exit 1
  fi
}

# Reload and, if the config broke, restore the previous state and reload back.
reload_or_rollback() {
  local old="$1"
  local errors
  hyprctl reload
  errors="$(hyprctl configerrors)"
  if [[ -n "$(printf '%s' "$errors" | tr -d '[:space:]')" ]]; then
    log "hyprctl configerrors after reload:"
    printf '%s\n' "$errors" >&2
    log "restoring previous state ($old) and reloading..."
    set_state "$old"
    hyprctl reload || true
    exit 1
  fi
}

# Retry `hyprctl eval EXPR` until exit 0: right after a reload the Lua state
# may still be the old one, where Desktops does not exist (exit 7).
eval_until_ready() {
  local expr="$1" tries="${2:-10}" i
  for i in $(seq 1 "$tries"); do
    if hyprctl eval "$expr" >/dev/null 2>&1; then return 0; fi
    sleep 0.2
  done
  log "warning: 'hyprctl eval $expr' never succeeded"
  return 1
}

# Disable every enabled widget whose id or clonedFrom matches $1.
disable_stale_widgets() {
  local selector="$1" sid stale
  for _ in 1 2 3 4 5; do
    stale="$(omarchy plugin list --json | jq -r \
      '.[] | select(.enabled == true) | select(.id == "'"$selector"'" or .clonedFrom == "'"$selector"'") | .id' || true)"
    [[ -z "$stale" ]] && break
    for sid in $stale; do
      log "disabling $sid..."
      omarchy plugin disable "$sid" >/dev/null 2>&1 || true
    done
  done
}

# ==== disable: GNOME-like -> stock ====
disable() {
  if state_is false; then log "already disabled"; exit 0; fi
  [[ -w "$HYPR_DIR" ]] || { log "error: $HYPR_DIR is not writable"; exit 1; }

  if ! hl_up; then
    set_state false
    log "Hyprland is not running; recorded disabled state for next login."
    exit 0
  fi

  # 1. Remember where every monitor is, left to right, and who has keyboard focus.
  mapfile -t MON_NAMES < <(hyprctl monitors -j | jq -r \
    '[.[] | select((.disabled != true) and (.name != "HEADLESS-1"))] | sort_by(.x) | .[].name')
  mapfile -t MON_IDS < <(hyprctl monitors -j | jq -r \
    '[.[] | select((.disabled != true) and (.name != "HEADLESS-1"))] | sort_by(.x) | .[].activeWorkspace.id')
  FOCUSED="$(hyprctl monitors -j | jq -r '.[] | select(.focused == true) | .name' | head -1)"

  local stride
  stride="$(stride_value)"
  local -a desktops
  local i
  for i in "${!MON_IDS[@]}"; do
    local id="${MON_IDS[$i]}"
    if [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 )); then
      desktops[$i]=$(( (id - 1) % stride + 1 ))
    else
      desktops[$i]=1   # special/scratchpad active -> assume desktop 1
    fi
  done
  (( ${#desktops[@]} > 0 )) || desktops[0]=1

  # 2. Merge secondary blocks onto the primary while the rules still pin
  #    1..count there. The module may already be inactive: exit 7 is fine.
  hyprctl eval 'Desktops.flatten()' >/dev/null 2>&1 || true

  # 3. Record the new state, reload; roll back on config errors.
  set_state false
  reload_or_rollback true

  # 4. Point every monitor at a stock-reachable workspace (1..10): leftmost
  #    keeps its desktop, next takes desktop+1, ... decrement on collision so
  #    no two monitors show the same workspace. End on the user's monitor.
  if (( ${#MON_NAMES[@]} > 0 )); then
    local primary="${desktops[0]:-1}" used="" target
    for i in "${!MON_NAMES[@]}"; do
      if (( i == 0 )); then
        target="$primary"
      else
        target=$(( primary + i ))
        (( target > 10 )) && target=10
        while grep -qw "$target" <<<"$used" && (( target > 1 )); do
          target=$(( target - 1 ))
        done
      fi
      used="$used $target"
      # Hyprland 0.56 evaluates `hyprctl dispatch` arguments as Lua, so bare
      # `focusmonitor`/`workspace` fail; use the hl.dsp.focus dispatcher form.
      hyprctl dispatch 'hl.dsp.focus({ monitor = "'"${MON_NAMES[$i]}"'" })' >/dev/null || true
      hyprctl dispatch 'hl.dsp.focus({ workspace = "'"$target"'" })' >/dev/null || true
    done
    if [[ -n "$FOCUSED" ]]; then
      hyprctl dispatch 'hl.dsp.focus({ monitor = "'"$FOCUSED"'" })' >/dev/null || true
    fi
  fi

  # 5. Swap the bar widgets: ours (and clones) out, stock in -- stock has no
  #    defaultSection in its manifest, so the section must be explicit (else
  #    it lands in center).
  if shell_up; then
    disable_stale_widgets "$MAIN_ID"
    if ! omarchy plugin enable "$STOCK_ID" --section left >/dev/null 2>&1; then
      omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
      omarchy plugin enable "$STOCK_ID" --section left >/dev/null 2>&1 || \
        log "warning: could not enable $STOCK_ID (removed from the machine?) - stock keybindings still work"
    fi
  fi
  log "disabled: stock Omarchy workspaces are back."
}

# ==== enable: stock -> GNOME-like ====
enable() {
  if state_is true; then log "already enabled"; exit 0; fi
  [[ -w "$HYPR_DIR" ]] || { log "error: $HYPR_DIR is not writable"; exit 1; }

  if ! hl_up; then
    set_state true
    log "Hyprland is not running; recorded enabled state for next login."
    exit 0
  fi

  # 1. Record the new state, reload; roll back on config errors.
  set_state true
  reload_or_rollback false

  # 2. Wait for the fresh Lua state (Desktops only exists when enabled), fold
  #    pool leftovers onto their block's last desktop, sync every monitor to
  #    the focused monitor's desktop.
  eval_until_ready 'Desktops.merge_stock()' || true
  eval_until_ready 'Desktops.switch(Desktops.current())' || true

  # 3. Swap the bar widgets: stock out, ours in at its usual spot.
  if shell_up; then
    disable_stale_widgets "$STOCK_ID"
    if ! omarchy plugin enable "$MAIN_ID" --section left --after omarchy.menu >/dev/null 2>&1; then
      # --after errors hard when omarchy.menu is absent; retry without it.
      omarchy plugin enable "$MAIN_ID" --section left >/dev/null 2>&1 || {
        omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
        omarchy plugin enable "$MAIN_ID" --section left >/dev/null 2>&1 || \
          log "warning: could not enable $MAIN_ID in the bar"
      }
    fi
  fi
  log "enabled: GNOME-like desktops are back."
}

status() { if state_is false; then echo "disabled"; else echo "enabled"; fi; }

# Serialize: two fast menu clicks become last-click-wins instead of two
# interleaved toggles fighting over reload.
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "another toggle is running; waiting up to 15s..."
  flock -w 15 9 || { log "error: timed out waiting for the toggle lock"; exit 1; }
fi

case "$action" in
  enable)  enable ;;
  disable) disable ;;
  status)  status ;;
  *) echo "usage: $0 enable|disable|status" >&2; exit 1 ;;
esac
