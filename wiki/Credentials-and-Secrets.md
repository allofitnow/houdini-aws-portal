# Credentials and Secrets

## Guiding principle

**No credentials are ever stored in the AMI image, in the Git repository, or in any script.**

Credentials are either:
1. Stored in **AWS Secrets Manager** and fetched at boot by systemd services, or
2. Stored in the **local `.env` file** (gitignored) for use in developer shell sessions.

---

## AWS Secrets Manager — all secrets

All secrets stored in `us-west-2`. The worker instance profile (`deadline-worker-profile`)
and the `deadline-portal` IAM user both have `GetSecretValue` access to all three namespaces.

| Secret name | Content | Used by | Status |
|---|---|---|---|
| `houdini/license-endpoint-dns` | Deadline Cloud UBL license endpoint DNS | `houdini-ubl.service` at boot → sets `HOUDINI_LICENSE_SERVER` | ⏳ PENDING — create endpoint in issue [#9](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/9) |
| `backblaze/b2-key-id` | B2 Application Key ID | `rclone-b2-renders.service` at boot | ✅ Stored |
| `backblaze/b2-app-key` | B2 Application Key secret | `rclone-b2-renders.service` at boot | ✅ Stored |
| `backblaze/b2-bucket` | B2 bucket name (`aoin-test`) | `rclone-b2-renders.service` at boot | ✅ Stored |
| `zerotier/api-token` | ZeroTier Central API token | Future: auto-auth in `03_zerotier.sh` | ✅ Stored |

### Updating houdini/license-endpoint-dns after endpoint creation

```bash
source .env
aws secretsmanager put-secret-value \
    --region us-west-2 \
    --secret-id houdini/license-endpoint-dns \
    --secret-string "<ENDPOINT_DNS_FROM_DEADLINE>"
```
See issue [#9](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/9) for full endpoint creation steps.

### Updating an existing secret

```bash
source .env
aws secretsmanager put-secret-value \
    --region us-west-2 \
    --secret-id backblaze/b2-app-key \
    --secret-string "<NEW_VALUE>"
```

---

## Backblaze B2 — bucket details

| Property | Value |
|---|---|
| Bucket name | `aoin-test` |
| Bucket ID | `33fe3c9f6231e68295880a19` |
| Endpoint | `s3.us-west-004.backblazeb2.com` |
| Key name | `HOUDINI-EC2-KEY` |
| Visibility | Public ⚠️ — change to Private before production use |
| Mount point on worker | `/mnt/renders` |

> **Action required:** Set bucket visibility to **Private** in Backblaze → Bucket Settings
> before any production renders are written.

---

## ZeroTier

| Property | Value |
|---|---|
| Network ID | `d3ecf5726d14ac76` |
| Network name | `deadline_houdini` |
| API base URL | `https://my.zerotier.com/api/` (legacy Central API) |
| Token stored as | `zerotier/api-token` in Secrets Manager |

The API token enables future automation for node authorization. The relevant call:

```bash
curl -X POST \
  -H "Authorization: token <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"config": {"authorized": true}}' \
  "https://my.zerotier.com/api/network/d3ecf5726d14ac76/member/<NODE_ID>"
```

---

## Local .env file

Located at `houdini-aws-portal/.env`. **Gitignored — never commit.**

Current variable inventory:

```
B2_KEY_ID               Backblaze Application Key ID
B2_KEY_NAME             Key label (human-readable, not used in auth)
B2_APP_KEY              Backblaze Application Key secret
AWS_ACCESS_KEY_ID       deadline-portal IAM access key
AWS_SECRET_ACCESS_KEY   deadline-portal IAM secret
AWS_DEFAULT_REGION      us-west-2
ZEROTIER_API_TOKEN      ZeroTier Central API token
```

Load for a shell session:

```bash
set -a && source .env && set +a
```

---

## IAM user: deadline-portal

Least-privilege user for running project scripts and Deadline AWS Portal.

| Permission block | Scope |
|---|---|
| `EC2SpotAndAMI` | EC2 instance + spot + AMI lifecycle |
| `IAMPassRole` | PassRole to `deadline-worker-profile` only |
| `BillingReadOnly` | Cost Explorer + Budgets read |
| `ServiceQuotas` | Read + request quota increases |
| `SecretsManagerRead` | `houdini/*`, `backblaze/*`, `zerotier/*` read only |

---

## IAM instance profile: deadline-worker-profile

Attached to every EC2 worker at launch (see Issue [#2](http://gitlab.someofitlater.com/renderfarm/houdini-aws-portal/-/issues/2)).
Must be created before the AMI build instance is launched.

Minimum permissions:
- `secretsmanager:GetSecretValue` on `houdini/*`, `backblaze/*`, `zerotier/*`
- `AmazonSSMManagedInstanceCore` (SSM session manager access)
