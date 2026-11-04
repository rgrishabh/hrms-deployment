# Disaster recovery

**This plan has not been exercised.** Nothing here has been applied or failed over, in any account. The times below are design targets, not measurements. Treat the first drill as the moment these steps get corrected, and run one before promising RPO or RTO to a client.

## Targets by tier

| Tier | Failure | RPO target | RTO target | How |
|---|---|---|---|---|
| On-prem | Host lost | Up to 24 hours, or since the last off-host copy | Hours | Restore the latest set to a new host (`bin/restore`). Needs `s3backup` or another off-host copy, and `DATA_ENCRYPTION_KEY` |
| `prod-low` | Node lost | None | 10 minutes | Auto Scaling replaces it, and Argo CD resyncs |
| `prod-low` | Zone with the database lost | About 5 minutes, because replica lag or PITR | 30 to 60 minutes | Promote the read replica if it's in a surviving zone, otherwise restore PITR to a new instance |
| `prod-low` | Region lost | None offered | None offered | No cross-region copy. A client who needs one belongs on `prod-high` |
| `prod-mid` | Zone lost | None to seconds | Minutes | Multi-AZ RDS and Redis, and two zones of nodes |
| `prod-mid` | Region lost | None offered | None offered | As `prod-low` |
| `prod-high` | Zone lost | None to seconds | Minutes | Three zones, and zone spread enforced |
| `prod-high` | Region lost | Database about 5 minutes, documents about 15 minutes or more | 2 to 4 hours, pilot light | Below |

S3 Replication Time Control is not enabled, so document replication has no guaranteed time. Replication lag and backup copies must be watched: no alarm for them exists yet.

## Pilot light or warm standby

| | Pilot light (built) | Warm standby |
|---|---|---|
| Always running in the DR region | RDS replica, S3 replica, secret replicas, KMS replica key, backup vault, VPC without NAT | All of that, plus NAT, EKS, nodes and the app at reduced size |
| Extra cost, estimate | About 150 to 280 a month | About 650 to 1,200 a month |
| RTO target | 2 to 4 hours | 15 to 45 minutes |
| Failover depends on | Terraform and EKS creation succeeding during an incident, and quota in the DR region | Mainly a database promotion and an origin change |
| Risk | The DR path is only proven by drills, and it can rot between them. A region-wide event may also make capacity scarce | Costs more, needs each release deployed twice, but real traffic checks are possible |
| Good for | Clients who accept half a day of downtime for a rare event | Clients with contractual RTO under an hour |

`prod-high` builds the pilot light. Setting `dr_activate = true` and leaving it on, with a DR overlay deployed, is the warm standby. Set `dr_region` in the guardrails' `allowed_regions` too.

## Before you ever need this

- Keep a copy of the client's Terraform values and overlay outside the primary region. GitHub already is.
- Check service quotas for EKS, EC2 and ALB in the DR region once a year.
- Run a drill at least yearly: restore into an isolated account or VPC, and time it.

## Failover (prod-high, region lost)

Run from a machine with the client's account credentials.

1. **Declare.** One person owns the incident. If the primary is partly alive, stop writes first, or you will lose whatever is written after promotion. For example, block traffic at CloudFront's WAF.
2. **Check what you are failing over to.** Look at `ReplicaLag` for `hrms-db-dr`, and the newest objects in the DR bucket.
3. **Promote the database.** This is one-way.
   ```bash
   aws rds promote-read-replica --region ap-south-2 --db-instance-identifier hrms-db-dr
   aws rds wait db-instance-available --region ap-south-2 --db-instance-identifier hrms-db-dr
   aws rds modify-db-instance --region ap-south-2 --db-instance-identifier hrms-db-dr \
     --backup-retention-period 14 --apply-immediately
   ```
4. **Build the rest.** With the primary region's APIs down, a normal plan cannot refresh those resources, so target the DR modules and skip refresh. Expect to adapt this, and test it in the drill: this is the step most likely to need changes.
   ```bash
   terraform plan -refresh=false -var dr_activate=true -out=dr.plan \
     -target=module.vpc_dr -target=module.eks_dr -target=module.iam_dr -target=module.acm_dr
   terraform apply dr.plan
   ```
   If `acm_dr` needs DNS validation at the client, this also needs them.
5. **Point the secrets at DR.** Replicas are read-only until detached. Repeat for each `hrms/*` secret. Then put the DR values into `hrms/infra`, taken from `terraform output dr_values`.
   ```bash
   aws secretsmanager stop-replication-to-replica --region ap-south-2 --secret-id hrms/infra
   aws secretsmanager put-secret-value --region ap-south-2 --secret-id hrms/infra --secret-string file://infra-dr.json
   ```
   The data key needs no change: the key is multi-region, so the replica decrypts the same ciphertext. `hrms/redis-url` has no replica, and the app runs without Redis, so delete `hrms-cache` from the DR overlay.
6. **Deploy.** Make the DR overlay in the client's repository with `scripts/new-client-overlay.sh` and the DR values. Install Argo CD and the add-ons as in onboarding, then sync. The provision Job needs master credentials, which a promoted replica does not have until you run `aws rds modify-db-instance --manage-master-user-password`. Do that, or drop the provision Job from the DR overlay, because the roles came across with the data.
7. **Move traffic.** CloudFront is global. Set `origin_alb_dns_name` to the DR ALB and apply with `-target=module.cloudfront`, or change the origin in the console if that is faster. The same domain and certificate stay in place.
8. **Verify.** `scripts/smoke-test.sh https://<domain> --expect-brand "<name>"`, then sign in, download a document and check that the worker sends email.
9. **Tell people** what the data-loss window was, from step 2.

## Failback

Do this in a planned window once the primary region is healthy. Allow a day.

1. In the primary region, remove the old database, keeping a final snapshot. Then create a cross-region replica of `hrms-db-dr`.
2. Reverse the document flow: enable replication from the DR bucket to the primary, and copy anything missing with S3 Batch Replication.
3. Confirm lag is near zero. Announce a window and stop writes.
4. Promote the primary replica. Point `hrms/infra` back. Deploy the normal overlay. Move CloudFront's origin back. Verify.
5. Rebuild DR. `rds_dr` and the secret replicas now differ from Terraform state: use `terraform state rm` and re-import or recreate them, then `dr_activate = false` for the pilot light.

## On backups

- **PITR:** RDS automated backups, 14 days on low and mid, 35 on high. Restores go to a new instance.
- **AWS Backup:** daily RDS and S3 recovery points, 14, 35 and 90 days by tier. Copied to the DR vault on high.
- **On-prem and dev:** `dev/bin/backup-loop.sh`, daily, plus the optional S3 copy. A failed run marks the `backup` container unhealthy.
- **A backup that has never been restored is only a hope.** Schedule restores. None have been run against these stacks.
