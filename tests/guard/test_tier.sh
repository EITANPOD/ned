#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
S=../../.github/scripts/guard-tier.sh
run() { # run <files> [env assignments...]
  local files=$1; shift
  printf '%b' "$files" | env "$@" bash "$S"
}
t() { run "$1" "${@:2}" | sed -n 's/^tier=//p'; }

assert_eq low    "$(t 'M\tapps/core/x.py\nA\tdocs/a.md\nM\tREADME.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "app+docs is low"
assert_eq medium "$(t 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "envs/prod add-only is medium"
assert_eq high   "$(t 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false)" "destroy is high"
assert_eq high   "$(t 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "infra without plan is high"
assert_eq high   "$(t 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "bootstrap is high"
assert_eq high   "$(t 'M\tinfra/envs/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "envs/bootstrap is high"
assert_eq high   "$(t 'M\tinfra/modules/github-ci-role/policy.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "github-ci-role module is high"
assert_eq low    "$(t 'M\tinfra/envs/prod/variables.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-nochanges.txt FORCE_PUSH=false)" "infra no-op plan is low"
assert_eq low    "$(t 'M\tinfra/modules/bedrock-runtime/variables.tf\nM\tdocs/a.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-nochanges.txt FORCE_PUSH=false)" "module no-op plan is low"
assert_eq high   "$(t 'M\tinfra/envs/bootstrap/variables.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-nochanges.txt FORCE_PUSH=false)" "trust root stays high on no-op plan"
assert_eq high   "$(t 'D\tinfra/envs/prod/moved.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-nochanges.txt FORCE_PUSH=false)" "infra deletion stays high on no-op plan"
assert_eq medium "$(t 'M\tinfra/envs/prod/variables.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-nochanges.txt FORCE_PUSH=false CLAUDE_VERDICT=human)" "human verdict still escalates a no-op"
assert_eq medium "$(t 'M\tinfra/modules/bedrock-runtime/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "other module is medium"
assert_eq high   "$(t 'M\tinfra/modules/budget-alerts/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "module change without plan is high (touches_infra)"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "workflow edit is medium"
assert_eq high   "$(t 'M\t.github/workflows/guard.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "guard edit is high"
assert_eq high   "$(t 'M\tCLAUDE.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "CLAUDE.md is high"
assert_eq high   "$(t 'M\t.claude/settings.json' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" ".claude is high"
assert_eq high   "$(t 'D\tinfra/envs/prod/moved.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "deleting infra file is high"
assert_eq low    "$(t 'M\t.github/dependabot.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 7.0.2' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot patch is low"
assert_eq medium "$(t 'M\t.github/workflows/ci.yml' PR_TITLE='chore(deps): bump actions/checkout from 7.0.1 to 8.0.0' 'PR_ACTOR=dependabot[bot]' PLAN_FILE= FORCE_PUSH=false)" "dependabot major is medium"
assert_eq high   "$(t 'M\tapps/x.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=true)" "force push is high"
r=$(run 'M\tinfra/bootstrap/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false | sed -n 's/^reasons=//p')
assert_contains "$r" "infra/bootstrap" "reason names bootstrap"
assert_contains "$r" "destroy" "reason names destroy"
assert_eq high "$(t 'R100\tapps/old.py\tinfra/bootstrap/new.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "rename into bootstrap is high"
assert_eq high "$(t 'R100\tinfra/envs/prod/a.tf\tapps/a.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "rename out of infra is high"
assert_eq low  "$(t 'R100\tapps/a.py\tapps/b.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "rename within apps is low"
assert_eq high "$(t 'M\tCLAUDE.md\r\n' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "CRLF input still classifies"
assert_eq high "$(t 'M\t.github/workflows/infra-aws.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "plan-producing workflow is high"
assert_eq high "$(t 'M\t.github/workflows/claude-review.yml' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "verdict-producing workflow is high"
assert_eq medium "$(t 'M\tapps/x.py\nM\tdocs/a.md' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false CLAUDE_VERDICT=human)" "human verdict escalates low to medium"
assert_eq low "$(t 'M\tapps/x.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false CLAUDE_VERDICT=pass)" "pass verdict keeps low"
d() { run "$1" "${@:2}" | sed -n 's/^destroys=//p'; }
assert_eq 1 "$(d 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy.txt FORCE_PUSH=false)" "destroys count printed"
assert_eq 0 "$(d 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-adds.txt FORCE_PUSH=false)" "zero destroys printed"
assert_eq 0 "$(d 'M\tapps/x.py' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE= FORCE_PUSH=false)" "non-infra prints destroys=0"
assert_eq 2 "$(d 'M\tinfra/envs/prod/main.tf' PR_TITLE=x PR_ACTOR=eitan PLAN_FILE=fixtures/plan-destroy-forget.txt FORCE_PUSH=false)" "'to forget' plan line still counts destroys"
echo "ok tier"
