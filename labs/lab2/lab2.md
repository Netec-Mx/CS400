---
layout: lab
title: "Práctica 2: Configuración y análisis del Data Service bajo presión de memoria"
permalink: /lab2/lab2/
images_base: /labs/lab2/img
duration: "84 minutos"
objective:
  - Validar un clúster Couchbase Server Enterprise 7.6.2 desplegado mediante Couchbase Kubernetes Operator sobre Amazon EKS.
  - Crear buckets Couchstore y Magma con cuotas reducidas para provocar presión controlada sobre la memoria administrada por Data Service.
  - Observar resident ratio, ejection, background fetch, watermarks y Disk Write Queue mientras aumenta el conjunto de datos.
  - Comparar operativamente Couchstore con valueOnly y Magma con fullEviction sin confundir la prueba con un benchmark absoluto de storage engines.
  - Generar carga mixta de lectura y escritura desde un cliente ejecutado dentro de Amazon EKS y analizar cache misses y lecturas desde almacenamiento.
  - Medir el impacto relativo de majority, majorityAndPersistActive y persistToMajority sobre la latencia de escritura mediante Couchbase Python SDK.
  - Conservar evidencias locales y eliminar de forma controlada los buckets experimentales y, cuando corresponda, la infraestructura Amazon EKS.
prerequisites:
  - Tener una cuenta de AWS con permisos para crear Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl y jq disponibles desde Git Bash.
  - Comprender los conceptos de Data Service, vBuckets, réplica, resident ratio, ejection y escritura memory-first.
  - Disponer de acceso a Internet para descargar imágenes de contenedor, charts de Helm y dependencias de Amazon EKS.
introduction:
  - En esta práctica estudiarás el comportamiento del Data Service de Couchbase Server Enterprise 7.6.2 cuando la memoria asignada a un bucket deja de ser suficiente para mantener todos sus valores residentes. Crearás un bucket Couchstore con valueOnly y otro Magma con fullEviction, generarás carga progresiva, capturarás métricas de ejection, background fetch y Disk Write Queue, y compararás la respuesta de ambos storage engines dentro de sus configuraciones soportadas. También medirás el costo relativo de los tres niveles actuales de Sync Durability. Amazon EKS será la infraestructura de ejecución, pero el objetivo del laboratorio seguirá siendo Couchbase.
slug: lab2
lab_number: 2
final_result: >
  Al finalizar la práctica habrás provocado presión de memoria controlada sobre dos buckets Couchbase, observado la reducción del resident ratio y la activación de mecanismos de ejection sin forzar OOM del contenedor, analizado lecturas no residentes y cola de escritura a disco, comparado operativamente Couchstore y Magma y medido el costo relativo de majority, majorityAndPersistActive y persistToMajority. También habrás generado evidencias locales y ejecutado una limpieza reproducible de los recursos utilizados.
notes:
  - Los 84 minutos corresponden únicamente a las tareas funcionales de Couchbase. La creación y eliminación de Amazon EKS están incluidas en la práctica, pero quedan expresamente fuera de ese tiempo.
  - Todos los comandos de terminal deben ejecutarse desde Git Bash dentro de Visual Studio Code.
  - La práctica fija Kubernetes 1.35 y Couchbase Kubernetes Operator 2.92.0 para mantener una combinación compatible y reproducible.
  - Se utilizan dos Pods Data + Query y replicaNumber 1; con dos nodos Data no debe configurarse replicaNumber 2.
  - La presión buscada corresponde a la cuota administrada por Couchbase Data Service. No se pretende provocar OOMKilled ni MemoryPressure de Kubernetes.
  - Couchstore y Magma no utilizan la misma cuota mínima de memoria. Los resultados constituyen una comparación operativa y no un benchmark absoluto entre storage engines.
  - Los valores exactos de latencia, resident ratio, background fetch y Disk Write Queue dependen del hardware, EBS, carga y estado del clúster.
references:
  - text: Instalación de AWS CLI
    url: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - text: Instalación oficial de eksctl
    url: https://eksctl.io/installation/
  - text: Instalación de kubectl en Windows
    url: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
  - text: Instalación de Helm
    url: https://helm.sh/docs/intro/install/
  - text: Instalación de jq
    url: https://jqlang.org/download/
  - text: Amazon EBS CSI Driver para Amazon EKS
    url: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
  - text: Prerrequisitos y preparación de Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/prerequisite-and-setup.html
  - text: Instalación de Couchbase Kubernetes Operator con Helm
    url: https://docs.couchbase.com/operator/current/helm-setup-guide.html
  - text: Creación y configuración de buckets mediante REST API
    url: https://docs.couchbase.com/server/7.6/rest-api/rest-bucket-create.html
  - text: Motores de almacenamiento en Couchbase Server
    url: https://docs.couchbase.com/server/7.6/learn/buckets-memory-and-storage/storage-engines.html
  - text: Eviction y administración de memoria en Couchbase Server
    url: https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/eviction.html
  - text: Durabilidad de datos en Couchbase Server
    url: https://docs.couchbase.com/server/current/learn/data/durability.html
  - text: Métricas del Data Service en Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/metrics-reference/data-service-metrics.html
prev: /lab1/lab1/
next: /lab3/lab3/
---

---
<!-- Aquí comienzan las instrucciones paso a paso de la práctica -->

## 📁 Preparación del directorio de trabajo

La práctica utilizará `C:\LABS\couchbase-nosql\lab2` para guardar scripts, manifiestos, snapshots de métricas, resultados de benchmarks y evidencias que deben permanecer disponibles aunque Amazon EKS sea eliminado.

### 🗂️ Crear el subdirectorio de la práctica

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona **File → Open Folder** y abre `C:\LABS\couchbase-nosql` para conservar la misma raíz de trabajo utilizada en el curso.

  ```text
  C:\LABS\couchbase-nosql
  ```

- {% include step_label.html %} Abre **Terminal → New Terminal** y confirma que el perfil sea **Git Bash**, porque los scripts utilizan Bash, variables de entorno y rutas POSIX.

- {% include step_label.html %} Crea la estructura de trabajo para scripts, manifiestos, métricas, benchmarks y salidas sin producir errores cuando alguna carpeta ya exista.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab2/{scripts,manifests,metrics,benchmarks,outputs}
  cd /c/LABS/couchbase-nosql/lab2
  ```

- {% include step_label.html %} Verifica la ruta activa y la estructura generada antes de crear archivos o infraestructura.

  ```bash
  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:**

```text
/c/LABS/couchbase-nosql/lab2
.
./benchmarks
./manifests
./metrics
./outputs
./scripts
```

---

## 🧰 Herramientas y enlaces oficiales

Instala las herramientas únicamente desde los sitios oficiales indicados. Si ya completaste la Práctica 1, la mayoría deben estar disponibles.

| Herramienta | Propósito | Enlace oficial |
|---|---|---|
| AWS CLI v2 | Autenticación y consultas AWS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| eksctl | Crear y eliminar Amazon EKS | https://eksctl.io/installation/ |
| kubectl | Administrar Kubernetes | https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/ |
| Helm 3 | Instalar Couchbase Kubernetes Operator | https://helm.sh/docs/intro/install/ |
| jq | Procesar respuestas JSON | https://jqlang.org/download/ |
| Git for Windows | Proporcionar Git Bash | https://git-scm.com/download/win |
| Visual Studio Code | Editor y terminal | https://code.visualstudio.com/download |
| Couchbase Downloads | Server y Operator | https://www.couchbase.com/downloads/ |

---

## ☁️ Preparación de infraestructura

Esta sección crea Amazon EKS, instala Couchbase Kubernetes Operator y despliega Couchbase Server Enterprise 7.6.2. Si ya conservas el clúster funcional de la Práctica 1, puedes ejecutar las validaciones y omitir la creación porque el script es idempotente.

## Crear las variables comunes

- {% include step_label.html %} Crea `lab.env` con la región, nombres, versiones y credenciales exclusivas del laboratorio para que todos los scripts reutilicen una única fuente de configuración.

  ```bash
  cat > lab.env << 'ENVEOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab02"
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

- {% include step_label.html %} Carga las variables y comprueba los valores no sensibles para confirmar que la terminal utilizará el clúster y la versión esperados.

  ```bash
  source lab.env

  printf 'AWS_REGION=%s\nEKS_CLUSTER=%s\nEKS_VERSION=%s\nCB_CLUSTER=%s\nCB_IMAGE=%s\n' \
    "$AWS_REGION" "$EKS_CLUSTER" "$EKS_VERSION" "$CB_CLUSTER" "$CB_IMAGE"
  ```

## Crear el script de ciclo de vida de EKS

- {% include step_label.html %} Crea `scripts/eks-cluster.sh` para validar herramientas, generar el archivo `eksctl`, crear EKS con tres workers de 16 GiB y eliminar posteriormente el entorno con el mismo nombre y región.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab2/eks-cluster.sh
  ```
  
  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```

> **NOTA:** Esta práctica utiliza `m6i.xlarge` para disponer de margen suficiente de memoria en los workers. La presión buscada debe producirse dentro de las cuotas de Couchbase y no mediante `OOMKilled` del contenedor.
{: .lab-note .info .compact}

## Crear Amazon EKS

- {% include step_label.html %} Ejecuta la acción `create`; si el clúster ya existe, el script únicamente actualizará `kubeconfig` y validará los nodos.

  ```bash
  source lab.env
  ./scripts/eks-cluster.sh create
  ```

- {% include step_label.html %} Confirma que existen tres workers `Ready` y que corresponden al tipo de instancia definido para esta práctica.

  ```bash
  kubectl get nodes \
    -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone \
    -o wide
  ```

## Preparar almacenamiento gp3

- {% include step_label.html %} Crea una StorageClass gp3 con `WaitForFirstConsumer` para permitir que EBS se aprovisione en la zona donde Kubernetes programe cada Pod Couchbase.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'SCSEOF'
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
  SCSEOF

  kubectl apply -f manifests/storageclass-gp3.yaml
  kubectl get storageclass gp3-couchbase -o wide
  ```

## Instalar Couchbase Kubernetes Operator

- {% include step_label.html %} Agrega el repositorio oficial de Couchbase e instala Operator 2.92.0 y Admission Controller sin crear el clúster predeterminado del chart.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update

  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace couchbase \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

- {% include step_label.html %} Espera que los deployments del namespace estén disponibles antes de crear el recurso `CouchbaseCluster`.

  ```bash
  kubectl wait \
    --namespace couchbase \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

## Crear el secreto administrativo y el CouchbaseCluster

- {% include step_label.html %} Genera el secreto administrativo sin escribir manualmente valores Base64 y aplícalo en el namespace `couchbase`.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace couchbase \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    > manifests/cb-admin-secret.yaml

  kubectl apply -f manifests/cb-admin-secret.yaml
  ```

- {% include step_label.html %} Crea un `CouchbaseCluster` con dos Pods Data + Query y dos Pods especializados. Cada miembro utiliza un PVC gp3 independiente.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'CBCEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-cs400
    namespace: couchbase

  spec:
    image: couchbase/server:enterprise-7.6.2

    cluster:
      dataServiceMemoryQuota: 2Gi
      indexServiceMemoryQuota: 512Mi
      searchServiceMemoryQuota: 512Mi
      analyticsServiceMemoryQuota: 1Gi
      eventingServiceMemoryQuota: 512Mi

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
  CBCEOF
  ```
  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```

- {% include step_label.html %} Espera hasta que el Operator reporte el recurso `Available` y confirma que existan cuatro Pods Couchbase en estado `Running`.

  ```bash
  kubectl wait \
    --namespace couchbase \
    --for=condition=Available \
    couchbasecluster/cb-cs400 \
    --timeout=15m
  ```
  ```bash
  kubectl get pods -n couchbase -o wide
  kubectl get pvc -n couchbase
  ```

## Crear el port-forward de administración

- {% include step_label.html %} Abre una **segunda terminal Git Bash** y ejecuta el port-forward al Service administrativo. Mantén esta terminal abierta durante todas las tareas REST y Web Console.

  ```bash
  kubectl port-forward \
    -n couchbase \
    service/cb-cs400-ui \
    8091:8091
  ```

**Salida esperada:**

```text
Forwarding from 127.0.0.1:8091 -> 8091
```

---

## 🔎 Tarea 1. Validar Data Service, réplica y almacenamiento persistente — 6 min

En esta tarea confirmarás que la presión se aplicará a la memoria administrada por Couchbase y no a un contenedor sin capacidad suficiente.

### Tarea 1.1. Confirmar la topología de servicios

- {% include step_label.html %} Consulta `/pools/default` para identificar los dos miembros con Data Service (`kv`) y comprobar que todos los nodos estén saludables antes de crear buckets.

  ```bash
  source lab.env

  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '[.nodes[] | {
        hostname: .hostname,
        status: .status,
        membership: .clusterMembership,
        services: .services
      }]'
  ```

**Validación:**

- Deben existir exactamente 4 nodos Couchbase.
- Deben existir exactamente 2 nodos con `kv`.
- Todos deben mostrarse `healthy` y `active`.

### Tarea 1.2. Identificar los Data Pods

- {% include step_label.html %} Lista los Pods Couchbase con sus nombres, IP y worker Kubernetes para registrar la relación entre miembro Couchbase y Pod antes de generar carga.

  ```bash
  kubectl get pods -n couchbase \
    -o custom-columns='POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,POD_IP:.status.podIP'
  ```

- {% include step_label.html %} Obtén desde Couchbase los hostnames que ejecutan `kv` y conserva la salida como referencia para las tareas de métricas.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq -r '.nodes[]
      | select(.services | index("kv"))
      | .hostname'
  ```

### Tarea 1.3. Confirmar PersistentVolumes

- {% include step_label.html %} Lista los PVC y confirma que todos estén `Bound`, porque Couchstore y Magma escribirán datos persistentes respaldados por Amazon EBS.

  ```bash
  kubectl get pvc -n couchbase
  ```

- {% include step_label.html %} Verifica que los Pods no presenten `OOMKilled`, `MemoryPressure` ni reinicios anormales antes de iniciar la prueba de presión.

  ```bash
  kubectl get pods -n couchbase \
    -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase'
  ```

> **IMPORTANTE:** El objetivo del laboratorio es forzar ejection dentro de Couchbase. Si Kubernetes muestra `OOMKilled`, la prueba dejó de medir el comportamiento deseado.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}

{% include support-prompt.html task="tarea1" %}

---

## 🪣 Tarea 2. Crear buckets Couchstore y Magma — 7 min

En esta tarea crearás dos buckets con storage engines y políticas de ejection diferentes. Couchstore utilizará una cuota de 256 MiB y Magma el mínimo de 1024 MiB requerido para 1024 vBuckets.

### Tarea 2.1. Crear lab-couchstore

- {% include step_label.html %} Envía la solicitud REST para crear `lab-couchstore` con Couchstore, `valueOnly`, una réplica y una cuota reducida de 256 MiB que permita alcanzar presión de memoria sin comprometer el Pod.

  ```bash
  curl -s -o outputs/create-couchstore.txt \
    -w "HTTP %{http_code}\n" \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/pools/default/buckets \
    -d name=lab-couchstore \
    -d bucketType=couchbase \
    -d ramQuota=256 \
    -d replicaNumber=1 \
    -d evictionPolicy=valueOnly \
    -d storageBackend=couchstore \
    -d durabilityMinLevel=none \
    -d flushEnabled=1
  ```

**Salida esperada:**

La creación correcta debe devolver un código `202`.

- {% include step_label.html %} Espera a que el bucket aparezca y valida sus propiedades efectivas antes de generar datos.

  ```bash
  sleep 8

  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab-couchstore \
    | jq '{
        name,
        ramQuotaMiB: (.quota.ram / 1048576),
        replicaNumber,
        evictionPolicy,
        storageBackend,
        durabilityMinLevel
      }'
  ```

**Salida esperada conceptual:**

```json
{
  "name": "lab-couchstore",
  "ramQuotaMiB": 256,
  "replicaNumber": 1,
  "evictionPolicy": "valueOnly",
  "storageBackend": "couchstore",
  "durabilityMinLevel": "none"
}
```

### Tarea 2.2. Crear lab-magma

- {% include step_label.html %} Crea `lab-magma` con 1024 MiB, `fullEviction`, una réplica y storage backend Magma. La cuota es mayor porque Magma requiere al menos 1024 MiB con 1024 vBuckets.

  ```bash
  curl -s -o outputs/create-magma.txt \
    -w "HTTP %{http_code}\n" \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/pools/default/buckets \
    -d name=lab-magma \
    -d bucketType=couchbase \
    -d ramQuota=1024 \
    -d replicaNumber=1 \
    -d evictionPolicy=fullEviction \
    -d storageBackend=magma \
    -d durabilityMinLevel=none \
    -d flushEnabled=1
  ```

- {% include step_label.html %} Verifica las propiedades efectivas de ambos buckets para confirmar que la comparación utilizará engines y políticas distintas.

  ```bash
  sleep 8

  for bucket in lab-couchstore lab-magma; do
    echo "=== ${bucket} ==="

    curl -s -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${bucket}" \
      | jq '{
          name,
          storageBackend,
          evictionPolicy,
          ramQuotaMiB: (.quota.ram / 1048576),
          replicaNumber
        }'
  done
  ```

> **NOTA:** Couchstore y Magma no tienen la misma cuota mínima. El ejercicio compara comportamiento operativo dentro de configuraciones soportadas; no pretende declarar qué engine es “más rápido”.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}

{% include support-prompt.html task="tarea2" %}

---

## 📏 Tarea 3. Capturar la línea base de métricas — 5 min

En esta tarea crearás un script reusable para guardar snapshots JSON antes y después de cada fase de carga. Las métricas se conservarán localmente aunque los buckets y EKS sean eliminados.

### Tarea 3.1. Crear capture-metrics.sh

- {% include step_label.html %} Crea `scripts/capture-metrics.sh` para extraer métricas relevantes del Data Service sin asumir valores específicos de resident ratio o watermarks.

  ```bash
  cat > scripts/capture-metrics.sh << 'METRICSEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  BUCKET="${1:?Uso: capture-metrics.sh <bucket> <label>}"
  LABEL="${2:?Uso: capture-metrics.sh <bucket> <label>}"

  mkdir -p "${ROOT_DIR}/metrics"

  TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
  OUTPUT="${ROOT_DIR}/metrics/${BUCKET}_${LABEL}_${TIMESTAMP}.json"

  curl -s -u "${CB_USER}:${CB_PASS}" \
    "http://localhost:8091/pools/default/buckets/${BUCKET}/stats" \
    | jq --arg bucket "$BUCKET" --arg label "$LABEL" '{
        capturedAt: (now | todate),
        bucket: $bucket,
        label: $label,
        metrics: {
          curr_items: .op.samples.curr_items[-1],
          mem_used: .op.samples.mem_used[-1],
          ep_max_size: .op.samples.ep_max_size[-1],
          ep_mem_high_wat: .op.samples.ep_mem_high_wat[-1],
          ep_mem_low_wat: .op.samples.ep_mem_low_wat[-1],
          vb_active_resident_items_ratio: .op.samples.vb_active_resident_items_ratio[-1],
          ep_num_value_ejects: .op.samples.ep_num_value_ejects[-1],
          ep_num_eject_failures: .op.samples.ep_num_eject_failures[-1],
          ep_num_non_resident: .op.samples.ep_num_non_resident[-1],
          vb_active_num_non_resident: .op.samples.vb_active_num_non_resident[-1],
          ep_tmp_oom_errors: .op.samples.ep_tmp_oom_errors[-1],
          ep_oom_errors: .op.samples.ep_oom_errors[-1],
          ep_queue_size: .op.samples.ep_queue_size[-1],
          ep_diskqueue_drain_rate: .op.samples.ep_diskqueue_drain_rate[-1],
          cmd_get: .op.samples.cmd_get[-1],
          get_hits: .op.samples.get_hits[-1],
          get_misses: .op.samples.get_misses[-1],
          avg_bg_wait_time: .op.samples.avg_bg_wait_time[-1],
          ep_bg_fetched: .op.samples.ep_bg_fetched[-1]
        }
      }' \
    | tee "$OUTPUT"

  echo "Snapshot guardado: $OUTPUT"
  METRICSEOF
  ```
  ```bash
  chmod +x scripts/capture-metrics.sh
  bash -n scripts/capture-metrics.sh
  ```

### Tarea 3.2. Capturar baseline

- {% include step_label.html %} Guarda un snapshot de cada bucket antes de cargar documentos para disponer de un punto de comparación real.

  ```bash
  ./scripts/capture-metrics.sh lab-couchstore baseline
  ./scripts/capture-metrics.sh lab-magma baseline
  ```

- {% include step_label.html %} Lista los archivos y confirma que se generaron dos snapshots JSON.

  ```bash
  ls -lh metrics/
  ```

**Validación:**

Con buckets recién creados, `curr_items` debe ser 0 y no deben existir ejections. El resident ratio puede mostrarse como `100` o `null` al no existir elementos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}

{% include support-prompt.html task="tarea3" %}

---

## 🔥 Tarea 4. Presionar Couchstore y observar ejection — 12 min

En esta tarea utilizarás `cbworkloadgen` desde un Pod Data para insertar lotes progresivos. La carga se detendrá cuando aparezca evidencia de ejection o cuando se alcance el límite definido por seguridad.

### Tarea 4.1. Localizar un Pod que ejecute Data Service

- {% include step_label.html %} Obtén el hostname de un nodo `kv` desde REST y localiza el Pod Kubernetes correspondiente para ejecutar la herramienta instalada con Couchbase Server.

  ```bash
  DATA_HOST=$(
    curl -sS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
    | jq -r '
        .nodes[]
        | select(.services | index("kv"))
        | .hostname
        | split(":")[0]
      ' \
    | head -n 1
  )

  DATA_POD="${DATA_HOST%%.*}"

  echo "Data hostname: $DATA_HOST"
  echo "Data Pod:      $DATA_POD"
  ```

> **NOTA:** Si el hostname expuesto por Couchbase incluye un dominio DNS adicional, utiliza `kubectl get pods -n couchbase` y selecciona manualmente el Pod cuyo prefijo coincida con el hostname mostrado.
{: .lab-note .info .compact}

### Tarea 4.2. Crear un script de carga progresiva para Couchstore

- {% include step_label.html %} Crea `scripts/load-couchstore.sh` para insertar lotes con prefijos únicos y consultar ejection después de cada fase, evitando depender de una cantidad fija que podría comportarse diferente entre entornos.

  ```bash
  cat > scripts/load-couchstore.sh << 'LOADCSEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  DATA_POD="${1:?Uso: load-couchstore.sh <DATA_POD>}"
  BUCKET="lab-couchstore"

  run_batch() {
    local label="$1"
    local items="$2"
    local size="$3"

    echo
    echo "============================================================"
    echo "${BUCKET}: ${label}"
    echo "Items objetivo : ${items}"
    echo "Tamaño mínimo  : ${size} bytes"
    echo "============================================================"

    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "${CB_NAMESPACE}" \
      "${DATA_POD}" \
      -c couchbase-server \
      -- \
      /opt/couchbase/bin/cbworkloadgen \
        -n cb-cs400-ui:8091 \
        -u "${CB_USER}" \
        -p "${CB_PASS}" \
        -b "${BUCKET}" \
        -r 1.0 \
        -i "${items}" \
        -s "${size}" \
        --prefix="${label}_" \
        -t 4

    echo
    echo "Carga ${label} finalizada. Esperando actualización de estadísticas..."
    sleep 5

    "${ROOT_DIR}/scripts/capture-metrics.sh" \
      "${BUCKET}" \
      "${label}"

    echo
    echo "--- Métricas posteriores a ${label} ---"

    curl -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}/stats" \
    | jq '.op.samples | {
        curr_items: (.curr_items[-1] // 0),
        resident_ratio: (.vb_active_resident_items_ratio[-1] // null),
        mem_used_mib:
          ((.mem_used[-1] // 0) / 1048576 | round),
        ejects: (.ep_num_value_ejects[-1] // 0),
        non_resident: (.ep_num_non_resident[-1] // 0),
        bg_fetches: (.ep_bg_fetched[-1] // 0),
        tmp_oom: (.ep_tmp_oom_errors[-1] // 0)
      }'
  }

  run_batch "cs_phase1" 40000 1024
  run_batch "cs_phase2" 60000 4096

  EJECTS=$(
    curl -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}/stats" \
    | jq -r '.op.samples.ep_num_value_ejects[-1] // 0'
  )

  if awk -v value="$EJECTS" 'BEGIN { exit !(value <= 0) }'; then
    echo
    echo "No se observó ejection después de las dos primeras fases."
    echo "Se ejecutará un lote adicional para incrementar la presión de memoria."

    run_batch "cs_phase3" 80000 4096
  else
    echo
    echo "Se detectaron ${EJECTS} ejections; no se requiere el lote adicional."
  fi
  LOADCSEOF
  ```
  ```bash
  chmod +x scripts/load-couchstore.sh
  bash -n scripts/load-couchstore.sh
  ```

### Tarea 4.3. Ejecutar la carga

- {% include step_label.html %} Ejecuta el script pasando el Data Pod localizado para generar presión en la cuota del bucket sin modificar recursos de memoria del contenedor.

  ```bash
  ./scripts/load-couchstore.sh "$DATA_POD"
  ```

### Tarea 4.4. Interpretar el resultado

- {% include step_label.html %} Consulta las métricas finales y verifica si Couchstore comenzó a expulsar valores mientras conserva metadatos en memoria.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab-couchstore/stats \
    | jq '.op.samples | {
        resident_ratio: .vb_active_resident_items_ratio[-1],
        ejects: .ep_num_value_ejects[-1],
        eject_failures: .ep_num_eject_failures[-1],
        non_resident: .ep_num_non_resident[-1],
        bg_fetches: .ep_bg_fetched[-1],
        tmp_oom: .ep_tmp_oom_errors[-1],
        oom: .ep_oom_errors[-1]
      }'
  ```

**Validación esperada:**

- `ep_num_value_ejects` debe aumentar cuando la cuota requiera liberar memoria.
- `resident_ratio` puede descender respecto al baseline.
- `ep_num_non_resident` debe aumentar cuando existan valores no residentes.
- `ep_tmp_oom_errors` y `ep_oom_errors` idealmente deben mantenerse en 0.

> **IMPORTANTE:** No agregues carga únicamente para provocar OOM. El criterio pedagógico es observar ejection y no una falla de capacidad.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}

{% include support-prompt.html task="tarea4" %}

---

## 🌋 Tarea 5. Presionar Magma y realizar una comparación operativa — 12 min

En esta tarea generarás una carga equivalente por fases sobre `lab-magma`. Debido a que Magma requiere una cuota mínima superior, puede necesitar más datos antes de observar el mismo tipo de presión.

### Tarea 5.1. Crear el script de carga Magma

- {% include step_label.html %} Crea una secuencia progresiva que comience con documentos moderados y añada un lote extra únicamente si todavía no existen elementos no residentes.

  ```bash
  cat > scripts/load-magma.sh << 'LOADMGEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  DATA_POD="${1:?Uso: load-magma.sh <DATA_POD>}"
  BUCKET="lab-magma"

  # ------------------------------------------------------------
  # Validación inicial
  # ------------------------------------------------------------

  CURRENT_ITEMS=$(
    curl -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}" \
    | jq '.basicStats.itemCount // 0'
  )

  if [[ "$CURRENT_ITEMS" -gt 0 ]]; then
    echo "ERROR: ${BUCKET} ya contiene ${CURRENT_ITEMS} documentos."
    echo "Realiza un flush antes de repetir la carga controlada."
    exit 1
  fi

  # ------------------------------------------------------------
  # Función de carga
  # ------------------------------------------------------------

  run_batch() {
    local label="$1"
    local items="$2"
    local size="$3"

    echo
    echo "============================================================"
    echo "${BUCKET}: ${label}"
    echo "Items objetivo : ${items}"
    echo "Tamaño mínimo  : ${size} bytes"
    echo "============================================================"

    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "${CB_NAMESPACE}" \
      "${DATA_POD}" \
      -c couchbase-server \
      -- \
      /opt/couchbase/bin/cbworkloadgen \
        -n cb-cs400-ui:8091 \
        -u "${CB_USER}" \
        -p "${CB_PASS}" \
        -b "${BUCKET}" \
        -r 1.0 \
        -i "${items}" \
        -s "${size}" \
        --prefix="${label}_" \
        -t 4

    echo
    echo "Carga ${label} finalizada. Esperando actualización de estadísticas..."
    sleep 5

    "${ROOT_DIR}/scripts/capture-metrics.sh" \
      "${BUCKET}" \
      "${label}"

    echo
    echo "--- Métricas posteriores a ${label} ---"

    curl -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}/stats" \
    | jq '.op.samples | {
        curr_items: (.curr_items[-1] // 0),
        resident_ratio: (.vb_active_resident_items_ratio[-1] // null),
        mem_used_mib:
          ((.mem_used[-1] // 0) / 1048576 | round),
        ejects: (.ep_num_value_ejects[-1] // 0),
        non_resident: (.ep_num_non_resident[-1] // 0),
        bg_fetches: (.ep_bg_fetched[-1] // 0),
        tmp_oom: (.ep_tmp_oom_errors[-1] // 0)
      }'
  }

  # ------------------------------------------------------------
  # Fases controladas
  # ------------------------------------------------------------

  run_batch "mg_phase1" 50000 1024
  run_batch "mg_phase2" 100000 4096
  run_batch "mg_phase3" 120000 4096

  # ------------------------------------------------------------
  # Evaluar elementos no residentes
  # ------------------------------------------------------------

  NON_RESIDENT=$(
    curl -sS \
      -u "${CB_USER}:${CB_PASS}" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}/stats" \
    | jq -r '.op.samples.ep_num_non_resident[-1] // 0'
  )

  if awk -v value="$NON_RESIDENT" 'BEGIN { exit !(value <= 0) }'; then
    echo
    echo "Magma aún no muestra elementos no residentes."
    echo "Se ejecutará un lote adicional para incrementar la presión."

    run_batch "mg_phase4" 120000 4096
  else
    echo
    echo "Se detectaron ${NON_RESIDENT} elementos no residentes."
    echo "No se requiere ejecutar la fase adicional."
  fi
  LOADMGEOF
  ```
  ```bash
  chmod +x scripts/load-magma.sh
  bash -n scripts/load-magma.sh
  ```

### Tarea 5.2. Ejecutar la carga

- {% include step_label.html %} Ejecuta la carga progresiva y permite que el script capture snapshots después de cada fase.

  ```bash
  ./scripts/load-magma.sh "$DATA_POD"
  ```

### Tarea 5.3. Comparar ambos buckets

- {% include step_label.html %} Ejecuta el resumen siguiente para contrastar configuración y métricas sin interpretar los valores como un benchmark directo entre engines.

  ```bash
  for bucket in lab-couchstore lab-magma; do
    echo
    echo "=== $bucket ==="

    curl -s -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${bucket}" \
      | jq '{
          storageBackend,
          evictionPolicy,
          ramQuotaMiB: (.quota.ram / 1048576),
          replicaNumber
        }'

    curl -s -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${bucket}/stats" \
      | jq '.op.samples | {
          curr_items: .curr_items[-1],
          resident_ratio: .vb_active_resident_items_ratio[-1],
          mem_used_mib: (.mem_used[-1] / 1048576 | round),
          ejects: .ep_num_value_ejects[-1],
          non_resident: .ep_num_non_resident[-1],
          bg_fetches: .ep_bg_fetched[-1],
          avg_bg_wait_us: .avg_bg_wait_time[-1],
          tmp_oom: .ep_tmp_oom_errors[-1]
        }'
  done
  ```

**Interpretación:**

- Couchstore `valueOnly` puede expulsar valores manteniendo metadatos en memoria.
- Magma utiliza `fullEviction`, por lo que el patrón de residencia y recuperación desde almacenamiento puede diferir.
- Las cuotas son diferentes por requisitos del engine; no compares únicamente números absolutos de documentos o memoria.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}

{% include support-prompt.html task="tarea5" %}

---

## 🔁 Tarea 6. Generar carga mixta y analizar cache misses — 10 min

En esta tarea utilizarás Couchbase Python SDK desde un Pod cliente dentro de EKS. La prueba alternará lecturas y escrituras sobre claves existentes para provocar lecturas residentes y no residentes sin exponer el puerto KV públicamente.

### Tarea 6.1. Crear el Pod cliente Python

- {% include step_label.html %} Crea `manifests/python-client.yaml` con un contenedor Python persistente que permanecerá disponible mientras ejecutas los scripts de carga y durabilidad.

  ```bash
  cat > manifests/python-client.yaml << 'PYCLIENTEOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-python-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: python
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 7200"]
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
  PYCLIENTEOF
  ```
  ```bash
  kubectl apply -f manifests/python-client.yaml
  ```
  ```bash
  kubectl wait \
    -n couchbase \
    --for=condition=Ready \
    pod/cb-python-client \
    --timeout=3m
  ```

- {% include step_label.html %} Instala Couchbase Python SDK 4.x dentro del Pod para disponer de un cliente KV moderno sin modificar Python del equipo Windows.

  ```bash
  kubectl exec -n couchbase cb-python-client -- \
    pip install --quiet 'couchbase>=4.4,<5'
  ```

- {% include step_label.html %} Confirma que el SDK quedó instalado.

  ```bash
  kubectl exec \
    -n couchbase \
    cb-python-client \
    -- \
    python -c 'import couchbase; print(couchbase.__version__)'
  ```

### Tarea 6.2. Crear el generador de carga mixta

- {% include step_label.html %} Crea un script local que ejecutará 20 000 operaciones con aproximadamente 70% GET y 30% UPSERT sobre `lab-couchstore`.

  ```bash
  cat > benchmarks/mixed_workload.py << 'PYEOF'
  import os
  import random
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  HOST = os.environ.get("CB_HOST", "couchbase://cb-cs400")
  USER = os.environ.get("CB_USER", "Administrator")
  PASSWORD = os.environ.get("CB_PASS", "Password123!")
  BUCKET = os.environ.get("CB_BUCKET", "lab-couchstore")
  OPERATIONS = int(os.environ.get("OPERATIONS", "20000"))

  auth = PasswordAuthenticator(USER, PASSWORD)
  cluster = Cluster(HOST, ClusterOptions(auth))
  cluster.wait_until_ready(timedelta(seconds=20))

  collection = cluster.bucket(BUCKET).default_collection()

  hits = 0
  misses = 0
  writes = 0
  errors = 0

  start = time.perf_counter()

  for i in range(OPERATIONS):
      try:
          if random.random() < 0.70:
              phase = random.choice(["cs_phase1", "cs_phase2", "cs_phase3"])
              upper = {"cs_phase1": 40000, "cs_phase2": 60000, "cs_phase3": 80000}[phase]
              key = f"{phase}_{random.randrange(upper)}"

              try:
                  collection.get(key)
                  hits += 1
              except Exception:
                  misses += 1
          else:
              key = f"mixed_write_{i}"
              collection.upsert(
                  key,
                  {
                      "type": "mixed",
                      "sequence": i,
                      "payload": "x" * 2048
                  },
              )
              writes += 1
      except Exception:
          errors += 1

  elapsed = time.perf_counter() - start

  print({
      "operations": OPERATIONS,
      "seconds": round(elapsed, 3),
      "ops_per_second": round(OPERATIONS / elapsed, 2),
      "reads_ok": hits,
      "reads_not_found_or_error": misses,
      "writes": writes,
      "outer_errors": errors
  })
  PYEOF
  ```

### Tarea 6.3. Copiar y ejecutar la carga

- {% include step_label.html %} Copia el script al Pod cliente y ejecútalo usando el Service DNS interno de Couchbase, manteniendo todo el tráfico dentro de Kubernetes.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    benchmarks/mixed_workload.py \
    couchbase/cb-python-client:/tmp/mixed_workload.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    cb-python-client \
    -- \
    env \
      CB_HOST=couchbase://cb-cs400 \
      CB_USER=Administrator \
      CB_PASS='Password123!' \
      CB_BUCKET=lab-couchstore \
      OPERATIONS=20000 \
      python /tmp/mixed_workload.py
  ```

### Tarea 6.4. Medir cache y background fetch

- {% include step_label.html %} Captura las métricas inmediatamente después de la carga para observar si las lecturas sobre valores no residentes incrementaron `ep_bg_fetched` y `avg_bg_wait_time`.

  ```bash
  ./scripts/capture-metrics.sh lab-couchstore mixed_workload
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab-couchstore/stats \
    | jq '.op.samples | {
        get_hits: .get_hits[-1],
        get_misses: .get_misses[-1],
        bg_fetches: .ep_bg_fetched[-1],
        avg_bg_wait_us: .avg_bg_wait_time[-1],
        resident_ratio: .vb_active_resident_items_ratio[-1]
      }'
  ```

- {% include step_label.html %} Calcula un cache miss ratio aproximado utilizando los contadores disponibles y evita dividir entre cero cuando todavía no existan lecturas registradas.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab-couchstore/stats \
    | jq '.op.samples |
      (.get_hits[-1] // 0) as $hits |
      (.get_misses[-1] // 0) as $misses |
      {
        hits: $hits,
        misses: $misses,
        cache_miss_ratio_pct:
          (if ($hits + $misses) == 0
           then 0
           else (($misses / ($hits + $misses)) * 100)
           end)
      }'
  ```

> **NOTA:** Este ratio es una aproximación basada en las métricas observadas. `ep_bg_fetched` es especialmente útil para detectar recuperaciones desde almacenamiento causadas por elementos no residentes.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}

{% include support-prompt.html task="tarea6" %}

---

## 🌡️ Tarea 7. Analizar watermarks y Disk Write Queue — 7 min

En esta tarea observarás los límites efectivos utilizados por Data Service y la cola de persistencia. No asumirás porcentajes fijos; calcularás los valores reales expuestos por la instancia.

### Tarea 7.1. Calcular watermarks efectivos

- {% include step_label.html %} Ejecuta el cálculo siguiente para obtener cuota, HWM, LWM y porcentajes efectivos de cada bucket a partir de las métricas observadas.

  ```bash
  for bucket in lab-couchstore lab-magma; do
    echo
    echo "=== $bucket ==="

    curl -s -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${bucket}/stats" \
      | jq '.op.samples |
        (.ep_max_size[-1] // 1) as $max |
        {
          mem_used_mib: (.mem_used[-1] / 1048576),
          max_mib: ($max / 1048576),
          hwm_mib: (.ep_mem_high_wat[-1] / 1048576),
          lwm_mib: (.ep_mem_low_wat[-1] / 1048576),
          hwm_pct: ((.ep_mem_high_wat[-1] / $max) * 100),
          lwm_pct: ((.ep_mem_low_wat[-1] / $max) * 100),
          currently_above_hwm:
            (.mem_used[-1] > .ep_mem_high_wat[-1])
        }'
  done
  ```

**Validación:**

Registra los porcentajes realmente expuestos. No modifiques los watermarks durante esta práctica.

### Tarea 7.2. Generar una ráfaga y observar Disk Write Queue

- {% include step_label.html %} Ejecuta un lote adicional de 20 000 documentos de 8 KiB para crear una ráfaga breve de persistencia en `lab-couchstore`.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    "$DATA_POD" \
    -c couchbase-server \
    -- \
    /opt/couchbase/bin/cbworkloadgen \
      -n cb-cs400-ui:8091 \
      -u "$CB_USER" \
      -p "$CB_PASS" \
      -b lab-couchstore \
      -r 1.0 \
      -i 20000 \
      -s 8192 \
      --prefix=burst_ \
      -t 8
  ```

- {% include step_label.html %} Monitorea durante aproximadamente 30 segundos la cola de escritura, su velocidad de drenado y el uso de memoria para correlacionar la ráfaga con el almacenamiento EBS.

  ```bash
  for i in $(seq 1 6); do
    echo "--- $(date +%H:%M:%S) ---"

    curl -s -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default/buckets/lab-couchstore/stats \
      | jq '.op.samples | {
          queue_items: .ep_queue_size[-1],
          drain_rate: .ep_diskqueue_drain_rate[-1],
          mem_used_mib: (.mem_used[-1] / 1048576),
          resident_ratio: .vb_active_resident_items_ratio[-1]
        }'

    sleep 5
  done
  ```

**Interpretación:**

Una cola que crece durante una ráfaga y después disminuye indica que el subsistema está drenando pendientes. Una cola persistentemente creciente merece investigar throughput, IOPS, CPU y carga concurrente.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}

{% include support-prompt.html task="tarea7" %}

---

## 🛡️ Tarea 8. Medir el impacto de Sync Durability — 10 min

En esta tarea medirás la latencia de escrituras sin nivel explícito y con los tres niveles actuales de durabilidad de Couchbase: `majority`, `majorityAndPersistActive` y `persistToMajority`.

### Tarea 8.1. Crear durability-benchmark.py

- {% include step_label.html %} Crea el benchmark Python con 40 muestras por nivel y guarda promedios y percentiles dentro de `outputs/durability-results.json`.

  ```bash
  cat > benchmarks/durability_benchmark.py << 'DUREOF'
  import json
  import os
  import statistics
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.durability import DurabilityLevel, ServerDurability
  from couchbase.options import ClusterOptions, UpsertOptions

  HOST = os.environ.get("CB_HOST", "couchbase://cb-cs400")
  USER = os.environ.get("CB_USER", "Administrator")
  PASSWORD = os.environ.get("CB_PASS", "Password123!")
  BUCKET = os.environ.get("CB_BUCKET", "lab-couchstore")
  SAMPLES = int(os.environ.get("SAMPLES", "40"))

  auth = PasswordAuthenticator(USER, PASSWORD)
  cluster = Cluster(HOST, ClusterOptions(auth))
  cluster.wait_until_ready(timedelta(seconds=20))

  collection = cluster.bucket(BUCKET).default_collection()

  configs = [
      ("none", None),
      ("majority", DurabilityLevel.MAJORITY),
      (
          "majorityAndPersistActive",
          DurabilityLevel.MAJORITY_AND_PERSIST_TO_ACTIVE,
      ),
      (
          "persistToMajority",
          DurabilityLevel.PERSIST_TO_MAJORITY,
      ),
  ]

  def percentile(values, p):
      if not values:
          return None
      ordered = sorted(values)
      idx = min(
          len(ordered) - 1,
          max(0, int(round((p / 100) * (len(ordered) - 1)))),
      )
      return ordered[idx]

  results = {}

  for name, level in configs:
      latencies = []
      errors = 0

      print(f"\nProbando: {name}")

      for i in range(SAMPLES):
          key = f"durability_{name}_{i}_{time.time_ns()}"
          document = {
              "type": "durability",
              "level": name,
              "sequence": i,
              "payload": "x" * 1024,
          }

          try:
              if level is None:
                  options = UpsertOptions(
                      timeout=timedelta(seconds=15)
                  )
              else:
                  options = UpsertOptions(
                      durability=ServerDurability(level),
                      timeout=timedelta(seconds=30),
                  )

              start = time.perf_counter()
              collection.upsert(key, document, options)
              elapsed_ms = (time.perf_counter() - start) * 1000
              latencies.append(elapsed_ms)

          except Exception as exc:
              errors += 1
              print(f"Error en {name} muestra {i}: {exc}")

      if latencies:
          results[name] = {
              "samples_ok": len(latencies),
              "errors": errors,
              "avg_ms": statistics.mean(latencies),
              "p50_ms": statistics.median(latencies),
              "p95_ms": percentile(latencies, 95),
              "p99_ms": percentile(latencies, 99),
              "min_ms": min(latencies),
              "max_ms": max(latencies),
          }

  print("\nRESULTADOS")
  print("-" * 90)
  print(
      f"{'Nivel':<28}"
      f"{'Avg':>10}"
      f"{'P50':>10}"
      f"{'P95':>10}"
      f"{'P99':>10}"
      f"{'Errores':>10}"
  )

  for name, stats in results.items():
      print(
          f"{name:<28}"
          f"{stats['avg_ms']:>10.2f}"
          f"{stats['p50_ms']:>10.2f}"
          f"{stats['p95_ms']:>10.2f}"
          f"{stats['p99_ms']:>10.2f}"
          f"{stats['errors']:>10}"
      )

  print("\nJSON_RESULTS_START")
  print(json.dumps(results))
  print("JSON_RESULTS_END")
  DUREOF
  ```

### Tarea 8.2. Ejecutar el benchmark dentro del cliente EKS

- {% include step_label.html %} Copia el script al Pod cliente y ejecuta las cuatro configuraciones contra `lab-couchstore` con replicaNumber 1.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    benchmarks/durability_benchmark.py \
    couchbase/cb-python-client:/tmp/durability_benchmark.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    cb-python-client \
    -- \
    env \
      CB_HOST="couchbase://cb-cs400" \
      CB_USER="$CB_USER" \
      CB_PASS="$CB_PASS" \
      CB_BUCKET="lab-couchstore" \
      SAMPLES="40" \
      python /tmp/durability_benchmark.py \
    | tee outputs/durability-benchmark.txt
  ```

### Tarea 8.3. Interpretar los niveles correctamente

| Nivel | Condición de éxito |
|---|---|
| `none` | ACK normal sin Sync Durability explícita |
| `majority` | Una mayoría conserva la mutación en memoria |
| `majorityAndPersistActive` | Majority + persistencia en el nodo activo |
| `persistToMajority` | Una mayoría persiste la mutación en disco |

- {% include step_label.html %} Compara los resultados observados sin asumir multiplicadores fijos, porque el costo depende de EBS, red, CPU y carga concurrente.

**Validación:**

- Deben existir resultados para los cuatro modos.
- Los errores idealmente deben ser 0.
- `persistToMajority` debe interpretarse como el nivel de mayor garantía de los tres niveles de Sync Durability.

> **IMPORTANTE:** No utilices cifras prefabricadas como “25x”. El objetivo es medir el entorno real y explicar por qué esperar persistencia suele incrementar la latencia.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}

{% include support-prompt.html task="tarea8" %}

---

## 🖥️ Tarea 9. Correlacionar las métricas con la Web Console — 5 min

En esta tarea compararás las métricas capturadas con la visualización disponible en Couchbase Web Console.

### Tarea 9.1. Acceder a la consola

- {% include step_label.html %} Abre `http://localhost:8091` mientras la segunda terminal mantiene activo el port-forward y autentícate con las credenciales del laboratorio.

  ```text
  http://localhost:8091
  ```

| Campo | Valor |
|---|---|
| Usuario | `Administrator` |
| Contraseña | `Password123!` |

### Tarea 9.2. Revisar estadísticas de lab-couchstore

- {% include step_label.html %} Abre **Buckets → lab-couchstore → Statistics** y busca las gráficas relacionadas con memoria, resident ratio, operaciones y persistencia.

- {% include step_label.html %} Registra en la tabla los valores visibles y compáralos con el último snapshot generado por `capture-metrics.sh`.

| Indicador | Valor observado |
|---|---|
| Resident ratio | __________ |
| Memory Used | __________ |
| Disk Write Queue | __________ |
| Operaciones | __________ |
| Background fetch / cache related | __________ |

### Tarea 9.3. Revisar lab-magma

- {% include step_label.html %} Repite la observación sobre `lab-magma` y compara visualmente el patrón con Couchstore sin concluir que uno es superior únicamente por el valor absoluto observado.

> **NOTA:** Los nombres exactos de algunas gráficas pueden variar entre versiones de Web Console. Utiliza la métrica REST como referencia cuando una tarjeta visual no muestre exactamente el mismo nombre.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}

{% include support-prompt.html task="tarea9" %}

---

## 📄 Tarea 10. Generar reporte, validar objetivos y limpiar recursos funcionales — 10 min

En esta tarea consolidarás los resultados, comprobarás que se alcanzaron los objetivos principales y eliminarás únicamente los recursos experimentales del Lab 2.

### Tarea 10.1. Crear analyze-metrics.py

- {% include step_label.html %} Crea un analizador local para presentar cada snapshot en una tabla cronológica y facilitar la comparación entre baseline y fases de presión.

  ```bash
  cat > scripts/analyze-metrics.py << 'ANALYZEEOF'
  import glob
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  metrics_dir = root / "metrics"

  print("=" * 100)
  print("ANÁLISIS COMPARATIVO - DATA SERVICE")
  print("=" * 100)

  for bucket in ["lab-couchstore", "lab-magma"]:
      print(f"\nBucket: {bucket}")
      print(
          f"{'Etiqueta':<24}"
          f"{'Items':>12}"
          f"{'Resident%':>12}"
          f"{'Ejects':>12}"
          f"{'NonRes':>12}"
          f"{'BGFetch':>12}"
          f"{'TmpOOM':>10}"
      )
      print("-" * 94)

      files = sorted(
          glob.glob(str(metrics_dir / f"{bucket}_*.json"))
      )

      for filename in files:
          with open(filename, encoding="utf-8") as handle:
              data = json.load(handle)

          m = data.get("metrics", {})
          label = data.get("label", "?")

          items = m.get("curr_items") or 0
          resident = m.get("vb_active_resident_items_ratio")
          ejects = m.get("ep_num_value_ejects") or 0
          nonresident = m.get("ep_num_non_resident") or 0
          bgfetch = m.get("ep_bg_fetched") or 0
          tmpoom = m.get("ep_tmp_oom_errors") or 0

          resident_text = (
              "null"
              if resident is None
              else f"{resident:.2f}"
          )

          print(
              f"{label:<24}"
              f"{items:>12}"
              f"{resident_text:>12}"
              f"{ejects:>12}"
              f"{nonresident:>12}"
              f"{bgfetch:>12}"
              f"{tmpoom:>10}"
          )
  ANALYZEEOF

  python scripts/analyze-metrics.py \
    | tee outputs/metrics-analysis.txt
  ```

### Tarea 10.2. Crear generate-report.sh

- {% include step_label.html %} Genera un reporte final que capture configuración, métricas actuales y estado de almacenamiento para conservar una evidencia independiente del clúster.

  ```bash
  curl -L -o scripts/generate-report.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab2/generate-report.sh
  ```
  ```bash
  chmod +x scripts/generate-report.sh
  bash -n scripts/generate-report.sh
  ```
  ```bash
  ./scripts/generate-report.sh \
    | tee outputs/final-report.txt
  ```

### Tarea 10.3. Crear validate.sh

- {% include step_label.html %} Crea una validación final basada en propiedades que sí deben cumplirse y evita exigir un resident ratio o una latencia fija que dependa del entorno.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab2/validate.sh
  ```
  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ```
  ```bash
  ./scripts/validate.sh
  ```

### Tarea 10.4. Responder las preguntas de análisis

- {% include step_label.html %} Documenta respuestas breves utilizando exclusivamente las métricas observadas durante tu ejecución.

  1. ¿En qué fase comenzó a disminuir el resident ratio de Couchstore?
  2. ¿Qué diferencia observaste entre `ep_num_value_ejects` y `ep_num_non_resident`?
  3. ¿Cuándo aumentó `ep_bg_fetched` y qué relación tuvo con las lecturas del cliente?
  4. ¿Cómo se comportó la Disk Write Queue durante la ráfaga?
  5. ¿Qué nivel de Sync Durability presentó mayor latencia en tu ejecución y por qué?
  6. ¿Por qué no es correcto afirmar que Couchstore o Magma “ganó” únicamente con estas cifras?

### Tarea 10.5. Eliminar los recursos experimentales del Lab 2

- {% include step_label.html %} Elimina el Pod cliente y los dos buckets experimentales después de guardar los reportes; `travel-sample`, Operator y CouchbaseCluster no se modifican.

  ```bash
  kubectl delete pod cb-python-client \
    -n couchbase \
    --ignore-not-found

  for bucket in lab-couchstore lab-magma; do
    echo "Eliminando ${bucket}..."

    curl -s -u "$CB_USER:$CB_PASS" \
      -X DELETE \
      "http://localhost:8091/pools/default/buckets/${bucket}"

    sleep 5
  done
  ```

- {% include step_label.html %} Confirma que los buckets experimentales desaparecieron y que los reportes locales continúan disponibles.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets \
    | jq -r '.[].name'

  ls -lh outputs/
  ls -lh metrics/
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}

{% include support-prompt.html task="tarea10" %}

---

## 🧹 Eliminación de Amazon EKS

Si el instructor indica que las prácticas posteriores utilizarán un clúster nuevo, elimina EKS para evitar mantener EC2, EBS y control plane generando costos. Si continuarás inmediatamente con otro laboratorio que reutiliza esta infraestructura, conserva EKS y ejecuta la eliminación al terminar la sesión.

## Detener el port-forward

- {% include step_label.html %} Regresa a la segunda terminal que ejecuta `kubectl port-forward` y presiona `Ctrl+C` antes de eliminar el clúster.

## Eliminar el clúster

- {% include step_label.html %} Ejecuta la acción `delete` utilizando las mismas variables de nombre y región empleadas durante la creación.

  ```bash
  cd /c/LABS/couchbase-nosql/lab2
  source lab.env
  ```
  ```bash
  ./scripts/eks-cluster.sh delete
  ```

## Validar la eliminación

- {% include step_label.html %} Comprueba que AWS ya no pueda describir el clúster con el nombre del laboratorio.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:**

Debe aparecer un error equivalente a:

```text
ResourceNotFoundException
```

- {% include step_label.html %} Ejecuta `eksctl get cluster` para confirmar adicionalmente que el clúster ya no aparece en la región.

  ```bash
  eksctl get cluster --region "$AWS_REGION"
  ```