# Configuración y análisis del Data Service bajo presión de memoria

## Metadatos

| Campo | Valor |
|---|---|
| **Duración estimada** | 84 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Aplicar (*Apply*) |
| **Servicio principal** | Data Service — Couchbase Server 7.6.x |
| **Modalidad** | Hands-on individual o en pareja |

---

## Visión General

En este laboratorio configurarás dos buckets con storage engines distintos —**Couchstore** y **Magma**— bajo cuotas de memoria deliberadamente reducidas para observar el comportamiento del Data Service cuando la presión de memoria activa las políticas de ejection. Utilizando `cbworkloadgen` y `cbc-pillowfight` generarás carga progresiva hasta degradar el resident ratio por debajo del umbral óptimo, monitorizando en tiempo real métricas clave como `ep_mem_high_watermark`, `vb_active_resident_items_ratio` y `ep_num_eject_failures` mediante la Web Console y la REST API. El lab culmina con una comparación documentada del comportamiento de ambos storage engines y la medición del impacto en latencia de distintos niveles de durabilidad.

---

## Objetivos de Aprendizaje

Al completar este laboratorio, serás capaz de:

- [ ] Configurar cuotas de memoria y políticas de ejection en buckets Couchbase y observar su activación bajo presión de memoria real
- [ ] Comparar el comportamiento operativo de Couchstore y Magma midiendo resident ratio, cache miss ratio y latencia de lectura bajo carga
- [ ] Analizar métricas del Data Service (`ep_mem_high_watermark`, `vb_active_resident_items_ratio`, `ep_num_eject_failures`) mediante la Web Console y la REST API
- [ ] Medir el impacto en latencia de los niveles de durabilidad `majority`, `persistToMajority` y `replicateToPersist` durante operaciones de escritura
- [ ] Correlacionar el tamaño de la Disk Write Queue con la saturación del subsistema de almacenamiento

---

## Prerequisitos

### Conocimiento previo
- Lab 01-00-01 completado: clúster de 3 nodos Couchbase operativo y accesible
- Comprensión del modelo de escritura en memoria primero (*memory-first write*) y el rol del Managed Object Cache (MOC)
- Familiaridad con el concepto de resident ratio y cache hit/miss
- Conocimiento básico de métricas de rendimiento en bases de datos

### Acceso y herramientas requeridas
- Clúster Couchbase Server 7.6.x con 3 nodos (nodo1: `192.168.1.101`, nodo2: `192.168.1.102`, nodo3: `192.168.1.103`)
- Usuario administrador: `Administrator` / contraseña: `password` (ajustar según entorno)
- `cbworkloadgen` disponible en PATH (incluido con Couchbase Server)
- `cbc-pillowfight` disponible en PATH (incluido con libcouchbase)
- `curl` y `jq` instalados en el nodo cliente
- Python 3.10+ con Couchbase Python SDK 4.2.x instalado
- Acceso a la Web Console en `http://192.168.1.101:8091`

---

## Entorno de Laboratorio

### Topología de referencia

| Rol | Hostname / IP | Servicios habilitados |
|---|---|---|
| Nodo 1 (coordinador) | `192.168.1.101` | Data, Index, Query |
| Nodo 2 | `192.168.1.102` | Data |
| Nodo 3 | `192.168.1.103` | Data |
| Cliente / generador de carga | `192.168.1.110` | cbworkloadgen, pillowfight, Python SDK |

### Requisitos de recursos para este lab

| Recurso | Mínimo recomendado |
|---|---|
| RAM por nodo Data | 8 GB (4 GB asignados a Couchbase) |
| Almacenamiento por nodo | 50 GB SSD disponible |
| Latencia inter-nodo | < 1 ms |
| Ancho de banda | ≥ 1 Gbps |

### Verificación del entorno antes de comenzar

Ejecuta los siguientes comandos desde el nodo cliente para confirmar que el entorno está listo:

```bash
# Verificar accesibilidad del clúster
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default \
  | jq '.name, .nodes[].status'

# Verificar que los 3 nodos están healthy
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default \
  | jq '.nodes[] | {hostname: .hostname, status: .status, services: .services}'

# Verificar versión de Couchbase
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools \
  | jq '.implementationVersion'

# Verificar disponibilidad de herramientas
cbworkloadgen --help > /dev/null 2>&1 && echo "cbworkloadgen: OK" || echo "cbworkloadgen: NO ENCONTRADO"
cbc-pillowfight --help > /dev/null 2>&1 && echo "cbc-pillowfight: OK" || echo "cbc-pillowfight: NO ENCONTRADO"
jq --version
python3 --version
```

**Salida esperada:** Los 3 nodos deben aparecer con `"status": "healthy"` y los servicios Data activos. Todas las herramientas deben responder correctamente.

---

## Pasos del Laboratorio

---

### Paso 1: Crear el bucket Couchstore con cuota de memoria limitada

**Objetivo:** Crear un bucket usando el storage engine Couchstore con una cuota de memoria intencionalmente baja para provocar presión de memoria durante la carga.

#### Instrucciones

1. Desde el nodo cliente, crea el bucket `lab-couchstore` mediante la REST API. Nota que se configura con **256 MB de RAM** (valor bajo intencional), ejection policy `valueOnly` y 2 réplicas:

```bash
curl -s -u Administrator:password \
  -X POST http://192.168.1.101:8091/pools/default/buckets \
  -d name=lab-couchstore \
  -d bucketType=couchbase \
  -d ramQuota=256 \
  -d replicaNumber=2 \
  -d evictionPolicy=valueOnly \
  -d storageBackend=couchstore \
  -d durabilityMinLevel=none \
  -d flushEnabled=1
```

2. Espera 10 segundos para que el bucket se inicialice y verifica su creación:

```bash
sleep 10

curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default/buckets/lab-couchstore \
  | jq '{
      name: .name,
      ramQuota: .quota.ram,
      replicaNumber: .replicaNumber,
      evictionPolicy: .evictionPolicy,
      storageBackend: .storageBackend,
      bucketType: .bucketType
    }'
```

3. Verifica el estado del bucket en la Web Console: navega a **Buckets** en `http://192.168.1.101:8091` y confirma que `lab-couchstore` aparece con estado `healthy`.

#### Salida esperada

```json
{
  "name": "lab-couchstore",
  "ramQuota": 268435456,
  "replicaNumber": 2,
  "evictionPolicy": "valueOnly",
  "storageBackend": "couchstore",
  "bucketType": "membase"
}
```

#### Verificación

```bash
# Confirmar que el bucket está activo en todos los nodos
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/nodes \
  | jq '.servers[] | {hostname: .hostname, status: .status}'
```

Todos los nodos deben reportar `"status": "healthy"`.

---

### Paso 2: Crear el bucket Magma con cuota de memoria limitada

**Objetivo:** Crear un segundo bucket usando el storage engine Magma con configuración equivalente para permitir la comparación directa.

> **Nota importante:** Magma requiere una cuota mínima de RAM de **1024 MB** por bucket. Para este lab usaremos exactamente ese mínimo para mantener la presión de memoria. Magma está optimizado para conjuntos de datos que superan ampliamente la RAM disponible.

#### Instrucciones

1. Crea el bucket `lab-magma` con storage engine Magma:

```bash
curl -s -u Administrator:password \
  -X POST http://192.168.1.101:8091/pools/default/buckets \
  -d name=lab-magma \
  -d bucketType=couchbase \
  -d ramQuota=1024 \
  -d replicaNumber=2 \
  -d evictionPolicy=fullEviction \
  -d storageBackend=magma \
  -d durabilityMinLevel=none \
  -d flushEnabled=1
```

> **Diferencia clave:** Magma utiliza `fullEviction` (evicción completa del documento, incluyendo metadatos) mientras que Couchstore típicamente usa `valueOnly` (retiene metadatos en memoria). Esta diferencia es fundamental para entender el comportamiento bajo presión.

2. Espera a que el bucket se inicialice:

```bash
sleep 15

curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default/buckets/lab-magma \
  | jq '{
      name: .name,
      ramQuota: .quota.ram,
      replicaNumber: .replicaNumber,
      evictionPolicy: .evictionPolicy,
      storageBackend: .storageBackend
    }'
```

3. Verifica que ambos buckets existen y están saludables:

```bash
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default/buckets \
  | jq '.[] | {name: .name, storageBackend: .storageBackend, ramQuota: .quota.ram}'
```

#### Salida esperada

```json
{ "name": "lab-couchstore", "storageBackend": "couchstore", "ramQuota": 268435456 }
{ "name": "lab-magma",      "storageBackend": "magma",      "ramQuota": 1073741824 }
```

#### Verificación

```bash
# Verificar watermarks de memoria inicial (deben estar en 0 uso)
for bucket in lab-couchstore lab-magma; do
  echo "=== $bucket ==="
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        mem_used: .mem_used[-1],
        ep_mem_high_wat: .ep_mem_high_wat[-1],
        ep_mem_low_wat: .ep_mem_low_wat[-1],
        curr_items: .curr_items[-1]
      }'
done
```

---

### Paso 3: Establecer línea base de métricas antes de la carga

**Objetivo:** Capturar el estado inicial del sistema antes de generar carga, para tener una línea base de comparación.

#### Instrucciones

1. Crea el directorio de trabajo para este lab y el script de captura de métricas:

```bash
mkdir -p ~/lab02/metrics
cd ~/lab02

cat > capture_metrics.sh << 'EOF'
#!/bin/bash
# Script de captura de métricas del Data Service
# Uso: ./capture_metrics.sh <bucket_name> <etiqueta>

BUCKET=$1
LABEL=$2
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
HOST="192.168.1.101"
AUTH="Administrator:password"
OUTPUT_FILE="metrics/${BUCKET}_${LABEL}_${TIMESTAMP}.json"

echo "Capturando métricas para bucket: $BUCKET (etiqueta: $LABEL)"

curl -s -u $AUTH \
  "http://${HOST}:8091/pools/default/buckets/${BUCKET}/stats" \
  | jq '{
      timestamp: now | todate,
      bucket: "'$BUCKET'",
      label: "'$LABEL'",
      metrics: {
        curr_items:                     .op.samples.curr_items[-1],
        mem_used:                       .op.samples.mem_used[-1],
        ep_mem_high_wat:                .op.samples.ep_mem_high_wat[-1],
        ep_mem_low_wat:                 .op.samples.ep_mem_low_wat[-1],
        vb_active_resident_items_ratio: .op.samples.vb_active_resident_items_ratio[-1],
        ep_num_value_ejects:            .op.samples.ep_num_value_ejects[-1],
        ep_tmp_oom_errors:              .op.samples.ep_tmp_oom_errors[-1],
        ep_queue_size:                  .op.samples.ep_queue_size[-1],
        ep_diskqueue_drain_rate:        .op.samples.ep_diskqueue_drain_rate[-1],
        cmd_get:                        .op.samples.cmd_get[-1],
        get_hits:                       .op.samples.get_hits[-1],
        get_misses:                     .op.samples.get_misses[-1],
        avg_bg_wait_time:               .op.samples.avg_bg_wait_time[-1],
        ep_bg_fetched:                  .op.samples.ep_bg_fetched[-1]
      }
    }' | tee "$OUTPUT_FILE"

echo "Guardado en: $OUTPUT_FILE"
EOF

chmod +x capture_metrics.sh
```

2. Captura la línea base para ambos buckets:

```bash
./capture_metrics.sh lab-couchstore baseline
./capture_metrics.sh lab-magma baseline
```

3. Registra manualmente los valores de referencia en la siguiente tabla (complétala con los valores reales):

```bash
echo "=== LÍNEA BASE - RESUMEN ==="
for bucket in lab-couchstore lab-magma; do
  echo "--- $bucket ---"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | 
        "Resident Ratio: \(.vb_active_resident_items_ratio[-1])% | " +
        "Items: \(.curr_items[-1]) | " +
        "Mem Used: \(.mem_used[-1] / 1024 / 1024 | round) MB"'
done
```

#### Salida esperada

Con los buckets vacíos, deberías ver:
- `curr_items`: 0
- `vb_active_resident_items_ratio`: 100 (o null si no hay ítems)
- `ep_num_value_ejects`: 0
- `ep_tmp_oom_errors`: 0

#### Verificación

Confirma que los archivos de métricas se crearon correctamente:

```bash
ls -la ~/lab02/metrics/
```

---

### Paso 4: Carga progresiva en el bucket Couchstore con cbworkloadgen

**Objetivo:** Generar carga de datos en el bucket Couchstore hasta superar la cuota de memoria y observar la activación de la ejection policy.

#### Instrucciones

1. Inicia la carga inicial de 50,000 documentos con `cbworkloadgen`. El tamaño de documento de 1 KB garantizará que 50K documentos (~50 MB de datos) quepan en los 256 MB del bucket:

```bash
# Fase 1: Carga inicial - documentos pequeños que caben en memoria
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-couchstore \
  --num-items=50000 \
  --item-size=1024 \
  --prefix=fase1_ \
  --set-pct=100 \
  -t 4

echo "Fase 1 completada. Capturando métricas..."
sleep 5
./capture_metrics.sh lab-couchstore fase1_50k
```

2. Observa el resident ratio después de la primera fase. Debería estar cerca del 100% ya que los datos caben en memoria.

3. Ahora genera una segunda fase con documentos más grandes para presionar la memoria. Usaremos documentos de 4 KB:

```bash
# Fase 2: Incrementar presión - documentos más grandes
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-couchstore \
  --num-items=100000 \
  --item-size=4096 \
  --prefix=fase2_ \
  --set-pct=100 \
  -t 4

echo "Fase 2 completada. Capturando métricas..."
sleep 5
./capture_metrics.sh lab-couchstore fase2_100k
```

4. Continúa con una tercera fase diseñada para superar claramente la cuota de memoria:

```bash
# Fase 3: Superar cuota - forzar ejection activa
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-couchstore \
  --num-items=150000 \
  --item-size=4096 \
  --prefix=fase3_ \
  --set-pct=100 \
  -t 4

echo "Fase 3 completada. Capturando métricas..."
sleep 5
./capture_metrics.sh lab-couchstore fase3_150k
```

5. Verifica el estado de la ejection en tiempo real mientras la carga está activa:

```bash
# Monitoreo continuo durante 60 segundos (ejecutar en terminal separado)
for i in $(seq 1 12); do
  echo "--- $(date +%H:%M:%S) ---"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
    | jq '.op.samples | {
        resident_ratio:   .vb_active_resident_items_ratio[-1],
        mem_used_mb:      (.mem_used[-1] / 1024 / 1024 | round),
        ejects:           .ep_num_value_ejects[-1],
        oom_errors:       .ep_tmp_oom_errors[-1],
        bg_fetches:       .ep_bg_fetched[-1],
        queue_size:       .ep_queue_size[-1]
      }'
  sleep 5
done
```

#### Salida esperada

Después de la Fase 3, deberías observar:
- `vb_active_resident_items_ratio` < 80% (señal de presión activa)
- `ep_num_value_ejects` > 0 (ejection activada)
- `ep_bg_fetched` > 0 (lecturas desde disco ocurriendo)
- `ep_tmp_oom_errors` posiblemente > 0 si la presión es extrema

#### Verificación

```bash
# Verificar que la ejection se activó
EJECTS=$(curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples.ep_num_value_ejects[-1]')

echo "Número de ejeciones: $EJECTS"
[ "$EJECTS" -gt 0 ] && echo "✓ Ejection policy activada correctamente" \
  || echo "⚠ Ejection no activada aún - considera agregar más datos"
```

---

### Paso 5: Carga equivalente en el bucket Magma y comparación inicial

**Objetivo:** Replicar la carga en el bucket Magma y observar las diferencias de comportamiento bajo presión de memoria con `fullEviction`.

#### Instrucciones

1. Ejecuta la misma secuencia de carga en el bucket Magma:

```bash
# Fase 1 Magma
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-magma \
  --num-items=50000 \
  --item-size=1024 \
  --prefix=fase1_ \
  --set-pct=100 \
  -t 4

sleep 5
./capture_metrics.sh lab-magma fase1_50k

# Fase 2 Magma
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-magma \
  --num-items=100000 \
  --item-size=4096 \
  --prefix=fase2_ \
  --set-pct=100 \
  -t 4

sleep 5
./capture_metrics.sh lab-magma fase2_100k

# Fase 3 Magma
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-magma \
  --num-items=200000 \
  --item-size=4096 \
  --prefix=fase3_ \
  --set-pct=100 \
  -t 4

sleep 5
./capture_metrics.sh lab-magma fase3_200k
```

2. Genera una comparación directa de métricas entre ambos buckets:

```bash
echo "========================================"
echo "COMPARACIÓN: Couchstore vs Magma"
echo "========================================"

for bucket in lab-couchstore lab-magma; do
  echo ""
  echo "--- $bucket ---"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        curr_items:        .curr_items[-1],
        resident_ratio_pct: .vb_active_resident_items_ratio[-1],
        mem_used_mb:       (.mem_used[-1] / 1024 / 1024 | round),
        ejects_total:      .ep_num_value_ejects[-1],
        bg_fetches:        .ep_bg_fetched[-1],
        avg_bg_wait_us:    .avg_bg_wait_time[-1],
        oom_errors:        .ep_tmp_oom_errors[-1]
      }'
done
```

#### Salida esperada

Deberías observar diferencias notables:

| Métrica | Couchstore (valueOnly) | Magma (fullEviction) |
|---|---|---|
| `ep_num_value_ejects` | Alto (solo valores) | Diferente patrón |
| `avg_bg_wait_time` | Latencia de fetch desde disco | Comparable o mayor |
| `resident_ratio` | Metadatos siempre en RAM | Puede ser más bajo |

#### Verificación

```bash
# Verificar que Magma tiene datos en disco
ls -lh /opt/couchbase/var/lib/couchbase/data/lab-magma.*/
```

---

### Paso 6: Prueba de carga con cbc-pillowfight y medición de cache miss

**Objetivo:** Usar `cbc-pillowfight` para generar carga mixta de lectura/escritura y medir el impacto del cache miss en latencia.

#### Instrucciones

1. Ejecuta `cbc-pillowfight` contra el bucket Couchstore con carga mixta (70% lecturas, 30% escrituras) durante 120 segundos. La combinación de claves aleatorias garantizará cache misses frecuentes:

```bash
# Carga mixta en Couchstore - observar cache misses
cbc-pillowfight \
  --spec couchbase://192.168.1.101/lab-couchstore \
  --username Administrator \
  --password password \
  --num-items 300000 \
  --num-threads 8 \
  --batch-size 100 \
  --set-pct 30 \
  --min-size 1024 \
  --max-size 4096 \
  --num-cycles 0 \
  --duration 120 &

PILLOWFIGHT_PID=$!
echo "cbc-pillowfight iniciado con PID: $PILLOWFIGHT_PID"
```

2. Mientras pillowfight está ejecutándose, monitoriza las métricas de cache miss en tiempo real:

```bash
# Monitoreo de cache miss durante la prueba (ejecutar en paralelo)
echo "Iniciando monitoreo de cache miss (30 segundos)..."
for i in $(seq 1 6); do
  TS=$(date +%H:%M:%S)
  STATS=$(curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
    | jq '.op.samples')
  
  GET_HITS=$(echo $STATS | jq '.get_hits[-1]')
  GET_MISSES=$(echo $STATS | jq '.get_misses[-1]')
  BG_FETCHED=$(echo $STATS | jq '.ep_bg_fetched[-1]')
  AVG_BG_WAIT=$(echo $STATS | jq '.avg_bg_wait_time[-1]')
  RESIDENT=$(echo $STATS | jq '.vb_active_resident_items_ratio[-1]')
  
  echo "[$TS] Resident: ${RESIDENT}% | Hits: $GET_HITS | Misses: $GET_MISSES | BG Fetches: $BG_FETCHED | Avg BG Wait: ${AVG_BG_WAIT}µs"
  sleep 5
done
```

3. Captura métricas durante la prueba activa:

```bash
sleep 30
./capture_metrics.sh lab-couchstore pillowfight_activo
```

4. Espera a que pillowfight termine y captura el estado final:

```bash
wait $PILLOWFIGHT_PID
echo "Prueba completada"
sleep 5
./capture_metrics.sh lab-couchstore pillowfight_final
```

5. Repite la prueba con el bucket Magma:

```bash
cbc-pillowfight \
  --spec couchbase://192.168.1.101/lab-magma \
  --username Administrator \
  --password password \
  --num-items 400000 \
  --num-threads 8 \
  --batch-size 100 \
  --set-pct 30 \
  --min-size 1024 \
  --max-size 4096 \
  --num-cycles 0 \
  --duration 120

sleep 5
./capture_metrics.sh lab-magma pillowfight_final
```

#### Salida esperada

Durante la prueba activa deberías ver en el monitoreo:
```
[14:32:10] Resident: 45% | Hits: 12450 | Misses: 3201 | BG Fetches: 3198 | Avg BG Wait: 8542µs
[14:32:15] Resident: 43% | Hits: 13102 | Misses: 3890 | BG Fetches: 3887 | Avg BG Wait: 9103µs
```

Un `avg_bg_wait_time` alto (miles de microsegundos) confirma que las lecturas desde disco están penalizando la latencia.

#### Verificación

```bash
# Calcular cache miss ratio aproximado
curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples | 
      "Cache Miss Ratio: \(
        (.get_misses[-1] / ((.get_hits[-1] + .get_misses[-1]) | if . == 0 then 1 else . end) * 100) | round
      )%"'
```

---

### Paso 7: Análisis de watermarks y comportamiento de ejection

**Objetivo:** Inspeccionar los watermarks de memoria (`ep_mem_high_watermark` y `ep_mem_low_watermark`) y comprender cuándo y cómo se activa la ejection.

#### Instrucciones

1. Consulta los watermarks actuales de ambos buckets:

```bash
echo "=== WATERMARKS DE MEMORIA ==="
for bucket in lab-couchstore lab-magma; do
  echo ""
  echo "--- $bucket ---"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        mem_used_mb:         (.mem_used[-1] / 1024 / 1024 | round),
        ep_mem_high_wat_mb:  (.ep_mem_high_wat[-1] / 1024 / 1024 | round),
        ep_mem_low_wat_mb:   (.ep_mem_low_wat[-1] / 1024 / 1024 | round),
        high_wat_pct:        ((.ep_mem_high_wat[-1] / .ep_max_size[-1]) * 100 | round),
        low_wat_pct:         ((.ep_mem_low_wat[-1] / .ep_max_size[-1]) * 100 | round),
        currently_above_hwm: (.mem_used[-1] > .ep_mem_high_wat[-1])
      }'
done
```

2. Verifica el número de ejeciones acumuladas y el estado del pager:

```bash
echo "=== ESTADO DEL ITEM PAGER ==="
for bucket in lab-couchstore lab-magma; do
  echo ""
  echo "--- $bucket ---"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        ep_num_value_ejects:      .ep_num_value_ejects[-1],
        ep_num_non_resident:      .ep_num_non_resident[-1],
        ep_tmp_oom_errors:        .ep_tmp_oom_errors[-1],
        ep_oom_errors:            .ep_oom_errors[-1],
        vb_active_num_non_resident: .vb_active_num_non_resident[-1]
      }'
done
```

3. Crea un script Python para visualizar la evolución del resident ratio a lo largo del tiempo usando los archivos de métricas capturados:

```python
#!/usr/bin/env python3
# ~/lab02/analyze_metrics.py
# Análisis comparativo de métricas capturadas

import json
import glob
import os

metrics_dir = os.path.expanduser("~/lab02/metrics")

print("=" * 70)
print("ANÁLISIS COMPARATIVO: Couchstore vs Magma")
print("=" * 70)

for bucket in ["lab-couchstore", "lab-magma"]:
    print(f"\n{'='*35}")
    print(f"Bucket: {bucket}")
    print(f"{'='*35}")
    print(f"{'Etiqueta':<25} {'Items':>10} {'Resident%':>10} {'Ejects':>10} {'BG Fetch':>10}")
    print("-" * 70)
    
    files = sorted(glob.glob(f"{metrics_dir}/{bucket}_*.json"))
    for filepath in files:
        with open(filepath) as f:
            data = json.load(f)
        
        m = data.get("metrics", {})
        label = data.get("label", "?")
        items = m.get("curr_items", 0) or 0
        resident = m.get("vb_active_resident_items_ratio", 100) or 100
        ejects = m.get("ep_num_value_ejects", 0) or 0
        bg_fetch = m.get("ep_bg_fetched", 0) or 0
        
        print(f"{label:<25} {items:>10,} {resident:>9.1f}% {ejects:>10,} {bg_fetch:>10,}")

print("\n✓ Análisis completado")
```

```bash
python3 ~/lab02/analyze_metrics.py
```

#### Salida esperada

```
======================================================================
ANÁLISIS COMPARATIVO: Couchstore vs Magma
======================================================================

===================================
Bucket: lab-couchstore
===================================
Etiqueta                      Items  Resident%     Ejects   BG Fetch
----------------------------------------------------------------------
baseline                          0     100.0%          0          0
fase1_50k                     50000      98.2%          0          0
fase2_100k                   150000      71.4%       8432        124
fase3_150k                   300000      42.1%      45821       3891
pillowfight_final            300000      38.7%      52103       8234
```

#### Verificación

```bash
# Confirmar que los watermarks están correctamente configurados (75% HWM, 60% LWM por defecto)
curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples | 
      "HWM: \((.ep_mem_high_wat[-1] / .ep_max_size[-1] * 100 | round))% | " +
      "LWM: \((.ep_mem_low_wat[-1] / .ep_max_size[-1] * 100 | round))%"'
```

Los valores esperados son HWM ≈ 75% y LWM ≈ 60% de la cuota RAM del bucket.

---

### Paso 8: Medición del impacto de los niveles de durabilidad en latencia

**Objetivo:** Configurar y medir el impacto en latencia de los tres niveles de durabilidad (`majority`, `persistToMajority`, `replicateToPersist`) usando el Python SDK.

#### Instrucciones

1. Crea el script Python de medición de durabilidad:

```python
#!/usr/bin/env python3
# ~/lab02/durability_benchmark.py
# Benchmark de latencia por nivel de durabilidad

import time
import statistics
from datetime import timedelta
from couchbase.cluster import Cluster
from couchbase.auth import PasswordAuthenticator
from couchbase.options import ClusterOptions, UpsertOptions
from couchbase.durability import (
    ServerDurability,
    Durability,
    DurabilityLevel
)

# Configuración
CB_HOST = "couchbase://192.168.1.101"
CB_USER = "Administrator"
CB_PASS = "password"
BUCKET_NAME = "lab-couchstore"
NUM_SAMPLES = 50  # Operaciones por nivel de durabilidad
DOC_SIZE_BYTES = 1024

# Documento de prueba
def make_doc(i):
    return {
        "id": i,
        "payload": "x" * DOC_SIZE_BYTES,
        "timestamp": time.time()
    }

# Conexión
auth = PasswordAuthenticator(CB_USER, CB_PASS)
cluster = Cluster(CB_HOST, ClusterOptions(auth))
cluster.wait_until_ready(timedelta(seconds=10))
bucket = cluster.bucket(BUCKET_NAME)
collection = bucket.default_collection()

print("=" * 65)
print("BENCHMARK DE DURABILIDAD - Couchbase Server 7.6.x")
print(f"Bucket: {BUCKET_NAME} | Muestras por nivel: {NUM_SAMPLES}")
print("=" * 65)

# Niveles de durabilidad a probar
durability_configs = [
    ("none (ACK en memoria)", None),
    ("majority", DurabilityLevel.MAJORITY),
    ("persistToMajority", DurabilityLevel.PERSIST_TO_MAJORITY),
    ("replicateToPersist", DurabilityLevel.MAJORITY_AND_PERSIST_TO_ACTIVE),
]

results = {}

for level_name, durability_level in durability_configs:
    latencies = []
    errors = 0
    
    print(f"\nProbando nivel: {level_name}")
    
    for i in range(NUM_SAMPLES):
        doc_key = f"durability_test_{level_name.replace(' ', '_')}_{i}"
        doc = make_doc(i)
        
        try:
            if durability_level is None:
                # Sin durabilidad especial
                opts = UpsertOptions(timeout=timedelta(seconds=10))
            else:
                opts = UpsertOptions(
                    durability=ServerDurability(durability_level),
                    timeout=timedelta(seconds=30)
                )
            
            start = time.perf_counter()
            collection.upsert(doc_key, doc, opts)
            elapsed_ms = (time.perf_counter() - start) * 1000
            latencies.append(elapsed_ms)
            
        except Exception as e:
            errors += 1
            print(f"  Error en operación {i}: {e}")
    
    if latencies:
        results[level_name] = {
            "p50": statistics.median(latencies),
            "p95": sorted(latencies)[int(len(latencies) * 0.95)],
            "p99": sorted(latencies)[int(len(latencies) * 0.99)],
            "avg": statistics.mean(latencies),
            "min": min(latencies),
            "max": max(latencies),
            "errors": errors
        }
        print(f"  ✓ Completado: avg={results[level_name]['avg']:.2f}ms, "
              f"p95={results[level_name]['p95']:.2f}ms, errores={errors}")

# Reporte final
print("\n" + "=" * 65)
print("RESULTADOS COMPARATIVOS DE LATENCIA (milisegundos)")
print("=" * 65)
print(f"{'Nivel':<30} {'Avg':>8} {'P50':>8} {'P95':>8} {'P99':>8} {'Max':>8} {'Err':>5}")
print("-" * 65)

for level_name, stats in results.items():
    print(f"{level_name:<30} "
          f"{stats['avg']:>7.2f}ms "
          f"{stats['p50']:>7.2f}ms "
          f"{stats['p95']:>7.2f}ms "
          f"{stats['p99']:>7.2f}ms "
          f"{stats['max']:>7.2f}ms "
          f"{stats['errors']:>5}")

# Guardar resultados
import json
with open(os.path.expanduser("~/lab02/durability_results.json"), "w") as f:
    json.dump(results, f, indent=2)

print("\n✓ Resultados guardados en ~/lab02/durability_results.json")
```

2. Instala las dependencias necesarias y ejecuta el benchmark:

```bash
pip3 install couchbase --quiet
python3 ~/lab02/durability_benchmark.py
```

3. Interpreta los resultados. La diferencia entre `none` y `persistToMajority` refleja exactamente el costo de esperar que el dato llegue a disco en la mayoría de los nodos:

```bash
cat ~/lab02/durability_results.json | jq .
```

#### Salida esperada (valores aproximados)

```
=================================================================
RESULTADOS COMPARATIVOS DE LATENCIA (milisegundos)
=================================================================
Nivel                             Avg      P50      P95      P99      Max   Err
-----------------------------------------------------------------
none (ACK en memoria)           0.48ms   0.41ms   0.89ms   1.23ms   2.10ms     0
majority                        1.82ms   1.65ms   3.21ms   4.87ms   8.34ms     0
persistToMajority              12.45ms  11.20ms  22.31ms  31.45ms  45.20ms     0
replicateToPersist             14.21ms  13.10ms  25.87ms  35.12ms  52.30ms     0
```

> **Observación clave:** `persistToMajority` tiene una latencia ~25x mayor que el modo sin durabilidad, porque debe esperar confirmación de escritura en disco desde al menos 2 de los 3 nodos. Este es el costo directo de la durabilidad fuerte.

#### Verificación

```bash
# Confirmar que los documentos de prueba se escribieron correctamente
curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples.curr_items[-1]'
```

---

### Paso 9: Observación en la Web Console y correlación visual

**Objetivo:** Correlacionar las métricas numéricas con las gráficas de la Web Console para desarrollar intuición visual sobre el comportamiento del sistema.

#### Instrucciones

1. Abre la Web Console en `http://192.168.1.101:8091` e inicia sesión como `Administrator`.

2. Navega a **Buckets → lab-couchstore → Statistics**. Localiza y documenta los valores actuales de los siguientes gráficos:

| Gráfico en Web Console | Métrica subyacente | Valor observado |
|---|---|---|
| Resident Items Ratio | `vb_active_resident_items_ratio` | ______% |
| Memory Used | `mem_used` | ______ MB |
| Disk Write Queue | `ep_queue_size` | ______ items |
| Cache Miss Ratio | `ep_bg_fetched` / total reads | ______% |
| Ejections per Second | `ep_num_value_ejects` | ______ /s |

3. Genera una ráfaga de escrituras mientras observas la Web Console en tiempo real:

```bash
# Ráfaga de escritura para observar el comportamiento en tiempo real en la Web Console
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator \
  -p password \
  -b lab-couchstore \
  --num-items=30000 \
  --item-size=8192 \
  --prefix=burst_ \
  --set-pct=100 \
  -t 8
```

4. Observa en la Web Console cómo:
   - La métrica **Memory Used** sube y puede superar el HWM (línea roja)
   - El **Resident Items Ratio** desciende cuando la ejection se activa
   - La **Disk Write Queue** crece durante la ráfaga y luego se drena

5. Consulta la Disk Write Queue mediante REST API para correlacionar con lo visual:

```bash
# Monitoreo de la cola de escritura a disco
echo "Monitorizando Disk Write Queue (30 segundos)..."
for i in $(seq 1 6); do
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
    | jq '"[" + (now | todate) + "] " +
          "Queue: \(.op.samples.ep_queue_size[-1]) items | " +
          "Drain: \(.op.samples.ep_diskqueue_drain_rate[-1]) items/s | " +
          "Mem: \(.op.samples.mem_used[-1] / 1024 / 1024 | round) MB"'
  sleep 5
done
```

#### Salida esperada

```
"[2024-01-15T14:45:23Z] Queue: 8432 items | Drain: 2145 items/s | Mem: 248 MB"
"[2024-01-15T14:45:28Z] Queue: 6891 items | Drain: 2310 items/s | Mem: 251 MB"
"[2024-01-15T14:45:33Z] Queue: 4102 items | Drain: 2289 items/s | Mem: 249 MB"
"[2024-01-15T14:45:38Z] Queue: 1834 items | Drain: 2156 items/s | Mem: 247 MB"
"[2024-01-15T14:45:43Z] Queue: 0 items | Drain: 0 items/s | Mem: 245 MB"
```

La cola crece durante la ráfaga y se drena progresivamente. Si la cola no se drena, indica saturación del subsistema de disco.

#### Verificación

Documenta en tu cuaderno de laboratorio las capturas de pantalla de los dashboards y los valores observados en la tabla del punto 2.

---

### Paso 10: Análisis comparativo final y generación del reporte

**Objetivo:** Consolidar todas las métricas capturadas en un análisis comparativo documentado entre Couchstore y Magma.

#### Instrucciones

1. Genera el reporte comparativo final:

```bash
cat > ~/lab02/generate_report.sh << 'EOF'
#!/bin/bash
echo "================================================================"
echo "REPORTE FINAL: Análisis Comparativo Data Service"
echo "Fecha: $(date)"
echo "================================================================"

echo ""
echo "--- ESTADO ACTUAL DE BUCKETS ---"
for bucket in lab-couchstore lab-magma; do
  echo ""
  echo "[ $bucket ]"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/stats" \
    | jq '.op.samples | {
        total_items:        .curr_items[-1],
        mem_used_mb:        (.mem_used[-1] / 1024 / 1024 | round),
        quota_mb:           (.ep_max_size[-1] / 1024 / 1024 | round),
        resident_ratio_pct: .vb_active_resident_items_ratio[-1],
        total_ejects:       .ep_num_value_ejects[-1],
        bg_fetches:         .ep_bg_fetched[-1],
        avg_bg_wait_us:     .avg_bg_wait_time[-1],
        oom_errors:         .ep_tmp_oom_errors[-1],
        disk_queue:         .ep_queue_size[-1]
      }'
done

echo ""
echo "--- CONFIGURACIÓN DE BUCKETS ---"
for bucket in lab-couchstore lab-magma; do
  echo ""
  echo "[ $bucket ]"
  curl -s -u Administrator:password \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}" \
    | jq '{
        storageBackend:  .storageBackend,
        evictionPolicy:  .evictionPolicy,
        ramQuota_mb:     (.quota.ram / 1024 / 1024 | round),
        replicaNumber:   .replicaNumber,
        durabilityMin:   .durabilityMinLevel
      }'
done
EOF

chmod +x ~/lab02/generate_report.sh
~/lab02/generate_report.sh | tee ~/lab02/reporte_final.txt
```

2. Completa la tabla comparativa en tu documentación personal:

```bash
echo ""
echo "================================================================"
echo "TABLA COMPARATIVA PARA DOCUMENTACIÓN"
echo "================================================================"
echo ""
echo "| Característica              | Couchstore (valueOnly) | Magma (fullEviction) |"
echo "|---|---|---|"

for metric_name in "Resident Ratio final" "Total ejeciones" "BG Fetches totales" "Avg BG Wait (µs)" "OOM Errors"; do
  echo "| $metric_name | [ver reporte] | [ver reporte] |"
done
```

3. Responde las siguientes preguntas de análisis en tu cuaderno de laboratorio:

```
PREGUNTAS DE ANÁLISIS:

1. ¿A qué porcentaje de uso de memoria se activó la ejection en el bucket
   Couchstore? ¿Coincide con el high watermark esperado (75%)?

2. ¿Cuál fue el impacto en latencia de lectura cuando el resident ratio
   cayó por debajo del 50%? Compara con la latencia inicial.

3. ¿Por qué Magma requiere fullEviction mientras que Couchstore puede
   usar valueOnly? ¿Qué implicaciones operativas tiene esto?

4. ¿Cuánto mayor fue la latencia de persistToMajority vs none?
   ¿En qué casos de uso justificarías ese overhead?

5. ¿Qué información proporciona la Disk Write Queue sobre la salud
   del subsistema de almacenamiento?
```

---

## Validación y Pruebas

Ejecuta la siguiente secuencia de validación para confirmar que todos los objetivos del lab se cumplieron:

```bash
#!/bin/bash
# ~/lab02/validate_lab.sh
echo "================================================================"
echo "VALIDACIÓN FINAL - Lab 02-00-01"
echo "================================================================"

PASS=0
FAIL=0

check() {
  local desc=$1
  local condition=$2
  if eval "$condition" > /dev/null 2>&1; then
    echo "  ✓ PASS: $desc"
    ((PASS++))
  else
    echo "  ✗ FAIL: $desc"
    ((FAIL++))
  fi
}

echo ""
echo "1. Verificando existencia de buckets..."
check "Bucket lab-couchstore existe" \
  "curl -s -u Administrator:password http://192.168.1.101:8091/pools/default/buckets/lab-couchstore | jq -e '.name'"
check "Bucket lab-magma existe" \
  "curl -s -u Administrator:password http://192.168.1.101:8091/pools/default/buckets/lab-magma | jq -e '.name'"

echo ""
echo "2. Verificando configuración de storage engines..."
check "lab-couchstore usa Couchstore" \
  "curl -s -u Administrator:password http://192.168.1.101:8091/pools/default/buckets/lab-couchstore | jq -e '.storageBackend == \"couchstore\"'"
check "lab-magma usa Magma" \
  "curl -s -u Administrator:password http://192.168.1.101:8091/pools/default/buckets/lab-magma | jq -e '.storageBackend == \"magma\"'"

echo ""
echo "3. Verificando que se cargaron datos..."
ITEMS_CS=$(curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples.curr_items[-1]')
ITEMS_MG=$(curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-magma/stats" \
  | jq '.op.samples.curr_items[-1]')

check "lab-couchstore tiene datos (>50000 items)" \
  "[ $ITEMS_CS -gt 50000 ]"
check "lab-magma tiene datos (>50000 items)" \
  "[ $ITEMS_MG -gt 50000 ]"

echo ""
echo "4. Verificando que ocurrió ejection..."
EJECTS=$(curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples.ep_num_value_ejects[-1]')
check "Ejection activada en lab-couchstore (>0 ejects)" \
  "[ $EJECTS -gt 0 ]"

echo ""
echo "5. Verificando archivos de métricas capturados..."
METRIC_FILES=$(ls ~/lab02/metrics/*.json 2>/dev/null | wc -l)
check "Se capturaron al menos 8 snapshots de métricas" \
  "[ $METRIC_FILES -ge 8 ]"
check "Resultados de durabilidad guardados" \
  "[ -f ~/lab02/durability_results.json ]"

echo ""
echo "================================================================"
echo "RESULTADO: $PASS pruebas PASS | $FAIL pruebas FAIL"
echo "================================================================"
```

```bash
chmod +x ~/lab02/validate_lab.sh
~/lab02/validate_lab.sh
```

**Criterio de éxito:** Todas las verificaciones deben mostrar `✓ PASS`. Si alguna falla, revisa el paso correspondiente antes de continuar.

---

## Solución de Problemas

### Problema 1: La ejection no se activa aunque se cargaron muchos datos

**Síntomas:**
- `ep_num_value_ejects` permanece en 0 después de cargar cientos de miles de documentos
- El resident ratio se mantiene en 100% a pesar de que la memoria debería estar saturada
- `cbworkloadgen` completa sin errores pero las métricas no muestran presión de memoria

**Causa probable:**
El bucket tiene una cuota de RAM demasiado alta en relación con los datos cargados, o el tamaño de los documentos es demasiado pequeño. También puede ocurrir si la cuota global del clúster fue modificada después de crear el bucket, o si el high watermark fue reconfigurado a un valor muy alto.

**Solución:**

```bash
# 1. Verificar la cuota real asignada al bucket
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools/default/buckets/lab-couchstore \
  | jq '{ramQuota_mb: (.quota.ram / 1024 / 1024 | round)}'

# 2. Verificar el high watermark efectivo
curl -s -u Administrator:password \
  "http://192.168.1.101:8091/pools/default/buckets/lab-couchstore/stats" \
  | jq '.op.samples | {
      hwm_mb: (.ep_mem_high_wat[-1] / 1024 / 1024 | round),
      mem_used_mb: (.mem_used[-1] / 1024 / 1024 | round)
    }'

# 3. Si la cuota es demasiado alta, reducirla via REST API
curl -s -u Administrator:password \
  -X POST http://192.168.1.101:8091/pools/default/buckets/lab-couchstore \
  -d ramQuota=128

# 4. Alternativamente, cargar más datos con documentos más grandes
cbworkloadgen \
  -n 192.168.1.101:8091 \
  -u Administrator -p password \
  -b lab-couchstore \
  --num-items=200000 \
  --item-size=8192 \
  --prefix=extra_ \
  --set-pct=100 -t 4
```

---

### Problema 2: Error al crear el bucket Magma — "Magma is not supported"

**Síntomas:**
- La llamada REST para crear `lab-magma` retorna un error HTTP 400
- El mensaje de error indica: `"Magma is not supported for this bucket"` o `"storageBackend magma requires Enterprise Edition"`
- La Web Console no muestra la opción de Magma en el selector de storage engine

**Causa probable:**
Magma está disponible únicamente en **Couchbase Server Enterprise Edition**. Si el clúster está ejecutando Community Edition, o si la licencia de evaluación expiró, Magma no estará disponible. También puede ocurrir si la versión del servidor es anterior a 7.0, donde Magma fue introducido.

**Solución:**

```bash
# 1. Verificar la edición del servidor
curl -s -u Administrator:password \
  http://192.168.1.101:8091/pools \
  | jq '{version: .implementationVersion, edition: .isEnterprise}'

# 2. Verificar estado de la licencia
curl -s -u Administrator:password \
  http://192.168.1.101:8091/settings/license \
  | jq '{type: .type, expiry: .expiry, valid: .valid}'

# 3. Si la licencia expiró, renovar la licencia de evaluación en couchbase.com
# y aplicarla mediante:
curl -s -u Administrator:password \
  -X POST http://192.168.1.101:8091/settings/license \
  -d "license=<CONTENIDO_LICENCIA>"

# 4. Si el entorno es Community Edition, adaptar el lab:
# Crear el segundo bucket con Couchstore pero con fullEviction
curl -s -u Administrator:password \
  -X POST http://192.168.1.101:8091/pools/default/buckets \
  -d name=lab-magma-alt \
  -d bucketType=couchbase \
  -d ramQuota=256 \
  -d replicaNumber=2 \
  -d evictionPolicy=fullEviction \
  -d storageBackend=couchstore \
  -d flushEnabled=1

echo "⚠ Usando Couchstore con fullEviction como alternativa a Magma"
echo "  La comparación de storage engines no será posible, pero se"
echo "  pueden comparar las políticas de eviction valueOnly vs fullEviction"
```

---

## Limpieza del Entorno

Ejecuta los siguientes comandos para limpiar los recursos creados en este lab. **No ejecutes la limpieza si planeas continuar con el Lab 03**, ya que algunos datos pueden ser reutilizados.

```bash
echo "=== LIMPIEZA DEL LAB 02-00-01 ==="

# 1. Hacer flush de los buckets (opcional - alternativa al borrado)
# Útil si quieres mantener los buckets pero vaciarlos para el próximo lab
for bucket in lab-couchstore lab-magma; do
  echo "Haciendo flush de $bucket..."
  curl -s -u Administrator:password \
    -X POST \
    "http://192.168.1.101:8091/pools/default/buckets/${bucket}/controller/doFlush"
  sleep 3
done

# 2. Eliminar los buckets completamente (si no se necesitan en labs posteriores)
# DESCOMENTAR SOLO SI SE DESEA ELIMINAR LOS BUCKETS
# for bucket in lab-couchstore lab-magma; do
#   echo "Eliminando bucket $bucket..."
#   curl -s -u Administrator:password \
#     -X DELETE \
#     "http://192.168.1.101:8091/pools/default/buckets/${bucket}"
#   sleep 5
# done

# 3. Limpiar archivos temporales del lab (preservar métricas para referencia)
# Los archivos de métricas en ~/lab02/metrics/ se conservan como evidencia
echo "Archivos de métricas preservados en: ~/lab02/metrics/"
ls ~/lab02/metrics/ | wc -l
echo "archivos de métricas capturados"

# 4. Detener cualquier proceso de carga que pueda estar activo
pkill -f cbworkloadgen 2>/dev/null || true
pkill -f cbc-pillowfight 2>/dev/null || true

echo ""
echo "✓ Limpieza completada"
echo "  Buckets: flusheados (datos eliminados, configuración preservada)"
echo "  Métricas: conservadas en ~/lab02/metrics/"
echo "  Procesos de carga: detenidos"
```

---

## Resumen

En este laboratorio aplicaste de forma práctica los conceptos del flujo de escritura y lectura del Data Service de Couchbase bajo condiciones reales de presión de memoria. Los puntos clave que debiste haber observado y documentado son:

| Concepto | Observación práctica realizada |
|---|---|
| **Memory-first write** | Las escrituras de `cbworkloadgen` completaron con baja latencia independientemente del resident ratio |
| **Ejection policy (valueOnly)** | Couchstore expulsó valores pero retuvo metadatos; los GET siguieron funcionando con mayor latencia por BG fetch |
| **Ejection policy (fullEviction)** | Magma expulsó documentos completos; el overhead de BG fetch incluye reconstrucción de metadatos |
| **High Watermark (75%)** | La ejection se activó al superar el HWM; el pager trabajó hasta bajar al LWM (60%) |
| **Disk Write Queue** | La cola creció durante ráfagas de escritura y se drenó progresivamente; una cola que no drena indica saturación |
| **Durabilidad y latencia** | `persistToMajority` tuvo ~25x mayor latencia que `none`; el costo es proporcional al nivel de garantía |
| **Resident ratio** | La caída del resident ratio correlacionó directamente con el incremento de `avg_bg_wait_time` |

### Próximos pasos

El Lab 03 profundizará en la configuración del Query Service y estrategias de indexación. Los buckets creados en este lab (`lab-couchstore` y `lab-magma`) servirán como base de datos para los ejercicios de indexación, por lo que se recomienda **no eliminarlos** si se continúa en secuencia.

### Recursos adicionales

- [Documentación oficial: Memory and Storage en Couchbase](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/memory-and-storage.html)
- [Documentación oficial: Ejection Policies](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/eviction.html)
- [Documentación oficial: Magma Storage Engine](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/storage-engines.html)
- [Documentación oficial: Durability Levels](https://docs.couchbase.com/server/current/learn/data/durability.html)
- [REST API: Bucket Statistics](https://docs.couchbase.com/server/current/rest-api/rest-bucket-stats.html)
- [cbworkloadgen Reference](https://docs.couchbase.com/server/current/cli/cbworkloadgen-tool.html)

---
