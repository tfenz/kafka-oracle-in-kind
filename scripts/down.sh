#!/usr/bin/env bash
# Deletes the Kind cluster (including Kafka and Oracle data).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"

require kind

if cluster_exists; then
  log "Deleting Kind cluster '${CLUSTER_NAME}'"
  kind delete cluster --name "${CLUSTER_NAME}"
else
  log "Kind cluster '${CLUSTER_NAME}' does not exist"
fi
