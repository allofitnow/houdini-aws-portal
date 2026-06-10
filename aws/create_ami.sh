#!/usr/bin/env bash
# create_ami.sh
# Stop the build instance and create the Portal-ready worker AMI from it.
# Run from your local workstation after build.sh completes on the instance.
#
# Preconditions:
#   - build.sh has completed successfully on the target instance
#   - AWS credentials with EC2 AMI creation permissions are configured

set -euo pipefail

REGION="${REGION:-${AWS_REGION:-us-west-2}}"
AMI_NAME="${AMI_NAME:-deadline-10.4.2.3-houdini-21.0-al2023-l40s-v1}"
AMI_DESC="${AMI_DESC:-Portal-ready Deadline 10.4.2.3 + Houdini 21.0.729 UBL. Amazon Linux 2023, NVIDIA L40S GPU driver (R550). Region ${REGION}.}"
INSTANCE_ID=""

usage() {
    cat >&2 <<USAGE
Usage: $0 <INSTANCE_ID> [--region REGION] [--name AMI_NAME] [--description AMI_DESC]
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region|--aws-region) REGION="$2"; shift 2 ;;
        --name|--ami-name) AMI_NAME="$2"; shift 2 ;;
        --description|--ami-desc) AMI_DESC="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        i-*) INSTANCE_ID="$1"; shift ;;
        *) echo "ERROR: Unknown argument '$1'" >&2; usage; exit 1 ;;
    esac
done

if [[ -z "$INSTANCE_ID" ]]; then
    usage
    exit 1
fi

echo "Stopping instance $INSTANCE_ID in ${REGION} before imaging..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Instance stopped."

echo "Creating AMI..."
AMI_ID=$(aws ec2 create-image \
    --region "$REGION" \
    --instance-id "$INSTANCE_ID" \
    --name "$AMI_NAME" \
    --description "$AMI_DESC" \
    --no-reboot \
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=DeadlineVersion,Value=10.4.2.3},{Key=HoudiniVersion,Value=21.0},{Key=OS,Value=AL2023},{Key=GPU,Value=L40S},{Key=PortalReady,Value=true},{Key=Region,Value=${REGION}}]" \
    --query "ImageId" \
    --output text)

echo "AMI creation started: $AMI_ID"
echo "Waiting for AMI to become available (this may take 5-15 minutes)..."
aws ec2 wait image-available --region "$REGION" --image-ids "$AMI_ID"

echo ""
echo "AMI is ready."
echo "  AMI ID   : $AMI_ID"
echo "  AMI Name : $AMI_NAME"
echo "  Region   : $REGION"
echo ""
echo "Next: register this AMI in Deadline Monitor > Tools > Configure AWS Portal."
echo "See deadline/aws_portal_notes.md for full configuration steps."
