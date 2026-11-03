# One-time setup

Everything here is done once. After it, a developer only pushes code, merges PRs, and approves production.
`scripts/setup-github.sh` does the GitHub part. The list below is what it cannot do for you.

> **GitHub plan:** required reviewers on environments and branch rulesets are **not available for private repos on
> GitHub Free**. Use GitHub Pro (personal) or Team, or the production approval gate and branch protection silently
> become "none". `setup-github.sh` warns when this happens.
>
> **GHCR limits:** private packages count against your plan's Packages storage and data-transfer quota (Free: 500 MB /
> 1 GB per month). Pulls from GitHub Actions are free; pulls from the dev EC2 and from AWS count. Watch
> *Settings → Billing → Packages*, or mirror to ECR (docs/RUNBOOK.md → "Mirror images to ECR").

## 1. Tools (your laptop)

```bash
brew install gh jq terraform        # also: aws CLI v2
gh auth login                       # GitHub.com, SSH, scopes: repo, workflow
```

## 2. Dispatch credentials: GitHub App (preferred) or PAT

App repos must start workflows in `hrms-deployment` (`repository_dispatch`), and bot PRs should run CI.

**GitHub App** (*Settings → Developer settings → GitHub Apps → New*): no webhook; repository permissions
**Contents: Read & write**, **Pull requests: Read & write**, **Metadata: Read**. Install it on the three repos, note
the **App ID**, and generate a **private key** (`.pem`).

**Or a fine-grained PAT**: resource owner `rgrishabh`, repositories `hrms-deployment` (plus `hrms-backend` and
`hrms-frontend` if you also use it as `RELEASE_PLEASE_TOKEN`), with **Contents RW** and **Pull requests RW**. Set an expiry and a reminder.

## 3. DNS

| Record | Value |
|---|---|
| `dev.rgrishabh.in` A | `3.104.1.47` (the dev EC2) |
| each customer domain | CNAME to the ALB DNS name (Terraform output `alb_dns_name`), or Route 53 alias when `route53_zone_id` is set |

The EC2 security group must allow 80 and 443 from anywhere (Let's Encrypt), and 22 from GitHub Actions (or use the SSM path).

## 4. Dev environment file

```bash
cd environments/dev
cp .env.example .env && bin/init-env      # generates DB passwords and the encryption key
$EDITOR .env                              # BOOTSTRAP_ADMIN_EMAIL, BRAND_SUPPORT_EMAIL, (SMTP)
```

Keep a copy in your password manager: `DATA_ENCRYPTION_KEY` cannot be recovered and encrypts bank details.

## 5. Run the GitHub setup

```bash
cd ~/hrms-repos/hrms-deployment
DEV_EC2_HOST=3.104.1.47 DEV_EC2_USER=ubuntu DEV_SITE=dev.rgrishabh.in \
DEV_EC2_SSH_KEY_FILE=~/.ssh/<dev-key> DEV_ENV_FILE_PATH=environments/dev/.env \
DEPLOY_APP_ID=<id> DEPLOY_APP_PRIVATE_KEY_FILE=~/Downloads/<app>.pem \
  scripts/setup-github.sh                 # or DEPLOY_REPO_TOKEN=<pat> instead of the two App lines
rm environments/dev/.env                  # it now lives only in the dev environment secret
```

It creates or updates the following.

| Where | Name | Kind |
|---|---|---|
| all three repos | private repo, `main` (+ `develop` for apps), squash/rebase only, auto-delete branches | settings |
| app repos | `DEPLOY_APP_ID` + `DEPLOY_APP_PRIVATE_KEY`, or `DEPLOY_REPO_TOKEN` | var + secret / secret |
| hrms-deployment | Actions access "repos of the same owner" (reusable workflows), label `release` | settings |
| env `dev` | `DEV_EC2_HOST`, `DEV_EC2_USER`, `DEV_SITE`, `DEV_EC2_HOST_KEY` (ssh-keyscan; **check the fingerprint**) | vars |
| env `dev` | `DEV_EC2_SSH_KEY`, `DEV_ENV_FILE` | secrets |
| env `prod-<slug>` | required reviewer = you; `AWS_DEPLOY_ROLE_ARN` | protection + var |
| env `infra-<slug>` | required reviewer = you (Terraform apply) | protection |
| rulesets | `main`/`develop`: PR required, checks `ci / Lint, test, build`, `ci / Image build + Trivy`, `ci / gitleaks`, linear history, no force-push. Deployment `main`: `lint`, `secrets`; bypass: admins + the bot | rulesets |

Optional: `NOTIFY_WEBHOOK_URL` (Slack/Teams), `GHCR_PULL_USER`/`GHCR_PULL_TOKEN`, `RELEASE_PLEASE_TOKEN` (app repos),
and the SSM vars (`DEV_DEPLOY_METHOD=ssm`, `DEV_AWS_ROLE_ARN`, `DEV_INSTANCE_ID`, `DEV_ARTIFACT_BUCKET`).

## 6. Package access (no API exists)

After the first push to `develop` of each app, the packages exist. For **each** package, open
`github.com/users/rgrishabh/packages/container/hrms-backend/settings` (and `hrms-frontend`), go to **Manage Actions access**,
and **add repository `hrms-deployment` with role Read**. The deploy workflows then pull with their own short-lived token.
Nothing long-lived is stored on the dev host.

## 7. First dev deploy

1. If the old demo stack still holds ports 80/443 on the host, stop it: `cd /opt/hrms/demo && docker compose down` (volumes are kept).
2. Push something to `develop` in **both** app repos (or run *Publish (develop)* manually). The second image triggers the first deploy.
3. The first deploy creates the administrator and writes the one-time setup link on the host:
   `ssh ubuntu@3.104.1.47 'cat /opt/hrms/dev/setup-link.txt && rm /opt/hrms/dev/setup-link.txt'`

## 8. Production (per customer, first time)

1. Create the customer's AWS account and apply `terraform/envs/customer` once with admin credentials
   (docs/TERRAFORM.md). This creates the OIDC provider and the `hrms-terraform`, `hrms-terraform-plan` and `hrms-release` roles.
   After that, the pipeline applies changes.
2. Fill the GHCR pull secret in that account:
   `printf '%s' "$READ_PACKAGES_TOKEN" | AWS_PROFILE=<customer> scripts/set-registry-credentials.sh rgrishabh`
3. Add the customer to `environments/prod/customers.json` and copy `environments/prod/_template` to `environments/prod/<slug>`.
   Re-run `scripts/setup-github.sh` to create `prod-<slug>` and `infra-<slug>`. Merge.

Every later release reaches the customer through a release PR plus one approval.
