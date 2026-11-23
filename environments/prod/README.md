# Production installations

One directory per customer (`<slug>/versions.env`) plus `customers.json`. Copy `_template/` to add a customer
(see docs/RUNBOOK.md → "Add a customer"). Merging a change to `<slug>/versions.env` deploys that customer
after the approval required by GitHub Environment `prod-<slug>`.

```json
{ "slug": "acme", "account_id": "123456789012", "region": "ap-south-1", "domain": "hrms.acme.example", "gitops_repo": "acme-org/acme-hrms", "enabled": true }
```

`gitops_repo` is the client's private repository, holding the overlay at `overlay/`. Optional: `overlay` for another path, `db_instance` if the database is not `hrms-db`. The `prod-<slug>` environment needs the secret `GITOPS_TOKEN`, a fine-grained token with Contents read and write on that repository only.
