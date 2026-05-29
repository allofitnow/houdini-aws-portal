#!/usr/bin/env bash
# launch_build_instance.sh
# Launch a temporary GPU build instance for building the worker AMI.
# Run from your local workstation with AWS CLI configured.
#
# Prerequisites:
#   - Key pair named by KEY_NAME must exist in the selected region
#   - IAM instance profile named by PROFILE must exist
#   - SUBNET_ID and SG_ID must identify build networking in the selected region

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
AMI_ID="${AMI_ID:-ami-0ababc7e5826abb79}"      # Ubuntu 22.04 LTS; override per region
INSTANCE_TYPE="${INSTANCE_TYPE:-g6.xlarge}"
KEY_NAME="${KEY_NAME:-deadline-ami-build}"
PROFILE="${PROFILE:-deadline-worker-profile}"
SUBNET_ID="${SUBNET_ID:-}"
SG_ID="${SG_ID:-}"
VOLUME_SIZE="${VOLUME_SIZE:-100}"              # GB root volume (Houdini + NVIDIA + Deadline)

usage() {
    cat >&2 <<USAGE
Usage: $0 --subnet-id SUBNET --sg-id SG [options]

Options:
  --region REGION           AWS region for the build instance
  --ami-id AMI              Base Ubuntu AMI in that region
  --instance-type TYPE      GPU instance type (default: ${INSTANCE_TYPE})
  --key-name NAME           EC2 key pair (default: ${KEY_NAME})
  --profile NAME            IAM instance profile (default: ${PROFILE})
  --volume-size GB          Root volume size (default: ${VOLUME_SIZE})
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region) REGION="$2"; shift 2 ;;
        --ami-id) AMI_ID="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --key-name) KEY_NAME="$2"; shift 2 ;;
        --profile) PROFILE="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --sg-id|--security-group-id) SG_ID="$2"; shift 2 ;;
        --volume-size) VOLUME_SIZE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$SUBNET_ID" || -z "$SG_ID" ]]; then
    echo "ERROR: SUBNET_ID and SG_ID are required. Set env vars or pass --subnet-id/--sg-id." >&2
    usage
    exit 1
fi

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=deadline-ami-build},{Key=Purpose,Value=ami-build},{Key=Region,Value=${REGION}}]" \
    --query "Instances[0].InstanceId" \
    --output text)

echo "Launched instance: $INSTANCE_ID"
echo "Waiting for running state..."

aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query "Reservations[0].Instances[0].PublicIpAddress" \
    --output text)

echo ""
echo "Instance is running."
echo "  Instance ID : $INSTANCE_ID"
echo "  Region      : $REGION"
echo "  Public IP   : $PUBLIC_IP"
echo ""
echo "Next steps:"
echo "  1. Copy build scripts to instance:"
echo "     scp -i ~/.ssh/${KEY_NAME}.pem -r ../ami ubuntu@${PUBLIC_IP}:/tmp/"
echo "  2. SSH in:"
echo "     ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo "  3. Run the build:"
echo "     sudo bash /tmp/ami/build.sh --aws-region ${REGION} --repo-ip <ZT_IP> --s3-bucket <BUCKET> --houdini-build <BUILD> --b2-bucket <B2_BUCKET>"
