# Architecture

The first part of this page is the target: a Compose stack for dev and on-prem, and three AWS tiers. **None of the AWS tiers has been applied.** The second part, [Delivery](#delivery), describes the pipeline that runs today, and still mentions the ECS design until the [cutover](CUTOVER.md).

Costs are in [COST_ESTIMATES.md](COST_ESTIMATES.md), recovery in [DR.md](DR.md), and the settings model in [CONFIGURATION.md](CONFIGURATION.md).

## Tiers at a glance

| | Compose (`dev/`) | `prod-low` | `prod-mid` | `prod-high` |
|---|---|---|---|---|
| For | Dev, on-prem about 100 users | About 100 to 300 users | About 300 to 2,000 | 2,000 and up |
| Compute | One host | k3s, one Graviton node | EKS, two zones | EKS, three zones |
| Database | Postgres container | RDS single-AZ plus read replica | RDS Multi-AZ | RDS Multi-AZ plus read replica |
| Cache | Redis container | None | ElastiCache, two nodes | ElastiCache, three nodes |
| Documents | Volume, or MinIO | S3 | S3 | S3, replicated |
| Edge | Caddy | ALB + WAF | CloudFront + WAF + ALB | CloudFront + WAF + ALB |
| Egress | Host | NAT instance, S3 endpoint | NAT gateway, S3 endpoint | NAT per zone, S3 endpoint |
| Identity | Environment | Node role | IRSA | IRSA |
| Region failure | Restore elsewhere | Not covered | Not covered | DR pilot light |

User counts are planning guesses: nothing has been load-tested.

**Every tier** has one installation per client in its own AWS account. It shares the same images, a read-only root, non-root users, KMS encryption, private subnets for compute and data, and no public RDS or S3.

**Tier-low's trade-offs.** A node failure is a short outage. A zone failure can mean promoting the replica or a point-in-time restore. Backend, worker and External Secrets share the node's identity ([ADR-005](../DECISIONS.md)). The tier is for clients who accept that for about a quarter of the mid-tier cost.

## Compose: dev and on-prem

```mermaid
flowchart TB
  U([Users]) -->|443| C[caddy, tls profile]
  L([Laptop]) -->|127.0.0.1:8088| G[gateway, local profile]
  subgraph edge[edge network]
    C & G -->|/, /assets| F[frontend :8080]
    C & G -->|/api /health /ready /brand| B[backend :4000]
  end
  subgraph internal["internal network: no route out"]
    B & W[worker] --> P[(postgres)]
    B & W --> R[(redis)]
    B & W --> V[clamav :3310]
    W --> M[mailpit :1025]
    BK[backup] --> P
  end
  S["provision, migrate, bootstrap"] -.runs first.-> B
  S --> P
  BK -.optional s3backup.-> X[(S3)]
  W -.on-prem: real SMTP.-> E([SMTP provider])
```

Order: `postgres` healthy, then `provision`, `migrate` and `bootstrap`, then `backend` and `worker`, then Caddy. Only `postgres` and `provision` see the superuser password; only the one-offs and `backup` see the owner's.

## prod-low

```mermaid
flowchart TB
  U([Users]) --> A[ALB + regional WAF<br/>public subnets, 404 for unknown hosts]
  A -->|NodePort 30080| T
  subgraph app[private app subnet, one zone]
    subgraph N[k3s on t4g.large, Auto Scaling group of 1]
      T[Traefik] --> FE[frontend]
      T --> BE[backend]
      WK[worker]
      CL[clamav]
      AR[Argo CD, External Secrets, Kyverno]
    end
  end
  subgraph data[data subnets: no internet route]
    RP[(RDS single-AZ)] --> RR[(read replica)]
  end
  BE & WK --> RP
  BE --> RR
  BE & WK -->|node role via IMDS| S3[(S3 + KMS)]
  N -->|NAT instance| NET([GHCR, SMTP, freshclam, AWS APIs])
  N -->|gateway endpoint| S3
```

## prod-mid

```mermaid
flowchart TB
  U([Users]) --> CF[CloudFront + WAF<br/>caches /assets only]
  CF -->|prefix-listed SG| A[ALB, from the Ingress]
  subgraph vpc[VPC, two zones]
    A --> P1 & P2
    subgraph P1[zone a: EKS node]
      F1[frontend] & B1[backend] & W1[worker] & C1[clamav]
    end
    subgraph P2[zone b: EKS node]
      F2[frontend] & B2[backend]
    end
    B1 & B2 & W1 --> DB[(RDS Multi-AZ)]
    B1 & B2 --> RD[(ElastiCache, two nodes)]
  end
  B1 & B2 & W1 -->|IRSA| S3[(S3 + KMS)]
  vpc -->|NAT gateway| NET([GHCR, SMTP, freshclam])
```

## prod-high

```mermaid
flowchart TB
  U([Users]) --> CF[CloudFront + WAF]
  CF --> A[ALB]
  subgraph primary["ap-south-1, three zones"]
    A --> PODS[EKS: hard zone spread, worker x2, clamav x2]
    PODS --> DB[(RDS Multi-AZ)]
    PODS --> RR[(read replica)]
    PODS --> RD[(ElastiCache, three nodes)]
    PODS --> S3[(S3 + KMS)]
    BK[AWS Backup]
  end
  subgraph dr["ap-south-2: pilot light"]
    DBD[(RDS cross-region replica)]
    S3D[(S3 replica)]
    KD[KMS replica key, secret replicas]
    BV[Backup vault]
    EKSD[EKS, only when activated]:::off
  end
  DB -.async.-> DBD
  S3 -.replication.-> S3D
  BK -.copy.-> BV
  CF -.on failover, origin changes.-> EKSD
  classDef off stroke-dasharray: 5 5
```

## How Kubernetes is put together

- `k8s/base`: every workload, under PodSecurity `restricted`, with default-deny NetworkPolicy, startup, liveness and readiness probes, topology spread, and images by digest.
- `k8s/components/tier-*`: sizing, replicas and tier differences. One line in the overlay selects one.
- `k8s/overlays/prod`: the template for a client: `app.env`, `brand.env`, brand files, digests and a release id.
- Jobs named per release, run in order by Argo CD sync waves ([ADR-006](../DECISIONS.md)).
- Secrets from AWS Secrets Manager through External Secrets. Workload classes receive different Secrets.
- Kyverno blocks mutable tags, root and missing limits. CI runs the same policies against all three tiers.

## Delivery

Delivery today:

Three repositories:

| Repo | Contains | Produces |
|---|---|---|
| `hrms-backend` | Fastify API, migrations, DB tooling | `ghcr.io/rgrishabh/hrms-backend` |
| `hrms-frontend` | React SPA, nginx config, runtime renderer | `ghcr.io/rgrishabh/hrms-frontend` |
| `hrms-deployment` | environments (versions as code), Terraform, scripts, **reusable workflows** | deployments |

HRMS is white-label with **one installation per customer**. Dev is one EC2 host with Docker Compose. Each production
customer has **its own AWS account** (ECS Fargate, ALB, RDS, S3), described by `terraform/customers/<slug>.tfvars`
and `environments/prod/<slug>/versions.env`. The same two images serve every installation; configuration is injected at runtime.

## Code → image → dev → prod

```mermaid
flowchart LR
  subgraph app["hrms-backend / hrms-frontend"]
    PR[PR to develop] -->|_app-ci| CI{{lint · tests · build · Trivy · gitleaks<br/>PR comment}}
    CI -->|merge| DEV[push develop]
    DEV -->|_app-ci + _app-publish| IMG[(GHCR :sha-abc1234<br/>SBOM · provenance · cosign)]
    MAIN[develop → main] --> RP[release-please PR]
    RP -->|merge = tag vX.Y.Z| REL[(GHCR :vX.Y.Z<br/>signed)]
  end
  subgraph dep["hrms-deployment"]
    IMG -->|repository_dispatch deploy-dev| DD[deploy-dev.yml]
    DD -->|bot commit| VD[environments/dev/versions.env]
    DD -->|SSH or SSM| EC2[(dev EC2<br/>Compose + Caddy)]
    REL -->|repository_dispatch release-prod| RPR[release-prod.yml]
    RPR -->|opens/updates PR| VP[environments/prod/*/versions.env]
    VP -->|merge| DP[deploy-prod.yml]
    DP -->|"approval: prod-&lt;slug&gt;"| ECS[(customer AWS account<br/>ECS · ALB · RDS)]
    RB[rollback-prod.yml] --> ECS
    TF[terraform.yml<br/>plan on PR · apply on main] --> ECS
  end
```

## Same origin, two images

The session cookie and CSRF header require the SPA and the API on one origin. The proxy routes by path.

```mermaid
flowchart LR
  B[Browser] -->|https://host| P{"Caddy in dev<br/>ALB rules in prod"}
  P -->|/api/* · /health* · /ready · /branding/*| BE["backend :4000"]
  P -->|everything else| FE["frontend nginx :8080"]
  BE --> DB[(PostgreSQL / RDS)]
  BE --> S[(documents: volume / S3)]
```

The frontend renders `index.html` (title, theme colour, favicon), `/env.js` and its CSP at container start, so no
per-customer build exists. The backend serves runtime branding at `/api/v1/public/config` and branding files at `/branding/*`.

## Dev deploy

1. An app push to `develop` → image `:sha-<short>` → `repository_dispatch deploy-dev {app, tag}`.
2. `deploy-dev.yml` (concurrency `deploy-dev`) commits the tag into `environments/dev/versions.env`.
3. It connects to the host by SSH with a **pinned host key** (or SSM Run Command via OIDC), runs `bootstrap-ec2.sh`
   (idempotent), syncs `environments/dev/`, writes `.env` from `DEV_ENV_FILE` (mode 600), and logs in to GHCR with the run's token.
4. On the host, `deploy-dev.sh` pulls, runs `provision` and `migrate` as one-off containers, starts the stack, creates
   the first admin once, waits for `/ready` and frontend health, and prunes images (keeps 3).
5. The runner smoke-tests `https://dev.rgrishabh.in`. On any failure it redeploys the previous versions, reverts the
   commit and fails the run.

## Prod deploy

1. Merging the release-please PR tags `vX.Y.Z` → signed `:vX.Y.Z` → `repository_dispatch release-prod`.
2. `release-prod.yml` opens or updates **one PR per app** that bumps every enabled customer, with release notes and a
   link to the dev run of the same commit.
3. Merging the PR → `deploy-prod.yml` → one job per changed customer in environment `prod-<slug>`. **Your approval is the only human step**
   (several customers can be approved in one dialog).
4. Per customer:
   1. Verify the cosign signatures. The image must be signed by `hrms-deployment/_app-publish.yml@main` and built from its own repo.
   2. Pin the image digests.
   3. Assume `hrms-release` via OIDC and check the account id.
   4. Run `deploy-prod.sh`: RDS snapshot, `provision`/`migrate`/`bootstrap` as one-off ECS tasks (abort on failure),
      register task definitions, update both services, wait for stability, check for circuit-breaker rollback, then smoke test.
5. On failure:
   - Both services go back to their previous task definitions.
   - The bot reverts that customer's `versions.env`.
   - Alerts go to SNS and the optional webhook.

## Security properties

- **Credentials:** no long-lived cloud keys anywhere; AWS access is OIDC only, and each account's role is trusted for one repo and environment.
- **Images:** only immutable tags are deployed (`sha-*`, `vX.Y.Z`; `latest` and `develop` are refused). Prod pulls by digest after signature verification.
- **Actions:** third-party actions are pinned to commit SHAs. Every workflow declares least-privilege `permissions`, concurrency and timeouts.
- **Secrets:** stored only in GitHub Environments and AWS Secrets Manager. `.env` is written on the host with mode 600 and is never committed (gitleaks in CI).
- **Database credentials:** the long-running backend never holds the database owner credentials. Migrations run in one-off containers or tasks.
- **Backups:** dev takes nightly `pg_dump` + documents tarballs (optional S3 copy). RDS has automated backups, AWS Backup, and a snapshot before each release.
