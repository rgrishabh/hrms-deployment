# Changelog

## Unreleased

### Removed

- All SMS configuration: the `SMS_*` variables in `environments/dev`, the `sms` Terraform variable, the `hrms/sms-auth-header` secret and their tests. SMTP is the only external notification channel.
- ECR repository, its policy and the `hrms-image-build` role from `terraform/modules/shared-services`, and their OIDC provider. Images moved to GHCR, and none of this was ever applied.

### Added

- `dev/` Compose stack, `k8s/`, `argocd/`, and `terraform/envs/prod-{low,mid,high}` with their modules.
- Optional `platforms` input on `_app-publish.yml`. Empty now means both architectures for a release and `linux/amd64` otherwise, so the app repos need no change.
- All deployment variables in the contract, in Compose and Kustomize: rate limits, previous keys, `TRUST_PROXY` hops, VAPID, `METRICS_TOKEN`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `WORKER_HEARTBEAT_FILE`.
- `hrms worker-health` as the worker probe. `make migrate-status`, `migrate-down`, `rotate-keys`. `scripts/k8s-ops-job.sh`, `scripts/gitops-release.sh`, `scripts/k8s-wait-release.sh`, `scripts/check-backend-env.sh`.
- Alarms on replication lag and on ClamAV signature age. `rds.allowed_extensions` for the migrations' three extensions. IAM roles and service accounts for migrate and the freshclam check. Secret `hrms/runtime-optional`.
- Repository variable `DEV_STACK_DIR`, default `environments/dev`, and new optional settings `DEV_ENV_FILE_V2`, `DEV_BRANDENV`, `DEV_EXPECT_BRAND`, all unused until the cutover.

### Changed

- `deploy-prod.yml` and `rollback-prod.yml` pin digests in the client's repository rather than deploying to ECS. `customers.json` gains `gitops_repo`, and each `prod-<slug>` a `GITOPS_TOKEN`. `rollback-prod.yml` needs `schema: compatible`, and no longer has an AWS role.
- ClamAV image to `clamav/clamav-debian`, UID 1000. MinIO images to Chainguard's, by digest.
- `TRUST_PROXY` from `true` to hop counts: 1 in Compose, 2 in Kubernetes.

### Fixed

- `make up` no longer fails on the `minio` profile with `container minio-init exited (0)`.
- The one-time setup link has the port on the `local` profile. Bootstrap gets `NODE_ENV` and `COOKIE_SECURE`, so its scheme is right.
- `scripts/smoke-test.sh` no longer fails the new frontend's title, and skips TLS checks on `http://`.
- `make seed` passes the flags and the data key that the demo command reads.
- A failed `pg_dump` in the backup scheduler no longer prints `backup ok`, publishes an empty set or prunes good sets.
- The organization guardrails no longer deny `wafv2` in `us-east-1`.
- The Terraform plan role can decrypt state encrypted with KMS.
- New modules allow SMTP egress on 587 and 465.
