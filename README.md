# hrms-deployment

Environments, infrastructure and pipelines for HRMS. Application code lives in
[hrms-backend](https://github.com/rgrishabh/hrms-backend) and [hrms-frontend](https://github.com/rgrishabh/hrms-frontend).

```
environments/dev/            Compose stack for dev.rgrishabh.in (also the self-hosted template) + versions.env (bot-managed)
environments/prod/<slug>/    versions.env per customer (changed by PRs) + customers.json (release targets)
terraform/                   modules (hrms-stack, account-baseline, …), envs (customer, organization, shared-services), customers/*.tfvars
scripts/                     bootstrap-ec2.sh, deploy-dev.sh, deploy-prod.sh, smoke-test.sh, setup-github.sh, set-registry-credentials.sh
.github/workflows/           _app-ci / _app-publish (reusable, called by the app repos), deploy-dev, release-prod, deploy-prod, rollback-prod, terraform, lint
docs/                        ONE-TIME-SETUP, ARCHITECTURE, RUNBOOK (+ DEPLOYMENT, TERRAFORM, BACKUP_AND_RESTORE, OPERATIONS_RUNBOOK, DISCOVERY)
```

## What happens automatically

| Trigger | Automatically | Human |
|---|---|---|
| PR in an app repo | lint, tests (PostgreSQL), build, audit, image build, hadolint, Trivy (CRITICAL fails), gitleaks, PR comment | review + merge |
| Merge to `develop` (app) | signed `:sha-<short>` image with SBOM/provenance → dev deploy: versions.env commit, host bootstrap, migrate, health check, smoke test, **auto-rollback** | — |
| Merge `develop` → `main` (app) | release-please opens/updates the release PR with the changelog | merge the release PR |
| Release PR merged (tag `vX.Y.Z`) | signed `:vX.Y.Z` → PR here bumping every enabled customer, with notes and the dev link | merge the PR |
| Prod PR merged | per customer: signature check, snapshot, migrations (one-off ECS task), rollout, circuit breaker, smoke test; on failure restore + revert + alert | **approve `prod-<slug>`** |
| PR touching `terraform/` | fmt, tflint, validate, module tests, read-only plan per customer as a PR comment | review |
| Merge to `main` touching `terraform/` | apply per customer | approve `infra-<slug>` |
| Something is wrong in prod | — | *Rollback prod* (one click + approval) |

Start with [docs/ONE-TIME-SETUP.md](docs/ONE-TIME-SETUP.md).
