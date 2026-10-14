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
