# Diagnóstico y optimización de consultas SQL++

## 1. Metadatos

| Campo            | Valor                                      |
|------------------|--------------------------------------------|
| **Duración**     | 108 minutos                                |
| **Complejidad**  | Alta                                       |
| **Nivel Bloom**  | Aplicar (Apply)                            |
| **Servicio**     | Query Service — SQL++                      |
| **Dataset**      | travel-sample + datos generados (~500K docs)|

---

## 2. Descripción General

En este laboratorio el estudiante diagnostica y optimiza consultas SQL++ progresivamente más complejas sobre el dataset `travel-sample` ampliado a un mínimo de 500 000 documentos. Partiendo de la arquitectura del Query Service estudiada en la Lección 3.1 —su pipeline interno de Parser → Optimizer → Execution Engine y su comunicación con el Data Service e Index Service— se aplican las herramientas nativas `EXPLAIN`, `ADVISE` y `PROFILE` para identificar operadores costosos, obtener recomendaciones de índices y medir tiempos reales por fase. El laboratorio culmina con la implementación de *prepared statements* con parámetros nombrados, la configuración de *timeouts* y la observación del comportamiento del Query Service bajo carga concurrente.

---

## 3. Objetivos de Aprendizaje

- [ ] Analizar el plan de ejecución de consultas SQL++ complejas con `EXPLAIN` e identificar operadores costosos (`PrimaryScan`, `Fetch`, `HashJoin`, etc.).
- [ ] Utilizar `ADVISE` para obtener recomendaciones automáticas de índices y comparar el plan antes y después de crearlos.
- [ ] Aplicar `PROFILE` para medir tiempos de ejecución por fase del pipeline e identificar cuellos de botella reales.
- [ ] Implementar *prepared statements* con parámetros nombrados y configurar `timeout` y `max_parallelism` para consultas en producción.
- [ ] Correlacionar las métricas del Query Monitor de la Web Console con los resultados obtenidos por CLI.

---

## 4. Prerrequisitos

### Conocimiento previo
- Lab 01-00-01 completado: clúster operativo de al menos 3 nodos con Query Service activo.
- Dataset `travel-sample` cargado en Couchbase Server 7.6.x.
- Dominio de SQL estándar: `JOIN`, `GROUP BY`, subconsultas, funciones de agregación.
- Comprensión básica de planes de ejecución de bases de datos relacionales.
- `cbq` instalado y funcional en el nodo cliente.

### Acceso requerido
- Credenciales de administrador del clúster (`Administrator` / `password` o equivalente).
- Acceso SSH al nodo cliente/generador de carga.
- Acceso a la Web Console en `http://<nodo-query>:8091`.
- Puerto 8093 accesible desde el nodo cliente hacia al menos un nodo Query.

---

## 5. Entorno de Laboratorio

### Hardware mínimo

| Componente          | Especificación mínima                              |
|---------------------|----------------------------------------------------|
| Nodos Couchbase     | 3 VMs, 8 vCPUs, 16 GB RAM, 100 GB SSD cada una    |
| Nodo cliente        | 1 VM, 4 vCPUs, 8 GB RAM                           |
| Red inter-nodo      | < 5 ms latencia, ≥ 1 Gbps                         |

### Software requerido

| Herramienta              | Versión         |
|--------------------------|-----------------|
| Couchbase Server EE      | 7.6.x           |
| cbq (Query Shell)        | Incluido con 7.6|
| curl                     | 7.x o superior  |
| jq                       | 1.6 o superior  |
| Python                   | 3.10 o superior |
| cbworkloadgen            | Incluido con 7.6|

### Variables de entorno — configurar antes de comenzar

Ejecutar en el nodo cliente para toda la duración del laboratorio:

```bash
export CB_HOST="127.0.0.1"          # IP del nodo con Query Service
export CB_ADMIN_PORT="8091"
export CB_QUERY_PORT="8093"
export CB_USER="Administrator"
export CB_PASS="password"           # Cambiar según el entorno
export CB_BUCKET="travel-sample"
```

### Verificación del entorno

```bash
# 1. Confirmar que el Query Service responde
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{"statement":"SELECT RAW \"OK\" AS status"}' | jq .

# 2. Verificar que travel-sample está cargado
curl -s -u ${CB_USER}:${CB_PASS} \
     http://${CB_HOST}:${CB_ADMIN_PORT}/pools/default/buckets/${CB_BUCKET} | \
     jq '.basicStats.itemCount'
```

**Salida esperada del paso 1:**
```json
{
  "requestID": "...",
  "results": ["OK"],
  "status": "success"
}
```

**Salida esperada del paso 2:** un número ≥ 63 000 (o ≥ 500 000 si los datos adicionales ya están cargados).

---

## 6. Pasos del Laboratorio

---

### Paso 1 — Ampliar el dataset hasta 500 000 documentos

**Objetivo:** Garantizar un volumen de datos suficiente para que las diferencias de rendimiento entre consultas optimizadas y no optimizadas sean estadísticamente significativas y observables.

#### Instrucciones

**1.1** Crear el script de generación de datos adicionales:

```python
# archivo: generate_routes.py
# Genera documentos de tipo "route_extended" en travel-sample
# Ejecutar: python3 generate_routes.py

from couchbase.cluster import Cluster
from couchbase.options import ClusterOptions
from couchbase.auth import PasswordAuthenticator
import random, uuid, time

auth = PasswordAuthenticator("Administrator", "password")
cluster = Cluster("couchbase://127.0.0.1", ClusterOptions(auth))
cluster.wait_until_ready(timeout=10)

bucket  = cluster.bucket("travel-sample")
scope   = bucket.scope("inventory")
col     = scope.collection("route")

airlines = ["AA", "UA", "DL", "BA", "LH", "AF", "IB", "QR", "EK", "SQ"]
airports = ["JFK","LAX","ORD","DFW","DEN","SFO","LAS","SEA","MCO","EWR",
            "LHR","CDG","FRA","AMS","MAD","FCO","ZUR","VIE","CPH","ARN"]

BATCH  = 500
TARGET = 450_000   # documentos a insertar (travel-sample ya trae ~63K)
inserted = 0
start = time.time()

while inserted < TARGET:
    docs = {}
    for _ in range(BATCH):
        doc_id = f"route_ext_{uuid.uuid4().hex}"
        orig   = random.choice(airports)
        dest   = random.choice([a for a in airports if a != orig])
        docs[doc_id] = {
            "type":           "route_extended",
            "airline":        random.choice(airlines),
            "airlineid":      f"airline_{random.randint(100,9999)}",
            "sourceairport":  orig,
            "destinationairport": dest,
            "stops":          random.randint(0, 2),
            "equipment":      random.choice(["738","320","77W","332","E75"]),
            "distance_km":    round(random.uniform(200, 14000), 1),
            "price_usd":      round(random.uniform(49, 1800), 2),
            "seats_available": random.randint(0, 180),
            "year":           random.randint(2018, 2024),
            "month":          random.randint(1, 12)
        }
    col.upsert_multi(docs)
    inserted += BATCH
    if inserted % 50_000 == 0:
        elapsed = time.time() - start
        print(f"  {inserted:,} docs insertados — {elapsed:.1f}s")

print(f"Completado: {inserted:,} documentos en {time.time()-start:.1f}s")
cluster.close()
```

**1.2** Ejecutar el script:

```bash
cd ~ && python3 generate_routes.py
```

**1.3** Verificar el conteo total:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     http://${CB_HOST}:${CB_ADMIN_PORT}/pools/default/buckets/${CB_BUCKET} | \
     jq '.basicStats.itemCount'
```

**Salida esperada:** valor ≥ 500 000.

**1.4** Crear el índice primario temporal en la colección `route` para permitir consultas de exploración iniciales (se eliminará en pasos posteriores):

```sql
-- Ejecutar en cbq o curl
CREATE PRIMARY INDEX idx_route_primary ON `travel-sample`.`inventory`.`route`;
```

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{"statement":"CREATE PRIMARY INDEX idx_route_primary ON `travel-sample`.`inventory`.`route`"}'
```

**Verificación:**

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{"statement":"SELECT COUNT(*) AS total FROM `travel-sample`.`inventory`.`route`"}' | \
     jq '.results'
```

Resultado esperado: `[{"total": <número ≥ 500000>}]`

---

### Paso 2 — Análisis de planes de ejecución con EXPLAIN

**Objetivo:** Comprender cómo el Optimizer del Query Service genera planes de ejecución y aprender a identificar operadores costosos —`PrimaryScan`, `Fetch` innecesarios— que indican ausencia de índices selectivos.

#### Instrucciones

**2.1** Abrir `cbq` conectado al clúster:

```bash
cbq -u ${CB_USER} -p ${CB_PASS} -engine http://${CB_HOST}:${CB_QUERY_PORT}
```

**2.2** Ejecutar `EXPLAIN` sobre una consulta simple sin índices secundarios:

```sql
-- Consulta Q1: Rutas de una aerolínea específica con precio alto
EXPLAIN
SELECT r.airline, r.sourceairport, r.destinationairport,
       r.price_usd, r.distance_km
FROM   `travel-sample`.`inventory`.`route` AS r
WHERE  r.airline = "AA"
  AND  r.price_usd > 500
ORDER BY r.price_usd DESC
LIMIT 20;
```

**Salida esperada (fragmento):** El plan mostrará un operador `PrimaryScan` sobre `idx_route_primary`, seguido de `Fetch`, `Filter`, `Order` y `Limit`. Ejemplo parcial:

```json
{
  "#operator": "Sequence",
  "~children": [
    {
      "#operator": "PrimaryScan3",
      "index": "idx_route_primary",
      "keyspace": "route",
      "~cost": 512847.3,
      "~cardinality": 513000
    },
    { "#operator": "Fetch", "~cost": 1026000 },
    { "#operator": "Filter", "~cost": 1100 },
    { "#operator": "Order",  "~cost": 220   },
    { "#operator": "Limit",  "~cost": 0.1   }
  ]
}
```

> **Nota de análisis:** El campo `~cost` en el `PrimaryScan3` refleja que el optimizador estima escanear la totalidad de la colección (~513 000 documentos) antes de filtrar. El `Fetch` duplica el costo porque debe recuperar cada documento del Data Service vía protocolo memcached binario (puerto 11210), como se estudió en la Lección 3.1.

**2.3** Registrar los valores clave del plan:

```bash
# Guardar el plan en un archivo para comparación posterior
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "EXPLAIN SELECT r.airline, r.sourceairport, r.destinationairport, r.price_usd, r.distance_km FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = \"AA\" AND r.price_usd > 500 ORDER BY r.price_usd DESC LIMIT 20"
     }' | jq '.results[0]' > /tmp/plan_q1_before.json

echo "Plan guardado en /tmp/plan_q1_before.json"
cat /tmp/plan_q1_before.json | jq '.. | .["#operator"]? // empty' | sort | uniq -c | sort -rn
```

**Verificación:** El comando `jq` final debe mostrar `PrimaryScan3` con conteo ≥ 1, confirmando que no hay índice secundario en uso.

---

### Paso 3 — Recomendaciones automáticas con ADVISE y el Cost-Based Optimizer

**Objetivo:** Utilizar el comando `ADVISE` para obtener recomendaciones automáticas de índices del CBO y evaluar el impacto de crearlos sobre el plan de ejecución.

#### Instrucciones

**3.1** Ejecutar `ADVISE` sobre la consulta Q1:

```sql
-- En cbq:
ADVISE
SELECT r.airline, r.sourceairport, r.destinationairport,
       r.price_usd, r.distance_km
FROM   `travel-sample`.`inventory`.`route` AS r
WHERE  r.airline = "AA"
  AND  r.price_usd > 500
ORDER BY r.price_usd DESC
LIMIT 20;
```

**Salida esperada (fragmento):**

```json
{
  "recommended_indexes": {
    "covering_indexes": [
      {
        "index_statement": "CREATE INDEX adv_airline_price_usd ON `travel-sample`.`inventory`.`route`(`airline`,`price_usd` DESC) WHERE `airline` IS NOT MISSING",
        "keyspace_alias": "route as r",
        "query_context": "`travel-sample`.`inventory`"
      }
    ]
  }
}
```

**3.2** Crear el índice recomendado (adaptado para incluir campos de proyección y hacerlo *covering*):

```sql
-- Índice compuesto + covering para Q1
CREATE INDEX idx_route_airline_price
ON `travel-sample`.`inventory`.`route`
   (airline, price_usd DESC, sourceairport, destinationairport, distance_km)
WHERE airline IS NOT MISSING;
```

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "CREATE INDEX idx_route_airline_price ON `travel-sample`.`inventory`.`route`(airline, price_usd DESC, sourceairport, destinationairport, distance_km) WHERE airline IS NOT MISSING"
     }' | jq '{status: .status, errors: .errors}'
```

**3.3** Actualizar estadísticas del CBO:

```sql
UPDATE STATISTICS FOR `travel-sample`.`inventory`.`route`
   (airline, price_usd, sourceairport, destinationairport, distance_km);
```

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "UPDATE STATISTICS FOR `travel-sample`.`inventory`.`route`(airline, price_usd, sourceairport, destinationairport, distance_km)"
     }' | jq '{status: .status}'
```

**3.4** Re-ejecutar `EXPLAIN` y comparar planes:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "EXPLAIN SELECT r.airline, r.sourceairport, r.destinationairport, r.price_usd, r.distance_km FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = \"AA\" AND r.price_usd > 500 ORDER BY r.price_usd DESC LIMIT 20"
     }' | jq '.results[0]' > /tmp/plan_q1_after.json

# Comparar operadores antes y después
echo "=== ANTES ===" && cat /tmp/plan_q1_before.json | jq '.. | .["#operator"]? // empty' | sort | uniq -c
echo "=== DESPUÉS ===" && cat /tmp/plan_q1_after.json  | jq '.. | .["#operator"]? // empty' | sort | uniq -c
```

**Salida esperada después de crear el índice:** El operador `PrimaryScan3` debe desaparecer y ser reemplazado por `IndexScan3` sobre `idx_route_airline_price`. Si el índice es *covering*, el operador `Fetch` también desaparecerá, indicando que todos los campos necesarios se obtienen directamente del índice sin consultar el Data Service.

**Verificación:**

```bash
grep -c "IndexScan3" /tmp/plan_q1_after.json && \
echo "✓ IndexScan3 presente — índice en uso" || \
echo "✗ Índice no utilizado — revisar predicados"
```

---

### Paso 4 — Análisis de consultas complejas: JOIN, GROUP BY y subconsultas

**Objetivo:** Aplicar `EXPLAIN` y `ADVISE` a consultas de mayor complejidad para identificar operadores de join costosos y estrategias de agregación ineficientes.

#### Instrucciones

**4.1** Consulta Q2 — JOIN entre `route` y `airline` con agregación:

```sql
-- En cbq: analizar con EXPLAIN
EXPLAIN
SELECT a.name AS airline_name,
       COUNT(r.`type`) AS total_routes,
       AVG(r.price_usd) AS avg_price,
       MAX(r.distance_km) AS max_distance
FROM   `travel-sample`.`inventory`.`route`   AS r
JOIN   `travel-sample`.`inventory`.`airline` AS a
       ON r.airlineid = META(a).id
WHERE  r.stops = 0
  AND  r.seats_available > 10
GROUP BY a.name
HAVING COUNT(r.`type`) > 5
ORDER BY total_routes DESC
LIMIT 10;
```

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "EXPLAIN SELECT a.name AS airline_name, COUNT(r.type) AS total_routes, AVG(r.price_usd) AS avg_price, MAX(r.distance_km) AS max_distance FROM `travel-sample`.`inventory`.`route` AS r JOIN `travel-sample`.`inventory`.`airline` AS a ON r.airlineid = META(a).id WHERE r.stops = 0 AND r.seats_available > 10 GROUP BY a.name HAVING COUNT(r.type) > 5 ORDER BY total_routes DESC LIMIT 10"
     }' | jq '.results[0]' | tee /tmp/plan_q2.json | \
     jq '.. | .["#operator"]? // empty' | sort | uniq -c | sort -rn
```

**Puntos de análisis en el plan Q2:**
- ¿Qué tipo de join seleccionó el optimizer: `NestedLoopJoin`, `HashJoin` o `IndexJoin`?
- ¿El operador `Group` aparece antes o después del `Order`?
- ¿Existe un `Fetch` sobre la colección `airline` o el join se resuelve mediante índice?

**4.2** Ejecutar `ADVISE` sobre Q2 y crear los índices recomendados:

```sql
ADVISE
SELECT a.name AS airline_name,
       COUNT(r.`type`) AS total_routes,
       AVG(r.price_usd) AS avg_price,
       MAX(r.distance_km) AS max_distance
FROM   `travel-sample`.`inventory`.`route`   AS r
JOIN   `travel-sample`.`inventory`.`airline` AS a
       ON r.airlineid = META(a).id
WHERE  r.stops = 0
  AND  r.seats_available > 10
GROUP BY a.name
HAVING COUNT(r.`type`) > 5
ORDER BY total_routes DESC
LIMIT 10;
```

Crear los índices recomendados por `ADVISE` (ejemplo típico):

```sql
-- Índice sobre campos de filtro en route
CREATE INDEX idx_route_stops_seats
ON `travel-sample`.`inventory`.`route`
   (stops, seats_available, airlineid, price_usd, distance_km, `type`);

-- Índice sobre airline para el JOIN
CREATE INDEX idx_airline_name
ON `travel-sample`.`inventory`.`airline`(name);
```

**4.3** Consulta Q3 — UNNEST con subconsulta correlacionada:

```sql
EXPLAIN
SELECT h.name AS hotel_name,
       h.city,
       h.country,
       r.ratings.Overall AS overall_rating,
       (SELECT RAW COUNT(*)
        FROM   `travel-sample`.`inventory`.`landmark` AS lm
        WHERE  lm.city = h.city) AS landmarks_nearby
FROM   `travel-sample`.`inventory`.`hotel` AS h
UNNEST h.reviews AS r
WHERE  h.country = "United States"
  AND  r.ratings.Overall >= 4
  AND  h.free_parking = TRUE
ORDER BY overall_rating DESC
LIMIT 15;
```

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "EXPLAIN SELECT h.name AS hotel_name, h.city, h.country, r.ratings.Overall AS overall_rating, (SELECT RAW COUNT(*) FROM `travel-sample`.`inventory`.`landmark` AS lm WHERE lm.city = h.city) AS landmarks_nearby FROM `travel-sample`.`inventory`.`hotel` AS h UNNEST h.reviews AS r WHERE h.country = \"United States\" AND r.ratings.Overall >= 4 AND h.free_parking = TRUE ORDER BY overall_rating DESC LIMIT 15"
     }' | jq '.results[0]' | tee /tmp/plan_q3.json | \
     jq '.. | .["#operator"]? // empty' | sort | uniq -c | sort -rn
```

**Verificación de los tres planes:**

```bash
for f in /tmp/plan_q1_after.json /tmp/plan_q2.json /tmp/plan_q3.json; do
  echo "--- $f ---"
  cat $f | jq '.. | .["~cost"]? // empty' | \
    python3 -c "import sys,json; vals=[json.loads(l) for l in sys.stdin if l.strip()]; print(f'  Costo total estimado: {sum(vals):.1f}')"
done
```

---

### Paso 5 — Medición de tiempos reales con PROFILE

**Objetivo:** Usar `PROFILE` para obtener tiempos de ejecución reales por fase del pipeline y contrastarlos con las estimaciones del `EXPLAIN`, identificando dónde se concentra el tiempo real.

#### Instrucciones

**5.1** Ejecutar Q1 con `PROFILE`:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "SELECT r.airline, r.sourceairport, r.destinationairport, r.price_usd, r.distance_km FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = \"AA\" AND r.price_usd > 500 ORDER BY r.price_usd DESC LIMIT 20",
       "profile": "timings"
     }' | jq '{
       status:        .status,
       elapsedTime:   .metrics.elapsedTime,
       executionTime: .metrics.executionTime,
       resultCount:   .metrics.resultCount,
       profile_phases: [.profile.executionTimings | .. | {op: .["#operator"], time: .["#time"]} | select(.op != null)]
     }' | tee /tmp/profile_q1.json
```

**5.2** Interpretar los campos clave del perfil:

| Campo en PROFILE | Significado |
|-----------------|-------------|
| `#time`         | Tiempo acumulado en ese operador (formato `"1.23ms"`) |
| `#itemsIn`      | Documentos/filas recibidas por el operador |
| `#itemsOut`     | Documentos/filas emitidas al operador siguiente |
| `#phaseSwitches`| Veces que el operador cedió el control al scheduler |

**5.3** Ejecutar Q2 con PROFILE y comparar la fase de Join:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "SELECT a.name AS airline_name, COUNT(r.type) AS total_routes, AVG(r.price_usd) AS avg_price, MAX(r.distance_km) AS max_distance FROM `travel-sample`.`inventory`.`route` AS r JOIN `travel-sample`.`inventory`.`airline` AS a ON r.airlineid = META(a).id WHERE r.stops = 0 AND r.seats_available > 10 GROUP BY a.name HAVING COUNT(r.type) > 5 ORDER BY total_routes DESC LIMIT 10",
       "profile": "timings"
     }' | jq '{
       elapsedTime:   .metrics.elapsedTime,
       executionTime: .metrics.executionTime,
       mutationCount: .metrics.mutationCount,
       sortCount:     .metrics.sortCount,
       top_operators: [.profile.executionTimings | .. | select(.["#time"] != null) | {op: .["#operator"], time: .["#time"], itemsOut: .["#itemsOut"]}] | sort_by(.time) | reverse | .[0:5]
     }' | tee /tmp/profile_q2.json
```

**5.4** Comparar `elapsedTime` vs `executionTime` para cuantificar latencia de red/serialización:

```bash
python3 - << 'EOF'
import json, re

def parse_ms(s):
    """Convierte '12.34ms' o '1.2s' a milisegundos"""
    if s is None: return 0
    s = s.strip()
    if s.endswith('ms'): return float(s[:-2])
    if s.endswith('µs'): return float(s[:-2]) / 1000
    if s.endswith('s'):  return float(s[:-1]) * 1000
    return 0

for fname, label in [('/tmp/profile_q1.json','Q1'), ('/tmp/profile_q2.json','Q2')]:
    with open(fname) as f:
        data = json.load(f)
    elapsed   = parse_ms(data.get('elapsedTime','0ms'))
    execution = parse_ms(data.get('executionTime','0ms'))
    overhead  = elapsed - execution
    print(f"{label}: elapsed={elapsed:.2f}ms  exec={execution:.2f}ms  overhead={overhead:.2f}ms ({overhead/elapsed*100:.1f}%)")
EOF
```

**Salida esperada (valores orientativos):**
```
Q1: elapsed=8.50ms   exec=6.20ms   overhead=2.30ms (27.1%)
Q2: elapsed=45.30ms  exec=41.80ms  overhead=3.50ms (7.7%)
```

> El overhead en Q1 es proporcionalmente mayor porque la consulta es muy rápida (índice covering); en Q2, el tiempo de ejecución domina por la agregación.

**Verificación:**

```bash
# Confirmar que los archivos de perfil existen y tienen contenido
for f in /tmp/profile_q1.json /tmp/profile_q2.json; do
  wc -c $f && echo "✓ $f generado correctamente"
done
```

---

### Paso 6 — Prepared Statements, parámetros nombrados y control de carga

**Objetivo:** Implementar *prepared statements* para eliminar el overhead de parsing/compilación en consultas repetitivas, configurar `timeout` para proteger el clúster de consultas runaway, y establecer `max_parallelism` para controlar el uso de CPU.

#### Instrucciones

**6.1** Crear un *prepared statement* para Q1:

```bash
# Preparar la consulta con parámetros nombrados ($airline, $min_price)
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "PREPARE stmt_routes_by_airline AS SELECT r.airline, r.sourceairport, r.destinationairport, r.price_usd, r.distance_km FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = $airline AND r.price_usd > $min_price ORDER BY r.price_usd DESC LIMIT 20",
       "query_context": "`travel-sample`.`inventory`"
     }' | jq '{name: .results[0].name, operator: .results[0].operator}'
```

**Salida esperada:**
```json
{
  "name": "stmt_routes_by_airline",
  "operator": "..."
}
```

**6.2** Ejecutar el *prepared statement* con parámetros nombrados:

```bash
# Primera ejecución (carga el plan en caché)
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "prepared": "stmt_routes_by_airline",
       "named_args": {
         "airline":   "UA",
         "min_price": 300
       },
       "timeout": "5000ms",
       "max_parallelism": 2
     }' | jq '{status: .status, count: .metrics.resultCount, elapsed: .metrics.elapsedTime}'
```

**6.3** Medir la diferencia de latencia entre ejecución normal y prepared:

```bash
# Función de benchmark simple
benchmark_query() {
  local label=$1
  local payload=$2
  local total=0
  for i in $(seq 1 5); do
    ms=$(curl -s -u ${CB_USER}:${CB_PASS} \
         -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
         -H "Content-Type: application/json" \
         -d "$payload" | \
         jq -r '.metrics.executionTime' | \
         python3 -c "import sys; s=sys.stdin.read().strip(); print(float(s[:-2]) if s.endswith('ms') else float(s[:-1])*1000 if s.endswith('s') else 0)")
    total=$(python3 -c "print($total + $ms)")
  done
  avg=$(python3 -c "print(f'{$total/5:.2f}ms')")
  echo "$label — promedio 5 ejecuciones: $avg"
}

# Sin prepared statement
benchmark_query "Sin prepared" '{
  "statement": "SELECT r.airline, r.sourceairport, r.destinationairport, r.price_usd, r.distance_km FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = \"DL\" AND r.price_usd > 400 ORDER BY r.price_usd DESC LIMIT 20"
}'

# Con prepared statement
benchmark_query "Con prepared" '{
  "prepared": "stmt_routes_by_airline",
  "named_args": {"airline": "DL", "min_price": 400},
  "timeout": "5000ms"
}'
```

**Salida esperada:** El prepared statement debe mostrar una reducción de 15–40% en `executionTime` en ejecuciones repetidas, ya que el plan compilado se reutiliza desde la caché del Query Service.

**6.4** Verificar el comportamiento del `timeout` con una consulta deliberadamente lenta:

```bash
# Consulta sin índice con timeout de 1 segundo
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "SELECT COUNT(*) FROM `travel-sample`.`inventory`.`route` AS r WHERE LOWER(r.equipment) LIKE \"%73%\" AND r.year BETWEEN 2019 AND 2023",
       "timeout": "1000ms"
     }' | jq '{status: .status, errors: .errors}'
```

**Salida esperada (si la consulta supera 1s):**
```json
{
  "status": "timeout",
  "errors": [{"code": 1080, "msg": "Timeout 1000ms exceeded"}]
}
```

**Verificación del caché de prepared statements:**

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     http://${CB_HOST}:${CB_QUERY_PORT}/admin/prepareds | \
     jq '[.[] | {name: .name, uses: .uses, avgElapsed: .avgElapsed}]'
```

---

### Paso 7 — Observación bajo carga concurrente con Query Monitor

**Objetivo:** Generar carga concurrente de consultas y observar el comportamiento del Query Service en la Web Console (Query Monitor), correlacionando las métricas de la UI con los tiempos obtenidos por CLI.

#### Instrucciones

**7.1** Crear el script de carga concurrente:

```bash
cat > /tmp/concurrent_queries.sh << 'SCRIPT'
#!/bin/bash
# Lanza N consultas concurrentes contra el Query Service
CB_HOST="${CB_HOST:-127.0.0.1}"
CB_USER="${CB_USER:-Administrator}"
CB_PASS="${CB_PASS:-password}"
CB_QUERY_PORT="${CB_QUERY_PORT:-8093}"
CONCURRENCY=20
ITERATIONS=50

run_query() {
  local id=$1
  local airline=$(echo "AA UA DL BA LH AF" | tr ' ' '\n' | shuf -n1)
  local price=$((RANDOM % 600 + 100))
  curl -s -u ${CB_USER}:${CB_PASS} \
       -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
       -H "Content-Type: application/json" \
       -d "{
         \"prepared\": \"stmt_routes_by_airline\",
         \"named_args\": {\"airline\": \"${airline}\", \"min_price\": ${price}},
         \"timeout\": \"10000ms\"
       }" | jq -r '"Worker \(.requestID[0:8]): \(.metrics.executionTime)"' 2>/dev/null
}
export -f run_query
export CB_HOST CB_USER CB_PASS CB_QUERY_PORT

echo "Iniciando $CONCURRENCY workers, $ITERATIONS iteraciones cada uno..."
for i in $(seq 1 $ITERATIONS); do
  for w in $(seq 1 $CONCURRENCY); do
    run_query $w &
  done
  wait
done
echo "Carga completada."
SCRIPT
chmod +x /tmp/concurrent_queries.sh
```

**7.2** Ejecutar la carga en segundo plano y monitorear desde la API:

```bash
# Terminal 1: lanzar carga
/tmp/concurrent_queries.sh > /tmp/load_output.log 2>&1 &
LOAD_PID=$!
echo "Carga iniciada con PID $LOAD_PID"

# Terminal 2 (o en la misma sesión con sleep): monitorear métricas cada 5s
for i in $(seq 1 6); do
  echo "=== Muestra $i ($(date +%H:%M:%S)) ==="
  curl -s -u ${CB_USER}:${CB_PASS} \
       http://${CB_HOST}:${CB_QUERY_PORT}/admin/stats | \
       jq '{
         active_requests:    .active_requests.value,
         queued_requests:    .queued_requests.value,
         request_rate:       .request_rate.value,
         request_timer_p99:  .request_timer.p99,
         request_timer_p999: .request_timer.p999
       }'
  sleep 5
done

wait $LOAD_PID
echo "Carga finalizada."
```

**7.3** Verificar en la Web Console:

1. Navegar a `http://<nodo>:8091` → **Query** → **Query Monitor**.
2. En la pestaña **Active Requests**, observar las consultas en ejecución durante la carga.
3. En la pestaña **Past Requests**, filtrar por duración > 10ms para identificar las consultas más lentas.
4. Anotar los valores de **Requests/sec** y **P99 latency** durante el pico de carga.

**Verificación:**

```bash
# Verificar que se procesaron consultas durante la carga
grep -c "Worker" /tmp/load_output.log && \
echo "✓ Consultas registradas en el log de carga" || \
echo "✗ Sin registros — verificar PID y conectividad"
```

---

## 7. Validación y Pruebas Finales

Ejecutar la siguiente secuencia de validación al finalizar todos los pasos:

```bash
#!/bin/bash
echo "=========================================="
echo " VALIDACIÓN FINAL — Lab 03-00-01"
echo "=========================================="

PASS=0; FAIL=0

check() {
  local desc=$1; local cmd=$2; local expected=$3
  result=$(eval "$cmd" 2>/dev/null)
  if echo "$result" | grep -q "$expected"; then
    echo "✓ $desc"; ((PASS++))
  else
    echo "✗ $desc (obtenido: ${result:0:80})"; ((FAIL++))
  fi
}

# 1. Dataset >= 500K documentos
check "Dataset >= 500K docs" \
  "curl -s -u ${CB_USER}:${CB_PASS} http://${CB_HOST}:${CB_ADMIN_PORT}/pools/default/buckets/${CB_BUCKET} | jq '.basicStats.itemCount'" \
  "^[5-9][0-9][0-9][0-9][0-9][0-9]"

# 2. Índice idx_route_airline_price existe
check "Índice idx_route_airline_price existe" \
  "curl -s -u ${CB_USER}:${CB_PASS} -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service -H 'Content-Type: application/json' -d '{\"statement\":\"SELECT name FROM system:indexes WHERE name = \\\"idx_route_airline_price\\\"\"}' | jq -r '.results[0].name'" \
  "idx_route_airline_price"

# 3. Índice idx_route_stops_seats existe
check "Índice idx_route_stops_seats existe" \
  "curl -s -u ${CB_USER}:${CB_PASS} -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service -H 'Content-Type: application/json' -d '{\"statement\":\"SELECT name FROM system:indexes WHERE name = \\\"idx_route_stops_seats\\\"\"}' | jq -r '.results[0].name'" \
  "idx_route_stops_seats"

# 4. Q1 usa IndexScan3 (no PrimaryScan)
check "Q1 usa IndexScan3 (no PrimaryScan)" \
  "cat /tmp/plan_q1_after.json | jq '.. | .\"#operator\"? // empty' | grep -c IndexScan3" \
  "^[1-9]"

# 5. Archivos de perfil generados
check "Perfil Q1 generado" "test -s /tmp/profile_q1.json && echo found" "found"
check "Perfil Q2 generado" "test -s /tmp/profile_q2.json && echo found" "found"

# 6. Prepared statement en caché
check "Prepared statement en caché" \
  "curl -s -u ${CB_USER}:${CB_PASS} http://${CB_HOST}:${CB_QUERY_PORT}/admin/prepareds | jq -r '.[].name' | grep stmt_routes_by_airline" \
  "stmt_routes_by_airline"

# 7. Estadísticas CBO actualizadas
check "Estadísticas CBO presentes" \
  "curl -s -u ${CB_USER}:${CB_PASS} -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service -H 'Content-Type: application/json' -d '{\"statement\":\"SELECT COUNT(*) AS cnt FROM system:dictionary WHERE keyspace_id = \\\"route\\\"\"}' | jq '.results[0].cnt'" \
  "^[1-9]"

echo "------------------------------------------"
echo "Resultado: ${PASS} pasados, ${FAIL} fallidos"
echo "=========================================="
```

**Criterio de aprobación:** mínimo 6 de 7 verificaciones en estado `✓`.

---

## 8. Resolución de Problemas

### Problema 1: `ADVISE` devuelve `"No index recommendation"` para consultas complejas

**Síntoma:**
```json
{
  "recommended_indexes": {},
  "current_indexes": []
}
```
`ADVISE` no sugiere ningún índice, aunque la consulta realiza un `PrimaryScan` completo.

**Causa:**
El Cost-Based Optimizer no tiene estadísticas actualizadas para las colecciones involucradas. Sin estadísticas de distribución de valores, el CBO no puede estimar la selectividad de los predicados y no genera recomendaciones confiables. Esto ocurre frecuentemente después de cargar datos masivamente (como en el Paso 1) sin ejecutar `UPDATE STATISTICS`.

**Solución:**

```bash
# Actualizar estadísticas para todas las colecciones relevantes
for collection in route airline hotel landmark; do
  echo "Actualizando estadísticas: $collection"
  curl -s -u ${CB_USER}:${CB_PASS} \
       -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
       -H "Content-Type: application/json" \
       -d "{\"statement\": \"UPDATE STATISTICS FOR \`travel-sample\`.\`inventory\`.\`${collection}\` INDEX ALL\"}" | \
       jq '{status: .status}'
done

# Verificar que las estadísticas fueron registradas
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{"statement": "SELECT keyspace_id, COUNT(*) AS stat_count FROM system:dictionary GROUP BY keyspace_id"}' | \
     jq '.results'
```

Después de actualizar estadísticas, re-ejecutar `ADVISE`. Si el problema persiste, verificar que el Index Service está activo en al menos un nodo del clúster con:

```bash
curl -s -u ${CB_USER}:${CB_PASS} \
     http://${CB_HOST}:${CB_ADMIN_PORT}/pools/nodes | \
     jq '[.nodes[] | {hostname: .hostname, services: .services}] | map(select(.services | contains(["index"])))'
```

---

### Problema 2: El *prepared statement* devuelve error `"No such prepared statement"` en ejecuciones posteriores

**Síntoma:**
```json
{
  "status": "errors",
  "errors": [{"code": 4040, "msg": "No such prepared statement: stmt_routes_by_airline"}]
}
```
La primera ejecución del prepared statement funciona, pero ejecuciones subsiguientes (especialmente tras reiniciar el servicio o bajo alta carga) fallan con el código 4040.

**Causa:**
Los prepared statements en Couchbase se almacenan en memoria en el nodo Query Service que los recibió. Si la solicitud siguiente es enrutada a un nodo Query diferente (comportamiento habitual en clústeres con múltiples nodos Query o con balanceador de carga), ese nodo no tiene el plan en caché. También ocurre si el nodo Query fue reiniciado, ya que la caché de prepared statements es volátil.

**Solución:**

```bash
# Opción A: Re-preparar automáticamente si falla (patrón recomendado en producción)
execute_prepared() {
  local stmt_name=$1
  local stmt_sql=$2
  local args=$3

  # Intentar ejecutar el prepared statement
  result=$(curl -s -u ${CB_USER}:${CB_PASS} \
       -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
       -H "Content-Type: application/json" \
       -d "{\"prepared\": \"${stmt_name}\", \"named_args\": ${args}}")

  error_code=$(echo $result | jq -r '.errors[0].code // empty')

  if [ "$error_code" = "4040" ]; then
    echo "Prepared statement no encontrado — re-preparando..."
    curl -s -u ${CB_USER}:${CB_PASS} \
         -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
         -H "Content-Type: application/json" \
         -d "{\"statement\": \"PREPARE ${stmt_name} AS ${stmt_sql}\"}" > /dev/null
    # Re-ejecutar
    curl -s -u ${CB_USER}:${CB_PASS} \
         -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
         -H "Content-Type: application/json" \
         -d "{\"prepared\": \"${stmt_name}\", \"named_args\": ${args}}"
  else
    echo $result
  fi
}

# Opción B: Usar el flag "auto_prepare" disponible en Couchbase 7.1+
# Enviar la consulta con el parámetro auto_prepare=true para que el servidor
# prepare y ejecute en un solo paso si el plan no está en caché
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{
       "statement": "SELECT r.airline FROM `travel-sample`.`inventory`.`route` AS r WHERE r.airline = $airline LIMIT 5",
       "named_args": {"airline": "AA"},
       "auto_prepare": true
     }' | jq '{status: .status, count: .metrics.resultCount}'
```

Para clústeres con múltiples nodos Query, la solución arquitectónica es preparar el statement en **todos los nodos Query** al inicio de la aplicación, o usar los SDKs oficiales de Couchbase que implementan este patrón automáticamente.

---

## 9. Limpieza del Entorno

Ejecutar al finalizar el laboratorio para liberar recursos y dejar el entorno en estado consistente para el siguiente lab:

```bash
echo "=== Iniciando limpieza del Lab 03-00-01 ==="

# 1. Eliminar índices creados en el lab (mantener solo los de travel-sample por defecto)
for idx in idx_route_airline_price idx_route_stops_seats idx_airline_name; do
  echo "Eliminando índice: $idx"
  curl -s -u ${CB_USER}:${CB_PASS} \
       -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
       -H "Content-Type: application/json" \
       -d "{\"statement\": \"DROP INDEX \`travel-sample\`.\`inventory\`.\`route\`.\`${idx}\` IF EXISTS\"}" | \
       jq '{status: .status}'
done

# 2. Eliminar índice primario temporal
curl -s -u ${CB_USER}:${CB_PASS} \
     -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
     -H "Content-Type: application/json" \
     -d '{"statement": "DROP PRIMARY INDEX `idx_route_primary` ON `travel-sample`.`inventory`.`route` IF EXISTS"}' | \
     jq '{status: .status}'

# 3. Limpiar archivos temporales
rm -f /tmp/plan_q1_before.json /tmp/plan_q1_after.json \
      /tmp/plan_q2.json /tmp/plan_q3.json \
      /tmp/profile_q1.json /tmp/profile_q2.json \
      /tmp/load_output.log /tmp/concurrent_queries.sh

# 4. OPCIONAL: Eliminar documentos generados (solo si el siguiente lab no los requiere)
# ADVERTENCIA: Este comando elimina los ~450K documentos insertados en el Paso 1
# Comentar si el Lab 04 también necesita el dataset ampliado
read -p "¿Eliminar documentos route_extended generados? (s/N): " confirm
if [[ "$confirm" =~ ^[sS]$ ]]; then
  echo "Eliminando documentos route_extended..."
  curl -s -u ${CB_USER}:${CB_PASS} \
       -X POST http://${CB_HOST}:${CB_QUERY_PORT}/query/service \
       -H "Content-Type: application/json" \
       -d '{"statement": "DELETE FROM `travel-sample`.`inventory`.`route` AS r WHERE r.type = \"route_extended\"", "timeout": "300000ms"}' | \
       jq '{status: .status, mutationCount: .metrics.mutationCount}'
fi

echo "=== Limpieza completada ==="
```

> **Nota:** Si el Lab 04 está planificado a continuación, **no eliminar** los documentos `route_extended`. El dataset ampliado es necesario para los escenarios de rendimiento del siguiente laboratorio.

---

## 10. Resumen

### Conceptos aplicados en este laboratorio

| Herramienta / Concepto | Lo que aprendiste |
|------------------------|-------------------|
| **EXPLAIN**            | Leer el árbol de operadores del plan de ejecución e identificar `PrimaryScan` como indicador de ausencia de índice selectivo |
| **ADVISE**             | Obtener recomendaciones automáticas del CBO y entender por qué requiere estadísticas actualizadas (`UPDATE STATISTICS`) |
| **PROFILE**            | Medir tiempos reales por operador y distinguir `elapsedTime` (incluye red/serialización) de `executionTime` (solo procesamiento) |
| **Índices covering**   | Diseñar índices que incluyen todos los campos proyectados para eliminar el operador `Fetch` y la comunicación con el Data Service |
| **Prepared statements**| Eliminar overhead de parsing/compilación en consultas repetitivas y gestionar el patrón de re-preparación ante errores 4040 |
| **Timeout y max_parallelism** | Proteger el clúster de consultas *runaway* y controlar el uso de CPU por consulta |
| **Query Monitor**      | Correlacionar métricas de la Web Console (P99, requests/sec) con datos obtenidos por CLI |

### Relación con la arquitectura del Query Service (Lección 3.1)

Cada herramienta utilizada en este lab corresponde directamente a un componente interno del Query Service:
- `EXPLAIN` expone las decisiones del **Optimizer** y el plan del **Execution Engine**.
- `PROFILE` instrumenta el **Execution Engine** y revela el tiempo invertido en el **Data Fetcher** (operador `Fetch`) y el **Index Scanner** (operador `IndexScan`).
- Los *prepared statements* eliminan el trabajo del **Parser** y el **Semantic Analyzer** en ejecuciones repetidas.
- Los `timeout` actúan en el **Listener HTTP**, que rechaza o cancela peticiones que superan el umbral configurado.

### Recursos adicionales

- [Referencia de EXPLAIN — Couchbase Docs](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/explain.html)
- [Referencia de ADVISE — Couchbase Docs](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/advise.html)
- [Referencia de PROFILE — Couchbase Docs](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/prepare.html)
- [Cost-Based Optimizer y UPDATE STATISTICS](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/cost-based-optimizer.html)
- [Prepared Statements en Couchbase](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/prepare.html)
- [Query Service REST API — parámetros de request](https://docs.couchbase.com/server/current/n1ql/n1ql-rest-api/index.html)
- [Covering Indexes — mejores prácticas](https://docs.couchbase.com/server/current/learn/services-and-indexes/indexes/index-replication.html)

---
