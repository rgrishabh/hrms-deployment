# New client onboarding

**Goal:** a new client running in under 30 minutes of your attention. AWS still needs time to build things, shown separately below. The one-host row is measured, see below. The AWS rows are estimates, because nothing here has run against a real account yet: expect the first run to take longer, and fix this page as you go.

| Path | Your time | Machine time |
|---|---|---|
| On-prem, one host | 5 minutes | 3 minutes, plus DNS and a certificate on `tls` |
| `prod-low` | 20 minutes | About 25 minutes |
| `prod-mid`, `prod-high` | 30 minutes | About 50 minutes, plus a second apply |

**Before you start, once only:**

- Set up the AWS organization, guardrails and state bucket (`terraform/envs/organization`, `shared-services`; see [TERRAFORM.md](TERRAFORM.md)).
- Have the app repos' release builds pass `platforms: linux/amd64,linux/arm64`, because the tiers use Graviton.

**For each client, have ready:**

- A dedicated AWS account, and admin credentials for it
- A private Git repository for the client's values. **Do not put these in this repository: it is public.**
- The client's domain, and access to its DNS
- Logo, colours, locale, timezone, and SMTP credentials if they have them
- The first administrator's name and email, and an address for alarms

## On-prem or a single host

```bash
cd dev
make init                    # creates .env and .brandenv, generates secrets
$EDITOR .brandenv            # the client: name, domain, colours, locale
$EDITOR .env                 # COMPOSE_PROFILES=tls, NODE_ENV=production, SMTP_*, BOOTSTRAP_ADMIN_*
cp logo.png brand/           # and BRAND_LOGO_URL=/brand/logo.png. PDFs draw a PNG or JPEG, not an SVG
$EDITOR versions.env         # released tags for both apps
make up
cat setup-link.txt           # one-time link for the first administrator; delete it afterwards
```

**To try it on a laptop,** edit only `BOOTSTRAP_ADMIN_*` in `.env` and the tags in `versions.env`. The defaults give plain HTTP at `http://localhost:8088`. To build the images rather than pull a release, see "Building images on a laptop" in the [RUNBOOK](RUNBOOK.md#the-dev-stack).

**Measured:** 176 seconds from `git clone` to a signed-in administrator, on 2026-11-05: an arm64 laptop, Colima with 4 CPUs and 5 GiB, plain HTTP. Building both images with an empty cache took 80 seconds, and `make up`, pulling five images, 95. Your time to edit the files is on top, and pulling released images replaces the build. The AWS paths have not been timed.

Point DNS at the host first, with ports 80 and 443 open, or use `CADDY_TLS="tls internal"`. Keep a copy of `.env` in a password manager: **without `DATA_ENCRYPTION_KEY`, restored bank details are unreadable.** Add the `s3backup` profile, or another off-host copy.

## prod-low (k3s) or prod-mid and prod-high (EKS)

### 1. Terraform values (5 minutes)

In the client's repository:

```bash
ENV=prod-low     # or prod-mid, prod-high
D=../hrms-deployment/terraform/envs/$ENV
cp $D/terraform.tfvars.example terraform.tfvars
cp $D/backend.hcl.example backend.hcl
$EDITOR terraform.tfvars backend.hcl
```

### 2. First apply (2 minutes, then wait)

```bash
terraform -chdir=$D init -backend-config=$PWD/backend.hcl
terraform -chdir=$D apply -var-file=$PWD/terraform.tfvars
```

If the client runs its own DNS, this waits on certificate validation. Open a second terminal, and send them `terraform output acm_validation_records`.

On `prod-low` the node starts installing as soon as it boots, and retries until step 3 is done.

### 3. Secrets and overlay (5 minutes)

```bash
terraform -chdir=$D output -json overlay_values > /dev/null    # confirm the outputs exist
../hrms-deployment/scripts/generate-data-key.sh "$(terraform -chdir=$D output -raw kms_key_id)" ap-south-1
aws secretsmanager put-secret-value --secret-id hrms/smtp-credentials \
  --secret-string '{"user":"<user>","password":"<password>"}'      # read these from a file, not shell history
# Optional: metrics_token, vapid_private_key, in hrms/runtime-optional, also as JSON. Empty means off.
../hrms-deployment/scripts/new-client-overlay.sh $D overlay <deployment-tag>
```

### 4. The client's identity (5 minutes)

This is the same as `.brandenv` on Compose. Nothing is rebuilt.

```bash
$EDITOR overlay/brand.env    # BRAND_DOMAIN and the rest; check with dev/bin/check-brandenv overlay/brand.env
$EDITOR overlay/app.env      # FEATURE_* flags, ORG_MANAGEMENT_MODE, SMTP_HOST
cp logo.svg overlay/brand/
$EDITOR overlay/kustomization.yaml    # add logo.svg to hrms-brand-files
../hrms-deployment/scripts/k8s-release.sh overlay sha256:<backend> sha256:<frontend> <version>
git add . && git commit -m "onboard <client>" && git push
```

Get digests from the release notes, or from `docker buildx imagetools inspect ghcr.io/rgrishabh/hrms-backend:<version>`. Add repository credentials to `hrms/argocd-repo` if the repository is private:

```bash
aws secretsmanager put-secret-value --secret-id hrms/argocd-repo \
  --secret-string file://repo-credentials.json    # {"url":"git@github.com:...","sshPrivateKey":"..."}
```

### 5. Start the deployment

**`prod-low`:** Argo CD comes up on the node by itself. If the first boot ran before step 4, replace the node once, so it picks up the credentials: `aws autoscaling start-instance-refresh --auto-scaling-group-name hrms-k3s`.

**`prod-mid`, `prod-high`:** with `endpoint_public_cidrs` set to your address (5 minutes):

```bash
aws eks update-kubeconfig --name hrms --region ap-south-1
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version 10.12.1 --namespace argocd --create-namespace --values argocd/bootstrap/values.yaml
```

Copy `argocd/project.yaml`, `hrms.yaml` and `addons.yaml` to the client's repository, and replace `CLIENT_ORG/CLIENT` and the add-on's `REPLACE_*` values from `terraform output addon_values`, then `kubectl apply` them.

### 6. Second apply: `prod-mid` and `prod-high` only (3 minutes, then wait)

The first sync creates the ALB. Then:

```bash
kubectl -n hrms get ingress hrms
# set origin_alb_dns_name and alb_arn_suffix in terraform.tfvars, and endpoint_public_cidrs = []
terraform -chdir=$D apply -var-file=$PWD/terraform.tfvars
```

### 7. DNS and first sign-in (2 minutes)

- With a Route 53 zone, the records are already made.
- Otherwise, point the domain at `terraform output alb_dns_name` (low) or `cloudfront_domain_name` (mid, high).
- Get the administrator's temporary password from `hrms/bootstrap-admin-password`, and hand it over securely. It must be changed at first sign-in.

### 8. Verify

```bash
../hrms-deployment/scripts/smoke-test.sh https://<domain> --expect-brand "<BRAND_NAME>"
```

Then sign in, upload a document, and check that an email arrives. Confirm the alarm email subscription: AWS sends a link to `alarm_emails`, and alarms reach nobody until it's clicked. The `freshclam` alarm fires until the first hourly check has run: that is expected.

### 9. Releases from now on

To have the pipeline deploy this client, add it to `environments/prod/customers.json` with `gitops_repo`, copy `environments/prod/_template/` to `environments/prod/<slug>/`, and give the `prod-<slug>` environment a `GITOPS_TOKEN` ([environments/prod/README.md](../environments/prod/README.md)).

## Afterwards

| Change | Do |
|---|---|
| New logo or colours | Edit `brand.env` or `overlay/brand/`, push |
| Turn a feature on | Edit `app.env`, push |
| New release | `scripts/k8s-release.sh`, push ([RUNBOOK](RUNBOOK.md)) |
| Move up a tier | One line in the overlay, plus the larger Terraform root. Moving from low to mid moves a database and a cluster, so plan it as a migration |
