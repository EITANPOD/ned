#!/usr/bin/env bash
# Send one Telegram message.
# Env: TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SILENT (true/false),
#      MESSAGE: trusted HTML template (the caller's own tags) with optional {1}..{4} placeholders,
#      ARG1..ARG4: untrusted text, fully HTML-escaped before it replaces {N}.
# Prints sent=true|false to $GITHUB_OUTPUT when set. Exit 1 on failure (the composite action swallows it).
set -euo pipefail
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}" "${MESSAGE:?}"
silent=${SILENT:-false}
report() { [ -z "${GITHUB_OUTPUT:-}" ] || echo "sent=$1" >> "$GITHUB_OUTPUT"; }

# '{' is escaped too, so an argument can never introduce another placeholder.
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e 's/{/\&#123;/g'; }
text=$MESSAGE
for i in 1 2 3 4; do
  var="ARG$i"
  arg=$(esc "${!var:-}")
  # ponytail: an arg over 900 chars is cut (entity-safe) so the template's closing tags survive the 3900 cap below.
  if [ "${#arg}" -gt 900 ]; then arg="$(sed 's/&[^;]*$//' <<<"${arg:0:900}")…"; fi
  text=${text//"{$i}"/"$arg"}
done
# Telegram's limit is 4096 characters after entity parsing; keep a margin and never end inside a tag or entity.
if [ "${#text}" -gt 3900 ]; then text="$(sed -e 's/&[^;]*$//' -e 's/<[^>]*$//' <<<"${text:0:3900}")…"; fi

resp=$(curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "parse_mode=HTML" \
  --data-urlencode "disable_notification=${silent}" \
  --data-urlencode "disable_web_page_preview=true" \
  --data-urlencode "text=${text}") || resp='{"ok":false,"description":"transport error"}'
case "$resp" in
  *'"ok":true'*) echo "telegram: sent"; report true;;
  *) echo "telegram: failed: ${resp//$TELEGRAM_BOT_TOKEN/***}" >&2; report false; exit 1;;
esac
