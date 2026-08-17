---
layout: lab
title: "Práctica 11: Construcción de un dashboard operativo y alertas"
permalink: /lab11/lab11/
images_base: /labs/lab11/img
duration: "72 minutos"
objective:
  - Validar la arquitectura de Couchbase Operator 2.92.0 y Server 7.6.2 en Amazon EKS (MDS con discos gp3) integrando un ServiceMonitor de Prometheus para capturar métricas, fijar una línea base bajo carga, estructurar un dashboard en Grafana y activar ocho reglas en una PrometheusRule diseñadas para evitar falsos positivos (separando scrape health o resident ratio de background fetches o backlog XDCR), comprobando el pipeline hacia Alertmanager mediante una alerta sintética correlacionada con los eventos del sistema.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Couchbase Server, MDS, Query, Index, Search, Eventing, Analytics, XDCR, Kubernetes y Amazon EKS.
  - Tener una cuenta AWS con permisos para EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender que los nombres y familias de métricas dependen de la versión exacta y de los servicios habilitados; la práctica valida las métricas antes de usarlas.
introduction:
  - En esta práctica implementarás observabilidad operativa de Couchbase Enterprise 7.6.2 sobre Amazon EKS utilizando Prometheus, Grafana y Alertmanager. El enfoque no será afirmar que se construyen los tres pilares de observabilidad, ya que no se incorpora tracing distribuido; en su lugar trabajarás con Golden Signals, métricas, eventos y alerting. Couchbase Server expone métricas Prometheus nativamente y el Operator también publica sus propias métricas. Prometheus descubrirá los endpoints mediante ServiceMonitor, Grafana visualizará la información y Alertmanager administrará el routing de notificaciones. Antes de crear paneles o reglas, construirás un catálogo real de métricas para evitar PromQL basado en nombres supuestos.
slug: lab11
lab_number: 11
final_result: >
  Al finalizar la práctica habrás construido un sistema de observabilidad Kubernetes-native para Couchbase sobre Amazon EKS, con scraping dinámico mediante ServiceMonitor, catálogo de métricas verificadas, workload y baseline, dashboard Grafana de cinco filas, ocho reglas PrometheusRule, Alertmanager con webhook receiver, correlación con eventos Couchbase/Operator y una validación end-to-end reproducible.
notes:
  - Los 72 minutos corresponden al trabajo funcional de observabilidad. EKS, Couchbase y kube-prometheus-stack quedan fuera del cronómetro; el workload y el baseline sí forman parte del flujo funcional.
  - Se utilizan Couchbase Kubernetes Operator 2.92.0 y Couchbase Server Enterprise 7.6.2.
  - El exporter Prometheus sidecar de Couchbase está deprecado; la práctica utiliza el endpoint nativo de Couchbase Server.
  - La práctica no denomina a Prometheus `up` como salud del nodo Couchbase; `up` representa únicamente salud del target de scraping.
  - ep_bg_fetched/background fetches no se interpreta como logical key miss ni como cache miss ratio.
  - La práctica no denomina p99 a n1ql_request_time/n1ql_requests; utiliza contadores documentados de slow queries y métricas verificadas en runtime.
  - Los cambios pendientes de XDCR no se convierten directamente a segundos de lag. Se presentan como backlog, y cualquier drain-time es una estimación.
  - La fila de eventos no es un sistema de logs centralizado. Para centralización completa podrían incorporarse Loki, OpenSearch u otra plataforma fuera del alcance.
  - El dashboard se genera de forma reproducible y no depende de crear manualmente paneles distintos en cada ejecución.
  - El EKS utiliza cinco workers `m6i.xlarge` el `CouchbaseCluster` crea cinco Pods y `antiAffinity true` exige capacidad para ubicarlos en hosts distintos.
references:
  - text: "Configure Prometheus Metrics Collection with Couchbase Operator"
    url: "https://docs.couchbase.com/operator/current/howto-prometheus.html"
  - text: "Couchbase Operator Prometheus Tutorial"
    url: "https://docs.couchbase.com/operator/current/tutorial-prometheus.html"
  - text: "Couchbase Operator Prometheus Metrics Reference"
    url: "https://docs.couchbase.com/operator/current/reference-prometheus-metrics.html"
  - text: "Configure Prometheus to Collect Couchbase Metrics"
    url: "https://docs.couchbase.com/server/current/manage/monitor/set-up-prometheus-for-monitoring.html"
  - text: "Query Service Metrics"
    url: "https://docs.couchbase.com/server/current/metrics-reference/query-service-metrics.html"
  - text: "Couchbase Server Roles — External Stats Reader"
    url: "https://docs.couchbase.com/server/current/learn/security/roles.html"
  - text: "Scopes and Collections REST API"
    url: "https://docs.couchbase.com/server/7.6/rest-api/scopes-and-collections-api.html"
  - text: "Couchbase System Events REST API"
    url: "https://docs.couchbase.com/server/current/rest-api/rest-get-system-events.html"
  - text: "Prometheus Alerting Rules"
    url: "https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/"
  - text: "Alertmanager"
    url: "https://prometheus.io/docs/alerting/latest/alertmanager/"
prev: /lab10/lab10/
next: /lab12/lab12/
---

---

## 📁 Preparación del directorio

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona `C:\LABS\couchbase-nosql` y crea una terminal integrada **Git Bash**.

- {% include step_label.html %} Crea los directorios que almacenarán manifiestos, scripts, métricas, dashboard, alertas, resultados y reportes.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab11/{scripts,manifests,metrics,grafana,alerts,results,reports}
  cd /c/LABS/couchbase-nosql/lab11

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:**

  ```text
  /c/LABS/couchbase-nosql/lab11
  ./alerts
  ./grafana
  ./manifests
  ./metrics
  ./reports
  ./results
  ./scripts
  ```

---

## ☁️ Preparación del entorno

## Crear variables

- {% include step_label.html %} Crea `lab.env` con las variables compartidas para que todos los manifiestos y scripts utilicen la misma región, nombres y credenciales.

  ```bash
  cat > lab.env << 'EOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab11"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"

  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_OPERATOR_VERSION="2.92.0"

  export MON_NAMESPACE="monitoring"
  export MON_RELEASE="monitoring"

  export CB_BUCKET="lab11-observability"
  export CB_SCOPE="workload"
  export CB_COLLECTION="items"

  export GRAFANA_USER="admin"
  export GRAFANA_PASS="Password123!"
  EOF

  source lab.env
  ```
  ```bash
  printf 'REGION=%s\nEKS=%s\nOPERATOR=%s\n' \
    "$AWS_REGION" \
    "$EKS_CLUSTER" \
    "$CB_OPERATOR_VERSION"
  ```

**Salida esperada:** Después de cargar `lab.env`, la terminal debe confirmar la región, el nombre de EKS y la versión real del Operator que utilizarán todos los pasos posteriores.

```text
REGION=us-west-2
EKS=cb-cs400-lab11
OPERATOR=2.92.0
```

## Crear EKS

- {% include step_label.html %} Genera el script de ciclo de vida EKS con cinco workers, tres Availability Zones y los add-ons necesarios para red, métricas y EBS CSI.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab11/eks-cluster.sh
  ```

**Salida esperada:** Debe quedar creado `scripts/eks-cluster.sh` con las acciones `create`, `status` y `delete`, cinco workers `m6i.xlarge`, tres Availability Zones y los add-ons requeridos por la práctica.

- {% include step_label.html %} Habilita el script de EKS y ejecuta la creación del clúster para disponer de capacidad suficiente antes de desplegar los cinco Pods Couchbase.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe imprimir errores. Después, `eksctl` debe crear o reutilizar `cb-cs400-lab11`, actualizar el kubeconfig y `kubectl wait` debe confirmar que los cinco workers alcanzaron `Ready`.

## StorageClass y Operator

- {% include step_label.html %} Define la StorageClass `gp3-couchbase` con EBS CSI y `WaitForFirstConsumer` para enlazar cada volumen con la zona del Pod consumidor.

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

**Salida esperada:** Debe quedar definido `gp3-couchbase` con `ebs.csi.aws.com`, `type: gp3`, `WaitForFirstConsumer` y expansión habilitada; todavía no se crea ningún volumen en este paso.
- {% include step_label.html %} Aplica la StorageClass gp3 y confirma que el provisioner dinámico queda disponible antes de crear PersistentVolumeClaims de Couchbase.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

**Salida esperada:** Kubernetes debe responder `storageclass.storage.k8s.io/gp3-couchbase created` o `configured`; esto confirma que los PVC posteriores podrán solicitar volúmenes gp3 mediante EBS CSI.
- {% include step_label.html %} Registra y actualiza el repositorio Helm de Couchbase para resolver el chart oficial del Operator utilizado por el laboratorio.

  ```bash
  helm repo add couchbase \
    https://couchbase-partners.github.io/helm-charts/

  helm repo update
  ```

**Salida esperada:** Helm debe registrar el repositorio `couchbase` o indicar que ya existe con la misma configuración, y `helm repo update` debe completar la actualización del índice sin errores.
- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 y Admission Controller sin crear automáticamente un CouchbaseCluster.

  ```bash
  helm upgrade --install cb-operator \
    couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

**Salida esperada:** Helm debe dejar la release `cb-operator` en estado `deployed`; se instalan Operator, Admission Controller y CRDs, pero no un `CouchbaseCluster` porque `install.couchbaseCluster=false`.
- {% include step_label.html %} Espera que los Deployments del componente recién instalado alcancen `Available` antes de crear recursos que dependan de ellos.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

**Salida esperada:** `kubectl wait` debe responder `condition met` para los Deployments del namespace `couchbase`, indicando que Operator y Admission Controller ya pueden procesar Custom Resources.

- {% include step_label.html %} Descubre el Deployment principal del Operator y conserva su nombre para exponer posteriormente el puerto de métricas 8383 sin depender del nombre generado por Helm.

  ```bash
  OPERATOR_DEPLOYMENT=$(
    kubectl get deployment \
      -n "$CB_NAMESPACE" \
      -o name \
    | grep 'operator' \
    | grep -v 'admission' \
    | head -n1 \
    | cut -d/ -f2 \
    | tr -d '\r'
  )

  echo "$OPERATOR_DEPLOYMENT" \
    | tee results/operator-deployment.txt
  ```

**Salida esperada:** `results/operator-deployment.txt` debe contener el Deployment principal del Operator y no el Admission Controller.

## CouchbaseCluster MDS

- {% include step_label.html %} Despliega cinco Pods para garantizar presencia de Data, Query, Index, Search, Eventing y Analytics sin concentrar todos los servicios en un único proceso.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Debe crearse o actualizarse `secret/cb-admin`; el contenido no se imprime, pero el Secret queda disponible para que Operator inicialice las credenciales administrativas.

- {% include step_label.html %} Define el CouchbaseCluster MDS de cinco Pods con persistencia gp3 y todos los servicios requeridos por la práctica de observabilidad.

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
      searchServiceMemoryQuota: 1Gi
      analyticsServiceMemoryQuota: 1Gi
      eventingServiceMemoryQuota: 512Mi

      indexer:
        storageMode: plasma

    networking:
      exposeAdminConsole: true
      adminConsoleServices:
        - query

    buckets:
      managed: true

    servers:
      - name: data-query
        size: 2
        services:
          - data
          - query
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: data-volume

      - name: index
        size: 1
        services:
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

      - name: search
        size: 1
        services:
          - search
        resources:
          requests:
            cpu: "500m"
            memory: "2Gi"
          limits:
            cpu: "1"
            memory: "3Gi"
        volumeMounts:
          default: search-volume

      - name: analytics-eventing
        size: 1
        services:
          - analytics
          - eventing
        resources:
          requests:
            cpu: "1000m"
            memory: "3Gi"
          limits:
            cpu: "2"
            memory: "4Gi"
        volumeMounts:
          default: analytics-volume

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

      - metadata:
          name: search-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 15Gi

      - metadata:
          name: analytics-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 20Gi
  EOF
  ```

**Salida esperada:** El manifiesto debe definir cinco Pods Couchbase: dos `data-query`, uno `index`, uno `search` y uno `analytics-eventing`, con `antiAffinity: true`, cuotas explícitas y `storageMode: plasma`.
- {% include step_label.html %} Aplica el CouchbaseCluster y entrega a Operator el desired state completo que debe reconciliar sobre Amazon EKS.

  ```bash
  kubectl apply --server-side \
    -f manifests/couchbase-cluster.yaml
  ```

**Salida esperada:** Kubernetes debe responder `couchbasecluster.couchbase.com/cb-cs400 serverside-applied`. Los warnings de `indexer.storageMode` o cuota Data por defecto no deben aparecer porque ambos valores ya están declarados.
- {% include step_label.html %} Espera que el CouchbaseCluster alcance condición `Available` antes de crear buckets, usuarios de métricas o integraciones de monitoreo.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    couchbasecluster/"$CB_CLUSTER" \
    --timeout=20m
  ```

**Salida esperada:** Debe mostrarse `couchbasecluster.couchbase.com/cb-cs400 condition met`, confirmando que Operator completó el bootstrap y el clúster está disponible.

## Crear bucket de observabilidad

- {% include step_label.html %} Verifica antes de crear el bucket que la cuota declarada para Data Service sea suficiente para `memoryQuota: 512Mi`, evitando que Admission Controller rechace el recurso.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.spec.cluster.dataServiceMemoryQuota}{"\n"}'
  ```

**Salida esperada:**

```text
1Gi
```

El valor confirma que `512Mi` por bucket cabe dentro de la cuota de Data Service por Pod y evita el error `bucket memory allocation exceeds data service quota`.

- {% include step_label.html %} Define el bucket persistente utilizado por el workload, con una réplica y backend Couchstore para generar métricas de Data e Index.

  ```bash
  cat > manifests/observability-bucket.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseBucket
  metadata:
    name: lab11-observability
    namespace: couchbase
  spec:
    memoryQuota: 512Mi
    replicas: 1
    storageBackend: couchstore
    evictionPolicy: valueOnly
  EOF
  ```

**Salida esperada:** Debe quedar preparado `observability-bucket.yaml` con `memoryQuota: 512Mi`, una réplica, backend Couchstore y política `valueOnly`.
- {% include step_label.html %} Aplica el CouchbaseBucket para que Operator cree y mantenga declarativamente el bucket de observabilidad.

  ```bash
  kubectl apply -f manifests/observability-bucket.yaml
  ```

**Salida esperada:** Kubernetes debe responder `couchbasebucket.couchbase.com/lab11-observability created` o `configured`. No debe aparecer el rechazo de Admission Controller por cuota Data.

## Instalar kube-prometheus-stack

- {% include step_label.html %} Instala Prometheus Operator, Prometheus, Alertmanager y Grafana en el namespace `monitoring`. La versión del chart se resuelve y registra para que la ejecución quede auditable.

  ```bash
  helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts

  helm repo update
  ```

**Salida esperada:** Helm debe registrar `prometheus-community` o indicar que ya existe, y la actualización del repositorio debe terminar correctamente para poder resolver el chart.
- {% include step_label.html %} Resuelve y registra la versión exacta de kube-prometheus-stack para mantener trazabilidad y reproducibilidad de la ejecución.

  ```bash
  PROM_STACK_VERSION=$(
    helm search repo \
      prometheus-community/kube-prometheus-stack \
      --versions \
      -o json \
      | jq -r '.[0].version'
  )

  echo "$PROM_STACK_VERSION" \
    | tee results/kube-prometheus-stack-version.txt
  ```

**Salida esperada:** Debe imprimirse una versión de chart no vacía, por ejemplo `XX.Y.Z`, y el mismo valor debe quedar guardado en `results/kube-prometheus-stack-version.txt`.
- {% include step_label.html %} Genera los valores Helm que permiten descubrir ServiceMonitor, PrometheusRule y AlertmanagerConfig creados explícitamente por la práctica.

  ```bash
  cat > manifests/monitoring-values.yaml << EOF
  crds:
    enabled: true
    upgradeJob:
      enabled: true
      forceConflicts: true

  grafana:
    adminUser: ${GRAFANA_USER}
    adminPassword: ${GRAFANA_PASS}

  prometheus:
    prometheusSpec:
      serviceMonitorSelector:
        matchLabels:
          release: ${MON_RELEASE}

      serviceMonitorNamespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${MON_NAMESPACE}

      ruleSelector:
        matchLabels:
          release: ${MON_RELEASE}

      ruleNamespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${MON_NAMESPACE}

  alertmanager:
    enabled: true
    alertmanagerSpec:
      alertmanagerConfigSelector:
        matchLabels:
          release: ${MON_RELEASE}

      alertmanagerConfigMatcherStrategy:
        type: None
  EOF
  ```

**Salida esperada:** `monitoring-values.yaml` debe seleccionar explícitamente `ServiceMonitor` y `PrometheusRule` con `release: monitoring` dentro del namespace `monitoring`, evitando depender de selectores implícitos del chart. Alertmanager seleccionará `AlertmanagerConfig` con la misma etiqueta.
- {% include step_label.html %} Instala kube-prometheus-stack con los selectores requeridos para integrar métricas, reglas y routing declarados posteriormente.

  ```bash
  helm upgrade --install "$MON_RELEASE" \
    prometheus-community/kube-prometheus-stack \
    --namespace "$MON_NAMESPACE" \
    --create-namespace \
    --version "$PROM_STACK_VERSION" \
    -f manifests/monitoring-values.yaml
  ```

**Salida esperada:** En una ejecución nueva Helm debe instalar la release `monitoring`; si ya existe debe actualizarla. Al finalizar debe quedar en estado `deployed` dentro de `monitoring`, con Prometheus Operator, Prometheus, Grafana y Alertmanager disponibles.
- {% include step_label.html %} Espera que los Deployments del componente recién instalado alcancen `Available` antes de crear recursos que dependan de ellos.

  ```bash
  kubectl wait \
    -n "$MON_NAMESPACE" \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=10m
  ```

**Salida esperada:** Todos los Deployments del stack deben alcanzar condición `Available`.

- {% include step_label.html %} Espera también los StatefulSets de Prometheus y Alertmanager; estos componentes no quedan cubiertos por `kubectl wait deployment --all` y sus Pods deben estar listos antes del port-forward.

  ```bash
  while read -r STS; do
    [[ -z "$STS" ]] && continue

    kubectl rollout status \
      -n "$MON_NAMESPACE" \
      "$STS" \
      --timeout=10m
  done < <(
    kubectl get statefulset \
      -n "$MON_NAMESPACE" \
      -o name
  )
  ```

**Salida esperada:** Los StatefulSets de Prometheus y Alertmanager deben completar su rollout sin exceder el timeout.

## Port-forward

- {% include step_label.html %} En terminales separadas abre Couchbase, Prometheus y Grafana mediante Services estables.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    service/cb-cs400-ui \
    8091:8091
  ```

**Salida esperada:** La terminal debe permanecer abierta mostrando `Forwarding from 127.0.0.1:8091 -> 8091`; mientras este proceso siga activo, `http://localhost:8091` debe alcanzar Couchbase.

- {% include step_label.html %} Descubre dinámicamente el Service principal de Prometheus para evitar depender del nombre exacto generado por la versión del chart.

  ```bash
  PROM_SVC=$(
    kubectl get svc -n "$MON_NAMESPACE" \
      -o name \
      | grep 'prometheus$' \
      | head -n 1
  )

  echo "PROM_SVC=$PROM_SVC"
  ```

**Salida esperada:** `PROM_SVC` debe contener un único recurso `service/...prometheus` y no quedar vacío; ese Service será el destino del port-forward 9090.
- {% include step_label.html %} Publica localmente la API de Prometheus en el puerto 9090 para validar targets, ejecutar PromQL y comprobar reglas de alerta.

  ```bash
  kubectl port-forward \
    -n "$MON_NAMESPACE" \
    "$PROM_SVC" \
    9090:9090
  ```

**Salida esperada:** La terminal debe permanecer abierta mostrando `Forwarding from 127.0.0.1:9090 -> 9090`; la API de Prometheus queda disponible en `http://localhost:9090`.

- {% include step_label.html %} Descubre dinámicamente el Service de Grafana creado por Helm antes de abrir el acceso local a la interfaz y API.

  ```bash
  GRAFANA_SVC=$(
    kubectl get svc -n "$MON_NAMESPACE" \
      -o name \
      | grep grafana \
      | head -n 1
  )

  echo "GRAFANA_SVC=$GRAFANA_SVC"
  ```

**Salida esperada:** `GRAFANA_SVC` debe contener un único Service de Grafana y no quedar vacío; ese nombre se reutiliza inmediatamente para publicar el puerto local 3000.
- {% include step_label.html %} Publica Grafana en `localhost:3000` para importar el dashboard reproducible y registrar annotations del laboratorio.

  ```bash
  kubectl port-forward \
    -n "$MON_NAMESPACE" \
    "$GRAFANA_SVC" \
    3000:80
  ```

**Salida esperada:** La terminal debe permanecer abierta mostrando `Forwarding from 127.0.0.1:3000 -> 3000` o el mapeo equivalente hacia el puerto 80 del Service; Grafana queda disponible en `http://localhost:3000`.

## Crear usuario de solo lectura para scraping

- {% include step_label.html %} Crea un usuario dedicado con rol `external_stats_reader`, limitado oficialmente a `/metrics` y `/prometheus_sd_config`.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    -X PUT \
    http://localhost:8091/settings/rbac/users/local/svc-monitoring \
    -d password='Monitor123!' \
    -d roles='external_stats_reader' \
    -d name='Prometheus Monitoring' \
    -o /dev/null \
    -w 'HTTP_STATUS=%{http_code}\n'
  ```

**Salida esperada:**

```text
HTTP_STATUS=200
```

El código `200` confirma que `svc-monitoring` quedó creado o actualizado con el rol `external_stats_reader`, suficiente para consultar `/metrics`.

- {% include step_label.html %} Espera a que el bucket declarativo sea visible por REST antes de crear el scope y la collection que utilizará el workload reproducible.

  ```bash
  BUCKET_READY=false

  for i in $(seq 1 60); do
    if curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${CB_BUCKET}" \
      >/dev/null; then
      BUCKET_READY=true
      break
    fi

    sleep 2
  done

  echo "BUCKET_READY=$BUCKET_READY"
  ```

**Salida esperada:** Debe mostrarse `BUCKET_READY=true`; no continúes con el workload si el bucket todavía no responde por REST.

- {% include step_label.html %} Crea de forma idempotente el scope `workload` mediante la API de Scopes y Collections para que el dataset no dependa de `_default`.

  ```bash
  if ! curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/scopes/" \
    | jq -e --arg S "$CB_SCOPE" '.scopes[] | select(.name == $S)' \
      >/dev/null; then
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/scopes" \
      -d "name=${CB_SCOPE}" \
      | jq '.'
  else
    echo "Scope ${CB_SCOPE} ya existe."
  fi
  ```

**Salida esperada:** La API debe devolver un `uid` al crear el scope o indicar que `workload` ya existe.

- {% include step_label.html %} Crea de forma idempotente la collection `items` y confirma la topología lógica utilizada posteriormente por el cliente Python.

  ```bash
  if ! curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/scopes/" \
    | jq -e \
        --arg S "$CB_SCOPE" \
        --arg C "$CB_COLLECTION" \
        '.scopes[] | select(.name == $S) | .collections[] | select(.name == $C)' \
      >/dev/null; then
    curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "http://localhost:8091/pools/default/buckets/${CB_BUCKET}/scopes/${CB_SCOPE}/collections" \
      -d "name=${CB_COLLECTION}" \
      | jq '.'
  else
    echo "Collection ${CB_SCOPE}.${CB_COLLECTION} ya existe."
  fi
  ```

**Salida esperada:** La API debe devolver un `uid` al crear la collection o indicar que `workload.items` ya existe.

---

## 🔎 Tarea 1. Descubrir y validar contrato de métricas — 7 min

### Tarea 1.1. Verificar endpoint nativo

- {% include step_label.html %} Consulta directamente el endpoint nativo `/metrics` para comprobar autenticación y formato Prometheus antes de integrar ServiceMonitor.

  ```bash
  curl -fsS \
    -u 'svc-monitoring:Monitor123!' \
    http://localhost:8091/metrics \
    > metrics/endpoint-check.prom

  sed -n '1,20p' \
    metrics/endpoint-check.prom
  ```

**Salida esperada:**

La respuesta debe comenzar con líneas en formato Prometheus:

```text
# HELP ...
# TYPE ...
<metric_name>{...} <value>
```

### Tarea 1.2. Construir catálogo real

- {% include step_label.html %} Guarda la exposición completa de métricas y extrae nombres únicos para construir un contrato basado en lo que realmente publica Couchbase 7.6.2.

  ```bash
  rm -f \
    metrics/raw-metrics.txt \
    metrics/metric-names.txt

  : > metrics/raw-metrics.txt

  while read -r POD; do
    POD=$(printf '%s' "$POD" | tr -d '\r')

    echo "Recolectando métricas de: $POD"

    {
      echo "# SOURCE_POD=${POD}"

      kubectl exec \
        -n "$CB_NAMESPACE" \
        "$POD" \
        -- \
        curl -fsS \
          -u 'svc-monitoring:Monitor123!' \
          http://localhost:8091/metrics

      echo
    } >> metrics/raw-metrics.txt

  done < <(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  )

  grep -v '^#' \
    metrics/raw-metrics.txt \
  | awk 'NF >= 2 {print $1}' \
  | sed 's/{.*//' \
  | sort -u \
  > metrics/metric-names.txt

  echo
  wc -l metrics/raw-metrics.txt
  wc -l metrics/metric-names.txt
  ```

**Salida esperada:** `raw-metrics.txt` debe contener una exposición Prometheus extensa y `metric-names.txt` debe contener decenas o cientos de nombres únicos, no sólo unas pocas líneas. Con Data, Query, Index, Search, Eventing y Analytics habilitados, un resultado como `3 metrics/metric-names.txt` indica extracción incorrecta y no debe considerarse válido.

> **NOTA:** No existe una cantidad fija de métricas como criterio de éxito. El número cambia con versión, servicios y objetos configurados.
{: .lab-note .info .compact}

### Tarea 1.3. Agrupar por servicio

- {% include step_label.html %} Agrupa el catálogo de nombres por prefijos de servicio para separar Data, Query, Index, Search, Eventing, Analytics y XDCR.

  ```bash
  for PREFIX in kv_ n1ql_ index_ fts_ eventing_ cbas_ xdcr_; do
    echo "=== ${PREFIX} ==="

    grep "^${PREFIX}" \
      metrics/metric-names.txt \
    | head -20 || true

    echo
  done | tee metrics/service-catalog.txt
  ```

**Salida esperada:** `metrics/service-catalog.txt` debe mostrar nombres reales bajo varias familias habilitadas, especialmente `kv_`, `n1ql_` e `index_`. Una familia puede quedar vacía si el servicio no publica series activas para ese escenario, pero las tres familias obligatorias no deben estar todas vacías.

### Tarea 1.4. Crear contrato obligatorio

- {% include step_label.html %} Crea un validador mínimo de métricas requeridas por los paneles Query e Index antes de utilizar esas series en PromQL.

  ```bash
  cat > scripts/validate_metric_contract.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  FILE="metrics/metric-names.txt"
  FAIL=0

  require_metric() {
    local metric="$1"

    if grep -qx "$metric" "$FILE"; then
      echo "✅ $metric"
    else
      echo "❌ $metric"
      FAIL=$((FAIL + 1))
    fi
  }

  require_metric "n1ql_requests"
  require_metric "n1ql_requests_500ms"
  require_metric "index_memory_used_total"
  require_metric "index_memory_quota"

  echo
  echo "Missing required metrics: $FAIL"

  [[ "$FAIL" -eq 0 ]]
  EOF
  ```

**Salida esperada:** Debe crearse `validate_metric_contract.sh` con cuatro comprobaciones iniciales: dos métricas Query y dos métricas Index disponibles antes de depender de un índice de usuario.
- {% include step_label.html %} Habilita y ejecuta el contrato de métricas para detener la práctica si faltan las series obligatorias de Query o Index.

  ```bash
  chmod +x scripts/validate_metric_contract.sh
  ./scripts/validate_metric_contract.sh \
    | tee results/metric-contract.txt
  ```

**Salida esperada:**

Las cuatro métricas obligatorias deben aparecer como `✅` y el resumen debe terminar en `Missing required metrics: 0`:

```text
✅ n1ql_requests
✅ n1ql_requests_500ms
✅ index_memory_used_total
✅ index_memory_quota

Missing required metrics: 0
```

`index_num_docs_pending` se valida después de crear `idx_lab11_value`, ya que es una métrica asociada a índices y no debe bloquear el contrato inicial.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🔗 Tarea 2. Configurar Metrics Service + ServiceMonitor — 7 min

### Tarea 2.1. Crear Secret de scraping

- {% include step_label.html %} Copia las credenciales de scraping al namespace `monitoring`, donde Prometheus Operator puede resolverlas desde el ServiceMonitor.

  ```bash
  kubectl create secret generic couchbase-metrics-auth \
    -n "$MON_NAMESPACE" \
    --from-literal=username='svc-monitoring' \
    --from-literal=password='Monitor123!' \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Debe crearse o configurarse `secret/couchbase-metrics-auth` en `monitoring`; Prometheus utilizará las claves `username` y `password` al procesar el `ServiceMonitor`.

### Tarea 2.2. Crear Service de métricas

- {% include step_label.html %} Crea un Service que selecciona todos los Pods pertenecientes al CouchbaseCluster y expone el puerto administrativo usado por `/metrics`.

  ```bash
  cat > manifests/couchbase-metrics-service.yaml << 'EOF'
  apiVersion: v1
  kind: Service
  metadata:
    name: couchbase-metrics
    namespace: couchbase
    labels:
      monitoring-target: couchbase-server
  spec:
    selector:
      app: couchbase
      couchbase_cluster: cb-cs400
      couchbase_server: "true"
    ports:
      - name: metrics
        port: 8091
        targetPort: 8091
        protocol: TCP
    sessionAffinity: ClientIP
  EOF
  ```

**Salida esperada:** El manifiesto debe seleccionar únicamente Pods de `cb-cs400`, exponer el puerto nombrado `metrics` en 8091 y conservar `sessionAffinity: ClientIP`, siguiendo el patrón recomendado para el endpoint nativo agregado.
- {% include step_label.html %} Aplica el Service de métricas para crear el objeto que será seleccionado posteriormente por ServiceMonitor.

  ```bash
  kubectl apply -f manifests/couchbase-metrics-service.yaml
  ```

**Salida esperada:** Kubernetes debe responder `service/couchbase-metrics created` o `configured`; a partir de este momento existe un Service estable que Prometheus Operator puede descubrir.

### Tarea 2.3. Verificar EndpointSlices

- {% include step_label.html %} Inspecciona los EndpointSlices del Service para confirmar que Kubernetes descubre dinámicamente las instancias Couchbase seleccionadas.

  ```bash
  kubectl get endpointslice \
    -n "$CB_NAMESPACE" \
    -l kubernetes.io/service-name=couchbase-metrics \
    -o wide
  ```

**Salida esperada:**

Debe aparecer al menos un `EndpointSlice` asociado con `couchbase-metrics`; en esta topología normalmente representa los cinco Pods Couchbase seleccionados. Las direcciones son dinámicas y deben figurar como endpoints listos, no como IPs hardcodeadas.

### Tarea 2.4. Crear ServiceMonitor

- {% include step_label.html %} Define el `ServiceMonitor` de Couchbase Server para que Prometheus Operator seleccione el Service `couchbase-metrics`, consulte `/metrics` por el puerto nombrado `metrics` y utilice Basic Auth.

  ```bash
  cat > manifests/couchbase-servicemonitor.yaml << 'EOF'
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: couchbase-server
    namespace: monitoring
    labels:
      release: monitoring
  spec:
    namespaceSelector:
      matchNames:
        - couchbase

    selector:
      matchLabels:
        monitoring-target: couchbase-server

    endpoints:
      - port: metrics
        path: /metrics
        interval: 15s
        scrapeTimeout: 10s

        basicAuth:
          username:
            name: couchbase-metrics-auth
            key: username
          password:
            name: couchbase-metrics-auth
            key: password
  EOF
  ```

**Salida esperada:** `couchbase-servicemonitor.yaml` debe quedar en namespace `monitoring`, seleccionar `monitoring-target: couchbase-server`, consultar `/metrics` cada 15 segundos y referenciar `couchbase-metrics-auth` para autenticación.

> **IMPORTANTE:** El Secret referenciado por `basicAuth` debe estar disponible para el Prometheus que procesa el ServiceMonitor. Si el stack instalado exige que el Secret resida en el mismo namespace del ServiceMonitor, este manifiesto ya cumple esa condición.
{: .lab-note .important .compact}

- {% include step_label.html %} Aplica el ServiceMonitor para incorporar el endpoint nativo de Couchbase Server a la configuración administrada por Prometheus Operator.

  ```bash
  kubectl apply -f manifests/couchbase-servicemonitor.yaml
  ```

**Salida esperada:** Kubernetes debe responder `servicemonitor.monitoring.coreos.com/couchbase-server created` o `configured`; Prometheus Operator ya dispone de la definición de scraping de Couchbase Server.

### Tarea 2.5. Exponer métricas del Couchbase Kubernetes Operator

- {% include step_label.html %} Recupera el Deployment descubierto en preparación y crea un Service estable hacia el puerto Prometheus 8383 publicado por Operator 2.92.0.

  ```bash
  OPERATOR_DEPLOYMENT=$(
    cat results/operator-deployment.txt \
    | tr -d '\r'
  )

  echo "OPERATOR_DEPLOYMENT=$OPERATOR_DEPLOYMENT"
  ```
  ```bash
  kubectl get deployment "$OPERATOR_DEPLOYMENT" \
    -n "$CB_NAMESPACE"
  ```
  ```bash
  kubectl delete service couchbase-operator-metrics \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```
  ```bash
  kubectl expose deployment "$OPERATOR_DEPLOYMENT" \
    -n "$CB_NAMESPACE" \
    --name=couchbase-operator-metrics \
    --port=8383 \
    --target-port=8383
  ```

**Salida esperada:** Debe crearse `service/couchbase-operator-metrics` a partir del selector del Deployment principal.

- {% include step_label.html %} Etiqueta el Service y asigna el nombre `metrics` a su puerto para que ServiceMonitor pueda seleccionarlo mediante el campo `port`.

  ```bash
  kubectl label service couchbase-operator-metrics \
    -n "$CB_NAMESPACE" \
    monitoring-target=couchbase-operator \
    --overwrite
  ```
  ```bash
  kubectl patch service couchbase-operator-metrics \
    -n "$CB_NAMESPACE" \
    --type=json \
    -p='[{"op":"add","path":"/spec/ports/0/name","value":"metrics"}]'
  ```

**Salida esperada:** Debe existir `service/couchbase-operator-metrics` con puerto `8383/TCP` y selector heredado del Deployment principal.

- {% include step_label.html %} Crea un segundo ServiceMonitor sin autenticación para incorporar las métricas nativas de Operator al mismo Prometheus del laboratorio.

  ```bash
  cat > manifests/couchbase-servicemonitor.yaml << 'EOF'
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: couchbase-server
    namespace: monitoring
    labels:
      release: monitoring
  spec:
    fallbackScrapeProtocol: PrometheusText0.0.4

    namespaceSelector:
      matchNames:
        - couchbase

    selector:
      matchLabels:
        monitoring-target: couchbase-server

    endpoints:
      - port: metrics
        path: /metrics
        interval: 15s
        scrapeTimeout: 10s

        basicAuth:
          username:
            name: couchbase-metrics-auth
            key: username
          password:
            name: couchbase-metrics-auth
            key: password
  EOF
  ```

**Salida esperada:** El archivo debe definir un `ServiceMonitor` que seleccione `couchbase-operator-metrics` y su puerto nombrado `metrics` en el namespace `couchbase`.

- {% include step_label.html %} Aplica el ServiceMonitor de Operator y confirma que el recurso quedó registrado antes de consultar sus series en Prometheus.

  ```bash
  kubectl apply \
    -f manifests/operator-servicemonitor.yaml
  ```

**Salida esperada:** Debe mostrarse `servicemonitor.monitoring.coreos.com/couchbase-operator created` o `configured`.

### Tarea 2.6. Validar pipeline de scraping antes del workload

- {% include step_label.html %} Verifica que el recurso Prometheus generado por Helm selecciona únicamente los `ServiceMonitor` etiquetados para esta práctica dentro del namespace `monitoring`.

  ```bash
  kubectl get prometheus \
    -n "$MON_NAMESPACE" \
    -o json \
  | jq '.items[] | {
      name: .metadata.name,
      serviceMonitorSelector:
        .spec.serviceMonitorSelector,
      serviceMonitorNamespaceSelector:
        .spec.serviceMonitorNamespaceSelector
    }'
  ```

**Salida esperada:** El selector debe contener `release: monitoring` y el selector de namespaces debe contener `kubernetes.io/metadata.name: monitoring`; esto confirma que los dos `ServiceMonitor` creados por la práctica son elegibles para Prometheus.

- {% include step_label.html %} Espera hasta que Prometheus haya incorporado los dos jobs generados por `couchbase-server` y `couchbase-operator`, evitando continuar mientras un `ServiceMonitor` exista en Kubernetes pero aún no forme parte de la configuración activa.

  ```bash
  JOBS_READY=false

  for i in $(seq 1 30); do
    PROM_CONFIG=$(
      curl -fsS \
        http://localhost:9090/api/v1/status/config \
      | jq -r '.data.yaml'
    )

    SERVER_JOB=$(
      printf '%s\n' "$PROM_CONFIG" \
      | grep -c \
        'serviceMonitor/monitoring/couchbase-server/0' \
        || true
    )

    OPERATOR_JOB=$(
      printf '%s\n' "$PROM_CONFIG" \
      | grep -c \
        'serviceMonitor/monitoring/couchbase-operator/0' \
        || true
    )

    echo \
      "Intento $i - Server job=$SERVER_JOB | Operator job=$OPERATOR_JOB"

    if [[ "$SERVER_JOB" -gt 0 && "$OPERATOR_JOB" -gt 0 ]]; then
      JOBS_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$JOBS_READY" == "true" ]]; then
    echo "PASS: Prometheus cargó ambos ServiceMonitor."
  else
    echo "FAIL: Prometheus no cargó uno o ambos ServiceMonitor."
  fi

  [[ "$JOBS_READY" == "true" ]]
  ```

**Salida esperada:** La secuencia debe terminar con `Server job=1` o mayor y `Operator job=1` o mayor, seguida de `PASS: Prometheus cargó ambos ServiceMonitor.`. Si alguno permanece en `0`, no continúes porque Grafana no podrá mostrar esas métricas.

- {% include step_label.html %} Sondea los `scrapePool` reales hasta confirmar que Couchbase Server y Couchbase Operator tienen targets activos en estado `up`.

  ```bash
  TARGETS_READY=false

  for i in $(seq 1 30); do
    TARGETS_JSON=$(
      curl -fsS \
        'http://localhost:9090/api/v1/targets?state=active'
    )

    SERVER_UP=$(
      printf '%s' "$TARGETS_JSON" \
      | jq '[
          .data.activeTargets[]
          | select(
              .scrapePool ==
              "serviceMonitor/monitoring/couchbase-server/0"
              and .health == "up"
            )
        ] | length'
    )

    OPERATOR_UP=$(
      printf '%s' "$TARGETS_JSON" \
      | jq '[
          .data.activeTargets[]
          | select(
              .scrapePool ==
              "serviceMonitor/monitoring/couchbase-operator/0"
              and .health == "up"
            )
        ] | length'
    )

    echo \
      "Intento $i - Couchbase Server UP=$SERVER_UP | Operator UP=$OPERATOR_UP"

    if [[ "$SERVER_UP" -gt 0 && "$OPERATOR_UP" -gt 0 ]]; then
      TARGETS_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$TARGETS_READY" == "true" ]]; then
    echo "PASS: ambos pipelines de métricas están activos."
  else
    echo "FAIL: uno o ambos scrape pools no alcanzaron estado UP."
  fi

  [[ "$TARGETS_READY" == "true" ]]
  ```

**Salida esperada:** Debe finalizar con al menos un target Couchbase Server `UP`, un target Operator `UP` y el mensaje `PASS: ambos pipelines de métricas están activos.`. El número de targets Server puede ser mayor que uno porque el Service descubre los Pods Couchbase seleccionados.

- {% include step_label.html %} Guarda los targets activos con su `scrapePool`, instancia, estado y último error para disponer de evidencia antes de iniciar el workload.

  ```bash
  curl -fsS \
    'http://localhost:9090/api/v1/targets?state=active' \
  | jq '[
      .data.activeTargets[]
      | select(
          .scrapePool ==
          "serviceMonitor/monitoring/couchbase-server/0"
          or .scrapePool ==
          "serviceMonitor/monitoring/couchbase-operator/0"
        )
      | {
          scrapePool,
          instance: .labels.instance,
          health: .health,
          lastError: .lastError,
          lastScrape: .lastScrape
        }
    ]' \
  | tee results/couchbase-targets.json
  ```

**Salida esperada:** Todas las entradas guardadas deben mostrar `health: "up"` y `lastError: ""`; `lastScrape` debe contener un timestamp reciente de Prometheus.

- {% include step_label.html %} Espera hasta confirmar que Prometheus ya almacena las cuatro series mínimas que utilizará el dashboard, de modo que la práctica no construya Grafana sobre un pipeline vacío.

  ```bash
  METRICS_READY=false

  for i in $(seq 1 30); do
    N1QL_COUNT=$(
      curl -fsSG \
        http://localhost:9090/api/v1/query \
        --data-urlencode 'query=n1ql_requests' \
      | jq '.data.result | length'
    )

    INDEX_USED_COUNT=$(
      curl -fsSG \
        http://localhost:9090/api/v1/query \
        --data-urlencode 'query=index_memory_used_total' \
      | jq '.data.result | length'
    )

    INDEX_QUOTA_COUNT=$(
      curl -fsSG \
        http://localhost:9090/api/v1/query \
        --data-urlencode 'query=index_memory_quota' \
      | jq '.data.result | length'
    )

    KV_MEMORY_COUNT=$(
      curl -fsSG \
        http://localhost:9090/api/v1/query \
        --data-urlencode 'query=kv_mem_used_bytes' \
      | jq '.data.result | length'
    )

    echo \
      "Intento $i - n1ql=$N1QL_COUNT | index_used=$INDEX_USED_COUNT | index_quota=$INDEX_QUOTA_COUNT | kv_memory=$KV_MEMORY_COUNT"

    if [[ "$N1QL_COUNT" -gt 0 \
       && "$INDEX_USED_COUNT" -gt 0 \
       && "$INDEX_QUOTA_COUNT" -gt 0 \
       && "$KV_MEMORY_COUNT" -gt 0 ]]; then
      METRICS_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$METRICS_READY" == "true" ]]; then
    echo "PASS: Prometheus almacena las métricas mínimas del dashboard."
  else
    echo "FAIL: faltan métricas requeridas para construir el dashboard."
  fi

  [[ "$METRICS_READY" == "true" ]]
  ```

**Salida esperada:** Los cuatro contadores deben ser mayores que `0` y el paso debe finalizar con `PASS: Prometheus almacena las métricas mínimas del dashboard.`. Sólo después de este punto se inicia el workload y se construye Grafana.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 🚦 Tarea 3. Iniciar workload y establecer baseline — 7 min

### Tarea 3.1. Crear cliente Python

- {% include step_label.html %} Define el Pod cliente Python con credenciales desde Secret y variables del keyspace que utilizará el workload reproducible.

  ```bash
  cat > manifests/load-client.yaml << 'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-lab11-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 7200"]
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
          - name: CB_BUCKET
            value: lab11-observability
          - name: CB_SCOPE
            value: workload
          - name: CB_COLLECTION
            value: items
        resources:
          requests:
            cpu: "250m"
            memory: "256Mi"
          limits:
            cpu: "1"
            memory: "1Gi"
  EOF
  ```

**Salida esperada:** `load-client.yaml` debe definir un Pod temporal con credenciales obtenidas desde `cb-admin` y las variables `CB_BUCKET`, `CB_SCOPE` y `CB_COLLECTION` apuntando al keyspace del laboratorio.
- {% include step_label.html %} Crea el Pod cliente que generará tráfico KV y SQL++ sin instalar herramientas adicionales en los Pods Couchbase.

  ```bash
  kubectl apply -f manifests/load-client.yaml
  ```

**Salida esperada:** Kubernetes debe responder `pod/cb-lab11-client created` o `configured`, iniciando un contenedor Python aislado para generar carga sin modificar los Pods Couchbase.
- {% include step_label.html %} Espera que el cliente alcance `Ready` antes de instalar el SDK o copiar scripts al contenedor.

  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Ready \
    pod/cb-lab11-client \
    --timeout=3m
  ```

**Salida esperada:** Debe aparecer `pod/cb-lab11-client condition met`, confirmando que el contenedor acepta comandos antes de instalar el SDK.
- {% include step_label.html %} Instala Couchbase Python SDK 4.x dentro del cliente temporal para ejecutar operaciones KV y SQL++ contra el clúster.

  ```bash
  kubectl exec -n "$CB_NAMESPACE" cb-lab11-client -- \
    pip install --quiet --root-user-action=ignore 'couchbase>=4.4,<5'
  ```

**Salida esperada:** `pip` debe finalizar con código 0 y sin errores de resolución o instalación; el SDK 4.x queda disponible sólo dentro del Pod temporal.

### Tarea 3.2. Crear workload continuo

- {% include step_label.html %} Crea un workload de 15 minutos que combina KV y SQL++, utiliza el scope/collection del laboratorio y emite muestras JSON cada 30 segundos para el baseline del cliente.

  ```bash
  cat > scripts/workload.py << 'PYEOF'
  import json
  import math
  import os
  import random
  import time
  from datetime import timedelta

  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.options import ClusterOptions

  username = os.environ["CB_USERNAME"]
  password = os.environ["CB_PASSWORD"]
  bucket_name = os.environ["CB_BUCKET"]
  scope_name = os.environ["CB_SCOPE"]
  collection_name = os.environ["CB_COLLECTION"]

  cluster = Cluster(
      "couchbase://cb-cs400-srv",
      ClusterOptions(
          PasswordAuthenticator(
              username,
              password
          )
      )
  )

  cluster.wait_until_ready(
      timedelta(seconds=30)
  )

  bucket = cluster.bucket(bucket_name)
  collection = (
      bucket.scope(scope_name)
      .collection(collection_name)
  )

  keyspace = (
      f"`{bucket_name}`."
      f"`{scope_name}`."
      f"`{collection_name}`"
  )

  for i in range(20000):
      collection.upsert(
          f"obs::{i:08d}",
          {
              "id": i,
              "type": "observability",
              "value": i % 1000,
              "payload": "x" * 512
          }
      )

  list(
      cluster.query(
          f"CREATE INDEX IF NOT EXISTS "
          f"idx_lab11_value ON {keyspace}(`value`)"
      )
  )

  index_ready = False

  for _ in range(60):
      rows = list(
          cluster.query(
              "SELECT RAW state "
              "FROM system:indexes "
              f'WHERE bucket_id="{bucket_name}" '
              f'AND scope_id="{scope_name}" '
              f'AND keyspace_id="{collection_name}" '
              "AND name='idx_lab11_value'"
          )
      )

      if rows and rows[0] == "online":
          index_ready = True
          break

      time.sleep(2)

  if not index_ready:
      raise RuntimeError(
          "idx_lab11_value no alcanzó estado online"
      )

  samples = []
  errors = 0
  operations = 0
  started = time.time()
  deadline = started + 900
  next_report = started + 30

  def percentile(values, p):
      if not values:
          return 0

      ordered = sorted(values)
      idx = max(
          math.ceil(p / 100 * len(ordered)) - 1,
          0
      )

      return ordered[
          min(idx, len(ordered) - 1)
      ]

  while time.time() < deadline:
      key_id = random.randrange(20000)
      key = f"obs::{key_id:08d}"
      choice = random.random()
      t0 = time.perf_counter()

      try:
          if choice < 0.70:
              collection.get(key)

          elif choice < 0.95:
              collection.upsert(
                  key,
                  {
                      "id": key_id,
                      "type": "observability",
                      "value": random.randrange(1000),
                      "payload": "x" * 512
                  }
              )

          else:
              low = random.randrange(0, 900)
              high = low + 99

              list(
                  cluster.query(
                      f"SELECT RAW COUNT(1) "
                      f"FROM {keyspace} "
                      f"WHERE `value` BETWEEN {low} AND {high}"
                  )
              )

          samples.append(
              (time.perf_counter() - t0) * 1000
          )
          operations += 1

      except Exception:
          errors += 1

      now = time.time()

      if now >= next_report:
          elapsed = max(now - started, 1)

          result = {
              "timestamp": round(now, 3),
              "elapsed_seconds": round(elapsed, 1),
              "operations": operations,
              "errors": errors,
              "ops_per_sec": round(
                  operations / elapsed,
                  2
              ),
              "p50_ms": round(
                  percentile(samples, 50),
                  2
              ),
              "p95_ms": round(
                  percentile(samples, 95),
                  2
              ),
              "p99_ms": round(
                  percentile(samples, 99),
                  2
              )
          }

          print(
              json.dumps(result),
              flush=True
          )

          next_report += 30

      time.sleep(0.002)

  cluster.close()
  PYEOF
  ```

**Salida esperada:** Debe crearse `scripts/workload.py` con mezcla 70% GET, 25% UPSERT y 5% SQL++; además incorpora una espera de hasta 120 s para que `idx_lab11_value` alcance `online` antes de ejecutar consultas.

- {% include step_label.html %} Valida la sintaxis Python del workload antes de copiarlo al Pod cliente, evitando iniciar una carga de 15 minutos con un script mal formado.

  ```bash
  python -m py_compile scripts/workload.py
  ```

**Salida esperada:** `python -m py_compile` no debe imprimir errores; esto confirma que el script puede ser interpretado correctamente por Python 3.

- {% include step_label.html %} Copia el workload al Pod cliente evitando que Git Bash convierta `/tmp/workload.py` en una ruta local de Windows.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/workload.py \
    "$CB_NAMESPACE/cb-lab11-client:/tmp/workload.py"
  ```

**Salida esperada:** `kubectl cp` debe finalizar sin errores y dejar `/tmp/workload.py` dentro del Pod cliente.

- {% include step_label.html %} Inicia el workload en segundo plano, registra el instante local de arranque y conserva las muestras periódicas dentro del Pod para consultarlas durante los siguientes pasos.

  ```bash
  date +%s \
    | tee results/workload-start-epoch.txt

  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab11-client \
    -- \
    sh -c '
      rm -f /tmp/workload.jsonl /tmp/workload-error.log
      nohup python /tmp/workload.py \
        >/tmp/workload.jsonl \
        2>/tmp/workload-error.log &
      echo $! > /tmp/workload.pid
    '
  ```

**Salida esperada:** Debe guardarse `results/workload-start-epoch.txt` y el proceso remoto debe continuar ejecutándose sin bloquear la terminal.

- {% include step_label.html %} Comprueba que el proceso remoto sigue activo y que comienzan a aparecer muestras JSONL antes de construir el dashboard.

  ```bash
  WORKLOAD_READY=false

  for i in $(seq 1 36); do
    STATUS=$(
      MSYS_NO_PATHCONV=1 kubectl exec \
        -n "$CB_NAMESPACE" \
        cb-lab11-client \
        -- \
        sh -c '
          PID=$(cat /tmp/workload.pid 2>/dev/null || true)

          if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            if [ -s /tmp/workload.jsonl ]; then
              echo "ready"
            else
              echo "starting"
            fi
          else
            echo "failed"
          fi
        ' \
      | tail -n 1 \
      | tr -d '\r'
    )

    echo "Intento $i - WORKLOAD_STATUS=$STATUS"

    if [[ "$STATUS" == "ready" ]]; then
      WORKLOAD_READY=true
      break
    fi

    if [[ "$STATUS" == "failed" ]]; then
      break
    fi

    sleep 5
  done

  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab11-client \
    -- \
    sh -c '
      PID=$(cat /tmp/workload.pid 2>/dev/null || true)

      echo "PID=$PID"

      if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "WORKLOAD_STATUS=running"
      else
        echo "WORKLOAD_STATUS=not-running"
      fi

      echo
      echo "=== Últimas muestras ==="
      tail -n 3 /tmp/workload.jsonl 2>/dev/null || true

      echo
      echo "=== Errores recientes ==="
      tail -n 20 /tmp/workload-error.log 2>/dev/null || true
    '

  if [[ "$WORKLOAD_READY" == "true" ]]; then
    echo "PASS: workload activo y generando muestras."
  else
    echo "FAIL: workload no alcanzó estado ready."
  fi
  ```

**Salida esperada:** La espera debe terminar cuando el proceso siga activo y `workload.jsonl` ya tenga al menos una muestra. La salida final debe indicar `WORKLOAD_STATUS=running`, mostrar JSON con `operations`, `errors`, `ops_per_sec`, `p50_ms`, `p95_ms` y `p99_ms`, y no presentar traceback en `Errores recientes`.

### Tarea 3.3. Capturar annotation de inicio

- {% include step_label.html %} Registra una annotation en Grafana para marcar temporalmente el inicio del baseline dentro del dashboard y poder correlacionar visualmente el periodo de carga con las métricas recopiladas por Prometheus.

  ```bash
  curl -fsS \
    -X POST \
    -H "Content-Type: application/json" \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    http://localhost:3000/api/annotations \
    -d "{
      \"time\": $(date +%s000),
      \"tags\": [\"couchbase\",\"baseline-start\"],
      \"text\": \"Inicio de workload y baseline Lab 11\"
    }" \
  | jq '.'
  ```

**Salida esperada:** Grafana debe devolver un objeto JSON que confirme la creación de la annotation, normalmente con un identificador y un mensaje de éxito. Esto demuestra que la API de Grafana está accesible, las credenciales son válidas y el marcador temporal quedó registrado para correlacionarlo posteriormente con el workload.

### Tarea 3.4. Preparar captura de baseline de cinco minutos

- {% include step_label.html %} Crea un script que exige al menos cinco minutos de workload, captura métricas de servidor en Prometheus y conserva las últimas muestras del cliente.

  ```bash
  cat > scripts/capture_baseline.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  START_EPOCH=$(
    cat "${ROOT_DIR}/results/workload-start-epoch.txt"
  )

  ELAPSED=$(( $(date +%s) - START_EPOCH ))

  if [[ "$ELAPSED" -lt 300 ]]; then
    echo "ERROR: baseline requiere al menos 300 s; transcurridos=${ELAPSED}."
    exit 1
  fi

  query_value() {
    local q="$1"

    curl -fsSG \
      http://localhost:9090/api/v1/query \
      --data-urlencode "query=${q}" \
    | jq -r '.data.result[0].value[1] // "0"'
  }

  N1QL_RATE=$(query_value 'sum(rate(n1ql_requests[5m])) or vector(0)')
  N1QL_SLOW=$(query_value 'sum(rate(n1ql_requests_500ms[5m])) or vector(0)')
  INDEX_PENDING=$(query_value 'max(index_num_docs_pending) or vector(0)')
  BG_FETCH_RATE=$(query_value 'sum(rate(kv_ep_bg_fetched[5m])) or vector(0)')

  jq -n \
    --arg captured_at "$(date -Iseconds)" \
    --argjson workload_elapsed_seconds "$ELAPSED" \
    --argjson n1ql_request_rate "$N1QL_RATE" \
    --argjson n1ql_slow_500ms_rate "$N1QL_SLOW" \
    --argjson index_pending_max "$INDEX_PENDING" \
    --argjson background_fetch_rate "$BG_FETCH_RATE" \
    '{
      captured_at: $captured_at,
      workload_elapsed_seconds: $workload_elapsed_seconds,
      n1ql_request_rate: $n1ql_request_rate,
      n1ql_slow_500ms_rate: $n1ql_slow_500ms_rate,
      index_pending_max: $index_pending_max,
      background_fetch_rate: $background_fetch_rate
    }' \
    | tee "${ROOT_DIR}/results/baseline.json"

  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-lab11-client \
    -- \
    tail -n 10 /tmp/workload.jsonl \
    | tee "${ROOT_DIR}/results/workload-baseline.jsonl"
  EOF
  ```

**Salida esperada:** Debe crearse un script que rechaza capturas prematuras y registra Query, Index, background fetches y diez muestras recientes del cliente.

- {% include step_label.html %} Habilita y valida la sintaxis del script; continúa con el dashboard mientras se completan los cinco minutos requeridos.

  ```bash
  chmod +x scripts/capture_baseline.sh
  bash -n scripts/capture_baseline.sh
  ```

**Salida esperada:** `bash -n` no debe mostrar errores; el script queda preparado para ejecutarse en la Tarea 7.1.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## 📊 Tarea 4. Crear dashboard Grafana completo — 11 min

### Tarea 4.1. Identificar datasource Prometheus

- {% include step_label.html %} Descubre el UID real del datasource Prometheus creado por Helm para referenciarlo al generar el dashboard mediante API.

  ```bash
  PROM_DS_UID=$(
    curl -s \
      -u "$GRAFANA_USER:$GRAFANA_PASS" \
      http://localhost:3000/api/datasources \
      | jq -r '
          .[]
          | select(.type == "prometheus")
          | .uid
        ' \
      | head -n 1
  )

  echo "PROM_DS_UID=$PROM_DS_UID"
  ```

**Salida esperada:** Debe imprimirse `PROM_DS_UID=<uid>` con un UID no vacío. Ese identificador enlaza los paneles generados con el datasource Prometheus instalado por Helm.

### Tarea 4.2. Generar dashboard reproducible

- {% include step_label.html %} Genera un script Python que construye de forma reproducible las cinco filas del dashboard con PromQL validado en runtime.

  ```bash
  cat > scripts/build_dashboard.py << 'PYEOF'
  import json
  import os
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  ds_uid = os.environ["PROM_DS_UID"]

  datasource = {
      "type": "prometheus",
      "uid": ds_uid
  }

  panels = []
  y = 0
  pid = 1

  def row(title):
      global y, pid
      panels.append({
          "id": pid,
          "type": "row",
          "title": title,
          "collapsed": False,
          "gridPos": {
              "h": 1,
              "w": 24,
              "x": 0,
              "y": y
          }
      })
      pid += 1
      y += 1

  def panel(title, expr, x, w=12, h=6, unit="short"):
      global y, pid
      panels.append({
          "id": pid,
          "type": "timeseries",
          "title": title,
          "datasource": datasource,
          "gridPos": {
              "h": h,
              "w": w,
              "x": x,
              "y": y
          },
          "fieldConfig": {
              "defaults": {
                  "unit": unit
              }
          },
          "targets": [{
              "refId": "A",
              "expr": expr,
              "legendFormat": "{{instance}}"
          }]
      })
      pid += 1

  row("1 — Cluster Overview")
  panel(
      "Couchbase Metrics Target Health",
      'up{service="couchbase-metrics"}',
      0
  )
  panel(
      "SQL++ Request Rate",
      'sum(rate(n1ql_requests[5m])) or vector(0)',
      12,
      unit="reqps"
  )
  y += 6

  row("2 — Data")
  panel(
      "Background Fetch Activity",
      'sum(rate(kv_ep_bg_fetched[5m])) or vector(0)',
      0
  )
  panel(
      "Data Memory Used",
      'sum(kv_mem_used_bytes)',
      12,
      unit="bytes"
  )
  y += 6

  row("3 — Query + Index")
  panel(
      "SQL++ Slow Queries >500ms",
      'sum(rate(n1ql_requests_500ms[5m])) or vector(0)',
      0,
      unit="reqps"
  )
  panel(
      "Index Pending Mutations",
      'max(index_num_docs_pending) or vector(0)',
      12
  )
  y += 6
  panel(
      "Index Memory Used",
      'sum(index_memory_used_total)',
      0,
      unit="bytes"
  )
  panel(
      "Index Memory Quota",
      'sum(index_memory_quota)',
      12,
      unit="bytes"
  )
  y += 6

  row("4 — Advanced Services")
  panel(
      "Advanced Metrics Available",
      'count({__name__=~"fts_.*|eventing_.*|cbas_.*|xdcr_.*"}) or vector(0)',
      0,
      w=24
  )
  y += 6

  row("5 — Kubernetes + Operator + Events")
  panel(
      "Pod Restarts — Couchbase Namespace",
      'sum(kube_pod_container_status_restarts_total{namespace="couchbase"})',
      0
  )
  panel(
      "Operator Manual Intervention",
      'max(cluster_manual_intervention) or vector(0)',
      12
  )
  y += 6

  dashboard = {
      "dashboard": {
          "uid": "cb-lab11-operational",
          "title": "Couchbase Operational Dashboard — Lab 11",
          "tags": [
              "couchbase",
              "eks",
              "operator",
              "lab11"
          ],
          "timezone": "browser",
          "refresh": "30s",
          "time": {
              "from": "now-1h",
              "to": "now"
          },
          "panels": panels
      },
      "overwrite": True
  }

  target = root / "grafana" / "dashboard.json"
  target.write_text(
      json.dumps(dashboard, indent=2),
      encoding="utf-8"
  )

  print(
      json.dumps(
          {
              "panels": len(panels),
              "rows": 5
          },
          indent=2
      )
  )
  PYEOF

  export PROM_DS_UID
  ```

**Salida esperada:** Debe crearse `scripts/build_dashboard.py` con cinco filas de Grafana y PromQL válido; la expresión de métricas avanzadas debe usar el operador regex `=~` sin barra invertida.
- {% include step_label.html %} Valida la sintaxis Python de `scripts/build_dashboard.py` antes de ejecutarlo.

  ```bash
  python -m py_compile scripts/build_dashboard.py
  ```

**Salida esperada:** `python -m py_compile` no debe imprimir errores; el generador queda validado antes de producir artefactos.

- {% include step_label.html %} Ejecuta el generador del dashboard y conserva el resumen de filas y paneles creados antes de importarlo en Grafana.

  ```bash
  python scripts/build_dashboard.py \
    | tee results/dashboard-build.json
  ```

**Salida esperada:** El script debe terminar sin traceback, imprimir un JSON con `"rows": 5` y crear `grafana/dashboard.json` con las filas Cluster Overview, Data, Query + Index, Advanced Services y Kubernetes + Operator + Events.

### Tarea 4.3. Importar dashboard

- {% include step_label.html %} Importa `grafana/dashboard.json` mediante la API de Grafana y conserva la respuesta que confirma UID, URL y estado.

  ```bash
  curl -s \
    -X POST \
    -H "Content-Type: application/json" \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    http://localhost:3000/api/dashboards/db \
    -d @grafana/dashboard.json \
    | tee results/dashboard-create.json \
    | jq '{uid, url, status}'
  ```

**Salida esperada:**

```text
uid = cb-lab11-operational
status = success
```

### Tarea 4.4. Verificar datos antes de abrir el dashboard

- {% include step_label.html %} Comprueba desde Prometheus que las expresiones principales del dashboard ya devuelven vectores antes de abrir Grafana, garantizando que la primera visualización no dependa de esperar manualmente.

  ```bash
  for QUERY in \
    'up{service="couchbase-metrics"}' \
    'sum(rate(n1ql_requests[5m]))' \
    'sum(kv_mem_used_bytes)' \
    'sum(index_memory_used_total)' \
    'sum(index_memory_quota)' \
    'max(cluster_manual_intervention)'; do

    COUNT=$(
      curl -fsSG \
        http://localhost:9090/api/v1/query \
        --data-urlencode "query=${QUERY}" \
      | jq '.data.result | length'
    )

    printf '%-45s series=%s\n' "$QUERY" "$COUNT"
  done
  ```

**Salida esperada:** Cada consulta principal debe mostrar `series=1` o un valor mayor. Esto confirma que Prometheus ya dispone de datos para Cluster Overview, Data, Query/Index y Operator antes de abrir Grafana.

### Tarea 4.5. Abrir dashboard

- {% include step_label.html %} Accede a Grafana `admin` y `Password123!`.

  ```text
  http://localhost:3000
  ```

- {% include step_label.html %} Da clic en el menú lateral izquierdo en **Dashboards** y selecciona el que se llame:

  ```text
  Couchbase Operational Dashboard — Lab 11
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🧪 Tarea 5. Analizar Data, Query e Index — 8 min

### Tarea 5.1. Validar Query request rate

- {% include step_label.html %} Ejecuta la consulta PromQL del apartado y guarda su resultado para analizar tráfico, latencia o saturación con series verificadas.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=sum(rate(n1ql_requests[5m]))' \
    | jq '{status, result: .data.result}'
  ```

**Salida esperada:** Prometheus debe responder un objeto con `"status": "success"` y `result` debe contener la tasa agregada de `n1ql_requests`; durante el workload normalmente será mayor que cero.

### Tarea 5.2. Calcular ratio de slow queries

- {% include step_label.html %} Usa el contador documentado `n1ql_requests_500ms`. No llames p99 a un promedio ni a una tasa que no representa un percentil.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=100 * sum(rate(n1ql_requests_500ms[5m])) / clamp_min(sum(rate(n1ql_requests[5m])), 0.001)' \
    | jq '{status, result: .data.result}' \
    | tee results/query-slow-ratio.json
  ```

**Salida esperada:** Prometheus debe responder `"status": "success"` y `result` debe contener el porcentaje de consultas superiores a 500 ms respecto al total; el valor puede ser `0` si no hubo consultas lentas.

### Tarea 5.3. Consultar Index memory

- {% include step_label.html %} Ejecuta la consulta PromQL del apartado y guarda su resultado para analizar tráfico, latencia o saturación con series verificadas.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=100 * sum(index_memory_used_total) / clamp_min(sum(index_memory_quota), 1)' \
    | jq '{status, result: .data.result}' \
    | tee results/index-memory-percent.json
  ```

**Salida esperada:** Prometheus debe responder `"status": "success"` y `result` debe contener el porcentaje de memoria Index utilizada respecto a `index_memory_quota`; el resultado debe ser numérico cuando el Index Service está siendo scrapeado.

### Tarea 5.4. Consultar pending mutations

- {% include step_label.html %} Ejecuta la consulta PromQL del apartado y guarda su resultado para analizar tráfico, latencia o saturación con series verificadas.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=max(index_num_docs_pending)' \
    | jq '{status, result: .data.result}' \
    | tee results/index-pending.json
  ```

**Salida esperada:** Prometheus debe responder `"status": "success"` y `result` debe mostrar el máximo de `index_num_docs_pending`; `0` es válido cuando el índice está completamente al día.

### Tarea 5.5. Consultar background fetches sin llamarlos cache misses

- {% include step_label.html %} Ejecuta la consulta PromQL del apartado y guarda su resultado para analizar tráfico, latencia o saturación con series verificadas.

  ```bash
  if grep -qx 'kv_ep_bg_fetched' metrics/metric-names.txt; then
    curl -sG \
      http://localhost:9090/api/v1/query \
      --data-urlencode 'query=sum(rate(kv_ep_bg_fetched[5m]))' \
      | jq '{status, result: .data.result}' \
      | tee results/background-fetch-rate.json
  else
    echo '{"status":"metric-not-present"}' \
      | tee results/background-fetch-rate.json
  fi
  ```

**Salida esperada:**

Cada archivo debe contener una medición válida o una declaración explícita de que la métrica no existe. No se sustituye una métrica ausente por otra semánticamente diferente.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🧭 Tarea 6. Analizar servicios avanzados, Kubernetes y Operator — 7 min

### Tarea 6.1. Generar catálogo avanzado

- {% include step_label.html %} Construye un inventario de métricas avanzadas presentes y marca `NOT_PRESENT` cuando un servicio no expone series utilizables en este escenario.

  ```bash
  {
    for PREFIX in fts_ eventing_ cbas_ xdcr_; do
      echo "### ${PREFIX}"

      MATCHES=$(
        grep "^${PREFIX}" \
          metrics/metric-names.txt \
          | head -20 || true
      )

      if [[ -n "$MATCHES" ]]; then
        echo "$MATCHES"
      else
        echo "NOT_PRESENT"
      fi

      echo
    done
  } | tee results/advanced-metrics.md
  ```

**Salida esperada:** `results/advanced-metrics.md` debe contener una sección para `fts_`, `eventing_`, `cbas_` y `xdcr_`; cada sección muestra hasta 20 métricas reales o `NOT_PRESENT`, evitando inventar series ausentes.

### Tarea 6.2. Interpretar XDCR correctamente

> ****IMPORTANTE:**** Si existe una métrica de `changes_left`, su unidad representa backlog/cambios pendientes. No significa segundos. Cualquier cálculo `changes_left / xdcr_rate` debe titularse ****estimated drain time****, no “lag real”.
{: .lab-note .important .compact}

### Tarea 6.3. Consultar métricas del Operator

- {% include step_label.html %} Ejecuta la consulta PromQL del apartado y guarda su resultado para analizar tráfico, latencia o saturación con series verificadas.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/query \
    --data-urlencode 'query=max(cluster_manual_intervention)' \
    | jq '{status, result: .data.result}' \
    | tee results/operator-manual-intervention.json
  ```

**Salida esperada:** Prometheus debe responder `"status": "success"` y `result` debe contener `cluster_manual_intervention`; el valor normal es `0`, mientras que un valor mayor que cero indica intervención manual requerida por Operator.

- {% include step_label.html %} Descubre además las métricas Operator realmente presentes en Prometheus.

  ```bash
  curl -sG \
    http://localhost:9090/api/v1/label/__name__/values \
    | jq -r '.data[]' \
    | grep -E 'reconcile|manual_intervention|pod_recover|swap_rebalance|backup_jobs' \
    | sort -u \
    | tee results/operator-metrics.txt
  ```

**Salida esperada:** `results/operator-metrics.txt` debe incluir al menos `cluster_manual_intervention` cuando el target del Operator está UP; también puede listar métricas de reconciliación, recuperación o backup disponibles en Operator 2.92.0.

### Tarea 6.4. Capturar Kubernetes events

- {% include step_label.html %} Captura los eventos Kubernetes recientes del namespace Couchbase para correlacionarlos con métricas y alertas sin tratarlos como logs centralizados.

  ```bash
  kubectl get events \
    -n "$CB_NAMESPACE" \
    --sort-by=.lastTimestamp \
    | tail -n 30 \
    | tee results/kubernetes-events.txt
  ```

**Salida esperada:** `results/kubernetes-events.txt` debe contener hasta 30 eventos recientes ordenados por `lastTimestamp`; es normal observar eventos de scheduling, volúmenes, Pods o reconciliación, pero no debe haber una cadena sostenida de errores críticos del clúster.

### Tarea 6.5. Capturar Couchbase system events

- {% include step_label.html %} Ejecuta este bloque como una unidad independiente para completar la operación del apartado y conservar una secuencia reproducible de la práctica.

  ```bash
  curl -s \
    -u "$CB_USER:$CB_PASS" \
    'http://localhost:8091/events?limit=20' \
    | jq '.' \
    | tee results/couchbase-events.json
  ```

**Salida esperada:**

`results/couchbase-events.json` debe contener un arreglo u objeto JSON válido con los eventos de sistema más recientes. Al terminar la tarea deben existir cuatro evidencias distintas: catálogo avanzado, métricas Operator, eventos Kubernetes y eventos Couchbase; no se mezclan como si fueran una única fuente de logs.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 📐 Tarea 7. Derivar thresholds desde baseline — 6 min

### Tarea 7.1. Capturar baseline después de cinco minutos

- {% include step_label.html %} Ejecuta la captura una vez cumplidos cinco minutos de workload y conserva simultáneamente baseline de servidor y muestras del cliente.

  ```bash
  ./scripts/capture_baseline.sh
  ```

**Salida esperada:** Si ya transcurrieron al menos 300 s desde `workload-start-epoch.txt`, deben generarse `results/baseline.json` y `results/workload-baseline.jsonl`. `baseline.json` debe incluir `n1ql_request_rate`, `n1ql_slow_500ms_rate`, `index_pending_max` y `background_fetch_rate`.

### Tarea 7.2. Crear política de thresholds

- {% include step_label.html %} Genera una política que distingue condiciones lógicas, umbrales del caso y un threshold de background fetch derivado del baseline observado.

  ```bash
  cat > scripts/build_thresholds.py << 'PYEOF'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent

  baseline = json.loads(
      (root / "results" / "baseline.json")
      .read_text(encoding="utf-8")
  )

  background_baseline = float(
      baseline.get(
          "background_fetch_rate",
          0
      )
  )

  background_threshold = max(
      round(background_baseline * 3, 2),
      1.0
  )

  thresholds = {
      "CouchbaseMetricsTargetDown": {
          "type": "logical",
          "for_seconds": 60,
          "condition": "up{service=\"couchbase-metrics\"} == 0"
      },
      "OperatorMetricsTargetDown": {
          "type": "logical",
          "for_seconds": 60,
          "condition": "up{service=\"couchbase-operator-metrics\"} == 0"
      },
      "QuerySlowRatioHigh": {
          "type": "case-policy",
          "percent": 5
      },
      "IndexPendingMutationsHigh": {
          "type": "case-policy",
          "documents": 10000
      },
      "PVCUsageHigh": {
          "type": "case-policy",
          "percent": 80
      },
      "OperatorManualIntervention": {
          "type": "product-condition",
          "condition": "> 0"
      },
      "BackgroundFetchActivityHigh": {
          "type": "baseline-derived",
          "baseline_per_second": background_baseline,
          "multiplier": 3,
          "threshold_per_second": background_threshold
      },
      "Lab11SyntheticPipeline": {
          "type": "synthetic",
          "condition": "vector(1)"
      }
  }

  target = (
      root /
      "results" /
      "alert-thresholds.json"
  )

  target.write_text(
      json.dumps(
          thresholds,
          indent=2
      ),
      encoding="utf-8"
  )

  print(
      json.dumps(
          thresholds,
          indent=2
      )
  )
  PYEOF
  ```

**Salida esperada:** El script debe calcular `BackgroundFetchActivityHigh.threshold_per_second` desde el baseline y conservar los demás umbrales con su origen explícito.

- {% include step_label.html %} Valida la sintaxis Python de `scripts/build_thresholds.py` antes de ejecutarlo.

  ```bash
  python -m py_compile scripts/build_thresholds.py
  ```

**Salida esperada:** `python -m py_compile` no debe imprimir errores; el generador queda validado antes de producir artefactos.

- {% include step_label.html %} Ejecuta el generador y conserva la política resultante para reutilizar el threshold derivado al construir las reglas Prometheus.

  ```bash
  python scripts/build_thresholds.py \
    | tee results/threshold-build.json
  ```

**Salida esperada:** Deben generarse `results/alert-thresholds.json` y `results/threshold-build.json` con ocho definiciones y tipos de origen identificables.

### Tarea 7.3. Documentar origen

| Regla | Origen del umbral |
|---|---|
| Target Down | Condición lógica de scraping |
| Query Slow Ratio | Política del caso / SLO |
| Index Pending | Política del caso |
| PVC Usage | Política de capacidad |
| Manual Intervention | Condición del producto |
| Background Fetch | Derivado del baseline × 3, mínimo 1/s |
| Operator Target Down | Condición lógica de scraping |
| Synthetic | Sólo validación del pipeline |

**Salida esperada:**

Debe existir:

```text
results/alert-thresholds.json
```

y ningún threshold debe presentarse como universal si sólo pertenece al caso.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🚨 Tarea 8. Crear 8 reglas Prometheus y Alertmanager routing — 8 min

### Tarea 8.1. Crear receiver Kubernetes

- {% include step_label.html %} Define un receiver HTTP mínimo dentro de Kubernetes para observar de forma determinista las notificaciones enviadas por Alertmanager.

  ```bash
  cat > manifests/alert-receiver.yaml << 'EOF'
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: alert-receiver-code
    namespace: monitoring
  data:
    receiver.py: |
      from http.server import HTTPServer, BaseHTTPRequestHandler
      import json

      class Handler(BaseHTTPRequestHandler):
          def do_POST(self):
              length = int(
                  self.headers.get(
                      "Content-Length",
                      "0"
                  )
              )

              body = self.rfile.read(length)
              print(
                  body.decode(),
                  flush=True
              )

              self.send_response(200)
              self.end_headers()

          def log_message(self, fmt, *args):
              return

      HTTPServer(
          ("0.0.0.0", 5001),
          Handler
      ).serve_forever()
  ---
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: alert-receiver
    namespace: monitoring
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: alert-receiver
    template:
      metadata:
        labels:
          app: alert-receiver
      spec:
        containers:
          - name: receiver
            image: python:3.12-slim
            command:
              - python
              - /app/receiver.py
            ports:
              - containerPort: 5001
            volumeMounts:
              - name: code
                mountPath: /app
        volumes:
          - name: code
            configMap:
              name: alert-receiver-code
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: alert-receiver
    namespace: monitoring
  spec:
    selector:
      app: alert-receiver
    ports:
      - name: http
        port: 5001
        targetPort: 5001
  EOF
  ```

**Salida esperada:** `alert-receiver.yaml` debe contener tres documentos Kubernetes: ConfigMap con el servidor HTTP Python, Deployment de una réplica y Service interno en el puerto 5001.
- {% include step_label.html %} Aplica ConfigMap, Deployment y Service del receiver para disponer de un destino webhook accesible desde Alertmanager.

  ```bash
  kubectl apply -f manifests/alert-receiver.yaml
  ```

**Salida esperada:** Deben crearse o configurarse `configmap/alert-receiver-code`, `deployment.apps/alert-receiver` y `service/alert-receiver`.
- {% include step_label.html %} Espera que el receiver quede disponible antes de configurar el routing y ejecutar la alerta sintética end-to-end.

  ```bash
  kubectl rollout status \
    -n "$MON_NAMESPACE" \
    deployment/alert-receiver \
    --timeout=3m
  ```

**Salida esperada:** `deployment/alert-receiver` debe completar su rollout, confirmando que Alertmanager dispone de un endpoint HTTP accesible antes de enviar notificaciones.

### Tarea 8.2. Configurar Alertmanager

- {% include step_label.html %} Configura un receiver webhook Kubernetes-native. Alertmanager administra agrupación, deduplicación y routing; Grafana permanece como capa de visualización.

  ```bash
  cat > alerts/alertmanagerconfig.yaml << 'EOF'
  apiVersion: monitoring.coreos.com/v1alpha1
  kind: AlertmanagerConfig
  metadata:
    name: couchbase-routing
    namespace: monitoring
    labels:
      release: monitoring
  spec:
    route:
      receiver: couchbase-webhook
      groupBy:
        - alertname
      groupWait: 5s
      groupInterval: 30s
      repeatInterval: 5m
    receivers:
      - name: couchbase-webhook
        webhookConfigs:
          - url: http://alert-receiver.monitoring.svc:5001/alerts
            sendResolved: true
  EOF
  ```

**Salida esperada:** `alertmanagerconfig.yaml` debe definir el receiver `couchbase-webhook`, agrupar por `alertname` y enviar POST al Service interno `alert-receiver.monitoring.svc:5001`.
- {% include step_label.html %} Aplica el routing declarativo para que Alertmanager incorpore el webhook seleccionado por la configuración del stack.

  ```bash
  kubectl apply -f alerts/alertmanagerconfig.yaml
  ```

**Salida esperada:** Kubernetes debe crear o configurar `alertmanagerconfig.monitoring.coreos.com/couchbase-routing`; kube-prometheus-stack podrá incorporarlo porque coincide con `release: monitoring`.

### Tarea 8.3. Crear ocho reglas

- {% include step_label.html %} Recupera el threshold de background fetch calculado desde baseline para insertarlo en la regla sin hardcodear un valor presentado como universal.

  ```bash
  BG_THRESHOLD=$(
    jq -r \
      '.BackgroundFetchActivityHigh.threshold_per_second' \
      results/alert-thresholds.json
  )

  echo "BG_THRESHOLD=$BG_THRESHOLD"
  ```

**Salida esperada:** `BG_THRESHOLD` debe ser un número mayor o igual a `1.0` operaciones por segundo.

- {% include step_label.html %} Crea siete reglas operativas: dos de scrape health, Query, Index, Operator, PVC y background fetch; todas quedan separadas de la prueba sintética.

{% raw %}
  ```bash
  cat > alerts/couchbase-rules.yaml << 'EOF'
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: couchbase-operational-alerts
    namespace: monitoring
    labels:
      release: monitoring
  spec:
    groups:
      - name: couchbase.operational
        interval: 30s
        rules:
          - alert: CouchbaseMetricsTargetDown
            expr: |
              up{service="couchbase-metrics"} == 0
            for: 1m
            labels:
              severity: critical
              category: availability
            annotations:
              summary: "A Couchbase Server metrics target is down"
              description: "Prometheus could not scrape {{ $labels.instance }}."

          - alert: OperatorMetricsTargetDown
            expr: |
              up{service="couchbase-operator-metrics"} == 0
            for: 1m
            labels:
              severity: critical
              category: operator
            annotations:
              summary: "The Couchbase Operator metrics target is down"

          - alert: QuerySlowRatioHigh
            expr: |
              100 *
              sum(rate(n1ql_requests_500ms[5m]))
              /
              clamp_min(
                sum(rate(n1ql_requests[5m])),
                0.001
              )
              > 5
            for: 2m
            labels:
              severity: warning
              category: latency
            annotations:
              summary: "SQL++ slow-query ratio exceeds case policy"

          - alert: IndexPendingMutationsHigh
            expr: |
              max(index_num_docs_pending) > 10000
            for: 2m
            labels:
              severity: warning
              category: saturation
            annotations:
              summary: "Index pending mutations exceed case policy"

          - alert: OperatorManualIntervention
            expr: |
              max(cluster_manual_intervention) > 0
            for: 1m
            labels:
              severity: critical
              category: operator
            annotations:
              summary: "Couchbase Operator requires manual intervention"

          - alert: CouchbasePVCUsageHigh
            expr: |
              100 *
              (
                kubelet_volume_stats_used_bytes{
                  namespace="couchbase",
                  persistentvolumeclaim=~".*cb-cs400.*"
                }
                /
                kubelet_volume_stats_capacity_bytes{
                  namespace="couchbase",
                  persistentvolumeclaim=~".*cb-cs400.*"
                }
              )
              > 80
            for: 5m
            labels:
              severity: warning
              category: storage
            annotations:
              summary: "Couchbase PVC usage exceeds 80%"

          - alert: BackgroundFetchActivityHigh
            expr: |
              sum(rate(kv_ep_bg_fetched[5m])) > __BG_THRESHOLD__
            for: 2m
            labels:
              severity: warning
              category: data
            annotations:
              summary: "Background fetch activity exceeds derived baseline threshold"
              description: "Background fetches represent disk fetch activity, not a logical key-miss ratio."
  EOF
  ```
{% endraw %}

**Salida esperada:** `alerts/couchbase-rules.yaml` debe contener exactamente siete bloques `alert:` y el placeholder `__BG_THRESHOLD__`.

- {% include step_label.html %} Sustituye el placeholder por el threshold derivado, valida que quedaron siete reglas y aplica el PrometheusRule operativo.

  ```bash
  sed -i \
    "s/__BG_THRESHOLD__/${BG_THRESHOLD}/g" \
    alerts/couchbase-rules.yaml

  grep -cE '^[[:space:]]*- alert:' \
    alerts/couchbase-rules.yaml

  kubectl apply \
    -f alerts/couchbase-rules.yaml
  ```

**Salida esperada:** `grep` debe devolver `7` y Kubernetes debe crear o configurar `prometheusrule/couchbase-operational-alerts`.

- {% include step_label.html %} Crea la octava regla en un PrometheusRule independiente para poder eliminar la prueba sintética sin editar el manifiesto operativo.

  ```bash
  cat > alerts/synthetic-rule.yaml << 'EOF'
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: lab11-synthetic-alert
    namespace: monitoring
    labels:
      release: monitoring
  spec:
    groups:
      - name: lab11.synthetic
        interval: 15s
        rules:
          - alert: Lab11SyntheticPipeline
            expr: vector(1)
            for: 15s
            labels:
              severity: info
              category: synthetic
            annotations:
              summary: "Synthetic Lab 11 alert for end-to-end validation"
  EOF
  ```

**Salida esperada:** `alerts/synthetic-rule.yaml` debe contener una única regla llamada `Lab11SyntheticPipeline`.

- {% include step_label.html %} Aplica la regla sintética y confirma que ambos PrometheusRule existen antes de verificar su carga en Prometheus.

  ```bash
  kubectl apply \
    -f alerts/synthetic-rule.yaml
  ```
  ```bash
  kubectl get prometheusrule \
    -n "$MON_NAMESPACE" \
    couchbase-operational-alerts \
    lab11-synthetic-alert
  ```

**Salida esperada:** Deben aparecer dos recursos `PrometheusRule`; juntos contienen las ocho reglas requeridas por la práctica.

### Tarea 8.4. Verificar carga de reglas

- {% include step_label.html %} Consulta las reglas cargadas por Prometheus y conserva nombre y estado para verificar que los ocho controles fueron aceptados.

  ```bash
  RULES_READY=false

  for i in $(seq 1 30); do
    RULES_JSON=$(
      curl -fsS \
        http://localhost:9090/api/v1/rules
    )

    OPERATIONAL_COUNT=$(
      printf '%s' "$RULES_JSON" \
      | jq '[
          .data.groups[].rules[]
          | select(
              .name ==
                "CouchbaseMetricsTargetDown"
              or .name ==
                "OperatorMetricsTargetDown"
              or .name ==
                "QuerySlowRatioHigh"
              or .name ==
                "IndexPendingMutationsHigh"
              or .name ==
                "OperatorManualIntervention"
              or .name ==
                "CouchbasePVCUsageHigh"
              or .name ==
                "BackgroundFetchActivityHigh"
            )
        ] | length'
    )

    SYNTHETIC_COUNT=$(
      printf '%s' "$RULES_JSON" \
      | jq '[
          .data.groups[].rules[]
          | select(
              .name ==
                "Lab11SyntheticPipeline"
            )
        ] | length'
    )

    echo \
      "Intento $i - Operativas=$OPERATIONAL_COUNT | Sintética=$SYNTHETIC_COUNT"

    if [[ "$OPERATIONAL_COUNT" -eq 7 \
      && "$SYNTHETIC_COUNT" -eq 1 ]]; then
      RULES_READY=true
      break
    fi

    sleep 5
  done

  if [[ "$RULES_READY" == "true" ]]; then
    echo "PASS: Prometheus cargó las 8 reglas del laboratorio."
  else
    echo "FAIL: Prometheus no cargó las 8 reglas esperadas."
  fi
  ```

**Salida esperada:**

La regla sintética deberá transitar de `pending` a `firing`. Las reglas operativas pueden permanecer `inactive`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 🔔 Tarea 9. Verificar alerting end-to-end y eventos — 7 min

### Tarea 9.1. Esperar alerta sintética

- {% include step_label.html %} Sondea la API de alertas hasta que la regla sintética alcance `firing`, demostrando evaluación real dentro de Prometheus.

  ```bash
  SYNTHETIC_FIRING=false

  for i in $(seq 1 30); do
    STATE=$(
      curl -fsS \
        http://localhost:9090/api/v1/alerts \
      | jq -r '
          .data.alerts[]
          | select(
              .labels.alertname ==
              "Lab11SyntheticPipeline"
            )
          | .state
        ' \
      | head -n1
    )

    echo "state=${STATE:-not-visible}"

    if [[ "$STATE" == "firing" ]]; then
      SYNTHETIC_FIRING=true
      break
    fi

    sleep 5
  done

  [[ "$SYNTHETIC_FIRING" == "true" ]]
  ```

**Salida esperada:** La salida debe evolucionar desde `state=not-visible` o `pending` hasta `state=firing` dentro de los reintentos, y la comprobación final debe devolver código 0.

### Tarea 9.2. Verificar notificación en receiver

- {% include step_label.html %} Consulta los logs del receiver y conserva el payload enviado por Alertmanager como evidencia de entrega end-to-end. Tambien puedes abrir esta url `http://localhost:9090/alerts` y verificar la alerta.

  ```bash
  kubectl logs \
    -n "$MON_NAMESPACE" \
    deployment/alert-receiver \
    --tail=100 \
    | tee results/receiver.log
  ```

**Salida esperada:**

El JSON recibido debe contener:

```text
Lab11SyntheticPipeline
```

- {% include step_label.html %} Puedes abrir otra terminal y ejecutar el comando para abrir **Alertmanager** luego abre una pestaña de navegador u abre la URL:

  ```bash
  ALERTMANAGER_SVC=$(
    kubectl get svc \
      -n "$MON_NAMESPACE" \
      -o name \
    | grep alertmanager \
    | head -n 1
  )

  echo "$ALERTMANAGER_SVC"
  ```
  ```bash
  http://localhost:9093
  ```

**Salida esperada:** Debes observar la interfaz de Alermanager y sus alertas.

### Tarea 9.3. Crear annotation en Grafana

- {% include step_label.html %} Registra una annotation en Grafana para marcar temporalmente el inicio del baseline o un evento de alerta dentro del dashboard.

  ```bash
  curl -s \
    -X POST \
    -H "Content-Type: application/json" \
    -u "$GRAFANA_USER:$GRAFANA_PASS" \
    http://localhost:3000/api/annotations \
    -d "{
      \"dashboardUID\":\"cb-lab11-operational\",
      \"time\":$(date +%s000),
      \"tags\":[
        \"couchbase\",
        \"synthetic-alert\"
      ],
      \"text\":\"Lab11SyntheticPipeline firing y recibido por Alertmanager webhook\"
    }" \
    | tee results/grafana-annotation.json \
    | jq '.'
  ```

**Salida esperada:** Grafana debe responder con un objeto que incluya un identificador de annotation y un mensaje de creación; la evidencia queda guardada en `results/grafana-annotation.json`.

### Tarea 9.4. Correlacionar con eventos

- {% include step_label.html %} Construye el reporte de correlación reuniendo system events Couchbase, eventos Kubernetes y el payload recibido por el webhook.

  ```bash
  {
    echo "# Correlación de eventos"
    echo
    echo "## Couchbase"
    jq '.' results/couchbase-events.json
    echo
    echo "## Kubernetes"
    cat results/kubernetes-events.txt
    echo
    echo "## Receiver"
    cat results/receiver.log
  } > reports/event-correlation.md
  ```

**Salida esperada:** Debe crearse `reports/event-correlation.md` con tres secciones diferenciadas: eventos de Couchbase, eventos Kubernetes y payload recibido por el webhook de Alertmanager.

### Tarea 9.5. Eliminar regla sintética después de validar

- {% include step_label.html %} Elimina únicamente el PrometheusRule sintético después de conservar la evidencia del receiver; las siete reglas operativas permanecen activas.

  ```bash
  kubectl delete \
    -f alerts/synthetic-rule.yaml \
    --ignore-not-found
  ```

**Salida esperada:** Debe eliminarse `prometheusrule.monitoring.coreos.com/lab11-synthetic-alert` sin afectar `couchbase-operational-alerts`.

- {% include step_label.html %} Confirma que el recurso operativo continúa presente y que la regla sintética ya no forma parte de la configuración activa.

  ```bash
  kubectl get prometheusrule \
    -n "$MON_NAMESPACE" \
    couchbase-operational-alerts
  ```
  ```bash
  kubectl get prometheusrule \
    -n "$MON_NAMESPACE" \
    lab11-synthetic-alert \
    --ignore-not-found
  ```

**Salida esperada:** Debe mostrarse `couchbase-operational-alerts`; `lab11-synthetic-alert` no debe aparecer.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación integral y reporte — 4 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea `validate.sh` para comprobar catálogo de métricas, ambos targets, dashboard, reglas, baseline, métricas Operator y evidencia del webhook.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab1/validate.sh
  ```

**Salida esperada:** `validate.sh` debe contener 11 verificaciones: contrato Query/Index, ServiceMonitor, targets Server/Operator, dashboard, cinco filas, PrometheusRule, webhook, baseline, métricas Operator y correlación de eventos.
- {% include step_label.html %} Habilita y ejecuta el validador final para obtener un conteo objetivo de PASS/FAIL antes de construir el dossier.

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ```

**Salida esperada:** `bash -n` no debe mostrar errores y el script debe quedar ejecutable.

- {% include step_label.html %} Ejecuta el validador integral y conserva el resumen PASS/FAIL como evidencia previa a la construcción del dossier final.

  ```bash
  ./scripts/validate.sh \
    | tee reports/validation-final.txt
  ```

**Salida esperada:** El script debe finalizar con `RESULTADO: 11 PASS / 0 FAIL`.

### Tarea 10.2. Generar dossier final

- {% include step_label.html %} Genera el dossier final reuniendo versiones, contrato de métricas, baseline, servicios avanzados, receiver y validación integral.

  ```bash
  {
    echo "# DOSSIER FINAL — LAB 11"
    echo

    echo "## Stack"
    echo "Operator: ${CB_OPERATOR_VERSION}"
    echo "Server: Enterprise 7.6.2"
    echo "Monitoring chart:"
    cat results/kube-prometheus-stack-version.txt
    echo

    echo "## Metric contract"
    cat results/metric-contract.txt
    echo

    echo "## Baseline"
    cat results/baseline.json
    echo

    echo "## Advanced services"
    cat results/advanced-metrics.md
    echo

    echo "## Alert receiver"
    tail -n 30 results/receiver.log
    echo

    echo "## Validation"
    cat reports/validation-final.txt
  } | tee reports/final-report.md
  ```

**Salida esperada:**

  ```text
  RESULTADO: 11 PASS / 0 FAIL
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

- {% include step_label.html %} Elimina el workload temporal y el receiver si no se utilizarán en Labs posteriores.

  ```bash
  kubectl delete pod cb-lab11-client \
    -n "$CB_NAMESPACE" \
    --ignore-not-found
  ```

**Salida esperada:** Debe eliminarse `pod/cb-lab11-client`; si ya había sido retirado, `--ignore-not-found` permite continuar sin convertir la limpieza en un fallo.
- {% include step_label.html %} Elimina únicamente el recurso temporal indicado para limpiar la práctica sin borrar evidencias locales que formarán parte del reporte.

  ```bash
  kubectl delete \
    -n "$MON_NAMESPACE" \
    -f manifests/alert-receiver.yaml \
    --ignore-not-found
  ```

**Salida esperada:** Deben eliminarse `configmap/alert-receiver-code`, `deployment/alert-receiver` y `service/alert-receiver`; si alguno ya no existe, la limpieza continúa por `--ignore-not-found`.

- {% include step_label.html %} Elimina PrometheusRule y AlertmanagerConfig únicamente si no quieres conservar la observabilidad para prácticas posteriores.

  ```bash
  kubectl delete \
    -n "$MON_NAMESPACE" \
    -f alerts/couchbase-rules.yaml \
    --ignore-not-found
  ```

**Salida esperada:** Debe eliminarse `prometheusrule/couchbase-operational-alerts`; las evidencias guardadas en `results/` y `reports/` permanecen intactas.

- {% include step_label.html %} Elimina también el recurso sintético si la práctica se interrumpió antes de la Tarea 9.5 y todavía permanece registrado.

  ```bash
  kubectl delete \
    -n "$MON_NAMESPACE" \
    -f alerts/synthetic-rule.yaml \
    --ignore-not-found
  ```

**Salida esperada:** Debe eliminarse `prometheusrule/lab11-synthetic-alert` si aún existe; si ya fue retirado en la Tarea 9.5, el comando termina sin error.
- {% include step_label.html %} Elimina únicamente el recurso temporal indicado para limpiar la práctica sin borrar evidencias locales que formarán parte del reporte.

  ```bash
  kubectl delete \
    -n "$MON_NAMESPACE" \
    -f alerts/alertmanagerconfig.yaml \
    --ignore-not-found
  ```

**Salida esperada:** Debe eliminarse `alertmanagerconfig/couchbase-routing`, retirando el receiver específico del laboratorio sin borrar Prometheus, Grafana ni Alertmanager.

- {% include step_label.html %} Conserva `reports/`, `results/`, `metrics/` y `grafana/dashboard.json` como evidencia de la práctica.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén los port-forward de Couchbase, Prometheus y Grafana mediante `Ctrl+C`.

- {% include step_label.html %} Elimina el clúster EKS.

  ```bash
  cd /c/LABS/couchbase-nosql/lab11
  source lab.env

  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe eliminar `cb-cs400-lab11` en `us-west-2` y esperar la eliminación de los recursos administrados antes de devolver el prompt.

- {% include step_label.html %} Confirma que AWS ya no encuentre el recurso.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:**

```text
ResourceNotFoundException
```