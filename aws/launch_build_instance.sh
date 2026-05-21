#!/usr/bin/env bash
# launch_build_instance.sh
# Launch a temporary g6e.4xlarge in us-west-2 for building the worker AMI.
# Run from your local workstation with AWS CLI configured.
#
# Prerequisites:
#   - Key pair named 'deadline-ami-build' must exist in us-west-2
#   - IAM instance profile 'deadline-worker-profile' must exist
#   - Edit SUBNET_ID and SG_ID below to match your VPC

REGION="us-west-2"
AMI_ID="ami-0ababc7e5826abb79"      # Ubuntu 22.04 LTS, us-west-2, May 2026
INSTANCE_TYPE="g6e.4xlarge"
KEY_NAME="deadline-ami-build"
PROFILE="deadline-worker-profile"
SUBNET_ID="CHANGE_ME"               # Public subnet in us-west-2
SG_ID="CHANGE_ME"                   # Security group: SSH from admin IP only
VOLUME_SIZE=100                      # GB root volume (Houdini + NVIDIA + Deadline)

INSTANCE_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --iam-instance-profile Name="$PROFILE" \
    --subnet-id "$SUBNET_ID" \
    --security-group-ids "$SG_ID" \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${VOLUME_SIZE},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=deadline-ami-build},{Key=Purpose,Value=ami-build}]" \
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
echo "  Public IP   : $PUBLIC_IP"
echo ""
echo "Next steps:"
echo "  1. Copy build scripts to instance:"
echo "     scp -i ~/.ssh/${KEY_NAME}.pem -r ../ami ubuntu@${PUBLIC_IP}:/tmp/"
echo "  2. SSH in:"
echo "     ssh -i ~/.ssh/${KEY_NAME}.pem ubuntu@${PUBLIC_IP}"
echo "  3. Run the build:"
echo "     sudo bash /tmp/ami/build.sh --repo-ip <ZT_IP> --s3-bucket <BUCKET> --houdini-build <BUILD> --b2-bucket <B2_BUCKET>"
