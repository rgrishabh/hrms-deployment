# Threat model inputs: infrastructure

These are inputs for a threat model, not a finished one. They cover the deployment and infrastructure layer. Application threats, such as authorization or RLS, belong with the backend. Nothing here has been penetration-tested.

## Assets

| Asset | Where | Why it matters |
|---|---|---|
| Employee personal data, salaries, bank details | RDS, backups | Regulatory exposure and direct harm to people |
| Documents | S3 or `app-storage`, backups | Identity documents, contracts |
| Data key | KMS (prod); `.env` (dev, on-prem) | Decrypts bank details. Losing it loses that data for good |
| DB master and owner credentials | Secrets Manager; `.env` | Bypass of RLS |
| Terraform state | Shared S3 bucket, KMS | Holds the Redis AUTH token and resource details |
| `DEPLOY_REPO_TOKEN` | Three public repos | Admin-level push to `main`, which runs on the dev host |
| Signing identity | `_app-publish.yml@main` | Trust in every image |

## Trust boundaries

1. Internet to CloudFront or ALB, or Caddy on dev and on-prem
2. Ingress to pods, enforced by NetworkPolicy
3. App pods to the data tier, enforced by security groups and database roles
4. Pods to AWS APIs, through IRSA or, on tier-low, the node role
5. GitHub Actions to AWS, through OIDC by environment; to the dev host, through SSH
6. Git to cluster, through Argo CD pull
7. A public repository to private client overlays
8. One client to another, separated by accounts: no shared clusters or databases

## Entry points

| Entry | Exposure | Controls |
|---|---|---|
| `/`, `/api`, `/health`, `/ready`, `/brand` | Public | WAF on AWS tiers, Host allowlist, TLS 1.2+, app auth and rate limits |
| `/metrics` | Internal | 404 at the public edge: Caddy, the Ingress's ALB action, and the ALB listener rule on tier-low. Prometheus scrapes the backend directly with `METRICS_TOKEN`. NetworkPolicy limits it to the VPC and pod ranges |
| Kubernetes API | Private by default; on k3s, on the node | `endpoint_public_cidrs` must return to empty after onboarding |
| Dev host SSH | Port 22 open to GitHub's wide ranges | Pinned key, no password. SSM path exists but is untested |
| Mailpit UI | Not published | Holds every email a dev box sends. Loopback only, through the override file |
| Argo CD | Not exposed | `kubectl port-forward` only |
| Node shell | SSM only | No inbound SSH on tier nodes |

## Threats and controls

| Threat | Controls in place | Gap |
|---|---|---|
| Stolen container reaches other AWS resources | IRSA per workload. IMDS hop limit 1 on EKS. Default-deny egress, with IMDS excluded | Tier-low: backend, worker and External Secrets share the node role, reached through IMDS (ADR-005) |
| Container escape or tampering | Non-root, read-only root, no capabilities, seccomp, PSA `restricted`, Kyverno | One k3s node has no isolation beyond the kernel |
| Lateral movement inside a cluster | Default-deny NetworkPolicy. Frontend has DNS only | The 10.0.0.0/8 rule is wider than the VPC. On EKS, enforcement depends on the CNI setting, which Terraform sets |
| Superuser credentials reach app pods | Separate Secrets by workload class. Provision is a Job, not an initContainer. Compose has no `env_file: .env` | `backup` holds owner credentials, as the audit found, because `pg_dump` must see past RLS |
| WAF bypass by reaching the ALB directly | Security group limited to CloudFront's prefix list. Host rules | The prefix list is shared by all CloudFront customers (ADR-010) |
| Malicious upload | ClamAV, required in production | Scanning depends on fresh signatures. No alarm if freshclam fails |
| Backup loss or false success | Fixed loop, verified dumps, unhealthy on failure, pre-migration backup on dev | Compose backups are unencrypted at rest on the volume. Off-host copy is opt-in. No restore drill yet |
| Ransomware or deletion in AWS | Versioning, deletion protection, AWS Backup, SCP on KMS deletion | Vault Lock and S3 Object Lock are not enabled |
| Supply chain | SHA-pinned actions. Digests in Kubernetes, checked by Kyverno. Cosign signing, SBOM, provenance | Compose images are pinned by tag, not digest. Dev does not verify signatures. The Argo CD and add-on charts are pinned by version only. **The cluster has no admission check for signatures** |
| Compromised app repo writer gets the deployment PAT | Hazard noted in the audit | Still open: replace with a GitHub App scoped to this repository |
| Client data leak through this public repo | Templates only, `*.tfvars` ignored, plan output withheld from logs, gitleaks | Depends on people using the private repository. The dev host IP is gone from current docs but remains in git history |
| Secrets in Terraform state | Write-only passwords, RDS-managed master, KMS-generated data key | Redis AUTH token remains in state |
| TLS interception inside the VPC | Database TLS `verify-full`. ElastiCache TLS | ALB to pods and to Traefik is plain HTTP inside the VPC |
| Tier-low node replaced with stale settings | k3s binary pinned by hash, AMI from a public parameter | A new launch picks up the latest AMI without testing |
| DoS | WAF rate limit, HPA, resource limits | App rate limits are per replica until Redis backs them. Tier-low has little headroom |

## Residual risks to accept or fix

Each needs an owner's decision:

1. Tier-low's shared node role.
2. CloudFront prefix-list bypass.
3. Plain HTTP from ALB to pods.
4. No admission control for image signatures.
5. The admin PAT.
6. No restore drill, and an untested DR plan.
7. No Vault Lock or Object Lock.
8. No alarm yet for replication lag, freshclam failures, backup job failures on AWS, or a stuck worker.

## Data residency

Defaults stay in India: `ap-south-1`, with `ap-south-2` for DR. CloudFront's edge caches only `/assets/*`, which holds no personal data. WAF logs in `us-east-1` redact the cookie, CSRF and device-key headers, but they do contain client IPs and URLs, and a client's rules may treat that as a transfer out of India. The dev host's address suggests `ap-southeast-2`, as the audit noted, and this needs checking.
