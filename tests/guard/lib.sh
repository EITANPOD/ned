#!/usr/bin/env bash
# Minimal assertions for guard scripts. Source this file.
set -euo pipefail
_fail() { echo "FAIL: $*" >&2; exit 1; }
assert_eq() { [ "$1" == "$2" ] || _fail "$3: expected '$1' got '$2'"; }
assert_contains() { case "$1" in *"$2"*) ;; *) _fail "$3: '$2' not in '$1'";; esac; }
# Fake curl: records argv, returns Telegram-style ok JSON.
with_fake_curl() {
  local bin; bin=$(mktemp -d)
  export FAKE_CURL_LOG="$bin/curl.log"
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FAKE_CURL_LOG"
echo '{"ok":true}'
EOF
  chmod +x "$bin/curl"
  export PATH="$bin:$PATH"
}
