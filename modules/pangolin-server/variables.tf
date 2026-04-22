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

variable "region" {
  description = "AWS region to deploy into (e.g. 'eu-west-2')."
  type        = string
  default     = "eu-west-2"
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
  description = "Name of the AWS EC2 key pair to use for SSH access. Leave empty to disable SSH entirely."
  type        = string
  default     = ""
}

variable "ssh_allowed_cidrs" {
  description = "Your public IP as a /32 CIDR (e.g. \"1.2.3.4/32\"). SSH access is restricted to this address only. Leave empty to disable SSH entirely."
  type        = list(string)
  default     = []
}

variable "user_data_template" {
  description = "Path to a custom cloud-init bash script template. Defaults to the bundled pangolin_init.sh. The template receives: owner_email, pangolin_server_secret, pangolin_device, pangolin_custom_domain."
  type        = string
  default     = ""
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the parent domain (e.g. the zone for 'example.com'). Must be set together with custom_domain. Leave empty to use the automatic sslip.io domain."
  type        = string
  default     = ""
}

variable "custom_domain" {
  description = "Fully-qualified domain for the Pangolin dashboard (e.g. 'pangolin.example.com'). When set, two Route53 A records are created: one for this name and a wildcard for the parent zone (*.example.com) covering resource tunnels. Must be set together with hosted_zone_id."
  type        = string
  default     = ""

  validation {
    condition     = var.custom_domain == "" || can(regex("^[^.]+\\.[^.]+\\..+$", var.custom_domain))
    error_message = "custom_domain must be a subdomain with at least two parent labels, e.g. 'pangolin.example.com'."
  }
}
