---
layout: lab
title: "Práctica 12: Ejecución de carga, análisis y optimización"
permalink: /lab12/lab12/
images_base: /labs/lab12/img
duration: "48 minutos"
objective:
  - Diseñar 4 escenarios en Python (4-32 hilos) para hallar la saturación en Couchbase, optimizar consultas SQL++ cambiando el PrimaryScan por índices secundarios y cubiertos, y ajustar la memoria para crear un reporte comparativo automático en AWS.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Data Service, Query Service, Index Service, SQL++, GSI, covering indexes, persistencia y Couchbase Kubernetes Operator.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender conceptos básicos de pruebas de rendimiento, concurrencia, throughput, percentiles p50/p95/p99, saturación, EXPLAIN, PROFILE y consumo de memoria.
  - Comprender que los niveles de concurrencia, reglas de saturación y cambios de memoryQuota utilizados en la práctica pertenecen al escenario experimental y no representan valores universales de rendimiento para Couchbase.
introduction:
  - En esta práctica ejecutarás un ciclo completo de performance engineering sobre Couchbase Enterprise 7.6.2 en Amazon EKS. El dataset se prepara fuera del cronómetro con un schema determinista para garantizar que las pruebas KV, SQL++ e índices utilicen los mismos documentos. Durante los 48 minutos ejecutarás cargas progresivas, identificarás un candidato de saturación, analizarás planes SQL++, aplicarás tres optimizaciones defendibles y generarás un reporte comparativo basado únicamente en resultados medidos.
slug: lab12
lab_number: 12
final_result: >
  Al finalizar habrás generado cuatro escenarios reproducibles, una curva de concurrencia 4→8→16→32, métricas cliente de throughput y latencia, planes SQL++ antes y después, un secondary index que elimina el PrimaryScan, un covering index validado mediante ausencia de Fetch, un experimento declarativo de memoryQuota y un reporte automático de optimización.
notes:
  - Los 48 minutos corresponden únicamente al trabajo funcional. EKS, Couchbase y el dataset se preparan fuera del tiempo.
  - Se utilizan Couchbase Kubernetes Operator 2.92.0 y Couchbase Server Enterprise 7.6.2.
  - El dataset contiene 200,000 documentos determinstas con type, category, value, created_at, region y payload.
  - USE KEYS accede directamente por document key y no necesita un primary index.
  - ep_bg_fetched representa background fetches de elementos no residentes; no equivale a logical key misses.
  - El resident ratio no se evalúa contra un umbral universal; debe correlacionarse con latencia y background fetches.
  - fullEviction y max_parallelism son trade-offs y quedan como extensiones opcionales, no como mejoras garantizadas.
  - memoryQuota se define por Data Service Pod.
  - Se utilizan cuatro workers `m6i.xlarge` para alojar cuatro Pods Couchbase.
  - La server class `query-index` utiliza dos Pods para disponer de dos Index Service nodes y permitir índices.
  - La propiedad `dataServiceMemoryQuota` se declara en `1Gi` desde el bootstrap para permitir `memoryQuota` de `512Mi` y `768Mi` sin correcciones posteriores.
  - La respuesta REST `.quota.ram` expresa la cuota total agregada del bucket; se valida contra `memoryQuota × Data nodes`.

references:
  - text: "SQL++ Optimizer Hints"
    url: "https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/hints.html"
  - text: "Covering Indexes"
    url: "https://docs.couchbase.com/server/current/indexes/covering-indexes.html"
  - text: "GROUP BY and Aggregate Performance"
    url: "https://docs.couchbase.com/server/current/indexes/groupby-aggregate-performance.html"
  - text: "CouchbaseCluster Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasecluster.html"
  - text: "Couchbase Operator 2.9 Release Notes"
    url: "https://docs.couchbase.com/operator/current/release-notes.html"
  - text: "Index Availability and Replication"
    url: "https://docs.couchbase.com/server/current/indexes/index-replication.html"
  - text: "CouchbaseBucket Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasebucket.html"
  - text: "Couchbase Memory and Storage"
    url: "https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/memory.html"
prev: /lab11/lab11/
next: /lab13/lab13/
---

## 📁 Preparación del directorio

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona `C:\LABS\couchbase-nosql` y abre una terminal integrada **Git Bash**.

- {% include step_label.html %} Crea una estructura separada para scripts, escenarios, resultados, planes, manifiestos y reportes.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab12/{scripts,manifests,scenarios,results,plans,reports}
  cd /c/LABS/couchbase-nosql/lab12

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:** La terminal debe confirmar que el directorio activo es `/c/LABS/couchbase-nosql/lab12` y listar las seis carpetas de trabajo, verificando que la estructura base quedó preparada antes de crear archivos o resultados.

```text
/c/LABS/couchbase-nosql/lab12
./manifests
./plans
./reports
./results
./scenarios
./scripts
```

---

## ☁️ Preparación de infraestructura

## Variables

- {% include step_label.html %} Crea `lab.env` con región, versiones, credenciales y nombres reutilizados durante toda la práctica para evitar valores divergentes entre comandos.

  ```bash
  cat > lab.env << 'EOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab12"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"

  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_OPERATOR_VERSION="2.92.0"
  export CB_BUCKET="lab12-load"
  export CB_SCOPE="workload"
  export CB_COLLECTION="items"
  export TOTAL_DOCS="200000"
  EOF
  ```

**Salida esperada:** Debe crearse `lab.env` con las variables reutilizadas durante toda la práctica, incluyendo `AWS_REGION=us-west-2` y `CB_OPERATOR_VERSION=2.92.0`, de forma que los comandos posteriores consuman valores consistentes.

- {% include step_label.html %} Carga las variables en la terminal actual y confirma los tres valores críticos antes de crear recursos AWS.

  ```bash
  source lab.env

  printf 'REGION=%s\nEKS=%s\nOPERATOR=%s\n' \
    "$AWS_REGION" \
    "$EKS_CLUSTER" \
    "$CB_OPERATOR_VERSION"
  ```

**Salida esperada:** La terminal debe mostrar los valores cargados para región, nombre del clúster EKS y versión del Operator, confirmando que `source lab.env` dejó disponibles las variables requeridas antes de crear infraestructura.

```text
REGION=us-west-2
EKS=cb-cs400-lab12
OPERATOR=2.92.0
```

## Crear EKS

- {% include step_label.html %} Crea el script de ciclo de vida EKS con cuatro workers `m6i.xlarge` distribuidos entre tres AZ y los add-ons necesarios para Couchbase y EBS.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab12/eks-cluster.sh
  ```

**Salida esperada:** Debe existir `scripts/eks-cluster.sh` como archivo descargado correctamente y listo para administrar el ciclo de vida del entorno mediante las acciones `create`, `status` y `delete` utilizadas en la práctica.


- {% include step_label.html %} Habilita el script y valida su sintaxis Bash antes de realizar cualquier llamada a AWS.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```

**Salida esperada:** `bash -n` no debe imprimir errores ni advertencias de sintaxis; una salida vacía confirma que `scripts/eks-cluster.sh` puede interpretarse correctamente antes de ejecutar operaciones contra AWS.


- {% include step_label.html %} Crea EKS y espera hasta que los cuatro workers estén listos.

  ```bash
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** La salida debe mostrar cuatro nodos `m6i.xlarge` en estado `Ready`, distribuidos entre las zonas `us-west-2a`, `us-west-2b` y `us-west-2c`, confirmando que EKS dispone de capacidad para los cuatro Pods Couchbase.


## StorageClass y Operator

- {% include step_label.html %} Crea la StorageClass gp3 con EBS CSI y `WaitForFirstConsumer` para que cada volumen se aprovisione en una zona compatible con su Pod.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'EOF'
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
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/storageclass-gp3.yaml` con `ebs.csi.aws.com`, tipo `gp3` y `WaitForFirstConsumer`, dejando definida la política de almacenamiento que utilizarán posteriormente los volúmenes persistentes.


- {% include step_label.html %} Aplica la StorageClass antes de crear Couchbase Pods con almacenamiento persistente.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

**Salida esperada:** Kubernetes debe indicar que `storageclass.storage.k8s.io/gp3-couchbase` fue creada o configurada, confirmando que la clase de almacenamiento gp3 está registrada y disponible antes del despliegue de Couchbase.


- {% include step_label.html %} Agrega el repositorio oficial de Couchbase y actualiza su índice local.

  ```bash
  helm repo add couchbase \
    https://couchbase-partners.github.io/helm-charts/

  helm repo update
  ```

**Salida esperada:** Helm debe confirmar que el repositorio `couchbase` quedó registrado y que el índice local de charts fue actualizado sin errores, permitiendo resolver correctamente el chart del Couchbase Kubernetes Operator.


- {% include step_label.html %} Instala Operator 2.92.0, Admission Controller y CRDs sin crear automáticamente un `CouchbaseCluster`.
  ```bash
  helm upgrade --install cb-operator \
    couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

**Salida esperada:** La instalación debe finalizar con la release `cb-operator` desplegada o actualizada en el namespace `couchbase`, dejando disponibles Operator, Admission Controller y CRDs sin crear todavía un `CouchbaseCluster`.


- {% include step_label.html %} Espera que todos los Deployments instalados por el chart estén disponibles antes de crear Custom Resources.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

**Salida esperada:** Todos los Deployments del namespace deben alcanzar la condición `Available` antes del timeout, confirmando que los componentes instalados por el chart están operativos y listos para procesar Custom Resources.


## CouchbaseCluster y bucket

- {% include step_label.html %} Crea el Secret administrativo que utilizará Operator para inicializar Couchbase Server sin imprimir los valores codificados.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
  | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe crear o configurar `secret/cb-admin` sin mostrar errores, confirmando que las credenciales administrativas quedaron almacenadas y disponibles para que Operator inicialice Couchbase Server.


- {% include step_label.html %} Crea el `CouchbaseCluster` completo desde el inicio con dos Data Pods y dos Query + Index Pods, manteniendo anti-affinity y persistencia gp3.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-cs400
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-7.6.2

    antiAffinity: true

    security:
      adminSecret: cb-admin
      podSecurityContext:
        fsGroup: 1000

    cluster:
      dataServiceMemoryQuota: 1Gi
      indexServiceMemoryQuota: 1Gi
      indexer:
        storageMode: plasma

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - query

    buckets:
      managed: true

    servers:
      - name: data
        size: 2
        services:
          - data
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: data-volume

      - name: query-index
        size: 2
        services:
          - query
          - index
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: index-volume

    volumeClaimTemplates:
      - metadata:
          name: data-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 30Gi

      - metadata:
          name: index-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 20Gi
  EOF
  ```

**Salida esperada:** Debe generarse `manifests/couchbase-cluster.yaml` con cuatro Pods Couchbase, cuotas Data e Index de `1Gi`, almacenamiento Plasma y volúmenes gp3, conservando la topología de dos Data y dos Query + Index.


- {% include step_label.html %} Revisa el recurso mediante Server-Side Diff para detectar errores de schema antes de registrarlo en Kubernetes.

  ```bash
  kubectl diff \
    --server-side \
    -f manifests/couchbase-cluster.yaml || true
  ```

**Salida esperada:** `kubectl diff` debe mostrar únicamente las diferencias que se aplicarían al crear el recurso; la presencia de cambios es esperada y `|| true` evita que el código propio de `diff` detenga la secuencia del laboratorio.


- {% include step_label.html %} Aplica el `CouchbaseCluster` mediante Server-Side Apply, requerido por el tamaño actual del CRD de Operator 2.9.

  ```bash
  kubectl apply \
    --server-side \
    -f manifests/couchbase-cluster.yaml
  ```

**Salida esperada:** Kubernetes debe confirmar la creación de `couchbasecluster.couchbase.com/cb-cs400`, demostrando que el manifiesto fue aceptado por el API Server y quedó registrado para que Operator inicie la reconciliación.


- {% include step_label.html %} Espera la convergencia del clúster antes de crear buckets, scopes, collections o índices.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    couchbasecluster/"$CB_CLUSTER" \
    --timeout=15m
  ```

**Salida esperada:** La espera debe finalizar con `condition met`, confirmando que el recurso `CouchbaseCluster` alcanzó la condición `Available` y que el clúster terminó su convergencia antes de crear recursos de datos.


- {% include step_label.html %} Verifica que los cuatro Pods Couchbase estén `Running` antes de continuar.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o wide
  ```

**Salida esperada:** La lista debe mostrar cuatro Pods Couchbase en estado `Running`, con dos Pods destinados a Data y dos a Query + Index, confirmando que la topología declarada fue materializada correctamente por Operator.


- {% include step_label.html %} Crea el bucket administrado con 512Mi por Data Pod, una réplica y Couchstore para conservar un backend determinista durante las pruebas.

  ```bash
  cat > manifests/lab12-bucket.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab12-load
    namespace: couchbase
  spec:
    memoryQuota: 512Mi
    replicas: 1
    storageBackend: couchstore
    evictionPolicy: valueOnly
    conflictResolution: seqno
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/lab12-bucket.yaml` con `memoryQuota: 512Mi`, una réplica, Couchstore y `valueOnly`, dejando documentada la configuración inicial del bucket para las pruebas de carga y memoria.


- {% include step_label.html %} Aplica el bucket después de haber reservado 1Gi de Data Service memory por Data Pod.

  ```bash
  kubectl apply -f manifests/lab12-bucket.yaml
  ```

**Salida esperada:** Kubernetes debe crear `couchbasebucket.couchbase.com/lab12-load` sin rechazos de admisión ni errores de cuota, confirmando que los `512Mi` solicitados son compatibles con la reserva del Data Service.


## Port-forward y colección

- {% include step_label.html %} En una terminal separada publica Management REST mediante el Service estable del clúster para mantener acceso aunque cambien Pods.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    service/cb-cs400-ui \
    8091:8091
  ```

**Salida esperada:** La terminal debe permanecer ocupada mostrando `Forwarding ... 8091 -> 8091`; esto confirma que Management REST está publicado localmente y disponible para las llamadas posteriores realizadas con `curl`.


- {% include step_label.html %} Descubre dinámicamente un Pod que ejecute Query Service usando las labels creadas por Operator, sin depender de nombres de server class.

  ```bash
  QUERY_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_query=enabled" \
      -o jsonpath='{.items[0].metadata.name}'
  )

  echo "QUERY_POD=$QUERY_POD"
  ```

**Salida esperada:** `QUERY_POD` debe imprimirse con un nombre ordinal válido de Pod Couchbase y no quedar vacío, confirmando que el selector detectó dinámicamente una instancia que ejecuta Query Service.


- {% include step_label.html %} En otra terminal publica Query Service 8093 desde el Pod descubierto para ejecutar SQL++ desde Git Bash.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    "pod/${QUERY_POD}" \
    8093:8093
  ```

**Salida esperada:** La segunda terminal debe permanecer activa mostrando `Forwarding ... 8093 -> 8093`, confirmando que Query Service está accesible localmente y listo para recibir las sentencias SQL++ del laboratorio.


- {% include step_label.html %} Crea el scope `workload` dentro del bucket y valida que Query Service confirme la operación.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=CREATE SCOPE `lab12-load`.workload IF NOT EXISTS' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder con `status: "success"` y sin errores, confirmando que el scope `workload` quedó creado dentro de `lab12-load` y puede utilizarse como contexto para las colecciones posteriores.


- {% include step_label.html %} Crea la colección `items` dentro del scope antes de cargar los documentos utilizados por todos los escenarios.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=CREATE COLLECTION `lab12-load`.workload.items IF NOT EXISTS' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` sin errores, confirmando que la colección `items` quedó creada dentro de `lab12-load.workload` y está disponible para recibir el dataset de 200,000 documentos.


## Cliente y dataset

- {% include step_label.html %} Crea el Pod cliente Python y monta las credenciales administrativas desde el Secret para evitar contraseñas hardcodeadas en los scripts.

  ```bash
  cat > manifests/load-client.yaml << 'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-lab12-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 14400"]
        env:
          - name: CB_USER
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: username
          - name: CB_PASS
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: password
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2"
            memory: "2Gi"
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/load-client.yaml` con las variables `CB_USER` y `CB_PASS` referenciadas desde `cb-admin`, confirmando que el cliente obtiene credenciales desde Kubernetes y no desde valores hardcodeados.


- {% include step_label.html %} Aplica el Pod cliente dentro del namespace Couchbase.

  ```bash
  kubectl apply -f manifests/load-client.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `pod/cb-lab12-client`, dejando disponible el cliente Python que se utilizará para instalar el SDK, cargar el dataset y ejecutar los workloads KV desde el clúster EKS.


- {% include step_label.html %} Espera que el Pod cliente alcance `Ready` antes de instalar dependencias.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Ready \
    pod/cb-lab12-client \
    --timeout=3m
  ```

**Salida esperada:** La espera debe finalizar con `condition met`, confirmando que `cb-lab12-client` alcanzó `Ready` y que su contenedor puede recibir comandos antes de instalar dependencias o copiar scripts.


- {% include step_label.html %} Instala Couchbase Python SDK dentro del cliente para ejecutar seed y workloads KV desde EKS.

  ```bash
  kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab12-client \
    -- \
    pip install --quiet 'couchbase>=4.4,<5'
  ```

**Salida esperada:** `pip` debe terminar sin errores de instalación; los avisos informativos sobre una versión más reciente pueden aparecer, pero el SDK Couchbase debe quedar importable dentro de `cb-lab12-client`.


- {% include step_label.html %} Crea el generador determinista de 200,000 documentos que reutilizará el mismo schema en todas las pruebas.

  ```bash
  cat > scripts/seed_dataset.py << 'PYEOF'
  import os
  from datetime import datetime, timedelta, timezone

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  TOTAL = 200_000
  BATCH = 1000

  TYPES = ["order", "quote", "invoice", "shipment"]
  CATEGORIES = ["hardware", "software", "services", "training"]
  REGIONS = ["north", "south", "east", "west"]

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket("lab12-load")
      .scope("workload")
      .collection("items")
  )

  base = datetime(2026, 1, 1, tzinfo=timezone.utc)

  for start in range(0, TOTAL, BATCH):
      docs = {}

      for i in range(start, min(start + BATCH, TOTAL)):
          created = base + timedelta(minutes=i % 260000)

          docs[f"item::{i:09d}"] = {
              "order_id": i,
              "type": TYPES[i % 4],
              "category": CATEGORIES[i % 4],
              "value": round(50 + ((i * 17) % 50000) / 100, 2),
              "created_at": created.isoformat(),
              "region": REGIONS[i % 4],
              "payload": "x" * 512
          }

      collection.upsert_multi(docs)
      print(
          f"seeded={min(start + BATCH, TOTAL)}",
          flush=True
      )

  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/seed_dataset.py` con el generador determinista de 200,000 documentos, manteniendo el mismo esquema y distribución de campos para que todos los escenarios posteriores sean comparables.


- {% include step_label.html %} Valida la sintaxis Python del generador antes de copiarlo al Pod cliente.

  ```bash
  python -m py_compile scripts/seed_dataset.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma que `seed_dataset.py` es sintácticamente válido antes de copiarlo y ejecutarlo dentro del Pod cliente.


- {% include step_label.html %} Copia el script al Pod desactivando la conversión de rutas de Git Bash para el destino `/tmp`.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/seed_dataset.py \
    couchbase/cb-lab12-client:/tmp/seed_dataset.py
  ```

**Salida esperada:** `kubectl cp` debe completar la copia sin errores, confirmando que `seed_dataset.py` quedó disponible como `/tmp/seed_dataset.py` dentro del Pod y que Git Bash no alteró la ruta Unix del destino.


- {% include step_label.html %} Ejecuta el seed dentro del Pod y espera que la última tanda complete los 200,000 documentos.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab12-client \
    -- \
    python /tmp/seed_dataset.py
  ```

**Salida esperada:** La ejecución debe mostrar el avance por lotes hasta que la última línea indique `seeded=200000`, confirmando que el dataset completo fue escrito en la colección y quedó listo para las pruebas posteriores.


---

## 🔎 Tarea 1. Validar entorno y documentar escenarios — 5 min

### Tarea 1.1. Validar los 200K documentos

- {% include step_label.html %} Cuenta los documentos de la colección para confirmar que el seed terminó completo antes de ejecutar cualquier carga o benchmark.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT COUNT(*) AS total
      FROM `lab12-load`.workload.items' \
  | jq '.results[0]'
  ```

**Salida esperada:** La consulta debe devolver exactamente `total: 200000`, confirmando que la colección contiene el volumen previsto y que no faltan documentos antes de comenzar las mediciones de carga, SQL++ e índices.

```json
{
  "total": 200000
}
```

### Tarea 1.2. Crear cuatro escenarios

- {% include step_label.html %} Documenta el escenario A de escritura intensiva con 20% GET, 80% UPSERT, distribución uniforme y 16 workers.

  ```bash
  cat > scenarios/scenario-A.yaml << 'EOF'
  scenario: kv-write-heavy
  operations:
    get_pct: 20
    upsert_pct: 80
  distribution: uniform
  workers: 16
  duration_seconds: 60
  EOF
  ```

**Salida esperada:** Debe crearse `scenarios/scenario-A.yaml` con la mezcla 20% GET / 80% UPSERT, 16 workers y 60 segundos, dejando documentados los parámetros que se utilizarán para la prueba KV de escritura intensiva.


- {% include step_label.html %} Documenta el escenario B con mezcla 70/30 y niveles progresivos de concurrencia para estudiar throughput y crecimiento de latencia.

  ```bash
  cat > scenarios/scenario-B.yaml << 'EOF'
  scenario: kv-mixed-progressive
  operations:
    get_pct: 70
    upsert_pct: 30
  distribution: uniform
  workers: [4, 8, 16, 32]
  duration_per_level_seconds: 60
  saturation_rule:
    throughput_gain_pct_below: 10
    p95_growth_pct_above: 25
  EOF
  ```

**Salida esperada:** Debe crearse `scenarios/scenario-B.yaml` con la mezcla 70% GET / 30% UPSERT y los niveles 4, 8, 16 y 32 workers, incluyendo la regla pedagógica utilizada para identificar un candidato de saturación.


- {% include step_label.html %} Documenta el escenario C para comparar un secondary index no cubierto con un covering index sobre el mismo patrón de consulta.

  ```bash
  cat > scenarios/scenario-C.yaml << 'EOF'
  scenario: sqlpp-selective-lookup
  filter:
    category: hardware
    region: north
  objective: compare non-covering and covering index
  measured_requests: 20
  EOF
  ```

**Salida esperada:** Debe crearse `scenarios/scenario-C.yaml` con los filtros `hardware` y `north`, el objetivo de comparar índice no cubierto frente a covering index y 20 solicitudes previstas para la comparación.


- {% include step_label.html %} Documenta el escenario D de agregación por rango temporal que se utilizará para comparar PrimaryScan contra secondary index.

  ```bash
  cat > scenarios/scenario-D.yaml << 'EOF'
  scenario: sqlpp-range-aggregation
  range:
    start: 2026-01-01T00:00:00+00:00
    end: 2026-04-30T23:59:59+00:00
  group_by: type
  aggregates:
    - COUNT
    - AVG(value)
  measured_requests: 20
  EOF
  ```

**Salida esperada:** Debe crearse `scenarios/scenario-D.yaml` con el rango temporal, agrupación por `type`, agregados COUNT y AVG, y 20 solicitudes, documentando el escenario utilizado para comparar PrimaryScan y secondary index.


- {% include step_label.html %} Verifica que existan exactamente los cuatro archivos de escenarios antes de continuar.

  ```bash
  find scenarios \
    -maxdepth 1 \
    -name 'scenario-*.yaml' \
    -type f \
  | sort
  ```

**Salida esperada:** La salida debe listar exactamente `scenario-A.yaml`, `scenario-B.yaml`, `scenario-C.yaml` y `scenario-D.yaml`, confirmando que los cuatro escenarios fueron documentados y no falta ningún archivo requerido.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## ✍️ Tarea 2. Ejecutar workload KV write-heavy — 4 min

### Tarea 2.1. Crear motor de carga

- {% include step_label.html %} Crea un motor KV multihilo parametrizable que mida operaciones completadas, errores y latencias p50/p95/p99 durante una ventana fija.

  ```bash
  cat > scripts/kv_load.py << 'PYEOF'
  import argparse
  import json
  import math
  import os
  import random
  import threading
  import time
  from concurrent.futures import ThreadPoolExecutor
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  parser = argparse.ArgumentParser()
  parser.add_argument("--workers", type=int, required=True)
  parser.add_argument("--duration", type=int, default=60)
  parser.add_argument("--get-pct", type=float, required=True)
  parser.add_argument("--name", required=True)
  args = parser.parse_args()

  TOTAL = 200_000

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket("lab12-load")
      .scope("workload")
      .collection("items")
  )

  lock = threading.Lock()
  results = []
  deadline = time.time() + args.duration

  def worker(worker_id):
      local = {
          "errors": 0,
          "operations": 0,
          "gets": 0,
          "upserts": 0,
          "latencies": []
      }

      while time.time() < deadline:
          i = random.randrange(TOTAL)
          key = f"item::{i:09d}"
          started = time.perf_counter()

          try:
              if random.random() < args.get_pct / 100:
                  collection.get(key)
                  local["gets"] += 1
              else:
                  collection.upsert(
                      key,
                      {
                          "order_id": i,
                          "type": ["order", "quote", "invoice", "shipment"][i % 4],
                          "category": ["hardware", "software", "services", "training"][i % 4],
                          "value": round(50 + ((i * 17) % 50000) / 100, 2),
                          "created_at": f"2026-02-{(i % 28)+1:02d}T12:00:00+00:00",
                          "region": ["north", "south", "east", "west"][i % 4],
                          "payload": "x" * 512,
                          "updated_by": worker_id
                      }
                  )
                  local["upserts"] += 1

              local["operations"] += 1
              local["latencies"].append(
                  (time.perf_counter() - started) * 1000
              )

          except Exception:
              local["errors"] += 1

      with lock:
          results.append(local)

  def pct(values, p):
      if not values:
          return 0.0

      ordered = sorted(values)
      idx = max(
          math.ceil((p / 100) * len(ordered)) - 1,
          0
      )
      return ordered[min(idx, len(ordered) - 1)]

  started = time.time()

  with ThreadPoolExecutor(max_workers=args.workers) as pool:
      futures = [
          pool.submit(worker, i)
          for i in range(args.workers)
      ]
      for future in futures:
          future.result()

  elapsed = time.time() - started

  operations = sum(x["operations"] for x in results)
  errors = sum(x["errors"] for x in results)
  gets = sum(x["gets"] for x in results)
  upserts = sum(x["upserts"] for x in results)
  latencies = [
      latency
      for result in results
      for latency in result["latencies"]
  ]

  output = {
      "scenario": args.name,
      "workers": args.workers,
      "duration_seconds": round(elapsed, 2),
      "operations": operations,
      "ops_per_sec": round(operations / max(elapsed, 0.001), 1),
      "gets": gets,
      "upserts": upserts,
      "errors": errors,
      "error_rate_pct": round(
          errors / max(operations + errors, 1) * 100,
          4
      ),
      "p50_ms": round(pct(latencies, 50), 2),
      "p95_ms": round(pct(latencies, 95), 2),
      "p99_ms": round(pct(latencies, 99), 2)
  }

  print(json.dumps(output, indent=2))
  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/kv_load.py` con parámetros para workers, duración, porcentaje de GET y nombre del escenario, además de las mediciones de throughput, errores y latencias p50, p95 y p99.


- {% include step_label.html %} Valida la sintaxis Python antes de copiar el motor al Pod cliente.

  ```bash
  python -m py_compile scripts/kv_load.py
  ```

**Salida esperada:** `python -m py_compile` no debe mostrar errores; una salida vacía confirma que `kv_load.py` puede ejecutarse y que no contiene problemas de sintaxis antes de copiarlo al Pod cliente.


- {% include step_label.html %} Copia el motor al Pod cliente evitando que Git Bash convierta `/tmp/kv_load.py` en una ruta de Windows.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/kv_load.py \
    couchbase/cb-lab12-client:/tmp/kv_load.py
  ```

**Salida esperada:** `kubectl cp` debe finalizar sin errores, confirmando que el motor de carga quedó disponible como `/tmp/kv_load.py` dentro del Pod y que la ruta no fue modificada por la conversión automática de Git Bash.


### Tarea 2.2. Ejecutar 20% GET / 80% UPSERT

- {% include step_label.html %} Ejecuta el escenario A con 16 workers durante 60 segundos y conserva el JSON producido por el motor de carga.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab12-client \
    -- \
    python /tmp/kv_load.py \
      --workers 16 \
      --duration 60 \
      --get-pct 20 \
      --name kv-write-heavy \
  | tee results/scenario-A.json
  ```

**Salida esperada:** Debe generarse `results/scenario-A.json` con throughput mayor que cero, latencias p50/p95/p99, contadores GET/UPSERT y errores, proporcionando una evidencia cuantitativa del escenario write-heavy de 16 workers.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 📈 Tarea 3. Ejecutar carga mixta 4→8→16→32 — 8 min

### Tarea 3.1. Crear runner

- {% include step_label.html %} Crea un runner que repita exactamente la mezcla 70% GET / 30% UPSERT con cuatro niveles de concurrencia y una pausa corta entre mediciones.

  ```bash
  cat > scripts/run_progressive_load.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  for WORKERS in 4 8 16 32; do
    echo "=== workers=${WORKERS} ==="

    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-lab12-client \
      -- \
      python /tmp/kv_load.py \
        --workers "$WORKERS" \
        --duration 60 \
        --get-pct 70 \
        --name "kv-mixed-${WORKERS}" \
    | tee "${ROOT_DIR}/results/scenario-B-${WORKERS}.json"

    sleep 5
  done
  EOF
  ```

**Salida esperada:** Debe crearse `scripts/run_progressive_load.sh` con las cuatro ejecuciones de 4, 8, 16 y 32 workers, reutilizando la misma mezcla 70/30 para que los resultados de concurrencia puedan compararse directamente.


- {% include step_label.html %} Habilita el runner y valida su sintaxis Bash antes de ejecutar las cuatro cargas.

  ```bash
  chmod +x scripts/run_progressive_load.sh
  bash -n scripts/run_progressive_load.sh
  ```

**Salida esperada:** `bash -n` no debe devolver errores; la ausencia de salida confirma que el runner tiene sintaxis Bash válida y puede ejecutar secuencialmente los cuatro niveles de carga sin fallar por errores de interpretación.


- {% include step_label.html %} Ejecuta el runner y espera a que termine las cuatro ventanas de carga. **Puede tardar varios minutos**

  ```bash
  ./scripts/run_progressive_load.sh
  ```

**Salida esperada:** Al finalizar deben existir `scenario-B-4.json`, `scenario-B-8.json`, `scenario-B-16.json` y `scenario-B-32.json`, cada uno con las métricas obtenidas durante su propia ventana de carga de 60 segundos.


### Tarea 3.2. Mostrar tabla

- {% include step_label.html %} Resume los cuatro resultados en filas tabuladas para comparar concurrencia, throughput, p95, p99 y tasa de error.

  ```bash
  for W in 4 8 16 32; do
    jq -r '[
      .workers,
      .ops_per_sec,
      .p95_ms,
      .p99_ms,
      .error_rate_pct
    ] | @tsv' \
      "results/scenario-B-${W}.json"
  done
  ```

**Salida esperada:** La terminal debe mostrar cuatro filas, una por cada nivel de concurrencia, incluyendo workers, operaciones por segundo, p95, p99 y tasa de error, permitiendo comparar el comportamiento conforme aumenta la carga.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## 🎯 Tarea 4. Identificar candidato de saturación — 4 min

### Tarea 4.1. Analizar niveles consecutivos

- {% include step_label.html %} Crea un analizador que compare cada nivel contra el anterior utilizando la regla pedagógica de menos de 10% de ganancia y más de 25% de crecimiento de p95.

  ```bash
  cat > scripts/analyze_saturation.py << 'PYEOF'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  workers = [4, 8, 16, 32]

  rows = [
      json.loads(
          (root / "results" / f"scenario-B-{w}.json").read_text()
      )
      for w in workers
  ]

  candidate = None

  print("workers\tops/s\tp95\tgain%\tp95_growth%")

  for i, row in enumerate(rows):
      if i == 0:
          print(
              f"{row['workers']}\t"
              f"{row['ops_per_sec']}\t"
              f"{row['p95_ms']}\t-\t-"
          )
          continue

      prev = rows[i - 1]

      gain = (
          (row["ops_per_sec"] - prev["ops_per_sec"])
          / max(prev["ops_per_sec"], 1)
          * 100
      )

      latency_growth = (
          (row["p95_ms"] - prev["p95_ms"])
          / max(prev["p95_ms"], 0.001)
          * 100
      )

      print(
          f"{row['workers']}\t"
          f"{row['ops_per_sec']}\t"
          f"{row['p95_ms']}\t"
          f"{gain:.2f}\t"
          f"{latency_growth:.2f}"
      )

      if (
          candidate is None
          and gain < 10
          and latency_growth > 25
      ):
          candidate = {
              "from_workers": prev["workers"],
              "to_workers": row["workers"],
              "throughput_gain_pct": round(gain, 2),
              "p95_growth_pct": round(latency_growth, 2)
          }

  print()

  if candidate:
      print("SATURATION_CANDIDATE")
      print(json.dumps(candidate, indent=2))
  else:
      print("No level met the laboratory saturation rule.")
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/analyze_saturation.py` con la lógica que compara niveles consecutivos y aplica los umbrales de ganancia de throughput y crecimiento de p95 definidos para localizar un candidato de saturación.


- {% include step_label.html %} Valida la sintaxis Python del analizador antes de procesar los resultados.

  ```bash
  python -m py_compile scripts/analyze_saturation.py
  ```

**Salida esperada:** `python -m py_compile` no debe mostrar errores; una salida vacía confirma que `analyze_saturation.py` es válido y puede procesar los cuatro JSON de carga sin problemas de sintaxis.


- {% include step_label.html %} Ejecuta el análisis y conserva la tabla y el posible candidato de saturación.

  ```bash
  python scripts/analyze_saturation.py \
  | tee results/saturation-analysis.txt
  ```

**Salida esperada:** La salida debe comparar los cuatro niveles con throughput, p95, ganancia y crecimiento de latencia; al final debe indicar `SATURATION_CANDIDATE` o declarar que ningún nivel cumplió simultáneamente la regla.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🔍 Tarea 5. SQL++ baseline con EXPLAIN y PROFILE — 6 min

### Tarea 5.1. Crear primary index sólo para baseline

- {% include step_label.html %} Crea un primary index temporal para permitir un baseline deliberadamente general antes de introducir el secondary index optimizado.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=CREATE PRIMARY INDEX IF NOT EXISTS ON items' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` sin errores, confirmando que el primary index temporal fue creado y puede utilizarse para obtener un baseline deliberadamente general antes de optimizar.


- {% include step_label.html %} Espera que el primary index `#primary` quede `online` antes de capturar el plan baseline.

  ```bash
  for i in $(seq 1 60); do
    STATE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        -X POST \
        http://localhost:8093/query/service \
        --data-urlencode 'statement=
          SELECT RAW state
          FROM system:indexes
          WHERE bucket_id="lab12-load"
            AND scope_id="workload"
            AND keyspace_id="items"
            AND name="#primary"' \
      | jq -r '.results[0] // "missing"'
    )

    echo "Intento $i - state=$STATE"

    [[ "$STATE" == "online" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** La salida debe evolucionar hasta `state=online`, confirmando que el índice `#primary` terminó de construirse y está disponible para que el optimizador genere el plan baseline sin depender de un índice pendiente.


### Tarea 5.2. Capturar EXPLAIN baseline

- {% include step_label.html %} Captura el plan de la agregación por rango temporal antes del secondary index y guarda el JSON para compararlo después.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      EXPLAIN
      SELECT type,
            COUNT(*) AS total,
            AVG(`value`) AS avg_value
      FROM items
      WHERE created_at BETWEEN
        "2026-01-01T00:00:00+00:00"
        AND
        "2026-04-30T23:59:59+00:00"
      GROUP BY type
      ORDER BY total DESC' \
  | jq '.results[0]' \
  | tee results/scenario-D-explain-before.json
  ```

**Salida esperada:** Debe generarse `results/scenario-D-explain-before.json` con el plan completo del baseline, conservando operadores y estimaciones suficientes para compararlo posteriormente contra el plan con secondary index.


- {% include step_label.html %} Lista los operadores del plan para comprobar que el baseline utiliza un operador `PrimaryScan`.

  ```bash
  jq '.. | .["#operator"]? // empty' \
    results/scenario-D-explain-before.json \
  | sort -u
  ```

**Salida esperada:** La lista debe incluir un operador de escaneo primario, normalmente `PrimaryScan3` en Couchbase Server 7.6.x, asociado a `#primary`; también puede aparecer `Fetch` para recuperar los documentos completos.


### Tarea 5.3. Crear benchmark SQL++

- {% include step_label.html %} Crea un benchmark local que utilice el port-forward 8093 y las credenciales cargadas desde `lab.env` para ejecutar la misma consulta repetidamente.

  ```bash
  cat > scripts/query_benchmark.py << 'PYEOF'
  import argparse
  import base64
  import json
  import math
  import os
  import sys
  import time
  import urllib.parse
  import urllib.request

  parser = argparse.ArgumentParser()
  parser.add_argument("--statement", required=True)
  parser.add_argument("--name", required=True)
  parser.add_argument("--runs", type=int, default=20)
  args = parser.parse_args()

  endpoint = "http://localhost:8093/query/service"

  token = base64.b64encode(
      f"{os.environ['CB_USER']}:{os.environ['CB_PASS']}".encode()
  ).decode()


  def execute():
      body = urllib.parse.urlencode({
          "statement": args.statement,
          "query_context": "default:`lab12-load`.workload",
          "metrics": "true"
      }).encode()

      request = urllib.request.Request(
          endpoint,
          data=body,
          method="POST"
      )

      request.add_header(
          "Authorization",
          f"Basic {token}"
      )

      started = time.perf_counter()

      with urllib.request.urlopen(
          request,
          timeout=120
      ) as response:
          data = json.load(response)

      elapsed = (
          time.perf_counter() - started
      ) * 1000

      return elapsed, data.get("status")


  for i in range(3):
      print(
          f"Warm-up {i + 1}/3...",
          file=sys.stderr,
          flush=True
      )

      elapsed, status = execute()

      print(
          f"  {elapsed:.2f} ms - status={status}",
          file=sys.stderr,
          flush=True
      )


  samples = []
  errors = 0

  for i in range(args.runs):
      elapsed, status = execute()

      if status == "success":
          samples.append(elapsed)
      else:
          errors += 1

      print(
          f"Iteración {i + 1}/{args.runs} "
          f"- {elapsed:.2f} ms "
          f"- status={status}",
          file=sys.stderr,
          flush=True
      )


  ordered = sorted(samples)


  def pct(p):
      if not ordered:
          return 0.0

      idx = max(
          math.ceil((p / 100) * len(ordered)) - 1,
          0
      )

      return ordered[
          min(idx, len(ordered) - 1)
      ]


  result = {
      "name": args.name,
      "runs": args.runs,
      "successful": len(samples),
      "errors": errors,
      "avg_ms": round(
          sum(samples) / max(len(samples), 1),
          2
      ),
      "p50_ms": round(pct(50), 2),
      "p95_ms": round(pct(95), 2),
      "p99_ms": round(pct(99), 2)
  }

  print(
      json.dumps(
          result,
          indent=2
      )
  )
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/query_benchmark.py` con soporte para warm-up, número configurable de ejecuciones y métricas avg/p50/p95/p99, utilizando el port-forward 8093 y las credenciales cargadas desde `lab.env`.


- {% include step_label.html %} Valida la sintaxis del benchmark antes de medir.

  ```bash
  python -m py_compile scripts/query_benchmark.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma que el benchmark es sintácticamente válido antes de iniciar las mediciones repetidas contra Query Service.


- {% include step_label.html %} Ejecuta 20 mediciones del baseline y guarda latencias promedio y percentiles. **Puede tardar varios minutos**

  ```bash
  python scripts/query_benchmark.py \
    --name scenario-D-before \
    --runs 20 \
    --statement 'SELECT type, COUNT(*) AS total, AVG(`value`) AS avg_value FROM items WHERE created_at BETWEEN "2026-01-01T00:00:00+00:00" AND "2026-04-30T23:59:59+00:00" GROUP BY type ORDER BY total DESC' \
  | tee results/scenario-D-before.json
  ```

**Salida esperada:** Durante la ejecución deben mostrarse warm-ups e iteraciones con latencia y `status=success`; al finalizar, `scenario-D-before.json` debe registrar 20 ejecuciones exitosas, cero errores y sus percentiles.


### Tarea 5.4. Ejecutar PROFILE de referencia

- {% include step_label.html %} Ejecuta la consulta baseline con `profile=timings` para conservar métricas y detalles de operadores como evidencia adicional.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'profile=timings' \
    --data-urlencode 'statement=
      SELECT type,
            COUNT(*) AS total,
            AVG(`value`) AS avg_value
      FROM items
      WHERE created_at BETWEEN
        "2026-01-01T00:00:00+00:00"
        AND
        "2026-04-30T23:59:59+00:00"
      GROUP BY type
      ORDER BY total DESC' \
  | jq '{status, metrics, profile}' \
  | tee results/scenario-D-profile-before.json
  ```

**Salida esperada:** La respuesta debe mostrar `status: "success"`, métricas y datos de perfil, y guardar `scenario-D-profile-before.json`, conservando tiempos y operadores del baseline como evidencia previa a la optimización.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## ⚙️ Tarea 6. Crear secondary index y medir mejora — 6 min

### Tarea 6.1. Crear índice

- {% include step_label.html %} Crea `idx_created_type_value` con una réplica; los dos Pods Query + Index permiten alojar índice y réplica en Index Service nodes distintos.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      CREATE INDEX idx_created_type_value
      ON items(created_at, type, `value`)
      WITH {"num_replica":1}' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` sin errores, confirmando que `idx_created_type_value` y su réplica fueron aceptados y que existen suficientes Index Service nodes para alojarlos.


### Tarea 6.2. Esperar online

- {% include step_label.html %} Espera que el índice y su metadata principal alcancen estado `online` antes de capturar el nuevo plan.

  ```bash
  INDEX_READY=false

  for i in $(seq 1 60); do
    STATE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        -X POST \
        http://localhost:8093/query/service \
        --data-urlencode 'statement=
          SELECT RAW state
          FROM system:indexes
          WHERE bucket_id="lab12-load"
            AND scope_id="workload"
            AND keyspace_id="items"
            AND name="idx_created_type_value"' \
      | jq -r '.results[0] // "missing"'
    )

    echo "Intento $i - state=$STATE"

    if [[ "$STATE" == "online" ]]; then
      INDEX_READY=true
      break
    fi

    sleep 2
  done

  if [[ "$INDEX_READY" == "true" ]]; then
    echo "PASS: idx_created_type_value online"
  else
    echo "FAIL: idx_created_type_value no alcanzó online"
  fi
  ```

**Salida esperada:** La espera debe finalizar con `PASS: idx_created_type_value online`, confirmando que el secondary index terminó su construcción y está disponible antes de capturar el nuevo plan de ejecución.


### Tarea 6.3. Capturar EXPLAIN post-index

- {% include step_label.html %} Captura nuevamente el mismo `EXPLAIN` para comprobar que el optimizador abandona el PrimaryScan y selecciona el secondary index.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      EXPLAIN
      SELECT type,
            COUNT(*) AS total,
            AVG(`value`) AS avg_value
      FROM items
      WHERE created_at BETWEEN
        "2026-01-01T00:00:00+00:00"
        AND
        "2026-04-30T23:59:59+00:00"
      GROUP BY type
      ORDER BY total DESC' \
  | jq '.results[0]' \
  | tee results/scenario-D-explain-after.json
  ```

**Salida esperada:** Debe generarse `results/scenario-D-explain-after.json` con el plan posterior a la creación del secondary index, permitiendo verificar que el optimizador seleccionó una ruta distinta al escaneo primario.


- {% include step_label.html %} Busca explícitamente el nombre del secondary index dentro del plan optimizado.

  ```bash
  grep -o 'idx_created_type_value' \
    results/scenario-D-explain-after.json \
  | head -n1
  ```

**Salida esperada:** La salida debe mostrar `idx_created_type_value`, confirmando que el nombre del secondary index aparece dentro del plan optimizado y que el optimizador lo seleccionó para resolver la consulta del escenario D.

```text
idx_created_type_value
```

- {% include step_label.html %} Comprueba que el plan optimizado ya no contiene un operador `PrimaryScan`.

  ```bash
  jq '[
      .. |
      objects |
      .["#operator"]? |
      select(type == "string" and contains("PrimaryScan"))
    ] | length' \
    results/scenario-D-explain-after.json
  ```

**Salida esperada:** El resultado debe ser `0`, confirmando que el plan posterior a la optimización no contiene operadores cuyo nombre incluya `PrimaryScan` y que el acceso basado en el índice primario fue eliminado.

```text
0
```

### Tarea 6.4. Medir otra vez

- {% include step_label.html %} Repite exactamente el benchmark SQL++ de 20 ejecuciones para comparar latencia con el baseline bajo el nuevo plan.

  ```bash
  python scripts/query_benchmark.py \
    --name scenario-D-after \
    --runs 20 \
    --statement 'SELECT type, COUNT(*) AS total, AVG(`value`) AS avg_value FROM items WHERE created_at BETWEEN "2026-01-01T00:00:00+00:00" AND "2026-04-30T23:59:59+00:00" GROUP BY type ORDER BY total DESC' \
  | tee results/scenario-D-after.json
  ```

**Salida esperada:** Debe generarse `scenario-D-after.json` con las mismas métricas y 20 ejecuciones comparables al baseline, permitiendo medir el efecto real del secondary index sin imponer de antemano un porcentaje de mejora.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 🧱 Tarea 7. Crear covering index y demostrar ausencia de Fetch — 5 min

### Tarea 7.1. Crear índice no cubierto

- {% include step_label.html %} Crea un índice que resuelve `category`, `region` y `created_at`, pero no contiene `type` ni `value`, por lo que el plan debe recuperar documentos mediante Fetch.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      CREATE INDEX idx_category_region
      ON items(category, region, created_at)
      WITH {"num_replica":1}' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"`, confirmando que `idx_category_region` fue creado con su réplica y quedó registrado como índice deliberadamente no cubierto para el escenario C.


- {% include step_label.html %} Espera que `idx_category_region` esté `online` antes de forzarlo con `USE INDEX`.

  ```bash
  for i in $(seq 1 60); do
    STATE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        -X POST \
        http://localhost:8093/query/service \
        --data-urlencode 'statement=
          SELECT RAW state
          FROM system:indexes
          WHERE bucket_id="lab12-load"
            AND scope_id="workload"
            AND keyspace_id="items"
            AND name="idx_category_region"' \
      | jq -r '.results[0] // "missing"'
    )

    echo "Intento $i - state=$STATE"
    [[ "$STATE" == "online" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** La salida debe alcanzar `state=online`, confirmando que `idx_category_region` terminó de construirse y está disponible antes de forzar su utilización mediante `USE INDEX` en el EXPLAIN no cubierto.


### Tarea 7.2. EXPLAIN no cubierto

- {% include step_label.html %} Captura un plan forzado al índice no cubierto para demostrar que los campos proyectados que faltan requieren acceso al documento.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      EXPLAIN
      SELECT category, region, type, `value`, created_at
      FROM items
      USE INDEX (idx_category_region USING GSI)
      WHERE category="hardware"
        AND region="north"
        AND created_at >= "2026-01-01T00:00:00+00:00"' \
  | jq '.results[0]' \
  | tee results/scenario-C-noncovering.json
  ```

**Salida esperada:** Debe generarse `results/scenario-C-noncovering.json` con el plan forzado a `idx_category_region`, conservando los operadores necesarios para demostrar que los campos no indexados obligan a recuperar documentos.


- {% include step_label.html %} Cuenta los operadores `Fetch` del plan no cubierto.

  ```bash
  jq '[
      .. |
      objects |
      .["#operator"]? |
      select(. == "Fetch")
    ] | length' \
    results/scenario-C-noncovering.json
  ```

**Salida esperada:** El conteo debe ser mayor que `0`, confirmando que el plan no cubierto contiene al menos un operador `Fetch` y que Query Service necesita acceder a los documentos para obtener `type` y `value`.


### Tarea 7.3. Crear índice cubierto

- {% include step_label.html %} Crea un índice que incluya tanto los predicados como `type` y `value` para que la consulta pueda resolverse desde el índice.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      CREATE INDEX idx_cover_category_region
      ON items(category, region, created_at, type, `value`)
      WITH {"num_replica":1}' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder `status: "success"`, confirmando que `idx_cover_category_region` fue creado con todos los campos requeridos para resolver desde el índice tanto predicados como proyección.


- {% include step_label.html %} Espera que `idx_cover_category_region` quede `online` antes de validar el plan cubierto.

  ```bash
  for i in $(seq 1 60); do
    STATE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        -X POST \
        http://localhost:8093/query/service \
        --data-urlencode 'statement=
          SELECT RAW state
          FROM system:indexes
          WHERE bucket_id="lab12-load"
            AND scope_id="workload"
            AND keyspace_id="items"
            AND name="idx_cover_category_region"' \
      | jq -r '.results[0] // "missing"'
    )

    echo "Intento $i - state=$STATE"
    [[ "$STATE" == "online" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** La salida debe alcanzar `state=online`, confirmando que `idx_cover_category_region` terminó de construirse y puede utilizarse de forma segura antes de capturar el EXPLAIN del plan cubierto.


### Tarea 7.4. EXPLAIN cubierto

- {% include step_label.html %} Captura el mismo patrón de consulta forzando el covering index para comparar sus operadores con el plan no cubierto.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=
      EXPLAIN
      SELECT category, region, type, `value`, created_at
      FROM items
      USE INDEX (idx_cover_category_region USING GSI)
      WHERE category="hardware"
        AND region="north"
        AND created_at >= "2026-01-01T00:00:00+00:00"' \
  | jq '.results[0]' \
  | tee results/scenario-C-covering.json
  ```

**Salida esperada:** Debe generarse `results/scenario-C-covering.json` con el plan forzado al covering index, proporcionando la evidencia necesaria para compararlo directamente con el plan no cubierto capturado anteriormente.


### Tarea 7.5. Validar no Fetch y covers

- {% include step_label.html %} Cuenta los operadores `Fetch` del plan cubierto; un covering index correcto no debe requerir recuperación adicional del documento.

  ```bash
  jq '[
      .. |
      objects |
      .["#operator"]? |
      select(. == "Fetch")
    ] | length' \
    results/scenario-C-covering.json
  ```

**Salida esperada:** El resultado debe ser exactamente `0`, confirmando que el plan cubierto no contiene operadores `Fetch` y que los campos solicitados pueden resolverse directamente desde el covering index.

```text
0
```

- {% include step_label.html %} Extrae las propiedades `covers` presentes en el plan como evidencia complementaria de cobertura.

  ```bash
  jq '.. | .covers? // empty' \
    results/scenario-C-covering.json
  ```

**Salida esperada:** La salida debe mostrar al menos un arreglo `covers` con expresiones provenientes del índice, proporcionando evidencia adicional de que el optimizador puede satisfacer la consulta sin recuperar documentos completos.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🧠 Tarea 8. Ajustar memoryQuota y repetir carga crítica — 4 min

### Tarea 8.1. Capturar estado actual

- {% include step_label.html %} Registra la cuota declarada, eviction policy y réplicas del bucket antes de realizar el experimento de memoria.

  ```bash
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '{
      memoryQuota: .spec.memoryQuota,
      evictionPolicy: .spec.evictionPolicy,
      replicas: .spec.replicas
    }'
  ```

**Salida esperada:** La salida debe mostrar `memoryQuota: "512Mi"`, `evictionPolicy: "valueOnly"` y una réplica, registrando el estado declarativo inicial del bucket antes de modificar la cuota de memoria.


### Tarea 8.2. Revisar allocations

- {% include step_label.html %} Guarda las allocations publicadas por el `CouchbaseCluster` como evidencia previa al cambio de memoria.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '.status.allocations // {}' \
  | tee results/memory-allocation-before.json
  ```

**Salida esperada:** Debe crearse `results/memory-allocation-before.json` con las allocations reportadas por el `CouchbaseCluster`; el contenido puede variar por versión, pero el archivo debe conservar la evidencia previa al cambio.


### Tarea 8.3. Cambiar 512Mi → 768Mi

- {% include step_label.html %} Modifica únicamente `memoryQuota` de `CouchbaseBucket` como cambio declarativo controlado; `dataServiceMemoryQuota=1Gi` ya permite este valor.

  ```bash
  kubectl patch couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    --type=merge \
    -p '{"spec":{"memoryQuota":"768Mi"}}'
  ```

**Salida esperada:** Kubernetes debe confirmar que `lab12-load` fue `patched`, demostrando que el cambio declarativo de `memoryQuota` a `768Mi` fue aceptado por el API Server y entregado a Operator para reconciliación.


- {% include step_label.html %} Calcula la cuota REST total esperada como 768Mi multiplicado por el número actual de Data nodes y espera la convergencia.

  ```bash
  BUCKET_READY=false

  DATA_NODES=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
    | jq '[
        .nodes[]
        | select(.services | index("kv"))
      ] | length'
  )

  EXPECTED_TOTAL_MIB=$((768 * DATA_NODES))

  echo "Data nodes: $DATA_NODES"
  echo "Total esperado: ${EXPECTED_TOTAL_MIB}MiB"

  for i in $(seq 1 30); do
    ACTUAL_TOTAL_MIB=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
      | jq -r '.quota.ram / 1024 / 1024 | floor'
    )

    echo "Intento $i - actual=${ACTUAL_TOTAL_MIB}MiB esperado=${EXPECTED_TOTAL_MIB}MiB"

    if [[ "$ACTUAL_TOTAL_MIB" -eq "$EXPECTED_TOTAL_MIB" ]]; then
      BUCKET_READY=true
      break
    fi

    sleep 2
  done

  if [[ "$BUCKET_READY" == "true" ]]; then
    echo "PASS: la cuota del bucket convergió correctamente."
  else
    echo "FAIL: la cuota del bucket no convergió dentro del tiempo esperado."
  fi
  ```

**Salida esperada:** Con dos Data nodes debe calcularse `Total esperado: 1536MiB`; los reintentos deben converger al mismo valor REST y finalizar con `PASS`, confirmando que la cuota declarada fue aplicada al bucket.


### Tarea 8.4. Repetir carga de 32 workers

- {% include step_label.html %} Repite exactamente la carga mixta de 32 workers para comparar el comportamiento antes y después del cambio de cuota.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab12-client \
    -- \
    python /tmp/kv_load.py \
      --workers 32 \
      --duration 60 \
      --get-pct 70 \
      --name kv-mixed-32-post-memory \
  | tee results/scenario-B-32-post-memory.json
  ```

**Salida esperada:** Debe generarse `scenario-B-32-post-memory.json` con las mismas métricas del escenario de 32 workers, permitiendo comparar 512Mi frente a 768Mi sin asumir que el cambio producirá necesariamente una mejora.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 📊 Tarea 9. Comparar KPIs automáticamente — 3 min

### Tarea 9.1. Crear generador de reporte

- {% include step_label.html %} Crea un generador que lea los JSON medidos y calcule automáticamente los cambios porcentuales sin hardcodear mejoras.

  ```bash
  cat > scripts/build_report.py << 'PYEOF'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent

  def load(name):
      return json.loads(
          (root / "results" / name).read_text()
      )

  d_before = load("scenario-D-before.json")
  d_after = load("scenario-D-after.json")
  kv_before = load("scenario-B-32.json")
  kv_after = load("scenario-B-32-post-memory.json")

  def delta(before, after):
      if before == 0:
          return 0.0

      return (
          (after - before)
          / before
          * 100
      )

  report = f"""# Reporte comparativo — Lab 12

  ## Escenario D — SQL++

  | Métrica | Antes | Después | Cambio |
  |---|---:|---:|---:|
  | Avg ms | {d_before['avg_ms']} | {d_after['avg_ms']} | {delta(d_before['avg_ms'], d_after['avg_ms']):.2f}% |
  | P50 ms | {d_before['p50_ms']} | {d_after['p50_ms']} | {delta(d_before['p50_ms'], d_after['p50_ms']):.2f}% |
  | P95 ms | {d_before['p95_ms']} | {d_after['p95_ms']} | {delta(d_before['p95_ms'], d_after['p95_ms']):.2f}% |
  | P99 ms | {d_before['p99_ms']} | {d_after['p99_ms']} | {delta(d_before['p99_ms'], d_after['p99_ms']):.2f}% |

  Un cambio negativo en latencia representa reducción del tiempo.

  ## Escenario B — 32 workers

  | Métrica | 512Mi/Pod | 768Mi/Pod | Cambio |
  |---|---:|---:|---:|
  | ops/s | {kv_before['ops_per_sec']} | {kv_after['ops_per_sec']} | {delta(kv_before['ops_per_sec'], kv_after['ops_per_sec']):.2f}% |
  | P95 ms | {kv_before['p95_ms']} | {kv_after['p95_ms']} | {delta(kv_before['p95_ms'], kv_after['p95_ms']):.2f}% |
  | P99 ms | {kv_before['p99_ms']} | {kv_after['p99_ms']} | {delta(kv_before['p99_ms'], kv_after['p99_ms']):.2f}% |
  | errors | {kv_before['errors']} | {kv_after['errors']} | — |

  ## Optimizaciones validadas

  1. Secondary index para sustituir el acceso basado en primary index.
  2. Covering index validado por ausencia de Fetch.
  3. memoryQuota 512Mi → 768Mi por Data Pod evaluada mediante re-test.

  ## Regla

  Una modificación sólo se considera mejora cuando el KPI objetivo mejora después de repetir la misma prueba.
  """

  (root / "reports" / "comparison.md").write_text(
      report,
      encoding="utf-8"
  )

  print(report)
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/build_report.py` con la lectura de los cuatro JSON requeridos y los cálculos porcentuales de cambio, dejando preparado el generador del reporte comparativo sin valores de mejora hardcodeados.


- {% include step_label.html %} Valida la sintaxis Python antes de consumir los resultados de benchmark.

  ```bash
  python -m py_compile scripts/build_report.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma que `build_report.py` es sintácticamente válido antes de leer los resultados y construir el reporte Markdown.


- {% include step_label.html %} Valida que existan todos los archivos y esten correctamente.

  ```bash
  for FILE in \
    scenario-D-before.json \
    scenario-D-after.json \
    scenario-B-32.json \
    scenario-B-32-post-memory.json
  do
    printf '%-40s ' "$FILE"

    if jq -e . "results/$FILE" >/dev/null 2>&1; then
      echo "OK"
    else
      echo "INVALIDO"
    fi
  done
  ```

**Salida esperada:** La validación debe listar los cuatro archivos requeridos y marcar cada uno con `OK`, confirmando que existen y contienen JSON válido antes de que `build_report.py` intente consumirlos.


- {% include step_label.html %} Genera el reporte comparativo y conserva una copia de la salida en consola.

  ```bash
  python scripts/build_report.py \
  | tee reports/comparison-console.txt
  ```

**Salida esperada:** Deben generarse `reports/comparison.md` y `reports/comparison-console.txt` con valores obtenidos de los JSON reales, incluyendo las comparaciones SQL++ y de memoria sin imponer conclusiones de mejora.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación y reporte final — 3 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea la validación final para comprobar escenarios, cargas, índices, planes, cuota agregada, rebalance y reporte.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab12/validate.sh
  ```

**Salida esperada:** Debe descargarse `scripts/validate.sh` correctamente y quedar disponible como validador final, incluyendo las comprobaciones previstas sobre escenarios, índices, planes, cuota, rebalance y evidencias generadas.


- {% include step_label.html %} Habilita el validador y revisa su sintaxis Bash antes de ejecutarlo.

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ```

**Salida esperada:** `bash -n` no debe devolver errores; una salida vacía confirma que `validate.sh` tiene sintaxis Bash válida y puede ejecutarse para consolidar las comprobaciones finales de la práctica.


- {% include step_label.html %} Ejecuta la validación y guarda el resultado como evidencia final.

  ```bash
  ./scripts/validate.sh \
  | tee reports/validation-final.txt
  ```

**Salida esperada:** El validador debe finalizar con `RESULTADO: 9 PASS / 0 FAIL`, confirmando que todas las comprobaciones definidas fueron satisfechas y que las evidencias principales del laboratorio están disponibles.

```text
RESULTADO: 9 PASS / 0 FAIL
```

### Tarea 10.2. Crear dossier

- {% include step_label.html %} Consolida análisis de saturación, comparación y validación en un único dossier Markdown.

  ```bash
  {
    echo "# DOSSIER FINAL - LAB 12"
    echo

    echo "## Saturation analysis"
    cat results/saturation-analysis.txt
    echo

    echo "## Comparison"
    cat reports/comparison.md
    echo

    echo "## Validation"
    cat reports/validation-final.txt
  } | tee reports/final-report.md
  ```

**Salida esperada:** Debe generarse `reports/final-report.md` con las secciones de análisis de saturación, comparación y validación final, consolidando en un solo documento las evidencias obtenidas durante la práctica.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

- {% include step_label.html %} Elimina únicamente los tres secondary indexes creados por la práctica utilizando el mismo query context de la colección.

  ```bash
  for INDEX in \
    idx_created_type_value \
    idx_category_region \
    idx_cover_category_region
  do
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      http://localhost:8093/query/service \
      --data-urlencode 'query_context=default:`lab12-load`.workload' \
      --data-urlencode "statement=DROP INDEX items.\`${INDEX}\` IF EXISTS" \
    | jq '{status, errors}'
  done
  ```

**Salida esperada:** Cada intento de eliminación debe devolver `status: "success"` o indicar que el índice ya no existe, confirmando que los tres secondary indexes de la práctica no permanecen activos tras la limpieza funcional.


- {% include step_label.html %} Elimina también el primary index temporal utilizado exclusivamente para construir el baseline.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab12-load`.workload' \
    --data-urlencode 'statement=DROP PRIMARY INDEX IF EXISTS ON items' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` sin errores, confirmando que el primary index temporal utilizado para el baseline fue eliminado o que la operación fue idempotente si ya no existía.


- {% include step_label.html %} Restaura `memoryQuota` a `512Mi` únicamente si conservarás el clúster para otra práctica.

  ```bash
  kubectl patch couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    --type=merge \
    -p '{"spec":{"memoryQuota":"512Mi"}}'
  ```

**Salida esperada:** Kubernetes debe confirmar que `lab12-load` fue `patched`, indicando que `memoryQuota` volvió a `512Mi` para dejar el bucket con su configuración inicial cuando el clúster vaya a reutilizarse.


- {% include step_label.html %} Elimina el Pod cliente temporal después de completar todos los benchmarks y reportes.

  ```bash
  kubectl delete pod cb-lab12-client \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** Kubernetes debe eliminar `cb-lab12-client` o informar que ya está ausente sin producir un error fatal, confirmando que el recurso temporal de carga fue retirado al terminar benchmarks y reportes.


---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` los port-forward 8091 y 8093 antes de destruir EKS.

**Salida esperada:** Ambas terminales de port-forward deben regresar al prompt de Git Bash después de `Ctrl+C`, confirmando que los túneles locales 8091 y 8093 fueron detenidos antes de iniciar la destrucción del clúster.


- {% include step_label.html %} Regresa al directorio del laboratorio y carga las variables utilizadas por el script de ciclo de vida.

  ```bash
  cd /c/LABS/couchbase-nosql/lab12
  source lab.env
  ```

**Salida esperada:** El prompt debe quedar ubicado en `/c/LABS/couchbase-nosql/lab12` y `source lab.env` no debe mostrar errores, confirmando que las variables necesarias para ejecutar la eliminación de EKS están cargadas.


- {% include step_label.html %} Elimina la infraestructura EKS mediante el mismo script utilizado durante la creación.

  ```bash
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe completar la eliminación del clúster EKS y sus recursos administrados sin errores pendientes, confirmando que la infraestructura temporal de la práctica fue retirada de la región configurada.


- {% include step_label.html %} Verifica que AWS ya no encuentre el clúster en `us-west-2`.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:** La llamada debe finalizar con `ResourceNotFoundException`, confirmando que AWS ya no localiza el clúster indicado en `us-west-2` y que la eliminación de la infraestructura EKS quedó completada.

```text
ResourceNotFoundException
```
