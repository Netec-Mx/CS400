#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"
PASS=0; FAIL=0
pass(){ echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

FTS_RESPONSE=$(curl -sS -u "${CB_USER}:${CB_PASS}"     -X POST -H 'Content-Type: application/json'     http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query     -d '{"query":{"match_all":{}},"size":1}')

FTS_FAILED=$(echo "$FTS_RESPONSE" | jq -r '.status.failed // 0')
FTS_COUNT=$(echo "$FTS_RESPONSE" | jq -r '.total_hits // 0')

[[ "$FTS_FAILED" -eq 0 && "$FTS_COUNT" -ge 6 ]]     && pass "FTS contiene ${FTS_COUNT} documentos"     || fail "FTS no contiene los 6 documentos esperados"

EN_HITS=$(jq '.total_hits // 0' "${ROOT_DIR}/outputs/search-en.json")
ES_HITS=$(jq '.total_hits // 0' "${ROOT_DIR}/outputs/search-es.json")
FUZZY_HITS=$(jq '.total_hits // 0' "${ROOT_DIR}/outputs/search-fuzzy.json")
[[ "$EN_HITS" -gt 0 ]] && pass "Búsqueda inglesa retorna resultados" || fail "Búsqueda inglesa sin resultados"
[[ "$ES_HITS" -gt 0 ]] && pass "Búsqueda española retorna resultados" || fail "Búsqueda española sin resultados"
[[ "$FUZZY_HITS" -gt 0 ]] && pass "Fuzzy search retorna resultados" || fail "Fuzzy search sin resultados"

EVENTING_RESPONSE=$(
  curl -sS -u "${CB_USER}:${CB_PASS}" \
    'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
)

EVENTING_STATUS=$(
  echo "$EVENTING_RESPONSE" \
  | jq -r '.app.composite_status // "unknown"'
)

EVENTING_DEPLOYMENT=$(
  echo "$EVENTING_RESPONSE" \
  | jq -r '.app.deployment_status // false'
)

EVENTING_PROCESSING=$(
  echo "$EVENTING_RESPONSE" \
  | jq -r '.app.processing_status // false'
)

if [[ "$EVENTING_STATUS" == "deployed" \
      && "$EVENTING_DEPLOYMENT" == "true" \
      && "$EVENTING_PROCESSING" == "true" ]]; then

  pass "Eventing deployed y processing"

else

  fail "Eventing status=${EVENTING_STATUS}, deployment=${EVENTING_DEPLOYMENT}, processing=${EVENTING_PROCESSING}"

fi

SOURCE_COUNT=$(curl -sS -u "${CB_USER}:${CB_PASS}" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings;' | jq '.results[0] // 0')
ENRICHED_COUNT=$(curl -sS -u "${CB_USER}:${CB_PASS}" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings_enriched;' | jq '.results[0] // 0')
[[ "$ENRICHED_COUNT" -ge "$SOURCE_COUNT" ]] && pass "Eventing enriqueció el conjunto vigente" || fail "source=${SOURCE_COUNT}, enriched=${ENRICHED_COUNT}"

ANALYTICS_WINDOW=$(curl -sS -u "${CB_USER}:${CB_PASS}" -X POST http://localhost:8095/analytics/service \
  --data-urlencode 'statement=
    SELECT VALUE COUNT(*) FROM (
      SELECT h.country, RANK() OVER (PARTITION BY h.country ORDER BY h.name) AS ranking
      FROM `travel-sample`.inventory.hotel AS h
      WHERE h.country IS NOT MISSING LIMIT 100
    ) AS ranked;' | jq '.results[0] // 0')
[[ "$ANALYTICS_WINDOW" -gt 0 ]] && pass "Window function Analytics funciona" || fail "Window function Analytics sin resultados"

[[ -s "${ROOT_DIR}/metrics/query-service-comparison.json" ]] && pass "Comparación Query generada" || fail "Falta comparación Query"
[[ -s "${ROOT_DIR}/metrics/analytics-service-comparison.json" ]] && pass "Comparación Analytics generada" || fail "Falta comparación Analytics"

echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]