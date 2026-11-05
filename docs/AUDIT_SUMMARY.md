# HRMS audit summary

For a technical lead. This combines the three Phase 0 audits, all dated 2026-11-05: [deployment](../AUDIT.md) at `92fef0b`, `hrms-backend/AUDIT.md` at `030af9c` and `hrms-frontend/AUDIT.md` at `bc9461a`. It describes **what was found at those commits, not the current state**. For what has been fixed since, see the pointers at the end.

## Overall

The audits found three kinds of problem that matter before release: pay and leave calculated wrongly, weak controls around money and salary data, and a deployment that was built for private repositories and could lose backups without saying so. The frontend's problems are mainly resilience and access rather than wrong results.

How far each audit went differs, so weigh them accordingly:

| Audit | Method | Main gap |
|---|---|---|
| Deployment | Read the repo, read-only GitHub and HTTP checks, stub reproductions | Dev host and `DEV_ENV_FILE` not inspected. Some AWS and GitHub behaviour is from knowledge, and is labelled |
| Backend | Read the core and money modules in full, delegated and spot-checked the others, probed the calculation functions | Some modules are `[delegated]`. A test-count difference (336 run, 351 `it(` calls) was not investigated |
| Frontend | Read every source file, ran build, tests and `npm audit` | Nothing opened in a browser, and Playwright not run. Layout claims are traced from code |

## Top risks

**1. Wrong pay (backend, P0).** All confirmed by tracing the code, and most by running the calculation:

- Half-day leave with the other half unworked is paid in full (F-1).
- Year-end carry-forward leaves the same days spendable in both years, and inflates F&F encashment (F-2).
- F&F and regular runs can pay the same days (F-3).
- A one-off bonus is annualised for TDS: ₹18,850 of tax in one month in the audit's example (F-4).
- ESI coverage is decided on prorated wages (F-5).
- A mid-month salary change applies to the whole month (F-6).
- A run can finalize on stale attendance (F-7), and approved corrections can leave a day as `missing_punch`, which costs a full day by default (F-8).

**2. Control over money and salary data (backend and frontend).**

- Anyone with `employees.bank.manage` can redirect a salary, with no second person or notification (F-9).
- Scheduled report snapshots can show payroll figures to recipients without the permission (F-10).
- The MFA "privileged" level omits `finance_manager` and `auditor` (F-11).
- Held pay still counts as loan recovery and has no release (F-12).
- The UI has no route guards, and finalize payroll, rotate device key and reset 2FA run on one click (frontend 2 and 5).

**3. Public repositories treated as private (deployment).** All three repos are public, while the docs assume otherwise. Customer tfvars, `customers.json` and Terraform plan comments would be world-readable. A single admin-level token sits in all three repos, and anyone with write access to an app repo could use it to push to deployment `main`, which runs on the dev host.

**4. Backups and rollback (deployment).** Backups report success when `pg_dump` fails, which the audit reproduced. A bad Compose change on `main` is not rolled back automatically. The dev cutover is rated the riskiest step of the revamp, because the old stack cannot run the new images and the new stack cannot run the old ones.

**5. Spoofable client address (backend and deployment).** `trustProxy` as a boolean behind an ALB lets a client spoof the address used for login rate limits and audit (F-15).

**6. The app blanks on failure (frontend).** A failed first load dereferences null with no ErrorBoundary, across 32 sites. Elsewhere a failed load reads as "nothing here". On top of that: no double-submit protection on most forms, a mobile drawer that can't be dismissed, a 792 KB single bundle that is probably served uncompressed, and clickable rows with no keyboard path.

**7. Approvals can stick forever (backend).** Nothing reassigns a disabled approver's steps, and escalation is off by default (F-14).

## What the three share

- **The repositories depend on each other in ways that are easy to break.** The deployment repo holds the reusable workflows and the signing identity. Renaming `_app-publish.yml` or its branch invalidates every earlier image's signature, and pinning its callers to a commit has the same effect on new images ([CUTOVER](CUTOVER.md#merge-order-and-the-workflow-pins)). The deployment audit found the brief's Redis, worker, MinIO and Mailpit had no backend support, so that work crossed the boundary too.
- **SMS** had to come out of all three repos.
- **Container and supply chain hygiene:** each audit lists digest pinning, and CI gaps of its own.
- **Proxy and edge settings span repos.** `TRUST_PROXY` hops, gzip on the frontend's nginx behind the old ALB, and same-origin routing all depend on both an app and the deployment.
- **Gaps in failure signalling.** Backups report success on failure, a failed load looks empty, and approvals stick with no warning. The common pattern is failure that looks like success, and it deserves specific attention in review.
- **Limited end-to-end evidence.** None of the audits ran the whole system. Treat claims about production behaviour as unproven until the cutover rehearsal.

## Where to read more

| Question | Where |
|---|---|
| Full findings and prioritised plans | `AUDIT.md` in each repo: deployment section 7, backend section 7, frontend section 8 |
| What was fixed, and how it was tested | `QA_REPORT.md` in each repo, `hrms-backend/SECURITY_REPORT.md` |
| Why a choice was made | `DECISIONS.md` here and in `hrms-backend` |
| Open image CVEs | [SECURITY.md](../SECURITY.md) |
| Threat models | [docs/THREAT_MODEL.md](THREAT_MODEL.md), `hrms-backend/docs/THREAT_MODEL.md` |
| Cutover and merge order | [docs/CUTOVER.md](CUTOVER.md) |
