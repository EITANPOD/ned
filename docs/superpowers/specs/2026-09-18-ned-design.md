# Ned — Design Spec (2026-09-18)

## Context

Eitan wants an always-on agent that knows his life (work Outlook mail+calendar, personal Gmail/GCal, Slack; more sources later), decides on its own when to interrupt him, and reaches him via Telegram (later: phone call, voice back). Dashboard with alert system. Real daily use + portfolio piece + shareable self-host for others. New project from scratch. Cheap + safe: Bedrock (cheapest Nova by default, any model selectable), Oracle free ARM VM.

Decisions made in brainstorming:
- Name: **Ned**. Folder `/Users/eitanpod/eitan/.mywork/ned`, new git repo.
- Own runtime (not Hermes). LLM behind one `Brain` interface; Hermes/MCP pluggable later.
- Python 3.12 backend (FastAPI), Next.js dashboard, Postgres 16 + pgvector.
- Single user, self-host, docker compose. Oracle Always Free ARM (2 OCPU/12GB post-2026-06).
- v1 sources: Gmail + Google Calendar (personal), Outlook mail + calendar via MS Graph (work, delegated auth, fallback if tenant blocks), Slack (Socket Mode, no inbound port).
- v1 outbound: Telegram bot. v2: Twilio voice call, Telegram voice notes in (Whisper), MCP server exposure.

## Concept: situational awareness engine

Not a chatbot. Pipeline:

```
connectors ──► signals (event log) ──► triage ──► alerts (tier, due_at) ──► scheduler ──► notifier ──► you
    ▲                                    │                                                   │
    │                                 memory (facts, people, commitments, pgvector)          │
    └──────────────────── inbound chat (Telegram) → agent loop w/ tools ◄────── buttons: done/snooze/more
```

Interrupt tiers (policy, user-tunable):
- **whisper** → dashboard only
- **nudge** → Telegram message + inline buttons
- **alarm** → Telegram + repeat until ack (v2: phone call)

Quiet hours, dedupe by external id, per-day token budget, rate limit per tier.

## Architecture (monorepo `ned/`)

```
ned/
  apps/
    core/            Python: FastAPI + workers (one container)
      ned/
        brain/       Brain interface + bedrock.py (Converse API, tool use) + embeddings.py
        connectors/  base.py (Connector protocol) gmail.py gcal.py outlook.py slack.py manual.py
        triage/      rules.py (cheap pre-filter) + llm_triage.py → Alert
        policy/      tiers.py quiet_hours.py budget.py  (pure functions)
        memory/      store.py (facts/people/commitments, pgvector search)
        scheduler/   apscheduler w/ SQLAlchemy jobstore: polls, alert firing, morning brief
        notify/      telegram.py (python-telegram-bot, long polling, allowlist, buttons)
        agent/       loop.py: inbound chat → tools (memory, alerts, reminders, mail, calendar)
        api/         REST + SSE for dashboard, /healthz
        db/          SQLAlchemy models + alembic
      tests/
    web/             Next.js 15 app router: alerts feed (SSE), today timeline, memory browser,
                     connector status, settings (tiers/quiet hours), cost meter
  deploy/
    docker-compose.yml   core, web, postgres(pgvector), caddy
    Caddyfile
    oracle/              bootstrap.sh (cloud-init: docker, tailscale, compose up)
  .github/workflows/     ci.yml (pytest, ruff, next build), release.yml (multi-arch images → GHCR)
  docs/superpowers/specs/2026-09-18-ned-design.md   (this design, committed at start)
  .env.example  README.md
```

Core tables: `signals`, `alerts`, `facts` (+embedding), `people`, `commitments`, `reminders`, `connector_state`, `oauth_tokens` (Fernet-encrypted), `llm_usage`.

## Key components

- **Connector protocol**: `poll(state) -> (signals, new_state)`. Idempotent via `external_id`. Each gets scheduler job (Gmail/Outlook every 2 min via delta/history APIs; calendar every 10 min; Slack push via Socket Mode).
- **Triage**: rules first (calendar in 15 min → nudge, no LLM). Rest batched to `Brain.fast` (cheapest Nova by default) w/ structured output: `{tier, summary, due_at, action_hint, people[], commitments[]}`. Extracted commitments/people update memory.
- **Brain**: `complete(messages, tools, schema)`. Bedrock implementation v1. OpenRouter impl trivial later (same interface).
- **Memory**: explicit ("remember X" from Telegram) + extracted. Embeddings via Bedrock (Titan Text v2 or cheapest embedding model available; verify at Phase 2). Retrieval feeds triage prompt + agent loop.
- **Notifier**: Telegram, allowlisted user id. Buttons: done / snooze 1h / snooze tomorrow / more. Callback updates alert, SSE pushes to dashboard.
- **Agent loop**: Nova tool-use loop, max N steps, tools = search_memory, list_alerts, create_reminder, search_mail, calendar_today, remember_fact.
- **Morning brief**: 07:30 job → calendar + open alerts + owed replies → one Telegram message (voice in v2).

## Intelligence: model routing

Bedrock only (data stays in AWS), routed by role via `Brain`:
- `Brain.fast` role: triage classification, extraction. Bulk.
- `Brain.smart` role: Telegram chat/agent loop, morning brief, nightly reflection, rule writing.
- **Default for both roles = cheapest Nova model available** (Nova Micro; verify current cheapest at Phase 1). User picks any Bedrock model per role via `.env` and dashboard settings (Nova 2 Lite/Pro, Claude Haiku/Sonnet, …). OpenRouter impl later, same interface.
- Budget: **$5–10/month hard target**. App-level daily token cap per role (from env, default sized to ~$5/mo) → degrade to rule-only triage when hit. AWS Budget alarm at $5 and $10 (Terraform) emails + Telegram nudge via SNS→webhook later.

## Learning loop (Ned gets smarter from your actions)

- `feedback` table: every action on an alert (done, snooze, ignored/expired, "stop these", reply latency, dashboard click) + context (sender, category, hour, weekday).
- **Fast learning (no LLM)**: `policy/scores.py` — exponentially-decayed scores per sender / category / hour. Demote after repeated ignores, promote after fast acts. Applied before LLM triage; overrides tier within bounds.
- **Case-based prompting**: signals + final verdict (tier, action) embedded in pgvector. Triage prompt includes k=5 nearest past cases → Ned triages the way you handled similar things.
- **Nightly reflection job** (`Brain.smart`, ~02:00): reads day's signals, alerts, feedback, misses (things you acted on that Ned whispered). Outputs: updated natural-language `rules` (shown in dashboard, editable), people/commitment updates, proposed automations sent to Telegram for approve/reject. Approved rules injected into triage prompt.
- **Weekly report** (Sunday): alert precision (acted / sent), misses, top noisy senders, rules added. Telegram + dashboard chart.
- Phase mapping: feedback capture in Phase 2; scores + case-based in Phase 3; reflection + weekly in new **Phase 6** (dashboard becomes 7, deploy 8).

## Infrastructure as Code (Terraform, pipelines only — never applied from laptop)

```
infra/
  bootstrap/   one-time: S3 state bucket + DynamoDB lock table + GitHub OIDC provider/role (applied once via workflow_dispatch with local state, then state migrated)
  aws/         IAM user `ned-runtime` (bedrock:InvokeModel* on allowed model ARNs only), Bedrock invocation logging → CloudWatch (14d retention),
               AWS Budgets ($5 alert, $10 alert, monthly), SNS topic for budget alerts, optional Bedrock guardrail
  oci/         compartment, VCN + subnet + security list (egress only; ingress only Tailscale UDP 41641), VM.Standard.A1.Flex 2 OCPU/12GB,
               reserved public IP, cloud-init (docker, tailscale up w/ auth key, compose pull+up), boot volume backup policy,
               Object Storage bucket for nightly pg_dump
```

Pipelines (`.github/workflows/`):
- `infra-aws.yml`, `infra-oci.yml`: on PR touching `infra/<x>/**` → `terraform fmt -check`, `validate`, `tflint`, `trivy config` (IaC scan), `plan` → plan posted as PR comment. On `workflow_dispatch` (manual) → `plan` then `apply` gated by GitHub **environment `prod` with required reviewer** (you). No apply on push.
- Auth: AWS via GitHub OIDC role (no long-lived keys in CI). OCI via API key in GitHub secrets (OCI has no GH OIDC federation). Tailscale auth key + Telegram/Bedrock secrets → GitHub environment secrets → written to VM `.env` by deploy job, never committed.
- Remote state: S3 backend + DynamoDB lock, separate state key per root module, versioning + encryption on.
- Providers/modules pinned; Dependabot for Terraform, pip, npm, GitHub Actions.

App CI/CD:
- `ci.yml`: ruff + mypy + pytest (testcontainers-postgres), `next lint` + `next build`, on every PR/push.
- `release.yml`: on tag `v*` → multi-arch (arm64+amd64) images to GHCR, Trivy image scan, SBOM attached, compose pins by tag.
- `deploy.yml`: manual dispatch → GitHub runner joins tailnet (tailscale/github-action) → SSH to VM → write `.env` from env secrets → `docker compose pull && up -d` → smoke-test `/healthz` → Telegram "deployed vX".
- Nightly `pg_dump` → OCI Object Storage (cron on VM, 14-day retention). Restore documented.
- Repo hygiene: pre-commit (ruff, terraform fmt, gitleaks), conventional commits, CODEOWNERS, branch protection on `main` (CI required, no direct push).

## Error handling

- Connector failure → `connector_state.error`, dashboard badge, Telegram nudge after 3 consecutive fails.
- LLM failure/budget exceeded → rule-only triage, alert marked `degraded`.
- All external writes idempotent (external_id unique). Retries w/ backoff (tenacity).
- Daily token cap from env; `llm_usage` row per call; dashboard cost meter.

## Security

- Secrets only in `.env` (validated at startup, pydantic-settings). OAuth tokens Fernet-encrypted at rest.
- Telegram user-id allowlist; dashboard reachable only via Tailscale (recommended) or Caddy + token.
- Bedrock least-priv IAM (reuse bedrock-triage pattern) + AWS budget alarm.
- No inbound ports required except dashboard (Tailscale).

## Testing

- pytest: policy/triage pure functions; connectors against recorded fixtures; Brain via `FakeBrain` (canned responses); DB via testcontainers-postgres.
- One e2e: fake signal → triage → alert → fake notifier receives message.
- CI runs pytest + ruff + `next build` on every push.

## Phases (each = own implementation plan)

0. **Infra bootstrap + AWS**: repo, branch protection, pre-commit, `infra/bootstrap` + `infra/aws` Terraform, `infra-aws.yml` pipeline (plan on PR, manual gated apply), budgets live before first Bedrock call.
1. **Skeleton**: compose (postgres, core), FastAPI /healthz, Telegram echo w/ allowlist, Bedrock Brain hello (cheapest Nova), alembic, `ci.yml`.
2. **Reminders + memory**: "remind me …" / "remember …" via Telegram, scheduler fires nudges, buttons.
3. **Google connector**: Gmail + GCal → signals → triage → alerts → morning brief.
4. **Outlook connector**: Graph delegated auth (device code), mail + calendar. Fallback if tenant blocks.
5. **Slack connector**: Socket Mode, mentions/DMs → signals.
6. **Learning loop**: nightly reflection, rules table, proposed automations, weekly report.
7. **Dashboard**: Next.js, SSE alerts, timeline, memory, rules, precision chart, settings, cost.
8. **Deploy**: `infra/oci` Terraform + `infra-oci.yml`, Tailscale, `release.yml` + `deploy.yml`, nightly backups, README for self-hosters.

v2 backlog: Twilio voice alarm, Telegram voice in/out, MCP server exposing Ned tools (Hermes/Claude plug-in), health/infra sources, weekly review.

## Verification (end-to-end, after phase 8)

0. PR touching `infra/aws` shows plan comment; `workflow_dispatch` apply waits for reviewer, then AWS Budgets show $5/$10 alerts, IAM user can only invoke allowed model ARNs (test denied call). Same for `infra/oci`: VM up, reachable only via Tailscale, no public ingress except Tailscale UDP.

1. `docker compose up` on VM; `/healthz` 200; dashboard via Tailscale.
2. Send "remind me in 2 min to test" on Telegram → nudge arrives, snooze/done buttons work, dashboard updates live.
3. Send self email with deadline → within 3 min alert appears (tier ≥ nudge) w/ extracted due date.
4. Create calendar event 20 min ahead → nudge at T-15.
5. Slack @mention → nudge within 10s.
6. 07:30 morning brief arrives.
7. `llm_usage` sum < daily cap; CI green.
8. Ignore same newsletter 5× → next one arrives as whisper only. Nightly reflection posts ≥1 proposed rule; approving it changes next-day triage. Weekly precision chart renders.


## Implementation

Each phase gets its own plan under `docs/superpowers/plans/`. Phase 0 first.
