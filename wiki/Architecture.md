# Architecture

## Overview

```
┌─────────────────────────────────────────────────────────────┐
│  Studio LAN (Los Angeles HQ)                                │
│                                                             │
│  ┌─────────────────┐    ┌──────────────────────────────┐   │
│  │  Deadline Repo  │    │  Artist Workstations         │   │
│  │  Windows 10.4.2 │    │  Houdini 21.0 Submitter      │   │
│  └────────┬────────┘    └──────────────┬───────────────┘   │
│           │ ZeroTier overlay           │ ZeroTier overlay   │
└───────────┼────────────────────────────┼───────────────────┘
            │                            │
            │   d3ecf5726d14ac76         │
            │                            │
┌───────────┴────────────────────────────┴───────────────────┐
│  AWS us-west-2                                              │
│                                                             │
│  ┌─────────────────────────────────────────┐               │
│  │  EC2 Spot — g6e.4xlarge (up to 10x)     │               │
│  │  Ubuntu 22.04  NVIDIA L40S              │               │
│  │                                         │               │
│  │  zerotier-one  ──── ZT overlay ────────>│               │
│  │  houdini-ubl   ──── Secrets Manager    │               │
│  │  rclone-b2     ──── /mnt/renders ─────>│               │
│  │  deadline-worker ── Deadline Repo      │               │
│  └─────────────────────────────────────────┘               │
│                                                             │
│  Secrets Manager                                            │
│    houdini/ubl-token                                        │
│    backblaze/b2-key-id                                      │
│    backblaze/b2-app-key                                     │
└─────────────────────────────────────────────────────────────┘
            │
            ▼
┌───────────────────────────┐
│  Backblaze B2             │
│  Render output bucket     │
│  /mnt/renders/<proj>/     │
└───────────────────────────┘
```

---

## Component breakdown

### On-prem
| Component | Detail |
|---|---|
| Deadline repository | Windows Server, version 10.4.2.3, hosts job queue and asset paths |
| On-prem render nodes | 10× RTX A6000, 128 GB RAM, 16 cores — local render pool |
| ZeroTier client | All nodes joined to network `d3ecf5726d14ac76`; EC2 workers join the same network to reach the repo |

### EC2 workers
| Component | Detail |
|---|---|
| Base AMI | Ubuntu 22.04 LTS — `ami-0ababc7e5826abb79` (us-west-2, May 2026) |
| Instance type | `g6e.4xlarge` — closest AWS match to on-prem RTX A6000 nodes |
| GPU | NVIDIA L40S 48 GB VRAM, 18 176 CUDA cores (~17% faster than A6000 Ada) |
| NVIDIA driver | 535 series (data center; installed in AMI) |
| Spot pool | `houdini-aws-gpu` / group `linux-gpu` in Deadline |
| Region | us-west-2 primary; us-east-1 secondary |

### Storage
| Path | Backend |
|---|---|
| `/mnt/renders` | Backblaze B2 bucket (rclone FUSE mount, POSIX-transparent) |
| `/opt/hfs21.0` | Houdini install on AMI root volume |
| AMI root | 100 GB gp3 EBS (deleted on termination) |

---

## Service boot sequence on an EC2 worker

When a Spot instance is launched by Deadline AWS Portal, services start in this order:

```
1. network-online.target   (cloud networking ready)
2. zerotier-one.service    (ZT daemon starts, re-joins d3ecf5726d14ac76)
3. houdini-ubl.service     (fetches license endpoint DNS from Secrets Manager, sets HOUDINI_LICENSE_SERVER)
4. rclone-b2-renders.service (fetches B2 keys from Secrets Manager, mounts /mnt/renders)
5. deadline10launcher.service (Deadline worker starts, connects to repo over ZeroTier IP)
```

**MVP caveat:** ZeroTier node authorisation is manual for the first launch of each new AMI. Once the node is authorised in the ZeroTier dashboard, all subsequent boots of instances from the same AMI will reconnect automatically.

---

## Networking

Workers communicate with the on-prem Deadline repository over the ZeroTier overlay network (`d3ecf5726d14ac76`). No port-forwarding, public IPs, or VPN gateway configuration is required on the studio side.

Workers also need outbound internet access for:
- Secrets Manager (`secretsmanager.us-west-2.amazonaws.com`)
- SideFX UBL licensing (`sesinetd.sidefx.com`)
- Backblaze B2 (`*.backblazeb2.com`)
- ZeroTier coordination (`*.zerotier.com`)

Workers do **not** need any inbound ports open in production. During AMI build, SSH (port 22) is open from the admin IP only.

---

## Cost model (indicative)

| Item | Rate |
|---|---|
| `g6e.4xlarge` Spot (us-west-2a) | ~$1.31/hr |
| AWS egress to Backblaze B2 | ~$0.09/GB |
| Backblaze B2 storage | $0.006/GB/month |
| SideFX UBL | Per-core-hour (see SideFX pricing) |

10 workers rendering for 8 hours ≈ **$105** in Spot compute before storage and UBL.
