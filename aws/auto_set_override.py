#!/usr/bin/env python3
"""
auto_set_override.py — Set HostMachineIPAddressOverride for spot workers.

Runs from WSL on the RCS host (ATXRTX). For each Deadline worker that:
  - Is NOT ATXRTX (local)
  - Has no HostMachineIPAddressOverride
  - Has an EC2 private IP in its name (ip-10-xxx-xxx-xxx pattern)

It finds the EC2 instance via the private IP, uses SSM to get the ZeroTier IP,
and sets the override via deadlinecommand.exe.

Usage:
  python3 auto_set_override.py [--region us-east-1] [--region us-west-2]
  python3 auto_set_override.py --dry-run

Requires: aws CLI, deadlinecommand.exe (on PATH via Windows)
"""
import subprocess, json, sys, re, argparse

DC = "/mnt/c/Program Files/Thinkbox/Deadline10/bin/deadlinecommand.exe"
ATXRTX = "ATXRTX"
ZT_NETWORK = "d3ecf5726d14ac76"

def run(cmd, timeout=15):
    """Run command, return stdout."""
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return r.stdout.strip()

def get_workers():
    """Get all Deadline workers."""
    out = run([DC, "GetSlaveNames"])
    return [w.strip() for w in out.split("\n") if w.strip()]

def get_worker_override(name):
    """Get HostMachineIPAddressOverride for a worker."""
    return run([DC, "GetSlaveSetting", name, "HostMachineIPAddressOverride"])

def get_worker_state(name):
    """Get slave state."""
    return run([DC, "GetSlaveInfo", name, "SlaveState"])

def find_instance_by_ip(ip, regions):
    """Find EC2 instance by private IP across regions."""
    # Extract the numeric parts from ip-10-129-5-158
    parts = ip.split("-")[-1] if "-" in ip else ip  # e.g. 10.129.5.158
    for region in regions:
        out = run([
            "aws", "ec2", "describe-instances",
            "--region", region,
            "--filters", f"Name=private-ip-address,Values={parts}",
                         "Name=instance-state-name,Values=running",
            "--query", "Reservations[].Instances[0].[InstanceId]",
            "--output", "text"
        ])
        if out and out.strip() and "None" not in out:
            instance_id = out.strip().split("\n")[0].strip()
            if instance_id.startswith("i-"):
                return instance_id, region
    return None, None

def get_zt_ip_ssm(instance_id, region):
    """Get ZeroTier IP via SSM."""
    cmdid = run([
        "aws", "ssm", "send-command",
        "--region", region,
        "--instance-ids", instance_id,
        "--document-name", "AWS-RunShellScript",
        "--parameters", 'commands=["/usr/sbin/zerotier-cli listnetworks 2>/dev/null | awk \'/OK/{print $9}\' | sed \'s|/.*||\'"]',
        "--timeout-seconds", "30",
        "--query", "Command.CommandId",
        "--output", "text"
    ])
    if not cmdid or len(cmdid) < 36:
        return None

    # Wait for SSM result
    import time
    time.sleep(6)
    out = run([
        "aws", "ssm", "get-command-invocation",
        "--region", region,
        "--command-id", cmdid.strip(),
        "--instance-id", instance_id,
        "--query", "StandardOutputContent",
        "--output", "text"
    ])
    zt_ip = out.strip().split("\n")[0].strip() if out else ""
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", zt_ip):
        return zt_ip
    return None

def set_override(name, zt_ip, dry_run=False):
    """Set HostMachineIPAddressOverride via deadlinecommand."""
    if dry_run:
        print(f"  [DRY-RUN] Would set {name} override → {zt_ip}")
        return True
    out = run([DC, "SetSlaveSetting", name, "HostMachineIPAddressOverride", zt_ip])
    return "Set HostMachineIPAddressOverride" in out

def main():
    parser = argparse.ArgumentParser(description="Auto-set HostMachineIPAddressOverride for spot workers")
    parser.add_argument("--region", action="append", default=["us-east-1", "us-west-2"],
                        help="AWS regions to search (can specify multiple)")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    workers = get_workers()
    fixed = 0
    skipped = 0

    for w in workers:
        if w == ATXRTX:
            continue

        override = get_worker_override(w)
        if override and re.match(r"^\d+\.\d+\.\d+\.\d+$", override):
            skipped += 1
            continue

        state = get_worker_state(w)
        print(f"\n  Worker: {w} (state={state}, override={override or 'EMPTY'})")

        # Extract private IP from worker name (ip-10-129-5-158)
        match = re.match(r"ip-(\d+-\d+-\d+-\d+)", w)
        if not match:
            print(f"    SKIP: not an EC2 spot worker (name doesn't match ip-x-x-x-x)")
            continue

        instance_id, region = find_instance_by_ip(w, args.region)
        if not instance_id:
            print(f"    SKIP: no running EC2 instance found for {w}")
            continue

        print(f"    Found: {instance_id} in {region}")

        zt_ip = get_zt_ip_ssm(instance_id, region)
        if not zt_ip:
            print(f"    SKIP: could not get ZT IP via SSM")
            continue

        print(f"    ZT IP: {zt_ip}")
        if set_override(w, zt_ip, args.dry_run):
            print(f"    ✓ Override set: {w} → {zt_ip}")
            fixed += 1
        else:
            print(f"    ✗ SetSlaveSetting failed")

    print(f"\n=== Done: {fixed} fixed, {skipped} already had override ===")
    return 0

if __name__ == "__main__":
    sys.exit(main())
