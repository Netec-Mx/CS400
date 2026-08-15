---
layout: lab
title: "Práctica 9: Simulación de fallos y recuperación entre clústeres"
permalink: /lab9/lab9/
images_base: /labs/lab9/img
duration: "78 minutos"
objective:
  - Validar la resiliencia multisitio de Couchbase en Kubernetes mediante pruebas de alta disponibilidad (Server Groups y failovers), replicación selectiva con XDCR declarativo, resolución de conflictos y medición experimental de RPO/RTO para estructurar un runbook de recuperación ante desastres.
prerequisites:
  - Haber completado las prácticas anteriores o dominar vBuckets, replicas, failover, rebalance, Server Groups, Couchbase Kubernetes Operator y XDCR.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender que auto-failover de Couchbase opera dentro de un solo clúster y no conmuta automáticamente aplicaciones hacia un clúster XDCR remoto.
introduction:
  - En esta práctica operarás dos CouchbaseCluster independientes dentro de un mismo Amazon EKS para simular una arquitectura primario/DR sin añadir complejidad innecesaria de redes multi-región. El clúster primario tendrá tres Data Pods distribuidos entre tres Availability Zones, permitiendo analizar Server Groups y failover. El segundo clúster funcionará como sitio DR y recibirá datos mediante XDCR administrado por Couchbase Kubernetes Operator. El laboratorio también utiliza dos pares de buckets separados para demostrar correctamente conflict resolution por sequence number y Last Write Wins, ya que la política se fija al crear un bucket y no puede modificarse posteriormente.
slug: lab9
lab_number: 9
final_result: >
  Al finalizar la práctica habrás verificado la distribución de active y replica vBuckets entre Availability Zones, medido el comportamiento de graceful, hard y auto-failover, configurado XDCR A→B con filtrado, comparado conflict resolution seqno y lww con pares de buckets independientes, medido un RPO experimental a partir de escrituras confirmadas y un RTO de aplicación hacia el clúster DR, y generado un runbook operativo con evidencias reproducibles.
notes:
  - Los 78 minutos corresponden sólo a tareas funcionales Couchbase. La creación, preparación y eliminación de Amazon EKS quedan fuera del tiempo.
  - Los dos CouchbaseCluster viven en el mismo EKS para reducir costo y complejidad; por ello se simula una arquitectura multi-sitio, no una latencia o pérdida de red multi-región real.
  - El clúster primario usa tres Data Pods distribuidos entre us-west-2a, us-west-2b y us-west-2c.
  - Server Groups protegen frente a failure domains dentro de un clúster; XDCR protege datos entre clústeres. Ninguno sustituye al otro.
  - Graceful failover está diseñado para preservar disponibilidad y datos cuando el clúster está sano, pero la práctica mide su impacto real en lugar de prometer cero latencia o cero interrupción.
  - Hard failover y auto-failover promueven replicas y pueden exponer pérdida de escrituras no replicadas o no durables; el laboratorio registra evidencia en lugar de asumirla.
  - autoFailoverTimeout se configura en 30s únicamente para acelerar el laboratorio.
  - Auto-failover es intra-clúster y no realiza site failover hacia XDCR.
  - La política conflictResolution se define al crear cada bucket. Los buckets source y target de una replicación deben utilizar la misma política.
  - LWW utiliza metadata temporal/CAS de Couchbase, no un campo timestamp escrito dentro del JSON de aplicación.
  - El campo xdcr_changes_left representa backlog de cambios de la replicación y no equivale directamente a RPO en segundos.
references:
  - text: "Configure XDCR with the Couchbase Kubernetes Operator"
    url: "https://docs.couchbase.com/operator/current/howto-xdcr.html"
  - text: "CouchbaseReplication Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasereplication.html"
  - text: "CouchbaseCluster Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasecluster.html"
  - text: "Server Groups with the Couchbase Kubernetes Operator"
    url: "https://docs.couchbase.com/operator/current/howto-server-groups.html"
  - text: "Automatic Failover"
    url: "https://docs.couchbase.com/server/7.6/learn/clusters-and-availability/automatic-failover.html"
  - text: "Filter XDCR Replications"
    url: "https://docs.couchbase.com/server/7.6/manage/manage-xdcr/filter-xdcr-replication.html"
  - text: "XDCR Conflict Resolution"
    url: "https://docs.couchbase.com/server/7.6/learn/clusters-and-availability/xdcr-conflict-resolution.html"
  - text: "XDCR Metrics Reference"
    url: "https://docs.couchbase.com/server/7.6/metrics-reference/xdcr-metrics.html"
prev: /lab8/lab8/
next: /lab10/lab10/
---

---

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona `C:\LABS\couchbase-nosql` y abre una terminal integrada **Git Bash** para conservar la misma operación utilizada en los laboratorios anteriores.

- {% include step_label.html %} Crea directorios específicos para manifiestos de ambos clústeres, scripts, workload, XDCR, evidencias y reportes.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab9/{scripts,manifests,workload,xdcr,metrics,snapshots,reports,outputs}
  cd /c/LABS/couchbase-nosql/lab9

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:**

  ```text
  /c/LABS/couchbase-nosql/lab9
  ./manifests
  ./metrics
  ./outputs
  ./reports
  ./scripts
  ./snapshots
  ./workload
  ./xdcr
  ```

---

## ☁️ Preparación de infraestructura

## Crear variables

- {% include step_label.html %} Crea `lab.env` con nombres, namespaces y versiones. Ambos clústeres utilizan credenciales iguales sólo por simplicidad pedagógica.

  ```bash
  cat > lab.env << 'ENVEOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab09"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"

  export NS_A="couchbase-a"
  export NS_B="couchbase-b"

  export CLUSTER_A="cb-primary"
  export CLUSTER_B="cb-dr"

  export CB_USER="Administrator"
  export CB_PASS="Password123!"

  export CB_OPERATOR_VERSION="2.92.0"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"

  export DR_BUCKET="lab9-dr"
  export SEQNO_BUCKET="lab9-seqno"
  export LWW_BUCKET="lab9-lww"

  export RPO_OBJECTIVE_SECONDS="300"
  export RTO_OBJECTIVE_SECONDS="600"
  ENVEOF

  source lab.env
  ```

## Crear y eliminar EKS

- {% include step_label.html %} Crea el script de ciclo de vida con cuatro workers `m6i.xlarge` distribuidos entre tres Availability Zones, suficientes para dos clusters reducidos y clientes de prueba.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab9/eks-cluster.sh
  ```

- {% include step_label.html %} Otorga permisos de ejecución al script descargado, valida su sintaxis Bash y crea el clúster EKS con la configuración definida para esta práctica.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** El script debe completar la creación de EKS sin errores y dejar cuatro workers `Ready` distribuidos entre las Availability Zones definidas.

- {% include step_label.html %} Verifica las Availability Zones reales de los workers antes de declarar Server Groups; los valores deben coincidir exactamente con la región `us-west-2` configurada en `lab.env`.

  ```bash
  kubectl get nodes     -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
  ```

**Salida esperada:** Los workers deben estar distribuidos entre `us-west-2a`, `us-west-2b` y `us-west-2c`; no continúes si aparecen zonas de otra región.

## Crear StorageClass e instalar Operator

- {% include step_label.html %} Crea una StorageClass `gp3` para los volúmenes persistentes; los Operators se instalarán después, uno por namespace y con un solo Admission Controller para todo EKS.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'YAMLEOF'
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata:
    name: gp3-couchbase
  provisioner: ebs.csi.aws.com
  parameters:
    type: gp3
    fsType: ext4
  reclaimPolicy: Delete
  volumeBindingMode: WaitForFirstConsumer
  allowVolumeExpansion: true
  YAMLEOF
  ```
  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

**Salida esperada:** Kubernetes debe crear o confirmar `storageclass.storage.k8s.io/gp3-couchbase` sin errores de validación.

- {% include step_label.html %} Aplica la StorageClass y crea los dos namespaces que aislarán el clúster primario y el clúster DR antes de instalar sus respectivos Operators.

  ```bash
  kubectl create namespace "$NS_A"
  ```
  ```bash
  kubectl create namespace "$NS_B"
  ```

**Salida esperada:** Deben crearse los namespaces `couchbase-a` y `couchbase-b` para separar el clúster primario del sitio DR.

- {% include step_label.html %} Agrega y actualiza el repositorio Helm oficial de Couchbase para disponer de la versión del Operator definida en `lab.env`.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```

**Salida esperada:** Helm debe registrar o confirmar el repositorio `couchbase` y actualizar correctamente el índice local de charts.

> **IMPORTANTE:** Si tu instalación del Operator fue configurada con RBAC de alcance `Role`, instala una instancia en cada namespace. Si utilizas `ClusterRole`, una sola instancia puede observar ambos namespaces según la configuración de despliegue.
{: .lab-note .important .compact}

- {% include step_label.html %} Para este laboratorio instala una instancia por namespace; esto mantiene el aislamiento simple y evita depender de configuración cluster-wide adicional.

  ```bash
  helm upgrade --install cb-operator-a couchbase/couchbase-operator \
    --namespace "$NS_A" \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

- {% include step_label.html %} Instala la segunda instancia del Operator en `couchbase-b` deshabilitando el Admission Controller adicional para evitar duplicarlo dentro del mismo clúster Kubernetes.

  ```bash
  helm upgrade --install cb-operator-b couchbase/couchbase-operator \
    --namespace "$NS_B" \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false \
    --set install.admissionController=false
  ```

- {% include step_label.html %} Espera que la instancia del Operator de `couchbase-a` alcance condición `Available` antes de validar el namespace DR.

  ```bash
  kubectl wait -n "$NS_A" \
    --for=condition=Available deployment --all --timeout=5m
  ```

- {% include step_label.html %} Confirma también la disponibilidad del Operator en `couchbase-b` para garantizar que ambos namespaces pueden reconciliar sus recursos Couchbase.

  ```bash
  kubectl wait -n "$NS_B" \
    --for=condition=Available deployment --all --timeout=5m
  ```

**Salida esperada:** Ambos namespaces deben tener un Operator disponible; el segundo release no debe desplegar otro Admission Controller cluster-wide.

## Crear secretos administrativos

- {% include step_label.html %} Crea el Secret administrativo en ambos namespaces mediante un flujo idempotente para que cada Operator utilice credenciales locales.

  ```bash
  for NS in "$NS_A" "$NS_B"; do
    kubectl create secret generic cb-admin \
      --namespace "$NS" \
      --from-literal=username="$CB_USER" \
      --from-literal=password="$CB_PASS" \
      --dry-run=client \
      -o yaml \
      | kubectl apply -f -
  done
  ```

**Salida esperada:** Deben existir dos Secrets `cb-admin`, uno por namespace; la salida no debe revelar el valor de `$CB_PASS`.

## Crear Cluster A: primario

- {% include step_label.html %} Declara tres Server Groups que coinciden con las Availability Zones y configura tres Data Pods, uno por failure domain, además de un Pod Query + Index.

  ```bash
  cat > manifests/cluster-a.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-primary
    namespace: couchbase-a
  spec:
    image: couchbase/server:enterprise-7.6.2

    antiAffinity: false

    security:
      adminSecret: cb-admin
      podSecurityContext:
        fsGroup: 1000

    buckets:
      managed: true

    serverGroups:
      - us-west-2a
      - us-west-2b
      - us-west-2c

    cluster:
      dataServiceMemoryQuota: 1Gi
      indexServiceMemoryQuota: 512Mi
      autoFailoverTimeout: 30s
      autoFailoverMaxCount: 1

    recoveryPolicy: PrioritizeDataIntegrity

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - query

    servers:
      - name: data
        size: 3
        services:
          - data
        serverGroups:
          - us-west-2a
          - us-west-2b
          - us-west-2c
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
        volumeMounts:
          default: couchbase-volume

      - name: query-index
        size: 1
        services:
          - query
          - index
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
        volumeMounts:
          default: couchbase-volume

    volumeClaimTemplates:
      - metadata:
          name: couchbase-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 30Gi
  YAMLEOF
  ```

- {% include step_label.html %} Aplica el manifiesto del Cluster A para que Operator materialice la topología primaria declarada con tres Data Pods y un Query + Index.

  ```bash
  kubectl apply -f manifests/cluster-a.yaml
  ```

**Salida esperada:** Kubernetes debe aceptar `cb-primary`; Operator debe iniciar tres Data Pods y un Query + Index, con buckets declarativos habilitados mediante `buckets.managed: true`.

## Crear Cluster B: DR

- {% include step_label.html %} Crea un clúster DR independiente con dos Data Pods y un Query + Index; el laboratorio no pretende modelar toda la capacidad productiva del sitio secundario.

  ```bash
  cat > manifests/cluster-b.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-dr
    namespace: couchbase-b
  spec:
    image: couchbase/server:enterprise-7.6.2

    antiAffinity: false

    security:
      adminSecret: cb-admin
      podSecurityContext:
        fsGroup: 1000

    buckets:
      managed: true

    cluster:
      dataServiceMemoryQuota: 1Gi
      indexServiceMemoryQuota: 512Mi
      autoFailoverTimeout: 30s
      autoFailoverMaxCount: 1

    recoveryPolicy: PrioritizeDataIntegrity

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - query

    servers:
      - name: data
        size: 2
        services:
          - data
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
        volumeMounts:
          default: couchbase-volume

      - name: query-index
        size: 1
        services:
          - query
          - index
        resources:
          requests:
            cpu: "1000m"
            memory: "2Gi"
          limits:
            cpu: "2"
            memory: "3Gi"
        volumeMounts:
          default: couchbase-volume

    volumeClaimTemplates:
      - metadata:
          name: couchbase-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 30Gi
  YAMLEOF
  ```

- {% include step_label.html %} Aplica el manifiesto del Cluster B para iniciar la creación del sitio DR independiente dentro de su namespace.

  ```bash
  kubectl apply -f manifests/cluster-b.yaml
  ```

**Salida esperada:** Kubernetes debe aceptar `cb-dr`; Operator debe iniciar dos Data Pods y un Query + Index, con buckets declarativos habilitados mediante `buckets.managed: true`.

- {% include step_label.html %} Espera primero que el `CouchbaseCluster` primario alcance condición `Available`; no continúes con buckets, clientes o port-forward mientras algún Pod Couchbase permanezca `Pending`.

  ```bash
  kubectl wait \
    -n "$NS_A" \
    --for=condition=Available \
    couchbasecluster/"$CLUSTER_A" \
    --timeout=15m
  ```

**Salida esperada:** `cb-primary` debe alcanzar condición `Available=True` y sus cuatro Pods Couchbase deben encontrarse en estado `Running`.

- {% include step_label.html %} Espera después que el `CouchbaseCluster` DR alcance condición `Available` para asegurar que el segundo sitio también terminó su bootstrap.

  ```bash
  kubectl wait \
    -n "$NS_B" \
    --for=condition=Available \
    couchbasecluster/"$CLUSTER_B" \
    --timeout=15m
  ```

**Salida esperada:** `cb-dr` debe alcanzar condición `Available=True` y sus tres Pods Couchbase deben encontrarse en estado `Running`.

- {% include step_label.html %} Confirma el estado de ambos despliegues antes de crear recursos dependientes; esta verificación detecta de inmediato problemas de scheduling, PVC o Server Groups.

  ```bash
  kubectl get pods -n "$NS_A" -o wide
  ```
  ```bash
  kubectl get pods -n "$NS_B" -o wide
  ```

**Salida esperada:** Ningún Pod `cb-primary-*` ni `cb-dr-*` debe permanecer en `Pending`, `ContainerCreating` o `CrashLoopBackOff`.

## Crear buckets declarativos

- {% include step_label.html %} Crea tres buckets en cada cluster: uno para DR filtrado, uno con conflict resolution `seqno` y otro con `lww`.

  ```bash
  for NS in "$NS_A" "$NS_B"; do
    cat << YAMLEOF | kubectl apply -f -
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab9-dr
    namespace: ${NS}
  spec:
    memoryQuota: 512Mi
    replicas: 1
    storageBackend: couchstore
    conflictResolution: seqno
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab9-seqno
    namespace: ${NS}
  spec:
    memoryQuota: 256Mi
    replicas: 1
    storageBackend: couchstore
    conflictResolution: seqno
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab9-lww
    namespace: ${NS}
  spec:
    memoryQuota: 256Mi
    replicas: 1
    storageBackend: couchstore
    conflictResolution: lww
  YAMLEOF
  done
  ```

**Salida esperada:** Deben crearse los tres buckets en ambos namespaces con replicas y políticas `seqno`, `seqno` y `lww` respectivamente.

## Abrir port-forward para administración

> **IMPORTANTE:** El servicio `*-ui` se restringió a nodos con servicio Query. Así el `port-forward` administrativo permanece fuera de los Data Pods que se eliminarán intencionalmente en las pruebas de hard y auto-failover.
{: .lab-note .important .compact}

- {% include step_label.html %} Abre una terminal dedicada para Cluster A; `cb-primary-ui` apunta al servicio Query para mantener el forwarding fuera de los Data Pods que serán eliminados durante los failovers.

  ```bash
  kubectl port-forward \
    -n "$NS_A" \
    service/cb-primary-ui \
    8091:8091
  ```

- {% include step_label.html %} Abre otra terminal para Cluster B usando un puerto local distinto; conserva ambas terminales activas durante toda la práctica.

  ```bash
  kubectl port-forward \
    -n "$NS_B" \
    service/cb-dr-ui \
    9091:8091
  ```

- {% include step_label.html %} Desde una tercera terminal carga `lab.env` y espera que los tres buckets existan realmente en ambos clústeres antes de instalar clientes o cargar el dataset.

  ```bash
  source lab.env

  for PORT in 8091 9091; do
    for BUCKET in \
      "$DR_BUCKET" \
      "$SEQNO_BUCKET" \
      "$LWW_BUCKET"
    do
      READY=false

      for i in $(seq 1 60); do
        if curl -fsS \
          -u "$CB_USER:$CB_PASS" \
          "http://localhost:${PORT}/pools/default/buckets/${BUCKET}" \
          >/dev/null; then
          echo "READY: ${BUCKET} en localhost:${PORT}"
          READY=true
          break
        fi

        sleep 2
      done

      if [[ "$READY" != "true" ]]; then
        echo "ERROR: ${BUCKET} no quedó disponible en localhost:${PORT}"
      fi
    done
  done
  ```

**Salida esperada:** Deben imprimirse seis líneas `READY`, una por cada bucket en Cluster A (`8091`) y Cluster B (`9091`), sin líneas `ERROR`.

## Crear cliente Python

- {% include step_label.html %} Crea un Pod cliente en cada namespace para acceder al DNS interno de cada CouchbaseCluster sin exponer KV hacia Windows.

  ```bash
  for NS in "$NS_A" "$NS_B"; do
    cat << YAMLEOF | kubectl apply -f -
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-lab9-client
    namespace: ${NS}
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 14400"]
        env:
          - name: CB_USERNAME
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: username
          - name: CB_PASSWORD
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: password
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
  YAMLEOF
  done
  ```

**Salida esperada:** Debe crearse un Pod `cb-lab9-client` en cada namespace usando la imagen `python:3.12-slim`.

- {% include step_label.html %} Espera que el cliente de `couchbase-a` quede `Ready` antes de comprobar el cliente equivalente del namespace DR.

  ```bash
  kubectl wait -n "$NS_A" \
    --for=condition=Ready pod/cb-lab9-client --timeout=3m
  ```

**Salida esperada:** El Pod `cb-lab9-client` de `couchbase-a` debe alcanzar condición `Ready=True`.

- {% include step_label.html %} Confirma que el cliente de `couchbase-b` también quede `Ready` antes de instalar dependencias Python.

  ```bash
  kubectl wait -n "$NS_B" \
    --for=condition=Ready pod/cb-lab9-client --timeout=3m
  ```

**Salida esperada:** El Pod `cb-lab9-client` de `couchbase-b` debe alcanzar condición `Ready=True`.

- {% include step_label.html %} Instala Couchbase Python SDK en el cliente del primario para ejecutar seed, probes y pruebas de conflicto desde la red interna.

  ```bash
  kubectl exec -n "$NS_A" cb-lab9-client -- \
    pip install --quiet --root-user-action=ignore 'couchbase>=4.4,<5'
  ```

- {% include step_label.html %} Instala el mismo SDK en el cliente DR para validar filtering, conflictos, RPO y healthchecks contra Cluster B.

  ```bash
  kubectl exec -n "$NS_B" cb-lab9-client -- \
    pip install --quiet --root-user-action=ignore 'couchbase>=4.4,<5'
  ```

## Crear dataset de DR

- {% include step_label.html %} Crea un script que inserta 10,000 documentos `order::*` y 2,000 `internal::*` en Cluster A; el filtro XDCR posterior debe replicar únicamente los primeros.

  ```bash
  cat > workload/seed_dr.py << 'PYEOF'
  from datetime import timedelta
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-primary-srv",
      ClusterOptions(
          PasswordAuthenticator(
              "Administrator",
              "Password123!"
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )

  for start in range(0, 10000, 500):
      docs = {}

      for i in range(start, start + 500):
          docs[f"order::{i:08d}"] = {
              "type": "order",
              "order_id": i,
              "amount": (i % 500) + 1,
              "status": "pending"
          }

      collection.upsert_multi(docs)
      print(f"orders through {start + 500}")

  for start in range(0, 2000, 500):
      docs = {}

      for i in range(start, start + 500):
          docs[f"internal::{i:08d}"] = {
              "type": "internal",
              "config_id": i,
              "value": f"config-{i}"
          }

      collection.upsert_multi(docs)
      print(f"internal through {start + 500}")

  cluster.close()
  PYEOF
  ```

- {% include step_label.html %} Copia el seeder al cliente del primario para ejecutarlo dentro del namespace y resolver Couchbase mediante su Service interno.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp workload/seed_dr.py \
    couchbase-a/cb-lab9-client:/tmp/seed_dr.py
  ```

- {% include step_label.html %} Ejecuta el seeder desde el cliente interno y deja cargados los documentos `order::*` e `internal::*` que se utilizarán para demostrar Advanced Filtering.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    python /tmp/seed_dr.py
  ```

---

## Helpers de descubrimiento y estabilización

- {% include step_label.html %} Crea un helper que descubra los Data Pods desde los servicios `kv` anunciados por Couchbase, evitando depender de nombres derivados de la server class.

  ```bash
  cat > scripts/list-data-pods.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
  | jq -r '
      .nodes[]
      | select(.services | index("kv"))
      | .hostname
      | split(".")[0]
    ' \
  | tr -d '\r' \
  | sort
  SHEOF
  ```

- {% include step_label.html %} Otorga permisos de ejecución al helper y ejecútalo para comprobar que descubre únicamente los Data Pods anunciados con servicio `kv`.

  ```bash
  chmod +x scripts/list-data-pods.sh
  ./scripts/list-data-pods.sh
  ```

**Salida esperada:** Deben aparecer tres nombres ordinales de Data Pods del Cluster A, sin depender de un patrón como `cb-primary-data`.

- {% include step_label.html %} Crea una espera integral que valide tres Data nodes reales, membership `healthy/active` y ausencia de rebalance durante tres muestras consecutivas.

  ```bash
  cat > scripts/wait-primary-stable.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  STABLE=0
  
  for i in $(seq 1 180); do
    CLUSTER_JSON=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default
    )
  
    DATA_COUNT=$(
      echo "$CLUSTER_JSON" \
      | jq '[
          .nodes[]
          | select(.services | index("kv"))
        ] | length'
    )
  
    UNHEALTHY=$(
      echo "$CLUSTER_JSON" \
      | jq '[
          .nodes[]
          | select(
              .status != "healthy"
              or .clusterMembership != "active"
            )
        ] | length'
    )
  
    REBALANCE=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/rebalanceProgress \
      | jq -r '.status // "unknown"'
    )
  
    if [[ "$DATA_COUNT" -eq 3 \
          && "$UNHEALTHY" -eq 0 \
          && "$REBALANCE" == "none" ]]; then
      STABLE=$((STABLE + 1))
    else
      STABLE=0
    fi
  
    echo "Intento $i - Data=$DATA_COUNT/3 unhealthy=$UNHEALTHY rebalance=$REBALANCE stable=$STABLE/3"
  
    if [[ "$STABLE" -ge 3 ]]; then
      echo "Cluster A estable con tres Data nodes."
      exit 0
    fi
  
    sleep 5
  done
  
  echo "ERROR: Cluster A no alcanzó estabilidad."
  exit 1
  SHEOF
  ```

- {% include step_label.html %} Habilita el helper de estabilización, valida su sintaxis y ejecútalo para confirmar que el primario está listo antes de iniciar los failovers.

  ```bash
  chmod +x scripts/wait-primary-stable.sh
  bash -n scripts/wait-primary-stable.sh
  ./scripts/wait-primary-stable.sh
  ```

**Salida esperada:** Debe imprimirse `Cluster A estable con tres Data nodes.` antes de ejecutar las pruebas de failover.

---

## 🔎 Tarea 1. Validar topología, Server Groups y dataset — 7 min

### Tarea 1.1. Confirmar tres Availability Zones

- {% include step_label.html %} Lista los workers y sus labels de zona; la práctica requiere tres failure domains distintos.

  ```bash
  kubectl get nodes \
    -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
    | tee snapshots/eks-zones.txt
  ```

**Salida esperada:**

Debe haber workers en:

```text
us-west-2a
us-west-2b
us-west-2c
```

### Tarea 1.2. Revisar Server Groups declarados

- {% include step_label.html %} Consulta el `CouchbaseCluster` primario y extrae los Server Groups globales junto con la asignación de la server class Data para confirmar que el diseño lógico coincide con las tres Availability Zones.

  ```bash
  kubectl get couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    -o json \
    | jq '{
        serverGroups: .spec.serverGroups,
        dataClass: (
          .spec.servers[]
          | select(.name == "data")
          | {
              size,
              serverGroups
            }
        )
      }'
  ```

**Salida esperada:**

  ```json
  {
    "serverGroups": [
      "us-west-2a",
      "us-west-2b",
      "us-west-2c"
    ],
    "dataClass": {
      "size": 3,
      "serverGroups": [
        "us-west-2a",
        "us-west-2b",
        "us-west-2c"
      ]
    }
  }
  ```

### Tarea 1.3. Correlacionar Data Pods con AZ

- {% include step_label.html %} Correlaciona cada Data Pod descubierto desde Couchbase con su worker y Availability Zone, limpiando `\r` para evitar errores de Git Bash al consultar nodos.

  ```bash
  while IFS= read -r POD; do
    NODE=$(
      kubectl get pod "$POD" \
        -n "$NS_A" \
        -o jsonpath='{.spec.nodeName}'
    )
  
    NODE=${NODE//$'\r'/}
  
    ZONE=$(
      kubectl get node "$NODE" \
        -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
    )
  
    printf '%s\t%s\t%s\n' \
      "$POD" "$NODE" "$ZONE"
  done < <(./scripts/list-data-pods.sh) \
    | tee snapshots/data-pods-nodes.txt \
    | tee outputs/data-pods-zones.txt
  ```

**Salida esperada:** Deben aparecer tres Data Pods distribuidos entre `us-west-2a`, `us-west-2b` y `us-west-2c`, sin errores `nodes "...\\r" not found`.

### Tarea 1.4. Verificar buckets y conflictResolution

- {% include step_label.html %} Consulta los tres buckets del Cluster A y muestra replica count y política de resolución de conflictos para comprobar que cada bucket conserva la configuración declarada antes de iniciar XDCR.

  ```bash
  for BUCKET in \
    "$DR_BUCKET" \
    "$SEQNO_BUCKET" \
    "$LWW_BUCKET"
  do
    echo "=== $BUCKET / Cluster A ==="

    curl -s -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${BUCKET}" \
      | jq '{
          name,
          replicaNumber,
          conflictResolutionType
        }'
  done
  ```

**Salida esperada:**

```text
lab9-dr    → seqno
lab9-seqno → seqno
lab9-lww   → lww
```

### Tarea 1.5. Analizar active/replica vBuckets

- {% include step_label.html %} Crea un script que obtenga `vBucketServerMap` del bucket DR y muestre las asignaciones activas y replica.

  ```bash
  cat > scripts/vbucket_map.py << 'PYEOF'
  import base64
  import json
  import urllib.request

  URL = (
      "http://localhost:8091/pools/default/"
      "buckets/lab9-dr"
  )

  req = urllib.request.Request(URL)

  token = base64.b64encode(
      b"Administrator:Password123!"
  ).decode()

  req.add_header(
      "Authorization",
      f"Basic {token}"
  )

  with urllib.request.urlopen(req) as response:
      bucket = json.load(response)

  mapping = bucket["vBucketServerMap"]
  servers = mapping["serverList"]
  vbucket_map = mapping["vBucketMap"]

  active = {s: 0 for s in servers}
  replica = {s: 0 for s in servers}

  for row in vbucket_map:
      if row[0] >= 0:
          active[servers[row[0]]] += 1

      for idx in row[1:]:
          if idx >= 0:
              replica[servers[idx]] += 1

  print(f"vBuckets: {len(vbucket_map)}")

  for server in servers:
      print(
          f"{server:<45} "
          f"active={active[server]:>4} "
          f"replica={replica[server]:>4}"
      )
  PYEOF
  ```
  ```bash
  python scripts/vbucket_map.py \
    | tee outputs/vbucket-map-baseline.txt
  ```

**Salida esperada:**

```text
vBuckets: 1024
```

Los tres Data nodes deben participar en active y replica vBuckets.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}

{% include support-prompt.html task="tarea1" %}

---

## 🧰 Tarea 2. Ejecutar graceful failover y medir impacto — 8 min

### Tarea 2.1. Crear workload de disponibilidad

- {% include step_label.html %} Crea un cliente que ejecuta GET y UPSERT continuamente y registra latencia, errores y último write confirmado.

  ```bash
  cat > workload/availability_probe.py << 'PYEOF'
  import json
  import random
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-primary-srv",
      ClusterOptions(
          PasswordAuthenticator(
              "Administrator",
              "Password123!"
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )

  write_id = 0

  while True:
      started = time.perf_counter()

      try:
          if random.random() < 0.70:
              key = f"order::{random.randrange(0, 10000):08d}"
              collection.get(key)
              op = "GET"
              ack_write = None
          else:
              write_id += 1
              key = f"order::probe::{write_id:09d}"

              collection.upsert(
                  key,
                  {
                      "type": "order",
                      "probe_write_id": write_id,
                      "source_time_epoch": time.time()
                  }
              )

              op = "UPSERT"
              ack_write = write_id

          elapsed = (
              time.perf_counter() - started
          ) * 1000

          print(
              json.dumps({
                  "epoch": time.time(),
                  "ok": True,
                  "operation": op,
                  "latency_ms": round(elapsed, 2),
                  "ack_write_id": ack_write
              }),
              flush=True
          )

      except Exception as exc:
          print(
              json.dumps({
                  "epoch": time.time(),
                  "ok": False,
                  "error": type(exc).__name__
              }),
              flush=True
          )

      time.sleep(0.05)
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp workload/availability_probe.py \
    couchbase-a/cb-lab9-client:/tmp/availability_probe.py
  ```

### Tarea 2.2. Iniciar probe

- {% include step_label.html %} En una terminal dedicada inicia el probe y deja la salida en `/tmp/availability.log`.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    sh -c '
      python /tmp/availability_probe.py \
      | tee /tmp/availability.log
    '
  ```

**Salida esperada:**

  ```json
  {"ok": true, "operation": "GET", "latency_ms": ...}
  {"ok": true, "operation": "UPSERT", "latency_ms": ..., "ack_write_id": ...}
  ```

### Tarea 2.3. Pausar temporalmente Operator

- {% include step_label.html %} Pausa el control administrativo de Operator sobre Cluster A para evitar que la reconciliación compita con el ejercicio Couchbase-native.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":true}}'
  ```

**Salida esperada:** `kubectl` debe confirmar el patch y `.spec.paused` debe quedar en `true` para Cluster A.

### Tarea 2.4. Seleccionar nodo y ejecutar graceful failover

- {% include step_label.html %} Selecciona dinámicamente un Data node activo mediante su `otpNode`, registra el instante inicial y solicita graceful failover para observar una retirada coordinada sin eliminar primero el Pod.

  ```bash
  TARGET_OTP=$(
    curl -s -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
      | jq -r '
          .nodes[]
          | select(
              (.services | index("kv")) != null
            )
          | .otpNode
        ' \
      | head -n 1
  )

  echo "TARGET_OTP=$TARGET_OTP"

  T_GRACEFUL_START=$(date +%s)

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/controller/startGracefulFailover \
    --data-urlencode "otpNode=${TARGET_OTP}" \
    | tee outputs/graceful-failover-response.txt
  ```

### Tarea 2.5. Esperar finalización funcional

- {% include step_label.html %} Consulta periódicamente `clusterMembership` del nodo seleccionado hasta que Couchbase lo marque `inactiveFailed`, y calcula el tiempo transcurrido de la operación para conservarlo como evidencia.

  ```bash
  for i in $(seq 1 120); do
    MEMBERSHIP=$(
      curl -s -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default \
        | jq -r --arg OTP "$TARGET_OTP" '
            .nodes[]
            | select(.otpNode == $OTP)
            | .clusterMembership
          '
    )

    echo "$(date +%H:%M:%S) membership=$MEMBERSHIP"

    [[ "$MEMBERSHIP" == "inactiveFailed" ]] && break
    sleep 2
  done

  T_GRACEFUL_END=$(date +%s)
  RTO_GRACEFUL=$((T_GRACEFUL_END - T_GRACEFUL_START))

  echo "$RTO_GRACEFUL" \
    > outputs/rto-graceful-seconds.txt
  ```

### Tarea 2.6. Capturar impacto

- {% include step_label.html %} Captura las últimas muestras del probe después del graceful failover para conservar errores, latencias y operaciones exitosas observadas durante la transición.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    tail -n 40 /tmp/availability.log \
    | tee snapshots/graceful-availability.jsonl
  ```

**Salida esperada:**

- El nodo seleccionado termina en `inactiveFailed`.
- Los otros Data nodes siguen `healthy/active`.
- El workload conserva operaciones exitosas; cualquier error o pico de latencia se documenta, no se descarta.

### Tarea 2.7. Reanudar Operator

- {% include step_label.html %} Quita la pausa administrativa del `CouchbaseCluster` y espera la estabilización real del primario para que Operator recupere la topología declarada antes de continuar.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":false}}'
  ```

- {% include step_label.html %} Ejecuta el helper de estabilización para verificar que Operator restauró la topología y que no queda rebalance activo antes de continuar.

  ```bash
  ./scripts/wait-primary-stable.sh
  ```

**Salida esperada:** El helper debe finalizar con `Cluster A estable con tres Data nodes.` y todos los nodos deben quedar `healthy/active`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 💥 Tarea 3. Ejecutar hard failover y recuperación — 8 min

### Tarea 3.1. Pausar Operator y seleccionar un Data Pod

- {% include step_label.html %} Pausa temporalmente Operator, selecciona un Data Pod real mediante el helper y relaciona su hostname con el `otpNode` que utilizará Couchbase para el hard failover.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":true}}'

  TARGET_POD=$(
    ./scripts/list-data-pods.sh \
      | head -n1
  )

  TARGET_HOSTNAME=$(
    kubectl get pod "$TARGET_POD" \
      -n "$NS_A" \
      -o jsonpath='{.metadata.name}'
  )

  TARGET_OTP=$(
    curl -s -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
      | jq -r --arg P "$TARGET_HOSTNAME" '
          .nodes[]
          | select(.hostname | contains($P))
          | .otpNode
        '
  )

  echo "TARGET_POD=$TARGET_POD"
  echo "TARGET_OTP=$TARGET_OTP"
  ```

**Salida esperada:** Deben mostrarse un Data Pod existente y su `otpNode` correspondiente, ambos con valores no vacíos.

### Tarea 3.2. Registrar última escritura confirmada

- {% include step_label.html %} Extrae del probe la última escritura reconocida antes de provocar la pérdida abrupta para conservar una referencia temporal del workload previo al hard failover.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    grep '"ack_write_id": [0-9]' /tmp/availability.log \
    | tail -n 1 \
    | tee snapshots/last-ack-before-hard-failover.json
  ```

### Tarea 3.3. Eliminar el Pod

- {% include step_label.html %} Elimina el Pod mientras Operator está pausado para simular pérdida abrupta del proceso Couchbase sin que sea recreado inmediatamente.

  ```bash
  T_HARD_START=$(date +%s)

  kubectl delete pod \
    -n "$NS_A" \
    "$TARGET_POD" \
    --wait=false
  ```

### Tarea 3.4. Ejecutar hard failover

- {% include step_label.html %} Después de retirar abruptamente el Pod seleccionado, solicita hard failover utilizando su `otpNode` para que Couchbase promueva las replicas disponibles del miembro perdido.

  ```bash
  sleep 5

  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/controller/failOver \
    --data-urlencode "otpNode=${TARGET_OTP}" \
    | tee outputs/hard-failover-response.txt
  ```

### Tarea 3.5. Medir recuperación funcional

- {% include step_label.html %} Cuenta miembros `healthy/active` hasta recuperar capacidad funcional mínima y registra la duración desde la eliminación del Pod para comparar este escenario con los demás failovers.

  ```bash
  HARD_DONE=false

  for i in $(seq 1 60); do
    MEMBERSHIP=$(
      curl -s -u "$CB_USER:$CB_PASS"         http://localhost:8091/pools/default       | jq -r --arg OTP "$TARGET_OTP" '
          .nodes[]
          | select(.otpNode == $OTP)
          | .clusterMembership
        '
    )

    echo "$(date +%H:%M:%S) membership=$MEMBERSHIP"

    if [[ "$MEMBERSHIP" == "inactiveFailed" ]]; then
      HARD_DONE=true
      break
    fi

    sleep 2
  done

  if [[ "$HARD_DONE" != "true" ]]; then
    echo "ERROR: hard failover no terminó dentro del timeout."
  fi

  T_HARD_END=$(date +%s)
  RTO_HARD=$((T_HARD_END - T_HARD_START))

  echo "$RTO_HARD"     > outputs/rto-hard-seconds.txt
  ```

### Tarea 3.6. Observar workload y recuperación

- {% include step_label.html %} Captura las últimas muestras del probe posteriores al hard failover para revisar continuidad, errores y latencia antes de permitir que Operator reconstruya la topología.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    tail -n 50 /tmp/availability.log \
    | tee snapshots/hard-failover-availability.jsonl
  ```

- {% include step_label.html %} Reanuda Operator y deja que reconstruya el estado deseado de tres Data Pods.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":false}}'
  ```

- {% include step_label.html %} Ejecuta el helper de estabilización después de reanudar Operator para comprobar que la recuperación terminó con tres Data nodes `healthy/active` y sin rebalance pendiente.

  ```bash
  ./scripts/wait-primary-stable.sh
  ```

**Salida esperada:** Debe finalizar con `Cluster A estable con tres Data nodes.` antes de iniciar la tarea siguiente.

> **IMPORTANTE:** La práctica no fuerza `delta recovery` manualmente. La disponibilidad de delta depende del estado del nodo y de las condiciones de recuperación; Operator administra el retorno al estado deseado.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## ⚡ Tarea 4. Configurar y medir auto-failover — 9 min

### Tarea 4.1. Validar configuración declarativa

- {% include step_label.html %} Lee del Custom Resource los parámetros de auto-failover y recovery policy para comprobar que la intención declarativa del laboratorio coincide con el escenario que se probará.

  ```bash
  kubectl get couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    -o json \
    | jq '{
        autoFailoverTimeout:
          .spec.cluster.autoFailoverTimeout,
        autoFailoverMaxCount:
          .spec.cluster.autoFailoverMaxCount,
        recoveryPolicy:
          .spec.recoveryPolicy
      }'
  ```

**Salida esperada:**

```text
autoFailoverTimeout = 30s
autoFailoverMaxCount = 1
recoveryPolicy = PrioritizeDataIntegrity
```

### Tarea 4.2. Confirmar settings Couchbase

- {% include step_label.html %} Consulta la configuración efectiva de auto-failover directamente en Couchbase y guarda la evidencia para comparar el estado real con lo declarado por Operator.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/autoFailover \
    | tee snapshots/auto-failover-settings.json \
    | jq '{
        enabled,
        timeout,
        count,
        maxCount
      }'
  ```

**Salida esperada:** Deben mostrarse `enabled`, `timeout`, `count` y `maxCount` con valores coherentes con la configuración del laboratorio.

### Tarea 4.3. Confirmar contador disponible

- {% include step_label.html %} Consulta el contador antes del fallo; un rebalance exitoso normalmente lo devuelve a cero y evita resetear manualmente el historial durante una prueba normal.

  ```bash
  AUTO_COUNT=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/settings/autoFailover \
    | jq -r '.count'
  )
  
  MAX_COUNT=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/settings/autoFailover \
    | jq -r '.maxCount'
  )
  
  echo "Auto-failover count: $AUTO_COUNT"
  echo "Auto-failover maxCount: $MAX_COUNT"
  ```

**Salida esperada:** Se espera `count: 0` y `maxCount: 1`. Si el contador ya alcanzó el máximo, revisa la ejecución anterior y estabiliza/rebalancea el clúster antes de repetir el escenario.

### Tarea 4.4. Pausar Operator y provocar fallo

- {% include step_label.html %} Pausa Operator, selecciona un Data Pod real y elimínalo sin ejecutar failover manual para que Couchbase pueda activar automáticamente el mecanismo configurado tras el timeout.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":true}}'

  TARGET_POD=$(
    ./scripts/list-data-pods.sh \
      | tail -n1
  )

  TARGET_OTP=$(
    curl -s -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
      | jq -r --arg P "$TARGET_POD" '
          .nodes[]
          | select(.hostname | contains($P))
          | .otpNode
        '
  )

  T_AUTO_START=$(date +%s)

  kubectl delete pod \
    -n "$NS_A" \
    "$TARGET_POD" \
    --wait=false
  ```

### Tarea 4.5. Esperar auto-failover

- {% include step_label.html %} Vigila `clusterMembership` del nodo eliminado hasta que Couchbase lo marque `inactiveFailed`, y registra el tiempo transcurrido desde la pérdida del Pod.

  ```bash
  for i in $(seq 1 30); do
    MEMBERSHIP=$(
      curl -s -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default \
        | jq -r --arg OTP "$TARGET_OTP" '
            .nodes[]
            | select(.otpNode == $OTP)
            | .clusterMembership
          '
    )

    echo "$(date +%H:%M:%S) $MEMBERSHIP"

    [[ "$MEMBERSHIP" == "inactiveFailed" ]] && break
    sleep 5
  done

  T_AUTO_END=$(date +%s)
  RTO_AUTO=$((T_AUTO_END - T_AUTO_START))

  echo "$RTO_AUTO" \
    > outputs/rto-auto-seconds.txt
  ```

### Tarea 4.6. Verificar evento y recuperar

- {% include step_label.html %} Consulta nuevamente los settings para confirmar que el contador de auto-failover aumentó después del evento antes de reanudar la reconciliación de Operator.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/autoFailover \
    | jq '{
        enabled,
        timeout,
        count,
        maxCount
      }'
  ```

**Salida esperada:**

```text
count = 1
```

- {% include step_label.html %} Reanuda Operator para recuperar la topología.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":false}}'
  ```

- {% include step_label.html %} Espera nuevamente la estabilización del primario después del auto-failover para restablecer replicas y dejar el clúster preparado para configurar XDCR.

  ```bash
  ./scripts/wait-primary-stable.sh
  ```

**Salida esperada:** Debe finalizar con `Cluster A estable con tres Data nodes.` y `rebalance=none`.

> **CONCEPTO CLAVE:** Auto-failover ha protegido Cluster A. No ha redirigido ninguna aplicación a Cluster B y no ha iniciado un “DR failover”. Auto-failover opera únicamente dentro de un Couchbase cluster.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🌍 Tarea 5. Configurar XDCR A→B con filtrado — 10 min

### Tarea 5.1. Obtener UUID y DNS del Cluster B

- {% include step_label.html %} Obtén el UUID remoto desde `status.clusterId` y valida resolución DNS interna desde Cluster A antes de declarar el remote cluster.

  ```bash
  CLUSTER_B_UUID=$(
    kubectl get couchbasecluster "$CLUSTER_B" \
      -n "$NS_B" \
      -o jsonpath='{.status.clusterId}'
  )
  
  echo "Cluster B UUID: $CLUSTER_B_UUID"
  
  kubectl exec -i \
    -n "$NS_A" \
    cb-lab9-client \
    -- \
    python - << 'PYEOF'
  import socket
  
  print(
      socket.gethostbyname(
          "cb-dr.couchbase-b.svc"
      )
  )
  PYEOF
  ```

**Salida esperada:** El UUID debe contener 32 caracteres hexadecimales y `cb-dr.couchbase-b.svc` debe resolver a una dirección interna. Los clientes SDK continúan usando `cb-dr-srv` para bootstrap KV.

### Tarea 5.2. Habilitar XDCR administrado en Cluster A

- {% include step_label.html %} Añade Cluster B como remote cluster utilizando su DNS Kubernetes estable; Operator 2.9 permite administrar la referencia declarativamente.

  ```bash
  kubectl patch couchbasecluster "$CLUSTER_A" \
    -n "$NS_A" \
    --type=merge \
    -p="{
      \"spec\": {
        \"xdcr\": {
          \"managed\": true,
          \"remoteClusters\": [
            {
              \"name\": \"dr-site\",
              \"uuid\": \"${CLUSTER_B_UUID}\",
              \"hostname\": \"couchbase://cb-dr.couchbase-b.svc?network=default\",
              \"authenticationSecret\": \"cb-admin\",
              \"replications\": {
                \"selector\": {
                  \"matchLabels\": {
                    \"replication\": \"dr-site\"
                  }
                }
              }
            }
          ]
        }
      }
    }"
  ```

> **NOTA:** Si tu instalación 2.9 no exige `uuid`, el campo puede omitirse; 2.9 eliminó el requisito obligatorio. Se conserva aquí para hacer explícita la identidad del destino.
{: .lab-note .info .compact}

### Tarea 5.3. Crear CouchbaseReplication filtrada

- {% include step_label.html %} Crea la replicación `lab9-dr` A→B con un filtro que permite exclusivamente documentos cuyo ID inicia con `order::`.

  ```bash
  cat > xdcr/dr-filtered-replication.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseReplication
  metadata:
    name: dr-filtered
    namespace: couchbase-a
    labels:
      replication: dr-site
  spec:
    bucket: lab9-dr
    remoteBucket: lab9-dr
    filterExpression: 'REGEXP_CONTAINS(META().id, "^order::")'
    filterSkipRestream: false
    compressionType: Auto
    priority: High
  YAMLEOF
  ```

- {% include step_label.html %} Aplica el recurso `CouchbaseReplication` para que Operator cree el pipeline filtrado entre el primario y el bucket homónimo del sitio DR.

  ```bash
  kubectl apply -f xdcr/dr-filtered-replication.yaml
  ```

**Salida esperada:** Kubernetes debe crear `couchbasereplication.couchbase.com/dr-filtered` sin errores de validación.

### Tarea 5.4. Esperar y revisar replicación

- {% include step_label.html %} Da tiempo a Operator para materializar la replicación, lista los recursos `CouchbaseReplication` y consulta las tareas XDCR del primario para confirmar que el pipeline A→B está operativo.

  ```bash
  sleep 20

  kubectl get couchbasereplication \
    -n "$NS_A" \
    -o wide
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/tasks \
    | jq '[
        .[]
        | select(.type == "xdcr")
        | {
            id,
            status,
            source,
            target
          }
      ]' \
    | tee outputs/xdcr-tasks-a.json
  ```

**Salida esperada:**

Debe existir una tarea XDCR para:

```text
lab9-dr → lab9-dr
```

con estado operativo.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🔬 Tarea 6. Validar filtering y métricas XDCR — 7 min

### Tarea 6.1. Crear verificador en Cluster B

- {% include step_label.html %} Crea y ejecuta un verificador desde el cliente DR que compruebe una muestra de IDs permitidos y excluidos para demostrar que el filtro replica `order::*` pero no `internal::*`.

  ```bash
  cat > workload/check_dr_filter.py << 'PYEOF'
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.exceptions import DocumentNotFoundException
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-dr-srv",
      ClusterOptions(
          PasswordAuthenticator(
              "Administrator",
              "Password123!"
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )

  order_hits = 0
  internal_hits = 0

  for i in range(100):
      try:
          collection.get(
              f"order::{i:08d}"
          )
          order_hits += 1
      except DocumentNotFoundException:
          pass

      try:
          collection.get(
              f"internal::{i:08d}"
          )
          internal_hits += 1
      except DocumentNotFoundException:
          pass

  print(f"order sample hits    : {order_hits}/100")
  print(f"internal sample hits : {internal_hits}/100")

  cluster.close()
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp workload/check_dr_filter.py \
    couchbase-b/cb-lab9-client:/tmp/check_dr_filter.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/check_dr_filter.py \
    | tee outputs/xdcr-filter-validation.txt
  ```

**Salida esperada:**

```text
order sample hits    : 100/100
internal sample hits : 0/100
```

### Tarea 6.2. Revisar backlog y estado del pipeline

- {% include step_label.html %} Captura las estadísticas legacy disponibles de XDCR como evidencia complementaria. `changes_left` es backlog, no RPO en segundos.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/lab9-dr/stats \
    | jq '{
        xdcr_changes_left:
          (.op.samples.xdcr_changes_left[-1] // null),
        xdcr_docs_written:
          (.op.samples.xdcr_docs_written[-1] // null)
      }' \
    | tee metrics/xdcr-dr-stats.json
  ```

**Salida esperada:** Debe generarse un JSON con `xdcr_changes_left` y `xdcr_docs_written`; sus valores pueden variar según el instante de la muestra.

### Tarea 6.3. Verificar convergencia elegible

- {% include step_label.html %} Espera un intervalo adicional y repite el verificador sobre Cluster B para confirmar que los documentos elegibles continúan disponibles y los excluidos siguen ausentes.

  ```bash
  sleep 10

  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/check_dr_filter.py
  ```

> **IMPORTANTE:** No compares el itemCount total de A y B. Cluster A contiene `internal::*`, que deliberadamente no debe existir en B.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## ⚔️ Tarea 7. Comparar conflictos seqno y lww — 11 min

### Tarea 7.1. Crear replicaciones bidireccionales de conflicto

Para `seqno` y `lww` se requieren replicaciones independientes en ambas direcciones.

- {% include step_label.html %} Habilita XDCR administrado también en Cluster B hacia Cluster A.

  ```bash
  CLUSTER_A_UUID=$(
    kubectl get couchbasecluster "$CLUSTER_A" \
      -n "$NS_A" \
      -o jsonpath='{.status.clusterId}'
  )
  ```
  ```bash
  kubectl patch couchbasecluster "$CLUSTER_B" \
    -n "$NS_B" \
    --type=merge \
    -p="{
      \"spec\": {
        \"xdcr\": {
          \"managed\": true,
          \"remoteClusters\": [
            {
              \"name\": \"primary-site\",
              \"uuid\": \"${CLUSTER_A_UUID}\",
              \"hostname\": \"couchbase://cb-primary.couchbase-a.svc?network=default\",
              \"authenticationSecret\": \"cb-admin\",
              \"replications\": {
                \"selector\": {
                  \"matchLabels\": {
                    \"replication\": \"primary-site\"
                  }
                }
              }
            }
          ]
        }
      }
    }"
  ```

- {% include step_label.html %} Crea cuatro recursos: seqno A→B, seqno B→A, lww A→B y lww B→A.

  ```bash
  cat > xdcr/conflict-replications.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseReplication
  metadata:
    name: seqno-a-to-b
    namespace: couchbase-a
    labels:
      replication: dr-site
  spec:
    bucket: lab9-seqno
    remoteBucket: lab9-seqno
    compressionType: Auto
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseReplication
  metadata:
    name: lww-a-to-b
    namespace: couchbase-a
    labels:
      replication: dr-site
  spec:
    bucket: lab9-lww
    remoteBucket: lab9-lww
    compressionType: Auto
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseReplication
  metadata:
    name: seqno-b-to-a
    namespace: couchbase-b
    labels:
      replication: primary-site
  spec:
    bucket: lab9-seqno
    remoteBucket: lab9-seqno
    compressionType: Auto
  ---
  apiVersion: couchbase.com/v2
  kind: CouchbaseReplication
  metadata:
    name: lww-b-to-a
    namespace: couchbase-b
    labels:
      replication: primary-site
  spec:
    bucket: lab9-lww
    remoteBucket: lab9-lww
    compressionType: Auto
  YAMLEOF
  ```

- {% include step_label.html %} Aplica las cuatro replicaciones y concede tiempo a Operator para crear los pipelines A→B y B→A de los buckets `seqno` y `lww`.

  ```bash
  kubectl apply -f xdcr/conflict-replications.yaml

  sleep 15
  ```

**Salida esperada:** Deben existir cuatro recursos `CouchbaseReplication` distribuidos entre ambos namespaces sin errores de reconciliación.

### Tarea 7.2. Crear generador de conflictos

- {% include step_label.html %} Crea el mismo script en ambos clientes. Las escrituras se ejecutarán prácticamente al mismo tiempo sobre los dos clusters.

  ```bash
  cat > workload/conflict_writer.py << 'PYEOF'
  import argparse
  import json
  import time
  from datetime import datetime, timezone, timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  parser = argparse.ArgumentParser()
  parser.add_argument("--conn", required=True)
  parser.add_argument("--bucket", required=True)
  parser.add_argument("--cluster-name", required=True)
  parser.add_argument("--key", required=True)
  parser.add_argument("--round", type=int, required=True)

  args = parser.parse_args()

  cluster = Cluster(
      args.conn,
      ClusterOptions(
          PasswordAuthenticator(
              "Administrator",
              "Password123!"
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  collection = (
      cluster.bucket(args.bucket)
      .default_collection()
  )

  doc = {
      "type": "xdcr-conflict-test",
      "written_by": args.cluster_name,
      "round": args.round,
      "application_timestamp":
          datetime.now(timezone.utc).isoformat(),
      "epoch": time.time()
  }

  result = collection.upsert(
      args.key,
      doc
  )

  print(
      json.dumps({
          "cluster": args.cluster_name,
          "bucket": args.bucket,
          "key": args.key,
          "cas": result.cas,
          "document": doc
      })
  )

  cluster.close()
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp workload/conflict_writer.py \
    couchbase-a/cb-lab9-client:/tmp/conflict_writer.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp workload/conflict_writer.py \
    couchbase-b/cb-lab9-client:/tmp/conflict_writer.py
  ```

### Tarea 7.3. Generar conflicto seqno

- {% include step_label.html %} Ejecuta escrituras concurrentes sobre la misma key del bucket `lab9-seqno` desde ambos clústeres y conserva las respuestas para observar qué versión termina resolviendo XDCR.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    python /tmp/conflict_writer.py \
      --conn couchbase://cb-primary-srv \
      --bucket lab9-seqno \
      --cluster-name A \
      --key conflict::seqno::001 \
      --round 1 \
    > outputs/seqno-write-a.json &

  PID_A=$!
  ```

- {% include step_label.html %} Inicia inmediatamente la escritura equivalente desde Cluster B sobre la misma key para generar dos versiones concurrentes.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/conflict_writer.py \
      --conn couchbase://cb-dr-srv \
      --bucket lab9-seqno \
      --cluster-name B \
      --key conflict::seqno::001 \
      --round 1 \
    > outputs/seqno-write-b.json &

  PID_B=$!
  ```

- {% include step_label.html %} Espera que ambas escrituras terminen y concede tiempo a XDCR para resolver y propagar la versión ganadora entre los dos clústeres.

  ```bash
  wait "$PID_A" "$PID_B"

  sleep 15
  ```

**Salida esperada:** Deben existir `outputs/seqno-write-a.json` y `outputs/seqno-write-b.json`, y ambos procesos deben finalizar sin error.

### Tarea 7.4. Generar conflicto LWW

- {% include step_label.html %} Ejecuta dos escrituras cercanas en el tiempo sobre la misma key del bucket `lab9-lww`, introduciendo una ligera separación para facilitar la observación de la política Last Write Wins.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    python /tmp/conflict_writer.py \
      --conn couchbase://cb-primary-srv \
      --bucket lab9-lww \
      --cluster-name A \
      --key conflict::lww::001 \
      --round 1 \
    > outputs/lww-write-a.json &

  PID_A=$!

  sleep 0.25
  ```

- {% include step_label.html %} Ejecuta la segunda escritura desde Cluster B después de la pausa controlada para generar el conflicto que será resuelto mediante LWW.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/conflict_writer.py \
      --conn couchbase://cb-dr-srv \
      --bucket lab9-lww \
      --cluster-name B \
      --key conflict::lww::001 \
      --round 1 \
    > outputs/lww-write-b.json &

  PID_B=$!

  wait "$PID_A" "$PID_B"

  sleep 15
  ```

**Salida esperada:** Deben generarse `outputs/lww-write-a.json` y `outputs/lww-write-b.json`, y ambas escrituras deben completar antes de validar convergencia.

> **NOTA:** El `sleep 0.25` sólo facilita observar una escritura temporalmente posterior en el ejercicio LWW. Couchbase no utiliza `application_timestamp`; utiliza metadata temporal/CAS.
{: .lab-note .info .compact}

### Tarea 7.5. Leer resultados finales

- {% include step_label.html %} Crea un lector genérico y confirma que ambos clusters convergen a la misma versión para cada bucket.

  ```bash
  cat > workload/read_conflict.py << 'PYEOF'
  import argparse
  import json
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  parser = argparse.ArgumentParser()
  parser.add_argument("--conn", required=True)
  parser.add_argument("--bucket", required=True)
  parser.add_argument("--key", required=True)

  args = parser.parse_args()

  cluster = Cluster(
      args.conn,
      ClusterOptions(
          PasswordAuthenticator(
              "Administrator",
              "Password123!"
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  result = (
      cluster.bucket(args.bucket)
      .default_collection()
      .get(args.key)
  )

  print(
      json.dumps({
          "cas": result.cas,
          "document": result.content_as[dict]
      })
  )

  cluster.close()
  PYEOF

  for NS in "$NS_A" "$NS_B"; do
    MSYS_NO_PATHCONV=1 kubectl cp workload/read_conflict.py \
      "${NS}/cb-lab9-client:/tmp/read_conflict.py"
  done
  ```

**Salida esperada:** `read_conflict.py` debe quedar copiado en ambos clientes sin errores.

- {% include step_label.html %} Lee la key de conflicto `seqno` desde Cluster A para registrar la versión final visible después de la convergencia.

  ```bash
  echo "=== SEQNO / A ==="
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    python /tmp/read_conflict.py \
      --conn couchbase://cb-primary-srv \
      --bucket lab9-seqno \
      --key conflict::seqno::001
  ```

- {% include step_label.html %} Lee la misma key `seqno` desde Cluster B y compárala con Cluster A para confirmar que ambos sitios convergieron al mismo contenido.

  ```bash
  echo "=== SEQNO / B ==="
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/read_conflict.py \
      --conn couchbase://cb-dr-srv \
      --bucket lab9-seqno \
      --key conflict::seqno::001
  ```

- {% include step_label.html %} Lee la key del escenario LWW desde Cluster A para observar la versión final seleccionada por Couchbase.

  ```bash
  echo "=== LWW / A ==="
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_A" cb-lab9-client -- \
    python /tmp/read_conflict.py \
      --conn couchbase://cb-primary-srv \
      --bucket lab9-lww \
      --key conflict::lww::001
  ```

- {% include step_label.html %} Lee finalmente la key LWW desde Cluster B para verificar que ambos clústeres muestran la misma versión.

  ```bash
  echo "=== LWW / B ==="
  MSYS_NO_PATHCONV=1 kubectl exec -n "$NS_B" cb-lab9-client -- \
    python /tmp/read_conflict.py \
      --conn couchbase://cb-dr-srv \
      --bucket lab9-lww \
      --key conflict::lww::001
  ```

**Salida esperada:**

Para cada bucket, A y B deben terminar mostrando el mismo `written_by`, el mismo contenido y metadata/CAS convergente.

### Tarea 7.6. Interpretar correctamente

| Política | Criterio principal |
|---|---|
| `seqno` | revision sequence metadata del documento y tie-breakers |
| `lww` | timestamp/CAS de Couchbase |

No confundas `seqno` conflict resolution con el high DCP sequence number del vBucket.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🚨 Tarea 8. Simular desastre del primario y medir RPO/RTO — 9 min

### Tarea 8.1. Generar escrituras mientras XDCR está activo

- {% include step_label.html %} Crea un escritor que produzca mutations confirmadas durante varios segundos y registre cada ACK para congelar XDCR mientras todavía existen escrituras en curso.

  ```bash
  cat > workload/rpo_writer.py << 'PYEOF'
  import json
  import os
  import time
  from datetime import timedelta
  
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions
  
  cluster = Cluster(
      "couchbase://cb-primary-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USERNAME"],
              os.environ["CB_PASSWORD"]
          )
      )
  )
  
  cluster.wait_until_ready(
      timedelta(seconds=30)
  )
  
  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )
  
  for write_id in range(1, 2001):
      timestamp = time.time()
  
      collection.upsert(
          f"order::rpo::{write_id:06d}",
          {
              "type": "order",
              "rpo_write_id": write_id,
              "source_timestamp": timestamp
          }
      )
  
      print(
          json.dumps({
              "write_id": write_id,
              "ack_epoch": timestamp
          }),
          flush=True
      )
  
      time.sleep(0.02)
  
  cluster.close()
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    workload/rpo_writer.py \
    "$NS_A/cb-lab9-client:/tmp/rpo_writer.py"
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$NS_A" \
    cb-lab9-client \
    -- \
    sh -c '
      rm -f /tmp/rpo-acknowledged-writes.jsonl
      python /tmp/rpo_writer.py \
        > /tmp/rpo-acknowledged-writes.jsonl \
        2>&1 &
      echo $! > /tmp/rpo-writer.pid
    '

  sleep 5
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$NS_A" \
    cb-lab9-client \
    -- \
    sh -c '
      echo "RPO writer PID: $(cat /tmp/rpo-writer.pid)"
      tail -n 5 /tmp/rpo-acknowledged-writes.jsonl
    '
  ```

**Salida esperada:** Debe mostrarse un PID remoto y varias líneas JSON con `write_id` y `ack_epoch`, confirmando que el escritor sigue activo dentro del Pod.

### Tarea 8.2. Declarar desastre y congelar la replicación

- {% include step_label.html %} Registra el instante de desastre, pausa XDCR y detén el escritor inmediatamente después para modelar un corte con mutations potencialmente en vuelo.

  ```bash
  DR_DECLARED_EPOCH=$(date +%s)
  
  echo "$DR_DECLARED_EPOCH" \
    > outputs/dr-declared-epoch.txt
  ```
  ```bash
  kubectl patch couchbasereplication dr-filtered \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":true}}'

  sleep 1
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$NS_A" \
    cb-lab9-client \
    -- \
    sh -c '
      if [ -f /tmp/rpo-writer.pid ]; then
        kill "$(cat /tmp/rpo-writer.pid)" 2>/dev/null || true
      fi
    '

  sleep 1
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    "$NS_A/cb-lab9-client:/tmp/rpo-acknowledged-writes.jsonl" \
    outputs/rpo-acknowledged-writes.jsonl

  echo "XDCR congelado y nuevas escrituras detenidas."
  ```

**Salida esperada:** `dr-filtered` debe quedar pausada, el escritor remoto debe detenerse y el archivo local debe conservar los ACK confirmados antes del corte.

### Tarea 8.3. Crear lector de último write disponible en DR

- {% include step_label.html %} Crea un lector que revise todos los IDs confirmados por el primario para contar exactamente cuáles llegaron a DR, evitando asumir que la replicación quedó perfectamente contigua al pausarla.

  ```bash
  cat > workload/rpo_reader.py << 'PYEOF'
  import os
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.exceptions import DocumentNotFoundException
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-dr-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USERNAME"],
              os.environ["CB_PASSWORD"]
          )
      )
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )

  max_write_id = int(
      os.environ["MAX_WRITE_ID"]
  )

  replicated_count = 0
  last = 0
  last_ts = None

  for write_id in range(1, max_write_id + 1):
      try:
          doc = collection.get(
              f"order::rpo::{write_id:06d}"
          ).content_as[dict]

          replicated_count += 1

          if write_id > last:
              last = write_id
              last_ts = doc.get(
                  "source_timestamp"
              )

      except DocumentNotFoundException:
          pass

  missing_count = (
      max_write_id - replicated_count
  )

  print(f"last_replicated_write_id={last}")
  print(f"last_replicated_source_timestamp={last_ts}")
  print(f"replicated_confirmed_count={replicated_count}")
  print(f"missing_confirmed_count={missing_count}")

  cluster.close()
  PYEOF
  ```

- {% include step_label.html %} Copia el lector al cliente DR y obtiene del log local el último write confirmado para limitar la comprobación únicamente al rango que realmente fue reconocido por Cluster A.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    workload/rpo_reader.py \
    "$NS_B/cb-lab9-client:/tmp/rpo_reader.py"

  LAST_ACK=$(
    tail -n 1 outputs/rpo-acknowledged-writes.jsonl \
    | jq -r '.write_id'
  )

  echo "LAST_ACK=$LAST_ACK"
  ```

**Salida esperada:** `LAST_ACK` debe contener un entero mayor que cero y `rpo_reader.py` debe copiarse al cliente DR sin errores de conversión de ruta.

- {% include step_label.html %} Ejecuta el lector en Cluster B usando `LAST_ACK` como límite superior y conserva el total replicado, faltantes y timestamp de la última mutation disponible.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$NS_B" \
    cb-lab9-client \
    -- \
    env MAX_WRITE_ID="$LAST_ACK" \
    python /tmp/rpo_reader.py \
    | tee outputs/rpo-dr-observed.txt
  ```

**Salida esperada:** Deben mostrarse `last_replicated_write_id`, `replicated_confirmed_count` y `missing_confirmed_count`; el total de faltantes debe ser cero o positivo.

### Tarea 8.4. Calcular pérdida experimental

- {% include step_label.html %} Calcula las mutations confirmadas que no están en DR y estima el RPO temporal usando el timestamp de origen de la última mutation disponible, sin convertir métricas de backlog en segundos.

  ```bash
  LAST_DR=$(
    grep 'last_replicated_write_id=' \
      outputs/rpo-dr-observed.txt \
    | cut -d= -f2
  )

  LAST_DR_TS=$(
    grep 'last_replicated_source_timestamp=' \
      outputs/rpo-dr-observed.txt \
    | cut -d= -f2
  )

  LOST_WRITES=$(
    grep 'missing_confirmed_count=' \
      outputs/rpo-dr-observed.txt \
    | cut -d= -f2
  )

  RPO_SECONDS=$(
    awk \
      -v disaster="$DR_DECLARED_EPOCH" \
      -v replicated="$LAST_DR_TS" \
      'BEGIN {
        if (replicated == "" || replicated == "None") {
          print "unknown"
          exit
        }

        lag = disaster - replicated

        if (lag < 0) {
          lag = 0
        }

        printf "%.3f", lag
      }'
  )

  echo "LAST_ACK=$LAST_ACK"
  echo "LAST_DR=$LAST_DR"
  echo "LOST_WRITES=$LOST_WRITES"
  echo "RPO_SECONDS=$RPO_SECONDS"

  {
    echo "last_acknowledged_write=${LAST_ACK}"
    echo "last_available_in_dr=${LAST_DR}"
    echo "lost_acknowledged_writes=${LOST_WRITES}"
    echo "last_available_source_timestamp=${LAST_DR_TS}"
    echo "rpo_seconds_observed=${RPO_SECONDS}"
  } | tee outputs/rpo-result.txt
  ```

**Salida esperada:** `LOST_WRITES` debe ser cero o positivo y `RPO_SECONDS` debe representar el retraso temporal observado respecto al instante de desastre.

### Tarea 8.5. Medir RTO de aplicación hacia DR

- {% include step_label.html %} Ejecuta GET y UPSERT contra Cluster B y toma el timestamp después del primer healthcheck exitoso para medir correctamente el RTO desde la declaración del desastre.

  ```bash
  cat > workload/dr_healthcheck.py << 'PYEOF'
  import os
  import time
  from datetime import timedelta
  
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions
  
  cluster = Cluster(
      "couchbase://cb-dr-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USERNAME"],
              os.environ["CB_PASSWORD"]
          )
      )
  )
  
  cluster.wait_until_ready(
      timedelta(seconds=30)
  )
  
  collection = (
      cluster.bucket("lab9-dr")
      .default_collection()
  )
  
  collection.get("order::00000000")
  
  collection.upsert(
      "order::dr-healthcheck",
      {
          "type": "order",
          "dr_active": True,
          "epoch": time.time()
      }
  )
  
  print("DR_READ_WRITE_OK")
  
  cluster.close()
  PYEOF
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    workload/dr_healthcheck.py \
    "$NS_B/cb-lab9-client:/tmp/dr_healthcheck.py"
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$NS_B" \
    cb-lab9-client \
    -- \
    python /tmp/dr_healthcheck.py
  
  T_DR_READY=$(date +%s)
  RTO_DR=$((T_DR_READY - DR_DECLARED_EPOCH))
  
  echo "$RTO_DR" \
    > outputs/rto-dr-seconds.txt
  
  echo "RTO DR: ${RTO_DR}s"
  ```

**Salida esperada:** Debe aparecer `DR_READ_WRITE_OK`; `outputs/rto-dr-seconds.txt` debe contener un entero no negativo.

> **IMPORTANTE:** Este RTO mide disponibilidad de la aplicación contra Cluster B. No incluye DNS TTL, balanceadores, routing global o intervención humana porque ambos sitios se simulan dentro del mismo EKS.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

--- 

## 📘 Tarea 9. Construir runbook de Disaster Recovery — 5 min

### Tarea 9.1. Recopilar tiempos

- {% include step_label.html %} Carga desde los archivos de evidencia los tiempos medidos de graceful, hard, auto-failover y DR para utilizarlos posteriormente en el runbook consolidado.

  ```bash
  RTO_GRACEFUL=$(cat outputs/rto-graceful-seconds.txt)
  RTO_HARD=$(cat outputs/rto-hard-seconds.txt)
  RTO_AUTO=$(cat outputs/rto-auto-seconds.txt)
  RTO_DR=$(cat outputs/rto-dr-seconds.txt)

  echo "Graceful : ${RTO_GRACEFUL}s"
  echo "Hard     : ${RTO_HARD}s"
  echo "Auto     : ${RTO_AUTO}s"
  echo "DR       : ${RTO_DR}s"
  ```

**Salida esperada:** Deben imprimirse cuatro valores en segundos correspondientes a graceful, hard, auto-failover y conmutación hacia DR.

### Tarea 9.2. Generar runbook

- {% include step_label.html %} Crea un runbook que separe mantenimiento, fallo de nodo y desastre de sitio, evitando presentar XDCR como auto-failover entre clusters.

  ```bash
  cat > reports/runbook-dr.md << EOF
  # Runbook DR — Couchbase CS400 Lab 9

  **Fecha:** $(date -Iseconds)

  ## Objetivos del caso

  | Métrica | Objetivo |
  |---|---:|
  | RPO temporal objetivo | <= ${RPO_OBJECTIVE_SECONDS} s |
  | RTO DR | <= ${RTO_OBJECTIVE_SECONDS} s |

  ## Mediciones

  | Operación | Tiempo medido |
  |---|---:|
  | Finalización de graceful failover | ${RTO_GRACEFUL} s |
  | Finalización de hard failover | ${RTO_HARD} s |
  | Detección + auto-failover | ${RTO_AUTO} s |
  | RTO de aplicación hacia DR | ${RTO_DR} s |

  ## RPO experimental

  La prueba cuantifica mutations confirmadas no disponibles en DR; no convierte automáticamente ese resultado a segundos.

  \`\`\`text
  $(cat outputs/rpo-result.txt)
  \`\`\`

  ## Arquitectura

  - Cluster A: cb-primary.
  - Cluster B: cb-dr.
  - Server Groups de Cluster A: us-west-2a, us-west-2b, us-west-2c.
  - Replica count: 1.
  - DR replication: lab9-dr A -> B.
  - Filter: sólo IDs order::*.
  - Conflict test: lab9-seqno y lab9-lww en replicación bidireccional.

  ## Escenario 1 — Mantenimiento planificado

  1. Confirmar salud del clúster y replicas.
  2. Iniciar graceful failover.
  3. Confirmar continuidad del workload.
  4. Ejecutar mantenimiento.
  5. Recuperar el miembro mediante el mecanismo de administración correspondiente.
  6. Esperar rebalance/Available.
  7. Confirmar 1024 active vBuckets.

  ## Escenario 2 — Fallo abrupto de un nodo

  1. Confirmar que el nodo está realmente no disponible.
  2. Validar que existe replica suficiente.
  3. Ejecutar hard failover sólo cuando la pérdida del nodo sea definitiva.
  4. Medir errores y disponibilidad de la aplicación.
  5. Permitir que Operator recupere el estado deseado.
  6. Validar health y distribución de vBuckets.

  ## Escenario 3 — Desastre del sitio primario

  1. Declarar el incidente y registrar timestamp.
  2. Detener escrituras hacia Cluster A.
  3. Verificar que Cluster B está healthy.
  4. Verificar el último write disponible en DR.
  5. Calcular RPO experimental.
  6. Redirigir aplicación a Cluster B.
  7. Ejecutar GET + UPSERT de healthcheck.
  8. Registrar RTO.
  9. Mantener XDCR controlado para evitar conflictos accidentales.
  10. Planificar failback separado; no restaurar tráfico a A sin validar convergencia.

  ## Importante

  Auto-failover Couchbase protege nodos dentro de un único cluster.
  No redirige aplicaciones entre Cluster A y Cluster B.
  La conmutación de sitio requiere un mecanismo externo de application routing.
  EOF
  ```

- {% include step_label.html %} Muestra el runbook generado para revisar que incluya objetivos, mediciones y procedimientos diferenciados para los tres escenarios operativos.

  ```bash
  cat reports/runbook-dr.md
  ```

**Salida esperada:** Debe mostrarse el contenido completo de `reports/runbook-dr.md` con las tablas de RPO/RTO y los procedimientos definidos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación final y reporte — 4 min

### Tarea 10.1. Reanudar XDCR DR

- {% include step_label.html %} Quita la pausa de `dr-filtered` y concede un breve intervalo de convergencia para dejar la replicación nuevamente activa antes de ejecutar la validación final.

  ```bash
  kubectl patch couchbasereplication dr-filtered \
    -n "$NS_A" \
    --type=merge \
    -p '{"spec":{"paused":false}}'

  sleep 10
  ```

**Salida esperada:** La replicación `dr-filtered` debe quedar nuevamente activa antes de ejecutar la validación final.

### Tarea 10.2. Crear validate.sh

- {% include step_label.html %} Crea una suite final que compruebe zonas, Server Groups, Data nodes, health, vBuckets, replicaciones, filtering, RPO, RTO y existencia del runbook mediante criterios objetivos.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab9/validate.sh
  ```

  ```bash
  chmod +x scripts/validate.sh
  ./scripts/validate.sh \
    | tee reports/validation-final.txt
  ```

### Tarea 10.3. Generar reporte consolidado

- {% include step_label.html %} Consolida en un único Markdown las evidencias principales de topología, tiempos de failover, RPO, RTO, filtering y validación para conservar el resultado final del laboratorio.

  ```bash
  {
    echo "# REPORTE FINAL - LAB 9"
    echo
    echo "## Topología y zonas"
    cat outputs/data-pods-zones.txt

    echo
    echo "## Graceful RTO"
    cat outputs/rto-graceful-seconds.txt

    echo
    echo "## Hard RTO"
    cat outputs/rto-hard-seconds.txt

    echo
    echo "## Auto RTO"
    cat outputs/rto-auto-seconds.txt

    echo
    echo "## DR RTO"
    cat outputs/rto-dr-seconds.txt

    echo
    echo "## RPO experimental"
    cat outputs/rpo-result.txt

    echo
    echo "## XDCR filter"
    cat outputs/xdcr-filter-validation.txt

    echo
    echo "## Validation"
    cat reports/validation-final.txt
  } | tee reports/final-report.md
  ```

**Salida esperada:** Debe crearse `reports/final-report.md` con topología, tiempos de failover, RPO, RTO, filtering y el resumen de validación.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

- {% include step_label.html %} Detén el probe de disponibilidad con `Ctrl+C` en la terminal donde continúa ejecutándose.

- {% include step_label.html %} Conserva `reports/`, `outputs/`, `metrics/` y `snapshots/`; forman parte de las evidencias del laboratorio.

- {% include step_label.html %} Si conservarás EKS para otra práctica, elimina sólo los recursos específicos de XDCR y los clientes temporales.

  ```bash
  kubectl delete couchbasereplication \
    -n "$NS_A" \
    --all

  kubectl delete couchbasereplication \
    -n "$NS_B" \
    --all

  kubectl delete pod cb-lab9-client \
    -n "$NS_A" \
    --ignore-not-found

  kubectl delete pod cb-lab9-client \
    -n "$NS_B" \
    --ignore-not-found
  ```

**Salida esperada:** Las replicaciones y los Pods cliente deben eliminarse o reportarse como inexistentes sin detener la limpieza.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén los port-forward de 8091 y 9091 con `Ctrl+C`.

- {% include step_label.html %} Elimina todo EKS mediante el script de ciclo de vida.

  ```bash
  cd /c/LABS/couchbase-nosql/lab9
  source lab.env

  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe completar la eliminación del clúster y de los recursos administrados asociados.

- {% include step_label.html %} Confirma que AWS ya no encuentre el clúster.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:**

```text
ResourceNotFoundException
```