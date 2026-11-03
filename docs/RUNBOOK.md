# Runbook

Day-to-day operations for dev (`dev.rgrishabh.in`, EC2 + Compose) and production (one AWS account per customer).
Deeper app-level procedures are in [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md) and [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md).

## Deploy

| What | How |
|---|---|
| Dev, normal | Merge to `develop` in an app repo. It deploys automatically |
| Dev, specific tags | *Actions → Deploy dev → Run workflow* with `backend_tag` / `frontend_tag` (e.g. `sha-1a2b3c4`, `v1.4.0`) |
| Dev, config change | Edit `environments/dev/**` on `main` (PR). It redeploys automatically. Change `.env` values via the `DEV_ENV_FILE` secret, then run *Deploy dev* |
| Prod release | Merge the app's release-please PR → a PR "chore(prod): release hrms-<app> vX.Y.Z" appears here → merge it → approve `prod-<slug>` |
| Prod, one customer only | Edit `environments/prod/<slug>/versions.env` in a PR, merge, approve |
| Prod, re-run | *Actions → Deploy prod → Run workflow* with `customer` (deploys the current `versions.env`) |

Migrations must be **expand/contract**: a release may add columns, tables or indexes and must keep working with the previous
release's code. Removals ship one release later. This is what makes rollbacks safe.

## Roll back

- **Dev:** automatic on a failed deploy. Manual: *Deploy dev* with the previous tags (see `git log environments/dev/versions.env`).
- **Prod:** automatic when a rollout or smoke test fails (previous task definitions, `versions.env` reverted).
  Manual, one click: *Actions → Rollback prod → customer* (empty tags = previous versions from git history) → approve.
  It skips migrations; the backend stays ready on the newer schema.
- **Data:** a release always takes an RDS snapshot first (`hrms-pre-<tag>-<time>`). Restoring one is a separate,
  deliberate step (see "Restore a database backup").

## View logs

```bash
# dev
ssh ubuntu@3.104.1.47 'cd /opt/hrms/dev && bin/dc logs -f --tail 200 backend'      # or frontend, caddy, db, backup
ssh ubuntu@3.104.1.47 'cd /opt/hrms/dev && bin/dc ps'
# prod (customer account credentials)
aws logs tail /hrms/api --follow --since 30m      # backend (JSON)
aws logs tail /hrms/web --follow                  # frontend nginx
aws logs tail /hrms/ops --since 2h                # provision / migrate / bootstrap one-off tasks
aws ecs describe-services --cluster hrms --services hrms-api hrms-web --query 'services[].{svc:serviceName,deploy:deployments[].{s:status,td:taskDefinition,r:rolloutState}}'
```

CloudWatch alarms (5xx, p95 latency, unhealthy API/web targets, task count, RDS CPU/storage/connections, WAF) notify the
account's SNS topic. Failed deploys also publish there.

## Rotate secrets

| Secret | Where | Rotate |
|---|---|---|
| Dev DB passwords | `DEV_ENV_FILE` | Change `DB_OWNER_PASSWORD` / `DB_APP_PASSWORD` in the file, `gh secret set DEV_ENV_FILE --env dev < .env`, run *Deploy dev* (`provision` re-applies role passwords) |
| `DATA_ENCRYPTION_KEY` | dev env file / Secrets Manager `hrms/data-encryption-key` | **Not by replacement**: needs the re-encryption job (docs/OPERATIONS_RUNBOOK.md) |
| Dev SSH key | env `dev` → `DEV_EC2_SSH_KEY` | Add the new public key to `~ubuntu/.ssh/authorized_keys`, update the secret, run *Deploy dev*, remove the old key |
| Dev host key (rebuilt host) | env `dev` → `DEV_EC2_HOST_KEY` | `ssh-keyscan <host>`, verify the fingerprint, update the variable |
| GitHub App key / PAT | app repos + hrms-deployment | Generate new, re-run `scripts/setup-github.sh` with it, revoke the old one |
| GHCR pull token (prod) | each account: `hrms/registry-credentials` | `printf '%s' "$NEW" \| scripts/set-registry-credentials.sh rgrishabh` (running tasks keep working; new tasks use it) |
| RDS master | AWS-managed secret | Rotates automatically (RDS-managed) |
| App DB roles (prod) | Secrets Manager `hrms/db-*-password` | Put new values, then run a release (provision re-applies them) |
| SMTP password | `.env` (dev) / `hrms/smtp-password` (prod) | Update, then redeploy (dev) / force a new deployment (prod) |

## Restore a database backup

**Dev (nightly sets in the `backups` volume, optionally copied to S3):**

```bash
ssh ubuntu@3.104.1.47
cd /opt/hrms/dev
bin/dc exec backup ls /backups                         # hrms-YYYYMMDD-HHMMSS
bin/dc cp backup:/backups/hrms-20261103-023000 /tmp/restore-set
bin/restore /tmp/restore-set --confirm hrms-dev        # replaces DB + documents, restarts the stack
```

**Prod (RDS):** restore a snapshot or point in time to a **new** instance, verify it, then switch. Never restore over the live
instance. Follow BACKUP_AND_RESTORE.md (snapshot `hrms-pre-<tag>-*` for a release, AWS Backup for older points).

## Add a customer

1. Create the AWS account and the files: `terraform/customers/<slug>.tfvars` and `<slug>.backend.hcl` (copy `_template.*`).
   Use `backend_image`/`frontend_image` = the current release.
2. First apply with admin credentials (docs/TERRAFORM.md). Then fill `hrms/registry-credentials` (`scripts/set-registry-credentials.sh`).
3. Add `{ "slug", "account_id", "region", "domain", "enabled": true }` to `environments/prod/customers.json` and
   copy `environments/prod/_template/` to `environments/prod/<slug>/`.
4. Re-run `scripts/setup-github.sh` (creates `prod-<slug>` with `AWS_DEPLOY_ROLE_ARN`, and `infra-<slug>`).
5. Open a PR. CI plans the new account; merge applies it (approve `infra-<slug>`) and deploys `versions.env` (approve `prod-<slug>`).

## Add a new service

1. Create the repo from either app repo. Keep `Dockerfile`, `.github/workflows/{ci,publish-develop,release}.yml` calling
   `_app-ci` / `_app-publish` with a new `app:` name, and release-please config.
2. In this repo, add `<APP>_TAG` to `environments/dev/versions.env` and each `environments/prod/*/versions.env`. Add the
   service to `environments/dev/docker-compose.yml` (and a Caddy route if it serves HTTP).
3. Extend the app allow-lists in `deploy-dev.yml` (`case "$P_APP"`) and `release-prod.yml`, and the signature checks in `deploy-prod.yml`/`rollback-prod.yml`.
4. Prod: add a task definition, service and target group/listener rule to `terraform/modules/hrms-stack` and a `register`
   line in `scripts/deploy-prod.sh`. Add `UpdateService` for it to the release role.
5. Run `scripts/setup-github.sh` for the new repo (rulesets, dispatch secret). Grant its package access to hrms-deployment.

## Mirror images to ECR (alternative to GHCR pulls in prod)

If GHCR transfer quotas or availability are a concern, copy the verified image into the customer account's ECR during
deploy and point the task definitions there:

1. Create an ECR repository per app (immutable tags, scan on push) and pass its ARNs as `ecr_repository_arns`; set `private_registry = false`.
2. In `deploy-prod.yml`, after signature verification: `crane copy ghcr.io/…@sha256:… <acct>.dkr.ecr.<region>.amazonaws.com/hrms-backend:vX.Y.Z`
   (log in with `aws ecr get-login-password`), then call `deploy-prod.sh` with the ECR references.
3. Add `ecr:*` push permissions for those repositories to the `hrms-release` role.

## Close port 22 on the dev host (SSM path)

1. Attach an instance role with `AmazonSSMManagedInstanceCore`, plus `s3:GetObject` on `s3://<bucket>/hrms-dev/*` and
   `ssm:GetParameter` on `/hrms/dev/*` (with KMS decrypt).
2. Create an OIDC role for `repo:rgrishabh/hrms-deployment:environment:dev` allowing `ssm:SendCommand` on the instance,
   `ssm:GetCommandInvocation`, `ssm:PutParameter`/`DeleteParameter` on `/hrms/dev/*`, and S3 put/delete on the bucket prefix.
3. Set env `dev` vars: `DEV_DEPLOY_METHOD=ssm`, `DEV_AWS_ROLE_ARN`, `DEV_INSTANCE_ID`, `DEV_ARTIFACT_BUCKET`. Remove the
   SSH rule from the security group. (This path is implemented in `scripts/lib/ssm-deploy-dev.sh` but has not been run yet.)
