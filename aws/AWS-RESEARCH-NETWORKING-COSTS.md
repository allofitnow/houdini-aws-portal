# AWS Research — Networking Costs & Requirements

Source data: AWS VPC pricing page, PrivateLink pricing page, Deadline Cloud pricing page.
Retrieved: 2026-06-24.

## Confirmed pricing (us-east-1 reference region)

### NAT Gateway
- **Hourly**: $0.045/hr ($1.08/day, $32.40/month) — billed while provisioned, even idle
- **Data processing**: $0.045/GB processed through the gateway
- **Regional NAT Gateway**: $0.045/hr **per AZ** (multi-AZ = multiply)
- **Data transfer**: standard EC2 data transfer rates apply on top
- Source: https://aws.amazon.com/vpc/pricing/ (NAT Gateway tab)

### VPC Endpoints — two types

| Type | Hourly | Data processing | Used for |
|------|--------|----------------|----------|
| **Gateway endpoint** | **$0** | **$0** | S3, DynamoDB only — always free |
| **Interface endpoint (PrivateLink)** | $0.01/hr/AZ | $0.01/GB (tiered) | AWS services, Deadline Cloud UBL |
| **Resource endpoint** | $0.02/hr/resource | $0.01/GB (tiered) | Cross-VPC resource access |

- The UBL license endpoint creates an **interface endpoint** — costs $0.01/hr/AZ
- Portal VPCs typically have interface endpoints in 2-3 AZs = $0.02-$0.03/hr
- Source: https://aws.amazon.com/privatelink/pricing/

### Public IPv4 Address (since Feb 2024)
- **All** public IPv4 addresses: $0.005/hr ($0.12/day, $3.60/month)
- Applies to: Elastic IPs (in-use), auto-assigned public IPs on EC2, ALBs, NAT Gateways
- Idle Elastic IPs are charged at the **same** $0.005/hr rate
- **Impact on direct-spawn workers**: each worker with a public IP costs $3.60/month while running (expected render cost, not a leak)
- Source: https://aws.amazon.com/vpc/pricing/ (Public IPv4 Address tab)

### VPC / Subnet / Route Table / IGW
- All **free** — no hourly charge
- Source: https://aws.amazon.com/vpc/pricing/ (no pricing tab for these = free)

### EBS (gp3)
- $0.08/GB-**month** (not per day!)
- $0.08/IOPS-month provisioned (above 3,000 free)
- $0.04/MBps-month throughput provisioned (above 125 free)
- Source: https://aws.amazon.com/ebs/pricing/

## Project-specific cost model

### Direct-spawn path (`launch_spot_worker.sh`)
No NAT Gateway. Workers in public subnets via IGW.

| Resource | While running | While idle/leaked |
|----------|---------------|-------------------|
| EC2 spot instance | Spot price (varies) | $0 (terminated) |
| EBS (attached) | $0.08/GB/month | $0.08/GB/month (available = leaked) |
| Public IP | $0.005/hr ($3.60/mo) | $0 (released on terminate) |
| Elastic IP (unattached) | — | $0.005/hr = $3.60/mo (leak) |

### Portal path (`launch_portal_worker_fleet.sh`)
Portal creates VPC with private subnets + NAT Gateway.

| Resource | While active | After fleet cancelled, before cleanup |
|----------|--------------|--------------------------------------|
| NAT Gateway | $0.045/hr ($32.40/mo) | **$32.40/mo until deleted** (leak!) |
| VPC endpoints (interface) | $0.01/hr/AZ | **$0.01/hr/AZ until deleted** (leak!) |
| Gateway instance | EC2 rate | Terminated by Portal |
| CloudFormation stack | — | DELETE_FAILED = orphan |

## Key findings

1. **NAT Gateway is the #1 leak** — $32.40/month per Portal VPC left running. The cleanup script (`portal_infra.sh stop`) does delete CF stacks which should remove the NAT GW, but `DELETE_FAILED` stacks leave it alive.

2. **VPC endpoint interface charges compound** — a Portal VPC with 3 AZs has 3 interface endpoints at $0.01/hr each = $0.72/day = $21.60/month. The cleanup script handles this (`delete_orphan_vpc_endpoints_for_vpcs`).

3. **EBS leak math was wrong in the spec** — a leaked 100GB gp3 volume costs $8/month, not $240/month. Still a leak, but much less alarming.

4. **Public IPv4 is now universally charged** — since Feb 2024, even auto-assigned public IPs on running instances cost $3.60/month. Direct-spawn workers are more expensive than they appear.

5. **Gateway VPC endpoints are free** — S3 and DynamoDB traffic should use gateway endpoints, not interface endpoints. The Portal stack likely already does this for its internal S3 buckets.

## NAT Gateway requirement per worker path

### Direct-spawn (`launch_spot_worker.sh`): NOT needed
Workers launch into public subnets (`map-public-ip-on-launch=true`), get public IPs, and route outbound through the **Internet Gateway (free)**. Code evidence:
- `launch_spot_worker.sh` line 108: filters subnets by `map-public-ip-on-launch=true`
- Workers access Secrets Manager and ZeroTier coordination servers via public endpoints
- Workers reach RCS via ZeroTier overlay (10.147.18.89:4433)
- No private subnet routing is required

### Portal (`launch_portal_worker_fleet.sh`): Required by Portal, not by you
AWS Portal creates its own VPC with private subnets and provisions a NAT Gateway automatically. You don't control this — it's part of the Portal CloudFormation stack. The workers need the NAT Gateway to:
- Reach Secrets Manager (for license-endpoint-dns secret)
- Reach ZeroTier coordination servers (if the ZeroTier path is used — Portal workers may not need this)
- Pull packages during boot (dnf, pip, etc.)

### UBL license endpoint connectivity
- Workers connect to UBL endpoint on **TCP 1715-1717** via the VPC (not via NAT Gateway or internet)
- The UBL endpoint itself is a Deadline Cloud managed resource inside the Portal VPC
- No internet or NAT Gateway path is needed for UBL licensing

## Summary: What actually costs money

| Resource | Monthly cost (idle) | Leak risk | Who creates it |
|----------|---------------------|-----------|----------------|
| NAT Gateway | $32.40 | **HIGH** — survives fleet cancel | Portal CF stack |
| VPC Endpoint (interface) | $7.20-$21.60 (1-3 AZ) | MEDIUM — blocks VPC delete | Portal CF stack |
| EBS volume (available) | $0.08/GB | LOW — small amounts | Worker launch/term |
| Elastic IP (unattached) | $3.60 | LOW — rare | Manual |
| CloudFormation stack (failed) | varies | MEDIUM — blocks VPC cleanup | Portal |
| Public IPv4 (running instance) | $3.60 | N/A — expected while running | Direct-spawn |
| UBL license endpoint | unknown idle cost | LOW — no documented standing fee | Deadline Cloud |
| VPC / Subnet / IGW | $0 | NONE — free | Both |
