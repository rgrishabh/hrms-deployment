# Changelog

## Unreleased

### Removed

- All SMS configuration: the `SMS_*` variables in `environments/dev`, the `sms` Terraform variable, the `hrms/sms-auth-header` secret and their tests. SMTP is the only external notification channel.
- ECR repository, its policy and the `hrms-image-build` role from `terraform/modules/shared-services`, and their OIDC provider. Images moved to GHCR, and none of this was ever applied.

### Added

- `dev/` Compose stack, `k8s/`, `argocd/`, and `terraform/envs/prod-{low,mid,high}` with their modules.
- Optional `platforms` input on `_app-publish.yml`; default unchanged.
- Repository variable `DEV_STACK_DIR`, default `environments/dev`, and new optional settings `DEV_ENV_FILE_V2`, `DEV_BRANDENV`, `DEV_EXPECT_BRAND`, all unused until the cutover.

### Fixed

- A failed `pg_dump` in the backup scheduler no longer prints `backup ok`, publishes an empty set or prunes good sets.
- The organization guardrails no longer deny `wafv2` in `us-east-1`.
- The Terraform plan role can decrypt state encrypted with KMS.
- New modules allow SMTP egress on 587 and 465.
