#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Cargar lab.env únicamente si existe.
if [[ -f "${ROOT_DIR}/lab.env" ]]; then
  source "${ROOT_DIR}/lab.env"
fi

# Validar variables necesarias.
: "${CB_USER:?ERROR: CB_USER no está definido}"
: "${CB_PASS:?ERROR: CB_PASS no está definido}"

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

query() {
  local statement="$1"

  curl --fail-with-body -sS \
    -u "${CB_USER}:${CB_PASS}" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode "statement=${statement}"
}

echo "================================================"
echo "VALIDACIÓN FINAL - LAB 3"
echo "================================================"

# ------------------------------------------------------------
# Validar cantidad de documentos
# ------------------------------------------------------------

COUNT_RESPONSE=$(
  query '
    SELECT RAW COUNT(*)
    FROM `travel-sample`.inventory.route_lab3;
  '
)

COUNT=$(
  jq -r '.results[0] // 0' \
    <<< "$COUNT_RESPONSE"
)

if [[ "$COUNT" -ge 500000 ]]; then
  pass "route_lab3 tiene ${COUNT} documentos"
else
  fail "route_lab3 tiene ${COUNT} documentos; se esperaban al menos 500000"
fi

# ------------------------------------------------------------
# Validar índices
# ------------------------------------------------------------

for idx in \
  idx_route_lab3_primary \
  idx_route_lab3_airline_price \
  idx_route_lab3_stops_seats
do

  FOUND_RESPONSE=$(
    query "
      SELECT RAW COUNT(*)
      FROM system:indexes
      WHERE name = \"${idx}\";
    "
  )

  FOUND=$(
    jq -r '.results[0] // 0' \
      <<< "$FOUND_RESPONSE"
  )

  if [[ "$FOUND" -gt 0 ]]; then
    pass "Índice ${idx} existe"
  else
    fail "Índice ${idx} falta"
  fi
done

# ------------------------------------------------------------
# Validar plan optimizado Q1
# ------------------------------------------------------------

PLAN_FILE="${ROOT_DIR}/plans/plan_q1_after.json"

if [[ -s "$PLAN_FILE" ]]; then
  if grep -q "idx_route_lab3_airline_price" "$PLAN_FILE"; then
    pass "Plan Q1 usa idx_route_lab3_airline_price"
  else
    fail "Plan Q1 no muestra idx_route_lab3_airline_price"
  fi
else
  fail "No existe plan_q1_after.json o está vacío"
fi

# ------------------------------------------------------------
# Validar PROFILE
# ------------------------------------------------------------

if [[ -s "${ROOT_DIR}/profiles/profile_q1.json" ]]; then
  pass "PROFILE Q1 existe"
else
  fail "PROFILE Q1 falta"
fi

if [[ -s "${ROOT_DIR}/profiles/profile_q2.json" ]]; then
  pass "PROFILE Q2 existe"
else
  fail "PROFILE Q2 falta"
fi

# ------------------------------------------------------------
# Validar benchmark concurrente
# ------------------------------------------------------------

CONCURRENT_FILE="${ROOT_DIR}/benchmarks/concurrent-results.json"

if [[ -s "$CONCURRENT_FILE" ]]; then

  SUCCESS=$(
    jq -r '.success // 0' \
      "$CONCURRENT_FILE"
  )

  FAILED=$(
    jq -r '.failed // 0' \
      "$CONCURRENT_FILE"
  )

  pass "Benchmark concurrente existe (${SUCCESS} exitosas, ${FAILED} fallidas)"

else
  fail "Benchmark concurrente falta o está vacío"
fi

# ------------------------------------------------------------
# Validar prepared statement
# ------------------------------------------------------------

PREPARED_RESPONSE=$(
  query '
    SELECT RAW COUNT(*)
    FROM system:prepareds
    WHERE name LIKE "%stmt_routes_by_airline%";
  '
)

PREPARED=$(
  jq -r '.results[0] // 0' \
    <<< "$PREPARED_RESPONSE"
)

if [[ "$PREPARED" -gt 0 ]]; then
  pass "Prepared stmt_routes_by_airline está presente"
else
  fail "Prepared stmt_routes_by_airline está ausente"
fi

# ------------------------------------------------------------
# Resultado final
# ------------------------------------------------------------

echo
echo "================================================"
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "================================================"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi