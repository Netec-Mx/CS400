---
layout: lab
title: "Práctica 8: Escalamiento y rebalanceo del clúster bajo carga"
permalink: /lab8/lab8/
images_base: /labs/lab8/img
duration: "96 minutos"
objective:
  - Validar la resiliencia y el comportamiento operativo de Couchbase en Kubernetes mediante pruebas automatizadas de escalado (out/in), Swap Rebalance y fallos provocados bajo una carga controlada de 70/30, midiendo el impacto real en throughput, errores y latencia..
prerequisites:
  - Haber completado las prácticas anteriores o dominar vBuckets, replicas, rebalance, failover, MDS y Couchbase Kubernetes Operator.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender que un CouchbaseCluster administrado por Operator debe modificarse declarativamente y no mediante addNode, ejectNode o rebalance manual.
introduction:
  - En esta práctica operarás Couchbase Server Enterprise 7.6.2 bajo una carga continua mientras modificas la cardinalidad de una server class Data desde Kubernetes. Couchbase Kubernetes Operator materializará el estado deseado y Couchbase Server ejecutará internamente los rebalanceos necesarios para redistribuir vBuckets. El laboratorio mantiene separadas ambas capas; Kubernetes declara intención y controla Pods; Couchbase expone progreso, membership y distribución de datos. La práctica utiliza descubrimiento dinámico de Pods y evita asumir nombres derivados de las server classes.
slug: lab8
lab_number: 8
final_result: >
  Al finalizar la práctica habrás mantenido una carga continua durante scale-out, scale-in, SwapRebalance y una interrupción controlada; medido throughput, errores y percentiles; observado rebalanceProgress y active/replica vBuckets; validado la reconciliación del Operator; comprobado por qué rebalance retry nativo debe permanecer deshabilitado cuando Operator administra el clúster; automatizado cambios de cardinalidad y generado un reporte comparativo reproducible.
notes:
  - Los 96 minutos corresponden únicamente a las tareas funcionales del laboratorio. La creación, preparación y destrucción de EKS quedan fuera del tiempo.
  - La práctica utiliza Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - El clúster inicia con cuatro Pods Data y un Pod Query + Index; scale-out incrementa Data de 4 a 5.
  - Los nombres de Pods son descubiertos dinámicamente desde la topología de Couchbase; no se asume que incluyan el nombre de la server class.
  - La carga se genera mediante Couchbase Python SDK desde un Pod interno para evitar dependencias del host Windows.
  - El objetivo del workload es 5,000 ops/s, pero la práctica registra la tasa realmente observada y no exige alcanzar exactamente esa cifra.
  - stopRebalance interrumpe un rebalanceo, pero no equivale a failover; no se utiliza setRecoveryType.
  - SwapRebalance se demuestra mediante la anotación de reschedule documentada por Couchbase Kubernetes Operator.
  - Rebalance Retry nativo se mantiene deshabilitado porque Couchbase recomienda no activarlo en clústeres administrados por Autonomous Operator.
  - ep_bg_fetched representa elementos recuperados desde disco por background fetch y no debe interpretarse como logical GET misses.
  - travel-sample no se modifica; el workload utiliza exclusivamente el bucket lab8-rebalance.
references:
  - text: CouchbaseCluster Resource
    url: https://docs.couchbase.com/operator/current/resource/couchbasecluster.html
  - text: Couchbase Upgrades y SwapRebalance
    url: https://docs.couchbase.com/operator/current/concept-upgrade.html
  - text: Anotación de reschedule del Operator
    url: https://docs.couchbase.com/operator/current/reference-annotations.html
  - text: Arquitectura y orden de reconciliación del Operator
    url: https://docs.couchbase.com/operator/current/concept-operator.html
  - text: Rebalance de Couchbase Server
    url: https://docs.couchbase.com/server/7.6/learn/clusters-and-availability/rebalance.html
  - text: Obtener progreso de rebalanceo
    url: https://docs.couchbase.com/server/7.6/rest-api/rest-get-rebalance-progress.html
  - text: Configurar Rebalance Retry
    url: https://docs.couchbase.com/server/current/rest-api/rest-configure-rebalance-retry.html
  - text: Consultar pending Rebalance Retry
    url: https://docs.couchbase.com/server/current/rest-api/rest-get-rebalance-retry.html
  - text: Configuración general de rebalance
    url: https://docs.couchbase.com/server/current/manage/manage-settings/general-settings.html
prev: /lab7/lab7/
next: /lab9/lab9/
---

---

> **IMPORTANTE:** Ejecuta los bloques `bash` desde Git Bash integrado en Visual Studio Code. PowerShell y CMD interpretan de forma distinta heredocs, comillas y rutas.
{: .lab-note .important .compact}

## 📁 Preparación del directorio

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona **File → Open Folder** y abre `C:\LABS\couchbase-nosql` para conservar la misma raíz de trabajo utilizada en las prácticas anteriores.

**Salida esperada:** Visual Studio Code debe mostrar `C:\LABS\couchbase-nosql` como carpeta raíz del workspace y permitir acceder a los laboratorios existentes.

- {% include step_label.html %} Crea directorios separados para scripts, manifiestos, métricas, snapshots, reportes, workload y evidencias antes de iniciar la infraestructura.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab8/{scripts,manifests,metrics,snapshots,reports,workload,outputs}
  cd /c/LABS/couchbase-nosql/lab8
  
  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:** `pwd` debe devolver `/c/LABS/couchbase-nosql/lab8`; `find` debe listar `manifests`, `metrics`, `outputs`, `reports`, `scripts`, `snapshots` y `workload`.

---

## ☁️ Preparación de infraestructura

### Variables comunes

- {% include step_label.html %} Crea `lab.env` para centralizar región, versiones, nombres y parámetros del workload, evitando repetir valores divergentes entre scripts.

  ```bash
  cat > lab.env << 'ENVEOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab08"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"
  
  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_OPERATOR_VERSION="2.92.0"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"
  
  export WORKLOAD_BUCKET="lab8-rebalance"
  export WORKLOAD_SCOPE="workload"
  export WORKLOAD_COLLECTION="items"
  export TARGET_OPS="5000"
  ENVEOF
  ```
  ```bash
  source lab.env
  
  printf 'REGION=%s EKS=%s OPERATOR=%s IMAGE=%s\n' \
    "$AWS_REGION" "$EKS_CLUSTER" "$CB_OPERATOR_VERSION" "$CB_IMAGE"
  ```

**Salida esperada:** Deben mostrarse región, clúster EKS, Operator `2.92.0` e imagen Enterprise `7.6.2`; `source lab.env` no debe generar errores.

### Crear y eliminar EKS

- {% include step_label.html %} Crea un script de ciclo de vida reproducible con cuatro workers `m6i.xlarge` distribuidos en tres Availability Zones para soportar scale-out y reemplazos temporales.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab8/eks-cluster.sh
  ```

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe producir salida; al finalizar deben aparecer cuatro workers `m6i.xlarge` en estado `Ready` y distribuidos entre las tres zonas declaradas.

### StorageClass y Operator

- {% include step_label.html %} Define una StorageClass EBS `gp3` con binding diferido y comprueba el recurso antes de instalar Couchbase Kubernetes Operator.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'YAMLEOF'
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
  YAMLEOF
  ```
  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  kubectl get storageclass gp3-couchbase
  ```

**Salida esperada:** `gp3-couchbase` debe utilizar `ebs.csi.aws.com`, `WaitForFirstConsumer`, `Delete` y permitir expansión de volumen.

- {% include step_label.html %} Instala Couchbase Kubernetes Operator `2.92.0` mediante Helm sin crear un clúster automático y espera que sus deployments estén disponibles.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```
  ```bash
  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```
  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available deployment \
    --all \
    --timeout=5m
  ```

**Salida esperada:** Helm debe instalar o actualizar `cb-operator`; `kubectl wait` debe finalizar indicando que los deployments están disponibles.

### Crear CouchbaseCluster inicial

- {% include step_label.html %} Crea el Secret administrativo de forma idempotente para que el Operator pueda administrar Couchbase sin imprimir la contraseña en el manifiesto.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe responder `secret/cb-admin created` o `configured`; la salida no debe mostrar el valor de `$CB_PASS`.

- {% include step_label.html %} Define cuatro Pods Data y un Pod Query + Index con PVC persistente, cuotas suficientes para el bucket del laboratorio y `SwapRebalance` como proceso de reemplazo.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'YAMLEOF'
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
  
    cluster:
      dataServiceMemoryQuota: 1Gi
      indexServiceMemoryQuota: 1Gi
      indexer:
        storageMode: plasma
  
    upgrade:
      upgradeProcess: SwapRebalance
      upgradeStrategy: RollingUpgrade
      rollingUpgrade:
        maxUpgradable: 1
      stabilizationPeriod: 10s
  
    servers:
      - name: data
        size: 4
        services:
          - data
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
        volumeMounts:
          default: couchbase-volume
  
      - name: query-index
        size: 1
        services:
          - query
          - index
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
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
  YAMLEOF
  ```
  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```
  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    "couchbasecluster/${CB_CLUSTER}" \
    --timeout=15m
  ```
  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o wide
  
  kubectl get pvc -n "$CB_NAMESPACE"
  ```

**Salida esperada:** El clúster debe alcanzar `Available`; deben existir cinco Pods Couchbase `1/1 Running` y cinco PVC `Bound`, sin Pods `Pending` persistentes.

### Crear bucket y dataset aislado

- {% include step_label.html %} Abre una segunda terminal Git Bash y publica la administración en 8091 mediante el Service creado por el Operator; mantén este túnel durante las tareas.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    "service/${CB_CLUSTER}-ui" \
    8091:8091
  ```

**Salida esperada:** La terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8091 -> 8091` y mantener disponible `http://localhost:8091`.

- {% include step_label.html %} Crea `lab8-rebalance` sólo cuando no exista y valida una réplica para disponer de active y replica vBuckets durante los rebalanceos.

  ```bash
  if ! curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${WORKLOAD_BUCKET}" \
      >/dev/null 2>&1; then
  
    curl -sS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      http://localhost:8091/pools/default/buckets \
      -d "name=${WORKLOAD_BUCKET}" \
      -d 'bucketType=couchbase' \
      -d 'ramQuota=512' \
      -d 'replicaNumber=1' \
      -d 'storageBackend=couchstore' \
      -o outputs/create-bucket.txt \
      -w 'Bucket create: HTTP %{http_code}\n'
  else
    echo "${WORKLOAD_BUCKET} ya existe."
  fi
  
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${WORKLOAD_BUCKET}" \
    | jq '{name,ramQuotaMB,replicaNumber,bucketType}'
  ```

**Salida esperada:** El bucket debe aparecer como `lab8-rebalance`, Couchbase bucket y `replicaNumber: 1`; una segunda ejecución no debe intentar recrearlo.

- {% include step_label.html %} Descubre el Pod que ejecuta Query Service desde `/pools/default`, evitando asumir que el nombre Kubernetes contiene `query-index`.

  ```bash
  TOPOLOGY=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default
  )
  
  QUERY_POD=$(
    echo "$TOPOLOGY" \
    | jq -r '
        .nodes[]
        | select(.services | index("n1ql"))
        | .hostname
      ' \
    | head -n1 \
    | cut -d. -f1 \
    | tr -d '\r'
  )
  
  echo "Query Pod: $QUERY_POD"
  ```
  ```bash
  kubectl get pod "$QUERY_POD" \
    -n "$CB_NAMESPACE" \
    -o wide
  ```

**Salida esperada:** Debe mostrarse un Pod ordinal como `cb-cs400-000X`; `kubectl get pod` debe encontrar exactamente ese recurso.

- {% include step_label.html %} Abre una tercera terminal y publica Query Service del Pod descubierto en 8093 para ejecutar DDL sin depender de nombres internos de server class.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    "pod/${QUERY_POD}" \
    8093:8093
  ```

**Salida esperada:** La terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8093 -> 8093` mientras Query Service esté accesible.

- {% include step_label.html %} Crea scope y collection mediante sentencias independientes para detectar con precisión cualquier fallo de DDL y evitar enviar múltiples statements en una sola petición.

  ```bash
  for statement in \
    'CREATE SCOPE `lab8-rebalance`.workload IF NOT EXISTS;' \
    'CREATE COLLECTION `lab8-rebalance`.workload.items IF NOT EXISTS;'
  do
    RESPONSE=$(
      curl -sS \
        -u "$CB_USER:$CB_PASS" \
        -X POST \
        http://localhost:8093/query/service \
        --data-urlencode "statement=${statement}"
    )
  
    echo "$RESPONSE" | jq '{status,errors}'
  done
  ```

**Salida esperada:** Las dos respuestas deben mostrar `status: success`; quedan creados `lab8-rebalance.workload` y la collection `items`.

### Crear Pod generador y precargar documentos

- {% include step_label.html %} Crea un Pod Python interno con credenciales obtenidas del Secret `cb-admin` para que los scripts no contengan la contraseña administrativa embebida.

  ```bash
  cat > manifests/load-generator.yaml << 'YAMLEOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-load-generator
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 14400"]
        env:
          - name: CB_CONNSTR
            value: couchbase://cb-cs400-srv
          - name: CB_USERNAME
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: username
          - name: CB_PASSWORD
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
  YAMLEOF
  ```
  ```bash
  kubectl apply -f manifests/load-generator.yaml
  ```
  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Ready \
    pod/cb-load-generator \
    --timeout=3m
  ```
  ```bash
  kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    pip install \
      --quiet \
      --root-user-action=ignore \
      'couchbase>=4.4,<5'
  ```

**Salida esperada:** `cb-load-generator` debe quedar `Ready` y la instalación del Couchbase Python SDK debe finalizar sin errores de `pip`.

- {% include step_label.html %} Crea un seeder idempotente de 120,000 documentos cercanos a 1 KiB usando `upsert_multi` y las credenciales recibidas por variables de entorno.

  ```bash
  cat > workload/seed.py << 'PYEOF'
  import os
  from datetime import timedelta
  
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions
  
  TARGET = 120_000
  BATCH = 1_000
  
  cluster = Cluster(
      os.environ["CB_CONNSTR"],
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USERNAME"],
              os.environ["CB_PASSWORD"]
          )
      )
  )
  
  cluster.wait_until_ready(timedelta(seconds=30))
  
  collection = (
      cluster.bucket("lab8-rebalance")
      .scope("workload")
      .collection("items")
  )
  
  payload = "x" * 900
  
  for start in range(0, TARGET, BATCH):
      docs = {}
  
      for i in range(start, min(start + BATCH, TARGET)):
          docs[f"item_{i:09d}"] = {
              "type": "load_item",
              "counter": i,
              "payload": payload
          }
  
      collection.upsert_multi(docs)
  
      print(
          f"Seeded through "
          f"{min(start + BATCH, TARGET):,}",
          flush=True
      )
  
  cluster.close()
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    workload/seed.py \
    "$CB_NAMESPACE/cb-load-generator:/tmp/seed.py"
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    python /tmp/seed.py
  ```

**Salida esperada:** El progreso debe alcanzar `Seeded through 120,000`; una repetición debe sobrescribir las mismas keys sin duplicar el conjunto lógico.

---

## 🔥 Tarea 1. Iniciar carga continua y capturar línea base — 10 min

### Tarea 1.1. Crear el generador 70/30

- {% include step_label.html %} Crea un workload con múltiples workers, mezcla 70% GET y 30% UPSERT y métricas por intervalo para throughput, errores y percentiles observados.

  ```bash
  curl -L -o workload/continuous_load.py https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab8/continuous_load.py
  ```

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    workload/continuous_load.py \
    "$CB_NAMESPACE/cb-load-generator:/tmp/continuous_load.py"
  ```

**Salida esperada:** El archivo debe copiarse a `/tmp/continuous_load.py` sin errores; el script conserva mezcla, métricas y target como parámetros configurables.

### Tarea 1.2. Iniciar la carga

- {% include step_label.html %} En una terminal dedicada inicia el workload y conserva el stream en `/tmp/load.log`; esta terminal debe permanecer activa durante las tareas siguientes.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    sh -c "
      python /tmp/continuous_load.py \
        --target-ops ${TARGET_OPS} \
        --workers 16 \
        --interval 10 \
      | tee /tmp/load.log
    "
  ```

**Salida esperada:** Después de `Continuous load started` deben aparecer objetos JSON con `ops_per_sec`, ratios cercanos a `0.70/0.30`, `errors` y percentiles; el throughput real puede ser diferente de 5,000 ops/s.

> **NOTA:** La práctica compara el mismo workload antes, durante y después de cambios de topología; no utiliza 5,000 ops/s como criterio rígido de aprobación.
{: .lab-note .info .compact}

### Tarea 1.3. Capturar línea base

- {% include step_label.html %} En otra terminal espera al menos tres intervalos y captura las últimas muestras junto con membership y servicios del clúster antes del primer scale-out.

  ```bash
  for i in $(seq 1 12); do
    JSON_LINES=$(
      kubectl exec \
        -n "$CB_NAMESPACE" \
        cb-load-generator \
        -- \
        sh -c "grep -c '^{\"timestamp\"' /tmp/load.log 2>/dev/null || true"
    )
  
    echo "Muestras JSON disponibles: $JSON_LINES"
  
    [[ "$JSON_LINES" -ge 3 ]] && break
    sleep 5
  done
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 6 /tmp/load.log \
    | tee snapshots/load-baseline.jsonl
  ```
  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '{
        rebalanceStatus,
        nodes: [
          .nodes[] | {
            hostname,
            status,
            clusterMembership,
            services
          }
        ]
      }' \
    | tee snapshots/cluster-baseline.json
  ```

**Salida esperada:** `load-baseline.jsonl` debe contener varias muestras y `cluster-baseline.json` debe mostrar cuatro miembros con `kv`, un miembro Query+Index y `rebalanceStatus: "none"`.

### Tarea 1.4. Crear helpers de descubrimiento y estabilización

- {% include step_label.html %} Crea un helper que obtenga los Data Pods desde los servicios reales anunciados por Couchbase y elimine `\r` para evitar problemas CRLF en Git Bash.

  ```bash
  cat > scripts/list-data-pods.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq -r '
      .nodes[]
      | select(.services | index("kv"))
      | .hostname
      | split(".")[0]
    ' \
  | tr -d '\r' \
  | sort
  SHEOF
  ```
  ```bash
  chmod +x scripts/list-data-pods.sh
  ./scripts/list-data-pods.sh
  ```

**Salida esperada:** Deben imprimirse cuatro nombres ordinales de Pods Data, por ejemplo `cb-cs400-0000`; no debe aparecer `\r` ni depender del texto `data` en el nombre.

- {% include step_label.html %} Crea un monitor que primero espere `status=running` y sólo considere terminado el rebalance después de haberlo observado realmente en ejecución.

  ```bash
  cat > scripts/monitor-rebalance.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  START=$(date +%s)
  TIMEOUT_SECONDS=1200
  SEEN_RUNNING=false
  
  while true; do
    RESPONSE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/rebalanceProgress
    )
  
    STATUS=$(
      echo "$RESPONSE" \
      | jq -r '.status // "unknown"'
    )
  
    NOW=$(date '+%H:%M:%S')
    ELAPSED=$(( $(date +%s) - START ))
  
    echo "[$NOW] status=$STATUS elapsed=${ELAPSED}s"
  
    echo "$RESPONSE" \
    | jq -r '
        to_entries[]
        | select(
            .key != "status"
            and (.value | type) == "object"
            and (.value.progress? != null)
          )
        | "  \(.key): \((.value.progress * 100) | round)%"
      ' || true
  
    if [[ "$STATUS" == "running" ]]; then
      SEEN_RUNNING=true
    elif [[ "$STATUS" == "none" && "$SEEN_RUNNING" == "true" ]]; then
      echo "Rebalance finalizado."
      break
    else
      echo "  esperando inicio o transición del rebalance..."
    fi
  
    if [[ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]]; then
      echo "ERROR: no se observó un ciclo completo de rebalance dentro del timeout."
      exit 1
    fi
  
    sleep 5
  done
  SHEOF
  ```
  ```bash
  chmod +x scripts/monitor-rebalance.sh
  bash -n scripts/monitor-rebalance.sh
  ```

**Salida esperada:** `bash -n` no debe producir salida; el monitor queda preparado para esperar el inicio real y no finalizar prematuramente ante un `status=none` inicial.

- {% include step_label.html %} Crea una espera de estabilidad que exige cardinalidad Data, nodos `healthy/active`, rebalance finalizado y tres muestras consecutivas correctas.

  ```bash
  cat > scripts/wait-cluster-stable.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  EXPECTED_DATA="${1:?Uso: wait-cluster-stable.sh <data-count>}"
  STABLE_REQUIRED=3
  STABLE_COUNT=0
  
  for i in $(seq 1 180); do
    CLUSTER_JSON=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default
    )
  
    DATA_COUNT=$(
      echo "$CLUSTER_JSON" \
      | jq '[
          .nodes[]
          | select(.services | index("kv"))
        ] | length'
    )
  
    UNHEALTHY=$(
      echo "$CLUSTER_JSON" \
      | jq '[
          .nodes[]
          | select(
              .status != "healthy"
              or .clusterMembership != "active"
            )
        ] | length'
    )
  
    REBALANCE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/rebalanceProgress \
      | jq -r '.status // "unknown"'
    )
  
    AVAILABLE=$(
      kubectl get couchbasecluster "$CB_CLUSTER" \
        -n "$CB_NAMESPACE" \
        -o json \
      | jq -r '
          [
            .status.conditions[]?
            | select(.type == "Available")
            | .status
          ][0] // "False"
        '
    )
  
    if [[ "$DATA_COUNT" -eq "$EXPECTED_DATA" \
          && "$UNHEALTHY" -eq 0 \
          && "$REBALANCE" == "none" \
          && "$AVAILABLE" == "True" ]]; then
      STABLE_COUNT=$((STABLE_COUNT + 1))
    else
      STABLE_COUNT=0
    fi
  
    echo "Intento $i - Data=$DATA_COUNT/$EXPECTED_DATA unhealthy=$UNHEALTHY rebalance=$REBALANCE Available=$AVAILABLE stable=$STABLE_COUNT/$STABLE_REQUIRED"
  
    if [[ "$STABLE_COUNT" -ge "$STABLE_REQUIRED" ]]; then
      echo "Clúster estable con ${EXPECTED_DATA} Data nodes."
      exit 0
    fi
  
    sleep 5
  done
  
  echo "ERROR: el clúster no alcanzó estabilidad dentro del tiempo previsto."
  exit 1
  SHEOF
  ```
  ```bash
  chmod +x scripts/wait-cluster-stable.sh
  bash -n scripts/wait-cluster-stable.sh
  ./scripts/wait-cluster-stable.sh 4
  ```

**Salida esperada:** Debe imprimirse `Clúster estable con 4 Data nodes.` después de tres verificaciones consecutivas con rebalance `none` y todos los miembros `healthy/active`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## ➕ Tarea 2. Scale-out declarativo Data 4 → 5 — 14 min

### Tarea 2.1. Crear helper de cardinalidad

- {% include step_label.html %} Crea un script que localice dinámicamente la posición de la server class `data` y aplique únicamente el cambio de `size` solicitado.

  ```bash
  cat > scripts/scale-data.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  TARGET="${1:?Uso: scale-data.sh <size>}"
  
  INDEX=$(
    kubectl get couchbasecluster "$CB_CLUSTER" \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r '
        .spec.servers
        | to_entries[]
        | select(.value.name == "data")
        | .key
      '
  )
  
  if [[ -z "$INDEX" ]]; then
    echo "ERROR: no se encontró la server class data."
    exit 1
  fi
  
  CURRENT=$(
    kubectl get couchbasecluster "$CB_CLUSTER" \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r ".spec.servers[$INDEX].size"
  )
  
  echo "Data class: ${CURRENT} -> ${TARGET}"
  
  kubectl patch couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    --type=json \
    -p="[
      {
        \"op\":\"replace\",
        \"path\":\"/spec/servers/${INDEX}/size\",
        \"value\":${TARGET}
      }
    ]"
  SHEOF
  ```
  ```bash
  chmod +x scripts/scale-data.sh
  bash -n scripts/scale-data.sh
  ```

**Salida esperada:** `bash -n` no debe producir salida; el script debe poder localizar `data` aunque cambie la posición de `spec.servers`.

### Tarea 2.2. Registrar Pods previos

- {% include step_label.html %} Guarda los cuatro Data Pods descubiertos desde la topología para identificar posteriormente cuál fue agregado por el scale-out.

  ```bash
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-before-scaleout.txt
  ```
  ```bash
  wc -l snapshots/data-pods-before-scaleout.txt
  ```

**Salida esperada:** El archivo debe contener cuatro nombres de Pods y `wc -l` debe devolver `4`.

### Tarea 2.3. Solicitar scale-out

- {% include step_label.html %} Cambia exclusivamente el estado deseado de Data de cuatro a cinco miembros y deja que Operator gestione creación, membership y rebalance.

  ```bash
  ./scripts/scale-data.sh 5
  ```

**Salida esperada:** Debe imprimirse `Data class: 4 -> 5` y Kubernetes debe responder que `cb-cs400` fue `patched`.

### Tarea 2.4. Monitorear Couchbase y Kubernetes

- {% include step_label.html %} Ejecuta el monitor de rebalanceo en una terminal mientras observas los Pods en otra para correlacionar el ciclo Couchbase con la creación del nuevo miembro.

  ```bash
  ./scripts/monitor-rebalance.sh \
    | tee outputs/scaleout-rebalance-monitor.txt
  ```

- {% include step_label.html %} En otra terminal:

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -w
  ```

**Salida esperada:** El monitor debe observar al menos un `status=running` y finalizar con `Rebalance finalizado.`; Kubernetes debe incorporar un nuevo Pod Couchbase.

### Tarea 2.5. Capturar workload durante scale-out

- {% include step_label.html %} Copia las últimas muestras del cliente mientras el cambio está ocurriendo para conservar throughput, errores y percentiles del mismo workload.

  ```bash
  kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 10 /tmp/load.log \
    | tee snapshots/load-during-scaleout.jsonl
  ```

**Salida esperada:** El archivo debe contener muestras JSON recientes; no se exige un porcentaje fijo de degradación ni `errors=0` durante toda la transición.

### Tarea 2.6. Esperar estado estable con cinco Data nodes

- {% include step_label.html %} Utiliza la espera integral para confirmar cinco Data nodes reales, membership saludable y ausencia de rebalance antes de continuar.

  ```bash
  ./scripts/wait-cluster-stable.sh 5
  ./scripts/list-data-pods.sh
  ```

**Salida esperada:** Debe imprimirse `Clúster estable con 5 Data nodes.` y el listado final debe contener cinco nombres.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🧩 Tarea 3. Analizar vBuckets y métricas post scale-out — 8 min

### Tarea 3.1. Crear analizador de vBucketServerMap

- {% include step_label.html %} Crea un analizador que obtenga `vBucketServerMap` y cuente active y replica vBuckets por servidor sin inferir distribución desde métricas agregadas.

  ```bash
  cat > scripts/vbucket-distribution.py << 'PYEOF'
  import base64
  import json
  import os
  import urllib.request
  
  url = (
      "http://localhost:8091/pools/default/"
      "buckets/lab8-rebalance"
  )
  
  req = urllib.request.Request(url)
  
  token = base64.b64encode(
      (
          os.environ["CB_USER"]
          + ":"
          + os.environ["CB_PASS"]
      ).encode()
  ).decode()
  
  req.add_header(
      "Authorization",
      f"Basic {token}"
  )
  
  with urllib.request.urlopen(
      req,
      timeout=15
  ) as response:
      bucket = json.load(response)
  
  mapping = bucket["vBucketServerMap"]
  servers = mapping["serverList"]
  vbuckets = mapping["vBucketMap"]
  
  active = {
      server: 0
      for server in servers
  }
  
  replica = {
      server: 0
      for server in servers
  }
  
  for row in vbuckets:
      if row and row[0] >= 0:
          active[
              servers[row[0]]
          ] += 1
  
      for replica_index in row[1:]:
          if replica_index >= 0:
              replica[
                  servers[replica_index]
              ] += 1
  
  print(
      f"Total vBuckets represented: "
      f"{len(vbuckets)}"
  )
  
  for server in servers:
      print(
          f"{server:<45} "
          f"active={active[server]:>4} "
          f"replica={replica[server]:>4}"
      )
  PYEOF
  ```
  ```bash
  python scripts/vbucket-distribution.py \
    | tee outputs/vbucket-distribution-scaleout.txt
  ```

**Salida esperada:** Debe mostrarse `Total vBuckets represented: 1024`, cinco Data servers en `serverList` y una distribución aproximadamente equilibrada.

### Tarea 3.2. Identificar nuevo Pod

- {% include step_label.html %} Captura el conjunto posterior y usa `comm` para identificar únicamente el Pod que apareció después del scale-out.

  ```bash
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-after-scaleout.txt
  ```
  ```bash
  comm -13 \
    snapshots/data-pods-before-scaleout.txt \
    snapshots/data-pods-after-scaleout.txt \
    | tee outputs/new-data-pod-scaleout.txt
  ```

**Salida esperada:** `data-pods-after-scaleout.txt` debe contener cinco líneas y `new-data-pod-scaleout.txt` debe identificar un único Pod nuevo.

### Tarea 3.3. Capturar métricas post scale-out

- {% include step_label.html %} Captura workload, estadísticas del bucket y recursos Kubernetes después de estabilizarse para comparar el estado posterior con la línea base.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 6 /tmp/load.log \
    | tee snapshots/load-after-scaleout.jsonl
  ```
  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${WORKLOAD_BUCKET}/stats" \
    | jq '
        def last_non_null(name):
          (.op.samples[name] // [])
          | map(select(. != null))
          | if length > 0 then .[-1] else null end;
  
        {
          cmd_get: last_non_null("cmd_get"),
          cmd_set: last_non_null("cmd_set"),
          ep_bg_fetched: last_non_null("ep_bg_fetched"),
          ep_queue_size: last_non_null("ep_queue_size"),
          curr_items: last_non_null("curr_items"),
          mem_used: last_non_null("mem_used")
        }
      ' \
    | tee metrics/cluster-after-scaleout.json
  ```
  ```bash
  kubectl top pods \
    -n "$CB_NAMESPACE" \
    | tee metrics/pods-after-scaleout.txt
  ```

**Salida esperada:** Deben crearse tres evidencias; las series pueden devolver `0` o `null` según disponibilidad, pero la petición REST y `kubectl top` no deben fallar.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## ➖ Tarea 4. Scale-in declarativo Data 5 → 4 — 12 min

### Tarea 4.1. Registrar estado previo

- {% include step_label.html %} Guarda la lista de cinco Data Pods y una muestra reciente de la carga antes de solicitar la reducción de cardinalidad.

  ```bash
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-before-scalein.txt
  
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 6 /tmp/load.log \
    | tee snapshots/load-before-scalein.jsonl
  ```

**Salida esperada:** El snapshot de Pods debe contener cinco líneas y el snapshot del workload debe incluir muestras JSON previas al scale-in.

### Tarea 4.2. Solicitar scale-in

- {% include step_label.html %} Reduce declarativamente Data a cuatro miembros y permite que Operator seleccione el miembro que debe retirarse y coordine el rebalance-out.

  ```bash
  ./scripts/scale-data.sh 4
  ```

**Salida esperada:** Debe imprimirse `Data class: 5 -> 4` y el `CouchbaseCluster` debe quedar `patched`.

### Tarea 4.3. Monitorear

- {% include step_label.html %} Monitorea el rebalanceo y los Pods en terminales separadas para observar transferencia, retiro y convergencia sin ejectNode manual.

  ```bash
  ./scripts/monitor-rebalance.sh \
    | tee outputs/scalein-rebalance-monitor.txt
  ```

- {% include step_label.html %} En otra terminal:

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -w
  ```

**Salida esperada:** El monitor debe observar `running` y terminar en `none`; Kubernetes debe retirar un miembro Data sin eliminar el Pod Query + Index.

### Tarea 4.4. Validar estado final

- {% include step_label.html %} Espera estabilidad integral y verifica membership para confirmar que el clúster quedó con cuatro Data nodes activos y ningún miembro no saludable.

  ```bash
  ./scripts/wait-cluster-stable.sh 4
  
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-after-scalein.txt
  ```
  ```bash 
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '{
        rebalanceStatus,
        unhealthy: [
          .nodes[]
          | select(
              .status != "healthy"
              or .clusterMembership != "active"
            )
          | {
              hostname,
              status,
              clusterMembership
            }
        ]
      }'
  ```

**Salida esperada:** Debe imprimirse `Clúster estable con 4 Data nodes.` y `unhealthy` debe ser `[]`.

### Tarea 4.5. Analizar vBuckets nuevamente

- {% include step_label.html %} Ejecuta nuevamente el analizador para comprobar que las 1024 active vBuckets y sus replicas fueron redistribuidas entre cuatro Data servers.

  ```bash
  python scripts/vbucket-distribution.py \
    | tee outputs/vbucket-distribution-scalein.txt
  ```

**Salida esperada:** Deben aparecer cuatro Data servers y `Total vBuckets represented: 1024`; los active vBuckets deben quedar aproximadamente balanceados.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🔁 Tarea 5. Ejecutar reemplazo administrado con SwapRebalance — 14 min

El Operator permite forzar la reprogramación de un Pod mediante la anotación `cao.couchbase.com/reschedule=true`. Con `spec.upgrade.upgradeProcess=SwapRebalance`, el reemplazo se realiza usando el proceso administrado de swap rebalance.

### Tarea 5.1. Confirmar estrategia

- {% include step_label.html %} Consulta la estrategia almacenada en el Custom Resource para comprobar que el reemplazo utilizará `SwapRebalance` y un RollingUpgrade de un miembro por ciclo.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{
        upgradeProcess: .spec.upgrade.upgradeProcess,
        upgradeStrategy: .spec.upgrade.upgradeStrategy,
        maxUpgradable: .spec.upgrade.rollingUpgrade.maxUpgradable,
        stabilizationPeriod: .spec.upgrade.stabilizationPeriod
      }'
  ```

**Salida esperada:** Debe mostrarse `SwapRebalance`, `RollingUpgrade`, `maxUpgradable: 1` y `stabilizationPeriod: "10s"`.

### Tarea 5.2. Registrar identidad de Data Pods

- {% include step_label.html %} Guarda nombre y UID de cada Data Pod descubierto dinámicamente para demostrar después qué miembro fue reemplazado.

  ```bash
  : > snapshots/data-pod-uids-before-swap.txt
  
  while IFS= read -r pod; do
    kubectl get pod "$pod" \
      -n "$CB_NAMESPACE" \
      -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,PHASE:.status.phase' \
      --no-headers
  done < <(./scripts/list-data-pods.sh) \
    | sort \
    | tee snapshots/data-pod-uids-before-swap.txt
  ```

**Salida esperada:** El archivo debe contener cuatro Data Pods con UID no vacío y `Running`.

### Tarea 5.3. Provocar un reemplazo controlado

- {% include step_label.html %} Selecciona un Data Pod real y aplica la anotación de reschedule para solicitar un único reemplazo administrado sin modificar CPU, memoria o cardinalidad.

  ```bash
  SWAP_TARGET=$(
    ./scripts/list-data-pods.sh \
    | head -n1
  )
  
  echo "Data Pod seleccionado: $SWAP_TARGET"
  ```
  ```bash
  kubectl annotate pod "$SWAP_TARGET" \
    -n "$CB_NAMESPACE" \
    cao.couchbase.com/reschedule=true \
    --overwrite
  ```

**Salida esperada:** Debe mostrarse el Pod seleccionado y Kubernetes debe responder `pod/<nombre> annotated`.

### Tarea 5.4. Observar SwapRebalance

- {% include step_label.html %} Monitorea `rebalanceProgress`, Pods y eventos para correlacionar el nuevo miembro, el rebalance y el retiro del candidato original.

  ```bash
  ./scripts/monitor-rebalance.sh \
    | tee outputs/swap-rebalance-monitor.txt
  ```

- {% include step_label.html %} En otra terminal:

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -w
  ```

- {% include step_label.html %} En otra terminal:

  ```bash
  kubectl get events \
    -n "$CB_NAMESPACE" \
    --sort-by=.lastTimestamp \
    -w
  ```

**Salida esperada:** Debe observarse un ciclo de reemplazo y rebalanceo administrado; los eventos pueden incluir `NewMemberAdded`, `RebalanceStarted`, `MemberRemoved` y `RebalanceCompleted`.

### Tarea 5.5. Esperar convergencia

- {% include step_label.html %} Confirma que el reemplazo finalizó con la misma cardinalidad Data y sin miembros degradados antes de comparar UIDs.

  ```bash
  ./scripts/wait-cluster-stable.sh 4
  ```

**Salida esperada:** Debe imprimirse `Clúster estable con 4 Data nodes.` sin errores de membership o rebalance.

### Tarea 5.6. Comparar UIDs y workload

- {% include step_label.html %} Captura los Data Pods posteriores, compara los snapshots y conserva una muestra del workload para demostrar reemplazo sin cambio de cardinalidad.

  ```bash
  : > snapshots/data-pod-uids-after-swap.txt
  
  while IFS= read -r pod; do
    kubectl get pod "$pod" \
      -n "$CB_NAMESPACE" \
      -o custom-columns='NAME:.metadata.name,UID:.metadata.uid,PHASE:.status.phase' \
      --no-headers
  done < <(./scripts/list-data-pods.sh) \
    | sort \
    | tee snapshots/data-pod-uids-after-swap.txt
  
  echo "=== Antes ==="
  cat snapshots/data-pod-uids-before-swap.txt
  
  echo "=== Después ==="
  cat snapshots/data-pod-uids-after-swap.txt
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 8 /tmp/load.log \
    | tee snapshots/load-after-swap.jsonl
  ```

**Salida esperada:** Deben existir cuatro Data Pods antes y después, pero al menos un nombre o UID debe cambiar como consecuencia del reschedule; la carga debe continuar generando muestras.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🧯 Tarea 6. Interrumpir un rebalanceo y observar reconciliación — 12 min

Esta tarea **no realiza failover**. Detener un rebalanceo no convierte automáticamente un nodo en `inactiveFailed`; por ello no se utiliza `setRecoveryType`.

### Tarea 6.1. Iniciar un nuevo scale-out

- {% include step_label.html %} Solicita nuevamente Data 4 → 5 para generar un rebalanceo que pueda detenerse de forma deliberada sin usar addNode manual.

  ```bash
  ./scripts/scale-data.sh 5
  ```

**Salida esperada:** Debe imprimirse `Data class: 4 -> 5` y el Custom Resource debe quedar actualizado.

### Tarea 6.2. Esperar status running

- {% include step_label.html %} Espera hasta que `/rebalanceProgress` confirme `running` y registra si el ciclo inicia dentro de la ventana prevista antes de intentar detenerlo.

  ```bash
  REBALANCE_STARTED=false
  
  for i in $(seq 1 60); do
    STATUS=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/rebalanceProgress \
      | jq -r '.status // "unknown"'
    )
  
    echo "Intento $i - rebalanceStatus=$STATUS"
  
    if [[ "$STATUS" == "running" ]]; then
      REBALANCE_STARTED=true
      break
    fi
  
    sleep 2
  done
  
  echo "Rebalance iniciado: $REBALANCE_STARTED"
  ```

**Salida esperada:** Debe aparecer `rebalanceStatus=running` y terminar con `Rebalance iniciado: true`; si finaliza demasiado rápido, repite el scale-out con mayor carga antes de ejecutar el stop.

### Tarea 6.3. Detener deliberadamente

- {% include step_label.html %} Obtén `stopRebalanceUri` desde la topología y úsalo sólo si contiene el endpoint esperado, evitando construir manualmente una URI potencialmente incorrecta.

  ```bash
  STOP_URI=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
    | jq -r '.stopRebalanceUri // ""'
  )
  
  echo "stopRebalanceUri=$STOP_URI"
  
  if [[ "$STOP_URI" == /controller/stopRebalance* ]]; then
    curl -sS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "http://localhost:8091${STOP_URI}" \
      -o outputs/stop-rebalance-response.txt \
      -w 'stopRebalance: HTTP %{http_code}\n'
  else
    echo "ERROR: Couchbase no devolvió un stopRebalanceUri válido."
  fi
  ```

**Salida esperada:** Debe imprimirse una URI `/controller/stopRebalance...` y `stopRebalance: HTTP 200`; la respuesta puede no contener body.

### Tarea 6.4. Observar estado deseado vs actual

- {% include step_label.html %} Compara la cardinalidad deseada del CR con membership y rebalance actual para demostrar que detener Couchbase no modifica el `spec` solicitado a Operator.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '
        .spec.servers[]
        | select(.name == "data")
        | {
            desiredSize: .size
          }
      '
  ```
  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '{
        rebalanceStatus,
        nodes: [
          .nodes[] | {
            hostname,
            status,
            clusterMembership,
            services
          }
        ]
      }' \
    | tee snapshots/after-stop-rebalance.json
  ```

**Salida esperada:** El CR debe conservar `desiredSize: 5`; el estado Couchbase puede mostrar una transición temporal mientras Operator vuelve a reconciliar.

### Tarea 6.5. Revisar Operator y retry state

- {% include step_label.html %} Identifica el deployment del Operator sin asumir un nombre exacto, captura logs recientes y consulta si Couchbase programó algún retry nativo.

  ```bash
  OPERATOR_DEPLOYMENT=$(
    kubectl get deployment \
      -n "$CB_NAMESPACE" \
      -o name \
    | grep 'operator' \
    | head -n1
  )
  
  echo "Operator deployment: $OPERATOR_DEPLOYMENT"
  ```
  ```bash
  kubectl logs \
    -n "$CB_NAMESPACE" \
    "$OPERATOR_DEPLOYMENT" \
    --tail=150 \
    | tee outputs/operator-after-stop.log
   ```
  ```bash 
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/pendingRetryRebalance \
    | tee outputs/pending-rebalance-retry.json \
    | jq '.'
  ```

**Salida esperada:** Los logs deben mostrar actividad de reconciliación; con retry nativo deshabilitado, `pendingRetryRebalance` normalmente debe indicar `"retry_rebalance":"not_pending"`.

### Tarea 6.6. Permitir reconciliación

- {% include step_label.html %} No llames `/controller/rebalance` manualmente; espera que Operator vuelva a converger al `spec` y valida cinco Data nodes saludables.

  ```bash
  ./scripts/wait-cluster-stable.sh 5
  
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 8 /tmp/load.log \
    | tee snapshots/load-after-stop-reconcile.jsonl
  ```

**Salida esperada:** Debe imprimirse `Clúster estable con 5 Data nodes.` y el workload debe continuar produciendo muestras después de la reconciliación.

### Tarea 6.7. Regresar a cuatro miembros

- {% include step_label.html %} Restaura el estado base del laboratorio mediante otro cambio declarativo y espera estabilidad antes de revisar la política de retry.

  ```bash
  ./scripts/scale-data.sh 4
  ./scripts/wait-cluster-stable.sh 4
  ```

**Salida esperada:** Debe imprimirse `Data class: 5 -> 4` seguido de `Clúster estable con 4 Data nodes.`.

> **IMPORTANTE:** `setRecoveryType` sólo aplica después de un failover cuando un nodo requiere recovery `full` o `delta`. Un `stopRebalance` no justifica ese endpoint.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## ♻️ Tarea 7. Revisar Rebalance Retry en un clúster administrado por Operator — 7 min

Couchbase Server dispone de Rebalance Retry nativo, pero la documentación recomienda **no habilitarlo cuando Couchbase Autonomous Operator administra el clúster**, porque Operator ya reconcilia la topología y dispara los rebalanceos necesarios.

### Tarea 7.1. Consultar configuración actual

- {% include step_label.html %} Consulta `/settings/retryRebalance` y conserva el estado previo para distinguir la función nativa de Couchbase de la reconciliación de Kubernetes Operator.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/retryRebalance \
    | tee snapshots/rebalance-retry-before.json \
    | jq '.'
  ```

**Salida esperada:** El JSON debe contener `enabled`, `afterTimePeriod` y `maxAttempts`; en un entorno administrado por Operator se espera mantener `enabled: false`.

### Tarea 7.2. Asegurar que retry nativo permanezca deshabilitado

- {% include step_label.html %} Deshabilita explícitamente Rebalance Retry y conserva valores válidos de espera e intentos sin activar el mecanismo que competiría con Operator.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/settings/retryRebalance \
    -d 'enabled=false' \
    -d 'afterTimePeriod=30' \
    -d 'maxAttempts=2' \
    | tee outputs/rebalance-retry-config.json \
    | jq '.'
  ```

**Salida esperada:** Debe devolverse un JSON con `"enabled":false`, `"afterTimePeriod":30` y `"maxAttempts":2`.

### Tarea 7.3. Consultar pending retry

- {% include step_label.html %} Comprueba que no exista una secuencia de retry nativa pendiente después de estabilizar el clúster y conservar el mecanismo deshabilitado.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/pendingRetryRebalance \
    | tee outputs/pending-rebalance-retry-final.json \
    | jq '.'
  ```

**Salida esperada:** Cuando no existe un retry programado debe mostrarse:

  ```json
  {
    "retry_rebalance": "not_pending"
  }
  ```

### Tarea 7.4. Diferenciar mecanismos

| Mecanismo | Cuándo aplica |
|---|---|
| Rebalance Retry de Couchbase | Reintenta un rebalance fallido en clústeres donde este mecanismo se administra explícitamente |
| Reconciliation de Operator | Corrige diferencias entre el estado real y `CouchbaseCluster.spec` |
| Recovery full/delta | Reincorpora un nodo previamente failed-over cuando corresponde |

> **NOTA:** En esta práctica la segunda fila es el mecanismo operativo utilizado. Rebalance Retry se consulta para comprenderlo, pero se deja deshabilitado.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🤖 Tarea 8. Automatizar scale-out y scale-in — 9 min

### Tarea 8.1. Crear automatización Operator-aware

- {% include step_label.html %} Crea un script Python que modifique únicamente `spec.servers[].size` y espere cardinalidad, salud y rebalance `none` sin usar addNode o controller/rebalance.

  ```bash
  curl -L -o scripts/rebalance_automation.py https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab8/rebalance_automation.py
  ```

  ```bash
  chmod +x scripts/rebalance_automation.py
  python -m py_compile scripts/rebalance_automation.py
  ```

**Salida esperada:** `py_compile` no debe producir salida; el script debe usar variables de `lab.env` y validar la cardinalidad real en lugar de depender de haber observado un `running`.

### Tarea 8.2. Automatizar scale-out

- {% include step_label.html %} Ejecuta el script para solicitar cinco Data nodes y conserva la salida completa con el estado de convergencia y validación.

  ```bash
  python scripts/rebalance_automation.py \
    --size 5 \
    | tee outputs/automation-scaleout.txt
  ```

**Salida esperada:** La salida debe terminar con `actual_data_nodes: 5`, `unhealthy: []` y varias muestras `rebalance=none` estables.

### Tarea 8.3. Automatizar scale-in

- {% include step_label.html %} Regresa a cuatro Data nodes con la misma automatización para demostrar que el flujo funciona en ambas direcciones.

  ```bash
  python scripts/rebalance_automation.py \
    --size 4 \
    | tee outputs/automation-scalein.txt
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    tail -n 8 /tmp/load.log \
    | tee snapshots/load-after-automation.jsonl
  ```

**Salida esperada:** La automatización debe terminar con `actual_data_nodes: 4`, `unhealthy: []` y el workload debe continuar generando muestras.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 📉 Tarea 9. Comparar impacto operativo — 6 min

### Tarea 9.1. Copiar log completo del workload

- {% include step_label.html %} Copia el log completo desde el Pod antes de detenerlo para conservar todas las muestras generadas durante los distintos cambios de topología.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-load-generator \
    -- \
    cat /tmp/load.log \
    > metrics/workload-complete.jsonl
  ```
  ```bash
  wc -l metrics/workload-complete.jsonl
  ```

**Salida esperada:** `workload-complete.jsonl` debe existir y contener múltiples líneas; la primera puede ser el mensaje inicial y las restantes incluyen objetos JSON.

### Tarea 9.2. Crear resumen estadístico

- {% include step_label.html %} Calcula throughput promedio, errores máximos y percentiles medios usando sólo líneas JSON válidas para evitar que el encabezado del generador rompa el análisis.

  ```bash
  cat > scripts/summarize-load.py << 'PYEOF'
  import json
  import statistics
  from pathlib import Path
  
  path = (
      Path(__file__).resolve().parent.parent
      / "metrics"
      / "workload-complete.jsonl"
  )
  
  samples = []
  
  for line in path.read_text(
      encoding="utf-8",
      errors="replace"
  ).splitlines():
      try:
          item = json.loads(line)
      except json.JSONDecodeError:
          continue
  
      if "ops_per_sec" in item:
          samples.append(item)
  
  if not samples:
      raise SystemExit(
          "No se encontraron muestras JSON."
      )
  
  print("WORKLOAD SUMMARY")
  print("=" * 72)
  print(
      f"samples       : "
      f"{len(samples)}"
  )
  print(
      f"avg ops/s     : "
      f"{statistics.mean(
          s['ops_per_sec']
          for s in samples
      ):.1f}"
  )
  print(
      f"max errors    : "
      f"{max(
          s['errors']
          for s in samples
      )}"
  )
  print(
      f"avg p50 ms    : "
      f"{statistics.mean(
          s['p50_ms']
          for s in samples
      ):.2f}"
  )
  print(
      f"avg p95 ms    : "
      f"{statistics.mean(
          s['p95_ms']
          for s in samples
      ):.2f}"
  )
  print(
      f"avg p99 ms    : "
      f"{statistics.mean(
          s['p99_ms']
          for s in samples
      ):.2f}"
  )
  PYEOF
  ```
  ```bash
  python scripts/summarize-load.py \
    | tee reports/workload-summary.txt
  ```

**Salida esperada:** Debe mostrarse `WORKLOAD SUMMARY`, número de muestras, throughput promedio, máximo de errores y promedios p50/p95/p99 sin cifras preestablecidas.

### Tarea 9.3. Resumir snapshots por fase

- {% include step_label.html %} Crea un analizador que recorra los snapshots `load-*.jsonl` y produzca una tabla comparable por fase utilizando únicamente muestras JSON válidas.

  ```bash
  cat > scripts/summarize-phases.py << 'PYEOF'
  import json
  import statistics
  from pathlib import Path
  
  root = (
      Path(__file__)
      .resolve()
      .parent
      .parent
  )
  
  files = sorted(
      (root / "snapshots")
      .glob("load-*.jsonl")
  )
  
  print(
      f"{'phase':<34} "
      f"{'samples':>7} "
      f"{'avg_ops':>10} "
      f"{'errors':>8} "
      f"{'avg_p95':>10}"
  )
  
  print("-" * 75)
  
  for path in files:
      samples = []
  
      for line in path.read_text(
          encoding="utf-8",
          errors="replace"
      ).splitlines():
          try:
              item = json.loads(line)
          except json.JSONDecodeError:
              continue
  
          if "ops_per_sec" in item:
              samples.append(item)
  
      if not samples:
          continue
  
      avg_ops = statistics.mean(
          item["ops_per_sec"]
          for item in samples
      )
  
      errors = sum(
          item["errors"]
          for item in samples
      )
  
      avg_p95 = statistics.mean(
          item["p95_ms"]
          for item in samples
      )
  
      print(
          f"{path.stem:<34} "
          f"{len(samples):>7} "
          f"{avg_ops:>10.1f} "
          f"{errors:>8} "
          f"{avg_p95:>10.2f}"
      )
  PYEOF
  ```
  ```bash
  python scripts/summarize-phases.py \
    | tee reports/workload-by-phase.txt
  ```

**Salida esperada:** Debe aparecer una fila por snapshot con muestras válidas, permitiendo comparar baseline, scale-out, scale-in, swap, reconciliación y automatización.

### Tarea 9.4. Completar tabla comparativa

| Operación | Data size inicial → final | Duración | Throughput observado | Errores | p95 | Observación |
|---|---|---:|---:|---:|---:|---|
| Scale-out | 4 → 5 |  |  |  |  |  |
| Scale-in | 5 → 4 |  |  |  |  |  |
| SwapRebalance | 4 → 4 |  |  |  |  |  |
| Stop + reconcile | 4 → 5 |  |  |  |  |  |
| Automated scale-out | 4 → 5 |  |  |  |  |  |

**Salida esperada:** La tabla debe completarse únicamente con tiempos y métricas observadas durante la ejecución, sin porcentajes de degradación predefinidos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación y reporte final — 4 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea una suite final que valide cardinalidad declarativa y real, membership, rebalance, vBuckets, workload, SwapRebalance, stop controlado y retry nativo deshabilitado.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab8/validate.sh
  ```

  ```bash  
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ```
  ```bash
  ./scripts/validate.sh \
    | tee reports/validation-final.txt
  ```

**Salida esperada:** `bash -n` no debe producir salida; la ejecución debe terminar con `RESULTADO: <n> PASS / 0 FAIL`.

### Tarea 10.2. Generar reporte

- {% include step_label.html %} Consolida resumen del workload, fases, distribución final de vBuckets, configuración de retry y suite final antes de limpiar recursos temporales.

  ```bash
  {
    echo "# REPORTE FINAL - LAB 8"
    echo
  
    echo "## Workload"
    cat reports/workload-summary.txt
    echo
  
    echo "## Workload por fase"
    cat reports/workload-by-phase.txt
    echo
  
    echo "## VBucket distribution final"
    python scripts/vbucket-distribution.py
    echo
  
    echo "## Rebalance Retry"
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/settings/retryRebalance \
      | jq '.'
    echo
  
    echo "## Validation"
    cat reports/validation-final.txt
  } | tee reports/final-report.md
  ```

**Salida esperada:** `reports/final-report.md` debe contener workload, comparación por fase, vBuckets, retry nativo deshabilitado y la validación final completa.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

- {% include step_label.html %} Detén el workload con `Ctrl+C` en la terminal dedicada sólo después de copiar `metrics/workload-complete.jsonl` y generar el reporte final.

**Salida esperada:** La terminal del workload debe regresar al prompt; los reportes locales ya no dependen del Pod generador.

- {% include step_label.html %} Elimina el Pod generador y el bucket temporal sin modificar `travel-sample` ni recursos de prácticas anteriores.

  ```bash
  kubectl delete pod cb-load-generator \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```
  ```bash
  curl -sS \
    -u "$CB_USER:$CB_PASS" \
    -X DELETE \
    "http://localhost:8091/pools/default/buckets/${WORKLOAD_BUCKET}" \
    -o /dev/null \
    -w 'Delete bucket: HTTP %{http_code}\n'
  ```

**Salida esperada:** El Pod debe eliminarse o quedar ausente y Couchbase debe devolver un código HTTP de éxito para la eliminación del bucket temporal.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` los port-forward de 8091 y 8093 para liberar puertos locales antes de retirar la infraestructura.

**Salida esperada:** Ambas terminales deben regresar al prompt y los dos túneles deben quedar cerrados.

- {% include step_label.html %} Elimina Amazon EKS mediante el mismo script de ciclo de vida para retirar managed node group y control plane de forma reproducible.

  ```bash
  cd /c/LABS/couchbase-nosql/lab8
  source lab.env
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe finalizar la eliminación sin errores bloqueantes de CloudFormation o recursos pendientes.

- {% include step_label.html %} Confirma que AWS ya no encuentre el clúster y utiliza `ResourceNotFoundException` como evidencia final de destrucción.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:** AWS CLI debe responder con `ResourceNotFoundException`, indicando que el control plane ya no existe.
