# Simulación de fallos y recuperación entre clústeres

## Metadatos

| Campo         | Valor                                      |
|---------------|--------------------------------------------|
| **Duración**  | 78 minutos                                 |
| **Complejidad** | Alta                                     |
| **Nivel Bloom** | Aplicar (Apply)                          |
| **Versión CB** | Couchbase Server Enterprise Edition 7.6.x |

---

## Descripción General

En este laboratorio operarás dos clústeres Couchbase (Clúster A: 3 nodos, Clúster B: 2 nodos) que simulan una arquitectura multi-región. Ejecutarás y compararás los tres tipos de failover —graceful, manual y automático— analizando el impacto en disponibilidad y pérdida de datos medido por los sequence numbers de DCP. Configurarás Server Groups con Zone Awareness para que las réplicas de vBuckets nunca compartan zona, implementarás XDCR bidireccional con filtrado de documentos y provocarás conflictos de escritura simultánea para observar la resolución por timestamp y por número de secuencia. Finalmente documentarás un runbook de Disaster Recovery con valores reales de RPO y RTO medidos durante la práctica.

---

## Objetivos de Aprendizaje

Al completar este laboratorio, el estudiante será capaz de:

- [ ] Ejecutar y comparar los tres tipos de failover (graceful, manual y automático) evaluando el impacto en disponibilidad y pérdida de datos según los sequence numbers de DCP.
- [ ] Configurar Server Groups con Zone Awareness en el Clúster A y verificar que las réplicas de vBuckets se distribuyen entre zonas distintas.
- [ ] Implementar XDCR bidireccional con filtros de replicación por expresión regular y analizar la resolución de conflictos bajo escrituras simultáneas.
- [ ] Documentar un runbook de DR con objetivos RPO ≤ 5 min y RTO ≤ 10 min verificados con mediciones reales del laboratorio.

---

## Prerrequisitos

### Conocimiento previo

- Labs **01-00-01** y **08-00-01** completados satisfactoriamente.
- Comprensión de vBuckets, réplicas y el protocolo DCP (Lección 9.1).
- Familiaridad con conceptos de HA: quorum, failover, rebalanceo.
- Conocimiento de los conceptos RPO (*Recovery Point Objective*) y RTO (*Recovery Time Objective*).

### Acceso y herramientas

- Docker Engine 24.x y Docker Compose instalados en la máquina host.
- Acceso a `couchbase-cli`, `curl` y `jq` desde la terminal.
- Licencia de evaluación Enterprise Edition activa (necesaria para XDCR).
- Puerto 8091–8096 y 11210 disponibles en localhost.

---

## Entorno de Laboratorio

### Topología objetivo

```
┌─────────────────────────────────────────┐     XDCR Bidireccional     ┌───────────────────────────────┐
│           CLÚSTER A (multi-zona)        │ ◄─────────────────────────► │       CLÚSTER B (DR)          │
│  cb-a1 (zona-1) | cb-a2 (zona-1)        │                             │  cb-b1 (nodo1)                │
│  cb-a3 (zona-2)                         │                             │  cb-b2 (nodo2)                │
└─────────────────────────────────────────┘                             └───────────────────────────────┘
```

### Tabla de recursos

| Componente        | CPU  | RAM  | Imagen Docker                          |
|-------------------|------|------|----------------------------------------|
| cb-a1, cb-a2, cb-a3 | 2 vCPU | 2 GB | `couchbase/server:enterprise-7.6.2` |
| cb-b1, cb-b2      | 2 vCPU | 2 GB | `couchbase/server:enterprise-7.6.2` |

### Archivo `docker-compose.yml`

Crea el directorio de trabajo y el archivo de composición:

```bash
mkdir -p ~/lab09 && cd ~/lab09
```

```yaml
# ~/lab09/docker-compose.yml
version: "3.8"

networks:
  cluster-a-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
  cluster-b-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.21.0.0/24

services:
  # ── Clúster A ──────────────────────────────────────────────────────────────
  cb-a1:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-a1
    hostname: cb-a1
    networks:
      cluster-a-net:
        ipv4_address: 172.20.0.11
    ports:
      - "8091:8091"
      - "11210:11210"
    ulimits:
      nofile: { soft: 40960, hard: 40960 }

  cb-a2:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-a2
    hostname: cb-a2
    networks:
      cluster-a-net:
        ipv4_address: 172.20.0.12
    ulimits:
      nofile: { soft: 40960, hard: 40960 }

  cb-a3:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-a3
    hostname: cb-a3
    networks:
      cluster-a-net:
        ipv4_address: 172.20.0.13
    ulimits:
      nofile: { soft: 40960, hard: 40960 }

  # ── Clúster B ──────────────────────────────────────────────────────────────
  cb-b1:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-b1
    hostname: cb-b1
    networks:
      cluster-b-net:
        ipv4_address: 172.21.0.11
      cluster-a-net:
        ipv4_address: 172.20.0.21
    ports:
      - "8092:8091"
    ulimits:
      nofile: { soft: 40960, hard: 40960 }

  cb-b2:
    image: couchbase/server:enterprise-7.6.2
    container_name: cb-b2
    hostname: cb-b2
    networks:
      cluster-b-net:
        ipv4_address: 172.21.0.12
    ulimits:
      nofile: { soft: 40960, hard: 40960 }
```

```bash
# Levantar todos los contenedores
docker compose up -d

# Esperar ~45 segundos a que los servicios arranquen
sleep 45

# Verificar que los 5 contenedores están en estado "Up"
docker compose ps
```

---

## Procedimiento Paso a Paso

---

### Parte 1 — Server Groups y Tipos de Failover (≈35 min)

---

#### Paso 1.1 — Inicializar el Clúster A

**Objetivo:** Crear el Clúster A con tres nodos, configurar el bucket `lab09` con 1 réplica y cargar datos de prueba.

**Instrucciones:**

1. Inicializa el nodo primario `cb-a1`:

```bash
couchbase-cli cluster-init \
  --cluster http://172.20.0.11:8091 \
  --cluster-name "ClusterA" \
  --cluster-username admin \
  --cluster-password Admin123! \
  --cluster-ramsize 1024 \
  --cluster-index-ramsize 256 \
  --services data,index,query
```

2. Agrega `cb-a2` al Clúster A:

```bash
couchbase-cli server-add \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-add http://172.20.0.12:8091 \
  --server-add-username admin \
  --server-add-password Admin123! \
  --services data,index,query
```

3. Agrega `cb-a3` al Clúster A:

```bash
couchbase-cli server-add \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-add http://172.20.0.13:8091 \
  --server-add-username admin \
  --server-add-password Admin123! \
  --services data,index,query
```

4. Ejecuta el rebalanceo inicial:

```bash
couchbase-cli rebalance \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

5. Crea el bucket `lab09` con **1 réplica**:

```bash
couchbase-cli bucket-create \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --bucket lab09 \
  --bucket-type couchbase \
  --bucket-ramsize 512 \
  --bucket-replica 1 \
  --enable-flush 1
```

6. Carga documentos de prueba con `cbworkloadgen`:

```bash
# Genera 50,000 documentos en el bucket lab09
cbworkloadgen \
  -n 172.20.0.11:8091 \
  -u admin -p Admin123! \
  -b lab09 \
  -i 50000 \
  --prefix "doc::" \
  -j
```

**Salida esperada:**

```
SUCCESS: Cluster initialized
SUCCESS: Server added
SUCCESS: Server added
Rebalance complete
SUCCESS: Bucket created
[=====] 100%  50000/50000 docs loaded
```

**Verificación:**

```bash
# Confirmar 3 nodos activos y 50K documentos
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/buckets/lab09 \
  | jq '{itemCount: .basicStats.itemCount, replicaNumber: .replicaNumber}'
```

Resultado esperado: `itemCount: 50000`, `replicaNumber: 1`.

---

#### Paso 1.2 — Configurar Server Groups (Zone Awareness)

**Objetivo:** Crear los grupos `zona-1` y `zona-2` en el Clúster A y asignar nodos para que las réplicas respeten la distribución entre zonas.

**Instrucciones:**

1. Obtén el ID del grupo por defecto y crea los nuevos grupos mediante la REST API:

```bash
# Listar grupos existentes
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/serverGroups \
  | jq '.groups[] | {name: .name, uri: .uri}'
```

2. Crea el grupo `zona-1`:

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'name=zona-1' \
  http://172.20.0.11:8091/pools/default/serverGroups
```

3. Crea el grupo `zona-2`:

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'name=zona-2' \
  http://172.20.0.11:8091/pools/default/serverGroups
```

4. Obtén los URIs actualizados de los grupos para asignar nodos:

```bash
# Guarda la respuesta completa para extraer URIs
GROUPS_JSON=$(curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/serverGroups)

echo $GROUPS_JSON | jq '.groups[] | {name: .name, uri: .uri, nodes: [.nodes[].hostname]}'
```

5. Construye el payload de asignación. Asigna `cb-a1` y `cb-a2` a `zona-1`, y `cb-a3` a `zona-2`. Primero obtén el `rev` y los URIs:

```bash
# Script de asignación de grupos
# Extrae URIs de grupos
URI_ZONA1=$(echo $GROUPS_JSON | jq -r '.groups[] | select(.name=="zona-1") | .uri')
URI_ZONA2=$(echo $GROUPS_JSON | jq -r '.groups[] | select(.name=="zona-2") | .uri')
REV=$(echo $GROUPS_JSON | jq -r '.uri' | grep -oP 'rev=\K[^&]+')

echo "URI zona-1: $URI_ZONA1"
echo "URI zona-2: $URI_ZONA2"
echo "Revision: $REV"
```

6. Aplica la asignación de nodos a grupos (usa el URI con rev):

```bash
# Construye el payload JSON de asignación
ASSIGN_PAYLOAD=$(cat <<EOF
{
  "groups": [
    {
      "uri": "${URI_ZONA1}",
      "nodes": [
        {"otpNode": "ns_1@cb-a1"},
        {"otpNode": "ns_1@cb-a2"}
      ]
    },
    {
      "uri": "${URI_ZONA2}",
      "nodes": [
        {"otpNode": "ns_1@cb-a3"}
      ]
    }
  ]
}
EOF
)

# Aplica la asignación
curl -s -X PUT \
  -u admin:Admin123! \
  -H "Content-Type: application/json" \
  -d "$ASSIGN_PAYLOAD" \
  "http://172.20.0.11:8091/pools/default/serverGroups?$(echo $GROUPS_JSON | jq -r '.uri' | sed 's|/pools/default/serverGroups?||')"
```

7. Ejecuta rebalanceo para que Zone Awareness redistribuya las réplicas:

```bash
couchbase-cli rebalance \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

**Verificación:**

```bash
# Verifica distribución de grupos
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/serverGroups \
  | jq '.groups[] | {grupo: .name, nodos: [.nodes[].hostname]}'
```

Resultado esperado:
```json
{"grupo": "zona-1", "nodos": ["cb-a1", "cb-a2"]}
{"grupo": "zona-2", "nodos": ["cb-a3"]}
```

> **Concepto clave:** Con Zone Awareness activo, Couchbase garantiza que el vBucket activo y su réplica nunca residan en la misma zona. Si `cb-a1` falla, la réplica en `cb-a3` (zona-2) promueve a activo sin perder datos.

---

#### Paso 1.3 — Graceful Failover y Reintegración

**Objetivo:** Ejecutar un graceful failover del nodo `cb-a2`, observar el comportamiento del clúster y reintegrar el nodo sin pérdida de datos.

**Instrucciones:**

1. Registra el timestamp de inicio para medir el RTO:

```bash
T_GRACEFUL_START=$(date +%s)
echo "Inicio graceful failover: $(date)"
```

2. Ejecuta el graceful failover de `cb-a2`:

```bash
couchbase-cli failover \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-failover http://172.20.0.12:8091 \
  --no-progress-bar
```

> El graceful failover transfiere activamente los vBuckets activos de `cb-a2` a otros nodos **antes** de marcarlo como caído. Esto garantiza **cero pérdida de datos** y **cero interrupción del servicio** durante el proceso.

3. Observa el estado del clúster mientras ocurre el failover:

```bash
# Monitorea el estado de los nodos cada 3 segundos
for i in {1..5}; do
  curl -s -u admin:Admin123! \
    http://172.20.0.11:8091/pools/default \
    | jq '.nodes[] | {hostname: .hostname, status: .status, clusterMembership: .clusterMembership}'
  echo "--- $(date) ---"
  sleep 3
done
```

4. Registra el tiempo de recuperación:

```bash
T_GRACEFUL_END=$(date +%s)
RTO_GRACEFUL=$((T_GRACEFUL_END - T_GRACEFUL_START))
echo "RTO Graceful Failover: ${RTO_GRACEFUL} segundos"
```

5. Verifica que los datos siguen accesibles (0 errores):

```bash
cbworkloadgen \
  -n 172.20.0.11:8091 \
  -u admin -p Admin123! \
  -b lab09 \
  -i 1000 \
  --prefix "post-graceful::" \
  -j
```

6. Reintegra `cb-a2` al clúster:

```bash
# Marca el nodo como listo para reincorporarse
couchbase-cli recovery \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-recovery http://172.20.0.12:8091 \
  --recovery-type full

# Rebalancea para reintegrar el nodo
couchbase-cli rebalance \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

**Salida esperada:**

```
SUCCESS: Server failed over
SUCCESS: Server recovered
Rebalance complete
```

**Verificación:**

```bash
# Los 3 nodos deben estar en estado "active" y "active" en clusterMembership
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default \
  | jq '.nodes[] | {hostname: .hostname, status: .status, membership: .clusterMembership}'
```

---

#### Paso 1.4 — Failover Manual de Nodo Caído

**Objetivo:** Simular un fallo catastrófico deteniendo el contenedor `cb-a3` y ejecutar un failover manual, analizando la posible pérdida de datos mediante sequence numbers.

**Instrucciones:**

1. Registra el high seqno antes del fallo:

```bash
# Captura sequence numbers actuales del bucket
curl -s -u admin:Admin123! \
  "http://172.20.0.11:8091/pools/default/buckets/lab09/stats" \
  | jq '.op.samples | {
      ep_dcp_replica_items_remaining: .ep_dcp_replica_items_remaining[-1],
      vb_replica_curr_items: .vb_replica_curr_items[-1]
    }'
```

2. Simula el fallo catastrófico deteniendo el contenedor:

```bash
T_MANUAL_START=$(date +%s)
echo "Simulando fallo catastrófico de cb-a3: $(date)"
docker stop cb-a3
```

3. Espera 10 segundos y confirma que el nodo es inaccesible:

```bash
sleep 10
curl -s --connect-timeout 3 http://172.20.0.13:8091/pools/default \
  && echo "NODO ACCESIBLE" || echo "NODO INACCESIBLE (esperado)"
```

4. Ejecuta el failover manual (hard failover):

```bash
couchbase-cli failover \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-failover http://172.20.0.13:8091 \
  --force
```

> **Diferencia crítica:** El flag `--force` ejecuta un **hard failover** inmediato. A diferencia del graceful failover, no espera a transferir vBuckets activos; promueve directamente las réplicas disponibles. Si la réplica estaba rezagada (lag de DCP > 0), puede haber pérdida de datos.

5. Mide el RTO del failover manual:

```bash
T_MANUAL_END=$(date +%s)
RTO_MANUAL=$((T_MANUAL_END - T_MANUAL_START))
echo "RTO Manual Failover: ${RTO_MANUAL} segundos"
```

6. Verifica el estado del clúster con 2 nodos activos:

```bash
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default \
  | jq '.nodes[] | select(.clusterMembership == "active") | {hostname: .hostname, status: .status}'
```

7. Reinicia el contenedor y reintegra con recuperación delta:

```bash
docker start cb-a3
sleep 30  # Espera a que el servicio Couchbase arranque dentro del contenedor

# Usa delta recovery para sincronizar solo los cambios (más rápido que full)
couchbase-cli recovery \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-recovery http://172.20.0.13:8091 \
  --recovery-type delta

couchbase-cli rebalance \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

**Verificación:**

```bash
# Cuenta de documentos debe ser >= 51000 (50K originales + 1K post-graceful)
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/buckets/lab09 \
  | jq '.basicStats.itemCount'
```

---

#### Paso 1.5 — Configurar y Activar Auto-Failover

**Objetivo:** Configurar el auto-failover con quorum mínimo y verificar su activación automática al detener un nodo.

**Instrucciones:**

1. Habilita auto-failover con timeout de 30 segundos y máximo 1 evento:

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'enabled=true&timeout=30&maxCount=1' \
  http://172.20.0.11:8091/settings/autoFailover
```

2. Verifica la configuración aplicada:

```bash
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/settings/autoFailover \
  | jq '{enabled: .enabled, timeout: .timeout, maxCount: .maxCount}'
```

3. Simula el fallo del nodo `cb-a2`:

```bash
T_AUTO_START=$(date +%s)
echo "Deteniendo cb-a2 para activar auto-failover: $(date)"
docker stop cb-a2
```

4. Monitorea los logs del clúster hasta detectar el auto-failover:

```bash
# Observa eventos del clúster cada 5 segundos durante 90 segundos
for i in {1..18}; do
  STATUS=$(curl -s -u admin:Admin123! \
    http://172.20.0.11:8091/pools/default \
    | jq -r '.nodes[] | select(.hostname | contains("cb-a2")) | .clusterMembership')
  echo "$(date +%H:%M:%S) - cb-a2 membership: $STATUS"
  [ "$STATUS" == "inactiveFailed" ] && echo ">>> AUTO-FAILOVER ACTIVADO <<<" && break
  sleep 5
done
```

5. Registra el tiempo de detección y failover:

```bash
T_AUTO_END=$(date +%s)
RTO_AUTO=$((T_AUTO_END - T_AUTO_START))
echo "RTO Auto-Failover (incluyendo timeout): ${RTO_AUTO} segundos"
```

6. Reinicia `cb-a2`, resetea el contador de auto-failover y reintegra:

```bash
docker start cb-a2
sleep 30

# Resetear el contador de auto-failover para permitir futuros eventos
curl -s -X POST \
  -u admin:Admin123! \
  http://172.20.0.11:8091/settings/autoFailover/resetCount

couchbase-cli recovery \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --server-recovery http://172.20.0.12:8091 \
  --recovery-type delta

couchbase-cli rebalance \
  --cluster http://172.20.0.11:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

**Verificación:**

```bash
# Consulta el log de eventos del clúster para confirmar el auto-failover
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/logs \
  | jq '.list[] | select(.text | contains("failover")) | {time: .serverTime, text: .text}' \
  | head -20
```

**Tabla comparativa de tipos de failover** (completa con tus mediciones):

| Tipo de Failover | RTO Medido | Pérdida de Datos | Intervención Manual | Caso de Uso |
|-----------------|------------|------------------|---------------------|-------------|
| Graceful        | ___ seg    | Ninguna          | Sí (iniciado manualmente) | Mantenimiento planificado |
| Manual (--force) | ___ seg   | Posible (lag DCP) | Sí                 | Nodo irrecuperable |
| Auto-Failover   | ~30+x seg  | Posible (lag DCP) | No                 | Fallo no planificado |

---

### Parte 2 — XDCR Bidireccional con Filtrado y Resolución de Conflictos (≈30 min)

---

#### Paso 2.1 — Inicializar el Clúster B

**Objetivo:** Crear el Clúster B con dos nodos y el bucket `lab09` listo para recibir replicación XDCR.

**Instrucciones:**

1. Inicializa el nodo primario `cb-b1`:

```bash
couchbase-cli cluster-init \
  --cluster http://172.20.0.21:8091 \
  --cluster-name "ClusterB-DR" \
  --cluster-username admin \
  --cluster-password Admin123! \
  --cluster-ramsize 1024 \
  --cluster-index-ramsize 256 \
  --services data,index,query
```

2. Agrega `cb-b2` al Clúster B:

```bash
couchbase-cli server-add \
  --cluster http://172.20.0.21:8091 \
  --username admin --password Admin123! \
  --server-add http://172.21.0.12:8091 \
  --server-add-username admin \
  --server-add-password Admin123! \
  --services data

couchbase-cli rebalance \
  --cluster http://172.20.0.21:8091 \
  --username admin --password Admin123! \
  --no-progress-bar
```

3. Crea el bucket `lab09` en el Clúster B (sin réplicas iniciales, 2 nodos):

```bash
couchbase-cli bucket-create \
  --cluster http://172.20.0.21:8091 \
  --username admin --password Admin123! \
  --bucket lab09 \
  --bucket-type couchbase \
  --bucket-ramsize 512 \
  --bucket-replica 1 \
  --enable-flush 1
```

**Verificación:**

```bash
# Verifica que el Clúster B tiene 2 nodos y el bucket lab09 vacío
curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/buckets/lab09 \
  | jq '{itemCount: .basicStats.itemCount, nodes: (.nodes | length)}'
```

---

#### Paso 2.2 — Configurar XDCR Bidireccional

**Objetivo:** Establecer referencias de clúster y crear replicaciones en ambas direcciones con filtros de documentos.

**Instrucciones:**

1. **En Clúster A:** Registra el Clúster B como referencia remota:

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'name=ClusterB-DR&hostname=172.20.0.21:8091&username=admin&password=Admin123!&demandEncryption=0' \
  http://172.20.0.11:8091/pools/default/remoteClusters
```

2. **En Clúster B:** Registra el Clúster A como referencia remota:

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'name=ClusterA&hostname=172.20.0.11:8091&username=admin&password=Admin123!&demandEncryption=0' \
  http://172.20.0.21:8091/pools/default/remoteClusters
```

3. Verifica las referencias creadas en ambos clústeres:

```bash
# Referencias en Clúster A
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/remoteClusters \
  | jq '.[] | {name: .name, hostname: .hostname, valid: .valid}'

# Referencias en Clúster B
curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/remoteClusters \
  | jq '.[] | {name: .name, hostname: .hostname, valid: .valid}'
```

4. **Crea la replicación A → B** con filtro para documentos de tipo `order`:

```bash
# Replica solo documentos cuya clave comience con "order::" o "doc::"
curl -s -X POST \
  -u admin:Admin123! \
  -d 'replicationType=continuous&toBucket=lab09&toCluster=ClusterB-DR&fromBucket=lab09&filterExpression=REGEXP_CONTAINS(META().id, "^(order|doc)::")' \
  http://172.20.0.11:8091/controller/createReplication
```

5. **Crea la replicación B → A** (sin filtro, replica todo):

```bash
curl -s -X POST \
  -u admin:Admin123! \
  -d 'replicationType=continuous&toBucket=lab09&toCluster=ClusterA&fromBucket=lab09' \
  http://172.20.0.21:8091/controller/createReplication
```

6. Captura los IDs de replicación para monitoreo posterior:

```bash
# Lista las replicaciones activas en Clúster A
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/tasks \
  | jq '.[] | select(.type == "xdcr") | {id: .id, status: .status, source: .source, target: .target}'
```

**Verificación:**

```bash
# Espera 30 segundos y verifica que los documentos se replican al Clúster B
sleep 30
curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/buckets/lab09 \
  | jq '.basicStats.itemCount'
```

El conteo debe ser cercano a 51,000 (los documentos con prefijo `doc::` que coinciden con el filtro).

---

#### Paso 2.3 — Generar Conflictos de Escritura Simultánea

**Objetivo:** Provocar conflictos XDCR escribiendo el mismo documento en ambos clústeres simultáneamente y analizar la resolución por timestamp y por número de secuencia.

**Instrucciones:**

1. Crea el script Python de escritura simultánea:

```bash
cat > ~/lab09/conflict_generator.py << 'EOF'
#!/usr/bin/env python3
"""
Generador de conflictos XDCR para Lab 09-00-01
Escribe el mismo documento en Clúster A y Clúster B simultáneamente
"""
import time
import threading
from couchbase.cluster import Cluster
from couchbase.options import ClusterOptions, UpsertOptions
from couchbase.auth import PasswordAuthenticator
from couchbase.durability import DurabilityLevel, ServerDurability

CLUSTER_A = "couchbase://172.20.0.11"
CLUSTER_B = "couchbase://172.20.0.21"
BUCKET    = "lab09"
DOC_KEY   = "conflict::test-001"
RESULTS   = {}

def write_to_cluster(name, connection_string, value_suffix):
    """Escribe un documento en el clúster especificado y registra el CAS resultante"""
    try:
        cluster = Cluster(
            connection_string,
            ClusterOptions(PasswordAuthenticator("admin", "Admin123!"))
        )
        bucket = cluster.bucket(BUCKET)
        col = bucket.default_collection()

        doc = {
            "type": "conflict-test",
            "cluster": name,
            "valor": f"escrito-en-{value_suffix}",
            "timestamp_epoch": time.time(),
            "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%S.") + f"{int(time.time()*1000)%1000:03d}Z"
        }

        result = col.upsert(
            DOC_KEY,
            doc,
            UpsertOptions(durability=ServerDurability(DurabilityLevel.MAJORITY))
        )
        RESULTS[name] = {
            "cas": result.cas,
            "timestamp": doc["timestamp_iso"],
            "valor": doc["valor"]
        }
        print(f"[{name}] Escritura exitosa | CAS: {result.cas} | TS: {doc['timestamp_iso']}")
    except Exception as e:
        print(f"[{name}] Error: {e}")

# Lanza escrituras simultáneas en ambos clústeres
print("=== Generando conflicto XDCR ===")
print(f"Documento clave: {DOC_KEY}")
print(f"Hora de inicio: {time.strftime('%H:%M:%S.%f')}\n")

t_a = threading.Thread(target=write_to_cluster, args=("ClusterA", CLUSTER_A, "cluster-A"))
t_b = threading.Thread(target=write_to_cluster, args=("ClusterB", CLUSTER_B, "cluster-B"))

t_a.start()
t_b.start()
t_a.join()
t_b.join()

print(f"\n=== Resultados de escritura simultánea ===")
for cluster, result in RESULTS.items():
    print(f"{cluster}: CAS={result['cas']}, TS={result['timestamp']}, Valor={result['valor']}")

print("\n[Espera 15s para que XDCR propague y resuelva el conflicto...]")
time.sleep(15)

# Lee el documento ganador en ambos clústeres
for name, conn_str in [("ClusterA", CLUSTER_A), ("ClusterB", CLUSTER_B)]:
    try:
        cluster = Cluster(conn_str, ClusterOptions(PasswordAuthenticator("admin", "Admin123!")))
        col = cluster.bucket(BUCKET).default_collection()
        result = col.get(DOC_KEY)
        print(f"\n[{name}] Documento post-conflicto:")
        print(f"  cluster: {result.content_as[dict].get('cluster')}")
        print(f"  valor:   {result.content_as[dict].get('valor')}")
        print(f"  ts:      {result.content_as[dict].get('timestamp_iso')}")
        print(f"  CAS:     {result.cas}")
    except Exception as e:
        print(f"[{name}] Error leyendo resultado: {e}")
EOF

python3 ~/lab09/conflict_generator.py
```

2. Analiza qué estrategia de resolución de conflictos ganó:

```bash
# Verifica la configuración de conflict resolution del bucket
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/buckets/lab09 \
  | jq '{conflictResolutionType: .conflictResolutionType}'
```

> **Concepto clave:** Couchbase soporta dos estrategias de resolución de conflictos XDCR:
> - **`seqno` (Sequence Number):** Gana la escritura con el número de secuencia más alto. Es el método por defecto y es determinístico.
> - **`lww` (Last Write Wins / Timestamp):** Gana la escritura con el timestamp más reciente. Requiere sincronización de relojes entre clústeres (NTP).

3. Genera múltiples conflictos para estadísticas:

```bash
# Genera 10 conflictos consecutivos y observa el patrón de resolución
for i in {1..10}; do
  # Escribe en Clúster A
  curl -s -X POST \
    -u admin:Admin123! \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"batch-conflict\",\"seq\":$i,\"cluster\":\"A\",\"ts\":$(date +%s%N)}" \
    "http://172.20.0.11:8092/lab09/conflict::batch-$i" &

  # Escribe en Clúster B simultáneamente
  curl -s -X POST \
    -u admin:Admin123! \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"batch-conflict\",\"seq\":$i,\"cluster\":\"B\",\"ts\":$(date +%s%N)}" \
    "http://172.20.0.21:8092/lab09/conflict::batch-$i" &

  wait
done

sleep 20
echo "Conflictos generados. Verificando resolución..."
```

**Verificación:**

```bash
# Verifica métricas XDCR de conflictos resueltos
curl -s -u admin:Admin123! \
  "http://172.20.0.11:8091/pools/default/buckets/lab09/stats" \
  | jq '.op.samples | {
      xdcr_docs_written: .xdcr_docs_written[-3:],
      xdcr_docs_failed_cr_source: .xdcr_docs_failed_cr_source[-3:]
    }'
```

El campo `xdcr_docs_failed_cr_source` indica cuántos documentos perdieron la resolución de conflictos en el lado fuente (fueron sobrescritos por la versión del destino).

---

#### Paso 2.4 — Verificar Filtrado de Replicación

**Objetivo:** Confirmar que el filtro REGEXP aplicado en la replicación A→B funciona correctamente.

**Instrucciones:**

1. Inserta documentos de distintos tipos en el Clúster A:

```bash
# Documentos que SÍ deben replicarse (coinciden con el filtro)
for i in {1..5}; do
  curl -s -X PUT \
    -u admin:Admin123! \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"order\",\"amount\":$((i*100)),\"status\":\"pending\"}" \
    "http://172.20.0.11:8092/lab09/order::filter-test-$i"
done

# Documentos que NO deben replicarse (no coinciden con el filtro)
for i in {1..5}; do
  curl -s -X PUT \
    -u admin:Admin123! \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"internal\",\"data\":\"config-$i\"}" \
    "http://172.20.0.11:8092/lab09/internal::config-$i"
done

echo "Documentos insertados. Esperando replicación XDCR (30s)..."
sleep 30
```

2. Verifica qué documentos llegaron al Clúster B:

```bash
# Consulta SQL++ en Clúster B para verificar filtrado
curl -s -u admin:Admin123! \
  -d 'statement=SELECT META().id, type FROM `lab09` WHERE META().id LIKE "order::filter-test-%" OR META().id LIKE "internal::config-%" ORDER BY META().id' \
  http://172.20.0.21:8093/query/service \
  | jq '.results[] | {id: .id, type: .type}'
```

**Resultado esperado:** Solo los documentos `order::filter-test-*` deben aparecer en el Clúster B. Los `internal::config-*` no deben replicarse.

---

### Parte 3 — Runbook de Disaster Recovery (≈13 min)

---

#### Paso 3.1 — Medir RPO Real

**Objetivo:** Medir el RPO real del sistema XDCR midiendo el lag de replicación bajo carga.

**Instrucciones:**

1. Genera carga continua en el Clúster A mientras mides el lag de XDCR:

```bash
# Genera escrituras continuas durante 60 segundos
cbworkloadgen \
  -n 172.20.0.11:8091 \
  -u admin -p Admin123! \
  -b lab09 \
  -i 10000 \
  --prefix "rpo-test::" \
  -j &
LOAD_PID=$!

# Monitorea el lag de XDCR cada 5 segundos
echo "=== Monitoreo de RPO XDCR (lag de replicación) ==="
for i in {1..12}; do
  LAG=$(curl -s -u admin:Admin123! \
    "http://172.20.0.11:8091/pools/default/buckets/lab09/stats" \
    | jq '.op.samples.xdcr_changes_left[-1] // 0')
  DOCS_A=$(curl -s -u admin:Admin123! \
    http://172.20.0.11:8091/pools/default/buckets/lab09 \
    | jq '.basicStats.itemCount')
  DOCS_B=$(curl -s -u admin:Admin123! \
    http://172.20.0.21:8091/pools/default/buckets/lab09 \
    | jq '.basicStats.itemCount')
  echo "$(date +%H:%M:%S) | Lag: ${LAG} docs | A: ${DOCS_A} | B: ${DOCS_B} | Delta: $((DOCS_A - DOCS_B))"
  sleep 5
done

wait $LOAD_PID
echo "Carga finalizada"
```

2. Calcula el RPO estimado:

```bash
# RPO = lag_docs / throughput_escrituras_por_segundo
# El lag en documentos dividido entre el throughput da el tiempo de exposición
echo "=== Cálculo de RPO ==="
echo "RPO estimado = documentos_en_lag / escrituras_por_segundo"
echo "Ejemplo: 500 docs en lag / 1000 docs/s = 0.5 segundos de RPO"
echo ""
echo "Mide el lag máximo observado y calcula tu RPO real:"
echo "RPO_REAL = MAX_LAG_DOCS / THROUGHPUT_DOCS_POR_SEGUNDO"
```

---

#### Paso 3.2 — Documentar el Runbook de DR

**Objetivo:** Crear un runbook operativo reutilizable con los procedimientos, tiempos y decisiones documentados durante el laboratorio.

**Instrucciones:**

1. Genera el runbook con los valores reales medidos:

```bash
cat > ~/lab09/runbook-dr.md << 'RUNBOOK'
# Runbook de Disaster Recovery — Couchbase Multi-Región
**Versión:** 1.0 | **Fecha:** $(date +%Y-%m-%d) | **Lab:** 09-00-01

## Objetivos de Recuperación

| Métrica | Objetivo | Valor Medido en Lab |
|---------|----------|---------------------|
| RPO (Recovery Point Objective) | ≤ 5 minutos | ___ segundos |
| RTO (Recovery Time Objective) | ≤ 10 minutos | ___ segundos |

## Arquitectura de Referencia

- **Sitio Primario (Clúster A):** 3 nodos, 2 zonas de disponibilidad, Server Groups activos
- **Sitio DR (Clúster B):** 2 nodos, XDCR bidireccional activo
- **Estrategia de Conflict Resolution:** seqno (sequence number)
- **Filtro XDCR A→B:** `REGEXP_CONTAINS(META().id, "^(order|doc)::")`

## Procedimiento de Failover por Tipo

### Escenario 1: Mantenimiento Planificado (Graceful Failover)

**RTO medido:** ___ segundos | **Pérdida de datos:** Ninguna

```bash
# Paso 1: Graceful failover del nodo a mantener
couchbase-cli failover \
  --cluster http://NODO_PRIMARIO:8091 \
  --username admin --password CONTRASEÑA \
  --server-failover http://NODO_A_MANTENER:8091 \
  --no-progress-bar

# Paso 2: Realizar mantenimiento (actualización, reemplazo de disco, etc.)
# ... operaciones de mantenimiento ...

# Paso 3: Reintegrar el nodo
couchbase-cli recovery \
  --cluster http://NODO_PRIMARIO:8091 \
  --username admin --password CONTRASEÑA \
  --server-recovery http://NODO_MANTENIDO:8091 \
  --recovery-type delta

couchbase-cli rebalance \
  --cluster http://NODO_PRIMARIO:8091 \
  --username admin --password CONTRASEÑA
```

### Escenario 2: Fallo Catastrófico de Nodo (Hard Failover)

**RTO medido:** ___ segundos | **Pérdida de datos:** Posible (verificar lag DCP)

```bash
# Paso 1: Confirmar que el nodo es inaccesible
curl --connect-timeout 5 http://NODO_CAIDO:8091/pools/default || echo "NODO INACCESIBLE"

# Paso 2: Hard failover inmediato
couchbase-cli failover \
  --cluster http://NODO_PRIMARIO:8091 \
  --username admin --password CONTRASEÑA \
  --server-failover http://NODO_CAIDO:8091 \
  --force

# Paso 3: Verificar integridad de datos
curl -s -u admin:CONTRASEÑA \
  http://NODO_PRIMARIO:8091/pools/default/buckets/BUCKET \
  | jq '.basicStats.itemCount'

# Paso 4: Cuando el nodo se recupere, reintegrar con delta recovery
couchbase-cli recovery \
  --cluster http://NODO_PRIMARIO:8091 \
  --username admin --password CONTRASEÑA \
  --server-recovery http://NODO_RECUPERADO:8091 \
  --recovery-type delta
```

### Escenario 3: Fallo Total del Sitio Primario (DR Completo)

**RTO objetivo:** ≤ 10 minutos | **RPO objetivo:** ≤ 5 minutos

```bash
# Paso 1: Confirmar que el Clúster A es inaccesible
curl --connect-timeout 5 http://CLUSTER_A:8091/pools/default || echo "CLUSTER A INACCESIBLE"

# Paso 2: Verificar estado de datos en Clúster B (sitio DR)
curl -s -u admin:CONTRASEÑA \
  http://CLUSTER_B:8091/pools/default/buckets/lab09 \
  | jq '.basicStats.itemCount'

# Paso 3: Redirigir aplicaciones al Clúster B
# Actualizar DNS o load balancer para apuntar a CLUSTER_B
# En SDK: cambiar connection string a "couchbase://CLUSTER_B"

# Paso 4: Detener replicación XDCR (evitar conflictos durante DR)
# Obtener ID de replicación
REPL_ID=$(curl -s -u admin:CONTRASEÑA \
  http://CLUSTER_B:8091/pools/default/tasks \
  | jq -r '.[] | select(.type=="xdcr") | .id')

# Pausar replicación entrante (opcional durante operación DR)
curl -X POST -u admin:CONTRASEÑA \
  "http://CLUSTER_B:8091/settings/replications/${REPL_ID}" \
  -d 'pauseRequested=true'

# Paso 5: Cuando Clúster A se recupere, resincronizar
# Reactivar XDCR y ejecutar rebalanceo completo
```

## Checklist de Validación Post-DR

- [ ] Conteo de documentos en sitio activo coincide con último backup conocido
- [ ] Latencia de operaciones KV < 10ms en percentil 95
- [ ] XDCR lag < 1000 documentos en estado estable
- [ ] Auto-failover reconfigurado y habilitado
- [ ] Alertas de monitoreo activas en nuevo sitio primario
- [ ] Runbook actualizado con lecciones aprendidas del incidente

## Decisión de Conflict Resolution

| Estrategia | Cuándo Usar | Requisito |
|------------|-------------|-----------|
| `seqno` (default) | Cargas OLTP estándar, no crítico cuál escritura gana | Ninguno |
| `lww` (timestamp) | Cuando el "más reciente" es semánticamente correcto | NTP sincronizado entre sitios, error < 250ms |

RUNBOOK

echo "Runbook generado en ~/lab09/runbook-dr.md"
cat ~/lab09/runbook-dr.md
```

---

## Validación y Pruebas Finales

Ejecuta la siguiente secuencia de verificaciones para confirmar que todos los objetivos del laboratorio se han cumplido:

```bash
echo "============================================"
echo "  VALIDACIÓN FINAL — Lab 09-00-01"
echo "============================================"

# 1. Verificar que el Clúster A tiene 3 nodos activos
echo ""
echo "[1/5] Nodos activos en Clúster A:"
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default \
  | jq '[.nodes[] | select(.clusterMembership == "active")] | length'
# Esperado: 3

# 2. Verificar Server Groups configurados
echo ""
echo "[2/5] Server Groups en Clúster A:"
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/serverGroups \
  | jq '[.groups[] | select(.name != "Group 1")] | length'
# Esperado: 2 (zona-1 y zona-2)

# 3. Verificar XDCR activo en ambas direcciones
echo ""
echo "[3/5] Replicaciones XDCR activas en Clúster A:"
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/tasks \
  | jq '[.[] | select(.type == "xdcr" and .status == "running")] | length'
# Esperado: 1 (A→B)

echo ""
echo "[3b/5] Replicaciones XDCR activas en Clúster B:"
curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/tasks \
  | jq '[.[] | select(.type == "xdcr" and .status == "running")] | length'
# Esperado: 1 (B→A)

# 4. Verificar sincronización de datos entre clústeres
echo ""
echo "[4/5] Conteo de documentos en ambos clústeres:"
DOCS_A=$(curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/buckets/lab09 \
  | jq '.basicStats.itemCount')
DOCS_B=$(curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/buckets/lab09 \
  | jq '.basicStats.itemCount')
echo "  Clúster A: $DOCS_A documentos"
echo "  Clúster B: $DOCS_B documentos"
echo "  Diferencia: $((DOCS_A - DOCS_B)) (debe ser cercana a 0 en estado estable)"

# 5. Verificar que el runbook fue generado
echo ""
echo "[5/5] Runbook DR generado:"
[ -f ~/lab09/runbook-dr.md ] && echo "  ✓ ~/lab09/runbook-dr.md existe" || echo "  ✗ Runbook no encontrado"

echo ""
echo "============================================"
echo "  Tiempos medidos durante el laboratorio:"
echo "  RTO Graceful Failover:  ${RTO_GRACEFUL:-'N/A'} segundos"
echo "  RTO Manual Failover:    ${RTO_MANUAL:-'N/A'} segundos"
echo "  RTO Auto-Failover:      ${RTO_AUTO:-'N/A'} segundos"
echo "============================================"
```

---

## Solución de Problemas

### Problema 1: El auto-failover no se activa después de 30 segundos

**Síntomas:**
- El nodo detenido permanece en estado `warmup` o `unhealthy` en el cluster map.
- El log del clúster no muestra eventos de failover automático.
- `curl .../settings/autoFailover` devuelve `"count": 1` aunque no se haya ejecutado ningún failover previo.

**Causa:**
El auto-failover tiene un contador máximo (`maxCount`). Si ya se ejecutó un auto-failover previo en la sesión (por ejemplo, durante el Paso 1.5 de práctica anterior), el sistema no ejecutará otro hasta que el contador sea reseteado. Adicionalmente, Couchbase no ejecuta auto-failover si el clúster quedaría por debajo del quorum mínimo (menos de 2 nodos activos para un bucket con 1 réplica).

**Solución:**
```bash
# 1. Verifica el estado actual del contador
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/settings/autoFailover \
  | jq '{enabled: .enabled, timeout: .timeout, count: .count, maxCount: .maxCount}'

# 2. Resetea el contador de auto-failover
curl -s -X POST \
  -u admin:Admin123! \
  http://172.20.0.11:8091/settings/autoFailover/resetCount

# 3. Confirma que el contador volvió a 0
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/settings/autoFailover \
  | jq '.count'

# 4. Verifica que hay suficientes nodos activos (mínimo 2 para 1 réplica)
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default \
  | jq '[.nodes[] | select(.clusterMembership == "active")] | length'
```

---

### Problema 2: XDCR muestra estado `notRunning` o `paused` y los documentos no se replican

**Síntomas:**
- El conteo de documentos en el Clúster B no aumenta después de insertar documentos en el Clúster A.
- `curl .../pools/default/tasks` muestra `"status": "notRunning"` para las tareas XDCR.
- Los logs de XDCR muestran errores de autenticación o conectividad con el clúster remoto.

**Causa:**
Existen tres causas comunes: (a) la referencia de clúster remoto tiene credenciales incorrectas o el hostname no es accesible desde la red Docker; (b) el bucket de destino no existe o tiene un nombre diferente; (c) la replicación fue pausada manualmente o por un evento de failover que invalidó la referencia.

**Solución:**
```bash
# 1. Verifica la conectividad de red entre clústeres
docker exec cb-a1 curl -s --connect-timeout 5 \
  http://172.20.0.21:8091/pools/default \
  | jq '.clusterName' || echo "ERROR: cb-a1 no puede alcanzar cb-b1"

# 2. Verifica el estado de las referencias remotas
curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/remoteClusters \
  | jq '.[] | {name: .name, hostname: .hostname, valid: .valid, deleted: .deleted}'

# 3. Si la referencia es inválida, recréala
curl -s -X DELETE \
  -u admin:Admin123! \
  "http://172.20.0.11:8091/pools/default/remoteClusters/ClusterB-DR"

curl -s -X POST \
  -u admin:Admin123! \
  -d 'name=ClusterB-DR&hostname=172.20.0.21:8091&username=admin&password=Admin123!&demandEncryption=0' \
  http://172.20.0.11:8091/pools/default/remoteClusters

# 4. Verifica que el bucket de destino existe en Clúster B
curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/buckets \
  | jq '.[].name'

# 5. Reanuda la replicación si estaba pausada
REPL_ID=$(curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/tasks \
  | jq -r '.[] | select(.type == "xdcr") | .id' | head -1)

curl -s -X POST \
  -u admin:Admin123! \
  "http://172.20.0.11:8091/settings/replications/${REPL_ID}" \
  -d 'pauseRequested=false'

# 6. Verifica el lag XDCR después de reanudar (debe reducirse)
sleep 10
curl -s -u admin:Admin123! \
  "http://172.20.0.11:8091/pools/default/buckets/lab09/stats" \
  | jq '.op.samples.xdcr_changes_left[-3:]'
```

---

## Limpieza del Entorno

```bash
cd ~/lab09

# 1. Elimina las replicaciones XDCR activas
echo "Eliminando replicaciones XDCR..."
for REPL_ID in $(curl -s -u admin:Admin123! \
  http://172.20.0.11:8091/pools/default/tasks \
  | jq -r '.[] | select(.type == "xdcr") | .id'); do
  curl -s -X DELETE \
    -u admin:Admin123! \
    "http://172.20.0.11:8091/controller/cancelXDCR/${REPL_ID}"
done

for REPL_ID in $(curl -s -u admin:Admin123! \
  http://172.20.0.21:8091/pools/default/tasks \
  | jq -r '.[] | select(.type == "xdcr") | .id'); do
  curl -s -X DELETE \
    -u admin:Admin123! \
    "http://172.20.0.21:8091/controller/cancelXDCR/${REPL_ID}"
done

# 2. Detiene y elimina todos los contenedores y redes
echo "Deteniendo contenedores..."
docker compose down -v

# 3. Elimina imágenes descargadas (opcional, libera ~1.5 GB por imagen)
# docker rmi couchbase/server:enterprise-7.6.2

# 4. Archiva los artefactos del laboratorio
echo "Archivando artefactos..."
tar -czf ~/lab09-artefactos-$(date +%Y%m%d).tar.gz \
  ~/lab09/runbook-dr.md \
  ~/lab09/conflict_generator.py \
  ~/lab09/docker-compose.yml

echo "Limpieza completada. Artefactos guardados en ~/lab09-artefactos-$(date +%Y%m%d).tar.gz"
```

---

## Resumen

En este laboratorio aplicaste de forma integral los conceptos de alta disponibilidad y recuperación ante desastres en Couchbase:

| Actividad | Concepto Clave | Resultado |
|-----------|----------------|-----------|
| Server Groups + Zone Awareness | Las réplicas de vBuckets nunca comparten zona | Resiliencia ante fallo de rack/AZ completa |
| Graceful Failover | Transferencia controlada de vBuckets activos antes del cierre | RTO medido, **cero pérdida de datos** |
| Hard Failover (--force) | Promoción inmediata de réplicas; posible lag DCP | RTO menor, **pérdida de datos posible** |
| Auto-Failover | Detección automática basada en timeout + quorum | RTO = timeout + tiempo de promoción |
| XDCR Bidireccional con filtros | `REGEXP_CONTAINS` en META().id para replicación selectiva | Solo documentos relevantes replican al sitio DR |
| Resolución de conflictos | `seqno` (default) vs `lww` (timestamp) | Comportamiento determinístico bajo escrituras simultáneas |
| Runbook DR | RPO y RTO documentados con valores reales | Documento operativo reutilizable |

**Lecciones operativas críticas:**
- El **graceful failover** es siempre preferible cuando hay tiempo planificado; el hard failover es para emergencias donde el nodo ya no responde.
- El **RPO real** de XDCR depende del lag de replicación; bajo carga alta, el lag puede superar los objetivos si el ancho de banda entre sitios es insuficiente.
- El **auto-failover** requiere que el clúster mantenga quorum después del evento; nunca se activa si dejaría al clúster sin mayoría de nodos activos.
- La resolución de conflictos **`lww`** requiere NTP sincronizado entre sitios con error < 250ms; sin esto, `seqno` es más seguro.

### Recursos Adicionales

- [Documentación oficial: Failover — Couchbase Server 7.6](https://docs.couchbase.com/server/current/manage/manage-nodes/fail-nodes-over.html)
- [Documentación oficial: Server Groups (Zone Awareness)](https://docs.couchbase.com/server/current/manage/manage-groups/manage-groups.html)
- [Documentación oficial: XDCR — Filtering](https://docs.couchbase.com/server/current/manage/manage-xdcr/filter-xdcr-replication.html)
- [Documentación oficial: XDCR Conflict Resolution](https://docs.couchbase.com/server/current/learn/clusters-and-availability/xdcr-conflict-resolution.html)
- [Documentación oficial: Auto-Failover Settings](https://docs.couchbase.com/server/current/manage/manage-settings/enable-auto-failover.html)
- [Guía de Durabilidad y Réplicas (Lección 9.1)](https://docs.couchbase.com/server/current/learn/data/durability.html)

---
