# Cost estimates

**These are estimates, not quotes.** They come from memory of AWS list prices for `ap-south-1`, written on 2026-11-05. Nothing was checked against the AWS price list or calculator for this page. Assume about 30% error either way, and check the calculator before you quote a client.

**Assumptions**

- On-demand prices, USD per month, 730 hours. Taxes, support plans and Savings Plans are excluded. A one-year Savings Plan or reserved RDS would lower compute by about 30%.
- Light traffic: under 200 GB out and under 20 million requests a month. Costs that grow with data are ranges.
- One client, one AWS account. No shared clusters.
- Monitoring is CloudWatch and alarms only. A Prometheus and Grafana stack, if you add it, needs extra node capacity.

## Summary

| Tier | Users | Shape | Idle cost, USD a month |
|---|---|---|---|
| On-prem (`dev/`) | About 100 | One host of 4 vCPU and 8 GB; client's hardware | No AWS cost except an optional off-host backup, under 5 |
| `prod-low` | About 100 to 300 | k3s on one Graviton node, single-AZ RDS plus replica, no NAT gateway | **130 to 190** |
| `prod-mid` | About 300 to 2,000 | EKS, two zones, Multi-AZ RDS, Redis, CloudFront | **530 to 700** |
| `prod-high` | 2,000 and up | EKS, three zones, Multi-AZ RDS plus replica, Redis, CloudFront, DR pilot light | **2,100 to 2,900** |

User counts are planning guesses: nothing has been load-tested.

## prod-low

| Item | USD a month |
|---|---|
| EC2 `t4g.large` (k3s) | 33 to 45 |
| EBS 40 GB gp3 + NAT instance's 8 GB | 4 to 5 |
| NAT instance `t4g.nano` | 3 to 4 |
| ALB + LCU | 20 to 28 |
| Public IPv4 (ALB 2, NAT 1) | 11 |
| RDS `db.t4g.small`, single-AZ | 25 to 35 |
| RDS read replica, same size | 25 to 35 |
| RDS storage, 20 GB each | 5 to 6 |
| WAF ACL, rules, requests | 10 to 15 |
| Secrets Manager (7 or 8) + KMS | 4 to 5 |
| CloudWatch logs, alarms | 5 to 15 |
| AWS Backup, S3, GuardDuty | 5 to 15 |
| **Total** | **about 130 to 190** |

### EKS or k3s for this tier

| Item | k3s (chosen) | EKS |
|---|---|---|
| Control plane | 0 | 73 |
| Nodes | 1 `t4g.large`: 33 | 2 `t4g.medium`, needed for a useful PDB: 65 |
| Egress | NAT instance: 3 | NAT gateway + data: 45 |
| **Difference** | | **about 145 a month more** |

See `DECISIONS.md`, ADR-005. What you give up: a node failure is a short outage, and backend, worker and External Secrets share one AWS identity.

The read replica is the first thing to cut if the budget is tight. It's about a quarter of this bill, and the app works without `DB_READ_HOST`.

## prod-mid

| Item | USD a month |
|---|---|
| EKS control plane | 73 |
| EC2 2 × `m7g.large` | 110 to 130 |
| EBS 100 GB gp3 | 9 to 10 |
| NAT gateway + data | 45 to 60 |
| ALB + LCU | 20 to 30 |
| CloudFront | 5 to 20 |
| WAF | 10 to 15 |
| RDS `db.t4g.large`, Multi-AZ | 150 to 190 |
| RDS storage, 50 GB Multi-AZ | 13 to 15 |
| ElastiCache 2 × `cache.t4g.small` | 45 to 60 |
| Secrets Manager + KMS | 5 |
| CloudWatch logs, control plane logs, alarms | 20 to 50 |
| AWS Backup, S3, GuardDuty | 15 to 40 |
| **Total** | **about 530 to 700** |

## prod-high

| Item | USD a month |
|---|---|
| EKS control plane | 73 |
| EC2 3 × `m7g.xlarge` | 330 to 380 |
| EBS 150 GB gp3 | 14 |
| NAT gateways × 3 + data | 110 to 140 |
| ALB + LCU | 30 to 50 |
| CloudFront | 30 to 100 |
| WAF | 15 to 30 |
| RDS `db.r7g.large`, Multi-AZ | 420 to 500 |
| RDS read replica | 210 to 250 |
| RDS storage, 200 GB Multi-AZ plus replica | 75 to 85 |
| ElastiCache 3 × `cache.r7g.large` | 400 to 480 |
| Secrets Manager + KMS, two regions | 10 |
| CloudWatch logs, alarms | 50 to 150 |
| AWS Backup, S3, GuardDuty | 50 to 130 |
| **Primary total** | **about 1,900 to 2,500** |
| DR pilot light: RDS replica `db.t4g.large` with storage | 110 to 160 |
| DR pilot light: S3 replica and replication transfer | 15 to 40 |
| DR pilot light: backup copies and cross-region transfer | 20 to 60 |
| DR pilot light: secret replicas, key replica, flow logs | 10 to 20 |
| **With DR pilot light** | **about 2,100 to 2,900** |

Warm standby, with a running EKS cluster, nodes and NAT in the DR region, adds about 500 to 900. See `docs/DR.md`.

## What drives the bill

- **RDS** is the largest line on mid and high. Reserved instances help most here.
- **Log retention.** All roots default to 365 days to meet the check and for HR audit needs. Control plane and WAF logs at that length can grow past the ranges above, and `log_retention_days` is one variable.
- **NAT data.** S3 goes through the free gateway endpoint. Image pulls from GHCR do not; mirror images if pulls get large.
- **ClamAV** needs about 1.2 GiB per replica, a large share of the `t4g.large` on low.
