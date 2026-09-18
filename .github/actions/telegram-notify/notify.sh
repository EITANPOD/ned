#!/usr/bin/env bash
# Send one Telegram message. Env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, MESSAGE, SILENT (true/false).
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}" "${MESSAGE:?}"
silent=${SILENT:-false}

esc=$(printf '%s' "$MESSAGE" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')
# re-allow a fixed tag whitelist
esc=$(printf '%s' "$esc" | sed -E \
  -e 's#&lt;(/?)(b|i|code)&gt;#<\1\2>#g' \
  -e 's#&lt;a href=&quot;([^&]*)&quot;&gt;#<a href="\1">#g' \
  -e 's#&lt;a href="([^"]*)"&gt;#<a href="\1">#g' \
  -e 's#&lt;/a&gt;#</a>#g')

resp=$(curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_notification=${silent}" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${esc}")
case "$resp" in *'"ok":true'*) echo "telegram: sent";; *) echo "telegram: failed: ${resp//$TELEGRAM_BOT_TOKEN/***}" >&2; exit 1;; esac
