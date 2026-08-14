#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

CB_NAMESPACE="${CB_NAMESPACE:-couchbase}"
CB_CLUSTER="${CB_CLUSTER:-cb-cs400}"

PASS=0
FAIL=0

pass() {
  echo "  ✅ PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  ❌ FAIL: $1"
  FAIL=$((FAIL + 1))
}

if [[ -z "${CB_USER:-}" || -z "${CB_PASS:-}" ]]; then
  echo "ERROR: CB_USER o CB_PASS no están definidos."
  exit 1
fi

CB_ADMIN_POD=$(
  kubectl get pods \
    -n "${CB_NAMESPACE}" \
    -l "couchbase_cluster=${CB_CLUSTER}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
)

if [[ -z "${CB_ADMIN_POD}" ]]; then
  echo "ERROR: No se encontró un Pod Couchbase en estado Running."
  exit 1
fi

cb_rest() {
  local endpoint="$1"

  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "${CB_NAMESPACE}" \
    "${CB_ADMIN_POD}" \
    -c couchbase-server \
    -- \
    curl --fail-with-body -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://127.0.0.1:8091${endpoint}"
}

check_bucket() {
  local bucket="$1"
  local expected_engine="$2"
  local expected_eviction="$3"

  local bucket_json
  local actual_engine
  local actual_eviction
  local items

  if bucket_json="$(cb_rest "/pools/default/buckets/${bucket}" 2>/dev/null)"; then
    pass "${bucket} existe"
  else
    fail "${bucket} no existe"
    return
  fi

  actual_engine=$(
    jq -r '.storageBackend // "unknown"' \
      <<< "$bucket_json"
  )

  actual_eviction=$(
    jq -r '.evictionPolicy // "unknown"' \
      <<< "$bucket_json"
  )

  items=$(
    jq '.basicStats.itemCount // 0' \
      <<< "$bucket_json"
  )

  if [[ "$actual_engine" == "$expected_engine" ]]; then
    pass "${bucket} usa ${expected_engine}"
  else
    fail "${bucket} usa ${actual_engine}; se esperaba ${expected_engine}"
  fi

  if [[ "$actual_eviction" == "$expected_eviction" ]]; then
    pass "${bucket} usa ${expected_eviction}"
  else
    fail "${bucket} usa ${actual_eviction}; se esperaba ${expected_eviction}"
  fi

  if [[ "$items" -gt 0 ]]; then
    pass "${bucket} contiene datos (${items})"
  else
    fail "${bucket} no contiene datos"
  fi
}

echo "================================================"
echo "VALIDACIÓN FINAL - LAB 2"
echo "================================================"
echo
echo "Pod administrativo: ${CB_ADMIN_POD}"
echo

# ------------------------------------------------------------
# CouchbaseCluster
# ------------------------------------------------------------

AVAILABLE=$(
  kubectl get couchbasecluster "${CB_CLUSTER}" \
    -n "${CB_NAMESPACE}" \
    -o json \
  | jq '
      [
        .status.conditions[]?
        | select(
            .type == "Available"
            and .status == "True"
          )
      ]
      | length
    '
)

if [[ "$AVAILABLE" -eq 1 ]]; then
  pass "CouchbaseCluster está Available"
else
  fail "CouchbaseCluster no está Available"
fi

# ------------------------------------------------------------
# Topología
# ------------------------------------------------------------

CLUSTER_JSON="$(cb_rest "/pools/default")"

HEALTHY_NODES=$(
  jq '
    [
      .nodes[]
      | select(.status == "healthy")
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)

if [[ "$HEALTHY_NODES" -eq 4 ]]; then
  pass "Los 4 nodos Couchbase están healthy"
else
  fail "Se encontraron ${HEALTHY_NODES} nodos healthy; se esperaban 4"
fi

REBALANCE_STATUS=$(
  jq -r '.rebalanceStatus' <<< "$CLUSTER_JSON"
)

if [[ "$REBALANCE_STATUS" == "none" ]]; then
  pass "No existe rebalance pendiente"
else
  fail "rebalanceStatus=${REBALANCE_STATUS}"
fi

DATA_NODES=$(
  jq '
    [
      .nodes[]
      | select(.services | index("kv"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)

if [[ "$DATA_NODES" -eq 2 ]]; then
  pass "Existen 2 nodos Data"
else
  fail "Se encontraron ${DATA_NODES} nodos Data; se esperaban 2"
fi

# ------------------------------------------------------------
# Buckets
# ------------------------------------------------------------

check_bucket \
  lab-couchstore \
  couchstore \
  valueOnly

check_bucket \
  lab-magma \
  magma \
  fullEviction

# ------------------------------------------------------------
# Evidencias de métricas
# ------------------------------------------------------------

METRIC_FILES=$(
  find "${ROOT_DIR}/metrics" \
    -type f \
    -name '*.json' \
  | wc -l \
  | tr -d ' '
)

if [[ "$METRIC_FILES" -ge 5 ]]; then
  pass "Se capturaron ${METRIC_FILES} snapshots de métricas"
else
  fail "Solo existen ${METRIC_FILES} snapshots; se esperaban al menos 5"
fi

# ------------------------------------------------------------
# Benchmark
# ------------------------------------------------------------

if [[ -s "${ROOT_DIR}/outputs/durability-benchmark.txt" ]]; then
  pass "Existe resultado del benchmark de durabilidad"
else
  fail "Falta durability-benchmark.txt o está vacío"
fi

# ------------------------------------------------------------
# Reporte
# ------------------------------------------------------------

if [[ -s "${ROOT_DIR}/outputs/final-report.txt" ]]; then
  pass "Existe reporte final"
else
  fail "Falta final-report.txt o está vacío"
fi

# ------------------------------------------------------------
# PVC
# ------------------------------------------------------------

BOUND_PVCS=$(
  kubectl get pvc \
    -n "${CB_NAMESPACE}" \
    -o json \
  | jq '
      [
        .items[]
        | select(.status.phase == "Bound")
      ]
      | length
    '
)

if [[ "$BOUND_PVCS" -ge 4 ]]; then
  pass "Existen ${BOUND_PVCS} PVC Bound"
else
  fail "Solo existen ${BOUND_PVCS} PVC Bound; se esperaban al menos 4"
fi

# ------------------------------------------------------------
# OOMKilled
# ------------------------------------------------------------

OOM_KILLED=$(
  kubectl get pods \
    -n "${CB_NAMESPACE}" \
    -o json \
  | jq '
      [
        .items[].status.containerStatuses[]?
        | select(
            .lastState.terminated.reason == "OOMKilled"
          )
      ]
      | length
    '
)

if [[ "$OOM_KILLED" -eq 0 ]]; then
  pass "No se produjo OOMKilled en los Pods"
else
  fail "Se detectaron ${OOM_KILLED} contenedores con OOMKilled"
fi

echo
echo "================================================"
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "================================================"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi