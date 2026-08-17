#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"
PASS=0; FAIL=0
pass(){ echo "  ✅ PASS: $1"; PASS=$((PASS+1)); }
fail(){ echo "  ❌ FAIL: $1"; FAIL=$((FAIL+1)); }

AVAILABLE=$(kubectl get couchbasecluster "$CB_CLUSTER" -n "$CB_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}')
[[ "$AVAILABLE" == "True" ]] && pass "CouchbaseCluster Available" || fail "Available=${AVAILABLE}"

UNHEALTHY=$(curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default | jq '[.nodes[]|select(.status!="healthy" or .clusterMembership!="active")]|length')
[[ "$UNHEALTHY" -eq 0 ]] && pass "Todos los nodos healthy/active" || fail "Unhealthy=${UNHEALTHY}"

WRONG_IMAGE=$(kubectl get pods -n "$CB_NAMESPACE" -o json | jq '[.items[]|select(.metadata.name|startswith("cb-cs400-"))|select((.spec.containers[0].image|contains("7.6.8"))|not)]|length')
[[ "$WRONG_IMAGE" -eq 0 ]] && pass "Todos los Couchbase Pods usan 7.6.8" || fail "Pods con otra imagen=${WRONG_IMAGE}"

INDEX_STATE=$(curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=SELECT RAW state FROM system:indexes WHERE name="idx_transactions_region"' | jq -r '.results[0] // "missing"')
[[ "$INDEX_STATE" == "online" ]] && pass "Índice crítico online" || fail "Index=${INDEX_STATE}"

BACKUP_SUCCESS=$(kubectl get couchbasebackup "$BACKUP_NAME" -n "$CB_NAMESPACE" -o jsonpath='{.status.lastSuccess}')
[[ -n "$BACKUP_SUCCESS" ]] && pass "Backup inmediato validado" || fail "Backup sin lastSuccess"

RESTORE_STATUS=$(
  kubectl get couchbasebackuprestore "$RESTORE_NAME" \
    -n "$CB_NAMESPACE" \
    -o json 2>/dev/null |
  jq -c '.status // empty' 2>/dev/null || true
)

if [[ -n "$RESTORE_STATUS" ]]; then

  RESTORE_COMPLETED=$(
    printf '%s' "$RESTORE_STATUS" |
      jq -r '.completed // false'
  )

  RESTORE_FAILED=$(
    printf '%s' "$RESTORE_STATUS" |
      jq -r '.failed // false'
  )

  RESTORE_LAST_SUCCESS=$(
    printf '%s' "$RESTORE_STATUS" |
      jq -r '.lastSuccess // empty'
  )

  if [[ "$RESTORE_COMPLETED" == "true" && "$RESTORE_FAILED" != "true" ]]; then
    pass "Restore completado"
  elif [[ -n "$RESTORE_LAST_SUCCESS" && "$RESTORE_FAILED" != "true" ]]; then
    pass "Restore validado por lastSuccess=${RESTORE_LAST_SUCCESS}"
  else
    fail "Restore completed=${RESTORE_COMPLETED} failed=${RESTORE_FAILED}"
  fi

elif grep -q 'INTEGRITY=PASS' "${ROOT_DIR}/backup/integrity-result.txt" 2>/dev/null; then

  pass "Restore validado funcionalmente; status del CR no disponible"

else

  fail "Restore sin status y sin evidencia de integridad post-restore"

fi

grep -q 'INTEGRITY=PASS' "${ROOT_DIR}/backup/integrity-result.txt" \
  && pass "Integridad post-restore validada" \
  || fail "Integridad post-restore"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="
[[ "$FAIL" -eq 0 ]]
