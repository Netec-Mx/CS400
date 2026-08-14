---
layout: lab
title: "Práctica 5: Implementación de búsqueda, automatización y análisis integrado"
permalink: /lab5/lab5/
images_base: /labs/lab5/img
duration: "78 minutos"
objective:
  - Validar Search, Eventing y Analytics como servicios especializados dentro de Couchbase Server Enterprise 7.6.2 sobre Amazon EKS.
  - Crear un índice Full-Text Search sobre una collection bilingüe controlada con mappings estáticos, analyzers en inglés y español, fuzzy, boolean y geo.
  - Implementar una función Eventing scoped que reaccione a mutaciones, valide datos, calcule campos derivados y escriba resultados en una collection destino.
  - Diferenciar los límites DCP From Now y Everything y correlacionar estado, estadísticas y application logs de una función Eventing.
  - Habilitar Analytics sobre collections concretas y ejecutar consultas OLAP con window functions sobre su copia analítica.
  - Comparar Query Service y Analytics Service utilizando métricas reales sin asumir que uno es siempre más rápido.
  - Conservar definiciones, consultas, resultados y reportes localmente y eliminar únicamente los recursos experimentales del laboratorio.
prerequisites:
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl y jq disponibles desde Git Bash.
  - Comprender SQL++, collections, scopes, DCP y la diferencia conceptual entre cargas operacionales y analíticas.
  - Conocer JavaScript básico para interpretar la función Eventing.
introduction:
  - En esta práctica integrarás Search, Eventing y Analytics en un flujo coherente sin convertir Amazon EKS en el objetivo académico. Search utilizará una collection bilingüe controlada para demostrar analyzers ingleses y españoles de forma reproducible. Eventing procesará reservas almacenadas en un bucket experimental con source, destination y metadata collections separadas. Analytics mantendrá shadow copies de collections seleccionadas y ejecutará consultas con window functions sobre su propio almacenamiento analítico.
slug: lab5
lab_number: 5
final_result: >
  Al finalizar la práctica habrás creado y consultado un índice FTS multilingüe con filtros booleanos, fuzzy search y proximidad geográfica; desplegado una función Eventing scoped que enriquece reservas y elimina su representación derivada ante OnDelete; demostrado la diferencia entre From Now y Everything; habilitado Analytics sobre collections específicas y ejecutado window functions; comparado Query y Analytics mediante métricas reales; y eliminado de forma segura los recursos temporales preservando travel-sample.
notes:
  - Los 78 minutos corresponden únicamente a las tareas funcionales de Couchbase. La creación y eliminación de Amazon EKS están incluidas pero quedan fuera de ese tiempo.
  - Todos los comandos deben ejecutarse desde Git Bash dentro de Visual Studio Code.
  - La práctica utiliza Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - La topología utiliza dos Pods Data + Query, un Pod Index, un Pod Search, un Pod Eventing y un Pod Analytics.
  - La práctica utiliza cuatro workers m6i.xlarge para evitar que la presión de Kubernetes distorsione el comportamiento de Search, Eventing o Analytics.
  - Los valores exactos de latencia, score, docCount y tiempo de ingestión varían según el entorno y no se validan con cifras rígidas.
  - travel-sample permanece intacto; los recursos experimentales se crean en collections y buckets dedicados.
references:
  - text: Instalación de AWS CLI
    url: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - text: Instalación oficial de eksctl
    url: https://eksctl.io/installation/
  - text: Instalación de kubectl en Windows
    url: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
  - text: Instalación de Helm
    url: https://helm.sh/docs/intro/install/
  - text: Couchbase Kubernetes Operator 2.9
    url: https://docs.couchbase.com/operator/current/release-notes.html
  - text: Search Service en Couchbase Server
    url: https://docs.couchbase.com/server/current/search/search.html
  - text: Crear Search index con REST API
    url: https://docs.couchbase.com/server/current/search/create-search-index-rest-api.html
  - text: Ejecutar Search con REST API
    url: https://docs.couchbase.com/server/current/search/simple-search-rest-api.html
  - text: Eventing REST API
    url: https://docs.couchbase.com/server/current/eventing-rest-api/index.html
  - text: Analytics SQL++ DDL
    url: https://docs.couchbase.com/server/current/analytics/5_ddl.html
  - text: Analytics REST API
    url: https://docs.couchbase.com/server/current/analytics/rest-analytics.html
prev: /lab4/lab4/
next: /lab6/lab6/
---

---
<!-- Aquí comienzan las instrucciones paso a paso de la práctica -->

> **IMPORTANTE:** Ejecuta todos los bloques `bash` desde Git Bash en Visual Studio Code; PowerShell y CMD interpretan heredoc, comillas y rutas de forma distinta.
{: .lab-note .important .compact}


## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre Visual Studio Code sobre `C:\LABS\couchbase-nosql` para conservar la raíz de trabajo y mantener separados los archivos del laboratorio 5.

**Salida esperada:** VS Code debe mostrar `C:\LABS\couchbase-nosql` como raíz del workspace y permitir visualizar los laboratorios anteriores junto al nuevo directorio.

- {% include step_label.html %} Abre una terminal Git Bash y crea la estructura de `lab5` para separar scripts, manifiestos, Search, Eventing, Analytics, métricas y evidencias.

```bash
mkdir -p /c/LABS/couchbase-nosql/lab5/{scripts,manifests,search,eventing,analytics,metrics,outputs}
cd /c/LABS/couchbase-nosql/lab5
pwd
find . -maxdepth 1 -type d | sort
```

**Salida esperada:** `pwd` debe mostrar la ruta de `lab5`; `find` debe listar `analytics`, `eventing`, `manifests`, `metrics`, `outputs`, `scripts` y `search`.

---

## 🧰 Herramientas y enlaces oficiales

| Herramienta | Uso en la práctica | Enlace |
|---|---|---|
| AWS CLI v2 | Identidad, kubeconfig y validación de EKS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| eksctl | Crear, consultar y eliminar Amazon EKS | https://eksctl.io/installation/ |
| kubectl | Administrar Pods, PVC y port-forward | https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/ |
| Helm 3 | Instalar Couchbase Kubernetes Operator | https://helm.sh/docs/intro/install/ |
| jq | Construir y analizar JSON de Search, Eventing y APIs REST | https://jqlang.org/download/ |
| Git for Windows | Proporcionar Git Bash y utilidades GNU | https://git-scm.com/download/win |
| VS Code | Editar scripts, manifiestos y evidencias | https://code.visualstudio.com/download |

---

## ☁️ Preparación de infraestructura

## Crear variables comunes

- {% include step_label.html %} Crea `lab.env` para centralizar región, versiones, nombres y credenciales, y reutilizar valores coherentes durante toda la práctica.

```bash
cat > lab.env << 'ENVEOF'
export AWS_REGION="us-west-2"
export EKS_CLUSTER="cb-cs400-lab05"
export EKS_VERSION="1.35"
export EKS_NODEGROUP="cb-workers"
export CB_NAMESPACE="couchbase"
export CB_CLUSTER="cb-cs400"
export CB_USER="Administrator"
export CB_PASS="Password123!"
export CB_IMAGE="couchbase/server:enterprise-7.6.2"
export CB_OPERATOR_VERSION="2.92.0"
export EVENTING_BUCKET="lab5-eventing"
ENVEOF
```
```bash
source lab.env
```

**Salida esperada:** `source lab.env` debe completar sin errores; las variables `AWS_REGION`, `EKS_CLUSTER`, `CB_CLUSTER` y `CB_OPERATOR_VERSION` quedan disponibles.

## Crear el script de ciclo de vida EKS

- {% include step_label.html %} Crea `scripts/eks-cluster.sh` para administrar EKS de forma reproducible con cuatro workers `m6i.xlarge`, validando dependencias antes de cada acción.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab5/eks-cluster.sh
  ```

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe imprimir errores y la acción `create` debe finalizar con cuatro workers EKS en estado `Ready`, mostrando tipo y zona.

## Crear almacenamiento e instalar Operator

- {% include step_label.html %} Crea la StorageClass `gp3-couchbase` con EBS CSI y binding diferido para que cada volumen se aprovisione en la zona del Pod que lo consume.

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
```bash
kubectl apply -f manifests/storageclass-gp3.yaml
```

**Salida esperada:** `kubectl apply` debe crear o conservar `gp3-couchbase`; la StorageClass queda disponible con `WaitForFirstConsumer` y aprovisionador EBS CSI.

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 mediante Helm sin crear un clúster automático y espera hasta que el deployment quede disponible.

```bash
helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
helm repo update
```
```bash
helm upgrade --install cb-operator couchbase/couchbase-operator \
  --namespace couchbase --create-namespace \
  --version "$CB_OPERATOR_VERSION" \
  --set install.couchbaseCluster=false
```
```bash
kubectl wait -n couchbase --for=condition=Available deployment --all --timeout=5m
```

**Salida esperada:** Helm debe reportar la release `cb-operator` instalada o actualizada y `kubectl wait` debe confirmar que los deployments están disponibles.

## Crear CouchbaseCluster especializado

- {% include step_label.html %} Crea el secreto administrativo y despliega seis Pods con recursos explícitos para aislar Data, Query, Index, Search, Eventing y Analytics.

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
cat > manifests/couchbase-cluster.yaml << 'EOFCC'
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

  cluster:
    dataServiceMemoryQuota: 3Gi
    indexServiceMemoryQuota: 2Gi
    searchServiceMemoryQuota: 2Gi
    analyticsServiceMemoryQuota: 2Gi
    eventingServiceMemoryQuota: 1Gi
    indexer:
      storageMode: plasma

  servers:
    - name: data-query
      size: 2
      services: [data, query]
      resources:
        requests:
          cpu: "1000m"
          memory: "5Gi"
        limits:
          cpu: "2000m"
          memory: "6Gi"
      volumeMounts:
        default: couchbase-volume

    - name: index
      size: 1
      services: [index]
      resources:
        requests:
          cpu: "750m"
          memory: "3Gi"
        limits:
          cpu: "1500m"
          memory: "4Gi"
      volumeMounts:
        default: couchbase-volume

    - name: search
      size: 1
      services: [search]
      resources:
        requests:
          cpu: "1000m"
          memory: "4Gi"
        limits:
          cpu: "2000m"
          memory: "5Gi"
      volumeMounts:
        default: couchbase-volume

    - name: eventing
      size: 1
      services: [eventing]
      resources:
        requests:
          cpu: "750m"
          memory: "3Gi"
        limits:
          cpu: "1500m"
          memory: "4Gi"
      volumeMounts:
        default: couchbase-volume

    - name: analytics
      size: 1
      services: [analytics]
      resources:
        requests:
          cpu: "1000m"
          memory: "4Gi"
        limits:
          cpu: "2000m"
          memory: "5Gi"
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
EOFCC
```
```bash
kubectl apply -f manifests/couchbase-cluster.yaml
```
```bash
for i in $(seq 1 90); do
POD_COUNT=$(kubectl get pods -n "$CB_NAMESPACE" -l "couchbase_cluster=$CB_CLUSTER" --no-headers 2>/dev/null | wc -l | tr -d ' ')
[[ "$POD_COUNT" -ge 6 ]] && break
echo "Esperando creación de los 6 Pods Couchbase... intento $i/90"
sleep 10
done
```
```bash
kubectl wait -n "$CB_NAMESPACE" --for=condition=Ready pod -l "couchbase_cluster=$CB_CLUSTER" --timeout=15m
```
```bash
kubectl get pods -n "$CB_NAMESPACE" -l "couchbase_cluster=$CB_CLUSTER" -o wide
kubectl get pvc -n "$CB_NAMESPACE"
```

**Salida esperada:** El Operator debe terminar con seis Pods Couchbase `1/1 Running`; los PVC deben quedar `Bound` y ningún Pod debe permanecer `Pending`.

> **IMPORTANTE:** Mantén cuatro workers `m6i.xlarge`; los requests dejan margen para Kubernetes y evitan iniciar servicios especializados bajo presión.
{: .lab-note .important .compact}

- {% include step_label.html %} Verifica el consumo de los cuatro workers y de los Pods Couchbase antes de cargar datos, confirmando que la infraestructura conserve margen.

```bash
kubectl top nodes
kubectl top pods -n "$CB_NAMESPACE"
```

**Salida esperada:** Los cuatro workers deben mostrar métricas y ningún Pod Couchbase debe sostener un consumo cercano a su límite antes de cargar los datos.


## Cargar travel-sample y crear port-forward

- {% include step_label.html %} Abre una segunda terminal Git Bash y publica el puerto 8091 del servicio administrativo para usar Web Console y Management REST durante la práctica.

```bash
kubectl port-forward -n couchbase service/cb-cs400-ui 8091:8091
```

**Salida esperada:** La terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8091 -> 8091`; no cierres este proceso mientras se utilice REST administrativo.

- {% include step_label.html %} Comprueba si `travel-sample` ya existe e instálalo sólo cuando falte, evitando errores o cargas duplicadas al reutilizar infraestructura previa.

```bash
if ! curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default/buckets/travel-sample >/dev/null 2>&1; then
  curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8091/sampleBuckets/install -d '["travel-sample"]' | jq .
else
  echo "travel-sample ya existe."
fi
```

**Salida esperada:** Debe mostrarse `travel-sample ya existe.` o una respuesta válida de instalación; el bucket queda disponible para las tareas Search y Analytics.

- {% include step_label.html %} Identifica Query, Search, Eventing y Analytics a partir de los servicios anunciados por Couchbase, sin depender de nombres específicos de Pods.

```bash
TOPOLOGY=$(curl -sS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default)

QUERY_POD=$(echo "$TOPOLOGY" | jq -r '.nodes[] | select(.services | index("n1ql")) | .hostname' | head -n1 | cut -d. -f1)
SEARCH_POD=$(echo "$TOPOLOGY" | jq -r '.nodes[] | select(.services | index("fts")) | .hostname' | head -n1 | cut -d. -f1)
EVENTING_POD=$(echo "$TOPOLOGY" | jq -r '.nodes[] | select(.services | index("eventing")) | .hostname' | head -n1 | cut -d. -f1)
ANALYTICS_POD=$(echo "$TOPOLOGY" | jq -r '.nodes[] | select(.services | index("cbas")) | .hostname' | head -n1 | cut -d. -f1)

for value in "$QUERY_POD" "$SEARCH_POD" "$EVENTING_POD" "$ANALYTICS_POD"; do
  [[ -n "$value" ]] || {
    echo "ERROR: no fue posible identificar todos los Pods especializados." >&2
    exit 1
  }
done

printf 'QUERY=%s\nSEARCH=%s\nEVENTING=%s\nANALYTICS=%s\n' \
  "$QUERY_POD" "$SEARCH_POD" "$EVENTING_POD" "$ANALYTICS_POD"
```

**Salida esperada:** Las variables deben contener un Pod para cada servicio y mostrar valores similares a `cb-cs400-0000` sin depender de sufijos como `-search`.

- {% include step_label.html %} Abre cuatro terminales Git Bash y crea un túnel por servicio para mantener Query, Search, Analytics y Eventing accesibles durante las tareas.

**Terminal Query:**

```bash
kubectl port-forward -n "$CB_NAMESPACE" "pod/${QUERY_POD}" 8093:8093
```

**Terminal Search:**

```bash
kubectl port-forward -n "$CB_NAMESPACE" "pod/${SEARCH_POD}" 8094:8094
```

**Terminal Analytics:**

```bash
kubectl port-forward -n "$CB_NAMESPACE" "pod/${ANALYTICS_POD}" 8095:8095
```

**Terminal Eventing:**

```bash
kubectl port-forward -n "$CB_NAMESPACE" "pod/${EVENTING_POD}" 8096:8096
```

**Salida esperada:** Cada terminal debe permanecer mostrando `Forwarding from 127.0.0.1:<puerto> -> <puerto>`; conserva las cuatro sesiones abiertas durante la práctica.

---

## 🔎 Tarea 1. Validar servicios y preparar recursos — 6 min

En esta tarea confirmarás la topología MDS y los listeners especializados antes de crear datos, índices FTS, funciones Eventing o copias analíticas.

### Tarea 1.1. Confirmar Search, Eventing y Analytics

- {% include step_label.html %} Consulta `/pools/default` y confirma que los seis Pods reporten estado saludable y que cada servicio especializado esté presente antes de continuar.

```bash
source lab.env
curl -sS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
  | jq '[.nodes[] | {hostname,status,services}]'
```

**Salida esperada:** El arreglo JSON debe mostrar seis miembros `healthy`: dos con `kv`+`n1ql` y uno por cada servicio `index`, `fts`, `eventing` y `cbas`.

### Tarea 1.2. Validar listeners especializados

- {% include step_label.html %} Valida los listeners 8094, 8095 y 8096 mediante peticiones mínimas para comprobar que Search, Analytics y Eventing responden por sus túneles locales.

```bash
curl -sS -u "$CB_USER:$CB_PASS" http://localhost:8094/api/index | jq 'keys'
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode 'statement=SELECT VALUE "ANALYTICS_OK";' | jq '{status,results}'
curl -sS -u "$CB_USER:$CB_PASS" http://localhost:8096/api/v1/status | jq '.'
```

**Salida esperada:** Search debe responder con JSON, Analytics debe devolver `ANALYTICS_OK` y Eventing debe responder con información de estado sin errores HTTP.

### Tarea 1.3. Crear corpus bilingüe controlado

- {% include step_label.html %} Recrea `hotel_search_lab5` dentro de `travel-sample.inventory` para aislar el corpus bilingüe sin alterar las collections originales del sample.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.hotel_search_lab5 IF EXISTS;' | jq '{status,errors}'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=CREATE COLLECTION `travel-sample`.inventory.hotel_search_lab5 IF NOT EXISTS;' | jq '{status,errors}'
```

**Salida esperada:** Las operaciones DROP y CREATE deben devolver `status: success`; `hotel_search_lab5` queda disponible dentro de `travel-sample.inventory`.

- {% include step_label.html %} Inserta seis documentos bilingües con textos y coordenadas conocidas para obtener resultados reproducibles en búsquedas match, fuzzy, boolean y geo.

```bash
cat > search/load-search-docs.sqlpp << 'EOFSQL'
UPSERT INTO `travel-sample`.inventory.hotel_search_lab5 (KEY, VALUE) VALUES
("hotel_lab5_001", {"type":"hotel_search_lab5","name":"Thames Riverside Hotel","description_en":"Modern hotel with pool and easy access to the river and city center","description_es":"Hotel moderno con piscina y acceso sencillo al río y al centro","city":"London","country":"United Kingdom","geo":{"lat":51.5074,"lon":-0.1276}}),
("hotel_lab5_002", {"type":"hotel_search_lab5","name":"Brighton Beach Residence","description_en":"Beach hotel with sea views, indoor pool and family rooms","description_es":"Hotel de playa con vista al mar, piscina cubierta y habitaciones familiares","city":"Brighton","country":"United Kingdom","geo":{"lat":50.8225,"lon":-0.1372}}),
("hotel_lab5_003", {"type":"hotel_search_lab5","name":"Oxford Garden Inn","description_en":"Quiet garden hotel near historic buildings with a heated pool","description_es":"Hotel tranquilo con jardín cerca de edificios históricos y piscina climatizada","city":"Oxford","country":"United Kingdom","geo":{"lat":51.7520,"lon":-1.2577}}),
("hotel_lab5_004", {"type":"hotel_search_lab5","name":"Paris Central Stay","description_en":"Central hotel near museums with breakfast and rooftop terrace","description_es":"Hotel céntrico cerca de museos con desayuno y terraza panorámica","city":"Paris","country":"France","geo":{"lat":48.8566,"lon":2.3522}}),
("hotel_lab5_005", {"type":"hotel_search_lab5","name":"Barcelona Playa Suites","description_en":"Mediterranean beach suites with pool close to restaurants","description_es":"Suites mediterráneas junto a la playa con piscina cerca de restaurantes","city":"Barcelona","country":"Spain","geo":{"lat":41.3874,"lon":2.1686}}),
("hotel_lab5_006", {"type":"hotel_search_lab5","name":"Madrid Urban Hotel","description_en":"Urban hotel for business travelers with meeting rooms","description_es":"Hotel urbano para viajeros de negocios con salas de reuniones","city":"Madrid","country":"Spain","geo":{"lat":40.4168,"lon":-3.7038}});
EOFSQL
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode "statement@search/load-search-docs.sqlpp" | jq '{status,mutationCount:.metrics.mutationCount,errors}'
```

**Salida esperada:** La carga debe devolver `status: success` y `mutationCount` cercano a 6; una repetición debe sobrescribir las mismas claves sin aumentar el conjunto.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🔍 Tarea 2. Crear un índice FTS multilingüe — 10 min

En esta tarea construirás un índice Search scoped y estático para controlar analyzers, campos almacenados y geopoint sobre un corpus bilingüe reproducible.

### Tarea 2.1. Crear la definición estática

- {% include step_label.html %} Crea la definición JSON del índice FTS scoped con mappings estáticos, analyzers `en` y `es`, campos keyword y un campo geográfico `geopoint`.

```bash
cat > search/hotel-search-lab5.json << 'EOFFTS'
{
  "type":"fulltext-index",
  "name":"hotel-search-lab5",
  "sourceType":"gocbcore",
  "sourceName":"travel-sample",
  "planParams":{"indexPartitions":1,"numReplicas":0},
  "params":{
    "doc_config":{"mode":"scope.collection.type_field","type_field":"type"},
    "mapping":{
      "default_analyzer":"standard",
      "default_datetime_parser":"dateTimeOptional",
      "default_field":"_all",
      "default_mapping":{"dynamic":false,"enabled":false},
      "types":{
        "inventory.hotel_search_lab5.hotel_search_lab5":{
          "dynamic":false,"enabled":true,
          "properties":{
            "name":{"fields":[{"name":"name","type":"text","analyzer":"standard","index":true,"store":true}]},
            "description_en":{"fields":[{"name":"description_en","type":"text","analyzer":"en","index":true,"store":true}]},
            "description_es":{"fields":[{"name":"description_es","type":"text","analyzer":"es","index":true,"store":true}]},
            "city":{"fields":[{"name":"city","type":"text","analyzer":"keyword","index":true,"store":true}]},
            "country":{"fields":[{"name":"country","type":"text","analyzer":"keyword","index":true,"store":true}]},
            "geo":{"fields":[{"name":"geo","type":"geopoint","index":true,"store":true}]}
          }
        }
      }
    },
    "store":{"indexType":"scorch"}
  },
  "sourceParams":{}
}
EOFFTS
```

**Salida esperada:** El JSON debe ser válido, incluir el mapping `inventory.hotel_search_lab5.hotel_search_lab5` y definir el campo `geo` como `geopoint`.

- {% include step_label.html %} Registra el índice FTS mediante el endpoint scoped de Search 7.6 y conserva la respuesta JSON para verificar nombre, estado y posibles errores.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X PUT -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5 \
  --data-binary @search/hotel-search-lab5.json \
  | tee outputs/fts-create-response.json | jq '.'
```

**Salida esperada:** Search debe responder con `status: ok` y un nombre scoped equivalente a `travel-sample.inventory.hotel-search-lab5`, además de un UUID generado.

### Tarea 2.2. Esperar que termine la indexación

- {% include step_label.html %} Consulta repetidamente el índice con `match_all` hasta observar los seis documentos, evitando depender de campos internos de estado no estables.

```bash
for i in $(seq 1 30); do
  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS"         -X POST -H 'Content-Type: application/json'         http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query         -d '{"query":{"match_all":{}},"size":0}'
  )

  STATUS=$(echo "$RESPONSE" | jq -r '.status.failed // 0')
  DOCS=$(echo "$RESPONSE" | jq -r '.total_hits // 0')

  echo "Intento $i - documentos visibles en Search: $DOCS"

  [[ "$STATUS" -eq 0 && "$DOCS" -ge 6 ]] && break
  sleep 5
done
```

**Salida esperada:** El bucle finaliza cuando `total_hits` llega al menos a 6 y `status.failed` vale 0; DCP puede requerir varios intentos para indexarlos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🔎 Tarea 3. Ejecutar match, fuzzy, boolean y geo — 12 min

En esta tarea utilizarás cuatro familias de consultas Search para comprobar análisis lingüístico, tolerancia a errores, filtros exactos y proximidad geográfica.

### Tarea 3.1. Match en inglés y español

- {% include step_label.html %} Ejecuta un match sobre `description_en` con el término `beach` y conserva total, score y campos almacenados para revisar el analyzer inglés.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"match":"beach","field":"description_en"},"size":10,"fields":["name","city","country","description_en"]}' \
  | tee outputs/search-en.json \
  | jq '{total:.total_hits,hits:[.hits[]|{id,score,name:.fields.name,city:.fields.city}]}'
```

**Salida esperada:** `outputs/search-en.json` debe contener resultados para `beach`; el total y los scores pueden variar, pero al menos un hotel de playa debe aparecer.

- {% include step_label.html %} Ejecuta un match sobre `description_es` con `playa` para comprobar que el campo utiliza el analyzer español definido durante la indexación.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"match":"playa","field":"description_es"},"size":10,"fields":["name","city","country","description_es"]}' \
  | tee outputs/search-es.json \
  | jq '{total:.total_hits,hits:[.hits[]|{id,score,name:.fields.name}]}'
```

**Salida esperada:** `outputs/search-es.json` debe devolver al menos un resultado para `playa`, demostrando que el campo español fue indexado y consultado correctamente.

### Tarea 3.2. Fuzzy search

- {% include step_label.html %} Ejecuta una búsqueda fuzzy con `match`, `fuzziness=1` y prefijo controlado para demostrar tolerancia a un error ortográfico sobre el término `beach`.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"match":"beech","field":"description_en","fuzziness":1,"prefix_length":2},"size":10,"fields":["name","city"]}' \
  | tee outputs/search-fuzzy.json \
  | jq '{total:.total_hits,hits:[.hits[]|{id,score,name:.fields.name}]}'
```

**Salida esperada:** `outputs/search-fuzzy.json` debe devolver resultados compatibles con `beech` a distancia 1; los scores no deben compararse contra valores rígidos.

### Tarea 3.3. Boolean query

- {% include step_label.html %} Combina un match de `pool` con un term exacto sobre `country` para validar una consulta booleana que aprovecha el analyzer `keyword` del país.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"conjuncts":[{"match":"pool","field":"description_en"},{"term":"United Kingdom","field":"country"}]},"size":10,"fields":["name","city","country"]}' \
  | tee outputs/search-boolean.json \
  | jq '{total:.total_hits,hits:[.hits[]|{name:.fields.name,city:.fields.city,country:.fields.country}]}'
```

**Salida esperada:** La respuesta debe contener hoteles del Reino Unido que incluyan `pool`; el filtro exacto por `country` restringe el conjunto del match textual.

### Tarea 3.4. Geo query

- {% include step_label.html %} Busca hoteles con `pool` dentro de 100 km de Londres para combinar texto y distancia geográfica sobre el campo `geo` del mismo índice FTS.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"conjuncts":[{"match":"pool","field":"description_en"},{"location":{"lon":-0.1276,"lat":51.5074},"distance":"100km","field":"geo"}]},"size":20,"fields":["name","city","country","geo"]}' \
  | tee outputs/geo-100km.json | jq '{total:.total_hits}'
```

**Salida esperada:** `outputs/geo-100km.json` debe contener hoteles próximos a Londres que satisfagan `pool`; el total depende del corpus de la práctica.

- {% include step_label.html %} Amplía la búsqueda geográfica a 200 km y compara `total_hits`, verificando que aumentar el radio no produzca un conjunto menor al anterior.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5/query \
  -d '{"query":{"conjuncts":[{"match":"pool","field":"description_en"},{"location":{"lon":-0.1276,"lat":51.5074},"distance":"200km","field":"geo"}]},"size":20,"fields":["name","city","country","geo"]}' \
  | tee outputs/geo-200km.json | jq '{total:.total_hits}'

H100=$(jq '.total_hits' outputs/geo-100km.json)
H200=$(jq '.total_hits' outputs/geo-200km.json)
[[ "$H200" -ge "$H100" ]] && echo 'VALIDACIÓN OK' || echo 'REVISAR GEO'
```

**Salida esperada:** Debe imprimirse `VALIDACIÓN OK`; `H200` tiene que ser mayor o igual que `H100` porque el segundo radio contiene completamente al primero.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---
## ⚡ Tarea 4. Preparar collections para Eventing — 5 min

En esta tarea prepararás un bucket aislado y collections separadas para source, destination y metadata antes de iniciar el procesamiento reactivo.

### Tarea 4.1. Crear el bucket experimental

- {% include step_label.html %} Crea `lab5-eventing` de forma idempotente con una réplica y 512 MiB de cuota, reservándolo exclusivamente para source, destination y metadata.

```bash
curl -s -o outputs/create-eventing-bucket.txt \
  -w "HTTP %{http_code}\n" \
  -u "$CB_USER:$CB_PASS" \
  -X POST http://localhost:8091/pools/default/buckets \
  -d name=lab5-eventing \
  -d bucketType=couchbase \
  -d ramQuota=512 \
  -d replicaNumber=1 \
  -d storageBackend=couchstore
```

**Salida esperada:** Debe mostrarse `lab5-eventing ya existe.` o `HTTP 202/200` según la creación; posteriormente el bucket debe aparecer en `/pools/default/buckets`.

### Tarea 4.2. Crear scope y collections

- {% include step_label.html %} Crea el scope `app` y tres collections para separar las mutaciones fuente, los documentos enriquecidos y la metadata interna de Eventing.

```bash
for statement in \
  'CREATE SCOPE `lab5-eventing`.app IF NOT EXISTS;' \
  'CREATE COLLECTION `lab5-eventing`.app.bookings IF NOT EXISTS;' \
  'CREATE COLLECTION `lab5-eventing`.app.bookings_enriched IF NOT EXISTS;' \
  'CREATE COLLECTION `lab5-eventing`.app.eventing_metadata IF NOT EXISTS;'
do
  curl -sS -u "$CB_USER:$CB_PASS" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode "statement=${statement}" \
    | jq '{status,errors}'
done
```

**Salida esperada:** Cada sentencia debe responder `status: success`; al finalizar existen `app.bookings`, `app.bookings_enriched` y `app.eventing_metadata`.

### Tarea 4.3. Insertar cinco documentos antes del deployment

- {% include step_label.html %} Inserta cinco reservas antes del deployment para disponer de mutaciones históricas y demostrar después el comportamiento de DCP con `from_now`.

```bash
cat > eventing/bookings-initial.sqlpp << 'EOFSQL'
UPSERT INTO `lab5-eventing`.app.bookings (KEY, VALUE) VALUES
("booking_001", {"type":"booking","hotel_id":"hotel_001","customer_name":"Ana García","checkin":"2026-06-15","checkout":"2026-06-20","room_rate":120.0,"currency":"EUR","status":"confirmed"}),
("booking_002", {"type":"booking","hotel_id":"hotel_002","customer_name":"John Smith","checkin":"2026-07-01","checkout":"2026-07-07","room_rate":85.5,"currency":"GBP","status":"confirmed"}),
("booking_003", {"type":"booking","hotel_id":"hotel_001","customer_name":"María López","checkin":"2026-06-20","checkout":"2026-06-22","room_rate":120.0,"currency":"EUR","status":"pending"}),
("booking_004", {"type":"booking","hotel_id":"hotel_004","customer_name":"Carlos Ruiz","checkin":"2026-08-10","checkout":"2026-08-17","room_rate":200.0,"currency":"USD","status":"confirmed"}),
("booking_005", {"type":"booking","hotel_id":"hotel_002","customer_name":"Emma Wilson","checkin":"2026-09-05","checkout":"2026-09-08","room_rate":95.0,"currency":"GBP","status":"cancelled"});
EOFSQL
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode "statement@eventing/bookings-initial.sqlpp" \
  | jq '{status,mutationCount:.metrics.mutationCount,errors}'
```

**Salida esperada:** La carga inicial debe devolver `status: success` y `mutationCount` cercano a 5; las claves `booking_001` a `booking_005` quedan en source.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🧠 Tarea 5. Crear y desplegar la función Eventing — 10 min

En esta tarea registrarás una función scoped con `from_now`, generarás una mutación posterior al deployment y validarás el documento derivado.

### Tarea 5.1. Crear el código JavaScript

- {% include step_label.html %} Crea `booking-enrichment.js` para validar reservas, calcular duración y costo, clasificar la estancia y mantener un documento derivado mediante `dst`.

```bash
cat > eventing/booking-enrichment.js << 'EOFJS'
function OnUpdate(doc, meta) {
    if (!doc || doc.type !== "booking") return;

    if (doc.checkin === undefined || doc.checkout === undefined || doc.room_rate === undefined) {
        log("booking-enrichment", "Documento incompleto:", meta.id);
        return;
    }

    var checkinDate = new Date(doc.checkin);
    var checkoutDate = new Date(doc.checkout);

    if (isNaN(checkinDate.getTime()) || isNaN(checkoutDate.getTime())) {
        log("booking-enrichment", "Fecha inválida:", meta.id);
        return;
    }

    var durationMs = checkoutDate.getTime() - checkinDate.getTime();
    var durationDays = Math.round(durationMs / (1000 * 60 * 60 * 24));

    if (durationDays <= 0) {
        log("booking-enrichment", "Estadía inválida:", meta.id);
        return;
    }

    var totalCost = Number(doc.room_rate) * durationDays;

    var stayCategory = durationDays <= 2 ? "short_stay" :
                       durationDays <= 7 ? "medium_stay" : "long_stay";

    var valueCategory = totalCost < 300 ? "budget" :
                        totalCost < 1000 ? "standard" : "premium";

    var enrichedDoc = {
        original_id: meta.id,
        type: "booking_enriched",
        hotel_id: doc.hotel_id,
        customer_name: doc.customer_name,
        checkin: doc.checkin,
        checkout: doc.checkout,
        room_rate: doc.room_rate,
        currency: doc.currency || "USD",
        status: doc.status,
        duration_days: durationDays,
        total_cost: totalCost,
        stay_category: stayCategory,
        value_category: valueCategory,
        enriched_at: new Date().toISOString(),
        enrichment_version: "1.0"
    };

    var destKey = "enriched_" + meta.id;
    dst[destKey] = enrichedDoc;
    log("booking-enrichment", "Documento enriquecido:", destKey, "duration_days:", durationDays, "total_cost:", totalCost);
}

function OnDelete(meta, options) {
    var destKey = "enriched_" + meta.id;
    delete dst[destKey];
    log("booking-enrichment", "Documento eliminado del destino:", destKey);
}
EOFJS
```

**Salida esperada:** El archivo debe incluir `OnUpdate`, `OnDelete`, los cálculos `duration_days` y `total_cost`, además de la escritura del resultado mediante `dst`.

### Tarea 5.2. Crear la definición scoped

- {% include step_label.html %} Construye la definición scoped de Eventing con source, metadata y destination separados, configurando `from_now` y un worker para la primera prueba.

```bash
jq -Rs --arg appname "booking-enrichment" '
  {
    appcode: .,
    appname: $appname,
    depcfg: {
      source_bucket: "lab5-eventing",
      source_scope: "app",
      source_collection: "bookings",
      metadata_bucket: "lab5-eventing",
      metadata_scope: "app",
      metadata_collection: "eventing_metadata",
      buckets: [{
        alias: "dst",
        bucket_name: "lab5-eventing",
        scope_name: "app",
        collection_name: "bookings_enriched",
        access: "rw"
      }]
    },
    function_scope: {bucket: "lab5-eventing", scope: "app"},
    settings: {
      dcp_stream_boundary: "from_now",
      deployment_status: false,
      processing_status: false,
      log_level: "INFO",
      worker_count: 1
    }
  }' eventing/booking-enrichment.js \
  > eventing/booking-enrichment-function.json
```

**Salida esperada:** `eventing/booking-enrichment-function.json` debe ser JSON válido y mostrar source `bookings`, metadata `eventing_metadata`, destination y `from_now`.

### Tarea 5.3. Registrar y desplegar

- {% include step_label.html %} Registra la función `booking-enrichment` con Eventing REST API dentro del scope `lab5-eventing.app` y conserva la respuesta para diagnóstico.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  'http://localhost:8096/api/v1/functions/booking-enrichment?bucket=lab5-eventing&scope=app' \
  --data-binary @eventing/booking-enrichment-function.json \
  | tee outputs/eventing-create.json | jq '.'
```

**Salida esperada:** Eventing debe aceptar la definición sin errores; `outputs/eventing-create.json` conserva la respuesta completa para revisar cualquier código de fallo.

- {% include step_label.html %} Despliega la función y consulta su estado hasta obtener `deployed`, evitando generar mutaciones antes de que el procesamiento esté activo.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST \
  'http://localhost:8096/api/v1/functions/booking-enrichment/deploy?bucket=lab5-eventing&scope=app' | jq '.'
```
```bash
for i in $(seq 1 30); do

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
  )

  STATUS=$(
    echo "$RESPONSE" \
    | jq -r '.app.composite_status // "unknown"'
  )

  DEPLOYMENT=$(
    echo "$RESPONSE" \
    | jq -r '.app.deployment_status // false'
  )

  PROCESSING=$(
    echo "$RESPONSE" \
    | jq -r '.app.processing_status // false'
  )

  echo "Intento $i - status=$STATUS deployment=$DEPLOYMENT processing=$PROCESSING"

  if [[ "$STATUS" == "deployed" \
        && "$DEPLOYMENT" == "true" \
        && "$PROCESSING" == "true" ]]; then
    echo "Función Eventing desplegada y procesando."
    break
  fi

  sleep 5
done
```

**Salida esperada:** El bucle debe finalizar mostrando `booking-enrichment: deployed`; si queda en `deploying`, espera la siguiente iteración antes de generar mutaciones.

### Tarea 5.4. Disparar OnUpdate

- {% include step_label.html %} Inserta `booking_006` después del deployment para producir una mutación nueva que debe entrar en el stream DCP configurado con `from_now`.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    UPSERT INTO `lab5-eventing`.app.bookings (KEY, VALUE)
    VALUES ("booking_006", {
      "type":"booking","hotel_id":"hotel_001","customer_name":"Pedro Martínez",
      "checkin":"2026-10-01","checkout":"2026-10-10","room_rate":150.0,
      "currency":"EUR","status":"confirmed"
    });' | jq '{status,mutationCount:.metrics.mutationCount,errors}'
```

**Salida esperada:** Query Service debe responder `status: success` con una mutación; `booking_006` queda almacenado después de que la función ya está desplegada.

- {% include step_label.html %} Consulta `bookings_enriched` después de la mutación y valida que duración, costo y categorías coincidan con los valores calculados por la función.

```bash
sleep 5
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT e.* FROM `lab5-eventing`.app.bookings_enriched AS e
    WHERE e.original_id = "booking_006";' | jq '.results'
```

**Salida esperada:** El documento debe mostrar `duration_days=9`, `total_cost=1350`, `stay_category="long_stay"` y `value_category="premium"` sin campos faltantes.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🔄 Tarea 6. Comparar From Now vs Everything y revisar métricas — 8 min

En esta tarea contrastarás los dos límites DCP, observarás el reprocesamiento histórico y correlacionarás ejecución, fallos y application log.

### Tarea 6.1. Confirmar From Now

- {% include step_label.html %} Compara el conteo de source y destination para demostrar que `from_now` procesó la mutación nueva sin recorrer automáticamente las cinco históricas.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT
      (SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings)[0] AS source_count,
      (SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings_enriched)[0] AS enriched_count;' \
  | jq '.results'
```

**Salida esperada:** Antes de Everything, source debe contener 6 documentos y destination normalmente sólo el enriquecido posterior al deployment, evidenciando `from_now`.

### Tarea 6.2. Undeploy y actualizar settings

- {% include step_label.html %} Solicita el undeploy de la función y espera `undeployed` antes de modificar el límite DCP, evitando cambiar settings durante una transición activa.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST \
  'http://localhost:8096/api/v1/functions/booking-enrichment/undeploy?bucket=lab5-eventing&scope=app' \
  | jq '.'

for i in $(seq 1 30); do

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
  )

  STATUS=$(
    echo "$RESPONSE" \
    | jq -r '.app.composite_status // "unknown"'
  )

  DEPLOYMENT=$(
    echo "$RESPONSE" \
    | jq -r '.app.deployment_status // false'
  )

  PROCESSING=$(
    echo "$RESPONSE" \
    | jq -r '.app.processing_status // false'
  )

  echo "Intento $i - status=$STATUS deployment=$DEPLOYMENT processing=$PROCESSING"

  if [[ "$STATUS" == "undeployed" \
        && "$DEPLOYMENT" == "false" \
        && "$PROCESSING" == "false" ]]; then
    echo "Función Eventing detenida correctamente."
    break
  fi

  sleep 3
done
```

**Salida esperada:** El estado debe evolucionar hasta `undeployed`; no continúes al cambio de settings mientras la función aparezca `undeploying` o `deployed`.

- {% include step_label.html %} Cambia `dcp_stream_boundary` a `everything` mientras la función está undeployed para que el siguiente deployment recorra las mutaciones históricas.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST -H 'Content-Type: application/json' \
  'http://localhost:8096/api/v1/functions/booking-enrichment/settings?bucket=lab5-eventing&scope=app' \
  -d '{"deployment_status":false,"processing_status":false,"dcp_stream_boundary":"everything","worker_count":1,"log_level":"INFO"}' \
  | jq '.'
```

**Salida esperada:** La respuesta de settings debe ser exitosa y la consulta posterior de settings debe mostrar `dcp_stream_boundary` con valor `everything`.

### Tarea 6.3. Re-deploy con Everything

- {% include step_label.html %} Despliega nuevamente la función y compara source con destination hasta que el reprocesamiento histórico complete la población enriquecida esperada.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST \
  'http://localhost:8096/api/v1/functions/booking-enrichment/deploy?bucket=lab5-eventing&scope=app' \
  | jq '.'

# Esperar primero a que Eventing quede realmente desplegado y procesando.
for i in $(seq 1 30); do

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
  )

  STATUS=$(
    echo "$RESPONSE" \
    | jq -r '.app.composite_status // "unknown"'
  )

  DEPLOYMENT=$(
    echo "$RESPONSE" \
    | jq -r '.app.deployment_status // false'
  )

  PROCESSING=$(
    echo "$RESPONSE" \
    | jq -r '.app.processing_status // false'
  )

  echo "Intento $i - status=$STATUS deployment=$DEPLOYMENT processing=$PROCESSING"

  if [[ "$STATUS" == "deployed" \
        && "$DEPLOYMENT" == "true" \
        && "$PROCESSING" == "true" ]]; then
    echo "Función Eventing desplegada y procesando con Everything."
    break
  fi

  sleep 5
done

# Esperar después a que destination alcance el conteo vigente de source.
for i in $(seq 1 30); do

  COUNTS=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8093/query/service \
      --data-urlencode 'statement=
        SELECT
          (SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings)[0] AS source_count,
          (SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings_enriched)[0] AS enriched_count;'
  )

  QUERY_STATUS=$(
    echo "$COUNTS" \
    | jq -r '.status // "unknown"'
  )

  if [[ "$QUERY_STATUS" != "success" ]]; then
    echo "ERROR: Query Service devolvió:"
    echo "$COUNTS" | jq '{status,errors}'
    break
  fi

  SRC=$(
    echo "$COUNTS" \
    | jq -r '.results[0].source_count // 0'
  )

  DST=$(
    echo "$COUNTS" \
    | jq -r '.results[0].enriched_count // 0'
  )

  echo "Intento $i - source=$SRC enriched=$DST"

  if [[ "$DST" -ge "$SRC" ]]; then
    echo "Reprocesamiento histórico completado."
    break
  fi

  sleep 5
done
```

**Salida esperada:** El conteo de destination debe alcanzar el conteo vigente de source una vez procesadas las mutaciones históricas; el tiempo exacto depende de DCP.

### Tarea 6.4. Revisar stats, logs y OnDelete

- {% include step_label.html %} Captura estadísticas de ejecución, fallos y application log para correlacionar mutaciones procesadas con los mensajes generados por la función.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  'http://localhost:8096/getExecutionStats?name=booking-enrichment&bucket=lab5-eventing&scope=app' \
  | tee metrics/eventing-execution-stats.json | jq '.'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  'http://localhost:8096/getFailureStats?name=booking-enrichment&bucket=lab5-eventing&scope=app' \
  | tee metrics/eventing-failure-stats.json | jq '.'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  'http://localhost:8096/getAppLog?name=booking-enrichment&aggregate=true&bucket=lab5-eventing&scope=app' \
  | tee outputs/eventing-applog.txt
```

**Salida esperada:** Se deben crear archivos de métricas y log no vacíos; execution/failure stats y `getAppLog` permiten revisar procesamiento y mensajes de la función.

- {% include step_label.html %} Elimina `booking_006` del source y confirma que `OnDelete` retire `enriched_booking_006`, validando la sincronización con el destino.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DELETE FROM `lab5-eventing`.app.bookings USE KEYS "booking_006";' \
  | jq '{status,mutationCount:.metrics.mutationCount,errors}'
sleep 5
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings_enriched USE KEYS "enriched_booking_006";' \
  | jq '.results'
```

**Salida esperada:** DELETE debe reportar una mutación y el conteo de `enriched_booking_006` debe terminar en 0 después de que Eventing procese `OnDelete`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---
## 📊 Tarea 7. Habilitar Analytics shadows — 7 min

En esta tarea habilitarás copias analíticas sobre collections concretas y compararás sus conteos con Data Service considerando la ingestión asíncrona.

En Couchbase 7.6 es preferible hablar de **Analytics scopes y Analytics collections**. Los términos históricos `Dataverse` y `Dataset` todavía pueden aparecer en metadata y documentación.

### Tarea 7.1. Habilitar Analytics sobre collections concretas

- {% include step_label.html %} Habilita Analytics sobre `hotel`, `route` y `bookings_enriched` mediante sentencias independientes para crear copias analíticas alimentadas por DCP.

```bash
cat > analytics/enable-analytics.sqlpp << 'EOFSQL'
ALTER COLLECTION `travel-sample`.inventory.hotel ENABLE ANALYTICS;
ALTER COLLECTION `travel-sample`.inventory.route ENABLE ANALYTICS;
ALTER COLLECTION `lab5-eventing`.app.bookings_enriched ENABLE ANALYTICS;
EOFSQL

: > outputs/analytics-enable.json
```
```bash
while IFS= read -r statement; do
  [[ -n "$statement" ]] || continue

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8095/analytics/service \
      --data-urlencode "statement=${statement}"
  )

  echo "$RESPONSE" | tee -a outputs/analytics-enable.json | jq '{status,errors}'
done < analytics/enable-analytics.sqlpp
```

**Salida esperada:** Las tres sentencias `ALTER COLLECTION ... ENABLE ANALYTICS` deben responder `status: success`; Analytics crea sus collections sincronizadas por DCP.

### Tarea 7.2. Preparar acceso operacional para la comparación

- {% include step_label.html %} Crea índices primarios temporales en `hotel` y `route` para que Query Service pueda contar y agregar ambas collections durante la comparación.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=CREATE PRIMARY INDEX idx_lab5_hotel_primary IF NOT EXISTS ON `travel-sample`.inventory.hotel;'   | jq '{status,errors}'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=CREATE PRIMARY INDEX idx_lab5_route_primary IF NOT EXISTS ON `travel-sample`.inventory.route;'   | jq '{status,errors}'
```

**Salida esperada:** Ambas respuestas deben mostrar `status: success`; los índices quedarán disponibles sólo para las consultas operacionales de esta práctica.

### Tarea 7.3. Comparar conteos operacionales y analíticos

- {% include step_label.html %} Obtén conteos de las tres collections mediante Query Service para establecer la referencia operacional que se comparará con Analytics Service.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=
    SELECT
      (SELECT RAW COUNT(*) FROM `travel-sample`.inventory.hotel)[0] AS hotels,
      (SELECT RAW COUNT(*) FROM `travel-sample`.inventory.route)[0] AS routes,
      (SELECT RAW COUNT(*) FROM `lab5-eventing`.app.bookings_enriched)[0] AS bookings_enriched;' \
  | tee outputs/data-service-counts.json | jq '.results'
```

**Salida esperada:** `outputs/data-service-counts.json` debe contener valores operacionales para hoteles, rutas y reservas enriquecidas sin errores de Query Service.

- {% include step_label.html %} Consulta los mismos keyspaces desde Analytics hasta aproximar los conteos operacionales, considerando que la ingestión mediante DCP es asíncrona.

```bash
for i in $(seq 1 30); do
  echo "=== $(date +%H:%M:%S) ==="

  curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
    --data-urlencode 'statement=
      SELECT
        (SELECT VALUE COUNT(*) FROM `travel-sample`.inventory.hotel)[0] AS hotels,
        (SELECT VALUE COUNT(*) FROM `travel-sample`.inventory.route)[0] AS routes,
        (SELECT VALUE COUNT(*) FROM `lab5-eventing`.app.bookings_enriched)[0] AS bookings_enriched;' \
    | tee outputs/analytics-counts.json | jq '.results'

  sleep 5
done
```

> **NOTA:** Analytics consulta su propia copia analítica; DCP mantiene esa representación sincronizada y puede existir una demora breve respecto a Data Service.
{: .lab-note .info .compact}

**Salida esperada:** `outputs/analytics-counts.json` debe converger con la referencia operacional; se aceptan diferencias temporales mientras DCP ingiere los datos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 📈 Tarea 8. Ejecutar window functions OLAP — 10 min

En esta tarea aplicarás funciones de ventana a hoteles, reservas enriquecidas y rutas para demostrar análisis OLAP sobre el almacenamiento de Analytics.

### Tarea 8.1. Validar la estructura de reviews

- {% include step_label.html %} Inspecciona una review real de `inventory.hotel` antes de usar `ratings.Overall`, confirmando la ruta de datos que emplearán las consultas OLAP.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode 'statement=
    SELECT VALUE h.reviews[0]
    FROM `travel-sample`.inventory.hotel AS h
    WHERE ARRAY_LENGTH(h.reviews) > 0
    LIMIT 1;' | jq '.results[0]'
```

**Salida esperada:** La respuesta debe mostrar una review con `ratings.Overall`; si esa ruta no existe, corrige la consulta antes de usar las window functions.

### Tarea 8.2. Ranking de hoteles por país

- {% include step_label.html %} Ejecuta una agregación de reviews seguida de `RANK()` y `COUNT() OVER` para obtener posición y cantidad de hoteles dentro de cada país.

```bash
cat > analytics/q1-hotel-ranking.sqlpp << 'EOFSQL'
SELECT country,
       name,
       city,
       avg_rating,
       RANK() OVER (
         PARTITION BY country
         ORDER BY avg_rating DESC
       ) AS rank_in_country,
       COUNT(*) OVER (
         PARTITION BY country
       ) AS hotels_in_country
FROM (
  SELECT h.name,
         h.city,
         h.country,
         AVG(review.ratings.Overall) AS avg_rating
  FROM `travel-sample`.inventory.hotel AS h
  UNNEST h.reviews AS review
  WHERE h.country IS NOT MISSING
    AND review.ratings.Overall IS NOT MISSING
  GROUP BY h.name, h.city, h.country
) AS ranked
WHERE avg_rating IS NOT NULL
ORDER BY country, rank_in_country
LIMIT 20;
EOFSQL

curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode "statement@analytics/q1-hotel-ranking.sqlpp" \
  | tee outputs/analytics-hotel-ranking.json \
  | jq '{status,resultCount:.metrics.resultCount,results}'
```

**Salida esperada:** `outputs/analytics-hotel-ranking.json` debe tener `status: success` y filas con `rank_in_country` y `hotels_in_country` calculados por ventana.

### Tarea 8.3. Acumulado sobre bookings_enriched

- {% include step_label.html %} Ejecuta `SUM() OVER` y `AVG() OVER` sobre `bookings_enriched` para calcular acumulados por hotel y promedios por categoría de estancia.

```bash
cat > analytics/q2-bookings.sqlpp << 'EOFSQL'
SELECT hotel_id,
       stay_category,
       value_category,
       total_cost,
       SUM(total_cost) OVER (
         PARTITION BY hotel_id
         ORDER BY enriched_at
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_revenue,
       AVG(total_cost) OVER (
         PARTITION BY stay_category
       ) AS avg_cost_by_category
FROM `lab5-eventing`.app.bookings_enriched
ORDER BY hotel_id, enriched_at;
EOFSQL
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode "statement@analytics/q2-bookings.sqlpp" \
  | tee outputs/analytics-bookings.json \
  | jq '{status,resultCount:.metrics.resultCount,results}'
```

**Salida esperada:** El JSON debe incluir `cumulative_revenue` y `avg_cost_by_category`; la cantidad de filas dependerá del conjunto enriquecido vigente.

### Tarea 8.4. Ranking de aerolíneas por conectividad

- {% include step_label.html %} Agrega rutas por aerolínea y aplica `RANK()` sobre el total de conexiones usando únicamente campos garantizados en `inventory.route`.

```bash
cat > analytics/q3-route-connectivity.sqlpp << 'EOFSQL'
WITH RouteStats AS (
  SELECT r.airline,
         COUNT(*) AS total_routes,
         COUNT(DISTINCT r.sourceairport) AS source_airports,
         COUNT(DISTINCT r.destinationairport) AS destination_airports
  FROM `travel-sample`.inventory.route AS r
  WHERE r.airline IS NOT MISSING
  GROUP BY r.airline
)
SELECT airline,
       total_routes,
       source_airports,
       destination_airports,
       RANK() OVER (ORDER BY total_routes DESC) AS route_rank
FROM RouteStats
ORDER BY route_rank
LIMIT 20;
EOFSQL
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode "statement@analytics/q3-route-connectivity.sqlpp" \
  | tee outputs/analytics-route-ranking.json \
  | jq '{status,resultCount:.metrics.resultCount,results}'
```

**Salida esperada:** `outputs/analytics-route-ranking.json` debe devolver aerolíneas con `total_routes`, aeropuertos distintos y `route_rank` ordenado por conectividad.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## ⚖️ Tarea 9. Comparar Query Service y Analytics Service — 5 min

En esta tarea ejecutarás una misma agregación por ambos servicios y conservarás planes y métricas sin asumir de antemano cuál debe ser más rápido.

### Tarea 9.1. Crear una consulta lógica equivalente

- {% include step_label.html %} Guarda una agregación común de hoteles para ejecutar exactamente la misma lógica en Query y Analytics sin sesgar previamente la comparación.

```bash
cat > analytics/query-vs-analytics.sqlpp << 'EOFSQL'
SELECT h.country,
       COUNT(*) AS hotel_count,
       AVG(review.ratings.Overall) AS avg_rating
FROM `travel-sample`.inventory.hotel AS h
UNNEST h.reviews AS review
WHERE review.ratings.Overall IS NOT MISSING
GROUP BY h.country
ORDER BY avg_rating DESC;
EOFSQL
```

**Salida esperada:** `analytics/query-vs-analytics.sqlpp` debe quedar creado sin errores y conservar exactamente la consulta que se utilizará en ambos servicios.

### Tarea 9.2. Capturar EXPLAIN y métricas de Query

- {% include step_label.html %} Captura `EXPLAIN` y métricas de Query Service para registrar el plan operacional, tiempo transcurrido, ejecución y cantidad de resultados.

```bash
SQL="$(tr '\n' ' ' < analytics/query-vs-analytics.sqlpp)"

curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode "statement=EXPLAIN ${SQL}" \
  | jq '.results[0]' | tee outputs/query-explain.json
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode "statement=${SQL}" \
  | jq '{status,elapsedTime:.metrics.elapsedTime,executionTime:.metrics.executionTime,resultCount:.metrics.resultCount}' \
  | tee metrics/query-service-comparison.json
```

**Salida esperada:** `outputs/query-explain.json` y `metrics/query-service-comparison.json` deben quedar no vacíos; la ejecución real debe responder `status: success`.

### Tarea 9.3. Capturar EXPLAIN y métricas de Analytics

- {% include step_label.html %} Captura el `EXPLAIN` y las métricas expuestas por Analytics para comparar el mismo análisis desde su almacenamiento analítico independiente.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode "statement=EXPLAIN ${SQL}" \
  | jq '.results[0]' | tee outputs/analytics-explain.json
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8095/analytics/service \
  --data-urlencode "statement=${SQL}" \
  | jq '{status,metrics}' \
  | tee metrics/analytics-service-comparison.json
```

**Salida esperada:** Ambos archivos deben contener datos, el plan debe ser legible y la ejecución analítica debe terminar con una respuesta satisfactoria.

### Tarea 9.4. Completar la comparación

| Aspecto | Query Service | Analytics Service |
|---|---|---|
| Datos consultados | Datos operacionales; puede usar GSI y Fetch | Copia analítica mantenida por Analytics |
| Sincronización | No aplica al SELECT | Ingestión asíncrona mediante DCP |
| Paralelismo | Puede ejecutar operadores en paralelo | Diseñado para procesamiento analítico paralelo |
| Caso de uso | Consultas operacionales y de baja latencia | OLAP, agregaciones y análisis complejo |
| Resultado medido | | |

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Generar reporte, validar y limpiar — 5 min

En esta tarea validarás los resultados mínimos, consolidarás evidencias y retirarás Search, Eventing y Analytics sin modificar `travel-sample`.

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea `validate.sh` para comprobar FTS, Eventing, Analytics y archivos de comparación, reportando cada criterio como PASS o FAIL sin umbrales rígidos.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab5/validate.sh
  ```

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ./scripts/validate.sh
  ```

**Salida esperada:** `bash -n scripts/validate.sh` debe finalizar sin salida y la ejecución debe reportar todos los criterios como PASS antes de permitir la limpieza.

### Tarea 10.2. Crear reporte final

- {% include step_label.html %} Consolida resultados de Search, Eventing y métricas Query/Analytics en un reporte local antes de eliminar los recursos temporales del laboratorio.

```bash
{
  echo "============================================================"
  echo "REPORTE FINAL - LAB 5"
  echo "Fecha: $(date)"
  echo "============================================================"
  echo "--- SEARCH EN ---"; jq '{total_hits,max_score}' outputs/search-en.json
  echo "--- SEARCH ES ---"; jq '{total_hits,max_score}' outputs/search-es.json
  echo "--- FUZZY ---"; jq '{total_hits,max_score}' outputs/search-fuzzy.json
  echo "--- EVENTING STATUS ---"
  curl -sS -u "$CB_USER:$CB_PASS" 'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
  echo "--- QUERY VS ANALYTICS ---"
  cat metrics/query-service-comparison.json
  cat metrics/analytics-service-comparison.json
} | tee outputs/final-summary.txt
```

**Salida esperada:** `outputs/final-summary.txt` debe reunir Search EN/ES, fuzzy, estado Eventing y métricas de ambos servicios antes de realizar la limpieza.

### Tarea 10.3. Limpiar Eventing y Analytics

- {% include step_label.html %} Undeploy y elimina la función scoped únicamente cuando quede detenida, evitando retirar el bucket mientras Eventing aún mantiene procesamiento activo.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST \
  'http://localhost:8096/api/v1/functions/booking-enrichment/undeploy?bucket=lab5-eventing&scope=app' | jq '.'
```
```bash
for i in $(seq 1 30); do

  RESPONSE=$(
    curl -sS -u "$CB_USER:$CB_PASS" \
      'http://localhost:8096/api/v1/status/booking-enrichment?bucket=lab5-eventing&scope=app'
  )

  STATUS=$(
    echo "$RESPONSE" \
    | jq -r '.app.composite_status // "unknown"'
  )

  DEPLOYMENT=$(
    echo "$RESPONSE" \
    | jq -r '.app.deployment_status // false'
  )

  PROCESSING=$(
    echo "$RESPONSE" \
    | jq -r '.app.processing_status // false'
  )

  echo "Intento $i - status=$STATUS deployment=$DEPLOYMENT processing=$PROCESSING"

  if [[ "$STATUS" == "undeployed" \
        && "$DEPLOYMENT" == "false" \
        && "$PROCESSING" == "false" ]]; then
    echo "Función Eventing detenida correctamente."
    break
  fi

  sleep 3
done
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X DELETE \
  'http://localhost:8096/api/v1/functions/booking-enrichment?bucket=lab5-eventing&scope=app' | jq '.'
```

**Salida esperada:** La función debe llegar a `undeployed` antes del DELETE; después, la consulta de estado no debe mostrarla como función activa del scope.

- {% include step_label.html %} Deshabilita Analytics en cada collection mediante sentencias independientes antes de borrar recursos operacionales utilizados como fuentes analíticas.

```bash
curl -sS -u "$CB_USER:$CB_PASS" \
  -X POST http://localhost:8095/analytics/service \
  --data-urlencode 'statement=
    ALTER COLLECTION `lab5-eventing`.app.bookings_enriched
    DISABLE ANALYTICS;' \
  | jq '{status,errors}'

echo "NOTA: travel-sample.inventory.hotel y route conservan Analytics habilitado"
echo "porque existen vistas Analytics dependientes:"
echo "- hotel_endorsement_view"
echo "- route_schedule_view"
```

**Salida esperada:** Cada `DISABLE ANALYTICS` debe responder `status: success`; las copias analíticas se retiran sin eliminar las collections operacionales originales.

### Tarea 10.4. Eliminar Search y recursos temporales

- {% include step_label.html %} Elimina los índices temporales, el FTS scoped, la collection bilingüe y el bucket Eventing, preservando los datos originales y las evidencias locales.

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=DROP INDEX IF EXISTS idx_lab5_hotel_primary ON `travel-sample`.inventory.hotel;' | jq '{status,errors}'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service --data-urlencode 'statement=DROP INDEX IF EXISTS idx_lab5_route_primary ON `travel-sample`.inventory.route;' | jq '{status,errors}'
```

```bash
curl -sS -u "$CB_USER:$CB_PASS" -X DELETE http://localhost:8094/api/bucket/travel-sample/scope/inventory/index/hotel-search-lab5 | jq '.'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
  --data-urlencode 'statement=DROP COLLECTION `travel-sample`.inventory.hotel_search_lab5 IF EXISTS;' | jq '{status,errors}'
```
```bash
curl -sS -u "$CB_USER:$CB_PASS" -X DELETE http://localhost:8091/pools/default/buckets/lab5-eventing -w "\nHTTP %{http_code}\n"
```

**Salida esperada:** Los índices temporales y FTS deben desaparecer, `hotel_search_lab5` debe eliminarse y `lab5-eventing` debe borrarse sin afectar los datos del sample.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}

{% include support-prompt.html task="tarea10" %}

---

## 🧹 Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` los cinco port-forward activos para liberar puertos locales y cerrar sesiones antes de eliminar la infraestructura de Amazon EKS.

**Salida esperada:** Cada terminal de port-forward debe finalizar al presionar `Ctrl+C`; los puertos 8091, 8093, 8094, 8095 y 8096 quedan liberados localmente.

- {% include step_label.html %} Ejecuta `delete` desde el script de ciclo de vida usando exactamente región y nombre del clúster para retirar control plane y managed node group.

```bash
cd /c/LABS/couchbase-nosql/lab5
source lab.env
./scripts/eks-cluster.sh delete
```

**Salida esperada:** `eksctl` debe mostrar el progreso de eliminación hasta retirar el clúster y sus recursos administrados sin terminar con mensajes `ERROR`.

- {% include step_label.html %} Consulta Amazon EKS con el nombre eliminado y confirma `ResourceNotFoundException` como evidencia de que la infraestructura dejó de existir.

```bash
aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION"
```

**Salida esperada:** AWS CLI debe responder `ResourceNotFoundException`, confirmando que el control plane del clúster ya no existe en la región seleccionada.