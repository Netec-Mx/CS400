#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

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

DATA_SIZE=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq -r '
      .spec.servers[]
      | select(.name == "data")
      | .size
    '
)

[[ "$DATA_SIZE" -eq 4 ]] \
  && pass "Data server class final = 4" \
  || fail "Data size=${DATA_SIZE}"

CLUSTER_JSON=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default
)

ACTUAL_DATA=$(
  echo "$CLUSTER_JSON" \
  | jq '[
      .nodes[]
      | select(.services | index("kv"))
    ] | length'
)

[[ "$ACTUAL_DATA" -eq 4 ]] \
  && pass "Couchbase tiene 4 Data nodes reales" \
  || fail "actual_data=${ACTUAL_DATA}"

UNHEALTHY=$(
  echo "$CLUSTER_JSON" \
  | jq '[
      .nodes[]
      | select(
          .status != "healthy"
          or .clusterMembership != "active"
        )
    ] | length'
)

[[ "$UNHEALTHY" -eq 0 ]] \
  && pass "Todos los nodos healthy/active" \
  || fail "unhealthy=${UNHEALTHY}"

REBALANCE=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/rebalanceProgress \
  | jq -r '.status // "unknown"'
)

[[ "$REBALANCE" == "none" ]] \
  && pass "No hay rebalance en curso" \
  || fail "rebalance=${REBALANCE}"

VB_COUNT=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${WORKLOAD_BUCKET}" \
  | jq '.vBucketServerMap.vBucketMap | length'
)

[[ "$VB_COUNT" -eq 1024 ]] \
  && pass "Bucket mantiene 1024 vBuckets" \
  || fail "vBuckets=${VB_COUNT}"

[[ -s "${ROOT_DIR}/metrics/workload-complete.jsonl" ]] \
  && pass "Workload log preservado" \
  || fail "Falta workload-complete.jsonl"

[[ -s "${ROOT_DIR}/outputs/swap-rebalance-monitor.txt" ]] \
  && pass "Evidencia SwapRebalance generada" \
  || fail "Falta swap-rebalance-monitor.txt"

[[ -f "${ROOT_DIR}/outputs/stop-rebalance-response.txt" ]] \
  && pass "Evidencia stopRebalance generada" \
  || fail "Falta stop-rebalance-response.txt"

RETRY_ENABLED=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/retryRebalance \
  | jq -r '.enabled'
)

[[ "$RETRY_ENABLED" == "false" ]] \
  && pass "Rebalance Retry nativo permanece deshabilitado" \
  || fail "retryRebalance enabled=${RETRY_ENABLED}"

PENDING_RETRY=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/pendingRetryRebalance \
  | jq -r '.retry_rebalance // "unknown"'
)

[[ "$PENDING_RETRY" == "not_pending" ]] \
  && pass "No existe Rebalance Retry pendiente" \
  || fail "pendingRetry=${PENDING_RETRY}"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]