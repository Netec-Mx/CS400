#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

PASS=0
FAIL=0

pass() {
  echo "✅ PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "❌ FAIL: $1"
  FAIL=$((FAIL + 1))
}

query() {
  local statement="$1"

  curl -sS \
    -u "${CB_USER}:${CB_PASS}" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode "statement=${statement}"
}

echo "================================================"
echo "VALIDACIÓN FINAL - LAB 4"
echo "================================================"

# ------------------------------------------------------------
# Validar nodos Index
# ------------------------------------------------------------

INDEX_NODES=$(
  curl -sS \
    -u "${CB_USER}:${CB_PASS}" \
    http://localhost:8091/pools/default \
  | jq '[.nodes[] | select(.services | index("index"))] | length'
)

if [[ "$INDEX_NODES" -eq 2 ]]; then
  pass "2 nodos Index"
else
  fail "Se esperaban 2 nodos Index y se encontraron ${INDEX_NODES}"
fi

# ------------------------------------------------------------
# Validar documentos
# ------------------------------------------------------------

DOC_RESPONSE=$(
  query '
    SELECT RAW COUNT(*)
    FROM `travel-sample`.inventory.booking_lab4;
  '
)

DOC_STATUS=$(jq -r '.status // "unknown"' <<< "$DOC_RESPONSE")

if [[ "$DOC_STATUS" != "success" ]]; then
  fail "No fue posible contar documentos"
  echo "$DOC_RESPONSE" | jq '{status,errors}'
  DOCS=0
else
  DOCS=$(jq -r '.results[0] // 0' <<< "$DOC_RESPONSE")

  if [[ "$DOCS" -ge 200000 ]]; then
    pass "200 000 documentos"
  else
    fail "Sólo ${DOCS} documentos"
  fi
fi

# ------------------------------------------------------------
# Validar índices requeridos
# ------------------------------------------------------------

INDEXES=(
  idx_booking_route_date
  idx_booking_status_price
  idx_cancelled_created_customer
  idx_booking_route_covering
  idx_booking_origin_status_partitioned
  idx_booking_customer_ha
  idx_booking_cabin_price
  idx_booking_flight
  idx_booking_date_origin
)

for idx in "${INDEXES[@]}"; do

  RESPONSE=$(
    query "
      SELECT RAW COUNT(*)
      FROM system:indexes AS i
      WHERE i.name = \"${idx}\"
        AND i.keyspace_id = \"booking_lab4\"
        AND i.state = \"online\";
    "
  )

  STATUS=$(jq -r '.status // "unknown"' <<< "$RESPONSE")

  if [[ "$STATUS" != "success" ]]; then
    fail "Error consultando ${idx}"
    echo "$RESPONSE" | jq '{status,errors}'
    continue
  fi

  COUNT=$(jq -r '.results[0] // 0' <<< "$RESPONSE")

  if [[ "$COUNT" -gt 0 ]]; then
    pass "${idx} online"
  else
    fail "${idx} no está online"
  fi
done

# ------------------------------------------------------------
# Validar configuración HA del índice
# ------------------------------------------------------------

REPLICA_RESPONSE=$(
  query '
    SELECT RAW i.metadata.num_replica
    FROM system:indexes AS i
    WHERE i.name = "idx_booking_customer_ha"
      AND i.keyspace_id = "booking_lab4"
      AND i.state = "online"
    LIMIT 1;
  '
)

REPLICA_STATUS=$(jq -r '.status // "unknown"' <<< "$REPLICA_RESPONSE")

if [[ "$REPLICA_STATUS" != "success" ]]; then

  fail "No fue posible validar la configuración HA"

  echo "$REPLICA_RESPONSE" \
    | jq '{status,errors}'

else

  NUM_REPLICA=$(
    jq -r '.results[0] // 0' \
      <<< "$REPLICA_RESPONSE"
  )

  if [[ "$NUM_REPLICA" -eq 1 ]]; then
    pass "índice HA configurado con num_replica=1"
  else
    fail "idx_booking_customer_ha tiene num_replica=${NUM_REPLICA}; se esperaba 1"
  fi

fi

# ------------------------------------------------------------
# Validar evidencia de recuperación
# ------------------------------------------------------------

if [[ -s "${ROOT_DIR}/outputs/q4-during-index-recovery.txt" ]]; then
  pass "evidencia de recuperación"
else
  fail "falta evidencia de recuperación"
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