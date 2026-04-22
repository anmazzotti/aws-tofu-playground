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
resource "aws_eip" "pangolin" {
  domain = "vpc"
}

resource "aws_security_group" "allow_pangolin" {
  name        = "allow_pangolin_${var.owner}"
  description = "Allow Pangolin inbound traffic and all outbound traffic"

  ingress {
    description = "Allow all Pangolin HTTP (ACME web challenge)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all Pangolin HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all Pangolin HTTPS (HTTP/3 QUIC)"
    from_port   = 443
    to_port     = 443
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all Pangolin site tunnel"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all Pangolin client tunnel"
    from_port   = 21820
    to_port     = 21820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH is disabled by default. To enable, set ssh_allowed_cidrs to your public IP as a /32.
  dynamic "ingress" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? [1] : []
    content {
      description = "SSH access (restricted to allowed CIDRs)"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_allowed_cidrs
    }
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Route53 DNS records — only created when hosted_zone_id and custom_domain are both set.
# Creates two A records pointing to the Elastic IP:
#   <custom_domain>      → Pangolin dashboard
#   *.<parent_domain>    → Resource tunnel subdomains (e.g. myapp.example.com)
resource "aws_route53_record" "pangolin_dashboard" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = var.custom_domain
  type    = "A"
  ttl     = 60
  records = [aws_eip.pangolin.public_ip]
}

resource "aws_route53_record" "pangolin_wildcard" {
  count   = local.use_custom_domain ? 1 : 0
  zone_id = var.hosted_zone_id
  name    = "*.${local.pangolin_base_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_eip.pangolin.public_ip]
}
