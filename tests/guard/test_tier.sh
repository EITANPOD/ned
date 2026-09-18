#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-tier.sh
run() { # run <files> [env assignments...]
  local files=$1; shift
  printf '%b' "$files" | env "$@" bash "$S"
}
t() { run "$1" "${@:2}" | sed -n 's/^tier=//p'; }

assert_eq low    "$(t 'M\tapps/core/x.py\nA\tdocs/a.md\nM\tREADME.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "app+docs is low"
assert_eq medium "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "infra/aws add-only is medium"
assert_eq high   "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false)" "destroy is high"
assert_eq high   "$(t 'M\tinfra/aws/iam.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "infra without plan is high"
assert_eq high   "$(t 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "bootstrap is high"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "workflow edit is medium"
assert_eq high   "$(t 'M\t.github/workflows/guard.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "guard edit is high"
assert_eq high   "$(t 'M\tCLAUDE.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "CLAUDE.md is high"
assert_eq high   "$(t 'M\t.claude/settings.json' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" ".claude is high"
assert_eq high   "$(t 'D\tinfra/aws/logging.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "deleting infra file is high"
assert_eq low    "$(t 'M\t.github/dependabot.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 7.0.2' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot patch is low"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 8.0.0' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot major is medium"
assert_eq high   "$(t 'M\tapps/x.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=true)" "force push is high"
r=$(run 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false | sed -n 's/^reasons=//p')
assert_contains "$r" "infra/bootstrap" "reason names bootstrap"
assert_contains "$r" "destroy" "reason names destroy"
echo "ok tier"
