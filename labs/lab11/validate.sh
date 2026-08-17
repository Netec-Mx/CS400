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

REQUIRED_METRICS=(
  n1ql_requests
  n1ql_requests_500ms
  index_memory_used_total
  index_memory_quota
)

METRIC_CONTRACT_OK=true

for METRIC in "${REQUIRED_METRICS[@]}"; do
  if ! grep -qx "$METRIC" "${ROOT_DIR}/metrics/metric-names.txt"; then
    METRIC_CONTRACT_OK=false
    break
  fi
done

[[ "$METRIC_CONTRACT_OK" == "true" ]] \
  && pass "Metric contract Query/Index completo" \
  || fail "Metric contract incompleto"

kubectl get servicemonitor couchbase-server \
  -n "$MON_NAMESPACE" \
  >/dev/null 2>&1 \
  && pass "ServiceMonitor existe" \
  || fail "ServiceMonitor"

SERVER_TARGETS=$(
  curl -fsS \
    http://localhost:9090/api/v1/targets \
  | jq '[
      .data.activeTargets[]
      | select(
          .scrapePool ==
          "serviceMonitor/monitoring/couchbase-server/0"
          and .health == "up"
        )
    ] | length'
)

[[ "$SERVER_TARGETS" -gt 0 ]] \
  && pass "Couchbase Server targets UP" \
  || fail "Server targets UP=${SERVER_TARGETS}"

OPERATOR_TARGETS=$(
  curl -fsS \
    http://localhost:9090/api/v1/targets \
  | jq '[
      .data.activeTargets[]
      | select(
          .scrapePool ==
          "serviceMonitor/monitoring/couchbase-operator/0"
          and .health == "up"
        )
    ] | length'
)

[[ "$OPERATOR_TARGETS" -gt 0 ]] \
  && pass "Couchbase Operator target UP" \
  || fail "Operator targets UP=${OPERATOR_TARGETS}"

DASHBOARD=$(
  curl -s \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    http://localhost:3000/api/dashboards/uid/cb-lab11-operational \
    | jq -r '.dashboard.title // empty'
)

[[ "$DASHBOARD" == *"Couchbase Operational"* ]] \
  && pass "Dashboard existe" \
  || fail "Dashboard"

ROWS=$(
  jq '[
      .dashboard.panels[]
      | select(.type == "row")
    ]
    | length' \
    "${ROOT_DIR}/grafana/dashboard.json"
)

[[ "$ROWS" -eq 5 ]] \
  && pass "Dashboard tiene 5 filas" \
  || fail "Rows=${ROWS}"

kubectl get prometheusrule couchbase-operational-alerts \
  -n "$MON_NAMESPACE" \
  >/dev/null 2>&1 \
  && pass "PrometheusRule existe" \
  || fail "PrometheusRule"

grep -q 'Lab11SyntheticPipeline' \
  "${ROOT_DIR}/results/receiver.log" \
  && pass "Webhook recibió alerta sintética" \
  || fail "Webhook synthetic"

[[ -s "${ROOT_DIR}/results/baseline.json" ]] \
  && pass "Baseline generado" \
  || fail "Baseline"

[[ -s "${ROOT_DIR}/results/operator-metrics.txt" ]] \
  && pass "Operator metrics inventariadas" \
  || fail "Operator metrics"

[[ -s "${ROOT_DIR}/reports/event-correlation.md" ]] \
  && pass "Correlación de eventos generada" \
  || fail "Event correlation"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]
