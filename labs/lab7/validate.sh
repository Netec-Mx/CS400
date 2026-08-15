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

DOCS=$(
  jq '[.buckets[].documents] | add' \
    "${ROOT_DIR}/models/sizing-inputs.json"
)

OPS=$(
  jq '[.buckets[] | .peak_gets_per_sec + .peak_sets_per_sec] | add' \
    "${ROOT_DIR}/models/sizing-inputs.json"
)

[[ "$DOCS" -eq 260000000 ]] \
  && pass "260M documentos modelados" \
  || fail "documents=${DOCS}"

[[ "$OPS" -eq 70500 ]] \
  && pass "70,500 ops/s modelados" \
  || fail "ops=${OPS}"

[[ -s "${ROOT_DIR}/outputs/data-ram-sizing.json" ]] \
  && pass "Sizing RAM generado" \
  || fail "Falta RAM sizing"

[[ -s "${ROOT_DIR}/outputs/data-disk-sizing.json" ]] \
  && pass "Modelo disk generado" \
  || fail "Falta disk sizing"

RAM_HEADROOM=$(
  jq -r '.total_ram_with_headroom_gib' \
    "${ROOT_DIR}/outputs/data-ram-sizing.json"
)

python - "$RAM_HEADROOM" << 'PY' \
  && pass "RAM con headroom es numérica y positiva" \
  || fail "RAM con headroom inválida"
import sys
value = float(sys.argv[1])
raise SystemExit(0 if value > 0 else 1)
PY

SCENARIOS=$(
  jq 'keys | length' \
    "${ROOT_DIR}/models/mds-scenarios.json"
)

[[ "$SCENARIOS" -eq 3 ]] \
  && pass "Tres escenarios MDS definidos" \
  || fail "scenarios=${SCENARIOS}"

ZONES=$(
  kubectl get nodes -o json \
  | jq '[
      .items[].metadata.labels["topology.kubernetes.io/zone"]
    ] | unique | length'
)

[[ "$ZONES" -eq 3 ]] \
  && pass "EKS opera en tres Availability Zones" \
  || fail "zones=${ZONES}"

SERVER_GROUPS=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '.spec.serverGroups | unique | length'
)

[[ "$SERVER_GROUPS" -eq 3 ]] \
  && pass "Operator declara tres Server Groups" \
  || fail "serverGroups=${SERVER_GROUPS}"

DATA_QUERY_SIZE=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq -r '
      .spec.servers[]
      | select(.name == "data-query")
      | .size
    '
)

[[ "$DATA_QUERY_SIZE" -eq 3 ]] \
  && pass "Tres Data + Query permiten distribución zonal" \
  || fail "data-query size=${DATA_QUERY_SIZE}"

[[ -s "${ROOT_DIR}/outputs/capacity-simulation.txt" ]] \
  && pass "Simulación generada" \
  || fail "Falta simulación"

[[ -s "${ROOT_DIR}/metrics/travel-sample-stats.json" ]] \
  && pass "Métricas reales capturadas" \
  || fail "Faltan métricas"

[[ -s "${ROOT_DIR}/outputs/couchbase-server-groups.json" ]] \
  && pass "Server Groups efectivos capturados" \
  || fail "Falta evidencia de Server Groups"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]