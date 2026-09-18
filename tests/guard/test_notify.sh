#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
with_fake_curl
N=../../.github/actions/telegram-notify/notify.sh
export TELEGRAM_BOT_TOKEN=tok123 TELEGRAM_CHAT_ID=42
OUT=$(mktemp); ERR=$(mktemp)
sent_text() { sed -n 's/^text=//p' "$FAKE_CURL_LOG" | tail -1; } # first line of the last message sent

MESSAGE='<b>HIGH</b> | {1} & more' ARG1='<b>x' SILENT=true GITHUB_OUTPUT=$OUT bash "$N"
log=$(cat "$FAKE_CURL_LOG")
assert_contains "$log" "https://api.telegram.org/bottok123/sendMessage" "url"
assert_contains "$log" "chat_id=42" "chat id"
assert_contains "$log" "parse_mode=HTML" "parse mode"
assert_contains "$log" "disable_notification=true" "silent"
assert_eq "<b>HIGH</b> | &lt;b&gt;x & more" "$(sent_text)" "template tags kept, arg escaped"
assert_eq "sent=true" "$(cat "$OUT")" "sent=true reported"

: > "$FAKE_CURL_LOG"
MESSAGE='t: {1}' ARG1='<a href="https://evil">x</a> {2} & co' ARG2=nope bash "$N"
assert_eq 't: &lt;a href=&quot;https://evil&quot;&gt;x&lt;/a&gt; &#123;2} &amp; co' "$(sent_text)" "links in args stay escaped; no placeholder injection"

: > "$FAKE_CURL_LOG"
MESSAGE="$(printf 'x%.0s' $(seq 5000))" bash "$N"
t=$(sent_text)
assert_contains "$t" "x…" "truncation marker"
t=${t%…}
assert_eq 3900 "${#t}" "5000-char message capped at 3900"

: > "$FAKE_CURL_LOG"
MESSAGE='{1} end' ARG1="$(printf '&%.0s' $(seq 400))" bash "$N"
t=$(sent_text)
assert_contains "$t" "&amp;… end" "long arg cut on an entity boundary, template tail kept"

# transport failure → exit 1, masked message, sent=false
printf '#!/usr/bin/env bash\nexit 28\n' > "$(dirname "$FAKE_CURL_LOG")/curl"
: > "$OUT"
set +e; MESSAGE=x GITHUB_OUTPUT=$OUT bash "$N" 2>"$ERR"; rc=$?; set -e
assert_eq 1 "$rc" "transport failure exit code"
assert_contains "$(cat "$ERR")" "transport error" "transport failure message"
assert_eq "sent=false" "$(cat "$OUT")" "sent=false reported"

echo "ok notify"
