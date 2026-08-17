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

AVAILABLE=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
)

[[ "$AVAILABLE" == "True" ]] \
  && pass "CouchbaseCluster Available" \
  || fail "Available=${AVAILABLE}"

DATA_DESIRED=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq -r '
        .spec.servers[]
        | select(.name == "data")
        | .size
      '
)

[[ "$DATA_DESIRED" -eq 3 ]] \
  && pass "Desired Data size=3" \
  || fail "Desired Data=${DATA_DESIRED}"

DATA_PODS=$(
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_data=enabled" \
    -o json \
  | jq '[
      .items[]
      | select(.status.phase == "Running")
    ] | length'
)

[[ "$DATA_PODS" -eq 3 ]] \
  && pass "Kubernetes tiene 3 Data Pods" \
  || fail "Data Pods=${DATA_PODS}"

UNHEALTHY=$(
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '[
        .nodes[]
        | select(
            .status != "healthy"
            or .clusterMembership != "active"
          )
      ]
      | length'
)

[[ "$UNHEALTHY" -eq 0 ]] \
  && pass "Couchbase nodes healthy/active" \
  || fail "Unhealthy=${UNHEALTHY}"

REBALANCE=$(
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/rebalanceProgress \
    | jq -r '.status'
)

[[ "$REBALANCE" == "none" ]] \
  && pass "No hay rebalance activo" \
  || fail "rebalance=${REBALANCE}"

BUCKET_DESIRED_MIB=$(
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.spec.memoryQuota}' \
  | sed 's/Mi$//'
)

DATA_NODES=$(
  curl -s \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq '[
      .nodes[]
      | select(.services | index("kv"))
    ] | length'
)

EXPECTED_BUCKET_TOTAL_MIB=$((BUCKET_DESIRED_MIB * DATA_NODES))

ACTUAL_BUCKET_TOTAL_MIB=$(
  curl -s \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
  | jq -r '.quota.ram / 1024 / 1024 | floor'
)

if [[ "$ACTUAL_BUCKET_TOTAL_MIB" -eq "$EXPECTED_BUCKET_TOTAL_MIB" ]]; then
  pass "lab-bucket quota total=${ACTUAL_BUCKET_TOTAL_MIB}MiB"
else
  fail "quota=${ACTUAL_BUCKET_TOTAL_MIB}MiB expected=${EXPECTED_BUCKET_TOTAL_MIB}MiB"
fi

BOUND_PVC=$(
  kubectl get pvc -n "$CB_NAMESPACE" \
    -o json \
    | jq '[
        .items[]
        | select(.status.phase == "Bound")
      ]
      | length'
)

[[ "$BOUND_PVC" -ge 4 ]] \
  && pass "PVCs principales Bound" \
  || fail "Bound PVC=${BOUND_PVC}"

if grep -q 'persisted before pod loss' \
    "${ROOT_DIR}/outputs/recovery-proof.json"; then
  pass "Documento recovery::proof sobrevivió"
else
  fail "No se confirmó recovery::proof"
fi

[[ -s "${ROOT_DIR}/reports/reconciliation-matrix.md" ]] \
  && pass "Matriz de reconciliación generada" \
  || fail "Falta matriz"

[[ -s "${ROOT_DIR}/outputs/troubleshooting-scheduler.txt" ]] \
  && pass "Evidencia de troubleshooting generada" \
  || fail "Falta evidencia troubleshooting"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]
