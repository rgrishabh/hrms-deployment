# Runbook

Day-to-day operations for dev (`dev.rgrishabh.in`, EC2 + Compose) and production.
Deeper app-level procedures are in [OPERATIONS_RUNBOOK.md](OPERATIONS_RUNBOOK.md) and [BACKUP_AND_RESTORE.md](BACKUP_AND_RESTORE.md).

Three things are in transition, and this page says which it means:

- **Dev:** `environments/dev` is live until the variable `DEV_STACK_DIR` is set to `dev` ([CUTOVER.md](CUTOVER.md)). Sections below written for it say `db`; on the new stack that service is `postgres`. Everything else carries over, and the commands are in [The dev/ stack](#the-dev-stack).
- **Prod on ECS:** the sections below mentioning ECS describe a design that was never run, and it goes away in the cutover.
- **Prod on Kubernetes:** see [Kubernetes tiers](#kubernetes-tiers). Manifests pass static checks, but have never run on a cluster.

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

## Add a customer (ECS design, until the cutover)

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
| Migration state | `make migrate-status` (exit 2 pending, exit 3 database ahead of this image) |
| Undo migrations | `make migrate-down ARGS="--steps 1"`, see [Roll back the dev/ stack](#roll-back-the-dev-stack) |
| Re-encrypt after a key change | `make rotate-keys` |
| Demo data | `make seed` |
| Backup now | `make backup` |
| Restore | `make restore SET=path/to/hrms-<ts> CONFIRM=hrms-dev` |
| Offline tests | `make test` |

**Local access.** With `COMPOSE_PROFILES=local`, the site is at `http://localhost:8088`. Copy `docker-compose.override.example.yml` to `docker-compose.override.yml` for caught email at `http://localhost:8025`. `PUBLIC_URL` in `.env` gives links in email their port. An older `.env` without it has links with no port, so add the line from `.env.example`. `setup-link.txt` has the port either way.

**Change the brand without a rebuild.** Edit `.brandenv`, then `bin/dc up -d --no-deps backend worker frontend`. Only those three are recreated, from the same images. On the `tls` profile add `caddy` if the domain changed. Logos go in `brand/`: PDFs draw a PNG or JPEG, and anything else prints the brand name.

**Removing a stack.** `bin/dc down -v` deletes the data. Giving `--profile` on the command line replaces `COMPOSE_PROFILES`, and services of any profile not named are left running, so name them all or none.

**Is the worker alive?** `bin/dc exec worker hrms worker-health` exits 0 when its heartbeat is fresh and a scheduler pass is not stuck. The health check runs the same command. It says why when it fails.

**Metrics.** `/metrics` answers 404 at Caddy, and at the ALB on the Kubernetes tiers. Prometheus scrapes `backend:4000` (`hrms-backend:4000` in a cluster) directly. Read it from inside: `bin/dc exec backend wget -qO- --header "Authorization: Bearer $(sed -n 's/^METRICS_TOKEN=//p' .env)" http://127.0.0.1:4000/metrics`.

**MinIO instead of the local volume.** In `.env`: `COMPOSE_PROFILES=local,minio`, `STORAGE_DRIVER=s3`, `S3_ENDPOINT=http://minio:9000`, `AWS_S3_BUCKET=hrms-documents`, and `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY`. Then `make up`. The bucket is created for you, and backups include it. Documents already in the local volume do not move.

**Building images on a laptop.** `docker build` needs buildx. If your Docker client has none, Colima's VM does: `colima ssh -- sh -c "cd $PWD/../../hrms-backend && docker build -t ghcr.io/rgrishabh/hrms-backend:local ."`, the same for the frontend, and put `local` in `versions.env`. The plugin for `docker compose` may need `"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]` in `~/.docker/config.json`.

### Roll back the dev/ stack

Move `versions.env` back, and `make up`. The older image runs on a newer schema: migrations are expand/contract, and `migrate` ignores applied migrations it does not ship. `/health/ready` stays 200 and logs a warning.

If the older image cannot work with the newer schema, undo first, **while `versions.env` still names the newer image**, because the down files are in the image being left:

```bash
make backup
make migrate-status                   # how far ahead
make migrate-down ARGS="--steps 1"    # or --to NAME; there is no default
# now change versions.env, and:
make up
```

Dropped data and scrubbed plaintext do not return, only their structure. To get data back, use `make restore`.

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

A failed Job stops the sync before the apps change.

`deploy-prod.yml` does this for you when a `versions.env` change reaches `main`, after the `prod-<slug>` approval: it verifies the signatures, checks the account, takes the snapshot, commits the digests to the client's repository, waits for the new version and runs the smoke test. On failure it puts the client's repository and `versions.env` back, and alerts `NOTIFY_WEBHOOK_URL` and the account's `hrms-alarms` SNS topic. Running it by hand instead, take the snapshot first:

```bash
aws rds create-db-snapshot --db-instance-identifier hrms-db --db-snapshot-identifier hrms-pre-1-2-0
```

`/health` does not report the backend's version yet. On a backend-only release the pipeline waits 10 minutes rather than seeing the rollout finish, so a slow sync can pass the smoke test on the old image. Argo CD's own status is the authority.

**Why the release id must change.** A Job's spec cannot be edited. A new image under the same Job name makes the sync fail, and a new name is a new Job. The previous release's Jobs are pruned once they leave the manifest. Without Argo CD, apply in the same order, using `kubectl wait --for=condition=complete job/<name>` between Jobs, and delete old Jobs yourself.

### Roll back

Run *Actions → Rollback prod*, or revert the commit in the client's repository. Either way it reuses the old release id, which is fine: that release's Jobs were pruned and are recreated, provision and migrate are idempotent, and `migrate` ignores applied migrations it does not ship. Neither changes the schema.

Usually that is enough, because migrations are expand/contract and the old image tolerates the newer schema. If it does not, undo the migrations **first, while the newer image is still running**. The down files are in the image being left, and `scripts/k8s-ops-job.sh` uses whichever image `hrms-backend` is running now:

```bash
aws rds create-db-snapshot --db-instance-identifier hrms-db --db-snapshot-identifier hrms-pre-rollback-1-2-0
scripts/k8s-ops-job.sh migrate-status              # exit status is in the logs: pending, unknown
scripts/k8s-ops-job.sh migrate-down --steps 1      # or --to NAME; there is no default
# now run Rollback prod, typing "compatible", or revert the commit
```

The pipeline cannot do this for you: it has no access to the cluster. Pause Argo CD's auto-sync first if a sync could start while this runs. Dropped data and scrubbed plaintext do not return, only their structure; for those, restore the snapshot to a new instance. The new image's pods will fail readiness between the down and the rollout, so expect an outage for that time.

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
| Alarm `freshclam` | Signatures older than 96 hours, or no report for 2 hours. `kubectl -n hrms logs job/<latest hrms-freshclam-check>`, then `logs deploy/hrms-clamav`. It also fires until the first sync has run |
| Alarm `db-replica-lag` | Reports are stale, and still correct as of the delay. Check the replica's load in Performance Insights |
| Worker restarts, `worker unhealthy: no heartbeat` | The process is stuck or cannot write `/tmp`. `kubectl -n hrms logs deploy/hrms-worker --previous` |

### Rotate secrets (Kubernetes tiers)

| Secret | Rotate |
|---|---|
| `hrms_owner`, `hrms_app` | Bump `password_version` in the `secrets` module and apply, then cut a release, so that provision re-applies them. Expect brief errors until pods restart with the new secret |
| RDS master | RDS-managed. Provision reads the current value at each release |
| SMTP | `aws secretsmanager put-secret-value --secret-id hrms/smtp-credentials`, then restart backend and worker |
| Redis AUTH token | `terraform taint` the `random_password` in `elasticache`, apply, and restart pods |
| Data key | **Never by replacement.** Put the old ciphertext in `data_key_ciphertext_previous` in `hrms/runtime-optional` and the new one in `hrms/data-key-ciphertext`, let External Secrets sync, restart the pods, run `scripts/k8s-ops-job.sh rotate-keys`, then clear the previous value |
| `METRICS_TOKEN`, `VAPID_PRIVATE_KEY` | Set them in `hrms/runtime-optional`, JSON with `metrics_token`, `vapid_private_key` and `data_key_ciphertext_previous`. Restart backend and worker. Empty means unset |
