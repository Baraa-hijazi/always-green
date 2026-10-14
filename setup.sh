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
apt-get update -q
apt-get install -y -q xvfb x11vnc xdotool imagemagick curl jq ufw fonts-liberation fonts-noto-color-emoji
if ! command -v google-chrome >/dev/null; then
  curl -fsSLo /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
  apt-get install -y -q /tmp/chrome.deb
  rm -f /tmp/chrome.deb
fi

if ! swapon --show | grep -q .; then
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi

timedatectl set-timezone "$SCHEDULE_TZ"
id teams &>/dev/null || useradd -m -s /bin/bash teams

install -d "$DEST/bin"
install -m 755 "$SRC"/bin/*.sh "$DEST/bin/"
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
