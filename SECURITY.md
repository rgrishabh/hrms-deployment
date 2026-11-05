# Security

Report vulnerabilities privately to the repository owner. Do not open public issues for them. Controls and the threat model are in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), and the application's in `hrms-backend/SECURITY.md`.

## Third-party image findings

**The Definition of Done asks for zero critical and high findings. The count is not zero.** Each image below is already at its newest tag and digest, and none of the remaining findings can be fixed from this repository without rebuilding someone else's image. This list records them. **It suppresses nothing:** none of these IDs are in `.trivyignore`, whose two entries are `trivy config` checks.

Scanned 2026-11-05 with Trivy 0.76.1 and the database of the same date, on `linux/arm64` and `linux/amd64`, which gave the same counts. **Review by 2026-12-05**, or sooner on a new image digest. Re-pin, rescan and update this table.

| Image, as pinned | Critical / high | Distinct CVEs | Fix available by moving tag? | Runs in production? |
|---|---|---|---|---|
| `postgres:17.11-alpine@sha256:266d3c25…` | 1 / 25 | 26 | No | **No.** Every tier uses RDS. Compose only |
| `clamav/clamav-debian:1.5.4@sha256:c21aa18c…` | 1 / 56 | 20 | No | **Yes, every tier** |
| `caddy:2.11.8-alpine@sha256:3db3a09e…` | 0 / 2 | 1 | No | **No.** The tiers use ALB, and Traefik on tier-low. Compose only |

The other pinned images and the app images scanned at 0 / 0 on the morning of 2026-11-05, on `arm64`. They were not rescanned for this entry.

**Tags tried instead,** all `arm64`: `postgres:17.11-alpine3.23` 1 / 25, `postgres:18.6-alpine` 2 / 26, `postgres:17.11-trixie` 2 / 89, `clamav-debian:1.5.4_base` 1 / 56, `clamav-debian:unstable` 5 / 115. None is better. Postgres 18 would also be a major upgrade, and a Debian Postgres would change the collation library under an existing data volume.

### postgres: `gosu` only. Not reachable

| CVEs | Package | Fix upstream | Reachable here |
|---|---|---|---|
| CVE-2025-68121 (critical); CVE-2025-61726, CVE-2025-61729, CVE-2026-25679, CVE-2026-27145, CVE-2026-32280, CVE-2026-32281, CVE-2026-32283, CVE-2026-33811, CVE-2026-33814, CVE-2026-33818, CVE-2026-39820, CVE-2026-39821, CVE-2026-39822, CVE-2026-39836, CVE-2026-42499, CVE-2026-42504, CVE-2026-56853, CVE-2026-56858, CVE-2026-56859, CVE-2026-56860, CVE-2026-56862, CVE-2026-78667, CVE-2026-78669, CVE-2026-97031, CVE-2026-111943 | Go stdlib 1.24.6 in `/usr/local/bin/gosu` 1.19 | Newer Go, when the image ships a `gosu` built with it. Nothing else in the image is flagged | **No.** The entrypoint calls `gosu` only when its UID is 0 (`docker-entrypoint.sh:341-343`). `postgres` runs as `70:70` with no capabilities. `volume-perms` runs as root but replaces the entrypoint with `chown`. Nothing in this repository calls `gosu` |

### clamav-debian: `libxml2` is reachable. Everything else is not

clamd scans uploads, and `libclamav` links `libxml2`. clamd's reported configuration has `ScanXMLDOCS = yes`, so a signed-in user's DOCX or XLSX, and HTML inside what they send, can reach the parser. Treat the first row as live.

| CVEs | Package | Debian status | Reachable here |
|---|---|---|---|
| CVE-2026-6653 (critical, denial of service, `xmlParseInternalSubset`), CVE-2026-86138 (`xmlDictAddQString`), CVE-2026-86140 (`xmlSnprintfElements`) | `libxml2` 2.9.14 | Affected, no fix | **Assume yes.** All three are in or near the parser that `xmlTextReader` and `htmlReadMemory` drive. Not proven exploitable: no exploit was attempted, and whether ClamAV's flags reach the validation path of CVE-2026-86140 was not checked |
| CVE-2026-86139 (`xmlURIEscapeStr`), CVE-2026-86142 (XPointer), CVE-2026-86143 (output callbacks), CVE-2026-86144 (XInclude) | `libxml2` | Affected, no fix | **Unlikely.** `libclamav` imports only the reader, `htmlReadMemory` and string helpers, with none of these functions. Internal calls inside `libxml2` were not traced |
| CVE-2026-74860 | `libxml2` | Affected, no fix | **No.** Needs the Python bindings, which are not there |
| CVE-2026-8458, CVE-2026-12064 | `libcurl4t64` | Affected, no fix | **Very unlikely.** Linked by `freshclam` only, which talks HTTPS to the signature mirror. No SFTP or SCP, and no credentials to reuse |
| CVE-2026-109518 | `apt`, `libapt-pkg7.0` | **Fixed in 3.0.4**, published 2026-11-04, after the image's 2026-11-02 build. The next upstream rebuild should clear it | **No.** Nothing runs `apt` |
| CVE-2026-76642, CVE-2026-78408, CVE-2026-78409, CVE-2026-78410 | `util-linux` family | Affected, no fix | **No.** Not linked by `clamd` or `freshclam`. The issues need `mount` or `nsenter` with privileges, and the container has no capabilities |
| CVE-2026-54369, CVE-2026-16742, CVE-2025-69720, CVE-2026-119373, CVE-2026-9538 | `libacl1`, `libsystemd0` and `libudev1`, `ncurses`, `libsqlite3-0`, `perl-base` | Affected or deferred, no fix | **No.** Not linked by `clamd` or `freshclam`, and neither runs these programs |

Linkage was read with `ldd` in the image, and imports with `strings` on `libclamav.so.12`.

**What limits a bad document.** clamd is non-root, with a read-only root filesystem and no capabilities. Only the backend, the worker and the signature check can reach port 3310. A crash fails closed: uploads answer 503. **What does not:** its egress allows 443 to any address, for signature downloads, so a compromised clamd could send a document it is scanning off the box.

**Open decision for the owner.** `ScanXMLDOCS no` and `ScanHTML no` would cut most of this path, at the cost of less inspection of those formats. It is not applied, because it weakens the scanner to quieten a finding, and it would need the EICAR-in-DOCX test rerun. Restricting egress to the signature mirror's addresses is the other option, but that CDN's addresses are not stable.

### caddy: one denial-of-service issue. No path found

| CVE | Package | Fix upstream | Reachable here |
|---|---|---|---|
| CVE-2026-116587, crafted RSA parameters in a JWK | `go-jose/v4` 4.1.5 in `/usr/bin/caddy` | 4.1.6, when a Caddy release ships it | **No path found.** `dev/Caddyfile` has no JWT handling or `acme_server`, so no public request supplies a JWK. Caddy's source was not audited |
| The same CVE | `go-jose/v3` 3.0.5 | No fix listed for v3 | As above |

Removing `go-jose` means building a custom Caddy. That is not worth it for this, and it would give up the official image's updates.

### The old stack

`environments/dev` uses floating `postgres:17-alpine` and `caddy:2.10-alpine`, and was not scanned here. It goes away in `docs/CUTOVER.md` Step 3.
