# AWS Portal RCS and Deadline Cloud UBL Runbook
This page is the clean-install runbook for getting Thinkbox Deadline 10 AWS Portal workers rendering Houdini 21/Karma through AWS Deadline Cloud usage-based licensing in `us-west-2`. It is organized in the order to follow when starting from a fresh Deadline install, with the troubleshooting notes we discovered during recovery folded into the relevant steps.

## Known-good validated state
These values are from the working recovery and repeated validation runs. Re-discover stack IDs and network resources after any AWS Portal infrastructure rebuild.

- AWS region: `us-west-2`
- Deadline RCS hostname: `ATXRTX:4433`
- RCS ZeroTier IP used by workers: `10.147.18.89`
- Portal stack: `stack38e316bac3ee4445b2d227d0fb178ff4`
- Portal VPC / `ReverseDashVPC`: `vpc-08477ae9dd456d2e0`
- Portal public subnet / `PublicSubnet`: `subnet-019a4948de8c68510`
- Portal worker security group / `ReverseSlaveSG`: `sg-09335256539b1c0f0`
- Portal gateway instance: `i-087c53183e3d058e2`
- Portal worker instance: `i-0d5382a1d760bdfb9`
- Deadline worker name: `ip-10-128-51-50`
- Deadline Cloud license endpoint: `le-f041d594eefc4506ad52c3d730c39417`
- License endpoint DNS: `vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com`
- Final repeated validation job: `6a193c914e4ae5bbdf353bcb`
- Final output pattern: `/home/ubuntu/renderkarma/Tester.karma1.000#.exr`

## Fresh install overview
A working build has these layers:

1. Deadline Repository, Client, Monitor, and RCS installed and working locally.
2. RCS SSL certificates copied out of the repository certificate folder into a user-accessible folder.
3. AWS Portal components installed on the Monitor workstation.
4. AWS Portal panel opened from Deadline Monitor and used to create infrastructure.
5. Workers configured to reach RCS by hostname `ATXRTX:4433` over ZeroTier with the correct client cert and CA cert.
6. Deadline Cloud license endpoint created with the Deadline Cloud API in the current Portal VPC/subnet/security group.
7. SideFX Houdini licensing configured to use the endpoint DNS on ports `1715`, `1716`, and `1717`.
8. Worker runtime libraries and IAM permissions installed.
9. Validation jobs submitted suspended, allowlisted to the AWS Portal worker, then resumed.

## 1. Install and verify Deadline/RCS
Start with a normal Deadline 10 install:

- Install the Deadline Repository/Database on the repository host.
- Install Deadline Client and Monitor on the workstation used to manage jobs.
- Enable/configure Remote Connection Server with SSL on port `4433`.
- Use the hostname `ATXRTX` for RCS, not an arbitrary IP-only configuration.

The worker-side `deadline.ini` must point at the RCS hostname and the copied cert files:

```ini
ConnectionType=Remote
ProxyRoot=ATXRTX:4433
ProxyUseSSL=True
ProxySSLCertificate=/var/lib/Thinkbox/Deadline10/certs/Deadline10Client.pfx
ProxySSLCA=/var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem
ClientSSLAuthentication=Required
```

On Linux workers, map `ATXRTX` to the RCS ZeroTier IP:

```text
10.147.18.89 ATXRTX
```

Validate from a worker:

```bash
getent hosts ATXRTX
bash -lc ': >/dev/tcp/ATXRTX/4433'
```

Failure signature if this is wrong:

```text
POST https://atxrtx:4433/rcs/v1/update returned "No route to host (atxrtx:4433)"
```

## 2. Copy certificates out of `C:\DeadlineDatabase10\certs`
Do not point AWS Portal, WSL scripts, or worker launch tooling directly at `C:\DeadlineDatabase10\certs`. That path caused access/copy failures. It is repository-owned and not reliably readable by the user/session that launches AWS Portal or scripts.

Copy the required certs into a hidden user folder or the user's AppData area first. The validated layout was:

```text
C:\Users\aoin\.deadline\certs\Deadline10Client.pfx
C:\Users\aoin\.deadline\certs\DeadlineRCSServer.pem
C:\Users\aoin\.deadline\certs\DeadlineRCSServer.pfx
C:\Users\aoin\.deadline\ubl-certs\
```

Equivalent AppData locations are also acceptable, as long as the user running Deadline Monitor and AWS Portal can read them reliably. Keep the AWS Portal UBL sync directory separate from the regular RCS cert directory.

Recommended Windows setup:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.deadline\certs"
New-Item -ItemType Directory -Force "$env:USERPROFILE\.deadline\ubl-certs"
Copy-Item "C:\DeadlineDatabase10\certs\Deadline10Client.pfx" "$env:USERPROFILE\.deadline\certs\"
Copy-Item "C:\DeadlineDatabase10\certs\DeadlineRCSServer.pem" "$env:USERPROFILE\.deadline\certs\"
Copy-Item "C:\DeadlineDatabase10\certs\DeadlineRCSServer.pfx" "$env:USERPROFILE\.deadline\certs\"
```

Validated settings:

- Regular RCS cert source for launch scripts: `/mnt/c/Users/aoin/.deadline/certs/`
- AWS Portal sync cert directory: `C:/Users/aoin/.deadline/ubl-certs`
- Keep `C:/Users/aoin/.deadline/ubl-certs` empty unless AWS Portal specifically writes/syncs into it.

## 3. Install AWS Portal if it is missing
If the AWS Portal panel/menu is not present in Deadline Monitor, install the AWS Portal components separately before trying to create infrastructure.

Practical install path:

1. Re-run the Deadline Client installer on the Monitor workstation, or run it in Modify/Repair mode.
2. Select/install the AWS Portal components for Deadline Monitor.
3. Restart Deadline Monitor after the installer finishes.
4. Confirm AWS Portal appears under the Monitor panel menu described below.

The only UI path we found to access AWS Portal is:

1. Open Deadline Monitor.
2. Go to `Tools` and enable `Power User Mode`.
3. Go to `View` → `New Panels`.
4. Open `AWS Portal` from the submenu.

Do not look for AWS Portal as a standalone application. In this setup it is accessed through Deadline Monitor after Power User Mode is enabled.

## 4. Create AWS Portal infrastructure cleanly
Use AWS Portal from Deadline Monitor to create infrastructure in `us-west-2`. Avoid reusing stale or partially deleted Portal resources.

Important lessons from recovery:

- Do not reuse stale VPCs, stale VPC endpoints, stale S3 buckets, or stale AWS Portal infrastructure entries.
- AWS Portal can show old `DELETE_COMPLETE` infrastructure entries; the active `CREATE_COMPLETE` CloudFormation stack is what matters.
- After rebuilding Portal infrastructure, rediscover the current stack resources and update any local `.env` values and scripts that reference subnets or worker security groups.
- The AWS Asset Server became healthy only after current infrastructure and Portal Link settings were corrected.

Current resources from the validated stack:

- `ReverseDashVPC` → `vpc-08477ae9dd456d2e0`
- `PublicSubnet` → `subnet-019a4948de8c68510`
- `ReverseSlaveSG` → `sg-09335256539b1c0f0`

## 5. Create the Deadline Cloud license endpoint correctly
Do not create the UBL endpoint with `aws ec2 create-vpc-endpoint`. That created endpoints stuck in `pendingAcceptance` and did not produce a usable Deadline Cloud license endpoint.

Wrong symptom:

```text
vpce-* State=pendingAcceptance
ServiceName=com.amazonaws.vpce.us-west-2.vpce-svc-0c4b155bc5b761304
```

Use the Deadline Cloud API instead:

```bash
aws deadline create-license-endpoint \
  --region us-west-2 \
  --vpc-id vpc-08477ae9dd456d2e0 \
  --subnet-ids subnet-019a4948de8c68510 \
  --security-group-ids sg-09335256539b1c0f0
```

Inspect it with:

```bash
aws deadline get-license-endpoint \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417
```

## 6. Attach required SideFX metered products
Attach all SideFX products used by the Houdini/Karma render path:

```bash
aws deadline put-metered-product \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417 \
  --product-id houdini-21.0

aws deadline put-metered-product \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417 \
  --product-id karma-21.0

aws deadline put-metered-product \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417 \
  --product-id mantra-21.0

aws deadline list-metered-products \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417
```

Expected product ports:

- `houdini-21.0` → `1715`
- `karma-21.0` → `1716`
- `mantra-21.0` → `1717`

## 7. Open license endpoint security group ports
The Deadline Cloud license endpoint and workers used `ReverseSlaveSG`. The security group initially only allowed SSH from the Portal CIDR, so UBL license ports were blocked.

Required inbound rule on `ReverseSlaveSG`:

- TCP `1715-1717`
- Source: same security group (`ReverseSlaveSG`)

```bash
aws ec2 authorize-security-group-ingress \
  --region us-west-2 \
  --group-id sg-09335256539b1c0f0 \
  --protocol tcp \
  --port 1715-1717 \
  --source-group sg-09335256539b1c0f0
```

Worker-side validation:

```bash
bash -lc ': >/dev/tcp/vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com/1715'
bash -lc ': >/dev/tcp/vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com/1716'
bash -lc ': >/dev/tcp/vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com/1717'
```

## 8. Store license endpoint DNS in Secrets Manager
Workers fetch the endpoint DNS from Secrets Manager.

Secret ID:

```text
houdini/license-endpoint-dns
```

Value should be the endpoint DNS without a port:

```bash
aws secretsmanager put-secret-value \
  --region us-west-2 \
  --secret-id houdini/license-endpoint-dns \
  --secret-string vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com
```

## 9. Configure worker IAM permissions
The EC2 worker role must allow the worker to read the license endpoint DNS secret and perform the EC2 tag operations Deadline expects.

Validated role:

```text
deadline-worker-role
```

Required inline policy behavior:

- Read `houdini/license-endpoint-dns` from Secrets Manager.
- Allow `ec2:DescribeTags` and `ec2:DescribeInstances`.
- Allow `ec2:CreateTags` on EC2 instances in `us-west-2`.

Failure signature when `ec2:CreateTags` was missing:

```text
UnauthorizedOperation: not authorized to perform: ec2:CreateTags
AWSPortalAccessDeniedException -- Got Access Denied when trying to CreateTags in EC2 Instance
```

The existing inline policy `deadline-ubl-ec2-tags` was updated to include:

```json
{
  "Effect": "Allow",
  "Action": "ec2:CreateTags",
  "Resource": "arn:aws:ec2:us-west-2:774538489810:instance/*"
}
```

## 10. Install worker runtime dependencies
Houdini licensing tools failed before they could contact UBL because `hkey-bin` was missing headless Qt/XCB libraries.

Failure signatures:

```text
/opt/hfs21.0/bin/hkey-bin: error while loading shared libraries: libxkbcommon.so.0
Qt xcb platform plugin could not be loaded
```

Install these packages in the AMI prep step:

```bash
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libxkbcommon0 \
  libxkbcommon-x11-0 \
  libxcb-cursor0 \
  libxcb-icccm4 \
  libxcb-image0 \
  libxcb-keysyms1 \
  libxcb-render-util0 \
  libxcb-shape0 \
  libxcb-randr0 \
  libxcb-xfixes0 \
  libxcb-xinerama0 \
  libxss1
```

Validate:

```bash
ldd /opt/hfs21.0/bin/hkey-bin | grep 'not found' || echo NO_MISSING_HKEY_LIBS
```

## 11. Configure SideFX hserver with the chained UBL endpoint
Setting only `HOUDINI_LICENSE_SERVER=<endpoint-dns>` was not sufficient. SideFX hserver needed a semicolon-separated chain with each product-specific port.

Known-good chain:

```bash
LICENSE_DNS=vpce-0508f24c517312706-44r8vcfr.vpce-svc-0c4b155bc5b761304.us-west-2.vpce.amazonaws.com
LICENSE_CHAIN="${LICENSE_DNS}:1715;${LICENSE_DNS}:1716;${LICENSE_DNS}:1717"
```

Environment:

```bash
export HOUDINI_LICENSE_SERVER="${LICENSE_CHAIN}"
export SESI_LMHOST="${LICENSE_CHAIN}"
export QT_QPA_PLATFORM=offscreen
```

Persist hserver prefs for system hserver, root, and ubuntu:

```bash
sudo install -d -m 755 /usr/lib/sesi/hserver /home/ubuntu
printf 'serverhost=%s\n' "$LICENSE_CHAIN" | sudo tee /usr/lib/sesi/hserver/.sesi_licenses.pref >/dev/null
printf 'serverhost=%s\n' "$LICENSE_CHAIN" | sudo tee /root/.sesi_licenses.pref >/dev/null
printf 'serverhost=%s\n' "$LICENSE_CHAIN" | sudo tee /home/ubuntu/.sesi_licenses.pref >/dev/null
sudo chown ubuntu:ubuntu /home/ubuntu/.sesi_licenses.pref
sudo chmod 644 /usr/lib/sesi/hserver/.sesi_licenses.pref /root/.sesi_licenses.pref /home/ubuntu/.sesi_licenses.pref
sudo pkill -f hserver || true
```

Useful log:

```bash
sudo tail -n 160 /tmp/houdini_temp/hserver.log
```

Successful license acquisition looked like:

```text
Acquired License ... Houdini Engine 20.0
Acquired License ... Karma Renderer 20.0
```

The log text said `20.0`, but the install was Houdini 21.0 and the render succeeded.

## 12. Ensure Deadline worker process is running
`deadline10launcher.service` can be active while the worker process itself is missing. In that state, allowlisted jobs remain queued.

Check:

```bash
systemctl is-active deadline10launcher deadline10worker 2>/dev/null || true
ps -ef | grep -i '[d]eadline' || true
/opt/Thinkbox/Deadline10/bin/deadlinecommand -GetSlave ip-10-128-51-50
```

If `deadlineworker` is missing:

```bash
nohup /opt/Thinkbox/Deadline10/bin/deadlineworker -nogui >/tmp/deadlineworker-start.log 2>&1 &
```

## 13. Submit validation jobs safely
Always target a real Houdini output driver. Empty `OutputDriver` caused Deadline to pass malformed arguments:

```text
-d  -gpu 0
Driver '-gpu' does not exist
```

Validated ROPs in `/home/ubuntu/Tester.hiplc`:

```text
ROP /out/karma1 karma
ROP /out/mantra1 ifd
ROP /out/usdrender1 usdrender
```

Validated plugin info:

```ini
SceneFile=/home/ubuntu/Tester.hiplc
OutputDriver=/out/karma1
Version=21.0
Build=64bit
IgnoreInputs=False
UseOpenCL=False
GPUsPerTask=1
```

For multi-frame tests, use:

```ini
Frames=1-3
ChunkSize=1
```

Submit suspended, allowlist the AWS worker, then resume. This prevents `ATXRTX` or any stale/non-Portal worker from taking the AWS Portal UBL validation job.

```bash
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetJobMachineLimitListedSlaves "$JOB_ID" ip-10-128-51-50
/opt/Thinkbox/Deadline10/bin/deadlinecommand -SetJobMachineLimitWhiteListFlag "$JOB_ID" True
/opt/Thinkbox/Deadline10/bin/deadlinecommand -ResumeJob "$JOB_ID"
```

Expected fields:

```text
ListedSlaves=ip-10-128-51-50
WhitelistFlag=True
```

## 14. Validation sequence
Run validation in this order:

1. Confirm RCS resolution and TCP reachability:

```bash
getent hosts ATXRTX
bash -lc ': >/dev/tcp/ATXRTX/4433'
```

2. Confirm UBL endpoint ports:

```bash
bash -lc ': >/dev/tcp/${LICENSE_DNS}/1715'
bash -lc ': >/dev/tcp/${LICENSE_DNS}/1716'
bash -lc ': >/dev/tcp/${LICENSE_DNS}/1717'
```

3. Confirm `hkey-bin` dependencies:

```bash
ldd /opt/hfs21.0/bin/hkey-bin | grep 'not found' || echo NO_MISSING_HKEY_LIBS
```

4. Direct Houdini import:

```bash
cd /opt/hfs21.0
source ./houdini_setup
QT_QPA_PLATFORM=offscreen hython -c 'import hou; print("HOUDINI_IMPORT_OK")'
```

5. Direct Karma render:

```python
import hou
hou.hipFile.load('/home/ubuntu/Tester.hiplc', suppress_save_prompt=True)
node = hou.node('/out/karma1')
node.render(frame_range=(1, 1, 1), verbose=True)
print('KARMA_RENDER_OK')
```

6. Deadline-managed single-frame render to `/out/karma1`.
7. Deadline-managed 3-frame render with `Frames=1-3` and `ChunkSize=1`.
8. Requeue and rerun the completed 3-frame job end-to-end.

## 15. Repeated validation results
Successful validation jobs included:

- `6a1915be4e4ae5bbdf353baf`: original Deadline-managed Karma job, completed with `ErrorReports=0`.
- `6a19256d4e4ae5bbdf353bba`: 3-frame AWS-worker-only test, completed with `ErrorReports=0`.
- `6a1938f84e4ae5bbdf353bc4`: clean suspended/allowlisted/resumed run, completed 3/3 frames with `ErrorReports=0`.
- `6a193ad14e4ae5bbdf353bc8`: single-operation clean run, completed 3/3 frames with `ErrorReports=0`.
- `6a193c914e4ae5bbdf353bcb`: RCS route retest, completed 3/3 frames with `ErrorReports=0`, then successfully requeued and rerun in its entirety.

Final output files:

- `/home/ubuntu/renderkarma/Tester.karma1.0001.exr`
- `/home/ubuntu/renderkarma/Tester.karma1.0002.exr`
- `/home/ubuntu/renderkarma/Tester.karma1.0003.exr`

## 16. Troubleshooting reference
### AWS Portal panel missing
Install AWS Portal components on the Monitor workstation, restart Deadline Monitor, enable `Tools` → `Power User Mode`, then open `View` → `New Panels` → `AWS Portal`.

### Cert path failures
Do not reference `C:\DeadlineDatabase10\certs` directly from AWS Portal or scripts. Copy certs to a user-accessible hidden folder or AppData path first, then reference that copy.

### Worker cannot reach RCS
Symptoms:

```text
No route to host (atxrtx:4433)
WORKER LOST CONNECTION TO THE REPOSITORY, SKIPPING TASK DEQUEUING
```

Checks:

```bash
getent hosts ATXRTX
ip route get 10.147.18.89
sudo zerotier-cli info
sudo zerotier-cli listnetworks
timeout 5 bash -lc ': >/dev/tcp/ATXRTX/4433' && echo RCS_TCP_OK || echo RCS_TCP_FAIL
```

If failures persist, restart `zerotier-one`, then `deadline10launcher.service`, then ensure `deadlineworker` is running.

### Connection reset by peer during worker info update
This can appear after successful renders:

```text
POST https://atxrtx:4433/db/slaves/info/save returned "Connection reset by peer"
```

A later 20-probe TCP sample showed `20/20` successful connections to `ATXRTX:4433`, and the job remained `Completed` with `ErrorReports=0`. Treat isolated heartbeat resets as noise unless they cause repeated worker offline/stalled states or task dequeuing failures.

### Houdini license not found
Check:

- The Deadline Cloud license endpoint was created with `aws deadline create-license-endpoint`, not EC2 `create-vpc-endpoint`.
- Products `houdini-21.0`, `karma-21.0`, and `mantra-21.0` are attached.
- Security group allows TCP `1715-1717` from itself.
- `houdini/license-endpoint-dns` contains the endpoint DNS.
- hserver prefs contain the chained list with ports `1715;1716;1717`.

### Missing Qt/XCB libraries
Run:

```bash
ldd /opt/hfs21.0/bin/hkey-bin | grep 'not found'
```

Install the runtime dependency list from section 10 if anything is missing.

### Empty OutputDriver
Use `/out/karma1`. Empty output driver produced:

```text
Driver '-gpu' does not exist
```

### Harmless warnings in successful runs
These appeared in successful renders and were not blockers:

```text
opalias: 'kinefx::motionclipupdate' is not a known operator.
opalias: 'kinefx::rop_fbxanimoutput' is not a known operator.
WARNING: Entered limited commercial session mode.
/opt/hfs21.0/houdini_setup: line 15: ./houdini_setup_bash: No such file or directory
```

The `houdini_setup` warning came from shell environments that source the setup script from the wrong working directory. Deadline launches `/opt/hfs21.0/bin/hython` directly and the warning did not prevent Karma rendering.

## 17. Repo changes that preserve the fixes
The validated AMI/worker fixes were persisted into:

- `ami/scripts/01_system_prep.sh`
  - Adds the headless Houdini/Qt/XCB runtime libraries.
  - Quotes `linux-headers-$(uname -r)` for ShellCheck.

- `ami/scripts/04_houdini.sh`
  - Fetches `houdini/license-endpoint-dns`.
  - Builds `${LICENSE_DNS}:1715;${LICENSE_DNS}:1716;${LICENSE_DNS}:1717`.
  - Exports `HOUDINI_LICENSE_SERVER`, `SESI_LMHOST`, and `QT_QPA_PLATFORM=offscreen`.
  - Writes hserver `.sesi_licenses.pref` files for system hserver, root, and ubuntu.
  - Kills stale `hserver` after applying the chain.
  - Documents `houdini-21.0`, `karma-21.0`, and `mantra-21.0` metered products.

Validation run after script edits:

```bash
bash -n ami/scripts/01_system_prep.sh
bash -n ami/scripts/04_houdini.sh
shellcheck ami/scripts/01_system_prep.sh ami/scripts/04_houdini.sh
git --no-pager diff --check -- ami/scripts/01_system_prep.sh ami/scripts/04_houdini.sh
```

All validation checks passed.

## 18. Dry-run preflight checklist
Use this non-destructive checklist before creating new infrastructure, launching replacement workers, or declaring a fresh install ready. It follows the same dependency order as the runbook.

### Local workstation and certificate access
Confirm the copied certs exist in the user-accessible folder, not only in `C:\DeadlineDatabase10\certs`:

```bash
ls -l /mnt/c/Users/aoin/.deadline/certs/Deadline10Client.pfx
ls -l /mnt/c/Users/aoin/.deadline/certs/DeadlineRCSServer.pem
ls -l /mnt/c/Users/aoin/.deadline/certs/DeadlineRCSServer.pfx
ls -ld /mnt/c/Users/aoin/.deadline/ubl-certs
```

Expected result from the dry run:

```text
Deadline10Client.pfx present
DeadlineRCSServer.pem present
DeadlineRCSServer.pfx present
AWS Portal UBL cert sync directory present
```

### AWS Portal stack and UBL resources
Check the active Portal stack and key resources:

```bash
aws cloudformation describe-stacks \
  --region us-west-2 \
  --stack-name stack38e316bac3ee4445b2d227d0fb178ff4

aws cloudformation describe-stack-resources \
  --region us-west-2 \
  --stack-name stack38e316bac3ee4445b2d227d0fb178ff4
```

Expected resources:

```text
StackStatus=CREATE_COMPLETE
ReverseDashVPC=vpc-08477ae9dd456d2e0
PublicSubnet=subnet-019a4948de8c68510
ReverseSlaveSG=sg-09335256539b1c0f0
```

Check the Deadline Cloud license endpoint and products:

```bash
aws deadline get-license-endpoint \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417

aws deadline list-metered-products \
  --region us-west-2 \
  --license-endpoint-id le-f041d594eefc4506ad52c3d730c39417
```

Expected result:

```text
license endpoint status=READY
houdini-21.0 on port 1715
karma-21.0 on port 1716
mantra-21.0 on port 1717
```

The security group rule may appear as two permissions rather than one contiguous rule, but it must cover self-referenced TCP `1715`, `1716`, and `1717` from `sg-09335256539b1c0f0`.

### Secret and IAM access
Check the license DNS secret exists and matches the endpoint DNS:

```bash
aws secretsmanager describe-secret \
  --region us-west-2 \
  --secret-id houdini/license-endpoint-dns
```

Check the worker role policies:

```bash
aws iam get-role-policy \
  --role-name deadline-worker-role \
  --policy-name SecretsManagerRead

aws iam get-role-policy \
  --role-name deadline-worker-role \
  --policy-name deadline-ubl-ec2-tags
```

Expected policy access:

```text
secretsmanager:GetSecretValue for arn:aws:secretsmanager:us-west-2:774538489810:secret:houdini/*
ec2:DescribeTags
ec2:DescribeInstances
ec2:CreateTags on arn:aws:ec2:us-west-2:774538489810:instance/*
```

### Worker RCS, Deadline, Houdini, and hserver checks
Run these on the EC2 worker through SSM or an interactive shell:

```bash
getent hosts ATXRTX
ip route get 10.147.18.89
sudo zerotier-cli info
sudo zerotier-cli listnetworks
timeout 5 bash -lc ': >/dev/tcp/ATXRTX/4433' && echo RCS_TCP_OK || echo RCS_TCP_FAIL

grep -E '^(ConnectionType|ProxyRoot|ProxyUseSSL|ProxySSLCertificate|ProxySSLCA|ClientSSLAuthentication)=' /var/lib/Thinkbox/Deadline10/deadline.ini
stat /var/lib/Thinkbox/Deadline10/certs/Deadline10Client.pfx
stat /var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem

systemctl is-active deadline10launcher deadline10worker 2>/dev/null || true
ps -ef | grep -i '[d]eadline' || true
/opt/Thinkbox/Deadline10/bin/deadlinecommand -GetSlave ip-10-128-51-50

ldd /opt/hfs21.0/bin/hkey-bin | grep 'not found' || echo NO_MISSING_HKEY_LIBS
cat /usr/lib/sesi/hserver/.sesi_licenses.pref
cat /root/.sesi_licenses.pref
cat /home/ubuntu/.sesi_licenses.pref
```

Expected worker state from the dry run:

```text
ATXRTX resolves to 10.147.18.89
ZeroTier ONLINE and network OK
RCS_TCP_OK
ProxyRoot=ATXRTX:4433
Deadline client cert and RCS CA cert present
NO_MISSING_HKEY_LIBS
hserver prefs present for system hserver, root, and ubuntu
latest validation job Completed with ErrorReports=0 and FailedChunks=0
```

Important nuance: `deadline10worker` may report `inactive` even when `deadlineworker.exe -nogui` is running under `deadlinelauncher.exe`. In this setup, the process list and `deadlinecommand -GetSlave ip-10-128-51-50` are the source of truth. If no `deadlineworker.exe` process exists and allowlisted jobs remain queued, start it manually or restart the launcher.
