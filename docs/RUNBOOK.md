# Runbook

Day-to-day operations for dev (`dev.rgrishabh.in`, EC2 + Compose) and production.
Deeper app-level procedures are in [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md) and [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md).

Three things are in transition, and this page says which it means:

- **Dev:** `environments/dev` is live until the variable `DEV_STACK_DIR` is set to `dev` ([CUTOVER.md](CUTOVER.md)). Sections below written for it say `db`; on the new stack that service is `postgres`. Everything else carries over, and the commands are in [The dev/ stack](#the-dev-stack).
- **Prod on ECS:** the sections below mentioning ECS describe a design that was never run, and it goes away in the cutover.
- **Prod on Kubernetes:** see [Kubernetes tiers](#kubernetes-tiers). These have also never run.

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
ssh ubuntu@<dev-host> 'cd /opt/hrms/dev && bin/dc logs -f --tail 200 backend'      # or frontend, caddy, db, backup
ssh ubuntu@<dev-host> 'cd /opt/hrms/dev && bin/dc ps'
# prod (customer account credentials)
aws logs tail /hrms/api --follow --since 30m      # backend (JSON)
aws logs tail /hrms/web --follow                  # frontend nginx
aws logs tail /hrms/ops --since 2h                # provision / migrate / bootstrap one-off tasks
aws ecs describe-services --cluster hrms --services hrms-api hrms-web --query 'services[].{svc:serviceName,deploy:deployments[].{s:status,td:taskDefinition,r:rolloutState}}'
```

CloudWatch alarms (5xx, p95 latency, unhealthy API/web targets, task count, RDS CPU/storage/connections, WAF) notify the
account's SNS topic. Failed deploys also publish there.

## Load demo data on dev

For testing and demos only. Actions → **Load dev demo data** → Run workflow, type `load-demo-data`.
It runs `environments/dev/bin/demo-data` on the host, which fills an **empty, bootstrapped**
installation with a synthetic 60-person testing laboratory (attendance, leave, training and
authorizations, policies, recruitment, salaries, assets, reviews) and 10 persona logins.

- Refused unless `APP_ENVIRONMENT` is `dev`/`demo`; the backend also refuses if any real
  (non-`DM-…`) employee exists, and is a no-op when demo data is already there.
- No statutory payroll rules are created.
- Logins + password: `ssh ubuntu@<dev host> 'cat /opt/hrms/dev/demo-credentials.txt'` (mode 600,
  never in the Actions log). Privileged personas enrol two-factor authentication at first sign-in.
- To start again: restore the post-bootstrap backup, or drop the `db-data` volume and re-bootstrap.

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
ssh ubuntu@<dev-host>
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

## The dev/ stack

Works the same on the dev host, a laptop and an on-prem client. From `dev/` (`/opt/hrms/dev` on the host):

| Task | Command |
|---|---|
| First time | `make init`, fill in `.env` and `.brandenv` |
| Start in order | `make up` |
| Stop, keeping data | `make down` |
| Logs | `make logs S=backend` |
| State and health | `make ps` |
| Migrations only | `make migrate` |
| Demo data | `make seed` |
| Backup now | `make backup` |
| Restore | `make restore SET=path/to/hrms-<ts> CONFIRM=hrms-dev` |
| Offline tests | `make test` |

**Local access.** With `COMPOSE_PROFILES=local`, the site is at `http://localhost:8088`. Copy `docker-compose.override.example.yml` to `docker-compose.override.yml` for caught email at `http://localhost:8025`.

**On-prem, about 100 users.** Use a host of 4 vCPU and 8 GB, and set in `.env`:

- `NODE_ENV=production`
- `COMPOSE_PROFILES=tls` (plus `s3backup` for an off-host copy)
- real `SMTP_*` with `SMTP_SECURE=starttls`
- `MFA_AVAILABLE=true`
- `CADDY_TLS="tls internal"` if there is no public DNS, in which case users must trust Caddy's private CA

**Missing `.brandenv`.** Compose stops with `env file .brandenv not found`. `bin/check-brandenv` reports what's wrong with a partial file.

**The `backup` container is unhealthy.** Its last run failed, or the last good one is older than 26 hours. Run `make backup` and read the error. A success clears it. While it's unhealthy, `make up` also fails at `--wait`, which is deliberate: no good backup should not go unnoticed. `/backups/.hrms-*` directories hold the failed attempts for diagnosis.

**ClamAV is slow to start.** Expect a few minutes, with `WAIT_TIMEOUT` at 600 seconds. It also needs up to 2 GB of memory during a signature reload.

## Kubernetes tiers

Applied by Argo CD from the client's private repository. Base and components live here, at a fixed tag.

### Deploy a release

```bash
scripts/k8s-release.sh overlay sha256:<backend> sha256:<frontend> 1.2.0
git commit -am "release 1.2.0" && git push
```

Argo CD then works through the sync waves:

1. ExternalSecrets and other prerequisites
2. Job `hrms-provision-1.2.0`, and it waits for completion
3. Job `hrms-migrate-1.2.0`
4. Job `hrms-bootstrap-1.2.0`
5. The apps, which roll when digests or the hashed ConfigMaps change

A failed Job stops the sync before the apps change. Take an RDS snapshot before merging, until the release job in [CUTOVER.md](CUTOVER.md) Step 4 does it for you:

```bash
aws rds create-db-snapshot --db-instance-identifier hrms-db --db-snapshot-identifier hrms-pre-1-2-0
```

**Why the release id must change.** A Job's spec cannot be edited. A new image under the same Job name makes the sync fail, and a new name is a new Job. The previous release's Jobs are pruned once they leave the manifest. Without Argo CD, apply in the same order, using `kubectl wait --for=condition=complete job/<name>` between Jobs, and delete old Jobs yourself.

### Roll back

Revert the commit in the client's repository. Migrations do not run backward: they are expand/contract, so the old image tolerates the newer schema. The revert reuses the old release id, which is fine because that release's Jobs were pruned and are recreated, and provision and migrate are idempotent.

### Change settings

| Change | Edit in the client's repository |
|---|---|
| Feature flag or mode | `overlay/app.env` |
| Brand or identity | `overlay/brand.env`, `overlay/brand/` |
| Tier | One line in `overlay/kustomization.yaml`, plus the matching Terraform root |

ConfigMap names carry a hash, so a change restarts the pods that use them.

### Look at things

```bash
kubectl -n hrms get pods,jobs,externalsecrets
kubectl -n hrms logs deploy/hrms-backend --tail 100
kubectl -n hrms logs job/hrms-migrate-1.2.0
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

**Reach the cluster.** On k3s: `aws ssm start-session --target <instance>`, then `sudo k3s kubectl ...`. On EKS: add your address to `endpoint_public_cidrs` and apply, and remove it afterwards.

### Common failures

| Symptom | Likely cause |
|---|---|
| `ExternalSecret` not ready, `hrms-runtime` | `hrms/data-key-ciphertext` has no value: run `scripts/generate-data-key.sh` |
| `ImagePullBackOff` with all zeros | The overlay still has placeholder digests: run `scripts/k8s-release.sh` |
| `ImagePullBackOff`, `exec format error` | Image lacks `linux/arm64`: release builds need the `platforms` input |
| Backend restarts, naming a variable | Contract validation. Check `app.env` and `brand.env` against [CONFIGURATION.md](CONFIGURATION.md) |
| Backend stays unready | `/health/ready` needs migrations applied and a tenant: read the migrate and bootstrap Jobs |
| Email never arrives | `FEATURE_EMAIL_NOTIFICATIONS`, `hrms/smtp-credentials`, then worker logs. Egress on 587 and 465 is allowed |
| Tier-low: everything returns 503 | Node replaced and still installing. Check the ALB target group, then `journalctl -u k3s` through SSM |
| Sync blocked by a Kyverno message | A digest or limit is missing: read the message |

### Rotate secrets (Kubernetes tiers)

| Secret | Rotate |
|---|---|
| `hrms_owner`, `hrms_app` | Bump `password_version` in the `secrets` module and apply, then cut a release, so that provision re-applies them. Expect brief errors until pods restart with the new secret |
| RDS master | RDS-managed. Provision reads the current value at each release |
| SMTP | `aws secretsmanager put-secret-value --secret-id hrms/smtp-credentials`, then restart backend and worker |
| Redis AUTH token | `terraform taint` the `random_password` in `elasticache`, apply, and restart pods |
| Data key | **Never by replacement.** It needs the re-encryption job |
