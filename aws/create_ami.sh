#!/usr/bin/env bash
# create_ami.sh
# Stop the build instance and create the worker AMI from it.
# Run from your local workstation after build.sh completes on the instance.
#
# Usage: ./create_ami.sh <INSTANCE_ID>

REGION="us-west-2"
AMI_NAME="deadline-10.4.2.3-houdini-21.0-ubuntu22-l40s-v1"
AMI_DESC="Deadline 10.4.2.3 + Houdini 21.0 UBL + ZeroTier + rclone B2. Ubuntu 22.04, NVIDIA L40S driver 535. us-west-2."

INSTANCE_ID="${1:-}"
if [[ -z "$INSTANCE_ID" ]]; then
    echo "Usage: $0 <INSTANCE_ID>"
    exit 1
fi

echo "Stopping instance $INSTANCE_ID before imaging..."
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
    --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=${AMI_NAME}},{Key=DeadlineVersion,Value=10.4.2.3},{Key=HoudiniVersion,Value=21.0}]" \
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
echo "Next: Register this AMI in Deadline Monitor > Tools > Configure AWS Portal"
echo "See deadline/aws_portal_notes.md for full configuration steps."
