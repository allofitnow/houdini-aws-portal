#!/usr/bin/env bash
# download_installers.sh
# Downloads Houdini and Deadline installers and uploads them to S3.
#
# USAGE:
#   # Download Houdini via SideFX API (requires API credentials):
#   ./download_installers.sh houdini --client-id <ID> --client-secret <SECRET>
#
#   # Download Deadline client (requires presigned URL from AWS Support/console):
#   ./download_installers.sh deadline --presigned-url <URL>
#
#   # Create S3 bucket and upload:
#   ./download_installers.sh upload-all
#
# HOUDINI:
#   Requires SideFX Web API credentials from https://www.sidefx.com/services/api/
#   The API returns a temporary signed CloudFront URL for the tarball.
#   API docs: https://www.sidefx.com/docs/api/download/index.html
#
# DEADLINE:
#   Deadline 10 entered maintenance mode Nov 2025.
#   The old download site (downloads.thinkboxsoftware.com) now redirects to
#   the AWS Deadline Cloud console.
#   The thinkbox-installers S3 bucket is locked down (403).
#   To obtain the installer:
#     1. Log into https://console.aws.amazon.com/deadlinecloud/home#/thinkbox
#     2. Open an AWS Support case requesting Deadline 10.4.2.3 client installer
#     3. Or obtain a presigned URL from an existing Deadline repository
#
# PREREQUISITES:
#   - aws CLI configured with appropriate credentials
#   - python3 with requests library (for Houdini download)
#   - Source .env for S3_BUCKET and other settings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/.env"

S3_BUCKET="${S3_BUCKET:-renderfarm-installers-774538489810}"
AWS_REGION="${AWS_DEFAULT_REGION:-us-west-2}"
HOUDINI_VERSION="21.0"
HOUDINI_BUILD="${HOUDINI_BUILD:-729}"
DEADLINE_VERSION="10.4.2.3"

HOUDINI_TARBALL="houdini-${HOUDINI_VERSION}.${HOUDINI_BUILD}-linux_x86_64_gcc11.2.tar.gz"
DEADLINE_INSTALLER="DeadlineClient-${DEADLINE_VERSION}-linux-x64-installer.run"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# --- SideFX API Python helper ---
SIDEFX_API_PY="${TMP_DIR}/sidefx_api.py"
cat > "$SIDEFX_API_PY" << 'PYTHON'
"""SideFX Web API download helper.
Uses the documented API at https://www.sidefx.com/docs/api/download/index.html
"""
import sys, json, base64, time
import requests

def get_access_token(client_id, client_secret, token_url="https://www.sidefx.com/oauth2/application_token"):
    auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    resp = requests.post(token_url, headers={"Authorization": f"Basic {auth}"}, timeout=60)
    if resp.status_code != 200:
        print(f"ERROR: Auth failed ({resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)
    data = resp.json()
    return data["access_token"]

def call_api(access_token, function, args, kwargs, endpoint="https://www.sidefx.com/api/"):
    resp = requests.post(endpoint, 
        headers={"Authorization": f"Bearer {access_token}"},
        data={"json": json.dumps([function, args, kwargs])},
        timeout=120)
    if resp.status_code != 200:
        print(f"ERROR: API call failed ({resp.status_code}): {resp.text}", file=sys.stderr)
        sys.exit(1)
    return resp.json()

def download_build(client_id, client_secret, version, build, platform, output_file):
    print(f"Getting access token...")
    token = get_access_token(client_id, client_secret)
    
    print(f"Requesting download URL for houdini {version}.{build} {platform}...")
    result = call_api(token, "download.get_daily_build_download",
        ["houdini", version, str(build), platform], {})
    
    download_url = result.get("download_url")
    if not download_url:
        print(f"ERROR: No download_url in response: {result}", file=sys.stderr)
        sys.exit(1)
    
    print(f"Download URL: {download_url}")
    print(f"Filename: {result.get('filename', 'N/A')}")
    print(f"Size: {result.get('size', 'N/A')} bytes")
    print(f"Downloading to {output_file}...")
    
    resp = requests.get(download_url, stream=True, timeout=600)
    resp.raise_for_status()
    total = int(resp.headers.get('content-length', 0))
    downloaded = 0
    with open(output_file, 'wb') as f:
        for chunk in resp.iter_content(chunk_size=8*1024*1024):
            f.write(chunk)
            downloaded += len(chunk)
            if total:
                pct = downloaded * 100 / total
                print(f"\r  {downloaded}/{total} bytes ({pct:.1f}%)", end="", flush=True)
    print(f"\n  Done: {downloaded} bytes written to {output_file}")
    return output_file

if __name__ == "__main__":
    if len(sys.argv) < 5:
        print(f"Usage: {sys.argv[0]} <client_id> <client_secret> <version> <build> <output>")
        print(f"  e.g. {sys.argv[0]} abc123 def456 21.0 729 houdini-21.0.729-linux_x86_64_gcc11.2.tar.gz")
        sys.exit(1)
    download_build(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4],
                   "linux_x86_64_gcc11.2", sys.argv[5])
PYTHON

create_bucket() {
    echo "Creating S3 bucket: s3://${S3_BUCKET}"
    if aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
        echo "  Bucket already exists."
    else
        aws s3api create-bucket \
            --bucket "$S3_BUCKET" \
            --region "$AWS_REGION" \
            --create-bucket-configuration LocationConstraint="$AWS_REGION"
        echo "  Bucket created."
    fi
}

case "${1:-help}" in
    houdini)
        shift
        CLIENT_ID=""
        CLIENT_SECRET=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --client-id) CLIENT_ID="$2"; shift 2 ;;
                --client-secret) CLIENT_SECRET="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
            echo "ERROR: --client-id and --client-secret required."
            echo "Get credentials at: https://www.sidefx.com/services/api/"
            echo "Also ensure EULA is accepted: https://www.sidefx.com/services/eula/"
            exit 1
        fi
        echo "==> Downloading Houdini ${HOUDINI_VERSION}.${HOUDINI_BUILD} via SideFX API..."
        python3 "$SIDEFX_API_PY" "$CLIENT_ID" "$CLIENT_SECRET" \
            "$HOUDINI_VERSION" "$HOUDINI_BUILD" "${TMP_DIR}/${HOUDINI_TARBALL}"
        echo "==> Uploading to s3://${S3_BUCKET}/installers/${HOUDINI_TARBALL}"
        aws s3 cp "${TMP_DIR}/${HOUDINI_TARBALL}" \
            "s3://${S3_BUCKET}/installers/${HOUDINI_TARBALL}" \
            --region "$AWS_REGION"
        echo "==> Houdini upload complete."
        ;;
    deadline)
        shift
        PRESIGNED_URL=""
        LOCAL_FILE=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --presigned-url) PRESIGNED_URL="$2"; shift 2 ;;
                --local-file) LOCAL_FILE="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        if [[ -n "$PRESIGNED_URL" ]]; then
            echo "==> Downloading Deadline Client ${DEADLINE_VERSION} from presigned URL..."
            curl -L -o "${TMP_DIR}/${DEADLINE_INSTALLER}" "$PRESIGNED_URL"
        elif [[ -n "$LOCAL_FILE" ]]; then
            echo "==> Copying Deadline installer from local file..."
            cp "$LOCAL_FILE" "${TMP_DIR}/${DEADLINE_INSTALLER}"
        else
            echo "ERROR: --presigned-url or --local-file required."
            echo ""
            echo "Deadline 10 is in maintenance mode (since Nov 2025)."
            echo "To obtain the installer:"
            echo "  1. AWS Console: https://console.aws.amazon.com/deadlinecloud/home#/thinkbox"
            echo "  2. AWS Support case requesting Deadline ${DEADLINE_VERSION} client"
            echo "  3. Copy from existing Deadline repository"
            echo "  4. If you have a presigned S3 URL, use --presigned-url"
            echo "  5. If you have the file locally, use --local-file"
            exit 1
        fi
        chmod +x "${TMP_DIR}/${DEADLINE_INSTALLER}"
        echo "==> Uploading to s3://${S3_BUCKET}/installers/${DEADLINE_INSTALLER}"
        aws s3 cp "${TMP_DIR}/${DEADLINE_INSTALLER}" \
            "s3://${S3_BUCKET}/installers/${DEADLINE_INSTALLER}" \
            --region "$AWS_REGION"
        echo "==> Deadline upload complete."
        ;;
    upload-all)
        create_bucket
        echo ""
        echo "==> Checking for files in ${TMP_DIR}..."
        for f in "${TMP_DIR}/${HOUDINI_TARBALL}" "${TMP_DIR}/${DEADLINE_INSTALLER}"; do
            if [[ -f "$f" ]]; then
                fname=$(basename "$f")
                echo "  Uploading $fname..."
                aws s3 cp "$f" "s3://${S3_BUCKET}/installers/$fname" --region "$AWS_REGION"
            fi
        done
        echo "==> Listing bucket contents:"
        aws s3 ls "s3://${S3_BUCKET}/installers/" --region "$AWS_REGION"
        ;;
    help|*)
        echo "Usage: $0 <command> [options]"
        echo ""
        echo "Commands:"
        echo "  houdini    Download Houdini via SideFX API"
        echo "             --client-id <ID>       SideFX API client ID"
        echo "             --client-secret <KEY>  SideFX API client secret"
        echo ""
        echo "  deadline   Download Deadline client installer"
        echo "             --presigned-url <URL>  Presigned S3 download URL"
        echo "             --local-file <PATH>    Path to local installer file"
        echo ""
        echo "  upload-all Create S3 bucket and upload any files in tmp"
        echo ""
        echo "Configuration (from .env):"
        echo "  S3_BUCKET=${S3_BUCKET}"
        echo "  AWS_REGION=${AWS_REGION}"
        echo "  HOUDINI_BUILD=${HOUDINI_BUILD}"
        echo ""
        echo "Houdini: Get API credentials at https://www.sidefx.com/services/api/"
        echo "         Accept EULA at https://www.sidefx.com/services/eula/"
        echo "Deadline: Get installer from https://console.aws.amazon.com/deadlinecloud/home#/thinkbox"
        ;;
esac
