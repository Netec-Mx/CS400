---LAB_START---
LAB_ID: 12-00-01
---MARKDOWN---
# Ejecución de carga, análisis y optimización

## Metadatos

| Campo            | Valor                                      |
|------------------|--------------------------------------------|
| **Duración**     | 48 minutos                                 |
| **Complejidad**  | Media                                      |
| **Nivel Bloom**  | Aplicar                                    |
| **Servicio**     | Data, Query, Index                         |
| **Versión CB**   | Couchbase Server Enterprise 7.6.x          |

---

## Descripción General

En esta práctica aplicarás el proceso completo de diseño, ejecución y análisis de escenarios de carga sobre un clúster Couchbase de 3 nodos. Partirás de la definición formal de cuatro escenarios documentados —siguiendo el modelo de las cuatro dimensiones estudiadas en la lección 12.1— y los traducirás a carga real usando `cbc-pillowfight` para operaciones KV y `cbq`/REST API para consultas SQL++. Medirás KPIs de rendimiento (throughput, latencia p50/p95/p99, tasa de errores) y aplicarás al menos tres optimizaciones concretas para mejorar los resultados, documentando el impacto en un reporte comparativo.

---

## Objetivos de Aprendizaje

Al completar este laboratorio, serás capaz de:

- [ ] Diseñar y documentar escenarios de carga formales con tipo de operaciones, proporciones, distribución de acceso e intensidad, traduciendo el modelo a parámetros concretos de `cbc-pillowfight`
- [ ] Ejecutar pruebas de carga KV progresivas (4 → 8 → 16 → 32 threads) e identificar el punto de saturación correlacionando el output de la herramienta con métricas de Grafana
- [ ] Analizar planes de ejecución SQL++ con `EXPLAIN`, identificar full scans y crear índices compuestos y cubiertos que mejoren la latencia de consulta
- [ ] Aplicar técnicas de tuning (memory quota, eviction policy, covering indexes, max_parallelism) y cuantificar la mejora en un reporte tabular antes/después
- [ ] Interpretar métricas de saturación de recursos (resident ratio, cache miss rate, DCP queue drain rate) para formular hipótesis de diagnóstico

---

## Prerrequisitos

### Conocimiento Previo

- Comprensión de los cuatro componentes de un escenario de carga (lección 12.1): tipo de operaciones, proporciones, distribución de acceso e intensidad
- Familiaridad con los perfiles read-heavy, write-heavy y mixto y su impacto en los servicios de Couchbase
- Capacidad de interpretar planes de ejecución `EXPLAIN` en N1QL/SQL++
- Conocimiento básico de métricas de Couchbase: ops/sec, resident ratio, cache miss rate

### Acceso y Herramientas

- Clúster Couchbase 7.6 de 3 nodos operativo con servicios Data, Query e Index habilitados
- Dashboard de Grafana funcional (Lab 11-00-01 o equivalente) accesible desde el nodo cliente
- `cbc-pillowfight` instalado en el nodo cliente con conectividad verificada al clúster
- `cbq` disponible y funcional con conexión al servicio Query (puerto 8093)
- `cbstats` accesible en al menos un nodo del clúster
- `curl` y `jq` instalados en el nodo cliente
- Bucket `testload` pre-creado con quota de 2 GB

---

## Entorno de Laboratorio

### Topología de Red

| Componente         | Hostname / IP        | Rol                                  |
|--------------------|----------------------|--------------------------------------|
| Nodo CB 1          | `cb-node1` / `10.0.0.11` | Data + Query + Index             |
| Nodo CB 2          | `cb-node2` / `10.0.0.12` | Data + Query + Index             |
| Nodo CB 3          | `cb-node3` / `10.0.0.13` | Data + Query + Index             |
| Nodo Cliente       | `cb-client` / `10.0.0.20` | cbc-pillowfight, cbq, scripts   |
| Grafana            | `10.0.0.20:3000`     | Monitoreo en tiempo real             |

### Variables de Entorno (definir en el nodo cliente)

Ejecuta los siguientes comandos en el nodo cliente antes de iniciar el laboratorio. Estas variables se usarán en todos los pasos posteriores:

```bash
# Configuración del clúster
export CB_HOST="10.0.0.11"
export CB_USER="Administrator"
export CB_PASS="Password123!"
export CB_BUCKET="testload"
export CB_CONN_STR="couchbase://10.0.0.11,10.0.0.12,10.0.0.13"

# Directorio de resultados
export LAB_DIR="$HOME/lab12"
mkdir -p $LAB_DIR/{escenarios,resultados,indices}
echo "Directorio de trabajo: $LAB_DIR"
```

### Verificación del Entorno (Setup Inicial)

Antes de comenzar, verifica que todos los componentes estén operativos:

```bash
# 1. Verificar conectividad al clúster
curl -s -u $CB_USER:$CB_PASS http://$CB_HOST:8091/pools/default | jq '.name, .nodes | length'

# 2. Verificar que el bucket testload existe
curl -s -u $CB_USER:$CB_PASS http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET | jq '.name, .quota.ram'

# 3. Verificar cbc-pillowfight
cbc-pillowfight --help 2>&1 | head -5

# 4. Verificar cbq
echo "SELECT 1+1 AS test;" | cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | jq '.results'

# 5. Contar documentos existentes en testload
echo "SELECT COUNT(*) AS total FROM \`$CB_BUCKET\`;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results[0].total'
```

**Salida esperada de verificación:**

```
"testload"
2147483648
# (2 GB en bytes)
1 (resultado de 1+1)
500000 (o más documentos)
```

> **Nota:** Si el bucket `testload` tiene menos de 500,000 documentos, ejecuta el script de warm-up del **Paso 2.1** antes de continuar con los demás pasos.

---

## Procedimiento Paso a Paso

---

### FASE 1 — Diseño de Escenarios de Carga (10 minutos)

---

#### Paso 1.1: Documentar los Cuatro Escenarios de Carga

**Objetivo:** Crear la documentación formal de los cuatro escenarios antes de ejecutar cualquier prueba, siguiendo el modelo de las cuatro dimensiones de la lección 12.1.

**Instrucciones:**

1. Crea el archivo de diseño para el Escenario A (warm-up de escrituras):

```bash
cat > $LAB_DIR/escenarios/escenario-A.yaml << 'EOF'
# Escenario A: Warm-up KV - 100% Escrituras
escenario: kv-warmup-writes
descripcion: "Carga inicial para poblar el bucket y calentar el caché"
bucket: testload
documento_size_bytes_min: 512
documento_size_bytes_max: 2048
total_documentos: 500000
distribucion_acceso: secuencial
operaciones:
  - tipo: SET
    porcentaje: 100
intensidad:
  clientes_concurrentes: 16
  duracion_segundos: 300
fases:
  steady_state_segundos: 300
criterios_exito:
  throughput_min_ops: 5000
  error_rate_max_pct: 0.1
EOF
echo "Escenario A documentado."
```

2. Crea el archivo de diseño para el Escenario B (carga KV mixta):

```bash
cat > $LAB_DIR/escenarios/escenario-B.yaml << 'EOF'
# Escenario B: Carga KV Mixta - 70% Reads / 30% Writes
escenario: kv-mixed-high-concurrency
descripcion: "Simula carga transaccional mixta con alta concurrencia progresiva"
bucket: testload
documento_size_bytes_min: 512
documento_size_bytes_max: 2048
total_documentos: 500000
distribucion_acceso: uniforme
operaciones:
  - tipo: GET
    porcentaje: 70
  - tipo: SET
    porcentaje: 30
intensidad:
  clientes_concurrentes: [4, 8, 16, 32]  # progresivo
  duracion_por_nivel_segundos: 120
fases:
  ramp_up_segundos: 30
  steady_state_por_nivel_segundos: 90
criterios_exito:
  throughput_min_ops: 10000
  latencia_p99_max_ms: 50
  error_rate_max_pct: 0.5
EOF
echo "Escenario B documentado."
```

3. Crea el archivo de diseño para el Escenario C (consultas SQL++ de punto):

```bash
cat > $LAB_DIR/escenarios/escenario-C.yaml << 'EOF'
# Escenario C: SQL++ - Consultas de Punto (lookup por clave primaria)
escenario: sqlpp-point-queries
descripcion: "SELECT por document key con índice primario"
bucket: testload
tipo_consulta: punto
patron_acceso: clave_primaria
consulta_plantilla: "SELECT * FROM `testload` USE KEYS [$key]"
intensidad:
  concurrencia: 10
  duracion_segundos: 180
criterios_exito:
  latencia_p95_max_ms: 20
  error_rate_max_pct: 0.1
EOF
echo "Escenario C documentado."
```

4. Crea el archivo de diseño para el Escenario D (consultas analíticas):

```bash
cat > $LAB_DIR/escenarios/escenario-D.yaml << 'EOF'
# Escenario D: SQL++ - Consultas Analíticas con GROUP BY
escenario: sqlpp-analytical-groupby
descripcion: "Consultas de agregación sobre campos indexados"
bucket: testload
tipo_consulta: analitica
patron_acceso: rango_con_agrupacion
consulta_plantilla: |
  SELECT t.type, COUNT(*) as total, AVG(t.value) as avg_value
  FROM `testload` t
  WHERE t.created_at BETWEEN $start AND $end
  GROUP BY t.type
  ORDER BY total DESC
  LIMIT 10
intensidad:
  concurrencia: 5
  duracion_segundos: 180
criterios_exito:
  latencia_p95_max_ms: 500
  error_rate_max_pct: 1.0
EOF
echo "Escenario D documentado."
```

5. Verifica que todos los escenarios están documentados:

```bash
ls -la $LAB_DIR/escenarios/
echo "Total de escenarios diseñados: $(ls $LAB_DIR/escenarios/*.yaml | wc -l)"
```

**Salida esperada:**

```
escenario-A.yaml  escenario-B.yaml  escenario-C.yaml  escenario-D.yaml
Total de escenarios diseñados: 4
```

**Verificación:** Revisa que cada archivo YAML contiene las cuatro dimensiones del modelo de carga: tipo de operaciones, proporciones, distribución de acceso e intensidad. Esto garantiza reproducibilidad y permite revisión antes de ejecutar.

---

### FASE 2 — Pruebas KV con cbc-pillowfight (15 minutos)

---

#### Paso 2.1: Ejecutar Escenario A — Warm-up de Escrituras (100% SET)

**Objetivo:** Poblar el bucket `testload` con 500,000 documentos y establecer una línea base de throughput de escritura pura.

**Instrucciones:**

1. Ejecuta el warm-up con `cbc-pillowfight` según el Escenario A documentado:

```bash
echo "=== ESCENARIO A: Warm-up 100% Writes ===" | tee $LAB_DIR/resultados/escenario-A.log
echo "Inicio: $(date)" | tee -a $LAB_DIR/resultados/escenario-A.log

cbc-pillowfight \
  --spec $CB_CONN_STR \
  --username $CB_USER \
  --password $CB_PASS \
  --bucket $CB_BUCKET \
  --num-items 500000 \
  --num-threads 16 \
  --ratio 0 \
  --min-size 512 \
  --max-size 2048 \
  --set-pct 100 \
  --duration 300 \
  --json \
  2>&1 | tee -a $LAB_DIR/resultados/escenario-A.log

echo "Fin: $(date)" | tee -a $LAB_DIR/resultados/escenario-A.log
```

> **Nota sobre `--ratio`:** En `cbc-pillowfight`, `--ratio 0` significa 0% de lecturas (100% escrituras). El flag `--set-pct 100` refuerza esto explícitamente.

2. Mientras se ejecuta el warm-up, en una segunda terminal, monitorea las métricas con `cbstats`:

```bash
# En una segunda terminal, ejecuta durante el warm-up:
watch -n 5 'echo "=== $(date) ===" && \
  /opt/couchbase/bin/cbstats \
  10.0.0.11:11210 \
  -u $CB_USER -p $CB_PASS \
  -b $CB_BUCKET \
  all | grep -E "ep_bg_fetches|ep_cache_miss_rate|vb_active_resident|cmd_set|cmd_get"'
```

**Salida esperada de pillowfight (fragmento):**

```
[PROGRESS] Set: 15234 ops/s  Get: 0 ops/s  Err: 0
[PROGRESS] Set: 18456 ops/s  Get: 0 ops/s  Err: 0
[PROGRESS] Set: 17890 ops/s  Get: 0 ops/s  Err: 0
...
[SUMMARY] Total ops: 4,234,560 | Set: 4,234,560 | Get: 0 | Err: 0
[SUMMARY] Avg throughput: 16,938 ops/s
```

**Verificación:**

```bash
# Verificar que los documentos fueron escritos
echo "SELECT COUNT(*) AS total FROM \`$CB_BUCKET\`;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results[0].total'
# Esperado: >= 500000
```

---

#### Paso 2.2: Ejecutar Escenario B — Carga KV Mixta con Concurrencia Progresiva

**Objetivo:** Identificar el punto de saturación del servicio Data aumentando la concurrencia de 4 a 32 threads y midiendo el impacto en throughput y latencia.

**Instrucciones:**

1. Crea el script de ejecución progresiva:

```bash
cat > $LAB_DIR/escenario-B-progresivo.sh << 'SCRIPT'
#!/bin/bash
# Escenario B: Carga mixta progresiva 70/30

CB_HOST="${CB_HOST:-10.0.0.11}"
CB_USER="${CB_USER:-Administrator}"
CB_PASS="${CB_PASS:-Password123!}"
CB_BUCKET="${CB_BUCKET:-testload}"
CB_CONN_STR="${CB_CONN_STR:-couchbase://10.0.0.11,10.0.0.12,10.0.0.13}"
LAB_DIR="${LAB_DIR:-$HOME/lab12}"

THREADS=(4 8 16 32)
DURATION=120  # segundos por nivel

echo "=== ESCENARIO B: Carga KV Mixta 70/30 - Progresiva ===" | tee $LAB_DIR/resultados/escenario-B.log
echo "Inicio: $(date)" | tee -a $LAB_DIR/resultados/escenario-B.log

for T in "${THREADS[@]}"; do
  echo "" | tee -a $LAB_DIR/resultados/escenario-B.log
  echo "--- Nivel: $T threads --- $(date)" | tee -a $LAB_DIR/resultados/escenario-B.log

  cbc-pillowfight \
    --spec $CB_CONN_STR \
    --username $CB_USER \
    --password $CB_PASS \
    --bucket $CB_BUCKET \
    --num-items 500000 \
    --num-threads $T \
    --ratio 70 \
    --min-size 512 \
    --max-size 2048 \
    --duration $DURATION \
    2>&1 | tee -a $LAB_DIR/resultados/escenario-B-threads-$T.log

  echo "Pausa de 15s entre niveles para estabilización..." | tee -a $LAB_DIR/resultados/escenario-B.log
  sleep 15
done

echo "Fin: $(date)" | tee -a $LAB_DIR/resultados/escenario-B.log
SCRIPT

chmod +x $LAB_DIR/escenario-B-progresivo.sh
```

> **Nota sobre `--ratio`:** En `cbc-pillowfight`, `--ratio N` especifica el porcentaje de operaciones GET. `--ratio 70` = 70% lecturas / 30% escrituras, que corresponde exactamente al Escenario B diseñado.

2. Ejecuta el script progresivo:

```bash
$LAB_DIR/escenario-B-progresivo.sh
```

3. Durante la ejecución, monitorea en Grafana las siguientes métricas (panel Data Service):
   - `kv_ops` (ops/sec por tipo: get, set)
   - `kv_ep_cache_miss_rate`
   - `kv_vb_active_resident_items_ratio`
   - CPU usage por nodo

4. Extrae y consolida los resultados de throughput por nivel de concurrencia:

```bash
echo "=== RESUMEN ESCENARIO B - Throughput por Nivel ===" | tee $LAB_DIR/resultados/escenario-B-resumen.txt
for T in 4 8 16 32; do
  echo -n "Threads=$T: "
  grep -E "ops/s|Avg throughput" $LAB_DIR/resultados/escenario-B-threads-$T.log 2>/dev/null | \
    tail -5 | awk '{sum+=$2; count++} END {if(count>0) printf "Avg=%.0f ops/s\n", sum/count; else print "N/A"}'
done | tee -a $LAB_DIR/resultados/escenario-B-resumen.txt
```

**Salida esperada (ejemplo representativo):**

```
=== RESUMEN ESCENARIO B - Throughput por Nivel ===
Threads=4:  Avg=8,234 ops/s
Threads=8:  Avg=15,678 ops/s
Threads=16: Avg=24,102 ops/s
Threads=32: Avg=26,450 ops/s   ← punto de saturación (ganancia marginal < 10%)
```

**Verificación:** El punto de saturación se identifica cuando el incremento de throughput entre niveles consecutivos cae por debajo del 10% mientras la latencia p99 supera los 50 ms. Anota este umbral para la Fase 4.

---

#### Paso 2.3: Capturar Métricas Detalladas con cbstats

**Objetivo:** Obtener estadísticas detalladas del servicio Data para correlacionar con los resultados de pillowfight.

**Instrucciones:**

1. Captura un snapshot de métricas clave durante la carga con 32 threads:

```bash
# Ejecutar durante el nivel de 32 threads del Escenario B
/opt/couchbase/bin/cbstats \
  10.0.0.11:11210 \
  -u $CB_USER -p $CB_PASS \
  -b $CB_BUCKET \
  all 2>/dev/null | grep -E \
  "ep_bg_fetches|ep_cache_miss_rate|vb_active_resident|ep_mem_high_wat|ep_mem_low_wat|ep_oom_errors|ep_tmp_oom_errors|ep_dcp_items_remaining" \
  | tee $LAB_DIR/resultados/cbstats-32threads.txt
```

2. Captura también las latencias de operación:

```bash
/opt/couchbase/bin/cbstats \
  10.0.0.11:11210 \
  -u $CB_USER -p $CB_PASS \
  -b $CB_BUCKET \
  timings 2>/dev/null \
  | grep -E "get|set|disk" \
  | tee $LAB_DIR/resultados/cbstats-timings.txt
```

**Salida esperada (fragmento):**

```
ep_bg_fetches:                    1234
ep_cache_miss_rate:               0.045
vb_active_resident_items_ratio:   0.82
ep_mem_high_wat:                  1717986918
ep_oom_errors:                    0
ep_dcp_items_remaining:           0
```

**Verificación:** Un `vb_active_resident_items_ratio` por debajo de 0.80 (80%) indica que Couchbase está realizando lecturas desde disco (bg_fetches elevados), lo que impactará negativamente la latencia. Esto es una señal de que la memory quota puede ser insuficiente.

---

### FASE 3 — Pruebas SQL++ con Análisis de Planes de Ejecución (12 minutos)

---

#### Paso 3.1: Preparar el Índice Primario y Ejecutar Escenario C

**Objetivo:** Establecer la línea base de rendimiento de consultas de punto usando el índice primario.

**Instrucciones:**

1. Verifica que el índice primario existe (o créalo):

```bash
echo "SELECT * FROM system:indexes WHERE keyspace_id = '$CB_BUCKET' AND is_primary = true;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results[] | {name: .name, state: .state}'
```

Si no existe, créalo:

```bash
echo "CREATE PRIMARY INDEX \`#primary\` ON \`$CB_BUCKET\` USING GSI;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.status, .errors'
```

2. Analiza el plan de ejecución de una consulta de rango (antes de crear índices secundarios):

```bash
cat > $LAB_DIR/indices/explain-antes.sql << 'SQL'
EXPLAIN
SELECT t.type, COUNT(*) AS total, AVG(t.value) AS avg_value
FROM `testload` t
WHERE t.created_at BETWEEN "2024-01-01" AND "2024-12-31"
GROUP BY t.type
ORDER BY total DESC
LIMIT 10;
SQL

cbq -u $CB_USER -p $CB_PASS \
    -engine http://$CB_HOST:8093 \
    -script $LAB_DIR/indices/explain-antes.sql \
    2>/dev/null | jq '.results[0]' \
    | tee $LAB_DIR/resultados/explain-antes.json
```

3. Identifica si hay un Primary Scan en el plan:

```bash
cat $LAB_DIR/resultados/explain-antes.json | jq '.. | .#operator? // empty' | sort -u
```

**Salida esperada (antes de optimización):**

```json
{
  "#operator": "PrimaryScan",
  "index": "#primary",
  "keyspace": "testload",
  "using": "gsi"
}
```

> **Importante:** La presencia de `PrimaryScan` indica un full scan del bucket. Para 500,000 documentos, esto resultará en latencias elevadas. Este es el problema que resolveremos en los pasos siguientes.

4. Ejecuta el Escenario C (consultas de punto) para capturar la línea base:

```bash
# Script de carga de consultas SQL++ usando curl (simula concurrencia de 10)
cat > $LAB_DIR/escenario-C-baseline.sh << 'SCRIPT'
#!/bin/bash
echo "=== ESCENARIO C: SQL++ Punto - Línea Base ===" | tee $LAB_DIR/resultados/escenario-C-baseline.log
echo "Inicio: $(date)" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log

TOTAL_REQUESTS=100
LATENCIAS=()

for i in $(seq 1 $TOTAL_REQUESTS); do
  # Seleccionar una clave aleatoria del rango de documentos
  KEY="testload::$(shuf -i 1-500000 -n 1)"

  START_NS=$(date +%s%N)
  RESULT=$(curl -s \
    -u "$CB_USER:$CB_PASS" \
    -d "statement=SELECT+META().id,*+FROM+\`$CB_BUCKET\`+USE+KEYS+[\"$KEY\"]" \
    http://$CB_HOST:8093/query/service)
  END_NS=$(date +%s%N)

  ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))
  STATUS=$(echo $RESULT | jq -r '.status' 2>/dev/null)
  LATENCIAS+=($ELAPSED_MS)

  if [ $((i % 20)) -eq 0 ]; then
    echo "Progreso: $i/$TOTAL_REQUESTS | Última latencia: ${ELAPSED_MS}ms | Status: $STATUS"
  fi
done

# Calcular estadísticas
printf '%s\n' "${LATENCIAS[@]}" | sort -n > /tmp/latencias_sorted.txt
P50=$(awk 'NR==int(0.50*NR+0.5)' /tmp/latencias_sorted.txt | head -1)
TOTAL=$(wc -l < /tmp/latencias_sorted.txt)
P50_IDX=$(echo "$TOTAL * 0.50" | bc | cut -d. -f1)
P95_IDX=$(echo "$TOTAL * 0.95" | bc | cut -d. -f1)
P99_IDX=$(echo "$TOTAL * 0.99" | bc | cut -d. -f1)

P50=$(sed -n "${P50_IDX}p" /tmp/latencias_sorted.txt)
P95=$(sed -n "${P95_IDX}p" /tmp/latencias_sorted.txt)
P99=$(sed -n "${P99_IDX}p" /tmp/latencias_sorted.txt)
AVG=$(awk '{sum+=$1} END {printf "%.0f", sum/NR}' /tmp/latencias_sorted.txt)

echo "" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "=== RESULTADOS ESCENARIO C - LÍNEA BASE ===" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Total requests: $TOTAL_REQUESTS" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Latencia Promedio: ${AVG}ms" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Latencia P50: ${P50}ms" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Latencia P95: ${P95}ms" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Latencia P99: ${P99}ms" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
echo "Fin: $(date)" | tee -a $LAB_DIR/resultados/escenario-C-baseline.log
SCRIPT

chmod +x $LAB_DIR/escenario-C-baseline.sh
$LAB_DIR/escenario-C-baseline.sh
```

**Salida esperada:**

```
=== RESULTADOS ESCENARIO C - LÍNEA BASE ===
Total requests: 100
Latencia Promedio: 8ms
Latencia P50: 6ms
Latencia P95: 18ms
Latencia P99: 35ms
```

---

#### Paso 3.2: Ejecutar Escenario D — Consultas Analíticas y Análisis EXPLAIN

**Objetivo:** Medir el impacto de un full scan en consultas analíticas con GROUP BY y cuantificar la degradación antes de aplicar índices.

**Instrucciones:**

1. Ejecuta la consulta analítica del Escenario D y mide su latencia inicial:

```bash
cat > /tmp/query-D.sql << 'SQL'
SELECT t.type, COUNT(*) AS total, AVG(t.value) AS avg_value
FROM `testload` t
WHERE t.created_at BETWEEN "2024-01-01" AND "2024-12-31"
GROUP BY t.type
ORDER BY total DESC
LIMIT 10;
SQL

echo "=== Ejecutando Escenario D (línea base - sin índice secundario) ===" | tee $LAB_DIR/resultados/escenario-D-baseline.log

time curl -s \
  -u "$CB_USER:$CB_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"statement\": \"SELECT t.type, COUNT(*) AS total, AVG(t.value) AS avg_value FROM \\\`testload\\\` t WHERE t.created_at BETWEEN '2024-01-01' AND '2024-12-31' GROUP BY t.type ORDER BY total DESC LIMIT 10\", \"metrics\": true}" \
  http://$CB_HOST:8093/query/service \
  | jq '{status: .status, metrics: .metrics, results: .results}' \
  | tee $LAB_DIR/resultados/escenario-D-baseline.json
```

2. Extrae las métricas de ejecución del resultado:

```bash
cat $LAB_DIR/resultados/escenario-D-baseline.json | jq '.metrics | {
  executionTime: .executionTime,
  resultCount: .resultCount,
  sortCount: .sortCount,
  mutationCount: .mutationCount,
  errorCount: .errorCount
}'
```

**Salida esperada (antes de optimización):**

```json
{
  "executionTime": "4.532s",
  "resultCount": 8,
  "sortCount": 500000,
  "mutationCount": 0,
  "errorCount": 0
}
```

> **Observación clave:** `sortCount: 500000` indica que Couchbase procesó todos los documentos del bucket para responder la consulta. Esto es el síntoma del full scan que debemos eliminar.

---

### FASE 4 — Tuning y Validación (11 minutos)

---

#### Paso 4.1: Crear Índice Compuesto para el Escenario D

**Objetivo:** Eliminar el full scan en la consulta analítica creando un índice compuesto sobre `created_at` y `type`.

**Instrucciones:**

1. Crea el índice compuesto:

```bash
echo "=== Creando índice compuesto para Escenario D ===" | tee $LAB_DIR/resultados/tuning.log

cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 << 'SQL' 2>/dev/null | jq '.status, .errors'
CREATE INDEX `idx_created_type_value`
ON `testload`(created_at, type, value)
WITH {"num_replica": 1, "defer_build": false};
SQL
```

2. Verifica que el índice está en estado `online`:

```bash
echo "SELECT name, state, keyspace_id FROM system:indexes WHERE name = 'idx_created_type_value';" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results[]'
```

**Salida esperada:**

```json
{
  "name": "idx_created_type_value",
  "state": "online",
  "keyspace_id": "testload"
}
```

3. Verifica que el plan de ejecución ahora usa el índice secundario:

```bash
echo "EXPLAIN SELECT t.type, COUNT(*) AS total, AVG(t.value) AS avg_value FROM \`testload\` t WHERE t.created_at BETWEEN '2024-01-01' AND '2024-12-31' GROUP BY t.type ORDER BY total DESC LIMIT 10;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.. | .#operator? // empty' | sort -u \
  | tee $LAB_DIR/resultados/explain-despues.txt
```

**Salida esperada (después de crear el índice):**

```
"Aggregate"
"IndexScan3"
"Order"
"Sequence"
```

> **Verificación crítica:** La presencia de `IndexScan3` y la ausencia de `PrimaryScan` confirma que la consulta ahora usa el índice secundario. El plan ya no realiza un full scan del bucket.

---

#### Paso 4.2: Crear Índice Cubierto (Covering Index) para el Escenario C

**Objetivo:** Mejorar las consultas de punto creando un índice cubierto que evite la fase de fetch del documento.

**Instrucciones:**

1. Analiza el plan actual de la consulta de punto:

```bash
echo "EXPLAIN SELECT META().id, type, value, created_at FROM \`testload\` WHERE META().id = 'testload::12345';" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.. | .#operator? // empty' | sort -u
```

2. Crea un índice cubierto que incluya los campos más consultados:

```bash
cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 << 'SQL' 2>/dev/null | jq '.status'
CREATE INDEX `idx_covering_type_value`
ON `testload`(type, value, created_at)
INCLUDE (META().id)
WITH {"num_replica": 1};
SQL
```

> **Nota:** Un **covering index** incluye todos los campos que la consulta necesita retornar, eliminando la necesidad de recuperar el documento completo desde el Data Service. Esto reduce significativamente la latencia en consultas de alto volumen.

---

#### Paso 4.3: Ajustar Memory Quota y Eviction Policy

**Objetivo:** Aplicar tuning de memoria para mejorar el resident ratio identificado en el Paso 2.3.

**Instrucciones:**

1. Verifica la configuración actual del bucket:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  | jq '{quota_mb: .quota.rawRAM | . / 1048576 | floor, evictionPolicy: .evictionPolicy, ramUsed_mb: .basicStats.memUsed | . / 1048576 | floor}'
```

2. Incrementa la memory quota del bucket de 2 GB a 3 GB (si el hardware lo permite):

```bash
echo "=== Ajustando Memory Quota del bucket ===" | tee -a $LAB_DIR/resultados/tuning.log

curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  -d "ramQuotaMB=3072" \
  | jq '.' \
  | tee -a $LAB_DIR/resultados/tuning.log

echo "Memory quota actualizada a 3072 MB" | tee -a $LAB_DIR/resultados/tuning.log
```

3. Cambia la eviction policy a `fullEviction` para cargas de lectura masiva con datasets grandes:

```bash
curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  -d "evictionPolicy=fullEviction" \
  | jq '.' \
  | tee -a $LAB_DIR/resultados/tuning.log

echo "Eviction policy cambiada a fullEviction" | tee -a $LAB_DIR/resultados/tuning.log
```

> **Nota sobre eviction policies:**
> - `valueOnly` (default): mantiene la clave y metadata en RAM, solo evicta el valor. Mejor para cargas donde el resident ratio puede mantenerse alto.
> - `fullEviction`: evicta tanto la clave como el valor. Permite datasets más grandes que la RAM disponible, pero incrementa la latencia de bg_fetches. Adecuado cuando el dataset supera significativamente la RAM disponible.

4. Ajusta el `max_parallelism` del servicio Query para consultas analíticas:

```bash
curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8093/admin/settings \
  -H "Content-Type: application/json" \
  -d '{"max-parallelism": 4}' \
  | jq '.' \
  | tee -a $LAB_DIR/resultados/tuning.log

echo "max_parallelism ajustado a 4" | tee -a $LAB_DIR/resultados/tuning.log
```

---

#### Paso 4.4: Re-ejecutar Pruebas y Comparar KPIs

**Objetivo:** Cuantificar el impacto de las tres optimizaciones aplicadas ejecutando de nuevo los escenarios C y D.

**Instrucciones:**

1. Re-ejecuta el Escenario D después de las optimizaciones:

```bash
echo "=== Ejecutando Escenario D (POST-TUNING) ===" | tee $LAB_DIR/resultados/escenario-D-post.log

curl -s \
  -u "$CB_USER:$CB_PASS" \
  -H "Content-Type: application/json" \
  -d "{\"statement\": \"SELECT t.type, COUNT(*) AS total, AVG(t.value) AS avg_value FROM \\\`testload\\\` t WHERE t.created_at BETWEEN '2024-01-01' AND '2024-12-31' GROUP BY t.type ORDER BY total DESC LIMIT 10\", \"metrics\": true}" \
  http://$CB_HOST:8093/query/service \
  | jq '{status: .status, metrics: .metrics}' \
  | tee $LAB_DIR/resultados/escenario-D-post.json
```

2. Re-ejecuta el Escenario B con 32 threads (el nivel de saturación identificado) para medir el impacto del tuning de memoria:

```bash
echo "=== Re-ejecutando Escenario B (32 threads) POST-TUNING ===" | tee $LAB_DIR/resultados/escenario-B-post.log

cbc-pillowfight \
  --spec $CB_CONN_STR \
  --username $CB_USER \
  --password $CB_PASS \
  --bucket $CB_BUCKET \
  --num-items 500000 \
  --num-threads 32 \
  --ratio 70 \
  --min-size 512 \
  --max-size 2048 \
  --duration 120 \
  2>&1 | tee $LAB_DIR/resultados/escenario-B-32t-post.log
```

3. Genera el reporte comparativo:

```bash
cat > $LAB_DIR/resultados/reporte-comparativo.md << 'EOF'
# Reporte Comparativo: Antes vs Después del Tuning

## Escenario D — Consulta Analítica SQL++ (GROUP BY)

| Métrica              | Antes (Línea Base)  | Después (Post-Tuning) | Mejora     |
|----------------------|---------------------|-----------------------|------------|
| Tiempo de ejecución  | ~4.5 s              | ~0.3 s                | ~93%       |
| Operador de acceso   | PrimaryScan (full)  | IndexScan3            | ✅ Óptimo  |
| sortCount            | 500,000             | < 1,000               | ~99.8%     |
| Índice utilizado      | #primary            | idx_created_type_value| ✅         |

## Escenario B — Carga KV Mixta (32 threads)

| Métrica                    | Antes  | Después | Mejora |
|----------------------------|--------|---------|--------|
| Throughput (ops/s)         | ~26,450| ~29,800 | ~12%   |
| resident_items_ratio       | 0.82   | 0.91    | +11%   |
| bg_fetches/s               | 234    | 45      | ~81%   |
| Eviction policy            | valueOnly | fullEviction | — |

## Optimizaciones Aplicadas

1. **Índice compuesto** `idx_created_type_value` → eliminó full scan en Escenario D
2. **Índice cubierto** `idx_covering_type_value` → redujo fetches en consultas de punto
3. **Memory quota** aumentada de 2 GB a 3 GB → mejoró resident ratio
4. **Eviction policy** cambiada a fullEviction → mejor gestión de memoria con dataset grande
5. **max_parallelism** ajustado a 4 → mejor utilización de CPU en consultas analíticas
EOF

echo "Reporte generado en: $LAB_DIR/resultados/reporte-comparativo.md"
cat $LAB_DIR/resultados/reporte-comparativo.md
```

---

## Validación y Verificación Final

Ejecuta los siguientes comandos de validación para confirmar que el laboratorio se completó correctamente:

```bash
echo "============================================"
echo "  VALIDACIÓN FINAL - Lab 12-00-01"
echo "============================================"

# V1: Verificar que los 4 escenarios fueron documentados
echo -n "V1 - Escenarios documentados: "
COUNT=$(ls $LAB_DIR/escenarios/*.yaml 2>/dev/null | wc -l)
[ "$COUNT" -eq 4 ] && echo "✅ PASS ($COUNT/4)" || echo "❌ FAIL ($COUNT/4)"

# V2: Verificar resultados de pillowfight para los 4 niveles
echo -n "V2 - Resultados pillowfight (4 niveles): "
COUNT=$(ls $LAB_DIR/resultados/escenario-B-threads-*.log 2>/dev/null | wc -l)
[ "$COUNT" -eq 4 ] && echo "✅ PASS" || echo "❌ FAIL (encontrados: $COUNT)"

# V3: Verificar que el índice compuesto existe y está online
echo -n "V3 - Índice compuesto online: "
STATE=$(echo "SELECT state FROM system:indexes WHERE name = 'idx_created_type_value';" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq -r '.results[0].state')
[ "$STATE" = "online" ] && echo "✅ PASS (state: $STATE)" || echo "❌ FAIL (state: $STATE)"

# V4: Verificar que el plan post-tuning usa IndexScan (no PrimaryScan)
echo -n "V4 - Plan de ejecución usa IndexScan: "
HAS_INDEX=$(echo "EXPLAIN SELECT t.type, COUNT(*) AS total FROM \`testload\` t WHERE t.created_at BETWEEN '2024-01-01' AND '2024-12-31' GROUP BY t.type LIMIT 10;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.. | .["#operator"]? // empty' | grep -c "IndexScan")
[ "$HAS_INDEX" -gt 0 ] && echo "✅ PASS" || echo "❌ FAIL (aún usa PrimaryScan)"

# V5: Verificar memory quota actualizada
echo -n "V5 - Memory quota >= 3 GB: "
QUOTA=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET 2>/dev/null | \
  jq '.quota.rawRAM // 0')
[ "$QUOTA" -ge 3221225472 ] && echo "✅ PASS (${QUOTA} bytes)" || echo "⚠️  WARN (quota: ${QUOTA} bytes)"

# V6: Verificar reporte comparativo generado
echo -n "V6 - Reporte comparativo generado: "
[ -f "$LAB_DIR/resultados/reporte-comparativo.md" ] && echo "✅ PASS" || echo "❌ FAIL"

echo "============================================"
echo "Directorio de resultados: $LAB_DIR/resultados/"
ls -la $LAB_DIR/resultados/
```

**Salida esperada de validación:**

```
============================================
  VALIDACIÓN FINAL - Lab 12-00-01
============================================
V1 - Escenarios documentados: ✅ PASS (4/4)
V2 - Resultados pillowfight (4 niveles): ✅ PASS
V3 - Índice compuesto online: ✅ PASS (state: online)
V4 - Plan de ejecución usa IndexScan: ✅ PASS
V5 - Memory quota >= 3 GB: ✅ PASS (3221225472 bytes)
V6 - Reporte comparativo generado: ✅ PASS
============================================
```

---

## Resolución de Problemas

### Problema 1: cbc-pillowfight reporta errores de autenticación o "Bucket not found"

**Síntomas:**
```
[ERROR] LCB_ERR_AUTHENTICATION_FAILURE (206): The provided credentials are not authorized
# o
[ERROR] LCB_ERR_BUCKET_NOT_FOUND: Bucket "testload" not found
```

**Causa:** Las credenciales pasadas a `cbc-pillowfight` no coinciden con las configuradas en el clúster, o el nombre del bucket tiene diferencias de capitalización. También puede ocurrir si el bucket fue creado con autenticación SASL y las credenciales no incluyen el password del bucket.

**Solución:**

```bash
# 1. Verificar que el bucket existe con el nombre exacto
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets \
  | jq '.[].name'

# 2. Verificar conectividad básica al puerto 11210 (memcached)
nc -zv $CB_HOST 11210
# Esperado: Connection to 10.0.0.11 11210 port [tcp] succeeded!

# 3. Probar con conexión explícita y bucket password (si aplica)
cbc-pillowfight \
  --spec "couchbase://$CB_HOST" \
  --username $CB_USER \
  --password $CB_PASS \
  --bucket $CB_BUCKET \
  --num-items 100 \
  --num-threads 1 \
  --duration 10 \
  -v 2>&1 | head -20

# 4. Si el clúster usa TLS, cambiar el scheme
# cbc-pillowfight --spec "couchbases://$CB_HOST" ...
```

---

### Problema 2: La consulta del Escenario D sigue usando PrimaryScan después de crear el índice

**Síntomas:**
```json
{
  "#operator": "PrimaryScan",
  "index": "#primary"
}
```
El plan de ejecución no cambia incluso después de crear `idx_created_type_value` y verificar que está en estado `online`.

**Causa:** El optimizador de consultas de Couchbase puede no seleccionar el índice secundario si: (a) las estadísticas del índice no están actualizadas, (b) el índice fue creado con `defer_build` y no se ejecutó `BUILD INDEX`, o (c) los campos en la cláusula `WHERE` de la consulta no coinciden exactamente con los campos del índice (diferencias en tipo de dato o formato de fecha).

**Solución:**

```bash
# 1. Verificar el estado completo del índice
echo "SELECT * FROM system:indexes WHERE name = 'idx_created_type_value';" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results[0] | {state, completion_progress, last_scan_time}'

# 2. Si el estado es "deferred", construir el índice manualmente
echo "BUILD INDEX ON \`testload\`(\`idx_created_type_value\`);" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.status'

# 3. Forzar el uso del índice con un hint explícito para verificar que funciona
echo "EXPLAIN SELECT t.type, COUNT(*) AS total FROM \`testload\` t
  USE INDEX (\`idx_created_type_value\` USING GSI)
  WHERE t.created_at BETWEEN '2024-01-01' AND '2024-12-31'
  GROUP BY t.type LIMIT 10;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.. | .["#operator"]? // empty' | sort -u

# 4. Verificar que los documentos tienen el campo created_at en el formato correcto
echo "SELECT created_at FROM \`testload\` LIMIT 5;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.results'
# Si el campo no existe o tiene formato diferente, ajustar la consulta o recrear el índice
```

---

## Limpieza del Entorno

Ejecuta los siguientes comandos para dejar el entorno en un estado limpio al finalizar el laboratorio:

```bash
echo "=== Iniciando limpieza del laboratorio 12-00-01 ==="

# 1. Eliminar los índices secundarios creados durante el lab
echo "DROP INDEX \`testload\`.\`idx_created_type_value\` USING GSI;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.status'

echo "DROP INDEX \`testload\`.\`idx_covering_type_value\` USING GSI;" | \
  cbq -u $CB_USER -p $CB_PASS -engine http://$CB_HOST:8093 2>/dev/null | \
  jq '.status'

# 2. Restaurar la memory quota original del bucket (2 GB)
curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  -d "ramQuotaMB=2048" \
  | jq '.errors // "OK"'

# 3. Restaurar eviction policy a valueOnly
curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  -d "evictionPolicy=valueOnly" \
  | jq '.errors // "OK"'

# 4. Restaurar max_parallelism al valor por defecto
curl -s -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8093/admin/settings \
  -H "Content-Type: application/json" \
  -d '{"max-parallelism": 1}' \
  | jq '.'

# 5. Archivar los resultados del lab (opcional: comprimir para entrega)
tar -czf $HOME/lab12-resultados-$(date +%Y%m%d-%H%M).tar.gz -C $HOME lab12/
echo "Resultados archivados en: $HOME/lab12-resultados-$(date +%Y%m%d-%H%M).tar.gz"

# 6. Verificar estado final del bucket
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET \
  | jq '{quota_mb: (.quota.rawRAM / 1048576 | floor), evictionPolicy: .evictionPolicy}'

echo "=== Limpieza completada ==="
```

> **Nota:** Los documentos en el bucket `testload` y el índice primario `#primary` se conservan intencionalmente para los laboratorios posteriores que puedan requerir datos de prueba.

---

## Resumen

En este laboratorio aplicaste el ciclo completo de diseño, ejecución y optimización de cargas en Couchbase:

**FASE 1 — Diseño:** Documentaste cuatro escenarios de carga formales siguiendo el modelo de las cuatro dimensiones de la lección 12.1 (tipo de operaciones, proporciones, distribución de acceso e intensidad), garantizando reproducibilidad antes de ejecutar cualquier prueba.

**FASE 2 — Pruebas KV:** Ejecutaste `cbc-pillowfight` con carga progresiva de 4 a 32 threads, identificando el punto de saturación donde el throughput marginal cae por debajo del 10% y la latencia p99 supera el umbral aceptable. Correlacionaste los resultados con métricas de `cbstats` (resident ratio, bg_fetches, cache miss rate).

**FASE 3 — Pruebas SQL++:** Analizaste planes de ejecución con `EXPLAIN`, identificando el `PrimaryScan` como el cuello de botella en la consulta analítica. Confirmaste que `sortCount: 500,000` es el síntoma de un full scan sobre el bucket completo.

**FASE 4 — Tuning:** Aplicaste cinco optimizaciones concretas y cuantificaste su impacto: el índice compuesto redujo el tiempo de la consulta analítica en ~93%, el ajuste de memory quota mejoró el resident ratio en 11 puntos porcentuales, y el cambio de eviction policy redujo los bg_fetches en ~81%.

### Conceptos Clave Reforzados

| Concepto | Herramienta | Impacto Medido |
|---|---|---|
| Distribución de acceso uniforme | cbc-pillowfight `--ratio` | Peor caso para caché (resident ratio bajo) |
| Punto de saturación | Progresión 4→8→16→32 threads | Identificado en 32 threads (ganancia marginal < 10%) |
| Full scan vs Index scan | `EXPLAIN` + `system:indexes` | 93% reducción en tiempo de ejecución |
| Covering index | `CREATE INDEX ... INCLUDE` | Eliminación de fetches al Data Service |
| Memory quota y eviction | REST API `/pools/default/buckets` | +11% resident ratio, -81% bg_fetches |

### Recursos Adicionales

- [Couchbase Docs: cbc-pillowfight Reference](https://docs.couchbase.com/sdk-api/couchbase-c-client/md_doc_cbc-pillowfight.html)
- [Couchbase Docs: Index Advisor y EXPLAIN](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/explain.html)
- [Couchbase Docs: Covering Indexes](https://docs.couchbase.com/server/current/n1ql/n1ql-language-reference/covering-indexes.html)
- [Couchbase Docs: Bucket Memory and Storage](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/memory.html)
- [YCSB Workload Definitions — referencia para modelos de carga estándar](https://github.com/brianfrankcooper/YCSB/wiki/Core-Workloads)

---
LAB_END---
