#!/usr/bin/env bash
source "$(dirname "$0")/lib.sh"
H=../../.claude/hooks/pre-tool-guard.sh
ERR=$(mktemp)
blocked() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$H" 2>"$ERR"; echo $?; }
block=(
  # original rules
  "terraform apply -auto-approve" "cd infra && terraform destroy" "terraform import aws_iam_user.x ned-runtime"
  "terraform state rm aws_iam_user.x" "terraform -chdir=infra apply" "cd x && terraform apply"
  "git push --force origin main" "git push -f" "git push --force-with-lease" "git push origin main --force-with-lease"
  "git reset --hard HEAD~1" "git branch -D phase0" "rm -rf ./x" "rm -fr x" "rm -r -f x" "gh pr merge 3 --squash"
  "gh secret set X" "gh variable set X --body y" "gh api -X DELETE repos/a/b" "gh api --method DELETE repos/a/b"
  "aws iam create-user --user-name x" "aws --profile eitan iam create-user --user-name x" "aws s3 rm s3://b/k"
  "aws s3 rb s3://bucket" "aws --region us-east-1 --profile p s3 rb s3://b" "aws ssm put-parameter --name n"
  "aws ssm delete-parameter --name /ned/x" "aws sts assume-role --role-arn r"
  # case-insensitive
  "rm -Rf x" "gh api -X delete repos/a/b" "Terraform Apply"
  # rm long forms
  "rm --recursive --force x" "rm -r --force x" "rm --recursive -f x"
  # wrappers and segments
  "FOO=1 terraform apply" "FOO=\"a b\" terraform apply" "env TF_LOG=1 terraform apply" "sudo rm -rf /x" "command gh pr merge 1"
  "echo hi; terraform apply" "true || terraform destroy" "ls | terraform apply" "(terraform apply)" "x=\$(gh pr merge 1)"
  "bash -c 'terraform apply'" "sh -c \"git push origin main\"" "bash -lc 'aws iam list-users'" "/usr/local/bin/terraform apply"
  # labels and merges
  "gh pr edit 3 --add-label human-approved" "gh issue edit 3 --title t --add-label allow-destroy"
  "gh api repos/o/r/issues/3/labels -f labels[]=human-approved" "gh api -X POST repos/o/r/issues/3/labels"
  "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input:{}) { clientMutationId } }'"
  "gh api graphql -f query='mutation { addLabelsToLabelable(input:{}) { clientMutationId } }'"
  "gh api -XPUT repos/o/r/pulls/1/merge" "gh api --method=PUT repos/o/r/pulls/1/merge" "gh api --method=patch repos/o/r"
  "gh api repos/o/r/pulls/1/merge -f merge_method=squash" "gh api repos/o/r/merges -f base=main -f head=x"
  # push variants
  "git push origin main" "git push origin HEAD:main" "git push origin HEAD:refs/heads/main" "git push origin refs/heads/main"
  "git push origin +feature" "git push origin :feature" "git push --delete origin feature" "git push -d origin feature"
  "git -C /repo push -f" "git -c user.name=x push --force-if-includes" "git push -fu origin x"
  # terraform state surgery
  "terraform state push x.tfstate" "terraform state mv a b" "terraform force-unlock 123" "terraform taint aws_x.y"
  "terraform untaint aws_x.y" "terraform -chdir=infra state rm x"
  # s3api deletes
  "aws s3api delete-object --bucket b --key k" "aws --profile p s3api delete-bucket --bucket b"
)
for c in "${block[@]}"; do
  assert_eq 2 "$(blocked "$c")" "block: $c"
done
assert_contains "$(cat "$ERR")" "Blocked by Ned guardrails" "message"
allow=(
  "terraform plan" "terraform test" "git push origin feature" "git push origin feature --set-upstream" "git push -u origin phase0c"
  "gh pr view 3" "aws sts get-caller-identity" "aws --profile eitan sts get-caller-identity" "rm -f tmp.txt" "rm -f a b" "rm -r dir"
  "gh api repos/a/b" "gh api --method GET repos/a/b"
  # text inside arguments never matches
  "git commit -m \"docs: terraform apply\"" "gh pr create --body \"never gh pr merge\"" "echo 'rm -rf /' > notes.txt"
  "gh pr edit 3 --title x" "gh api graphql -f query='{ viewer { login } }'" "git push origin mainline" "aws s3api list-buckets"
)
for c in "${allow[@]}"; do
  assert_eq 0 "$(blocked "$c")" "allow: $c"
done
printf '{"tool_name":"Read","tool_input":{"file_path":"x"}}' | bash "$H"; assert_eq 0 $? "non-bash tools pass"
echo "ok hook"
