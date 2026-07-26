# Diseño de sizing y topología para una carga empresarial

## Metadatos

| Campo | Valor |
|---|---|
| **Duración estimada** | 78 minutos |
| **Complejidad** | Media |
| **Nivel Bloom** | Crear |
| **Versión Couchbase** | 7.6.x Enterprise Edition |
| **Modalidad** | Individual / Parejas |

---

## Descripción General

En este laboratorio aplicarás la metodología oficial de sizing de Couchbase para caracterizar y dimensionar un sistema de e-commerce empresarial con 260 millones de documentos distribuidos en tres buckets, con picos de 50,000 operaciones por segundo en temporada alta. Partiendo del perfil de carga (read-heavy, write-heavy o mixto) identificado en la Lección 7.1, calcularás los recursos de RAM, CPU, almacenamiento y red necesarios para cada servicio. Finalmente, diseñarás una topología MDS con tres escenarios documentados y un simulador en Python que modele el comportamiento del clúster bajo diferentes configuraciones.

---

## Objetivos de Aprendizaje

Al completar este laboratorio serás capaz de:

- [ ] Caracterizar y clasificar la carga de trabajo del caso de negocio en sus componentes read-heavy, write-heavy y mixtos, identificando las métricas de alerta clave para cada bucket.
- [ ] Calcular el dimensionamiento de nodos Data Service usando las fórmulas oficiales de Couchbase Sizing Guide para RAM, almacenamiento (Couchstore vs. Magma) y CPU.
- [ ] Diseñar una topología MDS con Server Groups que separe servicios según su perfil de recursos y garantice alta disponibilidad con al menos un nodo de failover.
- [ ] Implementar un simulador en Python que modele el comportamiento del clúster y compare los tres escenarios de sizing (mínimo viable, recomendado y alta disponibilidad).
- [ ] Elaborar un plan de crecimiento a 12–24 meses con headroom del 30 %, proyecciones de costos en AWS/GCP y estrategias de escalamiento horizontal y vertical.

---

## Prerrequisitos

### Conocimiento Previo

- Laboratorios 01-00-01 y 02-00-01 completados (clúster operativo con `travel-sample` cargado).
- Comprensión de métricas del Data Service: `cmd_get`, `cmd_set`, `ep_resident_items_rate`, `ep_bg_fetched`.
- Familiaridad con los conceptos de vBuckets, replicación DCP y Multidimensional Scaling (MDS).
- Python 3.10+ con capacidad de instalar paquetes mediante `pip`.

### Acceso Requerido

- Clúster Couchbase 7.6.x con mínimo 3 nodos (o 2 nodos con ajustes indicados en las notas).
- Acceso a Couchbase Web Console (`http://<nodo1>:8091`) con credenciales de administrador.
- Terminal con `curl`, `jq` y `python3` disponibles.
- Acceso a Internet para consultar la [Couchbase Sizing Guide](https://docs.couchbase.com/server/current/install/sizing-general.html) (opcional pero recomendado).

---

## Entorno de Laboratorio

### Infraestructura Requerida

| Componente | Especificación Mínima | Especificación Recomendada |
|---|---|---|
| Nodos Couchbase | 3 VMs × 8 vCPU, 16 GB RAM | 3 VMs × 16 vCPU, 32 GB RAM |
| Almacenamiento por nodo | 100 GB SSD | 200 GB SSD |
| Red inter-nodo | 1 Gbps, latencia < 5 ms | 10 Gbps, latencia < 1 ms |
| Nodo cliente | 4 vCPU, 8 GB RAM | 8 vCPU, 16 GB RAM |
| Python | 3.10+ | 3.11+ |

### Software Necesario

| Herramienta | Versión | Propósito |
|---|---|---|
| Couchbase Server EE | 7.6.x | Clúster de referencia |
| Python | 3.10+ | Simulador de sizing |
| `pip` packages | `requests`, `tabulate`, `matplotlib` | Cálculos y visualización |
| `curl` + `jq` | 7.x / 1.6+ | Consultas REST API |
| `cbq` | Incluido en CB 7.6.x | Verificación SQL++ |

### Preparación del Entorno

Ejecuta los siguientes comandos en el **nodo cliente** antes de comenzar:

```bash
# Verificar que el clúster responde
curl -s -u Administrator:password \
  http://localhost:8091/pools/default | jq '.name'

# Instalar dependencias de Python para el simulador
pip3 install requests tabulate matplotlib

# Crear directorio de trabajo para el lab
mkdir -p ~/lab07 && cd ~/lab07

# Verificar versión de Python
python3 --version
```

**Salida esperada de la verificación del clúster:**
```json
"default"
```

> **Nota:** Si tu clúster solo tiene 2 nodos, los cálculos de topología MDS seguirán siendo válidos; simplemente ajusta el número de nodos en las fórmulas y marca los pasos afectados con ⚠️.

---

## Pasos del Laboratorio

---

### Paso 1: Análisis del Caso de Negocio y Caracterización de la Carga

**Objetivo:** Clasificar el perfil de carga de cada bucket del sistema de e-commerce y construir el modelo de carga que servirá como entrada para todos los cálculos de sizing.

#### Instrucciones

**1.1 — Revisar el caso de negocio**

El sistema de e-commerce presenta la siguiente distribución de datos y operaciones:

| Bucket | Documentos | Tamaño Promedio Doc | Operaciones Pico |
|---|---|---|---|
| `product_catalog` | 50 M | 2 KB | 45,000 GET/s + 3,000 SET/s |
| `user_sessions` | 200 M | 1.5 KB | 8,000 GET/s + 12,000 SET/s |
| `orders` | 10 M | 4 KB | 500 GET/s + 2,000 SET/s |
| **Total** | **260 M** | — | **~72,500 ops/s pico** |

**1.2 — Calcular el perfil de carga de cada bucket**

Crea el archivo `~/lab07/workload_profile.py` con el siguiente contenido:

```python
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 1: Caracterización de perfiles de carga
Basado en la metodología de la Lección 7.1
"""

from tabulate import tabulate

# Definición de buckets con sus cargas operacionales
buckets = [
    {
        "name": "product_catalog",
        "docs": 50_000_000,
        "avg_doc_size_kb": 2.0,
        "peak_gets_per_sec": 45_000,
        "peak_sets_per_sec": 3_000,
    },
    {
        "name": "user_sessions",
        "docs": 200_000_000,
        "avg_doc_size_kb": 1.5,
        "peak_gets_per_sec": 8_000,
        "peak_sets_per_sec": 12_000,
    },
    {
        "name": "orders",
        "docs": 10_000_000,
        "avg_doc_size_kb": 4.0,
        "peak_gets_per_sec": 500,
        "peak_sets_per_sec": 2_000,
    },
]

def classify_workload(gets, sets):
    """Clasifica el perfil de carga según la proporción lecturas/escrituras."""
    total = gets + sets
    if total == 0:
        return "N/A", 0.0
    read_pct = (gets / total) * 100
    if read_pct > 80:
        profile = "Read-Heavy"
    elif (100 - read_pct) > 60:
        profile = "Write-Heavy"
    else:
        profile = "Mixto"
    return profile, round(read_pct, 1)

def get_alert_metrics(profile):
    """Retorna las métricas de alerta clave según el perfil."""
    alerts = {
        "Read-Heavy":  "ep_bg_fetched, ep_resident_items_rate, cmd_get latency",
        "Write-Heavy": "ep_queue_size, ep_diskqueue_drain, DCP replication lag",
        "Mixto":       "ep_bg_fetched + ep_queue_size, resident ratio, disk write queue",
    }
    return alerts.get(profile, "N/A")

def get_primary_resource_pressure(profile):
    """Retorna el recurso más presionado según el perfil."""
    pressures = {
        "Read-Heavy":  "RAM (managed cache / resident ratio)",
        "Write-Heavy": "CPU + I/O disco + Red (DCP replication)",
        "Mixto":       "RAM + CPU + I/O (balance dinámico)",
    }
    return pressures.get(profile, "N/A")

# Análisis y presentación
rows = []
for b in buckets:
    profile, read_pct = classify_workload(b["peak_gets_per_sec"], b["peak_sets_per_sec"])
    total_ops = b["peak_gets_per_sec"] + b["peak_sets_per_sec"]
    dataset_gb = (b["docs"] * b["avg_doc_size_kb"]) / (1024 * 1024)  # KB → GB
    rows.append([
        b["name"],
        f"{b['docs']:,}",
        f"{b['avg_doc_size_kb']} KB",
        f"{total_ops:,} ops/s",
        f"{read_pct}%",
        profile,
        f"{dataset_gb:.1f} GB",
        get_primary_resource_pressure(profile),
    ])

headers = [
    "Bucket", "Documentos", "Tamaño Doc",
    "Ops Pico/s", "% Lecturas", "Perfil",
    "Dataset Raw", "Recurso Presionado"
]

print("\n" + "="*100)
print("CARACTERIZACIÓN DE CARGA - SISTEMA E-COMMERCE")
print("="*100)
print(tabulate(rows, headers=headers, tablefmt="grid"))

print("\n--- MÉTRICAS DE ALERTA POR BUCKET ---")
for b in buckets:
    profile, _ = classify_workload(b["peak_gets_per_sec"], b["peak_sets_per_sec"])
    print(f"\n  [{b['name']}] Perfil: {profile}")
    print(f"    Métricas clave: {get_alert_metrics(profile)}")

print("\n--- MODELO DE CARGA CONSOLIDADO ---")
total_gets = sum(b["peak_gets_per_sec"] for b in buckets)
total_sets = sum(b["peak_sets_per_sec"] for b in buckets)
total_ops = total_gets + total_sets
total_docs = sum(b["docs"] for b in buckets)
total_dataset = sum((b["docs"] * b["avg_doc_size_kb"]) / (1024*1024) for b in buckets)
print(f"  Total documentos:       {total_docs:,}")
print(f"  Total dataset raw:      {total_dataset:.1f} GB")
print(f"  Total ops/s en pico:    {total_ops:,}")
print(f"  Proporción global:      {(total_gets/total_ops)*100:.1f}% lecturas / {(total_sets/total_ops)*100:.1f}% escrituras")
_, global_pct = classify_workload(total_gets, total_sets)
global_profile, _ = classify_workload(total_gets, total_sets)
print(f"  Perfil global:          {global_profile}")
```

**1.3 — Ejecutar el análisis**

```bash
cd ~/lab07
python3 workload_profile.py
```

#### Salida Esperada

```
====================================================================================================
CARACTERIZACIÓN DE CARGA - SISTEMA E-COMMERCE
====================================================================================================
+------------------+-------------+------------+-----------+------------+-------------+-------------+-----------------------------------+
| Bucket           | Documentos  | Tamaño Doc | Ops Pico/s | % Lecturas | Perfil      | Dataset Raw | Recurso Presionado                |
+==================+=============+============+===========+============+=============+=============+===================================+
| product_catalog  | 50,000,000  | 2.0 KB     | 48,000/s  | 93.8%      | Read-Heavy  | 95.4 GB     | RAM (managed cache/resident ratio)|
| user_sessions    | 200,000,000 | 1.5 KB     | 20,000/s  | 40.0%      | Mixto       | 286.1 GB    | RAM + CPU + I/O (balance dinámico)|
| orders           | 10,000,000  | 4.0 KB     | 2,500/s   | 20.0%      | Write-Heavy | 38.1 GB     | CPU + I/O disco + Red (DCP)       |
+------------------+-------------+------------+-----------+------------+-------------+-------------+-----------------------------------+
```

#### Verificación

```bash
# Verificar que el script produce los tres perfiles esperados
python3 workload_profile.py | grep -E "Read-Heavy|Write-Heavy|Mixto"
# Debe mostrar las tres líneas con los perfiles correctos
```

---

### Paso 2: Cálculo de Sizing del Data Service

**Objetivo:** Aplicar las fórmulas oficiales de Couchbase Sizing Guide para calcular la RAM necesaria, el almacenamiento requerido (Couchstore vs. Magma) y los nodos Data Service para cada bucket.

#### Instrucciones

**2.1 — Comprender las fórmulas de sizing**

Las fórmulas base de la Couchbase Sizing Guide son:

```
# RAM para Data Service
RAM_necesaria = (working_set_GB × overhead_factor) / resident_ratio_objetivo
overhead_factor = 3.0   # Factor estándar de Couchbase (metadata + fragmentation + OS)

# Almacenamiento con Couchstore
storage_couchstore = dataset_raw_GB × 1.5  # Compresión ~33% + overhead B-tree

# Almacenamiento con Magma (recomendado para datasets > 100 GB)
storage_magma = dataset_raw_GB × 1.2       # Mejor compresión + LSM-tree efficiency

# Factor de replicación
storage_total = storage_engine_GB × (1 + num_replicas)

# CPU para Data Service
# Regla práctica: 1 core por cada 5,000 ops/s sostenidas
cores_data = ceil(peak_ops_per_sec / 5_000)
```

**2.2 — Crear el calculador de sizing del Data Service**

```bash
cat > ~/lab07/data_service_sizing.py << 'EOF'
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 2: Sizing del Data Service
Fórmulas basadas en Couchbase Sizing Guide oficial
https://docs.couchbase.com/server/current/install/sizing-general.html
"""

import math
from tabulate import tabulate

# ─────────────────────────────────────────────
# CONSTANTES DE SIZING (Couchbase Sizing Guide)
# ─────────────────────────────────────────────
RAM_OVERHEAD_FACTOR      = 3.0   # Metadata + fragmentación + overhead del OS
COUCHSTORE_FACTOR        = 1.5   # Overhead B-tree + compresión Couchstore
MAGMA_FACTOR             = 1.2   # LSM-tree, mejor compresión (recomendado >100GB)
MAGMA_THRESHOLD_GB       = 100   # Umbral para recomendar Magma
OPS_PER_CORE_DATA        = 5_000 # ops/s por core en Data Service
NUM_REPLICAS             = 1     # Réplicas estándar (1 réplica = 2 copias total)
HEADROOM_FACTOR          = 1.30  # 30% headroom para crecimiento
MIN_DATA_NODES           = 3     # Mínimo para HA con 1 réplica
RAM_PER_NODE_GB_OPTIONS  = [16, 32, 64, 128]  # Tamaños estándar de nodo

# ─────────────────────────────────────────────
# DEFINICIÓN DE BUCKETS
# ─────────────────────────────────────────────
buckets = [
    {
        "name":             "product_catalog",
        "docs":             50_000_000,
        "avg_doc_size_kb":  2.0,
        "peak_ops_per_sec": 48_000,
        "profile":          "Read-Heavy",
        "resident_ratio":   0.95,   # 95% en memoria (read-heavy requiere alto resident ratio)
        "working_set_pct":  1.00,   # 100% del dataset es working set (catálogo activo)
    },
    {
        "name":             "user_sessions",
        "docs":             200_000_000,
        "avg_doc_size_kb":  1.5,
        "peak_ops_per_sec": 20_000,
        "profile":          "Mixto",
        "resident_ratio":   0.60,   # 60%: solo sesiones activas en memoria
        "working_set_pct":  0.30,   # 30% del dataset es working set (sesiones activas)
    },
    {
        "name":             "orders",
        "docs":             10_000_000,
        "avg_doc_size_kb":  4.0,
        "peak_ops_per_sec": 2_500,
        "profile":          "Write-Heavy",
        "resident_ratio":   0.40,   # 40%: pedidos recientes en memoria
        "working_set_pct":  0.20,   # 20% del dataset es working set (pedidos recientes)
    },
]

def calculate_dataset_gb(docs, avg_doc_size_kb):
    return (docs * avg_doc_size_kb) / (1024 * 1024)

def calculate_working_set_gb(dataset_gb, working_set_pct):
    return dataset_gb * working_set_pct

def calculate_ram_gb(working_set_gb, resident_ratio):
    """RAM = (working_set × overhead_factor) / resident_ratio"""
    return (working_set_gb * RAM_OVERHEAD_FACTOR) / resident_ratio

def choose_storage_engine(dataset_gb):
    return "Magma" if dataset_gb >= MAGMA_THRESHOLD_GB else "Couchstore"

def calculate_storage_gb(dataset_gb, engine):
    factor = MAGMA_FACTOR if engine == "Magma" else COUCHSTORE_FACTOR
    base = dataset_gb * factor
    return base * (1 + NUM_REPLICAS)  # Con réplicas

def calculate_min_nodes_for_ram(total_ram_gb, ram_per_node_gb):
    return max(MIN_DATA_NODES, math.ceil(total_ram_gb / ram_per_node_gb))

def recommend_node_ram(ram_per_node_needed_gb):
    for size in RAM_PER_NODE_GB_OPTIONS:
        if size >= ram_per_node_needed_gb:
            return size
    return RAM_PER_NODE_GB_OPTIONS[-1]

# ─────────────────────────────────────────────
# CÁLCULOS
# ─────────────────────────────────────────────
print("\n" + "="*90)
print("SIZING DEL DATA SERVICE - SISTEMA E-COMMERCE")
print("="*90)

total_ram_gb    = 0
total_storage_gb = 0
total_cores_needed = 0
sizing_rows = []

for b in buckets:
    dataset_gb      = calculate_dataset_gb(b["docs"], b["avg_doc_size_kb"])
    working_set_gb  = calculate_working_set_gb(dataset_gb, b["working_set_pct"])
    ram_gb          = calculate_ram_gb(working_set_gb, b["resident_ratio"])
    engine          = choose_storage_engine(dataset_gb)
    storage_gb      = calculate_storage_gb(dataset_gb, engine)
    cores_needed    = math.ceil(b["peak_ops_per_sec"] / OPS_PER_CORE_DATA)

    total_ram_gb     += ram_gb
    total_storage_gb += storage_gb
    total_cores_needed += cores_needed

    sizing_rows.append([
        b["name"],
        b["profile"],
        f"{dataset_gb:.1f} GB",
        f"{b['working_set_pct']*100:.0f}%",
        f"{working_set_gb:.1f} GB",
        f"{b['resident_ratio']*100:.0f}%",
        f"{ram_gb:.1f} GB",
        engine,
        f"{storage_gb:.1f} GB",
        f"{cores_needed}",
    ])

headers = [
    "Bucket", "Perfil", "Dataset Raw", "Working Set%",
    "Working Set", "Resident Ratio", "RAM Requerida",
    "Engine", "Storage (c/réplica)", "Cores Mín"
]
print(tabulate(sizing_rows, headers=headers, tablefmt="grid"))

# ─────────────────────────────────────────────
# TOTALES Y RECOMENDACIÓN DE NODOS
# ─────────────────────────────────────────────
total_ram_with_headroom    = total_ram_gb * HEADROOM_FACTOR
total_storage_with_headroom = total_storage_gb * HEADROOM_FACTOR

print(f"\n{'─'*60}")
print("TOTALES CONSOLIDADOS (Data Service)")
print(f"{'─'*60}")
print(f"  RAM total requerida:           {total_ram_gb:.1f} GB")
print(f"  RAM con headroom (30%):        {total_ram_with_headroom:.1f} GB")
print(f"  Storage total (c/réplica):     {total_storage_gb:.1f} GB")
print(f"  Storage con headroom (30%):    {total_storage_with_headroom:.1f} GB")
print(f"  Cores mínimos totales:         {total_cores_needed}")

print(f"\n{'─'*60}")
print("CONFIGURACIONES DE NODO RECOMENDADAS")
print(f"{'─'*60}")

configs = [
    ("Nodo 32 GB RAM",  32),
    ("Nodo 64 GB RAM",  64),
    ("Nodo 128 GB RAM", 128),
]
node_rows = []
for label, ram_per_node in configs:
    n_nodes = calculate_min_nodes_for_ram(total_ram_with_headroom, ram_per_node)
    ram_per_node_rec = recommend_node_ram(total_ram_with_headroom / n_nodes)
    storage_per_node = math.ceil(total_storage_with_headroom / n_nodes)
    node_rows.append([
        label,
        n_nodes,
        f"{ram_per_node} GB",
        f"{storage_per_node} GB SSD",
        f"{math.ceil(total_cores_needed / n_nodes)} vCPU",
        "Recomendado" if n_nodes <= 6 else "Muchos nodos"
    ])

print(tabulate(node_rows,
    headers=["Configuración", "Nodos Data", "RAM/Nodo", "Storage/Nodo", "CPU/Nodo", "Nota"],
    tablefmt="grid"))
EOF
python3 ~/lab07/data_service_sizing.py
```

#### Salida Esperada (valores aproximados)

```
==========================================================================================
SIZING DEL DATA SERVICE - SISTEMA E-COMMERCE
==========================================================================================
+------------------+-------------+-------------+--------------+-------------+----------------+---------------+----------+---------------------+-----------+
| Bucket           | Perfil      | Dataset Raw | Working Set% | Working Set | Resident Ratio | RAM Requerida | Engine   | Storage (c/réplica) | Cores Mín |
+==================+=============+=============+==============+=============+================+===============+==========+=====================+===========+
| product_catalog  | Read-Heavy  | 95.4 GB     | 100%         | 95.4 GB     | 95%            | 301.3 GB      | Couchstore| 286.2 GB           | 10        |
| user_sessions    | Mixto       | 286.1 GB    | 30%          | 85.8 GB     | 60%            | 429.2 GB      | Magma    | 686.7 GB            | 4         |
| orders           | Write-Heavy | 38.1 GB     | 20%          | 7.6 GB      | 40%            | 57.2 GB       | Couchstore| 114.3 GB           | 1         |
+------------------+-------------+-------------+--------------+-------------+----------------+---------------+----------+---------------------+-----------+

────────────────────────────────────────────────────────────
TOTALES CONSOLIDADOS (Data Service)
────────────────────────────────────────────────────────────
  RAM total requerida:           787.7 GB
  RAM con headroom (30%):        1024.0 GB
  Storage total (c/réplica):     1087.2 GB
  Storage con headroom (30%):    1413.4 GB
  Cores mínimos totales:         15
```

#### Verificación

```bash
# Confirmar que el script termina sin errores y produce los tres engines
python3 ~/lab07/data_service_sizing.py | grep -E "Magma|Couchstore"
# Debe mostrar al menos una línea con "Magma" (user_sessions > 100 GB)
```

> **Punto de reflexión:** ¿Por qué `user_sessions` usa Magma mientras `product_catalog` usa Couchstore? Revisa el umbral `MAGMA_THRESHOLD_GB = 100` y el tamaño del dataset raw de cada bucket.

---

### Paso 3: Sizing de Query, Index, Search y Analytics Service

**Objetivo:** Calcular los recursos de CPU y RAM para los servicios no-Data usando las reglas de sizing de Couchbase para cada tipo de carga.

#### Instrucciones

**3.1 — Crear el calculador de servicios adicionales**

```bash
cat > ~/lab07/services_sizing.py << 'EOF'
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 3: Sizing de Query, Index, Search y Analytics Service
"""

import math
from tabulate import tabulate

# ─────────────────────────────────────────────
# CARGA DE TRABAJO POR SERVICIO
# ─────────────────────────────────────────────
# Query Service: estimado en 2,000 queries SQL++ / segundo en pico
# Index Service: 260M documentos, actualizaciones promedio 17,000 mutations/s
# Search Service: 100 búsquedas full-text / segundo
# Analytics Service: 20 queries analíticas concurrentes (batch)

QUERY_SERVICE = {
    "peak_queries_per_sec":   2_000,
    "avg_query_complexity":   "medium",  # simple=1, medium=2, complex=4 CPU-units
    "complexity_factor":      2,
    "cores_per_100qps":       2,         # Regla: 2 cores por cada 100 QPS medium
    "ram_gb_per_node":        16,        # RAM mínima recomendada por nodo Query
    "min_nodes":              2,         # HA: mínimo 2 nodos Query
}

INDEX_SERVICE = {
    "total_docs":             260_000_000,
    "mutation_rate_per_sec":  17_000,    # Suma de SETs de todos los buckets
    "indexes_count":          15,        # Estimado: 5 índices por bucket
    "ram_per_index_gb":       2,         # Estimado conservador
    "cores_per_index_node":   8,         # Recomendado para indexación activa
    "min_nodes":              2,         # HA con index partitioning
}

SEARCH_SERVICE = {
    "peak_fts_queries_per_sec": 100,
    "index_size_gb":            50,      # Estimado para índices FTS de product_catalog
    "ram_per_node_gb":          16,
    "cores_per_node":           8,
    "min_nodes":                2,
}

ANALYTICS_SERVICE = {
    "concurrent_queries":       20,
    "ram_per_query_gb":         4,       # RAM por query analítica compleja
    "min_ram_gb":               64,      # Mínimo recomendado para Analytics
    "cores_per_node":           16,
    "min_nodes":                1,       # Puede ser 1 nodo dedicado
}

# ─────────────────────────────────────────────
# CÁLCULOS
# ─────────────────────────────────────────────

# Query Service
query_cores_needed = math.ceil(
    (QUERY_SERVICE["peak_queries_per_sec"] / 100) *
    QUERY_SERVICE["cores_per_100qps"] *
    QUERY_SERVICE["complexity_factor"]
)
query_nodes = max(
    QUERY_SERVICE["min_nodes"],
    math.ceil(query_cores_needed / 16)  # Asumiendo nodos de 16 cores
)

# Index Service
index_ram_total = INDEX_SERVICE["indexes_count"] * INDEX_SERVICE["ram_per_index_gb"]
index_nodes = max(
    INDEX_SERVICE["min_nodes"],
    math.ceil(index_ram_total / 32)     # Nodos de 32 GB RAM
)

# Search Service
search_ram_total = SEARCH_SERVICE["index_size_gb"] * 1.5  # Factor de overhead FTS
search_nodes = max(
    SEARCH_SERVICE["min_nodes"],
    math.ceil(search_ram_total / SEARCH_SERVICE["ram_per_node_gb"])
)

# Analytics Service
analytics_ram = max(
    ANALYTICS_SERVICE["min_ram_gb"],
    ANALYTICS_SERVICE["concurrent_queries"] * ANALYTICS_SERVICE["ram_per_query_gb"]
)

# ─────────────────────────────────────────────
# PRESENTACIÓN
# ─────────────────────────────────────────────
print("\n" + "="*90)
print("SIZING DE SERVICIOS ADICIONALES - SISTEMA E-COMMERCE")
print("="*90)

services_rows = [
    [
        "Query Service",
        f"{QUERY_SERVICE['peak_queries_per_sec']:,} QPS",
        f"{query_cores_needed} cores totales",
        f"{QUERY_SERVICE['ram_gb_per_node']} GB/nodo",
        f"{query_nodes} nodos",
        f"{query_nodes * 16} vCPU + {query_nodes * QUERY_SERVICE['ram_gb_per_node']} GB RAM",
        "Separar de Data para evitar contención CPU"
    ],
    [
        "Index Service",
        f"{INDEX_SERVICE['mutation_rate_per_sec']:,} mutations/s",
        f"{INDEX_SERVICE['cores_per_index_node']} cores/nodo",
        f"{math.ceil(index_ram_total / index_nodes)} GB/nodo",
        f"{index_nodes} nodos",
        f"{index_nodes * INDEX_SERVICE['cores_per_index_node']} vCPU + {index_ram_total} GB RAM",
        "Usar index partitioning para HA"
    ],
    [
        "Search (FTS)",
        f"{SEARCH_SERVICE['peak_fts_queries_per_sec']} FTS QPS",
        f"{SEARCH_SERVICE['cores_per_node']} cores/nodo",
        f"{SEARCH_SERVICE['ram_per_node_gb']} GB/nodo",
        f"{search_nodes} nodos",
        f"{search_nodes * SEARCH_SERVICE['cores_per_node']} vCPU + {search_nodes * SEARCH_SERVICE['ram_per_node_gb']} GB RAM",
        "FTS index en SSD rápido"
    ],
    [
        "Analytics",
        f"{ANALYTICS_SERVICE['concurrent_queries']} queries concurrentes",
        f"{ANALYTICS_SERVICE['cores_per_node']} cores/nodo",
        f"{analytics_ram} GB/nodo",
        f"{ANALYTICS_SERVICE['min_nodes']} nodo",
        f"{ANALYTICS_SERVICE['cores_per_node']} vCPU + {analytics_ram} GB RAM",
        "Nodo dedicado; aislado de OLTP"
    ],
]

headers = ["Servicio", "Carga Pico", "CPU", "RAM", "Nodos", "Total Recursos", "Nota MDS"]
print(tabulate(services_rows, headers=headers, tablefmt="grid"))

print("\n  NOTA: Estos cálculos asumen separación MDS completa.")
print("  En topología colapsada, los recursos se suman pero la contención aumenta.")
EOF
python3 ~/lab07/services_sizing.py
```

#### Verificación

```bash
python3 ~/lab07/services_sizing.py | grep -c "nodos\|nodo"
# Debe retornar 4 (una línea por servicio con "nodos" o "nodo")
```

---

### Paso 4: Diseño de la Topología MDS con Server Groups

**Objetivo:** Diseñar una topología Multidimensional Scaling que separe servicios por perfil de recursos, configure Server Groups para HA y documente los tres escenarios de deployment.

#### Instrucciones

**4.1 — Crear el diseñador de topología MDS**

```bash
cat > ~/lab07/mds_topology.py << 'EOF'
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 4: Diseño de topología MDS con Server Groups
Multidimensional Scaling (MDS) - Couchbase 7.6.x
"""

from tabulate import tabulate

# ─────────────────────────────────────────────
# DEFINICIÓN DE ESCENARIOS
# ─────────────────────────────────────────────

scenarios = {
    "minimum_viable": {
        "label": "Escenario 1: Mínimo Viable (MVP)",
        "description": "Costo mínimo, servicios parcialmente colapsados. Sin HA completa.",
        "node_groups": [
            {
                "group_name":  "Group-Data",
                "server_group": "AZ-1 / AZ-2 (alternado)",
                "node_count":  3,
                "services":    ["data"],
                "vcpu":        16,
                "ram_gb":      64,
                "storage_gb":  500,
                "storage_type":"SSD NVMe",
                "notes":       "3 nodos mínimo para 1 réplica + failover"
            },
            {
                "group_name":  "Group-Query-Index",
                "server_group": "AZ-1 / AZ-2 (alternado)",
                "node_count":  2,
                "services":    ["query", "index"],
                "vcpu":        16,
                "ram_gb":      32,
                "storage_gb":  200,
                "storage_type":"SSD",
                "notes":       "Query e Index colapsados (ahorro de nodos)"
            },
        ],
        "aws_instance":  "r6i.4xlarge (16vCPU/128GB)",
        "monthly_cost_usd": 4_200,
    },
    "recommended": {
        "label": "Escenario 2: Recomendado (Producción)",
        "description": "Servicios separados por MDS. HA completa. Balance costo/rendimiento.",
        "node_groups": [
            {
                "group_name":  "Group-Data",
                "server_group": "AZ-1, AZ-2, AZ-3 (1 nodo/AZ)",
                "node_count":  6,
                "services":    ["data"],
                "vcpu":        16,
                "ram_gb":      128,
                "storage_gb":  500,
                "storage_type":"SSD NVMe",
                "notes":       "6 nodos: 3 activos + 3 réplica en AZs distintas"
            },
            {
                "group_name":  "Group-Query",
                "server_group": "AZ-1, AZ-2",
                "node_count":  2,
                "services":    ["query"],
                "vcpu":        32,
                "ram_gb":      32,
                "storage_gb":  100,
                "storage_type":"SSD",
                "notes":       "CPU-intensivo; separado de Data"
            },
            {
                "group_name":  "Group-Index",
                "server_group": "AZ-1, AZ-2",
                "node_count":  2,
                "services":    ["index"],
                "vcpu":        16,
                "ram_gb":      64,
                "storage_gb":  300,
                "storage_type":"SSD NVMe",
                "notes":       "Index partitioning entre 2 nodos"
            },
            {
                "group_name":  "Group-Search-Analytics",
                "server_group": "AZ-3",
                "node_count":  2,
                "services":    ["fts", "analytics"],
                "vcpu":        16,
                "ram_gb":      64,
                "storage_gb":  200,
                "storage_type":"SSD",
                "notes":       "FTS + Analytics colapsados (carga no concurrente)"
            },
        ],
        "aws_instance":  "Mixto: r6i.4xlarge (Data) + c6i.8xlarge (Query)",
        "monthly_cost_usd": 12_500,
    },
    "high_availability": {
        "label": "Escenario 3: Alta Disponibilidad (Enterprise)",
        "description": "Máxima resiliencia. Todos los servicios redundantes en 3 AZs. Failover automático.",
        "node_groups": [
            {
                "group_name":  "Group-Data-AZ1",
                "server_group": "AZ-1",
                "node_count":  4,
                "services":    ["data"],
                "vcpu":        32,
                "ram_gb":      256,
                "storage_gb":  1000,
                "storage_type":"NVMe SSD",
                "notes":       "4 nodos/AZ × 3 AZs = 12 nodos Data totales"
            },
            {
                "group_name":  "Group-Query (×3 AZs)",
                "server_group": "AZ-1, AZ-2, AZ-3",
                "node_count":  3,
                "services":    ["query"],
                "vcpu":        32,
                "ram_gb":      32,
                "storage_gb":  100,
                "storage_type":"SSD",
                "notes":       "1 nodo Query por AZ; load balancer delante"
            },
            {
                "group_name":  "Group-Index (×3 AZs)",
                "server_group": "AZ-1, AZ-2, AZ-3",
                "node_count":  3,
                "services":    ["index"],
                "vcpu":        16,
                "ram_gb":      128,
                "storage_gb":  500,
                "storage_type":"NVMe SSD",
                "notes":       "Index partitioning + réplica entre AZs"
            },
            {
                "group_name":  "Group-Search (×2 AZs)",
                "server_group": "AZ-1, AZ-2",
                "node_count":  2,
                "services":    ["fts"],
                "vcpu":        16,
                "ram_gb":      64,
                "storage_gb":  200,
                "storage_type":"SSD",
                "notes":       "FTS con réplica de índice"
            },
            {
                "group_name":  "Group-Analytics",
                "server_group": "AZ-3",
                "node_count":  2,
                "services":    ["analytics"],
                "vcpu":        32,
                "ram_gb":      128,
                "storage_gb":  500,
                "storage_type":"SSD",
                "notes":       "Analytics aislado; no impacta OLTP"
            },
        ],
        "aws_instance":  "r6i.8xlarge (Data) + c6i.8xlarge (Query/Index)",
        "monthly_cost_usd": 38_000,
    },
}

# ─────────────────────────────────────────────
# PRESENTACIÓN
# ─────────────────────────────────────────────
for scenario_key, scenario in scenarios.items():
    print("\n" + "="*100)
    print(f"  {scenario['label']}")
    print(f"  {scenario['description']}")
    print("="*100)

    rows = []
    total_nodes = 0
    total_vcpu  = 0
    total_ram   = 0
    for g in scenario["node_groups"]:
        n = g["node_count"]
        total_nodes += n
        total_vcpu  += n * g["vcpu"]
        total_ram   += n * g["ram_gb"]
        rows.append([
            g["group_name"],
            g["server_group"],
            n,
            ", ".join(g["services"]),
            f"{g['vcpu']} vCPU",
            f"{g['ram_gb']} GB",
            f"{g['storage_gb']} GB {g['storage_type']}",
            g["notes"],
        ])

    headers = ["Grupo", "Server Group / AZ", "Nodos", "Servicios",
               "CPU/Nodo", "RAM/Nodo", "Storage/Nodo", "Notas"]
    print(tabulate(rows, headers=headers, tablefmt="grid"))
    print(f"\n  Totales: {total_nodes} nodos | {total_vcpu} vCPU | {total_ram} GB RAM")
    print(f"  Instancia AWS referencia: {scenario['aws_instance']}")
    print(f"  Costo mensual estimado AWS: USD ${scenario['monthly_cost_usd']:,}")

# Tabla comparativa final
print("\n" + "="*80)
print("COMPARATIVA DE ESCENARIOS")
print("="*80)
comp_rows = []
for key, s in scenarios.items():
    total_n = sum(g["node_count"] for g in s["node_groups"])
    total_v = sum(g["node_count"] * g["vcpu"] for g in s["node_groups"])
    total_r = sum(g["node_count"] * g["ram_gb"] for g in s["node_groups"])
    comp_rows.append([
        s["label"].split(":")[1].strip(),
        total_n,
        f"{total_v} vCPU",
        f"{total_r} GB",
        f"USD ${s['monthly_cost_usd']:,}",
        f"USD ${s['monthly_cost_usd']*12:,}",
    ])
print(tabulate(comp_rows,
    headers=["Escenario", "Total Nodos", "Total vCPU", "Total RAM",
             "Costo/Mes", "Costo/Año"],
    tablefmt="grid"))
EOF
python3 ~/lab07/mds_topology.py
```

**4.2 — Verificar la configuración de Server Groups en el clúster real**

```bash
# Consultar Server Groups actuales del clúster de laboratorio
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/serverGroups \
  | jq '[.groups[] | {name: .name, nodes: [.nodes[].hostname]}]'
```

**Salida esperada:**
```json
[
  {
    "name": "Group 1",
    "nodes": ["node1:8091", "node2:8091", "node3:8091"]
  }
]
```

**4.3 — Crear Server Groups para simular la topología MDS en el laboratorio**

```bash
# Crear Server Group para simular separación MDS (en clúster de lab)
curl -s -u Administrator:password \
  -X POST http://localhost:8091/pools/default/serverGroups \
  -d 'name=Group-Data-AZ1'

curl -s -u Administrator:password \
  -X POST http://localhost:8091/pools/default/serverGroups \
  -d 'name=Group-Services-AZ2'

# Verificar grupos creados
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/serverGroups \
  | jq '[.groups[].name]'
```

**Salida esperada:**
```json
["Group 1", "Group-Data-AZ1", "Group-Services-AZ2"]
```

#### Verificación

```bash
# Contar cuántos Server Groups existen (debe ser >= 3)
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/serverGroups \
  | jq '.groups | length'
```

---

### Paso 5: Simulador de Comportamiento del Clúster

**Objetivo:** Implementar un simulador Python que modele el comportamiento del clúster bajo diferentes configuraciones y compare los tres escenarios de sizing, proyectando el crecimiento a 24 meses.

#### Instrucciones

**5.1 — Crear el simulador**

```bash
cat > ~/lab07/cluster_simulator.py << 'EOF'
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 5: Simulador de comportamiento del clúster
Modela resident ratio, latencia estimada y riesgo de saturación
bajo diferentes configuraciones de sizing.
"""

import math
from tabulate import tabulate

# ─────────────────────────────────────────────
# PARÁMETROS DEL SIMULADOR
# ─────────────────────────────────────────────
DISK_LATENCY_MS    = 8.0    # Latencia promedio de disco SSD en ms
CACHE_LATENCY_MS   = 0.5    # Latencia de cache hit en ms
REPLICATION_OVERHEAD_PCT = 0.15  # 15% overhead de red por replicación DCP

# Crecimiento de datos: 8% mensual (e-commerce en expansión)
MONTHLY_GROWTH_RATE = 0.08

def estimate_get_latency_ms(resident_ratio):
    """
    Estima la latencia promedio de GET considerando cache hits y misses.
    P(cache hit) = resident_ratio
    P(cache miss) = 1 - resident_ratio → acceso a disco
    """
    return (resident_ratio * CACHE_LATENCY_MS +
            (1 - resident_ratio) * DISK_LATENCY_MS)

def estimate_resident_ratio(ram_available_gb, working_set_gb):
    """Calcula el resident ratio real dado el RAM disponible."""
    effective_ram = ram_available_gb / 3.0  # Descontar overhead factor
    return min(1.0, effective_ram / working_set_gb)

def saturation_risk(resident_ratio, ops_per_sec, cores_available):
    """
    Calcula un índice de riesgo de saturación (0-100).
    Considera resident ratio bajo y sobrecarga de CPU.
    """
    # Riesgo por resident ratio bajo
    ram_risk = max(0, (0.60 - resident_ratio) / 0.60 * 50)
    # Riesgo por CPU (>80% utilización = riesgo)
    cpu_util = min(1.0, ops_per_sec / (cores_available * 5000))
    cpu_risk = max(0, (cpu_util - 0.80) / 0.20 * 50)
    return min(100, ram_risk + cpu_risk)

def risk_label(risk_score):
    if risk_score < 20:  return "BAJO    ✓"
    if risk_score < 50:  return "MEDIO   ⚠"
    return                      "ALTO    ✗"

# ─────────────────────────────────────────────
# CONFIGURACIONES A SIMULAR
# ─────────────────────────────────────────────
configs = [
    {
        "name":            "MVP (3 nodos × 64 GB)",
        "data_nodes":      3,
        "ram_per_node_gb": 64,
        "cores_per_node":  16,
        "scenario":        "minimum_viable",
    },
    {
        "name":            "Recomendado (6 nodos × 128 GB)",
        "data_nodes":      6,
        "ram_per_node_gb": 128,
        "cores_per_node":  16,
        "scenario":        "recommended",
    },
    {
        "name":            "HA Enterprise (12 nodos × 256 GB)",
        "data_nodes":      12,
        "ram_per_node_gb": 256,
        "cores_per_node":  32,
        "scenario":        "high_availability",
    },
]

# Working sets por bucket (calculados en Paso 2)
workloads = [
    {"bucket": "product_catalog", "working_set_gb": 95.4,  "peak_ops": 48_000},
    {"bucket": "user_sessions",   "working_set_gb": 85.8,  "peak_ops": 20_000},
    {"bucket": "orders",          "working_set_gb":  7.6,  "peak_ops":  2_500},
]
total_working_set_gb = sum(w["working_set_gb"] for w in workloads)
total_peak_ops       = sum(w["peak_ops"] for w in workloads)

# ─────────────────────────────────────────────
# SIMULACIÓN PUNTO ACTUAL
# ─────────────────────────────────────────────
print("\n" + "="*90)
print("SIMULACIÓN DE COMPORTAMIENTO - ESTADO ACTUAL (DÍA 0)")
print("="*90)

sim_rows = []
for cfg in configs:
    total_ram   = cfg["data_nodes"] * cfg["ram_per_node_gb"]
    total_cores = cfg["data_nodes"] * cfg["cores_per_node"]
    res_ratio   = estimate_resident_ratio(total_ram, total_working_set_gb)
    avg_latency = estimate_get_latency_ms(res_ratio)
    risk        = saturation_risk(res_ratio, total_peak_ops, total_cores)

    sim_rows.append([
        cfg["name"],
        f"{total_ram:,} GB",
        f"{total_cores} cores",
        f"{res_ratio*100:.1f}%",
        f"{avg_latency:.2f} ms",
        f"{risk:.0f}/100",
        risk_label(risk),
    ])

headers = ["Configuración", "RAM Total", "CPU Total",
           "Resident Ratio", "Latencia GET est.", "Riesgo", "Estado"]
print(tabulate(sim_rows, headers=headers, tablefmt="grid"))

# ─────────────────────────────────────────────
# PROYECCIÓN DE CRECIMIENTO 24 MESES
# ─────────────────────────────────────────────
print("\n" + "="*90)
print(f"PROYECCIÓN DE CRECIMIENTO ({MONTHLY_GROWTH_RATE*100:.0f}% MENSUAL) - 24 MESES")
print("="*90)

growth_rows = []
for month in [0, 3, 6, 12, 18, 24]:
    growth_factor = (1 + MONTHLY_GROWTH_RATE) ** month
    projected_ws  = total_working_set_gb * growth_factor
    projected_ops = total_peak_ops * growth_factor

    row = [f"Mes {month:2d}", f"{projected_ws:.0f} GB", f"{projected_ops:,.0f} ops/s"]
    for cfg in configs:
        total_ram   = cfg["data_nodes"] * cfg["ram_per_node_gb"]
        total_cores = cfg["data_nodes"] * cfg["cores_per_node"]
        res_ratio   = estimate_resident_ratio(total_ram, projected_ws)
        risk        = saturation_risk(res_ratio, projected_ops, total_cores)
        row.append(f"{res_ratio*100:.0f}% | {risk_label(risk)}")

    growth_rows.append(row)

growth_headers = ["Mes", "Working Set", "Ops/s"] + [c["name"].split("(")[0].strip() for c in configs]
print(tabulate(growth_rows, headers=growth_headers, tablefmt="grid"))

print("\n  INTERPRETACIÓN:")
print("  - Resident Ratio < 60%: riesgo alto de latencia por cache misses")
print("  - Riesgo ALTO: requiere escalamiento antes de ese mes")
print("  - Planificar escalamiento cuando Riesgo llegue a MEDIO (mes de anticipación)")
EOF
python3 ~/lab07/cluster_simulator.py
```

#### Salida Esperada (extracto)

```
==========================================================================================
SIMULACIÓN DE COMPORTAMIENTO - ESTADO ACTUAL (DÍA 0)
==========================================================================================
+-------------------------------+-----------+-----------+----------------+-------------------+--------+-----------+
| Configuración                 | RAM Total | CPU Total | Resident Ratio | Latencia GET est. | Riesgo | Estado    |
+===============================+===========+===========+================+===================+========+===========+
| MVP (3 nodos × 64 GB)         | 192 GB    | 48 cores  | 21.1%          | 6.40 ms           | 65/100 | ALTO    ✗ |
| Recomendado (6 nodos × 128 GB)| 768 GB    | 96 cores  | 84.6%          | 1.64 ms           | 12/100 | BAJO    ✓ |
| HA Enterprise (12 nodos ×256) | 3072 GB   | 384 cores | 100.0%         | 0.50 ms           | 0/100  | BAJO    ✓ |
+-------------------------------+-----------+-----------+----------------+-------------------+--------+-----------+
```

#### Verificación

```bash
# El simulador debe mostrar que MVP tiene riesgo ALTO y Recomendado tiene riesgo BAJO
python3 ~/lab07/cluster_simulator.py | grep -E "ALTO|BAJO"
# Debe aparecer al menos una línea con ALTO (MVP) y al menos una con BAJO (Recomendado/HA)
```

---

### Paso 6: Consulta de Métricas Reales del Clúster de Laboratorio

**Objetivo:** Usar la REST API de Couchbase para obtener métricas reales del clúster de laboratorio y compararlas con los valores teóricos calculados.

#### Instrucciones

**6.1 — Consultar métricas del bucket `travel-sample`**

```bash
# Obtener métricas clave del bucket travel-sample
BUCKET="travel-sample"
CB_HOST="localhost:8091"
CB_USER="Administrator"
CB_PASS="password"

curl -s -u ${CB_USER}:${CB_PASS} \
  "http://${CB_HOST}/pools/default/buckets/${BUCKET}/stats" \
  | jq '{
      cmd_get:               .op.samples.cmd_get[-1],
      cmd_set:               .op.samples.cmd_set[-1],
      ep_bg_fetched:         .op.samples.ep_bg_fetched[-1],
      ep_resident_items_rate:.op.samples.ep_resident_items_rate[-1],
      ep_queue_size:         .op.samples.ep_queue_size[-1],
      mem_used:              .op.samples.mem_used[-1],
      curr_items:            .op.samples.curr_items[-1]
    }'
```

**Salida esperada (valores de ejemplo del clúster de lab):**
```json
{
  "cmd_get": 0,
  "cmd_set": 0,
  "ep_bg_fetched": 0,
  "ep_resident_items_rate": 100,
  "ep_queue_size": 0,
  "mem_used": 52428800,
  "curr_items": 63288
}
```

**6.2 — Calcular el perfil de carga real del clúster de laboratorio**

```bash
cat > ~/lab07/measure_real_cluster.py << 'EOF'
#!/usr/bin/env python3
"""
Lab 07-00-01 - Paso 6: Medición del clúster real
Compara métricas reales con los umbrales teóricos de la Lección 7.1
"""

import requests
import json
from requests.auth import HTTPBasicAuth

CB_HOST = "localhost:8091"
CB_USER = "Administrator"
CB_PASS = "password"
BUCKET  = "travel-sample"

def get_bucket_stats(host, user, password, bucket):
    url  = f"http://{host}/pools/default/buckets/{bucket}/stats"
    resp = requests.get(url, auth=HTTPBasicAuth(user, password), timeout=10)
    resp.raise_for_status()
    return resp.json()

def get_last_sample(stats, metric):
    try:
        samples = stats["op"]["samples"].get(metric, [0])
        return samples[-1] if samples else 0
    except (KeyError, IndexError):
        return 0

try:
    stats = get_bucket_stats(CB_HOST, CB_USER, CB_PASS, BUCKET)

    cmd_get      = get_last_sample(stats, "cmd_get")
    cmd_set      = get_last_sample(stats, "cmd_set")
    bg_fetched   = get_last_sample(stats, "ep_bg_fetched")
    resident     = get_last_sample(stats, "ep_resident_items_rate")
    queue_size   = get_last_sample(stats, "ep_queue_size")
    mem_used_mb  = get_last_sample(stats, "mem_used") / (1024*1024)
    curr_items   = get_last_sample(stats, "curr_items")

    total_ops = cmd_get + cmd_set
    read_pct  = (cmd_get / total_ops * 100) if total_ops > 0 else 0

    print(f"\n{'='*60}")
    print(f"MÉTRICAS REALES - Bucket: {BUCKET}")
    print(f"{'='*60}")
    print(f"  cmd_get (lecturas/s):      {cmd_get:,.0f}")
    print(f"  cmd_set (escrituras/s):    {cmd_set:,.0f}")
    print(f"  % lecturas:                {read_pct:.1f}%")
    print(f"  ep_bg_fetched (misses/s):  {bg_fetched:,.0f}")
    print(f"  ep_resident_items_rate:    {resident:.1f}%")
    print(f"  ep_queue_size:             {queue_size:,.0f}")
    print(f"  Memoria usada:             {mem_used_mb:.1f} MB")
    print(f"  Documentos actuales:       {curr_items:,}")

    print(f"\n{'─'*60}")
    print("DIAGNÓSTICO SEGÚN LECCIÓN 7.1")
    print(f"{'─'*60}")

    # Clasificar perfil
    if total_ops == 0:
        print("  ⚠ Sin tráfico activo. Ejecuta cbc-pillowfight para generar carga.")
    elif read_pct > 80:
        print(f"  Perfil: READ-HEAVY ({read_pct:.1f}% lecturas)")
        print("  Riesgo principal: cache misses (ep_bg_fetched)")
    elif (100 - read_pct) > 60:
        print(f"  Perfil: WRITE-HEAVY ({100-read_pct:.1f}% escrituras)")
        print("  Riesgo principal: disk write queue (ep_queue_size)")
    else:
        print(f"  Perfil: MIXTO ({read_pct:.1f}% lecturas)")

    # Alertas
    if resident < 60:
        print(f"  ⚠ ALERTA: Resident ratio bajo ({resident:.1f}%) → riesgo de cache misses")
    else:
        print(f"  ✓ Resident ratio saludable ({resident:.1f}%)")

    if bg_fetched > 100:
        print(f"  ⚠ ALERTA: ep_bg_fetched={bg_fetched:.0f} → accesos a disco elevados")
    else:
        print(f"  ✓ ep_bg_fetched={bg_fetched:.0f} → dentro del rango normal")

    if queue_size > 10_000:
        print(f"  ⚠ ALERTA: ep_queue_size={queue_size:.0f} → cola de escritura creciendo")
    else:
        print(f"  ✓ ep_queue_size={queue_size:.0f} → cola de escritura normal")

except Exception as e:
    print(f"  ERROR al conectar con el clúster: {e}")
    print("  Verifica que Couchbase esté corriendo y travel-sample esté cargado.")
EOF
python3 ~/lab07/measure_real_cluster.py
```

**6.3 — Generar carga real para observar métricas dinámicas**

```bash
# Generar carga de lectura/escritura mixta en travel-sample
cbc-pillowfight \
  --spec couchbase://localhost/travel-sample \
  --username Administrator \
  --password password \
  --num-items 10000 \
  --num-threads 4 \
  --set-pct 30 \
  --num-cycles 5 \
  --min-size 512 \
  --max-size 2048 &

PILLOWFIGHT_PID=$!
sleep 15

# Medir métricas con carga activa
python3 ~/lab07/measure_real_cluster.py

# Detener la carga
kill $PILLOWFIGHT_PID 2>/dev/null
```

#### Verificación

```bash
# Verificar que el script de métricas se ejecuta sin errores
python3 ~/lab07/measure_real_cluster.py
# Debe mostrar las métricas sin errores de conexión
```

---

## Validación y Pruebas

Ejecuta la siguiente secuencia de validación para confirmar que todos los entregables del laboratorio están completos:

```bash
#!/bin/bash
# Script de validación completa - Lab 07-00-01
echo "========================================"
echo "VALIDACIÓN LAB 07-00-01"
echo "========================================"

PASS=0
FAIL=0

check() {
    local desc="$1"
    local cmd="$2"
    local expected="$3"
    result=$(eval "$cmd" 2>/dev/null)
    if echo "$result" | grep -q "$expected"; then
        echo "  ✓ PASS: $desc"
        ((PASS++))
    else
        echo "  ✗ FAIL: $desc (esperado: '$expected', obtenido: '$result')"
        ((FAIL++))
    fi
}

# Validar archivos creados
check "workload_profile.py existe" \
    "ls ~/lab07/workload_profile.py" "workload_profile.py"

check "data_service_sizing.py existe" \
    "ls ~/lab07/data_service_sizing.py" "data_service_sizing.py"

check "mds_topology.py existe" \
    "ls ~/lab07/mds_topology.py" "mds_topology.py"

check "cluster_simulator.py existe" \
    "ls ~/lab07/cluster_simulator.py" "cluster_simulator.py"

check "measure_real_cluster.py existe" \
    "ls ~/lab07/measure_real_cluster.py" "measure_real_cluster.py"

# Validar ejecución correcta
check "Perfil Read-Heavy identificado en product_catalog" \
    "python3 ~/lab07/workload_profile.py" "Read-Heavy"

check "Perfil Write-Heavy identificado en orders" \
    "python3 ~/lab07/workload_profile.py" "Write-Heavy"

check "Magma seleccionado para user_sessions" \
    "python3 ~/lab07/data_service_sizing.py" "Magma"

check "Tres escenarios de topología generados" \
    "python3 ~/lab07/mds_topology.py" "Escenario 3"

check "Simulador identifica riesgo ALTO en MVP" \
    "python3 ~/lab07/cluster_simulator.py" "ALTO"

check "Simulador identifica riesgo BAJO en configuración recomendada" \
    "python3 ~/lab07/cluster_simulator.py" "BAJO"

# Validar Server Groups en clúster real
check "Server Groups creados en el clúster" \
    "curl -s -u Administrator:password http://localhost:8091/pools/default/serverGroups | jq '.groups | length'" \
    "3\|[3-9]"

echo "========================================"
echo "Resultado: $PASS PASS / $FAIL FAIL"
echo "========================================"
```

```bash
# Ejecutar validación
bash ~/lab07/validate.sh
```

**Resultado esperado:** Al menos 9/10 checks en PASS. El check de Server Groups puede variar según el número de grupos pre-existentes en tu clúster.

---

## Solución de Problemas

### Problema 1: El script `data_service_sizing.py` falla con `ModuleNotFoundError: No module named 'tabulate'`

**Síntomas:**
```
Traceback (most recent call last):
  File "data_service_sizing.py", line 6, in <module>
    from tabulate import tabulate
ModuleNotFoundError: No module named 'tabulate'
```

**Causa:** El paquete `tabulate` no está instalado en el entorno Python activo. Esto ocurre cuando se usa un entorno virtual distinto al que se configuró, o cuando `pip` instaló el paquete para una versión diferente de Python.

**Solución:**
```bash
# Identificar qué Python se está usando
which python3
python3 --version

# Instalar tabulate para el Python correcto
python3 -m pip install tabulate

# Si hay múltiples versiones de Python, especificar explícitamente
python3.10 -m pip install tabulate matplotlib requests

# Verificar instalación
python3 -c "from tabulate import tabulate; print('tabulate OK')"

# Si estás en un entorno virtual, activarlo primero
source ~/venv/bin/activate
pip install tabulate matplotlib requests
```

---

### Problema 2: La REST API de Couchbase retorna `{"errors":{"_":"Requested resource not found."}}`

**Síntomas:**
```bash
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets/travel-sample/stats
# Retorna: {"errors":{"_":"Requested resource not found."}}
```

**Causa:** El bucket `travel-sample` no está cargado en el clúster de laboratorio. Este bucket es necesario para el Paso 6 (medición de métricas reales) y debe haberse cargado en los laboratorios previos (01-00-01 o 02-00-01).

**Solución:**
```bash
# Verificar qué buckets existen en el clúster
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets \
  | jq '[.[].name]'

# Si travel-sample no aparece, cargarlo desde la Web Console
# O mediante la CLI:
/opt/couchbase/bin/cbdocloader \
  -u Administrator -p password \
  -n localhost:8091 \
  -b travel-sample \
  -s 200 \
  /opt/couchbase/samples/travel-sample.zip

# Alternativa: usar cualquier bucket existente
# Editar ~/lab07/measure_real_cluster.py y cambiar:
# BUCKET = "travel-sample"  →  BUCKET = "<nombre_de_tu_bucket>"

# Verificar que el bucket cargó correctamente
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '.basicStats.itemCount'
# Debe retornar ~63288
```

---

## Limpieza del Entorno

```bash
# Detener cualquier proceso cbc-pillowfight que pueda estar corriendo
pkill -f cbc-pillowfight 2>/dev/null || true

# Eliminar Server Groups creados durante el lab (opcional)
# Primero obtener los URIs de los grupos
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/serverGroups \
  | jq '.groups[] | select(.name | test("Group-Data-AZ1|Group-Services-AZ2")) | .uri'

# Para cada URI obtenido, eliminar el grupo (solo si está vacío de nodos)
# curl -s -u Administrator:password \
#   -X DELETE "http://localhost:8091<URI_DEL_GRUPO>"

# Conservar los archivos del lab para referencia futura
echo "Archivos del lab conservados en ~/lab07/"
ls -la ~/lab07/

# Limpiar archivos temporales de Python
find ~/lab07/ -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find ~/lab07/ -name "*.pyc" -delete 2>/dev/null || true

echo "Limpieza completada."
```

> **Nota:** Los archivos Python generados en `~/lab07/` son entregables del laboratorio y deben conservarse como parte del runbook operativo. No los elimines si planeas usarlos como referencia en los laboratorios siguientes.

---

## Resumen

En este laboratorio aplicaste de forma end-to-end la metodología de sizing y diseño de topología de Couchbase para un sistema empresarial de e-commerce de escala real. Los principales logros fueron:

| Entregable | Descripción |
|---|---|
| **Modelo de carga** | Clasificación de 3 buckets: `product_catalog` (Read-Heavy, 93.8%), `user_sessions` (Mixto, 40%), `orders` (Write-Heavy, 20%) |
| **Sizing Data Service** | RAM total ~1,024 GB con headroom; Magma para datasets >100 GB; Couchstore para el resto |
| **Sizing servicios adicionales** | Query: 2 nodos CPU-intensivos; Index: 2 nodos con partitioning; FTS+Analytics: 2 nodos dedicados |
| **Topología MDS** | 3 escenarios con Server Groups por AZ; separación de servicios por perfil de recursos |
| **Simulador Python** | Modelo de resident ratio, latencia estimada y riesgo de saturación con proyección a 24 meses |
| **Métricas reales** | Consulta REST API con clasificación automática del perfil de carga según umbrales de la Lección 7.1 |

### Decisiones de Diseño Clave

- **Magma vs. Couchstore:** El umbral de 100 GB de dataset raw determina el storage engine óptimo. `user_sessions` (286 GB) se beneficia de la compresión LSM de Magma; `orders` (38 GB) es más eficiente con Couchstore.
- **Resident ratio objetivo:** Un sistema Read-Heavy como `product_catalog` requiere ≥95% de resident ratio; un sistema Mixto como `user_sessions` puede operar con 60% gracias a la localidad temporal de las sesiones activas.
- **Headroom del 30%:** La proyección del simulador muestra que el escenario MVP alcanza saturación en aproximadamente el Mes 6 con crecimiento del 8% mensual; el escenario Recomendado tiene margen hasta el Mes 18.

### Recursos Adicionales

- [Couchbase Sizing Guide (oficial)](https://docs.couchbase.com/server/current/install/sizing-general.html)
- [Couchbase Multidimensional Scaling](https://docs.couchbase.com/server/current/learn/services-and-indexes/services/services.html)
- [Couchbase Server Groups](https://docs.couchbase.com/server/current/manage/manage-groups/manage-groups.html)
- [Magma Storage Engine](https://docs.couchbase.com/server/current/learn/buckets-memory-and-storage/storage-engines.html)
- [Data Service Metrics Reference](https://docs.couchbase.com/server/current/metrics-reference/data-service-metrics.html)
- [REST API: Bucket Statistics](https://docs.couchbase.com/server/current/rest-api/rest-bucket-stats.html)

---
