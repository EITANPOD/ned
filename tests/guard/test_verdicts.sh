#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-verdicts.sh
# Fixtures: head abc123 arrived at 10:00; fresh comments are from 11:00, stale ones from 09:00.
v() { COMMENTS_JSON=fixtures/$1 REVIEWS_JSON=fixtures/$2 HEAD_SHA=abc123 HEAD_TIME=2026-09-18T10:00:00Z bash "$S"; }
out=$(v comments-pass.json reviews-clean.json)
assert_contains "$out" "claude=pass" "pass"
assert_contains "$out" "coderabbit=clean" "clean"
out=$(v comments-human.json reviews-findings.json)
assert_contains "$out" "claude=human" "human"
assert_contains "$out" "coderabbit=findings" "findings"
assert_eq "suggested_fix=pin Principal to arn:aws:iam::123:role/ned-*" "$(grep '^suggested_fix=' <<<"$out")" "fix extracted, CR stripped"
out=$(v comments-none.json reviews-none.json)
assert_contains "$out" "claude=missing" "missing claude"
assert_contains "$out" "coderabbit=missing" "missing cr"
out=$(v comments-quoted.json reviews-clean.json)
assert_contains "$out" "claude=human" "quoted PASS must not win"
assert_contains "$out" "suggested_fix=revert the trust change" "fix from quoted case"
out=$(v comments-inline-only.json reviews-clean.json)
assert_contains "$out" "claude=missing" "inline verdict is not a verdict line"
out=$(v comments-stale.json reviews-old-commit.json)
assert_contains "$out" "claude=missing" "comment older than the head is ignored"
assert_contains "$out" "coderabbit=missing" "CodeRabbit review of an old commit is ignored"
assert_contains "$(v comments-sticky-updated.json reviews-none.json)" "claude=pass" "sticky comment updated after the head counts"
assert_contains "$(v comments-spoof.json reviews-none.json)" "claude=missing" "non-Bot users named claude are ignored"

# guard-marked.sh: only the guard's own comments carry markers.
M=../../.github/scripts/guard-marked.sh
COMMENTS_JSON=fixtures/comments-markers.json bash "$M" "<!-- guard-digest:abc123 -->" || _fail "guard marker found"
if COMMENTS_JSON=fixtures/comments-markers.json bash "$M" "<!-- guard-alerted:abc123 -->"; then _fail "forged marker ignored"; fi
echo "ok verdicts"
