#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
H=../../.claude/hooks/pre-tool-guard.sh
ERR=$(mktemp)
blocked() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" | bash "$H" 2>"$ERR"; echo $?; }
for c in "terraform apply -auto-approve" "cd infra && terraform destroy" "terraform import aws_iam_user.x ned-runtime" "terraform state rm aws_iam_user.x" "terraform -chdir=infra apply" "cd x && terraform apply" "git push --force origin main" "git push -f" "git push --force-with-lease" "git push origin main --force-with-lease" "git reset --hard HEAD~1" "git branch -D phase0" "rm -rf ./x" "rm -fr x" "rm -r -f x" "gh pr merge 3 --squash" "gh secret set X" "gh variable set X --body y" "gh api -X DELETE repos/a/b" "gh api --method DELETE repos/a/b" "aws iam create-user --user-name x" "aws --profile eitan iam create-user --user-name x" "aws s3 rm s3://b/k" "aws s3 rb s3://bucket" "aws --region us-east-1 --profile p s3 rb s3://b" "aws ssm put-parameter --name n" "aws ssm delete-parameter --name /ned/x" "aws sts assume-role --role-arn r"; do
  assert_eq 2 "$(blocked "$c")" "block: $c"
done
assert_contains "$(cat "$ERR")" "Blocked by Ned guardrails" "message"
for c in "terraform plan" "terraform test" "git push origin feature" "git push origin feature --set-upstream" "gh pr view 3" "aws sts get-caller-identity" "aws --profile eitan sts get-caller-identity" "rm -f tmp.txt" "rm -f a b" "gh api repos/a/b" "gh api --method GET repos/a/b"; do
  assert_eq 0 "$(blocked "$c")" "allow: $c"
done
printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | bash "$H"; assert_eq 0 $? "non-bash tools pass"
echo "ok hook"
