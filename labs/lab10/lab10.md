---
layout: lab
title: "Práctica 10: Despliegue y recuperación de Couchbase en Kubernetes"
permalink: /lab10/lab10/
images_base: /labs/lab10/img
duration: "84 minutos"
objective:
  - Validar la arquitectura declarativa de Couchbase Operator 2.92.0 en Amazon EKS mediante el despliegue de un clúster MDS (versión 7.6.2) con almacenamiento gp3, analizando el bucle de reconciliación ante cambios de configuración, escalados y fallos simulados para generar una matriz de convergencia de estados.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Couchbase Server, MDS, rebalance, Kubernetes, Amazon EKS y conceptos básicos de Operator.
  - Tener una cuenta AWS con permisos para EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl y jq disponibles desde Git Bash.
  - Comprender Pods, Services, PVC, PV, StorageClass, requests/limits y Custom Resource Definitions.
introduction:
  - En esta práctica utilizarás Amazon EKS como plataforma de ejecución y profundizarás en el comportamiento del Couchbase Kubernetes Operator. En lugar de limitarte a desplegar un clúster, analizarás el flujo completo desde un Custom Resource hasta el estado real de Couchbase. Observarás cómo el Admission Controller valida cambios, cómo Kubernetes programa Pods y volúmenes, cómo el Operator compara estado deseado y estado actual, y cómo Couchbase Server aplica membership, rebalanceo y configuración de buckets. La práctica culmina con troubleshooting por capas para que puedas identificar si un fallo pertenece a validación, scheduling, runtime o reconciliación.
slug: lab10
lab_number: 10
final_result: >
  Al finalizar la práctica habrás desplegado y escalado un CouchbaseCluster Enterprise 7.6.2 sobre Amazon EKS, verificado PersistentVolumes gp3, demostrado recuperación tras pérdida de un Pod sin pérdida del documento de prueba, actualizado un bucket declarativamente, diagnosticado cuatro tipos de fallo en capas diferentes y generado un dossier que relaciona desired state, Kubernetes state y Couchbase state.
notes:
  - Los 84 minutos corresponden exclusivamente al trabajo funcional de la práctica. La creación y destrucción de Amazon EKS quedan fuera del tiempo.
  - La práctica utiliza Couchbase Kubernetes Operator 2.92.0 y Couchbase Server Enterprise 7.6.2.
  - Se utilizan cuatro workers `m6i.xlarge` distribuidos entre tres Availability Zones; el cuarto worker permite completar el scale-out manteniendo `antiAffinity: true`.
  - La StorageClass gp3 utiliza WaitForFirstConsumer; por ello no se espera que un PVC aislado pase a Bound antes de tener un Pod consumidor.
  - El clúster comienza con dos Pods Data y uno Query + Index; después escala Data de 2 a 3.
  - El port-forward utiliza el Service estable <cluster>-ui y no un Pod específico.
  - Los mensajes exactos de logs no se consideran criterio de éxito; se validan estados, condiciones, recursos y respuestas reales.
  - Los errores de troubleshooting se generan de forma independiente para evitar que un fallo temprano oculte los siguientes.
  - No se eliminan CRDs manualmente durante la limpieza. Borrar un CRD puede eliminar los Custom Resources asociados.
  - El `CouchbaseCluster` se crea una sola vez con su configuración completa. Después del bootstrap no se reaplica el manifiesto completo; los cambios de las Tareas 5 y 7 actualizan únicamente el campo que se desea estudiar.
  - Las cuotas de servicio se declaran desde el inicio: Data `1Gi` permite crear el bucket en `512Mi` y aumentarlo posteriormente a `768Mi` sin intervención correctiva.
references:
  - text: "Couchbase Kubernetes Operator Overview"
    url: "https://docs.couchbase.com/operator/current/overview.html"
  - text: "Couchbase Kubernetes Operator Release Notes"
    url: "https://docs.couchbase.com/operator/current/release-notes.html"
  - text: "Install the Couchbase Kubernetes Operator"
    url: "https://docs.couchbase.com/operator/current/install-kubernetes.html"
  - text: "Dynamic Admission Controller and Validation"
    url: "https://docs.couchbase.com/operator/current/concept-validation.html"
  - text: "Persistent Volumes with the Couchbase Kubernetes Operator"
    url: "https://docs.couchbase.com/operator/current/howto-persistent-volumes.html"
  - text: "CouchbaseCluster Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasecluster.html"
  - text: "CouchbaseBucket Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasebucket.html"
  - text: "Troubleshooting the Couchbase Kubernetes Operator"
    url: "https://docs.couchbase.com/operator/current/troubleshooting-operator.html" 
prev: /lab9/lab9/
next: /lab11/lab11/
---

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona `C:\LABS\couchbase-nosql` y crea una terminal integrada **Git Bash** para utilizar el mismo entorno operativo de las prácticas anteriores.

**Salida esperada:** Visual Studio Code debe mostrar `C:\LABS\couchbase-nosql` como directorio de trabajo y una terminal Git Bash disponible.

- {% include step_label.html %} Crea los directorios que separarán manifiestos, scripts, pruebas de troubleshooting, snapshots, métricas y reportes.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab10/{scripts,manifests,troubleshooting,snapshots,metrics,outputs,reports}
  cd /c/LABS/couchbase-nosql/lab10

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:**

```text
/c/LABS/couchbase-nosql/lab10
./manifests
./metrics
./outputs
./reports
./scripts
./snapshots
./troubleshooting
```

---

## ☁️ Preparación de Amazon EKS

## Crear variables

- {% include step_label.html %} Crea `lab.env` para centralizar nombres, versiones y credenciales del laboratorio.

  ```bash
  cat > lab.env << 'ENVEOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab10"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"

  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-lab-cluster"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"

  export CB_OPERATOR_VERSION="2.92.0"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"

  export CB_BUCKET="lab-bucket"
  ENVEOF

  source lab.env
  ```

**Salida esperada:** El archivo `lab.env` debe quedar creado y `source lab.env` no debe devolver errores.

## Crear script de ciclo de vida EKS

- {% include step_label.html %} Escribe el contenido completo del script de ciclo de vida para crear, consultar o eliminar el clúster EKS usando las variables definidas en `lab.env`.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab10/eks-cluster.sh
  ```

**Salida esperada:** Debe crearse `scripts/eks-cluster.sh` con las funciones `create`, `status` y `delete` definidas.

- {% include step_label.html %} Asigna permisos de ejecución al script y valida su sintaxis Bash antes de utilizarlo contra la cuenta AWS.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```

**Salida esperada:** `bash -n` no debe devolver errores de sintaxis.

- {% include step_label.html %} Ejecuta la creación de EKS y espera que los cuatro workers queden `Ready`; este tiempo continúa fuera de los 84 minutos funcionales.

  ```bash
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** Deben existir cuatro workers `m6i.xlarge` en estado `Ready`, distribuidos entre `us-west-2a`, `us-west-2b` y `us-west-2c`.

- {% include step_label.html %} Confirma capacidad y distribución de zonas antes de instalar Couchbase para evitar que el scale-out posterior quede bloqueado por `antiAffinity`.

  ```bash
  kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
  ```

**Salida esperada:** Deben observarse cuatro nodos `Ready` y al menos un worker en cada una de las tres Availability Zones.

## Crear StorageClass gp3

- {% include step_label.html %} Crea la StorageClass usada por los PersistentVolumeClaims de Couchbase. `WaitForFirstConsumer` retrasa el binding hasta conocer la zona del Pod consumidor.

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

**Salida esperada:** Debe crearse `manifests/storageclass-gp3.yaml` con provisioner `ebs.csi.aws.com` y `WaitForFirstConsumer`.

- {% include step_label.html %} Aplica la StorageClass y confirma que Kubernetes acepta el provisioner EBS CSI antes de crear PVC de Couchbase.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

**Salida esperada:** Debe crearse o configurarse `storageclass.storage.k8s.io/gp3-couchbase` sin errores.

## Instalar Operator 2.92.0

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 mediante Helm, incluyendo Admission Controller y CRDs, pero sin desplegar automáticamente un CouchbaseCluster.

  ```bash
  helm repo add couchbase \
    https://couchbase-partners.github.io/helm-charts/

  helm repo update
  ```

**Salida esperada:** El repositorio `couchbase` debe quedar agregado y actualizado sin errores.

- {% include step_label.html %} Instala o actualiza la release `cb-operator` en el namespace de Couchbase, incluyendo CRDs y Admission Controller pero sin crear automáticamente un `CouchbaseCluster`.

  ```bash
  helm upgrade --install cb-operator \
    couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

**Salida esperada:** Helm debe confirmar que la release `cb-operator` fue instalada o actualizada correctamente.

- {% include step_label.html %} Espera que todos los Deployments instalados por el chart queden disponibles.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

**Salida esperada:** Todos los Deployments instalados por el chart deben alcanzar la condición `Available` antes del timeout.

---

## 🔎 Tarea 1. Inspeccionar Operator, DAC, CRDs y webhooks — 8 min

### Tarea 1.1. Confirmar versión instalada

- {% include step_label.html %} Revisa la release Helm y los Deployments para confirmar que la plataforma administrativa está disponible antes de crear recursos Couchbase.

  ```bash
  helm list -n "$CB_NAMESPACE"

  kubectl get deployment \
    -n "$CB_NAMESPACE" \
    -o wide
  ```

**Salida esperada:**

Debe existir una release `cb-operator` y los componentes del Operator deben mostrar réplicas `AVAILABLE`.

### Tarea 1.2. Identificar dinámicamente el Deployment del Operator

- {% include step_label.html %} Descubre el Deployment principal sin asumir un nombre fijo generado por Helm.

  ```bash
  OPERATOR_DEPLOYMENT=$(
    kubectl get deployment \
      -n "$CB_NAMESPACE" \
      -o name \
      | grep 'operator' \
      | grep -v 'admission' \
      | head -n 1 \
      | cut -d/ -f2
  )

  echo "Operator Deployment: $OPERATOR_DEPLOYMENT"
  ```

**Salida esperada:** Debe mostrarse el Deployment principal del Operator y no el Admission Controller.

### Tarea 1.3. Verificar CRDs esenciales

- {% include step_label.html %} Valida CRDs concretos en lugar de depender de una cantidad total que puede cambiar entre releases.

  ```bash
  for CRD in \
    couchbaseclusters.couchbase.com \
    couchbasebuckets.couchbase.com \
    couchbasereplications.couchbase.com \
    couchbaseautoscalers.couchbase.com \
    couchbasebackups.couchbase.com
  do
    kubectl get crd "$CRD" \
      -o custom-columns='NAME:.metadata.name,CREATED:.metadata.creationTimestamp'
  done
  ```

**Salida esperada:** Cada CRD debe devolverse sin `NotFound`.

### Tarea 1.4. Explorar el schema mediante kubectl explain

- {% include step_label.html %} Utiliza el OpenAPI schema del CRD para explorar los campos de `CouchbaseCluster` y `CouchbaseBucket`.

  ```bash
  kubectl explain couchbasecluster.spec
  ```

**Salida esperada:** Debe mostrarse el schema general de `spec` sin errores.

- {% include step_label.html %} Consulta específicamente la definición de `spec.servers` para revisar los campos disponibles en las server classes del clúster.

  ```bash
  kubectl explain couchbasecluster.spec.servers
  ```

**Salida esperada:** Debe mostrarse la descripción del arreglo `servers` y sus campos soportados.

- {% include step_label.html %} Consulta el schema de `CouchbaseBucket.spec` para revisar las propiedades declarativas disponibles para los buckets administrados.

  ```bash
  kubectl explain couchbasebucket.spec
  ```

**Salida esperada:** Debe mostrarse el schema de `CouchbaseBucket.spec` sin errores.

- {% include step_label.html %} Consulta el campo `memoryQuota` para confirmar su tipo y descripción antes de modificar la cuota del bucket más adelante.

  ```bash
  kubectl explain couchbasebucket.spec.memoryQuota
  ```

**Salida esperada:** `kubectl explain` debe devolver el schema y descripción de los campos sin errores.

### Tarea 1.5. Verificar webhooks del Admission Controller

- {% include step_label.html %} Lista los webhooks asociados con Couchbase para comprobar que el Dynamic Admission Controller está registrado en la API de Kubernetes.

  ```bash
  kubectl get validatingwebhookconfigurations \
    | grep -i couchbase || true
  ```

**Salida esperada:** Debe mostrarse la configuración de validación asociada con Couchbase cuando esté registrada por el chart.

- {% include step_label.html %} Consulta también las `MutatingWebhookConfiguration` para identificar si la instalación registró webhooks de mutación relacionados con Couchbase.

  ```bash
  kubectl get mutatingwebhookconfigurations \
    | grep -i couchbase || true
  ```

**Salida esperada:** Si existe un webhook mutating de Couchbase debe mostrarse; una salida vacía no debe detener la práctica por `|| true`.

### Tarea 1.6. Capturar logs iniciales

- {% include step_label.html %} Guarda una muestra de logs del Operator como baseline para compararla con los eventos de escalamiento, recuperación y troubleshooting.

  ```bash
  kubectl logs \
    -n "$CB_NAMESPACE" \
    deployment/"$OPERATOR_DEPLOYMENT" \
    --tail=40 \
    | tee outputs/operator-baseline.log
  ```

**Salida esperada:** Debe generarse `outputs/operator-baseline.log` con una muestra reciente de logs del Operator. La tarea debe confirmar:

```text
Helm release instalada
Operator disponible
Admission Controller registrado
CRDs esenciales presentes
schema consultable mediante kubectl explain
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 💾 Tarea 2. Validar gp3, EBS CSI y el modelo de persistencia — 7 min

### Tarea 2.1. Inspeccionar StorageClass

- {% include step_label.html %} Guarda el manifiesto efectivo de `gp3-couchbase` para documentar provisioner, reclaim policy y modalidad de binding.

  ```bash
  kubectl get storageclass gp3-couchbase \
    -o yaml \
    | tee outputs/storageclass-gp3.yaml
  ```

**Salida esperada:** Debe generarse `outputs/storageclass-gp3.yaml` con la definición efectiva de `gp3-couchbase`.

- {% include step_label.html %} Extrae los atributos relevantes para confirmar el modelo de provisioning dinámico.

  ```bash
  kubectl get storageclass gp3-couchbase \
    -o json \
    | jq '{
        provisioner,
        reclaimPolicy,
        volumeBindingMode,
        allowVolumeExpansion,
        parameters
      }'
  ```

**Salida esperada:**

```text
provisioner = ebs.csi.aws.com
volumeBindingMode = WaitForFirstConsumer
allowVolumeExpansion = true
```

### Tarea 2.2. Verificar EBS CSI

- {% include step_label.html %} Confirma que los componentes del driver EBS CSI están ejecutándose antes de depender del aprovisionamiento dinámico de volúmenes.

  ```bash
  kubectl get pods -n kube-system \
    | grep ebs-csi
  ```

**Salida esperada:** Deben mostrarse los componentes `ebs-csi-controller` y `ebs-csi-node` ejecutándose en `kube-system`.

### Tarea 2.3. Comprender WaitForFirstConsumer

> **IMPORTANTE:** No crees un PVC aislado esperando que quede inmediatamente `Bound`. Con `WaitForFirstConsumer`, Kubernetes espera un Pod consumidor para seleccionar una Availability Zone compatible y aprovisionar el volumen allí.
{: .lab-note .important .compact}

### Tarea 2.4. Confirmar tres Availability Zones

- {% include step_label.html %} Registra nuevamente los workers y sus labels de zona para relacionar scheduling de Pods con la topología zonal de EBS.

  ```bash
  kubectl get nodes \
    -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
    | tee snapshots/nodes-and-zones.txt
  ```

**Salida esperada:**

Workers disponibles en al menos:

```text
us-west-2a
us-west-2b
us-west-2c
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🏗️ Tarea 3. Desplegar CouchbaseCluster MDS y bucket — 14 min

### Tarea 3.1. Crear Secret administrativo

- {% include step_label.html %} Crea el Secret sin imprimir sus valores base64; sólo se validarán las claves presentes.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
 ```

**Salida esperada:** Kubernetes debe crear o configurar `secret/cb-admin` sin imprimir los valores de las credenciales.

- {% include step_label.html %} Verifica únicamente las claves almacenadas en el Secret administrativo para confirmar que existen `username` y `password` sin revelar sus valores.

  ```bash
  kubectl get secret cb-admin \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '.data | keys'
  ```

**Salida esperada:**

```json
[
  "password",
  "username"
]
```

### Tarea 3.2. Crear CouchbaseCluster

- {% include step_label.html %} Crea el manifiesto MDS completo desde el inicio, incluyendo cuotas de Data e Index suficientes para el bucket, anti-affinity y persistencia gp3.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-lab-cluster
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-7.6.2

    antiAffinity: true

    security:
      adminSecret: cb-admin
      podSecurityContext:
        fsGroup: 1000

    cluster:
      dataServiceMemoryQuota: 1Gi
      indexServiceMemoryQuota: 512Mi
      autoFailoverTimeout: 120s
      autoFailoverMaxCount: 1
      autoCompaction:
        databaseFragmentationThreshold:
          percent: 30
        parallelCompaction: false
        tombstonePurgeInterval: 72h
      indexer:
        storageMode: plasma

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - query

    buckets:
      managed: true

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
          default: couchbase-data

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
          default: couchbase-index

    volumeClaimTemplates:
      - metadata:
          name: couchbase-data
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 20Gi

      - metadata:
          name: couchbase-index
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 15Gi
  YAMLEOF
  ```

**Salida esperada:** Debe crearse el manifiesto con Data `1Gi`, Index `512Mi`, Plasma, dos Data Pods, un Query + Index Pod y persistencia gp3.

### Tarea 3.3. Revisar cambio antes de aplicar

- {% include step_label.html %} Ejecuta `kubectl diff`; en una creación nueva devolverá diferencias completas y puede finalizar con código distinto de cero sin significar error funcional.

  ```bash
  kubectl diff \
    --server-side \
    -f manifests/couchbase-cluster.yaml || true
  ```

**Salida esperada:** En una creación nueva deben mostrarse diferencias del recurso; el código distinto de cero queda neutralizado por `|| true`.

### Tarea 3.4. Aplicar y esperar convergencia

- {% include step_label.html %} Aplica el `CouchbaseCluster` mediante Server-Side Apply para registrar el desired state que será reconciliado por el Operator.

  ```bash
  kubectl apply \
    --server-side \
    -f manifests/couchbase-cluster.yaml
  ```

**Salida esperada:** Kubernetes debe confirmar la creación o configuración de `couchbasecluster.couchbase.com/cb-lab-cluster`.

- {% include step_label.html %} Espera a que el Custom Resource reporte la condición `Available` para confirmar que la convergencia inicial terminó correctamente.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    couchbasecluster/"$CB_CLUSTER" \
    --timeout=15m
  ```

**Salida esperada:** El comando debe finalizar indicando que la condición `Available` fue alcanzada antes de 15 minutos.

- {% include step_label.html %} Verifica las cuotas declaradas en el `CouchbaseCluster` antes de crear el bucket; esta comprobación evita que Admission Controller rechace `memoryQuota: 512Mi`.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '{
      dataServiceMemoryQuota:
        .spec.cluster.dataServiceMemoryQuota,
      indexServiceMemoryQuota:
        .spec.cluster.indexServiceMemoryQuota,
      indexStorageMode:
        .spec.cluster.indexer.storageMode
    }'
  ```

**Salida esperada:**

```json
{
  "dataServiceMemoryQuota": "1Gi",
  "indexServiceMemoryQuota": "512Mi",
  "indexStorageMode": "plasma"
}
```

### Tarea 3.5. Crear CouchbaseBucket

- {% include step_label.html %} Declara un bucket Couchstore con una réplica y 512 MiB de cuota por Data node.

  ```bash
  cat > manifests/lab-bucket.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab-bucket
    namespace: couchbase
  spec:
    memoryQuota: 512Mi
    replicas: 1
    storageBackend: couchstore
    evictionPolicy: valueOnly
    conflictResolution: seqno
  YAMLEOF
  ```

**Salida esperada:** Debe crearse `manifests/lab-bucket.yaml` con cuota `512Mi`, una réplica y backend Couchstore.

- {% include step_label.html %} Aplica el `CouchbaseBucket` para que Operator cree `lab-bucket` con una réplica y backend Couchstore.

  ```bash
  kubectl apply -f manifests/lab-bucket.yaml
  ```

**Salida esperada:** Debe crearse `couchbasebucket.couchbase.com/lab-bucket` sin errores de cuota o validación.

- {% include step_label.html %} Confirma que el Custom Resource del bucket conserva la cuota de 512Mi y queda asociado con el clúster administrado.

  ```bash
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '{
      name: .metadata.name,
      memoryQuota: .spec.memoryQuota,
      replicas: .spec.replicas,
      storageBackend: .spec.storageBackend
    }'
  ```

**Salida esperada:** Debe mostrarse `lab-bucket`, `512Mi`, una réplica y `couchstore`.

> **NOTA:** `memoryQuota` representa la cuota del bucket por Data Service node, no una suma global independiente del número de Data nodes.
{: .lab-note .info .compact}

### Tarea 3.6. Verificar Pods y PVC

- {% include step_label.html %} Registra los Pods del clúster después del despliegue para comprobar que las tres instancias Couchbase se encuentran ejecutándose.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" -o wide \
    | tee snapshots/pods-after-deploy.txt
  ```

**Salida esperada:** Deben observarse dos Pods Data y un Pod Query + Index en estado `Running`.

- {% include step_label.html %} Registra los PersistentVolumeClaims creados por las plantillas del clúster para comprobar que el almacenamiento persistente fue aprovisionado.

  ```bash
  kubectl get pvc -n "$CB_NAMESPACE" -o wide \
    | tee snapshots/pvc-after-deploy.txt
  ```

**Salida esperada:** Deben existir tres PVC en estado `Bound`.

### Tarea 3.7. Verificar PV y zona

- {% include step_label.html %} Relaciona cada PersistentVolume gp3 con su claim y Availability Zone para documentar la afinidad zonal seleccionada por EBS CSI.

  ```bash
  kubectl get pv \
    -o custom-columns='PV:.metadata.name,SC:.spec.storageClassName,CLAIM:.spec.claimRef.name,NODE_AFFINITY:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]' \
    | grep 'gp3-couchbase' \
    | tee outputs/pv-zone-mapping.txt
  ```

**Salida esperada:** Deben mostrarse los PV de `gp3-couchbase`, sus claims asociados y una Availability Zone válida.

### Tarea 3.8. Helpers de descubrimiento y estabilización

- {% include step_label.html %} Crea un helper para descubrir Data Pods mediante labels de servicio generadas por Operator, evitando depender de nombres derivados de la server class.

  ```bash
  cat > scripts/list-data-pods.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_data=enabled" \
    -o json \
  | jq -r '
      .items[]
      | select(.status.phase == "Running")
      | .metadata.name
    ' \
  | tr -d '\r' \
  | sort
  SHEOF
  ```

**Salida esperada:** Debe crearse `scripts/list-data-pods.sh` con la lógica de descubrimiento por labels de servicio.

- {% include step_label.html %} Habilita el helper y comprueba que inicialmente descubre exactamente los dos Pods que ejecutan Data Service.

  ```bash
  chmod +x scripts/list-data-pods.sh
  ./scripts/list-data-pods.sh
  ```

**Salida esperada:** Deben mostrarse dos nombres ordinales `cb-lab-cluster-XXXX`.

- {% include step_label.html %} Crea un helper que espere cardinalidad Data, health, membership y ausencia de rebalance durante tres muestras consecutivas.

  ```bash
  cat > scripts/wait-cluster-stable.sh << 'SHEOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  EXPECTED_DATA="${1:?Uso: $0 <data_nodes_esperados>}"
  STABLE=0

  for i in $(seq 1 180); do
    if ! CLUSTER_JSON=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default
    ); then
      echo "Intento $i - API temporalmente no disponible; reintentando..."
      STABLE=0
      sleep 5
      continue
    fi

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
      curl -sS \
        -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/rebalanceProgress \
      | jq -r '.status // "unknown"' \
      2>/dev/null \
      || echo "unknown"
    )

    if [[ "$DATA_COUNT" -eq "$EXPECTED_DATA" \
          && "$UNHEALTHY" -eq 0 \
          && "$REBALANCE" == "none" ]]; then
      STABLE=$((STABLE + 1))
    else
      STABLE=0
    fi

    echo "Intento $i - Data=$DATA_COUNT/$EXPECTED_DATA unhealthy=$UNHEALTHY rebalance=$REBALANCE stable=$STABLE/3"

    if [[ "$STABLE" -ge 3 ]]; then
      echo "Clúster estable con ${EXPECTED_DATA} Data nodes."
      exit 0
    fi

    sleep 5
  done

  echo "ERROR: el clúster no alcanzó estabilidad."
  exit 1
  SHEOF
  ```

**Salida esperada:** Debe crearse `scripts/wait-cluster-stable.sh` con las validaciones de cardinalidad, health, membership y rebalance.

- {% include step_label.html %} Valida la sintaxis del helper de estabilización para utilizarlo más adelante en scale-out y recuperación.

  ```bash
  chmod +x scripts/wait-cluster-stable.sh
  bash -n scripts/wait-cluster-stable.sh
  ```

**Salida esperada:** `bash -n` no debe devolver errores.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## 🧭 Tarea 4. Explorar desired state, Kubernetes state y Couchbase state — 7 min

### Tarea 4.1. Abrir consola mediante Service estable

- {% include step_label.html %} Abre una terminal separada y publica la consola mediante el Service `cb-lab-cluster-ui`; este endpoint permanece estable aunque un Pod sea reemplazado.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    service/cb-lab-cluster-ui \
    8091:8091
  ```

**Salida esperada:** La terminal debe permanecer activa mostrando el forwarding local `8091 -> 8091`.

### Tarea 4.2. Consultar desired state

- {% include step_label.html %} Extrae del Custom Resource la imagen, server classes, tamaños, servicios, recursos y plantillas de volumen que representan el desired state declarado.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{
        image: .spec.image,
        servers: [
          .spec.servers[]
          | {
              name,
              size,
              services,
              resources
            }
        ],
        volumeClaimTemplates:
          .spec.volumeClaimTemplates
      }' \
    | tee outputs/desired-state.json
  ```

**Salida esperada:** El archivo debe reflejar Data `size=2`, Query + Index `size=1` y las plantillas de volumen declaradas.

### Tarea 4.3. Consultar Kubernetes state

- {% include step_label.html %} Captura nombre, UID, fase y nodo de los Pods para representar el estado que Kubernetes está ejecutando actualmente.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" \
    -o json \
    | jq '[
        .items[]
        | select(.metadata.name | startswith("cb-lab-cluster-"))
        | {
            name: .metadata.name,
            uid: .metadata.uid,
            phase: .status.phase,
            node: .spec.nodeName
          }
      ]' \
    | tee outputs/kubernetes-state.json
  ```

**Salida esperada:** El archivo debe contener tres Pods del clúster en fase `Running`, con UID y nodo asignado.

### Tarea 4.4. Consultar Couchbase state

- {% include step_label.html %} Consulta la API REST de Couchbase para registrar health, membership, servicios y estado de rebalance de los nodos integrados.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '{
        rebalanceStatus,
        nodes: [
          .nodes[]
          | {
              hostname,
              status,
              clusterMembership,
              services
            }
        ]
      }' \
    | tee outputs/couchbase-state.json
  ```

**Salida esperada:** Deben aparecer tres nodos `healthy`, activos y con `rebalanceStatus` igual a `none`.

### Tarea 4.5. Consultar status.conditions

- {% include step_label.html %} Guarda las condiciones publicadas por Operator para disponer de una referencia basal antes de provocar cambios o fallos.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '.status.conditions' \
    | tee outputs/status-conditions-baseline.json
  ```

**Salida esperada:** Debe generarse `outputs/status-conditions-baseline.json` con las condiciones actuales del clúster. Los tres planos deben converger:

```text
Desired:
Data size=2
Query+Index size=1

Kubernetes:
3 Pods Running

Couchbase:
3 nodes healthy/active
rebalanceStatus=none
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## ➕ Tarea 5. Ejecutar scale-out Data 2 → 3 — 11 min

### Tarea 5.1. Capturar estado previo

- {% include step_label.html %} Descubre los Data Pods mediante el helper y guarda el baseline para identificar después qué instancia fue añadida por el scale-out.

  ```bash
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-before-scaleout.txt
  ```

**Salida esperada:** El archivo debe contener exactamente dos Data Pods.

### Tarea 5.2. Descubrir índice del server class

- {% include step_label.html %} Localiza la server class por nombre para evitar depender del orden del arreglo `spec.servers`.

  ```bash
  DATA_INDEX=$(
    kubectl get couchbasecluster "$CB_CLUSTER" \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r '
        .spec.servers
        | to_entries[]
        | select(.value.name == "data")
        | .key
      '
  )

  echo "DATA_INDEX=$DATA_INDEX"
  ```

**Salida esperada:** `DATA_INDEX` debe contener un índice numérico y no quedar vacío.

### Tarea 5.3. Modificar desired state

- {% include step_label.html %} Actualiza únicamente el campo declarativo `size` de la server class Data de 2 a 3; este patch es parte de la prueba de reconciliación y no una corrección del despliegue.

  ```bash
  kubectl patch couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    --type='json' \
    -p="[
      {
        \"op\": \"replace\",
        \"path\": \"/spec/servers/${DATA_INDEX}/size\",
        \"value\": 3
      }
    ]"
  ```

**Salida esperada:**

```text
couchbasecluster.couchbase.com/cb-lab-cluster patched
```

### Tarea 5.4. Observar diferencia temporal

- {% include step_label.html %} Consulta inmediatamente el desired state para comprobar que Kubernetes ya registra Data `size=3` aunque la reconciliación todavía pueda estar en progreso.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '
      .spec.servers[]
      | select(.name == "data")
      | {desiredDataSize: .size}
    '
  ```

**Salida esperada:** Debe mostrarse `desiredDataSize` con valor `3`.

- {% include step_label.html %} Consulta los Data Pods reales para observar la posible divergencia temporal entre desired state y estado ejecutado.

  ```bash
  ./scripts/list-data-pods.sh
  ```

**Salida esperada:** Durante los primeros segundos puede existir `desiredDataSize=3` mientras todavía sólo aparecen dos Data Pods `Running`.

### Tarea 5.5. Monitorear reconciliación y rebalance

- {% include step_label.html %} Observa en una terminal secundaria la creación y transición del nuevo Pod mientras Operator materializa la cardinalidad Data solicitada.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -w
  ```

**Salida esperada:** Debe observarse la creación y transición del nuevo Pod hasta alcanzar `Running`; finaliza la observación con `Ctrl+C`.

- {% include step_label.html %} En la terminal principal espera estabilidad integral de tres Data nodes; el helper exige cardinalidad real, health, membership y `rebalance=none` durante tres muestras consecutivas.

  ```bash
  ./scripts/wait-cluster-stable.sh 3 \
    | tee outputs/scaleout-rebalance.txt
  ```

**Salida esperada:** Debe finalizar con `Clúster estable con 3 Data nodes.`.

### Tarea 5.6. Validar nuevo Pod y PVC

- {% include step_label.html %} Guarda nuevamente el conjunto de Data Pods para comparar el estado estable con el baseline previo.

  ```bash
  ./scripts/list-data-pods.sh \
    | tee snapshots/data-pods-after-scaleout.txt
  ```

**Salida esperada:** El archivo debe contener exactamente tres Data Pods.

- {% include step_label.html %} Compara ambos snapshots ordenados para mostrar únicamente la nueva instancia Data incorporada durante el scale-out.

  ```bash
  comm -13 \
    snapshots/data-pods-before-scaleout.txt \
    snapshots/data-pods-after-scaleout.txt
  ```

**Salida esperada:** Debe mostrarse exactamente un nombre de Pod nuevo.

- {% include step_label.html %} Verifica los PVC después del scale-out y conserva la evidencia del volumen persistente adicional.

  ```bash
  kubectl get pvc \
    -n "$CB_NAMESPACE" \
    -o wide \
    | tee snapshots/pvc-after-scaleout.txt
  ```

**Salida esperada:**

```text
3 Data Pods
1 Query+Index Pod
4 PVC Bound
rebalanceProgress.status = none
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## ♻️ Tarea 6. Simular pérdida de Pod y validar recuperación persistente — 11 min

### Tarea 6.1. Crear documento de prueba

- {% include step_label.html %} Descubre el Pod que ejecuta Query Service mediante labels, evitando depender de nombres derivados de la server class.

  ```bash
  QUERY_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_query=enabled" \
      -o jsonpath='{.items[0].metadata.name}'
  )

  echo "QUERY_POD=$QUERY_POD"
  ```

**Salida esperada:** `QUERY_POD` debe contener un nombre ordinal válido y no quedar vacío.

- {% include step_label.html %} En una terminal separada abre Query Service del Pod descubierto; ese Pod no será seleccionado para la prueba de pérdida del Data Service.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    "pod/${QUERY_POD}" \
    8093:8093
  ```

**Salida esperada:** La terminal debe permanecer activa mostrando el forwarding local `8093 -> 8093`.

- {% include step_label.html %} Inserta `recovery::proof` con durabilidad `majorityAndPersistActive` y valida la escritura antes de provocar la pérdida del Pod Data.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=
      UPSERT INTO `lab-bucket` (KEY, VALUE)
      VALUES (
        "recovery::proof",
        {
          "type":"recovery-proof",
          "message":"persisted before pod loss"
        }
      );' \
    --data-urlencode 'durability_level=majorityAndPersistActive' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Debe aparecer `"status": "success"` y no debe existir un arreglo de errores.

- {% include step_label.html %} Lee el documento antes de eliminar un Pod para demostrar que el dato era accesible previamente y conservar una referencia funcional.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT RAW l
      FROM `lab-bucket` AS l
      USE KEYS "recovery::proof";' \
  | jq '{status, results, errors}'
  ```

**Salida esperada:** `results` debe contener el objeto `recovery-proof`.

- {% include step_label.html %} Espera unos segundos para permitir persistencia y propagación de la mutation antes de iniciar el escenario de pérdida.

  ```bash
  sleep 5
  ```

**Salida esperada:** El comando no debe mostrar salida y debe devolver el prompt después de cinco segundos.

### Tarea 6.2. Seleccionar Pod Data y registrar UID/PVC

- {% include step_label.html %} Selecciona dinámicamente uno de los Data Pods después del scale-out y conserva nombre y UID para demostrar el reemplazo de instancia.

  ```bash
  TARGET_POD=$(
    ./scripts/list-data-pods.sh \
      | tail -n1
  )

  TARGET_UID=$(
    kubectl get pod "$TARGET_POD" \
      -n "$CB_NAMESPACE" \
      -o jsonpath='{.metadata.uid}'
  )

  echo "TARGET_POD=$TARGET_POD"
  echo "TARGET_UID=$TARGET_UID"
  ```

**Salida esperada:** Ambas variables deben contener valores no vacíos.

- {% include step_label.html %} Descubre el PVC montado por el Pod desde su especificación, sin asumir que el claim incluye el nombre de la server class.

  ```bash
  TARGET_PVC=$(
    kubectl get pod "$TARGET_POD" \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r '
        .spec.volumes[]
        | select(.persistentVolumeClaim != null)
        | .persistentVolumeClaim.claimName
      ' \
    | head -n1 \
    | tr -d '\r'
  )

  echo "TARGET_PVC=$TARGET_PVC"
  ```

**Salida esperada:** `TARGET_PVC` debe mostrar el claim persistente asociado al Data Pod.

- {% include step_label.html %} Guarda el estado del PVC antes de la pérdida para compararlo con el almacenamiento utilizado durante la recuperación.

  ```bash
  kubectl get pvc "$TARGET_PVC" \
    -n "$CB_NAMESPACE" \
    -o wide \
    | tee snapshots/target-pvc-before-loss.txt
  ```

**Salida esperada:** El PVC seleccionado debe encontrarse `Bound`.

### Tarea 6.3. Eliminar el Pod

- {% include step_label.html %} Elimina únicamente el Pod Data; no modifiques `spec.servers[].size`, de modo que el desired state continúe solicitando tres Data nodes.

  ```bash
  kubectl delete pod \
    -n "$CB_NAMESPACE" \
    "$TARGET_POD"
  ```

**Salida esperada:** Kubernetes debe confirmar la eliminación y Operator debe detectar la divergencia.

### Tarea 6.4. Verificar desired state sin cambios

- {% include step_label.html %} Comprueba que el desired state conserva tres Data nodes, diferenciando una pérdida accidental de una solicitud declarativa de scale-in.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '
      .spec.servers[]
      | select(.name == "data")
      | {desiredDataSize: .size}
    '
  ```

**Salida esperada:**

```text
desiredDataSize = 3
```

### Tarea 6.5. Esperar recuperación

- {% include step_label.html %} Espera la recuperación integral de los tres Data nodes utilizando cardinalidad, health, membership y ausencia de rebalance como criterios conjuntos.

  ```bash
  ./scripts/wait-cluster-stable.sh 3
  ```

**Salida esperada:** Debe finalizar con `Clúster estable con 3 Data nodes.`.

- {% include step_label.html %} Guarda la topología Kubernetes posterior a la recuperación para conservar la evidencia de Pods y nodos.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -o wide \
    | tee snapshots/pods-after-recovery.txt
  ```

**Salida esperada:** Deben observarse nuevamente tres Data Pods y un Query + Index Pod en estado operativo.

### Tarea 6.6. Comparar UID y PVC

- {% include step_label.html %} Localiza la instancia Data que utiliza el mismo PVC, relacionando identidad efímera del Pod con almacenamiento persistente recuperable.

  ```bash
  RECOVERED_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_data=enabled" \
      -o json \
    | jq -r --arg PVC "$TARGET_PVC" '
        .items[]
        | select(
            any(
              .spec.volumes[]?;
              .persistentVolumeClaim.claimName == $PVC
            )
          )
        | .metadata.name
      ' \
    | head -n1 \
    | tr -d '\r'
  )

  echo "RECOVERED_POD=$RECOVERED_POD"
  ```

**Salida esperada:** Debe aparecer un Data Pod asociado con el PVC registrado antes de la pérdida.

- {% include step_label.html %} Obtén el UID de la instancia recuperada y compáralo con el UID original para demostrar que Kubernetes creó una nueva instancia de Pod.

  ```bash
  NEW_UID=$(
    kubectl get pod "$RECOVERED_POD" \
      -n "$CB_NAMESPACE" \
      -o jsonpath='{.metadata.uid}'
  )

  echo "Old UID: $TARGET_UID"
  echo "New UID: $NEW_UID"
  ```

**Salida esperada:** Los UIDs deben ser diferentes.

- {% include step_label.html %} Confirma que el PVC original continúa `Bound` después de la recuperación y conserva la evidencia.

  ```bash
  kubectl get pvc "$TARGET_PVC" \
    -n "$CB_NAMESPACE" \
    -o wide \
    | tee snapshots/target-pvc-after-loss.txt
  ```

**Salida esperada:** El mismo `TARGET_PVC` debe continuar en estado `Bound`.

### Tarea 6.7. Verificar que el documento sobrevivió

- {% include step_label.html %} Consulta nuevamente `recovery::proof` después de la recuperación para validar supervivencia del dato desde Query Service.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT RAW l
      FROM `lab-bucket` AS l
      USE KEYS "recovery::proof";' \
    | tee outputs/recovery-proof.json \
    | jq '{status, results, errors}'
  ```

**Salida esperada:** La respuesta debe mostrar `status: "success"` y `results` debe contener:

```json
{
  "type": "recovery-proof",
  "message": "persisted before pod loss"
}
```

### Tarea 6.8. Capturar logs de recuperación

- {% include step_label.html %} Conserva los logs recientes de Operator como evidencia complementaria de las decisiones tomadas durante la recuperación.

  ```bash
  kubectl logs \
    -n "$CB_NAMESPACE" \
    deployment/"$OPERATOR_DEPLOYMENT" \
    --since=10m \
    | tee outputs/operator-recovery.log
  ```

**Salida esperada:** Debe generarse `outputs/operator-recovery.log`; no se exige un mensaje textual específico.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 🪣 Tarea 7. Cambiar bucket RAM declarativamente — 6 min

### Tarea 7.1. Consultar desired y actual

- {% include step_label.html %} Consulta el `CouchbaseBucket` para registrar la cuota declarada antes del cambio.

  ```bash
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{memoryQuota: .spec.memoryQuota}'
  ```

**Salida esperada:** Debe mostrarse `memoryQuota` con valor `512Mi`.

- {% include step_label.html %} Consulta la configuración efectiva vía REST para relacionar el desired state del CR con la cuota aplicada por Couchbase.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
  | jq '{
      quotaMiB:
        (.quota.ram / 1024 / 1024),
      replicaNumber
    }'
  ```

**Salida esperada:** Debe mostrarse una cuota efectiva cercana a `512` MiB y `replicaNumber` igual a `1`.

### Tarea 7.2. Aplicar cambio

- {% include step_label.html %} Actualiza únicamente `memoryQuota` de 512Mi a 768Mi como cambio controlado de la práctica; no se modifica ni se reaplica el `CouchbaseCluster`.

  ```bash
  kubectl patch couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    --type=merge \
    -p '{"spec":{"memoryQuota":"768Mi"}}'
  ```

**Salida esperada:** Kubernetes debe confirmar que `lab-bucket` fue patched.

### Tarea 7.3. Esperar convergencia

- {% include step_label.html %} Sondea la cuota efectiva hasta observar 768 MiB; si no converge dentro del intervalo, conserva el error y revisa `status.conditions`.

  ```bash
  BUCKET_READY=false

  DATA_NODES=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
    | jq '[
        .nodes[]
        | select(.services | index("kv"))
      ] | length'
  )

  EXPECTED_TOTAL_MIB=$((768 * DATA_NODES))

  echo "Data nodes: $DATA_NODES"
  echo "Total esperado: ${EXPECTED_TOTAL_MIB}MiB"

  for i in $(seq 1 30); do
    ACTUAL_TOTAL_MIB=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
      | jq -r '.quota.ram / 1024 / 1024 | floor'
    )

    echo "Intento $i - actual=${ACTUAL_TOTAL_MIB}MiB esperado=${EXPECTED_TOTAL_MIB}MiB"

    if [[ "$ACTUAL_TOTAL_MIB" -eq "$EXPECTED_TOTAL_MIB" ]]; then
      BUCKET_READY=true
      break
    fi

    sleep 2
  done
  ```

**Salida esperada:** Debe observarse `actual=768MiB` antes de terminar el ciclo.

### Tarea 7.4. Comparar desired vs actual

- {% include step_label.html %} Muestra por separado el valor declarado en Kubernetes y el valor efectivo reportado por Couchbase para confirmar convergencia de ambos planos.

  ```bash
  kubectl get couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.spec.memoryQuota}{"\n"}'
  ```

**Salida esperada:** Debe mostrarse `768Mi`.

- {% include step_label.html %} Consulta la cuota real por REST y confirma que coincide con el desired state.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
  | jq '.quota.ram / 1024 / 1024'
  ```

**Salida esperada:** Debe mostrarse `2304`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🛠️ Tarea 8. Troubleshooting por capas — 12 min

El objetivo no es crear un manifiesto con muchos errores simultáneos. Cada caso aislará una capa distinta y eliminará sus recursos antes de continuar con el siguiente.

### Caso A — Admission Controller: StorageClass inexistente

- {% include step_label.html %} Crea un `CouchbaseCluster` temporal que referencia una StorageClass inexistente, manteniendo el resto del manifiesto válido para aislar la validación de almacenamiento.

  ```bash
  cat > troubleshooting/01-invalid-storageclass.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-invalid-storage
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-7.6.2

    security:
      adminSecret: cb-admin

    buckets:
      managed: false

    servers:
      - name: data
        size: 1
        services:
          - data
        volumeMounts:
          default: data

    volumeClaimTemplates:
      - metadata:
          name: data
        spec:
          storageClassName: storageclass-does-not-exist
          resources:
            requests:
              storage: 5Gi
  YAMLEOF
  ```

**Salida esperada:** Debe crearse `troubleshooting/01-invalid-storageclass.yaml` referenciando `storageclass-does-not-exist`.

- {% include step_label.html %} Intenta aplicar el manifiesto y conserva stdout/stderr para determinar si el Dynamic Admission Controller detecta la StorageClass inexistente.

  ```bash
  kubectl apply \
    --server-side \
    -f troubleshooting/01-invalid-storageclass.yaml \
    > outputs/troubleshooting-admission.txt \
    2>&1 || true
  ```

**Salida esperada:** Debe generarse `outputs/troubleshooting-admission.txt` con la respuesta obtenida al aplicar el recurso.

- {% include step_label.html %} Muestra la evidencia capturada sin depender de un texto exacto del webhook.

  ```bash
  cat outputs/troubleshooting-admission.txt
  ```

**Salida esperada:** Con los permisos estándar del Admission Controller, la solicitud debe rechazarse porque la StorageClass no existe. Si esos permisos de lectura fueron retirados, documenta que el recurso puede superar admisión y fallar posteriormente al crear el PVC.

- {% include step_label.html %} Elimina el Custom Resource temporal en caso de que la configuración local del Admission Controller haya permitido su creación.

  ```bash
  kubectl delete couchbasecluster cb-invalid-storage \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** `cb-invalid-storage` debe quedar eliminado si llegó a crearse; su ausencia no debe generar error.

### Caso B — Scheduler: recursos imposibles

- {% include step_label.html %} Crea un recurso válido a nivel de schema, pero solicita 100Gi de memoria para que ningún worker pueda programar el Pod.

  ```bash
  cat > troubleshooting/02-unschedulable.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-unschedulable
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-7.6.2

    security:
      adminSecret: cb-admin

    buckets:
      managed: false

    servers:
      - name: data
        size: 1
        services:
          - data
        resources:
          requests:
            cpu: "1"
            memory: "100Gi"
          limits:
            cpu: "2"
            memory: "100Gi"
  YAMLEOF
  ```

**Salida esperada:** Debe crearse `troubleshooting/02-unschedulable.yaml` con una solicitud de memoria de `100Gi`.

- {% include step_label.html %} Aplica el caso para que Operator intente materializar un Pod que será rechazado por capacidad del scheduler.

  ```bash
  kubectl apply \
    --server-side \
    -f troubleshooting/02-unschedulable.yaml \
    || true
  ```

**Salida esperada:** Kubernetes debe aceptar el Custom Resource y Operator debe intentar materializar el Pod asociado.

- {% include step_label.html %} Espera unos segundos y comprueba el estado del Pod temporal.

  ```bash
  sleep 10
  ```

**Salida esperada:** El comando no debe mostrar salida y debe devolver el prompt después de aproximadamente diez segundos.

- {% include step_label.html %} Consulta los Pods del namespace y filtra el recurso temporal para comprobar que la instancia permanece sin poder programarse.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    | grep cb-unschedulable || true
  ```

**Salida esperada:** Debe aparecer un Pod `Pending`.

- {% include step_label.html %} Consulta eventos recientes para atribuir el fallo a scheduling y conservar la evidencia.

  ```bash
  kubectl get events \
    -n "$CB_NAMESPACE" \
    --sort-by=.lastTimestamp \
    | grep -E 'cb-unschedulable|Insufficient' \
    | tail -n 20 \
    | tee outputs/troubleshooting-scheduler.txt
  ```

**Salida esperada:** Los eventos deben indicar `Insufficient memory` o una imposibilidad equivalente de scheduling.

- {% include step_label.html %} Elimina el caso antes de continuar para que sus Pods y eventos no interfieran con el diagnóstico de runtime.

  ```bash
  kubectl delete couchbasecluster cb-unschedulable \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** `cb-unschedulable` debe quedar eliminado y sus Pods temporales deben comenzar a desaparecer.

### Caso C — Container runtime: imagen inexistente

- {% include step_label.html %} Declara un clúster temporal con una etiqueta de imagen inexistente para que el manifiesto sea aceptable pero el runtime no pueda descargar Couchbase Server.

  ```bash
  cat > troubleshooting/03-invalid-image.yaml << 'YAMLEOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-invalid-image
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-99.99.99

    security:
      adminSecret: cb-admin

    buckets:
      managed: false

    servers:
      - name: data
        size: 1
        services:
          - data
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "1"
            memory: "3Gi"
  YAMLEOF
  ```

**Salida esperada:** Debe crearse `troubleshooting/03-invalid-image.yaml` con la etiqueta inexistente `enterprise-99.99.99`.

- {% include step_label.html %} Aplica el caso temporal para que Kubernetes intente descargar la imagen inexistente.

  ```bash
  kubectl apply \
    --server-side \
    -f troubleshooting/03-invalid-image.yaml \
    || true
  ```

**Salida esperada:** Kubernetes debe aceptar el recurso y Operator debe intentar crear el Pod con la imagen indicada.

- {% include step_label.html %} Concede tiempo al kubelet para realizar los primeros intentos de pull.

  ```bash
  for i in $(seq 1 60); do
    BROKEN_POD=$(
      kubectl get pods \
        -n "$CB_NAMESPACE" \
        -o name \
      | grep 'cb-invalid-image' \
      | head -n1 \
      | cut -d/ -f2
    )

    if [[ -n "$BROKEN_POD" ]]; then
      echo "BROKEN_POD=$BROKEN_POD"
      break
    fi

    echo "Intento $i - Pod todavía no creado"
    sleep 5
  done
  ```

**Salida esperada:** El comando no debe mostrar salida y debe devolver el prompt después de aproximadamente quince segundos.

- {% include step_label.html %} Descubre dinámicamente el Pod generado por el caso, sin asumir un ordinal específico.

  ```bash
  BROKEN_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -o name \
    | grep 'cb-invalid-image' \
    | head -n1 \
    | cut -d/ -f2
  )

  echo "BROKEN_POD=$BROKEN_POD"
  ```

**Salida esperada:** `BROKEN_POD` debe contener un nombre si Operator alcanzó a crear la instancia.

- {% include step_label.html %} Describe el Pod y guarda los eventos que permitan atribuir el fallo al runtime o al pull de imagen.

  ```bash
  if [[ -n "$BROKEN_POD" ]]; then
    kubectl describe pod "$BROKEN_POD" \
      -n "$CB_NAMESPACE" \
    | tail -n 40 \
    | tee outputs/troubleshooting-runtime.txt
  fi
  ```

**Salida esperada:** Debe observarse `ErrImagePull`, `ImagePullBackOff`, `Failed to pull image` o un evento equivalente.

- {% include step_label.html %} Elimina el Custom Resource temporal antes de revisar el clúster principal.

  ```bash
  kubectl delete couchbasecluster cb-invalid-image \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** `cb-invalid-image` debe quedar eliminado y el Pod con error de imagen debe comenzar a desaparecer.

### Caso D — Operator / status.conditions

- {% include step_label.html %} Captura las condiciones del clúster principal para utilizar `status.conditions` como primera evidencia cuando un recurso aceptado no converge.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
  | jq '.status.conditions' \
  | tee outputs/troubleshooting-operator-conditions.json
  ```

**Salida esperada:** Debe generarse `outputs/troubleshooting-operator-conditions.json` con las condiciones actuales del clúster principal.

- {% include step_label.html %} Ahora asigna específicamente el Deployment del Operator:

  ```bash
  OPERATOR_DEPLOYMENT=$(
    kubectl get deployments \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r '
        .items[]
        | select(
            .metadata.name
            | contains("operator")
          )
        | select(
            .metadata.name
            | contains("admission")
            | not
          )
        | .metadata.name
      ' \
    | head -n1 \
    | tr -d '\r'
  )

  echo "OPERATOR_DEPLOYMENT=$OPERATOR_DEPLOYMENT"
  ```

**Salida esperada:** Debe obtenerse el valor `cb-operator-couchbase-operator`.

- {% include step_label.html %} Guarda los logs recientes del Operator como evidencia complementaria sin depender de mensajes exactos para declarar éxito o fallo.

  ```bash
  kubectl logs \
    -n "$CB_NAMESPACE" \
    deployment/"$OPERATOR_DEPLOYMENT" \
    --since=15m \
    | tee outputs/troubleshooting-operator.log
  ```

**Salida esperada:** Deben generarse los dos archivos de evidencia y el clúster principal debe continuar operativo.

### Tarea 8.5. Completar matriz de diagnóstico

| Caso | Capa | Síntoma esperado | Herramienta principal |
|---|---|---|---|
| StorageClass inexistente | Admission/validación | `apply` rechazado o PVC no aprovisionable según RBAC del DAC | `kubectl apply`, `status.conditions` |
| Request 100Gi | Scheduler | Pod `Pending` | `kubectl get events`, `describe pod` |
| Imagen inexistente | Container runtime | `ImagePullBackOff` | `kubectl describe pod` |
| Reconciliación | Operator/Couchbase | condition/log de error | `status.conditions`, Operator logs |

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 🧮 Tarea 9. Construir matriz de reconciliación — 4 min

### Tarea 9.1. Crear documento de evidencia

- {% include step_label.html %} Genera una matriz que relacione cada evento con desired state, Kubernetes state, Couchbase state y la acción esperada del Operator.

  ```bash
  cat > reports/reconciliation-matrix.md << 'EOF'
  # Matriz de reconciliación — Lab 10

  | Evento | Desired state | Kubernetes state | Couchbase state | Acción del Operator |
  |---|---|---|---|---|
  | Baseline | Data=2 | 2 Data Pods | 2 Data nodes | Ninguna |
  | Scale-out solicitado | Data=3 | temporalmente 2 Data Pods | temporalmente 2 Data nodes | Crear Pod + membership + rebalance |
  | Scale-out estable | Data=3 | 3 Data Pods | 3 Data nodes | Ninguna |
  | Pérdida de Pod | Data=3 | temporalmente 2 Data Pods | miembro perdido/recovery | Recuperar estado deseado |
  | Recovery estable | Data=3 | 3 Data Pods | 3 Data nodes healthy | Ninguna |
  | Bucket RAM update | 768Mi | sin cambio de Pods | quota actualizada | Reconciliar configuración |
  EOF
  ```

**Salida esperada:** Debe crearse `reports/reconciliation-matrix.md` con los eventos y estados definidos.

- {% include step_label.html %} Muestra el archivo generado para comprobar que baseline, scale-out, pérdida de Pod, recovery y cambio de bucket están representados.

  ```bash
  cat reports/reconciliation-matrix.md
  ```

**Salida esperada:** Debe mostrarse la tabla completa de reconciliación.

### Tarea 9.2. Registrar principio central

- {% include step_label.html %} Revisa el flujo conceptual para relacionar desired state, validación, API de Kubernetes, reconciliación del Operator y estado final de Couchbase.

  ```text
Desired state
     ↓
Admission Controller
     ↓
Kubernetes API
     ↓
Operator observe/compare/reconcile
     ↓
Kubernetes Pods/PVC
     ↓
Couchbase membership/configuration
  ```

**Salida esperada:** El flujo debe mostrar la secuencia completa desde `Desired state` hasta `Couchbase membership/configuration`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación integral y reporte — 4 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea el script de validación integral que comprobará disponibilidad, cardinalidad Data, health, rebalance, cuota, PVC y evidencias generadas.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab10/validate.sh
  ```

**Salida esperada:** Debe crearse `scripts/validate.sh` con todas las comprobaciones finales definidas.

- {% include step_label.html %} Asigna permisos de ejecución y valida la sintaxis de `validate.sh` antes de ejecutar las comprobaciones funcionales.

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ```

**Salida esperada:** `bash -n` no debe devolver errores de sintaxis.

- {% include step_label.html %} Ejecuta la validación integral y conserva el resultado en `reports/validation-final.txt` como evidencia de cierre.

  ```bash
  ./scripts/validate.sh \
    | tee reports/validation-final.txt
  ```

**Salida esperada:** Deben mostrarse `X PASS / X FAIL`.

### Tarea 10.2. Generar dossier final

- {% include step_label.html %} Consolida desired state, estado Kubernetes, estado Couchbase, recuperación persistente, matriz y validación en un único dossier Markdown.

  ```bash
  {
    echo "# REPORTE FINAL - LAB 10"
    echo

    echo "## Desired state"
    cat outputs/desired-state.json

    echo
    echo "## Kubernetes state"
    cat outputs/kubernetes-state.json

    echo
    echo "## Couchbase state"
    cat outputs/couchbase-state.json

    echo
    echo "## Persistent recovery"
    cat outputs/recovery-proof.json

    echo
    echo "## Reconciliation matrix"
    cat reports/reconciliation-matrix.md

    echo
    echo "## Validation"
    cat reports/validation-final.txt
  } | tee reports/final-report.md
  ```

**Salida esperada:** Debe generarse `reports/final-report.md` con las evidencias consolidadas de la práctica.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

Si el clúster EKS continuará utilizándose, elimina únicamente los recursos creados por esta práctica. Si destruirás EKS inmediatamente, puedes omitir esta sección.

- {% include step_label.html %} Elimina los Custom Resources temporales de troubleshooting si todavía existen.

  ```bash
  for RESOURCE in \
    cb-invalid-storage \
    cb-unschedulable \
    cb-invalid-image
  do
    kubectl delete couchbasecluster "$RESOURCE" \
      -n "$CB_NAMESPACE" \
      --ignore-not-found
  done
  ```

**Salida esperada:** Los recursos temporales deben eliminarse si existen; `--ignore-not-found` evita errores cuando alguno ya fue retirado.

- {% include step_label.html %} Elimina el bucket y el clúster principal.

  ```bash
  kubectl delete couchbasebucket "$CB_BUCKET" \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** `lab-bucket` debe quedar eliminado o reportarse como ausente sin generar error.

- {% include step_label.html %} Elimina el `CouchbaseCluster` principal una vez retirado el bucket para iniciar la limpieza de Pods y volúmenes asociados.

  ```bash
  kubectl delete couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** `cb-lab-cluster` debe quedar eliminado o reportarse como ausente sin generar error.

- {% include step_label.html %} No ejecutes `kubectl delete pvc --all` en namespaces compartidos. Si necesitas limpiar PVC residuales, identifica primero cuáles pertenecen al clúster del laboratorio.

**Salida esperada:** No debe eliminarse ningún PVC ajeno a la práctica; cualquier limpieza adicional debe limitarse a claims identificados del clúster.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` los port-forward de 8091 y 8093.

**Salida esperada:** Ambas terminales deben finalizar `kubectl port-forward` y regresar al prompt de Git Bash.

- {% include step_label.html %} Regresa al directorio del laboratorio y carga las variables necesarias para identificar el clúster EKS correcto.

  ```bash
  cd /c/LABS/couchbase-nosql/lab10
  source lab.env
  ```

**Salida esperada:** El prompt debe quedar en `lab10` y `source lab.env` no debe devolver errores.

- {% include step_label.html %} Elimina Amazon EKS mediante el mismo script de ciclo de vida utilizado durante la creación.

  ```bash
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** El script debe completar la eliminación del clúster EKS y sus recursos administrados sin errores.

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