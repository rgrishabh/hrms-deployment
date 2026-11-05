# Cutover plan

This takes `dev.rgrishabh.in` from `environments/dev` to `dev/`, then removes ECS. Only a person with access to GitHub settings and the dev host can run it. No step has been run.

## What makes this tricky

- **The old stack cannot run the new backend.** It sets `ENABLED_MODULES` and `MFA_ENFORCEMENT`, and the new backend refuses to start when those are set.
- **The new stack cannot run the old images.** The old backend has no `worker` command, and its required variables have different names.
- So the app images and the stack must change together, even though `docs/CONFIGURATION.md` is right that this repository merges first. If a new backend image reaches `develop` before the flip, its automatic deploy fails and rolls back. The site stays up, but the run is red and the tag is reverted.
- `deploy-dev.yml` cannot be tested from a branch: the `dev` environment allows `main` only.

## Step 0: before merging anything

1. On the host, take a backup and copy it off the box. Use `bin/backup` in `/opt/hrms/dev`.
2. Restore that copy into a throwaway stack. Confirm the password-manager copy of `DATA_ENCRYPTION_KEY`.
3. Check `DEV_ENV_FILE` for `notifications.sms` in `ENABLED_MODULES`. If it's there, remove it and redeploy first: this repository's merge stops passing `SMS_*` to the backend, and a module with no transport may stop startup.
4. Rehearse `dev/` on a throwaway host with a separate domain, restoring the real backup into it. A clean install has run on a laptop, so `clamav` with `/init-unprivileged`, `up --wait` with the one-offs and the worker are proven there. Prove these, which have not run yet:
   - non-root Postgres on the restored volume, which the first stack created
   - non-root Caddy on a copied `caddy-data`, and the `tls` profile at all
   - on `amd64`: the laptop run was `arm64`
   - total memory: the limits add up to about 6 GB, and idle use was about 1.3 GB, so check the instance size

## Step 1: merge this repository (no behaviour change)

Merge to `main`, late, taking `main`'s tags for `environments/dev/versions.env`. `DEV_STACK_DIR` is unset, so everything still uses `environments/dev`. The merge touches paths in the push filter, so it redeploys the old stack once. Confirm that run is green.

## Step 2: flip, together with the new images

1. In *Actions → Deploy dev*, disable the workflow, so that app dispatches do nothing for now. This is safe: tags dropped here are set explicitly below.
2. Merge `hrms-backend` and then `hrms-frontend` to `develop`. Note the two `sha-<short>` tags their publish runs produce.
3. Build the new settings from your local copy of the old `.env`, using `dev/.env.example` and the map in `docs/CONFIGURATION.md`:
   - **Copy exactly:** `POSTGRES_SUPERUSER_PASSWORD`, `DB_OWNER_PASSWORD`, `DB_APP_PASSWORD`, `DATA_ENCRYPTION_KEY`
   - **New:** `REDIS_PASSWORD`
   - **Set:** `COMPOSE_PROFILES=tls`, `CADDY_GLOBAL_OPTIONS=email <you>`, `BOOTSTRAP_ADMIN_*`
4. Set these in the `dev` environment. Secret values stay out of shell history: read them from a file.
   ```bash
   gh secret set DEV_ENV_FILE_V2 --env dev --repo rgrishabh/hrms-deployment < dev.env
   gh variable set DEV_BRANDENV --env dev --repo rgrishabh/hrms-deployment < dev.brandenv
   gh variable set DEV_EXPECT_BRAND --env dev --repo rgrishabh/hrms-deployment --body "<BRAND_NAME>"
   ```
5. Set the repository variable last: `gh variable set DEV_STACK_DIR --repo rgrishabh/hrms-deployment --body dev`
6. Enable the workflow, then run *Deploy dev* with both tags.
7. Check the site, sign-in, branding, `/health/ready`, a document upload, email in Mailpit, and that the volumes were reused:
   ```bash
   ssh <dev-host> 'cd /opt/hrms/dev && bin/dc ps && docker volume ls | grep hrms-dev_'
   ```

**To go back:** clear the variable with `gh variable delete DEV_STACK_DIR --repo rgrishabh/hrms-deployment` and run *Deploy dev* with no inputs. `environments/dev/versions.env` still holds the old tags. `scripts/deploy-dev.sh` removes the `postgres` container before starting `db`, and `--remove-orphans` clears the rest.

If the new backend's migrations already dropped something the old image reads, this rollback will not be enough: restore the Step 0 backup with `bin/restore`.

## Step 3: after a few green deploys and one backup cycle

1. Delete `environments/dev`, the `DEV_STACK_DIR` fallback, `DEV_ENV_FILE`, and the rollback guard in `scripts/deploy-dev.sh` (and that script, if unused).
2. Rename `DEV_ENV_FILE_V2` if you like.
3. Update `.gitignore`, Dependabot, `lint.yml`, the push filter and the docs.
4. Remove stale files from the host by hand, because rsync does not delete: `branding/`, `Caddyfile` is replaced, old `bin/` entries.
5. Remove the old-path branch from `scripts/smoke-test.sh`.

## Step 4: remove ECS and move prod to Kubernetes

Before the first client on the new tiers:

1. `deploy-prod.yml` and `rollback-prod.yml` already pin digests in the client's repository. They have never run. Give each customer `gitops_repo` in `customers.json` and a `GITOPS_TOKEN` in `prod-<slug>`, then prove them on a first client. `release-prod.yml` is unchanged: tags still live in `environments/prod/<slug>/versions.env`.
2. Decide whether alerts on a failed deploy should also go to the account's SNS topic. The ECS version read the topic from an SSM parameter that the new tiers do not create, so today only `NOTIFY_WEBHOOK_URL` and GitHub's own notification tell anyone.
3. Delete `terraform/modules/hrms-stack`, `terraform/envs/customer`, `terraform/customers`, `scripts/deploy-prod.sh`, `scripts/set-registry-credentials.sh`, and the ECS parts of `docs/TERRAFORM.md`, `docs/DEPLOYMENT.md` and `docs/OPERATIONS_RUNBOOK.md`.
4. Reduce `terraform.yml` to what `infra-checks.yml` does not cover. Remove the skip paths for those directories from `.checkov.yaml` and `.trivy.yaml`.
