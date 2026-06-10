#!/usr/bin/env bash
# download_installers.sh
# Downloads Houdini and Deadline installers and uploads them to S3.
#
# HOUDINI: Uses the SideFX Web API (requires API credentials).
#   1. Go to https://www.sidefx.com/services/api/ to generate client_id + client_secret
#   2. Accept the EULA at https://www.sidefx.com/services/eula/
#   3. Set SIDEFX_CLIENT_ID and SIDEFX_CLIENT_SECRET env vars
#   4. This script calls download.get_daily_build_download() to get a temporary CDN URL
#
# DEADLINE: The Thinkbox installers are no longer publicly downloadable.
#   The old S3 bucket (thinkbox-installers) is locked down and downloads.thinkboxsoftware.com
#   redirects to the AWS Deadline Cloud console.
#   Options:
#   a) Download from AWS Deadline Cloud console: https://console.aws.amazon.com/deadlinecloud/home#/thinkbox
#   b) Request from AWS Support (Thinkbox is now part of AWS)
#   c) Copy from an existing Deadline repository's share
#   d) If you have the .run file locally, place it at the DEADLINE_LOCAL_PATH
#
# Usage:
#   export SIDEFX_CLIENT_ID="your_client_id"
#   export SIDEFX_CLIENT_SECRET="your_client_secret"
#   export S3_BUCKET="deadline-houdini-installers"
#   export AWS_REGION="us-west-2"
#   # For Deadline, if you have the file locally:
#   export DEADLINE_LOCAL_PATH="/path/to/DeadlineClient-10.4.2.3-linux-x64-installer.run"
#   bash download_installers.sh

set -euo pipefail

S3_BUCKET="${S3_BUCKET:-deadline-houdini-installers}"
AWS_REGION="${AWS_REGION:-us-west-2}"
HOUDINI_VERSION="21.0"
HOUDINI_BUILD="729"
DEADLINE_VERSION="10.4.2.3"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "==> Download Installers Script"
echo "==> S3 Bucket: s3://${S3_BUCKET}/installers/"
echo "==> AWS Region: ${AWS_REGION}"
echo ""

# --- Create S3 bucket if it doesn't exist ---
if ! aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    echo "==> Creating S3 bucket: $S3_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
        aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION"
    else
        aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
fi

# ============================================================
# HOUDINI - SideFX Web API
# ============================================================
HOUDINI_TARBALL="houdini-${HOUDINI_VERSION}.${HOUDINI_BUILD}-linux_x86_64_gcc11.2.tar.gz"
S3_HOUDINI_KEY="installers/${HOUDINI_TARBALL}"

# Check if already in S3
if aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_HOUDINI_KEY" --region "$AWS_REGION" 2>/dev/null; then
    echo "==> [HOUDINI] Already exists in S3: s3://${S3_BUCKET}/${S3_HOUDINI_KEY}"
else
    if [[ -z "${SIDEFX_CLIENT_ID:-}" || -z "${SIDEFX_CLIENT_SECRET:-}" ]]; then
        echo "==> [HOUDINI] SKIP: Set SIDEFX_CLIENT_ID and SIDEFX_CLIENT_SECRET to download from SideFX API"
        echo "    Generate credentials at: https://www.sidefx.com/services/api/"
        echo "    Accept EULA at: https://www.sidefx.com/services/eula/"
        echo "    API docs: https://www.sidefx.com/docs/api/download/index.html"
        echo ""
        echo "    API call needed:"
        echo "      POST https://www.sidefx.com/api/"
        echo "      JSON: ['download.get_daily_build_download', ['houdini', '21.0', '729', 'linux_x86_64_gcc11.2'], {}]"
    else
        echo "==> [HOUDINI] Fetching download URL from SideFX API..."

        # Step 1: Get access token
        AUTH=$(printf '%s:%s' "$SIDEFX_CLIENT_ID" "$SIDEFX_CLIENT_SECRET" | base64 -w0)
        TOKEN_RESPONSE=$(curl -s -X POST 'https://www.sidefx.com/oauth2/application_token' \
            -H "Authorization: Basic ${AUTH}" \
            -d 'grant_type=client_credentials')
        ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

        # Step 2: Get download URL
        API_RESPONSE=$(curl -s -X POST 'https://www.sidefx.com/api/' \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H 'Content-Type: application/x-www-form-urlencoded' \
            --data-urlencode "json=[\"download.get_daily_build_download\", [\"houdini\", \"21.0\", \"729\", \"linux_x86_64_gcc11.2\"], {}]")

        DOWNLOAD_URL=$(echo "$API_RESPONSE" | python3 -c 'import sys,json; print(json.load(sys.stdin)["download_url"])')
        echo "==> [HOUDINI] Download URL: ${DOWNLOAD_URL:0:80}..."

        # Step 3: Download
        echo "==> [HOUDINI] Downloading ${HOUDINI_TARBALL}..."
        curl -L -o "${TMP_DIR}/${HOUDINI_TARBALL}" "$DOWNLOAD_URL"

        # Step 4: Upload to S3
        echo "==> [HOUDINI] Uploading to s3://${S3_BUCKET}/${S3_HOUDINI_KEY}"
        aws s3 cp "${TMP_DIR}/${HOUDINI_TARBALL}" "s3://${S3_BUCKET}/${S3_HOUDINI_KEY}" \
            --region "$AWS_REGION"
        echo "==> [HOUDINI] Done!"
    fi
fi

echo ""

# ============================================================
# DEADLINE - Thinkbox/AWS
# ============================================================
DEADLINE_INSTALLER="DeadlineClient-${DEADLINE_VERSION}-linux-x64-installer.run"
S3_DEADLINE_KEY="installers/${DEADLINE_INSTALLER}"

# Check if already in S3
if aws s3api head-object --bucket "$S3_BUCKET" --key "$S3_DEADLINE_KEY" --region "$AWS_REGION" 2>/dev/null; then
    echo "==> [DEADLINE] Already exists in S3: s3://${S3_BUCKET}/${S3_DEADLINE_KEY}"
else
    DEADLINE_LOCAL_PATH="${DEADLINE_LOCAL_PATH:-}"
    if [[ -n "$DEADLINE_LOCAL_PATH" && -f "$DEADLINE_LOCAL_PATH" ]]; then
        echo "==> [DEADLINE] Uploading local file to s3://${S3_BUCKET}/${S3_DEADLINE_KEY}"
        aws s3 cp "$DEADLINE_LOCAL_PATH" "s3://${S3_BUCKET}/${S3_DEADLINE_KEY}" \
            --region "$AWS_REGION"
        echo "==> [DEADLINE] Done!"
    else
        echo "==> [DEADLINE] SKIP: Deadline installers are no longer publicly downloadable."
        echo "    The Thinkbox downloads site now redirects to AWS Deadline Cloud console."
        echo "    Options to obtain the installer:"
        echo "    a) AWS Deadline Cloud console: https://console.aws.amazon.com/deadlinecloud/home#/thinkbox"
        echo "    b) AWS Support request (Thinkbox is now part of AWS)"
        echo "    c) Copy from an existing Deadline 10 repository installation"
        echo "    d) Set DEADLINE_LOCAL_PATH and re-run this script"
        echo ""
        echo "    Expected filename: ${DEADLINE_INSTALLER}"
        echo "    Target S3 key: ${S3_DEADLINE_KEY}"
        echo ""
        echo "    Historical URL (no longer publicly accessible):"
        echo "    https://thinkbox-installers.s3.us-west-2.amazonaws.com/Deadline/10.4.2.3/${DEADLINE_INSTALLER}"
    fi
fi

echo ""
echo "==> Summary:"
echo "    S3 Bucket: s3://${S3_BUCKET}"
echo "    Houdini:   s3://${S3_BUCKET}/${S3_HOUDINI_KEY}"
echo "    Deadline:  s3://${S3_BUCKET}/${S3_DEADLINE_KEY}"
