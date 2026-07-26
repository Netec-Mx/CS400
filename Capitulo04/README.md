# Diseño de una estrategia de indexación para alta carga

## 1. Metadatos

| Campo            | Valor                                      |
|------------------|--------------------------------------------|
| **Duración**     | 90 minutos                                 |
| **Complejidad**  | Alta                                       |
| **Nivel Bloom**  | Crear (Create)                             |
| **Servicio**     | Index Service — Global Secondary Indexes   |
| **Versión CB**   | Couchbase Server Enterprise 7.6.x          |

---

## 2. Descripción General

En este laboratorio diseñarás una estrategia completa de indexación para un sistema de reservas de viajes simulado que opera bajo una carga de **1 000 consultas por segundo (QPS)**. Partirás del análisis de patrones de acceso reales sobre el dataset `travel-sample` aumentado (≥ 200 K documentos) para construir progresivamente índices simples, compuestos, parciales, *covering* y particionados, midiendo el impacto de cada decisión con métricas comparativas. Al finalizar habrás implementado réplicas de índice, simulado la pérdida de un nodo de índice y ejecutado el proceso de recuperación, consolidando así el dominio operativo end-to-end del Index Service de Couchbase.

---

## 3. Objetivos de Aprendizaje

- [ ] Diseñar y crear una estrategia completa de indexación usando GSI que incluya índices simples, compuestos, parciales y *covering indexes*, justificando cada decisión con base en los patrones de acceso identificados.
- [ ] Implementar índices particionados por `PARTITION BY HASH` y réplicas de índice (`num_replica`) para garantizar distribución de carga y alta disponibilidad.
- [ ] Analizar el ciclo de vida completo de un índice: creación diferida con `BUILD INDEX`, estados (`deferred`, `building`, `online`) y recuperación ante fallos.
- [ ] Evaluar cuantitativamente el impacto de cada tipo de índice en el rendimiento de consultas mediante métricas del plan de ejecución (`EXPLAIN`) y estadísticas del Index Service.

---

## 4. Prerrequisitos

### Conocimiento previo
- Lab 03-00-01 completado: uso de `EXPLAIN` y `ADVISE` para interpretar planes de ejecución SQL++.
- Comprensión de la arquitectura del Index Service y el motor Plasma (Lección 4.1).
- Familiaridad con los operadores `IndexScan`, `Fetch` y `Filter` en planes de ejecución.

### Acceso requerido
- Clúster Couchbase de **3 nodos** con el Index Service activo en al menos **2 nodos**.
- Dataset `travel-sample` importado y aumentado a ≥ 200 K documentos (script provisto en la Sección 5).
- Acceso a `cbq` (Query Shell) y a la Consola Web de Couchbase (`http://<nodo1>:8091`).
- Usuario con rol `Full Admin` o `Query Manage Index` + `Query Select` sobre `travel-sample`.

---

## 5. Entorno de Laboratorio

### Topología recomendada

| Nodo    | Servicios activos                   | RAM asignada | Almacenamiento |
|---------|-------------------------------------|--------------|----------------|
| `node1` | Data, Query                         | 8 GB         | 100 GB SSD     |
| `node2` | Data, Index                         | 8 GB         | 100 GB SSD     |
| `node3` | Index, Query                        | 8 GB         | 100 GB SSD     |
| `client` | cbq, Python SDK, cbc-pillowfight   | 4 GB         | 20 GB          |

> **Nota:** Si el clúster tiene los servicios colocados de otra forma, verifica que el Index Service esté activo en al menos 2 nodos antes de continuar. Puedes confirmarlo en **Server Nodes → Services** en la Consola Web.

### Variables de entorno (definir en el nodo cliente antes de comenzar)

```bash
export CB_HOST="http://node1:8091"
export CB_USER="Administrator"
export CB_PASS="password"          # Sustituir por la contraseña real
export CB_BUCKET="travel-sample"
export CBQ="cbq -u ${CB_USER} -p ${CB_PASS} -engine=http://node1:8093/"
```

### 5.1 Verificar el estado del clúster

```bash
curl -s -u ${CB_USER}:${CB_PASS} ${CB_HOST}/pools/default \
  | jq '{clusterName: .clusterName, nodes: [.nodes[] | {hostname, services, status}]}'
```

**Salida esperada (resumen):**
```json
{
  "clusterName": "lab-cluster",
  "nodes": [
    {"hostname": "node1:8091", "services": ["kv","n1ql"], "status": "healthy"},
    {"hostname": "node2:8091", "services": ["kv","index"], "status": "healthy"},
    {"hostname": "node3:8091", "services": ["index","n1ql"], "status": "healthy"}
  ]
}
```

### 5.2 Aumentar el dataset travel-sample a ≥ 200 K documentos

Ejecuta el siguiente script Python desde el nodo cliente. Genera documentos de tipo `booking` que simulan reservas de vuelos con campos relevantes para los patrones de consulta del laboratorio.

```bash
pip install couchbase --quiet
```

```python
# archivo: generate_bookings.py
import random, uuid, datetime
from couchbase.cluster import Cluster
from couchbase.auth import PasswordAuthenticator
from couchbase.options import ClusterOptions

TARGET_DOCS = 200_000
BATCH_SIZE  = 500

cluster = Cluster(
    "couchbase://node1",
    ClusterOptions(PasswordAuthenticator("Administrator", "password"))
)
cb = cluster.bucket("travel-sample").default_collection()

airlines   = ["AA", "UA", "DL", "LH", "BA", "IB", "AF", "KL", "QR", "EK"]
airports   = ["JFK", "LAX", "ORD", "LHR", "CDG", "FRA", "DXB", "SIN", "NRT", "GRU"]
statuses   = ["confirmed", "pending", "cancelled"]
cabin_cls  = ["economy", "business", "first"]

def make_booking():
    dep = datetime.date(2024, random.randint(1,12), random.randint(1,28))
    return {
        "type": "booking",
        "bookingId": str(uuid.uuid4()),
        "customerId": f"cust_{random.randint(1, 50000)}",
        "flightId": f"{random.choice(airlines)}{random.randint(100,999)}",
        "origin": random.choice(airports),
        "destination": random.choice(airports),
        "departureDate": dep.isoformat(),
        "cabin": random.choice(cabin_cls),
        "price": round(random.uniform(150, 5000), 2),
        "status": random.choice(statuses),
        "createdAt": datetime.datetime.utcnow().isoformat()
    }

docs = {}
for i in range(TARGET_DOCS):
    doc = make_booking()
    docs[f"booking::{doc['bookingId']}"] = doc
    if len(docs) == BATCH_SIZE:
        for k, v in docs.items():
            cb.upsert(k, v)
        docs.clear()
        print(f"  Insertados: {i+1}/{TARGET_DOCS}", end="\r")

if docs:
    for k, v in docs.items():
        cb.upsert(k, v)

print(f"\nCompletado: {TARGET_DOCS} documentos insertados.")
```

```bash
python3 generate_bookings.py
```

### 5.3 Verificar el conteo de documentos

```sql
-- Ejecutar en cbq
SELECT RAW COUNT(*) FROM `travel-sample` WHERE type = "booking";
```

Resultado esperado: `[200000]` (o el valor que hayas generado).

---

## 6. Pasos del Laboratorio

---

### Paso 1 — Análisis de patrones de acceso y estado inicial de índices

**Objetivo:** Identificar qué consultas representan la carga de 1 000 QPS y qué índices existen actualmente, estableciendo la línea base de rendimiento.

#### Instrucciones

**1.1** Examina los índices existentes en el bucket `travel-sample`:

```sql
SELECT name, state, index_key, `condition`, nodes, num_replica
FROM system:indexes
WHERE keyspace_id = "travel-sample"
ORDER BY name;
```

**1.2** Registra los índices presentes. Típicamente encontrarás solo `#primary`. Anota el resultado en tu cuaderno de laboratorio.

**1.3** Ejecuta las cinco consultas representativas de los patrones de acceso del sistema de reservas. Estas consultas son la base de toda la estrategia de indexación:

```sql
-- Q1: Búsqueda de reservas por cliente (alta frecuencia, ~400 QPS)
EXPLAIN SELECT bookingId, flightId, status, departureDate
FROM `travel-sample`
WHERE type = "booking" AND customerId = "cust_12345";
```

```sql
-- Q2: Reservas por ruta y fecha (alta frecuencia, ~300 QPS)
EXPLAIN SELECT bookingId, customerId, price, cabin
FROM `travel-sample`
WHERE type = "booking"
  AND origin = "JFK"
  AND destination = "LHR"
  AND departureDate >= "2024-06-01"
  AND departureDate <= "2024-06-30";
```

```sql
-- Q3: Reservas pendientes por rango de precio (media frecuencia, ~150 QPS)
EXPLAIN SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample`
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;
```

```sql
-- Q4: Dashboard de cliente — solo campos de resumen (alta frecuencia, ~100 QPS)
EXPLAIN SELECT bookingId, status, departureDate, price
FROM `travel-sample`
WHERE type = "booking"
  AND customerId = "cust_99999"
ORDER BY departureDate DESC;
```

```sql
-- Q5: Conteo de reservas confirmadas por origen (baja frecuencia, ~50 QPS)
EXPLAIN SELECT origin, COUNT(*) AS total
FROM `travel-sample`
WHERE type = "booking" AND status = "confirmed"
GROUP BY origin;
```

**1.4** Para cada `EXPLAIN`, anota el operador raíz del plan. Sin índices adecuados, todos mostrarán `PrimaryScan` o `PrimaryIndex`, lo que indica un *full scan*.

#### Salida esperada (fragmento de Q1 sin índice optimizado)

```json
{
  "#operator": "Sequence",
  "~children": [
    {
      "#operator": "PrimaryScan3",
      "index": "#primary",
      "keyspace": "travel-sample"
    },
    {
      "#operator": "Filter",
      "condition": "((`travel-sample`.`type` = \"booking\") and ...)"
    }
  ]
}
```

#### Verificación

```bash
# Medir tiempo real de Q1 sin índice óptimo
time echo "SELECT bookingId, flightId, status, departureDate \
FROM \`travel-sample\` \
WHERE type = 'booking' AND customerId = 'cust_12345';" \
| cbq -u Administrator -p password -engine=http://node1:8093/ \
      --script -q 2>&1 | grep "elapsed"
```

> **Registra** el tiempo de ejecución. Este es tu **baseline**. Se espera latencia > 500 ms con solo el índice primario.

---

### Paso 2 — Creación de índices simples y medición de impacto

**Objetivo:** Crear los índices simples más urgentes y medir la mejora de latencia con `EXPLAIN` y `system:indexes`.

#### Instrucciones

**2.1** Crea un índice simple sobre `customerId` (atiende Q1 y Q4):

```sql
CREATE INDEX idx_booking_customer
ON `travel-sample`(customerId)
WHERE type = "booking";
```

> Este es un **partial index**: la cláusula `WHERE type = "booking"` reduce el tamaño del índice al excluir todos los documentos que no son reservas. Aprenderás más sobre partial indexes en el Paso 4, pero aquí ya aplicamos la práctica.

**2.2** Verifica que el índice esté `online`:

```sql
SELECT name, state, nodes
FROM system:indexes
WHERE name = "idx_booking_customer";
```

**2.3** Vuelve a ejecutar `EXPLAIN` para Q1 y observa el cambio de operador:

```sql
EXPLAIN SELECT bookingId, flightId, status, departureDate
FROM `travel-sample`
WHERE type = "booking" AND customerId = "cust_12345";
```

**2.4** Crea un índice simple sobre `status`:

```sql
CREATE INDEX idx_booking_status
ON `travel-sample`(status)
WHERE type = "booking";
```

**2.5** Mide el impacto en Q3 y Q5:

```sql
EXPLAIN SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample`
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;
```

#### Salida esperada (fragmento de Q1 con idx_booking_customer)

```json
{
  "#operator": "IndexScan3",
  "index": "idx_booking_customer",
  "index_projection": {"primary_key": true},
  "spans": [{"exact": true, "range": [{"high": "\"cust_12345\"", "low": "\"cust_12345\""}]}]
}
```

El operador `PrimaryScan3` debe haber desaparecido. Ahora verás `IndexScan3` seguido de `Fetch`.

#### Verificación

```bash
# Comparar latencia de Q1 con el nuevo índice
time echo "SELECT bookingId, flightId, status, departureDate \
FROM \`travel-sample\` \
WHERE type = 'booking' AND customerId = 'cust_12345';" \
| cbq -u Administrator -p password -engine=http://node1:8093/ \
      --script -q 2>&1 | grep "elapsed"
```

> Registra el nuevo tiempo. Espera una mejora de **10×–50×** respecto al baseline.

---

### Paso 3 — Índices compuestos con orden de campos optimizado

**Objetivo:** Diseñar índices compuestos para Q2 y Q3, aplicando el principio de orden de campos (igualdad → rango) y medir la reducción de filas escaneadas.

#### Instrucciones

**3.1** Analiza Q2 con `ADVISE` para obtener una recomendación inicial:

```sql
ADVISE SELECT bookingId, customerId, price, cabin
FROM `travel-sample`
WHERE type = "booking"
  AND origin = "JFK"
  AND destination = "LHR"
  AND departureDate >= "2024-06-01"
  AND departureDate <= "2024-06-30";
```

**3.2** Crea el índice compuesto para Q2. El orden correcto es: primero los campos de igualdad (`origin`, `destination`), luego el campo de rango (`departureDate`):

```sql
CREATE INDEX idx_booking_route_date
ON `travel-sample`(origin, destination, departureDate)
WHERE type = "booking";
```

**3.3** Verifica el plan de ejecución de Q2:

```sql
EXPLAIN SELECT bookingId, customerId, price, cabin
FROM `travel-sample`
WHERE type = "booking"
  AND origin = "JFK"
  AND destination = "LHR"
  AND departureDate >= "2024-06-01"
  AND departureDate <= "2024-06-30";
```

Busca en el plan el valor de `"spans"` para confirmar que el índice usa los tres campos como condición de escaneo (no solo los dos primeros).

**3.4** Crea el índice compuesto para Q3. El campo de igualdad (`status`) va primero, luego el rango (`price`):

```sql
CREATE INDEX idx_booking_status_price
ON `travel-sample`(status, price)
WHERE type = "booking";
```

**3.5** Compara los planes de Q3 antes (con `idx_booking_status`) y después (con `idx_booking_status_price`). Usa `EXPLAIN` para ambos y observa la diferencia en los `spans`:

```sql
-- Forzar el índice simple (para comparación)
EXPLAIN SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample` USE INDEX (idx_booking_status USING GSI)
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;

-- Con el índice compuesto (comportamiento natural)
EXPLAIN SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample`
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;
```

**3.6** Documenta en tu cuaderno el número de `spans` y la estimación de filas (`#docs`) en cada caso.

#### Verificación

```sql
-- Confirmar que ambos índices están online
SELECT name, state, index_key
FROM system:indexes
WHERE name IN ("idx_booking_route_date", "idx_booking_status_price");
```

Ambos deben aparecer con `"state": "online"`.

---

### Paso 4 — Partial Indexes: reducción del tamaño del índice

**Objetivo:** Comprender el impacto de la cláusula `WHERE` en la creación de índices y crear partial indexes que optimicen consultas sobre subconjuntos de datos.

#### Instrucciones

**4.1** Examina cuántos documentos del bucket NO son de tipo `"booking"`:

```sql
SELECT type, COUNT(*) AS total
FROM `travel-sample`
GROUP BY type
ORDER BY total DESC;
```

Observa la proporción de documentos `booking` versus otros tipos (`airline`, `airport`, `hotel`, `landmark`, `route`). Esta proporción justifica el uso de partial indexes.

**4.2** Compara el tamaño lógico de un índice sin condición versus uno con condición. Primero crea un índice sin `WHERE` (solo para comparación, lo eliminarás después):

```sql
-- Índice sin condición (indexa TODOS los documentos del bucket)
CREATE INDEX idx_full_customerId
ON `travel-sample`(customerId);
```

**4.3** Consulta las estadísticas de ambos índices para comparar el número de entradas:

```sql
SELECT b.name,
       b.keyspace_id,
       b.`condition`,
       b.index_key
FROM system:indexes b
WHERE b.name IN ("idx_full_customerId", "idx_booking_customer")
ORDER BY b.name;
```

**4.4** Usa la REST API para obtener métricas de tamaño del Index Service:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
  "http://node2:9102/api/v1/stats" \
  | jq 'to_entries
        | map(select(.key | test("idx_booking_customer|idx_full_customerId")))
        | from_entries'
```

> Compara los valores de `num_docs_indexed` entre ambos índices. El índice con `WHERE type = "booking"` debe tener significativamente menos entradas.

**4.5** Elimina el índice de comparación (no lo necesitarás más):

```sql
DROP INDEX `travel-sample`.idx_full_customerId;
```

**4.6** Crea un partial index adicional para reservas canceladas (útil para procesos de limpieza y auditoría):

```sql
CREATE INDEX idx_booking_cancelled
ON `travel-sample`(createdAt, customerId)
WHERE type = "booking" AND status = "cancelled";
```

**4.7** Verifica que la siguiente consulta use el partial index:

```sql
EXPLAIN SELECT bookingId, customerId, createdAt
FROM `travel-sample`
WHERE type = "booking"
  AND status = "cancelled"
  AND createdAt < "2024-03-01";
```

#### Verificación

```sql
SELECT name, state, `condition`
FROM system:indexes
WHERE keyspace_id = "travel-sample"
  AND `condition` IS NOT NULL
ORDER BY name;
```

Debes ver al menos tres índices con condición `WHERE`.

---

### Paso 5 — Covering Indexes: eliminación del operador Fetch

**Objetivo:** Diseñar *covering indexes* para Q1 y Q4 que incluyan todos los campos proyectados en el `SELECT`, eliminando el operador `Fetch` del plan de ejecución.

#### Instrucciones

**5.1** Revisa el plan actual de Q4 (dashboard de cliente):

```sql
EXPLAIN SELECT bookingId, status, departureDate, price
FROM `travel-sample`
WHERE type = "booking"
  AND customerId = "cust_99999"
ORDER BY departureDate DESC;
```

Identifica el operador `Fetch` en el plan. Este operador implica un viaje adicional al Data Service para recuperar el documento completo, lo que añade latencia y carga al Data Service.

**5.2** Crea un *covering index* para Q4. El índice debe incluir todos los campos del `SELECT` además del campo del `WHERE`:

```sql
-- Covering index para Q4: incluye customerId (WHERE), departureDate (ORDER BY),
-- bookingId, status y price (SELECT) — type queda cubierto por la condición WHERE
CREATE INDEX idx_booking_customer_covering
ON `travel-sample`(customerId, departureDate DESC, bookingId, status, price)
WHERE type = "booking";
```

**5.3** Verifica el nuevo plan de Q4:

```sql
EXPLAIN SELECT bookingId, status, departureDate, price
FROM `travel-sample`
WHERE type = "booking"
  AND customerId = "cust_99999"
ORDER BY departureDate DESC;
```

Confirma que el operador `Fetch` ha **desaparecido** del plan. El plan debe mostrar solo `IndexScan3` → `Parallel` → `Order` (sin `Fetch`).

**5.4** Crea un *covering index* para Q2 (búsqueda por ruta y fecha con proyección de precio y cabina):

```sql
CREATE INDEX idx_booking_route_covering
ON `travel-sample`(origin, destination, departureDate, bookingId, customerId, price, cabin)
WHERE type = "booking";
```

**5.5** Verifica Q2 con el nuevo índice:

```sql
EXPLAIN SELECT bookingId, customerId, price, cabin
FROM `travel-sample`
WHERE type = "booking"
  AND origin = "JFK"
  AND destination = "LHR"
  AND departureDate >= "2024-06-01"
  AND departureDate <= "2024-06-30";
```

**5.6** Mide la mejora de latencia para Q4:

```bash
# Latencia de Q4 con covering index
time echo "SELECT bookingId, status, departureDate, price \
FROM \`travel-sample\` \
WHERE type = 'booking' AND customerId = 'cust_99999' \
ORDER BY departureDate DESC;" \
| cbq -u Administrator -p password -engine=http://node1:8093/ \
      --script -q 2>&1 | grep "elapsed"
```

#### Salida esperada (plan de Q4 con covering index)

```json
{
  "#operator": "IndexScan3",
  "covers": ["cover (((`travel-sample`.`customerId`)))", "..."],
  "index": "idx_booking_customer_covering",
  "index_projection": {"entry_keys": [0,1,2,3,4]}
}
```

La presencia del campo `"covers"` en el plan confirma que es un *covering index* activo.

#### Verificación

```sql
-- Confirmar ausencia de Fetch en el plan de Q4
-- El resultado del EXPLAIN no debe contener la cadena "Fetch"
SELECT RAW plan
FROM (
  SELECT EXPLAIN(
    SELECT bookingId, status, departureDate, price
    FROM `travel-sample`
    WHERE type = "booking" AND customerId = "cust_99999"
    ORDER BY departureDate DESC
  ) AS plan
) subq
WHERE TOSTRING(plan) NOT LIKE "%Fetch%";
```

Si la consulta devuelve un resultado (no vacío), el `Fetch` fue eliminado correctamente.

---

### Paso 6 — Índices particionados con PARTITION BY HASH

**Objetivo:** Crear un índice particionado para distribuir la carga de escaneo entre múltiples nodos del Index Service y entender cuándo esta estrategia es beneficiosa.

#### Instrucciones

**6.1** Verifica que el clúster tiene al menos 2 nodos con el Index Service activo:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
  "${CB_HOST}/pools/default" \
  | jq '[.nodes[] | select(.services | contains(["index"])) | .hostname]'
```

Debes ver al menos 2 hostnames.

**6.2** Crea un índice particionado para la consulta Q5 (conteo por origen). El particionamiento por `origin` distribuye los datos del índice entre nodos según el hash del campo:

```sql
CREATE INDEX idx_booking_origin_partitioned
ON `travel-sample`(origin, status)
WHERE type = "booking"
PARTITION BY HASH(origin)
WITH {"num_partition": 8};
```

> **Nota:** Con `num_partition: 8` y 2 nodos de índice, cada nodo recibirá 4 particiones. Con 3 nodos, la distribución será 3-3-2.

**6.3** Verifica la distribución de particiones:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
  "http://node2:9102/api/v1/stats/idx_booking_origin_partitioned" \
  | jq '{num_docs_indexed, num_docs_pending, partition_stats: .partitions}'
```

**6.4** Consulta el plan de Q5 con el índice particionado:

```sql
EXPLAIN SELECT origin, COUNT(*) AS total
FROM `travel-sample`
WHERE type = "booking" AND status = "confirmed"
GROUP BY origin;
```

Busca en el plan el campo `"partition"` o `"PartitionedIndexScan"` que confirme el uso del índice particionado.

**6.5** Compara el rendimiento de Q5 con y sin particionamiento:

```bash
# Con índice particionado (comportamiento natural)
time echo "SELECT origin, COUNT(*) AS total \
FROM \`travel-sample\` \
WHERE type = 'booking' AND status = 'confirmed' \
GROUP BY origin;" \
| cbq -u Administrator -p password -engine=http://node1:8093/ \
      --script -q 2>&1 | grep "elapsed"

# Forzar el índice no particionado para comparación
time echo "SELECT origin, COUNT(*) AS total \
FROM \`travel-sample\` USE INDEX (idx_booking_status_price USING GSI) \
WHERE type = 'booking' AND status = 'confirmed' \
GROUP BY origin;" \
| cbq -u Administrator -p password -engine=http://node1:8093/ \
      --script -q 2>&1 | grep "elapsed"
```

#### Verificación

```sql
SELECT name, state, index_key, `partition`
FROM system:indexes
WHERE name = "idx_booking_origin_partitioned";
```

El campo `"partition"` debe mostrar `"HASH(origin)"`.

---

### Paso 7 — Réplicas de índice y simulación de failover

**Objetivo:** Crear réplicas de índice para garantizar alta disponibilidad y verificar que las consultas continúan respondiendo tras la pérdida de un nodo de índice.

#### Instrucciones

**7.1** Crea el índice de mayor criticidad (atiende Q1, ~400 QPS) con réplica:

```sql
CREATE INDEX idx_booking_customer_ha
ON `travel-sample`(customerId, departureDate DESC, bookingId, status, price)
WHERE type = "booking"
WITH {"num_replica": 1};
```

> Con `num_replica: 1`, Couchbase crea el índice original más 1 réplica, distribuyéndolas automáticamente entre los nodos de índice disponibles.

**7.2** Verifica dónde residen el índice y su réplica:

```sql
SELECT name, state, nodes
FROM system:indexes
WHERE name = "idx_booking_customer_ha";
```

Debes ver `"nodes"` con 2 entradas (una por nodo de índice).

**7.3** Confirma que el Query Service puede usar ambas copias. Ejecuta Q4 varias veces y observa que el plan puede usar cualquiera de los dos nodos:

```bash
for i in $(seq 1 5); do
  echo "SELECT bookingId, status, departureDate, price \
  FROM \`travel-sample\` \
  WHERE type = 'booking' AND customerId = 'cust_$(( RANDOM % 50000 ))' \
  ORDER BY departureDate DESC LIMIT 10;" \
  | cbq -u Administrator -p password -engine=http://node1:8093/ \
        --script -q 2>&1 | grep -E "elapsed|error"
done
```

**7.4** Simula la pérdida del nodo de índice secundario. **IMPORTANTE:** Esta operación es reversible. Detén el proceso de Couchbase en `node3` (que tiene el Index Service):

```bash
# Ejecutar en node3 (nodo con Index Service secundario)
sudo systemctl stop couchbase-server
```

**7.5** Desde el nodo cliente, verifica que el clúster detecta el nodo caído:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
  "${CB_HOST}/pools/default" \
  | jq '[.nodes[] | {hostname, status}]'
```

El nodo caído debe aparecer con `"status": "unhealthy"` o `"warmup"`.

**7.6** Verifica que las consultas Q4 siguen respondiendo (usando la réplica en `node2`):

```bash
for i in $(seq 1 10); do
  echo "SELECT bookingId, status, departureDate, price \
  FROM \`travel-sample\` \
  WHERE type = 'booking' AND customerId = 'cust_$(( RANDOM % 50000 ))' \
  ORDER BY departureDate DESC LIMIT 10;" \
  | cbq -u Administrator -p password -engine=http://node1:8093/ \
        --script -q 2>&1 | grep -E "elapsed|error"
  sleep 0.5
done
```

> Las consultas deben seguir respondiendo sin errores, demostrando la resiliencia de las réplicas de índice.

**7.7** Restaura el nodo caído:

```bash
# Ejecutar en node3
sudo systemctl start couchbase-server
```

**7.8** Espera 60 segundos y verifica que el índice vuelve a estar en estado `online` en ambos nodos:

```bash
sleep 60
curl -s -u ${CB_USER}:${CB_PASS} \
  "${CB_HOST}/pools/default" \
  | jq '[.nodes[] | {hostname, status}]'
```

```sql
SELECT name, state, nodes
FROM system:indexes
WHERE name = "idx_booking_customer_ha";
```

#### Verificación

Ambas copias del índice deben aparecer con `"state": "online"` tras la recuperación del nodo.

---

### Paso 8 — Deferred Build: construcción diferida de índices

**Objetivo:** Dominar el proceso de creación diferida de índices (`DEFERRED`) para construir múltiples índices en un solo paso de construcción, reduciendo el impacto en el Data Service.

#### Instrucciones

**8.1** Crea tres índices con `DEFERRED` (no se construyen inmediatamente):

```sql
-- Índice diferido 1: para análisis de precio por cabina
CREATE INDEX idx_booking_cabin_price
ON `travel-sample`(cabin, price, bookingId)
WHERE type = "booking"
WITH {"defer_build": true};

-- Índice diferido 2: para búsquedas por flightId
CREATE INDEX idx_booking_flight
ON `travel-sample`(flightId, departureDate, status)
WHERE type = "booking"
WITH {"defer_build": true};

-- Índice diferido 3: para análisis temporal
CREATE INDEX idx_booking_date_origin
ON `travel-sample`(departureDate, origin, destination, price)
WHERE type = "booking"
WITH {"defer_build": true};
```

**8.2** Verifica que los tres índices están en estado `deferred`:

```sql
SELECT name, state
FROM system:indexes
WHERE name IN (
  "idx_booking_cabin_price",
  "idx_booking_flight",
  "idx_booking_date_origin"
);
```

Los tres deben mostrar `"state": "deferred"`.

**8.3** Lanza la construcción de todos los índices diferidos en un único comando `BUILD INDEX`. Esto es más eficiente que construirlos uno a uno porque el Index Service puede paralelizar el escaneo del Data Service:

```sql
BUILD INDEX ON `travel-sample`(
  idx_booking_cabin_price,
  idx_booking_flight,
  idx_booking_date_origin
);
```

**8.4** Monitorea el progreso de construcción. Ejecuta la siguiente consulta repetidamente cada 15 segundos:

```bash
watch -n 15 "cbq -u Administrator -p password \
  -engine=http://node1:8093/ \
  --script -q <<< \
  \"SELECT name, state FROM system:indexes \
    WHERE name IN ('idx_booking_cabin_price','idx_booking_flight','idx_booking_date_origin');\""
```

Los estados posibles durante la construcción son:
- `deferred` → pendiente de construcción
- `building` → en construcción activa
- `online` → listo para servir consultas

**8.5** Mientras los índices están en estado `building`, intenta usarlos en una consulta y observa el comportamiento:

```sql
-- Esta consulta puede fallar o usar un índice alternativo mientras idx_booking_flight está "building"
EXPLAIN SELECT bookingId, departureDate, status
FROM `travel-sample`
WHERE type = "booking" AND flightId = "AA101";
```

> Si el índice aún está en `building`, el Query Service usará otro índice disponible o el primario. Esto es el comportamiento esperado.

**8.6** Espera a que los tres índices estén `online` (puede tardar 2–5 minutos con 200 K documentos):

```sql
SELECT name, state
FROM system:indexes
WHERE name IN (
  "idx_booking_cabin_price",
  "idx_booking_flight",
  "idx_booking_date_origin"
)
AND state = "online";
```

#### Verificación

La consulta anterior debe devolver exactamente 3 filas, todas con `"state": "online"`.

---

### Paso 9 — Recuperación de un índice corrupto

**Objetivo:** Simular y recuperar un índice en estado inválido, documentando el procedimiento de recuperación.

#### Instrucciones

**9.1** Consulta el estado completo de todos los índices del bucket:

```sql
SELECT name, state, nodes
FROM system:indexes
WHERE keyspace_id = "travel-sample"
ORDER BY name;
```

**9.2** Para simular un índice que necesita reconstrucción (escenario real: corrupción tras fallo de disco), elimina y recrea `idx_booking_flight` usando el proceso de deferred build:

```sql
-- Paso 1: Eliminar el índice afectado
DROP INDEX `travel-sample`.idx_booking_flight;

-- Paso 2: Verificar que fue eliminado
SELECT name FROM system:indexes WHERE name = "idx_booking_flight";
-- Debe devolver resultado vacío

-- Paso 3: Recrear con deferred build
CREATE INDEX idx_booking_flight
ON `travel-sample`(flightId, departureDate, status)
WHERE type = "booking"
WITH {"defer_build": true};

-- Paso 4: Construir
BUILD INDEX ON `travel-sample`(idx_booking_flight);
```

**9.3** Monitorea hasta que vuelva a estado `online`:

```sql
SELECT name, state
FROM system:indexes
WHERE name = "idx_booking_flight";
```

**9.4** Verifica que el índice recuperado sirve consultas correctamente:

```sql
SELECT bookingId, departureDate, status
FROM `travel-sample`
WHERE type = "booking" AND flightId = "AA101"
LIMIT 5;
```

#### Verificación

```sql
-- Inventario final de todos los índices del laboratorio
SELECT name, state,
       ARRAY_LENGTH(index_key) AS num_keys,
       `condition` IS NOT NULL AS is_partial,
       `partition` IS NOT NULL AS is_partitioned,
       num_replica
FROM system:indexes
WHERE keyspace_id = "travel-sample"
  AND name != "#primary"
ORDER BY name;
```

---

## 7. Validación y Pruebas Finales

### 7.1 Inventario completo de índices creados

Ejecuta la siguiente consulta para generar el inventario final de la estrategia de indexación:

```sql
SELECT
  name,
  state,
  index_key,
  `condition`     AS partial_condition,
  `partition`     AS partition_strategy,
  num_replica,
  nodes
FROM system:indexes
WHERE keyspace_id = "travel-sample"
  AND name != "#primary"
ORDER BY name;
```

**Resultado esperado:** Debes tener al menos los siguientes índices, todos en estado `online`:

| Nombre del índice                  | Tipo         | Parcial | Particionado | Réplicas |
|------------------------------------|--------------|---------|--------------|----------|
| `idx_booking_cabin_price`          | Compuesto    | Sí      | No           | 0        |
| `idx_booking_cancelled`            | Compuesto    | Sí      | No           | 0        |
| `idx_booking_customer`             | Simple       | Sí      | No           | 0        |
| `idx_booking_customer_covering`    | Covering     | Sí      | No           | 0        |
| `idx_booking_customer_ha`          | Covering     | Sí      | No           | 1        |
| `idx_booking_date_origin`          | Compuesto    | Sí      | No           | 0        |
| `idx_booking_flight`               | Compuesto    | Sí      | No           | 0        |
| `idx_booking_origin_partitioned`   | Compuesto    | Sí      | Sí (HASH)    | 0        |
| `idx_booking_route_covering`       | Covering     | Sí      | No           | 0        |
| `idx_booking_route_date`           | Compuesto    | Sí      | No           | 0        |
| `idx_booking_status`               | Simple       | Sí      | No           | 0        |
| `idx_booking_status_price`         | Compuesto    | Sí      | No           | 0        |

### 7.2 Prueba de rendimiento comparativa final

Ejecuta las cinco consultas originales y registra los tiempos de ejecución. Compara con el baseline del Paso 1:

```bash
cat << 'EOF' > /tmp/benchmark_queries.sql
-- Q1: Búsqueda por cliente
SELECT bookingId, flightId, status, departureDate
FROM `travel-sample`
WHERE type = "booking" AND customerId = "cust_12345";

-- Q2: Búsqueda por ruta y fecha
SELECT bookingId, customerId, price, cabin
FROM `travel-sample`
WHERE type = "booking"
  AND origin = "JFK"
  AND destination = "LHR"
  AND departureDate >= "2024-06-01"
  AND departureDate <= "2024-06-30";

-- Q3: Reservas pendientes por precio
SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample`
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;

-- Q4: Dashboard de cliente
SELECT bookingId, status, departureDate, price
FROM `travel-sample`
WHERE type = "booking"
  AND customerId = "cust_99999"
ORDER BY departureDate DESC;

-- Q5: Conteo por origen
SELECT origin, COUNT(*) AS total
FROM `travel-sample`
WHERE type = "booking" AND status = "confirmed"
GROUP BY origin;
EOF

cbq -u Administrator -p password \
    -engine=http://node1:8093/ \
    -f /tmp/benchmark_queries.sql 2>&1 | grep -E "elapsed|rows"
```

### 7.3 Verificación de cobertura de consultas (sin Fetch)

```sql
-- Verificar que Q4 no usa Fetch (covering index activo)
SELECT RAW (TOSTRING(p) NOT LIKE "%Fetch%") AS no_fetch_q4
FROM (SELECT META().plan AS p
      FROM `travel-sample`
      WHERE type = "booking" AND customerId = "cust_99999"
      ORDER BY departureDate DESC LIMIT 1) subq;
```

Resultado esperado: `[true]`

### 7.4 Tabla de resultados esperados

Completa esta tabla en tu cuaderno de laboratorio con los valores medidos:

| Consulta | Latencia Baseline (ms) | Latencia Final (ms) | Mejora (×) | Índice Utilizado | Fetch Eliminado |
|----------|------------------------|---------------------|------------|------------------|-----------------|
| Q1       | _____                  | _____               | _____      | _____            | N/A             |
| Q2       | _____                  | _____               | _____      | _____            | Sí / No         |
| Q3       | _____                  | _____               | _____      | _____            | N/A             |
| Q4       | _____                  | _____               | _____      | _____            | **Sí**          |
| Q5       | _____                  | _____               | _____      | _____            | N/A             |

---

## 8. Resolución de Problemas

### Problema 1: El índice permanece en estado `building` por más de 10 minutos

**Síntomas:**
- `SELECT state FROM system:indexes WHERE name = "idx_booking_...";` devuelve `"building"` indefinidamente.
- La Consola Web muestra el índice con un porcentaje de progreso estancado.
- El nodo de índice muestra alta utilización de CPU o I/O en `top`.

**Causa probable:**
El Index Service está procesando una gran cantidad de mutaciones pendientes en la cola DCP, o hay contención de recursos entre múltiples índices que se construyen simultáneamente. Con 200 K documentos y hardware limitado, la construcción puede tomar más tiempo del esperado. También puede ocurrir si el nodo de índice tiene memoria insuficiente para el buffer de construcción de Plasma.

**Solución:**

```bash
# 1. Verificar el progreso real de construcción vía REST API
curl -s -u ${CB_USER}:${CB_PASS} \
  "http://node2:9102/api/v1/stats" \
  | jq 'to_entries | map(select(.key | test("num_docs_queued|num_docs_indexed"))) | from_entries'

# 2. Verificar memoria disponible en el nodo de índice
curl -s -u ${CB_USER}:${CB_PASS} \
  "${CB_HOST}/pools/default/buckets/travel-sample" \
  | jq '.nodes[] | {hostname, memoryFree}'

# 3. Si hay contención, reducir la memoria de indexación y reiniciar el servicio
# En la Consola Web: Settings → Index → Max Index RAM → reducir al 60% de la RAM disponible

# 4. Si el índice está genuinamente atascado (sin progreso en 5+ minutos):
# Opción A: Cancelar y reconstruir
cbq -u Administrator -p password -engine=http://node1:8093/ \
    --script <<< "DROP INDEX \`travel-sample\`.idx_booking_flight;"
cbq -u Administrator -p password -engine=http://node1:8093/ \
    --script <<< "CREATE INDEX idx_booking_flight ON \`travel-sample\`(flightId, departureDate, status) WHERE type = 'booking';"
```

---

### Problema 2: Las consultas no usan el índice esperado (Query Service elige un índice diferente)

**Síntomas:**
- `EXPLAIN` muestra que el Query Service usa `idx_booking_status` en lugar de `idx_booking_status_price` para Q3.
- O bien, el plan muestra `PrimaryScan` a pesar de que el índice relevante está `online`.
- Las latencias no mejoran como se esperaba tras crear el índice.

**Causa probable:**
El optimizador de consultas de Couchbase elige el índice basándose en estadísticas de cardinalidad y en la selectividad estimada del índice. Si las estadísticas están desactualizadas, el optimizador puede tomar una decisión subóptima. También puede ocurrir si el índice no cubre exactamente los predicados de la consulta (por ejemplo, el campo `type` en el `WHERE` del índice no coincide con el tipo del documento consultado) o si el índice fue creado con un error tipográfico en el nombre del campo.

**Solución:**

```sql
-- 1. Verificar que el índice tiene la definición correcta
SELECT name, index_key, `condition`
FROM system:indexes
WHERE name = "idx_booking_status_price";
-- Confirmar que index_key = ["status", "price"] y condition contiene "booking"

-- 2. Forzar el uso del índice específico para diagnóstico
EXPLAIN SELECT bookingId, customerId, origin, destination, price
FROM `travel-sample` USE INDEX (idx_booking_status_price USING GSI)
WHERE type = "booking"
  AND status = "pending"
  AND price BETWEEN 500 AND 2000;

-- 3. Si el índice forzado funciona pero no se selecciona automáticamente,
-- actualizar las estadísticas del bucket
UPDATE STATISTICS FOR `travel-sample`(customerId, status, origin, destination, price, departureDate);

-- 4. Verificar que el índice está en el nodo correcto y en estado online
SELECT name, state, nodes
FROM system:indexes
WHERE name = "idx_booking_status_price";

-- 5. Si el índice tiene un error en la condición, eliminarlo y recrearlo
DROP INDEX `travel-sample`.idx_booking_status_price;
CREATE INDEX idx_booking_status_price
ON `travel-sample`(status, price)
WHERE type = "booking";
```

```bash
# 6. Verificar logs del Query Service para mensajes de selección de índice
sudo grep -i "index" /opt/couchbase/var/lib/couchbase/logs/query.log \
  | tail -50 | grep -i "plan\|select\|error"
```

---

## 9. Limpieza del Entorno

Ejecuta los siguientes comandos al finalizar el laboratorio para eliminar los índices creados y liberar recursos. **No ejecutes la limpieza si vas a continuar con el Lab 05.**

```sql
-- Eliminar todos los índices creados en este laboratorio
DROP INDEX `travel-sample`.idx_booking_customer;
DROP INDEX `travel-sample`.idx_booking_status;
DROP INDEX `travel-sample`.idx_booking_route_date;
DROP INDEX `travel-sample`.idx_booking_status_price;
DROP INDEX `travel-sample`.idx_booking_cancelled;
DROP INDEX `travel-sample`.idx_booking_customer_covering;
DROP INDEX `travel-sample`.idx_booking_route_covering;
DROP INDEX `travel-sample`.idx_booking_origin_partitioned;
DROP INDEX `travel-sample`.idx_booking_customer_ha;
DROP INDEX `travel-sample`.idx_booking_cabin_price;
DROP INDEX `travel-sample`.idx_booking_flight;
DROP INDEX `travel-sample`.idx_booking_date_origin;
```

```sql
-- Verificar que todos fueron eliminados (solo debe quedar #primary)
SELECT name FROM system:indexes
WHERE keyspace_id = "travel-sample"
  AND name != "#primary";
-- Resultado esperado: 0 filas
```

```bash
# Opcional: eliminar los documentos de tipo "booking" generados si el dataset
# aumentado no se necesita en labs posteriores
cbq -u Administrator -p password -engine=http://node1:8093/ \
    --script <<< "DELETE FROM \`travel-sample\` WHERE type = 'booking';"

# Eliminar archivos temporales del cliente
rm -f /tmp/benchmark_queries.sql
rm -f ~/generate_bookings.py
```

---

## 10. Resumen

### Lo que construiste en este laboratorio

En este laboratorio diseñaste e implementaste una estrategia completa de indexación para un sistema de reservas de viajes bajo carga empresarial real. La progresión fue deliberada:

1. **Análisis de patrones de acceso** → identificaste 5 consultas críticas que representan 1 000 QPS y estableciste una línea base de rendimiento con solo el índice primario.

2. **Índices simples con partial index** → aplicaste la cláusula `WHERE type = "booking"` desde el primer índice, reduciendo el tamaño del índice al excluir documentos irrelevantes. Comprendiste cómo el Index Service usa DCP para mantener estos índices sincronizados con el Data Service de forma asíncrona.

3. **Índices compuestos con orden optimizado** → aplicaste el principio fundamental: campos de igualdad primero, campos de rango al final. Verificaste con `EXPLAIN` que los `spans` del índice cubren todos los predicados de la consulta.

4. **Covering indexes** → eliminaste el operador `Fetch` del plan de ejecución incluyendo todos los campos proyectados en el índice. Esto elimina el viaje adicional al Data Service, reduciendo latencia y carga en el servicio de datos.

5. **Índices particionados** → distribuiste la carga de escaneo entre nodos del Index Service usando `PARTITION BY HASH`, apropiado para consultas de agregación sobre grandes volúmenes.

6. **Réplicas de índice y failover** → verificaste que `num_replica: 1` garantiza continuidad de servicio ante la pérdida de un nodo de índice, sin intervención manual.

7. **Deferred Build** → dominaste el proceso de construcción diferida para crear múltiples índices eficientemente, minimizando el impacto en el Data Service durante ventanas de mantenimiento.

8. **Recuperación de índice** → ejecutaste el procedimiento estándar de DROP → CREATE → BUILD para recuperar un índice en estado inválido.

### Principios de diseño consolidados

| Decisión de diseño          | Cuándo aplicarla                                                        |
|-----------------------------|-------------------------------------------------------------------------|
| **Partial index**           | Cuando las consultas filtran siempre por un campo de tipo o estado fijo |
| **Índice compuesto**        | Cuando la consulta tiene múltiples predicados; igualdad antes que rango |
| **Covering index**          | Cuando la latencia es crítica y el conjunto de campos proyectados es pequeño |
| **PARTITION BY HASH**       | Para índices grandes con consultas de agregación distribuida            |
| **num_replica**             | Para índices que atienden consultas críticas de alta frecuencia         |
| **defer_build**             | Para crear múltiples índices durante ventanas de mantenimiento          |

### Recursos adicionales

- [Documentación oficial: CREATE INDEX — Couchbase 7.6](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/createindex.html)
- [Documentación oficial: Partial Indexes](https://docs.couchbase.com/server/current/learn/services-and-indexes/indexes/partial-indexes.html)
- [Documentación oficial: Covering Indexes](https://docs.couchbase.com/server/current/learn/services-and-indexes/indexes/covering-indexes.html)
- [Documentación oficial: Partitioned Indexes](https://docs.couchbase.com/server/current/learn/services-and-indexes/indexes/index-partitioning.html)
- [Documentación oficial: Index Replicas](https://docs.couchbase.com/server/current/learn/services-and-indexes/indexes/index-replication.html)
- [Blog técnico: Index Advisor (ADVISE) en Couchbase](https://www.couchbase.com/blog/index-advisor-couchbase/)

---
