#!/usr/bin/env bash
# Spins up a Kind cluster with Strimzi, single-node Kafka, AKHQ and Oracle 19c.
#
# Usage: scripts/up.sh [--skip-oracle] [--no-wait]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"

SKIP_ORACLE=false
WAIT=true
for arg in "$@"; do
  case "${arg}" in
    --skip-oracle) SKIP_ORACLE=true ;;
    --no-wait)     WAIT=false ;;
    -h|--help)     sed -n '2,5p' "$0"; exit 0 ;;
    *)             die "unknown argument: ${arg}" ;;
  esac
done

require kind kubectl curl "${CONTAINER_CLI}"

create_cluster() {
  if cluster_exists; then
    log "Kind cluster '${CLUSTER_NAME}' already exists"
    kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
  else
    log "Creating Kind cluster '${CLUSTER_NAME}' (provider: ${CONTAINER_CLI})"
    kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/kind/cluster.yaml" --wait 120s
  fi
}

install_strimzi() {
  log "Installing Strimzi ${STRIMZI_VERSION} into namespace '${KAFKA_NAMESPACE}'"
  "${KUBECTL[@]}" create namespace "${KAFKA_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  curl -fsSL "https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI_VERSION}/strimzi-cluster-operator-${STRIMZI_VERSION}.yaml" \
    | sed "s/namespace: myproject/namespace: ${KAFKA_NAMESPACE}/" \
    | "${KUBECTL[@]}" apply --server-side --force-conflicts -n "${KAFKA_NAMESPACE}" -f - >/dev/null
  "${KUBECTL[@]}" -n "${KAFKA_NAMESPACE}" rollout status deployment/strimzi-cluster-operator --timeout=300s
}

deploy_kafka() {
  log "Deploying Kafka cluster '${KAFKA_CLUSTER}'"
  "${KUBECTL[@]}" -n "${KAFKA_NAMESPACE}" apply -f "${ROOT_DIR}/k8s/kafka/kafka.yaml"
}

deploy_akhq() {
  log "Deploying AKHQ"
  "${KUBECTL[@]}" -n "${KAFKA_NAMESPACE}" apply -f "${ROOT_DIR}/k8s/akhq/akhq.yaml"
}

# Makes the Oracle image available to the cluster: either load a locally pulled image
# into the Kind node, or create a pull secret so the node pulls it from the registry.
provide_oracle_image() {
  "${KUBECTL[@]}" create namespace "${ORACLE_NAMESPACE}" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -

  local node="${CLUSTER_NAME}-control-plane"
  if "${CONTAINER_CLI}" exec "${node}" crictl inspecti "${ORACLE_IMAGE}" >/dev/null 2>&1; then
    log "Oracle image already present on Kind node"
  elif "${CONTAINER_CLI}" image inspect "${ORACLE_IMAGE}" >/dev/null 2>&1; then
    log "Loading local image ${ORACLE_IMAGE} into Kind (this takes a few minutes)"
    local archive
    archive="$(mktemp --suffix=.tar)"
    if ! { "${CONTAINER_CLI}" save -o "${archive}" "${ORACLE_IMAGE}" \
           && kind load image-archive "${archive}" --name "${CLUSTER_NAME}"; }; then
      rm -f "${archive}"
      die "failed to load ${ORACLE_IMAGE} into Kind"
    fi
    rm -f "${archive}"
  elif [[ -n "${ORACLE_REGISTRY_USER:-}" && -n "${ORACLE_REGISTRY_TOKEN:-}" ]]; then
    log "Creating image pull secret for ${ORACLE_REGISTRY}"
    "${KUBECTL[@]}" -n "${ORACLE_NAMESPACE}" create secret docker-registry oracle-registry \
      --docker-server="${ORACLE_REGISTRY}" \
      --docker-username="${ORACLE_REGISTRY_USER}" \
      --docker-password="${ORACLE_REGISTRY_TOKEN}" \
      --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  else
    die "Oracle image '${ORACLE_IMAGE}' not available. Either
    - '${CONTAINER_CLI} login ${ORACLE_REGISTRY}' and '${CONTAINER_CLI} pull ${ORACLE_IMAGE}', or
    - export ORACLE_REGISTRY_USER / ORACLE_REGISTRY_TOKEN (Oracle SSO user + registry auth token).
    Re-run with --skip-oracle to deploy Kafka only."
  fi
}

deploy_oracle() {
  provide_oracle_image

  log "Deploying Oracle (${ORACLE_IMAGE}) into namespace '${ORACLE_NAMESPACE}'"
  "${KUBECTL[@]}" -n "${ORACLE_NAMESPACE}" create secret generic oracle-credentials \
    --from-literal=ORACLE_PWD="${ORACLE_PWD}" \
    --from-literal=DEMO_PWD="${DEMO_PWD}" \
    --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
  "${KUBECTL[@]}" kustomize "${ROOT_DIR}/k8s/oracle" \
    | sed "s#image: ${ORACLE_DEFAULT_IMAGE}#image: ${ORACLE_IMAGE}#" \
    | "${KUBECTL[@]}" apply -f -
}

wait_for_kafka() {
  log "Waiting for Kafka cluster '${KAFKA_CLUSTER}' to become ready"
  "${KUBECTL[@]}" -n "${KAFKA_NAMESPACE}" wait "kafka/${KAFKA_CLUSTER}" --for=condition=Ready --timeout=600s
}

wait_for_oracle() {
  log "Waiting for Oracle to become ready (first start creates the database: ~15-30 min)"
  log "  follow progress with: kubectl --context ${KUBE_CONTEXT} -n ${ORACLE_NAMESPACE} logs -f oracle-0"
  until "${KUBECTL[@]}" -n "${ORACLE_NAMESPACE}" get pod oracle-0 >/dev/null 2>&1; do sleep 5; done
  "${KUBECTL[@]}" -n "${ORACLE_NAMESPACE}" wait pod/oracle-0 --for=condition=Ready --timeout=3600s
}

create_cluster
install_strimzi
deploy_kafka
deploy_akhq
[[ "${SKIP_ORACLE}" == true ]] || deploy_oracle

if [[ "${WAIT}" == true ]]; then
  wait_for_kafka
  "${KUBECTL[@]}" -n "${KAFKA_NAMESPACE}" rollout status deployment/akhq --timeout=300s
  [[ "${SKIP_ORACLE}" == true ]] || wait_for_oracle
fi

cat <<EOF

$(log "Done")
  kubectl context : ${KUBE_CONTEXT}
  Kafka (in-cluster): ${KAFKA_CLUSTER}-kafka-bootstrap.${KAFKA_NAMESPACE}.svc:9092
  Kafka (host)      : 127.0.0.1:9092
  AKHQ             : http://127.0.0.1:8080 (after running the port-forward below)
  kubectl --context ${KUBE_CONTEXT} -n ${KAFKA_NAMESPACE} port-forward --address 127.0.0.1 svc/akhq 8080:8080
EOF
if [[ "${SKIP_ORACLE}" != true ]]; then
cat <<EOF
  Oracle (in-cluster): oracle.${ORACLE_NAMESPACE}.svc:1521/ORCLPDB1  (CDB: ORCLCDB)
  Oracle (host)      : 127.0.0.1:1521/ORCLPDB1
  Users              : sys/system -> \$ORACLE_PWD, demo -> \$DEMO_PWD
  Redo/archive PVC   : ${ORACLE_NAMESPACE}/oracle-oradata
EOF
fi
