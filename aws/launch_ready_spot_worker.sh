#!/usr/bin/env bash
# launch_ready_spot_worker.sh
# One-click launch/provision for a Deadline Spot Worker.
#
# This script:
#   1. Launches one Spot Worker (with multi-region/multi-AZ fallback)
#   2. Waits for SSM readiness
#   3. Regenerates ZeroTier identity (avoids AMI-baked node ID conflicts)
#   4. Authorizes the new ZeroTier node on the network
#   5. Injects the launch host's SSH public key for ubuntu access
#   6. Stages Deadline RCS certs to S3 then pulls them on the worker
#   7. Configures Deadline to connect to RCS via ZeroTier
#   8. Restarts Deadline and verifies worker registration
#
# Usage:
#   ./aws/launch_ready_spot_worker.sh
#
# Region fallback order (default):
#   us-east-1, us-east-2, us-west-1, us-west-2
#
# Optional environment overrides:
#   READY_WORKER_REGIONS=us-east-1,us-east-2,us-west-1,us-west-2
#   SOURCE_AMI_REGION=us-west-2
#   SOURCE_AMI_ID=ami-0f70342f66dc80ddb
#   AMI_ID_US_EAST_1=ami-...
#   SUBNET_ID_US_EAST_1=subnet-...
#   SG_ID_US_EAST_1=sg-...
#   INSTANCE_TYPE=g5.xlarge
#   DEADLINE_CLIENT_PFX=/mnt/c/Users/aoin/Deadline10Client.pfx
#   DEADLINE_RCS_CERT=/mnt/c/Users/aoin/DeadlineRCSServer.pem
#   DEADLINE_RCS_HOST=ATXRTX
#   DEADLINE_RCS_ZT_IP=10.147.18.89
#   DEADLINE_RCS_PORT=4433
#   ZT_NETWORK_ID=d3ecf5726d14ac76
#   CERT_BUCKET=renderfarm-installers-774538489810
#   CERT_PREFIX=tmp/deadline-certs
#   SSH_PUBLIC_KEYS_FILE=~/.ssh/authorized_keys  (or set SSH_PUBLIC_KEYS directly)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SOURCE_AMI_REGION="${SOURCE_AMI_REGION:-us-west-2}"
SOURCE_AMI_ID="${SOURCE_AMI_ID:-ami-0f70342f66dc80ddb}"
INSTANCE_TYPE="${INSTANCE_TYPE:-g5.xlarge}"
PROFILE="${PROFILE:-deadline-worker-profile}"
MARKET_OPTIONS='{"MarketType":"spot","SpotOptions":{"SpotInstanceType":"one-time"}}'
READY_WORKER_REGIONS="${READY_WORKER_REGIONS:-us-east-1,us-east-2,us-west-1,us-west-2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
fi

ZT_NETWORK_ID="${ZT_NETWORK_ID:-d3ecf5726d14ac76}"
DEADLINE_RCS_HOST="${DEADLINE_RCS_HOST:-ATXRTX}"
DEADLINE_RCS_ZT_IP="${DEADLINE_RCS_ZT_IP:-10.147.18.89}"
DEADLINE_RCS_PORT="${DEADLINE_RCS_PORT:-4433}"
DEADLINE_CLIENT_PFX="${DEADLINE_CLIENT_PFX:-/mnt/c/Users/aoin/Deadline10Client.pfx}"
DEADLINE_RCS_CERT="${DEADLINE_RCS_CERT:-/mnt/c/Users/aoin/DeadlineRCSServer.pem}"
DEADLINE_WORKER_SG_NAME="${DEADLINE_WORKER_SG_NAME:-deadline-worker-sg}"

# S3 bucket/prefix used to stage certificates so SSM can pull them without
# embedding binary/base64 data inline in CLI parameters.
CERT_BUCKET="${CERT_BUCKET:-renderfarm-installers-774538489810}"
CERT_PREFIX="${CERT_PREFIX:-tmp/deadline-certs}"
# Set to "true" to also install GNOME + Amazon DCV on each worker.
INSTALL_DESKTOP="${INSTALL_DESKTOP:-false}"

# SSH public keys to inject into the worker's ubuntu account.
# Defaults to all public keys found on this machine.
if [[ -z "${SSH_PUBLIC_KEYS:-}" ]]; then
    SSH_PUBLIC_KEYS=$(cat ~/.ssh/id_*.pub 2>/dev/null || true)
    # Additional trusted keys
    SSH_PUBLIC_KEYS+=$'\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBoaXzb7kZXI0VHl0TJzBv6l0UK29Xs0XmZCMHM8myvc aoin2@aoin-ma'
fi

REGION=""
AMI_ID=""
INSTANCE_ID=""
SUBNET_ID_SELECTED=""
SG_ID_SELECTED=""
SOURCE_AMI_NAME=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
require_file() {
    local file="$1"
    if [[ ! -r "$file" ]]; then
        echo "ERROR: Required file not readable: $file" >&2
        exit 1
    fi
}

require_env() {
    local name="$1"
    if [[ -z "${!name:-}" ]]; then
        echo "ERROR: ${name} is not set. Add it to .env or export it." >&2
        exit 1
    fi
}

region_env_value() {
    local prefix="$1"
    local region="$2"
    local key="${region^^}"
    key="${key//-/_}"
    key="${prefix}_${key}"
    printf '%s' "${!key:-}"
}

# ---------------------------------------------------------------------------
# AMI / subnet / security-group resolution
# ---------------------------------------------------------------------------
source_ami_name() {
    if [[ -n "$SOURCE_AMI_NAME" ]]; then
        printf '%s' "$SOURCE_AMI_NAME"
        return 0
    fi

    SOURCE_AMI_NAME=$(aws ec2 describe-images \
        --region "$SOURCE_AMI_REGION" \
        --image-ids "$SOURCE_AMI_ID" \
        --query 'Images[0].Name' \
        --output text)

    if [[ -z "$SOURCE_AMI_NAME" || "$SOURCE_AMI_NAME" == "None" ]]; then
        echo "ERROR: Could not resolve AMI name for ${SOURCE_AMI_ID} in ${SOURCE_AMI_REGION}." >&2
        exit 1
    fi

    printf '%s' "$SOURCE_AMI_NAME"
}

resolve_ami() {
    local region="$1"
    local override name image_id

    override=$(region_env_value AMI_ID "$region")
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi

    if [[ "$region" == "$SOURCE_AMI_REGION" ]]; then
        printf '%s' "$SOURCE_AMI_ID"
        return 0
    fi

    name=$(source_ami_name)
    image_id=$(aws ec2 describe-images \
        --region "$region" \
        --owners self \
        --filters "Name=name,Values=${name}" "Name=state,Values=available" \
        --query 'Images | sort_by(@,&CreationDate)[-1].ImageId' \
        --output text 2>/dev/null || true)

    if [[ -z "$image_id" || "$image_id" == "None" ]]; then
        return 1
    fi

    printf '%s' "$image_id"
}

resolve_subnets() {
    local region="$1"
    local override subnet_ids

    override=$(region_env_value SUBNET_ID "$region")
    if [[ -n "$override" ]]; then
        printf '%s\n' $override
        return 0
    fi

    if [[ "$region" == "$SOURCE_AMI_REGION" && -n "${SUBNET_ID:-}" ]]; then
        printf '%s\n' $SUBNET_ID
        return 0
    fi

    subnet_ids=$(aws ec2 describe-subnets \
        --region "$region" \
        --filters Name=default-for-az,Values=true \
        --query 'Subnets | sort_by(@,&AvailabilityZone)[].SubnetId' \
        --output text 2>/dev/null || true)

    if [[ -z "$subnet_ids" || "$subnet_ids" == "None" ]]; then
        return 1
    fi

    printf '%s\n' $subnet_ids
}

resolve_security_group() {
    local region="$1"
    local subnet_id="$2"
    local override vpc_id group_id

    override=$(region_env_value SG_ID "$region")
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
        return 0
    fi

    if [[ "$region" == "$SOURCE_AMI_REGION" && -n "${SG_ID:-}" ]]; then
        printf '%s' "$SG_ID"
        return 0
    fi

    vpc_id=$(aws ec2 describe-subnets \
        --region "$region" \
        --subnet-ids "$subnet_id" \
        --query 'Subnets[0].VpcId' \
        --output text)

    group_id=$(aws ec2 describe-security-groups \
        --region "$region" \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${DEADLINE_WORKER_SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>/dev/null || true)

    if [[ -n "$group_id" && "$group_id" != "None" ]]; then
        printf '%s' "$group_id"
        return 0
    fi

    group_id=$(aws ec2 create-security-group \
        --region "$region" \
        --group-name "$DEADLINE_WORKER_SG_NAME" \
        --description "Deadline worker outbound access" \
        --vpc-id "$vpc_id" \
        --query GroupId \
        --output text)

    aws ec2 create-tags \
        --region "$region" \
        --resources "$group_id" \
        --tags Key=Name,Value="$DEADLINE_WORKER_SG_NAME" Key=project,Value=deadline-worker \
        >/dev/null

    printf '%s' "$group_id"
}

# ---------------------------------------------------------------------------
# Launch with region/AZ fallback
# ---------------------------------------------------------------------------
launch_instance_with_fallback() {
    local regions_string regions candidate ami subnet sg name err_file output_file
    regions_string="${READY_WORKER_REGIONS//,/ }"
    read -r -a regions <<< "$regions_string"

    for candidate in "${regions[@]}"; do
        [[ -z "$candidate" ]] && continue
        echo "Trying ${candidate}..."

        if ! ami=$(resolve_ami "$candidate"); then
            echo "  No matching AMI found in ${candidate}; skipping."
            continue
        fi

        if ! mapfile -t subnets < <(resolve_subnets "$candidate"); then
            echo "  No subnet available in ${candidate}; skipping."
            continue
        fi

        if [[ ${#subnets[@]} -eq 0 ]]; then
            echo "  No subnet available in ${candidate}; skipping."
            continue
        fi

        for subnet in "${subnets[@]}"; do
            [[ -z "$subnet" ]] && continue

            if ! sg=$(resolve_security_group "$candidate" "$subnet"); then
                echo "  No security group available for subnet ${subnet}; skipping subnet."
                continue
            fi

            az=$(aws ec2 describe-subnets \
                --region "$candidate" \
                --subnet-ids "$subnet" \
                --query 'Subnets[0].AvailabilityZone' \
                --output text 2>/dev/null || printf 'unknown')
            echo "  Trying subnet ${subnet} (${az})..."

            name="deadline-worker-$(date +%s)"
            err_file=$(mktemp)
            output_file=$(mktemp)
            if aws ec2 run-instances \
                --region "$candidate" \
                --image-id "$ami" \
                --instance-type "$INSTANCE_TYPE" \
                --iam-instance-profile Name="$PROFILE" \
                --subnet-id "$subnet" \
                --security-group-ids "$sg" \
                --instance-market-options "$MARKET_OPTIONS" \
                --tag-specifications "ResourceType=instance,Tags=[{Key=project,Value=deadline-worker},{Key=Name,Value=${name}}]" \
                --query "Instances[0].InstanceId" \
                --output text >"$output_file" 2>"$err_file"; then
                REGION="$candidate"
                AMI_ID="$ami"
                SUBNET_ID_SELECTED="$subnet"
                SG_ID_SELECTED="$sg"
                INSTANCE_ID=$(cat "$output_file")
                rm -f "$err_file" "$output_file"
                echo "Launched ${INSTANCE_ID} in ${REGION} (${az})."
                return 0
            fi

            echo "    Launch failed in ${candidate}/${az}:"
            sed 's/^/      /' "$err_file"
            rm -f "$err_file" "$output_file"
        done
    done

    echo "ERROR: Failed to launch ${INSTANCE_TYPE} Spot worker in all configured regions: ${READY_WORKER_REGIONS}" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# SSM helpers
# ---------------------------------------------------------------------------
wait_for_ssm() {
    local instance_id="$1"
    echo "Waiting for SSM to come online for ${instance_id} in ${REGION}..."
    for _ in {1..60}; do
        local status
        status=$(aws ssm describe-instance-information \
            --region "$REGION" \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text 2>/dev/null || true)
        if [[ "$status" == "Online" ]]; then
            echo "SSM is online."
            return 0
        fi
        sleep 10
    done
    echo "ERROR: Timed out waiting for SSM on ${instance_id}." >&2
    exit 1
}

# ssm_send_and_wait <instance_id> <cmd1> [<cmd2> ...]
#
# Sends an AWS-RunShellScript command built from the given command strings.
# Uses --cli-input-json + jq so commands with any special characters
# (slashes, pipes, quotes, S3 URIs, etc.) are handled correctly.
# Waits for completion and prints [Status, Stdout, Stderr].
ssm_send_and_wait() {
    local instance_id="$1"
    shift
    local tmp_input command_id status

    tmp_input=$(mktemp)
    # Build the JSON input safely: each remaining argument is one command string.
    printf '%s\n' "$@" \
        | jq -R . \
        | jq -s \
            --arg iid "$instance_id" \
            '{DocumentName:"AWS-RunShellScript",InstanceIds:[$iid],Parameters:{commands:.}}' \
        > "$tmp_input"

    command_id=$(aws ssm send-command \
        --region "$REGION" \
        --cli-input-json "file://${tmp_input}" \
        --query Command.CommandId \
        --output text)
    rm -f "$tmp_input"

    for _ in {1..60}; do
        status=$(aws ssm get-command-invocation \
            --region "$REGION" \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --query Status \
            --output text 2>/dev/null || true)
        case "$status" in
            Success|Failed|Cancelled|TimedOut|Cancelling) break ;;
        esac
        sleep 5
    done

    aws ssm get-command-invocation \
        --region "$REGION" \
        --command-id "$command_id" \
        --instance-id "$instance_id" \
        --query '[Status,StandardOutputContent,StandardErrorContent]' \
        --output text
}

# ---------------------------------------------------------------------------
# Provisioning steps
# ---------------------------------------------------------------------------

# Regenerate ZeroTier identity so each instance gets a unique node ID
# regardless of what was baked into the AMI.
regenerate_zerotier_identity() {
    local instance_id="$1"
    echo "Regenerating ZeroTier identity on ${instance_id}..."
    ssm_send_and_wait "$instance_id" \
        "sudo systemctl stop zerotier-one" \
        "sudo rm -f /var/lib/zerotier-one/identity.public /var/lib/zerotier-one/identity.secret" \
        "sudo systemctl start zerotier-one" \
        "sleep 5" \
        "sudo zerotier-cli info || true"
    echo "ZeroTier identity regenerated."
}

authorize_zerotier_node() {
    local instance_id="$1"
    local output node_id

    echo "Waiting for ZeroTier node to join ${ZT_NETWORK_ID}..."
    for _ in {1..40}; do
        output=$(ssm_send_and_wait "$instance_id" \
            "sudo zerotier-cli info 2>/dev/null || true" \
            "sudo zerotier-cli listnetworks 2>/dev/null || true" || true)
        node_id=$(awk '/^[[:space:]]*Success[[:space:]]+200 info /{print $4; exit} /^200 info /{print $3; exit}' <<< "$output")
        if [[ -n "${node_id:-}" ]]; then
            echo "ZeroTier node: ${node_id}"
            curl -fsS -X POST \
                -H "Authorization: token ${ZEROTIER_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"config\":{\"authorized\":true},\"name\":\"deadline-worker-${instance_id}\"}" \
                "https://api.zerotier.com/api/v1/network/${ZT_NETWORK_ID}/member/${node_id}" \
                >/dev/null
            echo "Authorized ZeroTier node ${node_id}."
            return 0
        fi
        sleep 10
    done

    echo "ERROR: Timed out waiting for ZeroTier node ID." >&2
    exit 1
}

# Inject this machine's SSH public keys into the worker's ubuntu account.
inject_ssh_keys() {
    local instance_id="$1"
    if [[ -z "${SSH_PUBLIC_KEYS:-}" ]]; then
        echo "No SSH public keys found; skipping SSH key injection."
        return 0
    fi

    echo "Injecting SSH public keys into ubuntu@${instance_id}..."
    # Escape for safe embedding in a shell heredoc inside jq
    local escaped_keys
    escaped_keys=$(printf '%s' "$SSH_PUBLIC_KEYS" | sed "s/'/'\\''/g")

    ssm_send_and_wait "$instance_id" \
        "sudo mkdir -p /home/ubuntu/.ssh" \
        "sudo chmod 700 /home/ubuntu/.ssh" \
        "printf '%s\\n' '${escaped_keys}' | sudo tee -a /home/ubuntu/.ssh/authorized_keys > /dev/null" \
        "sudo sort -u /home/ubuntu/.ssh/authorized_keys -o /home/ubuntu/.ssh/authorized_keys" \
        "sudo chmod 600 /home/ubuntu/.ssh/authorized_keys" \
        "sudo chown -R ubuntu:ubuntu /home/ubuntu/.ssh"
    echo "SSH keys injected."
}

stage_certs_to_s3() {
    echo "Staging Deadline certificates to s3://${CERT_BUCKET}/${CERT_PREFIX}/..."
    aws s3 cp "$DEADLINE_CLIENT_PFX" \
        "s3://${CERT_BUCKET}/${CERT_PREFIX}/Deadline10Client.pfx" \
        --region us-east-1 >/dev/null
    aws s3 cp "$DEADLINE_RCS_CERT" \
        "s3://${CERT_BUCKET}/${CERT_PREFIX}/DeadlineRCSServer.pem" \
        --region us-east-1 >/dev/null
    echo "Certificates staged."
}

configure_deadline() {
    local instance_id="$1"

    echo "Installing Deadline RCS certificates and configuring Deadline client..."
    stage_certs_to_s3

    ssm_send_and_wait "$instance_id" \
        "sudo mkdir -p /var/lib/Thinkbox/Deadline10/certs" \
        "aws s3 cp s3://${CERT_BUCKET}/${CERT_PREFIX}/Deadline10Client.pfx /var/lib/Thinkbox/Deadline10/certs/Deadline10Client.pfx --region ${REGION}" \
        "aws s3 cp s3://${CERT_BUCKET}/${CERT_PREFIX}/DeadlineRCSServer.pem /var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem --region ${REGION}" \
        "sudo chmod 600 /var/lib/Thinkbox/Deadline10/certs/Deadline10Client.pfx" \
        "sudo chmod 644 /var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem" \
        "grep -qE '[[:space:]]${DEADLINE_RCS_HOST}$' /etc/hosts && sudo sed -i 's|^.*[[:space:]]${DEADLINE_RCS_HOST}$|${DEADLINE_RCS_ZT_IP} ${DEADLINE_RCS_HOST}|' /etc/hosts || echo '${DEADLINE_RCS_ZT_IP} ${DEADLINE_RCS_HOST}' | sudo tee -a /etc/hosts" \
        "sudo cp /var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem /usr/local/share/ca-certificates/DeadlineRCSServer.crt" \
        "sudo update-ca-certificates" \
        "sudo sed -i 's|^ProxyRoot=.*|ProxyRoot=${DEADLINE_RCS_HOST}:${DEADLINE_RCS_PORT}|' /var/lib/Thinkbox/Deadline10/deadline.ini" \
        "sudo sed -i 's|^ProxySSLCertificate=.*|ProxySSLCertificate=/var/lib/Thinkbox/Deadline10/certs/Deadline10Client.pfx|' /var/lib/Thinkbox/Deadline10/deadline.ini" \
        "sudo sed -i 's|^ProxySSLCA=.*|ProxySSLCA=/var/lib/Thinkbox/Deadline10/certs/DeadlineRCSServer.pem|' /var/lib/Thinkbox/Deadline10/deadline.ini" \
        "sudo sed -i 's|^ProxyUseSSL=.*|ProxyUseSSL=True|' /var/lib/Thinkbox/Deadline10/deadline.ini" \
        "sudo sed -i 's|^ClientSSLAuthentication=.*|ClientSSLAuthentication=Required|' /var/lib/Thinkbox/Deadline10/deadline.ini" \
        "sudo rm -f /root/Thinkbox/Deadline10/deadline.ini" \
        "sudo systemctl restart deadline10launcher"

    echo "Deadline configured."
}

verify_deadline() {
    local instance_id="$1"
    local output worker_name

    echo "Verifying Deadline registration (up to 4 minutes)..."
    for _ in {1..24}; do
        output=$(ssm_send_and_wait "$instance_id" \
            'WORKER_NAME=$(hostname); echo "WORKER_NAME=${WORKER_NAME}"' \
            '/opt/Thinkbox/Deadline10/bin/deadlinecommand -GetSlaveNames 2>&1 || true' \
            'systemctl is-active deadline10launcher || true' || true)
        echo "$output"
        worker_name=$(awk -F= '/WORKER_NAME=/{print $2; exit}' <<< "$output")
        if [[ -n "${worker_name:-}" ]] && grep -qx "$worker_name" <<< "$output"; then
            echo "Deadline worker is registered: ${worker_name}"
            return 0
        fi
        sleep 10
    done

    echo "ERROR: Timed out waiting for Deadline Worker registration." >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
require_env ZEROTIER_API_TOKEN
require_file "$DEADLINE_CLIENT_PFX"
require_file "$DEADLINE_RCS_CERT"

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not found in PATH." >&2
    exit 1
fi

source_ami_name >/dev/null

echo "Launching ready Deadline spot worker (${INSTANCE_TYPE})."
echo "Region fallback order: ${READY_WORKER_REGIONS}"

launch_instance_with_fallback
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
wait_for_ssm "$INSTANCE_ID"
regenerate_zerotier_identity "$INSTANCE_ID"
authorize_zerotier_node "$INSTANCE_ID"
inject_ssh_keys "$INSTANCE_ID"
configure_deadline "$INSTANCE_ID"
verify_deadline "$INSTANCE_ID"

# Optionally install GNOME + Amazon DCV
if [[ "${INSTALL_DESKTOP}" == "true" ]]; then
    echo ""
    echo "INSTALL_DESKTOP=true — starting GNOME + DCV setup..."
    INSTANCE_ID="$INSTANCE_ID" REGION="$REGION"         bash "${SCRIPT_DIR}/setup_desktop.sh" "$INSTANCE_ID" "$REGION"
else
    echo ""
    echo "========================================================"
    echo " Worker ready: ${INSTANCE_ID} in ${REGION}"
    echo " SSH:          ssh ubuntu@<zerotier-ip-of-worker>"
    echo " Deadline:     Worker should appear in Deadline Monitor"
    echo " Desktop:      Set INSTALL_DESKTOP=true to add GNOME+DCV"
    echo "========================================================"
fi
