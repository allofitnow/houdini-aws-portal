# Portal-Ready AMI Spec

The current AMI (`deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1`) was built for
**manual CLI bursting** over ZeroTier. It must be rebuilt for the
**AWS Portal bursting workflow**, where workers connect to the on-prem RCS
through the Portal Gateway (ReverseForwarder) and Portal Link SSH tunnels.

---

## What changed

| Aspect | Old AMI (ZeroTier) | New AMI (Portal) |
|---|---|---|
| RCS connectivity | ZeroTier overlay — `ProxyRoot=10.147.18.89:4433` | Portal Gateway — `ProxyRoot` set by Portal user-data at launch |
| ZeroTier | Required (step 03) | Not needed — removed |
| rclone / Backblaze B2 | `/mnt/renders` via rclone FUSE | Portal Asset Server syncs output; B2 optional as fallback |
| License endpoint DNS | `houdini-ubl.service` fetches at boot | Same — unchanged |
| Boot order | `zerotier → houdini-ubl → rclone-b2 → deadline10launcher` | `houdini-ubl → deadline10launcher` |
| Portal user-data compatibility | No — user-data assumes Amazon Linux paths | Yes — must handle Ubuntu paths + Portal Gateway config |

---

## How Portal workers connect to RCS

```
EC2 Worker (Portal VPC)
  → Gateway / ReverseForwarder (same VPC, private IP)
    → SSH tunnel (Portal Link on MWMSIWIN10)
      → RCS at 192.168.30.141:4433
```

When a Spot Fleet launches through the Portal, it injects user-data that:

1. Sets `Region=<stack-name>` in `deadline.ini` (so Deadline knows this is a Portal worker)
2. Downloads Gateway TLS certs from the Portal S3 bucket
3. Sets `LaunchSlaveAtStartup=true`
4. Restarts `deadline10launcher`

The worker then uses the `Region` key to discover the Gateway and establish the RCS proxy chain. The AMI must NOT hardcode a `ProxyRoot` that points at a ZeroTier or LAN IP, because the Portal user-data overrides it at runtime.

---

## Portal user-data requirements (from actual Spot Fleet launch)

The following user-data was captured from a live Portal Spot Fleet instance.
The new AMI must be compatible with every step:

```yaml
#cloud-config
runcmd:
  # 1. License ports script (empty — Portal expects the file to exist)
  - sudo touch /etc/profile.d/license_ports.sh
  - sudo chmod 777 /etc/profile.d/license_ports.sh

  # 2. Environment variables script
  - sudo touch /etc/profile.d/env_vars.sh
  - sudo chmod 777 /etc/profile.d/env_vars.sh

  # 3. Set Region to the Portal stack name in deadline.ini
  - sed -im 's/Region=.*$/Region=stacka27189af3e224b4ba366cf5386ace5c0/g' /var/lib/Thinkbox/Deadline10/deadline.ini

  # 4. Enable auto-launch
  - sed -im 's/LaunchSlaveAtStartup=.*$/LaunchSlaveAtStartup=true/g' /var/lib/Thinkbox/Deadline10/deadline.ini

  # 5. Mark as Portal instance
  - echo AWSPortalInstance=True >> /var/lib/Thinkbox/Deadline10/deadline.ini

  # 6. Download Gateway certs from Portal S3 bucket
  - sudo mkdir /var/lib/Thinkbox/Deadline10/gateway_certs
  - sudo aws s3 cp s3://stacka27189af3e224b4ba366cf5386ace5c0-bucket/gateway_certs/ca.crt /var/lib/Thinkbox/Deadline10/gateway_certs --region us-west-2

  # 7. Restart Deadline launcher
  - sudo service deadline10launcher restart

  # 8. CloudWatch logging setup
  - sudo service awslogs stop
  - sudo python /opt/Thinkbox/CloudWatchSetup/bin/set_awslogs_region.py us-west-2
  - sudo python /opt/Thinkbox/CloudWatchSetup/bin/add_awslogs_stream_name_prefix.py stacka27189af3e224b4ba366cf5386ace5c0
  - sudo sh /opt/Thinkbox/CloudWatch/on_instance_init.sh stackname=stacka27189af3e224b4ba366cf5386ace5c0
  - sudo chkconfig --add awslogs
  - sudo chkconfig awslogs on
  - sudo service awslogs start

  # 9. Worker slave config writable
  - sudo chmod -R 777 /var/lib/Thinkbox/Deadline10/slaves

  # 10. AWS CLI config for ec2-user
  - mkdir -p /home/ec2-user/.aws
  - echo '[default]'> /home/ec2-user/.aws/config
  - echo 'region = us-west-2'>> /home/ec2-user/.aws/config
```

### Base OS investigation: Amazon Linux 2 vs AL2023 vs Ubuntu 22.04

#### Amazon Linux 2 -- BLOCKED

AL2 ships with glibc 2.26 and gcc 7.3. Houdini 21.0 is distributed as
`houdini-21.0.<build>-linux_x86_64_gcc11.2.tar.gz` and requires glibc >= 2.34.
This is a hard incompatibility -- glibc cannot be upgraded independently.

#### Amazon Linux 2023 -- POSSIBLE, same shim count as Ubuntu

AL2023.12 (current, June 2026) ships glibc >= 2.38 and gcc 11.x.
Houdini 21.0 would run. However, the Portal user-data still needs compatibility
shims because it was written for AL2, not AL2023:

| Portal user-data command | AL2023 Problem | Fix |
|---|---|---|
| `sudo service awslogs stop/start` | AL2023 uses `amazon-cloudwatch-agent`, not `awslogs` | Create no-op `awslogs` service unit |
| `sudo python /opt/Thinkbox/CloudWatchSetup/bin/...` | AL2023 has `python3`, not `python` (v2) | Symlink `python` -> `python3` |
| `sudo chkconfig --add awslogs` | `chkconfig` exists but `awslogs` doesn't | Same as above: no-op service |
| `/home/ec2-user/.aws/config` | Native on AL2023 | No fix needed |
| `sudo service deadline10launcher restart` | Works natively | No fix needed |
| `sed -im` | Works natively | No fix needed |

AL2023 shims: 3 (awslogs no-op, python symlink, chkconfig for awslogs)
Ubuntu shims: 3 (ec2-user creation, chkconfig install, awslogs no-op)

Both need the same number of shims. AL2023 is marginally closer but the shim
count is identical.

#### Ubuntu 22.04 -- Rejected in favor of AL2023

Ubuntu 22.04 has glibc 2.35 and gcc 11. Houdini 21.0 is proven to work.
Rejected because AL2023 is the AWS-recommended OS for Portal workloads
and requires the same number of shims (3).

---

## New AMI build script changes

### Base OS: Amazon Linux 2023 (AL2023)

AMI: `al2023-ami-2023.12.20260608.0-kernel-6.1-x86_64` (latest AL2023)

AL2023 specifics:
- Package manager: `dnf`
- Default user: `ec2-user` (already exists)
- glibc: >= 2.38 (Houdini 21.0 gcc11.2 compatible)
- Python: `python3` only, no `python` v2 (needs symlink)
- `chkconfig`: available
- `awslogs`: NOT available (AL2023 uses `amazon-cloudwatch-agent`)
- `service` wrapper: works via systemd

### Scripts to keep (with modifications)

| Script | Changes |
|---|---|
| `01_system_prep.sh` | Full rewrite for AL2023: `dnf install` instead of `apt install`. Symlink `python` -> `python3`. Create no-op `awslogs` service. No `ec2-user` creation needed. |
| `02_nvidia_drivers.sh` | Rewrite dependency packages: `kernel-devel` matched to running kernel, `gcc`, `make`, `elfutils-libelf-devel` instead of Ubuntu packages. |
| `04_houdini.sh` | Rewrite dependency install: `dnf install` for `libX*`, `mesa*`, `alsa*`, `ffmpeg` etc. Keep UBL service. Ensure `.sesi_licenses.pref` written for `ec2-user`. |
| `05_deadline_worker.sh` | **Major rewrite** — same logic as Ubuntu version but with AL2023 package deps. |
| `06_cleanup.sh` | Remove ZeroTier state cleanup. Add `ec2-user` home cleanup. Remove apt-specific cleanup. |

### Scripts to remove

| Script | Reason |
|---|---|
| `03_zerotier.sh` | ZeroTier not needed for Portal workflow. |
| `04b_rclone_b2.sh` | Portal Asset Server handles file sync. B2/rclone is a CLI fallback only. |

### `05_deadline_worker.sh` rewrite

The current script installs Deadline with `--proxyrootdir` pointing at the
ZeroTier IP. The new version must:

1. **Install Deadline Client in "Remote" mode without a specific proxy target.**
   The Portal user-data sets `Region=<stack-name>` and `AWSPortalInstance=True`
   at launch time, which tells Deadline to discover the Gateway automatically.
   Use `--proxyrootdir ""` or configure `deadline.ini` with a placeholder that
   the Portal user-data will override.

2. **Do NOT set `ProxyRoot` to any ZeroTier or LAN IP.** Leave it empty or
   set it to `localhost:4433` as a placeholder.

3. **Install but do NOT enable `deadline10launcher.service`.** The Portal
   user-data starts it after configuration.

4. **Ensure the Deadline install creates the CloudWatch scripts:**
   `/opt/Thinkbox/CloudWatchSetup/bin/` and `/opt/Thinkbox/CloudWatch/`.
   The Portal user-data calls these. If the installer doesn't create them,
   create no-op wrappers.

5. **Ensure `/home/ec2-user` has proper permissions.** The default AL2023
   `ec2-user` already exists. Portal user-data writes AWS config there.
   Ensure `.aws/config` path is writable.

6. **Ensure `/var/lib/Thinkbox/Deadline10/deadline.ini` exists** with at
   minimum:
   ```ini
   ConnectionType=Remote
   ProxyRoot=
   LaunchSlaveAtStartup=false
   ```

7. **Do NOT configure pool or group at AMI build time.** The Portal will
   assign the worker to the pool specified during Spot Fleet creation.

### New boot order

```
1. network-online.target   (cloud networking ready)
2. houdini-ubl.service     (fetches license endpoint DNS from Secrets Manager)
3. deadline10launcher.service (started by Portal user-data after config)
```

No ZeroTier, no rclone dependencies.

### `build.sh` changes

- Remove `--repo-ip` argument (no longer needed)
- Remove ZeroTier authorization wait
- Remove `--b2-bucket` argument (B2 not in Portal path)
- Skip `03_zerotier.sh` and `04b_rclone_b2.sh`

---

## Validation checklist

Before creating the AMI image, verify on the running build instance:

```bash
nvidia-smi                          # L40S / GPU appears
hython --version                    # Houdini 21.0.x
id ec2-user                         # ec2-user exists
cat /var/lib/Thinkbox/Deadline10/deadline.ini  # ConnectionType=Remote, ProxyRoot empty
ls /opt/Thinkbox/CloudWatchSetup/bin/           # CloudWatch scripts exist
which chkconfig                     # chkconfig available
systemctl is-enabled deadline10launcher  # should be disabled (Portal starts it)
```

After launching through Portal Spot Fleet:

```bash
# On the worker instance (via SSM or SSH)
cat /var/lib/Thinkbox/Deadline10/deadline.ini  # Region=<stack>, AWSPortalInstance=True
ls /var/lib/Thinkbox/Deadline10/gateway_certs/ # ca.crt downloaded
systemctl status deadline10launcher             # running
```

Worker appears in Deadline Monitor under Workers tab.

---

## Resolved: How the Deadline client discovers the Gateway

**Answer: CloudFormation DescribeStacks API call using the stack name from `Region=`.**

The discovery chain was confirmed by inspecting strings in the Deadline .NET binary (`deadline.dll`):

```
Region=<stack-name> in deadline.ini
  → DescribeStacksRequest (CloudFormation API, using worker's IAM instance profile)
    → get_OutputValue("ReverseForwarderIp")
      → m_reverseForwarderIp (Gateway private IP in Portal VPC)
        → Worker connects to Gateway on private IP
          → Gateway SSH tunnels to Portal Link → RCS
```

Key strings found in `deadline.dll`:
- `DescribeStacksRequest`, `DescribeStacksResponse`, `get_OutputValue`
- `m_reverseForwarderIp`, `get_ReverseForwarderIp`, `ReverseForwarderIp`
- `m_reverseForwarderInstanceId`, `DescribeInstancesRequest`, `get_PrivateIpAddress`
- `AWSSDK.CloudFormation`, `AmazonCloudFormationClient`

This means the AMI does NOT need to set `ProxyRoot` to any IP. The Deadline client dynamically resolves the Gateway IP using:
1. The `Region=` key in `deadline.ini` (set by Portal user-data to the CloudFormation stack name)
2. The `AWSPortalInstance=True` flag (tells the client to use Portal discovery mode)
3. The worker's IAM instance profile (`AWSPortalWorkerRole`) for AWS API authentication

The AMI only needs:
```ini
ConnectionType=Remote
ProxyRoot=
LaunchSlaveAtStartup=false
```

---

## Open questions

- **Does the Portal user-data set `ProxyRoot` to the Gateway private IP?**
  **RESOLVED:** No. The Portal user-data sets `Region=<stack-name>` and `AWSPortalInstance=True`. The Deadline client binary calls `DescribeStacks` with the stack name and reads the `ReverseForwarderIp` output value to get the Gateway IP dynamically. The AMI should leave `ProxyRoot` empty.

- **CloudWatch agent compatibility.** The Portal user-data uses Amazon Linux
  CloudWatch scripts. We need to either install the CloudWatch agent for Ubuntu
  or create stub scripts so the user-data doesn't fail.

- **Asset Server vs B2.** Portal Asset Server syncs render output to the
  on-prem Windows machine. Do we want to keep B2/rclone as a secondary output
  path, or fully remove it from the Portal AMI?

---

## Relationship to existing wiki pages

- Supersedes: `AMI-Build.md` (will need to be updated after new AMI is built)
- Updates: `Architecture.md` (remove ZeroTier from Portal path)
- Updates: `Standards-and-Conventions.md` (boot order, service dependencies)
- References: `deadline/aws_portal_notes.md` (Portal workflow, unchanged)
