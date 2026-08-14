---
layout: lab
title: "Práctica 4: Diseño de una estrategia de indexación para alta carga"
permalink: /lab4/lab4/
images_base: /labs/lab4/img
duration: "90 minutos"
objective:
  - Analizar un workload objetivo de 1 000 QPS y traducir sus patrones de acceso en una estrategia GSI sobre Couchbase Server Enterprise 7.6.2.
  - Diseñar índices de clave simple, compuestos, parciales y covering, justificando cada decisión mediante EXPLAIN y métricas del Query e Index Service.
  - Comparar un índice no particionado con otro equivalente creado mediante PARTITION BY HASH para estudiar distribución horizontal del Index Service.
  - Crear una réplica de índice con num_replica=1 sobre dos Pods Index y verificar continuidad de consultas durante la pérdida temporal de un Pod.
  - Aplicar defer_build y BUILD INDEX para construir varios índices coordinadamente y observar los estados deferred, building y online.
  - Reconstruir operativamente un índice mediante DROP, CREATE deferred y BUILD sin manipular archivos internos del servicio.
  - Conservar planes, estadísticas y reportes localmente y eliminar la collection experimental sin afectar las collections originales de travel-sample.
prerequisites:
  - Haber completado la Práctica 3 o dominar EXPLAIN, ADVISE y la lectura básica de planes SQL++.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl y jq disponibles desde Git Bash.
  - Comprender la función de Data, Query e Index Service en Couchbase Server.
introduction:
  - En esta práctica diseñarás una estrategia GSI para un sistema de reservas con un workload objetivo de 1 000 QPS distribuido entre cinco patrones de acceso. Los datos se crearán en travel-sample.inventory.booking_lab4 para mantener el experimento aislado. La topología incluirá dos Pods Index independientes, condición necesaria para demostrar particionamiento, num_replica=1 y continuidad de consultas durante la pérdida temporal de un Pod Index. La cifra de 1 000 QPS representa una distribución objetivo de demanda y no una prueba de throughput real.
slug: lab4
lab_number: 4
final_result: >
  Al finalizar la práctica habrás convertido cinco patrones de acceso en una estrategia de indexación justificable, comparado planes antes y después de aplicar GSI, creado índices parciales, covering y particionados, desplegado una réplica sobre dos nodos Index, verificado continuidad durante la recreación de un Pod, utilizado deferred build y reconstruido un índice mediante un procedimiento soportado. Las evidencias permanecerán almacenadas localmente y la collection experimental podrá eliminarse sin alterar travel-sample.
notes:
  - Los 90 minutos corresponden únicamente a las tareas funcionales de Couchbase. La creación y eliminación de Amazon EKS están incluidas, pero fuera de ese tiempo.
  - La práctica utiliza Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - La topología utiliza dos Pods Data + Query, dos Pods Index y un Pod Analytics + Eventing.
  - num_replica=1 requiere al menos dos nodos Index.
  - Los valores de latencia, costo, cardinalidad, tamaño y tiempo de build dependen del entorno y no se validan cifras fijas.
  - Los planes, estadísticas y resultados se guardan en C:\LABS\couchbase-nosql\lab4.
references:
  - text: Creación de índices secundarios con CREATE INDEX
    url: https://docs.couchbase.com/server/7.6/n1ql/n1ql-language-reference/createindex.html
  - text: Construcción coordinada de índices con BUILD INDEX
    url: https://docs.couchbase.com/server/7.6/n1ql/n1ql-language-reference/build-index.html
  - text: Diseño y uso de índices parciales
    url: https://docs.couchbase.com/server/current/indexes/partial-indexes.html
  - text: Diseño y uso de covering indexes
    url: https://docs.couchbase.com/server/current/indexes/covering-indexes.html
  - text: Particionamiento de índices GSI
    url: https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/index-partitioning.html
  - text: Réplicas de índices y alta disponibilidad
    url: https://docs.couchbase.com/server/current/indexes/index-replication.html
  - text: REST API del Index Service
    url: https://docs.couchbase.com/server/current/rest-api/rest-index-service.html
  - text: Estadísticas REST del Index Service
    url: https://docs.couchbase.com/server/current/index-rest-stats/index.html
  - text: Couchbase Kubernetes Operator 2.9
    url: https://docs.couchbase.com/operator/current/release-notes.html
  - text: Versiones de Kubernetes admitidas por Amazon EKS
    url: https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
prev: /lab3/lab3/
next: /lab5/lab5/
---

---

> **IMPORTANTE:** Ejecuta los bloques `bash` únicamente en Git Bash; heredoc, rutas `/c/...` y expansión de variables no son equivalentes en PowerShell o CMD.
{: .lab-note .important .compact}

## 📁 Preparación del directorio de trabajo

### Crear la estructura local

- {% include step_label.html %} Abre **Visual Studio Code** sobre `C:\LABS\couchbase-nosql` para trabajar en la misma raíz y conservar continuidad con las prácticas previas.

**Salida esperada:** VS Code debe mostrar `C:\LABS\couchbase-nosql` como carpeta raíz del workspace, permitiendo crear `lab4` junto a los laboratorios anteriores.

- {% include step_label.html %} Abre **Git Bash** y crea la estructura de `lab4` para separar scripts, manifiestos, datos, planes, estadísticas, benchmarks y evidencias.

```bash
mkdir -p /c/LABS/couchbase-nosql/lab4/{scripts,manifests,dataset,plans,stats,benchmarks,outputs}
cd /c/LABS/couchbase-nosql/lab4
pwd
find . -maxdepth 1 -type d | sort
```

**Salida esperada:**

```text
/c/LABS/couchbase-nosql/lab4
./benchmarks
./dataset
./manifests
./outputs
./plans
./scripts
./stats
```

---

## 🧰 Herramientas y enlaces oficiales

| Herramienta | Uso en la práctica | Enlace |
|---|---|---|
| AWS CLI v2 | Identidad, kubeconfig y validación de EKS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| eksctl | Crear, consultar y eliminar Amazon EKS | https://eksctl.io/installation/ |
| kubectl | Administrar Pods, PVC y port-forward | https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/ |
| Helm 3 | Instalar Couchbase Kubernetes Operator | https://helm.sh/docs/intro/install/ |
| jq | Filtrar respuestas JSON de Couchbase y Kubernetes | https://jqlang.org/download/ |
| Git for Windows | Proporcionar Git Bash y utilidades GNU | https://git-scm.com/download/win |
| VS Code | Editar scripts, manifiestos y evidencias | https://code.visualstudio.com/download |

---

## ☁️ Preparación de infraestructura

## Crear variables comunes

- {% include step_label.html %} Crea `lab.env` para centralizar región, nombres, versiones y credenciales, evitando valores inconsistentes entre scripts y validaciones.

```bash
cat > lab.env << 'EOF'
export AWS_REGION="us-west-2"
export EKS_CLUSTER="cb-cs400-lab04"
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
export CB_COLLECTION="booking_lab4"
EOF
```
```bash
source lab.env
```
```bash
printf 'EKS_CLUSTER=%s\nCB_CLUSTER=%s\nCB_IMAGE=%s\n' \
  "$EKS_CLUSTER" "$CB_CLUSTER" "$CB_IMAGE"
```


**Salida esperada:**

```text
EKS_CLUSTER=cb-cs400-lab04
CB_CLUSTER=cb-cs400
CB_IMAGE=couchbase/server:enterprise-7.6.2
```

## Crear el script de ciclo de vida EKS

- {% include step_label.html %} Crea `scripts/eks-cluster.sh` para validar dependencias y administrar EKS con acciones reproducibles de creación, consulta de estado y eliminación.


  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab4/eks-cluster.sh
  ```

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:**

```text
El script no muestra errores de `bash -n`.
Los tres nodos EKS aparecen en estado Ready y muestran su tipo de instancia y zona.
```

## Crear almacenamiento gp3

- {% include step_label.html %} Crea la StorageClass `gp3-couchbase` con binding diferido para que EBS se aprovisione en la misma zona donde Kubernetes ubique cada Pod.

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
```bash
kubectl apply -f manifests/storageclass-gp3.yaml
```

**Salida esperada:**

```text
storageclass.storage.k8s.io/gp3-couchbase created
# o: storageclass.storage.k8s.io/gp3-couchbase unchanged
```

## Instalar Couchbase Kubernetes Operator

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 con Helm, deshabilitando el clúster automático para aplicar después la topología del laboratorio.

```bash
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/ --force-update
helm repo update
```
```bash
helm upgrade --install cb-operator couchbase/couchbase-operator \
  --namespace couchbase \
  --create-namespace \
  --version "$CB_OPERATOR_VERSION" \
  --set install.couchbaseCluster=false
```
```bash
kubectl wait -n couchbase --for=condition=Available deployment --all --timeout=5m
```

**Salida esperada:**

```text
Release "cb-operator" has been upgraded.
deployment.apps/... condition met
```

## Crear CouchbaseCluster con dos Pods Index

- {% include step_label.html %} Crea el secreto administrativo y define cinco Pods Couchbase: dos Data + Query, dos Index y uno Analytics + Eventing para las pruebas GSI.

```bash
kubectl create secret generic cb-admin \
  --namespace couchbase \
  --from-literal=username="$CB_USER" \
  --from-literal=password="$CB_PASS" \
  --dry-run=client -o yaml > manifests/cb-admin-secret.yaml
```
```bash
kubectl apply -f manifests/cb-admin-secret.yaml
```

```bash
cat > manifests/couchbase-cluster.yaml << 'EOF'
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

  # ------------------------------------------------------------
  # Cuotas internas de memoria de Couchbase
  # ------------------------------------------------------------
  cluster:
    dataServiceMemoryQuota: 3Gi
    queryServiceMemoryQuota: 1Gi
    indexServiceMemoryQuota: 4Gi
    analyticsServiceMemoryQuota: 2Gi
    eventingServiceMemoryQuota: 1Gi

    indexer:
      storageMode: plasma

  # ------------------------------------------------------------
  # Clases de servidores Couchbase
  # ------------------------------------------------------------
  servers:

    # Data + Query
    - name: data-query
      size: 2

      services:
        - data
        - query

      resources:
        requests:
          cpu: "1000m"
          memory: "5Gi"
        limits:
          cpu: "2000m"
          memory: "6Gi"

      volumeMounts:
        default: couchbase-volume

    # Index dedicado
    - name: index
      size: 2

      services:
        - index

      resources:
        requests:
          cpu: "1250m"
          memory: "5Gi"
        limits:
          cpu: "2500m"
          memory: "7Gi"

      volumeMounts:
        default: couchbase-volume

    # Analytics + Eventing
    - name: analytics-eventing
      size: 1

      services:
        - analytics
        - eventing

      resources:
        requests:
          cpu: "750m"
          memory: "4Gi"
        limits:
          cpu: "1500m"
          memory: "5Gi"

      volumeMounts:
        default: couchbase-volume

  # ------------------------------------------------------------
  # Almacenamiento persistente
  # ------------------------------------------------------------
  volumeClaimTemplates:
    - metadata:
        name: couchbase-volume

      spec:
        storageClassName: gp3-couchbase

        resources:
          requests:
            storage: 40Gi
EOF
```
```bash
kubectl apply -f manifests/couchbase-cluster.yaml
```
```bash
for i in $(seq 1 90); do
  POD_COUNT=$(kubectl get pods -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$POD_COUNT" -ge 5 ]] && break
  echo "Esperando creación de los 5 Pods Couchbase... intento $i/90"
  sleep 10
done
```
```bash
kubectl wait -n "$CB_NAMESPACE" --for=condition=Ready pod \
  -l "couchbase_cluster=$CB_CLUSTER" --timeout=15m
```
```bash
kubectl get pods -n "$CB_NAMESPACE" \
  -l "couchbase_cluster=$CB_CLUSTER" -o wide
kubectl get pvc -n "$CB_NAMESPACE"
```

> **IMPORTANTE:** Confirma dos nodos Index antes de continuar, porque `num_replica=1` necesita ubicar la copia del índice en otro miembro del servicio.
{: .lab-note .important .compact}


**Salida esperada:**

```text
Cinco Pods con READY 1/1 y STATUS Running.
Cinco PVC asociados a los Pods Couchbase en estado Bound.
```

## Cargar travel-sample y abrir port-forward

- {% include step_label.html %} Abre una segunda terminal de Git Bash y publica localmente el puerto 8091 para acceder a Web Console y Management REST API sin LoadBalancer.

**Salida esperada:** la terminal debe permanecer ejecutando `Forwarding from 127.0.0.1:8091 -> 8091`; mantén este proceso activo mientras uses la consola o REST.

```bash
kubectl port-forward -n couchbase service/cb-cs400-ui 8091:8091
```

- {% include step_label.html %} Comprueba si `travel-sample` ya existe e instálalo sólo cuando falte, manteniendo la preparación idempotente al reutilizar el entorno.

**Salida esperada:** si el bucket ya existe se mostrará `travel-sample ya existe.`; si no existe, Couchbase aceptará la instalación del sample bucket sin errores.

```bash
if ! curl -fsS -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/travel-sample >/dev/null 2>&1; then
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST \
    http://localhost:8091/sampleBuckets/install \
    -d '["travel-sample"]' | jq .
else
  echo "travel-sample ya existe."
fi
```

- {% include step_label.html %} Abre una tercera terminal de Git Bash y publica el puerto 8093 de Query Service para enviar SQL++ mediante REST desde el equipo local.

```bash
source lab.env
QUERY_POD=$(
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq -r '
      .nodes[]
      | select(.services | index("n1ql"))
      | .hostname
    ' \
  | head -n1 \
  | cut -d. -f1
)

echo "Query Pod seleccionado: $QUERY_POD"
```
```bash
kubectl port-forward \
  -n couchbase \
  "pod/${QUERY_POD}" \
  8093:8093
```

**Salida esperada:**

```text
Forwarding from 127.0.0.1:8091 -> 8091
travel-sample disponible.
Forwarding from 127.0.0.1:8093 -> 8093
```

---

## 🔎 Tarea 1. Validar dos nodos Index y analizar el workload — 6 min

En esta tarea confirmarás la topología distribuida requerida por GSI y transformarás la mezcla objetivo de consultas en decisiones de indexación justificables.


### Tarea 1.1. Confirmar servicios

- {% include step_label.html %} Consulta `/pools/default` y confirma dos servicios Index, dos Data y dos Query saludables antes de crear datos, índices o pruebas de disponibilidad.

```bash
source lab.env
curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
  | jq '[.nodes[] | {hostname,status,membership:.clusterMembership,services}]'
```


**Salida esperada:**

```text
Arreglo JSON con 5 nodos `healthy`; dos contienen `index`, dos contienen `kv` + `n1ql`, y uno contiene `cbas` + `eventing`.
```

### Tarea 1.2. Identificar Pods Index

- {% include step_label.html %} Lista cada Pod con worker e IP para registrar su ubicación física y disponer de evidencia antes de probar distribución y recuperación de Index.

```bash
kubectl get pods -n couchbase \
  -o custom-columns='POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,POD_IP:.status.podIP'
```


**Salida esperada:**

```text
Tabla con POD, STATUS, NODE y POD_IP. Los cinco Pods Couchbase deben aparecer en `Running`.
```

### Tarea 1.3. Analizar el workload objetivo

- {% include step_label.html %} Interpreta la mezcla de 1 000 QPS como distribución lógica de demanda y determina qué consultas deben recibir mayor prioridad de indexación.

| Consulta | QPS objetivo | % | Patrón |
|---|---:|---:|---|
| Q1 | 400 | 40% | customerId |
| Q2 | 300 | 30% | origin + destination + date range |
| Q3 | 150 | 15% | status + price range |
| Q4 | 100 | 10% | customer + ORDER BY date + proyección corta |
| Q5 | 50 | 5% | status + GROUP BY origin |


**Salida esperada:**

```text
La suma de Q1–Q5 es 1 000 QPS y 100 %. Q1 y Q2 concentran 70 % de la demanda objetivo.
```

### Tarea 1.4. Matriz de diseño

- {% include step_label.html %} Completa la última columna antes de crear índices para justificar la estrategia en función de frecuencia, filtro, orden y proyección.

| Query | Predicados | Orden/agregado | Proyección | Diseño propuesto |
|---|---|---|---|---|
| Q1 | customerId | — | bookingId, flightId, status, date |  |
| Q2 | origin,destination,date | — | bookingId, customerId, price, cabin |  |
| Q3 | status,price | — | bookingId, customerId, origin,destination,price |  |
| Q4 | customerId | date DESC | bookingId,status,date,price |  |
| Q5 | status | GROUP BY origin | origin,count |  |


**Salida esperada:**

```text
La columna «Diseño propuesto» queda completada para Q1–Q5 antes de crear índices.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🧱 Tarea 2. Crear booking_lab4, cargar 200 000 y establecer baseline — 10 min
En esta tarea crearás una collection aislada, generarás 200 000 reservas reproducibles y establecerás el baseline que servirá para comparar los índices posteriores.


### Tarea 2.1. Crear collection experimental

- {% include step_label.html %} Recrea `booking_lab4` dentro de `travel-sample.inventory` para aislar por completo el experimento de las collections originales del sample bucket.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.booking_lab4 IF EXISTS;' | jq '{status,errors}'
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE COLLECTION `travel-sample`.inventory.booking_lab4 IF NOT EXISTS;' | jq '{status,errors}'
```


**Salida esperada:**

```text
{"status":"success","errors":null}
{"status":"success","errors":null}
```

### Tarea 2.2. Crear cliente Python

- {% include step_label.html %} Despliega un Pod cliente temporal y agrega el SDK de Couchbase para generar datos desde dentro del clúster Kubernetes sin exponer el Data Service.

```bash
cat > manifests/python-client.yaml << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cb-index-client
  namespace: couchbase
spec:
  restartPolicy: Never
  containers:
    - name: python
      image: python:3.12-slim
      command: ["sh", "-c", "sleep 9000"]
      resources:
        requests:
          cpu: "500m"
          memory: "512Mi"
        limits:
          cpu: "2"
          memory: "2Gi"
EOF
```
```bash
kubectl apply -f manifests/python-client.yaml
```
```bash
kubectl wait -n couchbase --for=condition=Ready pod/cb-index-client --timeout=3m
kubectl exec -n couchbase cb-index-client -- pip install --quiet 'couchbase>=4.4,<5'
```


**Salida esperada:**

```text
pod/cb-index-client created
pod/cb-index-client condition met
# pip finaliza sin error
```

### Tarea 2.3. Generar 200 000 documentos idempotentes

- {% include step_label.html %} Genera 200 000 claves determinísticas por lotes para que una repetición sobrescriba los mismos documentos y no incremente la cardinalidad.

```bash
cat > dataset/generate_bookings.py << 'PYEOF'
import os
import random
import time
from datetime import date, timedelta

from couchbase.auth import PasswordAuthenticator
from couchbase.cluster import Cluster
from couchbase.options import ClusterOptions

HOST = os.environ.get("CB_HOST", "couchbase://cb-cs400")
USER = os.environ.get("CB_USER", "Administrator")
PASSWORD = os.environ.get("CB_PASS", "Password123!")
TARGET = 200_000
BATCH = 1_000

airlines = ["AA", "UA", "DL", "LH", "BA", "IB", "AF", "KL", "QR", "EK"]
airports = ["JFK", "LAX", "ORD", "LHR", "CDG", "FRA", "DXB", "SIN", "NRT", "GRU"]
statuses = ["confirmed", "pending", "cancelled"]
cabins = ["economy", "business", "first"]

random.seed(4004)

auth = PasswordAuthenticator(USER, PASSWORD)
cluster = Cluster(HOST, ClusterOptions(auth))
cluster.wait_until_ready(timedelta(seconds=30))
collection = (
    cluster.bucket("travel-sample")
    .scope("inventory")
    .collection("booking_lab4")
)

start = time.perf_counter()

for batch_start in range(0, TARGET, BATCH):
    docs = {}
    batch_end = min(batch_start + BATCH, TARGET)

    for seq in range(batch_start, batch_end):
        origin = random.choice(airports)
        destination = random.choice([x for x in airports if x != origin])
        airline = random.choice(airlines)
        departure = date(2026, random.randint(1, 12), random.randint(1, 28))
        key = f"booking_lab4_{seq:09d}"

        docs[key] = {
            "type": "booking",
            "bookingId": f"BK-{seq:09d}",
            "customerId": f"cust_{(seq % 50_000) + 1:05d}",
            "flightId": f"{airline}{random.randint(100, 999)}",
            "origin": origin,
            "destination": destination,
            "departureDate": departure.isoformat(),
            "cabin": random.choice(cabins),
            "price": round(random.uniform(150, 5000), 2),
            "status": random.choice(statuses),
            "createdAt": f"{departure.isoformat()}T12:00:00+00:00",
        }

    collection.upsert_multi(docs)
    processed = batch_end

    if processed % 50_000 == 0 or processed == TARGET:
        print(
            f"Procesados={processed:,}/{TARGET:,} "
            f"tiempo={time.perf_counter() - start:.1f}s"
        )

print(f"Documentos procesados: {TARGET:,}")
cluster.close()
PYEOF
```
```bash
python -m py_compile dataset/generate_bookings.py
```
```bash
MSYS_NO_PATHCONV=1 kubectl cp \
  dataset/generate_bookings.py \
  "${CB_NAMESPACE}/cb-index-client:/tmp/generate_bookings.py"
```
```bash
MSYS_NO_PATHCONV=1 kubectl exec \
  -n "$CB_NAMESPACE" \
  cb-index-client \
  -- \
  env \
    CB_HOST="couchbase://cb-cs400" \
    CB_USER="$CB_USER" \
    CB_PASS="$CB_PASS" \
    python /tmp/generate_bookings.py \
  | tee outputs/dataset-generation.txt
```


**Salida esperada:**

```text
Procesados=50,000/200,000 tiempo=<variable>s
...
Documentos procesados: 200,000
```

### Tarea 2.4. Crear índice primario baseline

- {% include step_label.html %} Crea el índice primario del baseline, espera su estado `online` y valida que `booking_lab4` contenga exactamente 200 000 documentos.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE PRIMARY INDEX IF NOT EXISTS idx_booking_lab4_primary ON `travel-sample`.inventory.booking_lab4;' \
  | jq '{status,errors}'
```


**Salida esperada:**

```text
{"status":"success","errors":null}
idx_booking_lab4_primary: online
```

### Tarea 2.5. Crear consultas Q1–Q5

- {% include step_label.html %} Guarda las cinco consultas del workload en archivos SQL++ separados para reutilizar exactamente las mismas sentencias en todas las comparaciones.

```bash
cat > dataset/q1.sqlpp << 'EOF'
SELECT bookingId, flightId, status, departureDate
FROM `travel-sample`.inventory.booking_lab4
WHERE customerId = "cust_12345";
EOF
cat > dataset/q2.sqlpp << 'EOF'
SELECT bookingId, customerId, price, cabin
FROM `travel-sample`.inventory.booking_lab4
WHERE origin = "JFK" AND destination = "LHR"
  AND departureDate >= "2026-06-01" AND departureDate <= "2026-06-30";
EOF
cat > dataset/q3.sqlpp << 'EOF'
SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample`.inventory.booking_lab4
WHERE status = "pending" AND price BETWEEN 500 AND 2000;
EOF
cat > dataset/q4.sqlpp << 'EOF'
SELECT bookingId, status, departureDate, price
FROM `travel-sample`.inventory.booking_lab4
WHERE customerId = "cust_09999"
ORDER BY departureDate DESC;
EOF
cat > dataset/q5.sqlpp << 'EOF'
SELECT origin, COUNT(*) AS total
FROM `travel-sample`.inventory.booking_lab4
WHERE status = "confirmed"
GROUP BY origin;
EOF
```


**Salida esperada:**

```text
Se crean `dataset/q1.sqlpp` ... `dataset/q5.sqlpp` sin salida de error.
```

### Tarea 2.6. Crear script de captura

- {% include step_label.html %} Crea un script que capture `EXPLAIN` y métricas, valide la respuesta de Query Service y detenga la ejecución cuando Couchbase reporte errores.

```bash
cat > scripts/capture-query.sh << 'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${ROOT_DIR}/lab.env"

Q="${1:?Uso: capture-query.sh q1..q5 tag}"
TAG="${2:?Uso: capture-query.sh q1..q5 tag}"
SQL_FILE="${ROOT_DIR}/dataset/${Q}.sqlpp"

[[ -f "$SQL_FILE" ]] || {
  echo "ERROR: no existe $SQL_FILE" >&2
  exit 1
}

SQL="$(tr '\n' ' ' < "$SQL_FILE")"
PLAN_FILE="${ROOT_DIR}/plans/${Q}_${TAG}.json"
BENCH_FILE="${ROOT_DIR}/benchmarks/${Q}_${TAG}.json"

EXPLAIN_RESPONSE=$(curl -fsS -u "${CB_USER}:${CB_PASS}" \
  -X POST http://localhost:8093/query/service \
  --data-urlencode "statement=EXPLAIN ${SQL}")

echo "$EXPLAIN_RESPONSE" | jq -e '.status == "success"' >/dev/null || {
  echo "$EXPLAIN_RESPONSE" | jq .
  exit 1
}

echo "$EXPLAIN_RESPONSE" | jq '.results[0]' > "$PLAN_FILE"

QUERY_RESPONSE=$(curl -fsS -u "${CB_USER}:${CB_PASS}" \
  -X POST http://localhost:8093/query/service \
  --data-urlencode 'scan_consistency=request_plus' \
  --data-urlencode "statement=${SQL}")

echo "$QUERY_RESPONSE" | jq -e '.status == "success"' >/dev/null || {
  echo "$QUERY_RESPONSE" | jq .
  exit 1
}

echo "$QUERY_RESPONSE" \
  | jq '{status,elapsedTime:.metrics.elapsedTime,executionTime:.metrics.executionTime,resultCount:.metrics.resultCount,errors}' \
  > "$BENCH_FILE"

cat "$BENCH_FILE"
EOF
chmod +x scripts/capture-query.sh
bash -n scripts/capture-query.sh
for q in q1 q2 q3 q4 q5; do
  ./scripts/capture-query.sh "$q" baseline
done
```


**Salida esperada:**

```text
Cada consulta imprime JSON con `"status": "success"` y crea un plan en `plans/` y un benchmark en `benchmarks/`.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🧩 Tarea 3. Diseñar índices de clave simple y compuestos — 12 min
En esta tarea convertirás predicados de igualdad y rango en índices secundarios concretos y observarás cómo cambian spans, cardinalidad y acceso en EXPLAIN.


### Tarea 3.1. Índice de una key para Q1

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_customer IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(customerId);' | jq '{status,errors}'
./scripts/capture-query.sh q1 customer_index
grep -n "idx_booking_customer" plans/q1_customer_index.json
```

### Tarea 3.2. Índice compuesto para Q2

- {% include step_label.html %} Crea un índice compuesto siguiendo predicados de igualdad y rango para observar spans sobre ruta y fecha en el plan optimizado de Q2.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_route_date IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(origin,destination,departureDate);' | jq '{status,errors}'
./scripts/capture-query.sh q2 route_date_index
jq '..|objects|select(has("spans"))|{operator:."#operator",index,spans}' plans/q2_route_date_index.json
```


**Salida esperada:**

```text
{"status":"success","errors":null}
# jq muestra un operador IndexScan con spans para ruta y rango de fecha
```

### Tarea 3.3. Índice compuesto para Q3

- {% include step_label.html %} Crea un índice compuesto sobre `status` y `price` para soportar primero la igualdad y después el rango numérico definido por la consulta Q3.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_status_price IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(status,price);' | jq '{status,errors}'
./scripts/capture-query.sh q3 status_price_index
```


**Salida esperada:**

```text
{"status":"success","errors":null}
# benchmark q3_status_price_index.json con status success
```

### Tarea 3.4. Comparar cardinalidad estimada

- {% include step_label.html %} Extrae operadores y cardinalidades estimadas de varios planes para comparar cómo cambia el trabajo previsto por el optimizador después de indexar.

```bash
for file in \
  plans/q1_baseline.json \
  plans/q1_customer_index.json \
  plans/q2_route_date_index.json \
  plans/q3_status_price_index.json
do
  echo "=== $file ==="

  jq '
    .. 
    | objects
    | select(
        has("#operator")
        and has("~cardinality")
      )
    | {
        operator: .["#operator"],
        index: (.index // null),
        cardinality: .["~cardinality"]
      }
  ' "$file"
done
```

**Salida esperada:**

```text
Bloques JSON por archivo con `operator`, `index` cuando aplique y `cardinality` estimada.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## ✂️ Tarea 4. Comparar índice completo y partial index — 8 min
En esta tarea compararás dos índices con claves equivalentes, pero distinta población, para comprobar cómo un predicado parcial reduce entradas mantenidas por GSI.


La collection contiene únicamente reservas, por lo que `WHERE type="booking"` no reduciría entradas. Se utilizará `status="cancelled"` para demostrar una reducción real.

### Tarea 4.1. Crear índices comparables

- {% include step_label.html %} Crea un índice completo y otro parcial con las mismas claves para comparar el efecto real de limitar las entradas a documentos cancelados.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_all_created_customer IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(createdAt,customerId);' | jq '{status,errors}'
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_cancelled_created_customer IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(createdAt,customerId) WHERE status="cancelled";' | jq '{status,errors}'
```


**Salida esperada:**

```text
Dos respuestas con `"status":"success"` y sin `errors`.
```

### Tarea 4.2. Verificar metadata

- {% include step_label.html %} Consulta `system:indexes` y confirma que ambos índices estén definidos, mientras el índice parcial muestra la condición asociada.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT i.name,
           i.state,
           i.index_key,
           i.`condition` AS index_condition
    FROM system:indexes AS i
    WHERE i.name IN [
      "idx_all_created_customer",
      "idx_cancelled_created_customer"
    ]
    ORDER BY i.name;' \
  | jq '{status,results,errors}'
```


**Salida esperada:**

```text
Dos objetos `online`; el parcial contiene una condición equivalente a `status = "cancelled"`.
```

### Tarea 4.3. Abrir REST 9102 del Index Service

- {% include step_label.html %} Identifica el Pod Index desde la topología de Couchbase —sin asumir nombres de Pod— y reenvía localmente el puerto REST 9102 del Index Service.

```bash
INDEX_POD=$(curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
  | jq -r '.nodes[] | select(.services | index("index")) | .hostname' \
  | head -n1 | cut -d. -f1)

[[ -n "$INDEX_POD" ]] || {
  echo "ERROR: no se pudo identificar un Pod con Index Service." >&2
  exit 1
}

echo "Index Pod seleccionado: $INDEX_POD"
```

En otra terminal:

```bash
kubectl port-forward -n couchbase "pod/${INDEX_POD}" 9102:9102
```


**Salida esperada:**

```text
Index Pod seleccionado: cb-cs400-000X
Forwarding from 127.0.0.1:9102 -> 9102
```

### Tarea 4.4. Comparar estadísticas y distribución lógica

- {% include step_label.html %} Obtén estadísticas REST de `booking_lab4` y compáralas con el conteo por estado para interpretar el tamaño relativo del índice parcial.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" \
  "http://localhost:9102/api/v1/stats/travel-sample.inventory.booking_lab4?pretty=true&skipEmpty=true" \
  | jq 'to_entries
        | map(select(.key | test("idx_all_created_customer|idx_cancelled_created_customer")))
        | from_entries' \
  | tee stats/partial-index-comparison.json
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT status,COUNT(*) AS total FROM `travel-sample`.inventory.booking_lab4 GROUP BY status ORDER BY status;' | jq '.results'
```


**Salida esperada:**

```text
`stats/partial-index-comparison.json` contiene estadísticas de ambos índices; el GROUP BY devuelve confirmed, pending y cancelled.
```

### Tarea 4.5. Validar que el predicado habilita el partial index

- {% include step_label.html %} Ejecuta `EXPLAIN` con el predicado `status="cancelled"` y comprueba que el optimizador pueda seleccionar el índice parcial.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=EXPLAIN SELECT bookingId,customerId,createdAt FROM `travel-sample`.inventory.booking_lab4 WHERE status="cancelled" AND createdAt < "2026-07-01";' \
  | jq '.results[0]' | tee plans/partial_cancelled.json

grep -n "idx_cancelled_created_customer" plans/partial_cancelled.json
```


**Salida esperada:**

```text
`grep` encuentra `idx_cancelled_created_customer` dentro de `plans/partial_cancelled.json`.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 📚 Tarea 5. Diseñar covering indexes — 10 min
En esta tarea incluirás campos de filtro, orden y proyección dentro de GSI para comprobar cuándo Query Service puede resolver la consulta sin recuperar documentos.


### Tarea 5.1. Capturar Q4 antes del covering index

- {% include step_label.html %} Captura el plan de Q4 antes del covering index y registra sus operadores para disponer de una comparación directa con la versión cubierta.

```bash
./scripts/capture-query.sh q4 before_covering
jq -r '..|objects|."#operator"? // empty' plans/q4_before_covering.json | sort | uniq -c
```


**Salida esperada:**

```text
Lista de operadores del plan previo; normalmente puede incluir un `Fetch` antes de cubrir la consulta.
```

### Tarea 5.2. Crear covering index para Q4

- {% include step_label.html %} Incluye filtros, orden y proyección de Q4 dentro del índice y verifica que el plan resultante no requiera un operador `Fetch`.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_customer_covering IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(customerId,departureDate DESC,bookingId,status,price);' | jq '{status,errors}'
./scripts/capture-query.sh q4 covering
grep -n "idx_booking_customer_covering" plans/q4_covering.json
```
```bash
FETCH_COUNT=$(jq -r '..|objects|."#operator"? // empty' plans/q4_covering.json | grep -c '^Fetch$' || true)
echo "Fetch operators: $FETCH_COUNT"
```


**Salida esperada:**

```text
El plan contiene `idx_booking_customer_covering` y `Fetch operators: 0`.
```

### Tarea 5.3. Crear covering index para Q2

- {% include step_label.html %} Amplía el índice de ruta y fecha con los campos proyectados por Q2 para comprobar la presencia de `covers` en el plan de ejecución.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_route_covering IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(origin,destination,departureDate,bookingId,customerId,price,cabin);' | jq '{status,errors}'
./scripts/capture-query.sh q2 covering
jq '..|objects|select(has("covers"))|{operator:."#operator",index,covers}' plans/q2_covering.json
```

> **NOTA:** Un covering index puede evitar lecturas al Data Service, pero aumenta tamaño y mantenimiento; úsalo cuando frecuencia y latencia lo justifiquen.
{: .lab-note .info .compact}


**Salida esperada:**

```text
`jq` muestra un operador de índice con la propiedad `covers` y los campos requeridos por Q2.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🧮 Tarea 6. Comparar índice no particionado y particionado — 10 min
En esta tarea crearás dos índices lógicamente equivalentes y utilizarás particionamiento hash para observar placement distribuido y comparar su comportamiento.


### Tarea 6.1. Crear índices equivalentes

- {% include step_label.html %} Crea una versión normal y una versión particionada del mismo índice para comparar distribución sin cambiar las claves lógicas de búsqueda.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_origin_status IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(origin,status);' | jq '{status,errors}'
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_origin_status_partitioned IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(origin,status) PARTITION BY HASH(origin) WITH {"num_partition":8};' | jq '{status,errors}'
```


**Salida esperada:**

```text
Dos respuestas con `"status":"success"`; ambos índices terminan `online` tras su construcción.
```

### Tarea 6.2. Consultar metadata de partición

- {% include step_label.html %} Consulta el catálogo del sistema para confirmar que sólo la segunda definición contiene expresión de partición y placement distribuido.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT i.name,
           i.state,
           i.index_key,
           i.`partition` AS partition_definition,
           i.nodes
    FROM system:indexes AS i
    WHERE i.name = "idx_booking_origin_status"
       OR i.name = "idx_booking_origin_status_partitioned"
    ORDER BY i.name;' \
  | jq '{status,results,errors}'
```


**Salida esperada:**

```text
El índice normal no presenta partición HASH; el particionado muestra `HASH(origin)` y nodos de placement.
```

### Tarea 6.3. Comparar Q5

- {% include step_label.html %} Fuerza cada índice con `USE INDEX` y captura plan y métricas por separado para comparar ambos diseños sin generalizar diferencias pequeñas.

```bash
cat > dataset/q5_nonpartitioned.sqlpp << 'EOF'
SELECT origin, COUNT(*) AS total
FROM `travel-sample`.inventory.booking_lab4
USE INDEX (idx_booking_origin_status USING GSI)
WHERE status="confirmed"
GROUP BY origin;
EOF
cat > dataset/q5_partitioned.sqlpp << 'EOF'
SELECT origin, COUNT(*) AS total
FROM `travel-sample`.inventory.booking_lab4
USE INDEX (idx_booking_origin_status_partitioned USING GSI)
WHERE status="confirmed"
GROUP BY origin;
EOF
for mode in nonpartitioned partitioned; do
  SQL=$(tr '\n' ' ' < dataset/q5_${mode}.sqlpp)
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode "statement=EXPLAIN ${SQL}" | jq '.results[0]' > plans/q5_${mode}.json
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode "statement=${SQL}" | jq '{status,elapsedTime:.metrics.elapsedTime,executionTime:.metrics.executionTime,resultCount:.metrics.resultCount}' > benchmarks/q5_${mode}.json
done
cat benchmarks/q5_nonpartitioned.json
cat benchmarks/q5_partitioned.json
```

> **IMPORTANTE:** Con 200 000 documentos no esperes una ventaja fija de latencia; la comparación busca observar distribución y escalabilidad horizontal del índice.
{: .lab-note .important .compact}


**Salida esperada:**

```text
Se crean `q5_nonpartitioned.json` y `q5_partitioned.json` con `status: success`; los tiempos son dependientes del entorno.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 🛡️ Tarea 7. Crear réplica y simular pérdida temporal de un Pod Index — 14 min
En esta tarea crearás una réplica GSI, registrarás su placement y retirarás temporalmente un Pod Index para observar continuidad y recuperación del servicio.


### Tarea 7.1. Crear índice HA con num_replica=1

- {% include step_label.html %} Crea un covering index con una réplica automática; con dos nodos Index, Couchbase puede colocar original y réplica en miembros diferentes.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_customer_ha IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(customerId,departureDate DESC,bookingId,status,price) WITH {"num_replica":1};' | jq '{status,errors}'
```


**Salida esperada:**

```text
{"status":"success","errors":null}
```

### Tarea 7.2. Consultar replicaId y placement

- {% include step_label.html %} Registra `replicaId`, estado y nodos para demostrar que existen dos copias utilizables antes de provocar la pérdida temporal de un Pod Index.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT name,state,replicaId,nodes,index_key FROM system:indexes WHERE name="idx_booking_customer_ha" ORDER BY replicaId;' \
  | jq '.results' | tee stats/index-replica-placement.json
```


**Salida esperada:**

```text
Dos filas para `idx_booking_customer_ha`, con replicaId distintos y placement en nodos Index.
```

### Tarea 7.3. Eliminar índices redundantes de cliente

- {% include step_label.html %} Retira índices equivalentes de `customerId` para reducir ambigüedad y favorecer que Q4 utilice el índice HA durante la prueba de continuidad.

```bash
for idx in \
  idx_booking_customer \
  idx_booking_customer_covering
do
  curl -sS -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=DROP INDEX IF EXISTS ${idx} ON \`travel-sample\`.inventory.booking_lab4;" \
    | jq '{status,errors}'
done
```

**Salida esperada:**

```text
Cada DROP devuelve `"status":"success"`; si ya no existe, `IF EXISTS` evita el error.
```

### Tarea 7.4. Verificar Q4 antes de la pérdida

- {% include step_label.html %} Captura una ejecución saludable de Q4 antes de la falla y confirma que el plan referencia el índice HA que dispone de original y réplica.

```bash
./scripts/capture-query.sh q4 ha_before_failure
grep -n "idx_booking_customer_ha" plans/q4_ha_before_failure.json
```

**Salida esperada:**

```text
El benchmark queda en `status: success` y el plan contiene `idx_booking_customer_ha`.
```

### Tarea 7.5. Identificar y eliminar un Pod Index

- {% include step_label.html %} Obtén los Pods Index desde la API de Couchbase y solicita la eliminación asíncrona de uno para permitir que el Operator inicie su recreación.

```bash
INDEX_PODS=$(curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
  | jq -r '.nodes[] | select(.services | index("index")) | .hostname' \
  | cut -d. -f1)

printf '%s\n' "$INDEX_PODS"
FAILED_INDEX_POD=$(printf '%s\n' "$INDEX_PODS" | head -n1)

[[ -n "$FAILED_INDEX_POD" ]] || {
  echo "ERROR: no se pudo seleccionar un Pod Index." >&2
  exit 1
}
echo "Pod Index a recrear: $FAILED_INDEX_POD"
```
```bash
kubectl delete pod -n "$CB_NAMESPACE" "$FAILED_INDEX_POD" --wait=false
```


**Salida esperada:**

```text
Se muestran dos nombres de Pod Index y Kubernetes confirma `pod/<nombre> deleted` o inicia su terminación asíncrona.
```

### Tarea 7.6. Ejecutar consultas durante la recuperación

- {% include step_label.html %} Ejecuta Q4 diez veces mientras un Pod Index se recupera y conserva cada respuesta para comprobar si la réplica mantiene el servicio.

```bash
for i in $(seq 1 10); do
  SQL=$(tr '\n' ' ' < dataset/q4.sqlpp)
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${SQL}" | jq '{status,elapsedTime:.metrics.elapsedTime,executionTime:.metrics.executionTime,resultCount:.metrics.resultCount,errors}'
  sleep 1
done | tee outputs/q4-during-index-recovery.txt
```


**Salida esperada:**

```text
Diez objetos JSON. El criterio esperado es `status: success` durante la ventana cubierta por la réplica.
```

### Tarea 7.7. Observar recuperación automática

- {% include step_label.html %} Sigue el Pod eliminado hasta que vuelva a `Running` y `ready=true`, identificándolo por servicio Couchbase y no por una suposición sobre su nombre.

```bash
for i in $(seq 1 60); do
  echo "=== $(date +%H:%M:%S) ==="
  kubectl get pod -n "$CB_NAMESPACE" "$FAILED_INDEX_POD" \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase,NODE:.spec.nodeName' \
    2>/dev/null || true

  READY=$(kubectl get pod -n "$CB_NAMESPACE" "$FAILED_INDEX_POD" \
    -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || true)

  [[ "$READY" == "true" ]] && break
  sleep 5
done
```


**Salida esperada:**

```text
El Pod seleccionado vuelve a `PHASE Running` con `READY true`.
```

### Tarea 7.8. Confirmar original y réplica online

- {% include step_label.html %} Espera hasta que `system:indexes` vuelva a mostrar dos copias `online` antes de considerar finalizada la recuperación del Index Service.

```bash
for i in $(seq 1 60); do
  RESPONSE=$(curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT name,state,replicaId,nodes FROM system:indexes WHERE name="idx_booking_customer_ha" ORDER BY replicaId;')

  echo "$RESPONSE" | jq '.results'
  ONLINE=$(echo "$RESPONSE" | jq '[.results[] | select(.state=="online")] | length')

  [[ "$ONLINE" -ge 2 ]] && break
  sleep 5
done
```

> **NOTA:** La prueba observa continuidad mediante réplica y recreación automática del Pod; no representa un hard failover administrativo de Couchbase Server.
{: .lab-note .info .compact}


**Salida esperada:**

```text
Dos entradas `idx_booking_customer_ha` con `"state":"online"`.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🏗️ Tarea 8. Utilizar deferred build — 10 min
En esta tarea registrarás varias definiciones sin construirlas de inmediato y utilizarás BUILD INDEX para coordinar su construcción sobre la misma collection.


### Tarea 8.1. Crear tres índices deferred

- {% include step_label.html %} Registra tres definiciones con `defer_build=true` para evitar iniciar tres construcciones independientes sobre la misma collection.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=CREATE INDEX idx_booking_cabin_price IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(cabin,price,bookingId) WITH {"defer_build":true};' | jq '{status,errors}'
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=CREATE INDEX idx_booking_flight IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(flightId,departureDate,status) WITH {"defer_build":true};' | jq '{status,errors}'
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=CREATE INDEX idx_booking_date_origin IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(departureDate,origin,destination,price) WITH {"defer_build":true};' | jq '{status,errors}'
```


**Salida esperada:**

```text
Tres respuestas con `"status":"success"` y sin errores.
```

### Tarea 8.2. Confirmar deferred

- {% include step_label.html %} Consulta el estado de las tres definiciones y verifica que permanezcan en `deferred` antes de lanzar el build coordinado.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT i.name,
           i.state
    FROM system:indexes AS i
    WHERE i.name IN [
      "idx_booking_cabin_price",
      "idx_booking_flight",
      "idx_booking_date_origin"
    ]
    ORDER BY i.name;' \
  | jq '{status,results,errors}'
```

**Salida esperada:**

```text
Tres objetos con `"state":"deferred"`.
```

### Tarea 8.3. Construir conjuntamente

- {% include step_label.html %} Inicia un único `BUILD INDEX` para las tres definiciones, permitiendo que Couchbase coordine la construcción sobre el mismo keyspace.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=BUILD INDEX ON `travel-sample`.inventory.booking_lab4(idx_booking_cabin_price,idx_booking_flight,idx_booking_date_origin);' | jq '{status,errors}'
```


**Salida esperada:**

```text
{"status":"success","errors":null}
```

### Tarea 8.4. Monitorear deferred → building → online

- {% include step_label.html %} Muestrea `system:indexes` hasta que los tres índices estén `online`; `building` puede durar poco y no necesariamente aparecer en cada observación.

```bash
for i in $(seq 1 60); do

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8093/query/service \
      --data-urlencode 'statement=
        SELECT i.name,
               i.state
        FROM system:indexes AS i
        WHERE i.name = "idx_booking_cabin_price"
           OR i.name = "idx_booking_flight"
           OR i.name = "idx_booking_date_origin"
        ORDER BY i.name;'
  )

  STATUS=$(echo "$RESPONSE" | jq -r '.status // "unknown"')

  if [[ "$STATUS" != "success" ]]; then
    echo "ERROR: Query Service devolvió:"
    echo "$RESPONSE" | jq '{status,errors}'
    break
  fi

  echo "=== intento $i ==="
  echo "$RESPONSE" | jq '.results'

  ONLINE=$(
    echo "$RESPONSE" \
    | jq '[.results[] | select(.state == "online")] | length'
  )

  echo "Índices online: $ONLINE/3"

  [[ "$ONLINE" -eq 3 ]] && break

  sleep 5
done
```


**Salida esperada:**

```text
Los estados evolucionan hasta que los tres objetos reportan `"state":"online"`.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## ♻️ Tarea 9. Reconstruir operativamente un índice — 5 min
En esta tarea reconstruirás un índice mediante operaciones SQL++ soportadas y verificarás que vuelva a estar disponible para el optimizador después del build.


### Tarea 9.1. Eliminar y recrear idx_booking_flight

- {% include step_label.html %} Reconstruye el índice con operaciones soportadas: `DROP INDEX`, `CREATE INDEX` deferred y `BUILD INDEX`, sin manipular archivos internos.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DROP INDEX IF EXISTS idx_booking_flight ON `travel-sample`.inventory.booking_lab4;' | jq '{status,errors}'
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE INDEX idx_booking_flight IF NOT EXISTS ON `travel-sample`.inventory.booking_lab4(flightId,departureDate,status) WITH {"defer_build":true};' | jq '{status,errors}'
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=BUILD INDEX ON `travel-sample`.inventory.booking_lab4(idx_booking_flight);' | jq '{status,errors}'
```


**Salida esperada:**

```text
DROP, CREATE y BUILD responden con `"status":"success"` y sin errores.
```

### Tarea 9.2. Esperar online y validar consulta

- {% include step_label.html %} Espera el estado `online` y utiliza `EXPLAIN` sobre `flightId` para verificar que el índice reconstruido vuelva a ser elegible.

```bash
for i in $(seq 1 30); do
  STATE=$(curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT RAW state FROM system:indexes WHERE name="idx_booking_flight" AND keyspace_id="booking_lab4" LIMIT 1;' | jq -r '.results[0] // "missing"')
  echo "idx_booking_flight: $STATE"
  [[ "$STATE" == "online" ]] && break
  sleep 5
done
```
```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=EXPLAIN SELECT bookingId,departureDate,status FROM `travel-sample`.inventory.booking_lab4 WHERE flightId="AA101" LIMIT 5;' \
  | jq '.results[0]' | tee plans/rebuilt-flight-index.json
```


**Salida esperada:**

```text
idx_booking_flight: online
# El plan reconstruido referencia idx_booking_flight.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Reporte, validación y limpieza — 5 min

En esta tarea consolidarás metadata y métricas, ejecutarás una validación final y retirarás únicamente los recursos experimentales creados durante el laboratorio.


### Tarea 10.1. Inventario final

- {% include step_label.html %} Exporta la metadata final de todos los índices de `booking_lab4`, incluyendo condición, partición, réplica y nodos, como evidencia del laboratorio.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT name,state,index_key,`condition`,`partition`,replicaId,nodes FROM system:indexes WHERE keyspace_id="booking_lab4" ORDER BY name,replicaId;' \
  | jq '.results' | tee outputs/final-index-inventory.json
```


**Salida esperada:**

```text
Arreglo JSON con los índices de `booking_lab4`, sus estados y metadata de condición, partición, réplica y nodos.
```

### Tarea 10.2. Crear validate.sh

- {% include step_label.html %} Genera y ejecuta una validación integral que comprueba topología, volumen de datos, estado de índices, réplica HA y evidencia de recuperación.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab4/validate.sh
  ```

  ```bash
  chmod +x scripts/validate.sh
  ./scripts/validate.sh
  ```

**Salida esperada:**

```text
✅ PASS: 2 nodos Index
✅ PASS: 200 000 documentos
...
RESULTADO: <PASS> PASS / 0 FAIL
```

### Tarea 10.3. Eliminar collection experimental

- {% include step_label.html %} Elimina únicamente `booking_lab4` y el Pod cliente, conservando localmente planes, benchmarks, estadísticas y reportes producidos durante la práctica.

```bash
curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.booking_lab4 IF EXISTS;' | jq '{status,errors}'
```
```bash
kubectl delete pod cb-index-client -n couchbase --ignore-not-found
find plans stats benchmarks outputs -maxdepth 1 -type f | sort
```

**Salida esperada:**

```text
{"status":"success","errors":null}
pod "cb-index-client" deleted
# Se listan las evidencias locales conservadas.
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}

{% include support-prompt.html task="tarea10" %}

---

## 🧹 Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` las terminales que mantienen los port-forward de 8091, 8093 y 9102 para liberar los puertos locales antes de eliminar recursos.

**Salida esperada:**

```text
Forwarding session terminated.
```

- {% include step_label.html %} Elimina el clúster EKS con el mismo script de ciclo de vida para retirar el control plane, node group y recursos administrados asociados.

```bash
cd /c/LABS/couchbase-nosql/lab4
source lab.env
./scripts/eks-cluster.sh delete
```

**Salida esperada:**

```text
# eksctl muestra el progreso de eliminación y finaliza sin ERROR.
```

- {% include step_label.html %} Consulta la API de Amazon EKS con el nombre del clúster y confirma `ResourceNotFoundException` para demostrar que la eliminación terminó.

```bash
aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION"
```

**Salida esperada:** `ResourceNotFoundException`.