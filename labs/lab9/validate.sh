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

ZONES=$(
  kubectl get nodes -o json \
    | jq '[
        .items[].metadata.labels[
          "topology.kubernetes.io/zone"
        ]
      ]
      | unique
      | length'
)

[[ "$ZONES" -ge 3 ]] \
  && pass "EKS dispone de tres Availability Zones" \
  || fail "zones=${ZONES}"

SERVER_GROUPS=$(
  kubectl get couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    -o json \
  | jq '(.spec.serverGroups // []) | unique | length'
)

[[ "$SERVER_GROUPS" -eq 3 ]] \
  && pass "Cluster A declara tres Server Groups" \
  || fail "serverGroups=${SERVER_GROUPS}"

DATA_A=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq '[
      .nodes[]
      | select(.services | index("kv"))
    ] | length'
)

[[ "$DATA_A" -eq 3 ]] \
  && pass "Cluster A tiene tres Data Pods" \
  || fail "Data Pods A=${DATA_A}"

UNHEALTHY_A=$(
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

[[ "$UNHEALTHY_A" -eq 0 ]] \
  && pass "Cluster A healthy/active" \
  || fail "Cluster A unhealthy=${UNHEALTHY_A}"

VBUCKETS=$(
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab9-dr \
    | jq '.vBucketServerMap.vBucketMap | length'
)

[[ "$VBUCKETS" -eq 1024 ]] \
  && pass "lab9-dr mantiene 1024 vBuckets" \
  || fail "vBuckets=${VBUCKETS}"

XDCR_COUNT=$(
  kubectl get couchbasereplication \
    -n "$NS_A" \
    -o json \
    | jq '.items | length'
)

[[ "$XDCR_COUNT" -ge 3 ]] \
  && pass "Replicaciones A configuradas" \
  || fail "XDCR A resources=${XDCR_COUNT}"

FILTER_INTERNAL=$(
  grep 'internal sample hits' \
    "${ROOT_DIR}/outputs/xdcr-filter-validation.txt" \
    | awk -F: '{gsub(/ /,"",$2); print $2}'
)

[[ "$FILTER_INTERNAL" == "0/100" ]] \
  && pass "Filtro excluye internal::*" \
  || fail "internal hits=${FILTER_INTERNAL}"

[[ -s "${ROOT_DIR}/outputs/rto-dr-seconds.txt" ]] \
  && pass "RTO DR medido" \
  || fail "Falta RTO DR"

[[ -s "${ROOT_DIR}/outputs/rpo-result.txt" ]] \
  && pass "RPO experimental medido" \
  || fail "Falta RPO result"

[[ -s "${ROOT_DIR}/reports/runbook-dr.md" ]] \
  && pass "Runbook DR generado" \
  || fail "Falta runbook"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]
