# Instance Allocation Logic

This document is the first-class spec for how render workers are allocated across AWS regions and instance types. It covers the Spot Event Plugin (SEP) configuration, scaling behavior, failover strategy, idle shutdown, and the relationship between Deadline groups and AWS Spot Fleet Requests (SFRs).

This spec applies to the on-prem ZeroTier + Backblaze B2 bursting path. The same allocation principles will be carried forward if the farm migrates to AWS Portal.

---

## Design goals

1. **Capacity over location.** Workers are ephemeral. The farm should burst wherever GPU spot capacity is available, not be tied to a single region.
2. **Job-to-group affinity.** A Deadline job targets a group (e.g., `aws-spot-east`). SEP translates that group into a Spot Fleet configuration.
3. **Same VPC per launch spec.** Security groups and subnets within a single launch specification must belong to the same VPC.
4. **No per-instance output folders.** Render output is written to a shared Backblaze B2 path (`/mnt/renders/outputs/<job-id>_<job-name>/`). Instances are ephemeral; output organization is by job, not by instance.
5. **Input assets from B2.** Input scene files and other assets are fetched from B2 (`inputs/` prefix) using the existing rclone mount.

---

## Region and group mapping

The SEP config is multi-region. Each tracked region contains one or more Deadline groups.

| Region | Deadline group | Purpose |
|---|---|---|
| `us-west-2` | `aws-spot` | Primary overflow capacity |
| `us-east-1` | `aws-spot-east` | Secondary / failover capacity |

A job submitted to `aws-spot-east` can only be picked up by a worker launched by the `us-east-1` Spot Fleet configuration. SEP creates and scales the SFR for that group when queued jobs exist.

### Future expansion

Additional regions should follow the same pattern: one VPC, one security group, one or more subnets, one AMI copy, and one SEP group config per region. Candidate overflow regions should be chosen based on GPU spot availability, cost, and latency to the on-prem RCS over ZeroTier.

Current US-only GPU spot drought (June 2026) shows that `g4dn`, `g5`, and `g6` families are effectively unavailable in `us-west-2` and `us-east-1`. Expanding to other regions is the fastest way to restore capacity, but each region adds fixed and variable costs.

| Region | GPU families | Spot price (indicative) | ZeroTier latency to ATX | Fixed-cost items |
|---|---|---|---|---|
| `us-west-2` | g4dn, g6 | $0.40–$0.80/hr | ~35 ms | baseline |
| `us-east-1` | g4dn, g6 | $0.40–$0.80/hr | ~55 ms | AMI copy, VPC, SG |
| `ca-central-1` | g4dn, g6, g6e | $0.40–$0.90/hr | ~50 ms | AMI copy, VPC, SG |
| `eu-west-2` (London) | g4dn, g6, g6e | $0.45–$1.00/hr | ~110 ms | AMI copy, VPC, SG |
| `ap-southeast-1` (Singapore) | g4dn, g5, g6 | $0.50–$1.10/hr | ~190 ms | AMI copy, VPC, SG |

Cost factors per new region:

1. **AMI storage**: ~$0.40/month per 20 GB EBS snapshot per region.
2. **VPC plumbing**: NAT Gateway (~$0.045/hr if used), VPC endpoints (optional), route tables, IGW.
3. **Cross-region egress**: Render output uploaded to B2 is inbound to B2 (free), but any inter-region traffic (e.g., logs, RCS) incurs AWS egress.
4. **Quota increases**: vCPU limits for GPU instance families must be requested per region.
5. **Operational overhead**: One more SEP config block, one more security group, one more AMI build step.

Recommended rollout order:

1. **Tier 1 overflow**: `ca-central-1` — same continent, similar pricing, often has GPU spot capacity when US regions are dry.
2. **Tier 2 overflow**: `eu-west-2` — higher latency but deep capacity; best for non-interactive batch jobs.
3. **Tier 3 overflow**: `ap-southeast-1` — only if Tier 1 and Tier 2 are also dry; latency may affect RCS responsiveness.

RCS connectivity is region-agnostic because all workers join the same ZeroTier network.

---

## Spot Fleet configuration

Each group config in SEP becomes one Spot Fleet Request. The current configuration for each region:

### `us-west-2` / `aws-spot`

| Attribute | Value |
|---|---|
| IAM Fleet Role | `arn:aws:iam::774538489810:role/aws-ec2-spot-fleet-tagging-role` |
| Allocation Strategy | `diversified` |
| Target Capacity | 1 |
| Spot Price | $0.80 |
| AMI | `ami-04f1f92230541947f` |
| Instance Type(s) | `g4dn.xlarge`, `g6.xlarge` |
| Security Group | `sg-07600453666354c8d` |
| Subnets | `subnet-0fd5d0b9dfd8e7ae6`, `subnet-58e53520`, `subnet-094816072a7fc11f6`, `subnet-0fa097440266d340f` |
| VPC | `vpc-23b1f65b` |

### `us-east-1` / `aws-spot-east`

| Attribute | Value |
|---|---|
| IAM Fleet Role | `arn:aws:iam::774538489810:role/aws-ec2-spot-fleet-tagging-role` |
| Allocation Strategy | `diversified` |
| Target Capacity | 1 |
| Spot Price | $0.80 |
| AMI | `ami-0546816e7e513ad03` |
| Instance Type(s) | `g4dn.xlarge`, `g6.xlarge` |
| Security Group | `sg-0de843cc211e3568d` |
| Subnets | `subnet-0091fb2ccfddf5421`, `subnet-0d992a58cdf9c893c`, `subnet-0e8f7a94a72cc9529`, `subnet-0cde3eaf7b8be6ee8` |
| VPC | `vpc-08898d1b9ae13ade8` |

### Allocation strategy rationale

`diversified` distributes capacity across the specified instance types and Availability Zones. This reduces the chance of a single instance-type outage blocking all renders. Because Houdini Karma is GPU-bound, the instance types are all NVIDIA GPU families in the same performance tier.

---

## Scaling behavior

SEP monitors the job queue for jobs assigned to each configured group.

1. **Queue depth > 0** for a group → SEP sets the corresponding SFR `TargetCapacity` to the configured value (currently 1).
2. **Queue depth == 0** → SEP sets `TargetCapacity` to 0.
3. SEP does not auto-scale beyond the configured target. If more workers are needed, either:
   - increase `TargetCapacity` in the SEP config, or
   - submit jobs that the existing workers can churn through faster than real-time.

### SFR lifecycle

- SEP creates a new SFR when it first needs capacity for a group.
- SEP updates the existing SFR's target capacity as queue state changes.
- SEP may leave old SFRs behind after restart or reconfiguration. These must be cancelled manually or by a cleanup script.
- A misconfigured SFR (e.g., wrong VPC) will remain in `pending_fulfillment` indefinitely and must be cancelled.

---

## Idle shutdown

SEP-managed spot instances are terminated when:

- The corresponding SFR `TargetCapacity` drops to 0 (no queued jobs in the group), or
- The instance is interrupted by AWS Spot.

The `IdleShutdown` SEP setting controls how long an idle worker waits before SEP scales it down. The current value is approximately 20 minutes.

Manually launched on-demand instances are **not** managed by SEP and must be terminated manually.

---

## On-demand fallback

SEP only launches spot instances. If spot capacity is unavailable in all configured regions, the farm has no workers. For development validation or critical renders, an operator may manually launch an on-demand instance:

1. Use the same AMI, security group, and subnet as the spot config.
2. Add the worker to the target Deadline group.
3. Terminate the instance manually after use to avoid runaway cost.

This is a temporary override, not a production allocation strategy.

---

## Input and output paths

### Input assets

Input scene files and other assets are stored in Backblaze B2 under the `inputs/` prefix:

```
b2://aoin-test/inputs/test-scenes/Tester.hiplc
b2://aoin-test/inputs/projects/<project>/<shot>/<file>
```

Workers download inputs at job start using rclone. On the worker AMI the rclone config is at `/etc/rclone/rclone.conf`, and the B2 bucket name must be included in the path:

```bash
rclone --config /etc/rclone/rclone.conf copyto \
  b2renders:aoin-test/inputs/test-scenes/Tester.hiplc \
  /tmp/Tester.hiplc
```

Use `copyto` (not `copy`) for single files to avoid creating a nested directory (`/tmp/Tester.hiplc/Tester.hiplc`).

### Output assets

Render frames are written to Backblaze B2 under the `outputs/` prefix, organized by job:

```
b2://aoin-test/outputs/<job-id>_<job-name>/Tester.karma1.0001.exr
```

The job ID prefix ensures unique namespaces across jobs. No per-instance folders are used because instances are ephemeral and the job ID already provides traceability.

Workers write outputs through the existing rclone FUSE mount:

```
/mnt/renders/outputs/<job-id>_<job-name>/
```

### Redirecting the Karma ROP output path

The test scene's Karma ROP writes to `/tmp/renderkarma/<scene>.<rop>.####.exr`. Because `/tmp` is local disk, the rendered frame would not reach B2 unless the path is redirected. The validated pattern is to replace `/tmp/renderkarma` with a symlink to the B2-backed output folder before rendering:

```bash
OUTDIR=/mnt/renders/outputs/<job-id>_<job-name>
mkdir -p "$OUTDIR"
rm -rf /tmp/renderkarma
ln -sfn "$OUTDIR" /tmp/renderkarma
```

Then render with hython:

```bash
/opt/hfs21.0/bin/hython -c '
import hou
hou.hipFile.load("/tmp/Tester.hiplc", suppress_save_prompt=True)
node = hou.node("/out/karma1")
node.render(frame_range=(1, 1))
'
```

The frame is written directly to `/mnt/renders/outputs/<job-id>_<job-name>/`, which is backed by B2.

---

## Worker registration

When a spot instance boots:

1. `zerotier-one.service` joins network `d3ecf5726d14ac76`.
2. `houdini-ubl.service` fetches the UBL endpoint DNS from Secrets Manager.
3. `rclone-b2-renders.service` mounts `/mnt/renders` from B2.
4. `deadline10launcher.service` starts the worker and connects to the on-prem Deadline repository over ZeroTier.

The worker appears in Deadline Monitor with a name derived from its private IP (e.g., `ip-10-129-6-214`).

---

## Failure modes and mitigations

| Failure | Symptom | Mitigation |
|---|---|---|
| VPC mismatch in SEP config | SFR stuck in `pending_fulfillment` | Ensure all subnets in a launch spec belong to the same VPC as the security group. |
| GPU drought in one region | SFR active, `FulfilledCapacity` = 0 | Add more regions or instance types to the SEP config. |
| Orphaned SFRs | Multiple old SFRs accumulating | Cancel stale SFRs; consider a cleanup script. |
| Stalled worker | Worker shows `Stalled` in Monitor | Delete the worker from Monitor; SEP or the next boot will recreate it. |
| Spot interruption | Job task fails mid-render | Submit jobs with chunking so only the interrupted task reruns. |
| Manual instance left running | On-demand instance idle after jobs complete | Terminate manually or set a CloudWatch alarm. |
| rclone config not found | Job fails with `Config file "/root/.config/rclone/rclone.conf" not found` | Use `--config /etc/rclone/rclone.conf` on the worker. |
| B2 bucket omitted | rclone error `directory not found` for `inputs/test-scenes/...` | Include the bucket name: `b2renders:aoin-test/inputs/...`. |
| Nested file upload/download | File ends up at `Tester.hiplc/Tester.hiplc` or `Tester.karma1.0001.exr/` | Use `rclone copyto` for single files. |
| Output written to local disk | EXR ends up in `/tmp/renderkarma/` instead of B2 | Create `/tmp/renderkarma` as a symlink to `/mnt/renders/outputs/<job-folder>/` before rendering. |
| Scene file corrupt after B2 download | Houdini error `Unexpected end of .hip file` | Re-upload the source file cleanly and verify hash; use `copyto`. |
| Monitor cannot resolve worker hostname | Deadline Monitor log connection fails with DNS error | Workers register by EC2 private hostname. Set `HostMachineIPAddressOverride` to the ZeroTier IP, or access logs via repository report files. |

---

## Configuration source of truth

The live SEP configuration is stored in the Deadline repository and is read/written via:

```python
from Deadline.Scripting import RepositoryUtils

config = RepositoryUtils.GetEventPluginConfig("Spot")
config_json = config.GetConfigEntry("Config")

# Update and persist
RepositoryUtils.AddOrUpdateEventPluginConfigSetting("Spot", "Config", new_config_json)
RepositoryUtils.AddOrUpdateServerData("event.plugin.spot", "Config", new_config_json)
```

Both the event plugin config and the server data entry must be updated together. Pulse must be restarted after changes.

---

## Open decisions

1. **Auto-cleanup of orphaned SFRs.** Should a cron job or event plugin cancel SFRs that are not referenced by the current SEP config?
2. **Target capacity scaling.** Should `TargetCapacity` be raised above 1 for groups that routinely see queue depth > 1?
3. **Instance type diversity.** Should cheaper/older GPU families (e.g., `g5.xlarge`) be added to reduce cost during non-drought periods?
4. **Regional RCS latency.** If expanding beyond US regions, is ZeroTier latency to the on-prem RCS acceptable, or should a regional RCS replica be considered?
5. **B2 render automation.** Should the `/tmp/renderkarma` symlink and rclone copy be moved into the AMI boot sequence or a Deadline event plugin so job submission does not need to carry boilerplate?
