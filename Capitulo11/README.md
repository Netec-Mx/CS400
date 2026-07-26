---LAB_START---
LAB_ID: 11-00-01
---MARKDOWN---
# Construcción de un dashboard operativo y alertas

## 1. Metadatos

| Campo | Valor |
|---|---|
| **Duración estimada** | 72 minutos |
| **Complejidad** | Alta |
| **Nivel Bloom** | Crear |
| **Servicios cubiertos** | Data, Query, Index, Search, Eventing, Analytics, XDCR |
| **Herramientas principales** | Couchbase 7.6, Prometheus 2.51.x, Grafana 10.4.x, PromQL, REST API |

---

## 2. Descripción General

En esta práctica se construye un sistema de observabilidad completo para un clúster Couchbase 7.6 de tres nodos, aplicando el modelo de tres pilares —métricas, logs y trazas— presentado en la Lección 11.1. El estudiante configurará el scraping de métricas con Prometheus, construirá un dashboard operativo en Grafana con cinco filas temáticas diferenciadas por servicio, establecerá baselines a partir de carga simulada real y configurará ocho reglas de alerta con umbrales justificados. La práctica culmina con la verificación de alertas mediante la introducción controlada de condiciones de umbral, consolidando el ciclo completo de observabilidad proactiva.

---

## 3. Objetivos de Aprendizaje

Al finalizar esta práctica, el estudiante será capaz de:

- [ ] Verificar y validar el endpoint nativo de métricas Prometheus en Couchbase 7.6 (`/metrics`) e integrarlo con un servidor Prometheus externo mediante configuración de scraping multi-nodo
- [ ] Construir un dashboard Grafana con cinco filas temáticas que cubran todos los servicios de Couchbase, utilizando paneles de tipo time series, stat, gauge y table con PromQL apropiado
- [ ] Establecer baselines de rendimiento mediante observación de métricas en estado estable con carga simulada y justificar umbrales de alerta a partir de esos baselines
- [ ] Configurar al menos ocho reglas de alerta en Grafana cubriendo memoria, latencia, disponibilidad, replicación y errores, y verificar su activación mediante condiciones controladas
- [ ] Correlacionar métricas de Grafana con logs del clúster Couchbase para diagnosticar anomalías identificadas durante las pruebas de alerta

---

## 4. Prerrequisitos

### Conocimiento Previo

| Área | Nivel Requerido |
|---|---|
| Couchbase Server 7.6 — administración básica | Intermedio |
| PromQL — sintaxis de queries de métricas | Básico |
| Grafana — navegación y creación de paneles | Básico |
| REST API de Couchbase con `curl` y `jq` | Básico |
| SSH y administración Linux | Intermedio |

### Acceso y Recursos

| Recurso | Estado Requerido |
|---|---|
| Clúster Couchbase 7.6 — 3 nodos operativos | ✅ Activo con Data, Query, Index, Search, Eventing, Analytics |
| Bucket `travel-sample` con ≥ 100,000 documentos | ✅ Cargado |
| Bucket `ecommerce` con datos KV simples | ✅ Cargado |
| Prometheus 2.51.x en nodo de observabilidad | ✅ Instalado |
| Grafana 10.4.x accesible en puerto 3000 | ✅ Instalado |
| Acceso SSH a todos los nodos con sudo | ✅ Disponible |
| `curl`, `jq` y `python3` en nodo cliente | ✅ Instalados |

---

## 5. Entorno de Laboratorio

### Topología de Red

```
┌─────────────────────────────────────────────────────────────┐
│  CLÚSTER COUCHBASE                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │  cb-node-1   │  │  cb-node-2   │  │  cb-node-3   │      │
│  │ 192.168.1.10 │  │ 192.168.1.11 │  │ 192.168.1.12 │      │
│  │ :8091/metrics│  │ :8091/metrics│  │ :8091/metrics│      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
└─────────────────────────────────────────────────────────────┘
         │                  │                  │
         └──────────────────┼──────────────────┘
                            │ scrape
┌─────────────────────────────────────────────────────────────┐
│  NODO DE OBSERVABILIDAD (192.168.1.20)                      │
│  Prometheus :9090  │  Grafana :3000                         │
└─────────────────────────────────────────────────────────────┘
         │
┌────────────────────┐
│  NODO CLIENTE      │
│  192.168.1.30      │
│  cbc-pillowfight   │
└────────────────────┘
```

### Tabla de Software

| Componente | Versión | Puerto | Nodo |
|---|---|---|---|
| Couchbase Server EE | 7.6.x | 8091, 11210 | cb-node-1/2/3 |
| Prometheus | 2.51.x | 9090 | observabilidad |
| Grafana | 10.4.x | 3000 | observabilidad |
| cbc-pillowfight | libcouchbase | — | cliente |

### Comandos de Verificación del Entorno

Ejecutar desde el **nodo de observabilidad** antes de comenzar:

```bash
# Verificar conectividad con los tres nodos de Couchbase
for node in 192.168.1.10 192.168.1.11 192.168.1.12; do
  echo -n "Nodo $node: "
  curl -s -o /dev/null -w "%{http_code}" \
    -u Administrator:password \
    http://${node}:8091/pools/default && echo ""
done

# Verificar que el endpoint /metrics responde en el nodo primario
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics | head -20

# Verificar Prometheus
curl -s http://localhost:9090/-/ready

# Verificar Grafana
curl -s http://localhost:3000/api/health | jq .
```

**Salida esperada de verificación:**
```
Nodo 192.168.1.10: 200
Nodo 192.168.1.11: 200
Nodo 192.168.1.12: 200
# HELP kv_ops Number of operations per second
...
Prometheus is Ready.
{"commit":"...","database":"ok","version":"10.4.x"}
```

---

## 6. Pasos de la Práctica

---

### Paso 1: Validación del Endpoint de Métricas Nativo de Couchbase

**Objetivo:** Confirmar que los tres nodos exponen métricas en formato Prometheus y explorar la estructura de namespaces de métricas disponibles.

#### Instrucciones

**1.1** Desde el nodo cliente, explorar el endpoint `/metrics` del nodo primario e identificar los namespaces disponibles:

```bash
# Extraer todos los namespaces únicos de métricas disponibles
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^# HELP" \
  | awk '{print $3}' \
  | sed 's/_[^_]*$//' \
  | sort -u
```

**1.2** Verificar métricas específicas por servicio para confirmar que todos los servicios están reportando:

```bash
# Verificar métricas del Data Service (KV)
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^kv_" | head -15

# Verificar métricas del Query Service
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^n1ql_" | head -10

# Verificar métricas del Index Service
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^index_" | head -10

# Verificar métricas del Search Service
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^fts_" | head -10
```

**1.3** Contar el total de métricas expuestas por nodo:

```bash
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^# HELP" | wc -l
```

#### Salida Esperada

```
# Namespaces identificados (muestra):
audit
cbas
eventing
fts
index
kv
n1ql
replication
sys

# Métricas KV (muestra):
kv_ops{bucket="travel-sample",op="get"} 0
kv_ops{bucket="travel-sample",op="set"} 0
kv_ep_bg_fetched{bucket="travel-sample"} 0
kv_mem_used_bytes{bucket="travel-sample"} 52428800

# Total de métricas: ~350-500 dependiendo de los servicios activos
```

#### Verificación

```bash
# Confirmar que los 3 nodos exponen métricas (deben retornar > 0 líneas)
for node in 192.168.1.10 192.168.1.11 192.168.1.12; do
  count=$(curl -s -u Administrator:password \
    http://${node}:8091/metrics | grep "^# HELP" | wc -l)
  echo "Nodo $node: $count métricas disponibles"
done
```

---

### Paso 2: Configuración de Prometheus para Scraping Multi-Nodo

**Objetivo:** Configurar Prometheus para recolectar métricas de los tres nodos de Couchbase con etiquetas apropiadas para identificación por nodo y servicio.

#### Instrucciones

**2.1** En el nodo de observabilidad, crear el archivo de configuración de Prometheus:

```bash
sudo tee /etc/prometheus/prometheus.yml > /dev/null << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  scrape_timeout: 10s

alerting:
  alertmanagers:
    - static_configs:
        - targets: []

rule_files:
  - "/etc/prometheus/rules/*.yml"

scrape_configs:
  # Scraping de métricas nativas de Couchbase - los 3 nodos
  - job_name: 'couchbase-cluster'
    metrics_path: '/metrics'
    scheme: http
    basic_auth:
      username: 'Administrator'
      password: 'password'
    static_configs:
      - targets:
          - '192.168.1.10:8091'
          - '192.168.1.11:8091'
          - '192.168.1.12:8091'
        labels:
          cluster: 'lab-cluster'
          environment: 'lab'
    relabel_configs:
      # Extraer el hostname del target para etiquetado
      - source_labels: [__address__]
        target_label: instance
        regex: '([^:]+).*'
        replacement: '${1}'

  # Scraping de métricas del sistema en cada nodo (node_exporter)
  - job_name: 'node-exporter'
    static_configs:
      - targets:
          - '192.168.1.10:9100'
          - '192.168.1.11:9100'
          - '192.168.1.12:9100'
        labels:
          cluster: 'lab-cluster'

  # Prometheus self-monitoring
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
```

**2.2** Crear el directorio de reglas de alerta:

```bash
sudo mkdir -p /etc/prometheus/rules
```

**2.3** Validar la configuración de Prometheus antes de recargar:

```bash
# Validar sintaxis del archivo de configuración
promtool check config /etc/prometheus/prometheus.yml
```

**2.4** Recargar Prometheus con la nueva configuración:

```bash
# Recargar configuración sin reiniciar el servicio
sudo systemctl reload prometheus
# Si no tiene systemd, usar señal HUP:
# sudo kill -HUP $(pgrep prometheus)

# Esperar 5 segundos y verificar que los targets están activos
sleep 5
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | {job: .labels.job, instance: .labels.instance, health: .health}'
```

**2.5** Verificar que las métricas de Couchbase están disponibles en Prometheus:

```bash
# Query de prueba: operaciones KV en el bucket travel-sample
curl -s "http://localhost:9090/api/v1/query?query=kv_ops" \
  | jq '.data.result | length'
```

#### Salida Esperada

```
# promtool check config
Checking /etc/prometheus/prometheus.yml
  SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

# targets activos
{"job": "couchbase-cluster", "instance": "192.168.1.10", "health": "up"}
{"job": "couchbase-cluster", "instance": "192.168.1.11", "health": "up"}
{"job": "couchbase-cluster", "instance": "192.168.1.12", "health": "up"}

# Número de series de kv_ops: debe ser > 0
12
```

#### Verificación

```bash
# Confirmar en la UI de Prometheus que todos los targets están UP
echo "Abrir http://localhost:9090/targets en el navegador"
echo "Todos los targets del job 'couchbase-cluster' deben mostrar estado UP"

# Verificar que hay datos históricos después de 30 segundos
sleep 30
curl -s "http://localhost:9090/api/v1/query?query=up{job='couchbase-cluster'}" \
  | jq '.data.result[] | {instance: .metric.instance, value: .value[1]}'
```

---

### Paso 3: Generación de Carga de Trabajo para Establecer Baselines

**Objetivo:** Generar carga representativa en el clúster durante 15 minutos para observar métricas en estado estable y establecer baselines para los umbrales de alerta.

#### Instrucciones

**3.1** Desde el **nodo cliente**, iniciar carga KV con `cbc-pillowfight`:

```bash
# Carga mixta de lectura/escritura: 70% reads, 30% writes
# Ejecutar en segundo plano durante el resto del lab
cbc-pillowfight \
  --spec couchbase://192.168.1.10/travel-sample \
  --username Administrator \
  --password password \
  --num-items 50000 \
  --num-threads 4 \
  --min-size 512 \
  --max-size 2048 \
  --set-pct 30 \
  --rate-limit 1000 \
  --num-cycles -1 \
  > /tmp/pillowfight.log 2>&1 &

echo "PID de pillowfight: $!"
echo $! > /tmp/pillowfight.pid
```

**3.2** Generar carga de consultas SQL++ con un script Python:

```bash
cat > /tmp/query_load.py << 'EOF'
import subprocess
import time
import random

queries = [
    "SELECT COUNT(*) FROM `travel-sample` WHERE type='airline';",
    "SELECT name, iata FROM `travel-sample` WHERE type='airline' LIMIT 10;",
    "SELECT * FROM `travel-sample` WHERE type='route' AND sourceairport='SFO' LIMIT 5;",
    "SELECT AVG(stops) FROM `travel-sample` WHERE type='route';",
    "SELECT name, city FROM `travel-sample` WHERE type='airport' AND country='United States' LIMIT 20;",
]

print("Iniciando generador de carga SQL++...")
count = 0
while True:
    query = random.choice(queries)
    cmd = [
        'curl', '-s', '-u', 'Administrator:password',
        'http://192.168.1.10:8093/query/service',
        '-d', f'statement={query}'
    ]
    subprocess.run(cmd, capture_output=True)
    count += 1
    if count % 50 == 0:
        print(f"  {count} queries ejecutadas")
    time.sleep(random.uniform(0.05, 0.2))
EOF

# Ejecutar en segundo plano
python3 /tmp/query_load.py > /tmp/query_load.log 2>&1 &
echo $! > /tmp/query_load.pid
echo "Generador SQL++ iniciado con PID: $(cat /tmp/query_load.pid)"
```

**3.3** Esperar 5 minutos y luego capturar las métricas baseline:

```bash
echo "Esperando 5 minutos para acumular datos baseline..."
sleep 300

# Capturar baseline de métricas clave
echo "=== BASELINE MÉTRICAS COUCHBASE ===" > /tmp/baseline.txt
echo "Timestamp: $(date)" >> /tmp/baseline.txt
echo "" >> /tmp/baseline.txt

# KV ops rate
echo "--- KV Operations Rate ---" >> /tmp/baseline.txt
curl -s "http://localhost:9090/api/v1/query?query=rate(kv_ops[5m])" \
  | jq '.data.result[] | {instance: .metric.instance, bucket: .metric.bucket, op: .metric.op, rate: .value[1]}' \
  >> /tmp/baseline.txt

# Query latency p99
echo "--- Query Latency p99 ---" >> /tmp/baseline.txt
curl -s "http://localhost:9090/api/v1/query?query=n1ql_request_time" \
  | jq '.data.result[] | {instance: .metric.instance, value: .value[1]}' \
  >> /tmp/baseline.txt

# Memory usage
echo "--- Memory Usage ---" >> /tmp/baseline.txt
curl -s "http://localhost:9090/api/v1/query?query=kv_mem_used_bytes" \
  | jq '.data.result[] | {instance: .metric.instance, bucket: .metric.bucket, bytes: .value[1]}' \
  >> /tmp/baseline.txt

cat /tmp/baseline.txt
```

#### Salida Esperada

```
=== BASELINE MÉTRICAS COUCHBASE ===
Timestamp: Mon Jan 15 10:30:00 UTC 2025

--- KV Operations Rate ---
{"instance": "192.168.1.10", "bucket": "travel-sample", "op": "get", "rate": "650.3"}
{"instance": "192.168.1.10", "bucket": "travel-sample", "op": "set", "rate": "280.1"}

--- Query Latency p99 ---
{"instance": "192.168.1.10", "value": "145000"}

--- Memory Usage ---
{"instance": "192.168.1.10", "bucket": "travel-sample", "bytes": "524288000"}
```

#### Verificación

```bash
# Confirmar que Prometheus tiene al menos 5 minutos de datos
curl -s "http://localhost:9090/api/v1/query_range?query=kv_ops&start=$(date -d '5 minutes ago' +%s)&end=$(date +%s)&step=15" \
  | jq '.data.result[0].values | length'
# Debe retornar ~20 (un punto cada 15 segundos en 5 minutos)
```

---

### Paso 4: Construcción del Dashboard en Grafana — Estructura y Fila 1 (Visión General)

**Objetivo:** Crear el dashboard base en Grafana y construir la primera fila con la visión general del clúster.

#### Instrucciones

**4.1** Configurar el datasource de Prometheus en Grafana mediante API:

```bash
# Crear datasource de Prometheus en Grafana
curl -s -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  http://localhost:3000/api/datasources \
  -d '{
    "name": "Prometheus-Couchbase",
    "type": "prometheus",
    "url": "http://localhost:9090",
    "access": "proxy",
    "isDefault": true,
    "jsonData": {
      "timeInterval": "15s",
      "queryTimeout": "60s"
    }
  }' | jq '{id: .id, name: .name, message: .message}'
```

**4.2** Crear el dashboard base con la primera fila mediante la API de Grafana. Guardar el JSON del dashboard:

```bash
cat > /tmp/dashboard_row1.json << 'DASHBOARD_EOF'
{
  "dashboard": {
    "title": "Couchbase Operational Dashboard",
    "tags": ["couchbase", "operational", "lab"],
    "timezone": "browser",
    "refresh": "30s",
    "time": {"from": "now-1h", "to": "now"},
    "panels": [
      {
        "id": 1,
        "title": "Estado de Nodos del Clúster",
        "type": "stat",
        "gridPos": {"h": 4, "w": 8, "x": 0, "y": 0},
        "targets": [{
          "expr": "up{job='couchbase-cluster'}",
          "legendFormat": "{{instance}}"
        }],
        "options": {
          "colorMode": "background",
          "graphMode": "none",
          "reduceOptions": {"calcs": ["lastNotNull"]}
        },
        "fieldConfig": {
          "defaults": {
            "mappings": [
              {"type": "value", "options": {"0": {"text": "DOWN", "color": "red"}, "1": {"text": "UP", "color": "green"}}}
            ],
            "thresholds": {"steps": [{"value": 0, "color": "red"}, {"value": 1, "color": "green"}]}
          }
        }
      },
      {
        "id": 2,
        "title": "Memoria RAM Usada vs Quota (%)",
        "type": "gauge",
        "gridPos": {"h": 4, "w": 8, "x": 8, "y": 0},
        "targets": [{
          "expr": "100 * kv_mem_used_bytes / kv_ep_max_size",
          "legendFormat": "{{instance}} - {{bucket}}"
        }],
        "fieldConfig": {
          "defaults": {
            "unit": "percent",
            "min": 0, "max": 100,
            "thresholds": {"steps": [{"value": 0, "color": "green"}, {"value": 70, "color": "yellow"}, {"value": 85, "color": "red"}]}
          }
        }
      },
      {
        "id": 3,
        "title": "Operaciones KV por Segundo",
        "type": "timeseries",
        "gridPos": {"h": 6, "w": 16, "x": 0, "y": 4},
        "targets": [
          {"expr": "rate(kv_ops{op='get'}[2m])", "legendFormat": "GET - {{instance}}"},
          {"expr": "rate(kv_ops{op='set'}[2m])", "legendFormat": "SET - {{instance}}"}
        ],
        "fieldConfig": {"defaults": {"unit": "ops"}}
      },
      {
        "id": 4,
        "title": "Uso de Disco por Bucket",
        "type": "bargauge",
        "gridPos": {"h": 6, "w": 8, "x": 16, "y": 4},
        "targets": [{
          "expr": "kv_ep_db_data_size_bytes",
          "legendFormat": "{{bucket}} - {{instance}}"
        }],
        "fieldConfig": {"defaults": {"unit": "bytes"}}
      }
    ]
  },
  "overwrite": false,
  "folderId": 0
}
DASHBOARD_EOF

# Crear el dashboard en Grafana
curl -s -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  http://localhost:3000/api/dashboards/db \
  -d @/tmp/dashboard_row1.json \
  | jq '{id: .id, uid: .uid, url: .url, status: .status}'
```

**4.3** Guardar el UID del dashboard para usarlo en los pasos siguientes:

```bash
DASHBOARD_UID=$(curl -s -u admin:admin \
  "http://localhost:3000/api/dashboards/home" \
  | jq -r '.dashboard.uid // empty')

# Alternativa: buscar por título
DASHBOARD_UID=$(curl -s -u admin:admin \
  "http://localhost:3000/api/search?query=Couchbase+Operational" \
  | jq -r '.[0].uid')

echo "Dashboard UID: $DASHBOARD_UID"
echo $DASHBOARD_UID > /tmp/dashboard_uid.txt
```

#### Salida Esperada

```json
{
  "id": 1,
  "uid": "abc123xyz",
  "url": "/d/abc123xyz/couchbase-operational-dashboard",
  "status": "success"
}
```

#### Verificación

```bash
# Verificar que el dashboard existe y tiene paneles
curl -s -u admin:admin \
  "http://localhost:3000/api/dashboards/uid/$(cat /tmp/dashboard_uid.txt)" \
  | jq '.dashboard | {title: .title, panels: (.panels | length)}'
# Debe mostrar title: "Couchbase Operational Dashboard" y panels: 4
```

---

### Paso 5: Filas 2 y 3 — Servicio Data, Query e Index

**Objetivo:** Agregar al dashboard los paneles de métricas críticas del Data Service (latencias KV, resident ratio, cache miss) y del Query/Index Service.

#### Instrucciones

**5.1** Acceder al dashboard en Grafana Web (`http://localhost:3000`) y agregar los siguientes paneles manualmente, o usar el editor JSON. Para los paneles del **Data Service**, usar estas queries PromQL:

```promql
# Panel: KV Get Latency percentiles (p50, p95, p99)
# Tipo: Time Series
histogram_quantile(0.50, rate(kv_cmd_duration_seconds_bucket{op="get"}[5m]))
histogram_quantile(0.95, rate(kv_cmd_duration_seconds_bucket{op="get"}[5m]))
histogram_quantile(0.99, rate(kv_cmd_duration_seconds_bucket{op="get"}[5m]))

# Panel: Resident Ratio por Bucket
# Tipo: Gauge (umbral crítico en 10%)
100 * kv_ep_num_non_resident / (kv_curr_items + kv_ep_num_non_resident)
# NOTA: resident ratio = 100 - porcentaje_no_residente

# Panel: Cache Miss Ratio
# Tipo: Time Series
rate(kv_ep_bg_fetched[2m]) / (rate(kv_ops{op="get"}[2m]) + 0.001)

# Panel: Evictions por Segundo
# Tipo: Time Series
rate(kv_ep_num_value_ejects[2m])

# Panel: DCP Replication Lag (items pendientes)
# Tipo: Stat
kv_ep_dcp_replica_items_remaining
```

**5.2** Agregar paneles del **Query Service e Index Service**:

```promql
# Panel: Query Request Rate
# Tipo: Time Series
rate(n1ql_requests[2m])

# Panel: Query Latency p99
# Tipo: Time Series (umbral de alerta en 500ms)
n1ql_request_time / n1ql_requests

# Panel: Queries Activas en Ejecución
# Tipo: Stat
n1ql_active_requests

# Panel: Errores de N1QL por Segundo
# Tipo: Time Series
rate(n1ql_errors[2m])

# Panel: Index RAM Usage
# Tipo: Gauge
index_memory_used_total / index_memory_quota * 100

# Panel: Index Scan Rate
# Tipo: Time Series
rate(index_num_rows_scanned[2m])
```

**5.3** Verificar los paneles con una query de prueba directamente en Prometheus:

```bash
# Verificar que hay datos de latencia de queries
curl -s "http://localhost:9090/api/v1/query?query=n1ql_request_time" \
  | jq '.data.result[] | {instance: .metric.instance, value: .value[1]}'

# Verificar métricas de índices
curl -s "http://localhost:9090/api/v1/query?query=index_memory_used_total" \
  | jq '.data.result[] | {instance: .metric.instance, value: .value[1]}'
```

#### Salida Esperada

```json
[
  {"instance": "192.168.1.10", "value": "2450000"},
  {"instance": "192.168.1.11", "value": "1890000"}
]
```

#### Verificación

```bash
# Confirmar que los paneles de Data y Query tienen datos en las últimas 2 horas
curl -s "http://localhost:9090/api/v1/query_range?\
query=rate(n1ql_requests[2m])&\
start=$(date -d '30 minutes ago' +%s)&\
end=$(date +%s)&step=30" \
  | jq '.data.result | length'
# Debe ser > 0
```

---

### Paso 6: Fila 4 — Search, Eventing, Analytics y XDCR

**Objetivo:** Completar el dashboard con métricas de los servicios avanzados y XDCR.

#### Instrucciones

**6.1** Agregar paneles para el **Search Service (FTS)**:

```promql
# Panel: FTS Query Rate
# Tipo: Time Series
rate(fts_total_queries[2m])

# Panel: FTS Query Latency (ms)
# Tipo: Time Series
fts_avg_queries_latency

# Panel: FTS Errores
# Tipo: Stat
rate(fts_total_queries_error[2m])
```

**6.2** Agregar paneles para **Eventing y Analytics**:

```promql
# Panel: Eventing - Tasa de Procesamiento de Eventos
# Tipo: Time Series
rate(eventing_processed_count[2m])

# Panel: Eventing - Fallos de Funciones
# Tipo: Stat
eventing_failed_count

# Panel: Analytics - Query Throughput
# Tipo: Time Series
rate(cbas_incoming_records_count[2m])
```

**6.3** Agregar paneles para **XDCR**:

```promql
# Panel: XDCR Replication Lag (cambios pendientes)
# Tipo: Time Series (umbral de alerta en 30s equivalente)
replication_changes_left

# Panel: XDCR Data Replication Rate
# Tipo: Time Series
rate(replication_data_replicated[2m])

# Panel: XDCR Errores de Replicación
# Tipo: Stat
replication_num_failedckpts
```

**6.4** Verificar disponibilidad de métricas XDCR (requiere que XDCR esté configurado):

```bash
# Verificar métricas XDCR disponibles
curl -s -u Administrator:password \
  http://192.168.1.10:8091/metrics \
  | grep "^replication_" | head -10

# Si XDCR no está configurado, las métricas replication_ no aparecerán
# En ese caso, verificar con la API REST de XDCR
curl -s -u Administrator:password \
  http://192.168.1.10:8091/pools/default/remoteClusters \
  | jq .
```

#### Salida Esperada

```
# Métricas XDCR (si hay replicación configurada):
replication_changes_left{pipelineType="Main",sourceBucketName="travel-sample",...} 0
replication_data_replicated{...} 1048576

# Si no hay XDCR configurado:
[]
```

#### Verificación

```bash
# Confirmar que el dashboard tiene al menos 12 paneles al finalizar esta fila
curl -s -u admin:admin \
  "http://localhost:3000/api/dashboards/uid/$(cat /tmp/dashboard_uid.txt)" \
  | jq '.dashboard.panels | length'
```

---

### Paso 7: Fila 5 — Panel de Logs y Eventos del Clúster

**Objetivo:** Integrar información de logs del clúster Couchbase en el dashboard para correlacionar eventos con métricas.

#### Instrucciones

**7.1** Consultar el log de eventos del clúster via REST API y crear un script de monitoreo:

```bash
# Consultar eventos recientes del clúster (últimos 20)
curl -s -u Administrator:password \
  "http://192.168.1.10:8091/logs" \
  | python3 -m json.tool \
  | jq '.list[:20] | .[] | {time: .serverTime, code: .code, text: .text, node: .node}' \
  2>/dev/null || \
curl -s -u Administrator:password \
  "http://192.168.1.10:8091/logs" \
  | jq '.list[:5]'
```

**7.2** Crear un script que extrae y formatea los errores del log de query para análisis:

```bash
cat > /tmp/check_logs.sh << 'EOF'
#!/bin/bash
# Script: check_couchbase_logs.sh
# Extrae errores recientes de los logs de Couchbase en todos los nodos

NODES=("192.168.1.10" "192.168.1.11" "192.168.1.12")
LOG_PATH="/opt/couchbase/var/lib/couchbase/logs"

echo "=== Verificación de Logs Couchbase - $(date) ==="

for node in "${NODES[@]}"; do
  echo ""
  echo "--- Nodo: $node ---"

  # Errores en el log del Data Service (últimas 2 horas)
  echo "[KV/Data Service - Errores recientes]"
  ssh -o StrictHostKeyChecking=no couchbase@${node} \
    "tail -n 200 ${LOG_PATH}/memcached.log 2>/dev/null | grep -i 'error\|warn\|fatal' | tail -5" \
    2>/dev/null || echo "  (no accesible via SSH)"

  # Errores en el log de Query
  echo "[Query Service - Errores recientes]"
  ssh -o StrictHostKeyChecking=no couchbase@${node} \
    "tail -n 200 ${LOG_PATH}/query.log 2>/dev/null | grep -i 'error\|panic' | tail -5" \
    2>/dev/null || echo "  (no accesible via SSH)"
done

# Eventos del clúster via REST API (nodo primario)
echo ""
echo "--- Eventos del Clúster (REST API) ---"
curl -s -u Administrator:password \
  "http://192.168.1.10:8091/logs" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
events = data.get('list', [])[:10]
for e in events:
    print(f\"  [{e.get('serverTime','?')}] [{e.get('code','?')}] {e.get('text','?')[:80]}\")
" 2>/dev/null
EOF

chmod +x /tmp/check_logs.sh
bash /tmp/check_logs.sh
```

**7.3** En Grafana, agregar un panel de texto/tabla para mostrar eventos recientes. Usar la siguiente query de Prometheus que cuenta eventos por tipo (si se tiene Loki, usar LogQL; de lo contrario, usar un panel de tipo **Text** con iframe o **Table** con datos de la API):

```bash
# Crear un panel de anotaciones en Grafana para eventos del clúster
# Esto permite correlacionar eventos con métricas en el timeline

curl -s -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  http://localhost:3000/api/annotations \
  -d "{
    \"dashboardUID\": \"$(cat /tmp/dashboard_uid.txt)\",
    \"time\": $(date +%s000),
    \"timeEnd\": $(date +%s000),
    \"tags\": [\"couchbase\", \"baseline-start\"],
    \"text\": \"Inicio de período de baseline - carga simulada activa\"
  }" | jq '{id: .id, message: .message}'
```

#### Salida Esperada

```
=== Verificación de Logs Couchbase - Mon Jan 15 10:45:00 UTC 2025 ===

--- Nodo: 192.168.1.10 ---
[KV/Data Service - Errores recientes]
  (no hay errores recientes)
[Query Service - Errores recientes]
  (no hay errores recientes)

--- Eventos del Clúster (REST API) ---
  [2025-01-15T10:30:00Z] [10000] Rebalance completed successfully
  [2025-01-15T10:00:00Z] [20010] Bucket travel-sample created
```

#### Verificación

```bash
# Confirmar que la anotación se creó en Grafana
curl -s -u admin:admin \
  "http://localhost:3000/api/annotations?dashboardUID=$(cat /tmp/dashboard_uid.txt)" \
  | jq '.[0] | {id: .id, text: .text, tags: .tags}'
```

---

### Paso 8: Configuración de Reglas de Alerta en Prometheus

**Objetivo:** Definir las ocho reglas de alerta requeridas en archivos de reglas de Prometheus con umbrales justificados por los baselines establecidos.

#### Instrucciones

**8.1** Crear el archivo de reglas de alerta de Prometheus:

```bash
sudo tee /etc/prometheus/rules/couchbase_alerts.yml > /dev/null << 'EOF'
groups:
  - name: couchbase_memory_alerts
    interval: 30s
    rules:
      # Alerta 1: Memoria RAM > 85% de quota
      - alert: CouchbaseMemoryHighUsage
        expr: |
          (kv_mem_used_bytes / kv_ep_max_size) * 100 > 85
        for: 2m
        labels:
          severity: critical
          service: data
        annotations:
          summary: "Memoria RAM del bucket supera el 85% de la quota"
          description: "Bucket {{ $labels.bucket }} en nodo {{ $labels.instance }} usa {{ $value | printf \"%.1f\" }}% de su quota de memoria. Considerar aumentar quota o reducir dataset activo."
          runbook_url: "http://wiki.internal/runbooks/couchbase-memory"

      # Alerta 2: Resident Ratio < 10%
      - alert: CouchbaseLowResidentRatio
        expr: |
          (1 - (kv_ep_num_non_resident / (kv_curr_items + kv_ep_num_non_resident + 0.001))) * 100 < 10
        for: 5m
        labels:
          severity: critical
          service: data
        annotations:
          summary: "Resident ratio crítico: menos del 10% de items en memoria"
          description: "Bucket {{ $labels.bucket }} en {{ $labels.instance }} tiene solo {{ $value | printf \"%.1f\" }}% de items en RAM. Rendimiento de lecturas severamente degradado."

  - name: couchbase_query_alerts
    interval: 30s
    rules:
      # Alerta 3: Query Latency p99 > 500ms
      - alert: CouchbaseQueryHighLatency
        expr: |
          (n1ql_request_time / (n1ql_requests + 0.001)) > 0.5
        for: 3m
        labels:
          severity: warning
          service: query
        annotations:
          summary: "Latencia media de queries N1QL supera 500ms"
          description: "Nodo {{ $labels.instance }} reporta latencia media de {{ $value | printf \"%.3f\" }}s por query. Revisar plan de ejecución e índices disponibles."

      # Alerta 4: Índice en estado degradado (build pendiente)
      - alert: CouchbaseIndexDegraded
        expr: |
          index_num_docs_pending > 10000
        for: 5m
        labels:
          severity: warning
          service: index
        annotations:
          summary: "Índice con más de 10,000 documentos pendientes de indexación"
          description: "Índice en {{ $labels.instance }} tiene {{ $value }} documentos pendientes. El índice puede estar en estado BUILD o CATCHUP."

  - name: couchbase_replication_alerts
    interval: 30s
    rules:
      # Alerta 5: XDCR Replication Lag > 30s (aproximado por cambios pendientes > umbral)
      - alert: CouchbaseXDCRLagHigh
        expr: |
          replication_changes_left > 50000
        for: 2m
        labels:
          severity: warning
          service: xdcr
        annotations:
          summary: "XDCR replication lag elevado: más de 50,000 cambios pendientes"
          description: "Replicación XDCR del bucket {{ $labels.sourceBucketName }} tiene {{ $value }} cambios sin replicar. Verificar conectividad con clúster remoto."

  - name: couchbase_storage_alerts
    interval: 60s
    rules:
      # Alerta 6: Disk Usage > 80%
      - alert: CouchbaseDiskUsageHigh
        expr: |
          (kv_ep_db_data_size_bytes / kv_ep_db_file_size_bytes) * 100 > 80
        for: 5m
        labels:
          severity: warning
          service: data
        annotations:
          summary: "Uso de disco del bucket supera el 80%"
          description: "Bucket {{ $labels.bucket }} en {{ $labels.instance }} usa {{ $value | printf \"%.1f\" }}% del espacio de archivo. Considerar compactación o expansión de almacenamiento."

  - name: couchbase_availability_alerts
    interval: 15s
    rules:
      # Alerta 7: Nodo no disponible
      - alert: CouchbaseNodeDown
        expr: |
          up{job="couchbase-cluster"} == 0
        for: 1m
        labels:
          severity: critical
          service: cluster
        annotations:
          summary: "Nodo Couchbase no disponible"
          description: "El nodo {{ $labels.instance }} no está respondiendo al scraping de Prometheus. Verificar estado del servicio y conectividad de red."

  - name: couchbase_error_alerts
    interval: 30s
    rules:
      # Alerta 8: Tasa de errores KV > 1%
      - alert: CouchbaseKVHighErrorRate
        expr: |
          (rate(kv_cmd_total{result="error"}[5m]) / (rate(kv_cmd_total[5m]) + 0.001)) * 100 > 1
        for: 3m
        labels:
          severity: warning
          service: data
        annotations:
          summary: "Tasa de errores KV supera el 1%"
          description: "Bucket {{ $labels.bucket }} en {{ $labels.instance }} reporta {{ $value | printf \"%.2f\" }}% de operaciones KV con error. Revisar logs del Data Service."
EOF
```

**8.2** Validar las reglas de alerta:

```bash
promtool check rules /etc/prometheus/rules/couchbase_alerts.yml
```

**8.3** Recargar Prometheus para activar las reglas:

```bash
sudo systemctl reload prometheus
sleep 5

# Verificar que las reglas están cargadas
curl -s http://localhost:9090/api/v1/rules \
  | jq '.data.groups[] | {name: .name, rules: [.rules[] | {alert: .name, state: .state}]}'
```

#### Salida Esperada

```
# promtool check rules
Checking /etc/prometheus/rules/couchbase_alerts.yml
  SUCCESS: 8 rules found

# Reglas cargadas en Prometheus:
{
  "name": "couchbase_memory_alerts",
  "rules": [
    {"alert": "CouchbaseMemoryHighUsage", "state": "inactive"},
    {"alert": "CouchbaseLowResidentRatio", "state": "inactive"}
  ]
}
...
```

#### Verificación

```bash
# Confirmar que las 8 alertas están registradas en estado 'inactive' (normal = no disparadas)
curl -s http://localhost:9090/api/v1/rules \
  | jq '[.data.groups[].rules[]] | length'
# Debe retornar 8
```

---

### Paso 9: Configuración de Alertas en Grafana con Canal de Notificación

**Objetivo:** Configurar las alertas en Grafana conectadas a Prometheus como datasource de alertas, con un canal de notificación funcional.

#### Instrucciones

**9.1** Configurar un contact point en Grafana (usando webhook para el lab):

```bash
# Crear contact point de tipo webhook (para testing en lab)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  http://localhost:3000/api/v1/provisioning/contact-points \
  -d '{
    "name": "Couchbase-Lab-Webhook",
    "type": "webhook",
    "settings": {
      "url": "http://localhost:5001/alerts",
      "httpMethod": "POST"
    },
    "disableResolveMessage": false
  }' | jq '{uid: .uid, name: .name}'
```

**9.2** Iniciar un receptor de webhooks simple para capturar alertas en el lab:

```bash
cat > /tmp/webhook_receiver.py << 'EOF'
#!/usr/bin/env python3
"""Receptor simple de webhooks de alertas para el lab"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json, datetime

class AlertHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers['Content-Length'])
        body = json.loads(self.rfile.read(length))
        timestamp = datetime.datetime.now().strftime('%H:%M:%S')
        print(f"\n[{timestamp}] === ALERTA RECIBIDA ===")
        for alert in body.get('alerts', [body]):
            name = alert.get('labels', {}).get('alertname', 'unknown')
            status = alert.get('status', 'unknown')
            instance = alert.get('labels', {}).get('instance', 'unknown')
            print(f"  Alerta: {name} | Estado: {status} | Instancia: {instance}")
        self.send_response(200)
        self.end_headers()

    def log_message(self, format, *args):
        pass  # Silenciar logs HTTP

print("Receptor de alertas iniciado en puerto 5001...")
HTTPServer(('0.0.0.0', 5001), AlertHandler).serve_forever()
EOF

python3 /tmp/webhook_receiver.py &
echo $! > /tmp/webhook.pid
echo "Receptor webhook iniciado con PID: $(cat /tmp/webhook.pid)"
```

**9.3** Configurar la política de notificación en Grafana:

```bash
# Configurar política de enrutamiento de alertas
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -u admin:admin \
  http://localhost:3000/api/v1/provisioning/policies \
  -d '{
    "receiver": "Couchbase-Lab-Webhook",
    "group_by": ["alertname", "instance"],
    "group_wait": "10s",
    "group_interval": "30s",
    "repeat_interval": "5m",
    "routes": [
      {
        "receiver": "Couchbase-Lab-Webhook",
        "matchers": ["severity=critical"],
        "group_wait": "5s"
      }
    ]
  }' | jq .
```

#### Salida Esperada

```json
{"uid": "webhook-001", "name": "Couchbase-Lab-Webhook"}
```

#### Verificación

```bash
# Enviar alerta de prueba al webhook
curl -s -X POST \
  -H "Content-Type: application/json" \
  http://localhost:5001/alerts \
  -d '{"alerts": [{"labels": {"alertname": "TestAlert", "instance": "test", "status": "firing"}, "status": "firing"}]}'

# Verificar que el receptor capturó la alerta (revisar stdout del proceso webhook)
echo "Verificar la salida del proceso webhook_receiver.py"
```

---

### Paso 10: Verificación de Alertas mediante Condiciones Controladas

**Objetivo:** Disparar alertas de forma controlada para verificar que el pipeline de alertas funciona end-to-end.

#### Instrucciones

**10.1** Simular alta carga para disparar la alerta de latencia de queries:

```bash
# Generar queries pesadas para elevar la latencia
cat > /tmp/heavy_queries.sh << 'EOF'
#!/bin/bash
echo "Generando carga pesada de queries para disparar alerta de latencia..."

for i in $(seq 1 50); do
  # Query sin índice apropiado - forzará full scan
  curl -s -u Administrator:password \
    http://192.168.1.10:8093/query/service \
    -d 'statement=SELECT * FROM `travel-sample` t1 JOIN `travel-sample` t2 ON t1.type = t2.type WHERE t1.type="route" LIMIT 100' \
    -o /dev/null &
done
wait
echo "Carga de queries completada"
EOF

chmod +x /tmp/heavy_queries.sh
bash /tmp/heavy_queries.sh
```

**10.2** Verificar el estado de las alertas en Prometheus después de 3 minutos:

```bash
# Esperar a que las alertas evalúen (for: 3m en la regla)
echo "Esperando 3 minutos para evaluación de alertas..."
sleep 180

# Verificar estado de alertas
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | {alert: .labels.alertname, state: .state, instance: .labels.instance}'
```

**10.3** Simular la alerta de nodo no disponible deteniendo temporalmente el scraping de un nodo:

```bash
# Agregar una regla temporal que simula un nodo caído usando una métrica siempre verdadera
# NOTA: En producción, esto se haría deteniendo el servicio en un nodo
# Para el lab, forzar la alerta modificando temporalmente el umbral

# Verificar alertas activas en Grafana
curl -s -u admin:admin \
  "http://localhost:3000/api/alertmanager/grafana/api/v2/alerts" \
  | jq '.[] | {name: .labels.alertname, status: .status.state}'
```

**10.4** Registrar los resultados de las pruebas de alerta:

```bash
cat > /tmp/alert_test_results.txt << EOF
=== RESULTADOS DE PRUEBAS DE ALERTA ===
Timestamp: $(date)

Alertas configuradas: 8
Alertas verificadas:
  [$(curl -s http://localhost:9090/api/v1/alerts | jq '.data.alerts | length')] alertas en estado activo/pending

Estado por alerta:
$(curl -s http://localhost:9090/api/v1/alerts \
  | jq -r '.data.alerts[] | "  \(.labels.alertname): \(.state)"' 2>/dev/null || echo "  (ninguna activa)")

Webhook receptor activo: $(kill -0 $(cat /tmp/webhook.pid 2>/dev/null) 2>/dev/null && echo "SÍ" || echo "NO")
EOF

cat /tmp/alert_test_results.txt
```

#### Salida Esperada

```
=== RESULTADOS DE PRUEBAS DE ALERTA ===
Timestamp: Mon Jan 15 11:00:00 UTC 2025

Alertas configuradas: 8
Alertas verificadas:
  [1] alertas en estado activo/pending

Estado por alerta:
  CouchbaseQueryHighLatency: pending
```

#### Verificación

```bash
# Verificar que al menos una alerta se disparó durante las pruebas
FIRED=$(curl -s http://localhost:9090/api/v1/alerts \
  | jq '[.data.alerts[] | select(.state == "firing" or .state == "pending")] | length')
echo "Alertas disparadas/pendientes: $FIRED"
echo "Resultado: $([ $FIRED -gt 0 ] && echo 'PASS - Al menos una alerta activada' || echo 'REVISAR - Ninguna alerta activada')"
```

---

## 7. Validación y Pruebas

### Lista de Verificación Final

Ejecutar el siguiente script de validación integral al finalizar todos los pasos:

```bash
cat > /tmp/lab_validation.sh << 'VALIDATION_EOF'
#!/bin/bash
echo "============================================"
echo "  VALIDACIÓN FINAL - LAB 11-00-01"
echo "  $(date)"
echo "============================================"
PASS=0; FAIL=0

check() {
  local desc="$1"; local cmd="$2"; local expected="$3"
  result=$(eval "$cmd" 2>/dev/null)
  if echo "$result" | grep -q "$expected"; then
    echo "  ✅ PASS: $desc"
    ((PASS++))
  else
    echo "  ❌ FAIL: $desc (obtenido: $result)"
    ((FAIL++))
  fi
}

echo ""
echo "--- Prometheus ---"
check "Prometheus accesible" \
  "curl -s http://localhost:9090/-/ready" "Prometheus is Ready"

check "Targets Couchbase UP (al menos 1)" \
  "curl -s 'http://localhost:9090/api/v1/targets' | jq '[.data.activeTargets[] | select(.health==\"up\" and .labels.job==\"couchbase-cluster\")] | length'" \
  "[1-9]"

check "Métricas KV disponibles" \
  "curl -s 'http://localhost:9090/api/v1/query?query=kv_ops' | jq '.data.result | length'" \
  "[1-9]"

check "8 reglas de alerta cargadas" \
  "curl -s 'http://localhost:9090/api/v1/rules' | jq '[.data.groups[].rules[]] | length'" \
  "8"

echo ""
echo "--- Grafana ---"
check "Grafana accesible" \
  "curl -s -u admin:admin http://localhost:3000/api/health | jq -r .database" \
  "ok"

check "Datasource Prometheus configurado" \
  "curl -s -u admin:admin 'http://localhost:3000/api/datasources' | jq '.[0].type'" \
  "prometheus"

check "Dashboard creado" \
  "curl -s -u admin:admin 'http://localhost:3000/api/search?query=Couchbase' | jq '.[0].title'" \
  "Couchbase"

check "Contact point webhook configurado" \
  "curl -s -u admin:admin 'http://localhost:3000/api/v1/provisioning/contact-points' | jq '.[0].name'" \
  "Couchbase"

echo ""
echo "--- Couchbase Métricas ---"
check "Endpoint /metrics responde en nodo 1" \
  "curl -s -u Administrator:password http://192.168.1.10:8091/metrics | grep -c '^kv_'" \
  "[1-9]"

check "Métricas de Query disponibles" \
  "curl -s -u Administrator:password http://192.168.1.10:8091/metrics | grep -c '^n1ql_'" \
  "[1-9]"

check "Métricas de Index disponibles" \
  "curl -s -u Administrator:password http://192.168.1.10:8091/metrics | grep -c '^index_'" \
  "[1-9]"

echo ""
echo "============================================"
echo "  RESULTADO: $PASS PASS | $FAIL FAIL"
echo "============================================"
VALIDATION_EOF

chmod +x /tmp/lab_validation.sh
bash /tmp/lab_validation.sh
```

### Criterios de Aprobación

| Criterio | Mínimo Requerido |
|---|---|
| Targets Couchbase UP en Prometheus | 3/3 nodos |
| Reglas de alerta cargadas | 8/8 |
| Paneles en dashboard Grafana | ≥ 12 paneles |
| Datasource Prometheus configurado | Sí |
| Al menos 1 alerta disparada durante pruebas | Sí |
| Baseline documentado | Sí (archivo `/tmp/baseline.txt`) |

---

## 8. Resolución de Problemas

### Problema 1: Los targets de Couchbase aparecen como "DOWN" en Prometheus

**Síntomas:**
- En `http://localhost:9090/targets`, los targets del job `couchbase-cluster` muestran estado `DOWN` con error `connection refused` o `401 Unauthorized`.
- No hay datos de métricas `kv_*`, `n1ql_*` en Grafana.
- `curl -s -u Administrator:password http://192.168.1.10:8091/metrics` retorna error o respuesta vacía.

**Causa probable:**
El endpoint `/metrics` de Couchbase 7.6 requiere autenticación con un usuario que tenga el rol `Cluster Monitor` o superior. Si las credenciales en `prometheus.yml` son incorrectas, o si el puerto 8091 no es accesible desde el nodo de observabilidad (firewall, grupo de seguridad), el scraping falla. Adicionalmente, en algunas configuraciones de Couchbase Enterprise con TLS habilitado, el endpoint puede estar en el puerto `18091` en lugar de `8091`.

**Solución:**

```bash
# Paso 1: Verificar credenciales directamente
curl -v -u Administrator:password http://192.168.1.10:8091/metrics 2>&1 | head -30

# Paso 2: Si retorna 401, verificar el rol del usuario
curl -s -u Administrator:password \
  http://192.168.1.10:8091/settings/rbac/users/local/Administrator \
  | jq '.roles[] | select(.role | contains("cluster_admin") or contains("ro_admin"))'

# Paso 3: Si hay problema de firewall, verificar conectividad de red
nc -zv 192.168.1.10 8091
# Si falla, abrir el puerto:
# sudo ufw allow from 192.168.1.20 to any port 8091

# Paso 4: Si Couchbase usa TLS, actualizar prometheus.yml
# Cambiar scheme: http por scheme: https y agregar:
# tls_config:
#   insecure_skip_verify: true

# Paso 5: Recargar Prometheus y verificar
sudo systemctl reload prometheus
sleep 10
curl -s http://localhost:9090/api/v1/targets \
  | jq '.data.activeTargets[] | select(.labels.job == "couchbase-cluster") | {instance: .labels.instance, health: .health, lastError: .lastError}'
```

---

### Problema 2: Las alertas en Grafana no se disparan aunque la condición de umbral se cumple

**Síntomas:**
- Las reglas de alerta en Prometheus muestran estado `pending` pero nunca pasan a `firing`.
- O bien, las alertas están en `firing` en Prometheus pero no llegan al webhook receptor.
- El receptor de webhooks en el puerto 5001 no recibe ninguna llamada.

**Causa probable:**
Existen dos causas comunes: (1) El parámetro `for:` en la regla de alerta requiere que la condición se mantenga durante el tiempo especificado (ej. `for: 3m`); si la carga simulada es breve, la alerta queda en `pending` sin llegar a `firing`. (2) El contact point de Grafana apunta a `localhost:5001` pero Grafana corre en un contenedor Docker y `localhost` dentro del contenedor no es el host, sino el propio contenedor; el webhook no es alcanzable.

**Solución:**

```bash
# Para el problema 1 (for: demasiado largo durante el lab):
# Reducir temporalmente el valor 'for' en las reglas para testing

sudo sed -i 's/for: 3m/for: 30s/g' /etc/prometheus/rules/couchbase_alerts.yml
sudo sed -i 's/for: 5m/for: 1m/g' /etc/prometheus/rules/couchbase_alerts.yml
sudo sed -i 's/for: 2m/for: 30s/g' /etc/prometheus/rules/couchbase_alerts.yml
promtool check rules /etc/prometheus/rules/couchbase_alerts.yml
sudo systemctl reload prometheus

# Verificar que la alerta pasa a 'firing' después de 30 segundos
sleep 35
curl -s http://localhost:9090/api/v1/alerts \
  | jq '.data.alerts[] | select(.state == "firing") | .labels.alertname'

# Para el problema 2 (Docker networking):
# Usar la IP del host en lugar de localhost en el contact point
HOST_IP=$(hostname -I | awk '{print $1}')
echo "IP del host: $HOST_IP"

# Actualizar el contact point con la IP real del host
curl -s -X PUT \
  -H "Content-Type: application/json" \
  -u admin:admin \
  "http://localhost:3000/api/v1/provisioning/contact-points/$(curl -s -u admin:admin http://localhost:3000/api/v1/provisioning/contact-points | jq -r '.[0].uid')" \
  -d "{
    \"name\": \"Couchbase-Lab-Webhook\",
    \"type\": \"webhook\",
    \"settings\": {
      \"url\": \"http://${HOST_IP}:5001/alerts\",
      \"httpMethod\": \"POST\"
    }
  }" | jq .

# Probar el contact point
curl -s -X POST \
  -H "Content-Type: application/json" \
  -u admin:admin \
  "http://localhost:3000/api/v1/provisioning/contact-points/$(curl -s -u admin:admin http://localhost:3000/api/v1/provisioning/contact-points | jq -r '.[0].uid')/test" \
  | jq .
```

---

## 9. Limpieza del Entorno

Ejecutar los siguientes comandos para detener los procesos iniciados durante el lab y dejar el entorno en estado limpio:

```bash
echo "=== Limpieza del Lab 11-00-01 ==="

# Detener generadores de carga
if [ -f /tmp/pillowfight.pid ]; then
  kill $(cat /tmp/pillowfight.pid) 2>/dev/null && echo "✅ cbc-pillowfight detenido"
  rm /tmp/pillowfight.pid
fi

if [ -f /tmp/query_load.pid ]; then
  kill $(cat /tmp/query_load.pid) 2>/dev/null && echo "✅ Generador SQL++ detenido"
  rm /tmp/query_load.pid
fi

# Detener receptor de webhooks
if [ -f /tmp/webhook.pid ]; then
  kill $(cat /tmp/webhook.pid) 2>/dev/null && echo "✅ Receptor webhook detenido"
  rm /tmp/webhook.pid
fi

# Restaurar valores originales de 'for' en reglas de alerta (si se modificaron)
# NOTA: Si se modificaron para testing, restaurar los valores originales:
# sudo sed -i 's/for: 30s/for: 3m/g' /etc/prometheus/rules/couchbase_alerts.yml
# sudo systemctl reload prometheus

# Limpiar archivos temporales del lab
rm -f /tmp/dashboard_row1.json /tmp/query_load.py \
      /tmp/heavy_queries.sh /tmp/check_logs.sh \
      /tmp/webhook_receiver.py /tmp/baseline.txt \
      /tmp/alert_test_results.txt /tmp/lab_validation.sh

echo ""
echo "Recursos conservados para labs futuros:"
echo "  - Configuración de Prometheus: /etc/prometheus/prometheus.yml"
echo "  - Reglas de alerta: /etc/prometheus/rules/couchbase_alerts.yml"
echo "  - Dashboard Grafana UID: $(cat /tmp/dashboard_uid.txt 2>/dev/null || echo 'ver Grafana UI')"
echo "  - Archivo baseline: eliminado (guardar manualmente si se desea conservar)"
echo ""
echo "=== Limpieza completada ==="
```

> **Nota:** El dashboard de Grafana, la configuración de Prometheus y las reglas de alerta se conservan intencionalmente, ya que serán referenciados en labs posteriores del Capítulo 11.

---

## 10. Resumen

En esta práctica se construyó un sistema de observabilidad completo para Couchbase 7.6 aplicando el modelo de tres pilares de la Lección 11.1. Los logros clave fueron:

| Componente | Resultado |
|---|---|
| **Integración Prometheus** | 3 nodos scrapeados con métricas nativas `/metrics` de Couchbase 7.6 |
| **Dashboard Grafana** | 5 filas temáticas cubriendo Data, Query, Index, Search, Eventing, Analytics y XDCR |
| **Baselines establecidos** | Métricas de referencia capturadas con carga real de 1,000 ops/s |
| **Reglas de alerta** | 8 alertas configuradas cubriendo memoria, latencia, disponibilidad, replicación y errores |
| **Verificación end-to-end** | Pipeline de alertas validado con condiciones controladas y webhook receptor |

### Conceptos Clave Reforzados

- El endpoint `/metrics` en el puerto `8091` de Couchbase 7.6 expone métricas en formato Prometheus de forma nativa, sin necesidad de exportadores externos, organizadas por namespaces (`kv_`, `n1ql_`, `index_`, `fts_`, `eventing_`, `cbas_`, `replication_`).
- Los baselines de rendimiento son fundamentales para justificar umbrales de alerta: un umbral sin baseline es arbitrario y genera falsos positivos o falsos negativos.
- La correlación entre métricas de Grafana y logs del clúster (consultados via REST API `/logs` o directamente en `/opt/couchbase/var/lib/couchbase/logs/`) permite diagnosticar la causa raíz de las anomalías detectadas.
- El parámetro `for:` en las reglas de Prometheus es crítico: evita alertas por picos transitorios pero requiere que la condición de umbral se mantenga sostenida.

### Recursos Adicionales

- [Documentación oficial de métricas Prometheus en Couchbase 7.6](https://docs.couchbase.com/server/current/rest-api/rest-statistics.html)
- [Referencia completa de métricas por servicio](https://docs.couchbase.com/server/current/metrics-reference/metrics-reference.html)
- [Grafana Alerting — Documentación oficial](https://grafana.com/docs/grafana/latest/alerting/)
- [Prometheus Alerting Rules — Best Practices](https://prometheus.io/docs/practices/alerting/)
- [Couchbase Monitoring Guide](https://docs.couchbase.com/server/current/manage/monitor/monitoring-intro.html)

---
LAB_END---
