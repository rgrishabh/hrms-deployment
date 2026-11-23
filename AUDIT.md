# HRMS deployment audit

Audited 2026-11-05 at commit `92fef0b` (`feature/hrms-revamp`, identical to `origin/main` at audit time; the branch exists only locally).

**Evidence labels**

| Label | Meaning |
|---|---|
| (none) | Read directly in the cited file |
| **[live]** | Read-only GitHub API call or public HTTP GET on 2026-11-05. Names and settings only, no secret values |
| **[reproduced]** | Run locally against a stub |
| **[platform]** | Behaviour of GitHub, AWS or Docker from my knowledge, not tested here. Confirm before relying on it |
| **[unknown]** | Cannot be determined from the repo. `DEV_ENV_FILE` and the dev host were deliberately not inspected |

Secret values are not reproduced. Where a literal is sensitive or merely unnecessary (dev host IP, a default seed password), only its location is cited.

---

## Summary of findings that change the plan

1. **All three repos are public [live]**, but the docs assume private (`scripts/setup-github.sh:62`, `scripts/setup-github.sh:38-39`). Customer tfvars, `customers.json` and Terraform plan comments would be world-readable (`.github/workflows/terraform.yml:101`). Per-customer Kustomize overlays must not live here. Flipping this repo private would likely break the app repos' reusable-workflow calls **[platform]**.
2. **Backups report success when `pg_dump` fails [reproduced]** (`environments/dev/bin/backup-loop.sh:25`), so the backup flow must be fixed before anything is carried over.
3. **Four brief items have no backend support yet:** Redis (no client in `hrms-backend/package.json`), worker (no entrypoint command, `hrms-backend/docker/entrypoint.sh:7-15`), MinIO (`hrms-backend/src/core/storage/index.ts:53` has no endpoint setting), Mailpit (`hrms-backend/src/core/notify/mailer.ts:23` forces STARTTLS).
4. **A bad Compose change merged to `main` is not auto-rolled back** (`.github/workflows/deploy-dev.yml:183`, `scripts/deploy-dev.sh:16-20`). The dev cutover is the riskiest step in the revamp.
5. **Renaming `environments/dev` does not touch the app repos, but breaks `deploy-dev.yml` unless changed in the same commit.** Renaming `_app-ci.yml` or `_app-publish.yml`, or their job names, breaks the app repos and prod signature verification. See section 8c.

---

## 1. Stack, tools, structure, how deploys run

### Stack

| Area | Current |
|---|---|
| Apps | Two images from sibling repos: `ghcr.io/rgrishabh/hrms-backend` (Fastify, Node 22, UID 1000, `hrms-backend/Dockerfile:50`) and `hrms-frontend` (nginx-unprivileged, UID 101, `hrms-frontend/Dockerfile:28`) |
| Dev runtime | One hand-built EC2 host running Docker Compose: `db`, `provision`, `migrate`, `backend`, `frontend`, `caddy`, `backup`, plus profiles `s3backup` and `tools` (`environments/dev/docker-compose.yml:41-269`) |
| Prod runtime | Terraform for ECS Fargate, ALB, WAF, RDS and S3, one AWS account per customer (`terraform/modules/hrms-stack/*`). Never applied (`docs/TERRAFORM.md:3`, `environments/prod/customers.json:3`) |
| CI/CD | GitHub Actions: 2 reusable, 6 repo workflows (`.github/workflows/`), 1 composite action (`.github/actions/bot-token/action.yml`) |
| Supply chain | Trivy, hadolint, gitleaks, SBOM, provenance, cosign keyless (`.github/workflows/_app-ci.yml:76-144`, `.github/workflows/_app-publish.yml:86-104`) |
| TLS | Caddy with Let's Encrypt in dev (`environments/dev/Caddyfile:5`); ACM on ALB in prod (`terraform/modules/hrms-stack/edge.tf:2`) |

### Structure

`environments/dev` (Compose, Caddyfile, `bin/`, `versions.env`), `environments/prod` (`customers.json`, template), `terraform/modules` (`hrms-stack`, `account-baseline`, `org-guardrails`, `shared-services`), `terraform/envs` (3 roots), `terraform/customers`, `scripts/`, `docs/`.

### Dev deploy, end to end (the only pipeline that has ever run)

1. Merge to `develop` in an app repo fires `publish-develop.yml` there (`hrms-backend/.github/workflows/publish-develop.yml:5-6`).
2. It calls `_app-ci.yml@main`, then `_app-publish.yml@main` with `mode: develop` (`hrms-backend/.github/workflows/publish-develop.yml:18,28-31`).
3. `_app-publish` pushes `:sha-<7>` and `:develop`, scans, signs (`.github/workflows/_app-publish.yml:59,72-104`).
4. It sends `repository_dispatch` `deploy-dev` with `{app, tag, digest, image, sha, repo, run_url, notes}` using `DEPLOY_REPO_TOKEN` (`.github/workflows/_app-publish.yml:145-162`). **[live]** No GitHub App is configured; each app repo has only that PAT secret.
5. `deploy-dev.yml` runs on `main`, with `ref: main` (`.github/workflows/deploy-dev.yml:46-48`). **[live]** 51 of the last 53 runs succeeded; about 60 seconds each.
6. Resolve tags: copies `versions.env` to a temp file, validates the tag, edits it with `sed` (`.github/workflows/deploy-dev.yml:68-71`).
7. Bot commits with `[skip ci]` and pushes straight to `main`, bypassing the ruleset (`.github/workflows/deploy-dev.yml:99-101`). **[live]** The `protect-main` bypass is the admin role only, so this works only because the PAT belongs to an admin.
8. SSH with pinned host key (`.github/workflows/deploy-dev.yml:113-118`). **[live]** `DEV_DEPLOY_METHOD` is unset, so SSH is the live path.
9. Copies and runs `bootstrap-ec2.sh` with sudo; rsyncs `environments/dev/` into `/opt/hrms/dev`, flattened, including `deploy-dev.sh` and `versions.prev.env`; writes `.env` from `DEV_ENV_FILE`; logs in to GHCR (`.github/workflows/deploy-dev.yml:129-136`).
10. `deploy-dev.sh` on the host: tag check, port guard, `pull`, `up db`, `run provision`, `run migrate`, `up --remove-orphans --wait`, `run bootstrap`, wait for `/ready` and `/healthz`, prune images (`scripts/deploy-dev.sh:23-69`).
11. Runner smoke test against the public URL (`.github/workflows/deploy-dev.yml:170`, `scripts/smoke-test.sh:28-45`).
12. On failure: `deploy-dev.sh --rollback`, then revert the bump (`.github/workflows/deploy-dev.yml:173-188`).

### Prod deploy (designed, never executed)

App release, then `_app-publish` `mode: release` (`hrms-backend/.github/workflows/release.yml:41-45`), then `release-prod` dispatch, then a PR bumping `environments/prod/<slug>/versions.env` (`.github/workflows/release-prod.yml:57-65,90-102`). Merge fires `deploy-prod.yml`, which verifies signatures and pins digests (`.github/workflows/deploy-prod.yml:99-108`), assumes `hrms-release`, then runs `deploy-prod.sh`: snapshot, register, provision, migrate, bootstrap, roll, smoke, restore on failure (`scripts/deploy-prod.sh:47-128`). **[live]** Only environment `dev` exists; no `prod-*` or `infra-*`.

---

## 2. Status: complete, partial, broken, dead

| Status | Item | Evidence |
|---|---|---|
| **Complete, live** | App CI, publish, dev auto-deploy, smoke test, image rollback, pinned host key | `.github/workflows/deploy-dev.yml:113-188`; **[live]** run history; `/health` and `/ready` return 200, HSTS, CSP and nosniff present |
| **Complete, live** | Compose hardening on app containers, internal network | `environments/dev/docker-compose.yml:15-19,271-274` |
| **Partial** | Nightly backups: run, but can falsely report success; off-host copy is opt-in | `environments/dev/bin/backup-loop.sh:25`, `environments/dev/.env.example:27-29`; whether enabled is **[unknown]** |
| **Partial** | Config-change rollback: images roll back, config does not | `.github/workflows/deploy-dev.yml:80,102,183`, `scripts/deploy-dev.sh:16-20` |
| **Partial** | Signature verification: prod only, despite the header claim | `.github/workflows/_app-publish.yml:6-7` vs `.github/workflows/deploy-dev.yml:58-89` |
| **Partial** | Dev infrastructure as code: none (EC2, security group, DNS are manual) | `docs/ONE-TIME-SETUP.md:32-39`; no EC2 resource in `terraform/` |
| **Written, never run** | Terraform, deploy-prod, rollback-prod, release-prod PR path | `docs/TERRAFORM.md:3`, `environments/prod/customers.json:3` |
| **Written, never run** | SSM deploy path | `docs/RUNBOOK.md:126`, `scripts/lib/ssm-deploy-dev.sh` |
| **Likely broken** | SMTP in ECS: API security group allows egress only on 443 and 5432, default SMTP port is 587 | `terraform/modules/hrms-stack/network.tf:213-229`, `terraform/modules/hrms-stack/variables.tf:83` |
| **Likely broken** | PR Terraform plans once state exists: plan role has `ReadOnlyAccess` only, which lacks `kms:Decrypt` for the KMS-encrypted state bucket **[platform]** | `terraform/modules/account-baseline/main.tf:127-130`, `terraform/modules/shared-services/main.tf:123-132`, `terraform/envs/customer/main.tf:19-22` |
| **Likely broken** | SSM path: `.env.example` is already 4,368 bytes; a Standard SSM parameter holds 4 KB **[platform]** | `scripts/lib/ssm-deploy-dev.sh:19`, `environments/dev/.env.example` |
| **Broken** | SSM script says `.env` parameter is deleted afterwards; the trap deletes only the GHCR token | `scripts/lib/ssm-deploy-dev.sh:3-4` vs `:13` |
| **Broken** | Module sizing unreachable from tfvars: many module variables are not exposed by the root | `terraform/envs/customer/main.tf:45-78` vs `terraform/modules/hrms-stack/variables.tf:178-189,203-230,232-282,281-284,298-302,310-314` |
| **Likely broken** | Budget with `monthly_budget_usd > 0` and empty `alarm_emails` has no subscribers **[platform]** | `terraform/modules/hrms-stack/operations.tf:170,184`, `terraform/modules/hrms-stack/variables.tf:286-290` |
| **Dead** | See section 3 | |

Checked and clean: `deploy-dev.sh:46` prints JSON bootstrap lines into public logs, but the setup URL is destructured out first (`hrms-backend/src/db/bootstrap.ts:155-156`), so no token leak. No key-shaped strings in the tree; no `.env`, `.pem` or tfstate ever added in history. All `uses:` are pinned to full SHAs. FORCE RLS on `pg_dump` is fixed (`hrms-backend/migrations/004_rls_no_force_for_owner.sql:12`).

---

## 3. Dead code

### Scripts

| Item | Evidence |
|---|---|
| `scripts/lib/pg-backup.sh`, `scripts/lib/pg-restore.sh`: no callers. Headers name `scripts/backup.sh` and `scripts/restore.sh`, which do not exist. Use macOS-style `shasum` | `scripts/lib/pg-backup.sh:3,10`, `scripts/lib/pg-restore.sh:3,6` |
| `scripts/e2e-seeded.sh`: no workflow calls it; only `hrms-backend/TESTING.md` mentions it. Targets an API-serves-SPA model. Contains a default seed password in a public repo | `scripts/e2e-seeded.sh:10,27` |
| `scripts/lib/ssm-deploy-dev.sh` and the four SSM steps: unused while `DEV_DEPLOY_METHOD` is unset **[live]** | `.github/workflows/deploy-dev.yml:148-163,181` |

### Workflows and CI steps

| Item | Evidence |
|---|---|
| Terraform `plan` and `apply` jobs always skip (no customers) | `.github/workflows/terraform.yml:56,109`, `environments/prod/customers.json:3` |
| `deploy-prod.yml`: `deploy` job always skips. `rollback-prod.yml`: no valid target | `.github/workflows/deploy-prod.yml:47`, `.github/workflows/rollback-prod.yml:58-59` |
| `release-prod.yml`: fires on each release, always a no-op | `.github/workflows/release-prod.yml:91,103-104` |
| Unused step IDs `deploy`, `deploy_ssm`, `smoke` | `.github/workflows/deploy-dev.yml:139,155,167` |
| Dispatch payload `digest`, `image`, `sha`, `repo` unused by dev | `.github/workflows/_app-publish.yml:161` vs `.github/workflows/deploy-dev.yml:62-64` |

### Variables and environment

| Item | Evidence |
|---|---|
| Backend settings Compose cannot set because of its allowlist: `RATE_LIMIT_PER_MINUTE`, `AUTH_RATE_LIMIT_PER_MINUTE`, `JOBS_INTERVAL_SECONDS` | `hrms-backend/src/config/env.ts:40-41,51` vs `environments/dev/docker-compose.yml:102-147` |
| `WEB_DIST_DIR`: leftover from the single-image era | `hrms-backend/src/config/env.ts:108` |
| Compose-only knobs never set in `.env.example`: `IMAGE_REGISTRY`, `POSTGRES_IMAGE`, `CADDY_IMAGE`, `AWS_CLI_IMAGE`, `DATABASE_POOL_MAX`, `SESSION_TTL_HOURS`, `JOBS_ENABLED` | `environments/dev/docker-compose.yml:12,43,109,114,116,177,222` |
| `AWS_REGION` in `.env.example`: used only by the optional `backup-s3` | `environments/dev/.env.example:30`, `environments/dev/docker-compose.yml:230` |
| `.gitignore` for `environments/*/backups/` and `*.dump`: backups live in a named volume, never in the repo tree | `.gitignore:17,19-20`, `environments/dev/docker-compose.yml:212` |
| `DEV_SMOKE_REQUIRED`, `AWS_REGION` repo vars unset **[live]**; defaults always apply | `.github/workflows/deploy-dev.yml:153,169` |

### Terraform

| Item | Evidence |
|---|---|
| ECR repo, repo policy, lifecycle, `hrms-image-build` role and its OIDC provider: images moved to GHCR | `terraform/modules/shared-services/main.tf:70-107,179-220`, `.github/workflows/_app-publish.yml:56`, `docs/DISCOVERY.md:40` |
| Unwired module outputs | `terraform/modules/hrms-stack/outputs.tf:34-44` vs `terraform/envs/customer/main.tf:80-106` |
| Duplicate template: differs only by whitespace | `terraform/customers/_template.tfvars:46`, `terraform/envs/customer/terraform.tfvars.example:46` |
| `staging.*`: placeholders, not in `customers.json`, yet claims "every release lands here first" | `terraform/customers/staging.tfvars:1,3`, `terraform/customers/staging.backend.hcl:3-4` |
| Stale comments naming `scripts/deploy/release.sh`, `infra/` | `terraform/modules/hrms-stack/compute.tf:356,475`, `terraform/modules/hrms-stack/edge.tf:14`, `terraform/envs/customer/main.tf:2`, `terraform/envs/organization/main.tf:3` |

### Documentation that no longer matches

| Doc | Stale content |
|---|---|
| `docs/DEPLOYMENT.md:31,36,43-45,57,153,165` | `apps/api/Dockerfile`, `compose.yaml`, profile `https`, broken `infra/README.md` link, `HRMS_IMAGE`, old backup format |
| `docs/DEPLOYMENT.md:21` | "Not run in a Docker engine yet", contradicted by the live box |
| `docs/DEPLOYMENT.md:51,53,96` | `APP_PORT`, `APP_BIND_ADDRESS`, `CADDY_SITE_ADDRESSES`: none exist in Compose |
| `docs/DEPLOYMENT.md:134` | Lists 3 jobs; the registry has at least 14 (`hrms-backend/src/core/jobs/registry.ts:46-215`) |
| `docs/TERRAFORM.md:8-22,41,43,49,59,63-75` | `infra/`, `live/`, `customers/customers.json`, `SHARED_ACCOUNT_ID`, `infra.yml`, `release.yml`, canaries, ECR, environments `staging`/`production` |
| `docs/BACKUP_AND_RESTORE.md:3,22,28-29` | `scripts/backup.sh`, `scripts/restore.sh`, `scripts/smoke.sh`: none exist |
| `docs/OPERATIONS_RUNBOOK.md:19,29,38` | Service `app`, now `backend` |
| `docs/ONE-TIME-SETUP.md:54` | `~/hrms-repos` path |
| `docs/DISCOVERY.md` | Historical, but `:17,39` matter: "No Redis" was a deliberate decision |

---

## 4. Security

### Secrets

| Sev | Finding | Evidence |
|---|---|---|
| High | **Public repos and prod data.** Once a customer exists, `customers.json` (account IDs, domains), tfvars (admin email, branding) and plan output (task-definition JSON, not marked sensitive) become public. Also `apply` output and ops-task logs in public Actions logs | `environments/prod/customers.json:2`, `terraform/customers/_template.tfvars`, `.github/workflows/terraform.yml:90,101,142-143`, `scripts/deploy-prod.sh:87-88`; **[live]** visibility |
| High | **A single admin-level PAT is in three public repos.** `DEPLOY_REPO_TOKEN` must bypass the ruleset. Anyone with write on an app repo can read it from a workflow, and so can push to deployment `main`, which runs on the dev host. `secrets: inherit` also hands the reusable workflow all app secrets. Expiry stops the whole pipeline | `scripts/setup-github.sh:158-162`, `docs/ONE-TIME-SETUP.md:29-30`, `.github/workflows/deploy-dev.yml:55`, `hrms-backend/.github/workflows/publish-develop.yml:32`; **[live]** names |
| Med | Long-running `backup` holds DB **owner** credentials and is unhardened, contradicting the stated property | `environments/dev/docker-compose.yml:197-205` vs `:79-80`, `docs/ARCHITECTURE.md:90` |
| Med | Terraform state contains generated DB passwords and the encryption key | `terraform/modules/hrms-stack/database.tf:96-98,158-168`, `terraform/modules/hrms-stack/database.tf:114-116` |
| Med | Backups are unencrypted at rest locally and hold personal data; S3 copy uses SSE-S3 | `environments/dev/bin/backup-loop.sh:11-12`, `environments/dev/docker-compose.yml:227` |
| Low | Tokens are interpolated into scripts with `${{ }}` and written to `.git/config` | `.github/workflows/deploy-dev.yml:96,184`, `.github/workflows/deploy-prod.yml:135`, `.github/workflows/rollback-prod.yml:114` |
| Low | `$GITHUB_OUTPUT` injection: unvalidated `run_url` and heredoc delimiter inside release notes | `.github/workflows/deploy-dev.yml:75`, `.github/workflows/_app-publish.yml:142`, `.github/workflows/release-prod.yml:73-86` |
| Low | Secrets on runner command lines in the SSM path | `scripts/lib/ssm-deploy-dev.sh:19-20` |
| Low | No gitleaks allowlist/config; a default seed password sits in the tree | `.github/workflows/lint.yml:56`, `scripts/e2e-seeded.sh:10` |
| Good | `.env` written mode 600 over stdin; setup link kept off logs; registry token read from stdin | `.github/workflows/deploy-dev.yml:135`, `scripts/deploy-dev.sh:45-49`, `scripts/set-registry-credentials.sh:9-10` |

### IAM

| Sev | Finding | Evidence |
|---|---|---|
| Med | `hrms-terraform` has `AdministratorAccess`. Acceptable only with SCPs and environment approval; SCPs are not applied anywhere yet | `terraform/modules/account-baseline/main.tf:100-103`, `terraform/modules/org-guardrails/main.tf:98-102` |
| Med | **"Only dbadmin can read the master secret" is not enforced.** One execution role is shared by all tasks and can read it. `hrms-release` can register any task definition and pass that role, so release is effectively DB master | `terraform/modules/hrms-stack/compute.tf:55,257,532,540`, `docs/TERRAFORM.md:31` |
| Low | Wildcards on `ecs:RegisterTaskDefinition` and `rds:CreateDBSnapshot`, partly unavoidable | `terraform/modules/hrms-stack/compute.tf:532,543` |
| Low | Plan role trust covers any PR job in the repo; fork PRs get no OIDC **[platform]** | `terraform/modules/account-baseline/main.tf:119` |
| Good | OIDC scoped to repo + environment; task roles scoped; `allowed_account_ids`; account check in workflows | `terraform/modules/hrms-stack/compute.tf:510-513,74-85`, `terraform/envs/customer/main.tf:27`, `.github/workflows/deploy-prod.yml:118-119` |

### Action pinning and workflow permissions

| Sev | Finding | Evidence |
|---|---|---|
| Med | Terraform and tflint binaries are unpinned: each run gets the latest | `.github/workflows/terraform.yml:35-38,71-73,129-131` |
| Low | Reusable workflows are consumed `@main` (mutable). Deliberate, because signature identity requires it | `hrms-backend/.github/workflows/publish-develop.yml:18,28`, `.github/workflows/deploy-prod.yml:102` |
| Low | Workflow-level `contents: write` and `id-token: write` for all steps; `id-token` unused on the SSH path | `.github/workflows/deploy-dev.yml:26-29` |
| Low | `release-prod` and `deploy-prod` plan jobs keep persisted checkout credentials | `.github/workflows/release-prod.yml:33-36`, `.github/workflows/deploy-prod.yml:29-31` |
| Low | Image is pushed before the Trivy gate; a failing image stays tagged, only the dispatch is blocked | `.github/workflows/_app-publish.yml:72-99` |
| Med | Dev never verifies signature or digest; a manual dispatch can deploy any valid-format tag | `.github/workflows/deploy-dev.yml:70,77-78` |
| Low | All 8 Dependabot PRs were closed unmerged **[live]**; actions are a major version behind | `.github/dependabot.yml:1-18` |
| Low | Rulesets require 0 approvals | `scripts/setup-github.sh:138` |
| Good | All actions SHA-pinned, top-level read-only defaults on most workflows, checksummed actionlint | `.github/workflows/lint.yml:26-28` |

### Public exposure

| Sev | Finding | Evidence |
|---|---|---|
| Med | Port 22 is open to GitHub's wide IP ranges, in practice the internet; SSM alternative is untested | `docs/ONE-TIME-SETUP.md:39`, `scripts/bootstrap-ec2.sh:48` |
| Med | Dev host IP published in public docs | `docs/ONE-TIME-SETUP.md:36,55,90`, `docs/RUNBOOK.md:33,34,78`, `scripts/setup-github.sh:9` |
| Med | IMDS hop limit 2 lets any container with egress (`backend`, `frontend`, `caddy`) reach the instance role | `environments/dev/docker-compose.yml:219` |
| Low | Docker-published ports bypass `ufw` **[platform]** | `environments/dev/docker-compose.yml:187-189`, `scripts/bootstrap-ec2.sh:47-49` |
| Low | `/ready` and `/health` are public, in both dev and ALB. Smoke tests depend on it | `environments/dev/Caddyfile:10`, `terraform/modules/hrms-stack/edge.tf:169`, `scripts/smoke-test.sh:28-29` |
| Low | Deploy user has passwordless sudo and docker group: root equivalent from the SSH key | `.github/workflows/deploy-dev.yml:130`, `scripts/bootstrap-ec2.sh:38` |
| Low | SCP region lock exempts `waf:*` but not `wafv2:*` (see 8b) | `terraform/modules/org-guardrails/main.tf:33-36` |
| Good | DB publishes no port; `internal` network; unknown Host gets 404 at ALB | `environments/dev/docker-compose.yml:53,271-273`, `terraform/modules/hrms-stack/edge.tf:149-163` |

### TLS

| Sev | Finding | Evidence |
|---|---|---|
| Low | No ACME contact email, so no expiry notices; no pre-flight check for LE rate limits | `environments/dev/Caddyfile:5` |
| Low | ALB to tasks is plain HTTP inside the VPC | `terraform/modules/hrms-stack/edge.tf:118-119,195` |
| Info | Compose DB has `DATABASE_SSL=disable` on a private network: accepted and required to be explicit | `environments/dev/docker-compose.yml:73`, `hrms-backend/src/config/env.ts:130` |
| Good | TLS 1.2+ ALB policy, `rds.force_ssl`, `verify-full` with bundled CA, HSTS set once, SMTP STARTTLS required | `terraform/modules/hrms-stack/edge.tf:153`, `terraform/modules/hrms-stack/database.tf:16`, `hrms-backend/Dockerfile:31-32`, `environments/dev/docker-compose.yml:166` |

---

## 5. Performance and cost (rough)

Numbers are approximate list prices from memory for `ap-south-1`, assume about 30% error, and need checking in the AWS calculator.

### Per customer account with module defaults, idle

Sizing from `terraform/modules/hrms-stack/variables.tf:198-266`.

| Item | USD/month |
|---|---|
| RDS `db.t4g.medium` Multi-AZ | 110-140 |
| RDS 50 GB gp3 Multi-AZ | 12-15 |
| NAT gateway (1) + data | 40-50 |
| ALB + LCU | 20-30 |
| Fargate API 2 × 0.5 vCPU/1 GB | 35-40 |
| Fargate web 2 × 0.25 vCPU/0.5 GB | 18-20 |
| WAF ACL, rules, requests | 10-15 |
| Secrets Manager (10) + KMS | 5 |
| CloudWatch logs (365-day retention), Container Insights, alarms | 15-40 |
| GuardDuty, AWS Backup, S3 | 10-30 |
| **Total** | **about 280-370** |

**Implication for tiers:** an EKS control plane adds about $73/month before nodes, so per-account EKS is hard to justify for a low tier. Single-node k3s (`t3.medium`-class, roughly $30-40 plus EBS) with in-cluster Postgres fits low, at the cost of Multi-AZ and of the RDS guarantees. No current prod spend exists.

### Dev

Instance type is not in the repo **[unknown]**. Expect tens of dollars a month. Host swap is 2 GB (`scripts/bootstrap-ec2.sh:8`). No memory limits, so adding Redis, Mailpit, MinIO and a worker risks OOM.

### Performance

| Finding | Evidence |
|---|---|
| No compression in prod: nginx has no `gzip`, ALB does not compress, Caddy is dev only. Needs CloudFront or Ingress compression | `hrms-frontend/docker/nginx.conf`, `environments/dev/Caddyfile:6` |
| Documents stream through the API (no presigned URLs), so downloads consume API memory and bandwidth | `docs/DISCOVERY.md:19` |
| Pool sizing differs: 20 in Compose, 10 in Terraform | `environments/dev/docker-compose.yml:109`, `terraform/modules/hrms-stack/variables.tf:277` |
| Scheduler and outbox delivery run inside the API process | `hrms-backend/src/server.ts:47`, `hrms-backend/src/core/jobs/scheduler.ts:106-107` |
| In-memory rate limit is per replica; effective limit scales with pods | `hrms-backend/src/app.ts:95` |
| `/ready` queries the DB twice per probe; cheap but keep probe intervals sane | `hrms-backend/src/app.ts:106,112` |
| No Postgres tuning in Compose except `shm_size` | `environments/dev/docker-compose.yml:59` |
| `provision` and `migrate` run twice each deploy (explicit `run`, then `up` deps). Harmless | `scripts/deploy-dev.sh:40-42`, `environments/dev/docker-compose.yml:89-90,100-101` |
| No GHCR retention: every develop push stores image, SBOM, provenance and signature | `.github/workflows/_app-publish.yml:59,86-87`, `docs/ONE-TIME-SETUP.md:10-12` |
| 365-day log retention default is a cost driver | `terraform/modules/hrms-stack/variables.tf:281-284` |

---

## 6. DevOps gaps

| Area | Finding | Evidence |
|---|---|---|
| Resource limits | None in Compose | `environments/dev/docker-compose.yml` (no `mem_limit`, `cpus`, `deploy`, `pids_limit`) |
| Non-root / hardening | App containers good. `db`, `caddy`, `backup`, `backup-s3` have no `read_only`, no `cap_drop`, run as root initially | `environments/dev/docker-compose.yml:42-59,176-194,197-216,220-233` |
| Health checks | None on `caddy`, `backup`, `backup-s3` | `environments/dev/docker-compose.yml:176,197,220` |
| Health semantics | Compose health uses `/health`; ALB uses `/health/ready` | `environments/dev/docker-compose.yml:153`, `terraform/modules/hrms-stack/edge.tf:124` |
| Image tags | App tags immutable by convention, not enforced in GHCR. Infra images floating, no digest | `environments/dev/docker-compose.yml:43,177,222`, `scripts/deploy-dev.sh:24` |
| Manual steps | Dev EC2, SG, DNS, package access grant, SSH key, DNS for customers, first apply, registry secret | `docs/ONE-TIME-SETUP.md:32-39,78-82,92-100` |
| **Backups: false success** | **[reproduced]** With a failing `pg_dump` stub the loop prints `backup ok` and leaves a set with no `db.dump`. `set -e` is ignored inside a function called from `\|\|`. Pruning still runs, so good sets age out while bad sets accumulate | `environments/dev/bin/backup-loop.sh:11-16,25` |
| Backups: placement | Same host and EBS as the data unless `s3backup` is on; no alert on failure; no restore drill on the live stack | `environments/dev/.env.example:27-29`, `docs/OPERATIONS_RUNBOOK.md:57-58` |
| Backups: leftovers | Failed runs leave `.hrms-*` temp dirs that are never pruned (the `find` pattern needs `hrms-*`) | `environments/dev/bin/backup-loop.sh:9,16` |
| Backups: S3 growth | `aws s3 sync` has no `--delete` and no bucket lifecycle in repo | `environments/dev/docker-compose.yml:227` |
| No pre-migration backup | Dev migrates on every deploy with no snapshot; prod does snapshot | `scripts/deploy-dev.sh:37-42` vs `scripts/deploy-prod.sh:47-52` |
| Rollback limits | Rollback swaps tags only and reruns `migrate` with the old image; config and schema stay. Old image tolerates newer schema | `scripts/deploy-dev.sh:16-20`, `hrms-backend/src/app.ts:107-110` |
| **Config rollback** | On a push-triggered failure, no bump was made, so there is nothing to revert, and the "previous" tags are the same. `main` stays broken and each later dispatch fails | `.github/workflows/deploy-dev.yml:80,102,179-183` |
| Deploy race | Bump is committed before deploy, so git briefly claims an unverified version | `.github/workflows/deploy-dev.yml:91-102` |
| Dropped tags | GitHub keeps one pending run per concurrency group and cancels older pending ones **[platform]**. Each dispatch carries one app's tag, so a cancelled run can lose a backend tag. **[live]** 0 cancelled in 53 runs: latent, not yet seen | `.github/workflows/deploy-dev.yml:31-33,73-74` |
| Notifications | `NOTIFY_WEBHOOK_URL` not set **[live]**; failures reach only GitHub email | `.github/workflows/deploy-dev.yml:199,214` |
| Alarms | No subscribers by default; no alarm for web task count | `terraform/modules/hrms-stack/variables.tf:286-290`, `terraform/modules/hrms-stack/operations.tf:80-83` |
| Terraform scanning | No checkov/tfsec; PR plans skip refresh, so no drift detection | `docs/TERRAFORM.md:97,100`, `.github/workflows/terraform.yml:86` |
| Parity | `MFA_ENFORCEMENT`, `SESSION_TTL_HOURS`, `JOBS_ENABLED`, `STORAGE_MAX_FILE_MB` are settable in Compose, not in ECS | `environments/dev/docker-compose.yml:114-120` vs `terraform/modules/hrms-stack/compute.tf:200-207` |
| Region | Dev host IP looks like `ap-southeast-2`, while defaults say `ap-south-1` **[unknown]**; check for data-residency reasons | `docs/ONE-TIME-SETUP.md:36`, `environments/dev/.env.example:30` |

---

## 7. Prioritised plan

### P0: before or as the first revamp change

1. **Fix `backup-loop.sh`.** Check each step explicitly (`pg_dump ... || return 1`, not `set -e`), keep the temp dir on failure, verify `db.dump` is non-empty and passes `pg_restore --list`, prune only after success, clean temp dirs, emit a failure signal. (`environments/dev/bin/backup-loop.sh:7-17,25`)
2. **Today, before anything moves:** run `bin/backup` on the host, copy it off the box, and do one restore to a throwaway stack. Confirm the password-manager copy of `DATA_ENCRYPTION_KEY` (`docs/ONE-TIME-SETUP.md:49`).
3. **Decide where customer data lives.** Put tfvars, overlays and `customers.json` in a new private repo, or keep names out of this one. Do not flip this repo private while app repos are public (8c).
4. **Agree the dev cutover design** in 8c before writing `dev/docker-compose.yml`.
5. **Settle the four backend prerequisites** in 8a: Mailpit TLS, MinIO endpoint, worker command, and whether Redis has a consumer.

### P1: during the revamp

6. Replace the admin PAT with a GitHub App scoped to `hrms-deployment`, and add it as a ruleset bypass (`scripts/setup-github.sh:158-162`).
7. Add a pre-migrate backup to `deploy-dev.sh` (`scripts/deploy-dev.sh:39`).
8. Add a config rollback path: on push-triggered failure, redeploy the previous commit's files or open an alert with revert instructions (`.github/workflows/deploy-dev.yml:183`).
9. Add resource limits and hardening to `db`, `caddy`, `backup`; healthchecks to `caddy` and `backup` (`environments/dev/docker-compose.yml:42,176,197`).
10. Enable off-host backups with lifecycle; move `backup` to a read-only role if practical (`environments/dev/docker-compose.yml:204-205`).
11. Verify signatures in dev, sharing the logic with prod (`.github/workflows/deploy-prod.yml:99-108`).
12. Pin Terraform and tflint versions (`.github/workflows/terraform.yml:35-38`).
13. In new modules: add `kms:Decrypt` to the plan role, allow SMTP egress, split execution roles per task class, add `wafv2:*`/`us-east-1` handling to the SCP (`terraform/modules/account-baseline/main.tf:127-130`, `terraform/modules/hrms-stack/network.tf:213-229`, `terraform/modules/hrms-stack/compute.tf:55`, `terraform/modules/org-guardrails/main.tf:33-36`).
14. Redact plan and ops-task output from public logs (`.github/workflows/terraform.yml:90,101`, `scripts/deploy-prod.sh:87-88`).
15. Set `NOTIFY_WEBHOOK_URL` or equivalent (`.github/workflows/deploy-dev.yml:199`).

### P2: cleanup

16. Remove dead scripts and ECR resources; rewrite stale docs (section 3).
17. Reconcile tags on each deploy to avoid dropped dispatches, for example by reading the newest published tag (`.github/workflows/deploy-dev.yml:73-74`).
18. Pin infra images by digest; add GHCR retention (`environments/dev/docker-compose.yml:43,177,222`, `.github/workflows/_app-publish.yml:59`).
19. Close port 22 after testing and fixing SSM, or use Tailscale or similar (`docs/RUNBOOK.md:119-126`, `scripts/lib/ssm-deploy-dev.sh:13,19`).
20. Remove the host IP and the seed password from public files (`docs/RUNBOOK.md:33`, `scripts/e2e-seeded.sh:10`).
21. Move tokens to `env:` in workflows; validate `run_url` (`.github/workflows/deploy-dev.yml:75,96`).
22. Put the dev host in Terraform (`docs/ONE-TIME-SETUP.md:36-39`).
23. Clear the Dependabot backlog (`.github/dependabot.yml`).

---

## 8. Revamp impact map

### 8a. What must carry over from Compose

#### Backend prerequisites (these change the plan)

| Brief item | State today | Needed |
|---|---|---|
| **Redis** | No client in `hrms-backend/package.json`; jobs are DB-claimed; "not needed" was a recorded decision (`docs/DISCOVERY.md:17,39`) | An idle container unless a consumer is added. The real candidate is the per-replica rate limit (`hrms-backend/src/app.ts:95`). Decide before building; same for ElastiCache |
| **Worker** | No `worker` command (`hrms-backend/docker/entrypoint.sh:7-15`). Scheduler starts inside `serve` (`hrms-backend/src/server.ts:47`). Outbox delivery is in the scheduler loop (`hrms-backend/src/core/jobs/scheduler.ts:106-107`) | Possible with no code: same image, `serve`, `JOBS_ENABLED=true`, and `JOBS_ENABLED=false` on `backend`. But it binds a port and needs the full env: mail, SMS, `DATA_ENCRYPTION_KEY`, storage, branding. Worker down means no email. A small `worker` command is cleaner. Runs are claimed once in the DB (`hrms-backend/src/config/env.ts:49`), so enable worker first, then disable on backend |
| **Mailpit** | `requireTLS: !SMTP_SECURE` (`hrms-backend/src/core/notify/mailer.ts:23`), so plain SMTP is refused. `MAIL_TRANSPORT=log` is rejected in production (`hrms-backend/src/config/env.ts:136`). The comment at `env.ts:65` ("when offered") is wrong | Either add a backend option such as `SMTP_REQUIRE_TLS=false`, or run Mailpit with STARTTLS and a CA via `NODE_EXTRA_CA_CERTS`. Also add `notifications.email` to `ENABLED_MODULES` and `MAIL_TRANSPORT=smtp`, with `MAIL_FROM_ADDRESS` |
| **MinIO** | `new S3Client({ region })` with no endpoint or path-style (`hrms-backend/src/core/storage/index.ts:53`) | Add endpoint and `forcePathStyle` env options. Existing documents in `hrms-dev_app-storage` need migrating, or keep `STORAGE_DRIVER=local` in dev. Backup must cover MinIO data: `backup-loop.sh:12` tars `/storage` only |

#### Environment variables: exact list

Compose uses an **explicit allowlist with no `env_file:`** (`environments/dev/docker-compose.yml:102-147`), so a new backend variable does nothing until added here. Extra values in `.env` are harmless, which makes additive secret updates safe.

**Do not use service-level `env_file: .env`:** it would hand `POSTGRES_SUPERUSER_PASSWORD` and `DB_OWNER_PASSWORD` to long-running containers (`environments/dev/docker-compose.yml:79-80`). `.brandenv` holds no secrets, so `env_file:` is acceptable for it.

| Service | Variables | Lines |
|---|---|---|
| `db` | `POSTGRES_USER=postgres`, `POSTGRES_PASSWORD`, `POSTGRES_DB=postgres` | 46-49 |
| `provision` | `DB_HOST=db`, `DB_NAME=hrms`, `DB_ADMIN_USER=postgres`, `DB_ADMIN_PASSWORD`, `DB_OWNER_PASSWORD`, `DB_APP_PASSWORD`, `DATABASE_SSL=disable` | 66-73 |
| `migrate` | `DATABASE_MIGRATION_URL` (`hrms_owner`), `DATABASE_SSL=disable` | 86-88 |
| `backend` core | `NODE_ENV=production`, `HOST=0.0.0.0`, `PORT=4000`, `DATABASE_URL` (`hrms_app`), `DATABASE_SSL`, `DATABASE_POOL_MAX`, `DATA_ENCRYPTION_KEY`, `COOKIE_SECURE=true`, `TRUST_PROXY=true`, `LOG_LEVEL`, `SESSION_TTL_HOURS`, `ENABLED_MODULES`, `JOBS_ENABLED`, `MFA_ENFORCEMENT` | 104-117 |
| `backend` storage | `STORAGE_DRIVER=local`, `STORAGE_PATH=/app/storage`, `STORAGE_MAX_FILE_MB` | 118-120 |
| `backend` mail | `MAIL_TRANSPORT`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | 121-128 |
| `backend` SMS | `SMS_TRANSPORT`, `SMS_HTTP_URL`, `SMS_HTTP_AUTH_HEADER`, `SMS_HTTP_CONTENT_TYPE`, `SMS_HTTP_BODY`, `SMS_SENDER_ID`, `SMS_DLT_ENTITY_ID` | 129-135 |
| `backend` identity (`x-identity`) | `APP_URL` (required), `APP_EXTRA_DOMAINS`, `ORGANIZATION_NAME` (required), `ORGANIZATION_TIMEZONE` | 27-31 |
| `backend` + `frontend` branding (`x-branding`) | `PRODUCT_NAME`, `BRAND_NAME`, `BRAND_SHORT_NAME`, `BRAND_LOGO_URL`, `BRAND_FAVICON_URL`, `BRAND_PRIMARY_COLOR` | 33-39 |
| `backend` branding rest | `BRANDING_DIR=/app/branding`, `BRAND_SECONDARY_COLOR`, `BRAND_ACCENT_COLOR`, `BRAND_LOGIN_MESSAGE`, `BRAND_SUPPORT_EMAIL`, `BRAND_SUPPORT_PHONE`, `BRAND_HELP_URL`, `ORGANIZATION_LEGAL_NAME`, `ORGANIZATION_COUNTRY`, `ORGANIZATION_CURRENCY`, `ORGANIZATION_DATE_FORMAT`, `ORGANIZATION_FY_START_MONTH` | 136-147 |
| `frontend` | branding above, `APP_ENVIRONMENT`, `HSTS=false` | 163-166 |
| `caddy` | `SITE_ADDRESS` (required), `APP_URL`, `CADDY_REDIRECT_ADDRESSES` | 183-186 |
| `backup` | `PGHOST=db`, `PGUSER=hrms_owner`, `PGPASSWORD`, `PGDATABASE=hrms`, `TZ`, `BACKUP_AT`, `BACKUP_KEEP_DAYS` | 202-209 |
| `backup-s3` | `BACKUP_S3_URI`, `AWS_REGION` | 228-230 |
| `bootstrap` | identity, `DATABASE_MIGRATION_URL`, `DATABASE_SSL`, `BOOTSTRAP_ADMIN_EMAIL` (required), `BOOTSTRAP_ADMIN_NAME` | 241-246 |
| `demo` | `APP_URL`, `ORGANIZATION_TIMEZONE`, `DATABASE_MIGRATION_URL`, `DATABASE_SSL`, `DEMO_DATA_ALLOWED` | 260-265 |
| Tags (`versions.env`) | `BACKEND_TAG`, `FRONTEND_TAG` | `environments/dev/versions.env:3-4` |
| Prod only | `AWS_REGION`, `AWS_S3_BUCKET`, `STORAGE_DRIVER=s3`, `DATABASE_SSL=verify-full`, `DB_PORT`, `BOOTSTRAP_MODE=password`, `BOOTSTRAP_ADMIN_PASSWORD` | `terraform/modules/hrms-stack/compute.tf:107,205-206,201,279,247,251` |

Details that bite:

- Backend treats empty as unset (`hrms-backend/src/config/env.ts:116`).
- Hex colours must be quoted (`environments/dev/.env.example:7`).
- Image defaults to `DATABASE_SSL=verify-full` and the RDS CA (`hrms-backend/Dockerfile:31-32`). In-cluster Postgres on the low tier must override both.
- `.env` reads that assume keys live there: `SITE_ADDRESS` (`scripts/deploy-dev.sh:28`) and `APP_ENVIRONMENT` (`environments/dev/bin/demo-data:9`).
- **Silent failure with `.brandenv`:** brand values use `${VAR:-}` (`environments/dev/docker-compose.yml:34-39`). If `.brandenv` is not passed they go blank, the backend falls back to `LabHRMS` defaults, and the smoke test's title check still passes (`scripts/smoke-test.sh:32`). Only `ORGANIZATION_NAME` fails loudly. Add a smoke check for the expected brand.
- **Three `--env-file` sites must change together:** `environments/dev/bin/dc:5`, `scripts/deploy-dev.sh:26`, `.github/workflows/lint.yml:42`.
- **`.brandenv` is not gitignored** (`.gitignore:1-3` matches `.env` and `.env.*` only). If committed, it is public and rsync delivers it. If it is meant to be private, it needs a secret and a write step at `.github/workflows/deploy-dev.yml:135`.

#### Profiles

`tools` (`bootstrap`, `demo`; lines 237, 256) and `s3backup` (`backup-s3`; line 221). `COMPOSE_PROFILES` comes from `.env` (`environments/dev/.env.example:28`). `deploy-dev.sh` passes `--profile tools` for bootstrap (`scripts/deploy-dev.sh:45`), and `bin/demo-data` for demo (`environments/dev/bin/demo-data:13`). Lint enables both (`.github/workflows/lint.yml:42`). New optional MinIO fits as a profile; add it to the lint line.

#### Sequence

```
Compose graph: db (healthy) -> provision (done) -> migrate (done) -> backend (healthy) + frontend (healthy) -> caddy
Deploy script: pull -> up db --wait -> run provision -> run migrate -> up --remove-orphans --wait --wait-timeout 180
               -> run bootstrap -> poll /ready and /healthz (30 × 4s) -> check via Caddy -> prune images
```

Evidence: `environments/dev/docker-compose.yml:74-75,89-90,100-101,180-182`, `scripts/deploy-dev.sh:37-69`.

Must preserve:

- Hard-coded names in the script: `pull db backend frontend caddy backup`, `run provision`, `run migrate`, `bootstrap`, `exec backend`, `exec frontend` (`scripts/deploy-dev.sh:37,40-41,45,55`). Renaming any service breaks the deploy.
- Setup link handling: `setup#token=` lines go to `setup-link.txt`, never logs (`scripts/deploy-dev.sh:45-49`). The ECS log tail filters too (`scripts/deploy-prod.sh:88`).
- Superuser only in `db` and `provision`; owner only in one-offs (and today's `backup` exception); `hrms_app` for runtime. The server refuses superuser or BYPASSRLS roles (`hrms-backend/src/server.ts:32`).
- `provision` re-applies role passwords each run, which is the rotation mechanism (`docs/RUNBOOK.md:63`).
- Migrate takes an advisory lock (`hrms-backend/src/db/migrate.ts:53`), so concurrent runs serialize.
- `/ready` returns 503 until migrations are applied **and** a tenant exists (`hrms-backend/src/app.ts:109,112-113`).

**Kubernetes:** bootstrap must run before readiness can pass. Compose gets away with bootstrap after `up` only because its healthcheck uses `/health` (`environments/dev/docker-compose.yml:153`). Follow the prod order instead: provision, migrate, bootstrap, then roll (`scripts/deploy-prod.sh:96-114`). Kustomize has no hooks and Job specs are immutable, so give Jobs a per-release suffix and have the pipeline wait on each. Keep `provision` out of initContainers so app pods never see superuser credentials. Prod uses `BOOTSTRAP_MODE=password`; Compose uses the setup link.

#### Read-only rootfs and container hardening

```yaml
read_only: true; tmpfs: ["/tmp"]; cap_drop: ["ALL"]; security_opt: ["no-new-privileges:true"]
```

From `environments/dev/docker-compose.yml:15-19`, applied to `provision`, `migrate`, `backend`, `frontend`, `bootstrap`, `demo`. Backend also has `init: true`, `stop_grace_period: 30s` (lines 97, 99). Logging is `json-file` at 10m × 5 (lines 21-24).

| Compose | Kubernetes |
|---|---|
| `read_only: true` | `readOnlyRootFilesystem: true` |
| `tmpfs /tmp` | `emptyDir` at `/tmp`. **Required by frontend**: it renders to `/tmp/hrms` and nginx includes from there (`hrms-frontend/docker/40-hrms-runtime.sh:7`, `hrms-frontend/docker/nginx.conf:16-17`) |
| `cap_drop ALL`, `no-new-privileges` | `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false` |
| Image UID | `runAsUser: 1000` backend, `101` frontend; `fsGroup: 1000` for storage (`hrms-backend/Dockerfile:48,50`) |
| `init: true` | `shareProcessNamespace` or accept node as PID 1; ECS uses `initProcessEnabled` (`terraform/modules/hrms-stack/compute.tf:168`) |
| `stop_grace_period: 30s` | `terminationGracePeriodSeconds: 30` |

New `worker` needs the same block. Redis, Mailpit and MinIO need their own writable paths.

#### Network layout

```
internal (internal: true, no egress): db, provision, migrate, backend, backup, bootstrap, demo
edge: backend, frontend, caddy, backup-s3
published: caddy 80, 443 only
```

Evidence: `environments/dev/docker-compose.yml:52,76,91,151,167,187-189,194,216,233,249,268,271-274`.

Placement:

- Redis and MinIO: `internal`.
- Mailpit: `internal` for SMTP. Attach to `edge` for the UI only behind Caddy auth; never publish it open. It would hold every email a dev box sends.
- `worker`: `internal` plus `edge` if it needs real SMTP, SMS or HTTP egress. An `internal`-only worker has no egress.
- Do not publish MinIO's console.

Routing must stay identical or auth breaks: `/api/*`, `/health`, `/health/*`, `/ready`, `/branding/*` to `backend:4000`, the rest to `frontend:8080`, preserving Host (`environments/dev/Caddyfile:8-16`, `docs/ARCHITECTURE.md:41`). The backend answers only configured hostnames (`docs/DEPLOYMENT.md:95`). HSTS exactly once: proxy sets it and `HSTS=false` on frontend (`environments/dev/docker-compose.yml:166`, `environments/dev/Caddyfile:19`). Set `TRUST_PROXY=true`.

**Keep Caddy for dev rather than Traefik.** `caddy-data` holds the live certificate (`environments/dev/docker-compose.yml:192`). Changing proxy means fresh ACME issuance against rate limits and re-proving each smoke assertion: HSTS, CSP, nosniff, HTTP redirect (`scripts/smoke-test.sh:33-35,45`). A smoke failure triggers rollback.

#### Backup scripts

| Item | Detail | Lines |
|---|---|---|
| Format | `hrms-<YYYYmmdd-HHMMSS>/{db.dump, documents.tar.gz, SHA256SUMS}`, custom-format `pg_dump --no-owner` | `environments/dev/bin/backup-loop.sh:8-14` |
| Schedule | Poll every 30s at `BACKUP_AT` (container `TZ`), retain `BACKUP_KEEP_DAYS` | `environments/dev/bin/backup-loop.sh:5,16,22-29` |
| Mounts | `./bin/backup-loop.sh:/scripts/backup-loop.sh:ro` (**relative path**), `backups:/backups`, `app-storage:/storage:ro` | `environments/dev/docker-compose.yml:211-213` |
| On-demand | `bin/backup` execs `--now` inside the running service | `environments/dev/bin/backup:7` |
| Restore | Needs `--confirm <project>`, verifies sums, drops and recreates DB, restores with `--role=hrms_owner`, restores docs into `${PROJECT}_app-storage` with `chown 1000:1000`, runs `up --wait` | `environments/dev/bin/restore:9-30` |
| Off-host | `backup-s3` syncs hourly, using instance role, on `edge` | `environments/dev/docker-compose.yml:220-233` |

Revamp edits:

- **`bin/restore:16` stops only `backend frontend`.** Add `worker`, or it reconnects during `DROP DATABASE` and the restore fails.
- `sha256sum` (`bin/restore:14`), `stat -c` (`scripts/deploy-dev.sh:15`) and `python3` (`scripts/deploy-dev.sh:27`) assume Linux. Make targets for laptops must not assume them.
- Backups do not include `DATA_ENCRYPTION_KEY`; without the same key, restored bank details are unreadable (`docs/DEPLOYMENT.md:176`).
- Existing `hrms-*` sets stay restorable if the format is unchanged.
- Fix first: P0 item 1.

#### Host details

`rsync --chmod=D750,F640` (`.github/workflows/deploy-dev.yml:133`) makes bind mounts readable only by the deploy user. `./branding` works only because `ubuntu` and `node` are both UID 1000 (`environments/dev/docker-compose.yml:149`). New bind mounts must account for this, or run as root. `chmod 750 $DEPLOY_DIR/bin/*` is hard-coded at `.github/workflows/deploy-dev.yml:134`. No `--delete` in rsync, so old files stay on the host and must be removed deliberately.

---

### 8b. Terraform reuse for new modules

All of `terraform/` is never-applied, with no state, so it can be restructured freely with no `moved` blocks (`docs/TERRAFORM.md:3`). Equally, none of it is proven: expect fixes on the first apply.

| New module | Source | Reuse | Changes needed |
|---|---|---|---|
| **vpc** | `terraform/modules/hrms-stack/network.tf:1-125` | High: 3-tier VPC, NAT switch, S3 endpoint, flow logs, locked default SG | Add `kubernetes.io/role/elb`, `internal-elb`, cluster tags to subnets (lines 29, 37). `/24` app subnets (line 36) can be tight with VPC CNI. Flow-log role from `operations.tf:1-29` |
| **rds** | `terraform/modules/hrms-stack/database.tf:1-93`, `network.tf:257-272` | High: encryption, TLS, Multi-AZ, PITR, PI, deletion protection | Ingress SGs are hard-wired to `api`, `ops` (`network.tf:265`); make it a list input. Needs KMS input. Master secret still RDS-managed |
| **s3** | `terraform/modules/hrms-stack/storage.tf:1-70`, `edge.tf:38-96` | High | Variable for bucket role. Task role policy moves to IRSA (`compute.tf:74-85`). Docs mention Object Lock, not implemented (`docs/BACKUP_AND_RESTORE.md:17`) |
| **cloudfront** | None | New | Must not cache `/api`, `/health`, `/ready`, `/env.js`, `/index.html` (`hrms-frontend/docker/nginx.conf:16-17`). Forward Host or set a domain the backend accepts (`docs/DEPLOYMENT.md:95`). Needs `us-east-1` ACM and WAF provider alias |
| **waf** | `terraform/modules/hrms-stack/edge.tf:235-364` | High: all 4 rules, body-size override, redactions | Parameterise `scope` (line 238), association (lines 334-337). **SCP blocks it:** `wafv2:*` is not in the global exemption list (`org-guardrails/main.tf:33-36`), so `CLOUDFRONT` scope in `us-east-1` is denied **[platform]**. Add it or allow `us-east-1`. Metric alarm dims in `operations.tf:84-87` |
| **acm** | `terraform/modules/hrms-stack/edge.tf:1-33` | High | Region alias for CloudFront; two-step customer DNS flow stays |
| **route53** | `terraform/modules/hrms-stack/edge.tf:15-25,223-233` | Medium | Alias target is `aws_lb.this` (lines 229-230). With an Ingress-created ALB, Terraform does not know it; pass as input, or use external-dns |
| **iam** | `terraform/modules/account-baseline/main.tf:71-143`, `hrms-stack/compute.tf:498-548`, `:68-85` | Medium | Baseline OIDC, terraform and plan roles reuse as is, plus `kms:Decrypt` for the plan role. `hrms-release` rewritten for `eks:DescribeCluster` and RBAC. Task roles become IRSA or Pod Identity. Execution role goes away |
| **secrets** | `terraform/modules/hrms-stack/database.tf:95-169`, `compute.tf:465-472`, `main.tf:38-87` | High | Keep names (`hrms/database-url`, etc.). Add External Secrets or CSI. Create a KMS module first: every other module depends on `aws_kms_key.main`. Add service principals if needed. Registry secret becomes imagePullSecret source. **Generated `random_bytes.data_key` must never be replaced** (`database.tf:114-116,130`) |
| **backup** | `terraform/modules/hrms-stack/operations.tf:110-166` | High | Selection takes ARNs as inputs (line 165). k3s tier with in-cluster Postgres needs logical dumps instead; AWS Backup does not cover it |
| **monitoring** | `terraform/modules/hrms-stack/operations.tf:31-108,168-186` | Medium | ALB, RDS and WAF alarms reuse with inputs. `api-running-tasks` (lines 80-83) is ECS-specific; replace with kube-state-metrics. ALB dims use `aws_lb.this` (line 46) and target groups (lines 58, 62), which are controller-managed under EKS. `/hrms/*` log groups (`compute.tf:10-16`) go away unless Fluent Bit writes to them |
| **elasticache** | None | New | No consumer yet (8a). Backend must support TLS and auth before this is useful. Needs its own SG pattern from `network.tf` |
| **eks** | None | New | Trust pattern from `compute.tf:498-516`. Node SG feeds RDS and ALB rules. **Egress must allow 587/465** or the same SMTP bug recurs (`network.tf:213-229`). Unknown-Host 404 must be reproduced by Ingress host rules (`edge.tf:148-163`) |
| Keep as is | `terraform/modules/org-guardrails`, `terraform/modules/shared-services` (state bucket part: lines 111-176), roots `terraform/envs/{organization,shared-services}` | | Delete ECR and build role from shared-services. `allowed_account_ids` pattern (`envs/customer/main.tf:27`) stays. |
| Tests | `terraform/modules/hrms-stack/tests/stack.tftest.hcl:100-291` | Partial | Validation tests (`:157-179`, `:201-207`, `:250-264`, `:286-291`) port directly. ECS JSON assertions must become manifest checks, for example with `kubeconform` |

---

### 8c. Reusable workflows and dev pipeline mechanics

#### What the app repos call

| Caller | Workflow | Inputs |
|---|---|---|
| `hrms-backend/.github/workflows/ci.yml:16-19` | `_app-ci.yml@main` | `app: backend`, `postgres: true` |
| `hrms-backend/.github/workflows/publish-develop.yml:18-21` | `_app-ci.yml@main` | `app: backend`, `postgres: true` |
| `hrms-backend/.github/workflows/publish-develop.yml:28-32` | `_app-publish.yml@main` | `app: backend`, `mode: develop`, `secrets: inherit` |
| `hrms-backend/.github/workflows/release.yml:41-46` | `_app-publish.yml@main` | `app: backend`, `mode: release`, `version`, `secrets: inherit` |
| `hrms-frontend/.github/workflows/ci.yml:16-18` | `_app-ci.yml@main` | `app: frontend` |
| `hrms-frontend/.github/workflows/publish-develop.yml:18-20,27-31` | both | as backend, no `postgres` |
| `hrms-frontend/.github/workflows/release.yml:41-46` | `_app-publish.yml@main` | as backend |

**Input contracts**

- `_app-ci.yml:7-18`: `app` (required), `postgres` (default false), `node-version` (default 22).
- `_app-publish.yml:10-27`: `app`, `mode` (required), `version`, `deployment-repo` (default `hrms-deployment`), optional secrets `DEPLOY_APP_PRIVATE_KEY`, `DEPLOY_REPO_TOKEN`. Reads caller var `DEPLOY_APP_ID` (line 127).

**Must not change without coordinated app-repo PRs**

| Item | Why | Evidence |
|---|---|---|
| Filenames `_app-ci.yml`, `_app-publish.yml`, ref `main` | Callers reference them literally; `.github/workflows/` cannot be nested **[platform]** | Table above |
| `_app-publish.yml` path and branch | Part of the cosign identity. A rename means **all earlier images fail verification** | `.github/workflows/deploy-prod.yml:102`, `.github/workflows/rollback-prod.yml:86` |
| Job names `Lint, test, build`, `Image build + Trivy`, `gitleaks` | Required checks in the app-repo rulesets; a rename blocks every app PR | `.github/workflows/_app-ci.yml:25,69,130`, `scripts/setup-github.sh:153` |
| Event types `deploy-dev`, `release-prod` and payload keys `app`, `tag`, `run_url` | Dispatch contract | `.github/workflows/_app-publish.yml:146,159-161`, `.github/workflows/deploy-dev.yml:10,62-64` |
| Dockerfile at repo root | `_app-ci` and `_app-publish` assume it | `.github/workflows/_app-ci.yml:78,83`, `.github/workflows/_app-publish.yml:76` |
| Repo name `hrms-deployment`, owner | Callers, default input, cosign regex, OIDC | `.github/workflows/_app-publish.yml:22`, `terraform/modules/hrms-stack/variables.tf:168` |
| **Repo visibility** | Public callers cannot use a private reusable workflow **[platform]**; `access_level=user` covers only private callers. Verify, but assume going private breaks all app CI and dev deploys | `scripts/setup-github.sh:63-66`; **[live]** all public |

`deploy-dev.yml` itself can be renamed: it is reached by event type, not filename. `.github/workflows/demo-data-dev.yml:18` shares its concurrency group `deploy-dev`, which should stay.

#### Paths that break if files move

| Path or mechanic | Reference | Failure mode |
|---|---|---|
| `environments/dev/versions.env` | `.github/workflows/deploy-dev.yml:68`, `:100` | `cp` fails in Resolve tags. Rollback is skipped because `ready` is unset, so dev keeps running the old version, but **every deploy fails and those tags are lost until the next merge** |
| `environments/dev/` rsync, `cp` of `versions.prev.env` and `deploy-dev.sh` | `.github/workflows/deploy-dev.yml:131-133` | Deploy fails |
| Push path filter | `.github/workflows/deploy-dev.yml:14-16` | Config changes silently stop deploying |
| `environments/dev` bundle (SSM) | `scripts/lib/ssm-deploy-dev.sh:15-16` | SSM path fails (not live) |
| Compose, `bin/demo-data` | `.github/workflows/demo-data-dev.yml:55-57` | Demo workflow fails |
| `working-directory` and shellcheck paths | `.github/workflows/lint.yml:33-36` | Required check `lint` fails, **blocking all PRs to main** |
| `.env.example` location and name | `.github/workflows/lint.yml:38`, `.github/workflows/deploy-dev.yml:133` | Lint fails; rsync copies the example to the host |
| `git log -S ... -- environments/dev/versions.env` | `.github/workflows/release-prod.yml:69` | Silent: PR shows "not found" for the dev link. History needs both paths |
| Dependabot directory | `.github/dependabot.yml:12` | Silent: updates stop |
| `.gitignore` paths | `.gitignore:17-18` | `dev/backups/`, `dev/setup-link.txt` not ignored |
| `DEV_ENV_FILE_PATH` example | `docs/ONE-TIME-SETUP.md:56`, `scripts/setup-github.sh:10` | Docs |
| Docs | `README.md:7`, `docs/RUNBOOK.md:12,22,48,102-103`, `docs/ARCHITECTURE.md:28,58,60`, `docs/ONE-TIME-SETUP.md:44,56,59`, `docs/DEPLOYMENT.md:4,15,36`, `environments/prod/README.md`, `.github/pull_request_template.md:7` | Docs |

**Must stay on the host and in config**

| Item | Why | Evidence |
|---|---|---|
| `/opt/hrms/dev` | `.env`, `setup-link.txt`, `demo-credentials.txt` live here | `.github/workflows/deploy-dev.yml:36`, `.github/workflows/demo-data-dev.yml:22`, `scripts/lib/ssm-deploy-dev.sh:10` |
| Flattened layout | `deploy-dev.sh` does `cd "$(dirname "$0")"` and expects Compose, `.env`, `versions.env`, `bin/` beside it | `scripts/deploy-dev.sh:8,14,22` |
| **Project name `hrms-dev`** | Volumes `hrms-dev_db-data`, `_app-storage`, `_backups`, `_caddy-data`, `_caddy-config`. Without `name:` or `COMPOSE_PROJECT_NAME`, the project is named after the folder and starts with **empty volumes**. The port guard should stop it, since the old project still holds 80/443 | `environments/dev/docker-compose.yml:10`, `environments/dev/.env.example:12`, `scripts/deploy-dev.sh:31-34` |
| `[skip ci]` in bot commits | With a PAT, the push would otherwise retrigger deploys via the path filter | `.github/workflows/deploy-dev.yml:14,99`, `.github/actions/bot-token/action.yml:3-4` |
| Bot push to `main` with admin PAT | Ruleset needs the bypass | `.github/workflows/deploy-dev.yml:101`, `scripts/setup-github.sh:158-162` |
| Tag format | `^(sha-[0-9a-f]{7,40}\|v[0-9]+\.[0-9]+\.[0-9]+)$`; keys `BACKEND_TAG`, `FRONTEND_TAG` with `sed`; sourced by shell | `.github/workflows/deploy-dev.yml:70-71,83`, `scripts/deploy-dev.sh:22` |
| Smoke URL, `DEV_SITE`, env `dev` | Branch policy allows `main` only **[live]**, so **deploy-dev cannot be tested from a feature branch** | `.github/workflows/deploy-dev.yml:42-44,170`, `scripts/setup-github.sh:102` |
| Secret-before-code | `.env` is overwritten every deploy from `DEV_ENV_FILE`, so a new required `:?` variable missing from it fails `dc config` at the first line and also breaks rollback | `.github/workflows/deploy-dev.yml:135`, `scripts/deploy-dev.sh:27` |
| `bin/dc` and restore project lookup | Assume compose in parent of `bin/` | `environments/dev/bin/dc:4`, `environments/dev/bin/restore:10` |

#### Does renaming break `dev.rgrishabh.in` auto-deploy?

**Yes, if `deploy-dev.yml` is not changed with it.** The running site itself stays up, since failure happens before the host is touched. But auto-deploys fail.

**App repos need no change for an `environments/dev` to `dev/` move**: they only send the event.

**Three extra hazards with the move:**

1. **No safety net.** On a push-triggered failure, `BUMP_SHA` is unset and "previous" tags equal current, so rollback restarts the same broken Compose (`.github/workflows/deploy-dev.yml:80,102,179-183`). Fix requires a manual revert.
2. **In-flight race.** A queued run uses the workflow file from its trigger SHA, but checks out latest `main` **[platform]** (`.github/workflows/deploy-dev.yml:47-48`). A dispatch queued just before the merge runs old YAML against new paths and fails. Bot retries via `pull --rebase` also meet the rename (`.github/workflows/deploy-dev.yml:101`).
3. **Merge conflicts.** Each app merge changes `environments/dev/versions.env` on `main` (51 runs in about 2 days **[live]**), while `feature/hrms-revamp` is local only. Rebase late, and take `main`'s tags.

#### Recommended cutover: variable-switched, three steps

Use one directory variable, and keep the old stack until the new one is proven.

**Step 0, before merging anything**

- Run a manual backup and copy it off the host (P0 items 1-2).
- Add new keys to `DEV_ENV_FILE`. Additive is safe because of the allowlist. Keep `COMPOSE_PROJECT_NAME=hrms-dev` and a literal `name:` in the new file.
- Rehearse the new Compose on a throwaway host (`deploy-dev.yml` cannot run from a branch). Use a separate domain, and restore a real backup into it.

**Step 1, PR: no behaviour change**

- Add `dev/` alongside `environments/dev`.
- Parameterise `deploy-dev.yml`, `demo-data-dev.yml`, `ssm-deploy-dev.sh`, with `STACK_DIR=${{ vars.DEV_STACK_DIR || 'environments/dev' }}`.
- Add both paths to the push filter, lint both, make `release-prod.yml:69` search both.
- Merge. Confirm the next real deploy still succeeds.

**Step 2, flip**

- Pause merges to `develop` in both app repos and let the queue drain.
- Copy the current tags into `dev/versions.env` in one commit.
- Set `DEV_STACK_DIR=dev`, then run *Deploy dev* manually.
- Check site, login, brand, `/ready`, documents, and that the `hrms-dev_*` volumes were reused (`bin/dc ps`, `docker volume ls`).
- **Rollback is unsetting the variable and redeploying.** Copy the newer tags back if any deployed.

**Step 3, after a few green deploys and one backup cycle**

- Delete `environments/dev`, the variable and the fallback.
- Update `.gitignore`, Dependabot, lint, docs.
- Remove stale host files by hand, since rsync does not delete.
- Update `bin/restore` before this step if worker exists.

If a one-shot PR is preferred, the same list applies in one commit, with merges paused and a prepared revert. It has no instant rollback and is not recommended on a live box.

---

### 8d. What is removed with ECS, and the consequences

**There is no data or runtime to migrate:** no customers, no applied infra, no `prod-*` environments **[live]**. No customer impact.

| Removed | Evidence | Consequence and replacement |
|---|---|---|
| ECS cluster, 4 task defs, 2 services, autoscaling | `terraform/modules/hrms-stack/compute.tf:1-8,182-325,328-461` | Move sizing and limits to tier overlays. CPU + request autoscaling becomes HPA, request metric needs an adapter. Fargate's per-task isolation is lost: add PodSecurity `restricted`, NetworkPolicy, and do not run customers on a shared cluster |
| Circuit breaker auto-rollback | `compute.tf:349-352`, `scripts/deploy-prod.sh:114-119` | `kubectl rollout status` + `rollout undo` in the pipeline, or Argo Rollouts |
| `scripts/deploy-prod.sh` | `scripts/deploy-prod.sh:1-130` | Rewrite. **Keep the behaviours:** snapshot before migrations (`:47-52`), abort on Job failure (`:89-93`), restore on smoke failure (`:128`), token filter (`:88`), mutable tag refusal (`:24-26`). The snapshot needs `rds:CreateDBSnapshot` on the new role for RDS tiers, and a logical dump on k3s |
| Registration via `describe`/`register` | `scripts/deploy-prod.sh:55-72` | `kustomize edit set image name@digest`. **Keep digest pinning** |
| `deploy-prod.yml` | `.github/workflows/deploy-prod.yml` | Rewrite the deploy step. **Keep:** cosign verify (`:99-108`), account check (`:114-119`), environment approval (`:55-57`), revert and alert (`:125-147`). The alert reads SSM `/hrms/release/alarm_topic` (`:144`), so create it or change it |
| `rollback-prod.yml` | `.github/workflows/rollback-prod.yml:102-105` | Same replacement; `--skip-migrations` semantic stays. Relies on expand/contract (`docs/RUNBOOK.md:17-18`) |
| `release-prod.yml` | `.github/workflows/release-prod.yml:60-64,102` | Survives if `versions.env` stays. If tags move to `kustomization.yaml`, rewrite the `sed` and `add-paths`. Keep the event listener name |
| `hrms-release` role | `compute.tf:498-548`, `outputs.tf:19-22` | New role with EKS access entry. `setup-github.sh:125` writes the ARN by name; **keep the name** or change that line. k3s tier needs a kubeconfig or agent, so no OIDC path exists there as designed. Decide this early |
| ALB rules, target groups, listener | `terraform/modules/hrms-stack/edge.tf:98-221` | AWS Load Balancer Controller or Traefik on k3s. Must keep `drop_invalid_header_fields`, TLS policy, access logs, Host allowlist. Also `deletion_protection` |
| Execution role, GHCR `repositoryCredentials` | `compute.tf:35-65,160,465-472`, `scripts/set-registry-credentials.sh` | imagePullSecret from the same secret. Consider the script's fate; docs cite it (`docs/ONE-TIME-SETUP.md:97-98`). Public images would make this moot; **[unknown]** package visibility |
| `/hrms/release/*` SSM params | `compute.tf:476-493`, `scripts/deploy-prod.sh:30-35` | Pipeline loses its source of cluster, subnets, DB id, domain. Keep a similar set for cluster name, DB id, domain |
| SGs `api`, `web`, `ops` | `terraform/modules/hrms-stack/network.tf:172-255` | NetworkPolicy plus node SG. Port SG intent: frontend no DB, ops no ingress, and fix SMTP egress |
| CloudWatch log groups, Container Insights | `compute.tf:3-6,10-16` | Fluent Bit and metrics stack; add to tier cost. Runbook commands change (`docs/RUNBOOK.md:36-39`) |
| `ecs:` references in tests and docs | `terraform/modules/hrms-stack/tests/stack.tftest.hcl:100-291`, `docs/ARCHITECTURE.md:12,33-35,77-78`, `docs/TERRAFORM.md:31`, `README.md:23`, `docs/OPERATIONS_RUNBOOK.md:7,29` | Rewrite |
| `terraform.yml` | `.github/workflows/terraform.yml:47` | Keep, change test path and the `terraform/envs/customer` assumption (`:83`, `:140`). k3s tiers may need a different root |
| Env values from task defs | `compute.tf:106-179,200-207,242-247,276-287` | Become Kustomize base + ConfigMap + secrets. Test `app_container_gets_same_configuration_as_compose` (`stack.tftest.hcl:100`) guards parity today; add a replacement that compares Compose and Kustomize keys |

**Prod tiers and customers.** Each tier overlay needs its own decision on `customers.json` schema (`environments/prod/customers.json:2`, `environments/prod/README.md:8`). Add `tier`; `region`, `domain`, `account_id` are consumed in `.github/workflows/deploy-prod.yml:57,113,116` and `.github/workflows/rollback-prod.yml:69`. k3s tiers may have no AWS account, so the account check and OIDC do not apply.

---

### 8e. All SMS references

#### hrms-deployment (complete: every line matching `sms`, case-insensitive)

| File | Lines | What |
|---|---|---|
| `docs/DEPLOYMENT.md` | 123 | Module list, env names, secret name |
| `environments/dev/.env.example` | 53-57, 59-63 | Section header, doc comments, 7 variables (line 58 is a related comment without the word) |
| `environments/dev/docker-compose.yml` | 129-135 | 7 pass-through variables |
| `terraform/customers/_template.tfvars` | 50-53, 57 | Comments, `sms = {}` block (block spans 53-60) |
| `terraform/envs/customer/terraform.tfvars.example` | 50-53, 57 | Same |
| `terraform/envs/customer/main.tf` | 54 | `sms = var.sms` |
| `terraform/envs/customer/variables.tf` | 46 | `variable "sms"` (block 46-50) |
| `terraform/modules/hrms-stack/compute.tf` | 55, 147-156, 200, 211 | Execution role grant, `sms_env`, `sms_env_list`, `sms_secret`, env and secret injection |
| `terraform/modules/hrms-stack/database.tf` | 149-152 | Secret `hrms/sms-auth-header` (block 150-156) |
| `terraform/modules/hrms-stack/variables.tf` | 96-97, 108-110 | Variable and validation (block 96-112) |
| `terraform/modules/hrms-stack/tests/stack.tftest.hcl` | 266-291 | Tests `sms_auth_header_only_from_secrets_manager`, `sms_needs_https` |

Introduced by `5ab6503`. Absent where one might expect it: `docs/DEPLOYMENT.md:138-144` and `docs/RUNBOOK.md:61-71` have no SMS row, and there is no reference in workflows or scripts. `DEV_ENV_FILE` may hold values **[unknown]**.

Note: `ssm` in `scripts/lib/ssm-deploy-dev.sh` and `.github/workflows/deploy-dev.yml` is AWS Systems Manager, unrelated.

#### hrms-backend (count of matching lines per file)

| File | Lines | Role |
|---|---|---|
| `src/core/notify/service.ts` | 23 | Dispatch and outbox delivery |
| `test/sms.test.ts` | 23 | Tests |
| `docs/SMS.md` | 21 | Docs |
| `src/modules/sms/routes.ts` | 20 | `/api/v1/sms` |
| `src/core/notify/sms.ts` | 18 | Sender |
| `src/config/env.ts` | 11 | Schema and validation (`:55-62,137-139`) |
| `migrations/025_sms.sql` | 9 | Schema |
| `src/app.ts`, `src/core/features/state.ts`, `src/modules/auth.ts` | 6 each | Wiring, feature state, user preference |
| `docs/API.md` | 3 | Docs |
| `src/core/jobs/scheduler.ts`, `IMPLEMENTATION_PLAN.md`, `test/helpers.ts` | 2 each | Delivery loop (`:7,107`), docs, test helper |
| `CHANGELOG.md`, `docs/NOTIFICATIONS.md`, `src/core/features/registry.ts` (`:83`), `src/core/http/context.ts`, `test/features-settings.test.ts` | 1 each | |

#### hrms-frontend

`src/pages/SmsSettings.tsx` (20), `src/main.tsx` (7), `e2e/sms.e2e.ts` (3), `src/pages/Settings.tsx` (3), `.github/workflows/e2e.yml` (2, includes `SMS_TRANSPORT=log` at `:75`), `src/auth.tsx` (1).

#### If the intent is to remove SMS

The brief as given lists references only, so this is conditional. Order matters:

1. Remove `notifications.sms` from `ENABLED_MODULES` in `DEV_ENV_FILE` **first**. Unknown modules stop startup (`environments/dev/.env.example:38`, `docs/DEPLOYMENT.md:125`), which on dev triggers a failed deploy.
2. Remove backend code. **Do not delete `migrations/025_sms.sql`**, because `schema_migrations` records it as applied. Add a new migration to drop tables and the `users.sms_notifications` column, expand/contract style (`docs/RUNBOOK.md:17-18`, `hrms-backend/src/modules/auth.ts:104`).
3. Remove frontend page and preference; drop `SMS_TRANSPORT` from `e2e.yml:75` (Zod ignores unknown keys, so order here is not critical).
4. Remove the Compose and `.env.example` entries; harmless to do early since the backend defaults to `disabled` (`hrms-backend/src/config/env.ts:56`).
5. Terraform: since it is being restructured anyway, do not port SMS items into `secrets` or the new overlays. Update `compute.tf:55` if `compute.tf` survives at all.
