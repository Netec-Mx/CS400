#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"
source "${ROOT_DIR}/secrets.env"

PASS=0
FAIL=0
CLIENT_POD="cb-security-client"
CA_FILE="/tmp/lab6-certs/ca.crt"

pass() {
  echo "  ✅ PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  ❌ FAIL: $1"
  FAIL=$((FAIL + 1))
}

DATA_QUERY_POD=""

for pod in $(
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o jsonpath='{.items[*].metadata.name}'
); do

  host="${pod}.${CB_CLUSTER}.${CB_NAMESPACE}.svc"

  response=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      "$CLIENT_POD" \
      -- \
      curl -sS \
        --connect-timeout 4 \
        --cacert "$CA_FILE" \
        -u "$CB_USER:$CB_PASS" \
        "https://${host}:18093/query/service" \
        --data-urlencode 'statement=SELECT 1 AS probe_value;' \
      2>/dev/null || true
  )

  if echo "$response" \
      | jq -e '.status == "success" and .results[0].probe_value == 1' \
      >/dev/null 2>&1; then
    DATA_QUERY_POD="$pod"
    break
  fi
done

if [[ -z "$DATA_QUERY_POD" ]]; then
  echo "  ❌ FAIL: no se encontró Query Service TLS"
  exit 1
fi

CB_TLS_HOST="${DATA_QUERY_POD}.${CB_CLUSTER}.${CB_NAMESPACE}.svc"

HTTPS_CODE=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "$CB_USER:$CB_PASS" \
      -o /dev/null \
      -w '%{http_code}' \
      "https://${CB_TLS_HOST}:18091/pools/default"
)

[[ "$HTTPS_CODE" == "200" ]] \
  && pass "HTTPS administración responde 200" \
  || fail "HTTPS administración respondió ${HTTPS_CODE}"

SECURITY=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/security"
)

HTTP_DISABLED=$(echo "$SECURITY" | jq -r '.disableUIOverHttp')
ENC_LEVEL=$(echo "$SECURITY" | jq -r '.clusterEncryptionLevel')

[[ "$HTTP_DISABLED" == "true" ]] \
  && pass "UI HTTP deshabilitada" \
  || fail "UI HTTP no deshabilitada"

[[ "$ENC_LEVEL" == "all" ]] \
  && pass "Cifrado inter-node completo activo" \
  || fail "clusterEncryptionLevel=${ENC_LEVEL}"

QUERY_STATUS=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "svc-query:${SVC_QUERY_PASS}" \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=
        SELECT RAW COUNT(*)
        FROM `travel-sample`.inventory.security_lab6;' \
    | jq -r '.status'
)

[[ "$QUERY_STATUS" == "success" ]] \
  && pass "svc-query ejecuta SELECT autorizado" \
  || fail "svc-query SELECT status=${QUERY_STATUS}"

READER_QUERY_STATUS=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "svc-reader:${SVC_READER_PASS}" \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=
        SELECT * FROM `travel-sample`.inventory.security_lab6 LIMIT 1;' \
    | jq -r '.status'
)

[[ "$READER_QUERY_STATUS" != "success" ]] \
  && pass "svc-reader no puede ejecutar SQL++" \
  || fail "svc-reader ejecutó SQL++ inesperadamente"

MTLS_IDENTITY=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      --cert /tmp/lab6-certs/client.crt \
      --key /tmp/lab6-certs/client.key \
      "https://${CB_TLS_HOST}:18091/whoami"
)

MTLS_USER=$(echo "$MTLS_IDENTITY" | jq -r '.id // ""')
MTLS_DOMAIN=$(echo "$MTLS_IDENTITY" | jq -r '.domain // ""')

[[ "$MTLS_USER" == "svc-mtls-client" \
   && "$MTLS_DOMAIN" == "local" ]] \
  && pass "mTLS autentica svc-mtls-client" \
  || fail "mTLS resolvió id=${MTLS_USER} domain=${MTLS_DOMAIN}"

CLIENT_CERT_AUTH=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/clientCertAuth"
)

CLIENT_CERT_STATE=$(echo "$CLIENT_CERT_AUTH" | jq -r '.state')
CLIENT_CERT_PATH=$(
  echo "$CLIENT_CERT_AUTH" \
  | jq -r '[.prefixes[]? | select(.path == "subject.cn")] | length'
)

[[ "$CLIENT_CERT_STATE" == "enable" && "$CLIENT_CERT_PATH" -ge 1 ]] \
  && pass "Client certificate auth efectivo por subject.cn" \
  || fail "clientCertAuth state=${CLIENT_CERT_STATE} subject.cn=${CLIENT_CERT_PATH}"

AUDIT_ENABLED=$(
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$CLIENT_POD" \
    -- \
    curl -sS \
      --cacert "$CA_FILE" \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit" \
    | jq -r '.auditdEnabled'
)

[[ "$AUDIT_ENABLED" == "true" ]] \
  && pass "Auditoría habilitada" \
  || fail "Auditoría no habilitada"

[[ -s "${ROOT_DIR}/audit-logs/audit-all.jsonl" ]] \
  && pass "Audit logs consolidados" \
  || fail "audit-all.jsonl ausente o vacío"

TLS_OPERATOR=$(
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json
)

N2N_POLICY=$(echo "$TLS_OPERATOR" | jq -r '.spec.networking.tls.nodeToNodeEncryption')
CLIENT_POLICY=$(echo "$TLS_OPERATOR" | jq -r '.spec.networking.tls.clientCertificatePolicy')
CLIENT_SECRET=$(echo "$TLS_OPERATOR" | jq -r '.spec.networking.tls.secretSource.clientSecretName')
CLIENT_PATH_COUNT=$(
  echo "$TLS_OPERATOR" \
  | jq -r '[.spec.networking.tls.clientCertificatePaths[]? | select(.path == "subject.cn")] | length'
)

[[ "$N2N_POLICY" == "All" ]] \
  && pass "Operator declara nodeToNodeEncryption=All" \
  || fail "Operator declara nodeToNodeEncryption=${N2N_POLICY}"

[[ "$CLIENT_POLICY" == "enable" ]] \
  && pass "Operator declara clientCertificatePolicy=enable" \
  || fail "clientCertificatePolicy=${CLIENT_POLICY}"

[[ "$CLIENT_SECRET" == "couchbase-operator-tls" ]] \
  && pass "Operator utiliza couchbase-operator-tls" \
  || fail "clientSecretName=${CLIENT_SECRET}"

[[ "$CLIENT_PATH_COUNT" -ge 1 ]] \
  && pass "Operator declara mapping subject.cn" \
  || fail "Operator no declara mapping subject.cn"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]