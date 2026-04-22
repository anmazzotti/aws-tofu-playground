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

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      owner = var.owner
      Name  = "${var.owner}_pangolin"
    }
  }
}

module "pangolin_server" {
  source = "./modules/pangolin-server"

  region                 = var.region
  owner                  = var.owner
  owner_email            = var.owner_email
  pangolin_server_secret = var.pangolin_server_secret
  key_name               = var.key_name
  ssh_allowed_cidrs      = var.ssh_allowed_cidrs
}
