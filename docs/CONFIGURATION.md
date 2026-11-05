# Configuration model

Every setting lives in exactly one of four layers. Use this page to decide where a setting belongs and who can change it.

| Layer | Stored in | Changed by | Takes effect |
|---|---|---|---|
| 1. Feature flags and security switches | `.env` (Compose), `app.env` (Kustomize) | Whoever deploys | Restart |
| 2. Brand and client identity | `.brandenv` (Compose), `brand.env` (Kustomize) | Whoever deploys | Restart, no rebuild |
| 3. Admin settings | Database | Client's admin, in the app | Immediately, audited |
| 4. Product constants | Code | Product team, by release | Next release |

Secrets are not a layer. They use the same variable names but come from a git-ignored `.env` in Compose and from AWS Secrets Manager through External Secrets in Kubernetes.

## Layer 1: feature flags

Set at deploy time only. They are not stored in the database, and no API or admin screen can change them.

`src/core/features/registry.ts` in `hrms-backend` is the single source of truth. Each entry holds the environment variable, default, description and dependencies. The backend validates the full set at startup and refuses to start if:

- a feature is on while a feature it depends on is off
- a `FEATURE_*` variable is not in the registry, which catches typos
- a flag value is anything other than `true` or `false`
- the removed `ENABLED_MODULES`, `MFA_ENFORCEMENT` or `SMS_*` variables are still set

### Flags

| Variable | Default | Requires | Controls |
|---|---|---|---|
| `FEATURE_DOCUMENTS` | true | | Employee and company documents |
| `FEATURE_ONBOARDING` | false | | Onboarding checklists, probation |
| `FEATURE_OFFBOARDING` | false | | Separation and exit |
| `FEATURE_POLICIES` | false | | Versioned policies and acknowledgements |
| `FEATURE_ATTENDANCE` | true | | Attendance engine and daily calculation |
| `FEATURE_ATTENDANCE_WEB` | true | `ATTENDANCE` | Web check-in |
| `FEATURE_ATTENDANCE_MOBILE` | false | `ATTENDANCE` | Mobile check-in |
| `FEATURE_ATTENDANCE_GEOFENCE` | false | `ATTENDANCE` | Location capture and geofence checks |
| `FEATURE_ATTENDANCE_SELFIE` | false | `ATTENDANCE` | Camera selfie at check-in |
| `FEATURE_ATTENDANCE_BIOMETRIC` | false | `ATTENDANCE` | Device ingestion |
| `FEATURE_ATTENDANCE_REGULARIZATION` | true | `ATTENDANCE` | Correction requests |
| `FEATURE_SHIFTS` | true | `ATTENDANCE` | Shifts and rosters |
| `FEATURE_HOLIDAYS` | true | `ATTENDANCE` | Holiday calendars |
| `FEATURE_LEAVE` | true | | Leave |
| `FEATURE_OVERTIME` | false | `ATTENDANCE` | Overtime claims |
| `FEATURE_COMP_OFF` | false | `LEAVE`, `OVERTIME` | Overtime taken as compensatory off |
| `FEATURE_FIELD_DUTY` | false | `ATTENDANCE` | Field duty |
| `FEATURE_PAYROLL` | false | `ATTENDANCE` | Payroll runs |
| `FEATURE_PAYSLIPS` | false | `PAYROLL` | Employee payslips |
| `FEATURE_PAYROLL_STATUTORY` | false | `PAYROLL` | Statutory deductions |
| `FEATURE_LOANS` | false | `PAYROLL` | Employee loans |
| `FEATURE_SALARY_ADVANCE` | false | `PAYROLL` | One-month salary advances |
| `FEATURE_ACCOUNTING_EXPORTS` | false | `PAYROLL` | Journal exports |
| `FEATURE_EXPENSE_CLAIMS` | false | | Expenses and reimbursements |
| `FEATURE_TRAVEL` | false | `EXPENSE_CLAIMS` | Travel requests |
| `FEATURE_RECRUITMENT` | false | | Recruitment |
| `FEATURE_PERFORMANCE_REVIEW` | false | | Performance reviews |
| `FEATURE_TRAINING` | false | | Training records |
| `FEATURE_LAB_COMPETENCY` | false | `TRAINING` | Laboratory competency and authorization |
| `FEATURE_ASSET_MANAGEMENT` | false | | Assets |
| `FEATURE_GRIEVANCE` | false | | Grievances |
| `FEATURE_POSH` | false | | POSH complaints |
| `FEATURE_REPORTS_ADVANCED` | false | | Saved and scheduled reports |
| `FEATURE_EMAIL_NOTIFICATIONS` | true | | Sending notification email |
| `FEATURE_PUSH_NOTIFICATIONS` | false | | PWA push |

Employee records, organization structure, self-service, approvals, in-app notifications, audit and security are always on and have no flag.

### What "off" means

Backend:

- The module's routes are not registered, so they return 404.
- Its scheduled jobs don't run, and its seed data is not created.
- Its permissions are removed from role listings.
- Its fields are removed from responses, reports and exports.
- Pending approvals of a switched-off module leave the inbox, and resume unchanged if the flag returns.
- Data is kept. Retention and erasure jobs still run for it, so personal data doesn't outlive its retention date.

Frontend:

- Its routes, menu items, widgets and form fields don't exist.
- Its lazy-loaded chunks are never requested.

A feature can be on but not yet usable because it needs runtime setup, such as an overtime setting, a registered device or a configured store. Those routes stay registered and answer 409 `feature_not_configured`.

### Management mode

`ORG_MANAGEMENT_MODE` is `single`, `single_hr` or `multi`. The default is `multi`.

| | `single` | `single_hr` | `multi` |
|---|---|---|---|
| Who | One owner | Owner plus HR users | Full team |
| Roles | Owner, Employee | Owner, HR, Employee | All system and custom roles |
| Role screens | None | None | Yes |
| Approvals | One step to the owner | One step: HR or Owner. HR's own requests go to the Owner | Multi-level, with delegation and escalation |
| Self-approval | Owner may approve their own, written to the audit log | Owner only, because nobody is above them, audited | Never |
| Separation of duties | Not applicable | Owner approves payroll | Preparer can't approve |

Moving `single` → `single_hr` → `multi` needs no data migration. The `owner` role resolves to the same permissions as Super-admin in `multi`.

Requests in flight keep the steps they were created with. Moving down to a smaller mode is not supported.

### Security

| Variable | Dev | Prod | Notes |
|---|---|---|---|
| `MFA_AVAILABLE` | `false` | `true` | `false` removes MFA for every user: no prompts, no setup screens, no challenge at login, `/auth/mfa/*` answers 404. What people enrolled in is kept, and counts again if it is turned back on |
| `MFA_ENFORCED` | `false` | `false` | `false`: optional per user, so people who can read salaries are not required to enrol. `true` makes enrolment required at next login. Invalid with `MFA_AVAILABLE=false`, and with email as the only method and no SMTP |
| `MFA_METHODS` | `totp,email` | `totp,email` | Subset of `totp`, `email`. Email codes need SMTP; enrolment says so without it |

### Runtime wiring

| Variable | Notes |
|---|---|
| `DATABASE_URL`, `DATABASE_MIGRATION_URL` | Secret. Runtime role and schema owner role |
| `DB_READ_HOST` | Optional. Reports and heavy reads go to this replica |
| `REDIS_URL` | Optional. Caches config and lookups. Without it the app reads the database, which is slower but correct |
| `DATA_ENCRYPTION_KEY` | Secret, dev only. Base64 of 32 bytes |
| `KMS_KEY_ID`, `DATA_KEY_CIPHERTEXT` | Prod. The data key is decrypted with KMS at startup. Takes priority over `DATA_ENCRYPTION_KEY` |
| `DATA_ENCRYPTION_KEY_PREVIOUS`, `DATA_KEY_CIPHERTEXT_PREVIOUS` | Comma-separated. Older keys still needed to read values during a rotation. Secret. Remove them after `hrms rotate-keys` has finished |
| `PROCESS_ROLE` | `api` or `worker`. Only the worker runs jobs and sends email |
| `TRUST_PROXY` | Whose `X-Forwarded-For` to believe: `false`, a number of proxy hops in front of the app, or comma-separated proxy addresses or CIDRs. `true` means one hop |
| `AUTH_RATE_LIMIT_PER_MINUTE` | Sign-in attempts per address per minute. Default 20. Failed sign-ins also back off, counted in the database |
| `AUTH_ACCOUNT_RATE_LIMIT_PER_MINUTE` | Sign-in attempts on one account per minute, from any address. Default 10. Browsers that have signed in to the account before, and addresses already backing off, do not count |
| `EXPORT_RATE_LIMIT_PER_MINUTE` | CSV, Excel and journal exports per user per minute. Default 30. Per address, four times this |
| `STORAGE_DRIVER`, `STORAGE_PATH`, `AWS_S3_BUCKET`, `AWS_REGION`, `S3_ENDPOINT` | `S3_ENDPOINT` is for MinIO |
| `CLAMAV_HOST`, `CLAMAV_PORT` | Upload malware scanning over clamd's INSTREAM. Port defaults to 3310. Prod refuses to start without the host when `FEATURE_DOCUMENTS` is on, and refuses any upload it cannot scan. clamd's `StreamMaxLength` must be at least `STORAGE_MAX_FILE_MB` |

### SMTP

SMTP is the only external notification channel. There is no SMS.

| Variable | Notes |
|---|---|
| `SMTP_HOST`, `SMTP_PORT` | Mailpit in dev. Any SMTP provider in prod, including Amazon SES |
| `SMTP_USER`, `SMTP_PASSWORD` | Secret. Both or neither |
| `SMTP_SECURE` | `starttls`, `tls` or `none`. Prod refuses `none` |

Password reset, invitations, email codes and security notices all need SMTP. Without it, `POST /auth/password/forgot` sends nothing and `auth.resetByEmail` in the public config is `false`. `FEATURE_EMAIL_NOTIFICATIONS=false` turns off the transport and so all of these too.

### Operator commands

Run in the image, as the schema owner. Nothing here has an HTTP endpoint.

| Command | Does |
|---|---|
| `hrms rotate-keys` | Re-encrypts every encrypted column with the active key, in committed batches. Rows already on it are skipped, so it can be run again. Needs the old key in a `*_PREVIOUS` variable while it runs |
| `hrms bootstrap` | First organization and first administrator, as Owner. A one-time link by default |
| `hrms bootstrap --reset-admin --admin-email X` | Recovers an account: new credentials, sessions ended, MFA cleared, administrator role restored. They also become Owner if no other active Owner exists |
| `hrms bootstrap --reset-admin --make-owner --admin-email X` | Hands ownership over. Nobody in the app can appoint an Owner |
| `hrms bootstrap --issue-link --admin-email X` | A one-time invitation link for an existing user, for an installation without SMTP |

## Layer 2: brand and client identity

**To onboard a new client, copy `.brandenv.example` to `.brandenv`, fill it in and deploy.** Nothing else changes, and the image isn't rebuilt.

| Variable | Required | Validation |
|---|---|---|
| `BRAND_NAME` | Yes | 1 to 120 characters |
| `BRAND_PRODUCT_NAME` | Yes | 1 to 60 characters |
| `BRAND_LEGAL_NAME` | No | Up to 200 characters. Used as the organization name at bootstrap |
| `BRAND_LOGO_URL`, `BRAND_LOGO_DARK_URL`, `BRAND_FAVICON_URL` | No | `https://` URL or `/brand/<file>` |
| `BRAND_PRIMARY_COLOR` | Yes | `#rrggbb`, quoted in env files |
| `BRAND_SECONDARY_COLOR`, `BRAND_ACCENT_COLOR` | No | `#rrggbb` |
| `BRAND_FONT_FAMILY` | No | One of the fonts bundled with the frontend |
| `BRAND_SUPPORT_EMAIL`, `BRAND_EMAIL_FROM` | Yes | Email address |
| `BRAND_SUPPORT_PHONE`, `BRAND_HELP_URL`, `BRAND_LOGIN_MESSAGE` | No | |
| `BRAND_DOMAIN` | Yes | Hostname. Sets the app URL and the only allowed CORS origin |
| `BRAND_EXTRA_DOMAINS` | No | Comma-separated hostnames |
| `BRAND_LOCALE` | Yes | BCP 47, for example `en-IN` |
| `BRAND_TIMEZONE` | Yes | IANA timezone |
| `BRAND_CURRENCY` | Yes | ISO 4217 |
| `BRAND_DATE_FORMAT` | Yes | `DD/MM/YYYY`, `DD-MM-YYYY`, `DD-MMM-YYYY` or `YYYY-MM-DD` |
| `BRAND_FINANCIAL_YEAR_START` | Yes | `MM-DD` |
| `BRAND_COUNTRY` | Yes | ISO 3166-1 alpha-2 |

Brand files are mounted, not baked in: a volume at `/brand` in Compose, and a ConfigMap or S3 path in Kubernetes. The frontend gets these values at boot from the same public endpoint as the flags:

```
GET /api/v1/config/public    no auth, read-only, no secrets
{ "product": {...}, "brand": {...}, "features": {"FEATURE_PAYROLL": true, ...},
  "mode": "multi", "mfa": {"available": true, "enforced": false, "methods": ["totp","email"]},
  "auth": {"resetByEmail": true} }
```

Switched-off features appear as `false`. Their descriptions don't appear.

## Layer 3: admin settings

Stored in the database and edited in the app. Each change is validated, restricted by role, and audited with who, when and old → new values. Settings of switched-off features are not shown.

- Company: legal name, GSTIN, PAN, TAN, CIN, registered address, PF, ESI and PT registration numbers, payroll bank details, authorised signatory, signature and stamp upload
- Leave policies, holiday calendar, shifts, working days
- Departments, designations, grades
- Approval workflows, payroll components, notification preferences
- Whether managers can see team salaries, capped by the salary hierarchy
- Session lifetime, idle sign-out, failed sign-ins before back-off, a password minimum above the floor
- Which document categories payroll staff and auditors can read

## Layer 4: product constants

These are in code and the same for every client. Changing one is a product release.

- API version `v1`; error format RFC 7807
- Data classification of each field (the registry in `src/core/policy/classification.ts`)
- Salary hierarchy rules
- Password floor of 12 characters; Argon2id parameters; offline breached-password list
- Session cookie flags; CSRF scheme
- Audit log append-only and hash-chained
- Upload allow-list; content-based type checks
- Rate limit floors on login, OTP, password reset and exports
- Encryption algorithm: AES-256-GCM

## Where does this setting live?

| Setting | Layer | Location |
|---|---|---|
| Turn loans on or off | 1 | `FEATURE_LOANS` |
| Single-person company | 1 | `ORG_MANAGEMENT_MODE` |
| MFA offered, MFA required | 1 | `MFA_AVAILABLE`, `MFA_ENFORCED` |
| SMTP server | 1 and secret | `SMTP_*` |
| Encryption key | Secret | `DATA_ENCRYPTION_KEY`, or KMS in prod |
| Read replica, Redis | 1 | `DB_READ_HOST`, `REDIS_URL` |
| Client name, logo, colours | 2 | `.brandenv` |
| Domain, locale, timezone, currency, date format, financial year | 2 | `.brandenv` |
| GSTIN, PAN, TAN, CIN, signatory | 3 | Settings → Company |
| Leave policies, holidays, shifts | 3 | Settings |
| Departments, grades, designations | 3 | Settings |
| A user's salary access level | 3 | Users, audited, capped below the editor's own level |
| Manager sees team salaries | 3 | Settings → Security |
| Idle sign-out, session lifetime | 3 | Settings → Security, within `SESSION_TTL_HOURS` |
| Payroll components | 3 | Settings → Payroll |
| Statutory rates | 3 | Rule register, maker-checker |
| Who can see salaries, by rule | 4 | Policy code |
| Which fields are L1 to L4 | 4 | Classification registry |
| Password floor, hashing | 4 | Code |

## Migrating from v1.1

| Old | New |
|---|---|
| `ENABLED_MODULES` | One `FEATURE_*` per module |
| `MFA_ENFORCEMENT` | `MFA_AVAILABLE`, `MFA_ENFORCED` |
| Setting `security.mfa_enforcement` | Removed. The deployment decides, for everyone |
| `SMS_*` | Removed |
| `SMTP_SECURE=true/false` | `SMTP_SECURE=tls/starttls/none` |
| `MAIL_TRANSPORT` | Removed. Email is on when `SMTP_HOST` is set and `FEATURE_EMAIL_NOTIFICATIONS=true` |
| `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | `BRAND_EMAIL_FROM`; the display name is `BRAND_PRODUCT_NAME` |
| `PRODUCT_NAME` | `BRAND_PRODUCT_NAME` |
| `BRAND_SHORT_NAME` | Removed; use `BRAND_PRODUCT_NAME` |
| `APP_URL`, `APP_EXTRA_DOMAINS` | `BRAND_DOMAIN`, `BRAND_EXTRA_DOMAINS` |
| `ORGANIZATION_NAME`, `ORGANIZATION_LEGAL_NAME` | `BRAND_NAME`, `BRAND_LEGAL_NAME` |
| `ORGANIZATION_COUNTRY`, `_TIMEZONE`, `_CURRENCY`, `_DATE_FORMAT` | `BRAND_COUNTRY`, `_TIMEZONE`, `_CURRENCY`, `_DATE_FORMAT` |
| `ORGANIZATION_FY_START_MONTH` | `BRAND_FINANCIAL_YEAR_START` |
| `BRANDING_DIR`, `/branding/*` | Fixed mount at `/brand`, served at `/brand/*` |
| `JOBS_ENABLED` | `PROCESS_ROLE` |
| `GET /api/v1/public/config` | `GET /api/v1/config/public` |

**Merge order:** `hrms-deployment` first, because extra variables are harmless to the old backend. Then `hrms-backend`, then `hrms-frontend`.
