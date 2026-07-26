# Despliegue y recuperación de Couchbase en Kubernetes

## Metadatos

| Campo         | Valor                                      |
|---------------|--------------------------------------------|
| **Duración**  | 84 minutos                                 |
| **Complejidad** | Alta (Hard)                              |
| **Nivel Bloom** | Aplicar (Apply)                          |
| **Módulo**    | 10 — Couchbase en Kubernetes               |
| **Versión CAO** | 2.6.x                                   |

---

## Descripción General

En este laboratorio desplegarás un clúster Couchbase de tres nodos en Kubernetes utilizando el **Couchbase Autonomous Operator (CAO) 2.6.x** y sus Custom Resource Definitions (CRDs) nativos. Comenzarás instalando el Operator vía Helm, examinarás los CRDs registrados y crearás un manifiesto `CouchbaseCluster` completo con Multi-Dimensional Scaling (MDS), PersistentVolumeClaims y configuración de buckets declarativa. Finalizarás ejecutando operaciones de escalamiento, simulando fallos de pods para observar la auto-recuperación del Operator y diagnosticando un despliegue deliberadamente mal configurado.

---

## Objetivos de Aprendizaje

- [ ] Desplegar el Couchbase Autonomous Operator en Kubernetes utilizando Helm y verificar el registro de sus CRDs y componentes (Operator Pod y Admission Controller).
- [ ] Crear y aplicar un manifiesto `CouchbaseCluster` con grupos de servidores diferenciados (MDS), PersistentVolumeClaims y configuración de buckets mediante CRDs.
- [ ] Ejecutar operaciones de escalamiento horizontal modificando `spec.servers[].size` y observar el bucle de reconciliación del Operator.
- [ ] Simular el fallo de un pod de Couchbase y verificar la auto-recuperación autónoma del Operator analizando logs y eventos de Kubernetes.
- [ ] Diagnosticar y corregir un despliegue mal configurado interpretando los mensajes del Admission Controller, los logs del Operator y los eventos del clúster.

---

## Prerrequisitos

### Conocimiento Previo

| Área | Nivel Requerido |
|------|----------------|
| Arquitectura Couchbase (Labs 01-00-01 y 08-00-01) | Completados |
| Recursos Kubernetes: Pods, StatefulSets, PVCs, ConfigMaps | Básico-Intermedio |
| Comandos `kubectl` y lectura de manifiestos YAML | Básico |
| Helm 3.x: instalación de charts y gestión de releases | Básico |
| Conceptos del patrón Operator y bucle de reconciliación | Cubiertos en Lección 10.1 |

### Acceso y Herramientas

| Herramienta | Versión | Verificación |
|-------------|---------|--------------|
| Clúster Kubernetes funcional (k3s, minikube o cloud) | 1.28.x+ | `kubectl version` |
| `kubectl` configurado con acceso al clúster | 1.28.x+ | `kubectl cluster-info` |
| Helm | 3.12.x+ | `helm version` |
| `jq` | 1.6+ | `jq --version` |
| `curl` | 7.x+ | `curl --version` |
| Acceso a internet para descargar chart de Helm | — | `curl https://charts.couchbase.com` |

---

## Entorno de Laboratorio

### Topología del Clúster Kubernetes

| Componente | Especificación Mínima |
|------------|----------------------|
| Nodos worker | 3 × (4 vCPUs, 8 GB RAM) |
| Almacenamiento por nodo | 50 GB SSD (PVC) |
| Red inter-nodo | < 5 ms latencia, ≥ 1 Gbps |
| StorageClass disponible | `standard` o `local-path` |

### Namespace y Estructura del Lab

```
Namespace del Operator : couchbase-operator
Namespace del clúster  : couchbase
Nombre del clúster     : cb-lab-cluster
```

### Configuración Inicial del Entorno

Ejecuta los siguientes comandos desde tu terminal de trabajo para preparar el entorno antes de comenzar los pasos del laboratorio:

```bash
# Verificar acceso al clúster Kubernetes
kubectl cluster-info
kubectl get nodes -o wide

# Verificar que Helm está disponible
helm version --short

# Crear los namespaces que utilizará el laboratorio
kubectl create namespace couchbase-operator
kubectl create namespace couchbase

# Verificar que existe una StorageClass disponible
kubectl get storageclass
# Anota el nombre de la StorageClass marcada como (default)
# Si usas k3s: "local-path" | Si usas minikube: "standard"
```

> **Nota para minikube:** Si ejecutas el lab en minikube con recursos limitados, usa `minikube start --cpus=6 --memory=12g --disk-size=60g` para garantizar recursos suficientes.

---

## Pasos del Laboratorio

---

### Paso 1 — Instalación del Couchbase Autonomous Operator vía Helm

**Objetivo:** Instalar el CAO 2.6.x en el namespace `couchbase-operator`, verificar que el Operator Pod y el Admission Controller están en estado `Running`, y examinar los CRDs registrados en el clúster.

**Tiempo estimado:** 12 minutos

#### Instrucciones

1. Agrega el repositorio oficial de Helm de Couchbase y actualiza el índice:

```bash
helm repo add couchbase https://charts.couchbase.com
helm repo update
# Verificar que el repositorio fue agregado correctamente
helm repo list | grep couchbase
```

2. Examina los valores configurables del chart antes de instalarlo:

```bash
helm show values couchbase/couchbase-operator | head -80
```

3. Instala el Operator en el namespace `couchbase-operator`. El flag `--set` configura el Operator para vigilar el namespace `couchbase` donde vivirá el clúster:

```bash
helm install couchbase-operator couchbase/couchbase-operator \
  --namespace couchbase-operator \
  --set cluster.enabled=false \
  --set watchNamespaces="{couchbase}" \
  --version 2.6.3 \
  --wait \
  --timeout 5m
```

> **Nota:** El flag `--set cluster.enabled=false` evita que el chart despliegue un clúster de ejemplo automáticamente. Lo crearemos manualmente en los pasos siguientes.

4. Verifica que el Operator Pod y el Admission Controller están en estado `Running`:

```bash
kubectl get pods -n couchbase-operator -o wide
kubectl get deployment -n couchbase-operator
```

5. Examina los CRDs instalados por el Operator:

```bash
kubectl get crds | grep couchbase.com
```

6. Inspecciona en detalle el CRD `CouchbaseCluster` para entender su estructura:

```bash
kubectl describe crd couchbaseclusters.couchbase.com | head -60
```

7. Verifica los permisos RBAC que el Operator tiene sobre el namespace `couchbase`:

```bash
kubectl describe clusterrole couchbase-operator
```

8. Consulta los logs iniciales del Operator para confirmar que está observando el namespace correcto:

```bash
kubectl logs -n couchbase-operator deployment/couchbase-operator --tail=30
```

#### Salida Esperada

```
# kubectl get pods -n couchbase-operator
NAME                                              READY   STATUS    RESTARTS   AGE
couchbase-operator-7d9f8b6c4-xk9pq               1/1     Running   0          2m
couchbase-operator-admission-6b5f7d8c9-m2nrs      1/1     Running   0          2m

# kubectl get crds | grep couchbase.com
couchbaseautoscalers.couchbase.com          2024-01-01T10:00:00Z
couchbasebackuprestores.couchbase.com       2024-01-01T10:00:00Z
couchbasebackups.couchbase.com              2024-01-01T10:00:00Z
couchbasebuckets.couchbase.com              2024-01-01T10:00:00Z
couchbaseclusters.couchbase.com             2024-01-01T10:00:00Z
couchbasecollections.couchbase.com          2024-01-01T10:00:00Z
couchbaseephemeralbuckets.couchbase.com     2024-01-01T10:00:00Z
couchbasegroups.couchbase.com               2024-01-01T10:00:00Z
couchbasememcachedbuckets.couchbase.com     2024-01-01T10:00:00Z
couchbasemigrationreplications.couchbase.com 2024-01-01T10:00:00Z
couchbaserolebindings.couchbase.com         2024-01-01T10:00:00Z
couchbasescopes.couchbase.com               2024-01-01T10:00:00Z
couchbaseusers.couchbase.com                2024-01-01T10:00:00Z
```

#### Verificación

```bash
# Confirmar que ambos componentes del CAO están Running
kubectl get pods -n couchbase-operator --field-selector=status.phase=Running | wc -l
# Debe retornar 2 (o más si hay réplicas adicionales)

# Confirmar que el webhook de admisión está registrado
kubectl get mutatingwebhookconfigurations | grep couchbase
kubectl get validatingwebhookconfigurations | grep couchbase
```

---

### Paso 2 — Creación del Secret de Credenciales y Configuración de Almacenamiento

**Objetivo:** Crear el Secret de Kubernetes con las credenciales del administrador de Couchbase y verificar la StorageClass disponible para los PersistentVolumeClaims del clúster.

**Tiempo estimado:** 8 minutos

#### Instrucciones

1. Crea el Secret con las credenciales del administrador de Couchbase. El Operator utilizará este Secret para inicializar el clúster:

```bash
kubectl create secret generic cb-admin-credentials \
  --namespace couchbase \
  --from-literal=username=Administrator \
  --from-literal=password=P@ssw0rd2024!

# Verificar que el Secret fue creado
kubectl get secret cb-admin-credentials -n couchbase -o yaml
```

2. Examina la StorageClass disponible en tu clúster y anota su nombre:

```bash
kubectl get storageclass
kubectl describe storageclass $(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}')
```

3. Si tu entorno usa `local-path` (k3s) o `standard` (minikube), crea un alias de variable de entorno para usarlo en los manifiestos:

```bash
# Detectar automáticamente la StorageClass por defecto
export DEFAULT_SC=$(kubectl get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')
echo "StorageClass por defecto: ${DEFAULT_SC}"

# Si no hay StorageClass por defecto detectada, asignar manualmente:
# export DEFAULT_SC="local-path"   # para k3s
# export DEFAULT_SC="standard"     # para minikube
```

4. Crea un manifiesto de prueba para verificar que los PVCs se pueden aprovisionar correctamente:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-test
  namespace: couchbase
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${DEFAULT_SC}
EOF

# Verificar que el PVC fue provisionado (puede tardar 30-60 segundos)
kubectl get pvc pvc-test -n couchbase --watch
# Esperar hasta que el estado sea "Bound", luego Ctrl+C

# Limpiar el PVC de prueba
kubectl delete pvc pvc-test -n couchbase
```

#### Salida Esperada

```
# kubectl get pvc pvc-test -n couchbase
NAME       STATUS   VOLUME                                     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
pvc-test   Bound    pvc-a1b2c3d4-e5f6-7890-abcd-ef1234567890   1Gi        RWO            local-path     15s
```

#### Verificación

```bash
# Confirmar que el Secret existe y tiene las claves correctas
kubectl get secret cb-admin-credentials -n couchbase \
  -o jsonpath='{.data}' | jq 'keys'
# Debe mostrar: ["password", "username"]
```

---

### Paso 3 — Despliegue del CouchbaseCluster con MDS y PersistentVolumeClaims

**Objetivo:** Crear y aplicar un manifiesto `CouchbaseCluster` completo que configure tres grupos de servidores con servicios diferenciados (MDS), PersistentVolumeClaims para persistencia de datos y la declaración de un bucket de trabajo.

**Tiempo estimado:** 20 minutos

#### Instrucciones

1. Crea el manifiesto completo del `CouchbaseCluster`. Guarda el siguiente contenido en el archivo `cb-lab-cluster.yaml`. **Reemplaza `YOUR_STORAGECLASS` con el valor de `${DEFAULT_SC}` obtenido en el Paso 2:**

```bash
cat <<'EOF' > cb-lab-cluster.yaml
# ============================================================
# CouchbaseCluster: cb-lab-cluster
# Topología MDS: Data+Index+Query separados
# Versión: Couchbase Enterprise 7.6.2
# ============================================================
apiVersion: couchbase.com/v2
kind: CouchbaseCluster
metadata:
  name: cb-lab-cluster
  namespace: couchbase
spec:
  # --- Imagen del servidor Couchbase ---
  image: couchbase/server:enterprise-7.6.2

  # --- Referencia al Secret de credenciales ---
  security:
    adminSecret: cb-admin-credentials
    rbac:
      managed: true

  # --- Política de red: exponer la UI y las APIs ---
  networking:
    exposeAdminConsole: true
    adminConsoleServices:
      - data

  # --- Configuración de anti-afinidad para distribuir pods en nodos ---
  antiAffinity: false

  # --- Grupos de servidores (MDS: Multi-Dimensional Scaling) ---
  servers:
    # Grupo 1: Nodos de Data Service
    - name: data-nodes
      size: 2
      services:
        - data
      resources:
        requests:
          cpu: "1"
          memory: "2Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
      volumeMounts:
        default: data-storage
      pod:
        metadata:
          labels:
            couchbase-service: data

    # Grupo 2: Nodo combinado de Index + Query Service
    - name: index-query-nodes
      size: 1
      services:
        - index
        - query
      resources:
        requests:
          cpu: "1"
          memory: "2Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
      volumeMounts:
        default: index-storage
      pod:
        metadata:
          labels:
            couchbase-service: index-query

  # --- Definición de volúmenes de almacenamiento ---
  volumeClaimTemplates:
    - metadata:
        name: data-storage
      spec:
        storageClassName: YOUR_STORAGECLASS
        resources:
          requests:
            storage: 10Gi
        accessModes:
          - ReadWriteOnce

    - metadata:
        name: index-storage
      spec:
        storageClassName: YOUR_STORAGECLASS
        resources:
          requests:
            storage: 5Gi
        accessModes:
          - ReadWriteOnce

  # --- Buckets declarados via CRD ---
  buckets:
    managed: true

  # --- Política de actualización automática ---
  upgradeStrategy: RollingUpgrade

  # --- Hibernación: desactivada ---
  hibernate: false
EOF
echo "Manifiesto creado: cb-lab-cluster.yaml"
```

2. Reemplaza el placeholder `YOUR_STORAGECLASS` con el valor real:

```bash
sed -i "s/YOUR_STORAGECLASS/${DEFAULT_SC}/g" cb-lab-cluster.yaml
# Verificar el reemplazo
grep "storageClassName" cb-lab-cluster.yaml
```

3. Aplica el manifiesto del clúster:

```bash
kubectl apply -f cb-lab-cluster.yaml
# Salida esperada: couchbasecluster.couchbase.com/cb-lab-cluster created
```

4. Crea el recurso `CouchbaseBucket` para el bucket de trabajo del laboratorio:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: couchbase.com/v2
kind: CouchbaseBucket
metadata:
  name: lab-bucket
  namespace: couchbase
spec:
  name: lab-bucket
  type: couchbase
  memoryQuota: 512Mi
  replicas: 1
  ioPriority: high
  evictionPolicy: valueOnly
  conflictResolution: seqno
  enableFlush: true
  enableIndexReplica: false
EOF
```

5. Monitoriza el proceso de reconciliación del Operator en tiempo real. **Abre una segunda terminal** y ejecuta:

```bash
# Terminal 2: Observar pods del clúster Couchbase
kubectl get pods -n couchbase --watch
```

6. En la terminal principal, observa los eventos de Kubernetes relacionados con el despliegue:

```bash
# Esperar 2-3 minutos mientras el Operator crea los pods
kubectl get events -n couchbase --sort-by='.lastTimestamp' | tail -20
```

7. Monitoriza los logs del Operator para ver el bucle de reconciliación en acción:

```bash
kubectl logs -n couchbase-operator deployment/couchbase-operator -f --tail=50
# Observar mensajes como:
# "Reconciling CouchbaseCluster cb-lab-cluster"
# "Creating pod cb-lab-cluster-data-nodes-0000"
# "Adding node to cluster"
# Ctrl+C para salir cuando los pods estén Running
```

8. Verifica el estado del clúster una vez que los pods estén corriendo (puede tardar 5-8 minutos):

```bash
# Verificar pods del clúster
kubectl get pods -n couchbase -o wide

# Verificar PVCs creados automáticamente
kubectl get pvc -n couchbase

# Verificar el estado reportado por el Operator
kubectl get couchbasecluster cb-lab-cluster -n couchbase -o yaml | grep -A 40 "^status:"
```

#### Salida Esperada

```
# kubectl get pods -n couchbase
NAME                                    READY   STATUS    RESTARTS   AGE
cb-lab-cluster-data-nodes-0000          1/1     Running   0          6m
cb-lab-cluster-data-nodes-0001          1/1     Running   0          5m
cb-lab-cluster-index-query-nodes-0000   1/1     Running   0          4m

# kubectl get pvc -n couchbase
NAME                                              STATUS   VOLUME     CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-storage-cb-lab-cluster-data-nodes-0000       Bound    pvc-...    10Gi       RWO            local-path     6m
data-storage-cb-lab-cluster-data-nodes-0001       Bound    pvc-...    10Gi       RWO            local-path     5m
index-storage-cb-lab-cluster-index-query-nodes-0000 Bound  pvc-...    5Gi        RWO            local-path     4m

# Fragmento del status del CouchbaseCluster:
status:
  availableNodes: 3
  conditions:
    - reason: ClusterAvailable
      status: "True"
      type: Available
    - status: "False"
      type: Degraded
  members:
    ready:
      - cb-lab-cluster-data-nodes-0000
      - cb-lab-cluster-data-nodes-0001
      - cb-lab-cluster-index-query-nodes-0000
```

#### Verificación

```bash
# Confirmar que el clúster está Available y no Degraded
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
# Debe retornar: True

# Confirmar que el bucket fue creado
kubectl get couchbasebucket -n couchbase
# Debe mostrar: lab-bucket   True   ...

# Confirmar los 3 nodos disponibles
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.availableNodes}'
# Debe retornar: 3
```

---

### Paso 4 — Acceso a la Consola Web vía Port-Forward

**Objetivo:** Acceder a la consola web de Couchbase utilizando `kubectl port-forward` para verificar visualmente el estado del clúster y confirmar la topología MDS desplegada.

**Tiempo estimado:** 5 minutos

#### Instrucciones

1. Identifica el Service de la consola web creado por el Operator:

```bash
kubectl get services -n couchbase
# Buscar el servicio de tipo NodePort o ClusterIP para la UI
```

2. Establece el port-forward hacia el pod de uno de los nodos Data:

```bash
# Ejecutar en segundo plano o en una terminal separada
kubectl port-forward -n couchbase \
  pod/cb-lab-cluster-data-nodes-0000 \
  8091:8091 &

echo "Consola web disponible en: http://localhost:8091"
```

3. Desde tu navegador, accede a `http://localhost:8091` e inicia sesión con:
   - **Usuario:** `Administrator`
   - **Contraseña:** `P@ssw0rd2024!`

4. Navega a **Servers** y verifica que los 3 nodos están presentes con los servicios correctos:
   - `cb-lab-cluster-data-nodes-0000` y `0001`: servicio **data**
   - `cb-lab-cluster-index-query-nodes-0000`: servicios **index** y **query**

5. Navega a **Buckets** y confirma que `lab-bucket` existe con 512 MB de RAM quota.

6. Consulta la misma información vía REST API para practicar el acceso programático:

```bash
# Verificar nodos del clúster via REST
curl -s -u Administrator:P@ssw0rd2024! \
  http://localhost:8091/pools/nodes | \
  jq '.nodes[] | {hostname: .hostname, services: .services, status: .status}'

# Verificar buckets
curl -s -u Administrator:P@ssw0rd2024! \
  http://localhost:8091/pools/default/buckets | \
  jq '.[] | {name: .name, quota: .quota.ram, replicas: .replicaNumber}'
```

#### Verificación

```bash
# Verificar que los 3 nodos están healthy via REST
curl -s -u Administrator:P@ssw0rd2024! \
  http://localhost:8091/pools/nodes | \
  jq '[.nodes[] | select(.status == "healthy")] | length'
# Debe retornar: 3
```

---

### Paso 5 — Escalamiento Horizontal: Agregar un Nodo Data

**Objetivo:** Ejecutar un scale-out del grupo `data-nodes` modificando `spec.servers[].size` en el `CouchbaseCluster` CRD y observar el proceso completo de reconciliación, incluyendo la incorporación del nuevo nodo y el rebalanceo automático.

**Tiempo estimado:** 12 minutos

#### Instrucciones

1. Observa el estado actual del clúster antes del escalamiento:

```bash
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.spec.servers[?(@.name=="data-nodes")].size}'
# Debe retornar: 2
```

2. Aplica el patch para incrementar el tamaño del grupo `data-nodes` de 2 a 3:

```bash
kubectl patch couchbasecluster cb-lab-cluster \
  --namespace couchbase \
  --type='json' \
  --patch='[{"op": "replace", "path": "/spec/servers/0/size", "value": 3}]'

# Confirmar que el patch fue aplicado
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.spec.servers[?(@.name=="data-nodes")].size}'
# Debe retornar: 3
```

3. Monitoriza el proceso de reconciliación en tiempo real:

```bash
# Terminal: observar pods
kubectl get pods -n couchbase --watch &
WATCH_PID=$!

# Ver los logs del Operator durante la reconciliación
kubectl logs -n couchbase-operator deployment/couchbase-operator -f --tail=20 &
LOG_PID=$!

# Esperar 3-4 minutos observando la creación del nuevo pod
sleep 180

# Detener los procesos en background
kill $WATCH_PID $LOG_PID 2>/dev/null
```

4. Verifica los eventos de Kubernetes generados durante el escalamiento:

```bash
kubectl get events -n couchbase \
  --sort-by='.lastTimestamp' \
  --field-selector reason=Created | tail -10
```

5. Confirma el estado del clúster después del escalamiento:

```bash
kubectl get pods -n couchbase -o wide

kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.availableNodes}'
# Debe retornar: 4

kubectl get pvc -n couchbase | grep data-storage | wc -l
# Debe retornar: 3 (un PVC por nodo data)
```

6. Verifica el rebalanceo automático en la consola web o via REST:

```bash
# Verificar que el rebalanceo fue completado
curl -s -u Administrator:P@ssw0rd2024! \
  http://localhost:8091/pools/default/rebalanceProgress | jq .
# Debe mostrar: {"status": "none"} indicando que no hay rebalanceo en curso
```

#### Salida Esperada

```
# kubectl get pods -n couchbase (después del escalamiento)
NAME                                    READY   STATUS    RESTARTS   AGE
cb-lab-cluster-data-nodes-0000          1/1     Running   0          15m
cb-lab-cluster-data-nodes-0001          1/1     Running   0          14m
cb-lab-cluster-data-nodes-0002          1/1     Running   0          3m   ← NUEVO
cb-lab-cluster-index-query-nodes-0000   1/1     Running   0          13m

# Logs del Operator durante la reconciliación:
# "Reconciling CouchbaseCluster cb-lab-cluster"
# "Scaling server group data-nodes from 2 to 3"
# "Creating pod cb-lab-cluster-data-nodes-0002"
# "Adding node cb-lab-cluster-data-nodes-0002 to Couchbase cluster"
# "Initiating rebalance"
# "Rebalance completed successfully"
```

#### Verificación

```bash
# Confirmar 4 nodos disponibles y clúster Available
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.availableNodes}'

kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
# Ambos deben ser: 4 y True respectivamente
```

---

### Paso 6 — Simulación de Fallo y Auto-Recuperación del Operator

**Objetivo:** Simular el fallo de un pod de Couchbase eliminándolo manualmente y observar cómo el Operator detecta la divergencia entre el estado deseado y el real, y ejecuta automáticamente la recuperación sin intervención humana.

**Tiempo estimado:** 10 minutos

#### Instrucciones

1. Establece un monitor continuo de pods en una terminal separada antes de provocar el fallo:

```bash
# Terminal 2: monitorizar pods continuamente
kubectl get pods -n couchbase --watch
```

2. Desde la terminal principal, elimina un pod de Couchbase para simular un fallo:

```bash
# Anotar el estado actual
echo "Estado antes del fallo:"
kubectl get pods -n couchbase

# Eliminar el pod data-nodes-0002 (el más reciente)
kubectl delete pod cb-lab-cluster-data-nodes-0002 -n couchbase

echo "Pod eliminado. Observando recuperación automática del Operator..."
```

3. Observa los logs del Operator inmediatamente después de la eliminación:

```bash
kubectl logs -n couchbase-operator deployment/couchbase-operator \
  --tail=30 --follow &
LOG_PID=$!
sleep 60
kill $LOG_PID 2>/dev/null
```

4. Examina los eventos de Kubernetes para entender la secuencia de acciones del Operator:

```bash
kubectl get events -n couchbase \
  --sort-by='.lastTimestamp' | tail -15
```

5. Verifica que el pod fue recreado y el clúster recuperó su estado deseado:

```bash
kubectl get pods -n couchbase
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.availableNodes}'
# Debe retornar: 4 (el Operator recreó el pod eliminado)
```

6. Inspecciona el campo `status` del `CouchbaseCluster` para ver cómo el Operator documentó la recuperación:

```bash
kubectl describe couchbasecluster cb-lab-cluster -n couchbase | \
  grep -A 20 "Conditions:"
```

#### Salida Esperada

```
# Secuencia observada en los logs del Operator:
# "Detected pod cb-lab-cluster-data-nodes-0002 is missing"
# "Reconciling CouchbaseCluster cb-lab-cluster"
# "Current state diverges from desired state: 3 data nodes found, 3 expected"
# "Creating pod cb-lab-cluster-data-nodes-0002"
# "Waiting for pod cb-lab-cluster-data-nodes-0002 to be ready"
# "Adding recovered node to Couchbase cluster"
# "Rebalance initiated after node recovery"

# kubectl get pods -n couchbase (después de la recuperación, ~2-3 minutos)
NAME                                    READY   STATUS    RESTARTS   AGE
cb-lab-cluster-data-nodes-0000          1/1     Running   0          25m
cb-lab-cluster-data-nodes-0001          1/1     Running   0          24m
cb-lab-cluster-data-nodes-0002          1/1     Running   0          1m   ← RECREADO
cb-lab-cluster-index-query-nodes-0000   1/1     Running   0          23m
```

> **Punto de reflexión:** A diferencia de un `StatefulSet` estándar de Kubernetes, el Operator no solo recrea el pod: también lo reincorpora al clúster Couchbase mediante llamadas a la API REST y ejecuta el rebalanceo necesario. Este es el valor del patrón Operator frente a los controladores genéricos de Kubernetes.

#### Verificación

```bash
# El clúster debe estar Available y no Degraded
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='{.status.conditions}' | jq '.[] | {type: .type, status: .status}'
```

---

### Paso 7 — Actualización de Configuración de Bucket vía CRD

**Objetivo:** Modificar la configuración del bucket `lab-bucket` actualizando su cuota de RAM mediante el CRD `CouchbaseBucket` y observar cómo el Operator aplica el cambio de forma declarativa sin intervención manual en la consola.

**Tiempo estimado:** 5 minutos

#### Instrucciones

1. Verifica la configuración actual del bucket:

```bash
kubectl get couchbasebucket lab-bucket -n couchbase -o yaml | \
  grep -E "(memoryQuota|replicas|name):"
```

2. Actualiza la cuota de memoria del bucket de 512Mi a 768Mi mediante patch:

```bash
kubectl patch couchbasebucket lab-bucket \
  --namespace couchbase \
  --type='merge' \
  --patch='{"spec": {"memoryQuota": "768Mi"}}'
```

3. Observa que el Operator aplica el cambio automáticamente:

```bash
# Ver los logs del Operator
kubectl logs -n couchbase-operator deployment/couchbase-operator \
  --tail=20 | grep -i bucket

# Verificar el nuevo valor via REST
sleep 10
curl -s -u Administrator:P@ssw0rd2024! \
  http://localhost:8091/pools/default/buckets/lab-bucket | \
  jq '.quota.ram / 1024 / 1024'
# Debe mostrar: 768 (MB)
```

#### Verificación

```bash
kubectl get couchbasebucket lab-bucket -n couchbase \
  -o jsonpath='{.spec.memoryQuota}'
# Debe retornar: 768Mi
```

---

### Paso 8 — Ejercicio de Troubleshooting: Diagnóstico de Despliegue Mal Configurado

**Objetivo:** Diagnosticar y corregir un despliegue de `CouchbaseCluster` deliberadamente mal configurado, interpretando los mensajes del Admission Controller, los logs del Operator y los eventos de Kubernetes para identificar y resolver los problemas.

**Tiempo estimado:** 12 minutos

#### Instrucciones

1. Crea el manifiesto de un clúster con configuraciones incorrectas intencionales:

```bash
cat <<'EOF' > cb-broken-cluster.yaml
apiVersion: couchbase.com/v2
kind: CouchbaseCluster
metadata:
  name: cb-broken-cluster
  namespace: couchbase
spec:
  # ERROR 1: Imagen con tag inexistente
  image: couchbase/server:enterprise-99.99.99

  security:
    adminSecret: cb-admin-credentials
    rbac:
      managed: true

  servers:
    # ERROR 2: Grupo de servidores sin servicio 'data' (requerido en al menos un grupo)
    - name: query-only-nodes
      size: 1
      services:
        - query
      resources:
        requests:
          cpu: "500m"
          # ERROR 3: Memoria insuficiente para Couchbase (mínimo recomendado: 1Gi)
          memory: "256Mi"
        limits:
          cpu: "1"
          memory: "256Mi"
      volumeMounts:
        default: data-vol

  volumeClaimTemplates:
    - metadata:
        name: data-vol
      spec:
        # ERROR 4: StorageClass inexistente
        storageClassName: nonexistent-storage-class
        resources:
          requests:
            storage: 5Gi
        accessModes:
          - ReadWriteOnce

  buckets:
    managed: true
EOF
```

2. Intenta aplicar el manifiesto y observa la respuesta del Admission Controller:

```bash
kubectl apply -f cb-broken-cluster.yaml
# Observar si el Admission Controller rechaza la solicitud o si pasa la validación
```

3. Si el manifiesto pasa el Admission Controller, examina los eventos del Operator:

```bash
kubectl get events -n couchbase \
  --sort-by='.lastTimestamp' \
  --field-selector involvedObject.name=cb-broken-cluster | tail -20
```

4. Examina el estado del clúster roto:

```bash
kubectl describe couchbasecluster cb-broken-cluster -n couchbase 2>/dev/null | \
  grep -A 30 "Events:"

kubectl get couchbasecluster cb-broken-cluster -n couchbase \
  -o jsonpath='{.status.conditions}' 2>/dev/null | jq .
```

5. Examina los pods (si se crearon) para identificar los errores de imagen:

```bash
kubectl get pods -n couchbase | grep broken
kubectl describe pod -n couchbase -l couchbase_cluster=cb-broken-cluster 2>/dev/null | \
  grep -A 10 "Events:"
# Buscar errores: ErrImagePull, ImagePullBackOff, Pending
```

6. Documenta los errores encontrados en la siguiente tabla (completa durante el ejercicio):

| # | Error Identificado | Síntoma Observado | Herramienta Usada |
|---|-------------------|-------------------|-------------------|
| 1 | Imagen inexistente `enterprise-99.99.99` | Pod en `ErrImagePull` / `ImagePullBackOff` | `kubectl describe pod` |
| 2 | Sin servicio `data` en ningún grupo | Error de validación del Operator o clúster en estado `Failed` | `kubectl get events` |
| 3 | Memoria insuficiente (256Mi) | Pod en `OOMKilled` o rechazado por Admission Controller | `kubectl logs` del Operator |
| 4 | StorageClass inexistente | PVC en estado `Pending` indefinidamente | `kubectl get pvc` |

7. Crea el manifiesto corregido y aplícalo:

```bash
cat <<EOF > cb-fixed-cluster.yaml
apiVersion: couchbase.com/v2
kind: CouchbaseCluster
metadata:
  name: cb-broken-cluster
  namespace: couchbase
spec:
  # CORRECCIÓN 1: Imagen válida
  image: couchbase/server:enterprise-7.6.2

  security:
    adminSecret: cb-admin-credentials
    rbac:
      managed: true

  servers:
    # CORRECCIÓN 2: Incluir servicio 'data' obligatorio
    - name: data-query-nodes
      size: 1
      services:
        - data
        - query
      resources:
        requests:
          cpu: "1"
          # CORRECCIÓN 3: Memoria suficiente
          memory: "2Gi"
        limits:
          cpu: "2"
          memory: "3Gi"
      volumeMounts:
        default: data-vol

  volumeClaimTemplates:
    - metadata:
        name: data-vol
      spec:
        # CORRECCIÓN 4: StorageClass existente
        storageClassName: ${DEFAULT_SC}
        resources:
          requests:
            storage: 5Gi
        accessModes:
          - ReadWriteOnce

  buckets:
    managed: true
EOF

kubectl apply -f cb-fixed-cluster.yaml
```

8. Verifica que el clúster corregido progresa hacia el estado `Available`:

```bash
kubectl get couchbasecluster cb-broken-cluster -n couchbase --watch
# Esperar hasta ver Available: True, luego Ctrl+C
```

#### Verificación

```bash
# Confirmar que el clúster corregido está Available
kubectl get couchbasecluster cb-broken-cluster -n couchbase \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].status}'
# Debe retornar: True
```

---

## Validación y Pruebas Finales

Ejecuta la siguiente secuencia de validación para confirmar que todos los objetivos del laboratorio fueron completados exitosamente:

```bash
echo "=========================================="
echo "VALIDACIÓN FINAL - Lab 10-00-01"
echo "=========================================="

# 1. Verificar que el Operator y el Admission Controller están Running
echo ""
echo "[1/6] Componentes del CAO:"
kubectl get pods -n couchbase-operator \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# 2. Verificar los CRDs instalados
echo ""
echo "[2/6] CRDs de Couchbase registrados:"
kubectl get crds | grep couchbase.com | wc -l
echo "  (Esperado: 13 o más CRDs)"

# 3. Verificar el clúster principal
echo ""
echo "[3/6] Estado del clúster principal cb-lab-cluster:"
kubectl get couchbasecluster cb-lab-cluster -n couchbase \
  -o jsonpath='  Nodos disponibles: {.status.availableNodes}{"\n"}  Estado Available: {.status.conditions[?(@.type=="Available")].status}{"\n"}'

# 4. Verificar todos los pods del clúster
echo ""
echo "[4/6] Pods del clúster Couchbase:"
kubectl get pods -n couchbase \
  -l "couchbase_cluster=cb-lab-cluster" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# 5. Verificar PVCs
echo ""
echo "[5/6] PersistentVolumeClaims:"
kubectl get pvc -n couchbase \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# 6. Verificar bucket
echo ""
echo "[6/6] Bucket lab-bucket:"
kubectl get couchbasebucket lab-bucket -n couchbase \
  -o jsonpath='  Nombre: {.spec.name}{"\n"}  RAM Quota: {.spec.memoryQuota}{"\n"}'

echo ""
echo "=========================================="
echo "Validación completada"
echo "=========================================="
```

**Criterios de éxito:**

| Criterio | Valor Esperado |
|----------|---------------|
| Pods del CAO en Running | 2 pods |
| CRDs registrados | ≥ 13 |
| Nodos disponibles en cb-lab-cluster | 4 |
| Estado Available del clúster | True |
| PVCs en estado Bound | 4 |
| Cuota de RAM de lab-bucket | 768Mi |

---

## Resolución de Problemas

### Problema 1: Los pods de Couchbase quedan en estado `Pending` indefinidamente

**Síntomas:**
- `kubectl get pods -n couchbase` muestra pods en estado `Pending` por más de 5 minutos.
- Los PVCs aparecen en estado `Pending` en lugar de `Bound`.
- `kubectl describe pod <nombre-pod> -n couchbase` muestra el mensaje: `0/3 nodes are available: 3 pod has unbound immediate PersistentVolumeClaims`.

**Causa:**
La `storageClassName` especificada en `volumeClaimTemplates` del `CouchbaseCluster` no existe en el clúster Kubernetes, o el provisionador dinámico de almacenamiento no está disponible. Esto impide que los PVCs sean aprovisionados, y sin PVC en estado `Bound`, el pod no puede ser programado.

**Solución:**

```bash
# 1. Identificar las StorageClasses disponibles
kubectl get storageclass
# Anotar el nombre de la StorageClass marcada como (default)

# 2. Verificar el estado de los PVCs
kubectl describe pvc -n couchbase | grep -A 5 "Events:"
# Buscar mensajes como: "no persistent volumes available" o "storageclass not found"

# 3. Corregir el CouchbaseCluster con la StorageClass correcta
SC_CORRECTA=$(kubectl get storageclass \
  -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}')

kubectl patch couchbasecluster cb-lab-cluster \
  --namespace couchbase \
  --type='json' \
  --patch="[
    {\"op\": \"replace\", \"path\": \"/spec/volumeClaimTemplates/0/spec/storageClassName\", \"value\": \"${SC_CORRECTA}\"},
    {\"op\": \"replace\", \"path\": \"/spec/volumeClaimTemplates/1/spec/storageClassName\", \"value\": \"${SC_CORRECTA}\"}
  ]"

# 4. Verificar que los PVCs se actualizan
kubectl get pvc -n couchbase --watch
# Esperar hasta que cambien a Bound
```

---

### Problema 2: El Operator entra en bucle de reconciliación continua sin converger

**Síntomas:**
- Los logs del Operator muestran repetidamente mensajes de reconciliación para el mismo `CouchbaseCluster` sin progresar.
- `kubectl get couchbasecluster cb-lab-cluster -n couchbase` muestra condiciones alternando entre `Available: True` y `Degraded: True`.
- Los pods de Couchbase se reinician repetidamente (`RESTARTS` > 3).
- `kubectl describe pod <nombre-pod> -n couchbase` muestra `OOMKilled` en la sección de eventos.

**Causa:**
Los límites de memoria configurados en `spec.servers[].resources.limits.memory` son insuficientes para el proceso de Couchbase. El proceso es terminado por el OOM Killer del kernel de Linux, el pod se reinicia, y el Operator detecta el nodo como no disponible e intenta reconciliar. Este ciclo se repite indefinidamente porque la causa raíz (memoria insuficiente) no es corregida por el Operator automáticamente.

**Solución:**

```bash
# 1. Confirmar que la causa es OOMKilled
kubectl get pods -n couchbase
kubectl describe pod cb-lab-cluster-data-nodes-0000 -n couchbase | \
  grep -A 5 "Last State:"
# Buscar: "Reason: OOMKilled"

# 2. Revisar el consumo de memoria actual
kubectl top pods -n couchbase 2>/dev/null || \
  echo "metrics-server no disponible; verificar con 'kubectl describe pod'"

# 3. Aumentar los límites de memoria en el CouchbaseCluster
# Couchbase Server requiere mínimo 1Gi, recomendado 2Gi+ para producción
kubectl patch couchbasecluster cb-lab-cluster \
  --namespace couchbase \
  --type='json' \
  --patch='[
    {"op": "replace", "path": "/spec/servers/0/resources/requests/memory", "value": "2Gi"},
    {"op": "replace", "path": "/spec/servers/0/resources/limits/memory", "value": "3Gi"},
    {"op": "replace", "path": "/spec/servers/1/resources/requests/memory", "value": "2Gi"},
    {"op": "replace", "path": "/spec/servers/1/resources/limits/memory", "value": "3Gi"}
  ]'

# 4. El Operator recreará los pods con los nuevos límites
# Monitorizar la recuperación
kubectl get pods -n couchbase --watch

# 5. Verificar que los reinicios se detienen
kubectl get pods -n couchbase
# La columna RESTARTS debe dejar de incrementarse
```

---

## Limpieza del Entorno

Ejecuta los siguientes comandos para limpiar los recursos creados durante el laboratorio. **Advertencia:** Estos comandos eliminarán todos los datos del clúster Couchbase desplegado.

```bash
echo "Iniciando limpieza del entorno del Lab 10-00-01..."

# 1. Eliminar el clúster corregido (del ejercicio de troubleshooting)
kubectl delete couchbasecluster cb-broken-cluster -n couchbase --ignore-not-found=true
echo "  [OK] cb-broken-cluster eliminado"

# 2. Eliminar el clúster principal
kubectl delete couchbasecluster cb-lab-cluster -n couchbase --ignore-not-found=true
echo "  [OK] cb-lab-cluster eliminado"

# 3. Eliminar los buckets declarados
kubectl delete couchbasebucket lab-bucket -n couchbase --ignore-not-found=true
echo "  [OK] CouchbaseBuckets eliminados"

# 4. Esperar a que los pods sean terminados por el Operator
echo "  Esperando terminación de pods (30s)..."
sleep 30
kubectl get pods -n couchbase

# 5. Eliminar PVCs residuales (si el Operator no los eliminó automáticamente)
kubectl delete pvc -n couchbase --all
echo "  [OK] PVCs eliminados"

# 6. Eliminar el Secret de credenciales
kubectl delete secret cb-admin-credentials -n couchbase --ignore-not-found=true
echo "  [OK] Secret eliminado"

# 7. Desinstalar el Couchbase Operator vía Helm
helm uninstall couchbase-operator -n couchbase-operator
echo "  [OK] Helm release del Operator desinstalado"

# 8. Eliminar los namespaces
kubectl delete namespace couchbase --ignore-not-found=true
kubectl delete namespace couchbase-operator --ignore-not-found=true
echo "  [OK] Namespaces eliminados"

# 9. Detener port-forward si está activo
pkill -f "kubectl port-forward" 2>/dev/null
echo "  [OK] Port-forwards terminados"

# 10. Limpiar archivos temporales
rm -f cb-lab-cluster.yaml cb-broken-cluster.yaml cb-fixed-cluster.yaml
echo "  [OK] Archivos YAML temporales eliminados"

echo ""
echo "Limpieza completada. Verificar estado final:"
kubectl get all -n couchbase 2>/dev/null || echo "  Namespace couchbase eliminado correctamente"
```

> **Nota:** Los CRDs de Couchbase (`couchbaseclusters.couchbase.com`, etc.) permanecen en el clúster después de desinstalar el Helm release, ya que son recursos de nivel de clúster. Si deseas eliminarlos completamente: `kubectl get crds | grep couchbase.com | awk '{print $1}' | xargs kubectl delete crd`

---

## Resumen

En este laboratorio aplicaste los conceptos de la Lección 10.1 sobre la arquitectura del Couchbase Autonomous Operator en un entorno Kubernetes real. Los logros principales fueron:

| Actividad | Concepto Aplicado |
|-----------|-------------------|
| Instalación del CAO vía Helm y verificación del Operator Pod + Admission Controller | Arquitectura del CAO: dos componentes principales |
| Examen de 13+ CRDs registrados (`CouchbaseCluster`, `CouchbaseBucket`, etc.) | Extensión de la API de Kubernetes con vocabulario Couchbase |
| Creación del manifiesto `CouchbaseCluster` con MDS, PVCs y grupos de servidores diferenciados | Estado deseado declarativo gestionado por el Operator |
| Observación del bucle de reconciliación en los logs del Operator | Ciclo Observar → Analizar → Actuar → Registrar |
| Scale-out de 2 a 3 nodos data y rebalanceo automático | Gestión de Pods individuales (no StatefulSet genérico) |
| Eliminación de pod y auto-recuperación sin intervención humana | Idempotencia y convergencia hacia el estado deseado |
| Diagnóstico de 4 errores en un despliegue roto | Uso del Admission Controller, logs del Operator y eventos de Kubernetes |

### Conceptos Clave Consolidados

- El **Admission Controller** actúa como primera línea de defensa rechazando configuraciones inválidas antes de que lleguen al Operator.
- El campo `status.conditions` del `CouchbaseCluster` es la fuente de verdad operativa; los estados `Available`, `Degraded` y `Scaling` guían el diagnóstico.
- El Operator gestiona cada nodo como un **Pod individual**, no como un StatefulSet genérico, lo que le permite ejecutar operaciones específicas de Couchbase como el rebalanceo.
- La **idempotencia** del bucle de reconciliación garantiza que el Operator puede recuperarse de interrupciones propias sin causar inconsistencias en el clúster.

### Recursos Adicionales

- [Documentación oficial del Couchbase Autonomous Operator 2.6](https://docs.couchbase.com/operator/current/overview.html)
- [Referencia completa del CRD CouchbaseCluster](https://docs.couchbase.com/operator/current/resource/couchbasecluster.html)
- [Guía de troubleshooting del CAO](https://docs.couchbase.com/operator/current/troubleshooting-operator.html)
- [Helm Chart oficial de Couchbase](https://github.com/couchbase-partners/helm-charts)
- [Patrón Operator — Documentación de Kubernetes](https://kubernetes.io/docs/concepts/extend-kubernetes/operator/)

---
