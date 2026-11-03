# Infrastructure: one AWS account per customer

> **Status: written and statically validated, never applied.** Every module and root passes `terraform validate` and `fmt`, and `modules/hrms-stack/tests/` runs offline plan/apply tests with mock providers (`terraform test`): container configuration, secret scoping, ALB host rules, input validation. No `plan` or `apply` has been run against a real AWS account yet. The first real deployment (staging) is when this gets proven. Expect fixes there.

## Layout

```
infra/
  modules/
    hrms-stack/        everything inside one customer account (VPC, RDS, ECS, ALB, WAF, KMS, S3, secrets, alarms, backups, budget, release role)
    account-baseline/  per-account security baseline + GitHub OIDC roles (terraform, terraform-plan)
    shared-services/   ECR image registry, Terraform state bucket, image-build role
    org-guardrails/    service control policies for the Customers OU
  live/
    customer/          ONE root used for every customer account (config comes from customers/)
    shared-services/   root for the Shared Services account
    organization/      root for the management account (SCPs)
  customers/
    customers.json     release/infra targets: staging + customers, rollout order, canary flags
    <slug>.tfvars      per-customer settings
    <slug>.backend.hcl per-customer state location
    _template.*        copy these for a new customer
```

## What each customer account contains

| Layer | Resources |
|---|---|
| Network | VPC across 2 AZs. Public subnets (ALB, NAT). App subnets (ECS tasks). Data subnets with **no internet route** (RDS). S3 gateway endpoint. Rejected-traffic flow logs. Default security group locked |
| Edge | ACM certificate (DNS-validated). ALB with TLS 1.2/1.3 only and HTTP→HTTPS redirect. **Unknown Host headers get a 404 at the ALB.** WAF: per-IP rate limit, AWS IP reputation, common rules, known bad inputs; logs with cookies, CSRF and device keys redacted |
| Compute | ECS Fargate service `hrms-api` (min 2, CPU autoscaling, circuit breaker with automatic rollback, read-only root filesystem). One-off task definitions `hrms-ops` (migrate, bootstrap) and `hrms-dbadmin` (provisioning; the only task that can read the RDS master secret) |
| Data | RDS PostgreSQL 17, Multi-AZ, gp3, KMS-encrypted, TLS forced (`rds.force_ssl`), PITR, Performance Insights, deletion protection, final snapshot |
| Secrets | RDS master password managed by RDS. App and owner DB URLs, field-encryption key and first-admin password in Secrets Manager (KMS) |
| Storage | Private documents bucket (KMS, versioned, TLS-only). ALB access-log bucket |
| Operations | CloudWatch alarms → SNS (email): 5xx, unhealthy targets, p95 latency, DB CPU/storage/connections, running tasks, WAF spikes. AWS Backup daily (RDS + documents), optional cross-account copy. Monthly budget alerts |
| Access | `hrms-release` (pipeline: deploy releases only), `hrms-terraform` (infra apply; approved environment only), `hrms-terraform-plan` (PR plans; read-only, cannot read secrets) |

## One-time setup (done once for the whole platform)

1. **AWS Organizations / Control Tower** in a new management account. Create OUs: `Infrastructure` (Shared Services, Log Archive, Security) and `Customers`. Enable IAM Identity Center for staff access (SSO, MFA). Control Tower provides the organization CloudTrail and the Log Archive / Audit accounts.
2. **Shared Services account:** apply `live/shared-services` with local state, then migrate its state into the bucket it created (instructions in its `main.tf`). Set the GitHub repository variable `SHARED_ACCOUNT_ID`.
3. **Guardrails:** apply `live/organization` from the management account with `customers_ou_id`.
4. **GitHub environments:** `staging` (no approval), `production` (required reviewers), and one `infra-<slug>` per customer (required reviewers).
5. **Staging account:** onboard it like a customer (below) using `customers/staging.tfvars`.

## Onboarding a customer

1. **Create the account** with Control Tower Account Factory in the `Customers` OU. Note the account id.
2. **Config:** copy `customers/_template.tfvars` → `customers/<slug>.tfvars` and `_template.backend.hcl` → `<slug>.backend.hcl`. Fill in account id, slug, domains, `organization`, `branding`, `enabled_modules`, admin email and sizing (same meaning as the Compose `.env`; see DEPLOYMENT.md §3). Add the customer to `customers/customers.json` with `"canary": false`. Open a PR and merge it.
3. **First apply** by an administrator via SSO, because the pipeline's role doesn't exist yet in the new account:
   ```bash
   cd infra/live/customer
   terraform init -reconfigure -backend-config=../../customers/<slug>.backend.hcl
   terraform apply -var-file=../../customers/<slug>.tfvars
   ```
   - **If we host the DNS zone** (`route53_zone_id` set): the certificate validates automatically and the apply completes.
   - **If the customer manages DNS**: first run `terraform apply -target=module.hrms.aws_acm_certificate.this -var-file=…`. Send the customer the `acm_validation_records` output and the `alb_dns_name` output (for their CNAME). Then run the full apply, which waits up to 2 hours for validation.

   Later infrastructure changes go through the pipeline (`infra.yml`).
4. **First release:** run the **Release** workflow (or wait for the next merge). It provisions the database, migrates, **bootstraps the organization and first admin** (password mode: temporary password from Secrets Manager, forced change at first sign-in), and starts the service.
5. **Hand over:** an operator reads the `hrms/bootstrap-admin` secret (access is logged in CloudTrail) and gives it to the customer's administrator over a secure channel. They should change it after first login.

## Releasing (`.github/workflows/release.yml`)

```
CI green on main → build image once → push to Shared Services ECR (immutable tag = commit SHA; blocked on CRITICAL scan findings)
  → staging → canary customers (approval) → everyone else (3 at a time, stop on first failure)
```

Per account, `scripts/deploy/release.sh`:
1. RDS snapshot.
2. New task definition revisions.
3. `provision` → `migrate` → `bootstrap` (any failure stops the release before traffic changes).
4. Roll the service (automatic rollback on failure).
5. Check `https://<domain>/health/ready` and the tenant branding.

## Infrastructure changes (`.github/workflows/infra.yml`)

- **PR:** `fmt` + `validate`, then a read-only plan for every account, shown in the job summary.
- **Merge:** plan + apply per account, each gated by its `infra-<slug>` environment approval, one account at a time.

## Offboarding a customer

1. Export the customer's data (procedure to be defined with legal: format, retention, hand-over).
2. Take a final manual RDS snapshot and copy it to the retention vault if the contract requires.
3. Set `deletion_protection = false` in their tfvars and apply.
4. `terraform destroy`. KMS key deletion is blocked by the guardrail SCP except for the break-glass role. That's deliberate: key destruction makes backups unrecoverable, so it's a separate, approved step.
5. Remove the customer from `customers.json` and close the account in Organizations.

## Cost notes

Every customer account pays a fixed baseline even when idle: Multi-AZ RDS instance, ALB, NAT gateway, WAF web ACL, Secrets Manager secrets, CloudWatch alarms and logs. Use the AWS Pricing Calculator with your expected sizes. Set `monthly_budget_usd` per customer. Staging uses a single-AZ database and one task to reduce cost.

## Known gaps / next steps

- Not yet applied anywhere. First `plan`/`apply` on the staging account is the next milestone.
- **Drift detection:** plans run with `-refresh=false`, so PR plans don't detect manual changes. Use AWS Config rules (enabled by Control Tower) and periodic admin `terraform plan` until a scheduled refresh-capable plan is added.
- **Central monitoring:** alarms notify per-account SNS email. Forwarding to a central topic, PagerDuty or Slack, and a cross-account CloudWatch dashboard, are follow-ups.
- **Secret rotation:** the RDS master secret can rotate with RDS-managed rotation. App and owner passwords rotate when the Terraform `random_password` is replaced, followed by a release (provision re-applies passwords). Not yet automated.
- Static security scanning of Terraform (checkov/tfsec) is not yet in CI.
