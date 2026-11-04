# Changelog

## Unreleased

### Removed

- All SMS configuration: the `SMS_*` variables in `environments/dev`, the `sms` Terraform variable, the `hrms/sms-auth-header` secret and their tests. SMTP is the only external notification channel.
- ECR repository, its policy and the `hrms-image-build` role from `terraform/modules/shared-services`, and their OIDC provider. Images moved to GHCR, and none of this was ever applied.
