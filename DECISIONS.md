# Decisions

Non-obvious choices in this repository. Newest last.

## ADR-001: Cut dev over with a variable and a separate settings secret

**Context.** `dev.rgrishabh.in` auto-deploys from this repository, and a bad Compose change on `main` is not rolled back automatically. The audit (8c) recommends a directory variable with the old stack kept alongside, and adding new keys to `DEV_ENV_FILE`.

**Options.** (a) Rename in one commit. (b) `DEV_STACK_DIR` plus additive keys in `DEV_ENV_FILE`. (c) `DEV_STACK_DIR` plus a second secret, `DEV_ENV_FILE_V2`.

**Decision.** (c), which differs from the audit on one point.

**Reason.** `DEV_ENV_FILE` cannot hold both stacks' settings, because the same name means different things: `SMTP_SECURE` is `true/false` for the old backend and `tls/starttls/none` for the new one. A shared file would break the rollback. With two secrets, clearing the variable always restores the old file untouched. If `DEV_ENV_FILE_V2` is empty, the expression falls back to the old file, and the new stack stops at its first required variable, before touching anything.

## ADR-002: `dev/versions.env` starts as `unset`, not with the current tags

**Context.** The audit says to copy the current tags into `dev/versions.env` at the flip. The new stack cannot run those images: it starts `worker`, which they do not have, and it no longer sets their required variables.

**Decision.** Start at `unset`, and do the first deploy with explicit tags for both apps.

**Reason.** The workflow already treats `unset` as "no previous version", so a failed first deploy is left in place for diagnosis and does not try to roll back to images that cannot run here. The way back is clearing the variable.

## ADR-003: Each stack removes the other's database container

**Context.** The brief names the service `postgres`; the old stack calls it `db`. Both use the volume `hrms-dev_db-data`. Compose would start `postgres` while `db` is still running, or the reverse on rollback. PostgreSQL's lock file does not protect across containers, so that would be two postmasters on one data directory, which corrupts it.

**Options.** (a) Keep the name `db`. (b) Rename and guard.

**Decision.** (b). `bin/stack-up` and `scripts/deploy-dev.sh` stop and remove the other service's container before starting their own. `dev/tests/deploy-order.test.sh` checks the order with a stub `docker`.

**Reason.** The brief asks for `postgres`, and the guard is small and tested. It has not run against a real daemon.

## ADR-004: Keep the ECS Terraform until the cutover; remove ECR now

**Context.** The brief keeps ECS until a documented step removes it. `terraform/modules/shared-services` also holds an ECR repository and build role, which the audit marks dead.

**Decision.** `hrms-stack`, `envs/customer`, `deploy-prod.yml` and friends stay, and `docs/CUTOVER.md` Step 4 removes them. ECR and the build role are removed now.

**Reason.** Nothing was ever applied, so there is no state to migrate. Prod workflows still reference the ECS stack, so it goes with them. Nothing references the ECR resources, and Trivy flagged their policy.

## ADR-005: Tier-low runs k3s on Graviton, not EKS

**Context.** Tier-low serves about 100 to 300 users, where each monthly dollar matters. Estimates are in `docs/COST_ESTIMATES.md`.

**Options.**

| | EKS | k3s on one Graviton node |
|---|---|---|
| Control plane | About $73 a month | Included |
| Compute | Two nodes for a useful PDB, about $65 | One `t4g.large`, about $33 |
| Egress | NAT gateway, about $45 | NAT instance, about $3 |
| Compute + egress total | About $185 | About $40 |
| Availability | Survives a node or zone | A node failure is an outage of about 5 to 10 minutes, while the Auto Scaling group replaces it |
| Pod identity | IRSA | Node role through IMDS |
| Upgrades | Managed control plane | New AMI and k3s version, node replaced |
| Manifests | Same | Same, plus `components/tier-low` |

**Decision.** k3s, about $145 a month cheaper, which is well over half of the tier's whole bill.

**Reason and costs accepted.** RDS and S3 hold all the data, and Argo CD rebuilds the workloads from git, so the node is disposable. Tier-low accepts brief outages. `tier-low` keeps every workload manifest compatible: it changes only the ingress class, replica counts, Redis and the secret store's auth.

The one weakness is identity. Without IRSA, backend, worker and External Secrets use the node role, which needs IMDS hop limit 2. NetworkPolicy blocks IMDS for every other pod (`allow-imds.yaml`), but all three workloads share one set of permissions, and a compromise of any of them reaches them all. Self-hosting an OIDC issuer would fix that, but it needs a public S3 bucket, which the brief rules out. Moving a client to tier-mid removes the weakness.

## ADR-006: Argo CD applies; per-release Job names give the order

**Context.** Kustomize has no hooks, and a Job's spec is immutable. k3s has no AWS role for a pipeline to assume, and the EKS endpoint is private. The audit asks for provision, then migrate, then bootstrap, then the rollout, because `/health/ready` needs a tenant.

**Options.** (a) A CI pipeline with `kubectl`. (b) Argo CD hooks. (c) Argo CD sync waves over ordinary resources with per-release names.

**Decision.** (c). `scripts/k8s-release.sh` sets the digests and a release id, the overlay's `replacements` put the id into the Job names, and sync waves run them in order. The previous release's Jobs drop out of the manifest and are pruned.

**Reason.** A pull model needs no inbound access or stored kubeconfig on either cluster type. Hooks would run before ordinary resources, so they could not use the ExternalSecrets, which must exist first. Nothing runs provision as an initContainer, so app pods never receive master credentials.

## ADR-007: Client values live in a private repository

**Context.** This repository is public and cannot go private while the app repos' public workflows call it. Account IDs, domains and brand files are client data.

**Decision.** `k8s/overlays/prod` and the `*.tfvars.example` files are templates. `scripts/new-client-overlay.sh` makes a client's overlay for a private repository, which references base and components here at a fixed tag. `.gitignore` refuses `*.tfvars`, except the existing ECS templates.

**Reason.** The audit's finding 1. It adds one repository per client, which the onboarding guide covers.

## ADR-008: ClamAV is in the Kubernetes base

**Context.** The brief's Kubernetes list omits it, but the contract says production refuses to start without `CLAMAV_HOST` while `FEATURE_DOCUMENTS` is on.

**Decision.** Add a Deployment and Service to base. Compose and Kubernetes both use the image's own `/init-unprivileged` entrypoint, which satisfies the non-root and read-only rules.

**Reason.** Without it, no production pod would start. It costs about 1.2 GiB of memory per replica, and its pre-start download makes a first start slow. Neither entrypoint has been run yet.

## ADR-009: How secrets avoid Terraform state

**Decision.** The RDS master password stays RDS-managed. `hrms_owner`, `hrms_app` and the bootstrap admin passwords use ephemeral values and write-only attributes, written once. The data key is created inside KMS by `scripts/generate-data-key.sh`, so its plaintext is never seen. The ElastiCache AUTH token is in state, because the provider has no write-only form; the state bucket is KMS-encrypted and restricted.

**Reason.** The audit found generated passwords and the encryption key in state. Connection URLs are assembled by External Secrets from a password and non-sensitive endpoints, so a changed endpoint does not lose a password that exists only in Secrets Manager. The RDS secret's generated name is why the overlay has one value from Terraform that cannot be a stable name.

## ADR-010: CloudFront in front of a public ALB

**Decision.** Tier-mid and tier-high use CloudFront, with WAF at the edge, and the ALB's security group admits only CloudFront's origin-facing prefix list.

**Trade-off.** That prefix list is shared by all CloudFront customers, so someone could point their own distribution at the ALB and bypass this WAF. They would still need a valid Host and would meet the app's own controls. Closing it needs a secret origin header in Ingress conditions or VPC origins, each adding steps to onboarding. It is recorded as a residual risk in `docs/THREAT_MODEL.md`, and should be revisited before a high-risk client.

## ADR-011: Graviton on every tier, with images built for both architectures

**Context.** The published images are `linux/amd64` only. `_app-publish.yml` has no `platforms` setting.

**Decision.** Add an optional `platforms` input, default unchanged. Release builds must pass `linux/amd64,linux/arm64` from the app repos before any tier runs.

**Reason.** One node architecture across tiers, at lower cost. The input is additive, so no caller breaks. Emulated arm64 builds with native modules are slow, so expect longer release builds, or use `node_ami_type` and x86 instances on mid and high, and `t3.large` plus an AMI change on low.

## ADR-012: Non-root Postgres, Caddy and backup in Compose

**Context.** The brief requires non-root and read-only for the dev stack. The first stack created its `backups` and `caddy-*` volumes as root, and `caddy-data` holds the live certificate.

**Decision.** Run them as non-root, with a one-off `volume-perms` service that changes volume ownership, using only `CHOWN`, `DAC_READ_SEARCH` and `FOWNER`, with no network. Caddy binds 80 and 443 through the `net.ipv4.ip_unprivileged_port_start` sysctl.

**Reason.** It keeps the existing certificate and backups usable, and rollback to the old stack still works, because root can read them. This is the main thing the flip rehearsal must prove.

## ADR-013: Worker health checks prove only that the container can run node

**Context.** The contract defines a `worker` command with no port or heartbeat. A real check needs something from the backend.

**Decision.** Compose and Kubernetes run `node -e 0`. A stuck job loop is not detected.

**Reason.** A guessed endpoint would fail the deploy. A real check needs a backend change, such as a heartbeat file or a small health port, and is listed as follow-up work.
