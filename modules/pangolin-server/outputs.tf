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

output "instance_id" {
  description = "EC2 instance ID of the Pangolin server."
  value       = aws_instance.pangolin.id
}

output "elastic_ip" {
  description = "Elastic IP address of the Pangolin server."
  value       = aws_eip.pangolin.public_ip
}

output "pangolin_url" {
  description = "Pangolin dashboard URL."
  value       = "https://pangolin.${aws_eip.pangolin.public_ip}.sslip.io"
}
