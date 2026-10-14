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
