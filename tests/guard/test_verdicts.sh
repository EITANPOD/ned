#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-verdicts.sh
v() { COMMENTS_JSON=fixtures/$1 REVIEWS_JSON=fixtures/$2 bash "$S"; }
out=$(v comments-pass.json reviews-clean.json)
assert_contains "$out" "claude=pass" "pass"
assert_contains "$out" "coderabbit=clean" "clean"
out=$(v comments-human.json reviews-findings.json)
assert_contains "$out" "claude=human" "human"
assert_contains "$out" "coderabbit=findings" "findings"
assert_contains "$out" "suggested_fix=pin Principal to arn:aws:iam::123:role/ned-*" "fix extracted"
out=$(v comments-none.json reviews-none.json)
assert_contains "$out" "claude=missing" "missing claude"
assert_contains "$out" "coderabbit=missing" "missing cr"
out=$(v comments-quoted.json reviews-clean.json)
assert_contains "$out" "claude=human" "quoted PASS must not win"
assert_contains "$out" "suggested_fix=revert the trust change" "fix from quoted case"
out=$(v comments-inline-only.json reviews-clean.json)
assert_contains "$out" "claude=missing" "inline verdict is not a verdict line"
echo "ok verdicts"
