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

SCENARIOS=$(
  find "${ROOT_DIR}/scenarios" \
    -name 'scenario-*.yaml' \
    -type f \
  | wc -l
)

[[ "$SCENARIOS" -eq 4 ]] \
  && pass "Cuatro escenarios documentados" \
  || fail "scenarios=${SCENARIOS}"

LEVELS=0

for W in 4 8 16 32; do
  [[ -s "${ROOT_DIR}/results/scenario-B-${W}.json" ]] \
    && LEVELS=$((LEVELS + 1))
done

[[ "$LEVELS" -eq 4 ]] \
  && pass "Cuatro niveles KV ejecutados" \
  || fail "levels=${LEVELS}"

INDEX_STATE=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT RAW state
      FROM system:indexes
      WHERE bucket_id="lab12-load"
        AND scope_id="workload"
        AND keyspace_id="items"
        AND name="idx_created_type_value"' \
  | jq -r '.results[0] // "missing"'
)

[[ "$INDEX_STATE" == "online" ]] \
  && pass "Secondary index online" \
  || fail "index=${INDEX_STATE}"

PRIMARY_AFTER=$(
  jq '[
      .. |
      objects |
      .["#operator"]? |
      select(
        type == "string"
        and contains("PrimaryScan")
      )
    ] | length' \
    "${ROOT_DIR}/results/scenario-D-explain-after.json"
)

[[ "$PRIMARY_AFTER" -eq 0 ]] \
  && pass "Plan D optimizado sin PrimaryScan" \
  || fail "PrimaryScan count=${PRIMARY_AFTER}"

FETCH_COVER=$(
  jq '[
      .. |
      objects |
      .["#operator"]? |
      select(. == "Fetch")
    ] | length' \
    "${ROOT_DIR}/results/scenario-C-covering.json"
)

[[ "$FETCH_COVER" -eq 0 ]] \
  && pass "Covering plan sin Fetch" \
  || fail "Fetch count=${FETCH_COVER}"

BUCKET_DESIRED_MIB=$(
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.spec.memoryQuota}' \
  | sed 's/Mi$//'
)

DATA_NODES=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq '[
      .nodes[]
      | select(.services | index("kv"))
    ] | length'
)

EXPECTED_BUCKET_TOTAL_MIB=$(
  echo $((BUCKET_DESIRED_MIB * DATA_NODES))
)

ACTUAL_BUCKET_TOTAL_MIB=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
  | jq -r '.quota.ram / 1024 / 1024 | floor'
)

[[ "$ACTUAL_BUCKET_TOTAL_MIB" -eq "$EXPECTED_BUCKET_TOTAL_MIB" ]] \
  && pass "Bucket quota total=${ACTUAL_BUCKET_TOTAL_MIB}MiB" \
  || fail "quota=${ACTUAL_BUCKET_TOTAL_MIB} expected=${EXPECTED_BUCKET_TOTAL_MIB}"

REBALANCE=$(
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/rebalanceProgress \
  | jq -r '.status'
)

[[ "$REBALANCE" == "none" ]] \
  && pass "Sin rebalance activo" \
  || fail "rebalance=${REBALANCE}"

[[ -s "${ROOT_DIR}/reports/comparison.md" ]] \
  && pass "Reporte comparativo generado" \
  || fail "Falta comparison.md"

[[ -s "${ROOT_DIR}/results/scenario-B-32-post-memory.json" ]] \
  && pass "Re-test 32 workers generado" \
  || fail "Falta scenario-B-32-post-memory.json"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]
