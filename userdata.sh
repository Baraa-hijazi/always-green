#!/bin/bash
# always-green: paste into DigitalOcean > Create Droplet > Startup scripts.
# Only edit the next line. Progress log on the droplet: /var/log/always-green-setup.log
TELEGRAM_BOT_TOKEN="PASTE_BOT_TOKEN_HERE"

set -euo pipefail
exec >/var/log/always-green-setup.log 2>&1
D=/root/always-green
mkdir -p "$D/bin" "$D/systemd"

cat >"$D/setup.sh" <<'AG_EOF'
#!/usr/bin/env bash
# One-shot installer for a fresh Ubuntu 24.04 droplet. Safe to re-run.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

SRC=$(cd "$(dirname "$0")" && pwd)
DEST=/opt/always-green
[[ -f $SRC/config.env ]] || { echo "Copy config.env.example to config.env and fill it in first"; exit 1; }
# shellcheck source=/dev/null
source "$SRC/config.env"

for d in $SCHEDULE_DAYS; do
  for t in "$START_TIME" "$STOP_TIME"; do
    systemd-analyze calendar "$d $t $SCHEDULE_TZ" >/dev/null || { echo "Bad schedule: $d $t $SCHEDULE_TZ"; exit 1; }
  done
done

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -q
apt-get -o DPkg::Lock::Timeout=600 install -y -q xvfb x11vnc xdotool imagemagick curl jq ufw fonts-liberation fonts-noto-color-emoji
if ! command -v google-chrome >/dev/null; then
  curl -fsSLo /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get -o DPkg::Lock::Timeout=600 install -y -q /tmp/chrome.deb
  rm -f /tmp/chrome.deb
fi

if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

timedatectl set-timezone "$SCHEDULE_TZ"
id teams &>/dev/null || useradd -m -s /bin/bash teams

# VNC password (only reachable through an SSH tunnel). Readable by root at /root/vnc-password.
if [[ ! -f /home/teams/.vnc/passwd ]]; then
  install -d -m 700 -o teams -g teams /home/teams/.vnc
  pw=$(head -c 48 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9')
  ( umask 077; echo "${pw:0:8}" >/root/vnc-password )
  x11vnc -storepasswd "${pw:0:8}" /home/teams/.vnc/passwd >/dev/null
  chown teams:teams /home/teams/.vnc/passwd
fi

install -d "$DEST/bin"
install -m 755 "$SRC"/bin/*.sh "$DEST/bin/"
# Keep a chat id the bot already linked when re-running setup.
if [[ -f $DEST/config.env ]] && grep -q '^TELEGRAM_CHAT_ID=.' "$DEST/config.env" && ! grep -q '^TELEGRAM_CHAT_ID=.' "$SRC/config.env"; then
  sed -i "s|^TELEGRAM_CHAT_ID=.*|$(grep '^TELEGRAM_CHAT_ID=' "$DEST/config.env")|" "$SRC/config.env"
fi
install -m 640 -o root -g teams "$SRC/config.env" "$DEST/config.env"
install -m 644 "$SRC"/systemd/* /etc/systemd/system/

render_timer() {
  local name=$1 time=$2 d
  {
    printf '[Unit]\nDescription=always-green scheduled %s\n\n[Timer]\n' "$name"
    for d in $SCHEDULE_DAYS; do echo "OnCalendar=$d $time $SCHEDULE_TZ"; done
    printf 'AccuracySec=1s\n\n[Install]\nWantedBy=timers.target\n'
  } >"/etc/systemd/system/ag-$name.timer"
}
render_timer start "$START_TIME"
render_timer stop "$STOP_TIME"

ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null

systemctl daemon-reload
systemctl enable --now ag-xvfb.service ag-start.timer ag-stop.timer
systemctl enable ag-bot.service
systemctl restart ag-bot.service

echo
systemctl list-timers 'ag-*' --no-pager
echo
echo "Next: log in to Teams once over VNC (see README)."
AG_EOF

cat >"$D/config.env.example" <<'AG_EOF'
# Copy to config.env and fill in. Re-run setup.sh after changing the schedule.

# Telegram: create a bot with @BotFather. Leave TELEGRAM_CHAT_ID empty: the first
# chat that messages the bot is linked automatically.
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=

# Schedule. Each entry in SCHEDULE_DAYS is a systemd calendar date
# (e.g. 2026-10-28, or Sun..Thu for a recurring week), space separated.
SCHEDULE_DAYS="2026-10-28 2026-10-29"
SCHEDULE_TZ=Asia/Amman
# Browser starts a few minutes early so Teams is loaded by 10:00.
START_TIME=09:55
STOP_TIME=18:00

# Mouse nudge interval, randomised between these bounds (seconds).
# Kept well below any likely Teams idle timeout; raise once you know yours.
NUDGE_MIN_SEC=60
NUDGE_MAX_SEC=90

# Periodic Telegram screenshot during the session (minutes, 0 = off).
SCREENSHOT_EVERY_MIN=30
# Wait after browser start before the first screenshot/health check.
STARTUP_GRACE_SEC=120

TEAMS_URL=https://teams.microsoft.com/v2/
DISPLAY_NUM=:99
SCREEN_W=1600
SCREEN_H=900
PROFILE_DIR=/home/teams/chrome-profile
AG_EOF

cat >"$D/bin/bot.sh" <<'AG_EOF'
#!/usr/bin/env bash
# Telegram command poller: /status, /on, /off. Only answers TELEGRAM_CHAT_ID.
set -uo pipefail
# shellcheck source=SCRIPTDIR/lib.sh
source /opt/always-green/bin/lib.sh

status() {
  if systemctl is-active --quiet ag-session.target; then
    tg_photo "Session active, page: $(health)"
  else
    tg_text "Session inactive. Next start: $(systemctl show ag-start.timer -p NextElapseUSecRealtime --value)"
  fi
}

offset=0
while true; do
  resp=$(curl -fsS -m 70 "$TG_API/getUpdates" -d timeout=60 -d offset="$offset") || { nap 5; continue; }
  while read -r upd; do
    offset=$(($(jq -r .update_id <<<"$upd") + 1))
    chat=$(jq -r '.message.chat.id // empty' <<<"$upd")
    text=$(jq -r '.message.text // empty' <<<"$upd")
    [[ -n $chat ]] || continue

    # First chat to message the bot claims it; everyone else is ignored after that.
    if [[ -z $TELEGRAM_CHAT_ID ]]; then
      sed -i "s|^TELEGRAM_CHAT_ID=.*|TELEGRAM_CHAT_ID=$chat|" "$CONF"
      TELEGRAM_CHAT_ID=$chat
      tg_text "Linked to this chat. Commands: /status /on /off"
      continue
    fi
    [[ $chat == "$TELEGRAM_CHAT_ID" ]] || continue

    case ${text%%@*} in
      /status) status ;;
      /on) systemctl start ag-session.target && tg_text "Session starting" ;;
      /off) systemctl stop ag-session.target && tg_text "Session stopped" ;;
      *) tg_text "Commands: /status /on /off" ;;
    esac
  done < <(jq -c '.result[]' <<<"$resp")
done
AG_EOF

cat >"$D/bin/browser.sh" <<'AG_EOF'
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
AG_EOF

cat >"$D/bin/keepalive.sh" <<'AG_EOF'
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

# Teams reopens the last chat on load; switch to Calendar (Ctrl+Shift+3) so
# chats aren't marked read and screenshots don't show chat contents.
show_calendar() {
  local wid
  wid=$(xdotool search --onlyvisible --class google-chrome 2>/dev/null | head -n1)
  [[ -n $wid ]] || return 0
  xdotool windowfocus "$wid" 2>/dev/null
  xdotool key --window "$wid" ctrl+shift+3
  nap 5
}

log "started, waiting ${STARTUP_GRACE_SEC}s for Teams to load"
nap "$STARTUP_GRACE_SEC"
show_calendar

last_state=$(health)
tg_photo "Session started $(date '+%a %H:%M'), page: $last_state"
next_shot=$(($(date +%s) + SCREENSHOT_EVERY_MIN * 60))

while true; do
  nudge

  state=$(health)
  if [[ $state != "$last_state" ]]; then
    log "state $last_state -> $state"
    case $state in
      ok) show_calendar; tg_photo "Recovered: Teams page is back" ;;
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
AG_EOF

cat >"$D/bin/lib.sh" <<'AG_EOF'
# shellcheck shell=bash
# Shared helpers, sourced by the other scripts.
CONF=${CONF:-/opt/always-green/config.env}
set -a
# shellcheck source=/dev/null
source "$CONF"
set +a
export DISPLAY=${DISPLAY_NUM:-:99}
TG_API=${TG_API:-"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"}
CDP=http://127.0.0.1:9222

log() { echo "[$(date '+%F %T')] $*"; }

tg_text() {
  local chat=${2:-$TELEGRAM_CHAT_ID}
  curl -fsS -m 30 "$TG_API/sendMessage" -d chat_id="$chat" \
    --data-urlencode text="$1" >/dev/null || log "telegram sendMessage failed"
}

tg_photo() {
  local f
  f=$(mktemp --suffix=.png)
  if import -window root "$f" 2>/dev/null; then
    curl -fsS -m 60 "$TG_API/sendPhoto" -F chat_id="$TELEGRAM_CHAT_ID" \
      --form-string caption="$1" -F photo=@"$f" >/dev/null || log "telegram sendPhoto failed"
  else
    tg_text "$1 (screenshot failed)"
  fi
  rm -f "$f"
}

# URL of the first browser tab, via the Chrome DevTools endpoint.
page_url() {
  curl -fsS -m 5 "$CDP/json/list" 2>/dev/null | jq -r '[.[] | select(.type == "page")][0].url // empty'
}

# Prints: ok | browser-down | signed-out
health() {
  local url
  url=$(page_url)
  if [[ -z $url ]]; then
    echo browser-down
  elif [[ $url == *login.microsoftonline.com* || $url == *login.live.com* || $url == *login.microsoft.com* ]]; then
    echo signed-out
  else
    echo ok
  fi
}

# Interruptible sleep so TERM traps fire immediately.
nap() { sleep "$1" & wait $!; }
AG_EOF

cat >"$D/systemd/ag-bot.service" <<'AG_EOF'
[Unit]
Description=always-green Telegram bot
Wants=network-online.target
After=network-online.target ag-xvfb.service

[Service]
ExecStart=/opt/always-green/bin/bot.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
AG_EOF

cat >"$D/systemd/ag-browser.service" <<'AG_EOF'
[Unit]
Description=always-green Chrome with Teams
Requires=ag-xvfb.service
After=ag-xvfb.service
PartOf=ag-session.target

[Service]
User=teams
ExecStart=/opt/always-green/bin/browser.sh
Restart=on-failure
RestartSec=10
AG_EOF

cat >"$D/systemd/ag-keepalive.service" <<'AG_EOF'
[Unit]
Description=always-green activity + Telegram reporting
Requires=ag-xvfb.service
# After= also means it is stopped before the browser, so the final screenshot shows Teams.
After=ag-xvfb.service ag-browser.service
PartOf=ag-session.target

[Service]
User=teams
ExecStart=/opt/always-green/bin/keepalive.sh
KillMode=mixed
TimeoutStopSec=90
Restart=on-failure
RestartSec=10
AG_EOF

cat >"$D/systemd/ag-session.target" <<'AG_EOF'
[Unit]
Description=always-green Teams session
Requires=ag-xvfb.service
After=ag-xvfb.service
Wants=ag-browser.service ag-keepalive.service
AG_EOF

cat >"$D/systemd/ag-start.service" <<'AG_EOF'
[Unit]
Description=always-green scheduled start

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl start ag-session.target
AG_EOF

cat >"$D/systemd/ag-stop.service" <<'AG_EOF'
[Unit]
Description=always-green scheduled stop

[Service]
Type=oneshot
ExecStart=/usr/bin/systemctl stop ag-session.target
AG_EOF

cat >"$D/systemd/ag-vnc.service" <<'AG_EOF'
# Start manually for the one-time login; localhost only, reach it via SSH tunnel.
[Unit]
Description=always-green VNC (localhost only)
Requires=ag-xvfb.service
After=ag-xvfb.service

[Service]
User=teams
EnvironmentFile=/opt/always-green/config.env
# macOS Screen Sharing refuses servers without a password; setup.sh creates one.
ExecStart=/usr/bin/x11vnc -display ${DISPLAY_NUM} -localhost -rfbport 5900 -forever -shared -rfbauth /home/teams/.vnc/passwd
# x11vnc exits 2 on SIGTERM.
SuccessExitStatus=2
Restart=on-failure
AG_EOF

cat >"$D/systemd/ag-xvfb.service" <<'AG_EOF'
[Unit]
Description=always-green virtual display

[Service]
User=teams
EnvironmentFile=/opt/always-green/config.env
ExecStart=/usr/bin/Xvfb ${DISPLAY_NUM} -screen 0 ${SCREEN_W}x${SCREEN_H}x24 -nolisten tcp
Restart=always

[Install]
WantedBy=multi-user.target
AG_EOF

chmod +x "$D/setup.sh" "$D"/bin/*.sh
sed "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN|" "$D/config.env.example" >"$D/config.env"
"$D/setup.sh"
echo "always-green setup done"
