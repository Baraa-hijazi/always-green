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

    if [[ -z $TELEGRAM_CHAT_ID ]]; then
      tg_text "Your chat id is $chat. Put it in config.env and re-run setup.sh." "$chat"
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
