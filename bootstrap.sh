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

# Day-zero bootstrap: provisions all AWS resources and creates the initial Pangolin
# admin account. Run this once on first deployment.
#
# Subsequent instance refreshes use import_resources.sh + tofu destroy/apply
# (see .github/workflows/weekly-refresh.yml or run manually).
#
# Usage:
#   ./bootstrap.sh
#
# Optional environment variables (prompted if not set):
#   PANGOLIN_ADMIN_EMAIL     Email for the initial Pangolin admin account
#   PANGOLIN_ADMIN_PASSWORD  Password for the initial Pangolin admin account

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

step()  { echo -e "\n${BOLD}==> $*${RESET}"; }
ok()    { echo -e "${GREEN}✓ $*${RESET}"; }
warn()  { echo -e "${YELLOW}⚠ $*${RESET}"; }
error() { echo -e "${RED}✗ $*${RESET}" >&2; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

missing=0
for cmd in tofu curl aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    error "$cmd not found in PATH"
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  error "AWS credentials not configured. Run 'aws configure' or export AWS_* env vars."
  exit 1
fi

if [ ! -f terraform.tfvars ]; then
  error "terraform.tfvars not found. Copy terraform.tfvars.example and fill in your values."
  exit 1
fi

ok "Prerequisites satisfied"

# ---------------------------------------------------------------------------
# Plan and apply
# ---------------------------------------------------------------------------
step "Initialising OpenTofu"
tofu init

step "Generating plan"
tofu plan -out=bootstrap.tfplan

echo ""
read -rp "$(echo -e "${BOLD}Apply this plan? [y/N]${RESET} ")" confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  echo "Aborted."
  rm -f bootstrap.tfplan
  exit 0
fi

step "Applying"
tofu apply bootstrap.tfplan
rm -f bootstrap.tfplan

# ---------------------------------------------------------------------------
# Retrieve Pangolin URL
# ---------------------------------------------------------------------------
PANGOLIN_URL=$(tofu output -raw pangolin_url)
step "Resources provisioned"
echo "  Dashboard: ${BOLD}${PANGOLIN_URL}${RESET}"
echo ""
echo "  The instance is now booting. cloud-init will install Docker and start"
echo "  the Pangolin stack (~3–5 minutes). You can follow progress via:"
echo ""
echo "    INSTANCE_ID=\$(tofu output -raw instance_id)"
echo "    aws ssm start-session --target \$INSTANCE_ID"
echo "    sudo tail -f /var/log/cloud-init-output.log"

# ---------------------------------------------------------------------------
# Admin account creation
# ---------------------------------------------------------------------------
step "Creating initial admin account"

if [ -z "${PANGOLIN_ADMIN_EMAIL:-}" ]; then
  read -rp "  Admin email: " PANGOLIN_ADMIN_EMAIL
fi

if [ -z "${PANGOLIN_ADMIN_PASSWORD:-}" ]; then
  read -rsp "  Admin password: " PANGOLIN_ADMIN_PASSWORD
  echo ""
fi

echo ""
echo "  Waiting for Pangolin API to become healthy (up to 10 minutes)..."

READY=false
for i in $(seq 1 120); do
  STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "${PANGOLIN_URL}/api/v1/" 2>/dev/null; echo)
  STATUS="${STATUS//[[:space:]]/}"
  [ -z "$STATUS" ] && STATUS="000"
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "404" ]; then
    READY=true
    ok "Pangolin API is up (attempt ${i})"
    break
  fi
  printf "  Attempt %d/120: HTTP %s — retrying in 5s...\r" "$i" "$STATUS"
  sleep 5
done
echo ""

if [ "$READY" != "true" ]; then
  warn "Pangolin did not respond within the timeout."
  warn "Complete account setup manually at: ${PANGOLIN_URL}"
  exit 0
fi

# Check if initial setup is already complete
SETUP_COMPLETE=$(curl -sk "${PANGOLIN_URL}/api/v1/auth/initial-setup-complete" \
  -H "X-CSRF-Token: x-csrf-protection" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('complete','false'))" 2>/dev/null || echo "false")

if [ "$SETUP_COMPLETE" = "True" ] || [ "$SETUP_COMPLETE" = "true" ]; then
  ok "Pangolin already has an admin account. Skipping setup."
else
  SETUP_TOKEN=$(tofu output -raw setup_token 2>/dev/null || echo "")
  if [ -z "$SETUP_TOKEN" ]; then
    warn "Could not retrieve setup token from tofu output."
    warn "Complete admin setup manually at: ${PANGOLIN_URL}"
  else
    HTTP_STATUS=$(curl -sk \
      -o /tmp/pangolin-signup.json \
      -w "%{http_code}" \
      -X PUT "${PANGOLIN_URL}/api/v1/auth/set-server-admin" \
      -H "Content-Type: application/json" \
      -H "X-CSRF-Token: x-csrf-protection" \
      -d "{\"email\": \"${PANGOLIN_ADMIN_EMAIL}\", \"password\": \"${PANGOLIN_ADMIN_PASSWORD}\", \"setupToken\": \"${SETUP_TOKEN}\"}")

    if [ "$HTTP_STATUS" = "200" ] || [ "$HTTP_STATUS" = "201" ]; then
      ok "Admin account created for ${PANGOLIN_ADMIN_EMAIL}"
    else
      warn "Setup returned HTTP ${HTTP_STATUS}. API response:"
      cat /tmp/pangolin-signup.json 2>/dev/null && echo ""
      warn "Complete admin setup manually at: ${PANGOLIN_URL}"
    fi
    rm -f /tmp/pangolin-signup.json
  fi
fi

# ---------------------------------------------------------------------------
# Next steps
# ---------------------------------------------------------------------------
step "Next steps"
cat <<EOF
  1. Open ${PANGOLIN_URL} and log in with ${PANGOLIN_ADMIN_EMAIL}
  2. Create a Site (Sites → New Site) — note the Site ID and Secret
  3. Create a Resource under the Site — target must be *.svc.cluster.local
  4. Install the Newt agent on your kind cluster (see README for Helm commands)
EOF
