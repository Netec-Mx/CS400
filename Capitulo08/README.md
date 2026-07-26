---LAB_START---
LAB_ID: 08-00-01
---MARKDOWN---
# Escalamiento y rebalanceo del clúster bajo carga

## Metadatos

| Campo            | Valor                                      |
|------------------|--------------------------------------------|
| **Duración**     | 96 minutos                                 |
| **Complejidad**  | Alta                                       |
| **Nivel Bloom**  | Aplicar                                    |
| **Versión CB**   | Couchbase Server Enterprise Edition 7.6.x  |
| **Modalidad**    | Individual / Parejas                       |

---

## Descripción General

En este laboratorio operarás un clúster de 4 nodos Couchbase bajo carga continua generada por `cbc-pillowfight` (mezcla 70% lectura / 30% escritura a 5,000 ops/seg). Ejecutarás operaciones de escala horizontal (scale-out y scale-in), un swap rebalance, la simulación y recuperación de un rebalanceo fallido, y finalmente automatizarás el proceso completo mediante un script Bash/Python que usa la REST API con polling de progreso. El laboratorio aplica directamente los conceptos del patrón de dos pasos —declarar intención y ejecutar rebalanceo— estudiados en la Lección 8.1.

---

## Objetivos de Aprendizaje

- [ ] Ejecutar operaciones de adición y remoción de nodos en un clúster bajo carga activa, monitorizando la transferencia de vBuckets, el tiempo estimado y las métricas de rendimiento durante el rebalanceo.
- [ ] Realizar un swap rebalance y comparar su duración e impacto frente a un rebalanceo estándar de adición/remoción.
- [ ] Automatizar operaciones de escalamiento horizontal mediante un script Bash/Python que use la REST API para agregar un nodo, iniciar el rebalanceo, monitorear su progreso con polling y notificar al completar.
- [ ] Diagnosticar y recuperar un rebalanceo fallido, identificando la causa de la falla y aplicando el procedimiento de recovery correcto.

---

## Prerrequisitos

### Conocimiento

- Haber completado **Lab 01-00-01** (despliegue y configuración inicial del clúster).
- Haber completado **Lab 04-00-01** (indexación y rendimiento de consultas).
- Comprensión del modelo de vBuckets y replicación de Couchbase.
- Familiaridad básica con `couchbase-cli`, `curl` y la REST API de Couchbase.
- Conocimiento básico de scripting en Bash o Python 3.

### Acceso y Herramientas

- Clúster de 4 nodos Couchbase Server 7.6.x en funcionamiento con el bucket `travel-sample` cargado y al menos 500 K documentos (ver nota de dataset aumentado en la introducción del curso).
- Un 5.º nodo disponible (VM o contenedor Docker) en estado limpio para incorporar al clúster.
- `cbc-pillowfight` instalado en el nodo cliente.
- `curl`, `jq` ≥ 1.6 instalados en el nodo cliente.
- Python 3.10+ con acceso a la red del clúster.
- Acceso a la Couchbase Web Console en `http://<node1>:8091`.

---

## Entorno de Laboratorio

### Topología Inicial

| Nodo        | Hostname / IP         | Servicios Asignados            | RAM Datos |
|-------------|-----------------------|--------------------------------|-----------|
| `node1`     | `192.168.10.11`       | Data, Query, Index             | 4 GB      |
| `node2`     | `192.168.10.12`       | Data, Query, Index             | 4 GB      |
| `node3`     | `192.168.10.13`       | Data                           | 4 GB      |
| `node4`     | `192.168.10.14`       | Data                           | 4 GB      |
| `node5`     | `192.168.10.15`       | Data *(se incorporará en lab)* | 4 GB      |
| `client`    | `192.168.10.20`       | Nodo cliente / generador carga | —         |

> **Nota Docker Compose:** Si usas el entorno containerizado provisto por el curso, ejecuta `docker-compose up -d` desde el directorio `lab08/` para levantar los 5 nodos y el cliente. El archivo `docker-compose.yml` ya configura las IPs estáticas y las variables de entorno necesarias.

### Variables de Entorno Globales

Define estas variables en tu sesión de terminal antes de comenzar. Serán usadas en todos los comandos del laboratorio:

```bash
export CB_HOST="192.168.10.11"
export CB_USER="Administrator"
export CB_PASS="password"
export CB_BUCKET="travel-sample"
export NODE1="ns_1@192.168.10.11"
export NODE2="ns_1@192.168.10.12"
export NODE3="ns_1@192.168.10.13"
export NODE4="ns_1@192.168.10.14"
export NODE5="ns_1@192.168.10.15"
export NEW_NODE_IP="192.168.10.15"
export NEW_NODE_HOST="192.168.10.15"
```

### Verificación del Estado Inicial del Clúster

Antes de iniciar cualquier ejercicio, confirma que el clúster está saludable:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, status: .status, services: .services}'
```

Todos los nodos deben reportar `"status": "healthy"`. Si alguno aparece en otro estado, notifica al instructor antes de continuar.

---

## Pasos del Laboratorio

---

### Paso 1 — Iniciar la Carga de Trabajo Continua con pillowfight

**Objetivo:** Establecer una carga de trabajo sostenida de 5,000 ops/seg (70% lectura / 30% escritura) que permanecerá activa durante todo el laboratorio para observar el impacto real de las operaciones de rebalanceo.

#### Instrucciones

1. Abre una terminal dedicada en el nodo `client` y **no la cierres** durante el resto del laboratorio. Esta terminal será la "ventana de carga".

2. Inicia `cbc-pillowfight` con los parámetros de carga especificados:

```bash
cbc-pillowfight \
  --spec couchbase://$CB_HOST/$CB_BUCKET \
  --username $CB_USER \
  --password $CB_PASS \
  --num-items 500000 \
  --num-threads 8 \
  --batch-size 100 \
  --rate-limit 5000 \
  --get-ratio 70 \
  --set-ratio 30 \
  --min-size 512 \
  --max-size 2048 \
  --duration 0
```

> El flag `--duration 0` ejecuta pillowfight indefinidamente. Lo detendrás manualmente al final del laboratorio con `Ctrl+C`.

3. Abre una **segunda terminal** en el nodo `client` para ejecutar los comandos de administración del clúster. Todas las instrucciones siguientes se ejecutan en esta segunda terminal, a menos que se indique lo contrario.

4. Espera 60 segundos y verifica que pillowfight está generando operaciones observando la salida en la terminal de carga. Deberías ver líneas similares a:

```
[0ms] OPS/SEC: 4987 | GET: 3490 | SET: 1497 | ERRORS: 0
```

#### Salida Esperada

La terminal de carga muestra OPS/SEC cercano a 5,000 con la proporción 70/30 de GET/SET y **ERRORS: 0**.

#### Verificación

```bash
# Consulta el throughput actual desde la REST API
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/stats | \
  jq '.op.samples | {
    ops_per_sec: .ops_per_sec[-1],
    gets_per_sec: .cmd_get[-1],
    sets_per_sec: .cmd_set[-1]
  }'
```

---

### Paso 2 — Scale-Out: Adición del Nodo 5 y Rebalanceo Monitorizando vBuckets

**Objetivo:** Incorporar el nodo 5 al clúster como nodo de Data Service, ejecutar el rebalanceo y monitorizar la transferencia de vBuckets, el tiempo estimado y el impacto en las métricas de rendimiento.

#### Instrucciones

1. **Verifica que el nodo 5 está limpio y accesible** desde el nodo 1:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$NEW_NODE_IP:8091/pools/default | jq '.nodes[0].status'
```

Si el nodo está limpio (recién instalado), este endpoint puede retornar un error de conexión o `"unknown"`. Eso es correcto. Si retorna `"healthy"` con otros nodos, el nodo ya pertenece a otro clúster y debe ser limpiado primero.

2. **Registra las métricas de línea base** antes del rebalanceo. Guarda estos valores para comparación posterior:

```bash
echo "=== MÉTRICAS PRE-REBALANCEO ===" > /tmp/metrics_baseline.txt
date >> /tmp/metrics_baseline.txt
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/stats | \
  jq '.op.samples | {
    ops_per_sec: .ops_per_sec[-5:],
    ep_bg_fetched: .ep_bg_fetched[-5:],
    vb_active_num: .vb_active_num[-1]
  }' >> /tmp/metrics_baseline.txt
cat /tmp/metrics_baseline.txt
```

3. **Incorpora el nodo 5** al clúster usando la REST API:

```bash
curl -v -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/addNode \
  -d "hostname=$NEW_NODE_HOST" \
  -d "user=$CB_USER" \
  -d "password=$CB_PASS" \
  -d "services=kv"
```

4. **Confirma que el nodo 5 está en estado `pending`** en la Web Console navegando a `http://$CB_HOST:8091` → **Servers**. También puedes verificarlo por API:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, clusterMembership: .clusterMembership, status: .status}'
```

El nodo 5 debe aparecer con `"clusterMembership": "inactivePendingJoin"`.

5. **Inicia el rebalanceo** especificando todos los nodos conocidos (incluyendo el nuevo):

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/rebalance \
  -d "knownNodes=$NODE1,$NODE2,$NODE3,$NODE4,$NODE5"
```

6. **Abre una tercera terminal** y ejecuta el siguiente bucle de monitoreo de progreso. Este script consultará el endpoint de progreso cada 5 segundos y mostrará el avance de la transferencia de vBuckets:

```bash
#!/bin/bash
# monitor_rebalance.sh
echo "Iniciando monitoreo de rebalanceo..."
START_TIME=$(date +%s)

while true; do
  PROGRESS=$(curl -s -u $CB_USER:$CB_PASS \
    http://$CB_HOST:8091/pools/default/rebalanceProgress)

  STATUS=$(echo $PROGRESS | jq -r '.status')

  if [ "$STATUS" == "none" ]; then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo ""
    echo "✅ Rebalanceo completado en ${DURATION} segundos."
    break
  fi

  PERCENT=$(echo $PROGRESS | jq -r '
    .perNode | to_entries[] |
    select(.value.progress != null) |
    "\(.key): \(.value.progress | . * 100 | round)%"
  ' 2>/dev/null | head -5)

  TIMESTAMP=$(date "+%H:%M:%S")
  echo "[$TIMESTAMP] Status: $STATUS"
  echo "$PERCENT"
  echo "---"
  sleep 5
done
```

```bash
bash monitor_rebalance.sh
```

7. **Mientras el rebalanceo está en curso**, observa en la terminal de carga (pillowfight) si hay variaciones en OPS/SEC o errores. Anota cualquier degradación observable.

8. Una vez completado el rebalanceo, **registra las métricas post-rebalanceo**:

```bash
echo "=== MÉTRICAS POST-REBALANCEO SCALE-OUT ===" >> /tmp/metrics_baseline.txt
date >> /tmp/metrics_baseline.txt
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/stats | \
  jq '.op.samples | {
    ops_per_sec: .ops_per_sec[-5:],
    vb_active_num: .vb_active_num[-1]
  }' >> /tmp/metrics_baseline.txt
cat /tmp/metrics_baseline.txt
```

#### Salida Esperada

- El endpoint `/pools/default/rebalanceProgress` muestra `"status": "running"` con porcentajes de progreso por nodo durante el rebalanceo.
- Al finalizar, el endpoint retorna `"status": "none"`.
- El número de vBuckets activos por nodo debe redistribuirse: con 5 nodos y 1024 vBuckets totales, cada nodo debería tener aproximadamente 204–205 vBuckets activos.
- pillowfight puede mostrar una leve reducción de OPS/SEC (5–15%) durante el rebalanceo, pero no debe reportar errores de conexión.

#### Verificación

```bash
# Verificar distribución de vBuckets post scale-out
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/nodes | \
  jq '.servers[] | {hostname: .hostname, status: .status, vBucketServerMap: "N/A"}'

# Verificar que todos los nodos están healthy
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | select(.status != "healthy") | .hostname'
```

La segunda consulta no debe retornar ningún resultado (todos los nodos están healthy).

---

### Paso 3 — Scale-In: Remoción Planificada de un Nodo y Rebalanceo

**Objetivo:** Ejecutar una remoción planificada (graceful remove) del nodo 5 usando `couchbase-cli`, observar cómo Couchbase transfiere los vBuckets antes de desconectar el nodo, y registrar la duración para comparación posterior.

#### Instrucciones

1. **Registra el tiempo de inicio** y las métricas actuales:

```bash
echo "=== INICIO SCALE-IN ===" > /tmp/scalein_metrics.txt
date >> /tmp/scalein_metrics.txt
SCALEIN_START=$(date +%s)
```

2. **Ejecuta la remoción y el rebalanceo usando `couchbase-cli`** en un solo comando. Este método combina el marcado para remoción y el inicio del rebalanceo:

```bash
couchbase-cli rebalance \
  --cluster http://$CB_HOST:8091 \
  --username $CB_USER \
  --password $CB_PASS \
  --server-remove $NEW_NODE_IP:8091 \
  --no-progress-bar
```

> **Nota:** El flag `--no-progress-bar` deshabilita la barra de progreso interactiva para que la salida sea más legible en logs. Si prefieres la barra visual, omite este flag.

3. **En paralelo** (en la tercera terminal), ejecuta el monitor de progreso del Paso 2 mientras el rebalanceo de scale-in está en curso.

4. Una vez completado, **registra la duración y métricas finales**:

```bash
SCALEIN_END=$(date +%s)
SCALEIN_DURATION=$((SCALEIN_END - SCALEIN_START))
echo "Duración scale-in: ${SCALEIN_DURATION} segundos" >> /tmp/scalein_metrics.txt
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/stats | \
  jq '.op.samples | {ops_per_sec: .ops_per_sec[-5:]}' >> /tmp/scalein_metrics.txt
cat /tmp/scalein_metrics.txt
```

5. **Verifica** que el clúster volvió a 4 nodos y todos están saludables:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes | length, (.nodes[] | {hostname: .hostname, status: .status})'
```

#### Salida Esperada

- `couchbase-cli rebalance` muestra progreso y finaliza con mensaje `SUCCESS: Rebalance complete`.
- El clúster vuelve a tener 4 nodos, todos en estado `healthy`.
- La duración del scale-in debe ser comparable o ligeramente mayor al scale-out del Paso 2 (ambos mueven aproximadamente 204 vBuckets).

#### Verificación

```bash
# Confirmar que el nodo 5 ya no está en el clúster
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | .hostname' | grep "$NEW_NODE_IP" && \
  echo "ERROR: Nodo 5 aún en el clúster" || \
  echo "OK: Nodo 5 removido correctamente"
```

---

### Paso 4 — Swap Rebalance: Sustitución Simultánea de un Nodo

**Objetivo:** Ejecutar un swap rebalance incorporando el nodo 5 y removiendo el nodo 4 en una sola operación, midiendo la duración y comparando el impacto en rendimiento versus los rebalanceos separados de los pasos anteriores.

#### Instrucciones

1. **Registra el tiempo de inicio**:

```bash
SWAP_START=$(date +%s)
echo "=== INICIO SWAP REBALANCE ===" > /tmp/swap_metrics.txt
date >> /tmp/swap_metrics.txt
```

2. **Incorpora el nodo 5** al clúster (debe estar limpio desde el Paso 3):

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/addNode \
  -d "hostname=$NEW_NODE_HOST" \
  -d "user=$CB_USER" \
  -d "password=$CB_PASS" \
  -d "services=kv"
```

3. **Verifica que el nodo 5 está en estado `inactivePendingJoin`** y el nodo 4 está activo:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, clusterMembership: .clusterMembership}'
```

4. **Ejecuta el swap rebalance** en un solo llamado REST, especificando el nodo a incorporar en `knownNodes` y el nodo a eyectar en `ejectedNodes`:

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/rebalance \
  -d "knownNodes=$NODE1,$NODE2,$NODE3,$NODE5" \
  -d "ejectedNodes=$NODE4"
```

> **Concepto clave:** Al especificar simultáneamente un nodo entrante y uno saliente, Couchbase detecta automáticamente el patrón de swap rebalance y transfiere los vBuckets **directamente** del nodo saliente al nodo entrante, sin redistribuir datos a través de los nodos intermedios. Esto reduce significativamente el tráfico de red total.

5. **Monitorea el progreso** ejecutando el script `monitor_rebalance.sh` de la tercera terminal y **observa en la Web Console** (`http://$CB_HOST:8091` → **Servers**) cómo el nodo 4 aparece como "Removing" y el nodo 5 como "Adding" simultáneamente.

6. Una vez completado, **registra la duración**:

```bash
SWAP_END=$(date +%s)
SWAP_DURATION=$((SWAP_END - SWAP_START))
echo "Duración swap rebalance: ${SWAP_DURATION} segundos" >> /tmp/swap_metrics.txt
```

7. **Compara las duraciones** de las tres operaciones:

```bash
echo ""
echo "=========================================="
echo "COMPARATIVA DE DURACIONES DE REBALANCEO"
echo "=========================================="
echo "Scale-out (add node5):    $(grep 'Duración scale-in' /tmp/scalein_metrics.txt | awk '{print $NF}') seg (referencia del scale-in)"
echo "Swap rebalance:           ${SWAP_DURATION} seg"
echo ""
echo "Nota: El swap rebalance debería ser igual o más rápido que"
echo "ejecutar add+rebalance y remove+rebalance por separado."
```

#### Salida Esperada

- El swap rebalance completa en un tiempo igual o menor al de los rebalanceos individuales de los pasos anteriores.
- En la Web Console, durante el swap rebalance se observa que el nodo 4 y el nodo 5 están en operación simultánea (uno saliendo, uno entrando).
- El clúster termina con 4 nodos: node1, node2, node3, node5, todos en estado `healthy`.

#### Verificación

```bash
# Confirmar topología final del swap rebalance
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, status: .status, services: .services}'
```

---

### Paso 5 — Simulación y Recuperación de un Rebalanceo Fallido

**Objetivo:** Interrumpir deliberadamente un rebalanceo en curso (simulando un fallo de red o una intervención manual), observar el estado resultante del clúster y ejecutar el procedimiento correcto de recovery.

#### Instrucciones

**Parte A: Preparar y lanzar el rebalanceo que se interrumpirá**

1. Incorpora el nodo 4 nuevamente al clúster (que fue removido en el Paso 4):

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/addNode \
  -d "hostname=192.168.10.14" \
  -d "user=$CB_USER" \
  -d "password=$CB_PASS" \
  -d "services=kv"
```

2. Inicia el rebalanceo:

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/rebalance \
  -d "knownNodes=$NODE1,$NODE2,$NODE3,$NODE5,ns_1@192.168.10.14"
```

**Parte B: Interrumpir el rebalanceo a mitad de proceso**

3. Espera exactamente **15 segundos** y luego detén el rebalanceo usando el endpoint de stop:

```bash
sleep 15
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/stopRebalance
```

4. **Observa el estado del clúster** inmediatamente después de la interrupción:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '{
    rebalanceStatus: .rebalanceStatus,
    nodes: [.nodes[] | {hostname: .hostname, status: .status, clusterMembership: .clusterMembership}]
  }'
```

5. **Consulta el log de rebalanceo** para entender el estado en que quedó:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/logs | \
  jq '.list[] | select(.type == "rebalance") | {tstamp: .tstamp, text: .text}' | \
  tail -20
```

**Parte C: Procedimiento de Recovery**

6. Verifica si hay vBuckets en estado inconsistente consultando el estado de cada nodo:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {
    hostname: .hostname,
    clusterMembership: .clusterMembership,
    recoveryType: .recoveryType
  }'
```

7. Si algún nodo aparece con `"clusterMembership": "inactiveFailed"` o `"recoveryType": "delta"/"full"`, ejecuta el recovery antes de reintentar el rebalanceo:

```bash
# Aplicar recovery a nodos que lo requieran (ajusta el OTP node según el output anterior)
# Ejemplo para node4 si quedó en estado inactiveFailed:
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/setRecoveryType \
  -d "otpNode=ns_1@192.168.10.14" \
  -d "recoveryType=delta"
```

8. **Reinicia el rebalanceo** para completar la operación interrumpida:

```bash
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/rebalance \
  -d "knownNodes=$NODE1,$NODE2,$NODE3,$NODE5,ns_1@192.168.10.14"
```

9. Monitorea hasta completar con el script `monitor_rebalance.sh`.

10. **Verifica el estado final**:

```bash
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, status: .status, clusterMembership: .clusterMembership}'
```

#### Salida Esperada

- Tras `stopRebalance`, el campo `rebalanceStatus` del clúster pasa de `"running"` a `"none"` o `"stopped"`.
- Algunos nodos pueden aparecer en estado `"inactivePendingJoin"` o con vBuckets parcialmente migrados. El clúster continúa sirviendo datos gracias a las réplicas existentes.
- Tras el recovery y el rebalanceo completo, todos los nodos reportan `"clusterMembership": "active"` y `"status": "healthy"`.

#### Verificación

```bash
# Confirmar que no hay nodos en estado anómalo
ANOMALOS=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '[.nodes[] | select(.clusterMembership != "active")] | length')

if [ "$ANOMALOS" -eq "0" ]; then
  echo "✅ Todos los nodos en estado 'active'. Recovery exitoso."
else
  echo "⚠️  Hay $ANOMALOS nodo(s) en estado anómalo. Revisar manualmente."
fi
```

---

### Paso 6 — Automatización: Script de Escalamiento con Polling REST API

**Objetivo:** Desarrollar un script Python que automatice el proceso completo de: agregar un nodo, iniciar el rebalanceo, monitorear su progreso mediante polling de la REST API y notificar al completar o ante un error.

#### Instrucciones

1. **Crea el archivo del script** en el nodo cliente:

```bash
cat > /opt/lab08/rebalance_automation.py << 'EOF'
#!/usr/bin/env python3
"""
rebalance_automation.py
Automatiza la adición de un nodo a un clúster Couchbase y monitorea
el rebalanceo hasta su completación mediante polling de la REST API.

Uso: python3 rebalance_automation.py --cluster <IP> --new-node <IP>
"""

import argparse
import json
import sys
import time
import urllib.request
import urllib.parse
import urllib.error
import base64
from datetime import datetime


def make_request(url, user, password, method="GET", data=None):
    """Realiza una petición HTTP a la REST API de Couchbase."""
    credentials = base64.b64encode(f"{user}:{password}".encode()).decode()
    headers = {
        "Authorization": f"Basic {credentials}",
        "Content-Type": "application/x-www-form-urlencoded"
    }
    
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        raise Exception(f"HTTP {e.code}: {error_body}")


def get_cluster_nodes(cluster_ip, user, password):
    """Obtiene la lista de nodos activos del clúster."""
    url = f"http://{cluster_ip}:8091/pools/default"
    data = make_request(url, user, password)
    return [node["otpNode"] for node in data["nodes"]]


def add_node(cluster_ip, user, password, new_node_ip, services="kv"):
    """Agrega un nuevo nodo al clúster en estado pending."""
    url = f"http://{cluster_ip}:8091/controller/addNode"
    data = {
        "hostname": new_node_ip,
        "user": user,
        "password": password,
        "services": services
    }
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Agregando nodo {new_node_ip} con servicios: {services}")
    result = make_request(url, user, password, method="POST", data=data)
    print(f"[{datetime.now().strftime('%H:%M:%S')}] ✅ Nodo agregado. OTP: {result.get('otpNode', 'N/A')}")
    return result


def start_rebalance(cluster_ip, user, password, known_nodes):
    """Inicia el rebalanceo con la lista de nodos conocidos."""
    url = f"http://{cluster_ip}:8091/controller/rebalance"
    data = {"knownNodes": ",".join(known_nodes)}
    print(f"[{datetime.now().strftime('%H:%M:%S')}] Iniciando rebalanceo con {len(known_nodes)} nodos...")
    make_request(url, user, password, method="POST", data=data)
    print(f"[{datetime.now().strftime('%H:%M:%S')}] ✅ Rebalanceo iniciado.")


def poll_rebalance_progress(cluster_ip, user, password, poll_interval=5, timeout=1800):
    """
    Monitorea el progreso del rebalanceo mediante polling.
    Retorna True si completó exitosamente, False si falló o se agotó el tiempo.
    """
    url = f"http://{cluster_ip}:8091/pools/default/rebalanceProgress"
    start_time = time.time()
    
    print(f"\n{'='*60}")
    print("MONITOREO DE PROGRESO DEL REBALANCEO")
    print(f"{'='*60}")
    
    while True:
        elapsed = time.time() - start_time
        
        if elapsed > timeout:
            print(f"\n⚠️  TIMEOUT: El rebalanceo no completó en {timeout} segundos.")
            return False
        
        try:
            progress = make_request(url, user, password)
        except Exception as e:
            print(f"[{datetime.now().strftime('%H:%M:%S')}] Error consultando progreso: {e}")
            time.sleep(poll_interval)
            continue
        
        status = progress.get("status", "unknown")
        
        if status == "none":
            total_time = time.time() - start_time
            print(f"\n✅ REBALANCEO COMPLETADO en {total_time:.1f} segundos.")
            return True
        
        if "errorMessage" in progress:
            print(f"\n❌ ERROR EN REBALANCEO: {progress['errorMessage']}")
            return False
        
        # Mostrar progreso por nodo
        timestamp = datetime.now().strftime('%H:%M:%S')
        per_node = progress.get("perNode", {})
        
        print(f"\n[{timestamp}] Status: {status} | Elapsed: {elapsed:.0f}s")
        for node, node_data in per_node.items():
            node_progress = node_data.get("progress", 0)
            bar_len = 20
            filled = int(bar_len * node_progress)
            bar = "█" * filled + "░" * (bar_len - filled)
            short_name = node.split("@")[-1]
            print(f"  {short_name:20s} [{bar}] {node_progress*100:.1f}%")
        
        time.sleep(poll_interval)


def verify_cluster_health(cluster_ip, user, password):
    """Verifica que todos los nodos del clúster estén en estado healthy."""
    url = f"http://{cluster_ip}:8091/pools/default"
    data = make_request(url, user, password)
    
    all_healthy = True
    print(f"\n{'='*60}")
    print("VERIFICACIÓN DE SALUD DEL CLÚSTER")
    print(f"{'='*60}")
    
    for node in data["nodes"]:
        hostname = node.get("hostname", "unknown")
        status = node.get("status", "unknown")
        membership = node.get("clusterMembership", "unknown")
        icon = "✅" if status == "healthy" else "❌"
        print(f"  {icon} {hostname:30s} | status: {status:10s} | membership: {membership}")
        if status != "healthy":
            all_healthy = False
    
    return all_healthy


def main():
    parser = argparse.ArgumentParser(description="Automatización de rebalanceo Couchbase")
    parser.add_argument("--cluster", required=True, help="IP del nodo coordinador del clúster")
    parser.add_argument("--new-node", required=True, help="IP del nuevo nodo a agregar")
    parser.add_argument("--user", default="Administrator", help="Usuario administrador")
    parser.add_argument("--password", default="password", help="Contraseña")
    parser.add_argument("--services", default="kv", help="Servicios: kv,n1ql,index,fts,cbas,eventing")
    parser.add_argument("--poll-interval", type=int, default=5, help="Intervalo de polling en segundos")
    args = parser.parse_args()
    
    print(f"\n{'='*60}")
    print("SCRIPT DE AUTOMATIZACIÓN DE ESCALAMIENTO COUCHBASE")
    print(f"Clúster: {args.cluster} | Nuevo nodo: {args.new_node}")
    print(f"{'='*60}\n")
    
    try:
        # Paso 1: Obtener nodos actuales
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Obteniendo topología actual...")
        current_nodes = get_cluster_nodes(args.cluster, args.user, args.password)
        print(f"[{datetime.now().strftime('%H:%M:%S')}] Nodos actuales ({len(current_nodes)}): {current_nodes}")
        
        # Paso 2: Agregar el nuevo nodo
        result = add_node(args.cluster, args.user, args.password, 
                         args.new_node, args.services)
        new_otp_node = result.get("otpNode")
        
        # Paso 3: Construir la lista completa de nodos conocidos
        all_nodes = current_nodes + [new_otp_node]
        
        # Paso 4: Iniciar el rebalanceo
        start_rebalance(args.cluster, args.user, args.password, all_nodes)
        
        # Paso 5: Monitorear progreso con polling
        success = poll_rebalance_progress(
            args.cluster, args.user, args.password, 
            poll_interval=args.poll_interval
        )
        
        # Paso 6: Verificar salud final del clúster
        healthy = verify_cluster_health(args.cluster, args.user, args.password)
        
        # Resultado final
        print(f"\n{'='*60}")
        if success and healthy:
            print("🎉 OPERACIÓN COMPLETADA EXITOSAMENTE")
            print(f"   El clúster ahora tiene {len(all_nodes)} nodos saludables.")
            sys.exit(0)
        else:
            print("⚠️  OPERACIÓN COMPLETADA CON ADVERTENCIAS")
            print("   Revisar el estado del clúster manualmente.")
            sys.exit(1)
            
    except Exception as e:
        print(f"\n❌ ERROR FATAL: {e}")
        sys.exit(2)


if __name__ == "__main__":
    main()
EOF

chmod +x /opt/lab08/rebalance_automation.py
```

2. **Antes de ejecutar el script**, asegúrate de que el clúster está en un estado limpio con 4 nodos y el nodo 5 ha sido removido. Si el nodo 5 aún está en el clúster desde el Paso 5, remuévelo primero:

```bash
# Verificar estado actual
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes | length'
```

Si hay 5 nodos, ejecuta un scale-in del nodo 5 antes de continuar:

```bash
couchbase-cli rebalance \
  --cluster http://$CB_HOST:8091 \
  --username $CB_USER \
  --password $CB_PASS \
  --server-remove $NEW_NODE_IP:8091
```

3. **Ejecuta el script de automatización** para agregar el nodo 5 nuevamente:

```bash
python3 /opt/lab08/rebalance_automation.py \
  --cluster $CB_HOST \
  --new-node $NEW_NODE_IP \
  --user $CB_USER \
  --password $CB_PASS \
  --services kv \
  --poll-interval 5
```

4. Observa la salida del script: debe mostrar el progreso en tiempo real con barras de avance por nodo y finalizar con el resumen de salud del clúster.

5. **Extiende el script** (ejercicio adicional): modifica `rebalance_automation.py` para aceptar también un parámetro `--eject-node` que permita ejecutar un swap rebalance automatizado. Añade la lógica en la función `start_rebalance` para incluir `ejectedNodes` en el payload cuando este parámetro esté presente.

#### Salida Esperada

```
============================================================
SCRIPT DE AUTOMATIZACIÓN DE ESCALAMIENTO COUCHBASE
Clúster: 192.168.10.11 | Nuevo nodo: 192.168.10.15
============================================================

[14:23:01] Obteniendo topología actual...
[14:23:01] Nodos actuales (4): ['ns_1@192.168.10.11', ...]
[14:23:01] Agregando nodo 192.168.10.15 con servicios: kv
[14:23:02] ✅ Nodo agregado. OTP: ns_1@192.168.10.15
[14:23:02] Iniciando rebalanceo con 5 nodos...
[14:23:03] ✅ Rebalanceo iniciado.

============================================================
MONITOREO DE PROGRESO DEL REBALANCEO
============================================================

[14:23:08] Status: running | Elapsed: 5s
  192.168.10.11        [████░░░░░░░░░░░░░░░░] 20.0%
  192.168.10.12        [████░░░░░░░░░░░░░░░░] 18.5%
  ...

✅ REBALANCEO COMPLETADO en 142.3 segundos.
```

#### Verificación

```bash
# Verificar código de salida del script
echo "Código de salida: $?"

# Verificar que el clúster tiene 5 nodos saludables
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '[.nodes[] | select(.status == "healthy")] | length'
```

El resultado debe ser `5`.

---

## Validación y Pruebas Finales

Ejecuta las siguientes verificaciones para confirmar que el laboratorio se completó correctamente:

```bash
#!/bin/bash
# validation_lab08.sh
echo "======================================"
echo "VALIDACIÓN FINAL - LAB 08-00-01"
echo "======================================"

PASS=0
FAIL=0

# Test 1: Clúster tiene nodos saludables
HEALTHY=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '[.nodes[] | select(.status == "healthy")] | length')
if [ "$HEALTHY" -ge "4" ]; then
  echo "✅ Test 1: $HEALTHY nodos saludables en el clúster"
  PASS=$((PASS+1))
else
  echo "❌ Test 1: Solo $HEALTHY nodos saludables (mínimo 4 requeridos)"
  FAIL=$((FAIL+1))
fi

# Test 2: No hay rebalanceo en curso
REBAL_STATUS=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/rebalanceProgress | \
  jq -r '.status')
if [ "$REBAL_STATUS" == "none" ]; then
  echo "✅ Test 2: No hay rebalanceo en curso"
  PASS=$((PASS+1))
else
  echo "❌ Test 2: Rebalanceo en estado '$REBAL_STATUS'"
  FAIL=$((FAIL+1))
fi

# Test 3: pillowfight sigue activo (sin errores críticos)
OPS=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET/stats | \
  jq '.op.samples.ops_per_sec[-1]')
if (( $(echo "$OPS > 1000" | bc -l) )); then
  echo "✅ Test 3: Carga activa - $OPS ops/seg"
  PASS=$((PASS+1))
else
  echo "⚠️  Test 3: Carga baja - $OPS ops/seg (pillowfight puede estar detenido)"
  FAIL=$((FAIL+1))
fi

# Test 4: Script de automatización existe y es ejecutable
if [ -x "/opt/lab08/rebalance_automation.py" ]; then
  echo "✅ Test 4: Script de automatización presente y ejecutable"
  PASS=$((PASS+1))
else
  echo "❌ Test 4: Script de automatización no encontrado"
  FAIL=$((FAIL+1))
fi

# Test 5: Todos los nodos en membership 'active'
INACTIVE=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '[.nodes[] | select(.clusterMembership != "active")] | length')
if [ "$INACTIVE" -eq "0" ]; then
  echo "✅ Test 5: Todos los nodos con membership 'active'"
  PASS=$((PASS+1))
else
  echo "❌ Test 5: $INACTIVE nodo(s) con membership anómalo"
  FAIL=$((FAIL+1))
fi

echo ""
echo "======================================"
echo "RESULTADO: $PASS/5 pruebas pasadas"
if [ "$FAIL" -eq "0" ]; then
  echo "🎉 LABORATORIO COMPLETADO EXITOSAMENTE"
else
  echo "⚠️  $FAIL prueba(s) fallida(s). Revisar secciones correspondientes."
fi
echo "======================================"
```

```bash
bash /opt/lab08/validation_lab08.sh
```

---

## Resolución de Problemas

### Problema 1: El rebalanceo falla con error "Not all nodes are healthy"

**Síntomas:**
- El comando `curl /controller/rebalance` retorna HTTP 400 con el mensaje `"Not all nodes are healthy"` o `"Rebalance failed"`.
- La Web Console muestra un banner de error rojo en la sección Servers.
- El endpoint `/pools/default/rebalanceProgress` retorna `{"status": "none", "errorMessage": "..."}`.

**Causa:**
Uno o más nodos del clúster tienen el Data Service en estado de calentamiento (`warmup`) o hay vBuckets en estado `pending` sin resolver de una operación anterior interrumpida. Esto ocurre típicamente cuando se intenta iniciar un nuevo rebalanceo muy poco tiempo después de un failover o de un rebalanceo interrumpido (como en el Paso 5).

**Solución:**

```bash
# Paso 1: Identificar nodos con estado anómalo
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | select(.status != "healthy") | {hostname: .hostname, status: .status}'

# Paso 2: Si hay nodos en 'warmup', esperar 2-3 minutos y reintentar
# El warmup es temporal y se resuelve solo

# Paso 3: Si hay nodos en 'inactiveFailed', aplicar recovery delta primero
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/controller/setRecoveryType \
  -d "otpNode=ns_1@<nodo-afectado>" \
  -d "recoveryType=delta"

# Paso 4: Reintentar el rebalanceo después de que todos los nodos estén healthy
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '[.nodes[] | select(.status == "healthy")] | length'
```

---

### Problema 2: pillowfight reporta errores de conexión durante el rebalanceo

**Síntomas:**
- La terminal de carga de pillowfight muestra `ERRORS: > 0` con mensajes como `LCB_ERR_TIMEOUT` o `LCB_ERR_TEMPORARY_FAILURE`.
- El número de errores aumenta durante la fase de transferencia de vBuckets y luego disminuye al completar el rebalanceo.
- OPS/SEC cae por debajo del 50% del valor esperado.

**Causa:**
Durante el rebalanceo, los vBuckets se mueven entre nodos. Hay una ventana breve en la que el cliente recibe una respuesta `NOT_MY_VBUCKET` del nodo origen antes de que el mapa de vBuckets actualizado se propague al cliente. Si el número de errores es alto y persistente (no temporal), puede indicar que el clúster tiene configuración de replicación insuficiente (0 réplicas) o que el `rebalanceMovesPerNode` está configurado demasiado alto, sobrecargando la red.

**Solución:**

```bash
# Paso 1: Verificar configuración de réplicas del bucket
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default/buckets/$CB_BUCKET | \
  jq '{name: .name, replicaNumber: .replicaNumber}'

# Si replicaNumber es 0, los errores durante rebalanceo son esperados.
# Para entornos de producción, se recomienda mínimo 1 réplica.

# Paso 2: Reducir la velocidad del rebalanceo para disminuir impacto
# (ajustar movimientos simultáneos de vBuckets por nodo)
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/internalSettings \
  -d "rebalanceMovesPerNode=2"

# Valor por defecto es 4; reducir a 2 disminuye el impacto pero aumenta la duración.

# Paso 3: Verificar que pillowfight usa reconexión automática
# El SDK de Couchbase maneja NOT_MY_VBUCKET automáticamente.
# Los errores transitorios durante rebalanceo son normales con duración < 30 seg.

# Paso 4: Si los errores persisten más de 5 minutos, verificar logs del clúster
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/logs | \
  jq '.list[] | select(.type == "error") | {tstamp: .tstamp, text: .text}' | \
  tail -10
```

---

## Limpieza del Entorno

Ejecuta los siguientes pasos para dejar el entorno en un estado limpio para el siguiente laboratorio:

```bash
# 1. Detener pillowfight (en la terminal de carga)
# Presiona Ctrl+C en la terminal donde está ejecutando pillowfight

# 2. Verificar el estado final del clúster
echo "Estado final del clúster:"
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '.nodes[] | {hostname: .hostname, status: .status, services: .services}'

# 3. Si el clúster terminó con 5 nodos, devuélvelo a 4 nodos removiendo el nodo 5
NODE_COUNT=$(curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | jq '.nodes | length')

if [ "$NODE_COUNT" -eq "5" ]; then
  echo "Removiendo nodo 5 para dejar el clúster en 4 nodos..."
  couchbase-cli rebalance \
    --cluster http://$CB_HOST:8091 \
    --username $CB_USER \
    --password $CB_PASS \
    --server-remove $NEW_NODE_IP:8091
fi

# 4. Limpiar archivos temporales del laboratorio
rm -f /tmp/metrics_baseline.txt /tmp/scalein_metrics.txt /tmp/swap_metrics.txt

# 5. Restaurar el parámetro rebalanceMovesPerNode a su valor por defecto
curl -u $CB_USER:$CB_PASS \
  -X POST \
  http://$CB_HOST:8091/internalSettings \
  -d "rebalanceMovesPerNode=4"

# 6. Confirmar estado final limpio
echo ""
echo "Verificación final:"
curl -s -u $CB_USER:$CB_PASS \
  http://$CB_HOST:8091/pools/default | \
  jq '{
    totalNodes: (.nodes | length),
    healthyNodes: ([.nodes[] | select(.status == "healthy")] | length),
    rebalanceStatus: .rebalanceStatus
  }'
```

---

## Resumen

En este laboratorio aplicaste el patrón de dos pasos de Couchbase —declarar intención y ejecutar rebalanceo— en cinco escenarios operativos de complejidad creciente:

| Operación                  | Método Utilizado                          | Resultado Clave                                          |
|----------------------------|-------------------------------------------|----------------------------------------------------------|
| Scale-out (Paso 2)         | REST API + monitor polling                | vBuckets redistribuidos a 5 nodos; impacto ~5–15% en OPS |
| Scale-in (Paso 3)          | `couchbase-cli rebalance --server-remove` | Remoción planificada sin pérdida de datos                |
| Swap rebalance (Paso 4)    | REST API con `ejectedNodes`               | Transferencia directa nodo-a-nodo; duración ≤ rebalanceo simple |
| Recovery de fallo (Paso 5) | `stopRebalance` + `setRecoveryType`       | Clúster recuperado sin pérdida de datos                  |
| Automatización (Paso 6)    | Script Python con polling REST API        | Proceso reproducible y observable end-to-end             |

**Lecciones operativas clave:**

- La **remoción planificada** (`ejectNode` + rebalanceo) es siempre preferible al failover cuando hay tiempo para planificar, ya que garantiza que todos los vBuckets se transfieren antes de desconectar el nodo.
- El **swap rebalance** minimiza el movimiento de datos al transferir vBuckets directamente entre el nodo entrante y el saliente, sin involucrar a los nodos intermedios.
- Un rebalanceo interrumpido no corrompe los datos gracias al sistema de réplicas, pero deja el clúster en un estado que requiere recovery explícito antes de reintentar.
- El endpoint `/pools/default/rebalanceProgress` es la fuente de verdad para monitorear el estado del rebalanceo y debe usarse en cualquier automatización operativa.

### Recursos Adicionales

- [Documentación oficial: Adding Nodes to a Cluster](https://docs.couchbase.com/server/current/clustersetup/add-nodes.html)
- [Documentación oficial: Removing Nodes from a Cluster](https://docs.couchbase.com/server/current/clustersetup/remove-nodes.html)
- [Documentación oficial: Rebalancing — REST API Reference](https://docs.couchbase.com/server/current/rest-api/rest-cluster-rebalance.html)
- [Couchbase Blog: Understanding Rebalance in Couchbase Server](https://www.couchbase.com/blog/understanding-rebalance-in-couchbase-server/)
- [Documentación oficial: couchbase-cli rebalance](https://docs.couchbase.com/server/current/cli/cbcli/couchbase-cli-rebalance.html)

---
LAB_END---
