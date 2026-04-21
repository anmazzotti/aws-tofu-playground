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

# Imports existing AWS resources into the OpenTofu state.
# Usage: OWNER=yourname ./import_resources.sh

set -e

OWNER="${OWNER:?'OWNER env var is required (e.g. OWNER=yourname ./import_resources.sh)'}"

elastic_ip_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=$OWNER" --query "Addresses[0].AllocationId" --output text)
instance_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=$OWNER" --query "Addresses[0].InstanceId" --output text)
ip_association_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=$OWNER" --query "Addresses[0].AssociationId" --output text)

echo "Found EC2 instance $instance_id associated to Elastic IP $elastic_ip_id"

tofu import aws_instance.pangolin "$instance_id"
tofu import aws_eip.pangolin "$elastic_ip_id"
tofu import aws_eip_association.pangolin_ip_assoc "$ip_association_id"
