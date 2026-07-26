# Análisis de la arquitectura y distribución interna de un clúster

## Metadatos

| Campo         | Valor                                      |
|---------------|--------------------------------------------|
| Duración      | 60 minutos                                 |
| Complejidad   | Media                                      |
| Nivel Bloom   | Aplicar (Apply)                            |
| Versión CB    | Couchbase Server Enterprise 7.6.x          |
| Modalidad     | Individual / Parejas                       |

---

## Descripción General

En este laboratorio desplegarás un clúster Couchbase de 3 nodos usando Docker Compose, configurando cada nodo con servicios diferenciados siguiendo el principio de **Multidimensional Scaling (MDS)**. Explorarás la arquitectura peer-to-peer interna: analizarás la distribución de los 1024 vBuckets entre nodos, consultarás el cluster map mediante la REST API, y verificarás el rol de cada servicio (Data, Query, Index, Search, Analytics, Eventing). Al finalizar, habrás construido un mapa completo y documentado de la topología del clúster observada.

---

## Objetivos de Aprendizaje

- [ ] Desplegar y configurar un clúster Couchbase de 3 nodos con separación de servicios (MDS) usando Docker Compose.
- [ ] Consultar el cluster map y la distribución de vBuckets activos y réplicas mediante la REST API y `couchbase-cli`.
- [ ] Diferenciar los roles y responsabilidades de cada servicio en un despliegue MDS real.
- [ ] Mapear la topología completa del clúster identificando la distribución de datos por nodo.
- [ ] Analizar el flujo de metadatos del Cluster Manager a través del endpoint `/pools/default`.

---

## Prerrequisitos

### Conocimiento previo
- Conceptos básicos de sistemas distribuidos: replicación y particionamiento.
- Familiaridad con JSON y REST APIs (lectura de respuestas JSON).
- Uso básico de terminal Linux (bash), `curl` y `docker`.
- Comprensión conceptual de contenedores Docker.

### Acceso y herramientas requeridas
- Docker Engine 24.x o superior instalado y en ejecución (`docker info` sin errores).
- Docker Compose plugin (`docker compose version` ≥ 2.20).
- Herramientas CLI: `curl`, `jq` 1.6+, `python3`.
- Mínimo 12 GB de RAM disponible para el host (3 contenedores × ~3 GB + overhead).
- Puertos locales libres: 8091–8097, 11210, 18091–18097.

---

## Entorno de Laboratorio

### Recursos de hardware recomendados

| Recurso         | Mínimo             | Recomendado         |
|-----------------|--------------------|---------------------|
| vCPUs (host)    | 4                  | 8                   |
| RAM (host)      | 12 GB              | 16 GB               |
| Almacenamiento  | 20 GB libres       | 40 GB SSD           |
| Red inter-nodo  | Docker bridge      | Docker bridge / overlay |

### Software utilizado

| Componente              | Versión       | Propósito                              |
|-------------------------|---------------|----------------------------------------|
| Couchbase Server EE     | 7.6.x         | Nodos del clúster                      |
| Docker Engine           | 24.x          | Contenedores de nodos                  |
| Docker Compose plugin   | 2.20+         | Orquestación multi-contenedor          |
| couchbase-cli           | Incluido CB   | Administración CLI del clúster         |
| curl + jq               | 7.x / 1.6     | Consultas REST API y formateo JSON     |
| cbq                     | Incluido CB   | Shell de consultas SQL++               |

### Configuración inicial del entorno

Crea el directorio de trabajo y el archivo `docker-compose.yml`:

```bash
mkdir -p ~/lab-01-00-01 && cd ~/lab-01-00-01
```

Crea el archivo `docker-compose.yml` con el siguiente contenido:

```yaml
# docker-compose.yml — Clúster Couchbase 3 nodos para Lab 01-00-01
version: "3.9"

networks:
  cb-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.28.0.0/24

services:
  cb-node1:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-node1
    hostname: cb-node1
    networks:
      cb-net:
        ipv4_address: 172.28.0.11
    ports:
      - "8091:8091"
      - "8092:8092"
      - "8093:8093"
      - "8094:8094"
      - "8095:8095"
      - "8096:8096"
      - "8097:8097"
      - "11210:11210"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - cb-data1:/opt/couchbase/var

  cb-node2:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-node2
    hostname: cb-node2
    networks:
      cb-net:
        ipv4_address: 172.28.0.12
    ports:
      - "8191:8091"
      - "8192:8092"
      - "8193:8093"
      - "8194:8094"
      - "8195:8095"
      - "8196:8096"
      - "8197:8097"
      - "11211:11210"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - cb-data2:/opt/couchbase/var

  cb-node3:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-node3
    hostname: cb-node3
    networks:
      cb-net:
        ipv4_address: 172.28.0.13
    ports:
      - "8291:8091"
      - "8292:8092"
      - "8293:8093"
      - "8294:8094"
      - "8295:8095"
      - "8296:8096"
      - "8297:8097"
      - "11212:11210"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    volumes:
      - cb-data3:/opt/couchbase/var

volumes:
  cb-data1:
  cb-data2:
  cb-data3:
```

---

## Procedimiento Paso a Paso

---

### Paso 1: Despliegue del clúster con Docker Compose

**Objetivo:** Levantar los tres contenedores Couchbase y verificar que están accesibles antes de proceder con la configuración.

**Instrucciones:**

1. Desde el directorio `~/lab-01-00-01`, inicia los contenedores en segundo plano:

```bash
docker compose up -d
```

2. Espera aproximadamente 30 segundos y verifica que los tres contenedores están en estado `running`:

```bash
docker compose ps
```

3. Comprueba que el nodo 1 responde en el puerto de administración:

```bash
curl -s http://localhost:8091/ui/index.html -o /dev/null -w "HTTP Status: %{http_code}\n"
```

4. Repite la verificación para los nodos 2 y 3:

```bash
curl -s http://localhost:8191/ui/index.html -o /dev/null -w "HTTP Status node2: %{http_code}\n"
curl -s http://localhost:8291/ui/index.html -o /dev/null -w "HTTP Status node3: %{http_code}\n"
```

**Salida esperada:**

```
NAME        IMAGE                               COMMAND                  SERVICE     CREATED         STATUS         PORTS
cb-node1    couchbase/server:enterprise-7.6.2   "/entrypoint.sh couc…"   cb-node1    X seconds ago   Up X seconds   0.0.0.0:8091->8091/tcp, ...
cb-node2    couchbase/server:enterprise-7.6.2   "/entrypoint.sh couc…"   cb-node2    X seconds ago   Up X seconds   0.0.0.0:8191->8091/tcp, ...
cb-node3    couchbase/server:enterprise-7.6.2   "/entrypoint.sh couc…"   cb-node3    X seconds ago   Up X seconds   0.0.0.0:8291->8091/tcp, ...

HTTP Status: 200
HTTP Status node2: 200
HTTP Status node3: 200
```

**Verificación:**

```bash
# Todos los contenedores deben aparecer con Status "Up"
docker compose ps --format "table {{.Name}}\t{{.Status}}"
```

---

### Paso 2: Inicialización del nodo primario (cb-node1)

**Objetivo:** Configurar el primer nodo como nodo primario del clúster, asignándole únicamente los servicios de **Data** (kv) y **Query** (n1ql). Esto implementa el principio MDS separando el plano de datos del plano de consultas.

**Instrucciones:**

1. Inicializa el nodo 1 con cuota de memoria y servicios Data + Query:

```bash
docker exec cb-node1 couchbase-cli node-init \
  --cluster http://cb-node1:8091 \
  --node-init-hostname cb-node1 \
  --node-init-data-path /opt/couchbase/var/lib/couchbase/data \
  --node-init-index-path /opt/couchbase/var/lib/couchbase/indexes \
  --node-init-analytics-path /opt/couchbase/var/lib/couchbase/analytics \
  --node-init-eventing-path /opt/couchbase/var/lib/couchbase/eventing
```

2. Crea el clúster en el nodo 1, habilitando solo los servicios Data y Query:

```bash
docker exec cb-node1 couchbase-cli cluster-init \
  --cluster http://cb-node1:8091 \
  --cluster-name "lab-cluster" \
  --cluster-username Administrator \
  --cluster-password Passw0rd! \
  --cluster-ramsize 1024 \
  --cluster-index-ramsize 512 \
  --cluster-fts-ramsize 256 \
  --cluster-analytics-ramsize 512 \
  --cluster-eventing-ramsize 256 \
  --services data,query
```

**Salida esperada:**

```
SUCCESS: Cluster initialized
```

**Verificación:**

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '.nodes[0] | {hostname: .hostname, services: .services, status: .status}'
```

Debes ver `"services": ["kv","n1ql"]` para el nodo 1.

---

### Paso 3: Incorporación de cb-node2 (servicios Index y Search)

**Objetivo:** Agregar el segundo nodo al clúster asignándole los servicios de **Index** (index) y **Search** (fts), demostrando la separación MDS entre indexación y búsqueda full-text respecto al nodo de datos.

**Instrucciones:**

1. Agrega cb-node2 al clúster con servicios Index y Search:

```bash
docker exec cb-node1 couchbase-cli server-add \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --server-add http://cb-node2:8091 \
  --server-add-username Administrator \
  --server-add-password Passw0rd! \
  --services index,fts
```

2. Verifica que el nodo fue añadido en estado `inactiveAdded`:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname: .hostname, clusterMembership: .clusterMembership, services: .services}'
```

**Salida esperada (parcial):**

```json
{
  "hostname": "cb-node2:8091",
  "clusterMembership": "inactiveAdded",
  "services": ["fts", "index"]
}
```

**Verificación:**

```bash
docker exec cb-node1 couchbase-cli server-list \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd!
```

Debes ver cb-node2 listado con estado `inactiveAdded`.

---

### Paso 4: Incorporación de cb-node3 (servicios Analytics y Eventing)

**Objetivo:** Agregar el tercer nodo con los servicios **Analytics** (cbas) y **Eventing** (eventing), completando la separación MDS de todos los servicios especializados en nodos dedicados.

**Instrucciones:**

1. Agrega cb-node3 al clúster con servicios Analytics y Eventing:

```bash
docker exec cb-node1 couchbase-cli server-add \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --server-add http://cb-node3:8091 \
  --server-add-username Administrator \
  --server-add-password Passw0rd! \
  --services analytics,eventing
```

2. Confirma que los tres nodos están pendientes de rebalanceo:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '[.nodes[] | {hostname: .hostname, membership: .clusterMembership, services: .services}]'
```

**Salida esperada:**

```json
[
  { "hostname": "cb-node1:8091", "membership": "active",        "services": ["kv","n1ql"] },
  { "hostname": "cb-node2:8091", "membership": "inactiveAdded", "services": ["fts","index"] },
  { "hostname": "cb-node3:8091", "membership": "inactiveAdded", "services": ["cbas","eventing"] }
]
```

**Verificación:**

```bash
# Verificar que hay exactamente 3 nodos registrados
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '.nodes | length'
# Resultado esperado: 3
```

---

### Paso 5: Rebalanceo inicial del clúster

**Objetivo:** Ejecutar el primer rebalanceo para activar los nodos incorporados, redistribuir responsabilidades y llevar el clúster a un estado `healthy` completo.

**Instrucciones:**

1. Inicia el rebalanceo desde cb-node1:

```bash
docker exec cb-node1 couchbase-cli rebalance \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --no-progress-bar
```

2. Espera a que el rebalanceo finalice (puede tomar 30–60 segundos). Monitorea el estado:

```bash
# Ejecuta este comando en un segundo terminal mientras el rebalanceo corre
watch -n 2 'curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/rebalanceProgress \
  | jq "{status: .status, progress: .progress}"'
```

3. Una vez completado, verifica el estado del clúster:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '{clusterName: .clusterName, rebalanceStatus: .rebalanceStatus, nodes: [.nodes[] | {hostname: .hostname, status: .status, membership: .clusterMembership}]}'
```

**Salida esperada:**

```json
{
  "clusterName": "lab-cluster",
  "rebalanceStatus": "none",
  "nodes": [
    { "hostname": "cb-node1:8091", "status": "healthy", "membership": "active" },
    { "hostname": "cb-node2:8091", "status": "healthy", "membership": "active" },
    { "hostname": "cb-node3:8091", "status": "healthy", "membership": "active" }
  ]
}
```

**Verificación:**

```bash
docker exec cb-node1 couchbase-cli server-list \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd!
```

Los tres nodos deben aparecer con estado `healthy active`.

---

### Paso 6: Carga del dataset travel-sample

**Objetivo:** Cargar el bucket `travel-sample` (~63K documentos) para generar distribución real de datos entre los vBuckets y poder observar la topología con datos reales.

**Instrucciones:**

1. Carga el sample bucket `travel-sample`:

```bash
docker exec cb-node1 couchbase-cli bucket-create \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --bucket travel-sample \
  --bucket-type couchbase \
  --bucket-ramsize 512 \
  --bucket-replica 1 \
  --enable-flush 1
```

2. Carga los datos del sample usando `cbdocloader`:

```bash
docker exec cb-node1 cbdocloader \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --bucket travel-sample \
  --dataset /opt/couchbase/samples/travel-sample.zip \
  --threads 4
```

> **Nota:** Si `cbdocloader` no está disponible en el PATH del contenedor, usa la Web Console en `http://localhost:8091` → Settings → Sample Buckets → selecciona `travel-sample` → Load Sample Data.

3. Espera a que el bucket esté listo:

```bash
# Monitorea el estado del bucket hasta que itemCount > 60000
watch -n 3 'curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq "{name: .name, itemCount: .basicStats.itemCount, diskUsed: .basicStats.diskUsed}"'
```

**Salida esperada (cuando el bucket esté cargado):**

```json
{
  "name": "travel-sample",
  "itemCount": 63288,
  "diskUsed": 45678901
}
```

**Verificación:**

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '.basicStats.itemCount'
# Debe ser >= 63000
```

---

### Paso 7: Análisis del Cluster Map mediante REST API

**Objetivo:** Consultar y analizar el cluster map completo para entender qué información utiliza el SDK para enrutar solicitudes directamente a los nodos responsables, sin intermediarios.

**Instrucciones:**

1. Obtén el cluster map completo del bucket travel-sample (este es el documento que recibe el SDK):

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/b/travel-sample \
  | jq '{
      name: .name,
      nodeLocator: .nodeLocator,
      numVBuckets: (.vBucketServerMap.numVBuckets),
      numReplicas: (.vBucketServerMap.numReplicas),
      serverList: (.vBucketServerMap.serverList)
    }'
```

2. Observa los primeros 10 vBuckets y su asignación a nodos (activo + réplica):

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/b/travel-sample \
  | jq '.vBucketServerMap.vBucketMap[0:10]'
```

3. Cuenta cuántos vBuckets activos (posición 0 del array) están asignados a cada nodo:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/b/travel-sample \
  | jq '
    .vBucketServerMap as $map |
    .vBucketServerMap.vBucketMap |
    group_by(.[0]) |
    map({
      node_index: .[0][0],
      node_hostname: $map.serverList[.[0][0]],
      active_vbuckets: length
    })
  '
```

4. Verifica el total de vBuckets confirmando que suman 1024:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/b/travel-sample \
  | jq '.vBucketServerMap.vBucketMap | length'
```

**Salida esperada:**

```json
{
  "name": "travel-sample",
  "nodeLocator": "vbucket",
  "numVBuckets": 1024,
  "numReplicas": 1,
  "serverList": [
    "cb-node1:11210",
    "cb-node1:11210"
  ]
}
```

> **Nota:** En un clúster de 3 nodos donde solo cb-node1 tiene el servicio Data (kv), todos los vBuckets activos residirán en cb-node1. Esto es esperado y correcto con la configuración MDS actual.

El array de vBuckets tendrá el formato `[activo, replica1]` donde cada número es el índice en `serverList`:

```json
[0, -1],  // vBucket 0: activo en nodo 0, sin réplica asignada aún
[0, -1],  // vBucket 1: activo en nodo 0
...
```

**Verificación:**

```bash
# El total debe ser exactamente 1024
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/b/travel-sample \
  | jq '.vBucketServerMap.vBucketMap | length'
# Resultado esperado: 1024
```

---

### Paso 8: Análisis detallado de la topología con couchbase-cli

**Objetivo:** Utilizar las herramientas CLI nativas de Couchbase para obtener una visión estructurada de la topología, complementando los datos crudos de la REST API con información legible para operaciones.

**Instrucciones:**

1. Lista todos los nodos con sus servicios y estado:

```bash
docker exec cb-node1 couchbase-cli server-list \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd!
```

2. Obtén información detallada de cada nodo individual:

```bash
# Información del nodo 1 (Data + Query)
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/nodes \
  | jq '[.nodes[] | {
      hostname: .hostname,
      version: .version,
      os: .os,
      services: .services,
      status: .status,
      memoryTotal: .memoryTotal,
      memoryFree: .memoryFree,
      cpuCount: .cpuCoresAvailable
    }]'
```

3. Consulta las estadísticas de bucket por nodo para ver la distribución real:

```bash
curl -s -u Administrator:Passw0rd! \
  "http://localhost:8091/pools/default/buckets/travel-sample/stats" \
  | jq '{
      samplesCount: .op.samplesCount,
      lastTStamp: .op.lastTStamp,
      interval: .op.interval
    }'
```

4. Verifica la configuración de replicación del bucket:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '{
      name: .name,
      replicaNumber: .replicaNumber,
      replicaIndex: .replicaIndex,
      threadsNumber: .threadsNumber,
      ramQuota: .quota.rawRAM,
      bucketType: .bucketType
    }'
```

5. Examina el estado de los servicios activos en cada nodo usando el endpoint de nodos:

```bash
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '[.nodes[] | {
      node: .hostname,
      services: .services,
      interestingStats: {
        curr_items: .interestingStats.curr_items,
        vb_active_num: .interestingStats.vb_active_num,
        vb_replica_num: .interestingStats.vb_replica_num
      }
    }]'
```

**Salida esperada del paso 1:**

```
ns_1@cb-node1  cb-node1:8091  healthy  active
ns_1@cb-node2  cb-node2:8091  healthy  active
ns_1@cb-node3  cb-node3:8091  healthy  active
```

**Salida esperada del paso 5 (fragmento):**

```json
[
  {
    "node": "cb-node1:8091",
    "services": ["kv", "n1ql"],
    "interestingStats": {
      "curr_items": 63288,
      "vb_active_num": 1024,
      "vb_replica_num": 0
    }
  },
  {
    "node": "cb-node2:8091",
    "services": ["fts", "index"],
    "interestingStats": {
      "curr_items": 0,
      "vb_active_num": 0,
      "vb_replica_num": 0
    }
  },
  {
    "node": "cb-node3:8091",
    "services": ["cbas", "eventing"],
    "interestingStats": {
      "curr_items": 0,
      "vb_active_num": 0,
      "vb_replica_num": 0
    }
  }
]
```

> **Análisis:** cb-node2 y cb-node3 muestran 0 ítems porque no ejecutan el servicio Data (kv). Esto es correcto en un despliegue MDS donde los nodos de Index, Search, Analytics y Eventing no almacenan documentos directamente.

**Verificación:**

```bash
# Confirmar que cb-node1 tiene todos los vBuckets activos
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default \
  | jq '.nodes[] | select(.services | contains(["kv"])) | {node: .hostname, active_vbuckets: .interestingStats.vb_active_num}'
```

---

### Paso 9: Exploración de la arquitectura mediante la Web Console

**Objetivo:** Correlacionar la información obtenida via CLI y REST API con la visualización gráfica de la Web Console, identificando los elementos arquitectónicos clave en la interfaz de administración.

**Instrucciones:**

1. Abre un navegador y accede a la Web Console del nodo 1:
   ```
   URL: http://localhost:8091
   Usuario: Administrator
   Contraseña: Passw0rd!
   ```

2. En el menú **Servers**, verifica que los tres nodos aparecen con estado verde (*healthy*) y anota los servicios de cada uno en la siguiente tabla:

   | Nodo      | Servicios visibles en la UI | Estado |
   |-----------|----------------------------|--------|
   | cb-node1  |                            |        |
   | cb-node2  |                            |        |
   | cb-node3  |                            |        |

3. Navega a **Buckets** y selecciona `travel-sample`. Observa:
   - El número de ítems activos.
   - La memoria RAM utilizada vs. cuota.
   - El número de réplicas configuradas.

4. Haz clic en **Documents** dentro del bucket `travel-sample` y examina la estructura de 3 documentos de diferentes tipos (airline, airport, route). Anota el patrón de la clave (`_id`).

5. Navega a **Statistics** del bucket y localiza las métricas:
   - `ops/sec` (operaciones por segundo).
   - `resident ratio` (porcentaje de datos en memoria).
   - `disk write queue` (cola de escritura a disco).

6. En la sección **Query**, ejecuta la siguiente consulta para verificar que el servicio Query está operativo:

```sql
SELECT COUNT(*) as total_docs,
       META().id as sample_id
FROM `travel-sample`
LIMIT 1;
```

**Salida esperada de la consulta:**

```json
[
  {
    "sample_id": "airline_10",
    "total_docs": 63288
  }
]
```

**Verificación:**

```bash
# Verificar el servicio Query desde CLI
docker exec cb-node1 cbq \
  --engine http://cb-node1:8093 \
  --credentials Administrator:Passw0rd! \
  --script "SELECT COUNT(*) as total FROM \`travel-sample\`;"
```

---

### Paso 10: Documentación del mapa arquitectónico

**Objetivo:** Sintetizar toda la información recopilada en los pasos anteriores para construir un mapa documentado de la arquitectura observada, aplicando los conceptos de peer-to-peer, cluster map y MDS.

**Instrucciones:**

1. Ejecuta el siguiente script para generar un reporte completo de la topología:

```bash
cat << 'EOF' > ~/lab-01-00-01/topology-report.sh
#!/bin/bash
# Script de reporte de topología - Lab 01-00-01

CB_HOST="http://localhost:8091"
CB_AUTH="Administrator:Passw0rd!"

echo "========================================"
echo "REPORTE DE TOPOLOGÍA - CLÚSTER COUCHBASE"
echo "Fecha: $(date)"
echo "========================================"

echo ""
echo "--- 1. INFORMACIÓN DEL CLÚSTER ---"
curl -s -u $CB_AUTH $CB_HOST/pools/default \
  | jq '{
      clusterName: .clusterName,
      rebalanceStatus: .rebalanceStatus,
      totalNodes: (.nodes | length),
      clusterVersion: .nodes[0].version
    }'

echo ""
echo "--- 2. NODOS Y SERVICIOS (MDS) ---"
curl -s -u $CB_AUTH $CB_HOST/pools/default \
  | jq '[.nodes[] | {
      hostname: .hostname,
      services: .services,
      status: .status,
      membership: .clusterMembership,
      memoryTotal_GB: (.memoryTotal / 1073741824 | round)
    }]'

echo ""
echo "--- 3. DISTRIBUCIÓN DE vBUCKETS (travel-sample) ---"
curl -s -u $CB_AUTH $CB_HOST/pools/default/b/travel-sample \
  | jq '{
      totalVBuckets: .vBucketServerMap.numVBuckets,
      numReplicas: .vBucketServerMap.numReplicas,
      serverList: .vBucketServerMap.serverList,
      nodeLocator: .nodeLocator
    }'

echo ""
echo "--- 4. ESTADÍSTICAS DEL BUCKET ---"
curl -s -u $CB_AUTH $CB_HOST/pools/default/buckets/travel-sample \
  | jq '{
      name: .name,
      itemCount: .basicStats.itemCount,
      memUsed_MB: (.basicStats.memUsed / 1048576 | round),
      diskUsed_MB: (.basicStats.diskUsed / 1048576 | round),
      replicaNumber: .replicaNumber
    }'

echo ""
echo "--- 5. ANÁLISIS PEER-TO-PEER: CLUSTER MAP DISPONIBLE ---"
echo "El SDK utiliza el endpoint /pools/default/b/{bucket} para enrutar solicitudes."
echo "Algoritmo: CRC32(document_key) mod 1024 = vBucket_ID"
echo "El vBucketMap mapea vBucket_ID -> [nodo_activo, nodo_replica]"
curl -s -u $CB_AUTH $CB_HOST/pools/default/b/travel-sample \
  | jq '.vBucketServerMap.vBucketMap[0:5] | 
    to_entries | 
    map({vbucket_id: .key, active_node_idx: .value[0], replica_node_idx: .value[1]})'

echo ""
echo "========================================"
echo "FIN DEL REPORTE"
echo "========================================"
EOF

chmod +x ~/lab-01-00-01/topology-report.sh
bash ~/lab-01-00-01/topology-report.sh | tee ~/lab-01-00-01/topology-output.txt
```

2. Revisa el archivo generado:

```bash
cat ~/lab-01-00-01/topology-output.txt
```

3. Basándote en el reporte, completa la siguiente tabla de arquitectura en tu cuaderno o documento de laboratorio:

   | Componente          | Nodo(s)   | Puerto(s) | Función en la arquitectura                          |
   |---------------------|-----------|-----------|-----------------------------------------------------|
   | Data Service (kv)   | cb-node1  | 11210     | Almacenamiento de documentos y gestión de vBuckets  |
   | Query Service (n1ql)| cb-node1  | 8093      | Procesamiento de consultas SQL++                    |
   | Index Service       | cb-node2  | 8094      | Mantenimiento de índices secundarios GSI            |
   | Search Service (fts)| cb-node2  | 8094      | Búsqueda full-text con índices FTS                  |
   | Analytics Service   | cb-node3  | 8095      | Consultas analíticas OLAP con CBAS                  |
   | Eventing Service    | cb-node3  | 8096      | Procesamiento de eventos basado en funciones JS     |
   | Cluster Manager     | Todos     | 8091      | Coordinación, cluster map, REST API, Web Console    |

4. Verifica el algoritmo de hash que usa Couchbase para mapear claves a vBuckets:

```python
# Ejecuta este script Python para entender el hash de vBuckets
python3 << 'PYEOF'
import binascii

def get_vbucket(key: str, num_vbuckets: int = 1024) -> int:
    """Calcula el vBucket ID para una clave dada usando CRC32."""
    crc = binascii.crc32(key.encode('utf-8')) & 0xFFFFFFFF
    vbucket_id = crc % num_vbuckets
    return vbucket_id

# Ejemplos con documentos reales de travel-sample
test_keys = [
    "airline_10",
    "airline_10123",
    "airport_1254",
    "airport_3577",
    "route_10000",
    "hotel_10025"
]

print("Distribución de claves a vBuckets (CRC32 mod 1024):")
print(f"{'Clave':<25} {'vBucket ID':>12}")
print("-" * 40)
for key in test_keys:
    vb = get_vbucket(key)
    print(f"{key:<25} {vb:>12}")

print(f"\nTotal vBuckets posibles: 1024")
print("El SDK usa este mismo algoritmo para enrutar directamente al nodo correcto.")
PYEOF
```

**Salida esperada del script Python:**

```
Distribución de claves a vBuckets (CRC32 mod 1024):
Clave                     vBucket ID
----------------------------------------
airline_10                       347
airline_10123                    892
airport_1254                     156
airport_3577                     743
route_10000                      521
hotel_10025                      238

Total vBuckets posibles: 1024
El SDK usa este mismo algoritmo para enrutar directamente al nodo correcto.
```

**Verificación:**

```bash
# Confirmar que el reporte fue generado correctamente
wc -l ~/lab-01-00-01/topology-output.txt
# Debe tener al menos 40 líneas de contenido
```

---

## Validación y Pruebas Finales

Ejecuta la siguiente batería de verificaciones para confirmar que el laboratorio fue completado exitosamente:

```bash
cat << 'EOF' > ~/lab-01-00-01/validate.sh
#!/bin/bash
# Script de validación - Lab 01-00-01
PASS=0
FAIL=0
CB_HOST="http://localhost:8091"
CB_AUTH="Administrator:Passw0rd!"

check() {
  local desc="$1"
  local result="$2"
  local expected="$3"
  if [ "$result" = "$expected" ]; then
    echo "  ✅ PASS: $desc"
    ((PASS++))
  else
    echo "  ❌ FAIL: $desc (obtenido='$result', esperado='$expected')"
    ((FAIL++))
  fi
}

echo "=============================="
echo "VALIDACIÓN - Lab 01-00-01"
echo "=============================="

echo ""
echo "[1] Verificando número de nodos..."
NODE_COUNT=$(curl -s -u $CB_AUTH $CB_HOST/pools/default | jq '.nodes | length')
check "Clúster tiene 3 nodos" "$NODE_COUNT" "3"

echo ""
echo "[2] Verificando estado de nodos..."
HEALTHY=$(curl -s -u $CB_AUTH $CB_HOST/pools/default | jq '[.nodes[].status] | map(select(. == "healthy")) | length')
check "Los 3 nodos están healthy" "$HEALTHY" "3"

echo ""
echo "[3] Verificando servicios en cb-node1 (kv + n1ql)..."
NODE1_SERVICES=$(curl -s -u $CB_AUTH $CB_HOST/pools/default \
  | jq -r '.nodes[] | select(.hostname | startswith("cb-node1")) | .services | sort | join(",")')
check "cb-node1 tiene kv,n1ql" "$NODE1_SERVICES" "kv,n1ql"

echo ""
echo "[4] Verificando servicios en cb-node2 (fts + index)..."
NODE2_SERVICES=$(curl -s -u $CB_AUTH $CB_HOST/pools/default \
  | jq -r '.nodes[] | select(.hostname | startswith("cb-node2")) | .services | sort | join(",")')
check "cb-node2 tiene fts,index" "$NODE2_SERVICES" "fts,index"

echo ""
echo "[5] Verificando servicios en cb-node3 (cbas + eventing)..."
NODE3_SERVICES=$(curl -s -u $CB_AUTH $CB_HOST/pools/default \
  | jq -r '.nodes[] | select(.hostname | startswith("cb-node3")) | .services | sort | join(",")')
check "cb-node3 tiene cbas,eventing" "$NODE3_SERVICES" "cbas,eventing"

echo ""
echo "[6] Verificando bucket travel-sample..."
BUCKET_EXISTS=$(curl -s -u $CB_AUTH $CB_HOST/pools/default/buckets/travel-sample | jq -r '.name')
check "Bucket travel-sample existe" "$BUCKET_EXISTS" "travel-sample"

echo ""
echo "[7] Verificando número de vBuckets..."
VBUCKETS=$(curl -s -u $CB_AUTH $CB_HOST/pools/default/b/travel-sample \
  | jq '.vBucketServerMap.numVBuckets')
check "Travel-sample tiene 1024 vBuckets" "$VBUCKETS" "1024"

echo ""
echo "[8] Verificando documentos cargados..."
ITEM_COUNT=$(curl -s -u $CB_AUTH $CB_HOST/pools/default/buckets/travel-sample \
  | jq '.basicStats.itemCount')
if [ "$ITEM_COUNT" -ge 60000 ] 2>/dev/null; then
  echo "  ✅ PASS: Travel-sample tiene $ITEM_COUNT documentos (>= 60000)"
  ((PASS++))
else
  echo "  ❌ FAIL: Travel-sample tiene $ITEM_COUNT documentos (esperado >= 60000)"
  ((FAIL++))
fi

echo ""
echo "[9] Verificando rebalanceo completado..."
REBALANCE=$(curl -s -u $CB_AUTH $CB_HOST/pools/default | jq -r '.rebalanceStatus')
check "Rebalanceo completado (status=none)" "$REBALANCE" "none"

echo ""
echo "[10] Verificando servicio Query operativo..."
QUERY_RESULT=$(docker exec cb-node1 cbq \
  --engine http://cb-node1:8093 \
  --credentials Administrator:Passw0rd! \
  --script "SELECT 1+1 AS result;" 2>/dev/null \
  | jq -r '.results[0].result' 2>/dev/null)
check "Servicio Query responde correctamente" "$QUERY_RESULT" "2"

echo ""
echo "=============================="
echo "RESULTADO: $PASS PASS / $FAIL FAIL"
echo "=============================="
if [ $FAIL -eq 0 ]; then
  echo "🎉 Laboratorio completado exitosamente."
else
  echo "⚠️  Revisa los ítems fallidos antes de continuar."
fi
EOF

chmod +x ~/lab-01-00-01/validate.sh
bash ~/lab-01-00-01/validate.sh
```

**Resultado esperado:** `10 PASS / 0 FAIL`

---

## Resolución de Problemas

### Problema 1: El contenedor cb-node2 o cb-node3 no puede ser agregado al clúster

**Síntoma:**
```
ERROR: Unable to add node. Reason: Unknown server error
```
O el comando `server-add` devuelve un error de conexión rechazada.

**Causa:**
Los contenedores Docker usan nombres de host (`cb-node2`, `cb-node3`) para la resolución DNS interna de la red Docker. Si el comando `server-add` se ejecuta desde fuera del contenedor (usando `localhost`), el nombre `cb-node2` no resuelve. Adicionalmente, el contenedor puede no estar completamente inicializado cuando se ejecuta el comando.

**Solución:**

```bash
# 1. Verificar que los contenedores están en la misma red Docker
docker network inspect lab-01-00-01_cb-net \
  | jq '[.[0].Containers[] | {name: .Name, ip: .IPv4Address}]'

# 2. Verificar resolución DNS desde dentro del contenedor cb-node1
docker exec cb-node1 ping -c 2 cb-node2
docker exec cb-node1 ping -c 2 cb-node3

# 3. Si el ping falla, reinicia los contenedores y espera 45 segundos
docker compose restart
sleep 45

# 4. Verificar que el puerto 8091 de cb-node2 responde DESDE cb-node1
docker exec cb-node1 curl -s http://cb-node2:8091/ui/index.html -o /dev/null \
  -w "HTTP Status desde cb-node1: %{http_code}\n"

# 5. Reintentar el server-add usando la IP interna si el nombre no resuelve
CB_NODE2_IP=$(docker inspect cb-node2 \
  --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "IP de cb-node2: $CB_NODE2_IP"

docker exec cb-node1 couchbase-cli server-add \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --server-add http://${CB_NODE2_IP}:8091 \
  --server-add-username Administrator \
  --server-add-password Passw0rd! \
  --services index,fts
```

---

### Problema 2: El dataset travel-sample muestra 0 documentos o el bucket está en estado `warmup`

**Síntoma:**
```json
{ "itemCount": 0, "diskUsed": 0 }
```
O la consulta SQL++ devuelve `"total_docs": 0` a pesar de que la carga aparentemente terminó.

**Causa:**
El bucket puede estar en fase de **warmup** (calentamiento), que es el proceso mediante el cual Couchbase carga los datos del disco a memoria después de un reinicio o creación del bucket. Este proceso puede tomar varios minutos dependiendo del volumen de datos y los recursos disponibles. También puede ocurrir que `cbdocloader` haya fallado silenciosamente.

**Solución:**

```bash
# 1. Verificar el estado actual del bucket
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '{name: .name, status: .nodes[0].status, itemCount: .basicStats.itemCount}'

# 2. Si el estado es "warmup", esperar y monitorear
watch -n 5 'curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq "{status: .nodes[0].status, itemCount: .basicStats.itemCount}"'

# 3. Verificar si cbdocloader completó sin errores
docker exec cb-node1 bash -c \
  "ls -la /opt/couchbase/samples/travel-sample.zip"

# 4. Si el archivo de sample existe, recargar usando la Web Console
# Navega a: http://localhost:8091 → Settings → Sample Buckets
# Si travel-sample ya está cargado, elimínalo primero y recárgalo:
curl -s -u Administrator:Passw0rd! \
  -X DELETE http://localhost:8091/pools/default/buckets/travel-sample

sleep 10

# Recrear el bucket y recargar
docker exec cb-node1 couchbase-cli bucket-create \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --bucket travel-sample \
  --bucket-type couchbase \
  --bucket-ramsize 512 \
  --bucket-replica 1

sleep 5

docker exec cb-node1 cbdocloader \
  --cluster http://cb-node1:8091 \
  --username Administrator \
  --password Passw0rd! \
  --bucket travel-sample \
  --dataset /opt/couchbase/samples/travel-sample.zip \
  --threads 2

# 5. Verificar que los datos se cargaron correctamente
sleep 30
curl -s -u Administrator:Passw0rd! \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '.basicStats.itemCount'
```

---

## Limpieza del Entorno

Una vez completado el laboratorio, puedes limpiar los recursos Docker para liberar memoria y almacenamiento:

```bash
cd ~/lab-01-00-01

# Opción 1: Detener los contenedores (conserva los volúmenes para labs futuros)
# RECOMENDADO si continuarás con los Labs 2, 3 y 4 en la misma sesión
docker compose stop

# Opción 2: Detener y eliminar contenedores (conserva volúmenes)
docker compose down

# Opción 3: Limpieza completa incluyendo volúmenes (solo si no continuarás con labs dependientes)
# ADVERTENCIA: Esto elimina todos los datos del clúster
docker compose down -v

# Verificar que los contenedores fueron detenidos
docker compose ps

# Liberar la imagen si no se usará más (opcional)
# docker rmi couchbase/server:enterprise-7.6.2
```

> **⚠️ Nota importante:** Los Labs 2, 3 y 4 están diseñados con dependencia secuencial sobre este clúster. Si planeas continuar con ellos en la misma sesión, usa **Opción 1** (`docker compose stop`) para conservar el estado del clúster.

---

## Resumen

En este laboratorio has completado un análisis arquitectónico end-to-end de un clúster Couchbase de 3 nodos:

| Actividad realizada                        | Concepto reforzado                              |
|--------------------------------------------|--------------------------------------------------|
| Despliegue con Docker Compose              | Reproducibilidad y configuración declarativa     |
| Configuración MDS con servicios separados  | Multidimensional Scaling y separación de planos  |
| Análisis del cluster map via REST API      | Arquitectura peer-to-peer y enrutamiento directo |
| Exploración de los 1024 vBuckets           | Particionamiento consistente del espacio de claves|
| Script de hash CRC32 → vBucket             | Algoritmo de distribución de datos               |
| Reporte de topología automatizado          | Observabilidad operacional y documentación       |

### Conceptos clave aplicados

- **Peer-to-peer sin maestro permanente:** el Cluster Manager coordina sin punto único de fallo; el cluster map permite enrutamiento directo desde el SDK.
- **vBuckets como unidad de distribución:** 1024 particiones virtuales asignadas a nodos físicos mediante CRC32, rebalanceables sin downtime.
- **Multidimensional Scaling (MDS):** cada servicio (Data, Query, Index, Search, Analytics, Eventing) puede asignarse a nodos dedicados para optimizar recursos independientemente.
- **REST API como fuente de verdad:** el endpoint `/pools/default` y `/pools/default/b/{bucket}` exponen el estado completo del clúster y el cluster map que usa el SDK.

### Recursos adicionales

- [Couchbase Architecture Overview](https://docs.couchbase.com/server/current/learn/architecture-overview.html)
- [vBuckets y distribución de datos](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/vbuckets.html)
- [Multidimensional Scaling](https://docs.couchbase.com/server/current/learn/services-and-indexes/services/services.html)
- [REST API de administración](https://docs.couchbase.com/server/current/rest-api/rest-cluster-intro.html)
- [couchbase-cli server-list](https://docs.couchbase.com/server/current/cli/cbcli/couchbase-cli-server-list.html)

---
