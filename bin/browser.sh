#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source /opt/always-green/bin/lib.sh

# Stale locks after an unclean stop make Chrome refuse to start.
rm -f "$PROFILE_DIR"/Singleton*

exec google-chrome \
  --user-data-dir="$PROFILE_DIR" \
  --remote-debugging-port=9222 \
  --no-first-run --no-default-browser-check \
  --disable-session-crashed-bubble --hide-crash-restore-bubble \
  --password-store=basic \
  --disable-background-timer-throttling \
  --disable-renderer-backgrounding \
  --disable-backgrounding-occluded-windows \
  --window-position=0,0 --window-size="${SCREEN_W},${SCREEN_H}" \
  "$TEAMS_URL"
