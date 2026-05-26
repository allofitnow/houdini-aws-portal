# Configuring Deadline AWS Portal

## Status — AWS Portal Plugin (Deadline 10.4.2.3)

The legacy Thinkbox AWS Portal plugin is **not bundled** with Deadline 10.4.2.3
(maintenance mode since 2025-11-07). Plugin installation is tracked in GitLab
issue #35 (deferred). Until the plugin is available, use the CLI workaround
scripts described below.

## CLI Workaround: Manual Spot Worker Management

Use these scripts (in `aws/`) to launch and terminate workers manually while
awaiting the AWS Portal plugin.

### Launch workers

```bash
source .env

# Launch one worker (default)
./aws/launch_spot_worker.sh

# Launch three workers
./aws/launch_spot_worker.sh 3
```

After launch, authorize each new ZeroTier node at:
https://my.zerotier.com/network/d3ecf5726d14ac76

Workers appear in Deadline Monitor (pool `houdini-aws-gpu`) within ~3-5 minutes
of ZeroTier authorization.

### Manage running workers

```bash
# List all running workers
./aws/terminate_spot_worker.sh --list

# Terminate a specific instance
./aws/terminate_spot_worker.sh i-0abc123def456

# Terminate all project workers
./aws/terminate_spot_worker.sh --all
```

Workers **are not** auto-terminated without the Portal plugin. Monitor idle
instances and terminate them to control cost.

---

## Prerequisites (for Portal plugin path)
- AMI has been built and `create_ami.sh` completed successfully
- Quota increase for G/VT Spot in us-west-2 is approved (160 vCPUs)
- Deadline Monitor 10.4.2.3 open on Windows workstation

## AWS IAM: Deadline Portal User
Create an IAM user (or role) with the following managed policies for the Deadline
AWS Portal plugin. In Deadline Monitor under Tools → Credentials, supply the
Access Key ID and Secret.

Required policies:
- `AmazonEC2FullAccess` (scoped down in production)
- `AmazonVPCReadOnlyAccess`
- `IAMReadOnlyAccess` (for instance profile lookup)

## Configuring the Portal in Deadline Monitor

1. Open **Tools → Configure AWS Portal**
2. **Region:** `us-west-2`
3. **AMI ID:** `ami-0f70342f66dc80ddb`
4. **Instance Type:** `g6e.4xlarge`
5. **Spot:** Enabled
6. **Spot Max Price:** Set to on-demand price (~$2.00/hr) as cap
7. **Max Workers:** `10`
8. **IAM Instance Profile:** `deadline-worker-profile`
9. **Subnet:** *(select a public subnet in us-west-2)*
10. **Security Group:** `sg-0f7755ef50058d7a1`
11. **Pool:** `houdini-aws-gpu`
12. **Key Pair:** `deadline-ami-build` *(for emergency SSH access; remove in production)*

## Render Output Path Mapping

Houdini ROPs on the artist workstation will likely reference a Windows or
on-prem NAS path. Configure Deadline path mapping so the worker's Linux path
`/mnt/renders/<project>/<shot>/` corresponds to the correct UNC/Windows path.

In Deadline Monitor: **Tools → Configure Repository → Path Mapping**

| Windows / macOS path (artist) | Linux path (EC2 worker)         |
|-------------------------------|----------------------------------|
| `//nas/renders/<project>/`    | `/mnt/renders/<project>/`        |
| `Z:\renders\<project>\`       | `/mnt/renders/<project>/`        |

The B2 bucket is mounted at `/mnt/renders` on every worker. Output EXR sequences
land directly in B2, accessible from the studio via the Backblaze B2 web UI,
rclone, or the B2 CLI.

## First Worker Test

1. Submit a small Houdini Karma XPU job from Houdini Monitor set to pool `houdini-aws-gpu`
2. Deadline AWS Portal will launch a single `g6e.4xlarge` Spot instance
3. Monitor the ZeroTier dashboard — authorize the new node when it appears
4. Worker should come online in Deadline Monitor within ~3-5 minutes of authorization
5. Job should complete and EXRs appear in the B2 bucket under `/mnt/renders/`

## Termination

Spot instances launched by AWS Portal are terminated when Deadline's Auto Scale
policy determines they are idle. Confirm Auto Scale is enabled with an idle
timeout of 15–30 minutes to control cost.
