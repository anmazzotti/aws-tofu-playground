#!/usr/bin/env bash

# Copyright © 2026 SUSE LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Imports all existing AWS resources into a fresh OpenTofu state.
#
# This script is designed for a stateless workflow where no .tfstate file is
# persisted between runs. A GitHub Action runs this every Sunday before
# destroying and recreating the EC2 instance (see .github/workflows/weekly-refresh.yml).
#
# Usage: OWNER=yourname ./import_resources.sh

set -e

OWNER="${OWNER:?'OWNER env var is required (e.g. OWNER=yourname ./import_resources.sh)'}"

echo "Discovering resources for owner=$OWNER ..."

elastic_ip_id=$(aws ec2 describe-addresses \
  --filters "Name=tag:owner,Values=$OWNER" \
  --query "Addresses[0].AllocationId" --output text)

instance_id=$(aws ec2 describe-addresses \
  --filters "Name=tag:owner,Values=$OWNER" \
  --query "Addresses[0].InstanceId" --output text)

ip_association_id=$(aws ec2 describe-addresses \
  --filters "Name=tag:owner,Values=$OWNER" \
  --query "Addresses[0].AssociationId" --output text)

ebs_volume_id=$(aws ec2 describe-volumes \
  --filters "Name=tag:owner,Values=$OWNER" \
  --query "Volumes[0].VolumeId" --output text)

security_group_id=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=allow_pangolin" \
  --query "SecurityGroups[0].GroupId" --output text)

dlm_policy_id=$(aws dlm get-lifecycle-policies \
  --query "Policies[?Description=='Pangolin Volume DLM lifecycle policy'].PolicyId | [0]" \
  --output text)

echo "EC2 instance:    $instance_id"
echo "Elastic IP:      $elastic_ip_id"
echo "EIP association: $ip_association_id"
echo "EBS volume:      $ebs_volume_id"
echo "Security group:  $security_group_id"
echo "DLM policy:      $dlm_policy_id"

tofu import module.pangolin_server.aws_instance.pangolin              "$instance_id"
tofu import module.pangolin_server.aws_eip.pangolin                   "$elastic_ip_id"
tofu import module.pangolin_server.aws_eip_association.pangolin_ip_assoc "$ip_association_id"
tofu import module.pangolin_server.aws_ebs_volume.pangolin             "$ebs_volume_id"
tofu import module.pangolin_server.aws_volume_attachment.pangolin_ebs_att \
  "${ebs_volume_id}:${instance_id}:/dev/sdh"
tofu import module.pangolin_server.aws_security_group.allow_pangolin   "$security_group_id"
tofu import module.pangolin_server.aws_iam_role.dlm_lifecycle_role     "dlm-lifecycle-role"
tofu import module.pangolin_server.aws_iam_role_policy.dlm_lifecycle   "dlm-lifecycle-role:dlm-lifecycle-policy"
tofu import module.pangolin_server.aws_dlm_lifecycle_policy.pangolin_snapshots "$dlm_policy_id"
