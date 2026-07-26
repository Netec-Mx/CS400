# Diagnóstico, recuperación y mantenimiento del clúster

## Metadatos

| Campo            | Valor                                                                 |
|------------------|-----------------------------------------------------------------------|
| **Duración**     | 48 minutos                                                            |
| **Complejidad**  | Alta                                                                  |
| **Nivel Bloom**  | Crear                                                                 |
| **Módulo**       | Capítulo 13 — Diagnóstico, recuperación y mantenimiento del clúster   |
| **Versión CB**   | Couchbase Server Enterprise Edition 7.6.x                             |

---

## Descripción General

Esta práctica integra cuatro bloques operativos que simulan situaciones reales de producción en un clúster Couchbase de tres nodos. El estudiante aplicará la metodología estructurada de troubleshooting (Observar → Delimitar → Formular hipótesis → Probar → Corregir → Verificar) para diagnosticar fallos inyectados, ejecutará un ciclo completo de backup y restore con validación de integridad, simulará un rolling upgrade con estrategia de rollback documentada, y compilará todos los hallazgos en un runbook operativo reutilizable. Al completar la práctica, el estudiante habrá demostrado dominio operativo end-to-end de Couchbase en escenarios de nivel intermedio-avanzado.

---

## Objetivos de Aprendizaje

Al finalizar este laboratorio, serás capaz de:

- [ ] Aplicar la metodología de seis etapas de troubleshooting para diagnosticar fallos simulados en el clúster, correlacionando métricas REST API, logs y salidas de `cbstats` con evidencias concretas.
- [ ] Ejecutar un ciclo completo de backup y restore selectivo con `cbbackupmgr`, validar la integridad de los datos recuperados mediante SQL++ y medir el RTO real del procedimiento.
- [ ] Realizar un rolling upgrade simulado de un nodo documentando puntos de verificación de compatibilidad, proceso de rebalance y procedimiento de rollback.
- [ ] Construir un runbook operativo ejecutable que documente los incidentes, comandos exactos de remediación y criterios de verificación de resolución.

---

## Prerrequisitos

### Conocimiento Previo

- Familiaridad con la arquitectura de servicios de Couchbase 7.6 (Data, Query, Index, Search, Analytics, Eventing).
- Comprensión del ciclo de vida de vBuckets, replicación y rebalanceo.
- Experiencia básica con `cbstats`, `cbcollect_info` y la REST API de administración.
- Conocimiento de la estructura de logs: `error.log`, `memcached.log`, `indexer.log`, `query.log`.
- Haber completado el Lab 11-00-01 (Grafana + Prometheus operativo).

### Acceso Requerido

- SSH con permisos `sudo` a los tres nodos del clúster (`node1`, `node2`, `node3`).
- Acceso a Couchbase Web Console: `http://node1:8091` con credenciales de administrador.
- `cbbackupmgr` disponible en `node1` (incluido en la instalación Enterprise).
- Directorio de backup con al menos 50 GB disponibles (por ejemplo: `/backup` o montaje NFS/S3).
- Bucket `travel-sample` cargado y bucket `transactions` con datos de prueba generados.

---

## Entorno de Laboratorio

### Infraestructura

| Componente         | Especificación mínima                              |
|--------------------|----------------------------------------------------|
| Nodos del clúster  | 3 VMs: `node1`, `node2`, `node3`                   |
| CPU por nodo       | 8 vCPUs                                            |
| RAM por nodo       | 16 GB                                              |
| Almacenamiento     | 100 GB SSD por nodo                                |
| Almacenamiento backup | 50 GB en `/backup` (separado o NFS)             |
| Red inter-nodo     | < 5 ms latencia, ≥ 1 Gbps                          |
| Nodo cliente       | 1 VM con 4 vCPUs, 8 GB RAM para generación de carga|

### Software

| Herramienta         | Versión       | Ubicación                        |
|---------------------|---------------|----------------------------------|
| Couchbase Server EE | 7.6.x         | `/opt/couchbase`                 |
| cbbackupmgr         | 7.6.x         | `/opt/couchbase/bin/cbbackupmgr` |
| cbstats             | 7.6.x         | `/opt/couchbase/bin/cbstats`     |
| cbcollect_info      | 7.6.x         | `/opt/couchbase/bin/cbcollect_info` |
| curl                | 7.x+          | Sistema operativo                |
| jq                  | 1.6+          | Sistema operativo                |
| cbq                 | 7.6.x         | `/opt/couchbase/bin/cbq`         |

### Comandos de Configuración Inicial

Ejecutar desde `node1` antes de iniciar los bloques:

```bash
# Verificar que el clúster esté saludable y los tres nodos activos
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status, clusterMembership}'

# Verificar buckets disponibles
curl -s -u admin:password http://localhost:8091/pools/default/buckets \
  | jq '.[].name'

# Crear directorio de backup si no existe
sudo mkdir -p /backup/cb-repo
sudo chown -R couchbase:couchbase /backup

# Cargar travel-sample si no está presente
/opt/couchbase/bin/cbdocloader \
  -u admin -p password \
  -n localhost:8091 \
  -b travel-sample \
  -s 200 \
  /opt/couchbase/samples/travel-sample.zip

# Crear bucket "transactions" para los ejercicios de la práctica
curl -s -u admin:password -X POST \
  http://localhost:8091/pools/default/buckets \
  -d 'name=transactions&ramQuota=512&bucketType=couchbase&replicaNumber=1'

# Generar 50,000 documentos de prueba en el bucket transactions
/opt/couchbase/bin/cbworkloadgen \
  -n localhost:8091 \
  -u admin -p password \
  -b transactions \
  --items=50000 \
  --prefix=txn- \
  --ratio-sets=1.0

echo "=== Entorno listo. Iniciando práctica ==="
```

---

## Instrucciones Paso a Paso

---

### BLOQUE 1 — Diagnóstico y Troubleshooting (18 minutos)

**Objetivo del bloque:** Aplicar la metodología estructurada de seis etapas para diagnosticar dos fallos inyectados en el clúster y documentar el proceso completo como un incidente formal.

---

#### Paso 1.1 — Inyección de Fallo 1: Presión de Memoria en el Bucket `transactions`

**Objetivo:** Simular un nodo bajo presión de memoria para practicar la etapa de Observar y Delimitar.

**Instrucciones:**

1. Desde el nodo cliente, inyectar una carga masiva de datos para saturar la memoria del bucket `transactions`:

```bash
# Inyectar 200,000 documentos adicionales para crear presión de memoria
# Ejecutar desde el nodo cliente o node1
/opt/couchbase/bin/cbc-pillowfight \
  --spec couchbase://node1/transactions \
  --username admin \
  --password password \
  --num-items 200000 \
  --num-threads 8 \
  --set-pct 100 \
  --min-size 1024 \
  --max-size 4096 \
  --duration 120 &

PILLOWFIGHT_PID=$!
echo "Pillowfight iniciado con PID: $PILLOWFIGHT_PID"
```

2. Mientras la carga se ejecuta, observar el estado del clúster:

```bash
# ETAPA 1 - OBSERVAR: Revisar alertas activas en el clúster
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.alerts'

# Verificar el estado de memoria de todos los nodos
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, memoryFree, memoryTotal, status}'
```

3. Delimitar el alcance del problema:

```bash
# ETAPA 2 - DELIMITAR: Identificar qué bucket está bajo presión
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions/stats \
  | jq '.op.samples | {
      vb_active_resident_items_ratio: .vb_active_resident_items_ratio[-1],
      ep_bg_fetched: .ep_bg_fetched[-1],
      ep_tmp_oom_errors: .ep_tmp_oom_errors[-1],
      ep_queue_size: .ep_queue_size[-1],
      mem_used: .mem_used[-1]
    }'
```

4. Formular y documentar hipótesis:

```bash
# ETAPA 3 - FORMULAR HIPÓTESIS: Registrar en archivo de incidente
cat > /tmp/incident-001.txt << 'EOF'
=== INCIDENTE-001: Presión de Memoria en Bucket transactions ===
Timestamp inicio: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Síntoma observado: Errores TMPFAIL en escrituras + latencia elevada en KV
Alcance: Bucket transactions, Data Service, todos los nodos

HIPÓTESIS (ordenadas por probabilidad):
H1 (ALTA): Resident ratio < 40% por exceso de datos vs RAM asignada.
           Verificar: vb_active_resident_items_ratio y ep_bg_fetched
H2 (MEDIA): Cola de escritura saturada (ep_queue_size > 500K ítems).
            Verificar: ep_queue_size y ep_tmp_oom_errors
H3 (BAJA): Problema de red entre cliente y nodos de datos.
           Verificar: Solo si H1 y H2 se descartan
EOF
echo "Hipótesis documentadas en /tmp/incident-001.txt"
```

5. Probar las hipótesis:

```bash
# ETAPA 4 - PROBAR H1: Verificar resident ratio
echo "=== Verificando Hipótesis H1: Resident Ratio ==="
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions/stats \
  | jq '.op.samples | {
      "resident_ratio_pct": .vb_active_resident_items_ratio[-1],
      "bg_fetches_per_sec": .ep_bg_fetched[-1]
    }'

# PROBAR H1 con cbstats para detalle de vBuckets
/opt/couchbase/bin/cbstats \
  localhost:11210 \
  -u admin -p password \
  -b transactions \
  all | grep -E "ep_num_non_resident|ep_bg_fetched|vb_active_resident_items_ratio"

# PROBAR H2: Verificar cola de escritura
echo "=== Verificando Hipótesis H2: Cola de Escritura ==="
/opt/couchbase/bin/cbstats \
  localhost:11210 \
  -u admin -p password \
  -b transactions \
  all | grep -E "ep_queue_size|ep_tmp_oom_errors|ep_diskqueue"
```

6. Detener la inyección de carga y aplicar remediación:

```bash
# Detener pillowfight
kill $PILLOWFIGHT_PID 2>/dev/null || true

# ETAPA 5 - CORREGIR: Aumentar la cuota de RAM del bucket si el resident ratio < 40%
# Primero verificar el valor actual
CURRENT_QUOTA=$(curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions \
  | jq '.quota.ram / 1048576')
echo "Cuota actual: ${CURRENT_QUOTA} MB"

# Aumentar cuota de RAM a 1024 MB para aliviar la presión
curl -s -u admin:password -X POST \
  http://localhost:8091/pools/default/buckets/transactions \
  -d 'ramQuota=1024'

echo "Cuota de RAM actualizada a 1024 MB"
```

**Salida Esperada:**

```
# Para el estado de nodos:
{
  "hostname": "node1:8091",
  "status": "healthy",
  "memoryFree": 2147483648,
  "memoryTotal": 17179869184
}

# Para las métricas del bucket bajo presión:
{
  "resident_ratio_pct": 32.5,      # < 40% confirma H1
  "bg_fetches_per_sec": 1250       # Fetches elevados confirman lectura desde disco
}
```

**Verificación:**

```bash
# ETAPA 6 - VERIFICAR: Confirmar que el resident ratio se recupera
sleep 30
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions/stats \
  | jq '.op.samples | {
      "resident_ratio_pct": .vb_active_resident_items_ratio[-1],
      "ep_tmp_oom_errors": .ep_tmp_oom_errors[-1]
    }'
# Esperado: resident_ratio_pct subiendo, ep_tmp_oom_errors = 0
```

---

#### Paso 1.2 — Inyección de Fallo 2: Índice en Estado Degradado

**Objetivo:** Diagnosticar un índice con fallo de construcción usando logs y la REST API del Index Service.

**Instrucciones:**

1. Crear un índice con una expresión intencionalmente problemática para simular el fallo:

```bash
# Crear un índice que fallará durante la construcción
# (uso de función inexistente para simular error de compilación)
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="CREATE INDEX idx_broken ON \`transactions\`(BROKEN_FUNC(type)) WITH {\"defer_build\":true};"

# Intentar construir el índice (fallará)
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="BUILD INDEX ON \`transactions\`(idx_broken);"
```

2. Observar el estado de los índices:

```bash
# ETAPA 1 - OBSERVAR: Revisar estado de todos los índices
echo "=== Estado de índices via REST API ==="
curl -s -u admin:password \
  http://localhost:8091/indexStatus \
  | jq '.indexes[] | {name, status, bucket, lastScanTime}'

# Verificar específicamente el índice degradado
curl -s -u admin:password \
  http://localhost:8091/indexStatus \
  | jq '.indexes[] | select(.status != "Ready") | {name, status, bucket, definition}'
```

3. Revisar los logs del Index Service para correlacionar el error:

```bash
# ETAPA 4 - PROBAR: Revisar indexer.log para el error específico
echo "=== Revisando indexer.log para errores recientes ==="
sudo tail -100 /opt/couchbase/var/lib/couchbase/logs/indexer.log \
  | grep -E "ERROR|WARN|idx_broken" \
  | tail -20

# Revisar error.log del clúster
sudo tail -50 /opt/couchbase/var/lib/couchbase/logs/error.log \
  | grep -iE "index|error" | tail -10

# Verificar el log de queries para el intento de BUILD INDEX
sudo tail -50 /opt/couchbase/var/lib/couchbase/logs/query.log \
  | grep -iE "BUILD INDEX|idx_broken|error" | tail -10
```

4. Formular hipótesis y diagnosticar:

```bash
# Consultar el estado detallado del índice problemático
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT name, state, progress FROM system:indexes WHERE name = 'idx_broken';"
```

5. Remediar: eliminar el índice degradado y crear uno correcto:

```bash
# ETAPA 5 - CORREGIR: Eliminar el índice roto
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="DROP INDEX \`transactions\`.\`idx_broken\`;"

# Crear el índice correcto
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="CREATE INDEX idx_transactions_type ON \`transactions\`(type) WITH {\"num_replica\":1};"

echo "Índice correcto creado. Esperando construcción..."
sleep 15
```

**Salida Esperada:**

```json
# Estado del índice degradado:
{
  "name": "idx_broken",
  "status": "Error",
  "bucket": "transactions"
}

# Tras la corrección:
{
  "name": "idx_transactions_type",
  "status": "Ready",
  "bucket": "transactions"
}
```

**Verificación:**

```bash
# ETAPA 6 - VERIFICAR: Confirmar que el nuevo índice está operativo
curl -s -u admin:password \
  http://localhost:8091/indexStatus \
  | jq '.indexes[] | select(.name == "idx_transactions_type") | {name, status}'

# Verificar que el índice es utilizado en una consulta
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="EXPLAIN SELECT * FROM \`transactions\` WHERE type = 'payment' LIMIT 10;"
```

---

#### Paso 1.3 — Recolección de Diagnóstico Completo con `cbcollect_info`

**Objetivo:** Recopilar el paquete de diagnóstico completo del nodo para correlacionar timestamps.

**Instrucciones:**

1. Ejecutar `cbcollect_info` en `node1`:

```bash
# Recolectar diagnóstico completo (puede tardar 2-3 minutos)
echo "Iniciando recolección de diagnóstico en $(date -u)"
sudo /opt/couchbase/bin/cbcollect_info \
  /tmp/cbcollect_node1_$(date +%Y%m%d_%H%M%S).zip \
  --log-redaction-level partial

echo "Diagnóstico recolectado en /tmp/cbcollect_node1_*.zip"
ls -lh /tmp/cbcollect_node1_*.zip
```

2. Correlacionar timestamps de alertas con entradas de log:

```bash
# Obtener timestamp de las alertas activas
ALERT_TIME=$(curl -s -u admin:password \
  http://localhost:8091/pools/default \
  | jq -r '.alerts[0] // "No hay alertas activas"')
echo "Alerta más reciente: $ALERT_TIME"

# Buscar entradas de log en la ventana de tiempo del incidente
INCIDENT_TIME=$(date -u -d "30 minutes ago" +"%Y-%m-%dT%H:%M")
echo "Buscando entradas desde: $INCIDENT_TIME"

sudo grep "$INCIDENT_TIME" \
  /opt/couchbase/var/lib/couchbase/logs/memcached.log \
  | grep -iE "warning|error|oom" | head -20
```

**Salida Esperada:**

```
Iniciando recolección de diagnóstico en 2024-01-15T10:30:00Z
Diagnóstico recolectado en /tmp/cbcollect_node1_20240115_103000.zip
-rw-r--r-- 1 root root 45M Jan 15 10:32 /tmp/cbcollect_node1_20240115_103000.zip
```

**Verificación:**

```bash
# Verificar que el archivo de diagnóstico contiene los logs esperados
unzip -l /tmp/cbcollect_node1_*.zip | grep -E "error.log|memcached.log|indexer.log"
```

---

### BLOQUE 2 — Backup, Restore y Validación (15 minutos)

**Objetivo del bloque:** Ejecutar un ciclo completo de backup y restore con `cbbackupmgr`, simular pérdida de datos, restaurar selectivamente y validar la integridad mediante SQL++.

---

#### Paso 2.1 — Configurar el Repositorio de Backup

**Objetivo:** Inicializar el repositorio de backup con `cbbackupmgr config`.

**Instrucciones:**

1. Configurar el repositorio:

```bash
# Configurar repositorio de backup para el bucket transactions
/opt/couchbase/bin/cbbackupmgr config \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --include-buckets transactions,travel-sample

echo "Repositorio configurado en /backup/cb-repo/lab13-backup"

# Verificar la configuración del repositorio
/opt/couchbase/bin/cbbackupmgr info \
  --archive /backup/cb-repo \
  --repo lab13-backup
```

**Salida Esperada:**

```
Name         | Size | # Backups
lab13-backup | 0 B  | 0
```

---

#### Paso 2.2 — Ejecutar Backup Completo y Registrar Estado Pre-Pérdida

**Objetivo:** Realizar el backup completo y documentar el estado de los datos antes de simular la pérdida.

**Instrucciones:**

1. Registrar el estado actual de los datos (pre-pérdida):

```bash
# Contar documentos en el bucket transactions ANTES del backup
echo "=== Estado PRE-BACKUP ==="
PRE_COUNT=$(/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;" \
  | jq -r '.results[0].total')
echo "Total documentos pre-backup: $PRE_COUNT"

# Registrar rango de IDs para verificación posterior
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT MIN(META().id) as min_id, MAX(META().id) as max_id FROM \`transactions\`;"
```

2. Ejecutar el backup completo:

```bash
# Registrar tiempo de inicio del backup
BACKUP_START=$(date +%s)
echo "Backup iniciado: $(date -u)"

# Ejecutar backup completo
/opt/couchbase/bin/cbbackupmgr backup \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --cluster couchbase://localhost \
  --username admin \
  --password password \
  --full-backup

BACKUP_END=$(date +%s)
BACKUP_DURATION=$((BACKUP_END - BACKUP_START))
echo "Backup completado en ${BACKUP_DURATION} segundos"

# Verificar que el backup se creó correctamente
/opt/couchbase/bin/cbbackupmgr info \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --json | jq '.backups[] | {date, size, type}'
```

**Salida Esperada:**

```
=== Estado PRE-BACKUP ===
Total documentos pre-backup: 250000

Backup iniciado: 2024-01-15T10:35:00Z
Backup completado en 45 segundos

{
  "date": "2024-01-15T10:35:45Z",
  "size": "285 MB",
  "type": "FULL"
}
```

---

#### Paso 2.3 — Simular Pérdida de Datos y Ejecutar Restore Selectivo

**Objetivo:** Eliminar un rango de documentos y restaurarlos desde el backup.

**Instrucciones:**

1. Simular la pérdida de datos eliminando 10,000 documentos de un rango conocido:

```bash
# Identificar el rango de IDs a eliminar (prefijo txn-)
echo "=== Simulando pérdida de datos ==="
LOSS_START=$(date +%s)

/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="DELETE FROM \`transactions\` WHERE META().id LIKE 'txn-%' LIMIT 10000;"

LOSS_END=$(date +%s)

# Verificar la pérdida
POST_DELETE_COUNT=$(/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;" \
  | jq -r '.results[0].total')

echo "Documentos después de la pérdida: $POST_DELETE_COUNT"
echo "Documentos eliminados: $((PRE_COUNT - POST_DELETE_COUNT))"
```

2. Ejecutar restore selectivo del bucket `transactions`:

```bash
# Registrar tiempo de inicio del restore
RESTORE_START=$(date +%s)
echo "Restore iniciado: $(date -u)"

# Ejecutar restore selectivo (solo el bucket transactions)
/opt/couchbase/bin/cbbackupmgr restore \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --cluster couchbase://localhost \
  --username admin \
  --password password \
  --include-buckets transactions \
  --force-updates

RESTORE_END=$(date +%s)
RTO_SECONDS=$((RESTORE_END - RESTORE_START))
echo "Restore completado en ${RTO_SECONDS} segundos"
echo "RTO medido: ${RTO_SECONDS} segundos ($(echo "scale=1; $RTO_SECONDS/60" | bc) minutos)"
```

3. Validar la recuperación mediante SQL++:

```bash
# Esperar a que los datos sean indexados
sleep 10

echo "=== Validación Post-Restore ==="

# Contar documentos restaurados
POST_RESTORE_COUNT=$(/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;" \
  | jq -r '.results[0].total')

echo "Documentos pre-backup:  $PRE_COUNT"
echo "Documentos post-delete: $POST_DELETE_COUNT"
echo "Documentos post-restore: $POST_RESTORE_COUNT"

# Verificar integridad: el conteo debe ser igual al pre-backup
if [ "$POST_RESTORE_COUNT" -eq "$PRE_COUNT" ]; then
  echo "✅ VALIDACIÓN EXITOSA: Los datos fueron restaurados completamente."
else
  DIFF=$((PRE_COUNT - POST_RESTORE_COUNT))
  echo "⚠️  ADVERTENCIA: Diferencia de $DIFF documentos. Verificar manualmente."
fi

# Verificar documentos con prefijo txn- específicamente
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as txn_count FROM \`transactions\` WHERE META().id LIKE 'txn-%';"
```

4. Documentar el RTO y RPO:

```bash
# Documentar métricas de recuperación
cat >> /tmp/incident-001.txt << EOF

=== MÉTRICAS DE RECUPERACIÓN (BLOQUE 2) ===
Duración del backup: ${BACKUP_DURATION} segundos
Documentos en backup: ${PRE_COUNT}
Documentos perdidos (simulados): $((PRE_COUNT - POST_DELETE_COUNT))
RTO medido (tiempo de restore): ${RTO_SECONDS} segundos
RPO implícito: Tiempo desde el último backup completo hasta el incidente
               (en este escenario: ~5 minutos de práctica = RPO máximo)
Validación de integridad: $([ "$POST_RESTORE_COUNT" -eq "$PRE_COUNT" ] && echo "EXITOSA" || echo "FALLIDA")
EOF
echo "Métricas de recuperación documentadas."
```

**Salida Esperada:**

```
=== Validación Post-Restore ===
Documentos pre-backup:   250000
Documentos post-delete:  240000
Documentos post-restore: 250000
✅ VALIDACIÓN EXITOSA: Los datos fueron restaurados completamente.
RTO medido: 38 segundos (0.6 minutos)
```

**Verificación:**

```bash
# Verificación final de integridad con consulta de muestra
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT META().id, * FROM \`transactions\` WHERE META().id LIKE 'txn-%' LIMIT 5;"
```

---

### BLOQUE 3 — Rolling Upgrade Simulado y Rollback (10 minutos)

**Objetivo del bloque:** Simular el proceso de rolling upgrade de un nodo del clúster documentando cada punto de verificación y el procedimiento de rollback.

---

#### Paso 3.1 — Preparación y Evacuación del Nodo

**Objetivo:** Evacuar `node3` del clúster de forma controlada antes del upgrade simulado.

**Instrucciones:**

1. Verificar el estado inicial del clúster:

```bash
echo "=== Estado del clúster ANTES del rolling upgrade ==="
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status, clusterMembership, version}'

# Obtener el OTP name del node3 para el rebalance
NODE3_OTP=$(curl -s -u admin:password \
  http://localhost:8091/pools/default \
  | jq -r '.nodes[] | select(.hostname | contains("node3")) | .otpNode')
echo "OTP name de node3: $NODE3_OTP"
```

2. Iniciar el rebalance para evacuar `node3` (failover graceful):

```bash
echo "=== PASO 1: Evacuando node3 del clúster ==="
EVACUATE_START=$(date +%s)

# Ejecutar failover graceful de node3
curl -s -u admin:password -X POST \
  http://localhost:8091/controller/startGracefulFailover \
  -d "otpNode=$NODE3_OTP"

echo "Failover graceful iniciado para $NODE3_OTP"

# Monitorear el progreso del rebalance
echo "Monitoreando progreso del rebalance..."
for i in $(seq 1 12); do
  PROGRESS=$(curl -s -u admin:password \
    http://localhost:8091/pools/default/rebalanceProgress \
    | jq -r '.status // "unknown"')
  echo "  [$(date +%H:%M:%S)] Estado del rebalance: $PROGRESS"
  [ "$PROGRESS" = "none" ] && break
  sleep 10
done

EVACUATE_END=$(date +%s)
echo "Evacuación completada en $((EVACUATE_END - EVACUATE_START)) segundos"
```

3. Verificar que el clúster opera con 2 nodos activos:

```bash
# Verificar estado del clúster con node3 evacuado
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, clusterMembership, status}'

# Confirmar que los buckets siguen accesibles
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;"
```

---

#### Paso 3.2 — Simulación del Upgrade del Nodo

**Objetivo:** Simular el proceso de upgrade del binario en `node3`.

**Instrucciones:**

1. Simular el upgrade (en un entorno real se instalaría el nuevo paquete):

```bash
echo "=== PASO 2: Simulando upgrade en node3 ==="

# En un entorno real, aquí se ejecutaría:
# ssh node3 "sudo systemctl stop couchbase-server"
# ssh node3 "sudo rpm -U couchbase-server-enterprise-7.6.x.rpm"  # o apt
# ssh node3 "sudo systemctl start couchbase-server"

# Para la simulación, reiniciar el servicio en node3 para simular el proceso
ssh -o StrictHostKeyChecking=no node3 \
  "sudo systemctl restart couchbase-server && echo 'Servicio reiniciado en node3'"

# Esperar a que el servicio esté disponible
echo "Esperando que node3 esté disponible..."
for i in $(seq 1 12); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    http://node3:8091/pools/default 2>/dev/null)
  echo "  [$(date +%H:%M:%S)] HTTP status node3: $STATUS"
  [ "$STATUS" = "200" ] && { echo "node3 disponible"; break; }
  sleep 10
done
```

2. Verificar compatibilidad antes de re-incorporar:

```bash
echo "=== PUNTO DE VERIFICACIÓN DE COMPATIBILIDAD ==="

# Verificar versión del nodo actualizado
NODE3_VERSION=$(curl -s -u admin:password \
  http://node3:8091/pools/default \
  | jq -r '.nodes[0].version // "no disponible"')
echo "Versión en node3: $NODE3_VERSION"

# Verificar versión del clúster activo
CLUSTER_VERSION=$(curl -s -u admin:password \
  http://localhost:8091/pools/default \
  | jq -r '.nodes[0].version')
echo "Versión del clúster: $CLUSTER_VERSION"

# Verificar compatibilidad (deben ser la misma versión major.minor)
echo "Checklist de compatibilidad:"
echo "  [ ] Versión de node3 compatible con el clúster: $NODE3_VERSION vs $CLUSTER_VERSION"
echo "  [ ] Configuración de buckets preservada"
echo "  [ ] Logs de node3 sin errores críticos post-restart"

# Revisar logs de node3 para errores
ssh node3 "sudo tail -20 /opt/couchbase/var/lib/couchbase/logs/error.log" \
  | grep -iE "error|fatal|crash" | head -5 || echo "  ✅ Sin errores críticos en node3"
```

---

#### Paso 3.3 — Re-incorporación del Nodo y Rebalance Final

**Objetivo:** Re-agregar `node3` al clúster y ejecutar el rebalance final.

**Instrucciones:**

1. Re-incorporar `node3` al clúster:

```bash
echo "=== PASO 3: Re-incorporando node3 al clúster ==="

# Agregar node3 de vuelta al clúster
curl -s -u admin:password -X POST \
  http://localhost:8091/controller/addNode \
  -d "hostname=node3&user=admin&password=password&services=kv,n1ql,index,fts"

echo "node3 agregado. Iniciando rebalance final..."

# Obtener lista de nodos conocidos para el rebalance
KNOWN_NODES=$(curl -s -u admin:password \
  http://localhost:8091/pools/default \
  | jq -r '[.nodes[].otpNode] | join(",")')
echo "Nodos para rebalance: $KNOWN_NODES"

# Ejecutar rebalance final
REBALANCE_START=$(date +%s)
curl -s -u admin:password -X POST \
  http://localhost:8091/controller/rebalance \
  -d "knownNodes=$KNOWN_NODES&ejectedNodes="

# Monitorear el rebalance
echo "Monitoreando rebalance final..."
for i in $(seq 1 18); do
  REBALANCE_STATUS=$(curl -s -u admin:password \
    http://localhost:8091/pools/default/rebalanceProgress \
    | jq '{status: .status, progress: (.perNode // {} | to_entries | map(.value.progress // 0) | add / length // 0)}')
  echo "  [$(date +%H:%M:%S)] $REBALANCE_STATUS"
  STATUS=$(echo $REBALANCE_STATUS | jq -r '.status')
  [ "$STATUS" = "none" ] && break
  sleep 10
done

REBALANCE_END=$(date +%s)
echo "Rebalance completado en $((REBALANCE_END - REBALANCE_START)) segundos"
```

2. Verificar el estado final del clúster:

```bash
echo "=== Verificación final post-rolling-upgrade ==="

# Estado de todos los nodos
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status, clusterMembership, version}'

# Verificar que todos los servicios están operativos
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions/stats \
  | jq '.op.samples | {
      "ops_per_sec": .ops[-1],
      "resident_ratio": .vb_active_resident_items_ratio[-1]
    }'
```

3. Documentar el procedimiento de rollback:

```bash
cat >> /tmp/incident-001.txt << 'EOF'

=== PROCEDIMIENTO DE ROLLBACK (si el upgrade fallara) ===
CONDICIÓN DE ACTIVACIÓN: node3 no responde después del restart, o versión incompatible

PASOS DE ROLLBACK:
1. Si node3 no responde en 5 minutos post-restart:
   curl -u admin:password -X POST http://localhost:8091/controller/failOver \
     -d "otpNode=<NODE3_OTP>&allowUnsafe=false"

2. Remover node3 del clúster permanentemente:
   curl -u admin:password -X POST http://localhost:8091/controller/rebalance \
     -d "ejectedNodes=<NODE3_OTP>&knownNodes=<ALL_NODES>"

3. Restaurar el binario anterior en node3:
   ssh node3 "sudo rpm -U --oldpackage couchbase-server-enterprise-PREVIOUS.rpm"

4. Re-agregar node3 con la versión anterior y ejecutar rebalance.

CRITERIO DE ÉXITO DEL ROLLBACK:
   - Clúster operativo con 2 nodos (node1, node2) sin pérdida de datos.
   - Todos los vBuckets activos y réplicas distribuidas.
   - Métricas de latencia KV dentro de los umbrales normales.
EOF
echo "Procedimiento de rollback documentado."
```

**Salida Esperada:**

```json
// Estado final del clúster (todos los nodos healthy):
{"hostname": "node1:8091", "status": "healthy", "clusterMembership": "active"}
{"hostname": "node2:8091", "status": "healthy", "clusterMembership": "active"}
{"hostname": "node3:8091", "status": "healthy", "clusterMembership": "active"}
```

**Verificación:**

```bash
# Verificación de integridad post-rebalance
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;"

# Verificar distribución de vBuckets en node3
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions \
  | jq '.vBucketServerMap.serverList'
```

---

### BLOQUE 4 — Construcción del Runbook Operativo (5 minutos)

**Objetivo del bloque:** Compilar todos los hallazgos de los bloques anteriores en un runbook operativo completo, ejecutable por un operador que no estuvo presente en el incidente.

---

#### Paso 4.1 — Generar el Runbook Completo

**Instrucciones:**

1. Compilar el runbook final con toda la información recopilada:

```bash
# Generar el runbook operativo completo
RUNBOOK_FILE="/tmp/runbook-lab13-$(date +%Y%m%d).md"

cat > $RUNBOOK_FILE << 'RUNBOOK_EOF'
# Runbook Operativo: Diagnóstico, Recuperación y Mantenimiento del Clúster Couchbase
**Versión:** 1.0 | **Fecha:** $(date +%Y-%m-%d) | **Autor:** [Nombre del Operador]
**Clúster:** lab-cluster-3nodes | **CB Version:** 7.6.x

---

## INCIDENTE-001: Presión de Memoria en Bucket (Data Service)

### Descripción del Incidente
Errores TMPFAIL en operaciones de escritura durante picos de carga. El bucket
`transactions` excedió su cuota de RAM asignada, causando que el resident ratio
cayera por debajo del 40% y generando fetches masivos desde disco.

### Síntomas Observables
- Errores `TMPFAIL` / `ENOMEM` reportados por el SDK del cliente.
- Latencia P99 de operaciones KV > 100 ms.
- Alertas en Couchbase Web Console: "Bucket memory usage high".
- Grafana: `kv_ep_bg_fetched` con picos sostenidos.

### Métricas de Diagnóstico Relevantes
| Métrica | Umbral Normal | Valor en Incidente |
|---------|--------------|-------------------|
| `vb_active_resident_items_ratio` | > 80% | < 40% |
| `ep_bg_fetched` | < 100/s | > 1000/s |
| `ep_tmp_oom_errors` | 0 | > 500 |
| `ep_queue_size` | < 100K | > 500K |

### Pasos de Diagnóstico Ordenados

**Paso 1 — Verificar estado del clúster:**
```bash
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status}'
```

**Paso 2 — Identificar bucket con presión:**
```bash
curl -s -u admin:password \
  http://localhost:8091/pools/default/buckets/transactions/stats \
  | jq '.op.samples | {vb_active_resident_items_ratio: .vb_active_resident_items_ratio[-1]}'
```

**Paso 3 — Confirmar con cbstats:**
```bash
/opt/couchbase/bin/cbstats localhost:11210 \
  -u admin -p password -b transactions all \
  | grep -E "ep_num_non_resident|ep_bg_fetched"
```

### Comandos de Remediación
```bash
# Aumentar cuota de RAM del bucket afectado
curl -u admin:password -X POST \
  http://localhost:8091/pools/default/buckets/transactions \
  -d 'ramQuota=1024'

# Alternativa: reducir la carga del cliente con backpressure
# Configurar max_parallelism en el cliente SDK
```

### Criterios de Verificación de Resolución
- `vb_active_resident_items_ratio` > 70% y en tendencia ascendente.
- `ep_tmp_oom_errors` = 0 durante 5 minutos consecutivos.
- Latencia P99 KV < 10 ms.

### Acciones Preventivas
- Configurar alerta en Grafana: `vb_active_resident_items_ratio < 60%`.
- Revisar tendencia de crecimiento del bucket mensualmente.
- Establecer cuota de RAM con margen del 30% sobre el working set esperado.

---

## INCIDENTE-002: Índice en Estado Degradado (Index Service)

### Descripción del Incidente
Índice GSI en estado `Error` por fallo durante la construcción. Las consultas
que dependían del índice degradaron a full scan, aumentando la latencia de queries.

### Síntomas Observables
- Índice en estado `Error` o `Building` por más de 10 minutos.
- Alertas en `/indexStatus` con status != "Ready".
- Queries con tiempos de ejecución anómalos (full scan).
- Entradas de ERROR en `/opt/couchbase/var/lib/couchbase/logs/indexer.log`.

### Pasos de Diagnóstico Ordenados

**Paso 1 — Identificar índices degradados:**
```bash
curl -s -u admin:password http://localhost:8091/indexStatus \
  | jq '.indexes[] | select(.status != "Ready") | {name, status, bucket}'
```

**Paso 2 — Revisar logs del indexer:**
```bash
sudo tail -100 /opt/couchbase/var/lib/couchbase/logs/indexer.log \
  | grep -E "ERROR|WARN" | tail -20
```

**Paso 3 — Verificar estado en system:indexes:**
```bash
/opt/couchbase/bin/cbq -u admin -p password \
  --script="SELECT name, state FROM system:indexes WHERE state != 'online';"
```

### Comandos de Remediación
```bash
# Eliminar el índice degradado
/opt/couchbase/bin/cbq -u admin -p password \
  --script="DROP INDEX \`bucket_name\`.\`index_name\`;"

# Recrear el índice correctamente
/opt/couchbase/bin/cbq -u admin -p password \
  --script="CREATE INDEX idx_name ON \`bucket_name\`(field) WITH {\"num_replica\":1};"
```

### Criterios de Verificación de Resolución
- Índice en estado `Ready` en `/indexStatus`.
- EXPLAIN de query relevante muestra uso del índice (no full scan).
- `indexer.log` sin nuevas entradas de ERROR.

### Acciones Preventivas
- Usar `WITH {"defer_build":true}` y validar la expresión antes de BUILD INDEX.
- Monitorear el endpoint `/indexStatus` cada 5 minutos con alerta automática.

---

## PROCEDIMIENTO: Backup y Restore con cbbackupmgr

### Configuración del Repositorio
```bash
/opt/couchbase/bin/cbbackupmgr config \
  --archive /backup/cb-repo \
  --repo NOMBRE_REPO \
  --include-buckets BUCKET1,BUCKET2
```

### Backup Completo
```bash
/opt/couchbase/bin/cbbackupmgr backup \
  --archive /backup/cb-repo \
  --repo NOMBRE_REPO \
  --cluster couchbase://localhost \
  --username admin --password password \
  --full-backup
```

### Restore Selectivo
```bash
/opt/couchbase/bin/cbbackupmgr restore \
  --archive /backup/cb-repo \
  --repo NOMBRE_REPO \
  --cluster couchbase://localhost \
  --username admin --password password \
  --include-buckets BUCKET_AFECTADO \
  --force-updates
```

### Validación Post-Restore
```bash
# Contar documentos y comparar con estado pre-backup
/opt/couchbase/bin/cbq -u admin -p password \
  --script="SELECT COUNT(*) as total FROM \`BUCKET_AFECTADO\`;"
```

### Métricas de Recuperación (Referencia)
- **RTO medido en lab:** ~38 segundos para 250K documentos (285 MB).
- **RPO implícito:** Tiempo transcurrido desde el último backup completo.
- **Frecuencia recomendada de backup:** Full diario + Incremental cada 4 horas.

---

## PROCEDIMIENTO: Rolling Upgrade de Nodo

### Pre-condiciones
- [ ] Backup completo ejecutado y validado.
- [ ] Replicación habilitada en todos los buckets (mínimo 1 réplica).
- [ ] Versión de destino compatible con la versión del clúster.

### Pasos del Rolling Upgrade
```bash
# 1. Failover graceful del nodo a actualizar
curl -u admin:password -X POST \
  http://localhost:8091/controller/startGracefulFailover \
  -d "otpNode=<OTP_NODE>"

# 2. Monitorear rebalance hasta completar
curl -u admin:password \
  http://localhost:8091/pools/default/rebalanceProgress | jq '.status'

# 3. Actualizar el binario (en el nodo evacuado)
# ssh <NODE> "sudo systemctl stop couchbase-server"
# ssh <NODE> "sudo rpm -U couchbase-server-enterprise-NEW.rpm"
# ssh <NODE> "sudo systemctl start couchbase-server"

# 4. Re-agregar el nodo al clúster
curl -u admin:password -X POST \
  http://localhost:8091/controller/addNode \
  -d "hostname=<NODE>&user=admin&password=password&services=kv,n1ql,index,fts"

# 5. Ejecutar rebalance final
curl -u admin:password -X POST \
  http://localhost:8091/controller/rebalance \
  -d "knownNodes=<ALL_NODES>&ejectedNodes="
```

### Procedimiento de Rollback
Si el upgrade falla (nodo no responde en 5 min o versión incompatible):
```bash
# Failover de emergencia del nodo problemático
curl -u admin:password -X POST \
  http://localhost:8091/controller/failOver \
  -d "otpNode=<OTP_NODE>&allowUnsafe=false"

# Remover del clúster y restaurar versión anterior
curl -u admin:password -X POST \
  http://localhost:8091/controller/rebalance \
  -d "ejectedNodes=<OTP_NODE>&knownNodes=<REMAINING_NODES>"
```

RUNBOOK_EOF

# Reemplazar variables de fecha en el runbook
sed -i "s/\$(date +%Y-%m-%d)/$(date +%Y-%m-%d)/g" $RUNBOOK_FILE

echo "✅ Runbook generado: $RUNBOOK_FILE"
wc -l $RUNBOOK_FILE
```

**Salida Esperada:**

```
✅ Runbook generado: /tmp/runbook-lab13-20240115.md
247 /tmp/runbook-lab13-20240115.md
```

**Verificación:**

```bash
# Verificar que el runbook contiene todas las secciones requeridas
echo "=== Verificando secciones del runbook ==="
for SECTION in "Descripción del Incidente" \
               "Síntomas Observables" \
               "Métricas de Diagnóstico" \
               "Pasos de Diagnóstico" \
               "Comandos de Remediación" \
               "Criterios de Verificación" \
               "Acciones Preventivas" \
               "Procedimiento de Rollback"; do
  if grep -q "$SECTION" $RUNBOOK_FILE; then
    echo "  ✅ Sección encontrada: $SECTION"
  else
    echo "  ❌ FALTA sección: $SECTION"
  fi
done
```

---

## Validación y Pruebas Finales

Ejecutar la siguiente secuencia de validación completa al finalizar todos los bloques:

```bash
echo "=============================================="
echo "VALIDACIÓN FINAL - LAB 13-00-01"
echo "Timestamp: $(date -u)"
echo "=============================================="

# 1. Estado del clúster (todos los nodos healthy)
echo ""
echo "--- 1. Estado del Clúster ---"
UNHEALTHY=$(curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '[.nodes[] | select(.status != "healthy")] | length')
[ "$UNHEALTHY" -eq 0 ] \
  && echo "✅ Todos los nodos están healthy" \
  || echo "❌ $UNHEALTHY nodo(s) no están healthy"

# 2. Verificar que los 3 nodos están en el clúster
echo ""
echo "--- 2. Membresía del Clúster ---"
NODE_COUNT=$(curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '[.nodes[] | select(.clusterMembership == "active")] | length')
[ "$NODE_COUNT" -eq 3 ] \
  && echo "✅ Los 3 nodos están activos en el clúster" \
  || echo "⚠️  Solo $NODE_COUNT nodo(s) activos (esperado: 3)"

# 3. Verificar integridad de datos post-restore
echo ""
echo "--- 3. Integridad de Datos (transactions) ---"
FINAL_COUNT=$(/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="SELECT COUNT(*) as total FROM \`transactions\`;" \
  | jq -r '.results[0].total')
echo "Total documentos en transactions: $FINAL_COUNT"
[ "$FINAL_COUNT" -gt 0 ] \
  && echo "✅ Datos accesibles post-restore" \
  || echo "❌ No se encontraron documentos"

# 4. Verificar que el índice correcto está operativo
echo ""
echo "--- 4. Estado de Índices ---"
INDEX_STATUS=$(curl -s -u admin:password \
  http://localhost:8091/indexStatus \
  | jq '[.indexes[] | select(.status != "Ready")] | length')
[ "$INDEX_STATUS" -eq 0 ] \
  && echo "✅ Todos los índices están en estado Ready" \
  || echo "⚠️  $INDEX_STATUS índice(s) no están en estado Ready"

# 5. Verificar que el backup existe y es válido
echo ""
echo "--- 5. Repositorio de Backup ---"
BACKUP_EXISTS=$(/opt/couchbase/bin/cbbackupmgr info \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --json 2>/dev/null | jq '.backups | length')
[ "$BACKUP_EXISTS" -gt 0 ] \
  && echo "✅ Repositorio de backup con $BACKUP_EXISTS backup(s) válido(s)" \
  || echo "❌ No se encontraron backups válidos"

# 6. Verificar que el runbook existe
echo ""
echo "--- 6. Runbook Operativo ---"
RUNBOOK_EXISTS=$(ls /tmp/runbook-lab13-*.md 2>/dev/null | wc -l)
[ "$RUNBOOK_EXISTS" -gt 0 ] \
  && echo "✅ Runbook generado: $(ls /tmp/runbook-lab13-*.md)" \
  || echo "❌ Runbook no encontrado"

echo ""
echo "=============================================="
echo "VALIDACIÓN COMPLETADA"
echo "=============================================="
```

---

## Solución de Problemas

### Problema 1: `cbbackupmgr restore` falla con error "bucket already exists"

**Síntomas:**
```
Error: restore failed: bucket transactions already exists and --force-updates flag is not set
```

**Causa:**
El comando `cbbackupmgr restore` por defecto no sobrescribe datos en buckets existentes. Al intentar restaurar en un bucket que ya contiene documentos sin el flag `--force-updates`, la operación falla como medida de protección.

**Solución:**
```bash
# Opción 1: Usar --force-updates para sobrescribir documentos existentes
/opt/couchbase/bin/cbbackupmgr restore \
  --archive /backup/cb-repo \
  --repo lab13-backup \
  --cluster couchbase://localhost \
  --username admin --password password \
  --include-buckets transactions \
  --force-updates   # <-- Agregar este flag

# Opción 2: Si se necesita un restore limpio, vaciar el bucket primero
curl -u admin:password -X POST \
  http://localhost:8091/pools/default/buckets/transactions/controller/doFlush
# Luego ejecutar restore sin --force-updates
```

---

### Problema 2: El rebalance se detiene con error durante el rolling upgrade

**Síntomas:**
```bash
# Al monitorear el rebalance:
{"status": "notRunning", "errorMessage": "Rebalance failed. See logs for details."}
```

**Causa:**
El rebalance puede fallar si: (a) el nodo recién agregado no tiene conectividad completa con el clúster, (b) hay vBuckets en estado inconsistente previo al rebalance, o (c) la cuota de RAM del bucket excede la memoria disponible en el nuevo nodo después de la redistribución.

**Solución:**
```bash
# Paso 1: Revisar el log de rebalance para identificar la causa exacta
curl -s -u admin:password http://localhost:8091/logs \
  | jq '.list[] | select(.module == "ns_rebalance") | {time, text}' | tail -10

# Paso 2: Verificar conectividad entre nodos
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status, clusterMembership}'

# Paso 3: Verificar que no hay vBuckets en estado inconsistente
/opt/couchbase/bin/cbstats localhost:11210 \
  -u admin -p password -b transactions \
  vbucket | grep -v "active\|replica\|dead" | head -10

# Paso 4: Si la causa es memoria insuficiente, aumentar la cuota antes de reintentar
curl -u admin:password -X POST \
  http://localhost:8091/pools/default/buckets/transactions \
  -d 'ramQuota=512'

# Paso 5: Reintentar el rebalance
KNOWN_NODES=$(curl -s -u admin:password \
  http://localhost:8091/pools/default \
  | jq -r '[.nodes[].otpNode] | join(",")')
curl -u admin:password -X POST \
  http://localhost:8091/controller/rebalance \
  -d "knownNodes=$KNOWN_NODES&ejectedNodes="
```

---

## Limpieza del Entorno

Ejecutar al finalizar la práctica para dejar el entorno en estado inicial:

```bash
echo "=== Iniciando limpieza del entorno ==="

# 1. Eliminar el índice de prueba si existe
/opt/couchbase/bin/cbq \
  -u admin -p password \
  -engine http://localhost:8093 \
  --script="DROP INDEX \`transactions\`.\`idx_transactions_type\` IF EXISTS;" \
  2>/dev/null || true

# 2. Eliminar el repositorio de backup del laboratorio
# NOTA: Comentar esta línea si se desea conservar el backup para referencia
# /opt/couchbase/bin/cbbackupmgr remove \
#   --archive /backup/cb-repo \
#   --repo lab13-backup

# 3. Limpiar archivos temporales del laboratorio
rm -f /tmp/incident-001.txt
rm -f /tmp/cbcollect_node1_*.zip

# 4. Conservar el runbook (mover a ubicación permanente)
sudo mkdir -p /opt/runbooks
sudo cp /tmp/runbook-lab13-*.md /opt/runbooks/
echo "Runbook archivado en /opt/runbooks/"

# 5. Verificar estado final del clúster
echo "=== Estado final del clúster ==="
curl -s -u admin:password http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname, status, clusterMembership}'

echo "=== Limpieza completada ==="
```

---

## Resumen

En esta práctica se aplicó una metodología estructurada de troubleshooting de seis etapas (Observar → Delimitar → Formular hipótesis → Probar → Corregir → Verificar) para diagnosticar y resolver dos fallos simulados en un clúster Couchbase de producción: presión de memoria en el Data Service e índice GSI en estado degradado. La correlación de métricas REST API, salidas de `cbstats` y entradas de log permitió identificar las causas raíz con precisión y aplicar correcciones quirúrgicas y verificables.

El ciclo completo de backup y restore con `cbbackupmgr` demostró la viabilidad de recuperar 250,000 documentos (285 MB) en aproximadamente 38 segundos de RTO, estableciendo una línea base para el dimensionamiento de los objetivos de recuperación. El rolling upgrade simulado ilustró la importancia de los puntos de verificación de compatibilidad y la disponibilidad de un procedimiento de rollback documentado antes de iniciar cualquier operación de mantenimiento en producción.

Finalmente, la compilación de todos los hallazgos en un runbook operativo estructurado garantiza que el conocimiento adquirido durante el incidente sea transferible y reutilizable por cualquier miembro del equipo en incidentes futuros similares.

### Recursos Adicionales

- [Couchbase cbbackupmgr — Documentación oficial](https://docs.couchbase.com/server/current/backup-restore/cbbackupmgr.html)
- [Couchbase — Performing a Rolling Upgrade](https://docs.couchbase.com/server/current/install/upgrade-procedure-selection.html)
- [Couchbase cbstats Reference](https://docs.couchbase.com/server/current/cli/cbstats/cbstats-intro.html)
- [Couchbase cbcollect_info Tool](https://docs.couchbase.com/server/current/cli/cbcollect-info-tool.html)
- [Couchbase REST API — Cluster Statistics](https://docs.couchbase.com/server/current/rest-api/rest-cluster-intro.html)
- [Google SRE Book — Chapter 12: Effective Troubleshooting](https://sre.google/sre-book/effective-troubleshooting/)

---
