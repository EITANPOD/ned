# envs/bootstrap

The one Terraform root applied from a laptop, because CI cannot authenticate before the OIDC roles exist.
It owns:

- the Terraform state bucket (official `terraform-aws-modules/s3-bucket/aws` `5.16.1`): versioned,
  SSE-S3, public access fully blocked, `plans/` expired after 1 day (current + noncurrent versions,
  then the leftover delete markers);
- `../../modules/github-ci-role`: the GitHub OIDC provider, the CI roles `ned-github-terraform-read`
  (PR plans), `ned-github-terraform-plan` (main-branch plans) and `ned-github-terraform` (apply, env
  `prod`), and the permissions boundaries `ned-user-boundary` / `ned-role-boundary`.

State key: `bootstrap/terraform.tfstate` in the state bucket itself (partial S3 backend, `use_lockfile`).

## Outputs

| Output | Use |
|--------|-----|
| `ci_role_arn` | repo variable `AWS_TF_ROLE_ARN` (apply job) |
| `plan_role_arn` | repo variable `AWS_TF_PLAN_ROLE_ARN` (main-branch plan job) |
| `read_role_arn` | repo variable `AWS_TF_READ_ROLE_ARN` (PR plan job) |
| `state_bucket` | repo variable `TF_STATE_BUCKET` |
| `user_boundary_arn`, `role_boundary_arn` | boundaries every CI-created user / role must carry |

## Runbook

Get the GitHub ids with `gh api repos/<owner>/<repo> -q '.owner.id, .id'`, then set:

```bash
export AWS_PROFILE=<admin-profile> TF_VAR_github_repo=<owner>/<repo> TF_VAR_github_owner_id=<owner-id> \
  TF_VAR_github_repo_id=<repo-id> TF_VAR_aws_region=us-east-1 TF_VAR_state_bucket_name=ned-tfstate-<account-id>
cd infra/envs/bootstrap
```

**First time (no bucket yet):** apply with local state, then move the state into the bucket it just created.

```bash
printf 'terraform {\n  backend "local" {}\n}\n' > zz_local_override.tf
terraform init -reconfigure && terraform apply
rm zz_local_override.tf
terraform init -migrate-state -force-copy -backend-config="bucket=$TF_VAR_state_bucket_name" -backend-config="region=$TF_VAR_aws_region"
rm -f terraform.tfstate terraform.tfstate.backup
```

**Every later change** (state already in S3):

```bash
terraform init -reconfigure -backend-config="bucket=$TF_VAR_state_bucket_name" -backend-config="region=$TF_VAR_aws_region"
terraform plan    # review: never apply a plan with destroys you did not intend
terraform apply
```

Then set the repo variables from the outputs table: `AWS_TF_ROLE_ARN` (`terraform output -raw ci_role_arn`),
`AWS_TF_PLAN_ROLE_ARN` (`terraform output -raw plan_role_arn`) and `AWS_TF_READ_ROLE_ARN`
(`terraform output -raw read_role_arn`). In the same rollout `.github/workflows/infra-aws.yml` switches its
plan jobs to the new roles: PR plans assume the read role, dispatch plans on `main` the plan role, and apply
keeps `AWS_TF_ROLE_ARN`. Follow the rollout order in [`infra/README.md`](../../README.md#migration-from-the-flat-roots-phase-0c).

## Migration from `infra/bootstrap`

`moved.tf` maps every address of the old flat config into the modules, so the first plan here against
the existing `bootstrap/terraform.tfstate` must show **0 to destroy**. Targets were read from the module
sources at the pinned tags (s3-bucket `5.16.1`, iam `6.8.2` via `github-ci-role`).

| Old address (`infra/bootstrap`) | New address |
|---------------------------------|-------------|
| `aws_s3_bucket.state` | `module.state_bucket.aws_s3_bucket.this[0]` |
| `aws_s3_bucket_versioning.state` | `module.state_bucket.aws_s3_bucket_versioning.this[0]` |
| `aws_s3_bucket_server_side_encryption_configuration.state` | `module.state_bucket.aws_s3_bucket_server_side_encryption_configuration.this[0]` |
| `aws_s3_bucket_public_access_block.state` | `module.state_bucket.aws_s3_bucket_public_access_block.this[0]` |
| `aws_s3_bucket_lifecycle_configuration.state` | `module.state_bucket.aws_s3_bucket_lifecycle_configuration.this[0]` |
| `aws_iam_openid_connect_provider.github` | `module.github_ci_role.module.oidc_provider.aws_iam_openid_connect_provider.this[0]` |
| `aws_iam_role.ci` | `module.github_ci_role.module.role.aws_iam_role.this[0]` |
| `aws_iam_role_policy.ci` | `module.github_ci_role.module.role.aws_iam_role_policy.inline[0]` |
| `aws_iam_policy.user_boundary` | `module.github_ci_role.aws_iam_policy.user_boundary` |
| `aws_iam_policy.role_boundary` | `module.github_ci_role.aws_iam_policy.role_boundary` |

Expected plan: **adds** = the plan and read roles and their inline policies; **in-place** = apply-role
trust narrowed to `environment:prod` and `force_detach_policies = true`, the rewritten apply-role inline
policy, OIDC `thumbprint_list`, public access block `skip_destroy = true` (module default, state-only:
the block survives a bucket-module destroy). The inline policy keeps its live name
`ned-github-terraform` (iam-role uses the role name when `use_name_prefix = false`), so no replace.

s3-bucket module defaults left off because the live bucket has none of them: `acl`/`grant`
(no `aws_s3_bucket_acl`), `control_object_ownership = false` (no ownership controls), `attach_policy`
and every `attach_*_policy = false` (no bucket policy), `logging`, CORS, website, object lock,
replication, intelligent tiering, metadata configuration. `attach_public_policy = true` is set
explicitly: despite its name it is the module's switch for creating the public access block.

The `moved` blocks can be deleted once this migration has been applied.
