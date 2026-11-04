# Changelog

## Unreleased

### Removed

- All SMS configuration: the `SMS_*` variables in `environments/dev`, the `sms` Terraform variable, the `hrms/sms-auth-header` secret and their tests. SMTP is the only external notification channel.
