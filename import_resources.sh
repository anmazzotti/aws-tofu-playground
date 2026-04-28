#!/usr/bin/env bash

set -e

elastic_ip_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].AllocationId" --output text)
instance_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].InstanceId" --output text)
ip_association_id=$(aws ec2 describe-addresses --filters "Name=tag:owner,Values=andrea" --query "Addresses[0].AssociationId" --output text)

echo "Found EC2 instance $instance_id associated to Elastic IP $elastic_ip_id"

tofu import aws_instance.pangolin_server $instance_id
tofu import aws_eip.pangolin_ip $elastic_ip_id
tofu import aws_eip_association.eip_assoc $ip_association_id
