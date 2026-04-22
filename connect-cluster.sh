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

# Connects a local kind cluster to the Pangolin server by installing the
# Newt agent via Helm. Run this after bootstrap.sh and after creating a
# Site + Resource in the Pangolin dashboard.
#
# Usage:
#   ./connect-cluster.sh
#
# Optional environment variables (prompted if not set):
#   PANGOLIN_URL     Pangolin dashboard URL (e.g. https://pangolin.1.2.3.4.sslip.io)
#   NEWT_SITE_ID     Site ID from the Pangolin dashboard
#   NEWT_SITE_SECRET Site secret from the Pangolin dashboard

set -euo pipefail

BOLD='\033[1m'
GREEN='\033[0;32m'
RESET='\033[0m'

step() { echo -e "\n${BOLD}==> $*${RESET}"; }
ok()   { echo -e "${GREEN}✓ $*${RESET}"; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
step "Checking prerequisites"

missing=0
for cmd in kubectl helm; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "✗ $cmd not found in PATH" >&2
    missing=1
  fi
done
[ "$missing" -eq 0 ] || exit 1

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "✗ kubectl cannot reach a cluster. Check your kubeconfig." >&2
  exit 1
fi

ok "Prerequisites satisfied"

# ---------------------------------------------------------------------------
# Gather inputs
# ---------------------------------------------------------------------------
step "Pangolin connection details"

if [ -z "${PANGOLIN_URL:-}" ]; then
  # Try to read from tofu output if we are in the repo root and state exists
  if command -v tofu >/dev/null 2>&1 && tofu output -raw pangolin_url >/dev/null 2>&1; then
    PANGOLIN_URL=$(tofu output -raw pangolin_url)
    echo "  Detected from tofu output: $PANGOLIN_URL"
  else
    read -rp "  Pangolin URL (e.g. https://pangolin.1.2.3.4.sslip.io): " PANGOLIN_URL
  fi
fi

if [ -z "${NEWT_SITE_ID:-}" ]; then
  read -rp "  Site ID (from Pangolin dashboard → Sites): " NEWT_SITE_ID
fi

if [ -z "${NEWT_SITE_SECRET:-}" ]; then
  read -rsp "  Site secret: " NEWT_SITE_SECRET
  echo ""
fi

# ---------------------------------------------------------------------------
# Install Newt
# ---------------------------------------------------------------------------
step "Installing Newt Helm chart"

helm repo add pangolin https://charts.pangolin.net --force-update
helm repo update pangolin

kubectl create namespace newt-system --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic newt-site \
  --namespace newt-system \
  --from-literal=id="$NEWT_SITE_ID" \
  --from-literal=secret="$NEWT_SITE_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install newt pangolin/newt \
  --namespace newt-system \
  --set pangolin.endpoint="$PANGOLIN_URL" \
  --set site.existingSecret=newt-site \
  --wait

ok "Newt installed in namespace newt-system"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
step "Verifying Newt pod"
kubectl rollout status deployment/newt --namespace newt-system --timeout=120s
ok "Newt is running"

echo ""
echo "  The cluster is now connected to ${BOLD}${PANGOLIN_URL}${RESET}."
echo "  Resources configured in the Pangolin dashboard are immediately reachable."
