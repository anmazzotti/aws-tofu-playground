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

variable "owner" {
  description = "Your name. Used for resource tags and identification (e.g. 'alice')."
  type        = string
}

variable "owner_email" {
  description = "Email address used for Let's Encrypt certificate notifications."
  type        = string
}

variable "pangolin_server_secret" {
  description = "Server-side secret for Pangolin. Use a strong random value."
  type        = string
  sensitive   = true
}

variable "key_name" {
  description = "Name of the AWS EC2 key pair to use for SSH access. Leave empty if using AWS SSM Session Manager (recommended per EDR 009)."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed for SSH access. Leave empty to disable public SSH entirely and use AWS SSM Session Manager instead (mandatory per EDR 009: no public SSH)."
  type        = list(string)
  default     = []
}
