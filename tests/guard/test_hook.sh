#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
H=../../.claude/hooks/pre-tool-guard.sh
blocked() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | bash "$H" 2>/tmp/hook.err; echo $?; }
for c in "terraform apply -auto-approve" "cd infra && terraform destroy" "terraform import aws_iam_user.x ned-runtime" "terraform state rm aws_iam_user.x" "git push --force origin main" "git push -f" "git reset --hard HEAD~1" "git branch -D phase0" "rm -rf ./x" "gh pr merge 3 --squash" "gh secret set X" "gh variable set X --body y" "gh api -X DELETE repos/a/b" "aws iam create-user --user-name x" "aws s3 rm s3://b/k" "aws s3 rb s3://bucket" "aws ssm put-parameter --name n" "aws ssm delete-parameter --name /ned/x" "aws sts assume-role --role-arn r"; do
  assert_eq 2 "$(blocked "$c")" "block: $c"
done
assert_contains "$(cat /tmp/hook.err)" "Blocked by Ned guardrails" "message"
for c in "terraform plan" "terraform test" "git push origin feature" "gh pr view 3" "aws sts get-caller-identity" "rm -f tmp.txt" "gh api repos/a/b"; do
  assert_eq 0 "$(blocked "$c")" "allow: $c"
done
printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | bash "$H"; assert_eq 0 $? "non-bash tools pass"
echo "ok hook"
