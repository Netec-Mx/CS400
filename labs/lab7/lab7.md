---
layout: lab
title: "Práctica 7: Diseño de sizing y topología para una carga empresarial"
permalink: /lab7/lab7/
images_base: /labs/lab7/img
duration: "78 minutos"
objective:
  - Caracterizar una carga empresarial de e-commerce con 260 millones de documentos y 70,500 operaciones por segundo de pico, diferenciando perfiles read-heavy, write-heavy y mixtos.
  - Construir una matriz auditable de supuestos que separe inputs de negocio, valores documentados por Couchbase y políticas internas de diseño.
  - Calcular RAM y almacenamiento del Data Service utilizando metadata, working set, replicas, overhead, high-water mark, compresión y append-only multipliers.
  - Comparar Couchstore y Magma sin utilizar umbrales artificiales de tamaño y justificar la elección mediante working set, escala y memory-to-data ratio.
  - Dimensionar Query e Index Service a partir de concurrencia, latencia objetivo, estructura de índices y requisitos de alta disponibilidad.
  - Dimensionar Search, Analytics y Eventing mediante inputs explícitos del caso, evitando presentar estimaciones sintéticas como fórmulas oficiales.
  - Diseñar tres escenarios MDS empresariales y distinguir Multidimensional Scaling, Server Groups, Availability Zones, replicas y capacidad N+1.
  - Modelar crecimiento a 24 meses con un simulador transparente de ratios de capacidad y comparar escenarios subdimensionado, recomendado y resiliente.
  - Consultar métricas reales en un clúster Couchbase reducido sobre Amazon EKS para validar instrumentación sin pretender reproducir 260 millones de documentos.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Data, Query, Index, Search, Analytics, Eventing, MDS y Server Groups.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender vBuckets, replicas DCP, working set, resident ratio, failure domains y alta disponibilidad.
introduction:
  - En esta práctica no desplegarás físicamente una plataforma de 260 millones de documentos. Construirás un modelo de capacidad empresarial verificable y lo contrastarás con un clúster EKS reducido que sirve únicamente para observar topología, zonas, Server Groups y métricas reales. Los cálculos distinguirán tres tipos de información: datos del caso, valores documentados por Couchbase y supuestos de modelado. Esta separación evita convertir heurísticas pedagógicas en reglas universales de sizing.
slug: lab7
lab_number: 7
final_result: >
  Al finalizar la práctica habrás producido una matriz de supuestos, un modelo de sizing del Data Service, cálculos de almacenamiento Couchstore y Magma, dimensionamiento de Query, Index, Search, Analytics y Eventing, tres escenarios MDS empresariales, un diseño de Server Groups alineado con tres Availability Zones, una simulación de crecimiento a 24 meses y una validación operativa sobre Amazon EKS.
notes:
  - Los 78 minutos corresponden exclusivamente al trabajo funcional de sizing y diseño. La creación y eliminación de Amazon EKS están incluidas pero quedan fuera del tiempo.
  - El caso empresarial usa 260 millones de documentos y 70,500 ops/s pico. La cifra de 50,000 o 72,500 ops/s de versiones anteriores no se utiliza.
  - El clúster EKS real es deliberadamente pequeño y no valida la capacidad de una plataforma de 260 millones de documentos.
  - El headroom del 30% y el crecimiento mensual del 8% son políticas y supuestos del caso, no recomendaciones universales de Couchbase.
  - Las fórmulas sintéticas de latencia y riesgo se etiquetan como modelos pedagógicos y no predicen SLA reales.
  - No se utilizan precios AWS hardcodeados; los escenarios comparan recursos y cost drivers para evitar que la práctica quede obsoleta.
  - Magma no se selecciona por un umbral fijo de 100 GB. La decisión considera working set, escala y memory-to-data ratio.
  - Server Groups y MDS son conceptos diferentes: MDS define qué servicios ejecuta cada server class; Server Groups representan failure domains.
references:
  - https://docs.couchbase.com/server/7.6/install/sizing-general.html
  - https://docs.couchbase.com/server/7.6/learn/buckets-memory-and-storage/storage-engines.html
  - https://docs.couchbase.com/server/7.6/learn/services-and-indexes/services/services.html
  - https://docs.couchbase.com/server/7.6/manage/manage-groups/manage-groups.html
  - https://docs.couchbase.com/operator/current/concept-server-groups.html
  - https://docs.couchbase.com/server/7.6/metrics-reference/data-service-metrics.html
  - https://docs.couchbase.com/server/7.6/rest-api/rest-bucket-stats.html
prev: /lab6/lab6/
next: /lab8/lab8/
---

---

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre Visual Studio Code en `C:\LABS\couchbase-nosql` para conservar la raíz común, localizar prácticas anteriores y trabajar en la ruta prevista.

**Salida esperada:** Visual Studio Code debe mostrar `C:\LABS\couchbase-nosql` como carpeta raíz, con las prácticas anteriores accesibles desde el explorador lateral.

- {% include step_label.html %} Abre una terminal integrada **Git Bash** y crea los directorios de scripts, modelos, métricas, manifiestos y reportes y confirma el resultado.

```bash
mkdir -p /c/LABS/couchbase-nosql/lab7/{scripts,models,metrics,manifests,outputs}
cd /c/LABS/couchbase-nosql/lab7

pwd
find . -maxdepth 1 -type d | sort
```

**Salida esperada:** `pwd` debe mostrar `/c/LABS/couchbase-nosql/lab7` y `find` debe listar `scripts`, `models`, `metrics`, `manifests` y `outputs`.

---

## ☁️ Preparación de infraestructura

La infraestructura real sólo sirve para observar Couchbase, Kubernetes, Availability Zones, métricas y distribución de Pods. Los escenarios empresariales se modelan en Python y no se despliegan físicamente.

## Crear variables

- {% include step_label.html %} Crea `lab.env` con una configuración EKS reducida de referencia para validar el resultado y conservar evidencia útil durante la revisión posterior.

```bash
cat > lab.env << 'ENVEOF'
export AWS_REGION="us-west-2"
export EKS_CLUSTER="cb-cs400-lab07"
export EKS_VERSION="1.35"
export EKS_NODEGROUP="cb-workers"
export CB_NAMESPACE="couchbase"
export CB_CLUSTER="cb-cs400"
export CB_USER="Administrator"
export CB_PASS="Password123!"
export CB_IMAGE="couchbase/server:enterprise-7.6.2"
export CB_OPERATOR_VERSION="2.92.0"
ENVEOF
```

**Salida esperada:** `lab.env` debe contener región, clúster, versión EKS 1.35, namespace, imagen Couchbase y Operator 2.92.0 en variables reutilizables.

- {% include step_label.html %} Carga `lab.env` en la terminal activa y confirma sus variables antes de ejecutar scripts o manifiestos que dependan de la configuración común.

```bash

source lab.env
printf 'AWS_REGION=%s EKS_CLUSTER=%s EKS_VERSION=%s CB_NAMESPACE=%s\n' \
  "$AWS_REGION" "$EKS_CLUSTER" "$EKS_VERSION" "$CB_NAMESPACE"
```

**Salida esperada:** La terminal debe mostrar región, nombre, versión EKS y namespace con valores no vacíos, sin revelar la contraseña administrativa de Couchbase.

## Crear ciclo de vida EKS

- {% include step_label.html %} Crea `scripts/eks-cluster.sh` con tres workers `m6i.xlarge` repartidos entre tres Availability Zones para validar el resultado antes de continuar.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab7/eks-cluster.sh
  ```

```bash
cat > scripts/eks-cluster.sh << 'SHEOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"
CONFIG="${ROOT_DIR}/manifests/eks-cluster.yaml"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: falta '$1' en PATH."
    exit 1
  }
}

precheck() {
  for cmd in aws eksctl kubectl helm curl jq python; do
    require_cmd "$cmd"
  done
  aws sts get-caller-identity --output table
}

write_config() {
  cat > "$CONFIG" << YAML
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig
metadata:
  name: ${EKS_CLUSTER}
  region: ${AWS_REGION}
  version: "${EKS_VERSION}"

availabilityZones:
  - ${AWS_REGION}a
  - ${AWS_REGION}b
  - ${AWS_REGION}c

managedNodeGroups:
  - name: ${EKS_NODEGROUP}
    instanceType: m6i.xlarge
    minSize: 3
    desiredCapacity: 3
    maxSize: 3
    volumeSize: 60
    labels:
      workload: couchbase

addonsConfig:
  autoApplyPodIdentityAssociations: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: metrics-server
  - name: eks-pod-identity-agent
  - name: aws-ebs-csi-driver
YAML
}

create_cluster() {
  precheck
  if ! eksctl get cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
    write_config
    eksctl create cluster -f "$CONFIG"
  fi
  aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION"
  kubectl wait --for=condition=Ready node --all --timeout=10m
  kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
}

status_cluster() {
  precheck
  aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null
  kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
}

delete_cluster() {
  precheck
  if eksctl get cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" >/dev/null 2>&1; then
    eksctl delete cluster --name "$EKS_CLUSTER" --region "$AWS_REGION" --wait
  fi
}

case "${1:-}" in
  create) create_cluster ;;
  status) status_cluster ;;
  delete) delete_cluster ;;
  *) echo "Uso: $0 {create|status|delete}"; exit 2 ;;
esac
SHEOF
```

**Salida esperada:** `scripts/eks-cluster.sh` debe incluir precheck y acciones `create`, `status` y `delete`, además de generar un ClusterConfig de tres zonas.

- {% include step_label.html %} Asigna permisos al script, valida su sintaxis y ejecútalo para comprobar el flujo completo antes de utilizar sus resultados en las tareas posteriores.

```bash

chmod +x scripts/eks-cluster.sh
bash -n scripts/eks-cluster.sh
./scripts/eks-cluster.sh create
```

**Salida esperada:** Bash no debe reportar errores de sintaxis; EKS debe crear tres workers Ready tipo `m6i.xlarge` distribuidos entre las zonas configuradas.

## Crear StorageClass, Operator y CouchbaseCluster

- {% include step_label.html %} Define la StorageClass `gp3-couchbase` con EBS CSI, aprovisionamiento diferido y expansión para los volúmenes persistentes del clúster.

```bash
cat > manifests/storageclass-gp3.yaml << 'EOFSC'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-couchbase
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  fsType: ext4
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOFSC
```

**Salida esperada:** `storageclass-gp3.yaml` debe declarar EBS CSI, discos `gp3`, binding diferido, expansión habilitada y política de recuperación `Delete`.

- {% include step_label.html %} Aplica la StorageClass y consulta el recurso para confirmar el aprovisionador, el binding diferido y la expansión antes de crear los PVC.

```bash

kubectl apply -f manifests/storageclass-gp3.yaml
kubectl get storageclass gp3-couchbase
```

**Salida esperada:** Kubernetes debe mostrar `gp3-couchbase` con `ebs.csi.aws.com`, `WaitForFirstConsumer` y expansión habilitada para futuros volúmenes.

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 con Helm, sin crear un CouchbaseCluster automático, y espera que el deployment quede disponible.

```bash
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
helm repo update

helm upgrade --install cb-operator couchbase/couchbase-operator \
  --namespace couchbase \
  --create-namespace \
  --version "$CB_OPERATOR_VERSION" \
  --set install.couchbaseCluster=false

kubectl wait -n couchbase --for=condition=Available deployment --all --timeout=5m
```

**Salida esperada:** Helm debe instalar o actualizar `cb-operator`; el deployment debe alcanzar `Available` dentro del namespace `couchbase` sin errores.

- {% include step_label.html %} Crea el Secret administrativo de forma idempotente para que el Operator configure Couchbase sin imprimir las credenciales en la salida del comando.

```bash
kubectl create secret generic cb-admin \
  --namespace couchbase \
  --from-literal=username="$CB_USER" \
  --from-literal=password="$CB_PASS" \
  --dry-run=client -o yaml \
  | kubectl apply -f -
```

**Salida esperada:** El Secret `cb-admin` debe quedar creado o actualizado en `couchbase`, y la salida no debe revelar el usuario ni la contraseña configurados.

- {% include step_label.html %} Define un CouchbaseCluster reducido de cuatro Pods MDS para observar métricas, aclarando que esta topología no representa el sizing calculado.

```bash
cat > manifests/couchbase-cluster.yaml << 'EOFCB'
apiVersion: couchbase.com/v2
kind: CouchbaseCluster
metadata:
  name: cb-cs400
  namespace: couchbase
spec:
  image: couchbase/server:enterprise-7.6.2
  security:
    adminSecret: cb-admin
  securityContext:
    fsGroup: 1000
  networking:
    exposeAdminConsole: true
    adminConsoleServices:
      - data

  servers:
    - name: data-query
      size: 2
      services:
        - data
        - query
      volumeMounts:
        default: couchbase-volume

    - name: index-search
      size: 1
      services:
        - index
        - search
      volumeMounts:
        default: couchbase-volume

    - name: analytics-eventing
      size: 1
      services:
        - analytics
        - eventing
      volumeMounts:
        default: couchbase-volume

  volumeClaimTemplates:
    - metadata:
        name: couchbase-volume
      spec:
        storageClassName: gp3-couchbase
        resources:
          requests:
            storage: 30Gi
EOFCB
```

**Salida esperada:** El manifiesto debe definir cuatro Pods en tres server classes, PVC `gp3-couchbase`, secreto administrativo y consola expuesta por Data Service.

- {% include step_label.html %} Aplica el CouchbaseCluster, espera su condición `Available` y confirma que los cuatro Pods MDS queden en ejecución antes de cargar datos.

```bash

kubectl apply -f manifests/couchbase-cluster.yaml
kubectl wait -n couchbase --for=condition=Available couchbasecluster/cb-cs400 --timeout=15m
kubectl get pods -n couchbase -o wide
```

**Salida esperada:** El recurso `cb-cs400` debe alcanzar `Available` y la consulta final debe listar cuatro Pods de Couchbase en estado `Running` y sin reinicios.

## Cargar travel-sample

- {% include step_label.html %} Publica la consola administrativa por 8091 desde una terminal dedicada y conserva el túnel activo durante las consultas de métricas del laboratorio.

```bash
kubectl port-forward -n couchbase service/cb-cs400-ui 8091:8091
```

**Salida esperada:** La terminal debe permanecer mostrando el reenvío de 8091 hacia el Service administrativo, sin errores de escucha o conexión local.

- {% include step_label.html %} Comprueba si `travel-sample` existe e instálalo únicamente cuando falte para evitar solicitudes duplicadas al reutilizar infraestructura previa.

```bash
if ! curl -fsS -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/travel-sample >/dev/null 2>&1; then
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8091/sampleBuckets/install \
    -d '["travel-sample"]' | jq .
fi
```

**Salida esperada:** La petición debe terminar sin error; al consultar el bucket, `travel-sample` debe existir aunque ya estuviera instalado antes de este paso.

---

## 🔎 Tarea 1. Caracterizar workload y construir matriz de supuestos — 8 min

### Tarea 1.1. Revisar el caso empresarial

| Bucket | Documentos | Tamaño medio | GET/s pico | SET/s pico | Total |
|---|---:|---:|---:|---:|---:|
| `product_catalog` | 50,000,000 | 2 KiB | 45,000 | 3,000 | 48,000 |
| `user_sessions` | 200,000,000 | 1.5 KiB | 8,000 | 12,000 | 20,000 |
| `orders` | 10,000,000 | 4 KiB | 500 | 2,000 | 2,500 |
| **Total** | **260,000,000** | — | **53,500** | **17,000** | **70,500** |

> **IMPORTANTE:** Los 70,500 ops/s representan la suma validada del caso; este valor común evita discrepancias entre los cálculos posteriores de capacidad.
{: .lab-note .important .compact}

### Tarea 1.2. Crear matriz de supuestos

- {% include step_label.html %} Crea `models/sizing-inputs.json` para separar valores documentados por Couchbase, políticas del caso e inputs de negocio.

```bash
cat > models/sizing-inputs.json << 'EOFIN'
{
  "documented_couchbase_values": {
    "metadata_per_document_bytes": 56,
    "tombstone_metadata_bytes": 60,
    "ram_overhead_pct": 0.25,
    "high_water_mark": 0.85,
    "couchstore_append_multiplier": 3.0,
    "magma_append_multiplier": 2.2
  },
  "case_policies": {
    "replicas": 1,
    "avg_key_size_bytes": 32,
    "compression_ratio": 0.70,
    "headroom_pct": 0.30,
    "monthly_growth_rate": 0.08,
    "growth_horizon_months": 24,
    "tombstone_purge_days": 3
  },
  "buckets": [
    {
      "name": "product_catalog",
      "documents": 50000000,
      "avg_doc_size_kib": 2.0,
      "peak_gets_per_sec": 45000,
      "peak_sets_per_sec": 3000,
      "working_set_pct": 0.90,
      "daily_deletes": 20000,
      "storage_engine_candidate": "couchstore"
    },
    {
      "name": "user_sessions",
      "documents": 200000000,
      "avg_doc_size_kib": 1.5,
      "peak_gets_per_sec": 8000,
      "peak_sets_per_sec": 12000,
      "working_set_pct": 0.30,
      "daily_deletes": 5000000,
      "storage_engine_candidate": "magma"
    },
    {
      "name": "orders",
      "documents": 10000000,
      "avg_doc_size_kib": 4.0,
      "peak_gets_per_sec": 500,
      "peak_sets_per_sec": 2000,
      "working_set_pct": 0.20,
      "daily_deletes": 50000,
      "storage_engine_candidate": "couchstore"
    }
  ]
}
EOFIN
```

**Salida esperada:** El JSON debe contener seis valores Couchbase, siete políticas del caso y tres buckets cuya suma represente 260 millones de documentos.

- {% include step_label.html %} Valida el modelo recién creado y ejecuta el cálculo asociado para confirmar que los inputs sean legibles antes de interpretar los resultados.

```bash

jq '.' models/sizing-inputs.json
```

**Salida esperada:** `jq` debe imprimir el JSON completo sin errores de parseo y conservar las tres secciones: valores documentados, políticas y buckets del caso.

### Tarea 1.3. Crear el perfil de workload

- {% include step_label.html %} Crea un script que clasifique perfiles con umbrales pedagógicos del caso y calcule documentos, GiB raw y operaciones pico.

```bash
cat > scripts/workload_profile.py << 'PY1'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "models" / "sizing-inputs.json").read_text())

total_docs = 0
total_gets = 0
total_sets = 0
total_raw_gib = 0.0

print("WORKLOAD PROFILE")
print("=" * 88)

for b in data["buckets"]:
    gets = b["peak_gets_per_sec"]
    sets = b["peak_sets_per_sec"]
    ops = gets + sets
    read_pct = gets / ops if ops else 0

    if read_pct > 0.80:
        profile = "Read-Heavy"
    elif (1 - read_pct) > 0.60:
        profile = "Write-Heavy"
    else:
        profile = "Mixed"

    raw_gib = (b["documents"] * b["avg_doc_size_kib"] * 1024) / (1024 ** 3)

    print(
        f"{b['name']:<18} docs={b['documents']:>11,} "
        f"raw={raw_gib:>7.1f} GiB ops={ops:>6,}/s "
        f"reads={read_pct*100:>5.1f}% profile={profile}"
    )

    total_docs += b["documents"]
    total_gets += gets
    total_sets += sets
    total_raw_gib += raw_gib

print()
print(f"Total documents : {total_docs:,}")
print(f"Total raw       : {total_raw_gib:.1f} GiB")
print(f"Peak GET/s      : {total_gets:,}")
print(f"Peak SET/s      : {total_sets:,}")
print(f"Peak operations : {total_gets + total_sets:,}/s")
PY1
```

**Salida esperada:** `workload_profile.py` debe sumar documentos, GiB raw y operaciones, clasificar cada bucket y escribir un resumen JSON reutilizable.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/workload_profile.py | tee outputs/workload-profile.txt
```

**Salida esperada:** El reporte debe totalizar 260 millones de documentos y 70,500 ops/s, además de guardar esos valores en `outputs/workload-profile.txt`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🧠 Tarea 2. Calcular RAM del Data Service — 12 min

### Tarea 2.1. Comprender el modelo

La práctica utilizará:

```text
copies = 1 + replicas

metadata =
documents × (metadata_per_document + avg_key_size) × copies

compressed_dataset =
documents × avg_document_size × compression_ratio × copies

working_set =
compressed_dataset × working_set_pct

RAM quota =
(metadata + working_set) × (1 + overhead) ÷ high_water_mark
```

### Tarea 2.2. Crear el calculador

- {% include step_label.html %} Crea `data_ram_sizing.py` para calcular quota por bucket y aplicar después la política de 30% de headroom y confirma el resultado esperado.

```bash
cat > scripts/data_ram_sizing.py << 'PY2'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / "models" / "sizing-inputs.json").read_text())
cb = config["documented_couchbase_values"]
policy = config["case_policies"]
copies = 1 + policy["replicas"]
rows = []
total_ram = 0.0

for b in config["buckets"]:
    docs = b["documents"]
    doc_bytes = b["avg_doc_size_kib"] * 1024

    metadata_bytes = docs * (
        cb["metadata_per_document_bytes"] + policy["avg_key_size_bytes"]
    ) * copies

    dataset_bytes = docs * doc_bytes * policy["compression_ratio"] * copies
    working_set_bytes = dataset_bytes * b["working_set_pct"]

    quota_bytes = (
        (metadata_bytes + working_set_bytes)
        * (1 + cb["ram_overhead_pct"])
        / cb["high_water_mark"]
    )

    quota_gib = quota_bytes / (1024 ** 3)
    total_ram += quota_gib

    rows.append({
        "bucket": b["name"],
        "metadata_gib": metadata_bytes / (1024 ** 3),
        "compressed_dataset_with_replica_gib": dataset_bytes / (1024 ** 3),
        "working_set_gib": working_set_bytes / (1024 ** 3),
        "ram_quota_gib": quota_gib
    })

total_with_headroom = total_ram * (1 + policy["headroom_pct"])

print("DATA SERVICE RAM SIZING")
print("=" * 88)
for row in rows:
    print(
        f"{row['bucket']:<18} metadata={row['metadata_gib']:>6.1f} GiB "
        f"dataset={row['compressed_dataset_with_replica_gib']:>7.1f} GiB "
        f"working_set={row['working_set_gib']:>7.1f} GiB "
        f"quota={row['ram_quota_gib']:>7.1f} GiB"
    )

print()
print(f"Total RAM quota         : {total_ram:.1f} GiB")
print(f"Headroom policy         : {policy['headroom_pct']*100:.0f}%")
print(f"RAM with headroom       : {total_with_headroom:.1f} GiB")

output = {
    "buckets": rows,
    "total_ram_quota_gib": total_ram,
    "total_ram_with_headroom_gib": total_with_headroom
}

(root / "outputs" / "data-ram-sizing.json").write_text(json.dumps(output, indent=2))
PY2
```

**Salida esperada:** `data_ram_sizing.py` debe separar metadata y working set, aplicar overhead, HWM y headroom, y producir un JSON con resultados por bucket.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/data_ram_sizing.py | tee outputs/data-ram-sizing.txt
```

**Salida esperada:** El script debe listar la cuota RAM de cada bucket y crear `outputs/data-ram-sizing.json` junto con el reporte legible capturado por `tee`.

### Tarea 2.3. Interpretar el resultado

- {% include step_label.html %} Revisa el JSON y documenta qué bucket domina la quota de RAM y qué efecto tienen replicas y working set para validar el resultado antes de continuar.

```bash
jq '.' outputs/data-ram-sizing.json
```

**Salida esperada:** `jq` debe identificar el bucket con mayor cuota RAM y mostrar cómo replicas y working set elevan la capacidad total requerida por Data Service.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 💾 Tarea 3. Calcular almacenamiento Couchstore y Magma — 10 min

### Tarea 3.1. Definir el modelo de disco

El cálculo replica los valores, suma una sola vez keys y metadata, aplica el multiplier del engine y agrega al final los tombstones con sus copias:

```text
Couchstore = 3.0
Magma      = 2.2
```

### Tarea 3.2. Crear el calculador

- {% include step_label.html %} Crea `data_disk_sizing.py` incluyendo tombstones acumulados durante tres días y confirma la condición esperada antes de continuar con la práctica.

```bash
cat > scripts/data_disk_sizing.py << 'PY3'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root / "models" / "sizing-inputs.json").read_text())
cb = config["documented_couchbase_values"]
policy = config["case_policies"]
copies = 1 + policy["replicas"]
purge_days = policy["tombstone_purge_days"]

results = []

for b in config["buckets"]:
    docs = b["documents"]
    doc_bytes = b["avg_doc_size_kib"] * 1024
    key_bytes = policy["avg_key_size_bytes"]

    compressed_values = docs * doc_bytes * policy["compression_ratio"] * copies
    keys_metadata = docs * (key_bytes + cb["metadata_per_document_bytes"])
    tombstones = b["daily_deletes"] * purge_days * (
        key_bytes + cb["tombstone_metadata_bytes"]
    ) * copies

    base = compressed_values + keys_metadata
    couchstore = base * cb["couchstore_append_multiplier"] + tombstones
    magma = base * cb["magma_append_multiplier"] + tombstones

    results.append({
        "bucket": b["name"],
        "base_gib": base / (1024 ** 3),
        "couchstore_gib": couchstore / (1024 ** 3),
        "magma_gib": magma / (1024 ** 3),
        "candidate": b["storage_engine_candidate"]
    })

print("DATA SERVICE DISK SIZING")
print("=" * 88)
for row in results:
    print(
        f"{row['bucket']:<18} base={row['base_gib']:>7.1f} GiB "
        f"couchstore={row['couchstore_gib']:>8.1f} GiB "
        f"magma={row['magma_gib']:>8.1f} GiB candidate={row['candidate']}"
    )

(root / "outputs" / "data-disk-sizing.json").write_text(json.dumps(results, indent=2))
PY3
```

**Salida esperada:** `data_disk_sizing.py` debe aplicar copias sólo donde corresponde, sumar tombstones después del multiplier y comparar ambos storage engines.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/data_disk_sizing.py | tee outputs/data-disk-sizing.txt
```

**Salida esperada:** La salida debe comparar GiB base, Couchstore y Magma por bucket, y guardar el detalle corregido en JSON y texto para su posterior revisión.

### Tarea 3.3. Justificar engines

| Bucket | Candidate | Justificación |
|---|---|---|
| `product_catalog` | Couchstore | Read-heavy, working set alto y prioridad de residency |
| `user_sessions` | Magma | 200M docs, working set proporcionalmente menor y alta rotación |
| `orders` | Couchstore inicial | Dataset menor; validar contra crecimiento y write pattern |

> **NOTA:** No existe una regla “Magma si dataset >100 GB”. El engine debe decidirse con working set, escala, memory-to-data ratio y benchmark.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## ⚙️ Tarea 4. Dimensionar Query e Index Service — 10 min

### Tarea 4.1. Dimensionar Query mediante concurrencia

El caso define:

```text
QPS pico SQL++ = 2,000
latencia media objetivo = 20 ms
```

Por Little's Law:

```text
concurrency ≈ QPS × latency_seconds
            ≈ 2,000 × 0.020
            ≈ 40 consultas concurrentes
```

- {% include step_label.html %} Crea el cálculo inicial de cores y aplica 30% de headroom; el resultado debe validarse con benchmark antes de producción.

```bash
cat > scripts/query_sizing.py << 'PY4A'
import math

peak_qps = 2000
target_avg_latency_ms = 20
concurrent_queries_per_core = 4
headroom = 0.30
min_nodes_for_ha = 2

concurrency = peak_qps * (target_avg_latency_ms / 1000)
base_cores = math.ceil(concurrency / concurrent_queries_per_core)
cores_with_headroom = math.ceil(base_cores * (1 + headroom))
cores_per_node = math.ceil(cores_with_headroom / min_nodes_for_ha)

print("QUERY SERVICE SIZING")
print("=" * 72)
print(f"Peak QPS                 : {peak_qps:,}")
print(f"Latency target           : {target_avg_latency_ms} ms")
print(f"Estimated concurrency    : {concurrency:.1f}")
print(f"Base cores               : {base_cores}")
print(f"Cores with headroom      : {cores_with_headroom}")
print(f"HA nodes                 : {min_nodes_for_ha}")
print(f"Modeled cores/node       : {cores_per_node}")
print("Benchmark required before production.")
PY4A
```

**Salida esperada:** `query_sizing.py` debe derivar concurrencia desde QPS y latencia, convertirla en cores del modelo y añadir 30% de margen explícito.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/query_sizing.py | tee outputs/query-sizing.txt
```

**Salida esperada:** El reporte debe mostrar concurrencia estimada, cores base y cores con 30% de margen, conservando el cálculo en `outputs/query-sizing.txt`.

### Tarea 4.2. Dimensionar Index mediante entries

- {% include step_label.html %} Define número de índices y tamaño medio de secondary keys como inputs explícitos del caso y conserva evidencia suficiente para la revisión posterior.

```bash
cat > models/index-inputs.json << 'EOFIDX'
[
  {"bucket":"product_catalog","documents":50000000,"indexes":5,"avg_secondary_key_bytes":48,"working_set_pct":0.70},
  {"bucket":"user_sessions","documents":200000000,"indexes":4,"avg_secondary_key_bytes":32,"working_set_pct":0.30},
  {"bucket":"orders","documents":10000000,"indexes":6,"avg_secondary_key_bytes":64,"working_set_pct":0.50}
]
EOFIDX
```

**Salida esperada:** `index-inputs.json` debe declarar cinco índices, tamaños de claves, metadata, working set, overhead, replicas y modo `plasma` como inputs.

- {% include step_label.html %} Crea un capacity model transparente basado en entries, document key, secondary key, metadata y working set y confirma el resultado esperado.

```bash
cat > scripts/index_sizing.py << 'PY4B'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "models" / "index-inputs.json").read_text())

avg_doc_key_bytes = 32
per_entry_metadata_bytes = 64
overhead = 0.25
total_ram = 0

print("INDEX SERVICE CAPACITY MODEL")
print("=" * 88)

for item in data:
    entries = item["documents"] * item["indexes"]
    bytes_per_entry = avg_doc_key_bytes + item["avg_secondary_key_bytes"] + per_entry_metadata_bytes
    logical_bytes = entries * bytes_per_entry
    working_set_bytes = logical_bytes * item["working_set_pct"]
    ram_bytes = working_set_bytes * (1 + overhead)
    ram_gib = ram_bytes / (1024 ** 3)
    total_ram += ram_gib

    print(
        f"{item['bucket']:<18} entries={entries:>12,} "
        f"logical={logical_bytes/(1024**3):>7.1f} GiB "
        f"working-set={working_set_bytes/(1024**3):>7.1f} GiB "
        f"ram-model={ram_gib:>7.1f} GiB"
    )

print()
print(f"Total modeled index RAM: {total_ram:.1f} GiB")
print("Partitioning distributes an index; num_replica provides index copies.")
PY4B
```

**Salida esperada:** `index_sizing.py` debe calcular bytes por entrada, disco total y RAM de working set sin recurrir a una cantidad fija de memoria por índice.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/index_sizing.py | tee outputs/index-sizing.txt
```

> **IMPORTANTE:** La práctica ya no usa la regla ficticia “2 GB por índice”. El tamaño depende de entries, key sizes, metadata, storage mode y working set.
{: .lab-note .important .compact}

**Salida esperada:** El cálculo debe informar entradas, almacenamiento y RAM estimada de Index, y guardar el modelo en `outputs/index-sizing.txt` sin usar reglas fijas.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🔍 Tarea 5. Dimensionar Search, Analytics y Eventing — 8 min

### Tarea 5.1. Definir inputs especializados

- {% include step_label.html %} Crea un archivo con inputs explícitos; ninguno se presenta como multiplicador universal de Couchbase para validar el resultado antes de continuar.

```bash
cat > models/specialized-services.json << 'EOFSPEC'
{
  "search": {
    "estimated_fts_index_gib": 50,
    "peak_queries_per_sec": 100,
    "ha_nodes": 2,
    "notes": "Index size es input del caso; depende de mapping, stored fields y term vectors."
  },
  "analytics": {
    "shadow_data_gib": 350,
    "concurrent_queries": 20,
    "temporary_disk_factor": 2.0,
    "ha_nodes": 2,
    "notes": "Analytics debe aislarse de OLTP en el escenario recomendado."
  },
  "eventing": {
    "functions": 6,
    "peak_mutations_per_sec": 17000,
    "workers_per_function": 3,
    "ha_nodes": 2,
    "notes": "CPU debe validarse con funciones reales; workers y complejidad afectan memoria."
  }
}
EOFSPEC
```

**Salida esperada:** `specialized-services.json` debe conservar como inputs explícitos el tamaño FTS, shadow data, concurrencia, mutaciones y funciones Eventing.

### Tarea 5.2. Generar drivers de capacidad

- {% include step_label.html %} Calcula temporary disk de Analytics y presenta los drivers sin inventar throughput por core para Search o Eventing y confirma el resultado esperado.

```bash
cat > scripts/specialized_services_sizing.py << 'PY5'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "models" / "specialized-services.json").read_text())
search = data["search"]
analytics = data["analytics"]
eventing = data["eventing"]

analytics_temp_disk = analytics["shadow_data_gib"] * analytics["temporary_disk_factor"]

print("SPECIALIZED SERVICES CAPACITY DRIVERS")
print("=" * 82)
print("\nSEARCH")
print(f"Estimated FTS index    : {search['estimated_fts_index_gib']} GiB")
print(f"Peak Search QPS        : {search['peak_queries_per_sec']}")
print(f"HA nodes               : {search['ha_nodes']}")
print(f"Notes                  : {search['notes']}")

print("\nANALYTICS")
print(f"Shadow data            : {analytics['shadow_data_gib']} GiB")
print(f"Concurrent queries     : {analytics['concurrent_queries']}")
print(f"Temporary disk model   : {analytics_temp_disk:.0f} GiB")
print(f"HA nodes               : {analytics['ha_nodes']}")
print(f"Notes                  : {analytics['notes']}")

print("\nEVENTING")
print(f"Functions              : {eventing['functions']}")
print(f"Peak mutations         : {eventing['peak_mutations_per_sec']:,}/s")
print(f"Workers/function       : {eventing['workers_per_function']}")
print(f"HA nodes               : {eventing['ha_nodes']}")
print(f"Notes                  : {eventing['notes']}")
PY5
```

**Salida esperada:** El script debe calcular sólo el disco temporal de Analytics y presentar los demás valores como drivers que requieren una prueba de carga.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/specialized_services_sizing.py | tee outputs/specialized-services-sizing.txt
```

**Salida esperada:** El reporte debe presentar los drivers de Search, Analytics y Eventing, incluido el disco temporal, sin convertirlos en fórmulas universales.

### Tarea 5.3. Registrar decisiones MDS

| Servicio | Driver principal | Decisión inicial |
|---|---|---|
| Search | tamaño FTS + QPS | dos nodos dedicados si es crítico |
| Analytics | shadow data + temp disk + concurrencia | aislar de OLTP |
| Eventing | mutations/s + functions + workers | dos nodos si es crítico |
| Query | concurrencia + target latency | separar de Data ante contención CPU |
| Index | entries + key sizes + working set | partitioning y replicas según HA |

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🏗️ Tarea 6. Diseñar tres escenarios MDS — 10 min

### Tarea 6.1. Crear modelo de escenarios

- {% include step_label.html %} Define tres escenarios con intención explícita y sin precios AWS hardcodeados y confirma la condición esperada antes de continuar con la práctica.

```bash
cat > models/mds-scenarios.json << 'EOFMDS'
{
  "scenario_a": {
    "label": "A - Subdimensionado / costo mínimo",
    "description": "Ejemplo deliberadamente ajustado para mostrar riesgo y falta de N+1.",
    "classes": [
      {"name":"data","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":500,"services":["data"]},
      {"name":"query-index","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":32,"storage_gib_per_node":200,"services":["query","index"]},
      {"name":"search-eventing","nodes":1,"vcpu_per_node":8,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["fts","eventing"]},
      {"name":"analytics","nodes":1,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":700,"services":["analytics"]}
    ]
  },
  "scenario_b": {
    "label": "B - Capacidad recomendada",
    "description": "MDS separado, HA básica y capacidad N+1 para Data.",
    "classes": [
      {"name":"data","nodes":6,"vcpu_per_node":16,"ram_gib_per_node":128,"storage_gib_per_node":750,"services":["data"]},
      {"name":"query","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["query"]},
      {"name":"index","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":96,"storage_gib_per_node":400,"services":["index"]},
      {"name":"search","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":200,"services":["fts"]},
      {"name":"analytics","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":128,"storage_gib_per_node":700,"services":["analytics"]},
      {"name":"eventing","nodes":2,"vcpu_per_node":8,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["eventing"]}
    ]
  },
  "scenario_c": {
    "label": "C - Resiliencia y crecimiento",
    "description": "Mayor capacidad y redundancia entre failure domains.",
    "classes": [
      {"name":"data","nodes":9,"vcpu_per_node":32,"ram_gib_per_node":256,"storage_gib_per_node":1200,"services":["data"]},
      {"name":"query","nodes":3,"vcpu_per_node":32,"ram_gib_per_node":64,"storage_gib_per_node":100,"services":["query"]},
      {"name":"index","nodes":3,"vcpu_per_node":24,"ram_gib_per_node":128,"storage_gib_per_node":600,"services":["index"]},
      {"name":"search","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":300,"services":["fts"]},
      {"name":"analytics","nodes":3,"vcpu_per_node":32,"ram_gib_per_node":192,"storage_gib_per_node":1000,"services":["analytics"]},
      {"name":"eventing","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":150,"services":["eventing"]}
    ]
  }
}
EOFMDS
```

**Salida esperada:** `mds-scenarios.json` debe definir escenarios A, B y C con clases de servicio, nodos, vCPU, RAM y disco, sin incorporar precios cambiantes.

### Tarea 6.2. Generar comparativa de recursos

- {% include step_label.html %} Calcula nodos, vCPU, RAM y almacenamiento como cost drivers independientes de precios comerciales para validar el resultado antes de continuar.

```bash
cat > scripts/mds_topology.py << 'PY6'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "models" / "mds-scenarios.json").read_text())
summary = []

for key, scenario in data.items():
    total_nodes = sum(c["nodes"] for c in scenario["classes"])
    total_vcpu = sum(c["nodes"] * c["vcpu_per_node"] for c in scenario["classes"])
    total_ram = sum(c["nodes"] * c["ram_gib_per_node"] for c in scenario["classes"])
    total_storage = sum(c["nodes"] * c["storage_gib_per_node"] for c in scenario["classes"])

    print("\n" + "=" * 96)
    print(scenario["label"])
    print(scenario["description"])
    print("=" * 96)

    for c in scenario["classes"]:
        print(
            f"{c['name']:<16} nodes={c['nodes']:<2} "
            f"services={','.join(c['services']):<18} "
            f"vCPU/node={c['vcpu_per_node']:<3} "
            f"RAM/node={c['ram_gib_per_node']:<4} GiB "
            f"disk/node={c['storage_gib_per_node']} GiB"
        )

    print(f"TOTAL nodes={total_nodes} vCPU={total_vcpu} RAM={total_ram} GiB storage={total_storage} GiB")

    summary.append({
        "scenario": key,
        "label": scenario["label"],
        "nodes": total_nodes,
        "vcpu": total_vcpu,
        "ram_gib": total_ram,
        "storage_gib": total_storage
    })

(root / "outputs" / "mds-summary.json").write_text(json.dumps(summary, indent=2))
PY6
```

**Salida esperada:** `mds_topology.py` debe sumar recursos por escenario, imprimir cada server class y guardar una síntesis JSON para las validaciones finales.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/mds_topology.py | tee outputs/mds-topology.txt
```

> **IMPORTANTE:** Data Service no separa nodos activos y réplica: cada nodo distribuye vBuckets activos y de réplica según la topología configurada.
{: .lab-note .important .compact}

**Salida esperada:** La comparativa debe listar nodos, vCPU, RAM y disco de los escenarios A, B y C, y crear `outputs/mds-summary.json` para validación.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 🌐 Tarea 7. Modelar Server Groups y Availability Zones — 6 min

### Tarea 7.1. Observar las zonas reales

- {% include step_label.html %} Lista workers y Availability Zones para confirmar tres failure domains físicos y confirma la condición esperada antes de continuar con la práctica.

```bash
kubectl get nodes \
  -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
  | tee outputs/eks-zones.txt
```

**Salida esperada:** La tabla debe listar tres valores distintos en la columna de zona y conservar cada tipo de instancia en `outputs/eks-zones.txt` como evidencia.

### Tarea 7.2. Consultar Server Groups Couchbase

- {% include step_label.html %} Consulta los grupos existentes sin crear grupos vacíos artificiales que no tendrían valor de HA para validar el resultado antes de continuar.

```bash
curl -s -u "$CB_USER:$CB_PASS" \
  http://localhost:8091/pools/default/serverGroups \
  | jq '[.groups[] | {name, nodes: [.nodes[]?.hostname]}]' \
  | tee outputs/couchbase-server-groups.json
```

**Salida esperada:** El JSON debe listar los Server Groups reales y sus hostnames; no deben agregarse grupos sin nodos para simular una distribución inexistente.

### Tarea 7.3. Documentar MDS vs Server Groups

- {% include step_label.html %} Registra la diferencia entre distribución de servicios y failure domains y confirma la condición esperada antes de continuar con la práctica.

```bash
cat > outputs/mds-vs-server-groups.md << 'EOFSG'
# MDS vs Server Groups

## MDS
Define qué servicios ejecuta cada server class: Data, Query, Index, Search, Analytics y Eventing.

## Server Groups
Representan failure domains lógicos y deben alinearse con failure domains físicos como AWS Availability Zones.

## En EKS
`topology.kubernetes.io/zone` identifica la zona del worker.
El Operator puede aprovechar la topología para distribuir server classes y reducir la probabilidad de concentrar copias en un mismo failure domain.

## Regla
Replica count no sustituye Server Groups.
Server Groups no sustituyen capacity planning.
MDS no sustituye high availability.
EOFSG
```

**Salida esperada:** `outputs/mds-vs-server-groups.md` debe distinguir MDS, Server Groups y zonas físicas sin tratarlos como mecanismos equivalentes.

### Tarea 7.4. Validar tres zonas

- {% include step_label.html %} Cuenta las zonas únicas de los workers y muestra sus nombres para comprobar que la infraestructura utiliza tres failure domains físicos distintos.

```bash
kubectl get nodes -o json \
  | jq '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | {zones: ., count: length}'
```

**Salida esperada:** El objeto JSON debe contener tres zonas diferentes y mostrar `"count": 3`; cualquier valor menor invalida la comprobación de distribución.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 📈 Tarea 8. Simular crecimiento y capacidad N+1 — 7 min

### Tarea 8.1. Crear un modelo transparente

El simulador calculará:

```text
RAM capacity ratio
storage capacity ratio
N+1 RAM ratio
```

El peor ratio se utilizará como indicador sintético del laboratorio.

### Tarea 8.2. Crear el simulador

- {% include step_label.html %} Crea `capacity_simulator.py`; el 8% mensual queda etiquetado como escenario agresivo del caso para validar el resultado antes de continuar.

```bash
cat > scripts/capacity_simulator.py << 'PY8'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
inputs = json.loads((root / "models" / "sizing-inputs.json").read_text())
scenarios = json.loads((root / "models" / "mds-scenarios.json").read_text())
ram = json.loads((root / "outputs" / "data-ram-sizing.json").read_text())
disk = json.loads((root / "outputs" / "data-disk-sizing.json").read_text())

growth = inputs["case_policies"]["monthly_growth_rate"]
current_ram = ram["total_ram_with_headroom_gib"]

selected_disk = 0.0
for item in disk:
    selected_disk += item["magma_gib"] if item["candidate"] == "magma" else item["couchstore_gib"]

print("CAPACITY SIMULATOR")
print("=" * 104)
print(f"Growth assumption: {growth*100:.0f}% monthly (aggressive case assumption)")

for month in [0, 6, 12, 18, 24]:
    factor = (1 + growth) ** month
    demand_ram = current_ram * factor
    demand_disk = selected_disk * factor

    print(f"\nMONTH {month} growth_factor={factor:.2f}")

    for scenario in scenarios.values():
        data_class = next(c for c in scenario["classes"] if c["name"] == "data")
        total_ram = data_class["nodes"] * data_class["ram_gib_per_node"]
        total_disk = data_class["nodes"] * data_class["storage_gib_per_node"]
        n1_nodes = max(data_class["nodes"] - 1, 1)
        n1_ram = n1_nodes * data_class["ram_gib_per_node"]

        ram_ratio = demand_ram / total_ram
        disk_ratio = demand_disk / total_disk
        n1_ratio = demand_ram / n1_ram
        worst = max(ram_ratio, disk_ratio, n1_ratio)

        if worst < 0.70:
            state = "LOW"
        elif worst < 0.90:
            state = "MEDIUM"
        else:
            state = "HIGH"

        print(
            f"{scenario['label']:<38} RAM={ram_ratio:>5.2f} "
            f"DISK={disk_ratio:>5.2f} N+1_RAM={n1_ratio:>5.2f} state={state}"
        )
PY8
```

**Salida esperada:** `capacity_simulator.py` debe proyectar demanda, calcular ratios normal y N+1, y etiquetar el peor ratio de cada periodo sin afirmar un SLA.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/capacity_simulator.py | tee outputs/capacity-simulation.txt
```

> **NOTA:** LOW, MEDIUM y HIGH son indicadores pedagógicos de capacidad; no representan estados de Couchbase ni reemplazan pruebas de carga controladas.
{: .lab-note .info .compact}

**Salida esperada:** El simulador debe mostrar ratios de RAM, disco y N+1 por periodo, guardar el reporte y etiquetar el riesgo sin afirmar una predicción productiva.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 📊 Tarea 9. Consultar métricas reales del clúster EKS — 4 min

El clúster real no valida el sizing empresarial; sirve para demostrar cómo se observan las métricas que alimentarían una revisión de capacidad.

### Tarea 9.1. Capturar stats

- {% include step_label.html %} Obtén una muestra de métricas legacy disponibles para `travel-sample` y conserva la salida y conserva evidencia suficiente para la revisión posterior.

```bash
curl -s -u "$CB_USER:$CB_PASS" \
  http://localhost:8091/pools/default/buckets/travel-sample/stats \
  | jq '{
      cmd_get: .op.samples.cmd_get[-1],
      cmd_set: .op.samples.cmd_set[-1],
      ep_bg_fetched: .op.samples.ep_bg_fetched[-1],
      ep_resident_items_rate: .op.samples.ep_resident_items_rate[-1],
      ep_queue_size: .op.samples.ep_queue_size[-1],
      mem_used: .op.samples.mem_used[-1],
      curr_items: .op.samples.curr_items[-1]
    }' \
  | tee metrics/travel-sample-stats.json
```

**Salida esperada:** `metrics/travel-sample-stats.json` debe guardar series del bucket y `jq` debe mostrar las claves disponibles junto con sus últimas muestras.

### Tarea 9.2. Interpretar correctamente

- {% include step_label.html %} Crea un lector que describa `ep_bg_fetched` como background fetches y no como “logical misses” para validar el resultado antes de continuar.

```bash
cat > scripts/measure_real_cluster.py << 'PY9'
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
data = json.loads((root / "metrics" / "travel-sample-stats.json").read_text())

print("REAL CLUSTER OBSERVATION")
print("=" * 72)
print(f"cmd_get sample             : {data.get('cmd_get')}")
print(f"cmd_set sample             : {data.get('cmd_set')}")
print(f"background fetch sample    : {data.get('ep_bg_fetched')}")
print(f"resident items rate sample : {data.get('ep_resident_items_rate')}")
print(f"write queue sample         : {data.get('ep_queue_size')}")
print(f"memory used sample         : {data.get('mem_used')}")
print(f"current items sample       : {data.get('curr_items')}")
print()
print("These values validate observability, not the 260M-document capacity model.")
PY9
```

**Salida esperada:** `measure_real_cluster.py` debe leer las series guardadas, mostrar su último valor y documentar el significado correcto de cada métrica observada.

- {% include step_label.html %} Ejecuta el script recién definido y conserva su salida para revisar cálculos, supuestos y resultados antes de continuar con el dimensionamiento.

```bash

python scripts/measure_real_cluster.py | tee outputs/real-cluster-observation.txt
```

**Salida esperada:** El lector debe resumir las series disponibles y explicar `ep_bg_fetched` como lecturas en segundo plano, sin confundirlas con fallos lógicos.

- {% include step_label.html %} Captura CPU y memoria de Pods para conservar una referencia del entorno reducido y confirma la condición esperada antes de continuar con la práctica.

```bash
kubectl top pods -n couchbase \
  | tee metrics/kubernetes-pod-usage.txt
```

**Salida esperada:** `kubectl top` debe listar CPU y memoria actuales de los Pods Couchbase y guardar la muestra en `outputs/couchbase-pod-usage.txt`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validar y generar dossier final — 3 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea una validación estructural de inputs, resultados, escenarios y tres Availability Zones sin depender de precios ni fechas de saturación rígidas.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab7/validate.sh
  ```

```bash
cat > scripts/validate.sh << 'EOFVAL'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "  ✅ PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ FAIL: $1"; FAIL=$((FAIL + 1)); }

DOCS=$(jq '[.buckets[].documents] | add' "${ROOT_DIR}/models/sizing-inputs.json")
OPS=$(jq '[.buckets[] | .peak_gets_per_sec + .peak_sets_per_sec] | add' "${ROOT_DIR}/models/sizing-inputs.json")

[[ "$DOCS" -eq 260000000 ]] && pass "260M documentos modelados" || fail "documents=${DOCS}"
[[ "$OPS" -eq 70500 ]] && pass "70,500 ops/s modelados" || fail "ops=${OPS}"
[[ -s "${ROOT_DIR}/outputs/data-ram-sizing.json" ]] && pass "Sizing RAM generado" || fail "Falta RAM sizing"
[[ -s "${ROOT_DIR}/outputs/data-disk-sizing.json" ]] && pass "Sizing disk generado" || fail "Falta disk sizing"

SCENARIOS=$(jq 'keys | length' "${ROOT_DIR}/models/mds-scenarios.json")
[[ "$SCENARIOS" -eq 3 ]] && pass "Tres escenarios MDS definidos" || fail "scenarios=${SCENARIOS}"

ZONES=$(kubectl get nodes -o json | jq '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | unique | length')
[[ "$ZONES" -eq 3 ]] && pass "EKS opera en tres Availability Zones" || fail "zones=${ZONES}"

[[ -s "${ROOT_DIR}/outputs/capacity-simulation.txt" ]] && pass "Simulación generada" || fail "Falta simulación"
[[ -s "${ROOT_DIR}/metrics/travel-sample-stats.json" ]] && pass "Métricas reales capturadas" || fail "Faltan métricas"

echo
echo "=============================================="
echo "RESULTADO: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

[[ "$FAIL" -eq 0 ]]
EOFVAL
```

**Salida esperada:** `validate.sh` debe comprobar artefactos, totales, escenarios y zonas mediante aserciones que fallen con un mensaje concreto si algo no coincide.

- {% include step_label.html %} Asigna permisos al script, valida su sintaxis y ejecútalo para comprobar el flujo completo antes de utilizar sus resultados en las tareas posteriores.

```bash

chmod +x scripts/validate.sh
./scripts/validate.sh | tee outputs/validation-final.txt
```

**Salida esperada:** `bash -n` debe aceptar el script y su ejecución debe finalizar con `VALIDATION PASSED` después de aprobar todas las aserciones estructurales.

### Tarea 10.2. Generar dossier

- {% include step_label.html %} Consolida los entregables principales en un único Markdown local para validar el resultado y conservar evidencia útil durante la revisión posterior.

```bash
{
  echo "# DOSSIER FINAL - LAB 7"
  echo
  echo "## Workload"
  cat outputs/workload-profile.txt
  echo
  echo "## Data RAM"
  cat outputs/data-ram-sizing.txt
  echo
  echo "## Data Disk"
  cat outputs/data-disk-sizing.txt
  echo
  echo "## Query"
  cat outputs/query-sizing.txt
  echo
  echo "## Index"
  cat outputs/index-sizing.txt
  echo
  echo "## Specialized services"
  cat outputs/specialized-services-sizing.txt
  echo
  echo "## MDS"
  cat outputs/mds-topology.txt
  echo
  echo "## Capacity simulation"
  cat outputs/capacity-simulation.txt
  echo
  echo "## Real cluster observation"
  cat outputs/real-cluster-observation.txt
  echo
  echo "## Validation"
  cat outputs/validation-final.txt
} | tee outputs/final-sizing-dossier.md
```

**Salida esperada:** `outputs/lab7-sizing-dossier.md` debe reunir perfiles, cálculos, escenarios, simulación, observaciones y validación en un solo entregable.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

# 🧹 Limpieza funcional

- {% include step_label.html %} Conserva los modelos, scripts, métricas y reportes porque constituyen los entregables principales del laboratorio y confirma el resultado esperado.

```bash
find models outputs metrics scripts \
  -maxdepth 1 \
  -type f \
  | sort
```

> **NOTA:** `travel-sample` no se elimina porque la práctica no lo modifica destructivamente y puede reutilizarse en laboratorios posteriores.
{: .lab-note .info .compact}

**Salida esperada:** La lista ordenada debe incluir modelos, scripts, métricas y reportes del laboratorio, confirmando que los entregables permanecen disponibles.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` el port-forward de 8091 para liberar el puerto local y evitar conexiones activas mientras se elimina la infraestructura EKS.

**Salida esperada:** El proceso debe finalizar y devolver el prompt de Git Bash; el puerto local 8091 ya no debe conservar un túnel hacia el Service de Couchbase.

- {% include step_label.html %} Ejecuta la acción `delete` del script de ciclo de vida para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

```bash
cd /c/LABS/couchbase-nosql/lab7
source lab.env
./scripts/eks-cluster.sh delete
```

**Salida esperada:** `eksctl` debe completar la eliminación del control plane, nodegroup y recursos administrados sin dejar el clúster registrado en la región.

- {% include step_label.html %} Confirma que AWS ya no pueda describir el clúster para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

```bash
aws eks describe-cluster \
  --name "$EKS_CLUSTER" \
  --region "$AWS_REGION"
```

**Salida esperada:** AWS debe responder `ResourceNotFoundException`, confirmando que el plano de control del clúster ya no existe en la región configurada.

```text
ResourceNotFoundException
```