#!/usr/bin/env bash
# Runs during the session: nudges the mouse, watches Teams, reports to Telegram.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source /opt/always-green/bin/lib.sh

on_stop() {
  log "stopping"
  tg_photo "Session ending $(date '+%a %H:%M')"
  exit 0
}
trap on_stop TERM INT

nudge() {
  local wid x y
  # No window manager on Xvfb, so give Chrome input focus explicitly.
  wid=$(xdotool search --onlyvisible --class google-chrome 2>/dev/null | head -n1)
  [[ -n $wid ]] && xdotool windowfocus "$wid" 2>/dev/null
  x=$((SCREEN_W / 2 + RANDOM % 200 - 100))
  y=$((SCREEN_H / 2 + RANDOM % 200 - 100))
  xdotool mousemove "$x" "$y"
}

log "started, waiting ${STARTUP_GRACE_SEC}s for Teams to load"
nap "$STARTUP_GRACE_SEC"

last_state=$(health)
tg_photo "Session started $(date '+%a %H:%M'), page: $last_state"
next_shot=$(($(date +%s) + SCREENSHOT_EVERY_MIN * 60))

while true; do
  nudge

  state=$(health)
  if [[ $state != "$last_state" ]]; then
    log "state $last_state -> $state"
    case $state in
      ok) tg_photo "Recovered: Teams page is back" ;;
      browser-down) tg_text "ALERT: browser not responding (systemd will restart it)" ;;
      signed-out) tg_photo "ALERT: Teams is signed out. Log in again over VNC." ;;
    esac
    last_state=$state
  fi

  if ((SCREENSHOT_EVERY_MIN > 0 && $(date +%s) >= next_shot)); then
    tg_photo "Status $(date '+%H:%M'), page: $state"
    next_shot=$(($(date +%s) + SCREENSHOT_EVERY_MIN * 60))
  fi

  nap $((NUDGE_MIN_SEC + RANDOM % (NUDGE_MAX_SEC - NUDGE_MIN_SEC + 1)))
done
