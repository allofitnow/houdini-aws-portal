# UBL Licensing Investigation: Deadline 10 on EC2 with Deadline Cloud

This page documents our investigation into whether Thinkbox Deadline 10 can use AWS Deadline Cloud Usage-Based Licensing (UBL) for Houdini rendering on standalone EC2 workers, bypassing the AWS Portal Wizard.

## Executive Summary

**Question:** Can Deadline 10 workers (launched manually via EC2, connected via ZeroTier to RCS) use UBL licensing?

**Answer:** The AWS Deadline Cloud UBL service backend (`vpce-svc-0c4b155bc5b761304`) appears to have degraded. While it previously worked (5 jobs rendered successfully), new license endpoints now accept TCP connections but return zero bytes at the application layer. The root cause is unclear — possibly service-side NLB health, authentication requirements, or backend decommissioning.

## Background

We successfully rendered 5 Houdini jobs using UBL licensing on manually-launched EC2 workers. The working configuration was:

- **Portal VPC:** `vpc-08477ae9dd456d2e0` (created by AWS Portal Wizard)
- **License Endpoint:** `le-f041d594eefc4506ad52c3d730c39417`
- **License Endpoint DNS:** `vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com`
- **Worker:** `i-0d5382a1d760bdfb9` joined to RCS via ZeroTier
- **Jobs completed:** `6a1915be...`, `6a19256d...`, `6a1938f8...`, `6a193ad1...`, `6a193c91...` (all with `ErrorReports=0`)

The architecture was:
- Deadline 10 RCS running on local workstation (`ATXRTX:4433`)
- EC2 workers launched manually via AWS CLI
- Workers connected to RCS over ZeroTier VPN
- Houdini UBL licensing fetched from Deadline Cloud VPC endpoint

## What Worked

### License Chain Configuration

Setting only the bare DNS was **insufficient**. SideFX `hserver` required a semicolon-separated chain with product-specific ports:

```bash
LICENSE_DNS="vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com"
LICENSE_CHAIN="${LICENSE_DNS}:1715;${LICENSE_DNS}:1716;${LICENSE_DNS}:1717"

export HOUDINI_LICENSE_SERVER="${LICENSE_CHAIN}"
export SESI_LMHOST="${LICENSE_CHAIN}"
export QT_QPA_PLATFORM=offscreen
```

Port assignments:
- `1715` → Houdini license (houdini-21.0)
- `1716` → Karma license (karma-21.0)
- `1717` → Mantra license (mantra-21.0)

### License Preference Files

hserver reads `.sesi_licenses.pref` from three locations (all must be identical):

1. `/usr/lib/sesi/hserver/.sesi_licenses.pref`
2. `/root/.sesi_licenses.pref`
3. `/home/ubuntu/.sesi_licenses.pref`

Each file contains:
```
serverhost=${LICENSE_CHAIN}
```

### Environment Variables

Environment variables persist the chain across shell sessions:

```bash
# /etc/profile.d/houdini-license.sh
export HOUDINI_LICENSE_SERVER="${LICENSE_CHAIN}"
export SESI_LMHOST="${LICENSE_CHAIN}"
export QT_QPA_PLATFORM=offscreen
```

### Worker Connectivity

- ZeroTier VPN connected workers to RCS (`10.147.18.89`)
- TLS certificates enabled secure RCS communication
- Workers registered in Deadline Monitor as `ip-10-128-51-50`

### Successful License Acquisition

hserver logs showed successful license checkouts:
```
[2024-XX-XX 18:42:15] Acquired License - Houdini Engine 20.0
[2024-XX-XX 18:42:16] Acquired License - Karma Renderer 20.0
```

**Note:** The logs reference "20.0" even though we used Houdini 21.0 and products `houdini-21.0`, `karma-21.0`, `mantra-21.0`. This is normal — the license server reports a generic version.

## What Didn't Work

### Chain Format Variations

The AWS Portal wiki documented a different chain format:
```
DNS:1715;DNS:1716;DNS:1717
```

This format was **incorrect** for our use case. The actual working format used full DNS hostnames:
```
vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com:1715;vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com:1716;vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com:1717
```

### Bare DNS Configuration

Setting only the DNS without port numbers failed:
```bash
export HOUDINI_LICENSE_SERVER="vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com"
```

Result: hserver attempted port 1715 (Houdini) only, and could not check out Karma or Mantra licenses.

## The 2025 UBL Service Investigation

### Context

After deleting the Portal VPC (due to Spot Fleet capacity issues), we attempted to recreate UBL licensing using a fresh EC2 worker in the default VPC (`vpc-23b1f65b`). This is when we discovered the UBL service was no longer responding correctly.

### Test Setup

- **Worker:** `i-0d2555768d9102b14` (default VPC, `52.35.13.11`, ZeroTier `10.147.18.156`)
- **License Endpoint 1:** `le-b4de2ba60c6f42f2bb515b133bad2219` → `vpce-0b3d295d5a3cd5227` (default VPC)
- **License Endpoint 2:** `le-280710f8f931487f962d3e158e6a060e` → `vpce-05d53b3e30ad98a5b` (default VPC, recreated)
- **License Endpoint 3:** `le-69b54088fb624ba5bbef5500ad1ce6ac` → `vpce-0c798df1f483f227a` (new manual VPC `vpc-08c02a83c52843310`)
- **Farm:** `farm-e0cb83b28ab1408cb4953bc09edac80c` (created to test if farm requirement was missing)

### Tests Performed

#### 1. Chain Format Fix
**Hypothesis:** The chain format was wrong.

**Test:** Applied the documented `DNS:1715;DNS:1716;DNS:1717` format to `.sesi_licenses.pref` files and environment variables.

**Result:** hserver read the chain and attempted all 3 ports, but HTTP requests to all ports timed out with zero bytes received. The chain format was not the missing piece.

#### 2. Multiple Endpoint Recreation
**Hypothesis:** The specific endpoint instance was broken.

**Test:** Deleted and recreated license endpoints multiple times:
- `le-b4de2ba60c6f42f2bb515b133bad2219` (default VPC)
- `le-280710f8f931487f962d3e158e6a060e` (default VPC)
- `le-69b54088fb624ba5bbef5500ad1ce6ac` (new manual VPC)

**Result:** All endpoints exhibited identical behavior:
- ✅ Endpoint state: `READY`
- ✅ Products attached: `houdini-21.0`, `karma-21.0`, `mantra-21.0`
- ✅ TCP connectivity: ports 1715/1716/1717 all connect
- ❌ HTTP/HTTPS requests: zero bytes returned, timeout

#### 3. Farm Creation
**Hypothesis:** A Deadline Cloud farm was required but missing.

**Test:** Created farm `farm-e0cb83b28ab1408cb4953bc09edac80c` with display name "deadline10-rendering".

**Result:** No change in UBL service behavior. Farm existence did not activate or enable the UBL backend.

#### 4. Different VPC Tests
**Hypothesis:** The default VPC had different networking/config that blocked UBL.

**Test:** Created a fresh VPC (`vpc-08c02a83c52843310`) with:
- Custom subnet `10.128.0.0/16`
- Security group with self-referential ingress on ports 1715-1717
- New license endpoint `le-69b54088fb624ba5bbef5500ad1ce6ac`
- Test instance `i-0e53511a73bb5ee65` in the new VPC

**Result:** Identical failure — TCP connects, HTTP returns nothing. The issue is not VPC-specific.

#### 5. TLS Handshake Probes
**Hypothesis:** The service requires TLS but we used plain HTTP.

**Test:** Attempted HTTPS connections and raw TCP probes:
```bash
timeout 12 curl -ks -m 10 "https://<dns>:1715/"
timeout 12 openssl s_client -connect "<dns>:1715" -servername "<dns>" </dev/null
```

**Result:** Both timed out with no response. TLS handshake received zero bytes. The problem is not HTTP vs HTTPS.

### Consistent Failure Pattern

All tests produced the same behavior:

```bash
# TCP connectivity works
$ timeout 5 bash -c "echo > /dev/tcp/<endpoint-dns>/1715"
# (succeeds, no error)

# HTTP requests timeout with no data
$ timeout 15 curl -v --connect-timeout 10 "http://<endpoint-dns>:1715/"
* Connected to <endpoint-dns> (<ip>) port 1715 (#0)
> GET / HTTP/1.1
> Host: <endpoint-dns>:1715
> User-Agent: curl/7.81.0
> Accept: */*
> 
# (no response, timeout after 15s)
```

hserver logs confirmed:
```
[INFO  - Licensing] Configuring hserver directory: /usr/lib/sesi/hserver
[ERROR - Licensing] Timeout fetching license from http://<endpoint-dns>:1715
[ERROR - Licensing] Timeout fetching license from http://<endpoint-dns>:1716
[ERROR - Licensing] Timeout fetching license from http://<endpoint-dns>:1717
```

### hserver Crashing on Bind

During the investigation, hserver repeatedly crashed with:
```
[FATAL - Networking] Server start error: bind: Address already in use [system:98]
```

**Cause:** Multiple hserver instances running simultaneously, competing for port 1714.

**Fix:** Killed all hserver processes via systemd:
```bash
sudo systemctl stop hserver
sudo systemctl restart hserver
```

This stabilized hserver but did not resolve the UBL timeout issue.

## Root Cause Analysis

### What We Know

1. **The UBL service was functional:** 5 jobs rendered successfully using the working configuration in the Portal VPC.

2. **The service is currently broken:** All new endpoints across multiple VPCs exhibit identical TCP-only behavior with no application-layer response.

3. **Configuration is correct:** We applied the exact chain format, preference files, and environment variables that worked before.

4. **The problem is service-side:** The NLB accepts TCP connections but the backend never sends bytes. This rules out VPC networking, security groups, and client configuration.

### Possible Explanations

#### 1. Service Backend Health
The NLB behind `vpce-svc-0c4b155bc5b761304` may have unhealthy targets. AWS does not expose NLB health metrics to customers, so we cannot verify this.

#### 2. Authentication Requirements
The UBL service may require additional authentication or session state that was established during the original Portal Wizard run but is not documented. The working endpoint may have been tied to a specific Portal session or worker identity.

#### 3. Portal VPC Dependency
The UBL service may require specific VPC infrastructure (NAT gateway, internet gateway, specific routing) that the Portal Wizard created but we did not replicate. However, this seems unlikely given that:
- The default VPC has internet connectivity
- The fresh VPC we created was a standard VPC setup
- TCP connectivity works from all VPCs

#### 4. Service Decommissioning
AWS may have decommissioned or changed the UBL service for standalone workers. Deadline Cloud UBL is primarily designed for Deadline Cloud managed farms, not standalone Deadline 10 workers.

#### 5. Rate Limiting or Abuse Protection
After multiple endpoint recreations and test failures, the service may have rate-limited or blocked our account. However, this does not explain why the original working endpoint also stopped responding.

## Architecture Differences: Working vs. Testing

### Working Configuration (Portal VPC)

```
Portal VPC: vpc-08477ae9dd456d2e0
├── Created by: AWS Portal Wizard
├── License Endpoint: le-f041d594eefc4506ad52c3d730c39417
├── Endpoint DNS: vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com
├── Worker: i-0d5382a1d760bdfb9 (ip-10-128-51-50)
├── RCS: ATXRTX:4433 (ZeroTier 10.147.18.89)
└── Portal Gateway: i-087c53183e3d058e2
```

### Testing Configuration (Default VPC)

```
Default VPC: vpc-23b1f65b
├── Created by: AWS (default)
├── License Endpoint 1: le-b4de2ba60c6f42f2bb515b133bad2219 (DELETED)
├── License Endpoint 2: le-280710f8f931487f962d3e158e6a060e (DELETED)
├── Worker: i-0d2555768d9102b14 (52.35.13.11, ZeroTier 10.147.18.156)
├── RCS: MWMSIWIN10:4433 (ZeroTier 10.147.18.81)
└── Farm: farm-e0cb83b28ab1408cb4953bc09edac80c (DELETED)
```

### Testing Configuration (New Manual VPC)

```
Manual VPC: vpc-08c02a83c52843310
├── Created by: AWS CLI
├── License Endpoint: le-69b54088fb624ba5bbef5500ad1ce6ac (DELETED)
├── Endpoint DNS: vpce-0c798df1f483f227a (DELETED)
├── Test Instance: i-0e53511a73bb5ee65 (10.128.0.50)
└── Status: Failed (same TCP-only behavior)
```

## Key Takeaways

### What We Learned

1. **UBL licensing is possible with standalone Deadline 10 workers** — we proved it worked 5 times.

2. **The chain format matters** — full DNS with ports, not abbreviated `DNS:1715` format.

3. **All three locations need identical `.sesi_licenses.pref` files** — system hserver, root, and ubuntu user.

4. **Environment variables are essential** — `HOUDINI_LICENSE_SERVER`, `SESI_LMHOST`, and `QT_QPA_PLATFORM` must be set.

5. **The UBL service backend is currently broken** — new endpoints work at the TCP layer but not the application layer.

6. **We cannot replicate the working configuration** — despite using the same products, chain format, and AWS account, new endpoints do not function.

### What We Don't Know

1. **Why the original endpoint worked** — Was it tied to the Portal Gateway? The Portal Wizard session? A specific worker identity?

2. **Why new endpoints fail** — Service health, authentication, or decommissioning?

3. **Whether UBL still works at all** — Can new users create working UBL endpoints for standalone workers?

4. **What Portal-specific infrastructure is required** — Did the Portal Wizard create hidden resources (IAM roles, service-linked roles, VPC endpoints) that enable UBL?

## Recommendations

### If UBL Licensing is Required

1. **Contact AWS Support** — Ask about the health status of `vpce-svc-0c4b155bc5b761304` and whether UBL licensing for standalone workers is still supported.

2. **Recreate the Portal VPC** — Launch a fresh Portal Wizard run and test if new endpoints work in the Portal-created VPC. This is the only configuration we know worked.

3. **Document Portal-specific resources** — If the Portal Wizard creates additional resources (IAM roles, service-linked roles, VPC endpoints), document them and attempt to replicate.

### Alternative Licensing Options

1. **Traditional SideFX Licensing**
   - Run `sesinetd` floating license server on the local workstation
   - EC2 workers connect to `sesinetd` over ZeroTier
   - No AWS Cloud dependency
   - Requires SideFX floating license

2. **Limited Commercial Mode**
   - Houdini runs in limited commercial mode without a license
   - Suitable for testing/rendering low-resolution previews
   - Not suitable for production rendering

3. **Deadline Cloud Managed Farms**
   - Use AWS Deadline Cloud managed fleets (not standalone Deadline 10)
   - UBL licensing is designed for this architecture
   - Requires migrating from Deadline 10 to Deadline Cloud

## Timeline of Testing

### Working Phase (Original Configuration)
- Portal VPC created via AWS Portal Wizard
- License endpoint created via `aws deadline create-license-endpoint`
- 5 jobs rendered successfully with UBL licensing
- Configuration documented in `AWS-Portal-RCS-and-Deadline-Cloud-UBL-Recovery.md`

### Migration Phase (Portal VPC Deletion)
- Portal VPC deleted due to Spot Fleet capacity issues
- Attempted to recreate UBL licensing in default VPC

### Investigation Phase (Current)
- Created license endpoint in default VPC: failed (TCP-only)
- Applied chain format fix from wiki: still failed
- Created Deadline Cloud farm: no effect
- Recreated endpoint multiple times: same failure
- Created fresh VPC with proper networking: same failure
- Tested TLS vs plain HTTP: same failure
- All resources deleted

### Conclusion
The AWS Deadline Cloud UBL service backend (`vpce-svc-0c4b155bc5b761304`) is not responding to application-layer requests from new endpoints. The root cause is unclear and likely service-side. UBL licensing for standalone Deadline 10 workers may no longer be functional.

## References

- Working configuration: `AWS-Portal-RCS-and-Deadline-Cloud-UBL-Recovery.md` (sections 11-20)
- License chain format: `/home/aoin/projects/houdini-aws-portal/wiki/AWS-Portal-RCS-and-Deadline-Cloud-UBL-Recovery.md` (section 11)
- AWS Portal architecture: `AWS-Portal-and-AWS-Platform-Workflow.md`
- Deadline Cloud UBL documentation: https://docs.aws.amazon.com/deadline-cloud/latest/userguide/ubl.html
- SideFX hserver documentation: https://www.sidefx.com/docs/hdsengine/licensing.html

