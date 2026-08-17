---
layout: lab
title: "Práctica 13: Diagnóstico, recuperación y mantenimiento del clúster"
permalink: /lab13/lab13/
images_base: /labs/lab13/img
duration: "48 minutos"
objective:
  - Aplicar troubleshooting en seis etapas para diagnosticar fallos en Couchbase, Kubernetes y Operator. Correlacionar memoria, optimizar Query con índices GSI, gestionar backups/restores, ejecutar un rolling upgrade y crear un runbook operativo native.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Data Service, Query, Index, rebalance, persistencia, Operator y conceptos básicos de backup/restore.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq, Python 3 y `cao` 2.92.0 disponibles desde Git Bash.
  - Comprender que la frecuencia de backup, los umbrales de memoria y los objetivos RPO/RTO pertenecen al diseño de cada organización y no son valores universales del producto.
introduction:
  - En esta práctica operarás Couchbase Enterprise 7.6.2 sobre Amazon EKS aplicando troubleshooting estructurado, recuperación de datos y mantenimiento declarativo. Dos incidentes controlados permitirán practicar la secuencia Observar → Delimitar → Formular hipótesis → Probar → Corregir → Verificar. Después utilizarás los recursos CouchbaseBackup y CouchbaseBackupRestore del Operator para crear un punto de recuperación y restaurar selectivamente una collection. Finalmente ejecutarás un rolling upgrade real hacia Couchbase Server Enterprise 7.6.8 mediante spec.image, observarás Mixed Mode y prepararás un rollback declarativo. Todos los resultados se consolidarán en un runbook operativo reproducible.
slug: lab13
lab_number: 13
final_result: >
  Al finalizar la práctica habrás diagnosticado y corregido dos incidentes reproducibles, generado un paquete de evidencias Couchbase/Kubernetes/Operator, completado un backup y restore selectivo administrados por Operator, medido RPO y RTO con write IDs reales, actualizado el clúster de Enterprise 7.6.2 a 7.6.8 mediante RollingUpgrade y generado un runbook operativo con procedimiento de rollback declarativo validado.
notes:
  - Los 48 minutos corresponden exclusivamente al trabajo funcional. La creación de EKS, despliegue base, carga inicial de datos, preparación de backup RBAC y precarga de la imagen de upgrade quedan fuera del tiempo.
  - La versión inicial es couchbase/server:enterprise-7.6.2 y la versión objetivo del ejercicio es couchbase/server:enterprise-7.6.8.
  - El upgrade 7.6.2→7.6.8 permanece dentro de la rama 7.6.x; antes de reutilizar esta práctica con otra versión debe revisarse nuevamente la matriz oficial de upgrade.
  - Backup y restore se ejecutan mediante CouchbaseBackup y CouchbaseBackupRestore; el Operator utiliza cbbackupmgr dentro de un Pod separado.
  - El repositorio de backup utiliza un PVC gp3 de laboratorio. En producción puede utilizarse object storage como Amazon S3 según la estrategia de protección definida.
  - La collection protegida es lab13-recovery.production.transactions.
  - El dataset inicial contiene 100,000 documentos; después del backup se confirman 1,000 escrituras adicionales para medir el RPO experimental.
  - El incidente de memoria no presupone que un resident ratio específico constituya una falla universal; se correlacionan varias evidencias antes de formular una conclusión.
  - ep_bg_fetched representa background fetches de elementos no residentes, no logical key misses.
  - El incidente de índice utiliza un índice deferred para producir una degradación reproducible; no se depende de una función SQL++ inválida que pudiera impedir la creación del índice.
  - El rollback de versión se prepara y valida con dry-run. Su ejecución real debe ocurrir únicamente dentro de una ventana de rollback soportada y después de revisar compatibilidad.
references:
  - text: "Backup and Restore with Couchbase Operator"
    url: "https://docs.couchbase.com/operator/current/howto-backup.html"
  - text: "CouchbaseBackup Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasebackup.html"
  - text: "CouchbaseBackupRestore Resource"
    url: "https://docs.couchbase.com/operator/current/resource/couchbasebackuprestore.html"
  - text: "Backup and Restore Concepts"
    url: "https://docs.couchbase.com/operator/current/concept-backup.html"
  - text: "Couchbase Server Upgrade with Operator"
    url: "https://docs.couchbase.com/operator/current/howto-couchbase-upgrade.html"
  - text: "Couchbase Upgrade Concepts"
    url: "https://docs.couchbase.com/operator/current/concept-upgrade.html"
  - text: "cbopinfo Diagnostic Tool"
    url: "https://docs.couchbase.com/operator/current/tools/cbopinfo.html"
  - text: "Couchbase Server Troubleshooting"
    url: "https://docs.couchbase.com/server/current/manage/troubleshoot/troubleshoot.html"
  - text: "Couchbase Server Upgrade"
    url: "https://docs.couchbase.com/server/current/install/upgrade.html"
prev: /lab12/lab12/
next: /lab14/lab14/
---

---

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona `C:\LABS\couchbase-nosql` y utiliza una terminal integrada **Git Bash** para conservar el entorno o...
- {% include step_label.html %} Crea la estructura de trabajo del laboratorio y confirma el directorio activo antes de generar manifiestos y evidencias.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab13/{scripts,manifests,incidents,backup,diagnostics,results,reports}
  cd /c/LABS/couchbase-nosql/lab13

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:** Debe mostrarse `/c/LABS/couchbase-nosql/lab13` y las carpetas `backup`, `diagnostics`, `incidents`, `manifests`, `reports`, `results` y `scripts`.


---

## ☁️ Preparación de Amazon EKS

## Crear variables
- {% include step_label.html %} Crea `lab.env` con región, versiones, credenciales y nombres que reutilizarán los comandos de toda la práctica.

  ```bash
  cat > lab.env << 'EOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab13"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"

  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"

  export CB_OPERATOR_VERSION="2.92.0"
  export CB_IMAGE_BASE="couchbase/server:enterprise-7.6.2"
  export CB_IMAGE_TARGET="couchbase/server:enterprise-7.6.8"

  export CB_BUCKET="lab13-recovery"
  export CB_SCOPE="production"
  export CB_COLLECTION="transactions"

  export BACKUP_NAME="lab13-backup"
  export RESTORE_NAME="lab13-restore"

  export INITIAL_DOCS="100000"
  export POST_BACKUP_DOCS="1000"

  export RPO_OBJECTIVE_SECONDS="300"
  export RTO_OBJECTIVE_SECONDS="600"
  EOF

  source lab.env
  ```

**Salida esperada:** Debe crearse `lab.env` con `AWS_REGION=us-west-2`, `CB_OPERATOR_VERSION=2.92.0`, versiones 7.6.2/7.6.8 y los nombres reutilizados durante la práctica.


## Crear EKS
- {% include step_label.html %} Crea el script de ciclo de vida de EKS con cinco workers y los add-ons requeridos para Couchbase y volúmenes EBS gp3.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab13/eks-cluster.sh
  ```

**Salida esperada:** Debe crearse `scripts/eks-cluster.sh` con las acciones `create`, `status` y `delete`, configurado para cinco workers `m6i.xlarge` y los add-ons requeridos.

- {% include step_label.html %} Habilita y valida la sintaxis del script de EKS antes de solicitar la creación del clúster en AWS.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```
  ```bash
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe devolver errores; el script debe quedar ejecutable antes de iniciar la creación del clúster.


## StorageClass e instalación del Operator
- {% include step_label.html %} Define la StorageClass gp3 con EBS CSI y WaitForFirstConsumer para aprovisionar volúmenes en la zona del Pod.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'EOF'
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
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/storageclass-gp3.yaml` con `ebs.csi.aws.com`, tipo `gp3` y `WaitForFirstConsumer`.

- {% include step_label.html %} Registra la StorageClass gp3 y actualiza el repositorio Helm oficial antes de instalar Couchbase Operator.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```
  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```

**Salida esperada:** Kubernetes debe crear o configurar `gp3-couchbase`; Helm debe registrar o confirmar el repositorio `couchbase` y actualizarlo sin errores.

- {% include step_label.html %} Instala Couchbase Operator 2.92.0 y Admission Controller sin crear automáticamente un CouchbaseCluster.

  ```bash
  helm upgrade --install cb-operator \
    couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

**Salida esperada:** Helm debe instalar o actualizar la release `cb-operator` en `couchbase` usando la versión `2.92.0`, sin crear automáticamente un CouchbaseCluster.

- {% include step_label.html %} Espera que los Deployments del Operator estén Available antes de crear recursos personalizados de Couchbase.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

**Salida esperada:** Todos los Deployments del namespace `couchbase` deben alcanzar la condición `Available` antes del timeout configurado.


## Preparar RBAC oficial para backup

> **IMPORTANTE:** Couchbase recomienda generar el `ServiceAccount`, `Role` y `RoleBinding` de backup con la utilidad `cao` correspondiente a la misma versión del Operator. Esto evita mantener manualmente una lista de permisos que puede cambiar entre releases.
{: .lab-note .important .compact}

- {% include step_label.html %} Crea un directorio local para almacenar las herramientas del Operator utilizadas durante la práctica.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab13/tools/operator
  cd /c/LABS/couchbase-nosql/lab13/tools/operator
  ```
**Salida esperada:** El directorio tools/operator debe quedar creado y la terminal debe ubicarse en esa ruta antes de preparar la utilidad cao.

- {% include step_label.html %} Descarga desde Couchbase el paquete de **Couchbase Kubernetes Operator 2.92.0 para Windows x86_64** y descomprímelo en tools/operator.

  ```bash
  https://packages.couchbase.com/releases/couchbase-operator/2.9.2/couchbase-autonomous-operator_2.9.2-kubernetes-windows-amd64.zip
  ```
  ```bash
  https://www.couchbase.com/downloads/?family=couchbase-autonomous-operator
  ```

**Salida esperada:** Debe existir cao.exe dentro del directorio bin del paquete descomprimido del Operator.

```text
couchbase-autonomous-operator-kubernetes_2.92.0-windows_x86_64/
└── bin/
    └── cao.exe
```

- {% include step_label.html %} Localiza cao.exe para confirmar la ruta exacta del ejecutable antes de incorporarlo temporalmente al PATH.

  ```bash
  find . \
    -type f \
    -iname 'cao.exe' \
    -print
  ```

**Salida esperada:** Debe mostrarse una ruta que termine en /bin/cao.exe y corresponda al paquete del Operator utilizado en la práctica.

- {% include step_label.html %} Obtén automáticamente la carpeta bin que contiene cao.exe y agrégala al PATH de la terminal Git Bash actual.

  ```bash
  CAO_BIN=$(
    dirname "$(
      find "$PWD" \
        -type f \
        -iname 'cao.exe' \
        -print \
      | head -n1
    )"
  )

  export PATH="$CAO_BIN:$PATH"

  echo "CAO_BIN=$CAO_BIN"
  ```

**Salida esperada:** CAO_BIN debe mostrar la carpeta bin donde se encuentra cao.exe y la variable PATH debe quedar actualizada en la terminal actual.

- {% include step_label.html %} Regresa al directorio raíz de la práctica conservando cao disponible en el PATH de esta terminal.

  ```bash
  cd /c/LABS/couchbase-nosql/lab13

  source lab.env

  command -v cao
  ```

**Salida esperada:** La terminal debe quedar ubicada en lab13, las variables de lab.env deben cargarse y command -v cao debe seguir devolviendo la ruta del ejecutable.

- {% include step_label.html %} Verifica `cao` y genera el RBAC oficial de backup para el namespace usando la misma versión del Operator.

  ```bash
  cao generate backup \
    -n "$CB_NAMESPACE" \
    > manifests/backup-rbac.yaml
  ```

**Salida esperada:** `cao` debe estar disponible y generar `manifests/backup-rbac.yaml` con el RBAC de backup correspondiente a la versión del Operator.

- {% include step_label.html %} Aplica el ServiceAccount, Role y RoleBinding de backup generados por `cao` para habilitar los Jobs administrados.

  ```bash
  kubectl apply -f manifests/backup-rbac.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar los recursos RBAC de backup generados por `cao` sin errores de validación.

- {% include step_label.html %} Confirma que el ServiceAccount de backup existe antes de habilitar la administración de backups en el clúster.

  ```bash
  kubectl get serviceaccount couchbase-backup \
    -n "$CB_NAMESPACE"
  ```

**Salida esperada:** Debe mostrarse el ServiceAccount `couchbase-backup` dentro del namespace `couchbase`.


## Crear Secret, CouchbaseCluster y bucket
- {% include step_label.html %} Crea o actualiza el Secret administrativo que Operator utilizará para inicializar y administrar Couchbase Server.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe crear o configurar `secret/cb-admin` sin imprimir las credenciales en claro.

- {% include step_label.html %} Define el CouchbaseCluster con cuatro Pods, persistencia gp3, cuotas explícitas y RollingUpgrade por SwapRebalance.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-cs400
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
      indexServiceMemoryQuota: 1Gi
      indexer:
        storageMode: plasma

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - data
    backup:
      managed: true
      serviceAccountName: couchbase-backup
    buckets:
      managed: true
    upgrade:
      upgradeProcess: SwapRebalance
      upgradeStrategy: RollingUpgrade
      rollingUpgrade:
        maxUpgradable: 1
    servers:
      - name: data
        size: 3
        services:
          - data
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: data-volume
      - name: query-index
        size: 1
        services:
          - query
          - index
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: index-volume
    volumeClaimTemplates:
      - metadata:
          name: data-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 30Gi
      - metadata:
          name: index-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 20Gi
  EOF
  ```

**Salida esperada:** Debe crearse el manifiesto del clúster con 3 Data Pods, 1 Query+Index Pod, cuotas Data/Index de `1Gi`, persistencia gp3 y RollingUpgrade.

- {% include step_label.html %} Registra el CouchbaseCluster mediante Server-Side Apply para iniciar la reconciliación declarativa del Operator.

  ```bash
  kubectl apply --server-side -f manifests/couchbase-cluster.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `couchbasecluster.couchbase.com/cb-cs400` mediante Server-Side Apply.

- {% include step_label.html %} Espera que el CouchbaseCluster alcance Available antes de crear bucket, scope, colección o cargas de prueba.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    couchbasecluster/"$CB_CLUSTER" \
    --timeout=15m
  ```

**Salida esperada:** La espera debe finalizar con `condition met`, confirmando que `cb-cs400` alcanzó la condición `Available`.

- {% include step_label.html %} Define el bucket administrado con 512Mi por Data Pod, una réplica y eviction policy valueOnly.

  ```bash
  cat > manifests/recovery-bucket.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab13-recovery
    namespace: couchbase
  spec:
    memoryQuota: 512Mi
    replicas: 1
    evictionPolicy: valueOnly
    conflictResolution: seqno
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/recovery-bucket.yaml` con `memoryQuota: 512Mi`, una réplica y `evictionPolicy: valueOnly`.

- {% include step_label.html %} Crea el bucket administrado después de reservar 1Gi de memoria para Data Service en cada Pod de datos.

  ```bash
  kubectl apply -f manifests/recovery-bucket.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `couchbasebucket.couchbase.com/lab13-recovery` sin rechazo por cuota.


## Cliente, port-forward y dataset
- {% include step_label.html %} Define el Pod cliente Python y obtiene las credenciales desde `cb-admin` para evitar valores hardcodeados.

  ```bash
  cat > manifests/lab-client.yaml << 'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-lab13-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 14400"]
        env:
          - name: CB_USER
            valueFrom:
              secretKeyRef:
                name: cb-admin
                key: username
          - name: CB_PASS
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
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/lab-client.yaml` con el Pod `cb-lab13-client` y las credenciales obtenidas desde `secret/cb-admin`.

- {% include step_label.html %} Crea el Pod cliente y espera que esté Ready antes de instalar el SDK o ejecutar scripts contra Couchbase.

  ```bash
  kubectl apply -f manifests/lab-client.yaml
  kubectl wait -n "$CB_NAMESPACE" --for=condition=Ready pod/cb-lab13-client --timeout=3m
  ```

**Salida esperada:** Kubernetes debe crear o configurar `cb-lab13-client` y la espera debe terminar con `condition met`.

- {% include step_label.html %} Instala Couchbase Python SDK dentro del cliente para cargar datos y ejecutar las pruebas reproducibles del laboratorio.

  ```bash
  kubectl exec -n "$CB_NAMESPACE" cb-lab13-client -- pip install --quiet 'couchbase>=4.4,<5'
  ```

**Salida esperada:** `pip` debe finalizar sin errores; pueden aparecer avisos informativos, pero el SDK Couchbase debe quedar instalado dentro del Pod cliente.

- {% include step_label.html %} Publica Management REST por el Service estable del clúster y conserva esta terminal abierta durante la práctica.

  ```bash
  kubectl port-forward -n "$CB_NAMESPACE" service/cb-cs400-ui 8091:8091
  ```

**Salida esperada:** La terminal debe permanecer activa mostrando `Forwarding ... 8091 -> 8091`, confirmando acceso local a Management REST.

- {% include step_label.html %} Descubre por labels un Pod con Query Service y publica el puerto 8093 sin depender del nombre de la server class.

  {%raw%}
  ```bash
  QUERY_POD=$(
    kubectl get pods -n "$CB_NAMESPACE" -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_query=enabled" -o jsonpath='{.items[0].metadata.name}'
  )

  echo "QUERY_POD=$QUERY_POD"
  ```
  {%endraw%}
  ```bash
  kubectl port-forward -n "$CB_NAMESPACE" "pod/${QUERY_POD}" 8093:8093
  ```

**Salida esperada:** `QUERY_POD` debe mostrar un Pod Couchbase válido con Query Service y el port-forward debe quedar activo en `8093 -> 8093`.

- {% include step_label.html %} Crea el scope `production` dentro del bucket y confirma que Query Service acepte la sentencia sin errores.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=CREATE SCOPE `lab13-recovery`.production IF NOT EXISTS' \
    | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder con `status: "success"` y sin errores al crear el scope `production`.

- {% include step_label.html %} Crea la colección `transactions` donde se almacenará el dataset utilizado por diagnóstico, backup y restore.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=CREATE COLLECTION `lab13-recovery`.production.transactions IF NOT EXISTS' \
    | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder con `status: "success"` y sin errores al crear la colección `transactions`.

- {% include step_label.html %} Crea el primary index temporal requerido para consultas generales de fingerprint y validación del dataset.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=CREATE PRIMARY INDEX IF NOT EXISTS ON transactions' \
    | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder con `status: "success"`, confirmando la creación o existencia del primary index sobre `transactions`.

- {% include step_label.html %} Crea el generador determinista de 100,000 documentos con write_id y ack_epoch para medir integridad y recuperación.

  ```bash
  cat > scripts/seed_dataset.py << 'PYEOF'
  import os
  import time
  from datetime import timedelta
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  TOTAL = 100_000
  BATCH = 500

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )
  cluster.wait_until_ready(timedelta(seconds=30))
  collection = cluster.bucket("lab13-recovery").scope("production").collection("transactions")

  for start in range(1, TOTAL + 1, BATCH):
      docs = {}
      for write_id in range(start, min(start + BATCH, TOTAL + 1)):
          docs[f"recovery::{write_id:09d}"] = {
              "type": "transaction",
              "write_id": write_id,
              "amount": round(10 + (write_id % 25000) / 100, 2),
              "region": ["north", "south", "east", "west"][write_id % 4],
              "ack_epoch": time.time(),
              "payload": "x" * 4096
          }
      collection.upsert_multi(docs)
      print(f"seeded={min(start + BATCH - 1, TOTAL)}", flush=True)

  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/seed_dataset.py` con el generador determinista de 100,000 documentos y los campos `write_id`, `ack_epoch`, `amount`, `region` y `payload`.

- {% include step_label.html %} Valida la sintaxis del generador antes de copiarlo al Pod cliente y ejecutar la carga inicial de documentos.

  ```bash
  python -m py_compile scripts/seed_dataset.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/seed_dataset.py \
    couchbase/cb-lab13-client:/tmp/seed_dataset.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab13-client \
    -- \
    python /tmp/seed_dataset.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma sintaxis válida del generador.


## Precargar imagen objetivo 7.6.8
- {% include step_label.html %} Define un DaemonSet temporal para precargar la imagen 7.6.8 en los workers antes del rolling upgrade.

  ```bash
  cat > manifests/prepull-target-image.yaml << 'EOF'
  apiVersion: apps/v1
  kind: DaemonSet
  metadata:
    name: cb-prepull-768
    namespace: couchbase
  spec:
    selector:
      matchLabels:
        app: cb-prepull-768
    template:
      metadata:
        labels:
          app: cb-prepull-768
      spec:
        containers:
          - name: prepull
            image: couchbase/server:enterprise-7.6.8
            command: ["sh", "-c", "sleep 180"]
            resources:
              requests:
                cpu: "10m"
                memory: "32Mi"
        terminationGracePeriodSeconds: 0
  EOF
  ```

**Salida esperada:** Debe crearse el DaemonSet temporal `cb-prepull-768` usando la imagen `couchbase/server:enterprise-7.6.8`.

- {% include step_label.html %} Precarga la imagen objetivo en los workers y espera que el DaemonSet complete su rollout antes de eliminarlo.

  ```bash
  kubectl apply -f manifests/prepull-target-image.yaml
  kubectl rollout status -n "$CB_NAMESPACE" daemonset/cb-prepull-768 --timeout=10m
  ```

**Salida esperada:** El DaemonSet debe quedar aplicado y completar su rollout en todos los workers antes del timeout.

- {% include step_label.html %} Elimina el DaemonSet de precarga una vez que la imagen objetivo quedó almacenada en los nodos.

  ```bash
  kubectl delete -n "$CB_NAMESPACE" daemonset/cb-prepull-768
  ```

**Salida esperada:** Kubernetes debe confirmar la eliminación de `daemonset.apps/cb-prepull-768`.


---

## 🔎 Tarea 1. Establecer baseline y metodología — 4 min

### Tarea 1.1. Confirmar estado Couchbase
- {% include step_label.html %} Captura salud, membresía, servicios y versión de los nodos antes de inyectar incidentes controlados.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
    | jq '{rebalanceStatus,nodes:[.nodes[]|{hostname,status,clusterMembership,version,services}]}' \
    | tee results/baseline-cluster.json
  ```

**Salida esperada:** Debe guardarse un JSON con 4 nodos Couchbase `healthy`, membresía `active`, `rebalanceStatus=none` y versión inicial 7.6.2.


### Tarea 1.2. Capturar fingerprint del dataset
- {% include step_label.html %} Calcula count, checksum y límites de write_id para establecer el fingerprint inicial del dataset.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT COUNT(*) AS total,SUM(write_id) AS checksum,MIN(write_id) AS min_write_id,MAX(write_id) AS max_write_id FROM `lab13-recovery`.production.transactions' \
    | jq '.results[0]' \
    | tee results/fingerprint-initial.json
  ```

**Salida esperada:** Debe guardarse `total=100000`, `min_write_id=1`, `max_write_id=100000` y un `checksum` mayor que cero.


### Tarea 1.3. Registrar metodología
- {% include step_label.html %} Documenta la metodología de seis etapas que se seguirá para investigar y cerrar cada incidente del laboratorio.

  ```bash
  cat > reports/troubleshooting-method.md << 'EOF'
  # Metodología de troubleshooting

  1. Observar — registrar síntoma y momento.
  2. Delimitar — identificar servicio, recurso y alcance.
  3. Formular hipótesis — ordenar causas plausibles.
  4. Probar — recopilar evidencia que confirme o descarte.
  5. Corregir — cambiar una variable relevante.
  6. Verificar — repetir la medición y confirmar recuperación.
  EOF
  ```

**Salida esperada:** Debe crearse `reports/troubleshooting-method.md` con las seis etapas: Observar, Delimitar, Formular hipótesis, Probar, Corregir y Verificar.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🧠 Tarea 2. Incidente A: presión de memoria — 7 min

### Tarea 2.1. OBSERVAR métricas previas
- {% include step_label.html %} Captura métricas de memoria y background fetch antes de reducir la cuota para disponer de una línea base.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/stats" \
    | jq '.op.samples | {resident_ratio:(.vb_active_resident_items_ratio[-1] // null),bg_fetched:(.ep_bg_fetched[-1] // null),tmp_oom:(.ep_tmp_oom_errors[-1] // null),queue:(.ep_queue_size[-1] // null),mem_used:(.mem_used[-1] // null)}' \
    | tee incidents/memory-before.json
  ```

**Salida esperada:** Debe guardarse `incidents/memory-before.json` con resident ratio, background fetches, tmp OOM, cola y memoria usada antes del cambio de cuota.


### Tarea 2.2. DELIMITAR modificando una sola variable
- {% include step_label.html %} Reduce la cuota a 256Mi por Data Pod y valida por REST la cuota agregada aplicada a todos los nodos Data.

  ```bash
  kubectl patch couchbasebucket "$CB_BUCKET" \
  -n "$CB_NAMESPACE" \
  --type=merge \
  -p '{"spec":{"memoryQuota":"256Mi"}}'
  ```
  ```bash
  DATA_NODES=$(
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default \
    | jq '[.nodes[] | select(.services | index("kv"))] | length'
  )

  EXPECTED_QUOTA_MIB=$((256 * DATA_NODES))
  ```
  ```bash
  for i in $(seq 1 30); do
    QUOTA=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
      | jq -r '.quota.ram / 1024 / 1024 | floor'
    )

    echo "quota=${QUOTA}MiB expected=${EXPECTED_QUOTA_MIB}MiB"

    [[ "$QUOTA" -eq "$EXPECTED_QUOTA_MIB" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** Kubernetes debe aplicar `256Mi` por Data Pod y la validación REST debe converger a la cuota agregada calculada para los Data nodes.


### Tarea 2.3. FORMULAR HIPÓTESIS
- {% include step_label.html %} Registra el síntoma inducido y las hipótesis que se contrastarán con carga cliente y métricas del servidor.

  ```bash
  cat > incidents/incident-001-memory.md << 'EOF'
  # INCIDENTE-001 — Presión de memoria

  ## Síntoma inducido
  La memoryQuota del bucket se redujo manteniendo el mismo dataset.

  ## Hipótesis
  1. El working set deja de caber cómodamente en la cuota.
  2. Aumentan elementos no residentes y background fetches.
  3. La latencia de lecturas aleatorias puede crecer.
  4. Un resident ratio bajo aislado no demuestra por sí mismo una falla.
  EOF
  ```

**Salida esperada:** Debe crearse `incidents/incident-001-memory.md` con el síntoma inducido y las hipótesis que se contrastarán durante el incidente.


### Tarea 2.4. PROBAR mediante carga de lectura
- {% include step_label.html %} Crea una sonda de lecturas aleatorias que mida throughput, errores y percentiles durante la presión de memoria.

  ```bash
  cat > scripts/read_probe.py << 'PYEOF'
  import json
  import math
  import os
  import random
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  collection = (
      cluster.bucket("lab13-recovery")
      .scope("production")
      .collection("transactions")
  )

  samples = []
  errors = 0
  started = time.time()
  deadline = started + 45

  while time.time() < deadline:
      key = f"recovery::{random.randint(1, 100000):09d}"
      t0 = time.perf_counter()

      try:
          collection.get(key)

          samples.append(
              (time.perf_counter() - t0) * 1000
          )

      except Exception:
          errors += 1


  ordered = sorted(samples)


  def pct(p):
      if not ordered:
          return 0

      i = max(
          math.ceil(
              p / 100 * len(ordered)
          ) - 1,
          0
      )

      return ordered[
          min(i, len(ordered) - 1)
      ]


  print(
      json.dumps(
          {
              "operations": len(samples),
              "errors": errors,
              "ops_per_sec": round(
                  len(samples)
                  / max(time.time() - started, 1),
                  2
              ),
              "p50_ms": round(pct(50), 2),
              "p95_ms": round(pct(95), 2),
              "p99_ms": round(pct(99), 2)
          },
          indent=2
      )
  )

  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/read_probe.py` con una sonda de lectura aleatoria de 45 segundos que mida operaciones, errores, throughput y p50/p95/p99.

- {% include step_label.html %} Valida la sintaxis de la sonda de lectura antes de copiarla al Pod cliente.

  ```bash
  python -m py_compile scripts/read_probe.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp scripts/read_probe.py couchbase/cb-lab13-client:/tmp/read_probe.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma que `read_probe.py` es sintácticamente válido.

- {% include step_label.html %} Ejecuta la sonda durante 45 segundos y guarda throughput, errores y latencias para correlacionarlos con memoria.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab13-client \
    -- \
    python /tmp/read_probe.py \
  | tee incidents/memory-client-load.json
  ```

**Salida esperada:** Debe generarse `memory-client-load.json` con `operations > 0`, `ops_per_sec`, `errors` y latencias p50/p95/p99.

### Tarea 2.5. PROBAR métricas del servidor
- {% include step_label.html %} Captura métricas del servidor durante la presión para comparar resident ratio, background fetch y cola.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/stats" \
    | jq '.op.samples | {resident_ratio:(.vb_active_resident_items_ratio[-1] // null),bg_fetched:(.ep_bg_fetched[-1] // null),tmp_oom:(.ep_tmp_oom_errors[-1] // null),queue:(.ep_queue_size[-1] // null),mem_used:(.mem_used[-1] // null)}' \
    | tee incidents/memory-during.json
  ```

**Salida esperada:** Debe guardarse `memory-during.json` con resident ratio, background fetches, tmp OOM, cola y memoria usada durante la presión inducida.


> **IMPORTANTE:** `ep_bg_fetched` representa background fetches. No conviertas un valor acumulado directamente en “fetches por segundo” ni lo llames cache miss ratio.
{: .lab-note .important .compact}

### Tarea 2.6. CORREGIR y VERIFICAR
- {% include step_label.html %} Restaura la cuota a 512Mi por Data Pod para corregir el incidente controlado.

  ```bash
  kubectl patch couchbasebucket "$CB_BUCKET" \
  -n "$CB_NAMESPACE" \
  --type=merge \
  -p '{"spec":{"memoryQuota":"512Mi"}}'
```

**Salida esperada:** Kubernetes debe aplicar nuevamente `512Mi` por Data Pod para iniciar la corrección del incidente.

- {% include step_label.html %} Espera que Management REST refleje la cuota agregada restaurada antes de capturar métricas posteriores.

  ```bash
  EXPECTED_QUOTA_MIB=$((512 * DATA_NODES))

  for i in $(seq 1 30); do
    QUOTA=$(
      curl -fsS \
        -u "$CB_USER:$CB_PASS" \
        "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
      | jq -r '.quota.ram / 1024 / 1024 | floor'
    )

    echo "quota=${QUOTA}MiB expected=${EXPECTED_QUOTA_MIB}MiB"

    [[ "$QUOTA" -eq "$EXPECTED_QUOTA_MIB" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** La validación REST debe converger a la cuota agregada esperada de `512Mi × Data nodes` antes de continuar.

- {% include step_label.html %} Guarda métricas posteriores a la corrección para completar la comparación antes/durante/después.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/stats" \
    | jq '.op.samples | {resident_ratio:(.vb_active_resident_items_ratio[-1] // null),bg_fetched:(.ep_bg_fetched[-1] // null),mem_used:(.mem_used[-1] // null)}' \
    | tee incidents/memory-after.json
  ```

**Salida esperada:** Debe guardarse `memory-after.json` con resident ratio, background fetches y memoria usada después de restaurar la cuota.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🧩 Tarea 3. Incidente B: índice crítico deferred — 5 min

### Tarea 3.1. OBSERVAR y DELIMITAR
- {% include step_label.html %} Crea el índice GSI en estado deferred para reproducir una degradación sin solicitar una réplica inexistente.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=
      CREATE INDEX idx_transactions_region
      ON transactions(region, amount)
      WITH {"defer_build":true}' \
  | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe responder `status: "success"`, creando `idx_transactions_region` en estado deferred y sin réplica.

- {% include step_label.html %} Consulta `system:indexes` y guarda la evidencia de que `idx_transactions_region` permanece deferred.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT name,state,bucket_id,scope_id,keyspace_id,index_key FROM system:indexes WHERE name="idx_transactions_region"' \
    | tee incidents/index-deferred-state.json \
    | jq '.results'
  ```

**Salida esperada:** La consulta a `system:indexes` debe mostrar `idx_transactions_region` con `state` igual a `deferred`.


### Tarea 3.2. FORMULAR y PROBAR
- {% include step_label.html %} Documenta el síntoma del índice deferred y la hipótesis que se comprobará mediante EXPLAIN y BUILD INDEX.

  ```bash
  cat > incidents/incident-002-index.md << 'EOF'
  # INCIDENTE-002 — Índice crítico deferred

  ## Síntoma
  La aplicación espera idx_transactions_region, pero el índice no fue construido.

  ## Hipótesis
  CREATE INDEX utilizó defer_build y nunca se ejecutó BUILD INDEX.
  EOF
  ```

**Salida esperada:** Debe crearse `incident-002-index.md` documentando que el índice fue creado con `defer_build` y aún no se ejecutó `BUILD INDEX`.

- {% include step_label.html %} Captura el EXPLAIN previo para observar el plan disponible mientras el índice crítico sigue sin construirse.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=EXPLAIN SELECT region,COUNT(*) AS total,AVG(amount) AS avg_amount FROM transactions WHERE region="north" GROUP BY region' \
    | jq '.results[0]' \
    | tee incidents/index-plan-before.json
  ```

**Salida esperada:** Debe generarse `index-plan-before.json` con el EXPLAIN previo a construir el índice, conservando el plan disponible durante el incidente.


### Tarea 3.3. CORREGIR y VERIFICAR
- {% include step_label.html %} Construye explícitamente el índice deferred para aplicar la remediación del incidente de Query.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=BUILD INDEX ON transactions(idx_transactions_region)' \
    | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"`, iniciando la construcción de `idx_transactions_region`.

- {% include step_label.html %} Sondea `system:indexes` hasta confirmar que el índice crítico alcanzó el estado online.

  ```bash
  for i in $(seq 1 60); do
    STATE=$(curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
      --data-urlencode 'statement=SELECT RAW state FROM system:indexes WHERE name="idx_transactions_region"' \
      | jq -r '.results[0] // "missing"')
    echo "state=$STATE"
    [[ "$STATE" == "online" ]] && break
    sleep 2
  done
  ```

**Salida esperada:** Los reintentos deben evolucionar hasta `state=online`, confirmando que el índice quedó disponible para Query Service.

- {% include step_label.html %} Captura el EXPLAIN posterior y verifica que el plan incluya `idx_transactions_region` después de construirlo.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=EXPLAIN SELECT region,COUNT(*) AS total,AVG(amount) AS avg_amount FROM transactions WHERE region="north" GROUP BY region' \
    | jq '.results[0]' \
    | tee incidents/index-plan-after.json

  grep -o 'idx_transactions_region' incidents/index-plan-after.json | head
  ```

**Salida esperada:** Debe generarse `index-plan-after.json` y la búsqueda debe mostrar `idx_transactions_region` dentro del plan posterior.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## 🧰 Tarea 4. Recolectar diagnóstico — 4 min

### Tarea 4.1. Snapshot Kubernetes y Operator
- {% include step_label.html %} Guarda el CouchbaseCluster completo como evidencia declarativa del estado del entorno.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" -n "$CB_NAMESPACE" -o yaml > diagnostics/couchbasecluster.yaml
  ```

**Salida esperada:** Debe crearse `diagnostics/couchbasecluster.yaml` con el recurso completo del clúster.

- {% include step_label.html %} Registra Pods y ubicación de ejecución para documentar el estado Kubernetes durante el diagnóstico.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" -o wide > diagnostics/pods.txt
  ```

**Salida esperada:** Debe crearse `diagnostics/pods.txt` con el estado y ubicación de los Pods del namespace `couchbase`.

- {% include step_label.html %} Registra los PVC y su estado para incluir evidencia de persistencia dentro del paquete de diagnóstico.

  ```bash
  kubectl get pvc -n "$CB_NAMESPACE" -o wide > diagnostics/pvc.txt
  ```

**Salida esperada:** Debe crearse `diagnostics/pvc.txt` con los PVC, su estado, capacidad y StorageClass.

- {% include step_label.html %} Guarda los eventos ordenados cronológicamente para correlacionar reconciliaciones, fallos y cambios de recursos.

  ```bash
  kubectl get events -n "$CB_NAMESPACE" --sort-by=.lastTimestamp > diagnostics/events.txt
  ```

**Salida esperada:** Debe crearse `diagnostics/events.txt` con los eventos del namespace ordenados por `lastTimestamp`.

- {% include step_label.html %} Descubre dinámicamente el Deployment del Operator sin asumir un nombre fijo.

  ```bash
  OPERATOR_DEPLOYMENT=$(kubectl get deployment -n "$CB_NAMESPACE" -o name | grep operator | grep -v admission | head -n 1 | cut -d/ -f2)
  ```

**Salida esperada:** `OPERATOR_DEPLOYMENT` debe contener el nombre del Deployment principal del Couchbase Operator y no quedar vacío.

- {% include step_label.html %} Guarda los últimos 20 minutos de logs del Operator para correlacionarlos con los incidentes observados.

  ```bash
  kubectl logs -n "$CB_NAMESPACE" deployment/"$OPERATOR_DEPLOYMENT" --since=20m > diagnostics/operator.log
  ```

**Salida esperada:** Debe crearse `diagnostics/operator.log` con los últimos 20 minutos de logs del Couchbase Operator.


### Tarea 4.2. Ejecutar cbcollect_info en un Data Pod
- {% include step_label.html %} Descubre por labels un Pod que ejecute Data Service para ejecutar `cbcollect_info` sobre una instancia válida.

  ```bash
  DATA_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER,couchbase_service_data=enabled" \
      -o jsonpath='{.items[0].metadata.name}'
  )

  echo "DATA_POD=$DATA_POD"
  ```

**Salida esperada:** `DATA_POD` debe mostrar un Pod Couchbase válido que ejecute Data Service.

- {% include step_label.html %} Ejecuta `cbcollect_info` dentro del Data Pod y genera un ZIP con diagnóstico de Couchbase Server.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec -n "$CB_NAMESPACE" "$DATA_POD" -- \
    /opt/couchbase/bin/cbcollect_info \
      /tmp/lab13-cbcollect.zip \
      --log-redaction-level partial
  ```

**Salida esperada:** `cbcollect_info` debe finalizar sin errores y crear `/tmp/lab13-cbcollect.zip` dentro del Data Pod.

- {% include step_label.html %} Copia el ZIP de diagnóstico al equipo local sin permitir que Git Bash transforme la ruta `/tmp`.

  ```bash
  MSYS_NO_PATHCONV=1 MSYS_NO_PATHCONV=1 kubectl cp "${CB_NAMESPACE}/${DATA_POD}:/tmp/lab13-cbcollect.zip" diagnostics/lab13-cbcollect.zip
  ls -lh diagnostics/lab13-cbcollect.zip
  ```

**Salida esperada:** Debe copiarse `diagnostics/lab13-cbcollect.zip` y `ls -lh` debe mostrar un archivo ZIP con tamaño mayor que cero.


### Tarea 4.3. Empaquetar evidencia
- {% include step_label.html %} Guarda el CouchbaseCluster completo como evidencia declarativa del estado del entorno.

  ```bash
  tar -czf diagnostics/lab13-diagnostics.tar.gz \
    diagnostics/couchbasecluster.yaml \
    diagnostics/pods.txt \
    diagnostics/pvc.txt \
    diagnostics/events.txt \
    diagnostics/operator.log

  ls -lh diagnostics/
  ```

**Salida esperada:** Debe crearse `diagnostics/couchbasecluster.yaml` con el recurso completo del clúster.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 💾 Tarea 5. Ejecutar y validar backup inmediato — 5 min

### Tarea 5.1. Capturar fingerprint del restore point
- {% include step_label.html %} Captura count, checksum y write_id del restore point inmediatamente antes de solicitar el backup.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT COUNT(*) AS total,SUM(write_id) AS checksum,MIN(write_id) AS min_write_id,MAX(write_id) AS max_write_id FROM `lab13-recovery`.production.transactions' \
    | jq '.results[0]' \
    | tee backup/fingerprint-at-backup.json
  ```

**Salida esperada:** Debe guardarse el fingerprint del restore point con `total=100000`, checksum y límites de `write_id` antes del backup.


### Tarea 5.2. Crear CouchbaseBackup inmediato
- {% include step_label.html %} Define un CouchbaseBackup `immediate_full` de la colección protegida sobre un PVC gp3 de 10Gi.

  ```bash
  cat > backup/immediate-backup.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseBackup
  metadata:
    name: lab13-backup
    namespace: couchbase
  spec:
    strategy: immediate_full
    size: 10Gi
    storageClassName: gp3-couchbase
    data:
      include:
        - lab13-recovery.production.transactions
    threads: 2
    successfulJobsHistoryLimit: 3
    failedJobsHistoryLimit: 3
  EOF
  ```

**Salida esperada:** Debe crearse `backup/immediate-backup.yaml` con estrategia `immediate_full`, PVC gp3 de 10Gi y la colección `lab13-recovery.production.transactions` incluida.

- {% include step_label.html %} Registra el instante de inicio del backup para conservar una referencia temporal del punto de recuperación.

  ```bash
  BACKUP_START_EPOCH=$(date +%s)
  echo "$BACKUP_START_EPOCH" > backup/backup-start-epoch.txt
  ```

**Salida esperada:** Debe crearse `backup/backup-start-epoch.txt` con un epoch Unix válido correspondiente al inicio del backup.

- {% include step_label.html %} Crea el CouchbaseBackup para que Operator genere inmediatamente el Job de backup y su PVC asociado.

  ```bash
  kubectl apply -f backup/immediate-backup.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `couchbasebackup.couchbase.com/lab13-backup`.


### Tarea 5.3. Esperar Job y validar status

- {% include step_label.html %} Sondea el estado soportado del CouchbaseBackup hasta confirmar `lastSuccess` y ausencia de fallo.

  ```bash
  BACKUP_READY=false

  for i in $(seq 1 120); do
    BACKUP_STATE=$(
      kubectl get couchbasebackup "$BACKUP_NAME" \
        -n "$CB_NAMESPACE" \
        -o json
    )

    RUNNING=$(printf '%s' "$BACKUP_STATE" | jq -r '.status.running // false')
    FAILED=$(printf '%s' "$BACKUP_STATE" | jq -r '.status.failed // false')
    LAST_SUCCESS=$(printf '%s' "$BACKUP_STATE" | jq -r '.status.lastSuccess // ""')

    echo "Intento $i - running=$RUNNING failed=$FAILED lastSuccess=${LAST_SUCCESS:-none}"

    if [[ "$FAILED" == "true" ]]; then
      break
    fi

    if [[ "$RUNNING" == "false" && -n "$LAST_SUCCESS" ]]; then
      BACKUP_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$BACKUP_READY" == "true" ]]; then
    echo "PASS: backup inmediato completado."
  else
    echo "FAIL: backup inmediato no completó correctamente."
  fi
```

**Salida esperada:** Los reintentos deben finalizar con `PASS: backup inmediato completado.`, `failed=false` y `lastSuccess` no vacío.

- {% include step_label.html %} Descubre el Job de backup por ownerReference y muestra su estado como evidencia adicional de ejecución.

  ```bash
  BACKUP_JOB="${BACKUP_NAME}-full"

  echo "BACKUP_NAME=$BACKUP_NAME"
  echo "BACKUP_JOB=$BACKUP_JOB"

  kubectl get job "$BACKUP_JOB" \
    -n "$CB_NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[-1].type,SUCCEEDED:.status.succeeded,FAILED:.status.failed'
  ```

**Salida esperada:** Debe mostrarse el Job asociado al CouchbaseBackup o `not-found`; si existe, su estado debe indicar `SUCCEEDED=1` y sin fallos.

- {% include step_label.html %} Guarda el status del CouchbaseBackup con duración, repositorio, ejecuciones y último éxito.

  ```bash
  kubectl get couchbasebackup "$BACKUP_NAME" -n "$CB_NAMESPACE" -o json \
    | jq '{strategy:.spec.strategy,running:.status.running,failed:.status.failed,lastRun:.status.lastRun,lastSuccess:.status.lastSuccess,duration:.status.duration,repo:.status.repo,backups:.status.backups}' \
    | tee backup/backup-status.json
  ```

**Salida esperada:** Debe crearse `backup/backup-status.json` con estrategia, estado, `lastSuccess`, duración, repo y backups reportados por el recurso.

- {% include step_label.html %} Confirma que el PVC del backup existe y está Bound antes de simular pérdida de datos.

  ```bash
  kubectl get pvc "$BACKUP_NAME" -n "$CB_NAMESPACE" -o wide
  ```

**Salida esperada:** Debe mostrarse el PVC `lab13-backup` en estado `Bound` antes de simular la pérdida de datos.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🚨 Tarea 6. Simular pérdida y ejecutar restore — 7 min

### Tarea 6.1. Generar 1,000 escrituras posteriores al backup
- {% include step_label.html %} Crea 1,000 escrituras posteriores al restore point y conserva el último write_id confirmado con su timestamp.

  ```bash
  cat > scripts/post_backup_writes.py << 'PYEOF'
  import json
  import os
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  collection = (
      cluster.bucket("lab13-recovery")
      .scope("production")
      .collection("transactions")
  )

  start_id = 100001
  total = 1000

  started = time.time()

  for write_id in range(start_id, start_id + total):
      collection.upsert(
          f"recovery::{write_id:09d}",
          {
              "type": "transaction",
              "write_id": write_id,
              "amount": 100.0,
              "region": "post-backup",
              "ack_epoch": time.time(),
              "payload": "x" * 4096
          }
      )

  finished = time.time()

  result = {
      "first_write_id": start_id,
      "last_write_id": start_id + total - 1,
      "writes": total,
      "started_epoch": started,
      "finished_epoch": finished,
      "duration_seconds": round(finished - started, 2)
  }

  print(
      json.dumps(
          result,
          indent=2
      )
  )

  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `post_backup_writes.py` para generar write_id 100001–101000 y registrar el último ACK con su `ack_epoch`.

- {% include step_label.html %} Valida la sintaxis del generador de escrituras posteriores antes de copiarlo al Pod cliente.

  ```bash
  python -m py_compile scripts/post_backup_writes.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/post_backup_writes.py \
    couchbase/cb-lab13-client:/tmp/post_backup_writes.py
  ```

**Salida esperada:** `python -m py_compile` no debe devolver errores; una salida vacía confirma sintaxis válida del script.

- {% include step_label.html %} Ejecuta las 1,000 escrituras posteriores y guarda el último write_id confirmado para calcular el RPO.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab13-client \
    -- \
    python /tmp/post_backup_writes.py \
  | tee backup/last-ack-before-incident.json
  ```

**Salida esperada:** Debe generarse un JSON cuyo último `write_id` sea `101000` y contenga un `ack_epoch` válido.


### Tarea 6.2. Capturar fingerprint pre-incidente
- {% include step_label.html %} Captura el fingerprint con 101,000 documentos antes de eliminar los datos y declarar el incidente.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT COUNT(*) AS total,SUM(write_id) AS checksum,MIN(write_id) AS min_write_id,MAX(write_id) AS max_write_id FROM `lab13-recovery`.production.transactions' \
    | jq '.results[0]' \
    | tee backup/fingerprint-pre-incident.json
  ```

**Salida esperada:** Debe guardarse `total=101000`, `max_write_id=101000` y un checksum correspondiente al dataset antes del incidente.


### Tarea 6.3. Declarar incidente y eliminar datos
- {% include step_label.html %} Registra el instante en que se declara la pérdida para calcular posteriormente el RTO experimental.

  ```bash
  INCIDENT_EPOCH=$(date +%s)
  echo "$INCIDENT_EPOCH" > backup/incident-declared-epoch.txt
  ```

**Salida esperada:** Debe crearse `backup/incident-declared-epoch.txt` con el epoch Unix en que se declara la pérdida.

- {% include step_label.html %} Elimina deliberadamente los documentos de la colección para simular una pérdida de datos controlada.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=DELETE FROM `lab13-recovery`.production.transactions' \
    | jq '{status, metrics, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` y métricas de ejecución sin errores al eliminar los documentos de la colección.

- {% include step_label.html %} Confirma que la colección quedó vacía antes de iniciar el restore selectivo desde el backup validado.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT COUNT(*) AS total FROM `lab13-recovery`.production.transactions' \
    | jq '.results[0]' \
    | tee backup/fingerprint-after-loss.json
  ```

**Salida esperada:** Debe guardarse un fingerprint posterior a la pérdida con `total=0`.


### Tarea 6.4. Crear CouchbaseBackupRestore selectivo
- {% include step_label.html %} Obtiene el repositorio reportado por CouchbaseBackup para seleccionar explícitamente el restore point.

  ```bash
  BACKUP_REPO=$(kubectl get couchbasebackup "$BACKUP_NAME" -n "$CB_NAMESPACE" -o jsonpath='{.status.repo}')
  echo "BACKUP_REPO=$BACKUP_REPO"
  ```

**Salida esperada:** `BACKUP_REPO` debe mostrar un repositorio no vacío obtenido desde `status.repo` del CouchbaseBackup.

- {% include step_label.html %} Define un CouchbaseBackupRestore que restaura sólo la colección protegida y excluye metadatos no requeridos.

  ```bash
  cat > backup/restore.yaml << EOF
  apiVersion: couchbase.com/v2
  kind: CouchbaseBackupRestore
  metadata:
    name: ${RESTORE_NAME}
    namespace: ${CB_NAMESPACE}
  spec:
    backup: ${BACKUP_NAME}
    preserveRestoreRecord: true
    repo: ${BACKUP_REPO}
    start:
      int: 1
    end:
      int: 1
    forceUpdates: true
    data:
      include:
        - ${CB_BUCKET}.${CB_SCOPE}.${CB_COLLECTION}
    services:
      bucketConfig: false
      data: true
      analytics: false
      bucketQuery: false
      clusterAnalytics: false
      clusterQuery: false
      eventing: false
      ftAlias: false
      ftIndex: false
      gsiIndex: false
      users: false
      views: false
  EOF
  ```

**Salida esperada:** Debe crearse `backup/restore.yaml` apuntando al backup y repo detectados, restaurando sólo `lab13-recovery.production.transactions`.

- {% include step_label.html %} Crea el recurso de restore selectivo para que Operator inicie la recuperación desde el backup elegido.

  ```bash
  kubectl apply -f backup/restore.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `couchbasebackuprestore.couchbase.com/lab13-restore`.


### Tarea 6.5. Esperar restore Job

- {% include step_label.html %} Sondea `completed`, `failed` y `lastSuccess` hasta confirmar que el restore terminó correctamente.

  ```bash
  RESTORE_READY=false

  for i in $(seq 1 120); do
    if ! RESTORE_STATE=$(
      kubectl get couchbasebackuprestore "$RESTORE_NAME" \
        -n "$CB_NAMESPACE" \
        -o json 2>/dev/null
    ); then
      echo "FAIL: recurso CouchbaseBackupRestore no disponible."
      break
    fi

    COMPLETED=$(printf '%s' "$RESTORE_STATE" | jq -r '.status.completed // false')
    FAILED=$(printf '%s' "$RESTORE_STATE" | jq -r '.status.failed // false')
    LAST_SUCCESS=$(printf '%s' "$RESTORE_STATE" | jq -r '.status.lastSuccess // ""')

    echo "Intento $i - completed=$COMPLETED failed=$FAILED lastSuccess=${LAST_SUCCESS:-none}"

    if [[ "$FAILED" == "true" ]]; then
      break
    fi

    if [[ "$COMPLETED" == "true" ]]; then
      RESTORE_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$RESTORE_READY" == "true" ]]; then
    echo "PASS: restore selectivo completado."
  else
    echo "FAIL: restore selectivo no completó correctamente."
  fi
  ```

**Salida esperada:** Los reintentos deben finalizar con `PASS: restore selectivo completado.`, `completed=true`, `failed=false` y `lastSuccess` no vacío.

- {% include step_label.html %} Primero debemos mirar los logs para asegurar que se haya completado correctamente.

  ```bash
  kubectl get events \
    -n "$CB_NAMESPACE" \
    --sort-by=.lastTimestamp \
  | grep -E 'BackupRestore|lab13-restore'
  ```

**Salida esperada:** Deben aparecer eventos relacionados con la creación y posterior eliminación del restore, especialmente BackupRestoreDeleted. Couchbase define ese evento como una condición que indica finalización exitosa.

- {% include step_label.html %} Descubre el Job de restore por ownerReference y muestra su resultado como evidencia complementaria.

  ```bash
  RESTORE_JOB=$(
    kubectl get jobs \
      -n "$CB_NAMESPACE" \
      --sort-by=.metadata.creationTimestamp \
      -o json \
    | jq -r --arg NAME "$RESTORE_NAME" '
        [
          .items[]
          | select(
              any(
                .metadata.ownerReferences[]?;
                .kind == "CouchbaseBackupRestore"
                and .name == $NAME
              )
            )
          | .metadata.name
        ]
        | last // empty
      '
  )

  echo "RESTORE_JOB=${RESTORE_JOB:-not-found}"

  if [[ -n "$RESTORE_JOB" ]]; then
    kubectl get job "$RESTORE_JOB" \
      -n "$CB_NAMESPACE" \
      -o custom-columns='NAME:.metadata.name,SUCCEEDED:.status.succeeded,FAILED:.status.failed'
  fi
  ```

**Salida esperada:** Debe mostrarse el Job asociado al restore o `not-found`; si existe, su estado debe indicar `SUCCEEDED=1` y sin fallos.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## ⏱️ Tarea 7. Medir RPO, RTO e integridad — 4 min

### Tarea 7.1. Fingerprint post-restore
- {% include step_label.html %} Registra el instante de recuperación antes de medir integridad y calcular el RTO experimental.

  ```bash
  RESTORE_READY_EPOCH=$(date +%s)
  echo "$RESTORE_READY_EPOCH" > backup/restore-ready-epoch.txt
  ```

**Salida esperada:** Debe crearse `backup/restore-ready-epoch.txt` con el epoch Unix correspondiente al momento en que se considera listo el restore.

- {% include step_label.html %} Calcula el fingerprint posterior para verificar count, checksum y último write_id recuperado.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=SELECT COUNT(*) AS total,SUM(write_id) AS checksum,MIN(write_id) AS min_write_id,MAX(write_id) AS max_write_id FROM `lab13-recovery`.production.transactions' \
    | jq '.results[0]' \
    | tee backup/fingerprint-post-restore.json
  ```

**Salida esperada:** Debe guardarse `total=100000`, `min_write_id=1`, `max_write_id=100000` y checksum comparable con el restore point.


### Tarea 7.2. Calcular RPO lógico

- {% include step_label.html %} Ejecuta las 1,000 escrituras posteriores y guarda el último write_id confirmado para calcular el RPO.

  ```bash
  LAST_ACK=$(jq -r '.last_write_id' backup/last-ack-before-incident.json)
  LAST_RESTORED=$(jq -r '.max_write_id' backup/fingerprint-post-restore.json)
  LOST_ACKNOWLEDGED=$((LAST_ACK - LAST_RESTORED))

  {
    echo "last_acknowledged=${LAST_ACK}"
    echo "last_restored=${LAST_RESTORED}"
    echo "lost_acknowledged=${LOST_ACKNOWLEDGED}"
  } | tee backup/rpo-count.txt
  ```

**Salida esperada:** Debe registrar last_acknowledged=101000, last_restored=100000 y lost_acknowledged=1000 en backup/rpo-count.txt.

### Tarea 7.3. Calcular RPO temporal y RTO

- {% include step_label.html %} Obtén el instante de la última escritura confirmada y el ack_epoch del último documento restaurado para calcular el RPO temporal.

  ```bash
  LAST_ACK_EPOCH=$(jq -r '.finished_epoch' backup/last-ack-before-incident.json)

  LAST_RESTORED_EPOCH=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -i \
      -n "$CB_NAMESPACE" \
      cb-lab13-client \
      -- \
      python - << 'PYEOF'
  import os
  from datetime import timedelta
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USER"],
              os.environ["CB_PASS"]
          )
      )
  )

  cluster.wait_until_ready(timedelta(seconds=30))

  doc = (
      cluster.bucket("lab13-recovery")
      .scope("production")
      .collection("transactions")
      .get("recovery::000100000")
      .content_as[dict]
  )

  print(doc["ack_epoch"])
  cluster.close()
  PYEOF
  )
  ```

**Salida esperada:** Deben cargarse en LAST_ACK_EPOCH y LAST_RESTORED_EPOCH timestamps válidos asociados al último write confirmado y al último documento restaurado.

- {% include step_label.html %} Calcula el RPO temporal usando ambos timestamps y conserva el resultado en la variable RPO_SECONDS.

  ```bash
  RPO_SECONDS=$(
    python - << PYEOF
  last_ack = float("${LAST_ACK_EPOCH}")
  last_restored = float("${LAST_RESTORED_EPOCH}")
  print(round(max(last_ack - last_restored, 0), 2))
  PYEOF
  )
  ```

**Salida esperada:** RPO_SECONDS debe contener una cantidad válida de segundos mayor o igual que cero.

- {% include step_label.html %} Calcula el RTO desde la declaración del incidente hasta la recuperación funcional registrada después del restore.

  ```bash
  INCIDENT_EPOCH=$(cat backup/incident-declared-epoch.txt)
  RESTORE_READY_EPOCH=$(cat backup/restore-ready-epoch.txt)

  RTO_SECONDS=$(
    python - << PYEOF
  incident = float("${INCIDENT_EPOCH}")
  ready = float("${RESTORE_READY_EPOCH}")
  print(round(max(ready - incident, 0), 2))
  PYEOF
  )
  ```

**Salida esperada:** RTO_SECONDS debe contener el tiempo total de recuperación funcional expresado en segundos.

- {% include step_label.html %} Guarda las métricas de RPO temporal, RTO y pérdida lógica para conservar evidencia consolidada de la recuperación.

  ```bash
  {
    echo "rpo_seconds=${RPO_SECONDS}"
    echo "rto_seconds=${RTO_SECONDS}"
    echo "lost_acknowledged=${LOST_ACKNOWLEDGED}"
  } | tee backup/recovery-metrics.txt
  ```

**Salida esperada:** Debe crearse backup/recovery-metrics.txt con valores válidos para rpo_seconds, rto_seconds y lost_acknowledged=1000.

### Tarea 7.4. Verificar integridad exacta del restore point

- {% include step_label.html %} Captura count, checksum y write_id del restore point inmediatamente antes de solicitar el backup.

  ```bash
  BACKUP_COUNT=$(jq -r '.total' backup/fingerprint-at-backup.json)
  RESTORED_COUNT=$(jq -r '.total' backup/fingerprint-post-restore.json)
  BACKUP_SUM=$(jq -r '.checksum' backup/fingerprint-at-backup.json)
  RESTORED_SUM=$(jq -r '.checksum' backup/fingerprint-post-restore.json)

  if [[ "$BACKUP_COUNT" == "$RESTORED_COUNT" && "$BACKUP_SUM" == "$RESTORED_SUM" ]]; then
    echo "INTEGRITY=PASS" | tee backup/integrity-result.txt
  else
    echo "INTEGRITY=FAIL" | tee backup/integrity-result.txt
  fi
  ```

**Salida esperada:** Debe guardarse el fingerprint del restore point con `total=100000`, checksum y límites de `write_id` antes del backup.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🔄 Tarea 8. Ejecutar rolling upgrade declarativo — 6 min

### Tarea 8.1. Capturar versión inicial y PDB
- {% include step_label.html %} Guarda Pods, UID e imagen antes del upgrade para disponer de evidencia de la versión inicial.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" \
    -o custom-columns='POD:.metadata.name,UID:.metadata.uid,IMAGE:.spec.containers[0].image' \
    | grep cb-cs400 \
    | tee results/upgrade-pods-before.txt
  ```

**Salida esperada:** Debe guardarse `upgrade-pods-before.txt` mostrando los cuatro Couchbase Pods con imagen `couchbase/server:enterprise-7.6.2`.

- {% include step_label.html %} Registra los PodDisruptionBudgets antes del mantenimiento para documentar las protecciones de disponibilidad.

  ```bash
  kubectl get pdb -n "$CB_NAMESPACE" \
    | tee results/pdb-before-upgrade.txt
  ```

**Salida esperada:** Debe crearse `pdb-before-upgrade.txt` con los PodDisruptionBudgets vigentes antes del rolling upgrade.


### Tarea 8.2. Iniciar upgrade controlado a 7.6.8
- {% include step_label.html %} Inicia el RollingUpgrade a 7.6.8 y conserva un Pod 7.6.2 para observar Mixed Mode antes del cierre.

  ```bash
  kubectl patch couchbasecluster "$CB_CLUSTER" -n "$CB_NAMESPACE" --type=merge -p '{
    "spec": {
      "image": "couchbase/server:enterprise-7.6.8",
      "upgrade": {
        "upgradeProcess": "SwapRebalance",
        "upgradeStrategy": "RollingUpgrade",
        "rollingUpgrade": {"maxUpgradable": 1},
        "previousVersionPodCount": 1
      }
    }
  }'
  ```

**Salida esperada:** Kubernetes debe confirmar el patch del CouchbaseCluster e iniciar el RollingUpgrade hacia `enterprise-7.6.8` conservando un Pod anterior.


### Tarea 8.3. Observar Mixed Mode
- {% include step_label.html %} Sondea las imágenes hasta observar un Pod 7.6.2 y tres Pods 7.6.8 durante Mixed Mode.

  ```bash
  for i in $(seq 1 120); do
    OLD=$(kubectl get pods -n "$CB_NAMESPACE" -o json | jq '[.items[]|select(.metadata.name|startswith("cb-cs400-"))|select(.spec.containers[0].image|contains("7.6.2"))]|length')
    NEW=$(kubectl get pods -n "$CB_NAMESPACE" -o json | jq '[.items[]|select(.metadata.name|startswith("cb-cs400-"))|select(.spec.containers[0].image|contains("7.6.8"))]|length')
    echo "$(date +%H:%M:%S) old=${OLD} new=${NEW}"
    [[ "$OLD" -eq 1 && "$NEW" -eq 3 ]] && break
    sleep 5
  done
  ```

**Salida esperada:** Los reintentos deben alcanzar `old=1 new=3`, demostrando un estado Mixed Mode controlado.


### Tarea 8.4. Capturar evidencia y completar upgrade
- {% include step_label.html %} Captura Pods, UID e imágenes mientras el clúster permanece intencionalmente en Mixed Mode.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" \
    -o custom-columns='POD:.metadata.name,UID:.metadata.uid,IMAGE:.spec.containers[0].image' \
    | grep cb-cs400 \
    | tee results/upgrade-mixed-mode.txt
  ```

**Salida esperada:** Debe guardarse `upgrade-mixed-mode.txt` mostrando un Pod 7.6.2 y tres Pods 7.6.8.

- {% include step_label.html %} Guarda las condiciones del CouchbaseCluster durante Mixed Mode para correlacionarlas con el estado de Pods.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" -n "$CB_NAMESPACE" -o json \
    | jq '.status.conditions' \
    | tee results/upgrade-conditions-mixed.json
  ```

**Salida esperada:** Debe guardarse `upgrade-conditions-mixed.json` con las condiciones actuales del CouchbaseCluster durante Mixed Mode.

- {% include step_label.html %} Retira la retención del Pod anterior para permitir que Operator ejecute el último ciclo del upgrade.

  ```bash
  kubectl patch couchbasecluster "$CB_CLUSTER" -n "$CB_NAMESPACE" --type=json -p='[
    {"op":"remove","path":"/spec/upgrade/previousVersionPodCount"}
  ]'
  ```

**Salida esperada:** Kubernetes debe confirmar el patch que elimina `previousVersionPodCount`, permitiendo continuar el último reemplazo.

- {% include step_label.html %} Espera que el CouchbaseCluster alcance Available antes de crear bucket, scope, colección o cargas de prueba.

  ```bash
  kubectl wait -n "$CB_NAMESPACE" --for=condition=Available couchbasecluster/"$CB_CLUSTER" --timeout=20m
  ```

**Salida esperada:** La espera debe finalizar con `condition met`, confirmando que `cb-cs400` alcanzó la condición `Available`.


### Tarea 8.5. Verificar versión final
- {% include step_label.html %} Guarda la topología final y confirma que todos los Couchbase Pods utilizan la imagen 7.6.8.

  ```bash
  kubectl get pods -n "$CB_NAMESPACE" \
    -o custom-columns='POD:.metadata.name,UID:.metadata.uid,IMAGE:.spec.containers[0].image' \
    | grep cb-cs400 \
    | tee results/upgrade-pods-after.txt
  ```

**Salida esperada:** Debe guardarse `upgrade-pods-after.txt` mostrando los cuatro Couchbase Pods con imagen `enterprise-7.6.8`.

- {% include step_label.html %} Consulta Couchbase REST para verificar versión, salud y membresía de todos los nodos después del upgrade.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" http://localhost:8091/pools/default \
    | jq '[.nodes[]|{hostname,status,clusterMembership,version}]' \
    | tee results/upgrade-couchbase-versions.json
  ```

**Salida esperada:** El JSON debe mostrar todos los miembros `healthy`, `active` y con versión Couchbase 7.6.8.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## ↩️ Tarea 9. Preparar y validar rollback declarativo — 3 min

### Tarea 9.1. Crear patch de rollback
- {% include step_label.html %} Crea un patch de referencia que devuelve `spec.image` a 7.6.2 para documentar el mecanismo de rollback.

  ```bash
  cat > manifests/rollback-patch.json << 'EOF'
  {
    "spec": {
      "image": "couchbase/server:enterprise-7.6.2",
      "upgrade": {
        "upgradeProcess": "SwapRebalance",
        "upgradeStrategy": "RollingUpgrade",
        "rollingUpgrade": {
          "maxUpgradable": 1
        }
      }
    }
  }
  EOF
  ```

**Salida esperada:** Debe crearse `manifests/rollback-patch.json` con `spec.image` apuntando a `enterprise-7.6.2` y la estrategia de upgrade declarativa.


### Tarea 9.2. Validar con server-side dry-run
- {% include step_label.html %} Valida la estructura del patch con server-side dry-run sin ejecutar un downgrade del clúster ya actualizado.

  ```bash
  kubectl patch couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    --type=merge \
    --patch-file manifests/rollback-patch.json \
    --dry-run=server \
    -o yaml \
    > results/rollback-dry-run.yaml

  grep -A3 'image:' results/rollback-dry-run.yaml | head
  ```

**Salida esperada:** El dry-run debe aceptar la estructura y `rollback-dry-run.yaml` debe mostrar la imagen 7.6.2; esto no confirma que un downgrade cerrado sea soportado.


### Tarea 9.3. Documentar condición de activación
- {% include step_label.html %} Documenta cuándo puede usarse rollback y diferencia esa ventana de un downgrade tras completar el upgrade.

  ```bash
  cat > reports/rollback-procedure.md << 'EOF'
  # Procedimiento de rollback de versión

  ## Condición de activación
  Utilizar rollback sólo si:
  - el upgrade todavía está dentro de una ventana soportada;
  - la documentación de compatibilidad permite volver a la versión anterior;
  - existe un backup validado;
  - existe una falla que justifique detener o revertir.

  ## Acción declarativa
  Aplicar el patch que restaura spec.image a la versión anterior.

  ## Evidencia requerida
  - Pods progresan hacia la imagen anterior.
  - CouchbaseCluster retorna a Available.
  - Todos los miembros quedan healthy/active.
  - rebalanceProgress vuelve a none.
  - el healthcheck de datos es exitoso.

  ## Advertencia
  Un downgrade después de cerrar completamente un upgrade no debe confundirse con rollback durante Mixed Mode. Revisar siempre el path oficial para las versiones específicas.
  EOF
  ```

**Salida esperada:** Debe crearse `reports/rollback-procedure.md` con condición de activación, acción declarativa, evidencia requerida y advertencia sobre downgrade.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## 📘 Tarea 10. Generar runbook y validación final — 3 min

### Tarea 10.1. Generar runbook con resultados medidos
- {% include step_label.html %} Calcula RPO temporal y RTO usando timestamps reales del último ACK, restore point e incidente.

  ```bash
  RPO_SECONDS=$(grep '^rpo_seconds=' backup/recovery-metrics.txt | cut -d= -f2)
  RTO_SECONDS=$(grep '^rto_seconds=' backup/recovery-metrics.txt | cut -d= -f2)
  LOST=$(grep '^lost_acknowledged=' backup/recovery-metrics.txt | cut -d= -f2)
  ```

**Salida esperada:** Debe crearse `backup/recovery-metrics.txt` con valores numéricos para `rpo_seconds`, `rto_seconds` y `lost_acknowledged=1000`.

- {% include step_label.html %} Captura métricas de memoria y background fetch antes de reducir la cuota para disponer de una línea base.

  ```bash
  cat > reports/runbook-lab13.md << EOF
  # Runbook operativo — Lab 13

  **Cluster:** ${CB_CLUSTER}
  **Baseline:** Couchbase Server Enterprise 7.6.2
  **Versión final:** Couchbase Server Enterprise 7.6.8
  **Fecha:** $(date -Iseconds)

  ## Metodología
  Observar → Delimitar → Formular hipótesis → Probar → Corregir → Verificar.

  ## Incident 001 — Presión de memoria
  Evidencia:
  - incidents/memory-before.json
  - incidents/memory-during.json
  - incidents/memory-client-load.json
  - incidents/memory-after.json

  Remediación: restaurar memoryQuota declarativa del CouchbaseBucket.

  ## Incident 002 — Índice deferred
  Evidencia:
  - incidents/index-deferred-state.json
  - incidents/index-plan-before.json
  - incidents/index-plan-after.json

  Remediación: BUILD INDEX ON transactions(idx_transactions_region).

  ## Backup y restore
  Backup Resource: ${BACKUP_NAME}
  Restore Resource: ${RESTORE_NAME}
  Protected data: ${CB_BUCKET}.${CB_SCOPE}.${CB_COLLECTION}

  ## Recovery results
  - RPO experimental: ${RPO_SECONDS} segundos
  - RTO experimental: ${RTO_SECONDS} segundos
  - Writes confirmados no presentes en restore point: ${LOST}
  - Integrity: $(cat backup/integrity-result.txt)

  ## Objetivos del caso
  - RPO objetivo: <= ${RPO_OBJECTIVE_SECONDS}s
  - RTO objetivo: <= ${RTO_OBJECTIVE_SECONDS}s

  ## Rolling upgrade
  spec.image: 7.6.2 → 7.6.8
  Process: SwapRebalance + RollingUpgrade
  maxUpgradable: 1

  ## Rollback
  Ver reports/rollback-procedure.md y results/rollback-dry-run.yaml.

  ## Diagnóstico y escalamiento
  Recopilar CouchbaseCluster YAML, Pods/PVC, events, Operator logs, cbcollect_info y cbopinfo/cao collect-logs cuando esté disponible.
  EOF
  ```

**Salida esperada:** Debe guardarse `incidents/memory-before.json` con resident ratio, background fetches, tmp OOM, cola y memoria usada antes del cambio de cuota.


### Tarea 10.2. Crear validación integral

- {% include step_label.html %} Sondea `system:indexes` hasta confirmar que el índice crítico alcanzó el estado online.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab13/validate.sh
  ```

**Salida esperada:** El script ha sido creado para ralizar la validación final.

- {% include step_label.html %} Habilita y ejecuta el validador final, guardando los resultados como evidencia del laboratorio.

  ```bash
  chmod +x scripts/validate.sh
  ./scripts/validate.sh | tee reports/validation-final.txt
  ```

**Salida esperada:** La ejecución debe finalizar con `RESULTADO: X PASS / X FAIL` y guardar `reports/validation-final.txt`.


{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional
- {% include step_label.html %} Elimina el recurso de restore cuando ya no se necesite conservar su historial de ejecución.

  ```bash
  kubectl delete couchbasebackuprestore "$RESTORE_NAME" -n "$CB_NAMESPACE" --ignore-not-found
  ```

**Salida esperada:** Kubernetes debe eliminar `lab13-restore` o indicar que ya no existe, sin producir un error fatal.

> **IMPORTANTE:** No elimines `CouchbaseBackup` ni su PVC si deseas conservar el restore point. Eliminar el PVC destruye los datos del backup almacenados por este laboratorio.
{: .lab-note .important .compact}

- {% include step_label.html %} Elimina de forma idempotente el índice del incidente y retira el Pod cliente si conservarás EKS.

  ```bash
  curl -fsS -u "$CB_USER:$CB_PASS" -X POST http://localhost:8093/query/service \
    --data-urlencode 'query_context=default:`lab13-recovery`.production' \
    --data-urlencode 'statement=DROP INDEX IF EXISTS transactions.idx_transactions_region' \
    | jq '{status, errors}'
  ```
  ```bash
  kubectl delete pod cb-lab13-client -n "$CB_NAMESPACE" --ignore-not-found
  ```

**Salida esperada:** Query Service debe devolver `status: "success"` o indicar que el índice ya no existe; Kubernetes debe eliminar el Pod cliente sin error fatal.

---

## ☁️ Eliminación de Amazon EKS
- {% include step_label.html %} Detén los túneles previamente y elimina el clúster EKS mediante el mismo script de ciclo de vida.

  ```bash
  cd /c/LABS/couchbase-nosql/lab13
  source lab.env
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe completar la eliminación del clúster EKS y sus recursos administrados sin errores pendientes.

- {% include step_label.html %} Confirma que AWS ya no encuentra el clúster después de finalizar la eliminación de infraestructura.

  ```bash
  aws eks describe-cluster --name "$EKS_CLUSTER" --region "$AWS_REGION"
  ```

**Salida esperada:** AWS debe responder `ResourceNotFoundException`, confirmando que el clúster ya no existe en `us-west-2`.
