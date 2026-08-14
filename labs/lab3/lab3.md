---
layout: lab
title: "Práctica 3: Diagnóstico y optimización de consultas SQL++"
permalink: /lab3/lab3/
images_base: /labs/lab3/img
duration: "108 minutos"
objective:
  - Validar Query, Index y Data Service en Couchbase Server Enterprise 7.6.2 desplegado sobre Amazon EKS.
  - Crear una collection aislada con al menos 500 000 documentos relacionados correctamente con aerolíneas reales.
  - Analizar planes SQL++ con EXPLAIN e identificar scans, Fetch, filtros, agregaciones y operadores de join.
  - Utilizar ADVISE y UPDATE STATISTICS para evaluar recomendaciones y decisiones del Cost-Based Optimizer.
  - Aplicar PROFILE para medir tiempos reales por operador y comparar planes antes y después de optimizar.
  - Implementar prepared statements con parámetros nombrados, query context, timeout y max_parallelism.
  - Generar carga concurrente controlada y correlacionar Active Requests, Completed Requests y Query Monitor.
  - Conservar evidencias localmente y eliminar la collection experimental sin modificar travel-sample original.
prerequisites:
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl y jq disponibles desde Git Bash.
  - Conocer SQL++ básico, JOIN, GROUP BY, HAVING, subconsultas y agregaciones.
  - Comprender Data Service, Index Service y Query Service.
introduction:
  - En esta práctica diagnosticarás y optimizarás consultas SQL++ sobre una collection experimental llamada route_lab3 con al menos 500 000 documentos. Los documentos usarán airlineid reales de inventory.airline para que los JOIN sean válidos. Aplicarás EXPLAIN, ADVISE, UPDATE STATISTICS, PROFILE, prepared statements, parámetros nombrados, timeout, max_parallelism y Query Monitor, relacionando cada herramienta con el pipeline del Query Service.
slug: lab3
lab_number: 3
final_result: >
  Al finalizar habrás creado una collection aislada con al menos 500 000 documentos, comparado planes antes y después de crear índices selectivos y covering, actualizado estadísticas del CBO, medido tiempos reales con PROFILE, reutilizado consultas parametrizadas correctamente y observado Query Service bajo carga concurrente. Las evidencias se conservarán localmente y route_lab3 se eliminará sin afectar travel-sample.
notes:
  - Los 108 minutos corresponden únicamente a las tareas funcionales de Couchbase.
  - La creación y eliminación de Amazon EKS están documentadas pero quedan fuera de los 108 minutos.
  - Todos los comandos deben ejecutarse desde Git Bash dentro de Visual Studio Code.
  - La práctica usa Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - La topología usa dos Pods Data + Query, un Pod Index + Search y un Pod Analytics + Eventing.
  - Costos, cardinalidades y tiempos son variables; no se validan cifras fijas.
references:
  - text: Instalación de AWS CLI
    url: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - text: Instalación oficial de eksctl
    url: https://eksctl.io/installation/
  - text: Instalación de kubectl en Windows
    url: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
  - text: Instalación de Helm
    url: https://helm.sh/docs/intro/install/
  - text: Instalación de Couchbase Kubernetes Operator con Helm
    url: https://docs.couchbase.com/operator/current/helm-setup-guide.html
  - text: Query Service en Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/learn/services-and-indexes/services/query-service.html
  - text: Análisis de planes de ejecución con EXPLAIN
    url: https://docs.couchbase.com/server/7.6/n1ql/n1ql-language-reference/explain.html
  - text: Recomendaciones de índices con ADVISE
    url: https://docs.couchbase.com/server/7.6/n1ql/n1ql-language-reference/advise.html
  - text: Cost-Based Optimizer en Couchbase Server
    url: https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/cost-based-optimizer.html
  - text: Prepared statements en SQL++
    url: https://docs.couchbase.com/server/7.6/n1ql/n1ql-language-reference/prepare.html
  - text: Query Service REST API
    url: https://docs.couchbase.com/server/7.6/n1ql-rest-query/index.html
prev: /lab2/lab2/
next: /lab4/lab4/
---

---
<!-- Aquí comienzan las instrucciones paso a paso de la práctica -->

## 📁 Preparación del directorio de trabajo
### 🗂️ Crear la estructura local
- {% include step_label.html %} Abre **Visual Studio Code**, selecciona **File → Open Folder** y abre `C:\LABS\couchbase-nosql` para conservar la misma raíz de trabajo de las prácticas anteriores.

  ```text
  C:\LABS\couchbase-nosql
  ```

- {% include step_label.html %} Abre **Terminal → New Terminal**, confirma que el perfil sea **Git Bash** y crea los directorios necesarios para scripts, dataset, planes, perfiles, benchmarks y salidas.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab3/{scripts,manifests,dataset,plans,profiles,benchmarks,outputs}
  cd /c/LABS/couchbase-nosql/lab3
  ```

- {% include step_label.html %} Verifica la ubicación y la estructura antes de crear archivos o ejecutar operaciones contra AWS y Couchbase.

  ```bash
  pwd
  find . -maxdepth 1 -type d | sort
  ```

---

## 🧰 Herramientas y enlaces oficiales

| Herramienta | Uso | Enlace |
|---|---|---|
| AWS CLI v2 | Autenticación AWS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| eksctl | Crear/eliminar EKS | https://eksctl.io/installation/ |
| kubectl | Kubernetes | https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/ |
| Helm 3 | Couchbase Operator | https://helm.sh/docs/intro/install/ |
| jq | JSON | https://jqlang.org/download/ |
| Git for Windows | Git Bash | https://git-scm.com/download/win |
| VS Code | Editor | https://code.visualstudio.com/download |

---

## ☁️ Preparación de infraestructura

## Crear variables del laboratorio

- {% include step_label.html %} Crea `lab.env` para centralizar nombres, versiones y credenciales reutilizadas por todos los scripts y evitar valores distintos entre creación, validación y limpieza.

  ```bash
  cat > lab.env << 'EOFENV'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab03"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"
  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"
  export CB_OPERATOR_VERSION="2.92.0"
  export CB_BUCKET="travel-sample"
  export CB_SCOPE="inventory"
  export CB_COLLECTION="route_lab3"
  EOFENV
  ```
  ```bash
  source lab.env
  ```

## Crear script EKS
- {% include step_label.html %} Crea `scripts/eks-cluster.sh` para disponer de acciones reproducibles `create`, `status` y `delete`, utilizando tres workers `m6i.xlarge` y los add-ons necesarios para EBS.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab3/eks-cluster.sh
  ```

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```

- {% include step_label.html %} Crea el clúster y valida que los workers estén disponibles antes de instalar componentes Couchbase.

  ```bash
  ./scripts/eks-cluster.sh create
  ```

## Preparar gp3, Operator y CouchbaseCluster
- {% include step_label.html %} Crea la StorageClass gp3 usada por los PVC de Couchbase para disponer de almacenamiento persistente mediante Amazon EBS.

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

  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 mediante Helm sin crear el clúster predeterminado del chart.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```
  ```bash
  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace couchbase \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

- {% include step_label.html %} Genera el secreto administrativo y el `CouchbaseCluster` con dos Pods Data + Query, un Pod Index + Search y un Pod Analytics + Eventing.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace couchbase \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml > manifests/cb-admin-secret.yaml
  ```
  ```bash
  kubectl apply -f manifests/cb-admin-secret.yaml
  ```

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
        services: [data, query]
        volumeMounts:
          default: couchbase-volume
      - name: index-search
        size: 1
        services: [index, search]
        volumeMounts:
          default: couchbase-volume
      - name: analytics-eventing
        size: 1
        services: [analytics, eventing]
        volumeMounts:
          default: couchbase-volume
    volumeClaimTemplates:
      - metadata:
          name: couchbase-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 40Gi
  EOFCB
  ```
  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```
  ```bash
  kubectl wait \
    -n couchbase \
    --for=condition=Available \
    couchbasecluster/cb-cs400 \
    --timeout=15m
  ```

## Cargar travel-sample y abrir port-forward
- {% include step_label.html %} Abre una segunda terminal y crea el túnel administrativo para utilizar la Web Console y Management REST API sin publicar un LoadBalancer en AWS.

  ```bash
  kubectl port-forward -n couchbase service/cb-cs400-ui 8091:8091
  ```

- {% include step_label.html %} Instala `travel-sample` únicamente si no existe para que la práctica sea repetible y no genere un error al reutilizar el entorno.

  ```bash
  if ! curl -fsS -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default/buckets/travel-sample >/dev/null 2>&1; then
    curl -s -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8091/sampleBuckets/install \
      -d '["travel-sample"]' | jq .
  else
    echo "travel-sample ya existe."
  fi
  ```

- {% include step_label.html %} Abre una tercera terminal, identifica un Pod que ejecute Query Service y crea un port-forward directo al puerto 8093.

  ```bash
  QUERY_POD=$(kubectl get pods -n couchbase -o name | grep cb-cs400 | head -n 1 | cut -d/ -f2)

  kubectl port-forward \
    -n couchbase \
    "pod/${QUERY_POD}" \
    8093:8093
  ```

---

## 🔎 Tarea 1. Validar Query, Index y Data Service — 6 min
### Tarea 1.1. Confirmar la topología
- {% include step_label.html %} Consulta `/pools/default` y verifica que existan los servicios requeridos antes de generar datos o índices.

  > **NOTA:** Si estas reusando el cluster de la practica 2 **No** ejecutes el **source lab.env**
  {: .lab-note .info .compact}

  ```bash
  source lab.env
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '[.nodes[] | {hostname,status,services}]'
  ```


### Tarea 1.2. Verificar Query Service
- {% include step_label.html %} Envía una consulta mínima al puerto 8093 para validar listener, parser y execution engine del Query Service.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT RAW "OK";' \
    | jq '{status,results,metrics}'
  ```


### Tarea 1.3. Verificar airline
- {% include step_label.html %} Comprueba que `inventory.airline` contiene documentos reales que serán utilizados para generar `airlineid` válidos.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT RAW COUNT(*) FROM `travel-sample`.inventory.airline;' \
    | jq '{status,results}'
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}

{% include support-prompt.html task="tarea1" %}

---

## 🧱 Tarea 2. Crear route_lab3 y cargar 500 000 documentos — 14 min
### Tarea 2.1. Crear la collection experimental
- {% include step_label.html %} Elimina una ejecución previa de `route_lab3` y crea nuevamente la collection para garantizar un estado limpio y aislado de `inventory.route`.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.route_lab3 IF EXISTS;' \
    | jq '{status,errors}'
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=CREATE COLLECTION `travel-sample`.inventory.route_lab3 IF NOT EXISTS;' \
    | jq '{status,errors}'
  ```


### Tarea 2.2. Crear un cliente Python dentro de EKS
- {% include step_label.html %} Despliega un Pod Python temporal y añade Couchbase Python SDK 4.x para generar el dataset sin exponer KV fuera del clúster.

  ```bash
  cat > manifests/python-client.yaml << 'EOFPYCLIENT'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-query-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: python
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 10800"]
        resources:
          requests:
            cpu: "500m"
            memory: "512Mi"
          limits:
            cpu: "2"
            memory: "2Gi"
  EOFPYCLIENT
  ```
  ```bash
  kubectl apply -f manifests/python-client.yaml
  kubectl wait -n couchbase --for=condition=Ready pod/cb-query-client --timeout=3m
  ```
  ```bash
  kubectl exec \
    -n couchbase \
    cb-query-client \
    -- \
    pip install \
      --quiet \
      --root-user-action=ignore \
      'couchbase>=4.4,<5'
  ```

- {% include step_label.html %} Ahora valida la instalación:

  ```bash
  kubectl exec \
    -n couchbase \
    cb-query-client \
    -- \
    python -c 'import couchbase; print(couchbase.__version__)'  
  ```



### Tarea 2.3. Crear generate_routes.py
- {% include step_label.html %} Crea un generador idempotente que consulta aerolíneas reales, calcula el faltante hasta 500K y utiliza claves deterministas para facilitar auditoría y limpieza.

  ```bash
  cat > dataset/generate_routes.py << 'EOFPY'
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

  TARGET_TOTAL = 500_000
  BATCH_SIZE = 1000

  airports = [
      "JFK", "LAX", "ORD", "DFW", "DEN",
      "SFO", "LAS", "SEA", "MCO", "EWR",
      "LHR", "CDG", "FRA", "AMS", "MAD",
      "FCO", "ZUR", "VIE", "CPH", "ARN",
  ]

  equipment = [
      "738",
      "320",
      "77W",
      "332",
      "E75",
  ]

  auth = PasswordAuthenticator(
      USER,
      PASSWORD,
  )

  cluster = Cluster(
      HOST,
      ClusterOptions(auth),
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  bucket = cluster.bucket("travel-sample")
  scope = bucket.scope("inventory")
  collection = scope.collection("route_lab3")

  # ------------------------------------------------------------
  # Obtener aerolíneas reales
  # ------------------------------------------------------------

  airline_result = cluster.query("""
      SELECT META(a).id AS document_id,
            a.iata,
            a.name
      FROM `travel-sample`.inventory.airline AS a
  """)

  airlines = list(
      airline_result.rows()
  )

  if not airlines:
      raise RuntimeError(
          "No se encontraron aerolíneas reales en "
          "travel-sample.inventory.airline."
      )

  print(
      f"Aerolíneas disponibles: {len(airlines)}"
  )

  # ------------------------------------------------------------
  # Determinar documentos existentes
  # ------------------------------------------------------------

  count_result = cluster.query("""
      SELECT RAW COUNT(*)
      FROM `travel-sample`.inventory.route_lab3
  """)

  count_rows = count_result.rows()

  try:
      current = int(
          next(iter(count_rows))
      )
  except StopIteration:
      current = 0

  remaining = max(
      TARGET_TOTAL - current,
      0,
  )

  print(f"Actuales : {current:,}")
  print(f"Objetivo : {TARGET_TOTAL:,}")
  print(f"Faltantes: {remaining:,}")

  if remaining == 0:
      print(
          "La collection ya contiene el volumen objetivo."
      )
      cluster.close()
      raise SystemExit(0)

  # ------------------------------------------------------------
  # Generación del dataset
  # ------------------------------------------------------------

  inserted = 0
  next_id = current
  start = time.perf_counter()

  while inserted < remaining:

      batch_count = min(
          BATCH_SIZE,
          remaining - inserted,
      )

      docs = {}

      for offset in range(batch_count):

          sequence = next_id + offset

          airline = random.choice(
              airlines
          )

          source = random.choice(
              airports
          )

          destination = random.choice(
              [
                  airport
                  for airport in airports
                  if airport != source
              ]
          )

          docs[
              f"route_lab3_{sequence:09d}"
          ] = {
              "type": "route_lab3",
              "airline":
                  airline.get("iata") or "NA",
              "airlineid":
                  airline["document_id"],
              "airline_name":
                  airline.get("name") or "Unknown",
              "sourceairport":
                  source,
              "destinationairport":
                  destination,
              "stops":
                  random.randint(0, 2),
              "equipment":
                  random.choice(equipment),
              "distance_km":
                  round(
                      random.uniform(
                          200,
                          14000,
                      ),
                      1,
                  ),
              "price_usd":
                  round(
                      random.uniform(
                          49,
                          1800,
                      ),
                      2,
                  ),
              "seats_available":
                  random.randint(0, 180),
              "year":
                  random.randint(
                      2018,
                      2026,
                  ),
              "month":
                  random.randint(
                      1,
                      12,
                  ),
          }

      collection.upsert_multi(
          docs
      )

      inserted += batch_count
      next_id += batch_count

      if (
          inserted % 50_000 == 0
          or inserted == remaining
      ):
          elapsed = (
              time.perf_counter()
              - start
          )

          rate = (
              inserted / elapsed
              if elapsed > 0
              else 0
          )

          print(
              f"{inserted:,}/{remaining:,} "
              f"insertados | "
              f"{elapsed:.1f}s | "
              f"{rate:,.0f} docs/s"
          )

  # ------------------------------------------------------------
  # Validación final
  # ------------------------------------------------------------

  final_result = cluster.query("""
      SELECT RAW COUNT(*)
      FROM `travel-sample`.inventory.route_lab3
  """)

  try:
      final_count = int(
          next(
              iter(
                  final_result.rows()
              )
          )
      )
  except StopIteration:
      final_count = 0

  elapsed = (
      time.perf_counter()
      - start
  )

  print()
  print("========================================")
  print("CARGA TERMINADA")
  print("========================================")
  print(
      f"Documentos finales : {final_count:,}"
  )
  print(
      f"Insertados ahora    : {inserted:,}"
  )
  print(
      f"Tiempo total        : {elapsed:.1f}s"
  )

  if final_count < TARGET_TOTAL:
      raise RuntimeError(
          "La collection no alcanzó "
          f"{TARGET_TOTAL:,} documentos."
      )

  cluster.close()
  EOFPY
  ```


### Tarea 2.4. Ejecutar el generador
- {% include step_label.html %} Copia el script al Pod y ejecuta la carga dentro de EKS, conservando la salida como evidencia local.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    dataset/generate_routes.py \
    couchbase/cb-query-client:/tmp/generate_routes.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    cb-query-client \
    -- \
    env \
      CB_HOST="couchbase://cb-cs400" \
      CB_USER="$CB_USER" \
      CB_PASS="$CB_PASS" \
      python /tmp/generate_routes.py \
    | tee outputs/dataset-generation.txt
  ```


### Tarea 2.5. Validar volumen y JOIN
- {% include step_label.html %} Confirma que `route_lab3` contiene al menos 500K documentos y que sus `airlineid` encuentran coincidencias reales.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT RAW COUNT(*) FROM `travel-sample`.inventory.route_lab3;' \
    | jq '.results'
  ```

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT COUNT(*) AS joined_docs
      FROM `travel-sample`.inventory.route_lab3 AS r
      JOIN `travel-sample`.inventory.airline AS a
        ON r.airlineid = META(a).id;' \
    | jq '.results'
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}

{% include support-prompt.html task="tarea2" %}

---

## 🧭 Tarea 3. Analizar el plan baseline con EXPLAIN — 12 min
En esta tarea establecerás un plan de ejecución de referencia para Q1 antes de optimizar índices, de modo que puedas reconocer operadores, estimaciones de costo y cardinalidad y compararlos posteriormente con un plan mejorado.


### Tarea 3.1. Crear índice primario temporal
- {% include step_label.html %} Crea un índice primario únicamente sobre `route_lab3` para establecer un baseline de acceso amplio sin tocar la collection `route` original.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      CREATE PRIMARY INDEX IF NOT EXISTS idx_route_lab3_primary
      ON `travel-sample`.inventory.route_lab3;' \
    | jq '{status,errors}'
  ```

**Salida esperada:** la respuesta debe mostrar `"status": "success"` y no presentar errores; el índice `idx_route_lab3_primary` queda creado o reutilizado si ya existía.

### Tarea 3.2. Crear Q1
- {% include step_label.html %} Guarda Q1 en un archivo para reutilizar exactamente la misma sentencia antes y después de crear índices secundarios.

  ```bash
  cat > dataset/q1.sqlpp << 'EOFQ1'
  SELECT r.airline,
         r.sourceairport,
         r.destinationairport,
         r.price_usd,
         r.distance_km
  FROM `travel-sample`.inventory.route_lab3 AS r
  WHERE r.airline = "AA"
    AND r.price_usd > 500
  ORDER BY r.price_usd DESC
  LIMIT 20;
  EOFQ1
  ```

**Salida esperada:** el archivo `dataset/q1.sqlpp` debe quedar creado sin salida de error; su contenido conserva el filtro por `AA`, `price_usd > 500`, orden descendente y límite de 20 filas.

### Tarea 3.3. Guardar el plan inicial
- {% include step_label.html %} Construye una sentencia `EXPLAIN` a partir de Q1, envíala a Query Service y conserva el plan JSON inicial como evidencia reproducible del acceso utilizado antes de optimizar índices.

  ```bash
  STATEMENT="EXPLAIN $(tr '\n' ' ' < dataset/q1.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.results[0]' \
    | tee plans/plan_q1_before.json
  ```

**Salida esperada:** `plans/plan_q1_before.json` debe contener un objeto JSON con operadores del plan generado por `EXPLAIN`; los nombres y costos exactos pueden variar según estadísticas e índices disponibles.

### Tarea 3.4. Identificar operadores
- {% include step_label.html %} Recorre recursivamente el plan inicial con `jq`, extrae los operadores ejecutables y agrúpalos por frecuencia para reconocer scans, filtros, fetches, ordenamientos y demás etapas del pipeline.

  ```bash
  jq -r '.. | objects | .["#operator"]? // empty' \
    plans/plan_q1_before.json \
    | sort | uniq -c | sort -rn
  ```

**Salida esperada:** se mostrará una lista de operadores acompañados por su frecuencia, por ejemplo operadores de scan, filter, fetch, sort, limit o projection según el plan efectivo.

### Tarea 3.5. Revisar costo y cardinalidad
- {% include step_label.html %} Extrae de cada operador las estimaciones `~cost` y `~cardinality` para observar cómo el optimizador estima trabajo y volumen de filas sin convertir esas cifras en un costo total inventado.

  ```bash
  CBO_FIELDS=$(
    jq '
      [
        .. | objects
        | select(has("~cost") or has("~cardinality"))
      ]
      | length
    ' plans/plan_q1_before.json
  )

  if [[ "$CBO_FIELDS" -eq 0 ]]; then
    echo "El plan baseline no contiene estimaciones ~cost ni ~cardinality."
    echo "Esto es válido antes de disponer de estadísticas suficientes para el CBO."
  else
    jq '
      .. | objects
      | select(has("#operator") and (has("~cost") or has("~cardinality")))
      | {
          operator: .["#operator"],
          cost: .["~cost"],
          cardinality: .["~cardinality"]
        }
    ' plans/plan_q1_before.json
  fi
  ```

> **IMPORTANTE:** Los valores `~cost` pertenecen al árbol de decisión del optimizer. No deben sumarse para inventar un “costo total”.
{: .lab-note .important .compact}

**Salida esperada:** se imprimirán objetos con `operator`, `cost` y/o `cardinality` para los operadores que expongan esas estimaciones; los valores numéricos no son fijos y dependen del CBO.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}

{% include support-prompt.html task="tarea3" %}

---

## 🧠 Tarea 4. ADVISE, covering index y CBO — 14 min
En esta tarea utilizarás ADVISE y estadísticas del optimizador para contrastar recomendaciones con un índice covering controlado, esperarás su disponibilidad y comprobarás cómo cambia el plan seleccionado por Query Service.

### Tarea 4.1. Ejecutar ADVISE
- {% include step_label.html %} Ejecuta `ADVISE` y guarda la respuesta completa, porque las recomendaciones pueden variar según estadísticas e índices existentes.

  ```bash
  STATEMENT="ADVISE $(tr '\n' ' ' < dataset/q1.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.' \
    | tee outputs/advise_q1.json
  ```

  ```bash
  jq '.. | .index_statement? // empty' outputs/advise_q1.json
  ```

**Salida esperada:** `outputs/advise_q1.json` debe contener una respuesta válida de ADVISE; puede incluir una o más recomendaciones de índice, o ninguna si el optimizador considera suficiente la estructura existente.

### Tarea 4.2. Crear un covering index controlado
- {% include step_label.html %} Crea el índice secundario covering diseñado para los predicados, ordenamiento y proyección de Q1, reduciendo la necesidad de recuperar documentos completos desde Data Service cuando el plan pueda cubrirse.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      CREATE INDEX idx_route_lab3_airline_price
      ON `travel-sample`.inventory.route_lab3
         (airline, price_usd DESC, sourceairport, destinationairport, distance_km)
      WHERE airline IS NOT MISSING;' \
    | jq '{status,errors}'
  ```

**Salida esperada:** la respuesta debe mostrar `"status": "success"` sin errores y comenzar la creación de `idx_route_lab3_airline_price` en Index Service.

### Tarea 4.3. Esperar estado online
- {% include step_label.html %} Consulta repetidamente `system:indexes` hasta que el índice optimizado llegue a estado `online`, evitando ejecutar la comparación mientras Index Service todavía construye la estructura.

  ```bash
  while true; do
    STATE=$(
      curl -s -u "$CB_USER:$CB_PASS" \
        -X POST http://localhost:8093/query/service \
        --data-urlencode 'statement=
          SELECT RAW state
          FROM system:indexes
          WHERE name = "idx_route_lab3_airline_price"
          LIMIT 1;' \
        | jq -r '.results[0] // "missing"'
    )

    echo "Estado: $STATE"
    [[ "$STATE" == "online" ]] && break
    sleep 5
  done
  ```

**Salida esperada:** durante la construcción pueden aparecer estados transitorios; el bucle debe finalizar cuando imprima `Estado: online`.

### Tarea 4.4. Actualizar estadísticas
- {% include step_label.html %} Actualiza estadísticas de los campos relevantes para proporcionar al Cost-Based Optimizer información de distribución y cardinalidad antes de solicitar un nuevo plan para Q1.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      UPDATE STATISTICS FOR `travel-sample`.inventory.route_lab3
      (airline, price_usd, sourceairport, destinationairport, distance_km);' \
    | jq '{status,errors}'
  ```

> **NOTA:** Couchbase Server 7.6 también puede recopilar estadísticas al crear o construir índices; aquí se ejecuta `UPDATE STATISTICS` para hacer explícita su relación con el CBO.
{: .lab-note .info .compact}

**Salida esperada:** Query Service debe responder `"status": "success"` sin errores, indicando que las estadísticas solicitadas fueron actualizadas para los campos especificados.

### Tarea 4.5. Comparar el nuevo plan
- {% include step_label.html %} Genera nuevamente `EXPLAIN` con la misma Q1, guarda el plan posterior y compara operadores e índice utilizado para identificar el cambio provocado por la optimización.

  ```bash
  STATEMENT="EXPLAIN $(tr '\n' ' ' < dataset/q1.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.results[0]' \
    | tee plans/plan_q1_after.json
  ```

  ```bash
  grep -n "idx_route_lab3_airline_price" plans/plan_q1_after.json
  ```

  ```bash
  echo "=== ANTES ==="
  jq -r '.. | objects | .["#operator"]? // empty' plans/plan_q1_before.json | sort | uniq -c

  echo "=== DESPUÉS ==="
  jq -r '.. | objects | .["#operator"]? // empty' plans/plan_q1_after.json | sort | uniq -c
  ```

**Salida esperada:** `plans/plan_q1_after.json` debe quedar creado y la búsqueda con `grep` debe localizar `idx_route_lab3_airline_price` cuando el optimizador seleccione el índice diseñado; la comparación mostrará la estructura antes y después.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}

{% include support-prompt.html task="tarea4" %}

---

## 🔗 Tarea 5. JOIN, GROUP BY y subconsultas — 16 min
En esta tarea ampliarás el diagnóstico hacia consultas con JOIN, agregaciones, filtros, UNNEST y subconsultas, observando cómo los índices y la forma de los documentos influyen en los planes generados.

### Tarea 5.1. Crear Q2
- {% include step_label.html %} Crea una consulta con JOIN y agregación que aproveche los `airlineid` reales incorporados durante la generación del dataset.

  ```bash
  cat > dataset/q2.sqlpp << 'EOFQ2'
  SELECT a.name AS airline_name,
         COUNT(*) AS total_routes,
         AVG(r.price_usd) AS avg_price,
         MAX(r.distance_km) AS max_distance
  FROM `travel-sample`.inventory.route_lab3 AS r
  JOIN `travel-sample`.inventory.airline AS a
    ON r.airlineid = META(a).id
  WHERE r.stops = 0
    AND r.seats_available > 10
  GROUP BY a.name
  HAVING COUNT(*) > 5
  ORDER BY total_routes DESC
  LIMIT 10;
  EOFQ2
  ```

**Salida esperada:** se crea `dataset/q2.sqlpp` sin errores y el archivo contiene el JOIN por `airlineid`, filtros de rutas directas y asientos, agregaciones por aerolínea y límite de 10 resultados.

### Tarea 5.2. Guardar el plan Q2
- {% include step_label.html %} Ejecuta `EXPLAIN` sobre Q2 y almacena el plan previo a la optimización para conservar una referencia de los operadores de JOIN, filtrado, agregación y ordenamiento seleccionados inicialmente.

  ```bash
  STATEMENT="EXPLAIN $(tr '\n' ' ' < dataset/q2.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.results[0]' \
    | tee plans/plan_q2_before.json
  ```

**Salida esperada:** `plans/plan_q2_before.json` debe contener el plan de Q2 con operadores correspondientes al acceso a datos, JOIN, filtrado, agregación, ordenamiento y límite según la estrategia seleccionada.

### Tarea 5.3. Ejecutar ADVISE para Q2
- {% include step_label.html %} Ejecuta `ADVISE` sobre Q2 y conserva la respuesta completa para revisar si Couchbase propone índices adicionales para los filtros y campos involucrados en la relación con aerolíneas.

  ```bash
  STATEMENT="ADVISE $(tr '\n' ' ' < dataset/q2.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.' \
    | tee outputs/advise_q2.json
  ```

**Salida esperada:** `outputs/advise_q2.json` debe contener una respuesta válida de ADVISE y, cuando corresponda, recomendaciones de índices relacionadas con los campos usados por Q2.

### Tarea 5.4. Crear índice secundario para filtros Q2
- {% include step_label.html %} Crea un índice secundario sobre `stops`, `seats_available`, `airlineid`, `price_usd` y `distance_km` para proporcionar un acceso más selectivo a los predicados y columnas utilizadas por Q2.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      CREATE INDEX idx_route_lab3_stops_seats
      ON `travel-sample`.inventory.route_lab3
         (stops, seats_available, airlineid, price_usd, distance_km);' \
    | jq '{status,errors}'
  ```

**Salida esperada:** la respuesta debe indicar `"status": "success"` y no presentar errores al solicitar la creación de `idx_route_lab3_stops_seats`.

### Tarea 5.5. Actualizar estadísticas y repetir EXPLAIN
- {% include step_label.html %} Actualiza estadísticas de los campos de Q2 y vuelve a generar `EXPLAIN` para comprobar si el CBO modifica la estrategia de acceso después de disponer del nuevo índice y datos estadísticos.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      UPDATE STATISTICS FOR `travel-sample`.inventory.route_lab3
      (stops, seats_available, airlineid, price_usd, distance_km);' \
    | jq '{status,errors}'
  ```

  ```bash
  STATEMENT="EXPLAIN $(tr '\n' ' ' < dataset/q2.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.results[0]' \
    | tee plans/plan_q2_after.json
  ```

**Salida esperada:** la actualización de estadísticas y el nuevo `EXPLAIN` deben finalizar con estado correcto; `plans/plan_q2_after.json` conservará el plan posterior para compararlo con el baseline.

### Tarea 5.6. Validar estructura de reviews antes de Q3
- {% include step_label.html %} Consulta una muestra real de `hotel.reviews` antes de construir Q3 para confirmar la forma del arreglo y la ruta `ratings.Overall` que posteriormente será recorrida mediante `UNNEST`.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT RAW h.reviews[0]
      FROM `travel-sample`.inventory.hotel AS h
      WHERE ARRAY_LENGTH(h.reviews) > 0
      LIMIT 1;' \
    | jq '.results[0]'
  ```

**Salida esperada:** debe mostrarse un objeto de review real que incluya su estructura de `ratings`; verifica que exista el campo `Overall` antes de continuar con Q3.

### Tarea 5.7. Crear y explicar Q3
- {% include step_label.html %} Crea Q3 con `UNNEST`, filtros y una subconsulta correlacionada, y genera su plan para identificar cómo Query Service descompone operaciones sobre arreglos y búsquedas relacionadas por ciudad.

  ```bash
  cat > dataset/q3.sqlpp << 'EOFQ3'
  SELECT h.name AS hotel_name,
         h.city,
         h.country,
         review.ratings.Overall AS overall_rating,
         (
           SELECT RAW COUNT(*)
           FROM `travel-sample`.inventory.landmark AS lm
           WHERE lm.city = h.city
         )[0] AS landmarks_nearby
  FROM `travel-sample`.inventory.hotel AS h
  UNNEST h.reviews AS review
  WHERE h.country = "United States"
    AND review.ratings.Overall >= 4
    AND h.free_parking = TRUE
  ORDER BY overall_rating DESC
  LIMIT 15;
  EOFQ3
  ```

  ```bash
  STATEMENT="EXPLAIN $(tr '\n' ' ' < dataset/q3.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    | jq '.results[0]' \
    | tee plans/plan_q3.json
  ```

**Salida esperada:** `dataset/q3.sqlpp` y `plans/plan_q3.json` deben quedar creados; el plan mostrará operadores asociados a acceso a hotel, `UNNEST`, filtros, ordenamiento y evaluación de la subconsulta.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}

{% include support-prompt.html task="tarea5" %}

---

## ⏱️ Tarea 6. Medir ejecución real con PROFILE — 14 min
En esta tarea pasarás de las estimaciones de EXPLAIN a mediciones reales con PROFILE, identificando tiempos e intercambio de elementos por operador y comparando elapsedTime con executionTime.

### Tarea 6.1. Perfilar Q1
- {% include step_label.html %} Ejecuta Q1 con `profile=timings` para capturar métricas de ejecución reales y guarda únicamente el estado, las métricas globales y el árbol instrumentado que se analizará en los pasos siguientes.

  ```bash
  STATEMENT="$(tr '\n' ' ' < dataset/q1.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    --data-urlencode 'profile=timings' \
    | jq '{status,metrics,executionTimings: .profile.executionTimings}' \
    | tee profiles/profile_q1.json
  ```

**Salida esperada:** `profiles/profile_q1.json` debe contener `status`, métricas como `elapsedTime` y `executionTime`, además de `executionTimings` con el árbol instrumentado de la consulta.

### Tarea 6.2. Extraer operadores instrumentados
- {% include step_label.html %} Recorre el árbol instrumentado de Q1 y extrae tiempo, elementos de entrada y salida por operador para localizar las etapas que concentran mayor trabajo durante la ejecución real.

  ```bash
  jq '
    .executionTimings
    | ..
    | objects
    | select(has("#operator"))
    | {
        operator: .["#operator"],
        time: .["#time"],
        itemsIn: .["#itemsIn"],
        itemsOut: .["#itemsOut"]
      }
  ' profiles/profile_q1.json
  ```

**Salida esperada:** se imprimirán operadores instrumentados con sus campos de tiempo y cantidades de entrada/salida cuando estén disponibles, permitiendo identificar las etapas con mayor trabajo.

### Tarea 6.3. Perfilar Q2
- {% include step_label.html %} Ejecuta Q2 con PROFILE bajo el mismo criterio utilizado para Q1 y conserva el resultado para comparar una consulta simple optimizada con otra que incluye JOIN y agregaciones.

  ```bash
  STATEMENT="$(tr '\n' ' ' < dataset/q2.sqlpp)"

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${STATEMENT}" \
    --data-urlencode 'profile=timings' \
    | jq '{status,metrics,executionTimings: .profile.executionTimings}' \
    | tee profiles/profile_q2.json
  ```

**Salida esperada:** `profiles/profile_q2.json` debe contener una ejecución exitosa con métricas globales y un árbol instrumentado que refleje las etapas adicionales de JOIN y agregación de Q2.

### Tarea 6.4. Comparar elapsedTime y executionTime
- {% include step_label.html %} Crea y ejecuta un analizador local que normaliza las unidades de tiempo de Couchbase y calcula la diferencia entre `elapsedTime` y `executionTime` sin atribuirla únicamente a la red.

  ```bash
  cat > scripts/compare-profile-times.py << 'EOFCOMP'
  import json
  import re
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent

  def parse_ms(value):
      if not value:
          return 0.0
      match = re.fullmatch(r"([0-9.]+)(ns|µs|us|ms|s)", str(value).strip())
      if not match:
          return 0.0
      number = float(match.group(1))
      unit = match.group(2)
      factors = {"ns": 1e-6, "µs": 1e-3, "us": 1e-3, "ms": 1, "s": 1000}
      return number * factors[unit]

  for filename, label in [
      ("profiles/profile_q1.json", "Q1"),
      ("profiles/profile_q2.json", "Q2"),
  ]:
      data = json.loads((root / filename).read_text(encoding="utf-8"))
      metrics = data.get("metrics", {})
      elapsed = parse_ms(metrics.get("elapsedTime"))
      execution = parse_ms(metrics.get("executionTime"))
      overhead = max(elapsed - execution, 0)
      print(
          f"{label}: elapsed={elapsed:.3f} ms | "
          f"execution={execution:.3f} ms | "
          f"overhead_no_execution={overhead:.3f} ms"
      )
  EOFCOMP

  python scripts/compare-profile-times.py \
    | tee outputs/profile-time-comparison.txt
  ```

> **IMPORTANTE:** `elapsedTime - executionTime` no debe interpretarse exclusivamente como latencia de red.
{: .lab-note .important .compact}

**Salida esperada:** `outputs/profile-time-comparison.txt` debe mostrar una línea para Q1 y otra para Q2 con valores normalizados en milisegundos para `elapsed`, `execution` y `overhead_no_execution`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}

{% include support-prompt.html task="tarea6" %}

---

## 📦 Tarea 7. Prepared statements y parámetros nombrados — 10 min
En esta tarea prepararás una consulta parametrizada, reutilizarás su plan con valores distintos y compararás varias ejecuciones ad hoc y prepared para comprender la reutilización del plan en Query Service.

### Tarea 7.1. Crear el prepared statement
- {% include step_label.html %} Prepara la consulta dentro de `travel-sample.inventory` para asociar el plan con ese query context y utilizar parámetros nombrados `$airline` y `$min_price`.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      PREPARE stmt_routes_by_airline AS
      SELECT r.airline,
             r.sourceairport,
             r.destinationairport,
             r.price_usd,
             r.distance_km
      FROM route_lab3 AS r
      WHERE r.airline = $airline
        AND r.price_usd > $min_price
      ORDER BY r.price_usd DESC
      LIMIT 20;' \
    --data-urlencode 'query_context=travel-sample.inventory' \
    | tee outputs/prepare-response.json \
    | jq '{status,name: .results[0].name}'
  ```

**Salida esperada:** la respuesta debe mostrar `"status": "success"` y un nombre de prepared statement en `.results[0].name`; la respuesta completa se conserva en `outputs/prepare-response.json`.

### Tarea 7.2. Capturar el nombre completo
- {% include step_label.html %} Extrae del JSON de respuesta el nombre completo asignado al prepared statement y guárdalo en una variable Bash para reutilizar exactamente ese identificador en las siguientes ejecuciones.

  ```bash
  PREPARED_NAME=$(jq -r '.results[0].name' outputs/prepare-response.json)
  echo "$PREPARED_NAME"
  ```

**Salida esperada:** la terminal debe imprimir un identificador no vacío correspondiente al prepared statement; ese mismo valor queda almacenado en `PREPARED_NAME`.

### Tarea 7.3. Ejecutar parámetros nombrados correctamente
- {% include step_label.html %} Envía los parámetros como propiedades REST con `$`, conservando el mismo `query_context` utilizado durante PREPARE.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "prepared=${PREPARED_NAME}" \
    --data-urlencode 'query_context=travel-sample.inventory' \
    --data-urlencode '$airline="AA"' \
    --data-urlencode '$min_price=400' \
    --data-urlencode 'timeout=5000ms' \
    --data-urlencode 'max_parallelism=2' \
    | jq '{status,resultCount: .metrics.resultCount,elapsedTime: .metrics.elapsedTime,errors}'
  ```

**Salida esperada:** la respuesta debe mostrar `"status": "success"`, un `resultCount` válido, un `elapsedTime` y ausencia de errores para los parámetros enviados.

### Tarea 7.4. Verificar system:prepareds
- {% include step_label.html %} Consulta `system:prepareds` para confirmar que el prepared statement permanece registrado y revisar sus metadatos de uso, sentencia asociada y último momento de utilización.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT name, statement, uses, lastUse
      FROM system:prepareds
      WHERE name LIKE "%stmt_routes_by_airline%";' \
    | jq '.results'
  ```

**Salida esperada:** debe aparecer al menos un registro cuyo nombre contenga `stmt_routes_by_airline`, acompañado de la sentencia preparada y metadatos de uso cuando estén disponibles.

### Tarea 7.5. Comparar cinco ejecuciones
- {% include step_label.html %} Crea un script que ejecute cinco consultas ad hoc y cinco prepared con el mismo criterio funcional, guardando tiempos reportados por Couchbase en CSV para una comparación repetible.

  ```bash
  cat > scripts/benchmark-prepared.sh << 'EOFBENCH'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  # Cargar lab.env únicamente si existe.
  if [[ -f "${ROOT_DIR}/lab.env" ]]; then
    source "${ROOT_DIR}/lab.env"
  fi

  # Validar variables necesarias.
  : "${CB_USER:?ERROR: CB_USER no está definido}"
  : "${CB_PASS:?ERROR: CB_PASS no está definido}"

  PREPARED_NAME="${1:?Uso: benchmark-prepared.sh <PREPARED_NAME>}"

  echo "mode,iteration,elapsedTime,executionTime"

  for i in $(seq 1 5); do
    curl --fail-with-body -sS \
      -u "${CB_USER}:${CB_PASS}" \
      -X POST \
      http://localhost:8093/query/service \
      --data-urlencode 'statement=
        SELECT r.airline,
              r.sourceairport,
              r.destinationairport,
              r.price_usd,
              r.distance_km
        FROM `travel-sample`.inventory.route_lab3 AS r
        WHERE r.airline = "AA"
          AND r.price_usd > 400
        ORDER BY r.price_usd DESC
        LIMIT 20;' \
      | jq -r \
          --arg i "$i" \
          '["adhoc",$i,.metrics.elapsedTime,.metrics.executionTime] | @csv'
  done

  for i in $(seq 1 5); do
    curl --fail-with-body -sS \
      -u "${CB_USER}:${CB_PASS}" \
      -X POST \
      http://localhost:8093/query/service \
      --data-urlencode "prepared=${PREPARED_NAME}" \
      --data-urlencode 'query_context=travel-sample.inventory' \
      --data-urlencode '$airline="AA"' \
      --data-urlencode '$min_price=400' \
      | jq -r \
          --arg i "$i" \
          '["prepared",$i,.metrics.elapsedTime,.metrics.executionTime] | @csv'
  done
  EOFBENCH
  ```
  ```bash
  chmod +x scripts/benchmark-prepared.sh
  bash -n scripts/benchmark-prepared.sh
  ```
  ```bash
  ./scripts/benchmark-prepared.sh "$PREPARED_NAME" \
    | tee benchmarks/prepared-comparison.csv
  ```

**Salida esperada:** `benchmarks/prepared-comparison.csv` debe contener una cabecera y diez filas de medición: cinco `adhoc` y cinco `prepared`, cada una con `elapsedTime` y `executionTime`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}

{% include support-prompt.html task="tarea7" %}

---

## ⏲️ Tarea 8. timeout y max_parallelism — 6 min
En esta tarea revisarás parámetros operativos de Query Service y demostrarás cómo timeout y max_parallelism permiten limitar duración y paralelismo sin modificar la sentencia SQL++.

### Tarea 8.1. Consultar configuración del Query Service
- {% include step_label.html %} Consulta la configuración administrativa de Query Service para observar los parámetros efectivos del nodo antes de aplicar límites por solicitud durante las pruebas de timeout y paralelismo.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8093/admin/config \
    | jq .
  ```

**Salida esperada:** se mostrará un objeto JSON con la configuración efectiva de Query Service; los valores concretos pueden variar según el nodo y la configuración aplicada al clúster.

### Tarea 8.2. Demostrar timeout
- {% include step_label.html %} Ejecuta una consulta de agregación con un timeout deliberadamente bajo para demostrar la protección sin dejar una operación pesada ejecutándose durante demasiado tiempo.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT COUNT(*)
      FROM `travel-sample`.inventory.route_lab3 AS r
      WHERE LOWER(r.equipment) LIKE "%73%"
        AND r.year BETWEEN 2019 AND 2026;' \
    --data-urlencode 'timeout=5ms' \
    | jq '{status,errors,metrics}'
  ```

> **NOTA:** Si el entorno completa la consulta antes de 5 ms, utiliza `timeout=1ms` una sola vez para demostrar la protección.
{: .lab-note .info .compact}

**Salida esperada:** normalmente la respuesta mostrará un estado de error o timeout y un mensaje asociado a la expiración de la solicitud; si termina demasiado rápido, la nota permite repetir una sola vez con `1ms`.

### Tarea 8.3. Comparar max_parallelism
- {% include step_label.html %} Ejecuta Q1 con `max_parallelism` igual a 1 y 2 para comparar los tiempos reportados y observar el efecto del paralelismo sin asumir que un valor mayor siempre mejora el rendimiento.

  ```bash
  for parallelism in 1 2; do
    echo "=== max_parallelism=${parallelism} ==="

    curl -s -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8093/query/service \
      --data-urlencode "statement=$(tr '\n' ' ' < dataset/q1.sqlpp)" \
      --data-urlencode "max_parallelism=${parallelism}" \
      | jq '{status,elapsedTime: .metrics.elapsedTime,executionTime: .metrics.executionTime}'
  done
  ```

**Salida esperada:** se mostrarán dos bloques, uno para `max_parallelism=1` y otro para `max_parallelism=2`, cada uno con estado y tiempos; no se exige que el segundo sea necesariamente menor.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}

{% include support-prompt.html task="tarea8" %}

---

## 🚦 Tarea 9. Carga concurrente y Query Monitor — 10 min
En esta tarea generarás concurrencia controlada desde un cliente Python y correlacionarás throughput y percentiles del cliente con solicitudes activas, completadas y la observación disponible en Query Monitor.

### Tarea 9.1. Crear concurrent_queries.py
- {% include step_label.html %} Crea un cliente Python con `ThreadPoolExecutor` para ejecutar 300 consultas con 10 workers y calcular throughput, promedio, P50, P95 y P99.

  ```bash
  cat > benchmarks/concurrent_queries.py << 'EOFCONC'
  import json
  import os
  import random
  import statistics
  import time
  from concurrent.futures import ThreadPoolExecutor, as_completed
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions, QueryOptions

  HOST = os.environ.get("CB_HOST", "couchbase://cb-cs400")
  USER = os.environ.get("CB_USER", "Administrator")
  PASSWORD = os.environ.get("CB_PASS", "Password123!")

  WORKERS = 10
  TOTAL_QUERIES = 300

  airlines = [
      "AA",
      "UA",
      "DL",
      "BA",
      "LH",
      "AF",
  ]

  auth = PasswordAuthenticator(
      USER,
      PASSWORD,
  )

  cluster = Cluster(
      HOST,
      ClusterOptions(auth),
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  statement = """
  SELECT r.airline,
        r.sourceairport,
        r.destinationairport,
        r.price_usd
  FROM `travel-sample`.inventory.route_lab3 AS r
  WHERE r.airline = $airline
    AND r.price_usd > $min_price
  ORDER BY r.price_usd DESC
  LIMIT 20
  """


  def execute_query(sequence):
      start = time.perf_counter()

      try:
          result = cluster.query(
              statement,
              QueryOptions(
                  named_parameters={
                      "airline": random.choice(airlines),
                      "min_price": random.randint(100, 900),
                  },
                  timeout=timedelta(seconds=10),
                  adhoc=False,
              ),
          )

          rows = list(
              result.rows()
          )

          return {
              "ok": True,
              "sequence": sequence,
              "rows": len(rows),
              "elapsed_ms":
                  (time.perf_counter() - start) * 1000,
          }

      except Exception as exc:
          return {
              "ok": False,
              "sequence": sequence,
              "elapsed_ms":
                  (time.perf_counter() - start) * 1000,
              "error": str(exc),
          }


  def percentile(values, p):
      if not values:
          return None

      idx = min(
          len(values) - 1,
          round(
              (p / 100)
              * (len(values) - 1)
          ),
      )

      return values[idx]


  started = time.perf_counter()
  results = []

  with ThreadPoolExecutor(
      max_workers=WORKERS
  ) as executor:

      futures = [
          executor.submit(
              execute_query,
              i,
          )
          for i in range(TOTAL_QUERIES)
      ]

      for future in as_completed(futures):
          results.append(
              future.result()
          )

  total_seconds = (
      time.perf_counter()
      - started
  )

  ok = [
      result
      for result in results
      if result["ok"]
  ]

  failed = [
      result
      for result in results
      if not result["ok"]
  ]

  latencies = sorted(
      result["elapsed_ms"]
      for result in ok
  )

  summary = {
      "workers": WORKERS,
      "total_queries": TOTAL_QUERIES,
      "success": len(ok),
      "failed": len(failed),
      "total_seconds": round(
          total_seconds,
          3,
      ),
      "queries_per_second": round(
          len(ok) / total_seconds
          if total_seconds
          else 0,
          2,
      ),
      "avg_ms": round(
          statistics.mean(latencies),
          3,
      ) if latencies else None,
      "p50_ms": round(
          percentile(latencies, 50),
          3,
      ) if latencies else None,
      "p95_ms": round(
          percentile(latencies, 95),
          3,
      ) if latencies else None,
      "p99_ms": round(
          percentile(latencies, 99),
          3,
      ) if latencies else None,
  }

  print(
      json.dumps(
          summary,
          indent=2,
      )
  )

  if failed:
      print(
          "\nPrimeros errores:",
          file=os.sys.stderr,
      )

      for error in failed[:5]:
          print(
              json.dumps(
                  error,
                  ensure_ascii=False,
              ),
              file=os.sys.stderr,
          )

  cluster.close()
  EOFCONC
  ```

**Salida esperada:** se crea `benchmarks/concurrent_queries.py` sin errores; el script queda configurado para 10 workers, 300 consultas y cálculo de throughput, promedio, P50, P95 y P99.

### Tarea 9.2. Ejecutar la carga
- {% include step_label.html %} Copia el generador concurrente al Pod cliente y ejecútalo dentro de EKS para mantener el tráfico de SDK en la red del clúster y conservar el resumen JSON como evidencia de la prueba.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    benchmarks/concurrent_queries.py \
    couchbase/cb-query-client:/tmp/concurrent_queries.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    cb-query-client \
    -- \
    env \
      CB_HOST="couchbase://cb-cs400" \
      CB_USER="$CB_USER" \
      CB_PASS="$CB_PASS" \
      python /tmp/concurrent_queries.py \
    | tee benchmarks/concurrent-results.json
  ```

**Salida esperada:** `benchmarks/concurrent-results.json` debe contener un resumen JSON con `workers`, `total_queries`, `success`, `failed`, `queries_per_second`, `avg_ms`, `p50_ms`, `p95_ms` y `p99_ms`.

### Tarea 9.3. Observar Active Requests y Completed Requests
- {% include step_label.html %} Consulta los endpoints administrativos de solicitudes activas y completadas para observar qué trabajo está ejecutando Query Service y qué consultas recientes quedan disponibles para diagnóstico.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8093/admin/active_requests \
    | jq 'map({requestId,statement,elapsedTime,executionTime,state})[0:10]'
  ```

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8093/admin/completed_requests \
    | jq 'map({requestId,statement,elapsedTime,executionTime,state})[0:10]'
  ```

**Salida esperada:** `active_requests` puede estar vacío si la carga terminó antes de consultarlo; `completed_requests` debe mostrar solicitudes recientes cuando el registro de completadas esté habilitado y disponible.

### Tarea 9.4. Correlacionar con Web Console
- {% include step_label.html %} Abre `http://localhost:8091`, entra a **Query** y utiliza Query Monitor para comparar solicitudes activas y completadas con los percentiles calculados por el cliente Python.

| Indicador | Valor |
|---|---|
| Active Requests pico |  |
| P95 cliente Python |  |
| P99 cliente Python |  |
| Consulta más lenta visible |  |

**Salida esperada:** completa la tabla con observaciones reales de Query Monitor y compáralas con P95 y P99 del cliente; los valores dependen de la carga y del momento exacto de observación.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}

{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Reporte, validación y limpieza — 6 min
En esta tarea consolidarás evidencias, validarás los resultados mínimos del laboratorio y retirarás únicamente los recursos experimentales creados para la práctica, conservando los archivos locales de análisis.

### Tarea 10.1. Crear validate.sh
- {% include step_label.html %} Crea una validación final basada en volumen, índices, planes, perfiles, prepared statement y resultados de concurrencia, evitando exigir costos o tiempos específicos.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab3/validate.sh
  ```

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ./scripts/validate.sh
  ```

**Salida esperada:** el script debe finalizar mostrando varios mensajes `PASS` y una línea `RESULTADO: <n> PASS / 0 FAIL`; cualquier `FAIL` debe investigarse antes de realizar la limpieza.

### Tarea 10.2. Eliminar route_lab3
- {% include step_label.html %} Elimina la collection completa para retirar los 500K documentos y sus índices en una sola operación sin afectar `inventory.route`.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.route_lab3 IF EXISTS;' \
    | jq '{status,errors}'
  ```

**Salida esperada:** Query Service debe responder con `"status": "success"` y sin errores; `route_lab3` y los índices pertenecientes a esa collection dejan de estar disponibles.

### Tarea 10.3. Eliminar el cliente temporal
- {% include step_label.html %} Elimina el Pod cliente temporal utilizado para generar carga y después enumera las evidencias locales para confirmar que planes, perfiles, benchmarks y reportes permanecen disponibles.

  ```bash
  kubectl delete pod cb-query-client -n couchbase --ignore-not-found
  find plans profiles benchmarks outputs -maxdepth 1 -type f | sort
  ```

**Salida esperada:** Kubernetes debe indicar que `cb-query-client` fue eliminado o que no existía, y `find` debe listar las evidencias locales creadas durante la práctica.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}

{% include support-prompt.html task="tarea10" %}

---

## 🧹 Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` los port-forward de 8091 y 8093 antes de iniciar la eliminación de infraestructura.

- {% include step_label.html %} Elimina EKS si el instructor indica que no será reutilizado por el siguiente laboratorio.

  ```bash
  cd /c/LABS/couchbase-nosql/lab3
  ./scripts/eks-cluster.sh delete
  ```

- {% include step_label.html %} Confirma que AWS ya no pueda describir el clúster.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:** `ResourceNotFoundException`.