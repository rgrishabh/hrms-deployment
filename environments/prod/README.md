# Production installations

One directory per customer (`<slug>/versions.env`) plus `customers.json`. Copy `_template/` to add a customer
(see docs/RUNBOOK.md → "Add a customer"). Merging a change to `<slug>/versions.env` deploys that customer
after the approval required by GitHub Environment `prod-<slug>`.

```json
{ "slug": "acme", "account_id": "123456789012", "region": "ap-south-1", "domain": "hrms.acme.example", "enabled": true }
```
