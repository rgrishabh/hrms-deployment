# Discovery: current state before the three-repo restructure

Written 2026-11-03 for the request to split the code into `hrms-frontend`, `hrms-backend` and `hrms-deployment`.

## Stack

| Area | Found |
|---|---|
| Layout | npm-workspaces monorepo: `apps/api`, `apps/web`, plus `deploy/compose`, `infra/` (Terraform), `.github/workflows` (`ci.yml`, `release.yml`, `infra.yml`) |
| Backend | Node.js 22 + TypeScript, Fastify 5, zod, `pg`. Build `npm run build -w apps/api`, tests `npm test` (Vitest, 179 tests, needs PostgreSQL) |
| Frontend | React 19 + Vite 8 SPA, react-router 7. Build `vite build` → `apps/web/dist`. No SSR |
| Serving | **One image.** The API serves the SPA from `WEB_DIST_DIR` and renders `index.html` at startup with the installation's product name, favicon and theme colour. Branding files come from `BRANDING_DIR`. The SPA reads runtime config from `GET /api/v1/public/config` (it is already the same image for every environment and customer) |
| Auth coupling | Session cookie + CSRF header on the **same origin**. The SPA and the API must stay same-origin (or the cookie/CSRF model changes) |
| Database | PostgreSQL 17 (only database). Roles: owner (migrations) and app (runtime, RLS enforced). 13 SQL migrations |
| Migrations | Separate command already: `node dist/db/migrate.js` (`--status` exits 0/2/3). Compose and ECS run it as a one-off before the app |
| Other one-offs | `provision` (DB roles), `bootstrap` (first administrator, setup link) |
| Cache / queue | **None.** Background jobs use a database-claimed scheduler inside the app process; email uses a transactional outbox table. No Redis or SQS is needed |
| Cron | Inside the app (`JOBS_ENABLED`); nothing on the host |
| File uploads | `STORAGE_DRIVER=local` (volume) or `s3` (private bucket, SSE-KMS). Files are streamed through the API after permission checks and audit; **no presigned URLs** by design |
| Health | `/health/live` (liveness), `/health/ready` (DB reachable, migrations current, organization bootstrapped) |
| Logging / shutdown | pino JSON to stdout; SIGTERM → stop scheduler, close server and pool |
| Port | 4000 (container), non-root `node` user, HEALTHCHECK present |
| Env vars | Validated at startup (`apps/api/src/config/env.ts`); documented in `deploy/compose/.env.example` and DEPLOYMENT.md |

## Existing deployment model (important)

The product is **white-label, one installation per customer**. This was decided earlier (DECISIONS D21–D23, DEPLOYMENT.md):

- **Compose:** one Compose project per customer (`deploy/compose`, Caddy with automatic TLS, backups to a tarball).
- **AWS:** **one AWS account per customer** (`infra/live/organization`, `infra/live/shared-services`, `infra/live/customer`, `infra/customers/*.tfvars`). Each customer gets ECS Fargate, an ALB with ACM, WAF, RDS, an S3 documents bucket, Secrets Manager, CloudWatch and SNS, in its own account.
- **Registry today:** ECR in a shared-services account (`release.yml`), with an ECR scan gate.
- **Git:** one commit (`Initial commit`). **All work since then is uncommitted**, so "history preservation" currently means only that commit.
- **Tooling on this machine:** `gh` CLI is **not installed**. Git remote is `git@github.com:rgrishabh/HRMS-POC.git`.

## Conflicts with the requested target

1. **Single prod (`app.DOMAIN`) vs per-customer installations.** The request describes one dev and one prod. The product is designed for many prod installations, each in its own AWS account with its own domain and branding.
2. **Separate frontend repo and image.** Possible, but the SPA must stay same-origin with the API (cookies + CSRF). Branding currently rendered into `index.html` by the API would move to an entrypoint-generated `env.js` (Compose/ECS) or a per-customer `env.js` uploaded to S3 (CloudFront).
3. **Redis / presigned URLs.** Not used; I would not add them.
4. **Registry:** GHCR replaces ECR. ECS pulls through `repositoryCredentials` (one Secrets Manager secret per customer account).

## Assumptions (unless told otherwise)

- GitHub owner `rgrishabh` (from the current remote); region `ap-south-1` (from the tfvars template); domain kept as a variable.
- Nothing is created on GitHub or AWS, and nothing is pushed, without explicit approval. Repos are built locally with commits; `scripts/setup-github.sh` does the GitHub side once `gh` is installed and authenticated.
