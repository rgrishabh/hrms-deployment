## What and why

<!-- Conventional Commit title: feat|fix|chore|docs|ci|refactor(scope): summary -->

## Checklist

- [ ] Version bumps only change `environments/*/versions.env` (immutable tags)
- [ ] Terraform: plan comment reviewed for every affected customer
- [ ] No secrets, `.env` or `*.tfvars` with real credentials committed
- [ ] Runbook / one-time setup updated if operators must do something new
