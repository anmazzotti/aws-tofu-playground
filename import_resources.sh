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

# This script dumps some etcd info.
# Mainly this is used to detect and debug conflicts managing resources.
 
set -e

elastic_ip_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].AllocationId" --output text)
instance_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].InstanceId" --output text)
ip_association_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].AssociationId" --output text)

echo "Found EC2 instance $instance_id associated to Elastic IP $elastic_ip_id"

tofu import aws_instance.pangolin_server $instance_id
tofu import aws_eip.pangolin_ip $elastic_ip_id
tofu import aws_eip_association.eip_assoc $ip_association_id
