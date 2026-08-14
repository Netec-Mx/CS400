#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

CB_NAMESPACE="${CB_NAMESPACE:-couchbase}"
CB_CLUSTER="${CB_CLUSTER:-cb-cs400}"

if [[ -z "${CB_USER:-}" || -z "${CB_PASS:-}" ]]; then
  echo "ERROR: CB_USER o CB_PASS no están definidos."
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

echo "============================================================"
echo "REPORTE FINAL - DATA SERVICE BAJO PRESIÓN"
echo "Fecha: $(date)"
echo "Cluster: ${CB_CLUSTER}"
echo "Pod administrativo: ${CB_ADMIN_POD}"
echo "============================================================"

echo
echo "--- PODS Y PVC ---"

kubectl get pods \
  -n "${CB_NAMESPACE}" \
  -o wide

echo

kubectl get pvc \
  -n "${CB_NAMESPACE}"

for bucket in lab-couchstore lab-magma; do

  echo
  echo "============================================================"
  echo "BUCKET: ${bucket}"
  echo "============================================================"

  echo
  echo "--- Configuración ---"

  cb_rest "/pools/default/buckets/${bucket}" \
    | jq '{
        name,
        storageBackend,
        evictionPolicy,
        ramQuotaMiB: (.quota.ram / 1048576),
        replicaNumber,
        durabilityMinLevel
      }'

  echo
  echo "--- Métricas ---"

  cb_rest "/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        curr_items: (.curr_items[-1] // 0),
        resident_ratio: (.vb_active_resident_items_ratio[-1] // null),
        mem_used_mib: (
          ((.mem_used[-1] // 0) / 1048576)
          | round
        ),
        ejects: (.ep_num_value_ejects[-1] // 0),
        eject_failures: (.ep_num_eject_failures[-1] // null),
        non_resident: (.ep_num_non_resident[-1] // 0),
        bg_fetches: (.ep_bg_fetched[-1] // 0),
        avg_bg_wait_us: (.avg_bg_wait_time[-1] // 0),
        disk_queue: (.ep_queue_size[-1] // 0),
        tmp_oom: (.ep_tmp_oom_errors[-1] // 0),
        oom: (.ep_oom_errors[-1] // 0)
      }'

done

echo
echo "============================================================"
echo "FIN DEL REPORTE"
echo "============================================================"