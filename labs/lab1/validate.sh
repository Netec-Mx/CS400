#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

CB_NAMESPACE="${CB_NAMESPACE:-couchbase}"
CB_CLUSTER="${CB_CLUSTER:-cb-cs400}"

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

equals() {
  local description="$1"
  local actual="$2"
  local expected="$3"

  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description (obtenido=${actual}, esperado=${expected})"
  fi
}

echo "================================================"
echo "VALIDACIÓN FINAL - Couchbase CS400 Lab 1"
echo "================================================"

# ------------------------------------------------------------
# Validaciones previas
# ------------------------------------------------------------

if [[ -z "${CB_USER:-}" || -z "${CB_PASS:-}" ]]; then
  echo "ERROR: CB_USER o CB_PASS no están definidos en lab.env."
  exit 1
fi

CB_ADMIN_POD=$(
  kubectl get pods \
    -n "${CB_NAMESPACE}" \
    -l "couchbase_cluster=${CB_CLUSTER}" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}'
)

if [[ -z "${CB_ADMIN_POD}" ]]; then
  echo "ERROR: No se encontró un Pod Couchbase en estado Running."
  exit 1
fi

cb_rest() {
  local endpoint="$1"

  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "${CB_NAMESPACE}" \
    "${CB_ADMIN_POD}" \
    -c couchbase-server \
    -- \
    curl --fail-with-body -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://127.0.0.1:8091${endpoint}"
}

echo
echo "Pod administrativo seleccionado: ${CB_ADMIN_POD}"
echo

# ------------------------------------------------------------
# 1. Amazon EKS
# ------------------------------------------------------------

READY_NODES="$(
  kubectl get nodes \
    -o json \
  | jq '
      [
        .items[]
        | select(
            any(
              .status.conditions[]?;
              .type == "Ready"
              and .status == "True"
            )
          )
      ]
      | length
    '
)"

equals \
  "Amazon EKS tiene 3 nodos Ready" \
  "$READY_NODES" \
  "3"

# ------------------------------------------------------------
# 2. CouchbaseCluster disponible
# ------------------------------------------------------------

CB_AVAILABLE="$(
  kubectl get couchbasecluster "${CB_CLUSTER}" \
    -n "${CB_NAMESPACE}" \
    -o json \
  | jq -r '
      [
        .status.conditions[]?
        | select(
            .type == "Available"
            and .status == "True"
          )
      ]
      | length
    '
)"

equals \
  "CouchbaseCluster está Available" \
  "$CB_AVAILABLE" \
  "1"

# ------------------------------------------------------------
# 3. Estado general Couchbase
# ------------------------------------------------------------

CLUSTER_JSON="$(cb_rest "/pools/default")"

CB_READY="$(
  jq '
    [
      .nodes[]
      | select(.status == "healthy")
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Couchbase tiene 4 nodos healthy" \
  "$CB_READY" \
  "4"

ACTIVE_NODES="$(
  jq '
    [
      .nodes[]
      | select(.clusterMembership == "active")
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Couchbase tiene 4 nodos active" \
  "$ACTIVE_NODES" \
  "4"

REBALANCE_STATUS="$(
  jq -r '.rebalanceStatus' <<< "$CLUSTER_JSON"
)"

equals \
  "No existe rebalance pendiente" \
  "$REBALANCE_STATUS" \
  "none"

# ------------------------------------------------------------
# 4. Servicios MDS
# ------------------------------------------------------------

DATA_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("kv"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existen 2 nodos Data" \
  "$DATA_NODES" \
  "2"

QUERY_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("n1ql"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existen 2 nodos Query" \
  "$QUERY_NODES" \
  "2"

INDEX_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("index"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existe 1 nodo Index" \
  "$INDEX_NODES" \
  "1"

FTS_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("fts"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existe 1 nodo Search" \
  "$FTS_NODES" \
  "1"

ANALYTICS_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("cbas"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existe 1 nodo Analytics" \
  "$ANALYTICS_NODES" \
  "1"

EVENTING_NODES="$(
  jq '
    [
      .nodes[]
      | select(.services | index("eventing"))
    ]
    | length
  ' <<< "$CLUSTER_JSON"
)"

equals \
  "Existe 1 nodo Eventing" \
  "$EVENTING_NODES" \
  "1"

# ------------------------------------------------------------
# 5. travel-sample
# ------------------------------------------------------------

BUCKET_JSON="$(
  cb_rest "/pools/default/buckets/travel-sample"
)"

BUCKET_NAME="$(
  jq -r '.name' <<< "$BUCKET_JSON"
)"

equals \
  "El bucket travel-sample existe" \
  "$BUCKET_NAME" \
  "travel-sample"

ITEM_COUNT="$(
  jq '.basicStats.itemCount // 0' <<< "$BUCKET_JSON"
)"

if [[ "$ITEM_COUNT" -gt 0 ]]; then
  pass "travel-sample contiene ${ITEM_COUNT} documentos"
else
  fail "travel-sample no contiene documentos"
fi

BUCKET_TYPE="$(
  jq -r '.bucketType' <<< "$BUCKET_JSON"
)"

equals \
  "travel-sample utiliza bucketType membase" \
  "$BUCKET_TYPE" \
  "membase"

REPLICA_NUMBER="$(
  jq '.replicaNumber' <<< "$BUCKET_JSON"
)"

equals \
  "travel-sample tiene replicaNumber 1" \
  "$REPLICA_NUMBER" \
  "1"

# ------------------------------------------------------------
# 6. vBucket map
# ------------------------------------------------------------

VBUCKET_JSON="$(
  cb_rest "/pools/default/b/travel-sample"
)"

VBUCKETS="$(
  jq '.vBucketServerMap.vBucketMap | length' \
    <<< "$VBUCKET_JSON"
)"

equals \
  "travel-sample tiene 1024 vBuckets" \
  "$VBUCKETS" \
  "1024"

MAP_REPLICAS="$(
  jq '.vBucketServerMap.numReplicas' \
    <<< "$VBUCKET_JSON"
)"

equals \
  "El vBucket map utiliza 1 réplica" \
  "$MAP_REPLICAS" \
  "1"

REPLICATED_VBUCKETS="$(
  jq '
    [
      .vBucketServerMap.vBucketMap[]
      | select(.[1] >= 0)
    ]
    | length
  ' <<< "$VBUCKET_JSON"
)"

equals \
  "Los 1024 vBuckets tienen réplica asignada" \
  "$REPLICATED_VBUCKETS" \
  "1024"

DATA_SERVERS="$(
  jq '.vBucketServerMap.serverList | length' \
    <<< "$VBUCKET_JSON"
)"

equals \
  "El cluster map contiene 2 Data nodes" \
  "$DATA_SERVERS" \
  "2"

# ------------------------------------------------------------
# 7. PVC
# ------------------------------------------------------------

BOUND_PVCS="$(
  kubectl get pvc \
    -n "${CB_NAMESPACE}" \
    -o json \
  | jq '
      [
        .items[]
        | select(.status.phase == "Bound")
      ]
      | length
    '
)"

if [[ "$BOUND_PVCS" -ge 4 ]]; then
  pass "Existen ${BOUND_PVCS} PVC Bound"
else
  fail "Solo existen ${BOUND_PVCS} PVC Bound; se esperaban al menos 4"
fi

# ------------------------------------------------------------
# Resultado
# ------------------------------------------------------------

echo
echo "================================================"
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "================================================"

if [[ "$FAIL" -ne 0 ]]; then
  exit 1
fi