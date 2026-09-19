# telegram-approver

Lambda that receives Telegram's `callback_query` webhook (an approve/deny/fix
button tap on a PR notification) and turns it into a `workflow_dispatch` of
`telegram-action.yml` in `var.repo`. Handler code lives in
`apps/telegram-approver/handler.py` (entrypoint `handler.lambda_handler`);
this module only provisions the Lambda, its execution role, and the public
function URL Telegram posts to.

## Secrets

The Lambda reads four SSM parameters at cold start (created out-of-band by
the maintainer — see the runbook below — and never in Terraform state):
`/ned/telegram/bot-token`, `/ned/telegram/webhook-secret`,
`/ned/github/dispatch-token`, `/ned/telegram/approver-id`. Their names are
passed to the handler as env vars (`BOT_TOKEN_PARAM`, `WEBHOOK_SECRET_PARAM`,
`DISPATCH_TOKEN_PARAM`, `APPROVER_ID_PARAM`); the values are fetched via
`ssm:GetParameters` + `kms:Decrypt` (via `kms:ViaService=ssm`), both granted
by the execution role's inline policy and allowed by `ned-role-boundary`.

## Function URL auth

Telegram cannot sign webhook requests, so `aws_lambda_function_url.this` uses
`authorization_type = "NONE"` — the function URL is public. The handler
authenticates every request itself, comparing the
`X-Telegram-Bot-Api-Secret-Token` header against the webhook secret with
`hmac.compare_digest`. A public function URL needs two `aws_lambda_permission`
grants: `lambda:InvokeFunctionUrl` (the URL itself) and `lambda:InvokeFunction`
scoped with `invoked_via_function_url = true` (the underlying invoke). Both
attributes are present on the pinned aws provider (6.65.0, confirmed via
`terraform providers schema -json`), so both resources are kept as written in
the task brief — no fallback needed for older provider versions.

## Packaging

`data.archive_file.handler` zips `apps/telegram-approver/handler.py` into
`.build/telegram-approver.zip` under the *root* module (`path.root`), not
this module, so `infra/envs/prod`'s single `.build/` directory holds it. The
zip is a plan-time artifact: `infra-aws.yml` stashes it alongside the saved
`tfplan` for apply (a saved plan does not re-run data sources), and `.build/`
is gitignored.

## Logs

Logs go to `/ned/lambda/telegram-approver`, inside the `ned-role-boundary`'s
`log-group:/ned/*` allowance. The handler never logs secret values (see
`apps/telegram-approver/handler.py`'s comments on `answerCallbackQuery`).

## One-time setup (maintainer)

1. GitHub App: Settings → Developer settings → GitHub Apps → New. Name `ned-bot-<you>`, no webhook, permissions:
   Contents RW, Pull requests RW, Issues RW, Metadata R (no Workflows). Install on `EITANPOD/ned` only.
   Generate a private key. Then:
   `gh secret set NED_APP_PRIVATE_KEY -R EITANPOD/ned < key.pem && rm key.pem`
   `gh variable set NED_APP_ID -R EITANPOD/ned --body <app id>`
   `gh variable set NED_APP_SLUG -R EITANPOD/ned --body <app slug>`
2. Fine-grained PAT: repo `EITANPOD/ned` only, permission **Actions: Read and write** only, 1-year expiry.
3. SSM (AWS_PROFILE=eitan):
   `aws ssm put-parameter --name /ned/github/dispatch-token --type SecureString --value '<PAT>'`
   `aws ssm put-parameter --name /ned/telegram/bot-token --type SecureString --value '<bot token>'`
   `aws ssm put-parameter --name /ned/telegram/webhook-secret --type SecureString --value "$(openssl rand -hex 32)"`
   `aws ssm put-parameter --name /ned/telegram/approver-id --type String --value '<your Telegram user id>'`
4. Webhook (after the prod apply):
   `url=$(terraform -chdir=infra/envs/prod output -raw telegram_approver_url)`
   `secret=$(aws ssm get-parameter --name /ned/telegram/webhook-secret --with-decryption --query Parameter.Value --output text)`
   `curl -sS "https://api.telegram.org/bot<bot token>/setWebhook" -d url="$url" -d secret_token="$secret" -d allowed_updates='["callback_query"]'`

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| aws\_region | Region for the Lambda and the ARNs this module builds. | `string` | n/a | yes |
| account\_id | AWS account ID, used to scope SSM/KMS/log ARNs. | `string` | n/a | yes |
| role\_boundary\_arn | Permissions boundary ARN attached to the Lambda's execution role. | `string` | n/a | yes |
| repo | GitHub repo the approver dispatches workflow runs to, as owner/name. | `string` | n/a | yes |
| log\_retention\_days | Retention for the Lambda's CloudWatch logs. | `number` | `14` | no |
| tags | Tags applied to resources created by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| function\_url | Public Lambda function URL Telegram posts webhooks to. |
