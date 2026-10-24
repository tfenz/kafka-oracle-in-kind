# Shared settings for scripts/*.sh — override any value via environment variables.

CLUSTER_NAME="${CLUSTER_NAME:-kafka-oracle}"

STRIMZI_VERSION="${STRIMZI_VERSION:-1.3.0}"
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
KAFKA_CLUSTER="${KAFKA_CLUSTER:-cdc-cluster}"

ORACLE_NAMESPACE="${ORACLE_NAMESPACE:-oracle}"
ORACLE_DEFAULT_IMAGE="container-registry.oracle.com/database/enterprise:19.3.0.0"
ORACLE_IMAGE="${ORACLE_IMAGE:-${ORACLE_DEFAULT_IMAGE}}"
ORACLE_REGISTRY="${ORACLE_IMAGE%%/*}"
ORACLE_PWD="${ORACLE_PWD:-OraclePwd_123}"
DEMO_PWD="${DEMO_PWD:-demo}"

# kind talks to podman when docker is not available
if ! command -v docker >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
  export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
fi
CONTAINER_CLI="${KIND_EXPERIMENTAL_PROVIDER:-docker}"

KUBE_CONTEXT="kind-${CLUSTER_NAME}"
KUBECTL=(kubectl --context "${KUBE_CONTEXT}")

log()  { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

require() {
  for bin in "$@"; do
    command -v "${bin}" >/dev/null 2>&1 || die "'${bin}' is required but not installed"
  done
}

# `kind get clusters` is broken with podman >= 6 (Go template on .Labels), so query the node container directly.
cluster_exists() {
  [[ -n "$("${CONTAINER_CLI}" ps -a --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format '{{.Names}}')" ]]
}
