#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
with_fake_curl
export TELEGRAM_BOT_TOKEN=tok123 TELEGRAM_CHAT_ID=42
MESSAGE='<b>hi</b> a<b & c' SILENT=true bash ../../.github/actions/telegram-notify/notify.sh
log=$(cat "$FAKE_CURL_LOG")
assert_contains "$log" "https://api.telegram.org/bottok123/sendMessage" "url"
assert_contains "$log" "chat_id=42" "chat id"
assert_contains "$log" "parse_mode=HTML" "parse mode"
assert_contains "$log" "disable_notification=true" "silent"
# raw '<b' inside text must be escaped, but our own <b> tags are allowed via the RAW_HTML marker rule:
assert_contains "$log" "text=<b>hi</b> a&lt;b &amp; c" "escaping"

# transport failure → exit 1, masked message
printf '#!/usr/bin/env bash\nexit 28\n' > "$(dirname "$FAKE_CURL_LOG")/curl"
set +e; MESSAGE=x bash ../../.github/actions/telegram-notify/notify.sh 2>/tmp/notify.err; rc=$?; set -e
assert_eq 1 "$rc" "transport failure exit code"
assert_contains "$(cat /tmp/notify.err)" "transport error" "transport failure message"

echo "ok notify"
