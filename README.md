# hrms-deployment

Environments, infrastructure and pipelines for HRMS. Application code lives in
[hrms-backend](https://github.com/rgrishabh/hrms-backend) and [hrms-frontend](https://github.com/rgrishabh/hrms-frontend).

```
dev/                         Compose stack: dev, laptops, on-prem clients. Makefile, .env + .brandenv examples, brand/, tests
environments/dev/            The stack live on dev.rgrishabh.in until the cutover (docs/CUTOVER.md)
environments/prod/<slug>/    versions.env per customer + customers.json, for the ECS design, until the cutover
k8s/                         base, components/tier-{low,mid,high}, overlays/prod (client template), Kyverno policies
argocd/                      Argo CD project, Application and add-ons
terraform/modules/           kms vpc acm route53 waf s3 rds elasticache secrets iam eks k3s cloudfront backup monitoring
                             + org-guardrails, account-baseline, shared-services, and hrms-stack (ECS, until the cutover)
terraform/envs/              prod-low, prod-mid, prod-high (+ organization, shared-services, customer)
scripts/                     deploy, smoke test, k8s build and release, client overlay, data key, config parity
.github/workflows/           _app-ci, _app-publish (called by the app repos), deploy-dev, infra-checks, lint, terraform, release and rollback
docs/                        See below
```

**Status.** The dev pipeline is live. Everything under `k8s/`, `argocd/` and the new Terraform roots passes static checks only: nothing has been applied to any AWS account or cluster, and `dev/` has not run against a Docker daemon.

## Documentation

| To | Read |
|---|---|
| Understand the tiers | [ARCHITECTURE](docs/ARCHITECTURE.md) |
| Decide where a setting lives | [CONFIGURATION](docs/CONFIGURATION.md) |
| Set up a new client | [NEW_CLIENT_ONBOARDING](docs/NEW_CLIENT_ONBOARDING.md) |
| Operate a stack | [RUNBOOK](docs/RUNBOOK.md) |
| Move dev to the new stack, and remove ECS | [CUTOVER](docs/CUTOVER.md) |
| Estimate costs | [COST_ESTIMATES](docs/COST_ESTIMATES.md) |
| Plan recovery | [DR](docs/DR.md) |
| Review the security posture | [THREAT_MODEL](docs/THREAT_MODEL.md) |
| See why something is this way | [DECISIONS](DECISIONS.md) |
| Set up this repository's pipelines | [ONE-TIME-SETUP](docs/ONE-TIME-SETUP.md) |

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
