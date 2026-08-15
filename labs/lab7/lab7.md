---
layout: lab
title: "Práctica 7: Diseño de sizing y topología para una carga empresarial"
permalink: /lab7/lab7/
images_base: /labs/lab7/img
duration: "78 minutos"
objective:
  - Dimensionar, comparar y validar una arquitectura Couchbase en Amazon EKS para una carga e-commerce de 260M de documentos y 70.5k OPS de pico, mediante una matriz auditable de supuestos, el cálculo estructurado de servicios (Data, Index, Query, Search, Analytics, Eventing), tres escenarios MDS a 24 meses y una validación a escala reducida.
prerequisites:
  - Haber completado las prácticas anteriores o dominar Data, Query, Index, Search, Analytics, Eventing, MDS y Server Groups.
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y Python 3 disponibles desde Git Bash.
  - Comprender vBuckets, replicas, working set, resident ratio, failure domains, Server Group Awareness y alta disponibilidad.
introduction:
  - En esta práctica no desplegarás físicamente una plataforma de 260 millones de documentos. Construirás un modelo de capacidad empresarial verificable y lo contrastarás con un clúster EKS reducido utilizado para observar topología, Availability Zones, Server Groups y métricas reales. Los cálculos separan datos del caso, valores presentes en las guías de Couchbase y supuestos pedagógicos para impedir que una heurística local se interprete como una regla universal de sizing.
slug: lab7
lab_number: 7
final_result: >
  Al finalizar la práctica habrás producido una matriz de supuestos, un modelo reproducible de RAM y disco del Data Service, dimensionamiento de Query, Index, Search, Analytics y Eventing, tres escenarios MDS, Server Groups reales alineados con tres Availability Zones, una simulación de crecimiento con capacidad N+1 y evidencias operativas obtenidas desde un clúster Couchbase Enterprise 7.6.2 sobre Amazon EKS.
notes:
  - Los 78 minutos corresponden exclusivamente al trabajo funcional de sizing y diseño; la creación y eliminación de Amazon EKS quedan fuera del tiempo.
  - Todos los comandos locales deben ejecutarse desde Git Bash integrado en Visual Studio Code.
  - La práctica utiliza Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - El caso empresarial usa 260 millones de documentos y 70,500 ops/s pico; cifras alternativas de versiones anteriores no se utilizan.
  - El clúster EKS de validación utiliza tres Pods Data + Query, un Pod Index + Search y un Pod Analytics + Eventing sobre tres workers m6i.xlarge.
  - Los tres Pods Data + Query permiten comprobar distribución del Data Service entre tres Server Groups alineados con las Availability Zones del clúster EKS.
  - El clúster reducido valida instrumentación y topología, pero no demuestra la capacidad necesaria para 260 millones de documentos o 70,500 ops/s.
  - El headroom de 30%, el crecimiento mensual de 8%, la compresión de 0.70 y los factores de reserva de disco son supuestos del caso, no recomendaciones universales de Couchbase.
  - Los indicadores LOW, MEDIUM y HIGH del simulador son umbrales pedagógicos de capacidad y no representan estados internos de Couchbase.
  - Magma no se selecciona por un umbral fijo de 100 GB; la decisión considera working set, escala, memory-to-data ratio, almacenamiento y benchmark.
  - Server Groups y MDS son conceptos diferentes: MDS define qué servicios ejecuta cada server class y Server Groups representan failure domains.
references:
  - text: Guía general de sizing de Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/install/sizing-general.html
  - text: Couchstore y Magma en Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/learn/buckets-memory-and-storage/storage-engines.html
  - text: Servicios y Multi-Dimensional Scaling
    url: https://docs.couchbase.com/server/7.6/learn/services-and-indexes/services/services.html
  - text: Administración de Server Groups en Couchbase Server
    url: https://docs.couchbase.com/server/7.6/manage/manage-groups/manage-groups.html
  - text: Server Groups con Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/concept-server-groups.html
  - text: Configuración de Server Groups con el Operator
    url: https://docs.couchbase.com/operator/current/howto-server-groups.html
  - text: Sizing y capacidad adicional con Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/concept-sizing.html
  - text: Referencia de métricas del Data Service
    url: https://docs.couchbase.com/server/7.6/metrics-reference/data-service-metrics.html
  - text: Estadísticas REST de buckets en Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/rest-api/rest-bucket-stats.html
prev: /lab6/lab6/
next: /lab8/lab8/
---

---

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona **File → Open Folder** y abre `C:\LABS\couchbase-nosql` para conservar la misma raíz de trabajo utilizada por las prácticas anteriores.

**Salida esperada:** Visual Studio Code debe mostrar `C:\LABS\couchbase-nosql` como carpeta raíz del workspace y permitir acceder a los laboratorios existentes desde el explorador lateral.

- {% include step_label.html %} Abre una terminal integrada **Git Bash**, crea los directorios del laboratorio y confirma la ruta antes de generar modelos, manifiestos, métricas y evidencias.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab7/{scripts,models,metrics,manifests,outputs}
  cd /c/LABS/couchbase-nosql/lab7

  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:** `pwd` debe devolver `/c/LABS/couchbase-nosql/lab7`; `find` debe listar `scripts`, `models`, `metrics`, `manifests` y `outputs`.

- {% include step_label.html %} Excluye credenciales y archivos temporales del repositorio para que la configuración local del laboratorio no se incorpore accidentalmente a Git.

  ```bash
  cat > .gitignore << 'EOF'
  lab.env
  *.tmp
  __pycache__/
  *.pyc
  EOF
  ```

**Salida esperada:** `.gitignore` debe excluir `lab.env`, archivos temporales y caché de Python sin impedir que modelos, scripts y evidencias se conserven como entregables.

## ☁️ Preparación de infraestructura

La infraestructura real sólo sirve para observar Couchbase, Kubernetes, Availability Zones, Server Groups y métricas. Los escenarios empresariales se calculan localmente y no se despliegan físicamente.

## Crear variables

- {% include step_label.html %} Crea `lab.env` con la configuración común de Amazon EKS y Couchbase para que manifiestos, scripts y validaciones utilicen una única fuente de parámetros.

  ```bash
  cat > lab.env << 'ENVEOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab07"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"
  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"
  export CB_OPERATOR_VERSION="2.92.0"
  ENVEOF
  ```

**Salida esperada:** `lab.env` debe contener región, clúster EKS, versión Kubernetes, namespace, imagen Enterprise 7.6.2 y Operator 2.92.0 con valores no vacíos.

- {% include step_label.html %} Carga las variables en la terminal activa y muestra únicamente valores no sensibles para comprobar que la sesión está preparada antes de crear infraestructura.

  ```bash
  source lab.env

  printf 'AWS_REGION=%s EKS_CLUSTER=%s EKS_VERSION=%s CB_NAMESPACE=%s\n' \
    "$AWS_REGION" "$EKS_CLUSTER" "$EKS_VERSION" "$CB_NAMESPACE"
  ```

**Salida esperada:** La terminal debe mostrar `us-west-2`, `cb-cs400-lab07`, `1.35` y `couchbase` sin imprimir la contraseña administrativa.

## Crear ciclo de vida EKS

- {% include step_label.html %} Crea un script reproducible que valide dependencias y gestione `create`, `status` y `delete` sobre tres workers `m6i.xlarge` distribuidos en tres Availability Zones.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab7/eks-cluster.sh
  ```

**Salida esperada:** `scripts/eks-cluster.sh` debe incluir prechecks, generar el ClusterConfig y proporcionar las acciones `create`, `status` y `delete`.

- {% include step_label.html %} Asigna permisos, valida la sintaxis Bash y crea EKS para comprobar que existen tres workers Ready y que AWS los distribuyó en las tres zonas declaradas.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe producir salida; al finalizar deben aparecer tres workers `m6i.xlarge` en estado `Ready`, uno por cada Availability Zone configurada.

## Crear StorageClass, Operator y CouchbaseCluster

- {% include step_label.html %} Define una StorageClass EBS `gp3` con `WaitForFirstConsumer` para que cada PVC se aprovisione después de conocer la zona donde Kubernetes programará el Pod.

  ```bash
  cat > manifests/storageclass-gp3.yaml << 'EOFSC'
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
  EOFSC
  ```
  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  kubectl get storageclass gp3-couchbase
  ```

**Salida esperada:** `gp3-couchbase` debe utilizar `ebs.csi.aws.com`, `WaitForFirstConsumer`, `Delete` y permitir expansión; no debe aparecer un error del EBS CSI Driver.

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 sin crear un clúster automático y espera que sus deployments queden disponibles antes de aplicar el CR.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```
  ```bash
  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace "$CB_NAMESPACE" \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```
  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available deployment --all \
    --timeout=5m
  ```

**Salida esperada:** Helm debe instalar o actualizar `cb-operator`; `kubectl wait` debe confirmar los deployments disponibles en `couchbase`.

- {% include step_label.html %} Crea el Secret administrativo de forma idempotente para permitir que el Operator configure Couchbase sin imprimir usuario o contraseña en el manifiesto.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace "$CB_NAMESPACE" \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe responder `secret/cb-admin created` o `configured`; la salida no debe revelar el valor de `$CB_PASS`.

- {% include step_label.html %} Define un clúster MDS reducido con tres Data + Query y Server Groups alineados con las tres AZ, más Index + Search y Analytics + Eventing para observación funcional.

  ```bash
  cat > manifests/couchbase-cluster.yaml << EOFCB
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: ${CB_CLUSTER}
    namespace: ${CB_NAMESPACE}
  spec:
    image: ${CB_IMAGE}

    security:
      adminSecret: cb-admin

    securityContext:
      fsGroup: 1000

    networking:
      exposeAdminConsole: false

    serverGroups:
      - ${AWS_REGION}a
      - ${AWS_REGION}b
      - ${AWS_REGION}c

    servers:
      - name: data-query
        size: 3
        services: [data, query]
        serverGroups:
          - ${AWS_REGION}a
          - ${AWS_REGION}b
          - ${AWS_REGION}c
        volumeMounts:
          default: couchbase-volume

      - name: index-search
        size: 1
        services: [index, search]
        volumeMounts:
          default: couchbase-volume

      - name: analytics-eventing
        size: 1
        services: [analytics, eventing]
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
  EOFCB
  ```

> **IMPORTANTE:** Los cinco Pods constituyen un entorno pequeño de observación. No representan ninguno de los escenarios empresariales calculados posteriormente.
{: .lab-note .important .compact}

**Salida esperada:** El manifiesto debe definir cinco Pods, tres Server Groups `us-west-2a/b/c` y tres miembros Data + Query susceptibles de distribuirse uno por cada failure domain.

- {% include step_label.html %} Aplica el `CouchbaseCluster`, espera la condición `Available` y revisa Pods, nodos y zonas para confirmar que la topología reducida quedó operativa.

  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```
  ```bash
  kubectl wait \
    -n "$CB_NAMESPACE" \
    --for=condition=Available \
    "couchbasecluster/${CB_CLUSTER}" \
    --timeout=15m
  ```
  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o wide
  ```

**Salida esperada:** El clúster debe alcanzar `Available`; deben aparecer cinco Pods `1/1 Running`, incluidos tres Data + Query distribuidos por el Operator.

## Cargar travel-sample

- {% include step_label.html %} Localiza dinámicamente un Pod Data + Query mediante los servicios anunciados por Couchbase, evitando asumir nombres ordinales generados por el Operator.

  ```bash
  MGMT_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}'
  )

  [[ -n "$MGMT_POD" ]] || {
    echo "ERROR: no se encontró ningún Pod Couchbase en ejecución."
    exit 1
  }

  TOPOLOGY=$(
    kubectl exec \
      -n "$CB_NAMESPACE" \
      "$MGMT_POD" \
      -c couchbase-server \
      -- \
      curl -sS \
        -u "$CB_USER:$CB_PASS" \
        http://127.0.0.1:8091/pools/default
  )

  DATA_QUERY_POD=$(
    echo "$TOPOLOGY" \
    | jq -r '
        .nodes[]
        | select(
            (.services | index("kv"))
            and (.services | index("n1ql"))
          )
        | .hostname
      ' \
    | head -n1 \
    | cut -d. -f1
  )

  [[ -n "$DATA_QUERY_POD" ]] || {
    echo "ERROR: no se encontró un Pod con Data + Query Service."
    exit 1
  }

  export DATA_QUERY_POD
  echo "Data + Query Pod seleccionado: $DATA_QUERY_POD"
  ```

**Salida esperada:** Debe imprimirse `Data + Query Pod seleccionado: cb-cs400-000X`; el miembro seleccionado debe anunciar simultáneamente `kv` y `n1ql`.

- {% include step_label.html %} Publica la administración HTTP del Pod seleccionado por el puerto local 8091 y mantén esta terminal dedicada activa durante las tareas de observación.

  ```bash
  kubectl port-forward \
    -n "$CB_NAMESPACE" \
    "pod/${DATA_QUERY_POD}" \
    8091:8091
  ```

**Salida esperada:** La terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8091 -> 8091` mientras el túnel esté activo y el Pod permanezca estable.

- {% include step_label.html %} Instala `travel-sample` solamente cuando el bucket no exista y valida después su presencia para evitar interpretar una ejecución repetida como un fallo.

  ```bash
  if ! curl -fsS \
      -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default/buckets/travel-sample \
      >/dev/null 2>&1; then

    curl -sS \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      http://localhost:8091/sampleBuckets/install \
      -d '["travel-sample"]' \
      | jq .
  fi

  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/travel-sample \
    | jq '{name, itemCount, replicaNumber}'
  ```             

**Salida esperada:** La consulta final debe mostrar `name: "travel-sample"` y datos del bucket; la instalación no debe repetirse cuando el sample ya exista.

---

## 🔎 Tarea 1. Caracterizar workload y construir matriz de supuestos — 8 min

### Tarea 1.1. Revisar el caso empresarial

| Bucket | Documentos | Tamaño medio | GET/s pico | SET/s pico | Total |
|---|---:|---:|---:|---:|---:|
| `product_catalog` | 50,000,000 | 2 KiB | 45,000 | 3,000 | 48,000 |
| `user_sessions` | 200,000,000 | 1.5 KiB | 8,000 | 12,000 | 20,000 |
| `orders` | 10,000,000 | 4 KiB | 500 | 2,000 | 2,500 |
| **Total** | **260,000,000** | — | **53,500** | **17,000** | **70,500** |

> **IMPORTANTE:** Los 70,500 ops/s son un input del caso empresarial y no throughput medido del clúster EKS reducido.
{: .lab-note .important .compact}

### Tarea 1.2. Crear matriz de supuestos

- {% include step_label.html %} Crea `sizing-inputs.json` separando las constantes utilizadas por la guía RAM de Couchbase de los supuestos pedagógicos necesarios para completar el escenario.

  ```bash
  cat > models/sizing-inputs.json << 'EOFIN'
  {
    "documented_couchbase_values": {
      "metadata_per_document_bytes": 56,
      "ram_overhead_pct": 0.25,
      "high_water_mark": 0.85,
      "query_concurrency_per_core": 4,
      "plasma_metadata_back_index_bytes": 46,
      "plasma_metadata_main_index_bytes": 74,
      "plasma_secondary_index_storage_factor": 2.0,
      "analytics_typical_temp_disk_factor": 2.0,
      "couchstore_recommended_min_memory_to_data_ratio": 0.10,
      "magma_min_memory_to_data_ratio": 0.01
    },
    "case_policies": {
      "replicas": 1,
      "avg_key_size_bytes": 32,
      "compression_ratio": 0.70,
      "headroom_pct": 0.30,
      "monthly_growth_rate": 0.08,
      "growth_horizon_months": 24,
      "tombstone_purge_days": 3,
      "estimated_tombstone_metadata_bytes": 60,
      "couchstore_disk_reserve_factor": 3.0,
      "magma_disk_reserve_factor": 2.2
    },
    "buckets": [
      {
        "name": "product_catalog",
        "documents": 50000000,
        "avg_doc_size_kib": 2.0,
        "peak_gets_per_sec": 45000,
        "peak_sets_per_sec": 3000,
        "working_set_pct": 0.90,
        "daily_deletes": 20000,
        "selected_engine": "couchstore"
      },
      {
        "name": "user_sessions",
        "documents": 200000000,
        "avg_doc_size_kib": 1.5,
        "peak_gets_per_sec": 8000,
        "peak_sets_per_sec": 12000,
        "working_set_pct": 0.30,
        "daily_deletes": 5000000,
        "selected_engine": "magma"
      },
      {
        "name": "orders",
        "documents": 10000000,
        "avg_doc_size_kib": 4.0,
        "peak_gets_per_sec": 500,
        "peak_sets_per_sec": 2000,
        "working_set_pct": 0.20,
        "daily_deletes": 50000,
        "selected_engine": "couchstore"
      }
    ]
  }
  EOFIN
  ```

> **IMPORTANTE:** Los factores de disco `3.0` y `2.2`, los 60 bytes estimados de tombstone, la compresión, el headroom y el crecimiento son supuestos del caso. No se presentan como constantes oficiales de Couchbase.
{: .lab-note .important .compact}

**Salida esperada:** El JSON debe separar `documented_couchbase_values`, `case_policies` y tres buckets; los documentos y operaciones deben sumar 260 millones y 70,500 ops/s.

- {% include step_label.html %} Valida sintaxis, documentos y throughput antes de ejecutar cualquier calculador para detectar inmediatamente un input incompleto o alterado.

  ```bash
  jq '{
      documentedValues: (.documented_couchbase_values | keys | length),
      casePolicies: (.case_policies | keys | length),
      buckets: (.buckets | length),
      documents: ([.buckets[].documents] | add),
      peakOps: ([.buckets[] | .peak_gets_per_sec + .peak_sets_per_sec] | add)
    }' models/sizing-inputs.json
  ```

**Salida esperada:** Deben aparecer `buckets: 3`, `documents: 260000000` y `peakOps: 70500`; `jq` no debe reportar errores de parseo.

### Tarea 1.3. Crear el perfil de workload

- {% include step_label.html %} Crea un perfil que calcule el porcentaje de lecturas de cada bucket y aplique umbrales pedagógicos explícitos para distinguir cargas read-heavy, write-heavy y mixtas.

  ```bash
  cat > scripts/workload_profile.py << 'PY1'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  data = json.loads((root / "models" / "sizing-inputs.json").read_text())

  total_docs = 0
  total_gets = 0
  total_sets = 0
  total_raw_gib = 0.0

  print("WORKLOAD PROFILE")
  print("=" * 88)

  for b in data["buckets"]:
      gets = b["peak_gets_per_sec"]
      sets = b["peak_sets_per_sec"]
      ops = gets + sets
      read_pct = gets / ops if ops else 0

      if read_pct > 0.80:
          profile = "Read-Heavy"
      elif (1 - read_pct) > 0.60:
          profile = "Write-Heavy"
      else:
          profile = "Mixed"

      raw_gib = (
          b["documents"] * b["avg_doc_size_kib"] * 1024
      ) / (1024 ** 3)

      print(
          f"{b['name']:<18} docs={b['documents']:>11,} "
          f"raw={raw_gib:>7.1f} GiB ops={ops:>6,}/s "
          f"reads={read_pct*100:>5.1f}% profile={profile}"
      )

      total_docs += b["documents"]
      total_gets += gets
      total_sets += sets
      total_raw_gib += raw_gib

  print()
  print(f"Total documents : {total_docs:,}")
  print(f"Total raw       : {total_raw_gib:.1f} GiB")
  print(f"Peak GET/s      : {total_gets:,}")
  print(f"Peak SET/s      : {total_sets:,}")
  print(f"Peak operations : {total_gets + total_sets:,}/s")
  PY1
  ```

**Salida esperada:** El script debe clasificar `product_catalog` como read-heavy, `orders` como write-heavy y `user_sessions` como mixed con los umbrales declarados.

- {% include step_label.html %} Ejecuta el perfil y guarda la salida para utilizarla como evidencia del workload que alimentará las decisiones de sizing posteriores.

  ```bash
  python scripts/workload_profile.py \
    | tee outputs/workload-profile.txt
  ```

**Salida esperada:** El reporte debe totalizar `260,000,000` documentos, `53,500` GET/s, `17,000` SET/s y `70,500` operaciones por segundo.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 🧠 Tarea 2. Calcular RAM del Data Service — 12 min

### Tarea 2.1. Comprender el modelo

La guía de sizing de Couchbase utiliza `56 bytes` de metadata por documento, `25%` de overhead y un high-water mark de `85%` en su ejemplo de cálculo. En esta práctica el `compression_ratio=0.70` se conserva como supuesto adicional del caso.

```text
copies = 1 + replicas

metadata =
documents × (metadata_per_document + avg_key_size) × copies

compressed_dataset =
documents × avg_document_size × compression_ratio × copies

working_set =
compressed_dataset × working_set_pct

RAM quota =
(metadata + working_set) × (1 + overhead) ÷ high_water_mark
```

### Tarea 2.2. Crear el calculador

- {% include step_label.html %} Crea un calculador por bucket que aplique replicas, metadata, working set, overhead y HWM y agregue el headroom del caso únicamente después de obtener la quota.

  ```bash
  cat > scripts/data_ram_sizing.py << 'PY2'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  config = json.loads((root / "models" / "sizing-inputs.json").read_text())
  cb = config["documented_couchbase_values"]
  policy = config["case_policies"]

  copies = 1 + policy["replicas"]
  rows = []
  total_ram = 0.0

  for b in config["buckets"]:
      docs = b["documents"]
      doc_bytes = b["avg_doc_size_kib"] * 1024

      metadata_bytes = docs * (
          cb["metadata_per_document_bytes"] + policy["avg_key_size_bytes"]
      ) * copies

      dataset_bytes = (
          docs
          * doc_bytes
          * policy["compression_ratio"]
          * copies
      )

      working_set_bytes = dataset_bytes * b["working_set_pct"]

      quota_bytes = (
          (metadata_bytes + working_set_bytes)
          * (1 + cb["ram_overhead_pct"])
          / cb["high_water_mark"]
      )

      quota_gib = quota_bytes / (1024 ** 3)
      total_ram += quota_gib

      rows.append({
          "bucket": b["name"],
          "metadata_gib": metadata_bytes / (1024 ** 3),
          "compressed_dataset_with_replica_gib": dataset_bytes / (1024 ** 3),
          "working_set_gib": working_set_bytes / (1024 ** 3),
          "ram_quota_gib": quota_gib
      })

  total_with_headroom = total_ram * (1 + policy["headroom_pct"])

  print("DATA SERVICE RAM SIZING")
  print("=" * 88)

  for row in rows:
      print(
          f"{row['bucket']:<18} "
          f"metadata={row['metadata_gib']:>6.1f} GiB "
          f"dataset={row['compressed_dataset_with_replica_gib']:>7.1f} GiB "
          f"working_set={row['working_set_gib']:>7.1f} GiB "
          f"quota={row['ram_quota_gib']:>7.1f} GiB"
      )

  print()
  print(f"Total RAM quota          : {total_ram:.1f} GiB")
  print(f"Headroom policy          : {policy['headroom_pct']*100:.0f}%")
  print(f"RAM with headroom        : {total_with_headroom:.1f} GiB")

  output = {
      "buckets": rows,
      "total_ram_quota_gib": total_ram,
      "total_ram_with_headroom_gib": total_with_headroom
  }

  (root / "outputs" / "data-ram-sizing.json").write_text(
      json.dumps(output, indent=2)
  )
  PY2
  ```

**Salida esperada:** El script debe generar una quota por bucket, sumar la necesidad del Data Service y escribir `outputs/data-ram-sizing.json` con valores numéricos positivos.

- {% include step_label.html %} Ejecuta el cálculo y conserva tanto el reporte humano como el JSON estructurado para reutilizarlos en los escenarios MDS y en la simulación de crecimiento.

  ```bash
  python scripts/data_ram_sizing.py \
    | tee outputs/data-ram-sizing.txt
  ```

**Salida esperada:** El resultado debe ser aproximadamente `431.8 GiB` de quota antes del margen y `561.3 GiB` después de aplicar el headroom de 30% del caso.

### Tarea 2.3. Interpretar el resultado

- {% include step_label.html %} Ordena los buckets por quota RAM para identificar cuál domina la demanda y relacionar ese resultado con documentos, replicas y working set.

  ```bash
  jq '{
      totalRamQuotaGiB: .total_ram_quota_gib,
      totalWithHeadroomGiB: .total_ram_with_headroom_gib,
      bucketsByRam:
        (.buckets | sort_by(.ram_quota_gib) | reverse)
    }' outputs/data-ram-sizing.json
  ```

**Salida esperada:** `user_sessions` y `product_catalog` deben concentrar la mayor parte de la quota; el total con headroom debe permanecer cercano a `561.3 GiB`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}

---

## 💾 Tarea 3. Modelar almacenamiento Couchstore y Magma — 10 min

### Tarea 3.1. Definir el modelo de disco

La documentación de Couchbase no establece `3.0` para Couchstore ni `2.2` para Magma como multiplicadores universales de disco. En esta práctica se conservan exclusivamente como **factores de reserva del caso** para comparar escenarios y deben sustituirse por mediciones de fragmentación, compaction y benchmark en un diseño real.

```text
copies = 1 + replicas

live_logical_storage =
(
  compressed_values
  + document_keys
  + metadata
) × copies

tombstones =
daily_deletes × purge_days
× (key_size + estimated_tombstone_metadata)
× copies

case_disk_model =
(live_logical_storage + tombstones)
× case_engine_reserve_factor
```

### Tarea 3.2. Crear el calculador

- {% include step_label.html %} Crea un modelo que replique valores, keys, metadata y tombstones y aplique después el factor pedagógico de reserva correspondiente a cada engine.

  ```bash
  cat > scripts/data_disk_sizing.py << 'PY3'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  config = json.loads((root / "models" / "sizing-inputs.json").read_text())

  cb = config["documented_couchbase_values"]
  policy = config["case_policies"]

  copies = 1 + policy["replicas"]
  purge_days = policy["tombstone_purge_days"]

  engine_factors = {
      "couchstore": policy["couchstore_disk_reserve_factor"],
      "magma": policy["magma_disk_reserve_factor"],
  }

  results = []

  for b in config["buckets"]:
      docs = b["documents"]
      doc_bytes = b["avg_doc_size_kib"] * 1024
      key_bytes = policy["avg_key_size_bytes"]

      compressed_values = (
          docs
          * doc_bytes
          * policy["compression_ratio"]
          * copies
      )

      keys_and_metadata = (
          docs
          * (key_bytes + cb["metadata_per_document_bytes"])
          * copies
      )

      tombstones = (
          b["daily_deletes"]
          * purge_days
          * (
              key_bytes
              + policy["estimated_tombstone_metadata_bytes"]
          )
          * copies
      )

      logical = compressed_values + keys_and_metadata + tombstones

      couchstore = (
          logical
          * engine_factors["couchstore"]
      )

      magma = (
          logical
          * engine_factors["magma"]
      )

      results.append({
          "bucket": b["name"],
          "logical_with_replica_gib": logical / (1024 ** 3),
          "tombstones_gib": tombstones / (1024 ** 3),
          "couchstore_case_model_gib": couchstore / (1024 ** 3),
          "magma_case_model_gib": magma / (1024 ** 3),
          "selected_engine": b["selected_engine"]
      })

  print("DATA SERVICE DISK CASE MODEL")
  print("=" * 96)

  for row in results:
      print(
          f"{row['bucket']:<18} "
          f"logical={row['logical_with_replica_gib']:>7.1f} GiB "
          f"tomb={row['tombstones_gib']:>6.2f} GiB "
          f"couchstore={row['couchstore_case_model_gib']:>8.1f} GiB "
          f"magma={row['magma_case_model_gib']:>8.1f} GiB "
          f"selected={row['selected_engine']}"
      )

  (root / "outputs" / "data-disk-sizing.json").write_text(
      json.dumps(results, indent=2)
  )
  PY3
  ```

**Salida esperada:** El script debe calcular almacenamiento lógico con réplica y comparar ambos factores del caso sin etiquetar esos factores como constantes oficiales de Couchbase.

- {% include step_label.html %} Ejecuta el modelo y guarda los resultados para utilizar el engine seleccionado de cada bucket en la simulación de capacidad posterior.

  ```bash
  python scripts/data_disk_sizing.py \
    | tee outputs/data-disk-sizing.txt
  ```

**Salida esperada:** Deben generarse resultados para los tres buckets y `outputs/data-disk-sizing.json`; con los supuestos actuales el engine seleccionado suma alrededor de `1.55 TiB`.

### Tarea 3.3. Justificar la selección del caso

| Bucket | Selección del caso | Interpretación |
|---|---|---|
| `product_catalog` | Couchstore | Working set de 90%; el caso prioriza reads y alta residencia |
| `user_sessions` | Magma | 200M documentos, mayor churn y presión futura de data-to-memory; requiere benchmark |
| `orders` | Couchstore | Dataset inicial menor y working set controlado; revisar conforme crezca |

> **NOTA:** Couchbase 7.6 documenta un memory-to-data ratio recomendado mínimo de 10% para Couchstore y un mínimo de 1% para Magma. La selección concreta debe validarse con tamaño por nodo, I/O, latencia y carga real.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## ⚙️ Tarea 4. Dimensionar Query e Index Service — 10 min

### Tarea 4.1. Dimensionar Query mediante concurrencia

El caso define `2,000 QPS` SQL++ y `20 ms` de latencia media objetivo. Por Little's Law:

```text
concurrency ≈ QPS × latency_seconds
            ≈ 2,000 × 0.020
            ≈ 40 consultas concurrentes
```

La guía de Couchbase 7.6 indica que la cantidad de queries procesadas simultáneamente puede aproximarse como `CPU_cores × 4`. El 30% adicional sigue siendo una política del caso.

- {% include step_label.html %} Calcula cores a partir de la concurrencia, aplica el factor documentado de cuatro queries concurrentes por core y agrega el headroom antes de repartir entre dos nodos HA.

  ```bash
  cat > scripts/query_sizing.py << 'PY4A'
  import json
  import math
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  config = json.loads((root / "models" / "sizing-inputs.json").read_text())

  peak_qps = 2000
  target_avg_latency_ms = 20
  queries_per_core = config["documented_couchbase_values"]["query_concurrency_per_core"]
  headroom = config["case_policies"]["headroom_pct"]
  ha_nodes = 2

  concurrency = peak_qps * (target_avg_latency_ms / 1000)
  base_cores = math.ceil(concurrency / queries_per_core)
  cores_with_headroom = math.ceil(base_cores * (1 + headroom))
  cores_per_node = math.ceil(cores_with_headroom / ha_nodes)

  print("QUERY SERVICE SIZING")
  print("=" * 72)
  print(f"Peak QPS                  : {peak_qps:,}")
  print(f"Latency target            : {target_avg_latency_ms} ms")
  print(f"Estimated concurrency     : {concurrency:.1f}")
  print(f"Queries/core approximation: {queries_per_core}")
  print(f"Base cores                : {base_cores}")
  print(f"Cores with headroom       : {cores_with_headroom}")
  print(f"HA nodes                  : {ha_nodes}")
  print(f"Modeled cores/node        : {cores_per_node}")
  print("Benchmark required before production.")
  PY4A
  ```
  ```bash
  python scripts/query_sizing.py \
    | tee outputs/query-sizing.txt
  ```

**Salida esperada:** El modelo debe obtener `40` consultas concurrentes, `10` cores base, `13` con headroom y `7` cores modelados por nodo al repartir entre dos nodos.

### Tarea 4.2. Dimensionar Index mediante entries y Plasma

- {% include step_label.html %} Define DocumentID, secondary-key size, número de índices y working set por bucket para aplicar el modelo Plasma de la guía con inputs trazables.

  ```bash
  cat > models/index-inputs.json << 'EOFIDX'
  {
    "avg_document_id_bytes": 32,
    "buckets": [
      {
        "bucket": "product_catalog",
        "documents": 50000000,
        "indexes": 5,
        "avg_secondary_key_bytes": 48,
        "working_set_pct": 0.70
      },
      {
        "bucket": "user_sessions",
        "documents": 200000000,
        "indexes": 4,
        "avg_secondary_key_bytes": 32,
        "working_set_pct": 0.30
      },
      {
        "bucket": "orders",
        "documents": 10000000,
        "indexes": 6,
        "avg_secondary_key_bytes": 64,
        "working_set_pct": 0.50
      }
    ]
  }
  EOFIDX
  ```

**Salida esperada:** El archivo debe contener tres buckets, `15` índices en total, tamaños explícitos de secondary key y porcentajes de working set sin una regla fija de RAM por índice.

- {% include step_label.html %} Crea el cálculo Plasma utilizando metadata back+main de la guía, factor de almacenamiento secundario y memoria basada en el working set del índice.

  ```bash
  cat > scripts/index_sizing.py << 'PY4B'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  inputs = json.loads((root / "models" / "index-inputs.json").read_text())
  config = json.loads((root / "models" / "sizing-inputs.json").read_text())

  cb = config["documented_couchbase_values"]
  overhead = cb["ram_overhead_pct"]

  document_id = inputs["avg_document_id_bytes"]
  metadata_per_entry = (
      cb["plasma_metadata_back_index_bytes"]
      + cb["plasma_metadata_main_index_bytes"]
  )
  plasma_storage_factor = cb["plasma_secondary_index_storage_factor"]

  total_ram = 0.0
  total_storage = 0.0

  print("INDEX SERVICE - PLASMA CAPACITY MODEL")
  print("=" * 96)

  for item in inputs["buckets"]:
      entries = item["documents"] * item["indexes"]

      bytes_per_entry = (
          document_id
          + item["avg_secondary_key_bytes"]
          + metadata_per_entry
      )

      base_index_bytes = entries * bytes_per_entry

      plasma_storage_bytes = (
          base_index_bytes
          * plasma_storage_factor
      )

      ram_bytes = (
          base_index_bytes
          * (1 + overhead)
          * item["working_set_pct"]
      )

      ram_gib = ram_bytes / (1024 ** 3)
      storage_gib = plasma_storage_bytes / (1024 ** 3)

      total_ram += ram_gib
      total_storage += storage_gib

      print(
          f"{item['bucket']:<18} "
          f"entries={entries:>12,} "
          f"bytes/entry={bytes_per_entry:>3} "
          f"plasma-storage={storage_gib:>8.1f} GiB "
          f"ram-model={ram_gib:>7.1f} GiB"
      )

  print()
  print(f"Total modeled Plasma storage: {total_storage:.1f} GiB")
  print(f"Total modeled Index RAM     : {total_ram:.1f} GiB")
  print("Partitioning distributes an index; num_replica creates index copies.")
  PY4B
  ```
  ```bash
  python scripts/index_sizing.py \
    | tee outputs/index-sizing.txt
  ```

> **IMPORTANTE:** La guía de Couchbase utiliza metadata y tamaño de entradas; esta práctica no emplea reglas ficticias como “2 GB por índice”.
{: .lab-note .important .compact}

**Salida esperada:** El reporte debe calcular entries, bytes por entrada, almacenamiento Plasma y RAM de working set para cada bucket y producir totales reproducibles.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---

## 🔍 Tarea 5. Dimensionar Search, Analytics y Eventing — 8 min

### Tarea 5.1. Definir inputs especializados

- {% include step_label.html %} Crea drivers explícitos de Search, Analytics y Eventing y marca cuáles son inputs del caso para evitar convertir tamaños o throughput sintéticos en fórmulas universales.

  ```bash
  cat > models/specialized-services.json << 'EOFSPEC'
  {
    "search": {
      "estimated_fts_index_gib": 50,
      "peak_queries_per_sec": 100,
      "ha_nodes": 2,
      "notes": "El tamaño FTS es input del caso y depende de mapping, analyzer, stored fields y term vectors."
    },
    "analytics": {
      "shadow_data_gib": 350,
      "concurrent_queries": 20,
      "ha_nodes": 2,
      "notes": "El modelo aplica el factor temporal típico 2x documentado en la guía de sizing 7.6."
    },
    "eventing": {
      "functions": 6,
      "peak_mutations_per_sec": 17000,
      "workers_per_function": 3,
      "starting_vcpu_per_node": 8,
      "ha_nodes": 2,
      "notes": "Mutations y workers son inputs del caso; Couchbase indica que 8 vCPU es un buen punto inicial para algunas Functions."
    }
  }
  EOFSPEC
  ```

**Salida esperada:** El archivo debe registrar FTS, shadow data, concurrencia, mutaciones, workers y HA sin afirmar throughput por core para Search o Eventing.

### Tarea 5.2. Generar drivers de capacidad

- {% include step_label.html %} Calcula únicamente el temporary disk de Analytics mediante el factor típico 2x documentado y presenta Search y Eventing como drivers que requieren benchmark.

  ```bash
  cat > scripts/specialized_services_sizing.py << 'PY5'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent

  services = json.loads(
      (root / "models" / "specialized-services.json").read_text()
  )

  config = json.loads(
      (root / "models" / "sizing-inputs.json").read_text()
  )

  search = services["search"]
  analytics = services["analytics"]
  eventing = services["eventing"]

  analytics_factor = (
      config["documented_couchbase_values"]
      ["analytics_typical_temp_disk_factor"]
  )

  analytics_temp_disk = (
      analytics["shadow_data_gib"]
      * analytics_factor
  )

  print("SPECIALIZED SERVICES CAPACITY DRIVERS")
  print("=" * 82)

  print("\nSEARCH")
  print(f"Estimated FTS index     : {search['estimated_fts_index_gib']} GiB")
  print(f"Peak Search QPS         : {search['peak_queries_per_sec']}")
  print(f"HA nodes                : {search['ha_nodes']}")
  print(f"Notes                   : {search['notes']}")

  print("\nANALYTICS")
  print(f"Shadow data             : {analytics['shadow_data_gib']} GiB")
  print(f"Concurrent queries      : {analytics['concurrent_queries']}")
  print(f"Typical temp factor     : {analytics_factor:.1f}x")
  print(f"Temporary disk model    : {analytics_temp_disk:.0f} GiB")
  print(f"HA nodes                : {analytics['ha_nodes']}")
  print(f"Notes                   : {analytics['notes']}")

  print("\nEVENTING")
  print(f"Functions               : {eventing['functions']}")
  print(f"Peak mutations          : {eventing['peak_mutations_per_sec']:,}/s")
  print(f"Workers/function        : {eventing['workers_per_function']}")
  print(f"Starting vCPU/node      : {eventing['starting_vcpu_per_node']}")
  print(f"HA nodes                : {eventing['ha_nodes']}")
  print(f"Notes                   : {eventing['notes']}")
  PY5
  ```
  ```bash
  python scripts/specialized_services_sizing.py \
    | tee outputs/specialized-services-sizing.txt
  ```

**Salida esperada:** Analytics debe mostrar `700 GiB` de temporary disk model; Search y Eventing deben permanecer expresados como drivers que necesitan validación de carga.

### Tarea 5.3. Registrar decisiones MDS

| Servicio | Driver principal | Decisión inicial del caso |
|---|---|---|
| Search | tamaño FTS + QPS | dos nodos si el servicio es crítico |
| Analytics | shadow data + temp disk + concurrencia | aislar de OLTP |
| Eventing | mutations/s + Functions + workers | iniciar con dos nodos y benchmark |
| Query | concurrencia + target latency | separar de Data ante contención CPU |
| Index | entries + key sizes + working set | Plasma; partitioning y replicas según HA |

**Salida esperada:** La matriz debe diferenciar los drivers de cada servicio y evitar presentar una misma relación CPU/RAM como válida para todos los componentes Couchbase.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🏗️ Tarea 6. Diseñar tres escenarios MDS — 10 min

### Tarea 6.1. Crear modelo de escenarios

- {% include step_label.html %} Define tres escenarios deliberadamente distintos y conserva recursos por server class como cost drivers, sin incluir precios AWS ni presentarlos como configuraciones oficiales de Couchbase.

  ```bash
  cat > models/mds-scenarios.json << 'EOFMDS'
  {
    "scenario_a": {
      "label": "A - Subdimensionado / costo mínimo",
      "description": "Escenario deliberadamente ajustado para visualizar riesgo de capacidad y ausencia de margen N+1.",
      "classes": [
        {"name":"data","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":500,"services":["data"]},
        {"name":"query-index","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":32,"storage_gib_per_node":200,"services":["query","index"]},
        {"name":"search-eventing","nodes":1,"vcpu_per_node":8,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["fts","eventing"]},
        {"name":"analytics","nodes":1,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":700,"services":["analytics"]}
      ]
    },
    "scenario_b": {
      "label": "B - Diseño objetivo del caso",
      "description": "MDS separado, HA básica y capacidad N+1 inicial para Data según los resultados del modelo.",
      "classes": [
        {"name":"data","nodes":6,"vcpu_per_node":16,"ram_gib_per_node":128,"storage_gib_per_node":750,"services":["data"]},
        {"name":"query","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["query"]},
        {"name":"index","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":96,"storage_gib_per_node":400,"services":["index"]},
        {"name":"search","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":200,"services":["fts"]},
        {"name":"analytics","nodes":2,"vcpu_per_node":16,"ram_gib_per_node":128,"storage_gib_per_node":700,"services":["analytics"]},
        {"name":"eventing","nodes":2,"vcpu_per_node":8,"ram_gib_per_node":32,"storage_gib_per_node":100,"services":["eventing"]}
      ]
    },
    "scenario_c": {
      "label": "C - Resiliencia y crecimiento",
      "description": "Mayor capacidad y redundancia para comparar el efecto del crecimiento y de la pérdida de un nodo Data.",
      "classes": [
        {"name":"data","nodes":9,"vcpu_per_node":32,"ram_gib_per_node":256,"storage_gib_per_node":1200,"services":["data"]},
        {"name":"query","nodes":3,"vcpu_per_node":32,"ram_gib_per_node":64,"storage_gib_per_node":100,"services":["query"]},
        {"name":"index","nodes":3,"vcpu_per_node":24,"ram_gib_per_node":128,"storage_gib_per_node":600,"services":["index"]},
        {"name":"search","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":300,"services":["fts"]},
        {"name":"analytics","nodes":3,"vcpu_per_node":32,"ram_gib_per_node":192,"storage_gib_per_node":1000,"services":["analytics"]},
        {"name":"eventing","nodes":3,"vcpu_per_node":16,"ram_gib_per_node":64,"storage_gib_per_node":150,"services":["eventing"]}
      ]
    }
  }
  EOFMDS
  ```

**Salida esperada:** Deben existir exactamente tres escenarios con recursos por server class; B se identifica como diseño objetivo del caso y no como recomendación universal de Couchbase.

### Tarea 6.2. Generar comparativa de recursos

- {% include step_label.html %} Suma nodos, vCPU, RAM y almacenamiento de cada escenario para obtener cost drivers comparables sin depender de precios comerciales cambiantes.

  ```bash
  cat > scripts/mds_topology.py << 'PY6'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  data = json.loads((root / "models" / "mds-scenarios.json").read_text())

  summary = []

  for key, scenario in data.items():
      total_nodes = sum(c["nodes"] for c in scenario["classes"])
      total_vcpu = sum(
          c["nodes"] * c["vcpu_per_node"]
          for c in scenario["classes"]
      )
      total_ram = sum(
          c["nodes"] * c["ram_gib_per_node"]
          for c in scenario["classes"]
      )
      total_storage = sum(
          c["nodes"] * c["storage_gib_per_node"]
          for c in scenario["classes"]
      )

      print("\n" + "=" * 96)
      print(scenario["label"])
      print(scenario["description"])
      print("=" * 96)

      for c in scenario["classes"]:
          print(
              f"{c['name']:<16} nodes={c['nodes']:<2} "
              f"services={','.join(c['services']):<18} "
              f"vCPU/node={c['vcpu_per_node']:<3} "
              f"RAM/node={c['ram_gib_per_node']:<4} GiB "
              f"disk/node={c['storage_gib_per_node']} GiB"
          )

      print(
          f"TOTAL nodes={total_nodes} "
          f"vCPU={total_vcpu} "
          f"RAM={total_ram} GiB "
          f"storage={total_storage} GiB"
      )

      summary.append({
          "scenario": key,
          "label": scenario["label"],
          "nodes": total_nodes,
          "vcpu": total_vcpu,
          "ram_gib": total_ram,
          "storage_gib": total_storage
      })

  (root / "outputs" / "mds-summary.json").write_text(
      json.dumps(summary, indent=2)
  )
  PY6
  ```
  ```bash
  python scripts/mds_topology.py \
    | tee outputs/mds-topology.txt
  ```

> **IMPORTANTE:** Data Service no utiliza nodos “activos” y “de réplica” separados; cada Data node puede alojar vBuckets activos y réplicas según la distribución del clúster.
{: .lab-note .important .compact}

**Salida esperada:** La comparativa debe listar recursos de A, B y C y crear `outputs/mds-summary.json` con tres registros.

### Tarea 6.3. Validar capacidad inicial del escenario B

- {% include step_label.html %} Compara el Data class del escenario B con la demanda actual de RAM y disco, incluida la pérdida de un nodo, para comprobar que el nombre “objetivo” tiene respaldo cuantitativo inicial.

  ```bash
  python - << 'PY6B'
  import json
  from pathlib import Path

  root = Path.cwd()

  ram = json.loads(
      (root / "outputs" / "data-ram-sizing.json").read_text()
  )
  disk = json.loads(
      (root / "outputs" / "data-disk-sizing.json").read_text()
  )
  scenarios = json.loads(
      (root / "models" / "mds-scenarios.json").read_text()
  )

  demand_ram = ram["total_ram_with_headroom_gib"]

  demand_disk = sum(
      item["magma_case_model_gib"]
      if item["selected_engine"] == "magma"
      else item["couchstore_case_model_gib"]
      for item in disk
  )

  data_class = next(
      c
      for c in scenarios["scenario_b"]["classes"]
      if c["name"] == "data"
  )

  nodes = data_class["nodes"]
  ram_per_node = data_class["ram_gib_per_node"]
  disk_per_node = data_class["storage_gib_per_node"]

  print(f"Demand RAM             : {demand_ram:.1f} GiB")
  print(f"Demand disk            : {demand_disk:.1f} GiB")
  print(f"B Data RAM             : {nodes * ram_per_node:.1f} GiB")
  print(f"B Data disk            : {nodes * disk_per_node:.1f} GiB")
  print(f"B N+1 RAM              : {(nodes - 1) * ram_per_node:.1f} GiB")
  print(f"B N+1 disk             : {(nodes - 1) * disk_per_node:.1f} GiB")

  assert demand_ram < (nodes - 1) * ram_per_node
  assert demand_disk < (nodes - 1) * disk_per_node

  print("Escenario B soporta la demanda inicial modelada incluso con un Data node menos.")
  PY6B
  ```

**Salida esperada:** Las dos aserciones deben pasar y debe imprimirse que el escenario B soporta la demanda **inicial** modelada con un Data node menos; esto no garantiza crecimiento futuro.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---

## 🌐 Tarea 7. Validar Server Groups y Availability Zones — 6 min

### Tarea 7.1. Observar las zonas físicas

- {% include step_label.html %} Lista workers con zona e instance type para demostrar que Kubernetes dispone de tres failure domains físicos antes de relacionarlos con Server Groups.

  ```bash
  kubectl get nodes \
    -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type \
    | tee outputs/eks-zones.txt
  ```

**Salida esperada:** Deben aparecer tres workers `m6i.xlarge` y tres valores distintos en `topology.kubernetes.io/zone`, uno por cada Availability Zone del laboratorio.

### Tarea 7.2. Verificar la declaración del Operator

- {% include step_label.html %} Consulta `spec.serverGroups` y la distribución por server class para comprobar que el `CouchbaseCluster` utiliza explícitamente las tres zonas configuradas.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{
        globalServerGroups: .spec.serverGroups,
        serverClasses: [
          .spec.servers[] |
          {
            name,
            size,
            services,
            serverGroups
          }
        ]
      }' \
    | tee outputs/operator-server-groups.json
  ```

**Salida esperada:** `globalServerGroups` debe contener `us-west-2a`, `us-west-2b` y `us-west-2c`; `data-query` debe tener `size: 3` y declarar las tres zonas.

### Tarea 7.3. Consultar Server Groups efectivos de Couchbase

- {% include step_label.html %} Consulta la REST API de Server Groups para verificar que Couchbase materializó los failure domains y que cada grupo contiene al menos el Data node programado en esa zona.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/serverGroups \
    | jq '[
        .groups[] |
        {
          name,
          nodes: [
            .nodes[]? |
            {
              hostname,
              services
            }
          ]
        }
      ]' \
    | tee outputs/couchbase-server-groups.json
  ```

**Salida esperada:** El JSON debe contener tres Server Groups efectivos; la distribución puede incluir servicios adicionales, pero cada zona debe contar con un miembro Data + Query.

### Tarea 7.4. Correlacionar Pods, workers y zonas

- {% include step_label.html %} Genera un mapa Pod → worker → zona para demostrar que los tres Data + Query se encuentran físicamente distribuidos entre los failure domains declarados.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o json \
    | jq -r '.items[] | [.metadata.name,.spec.nodeName] | @tsv' \
    | tr -d '\r' \
    | while IFS=$'\t' read -r pod node; do
        zone=$(
          kubectl get node "$node" \
            -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
        )

        printf '%-22s %-55s %s\n' \
          "$pod" \
          "$node" \
          "$zone"
      done \
    | tee outputs/pod-zone-map.txt
  ```

**Salida esperada:** `pod-zone-map.txt` debe mostrar cada Pod, su worker y su AZ; los tres miembros Data + Query deben cubrir las tres zonas configuradas.

### Tarea 7.5. Documentar MDS vs Server Groups

- {% include step_label.html %} Registra por escrito la diferencia entre asignación de servicios, failure domains y replicas para evitar tratarlos como mecanismos equivalentes de alta disponibilidad.

  ```bash
  cat > outputs/mds-vs-server-groups.md << 'EOFSG'
  # MDS vs Server Groups

  ## MDS
  Define qué servicios ejecuta cada server class: Data, Query, Index, Search, Analytics y Eventing.

  ## Server Groups
  Representan failure domains lógicos y pueden alinearse con failure domains físicos, como AWS Availability Zones.

  ## En EKS
  `topology.kubernetes.io/zone` identifica la zona del worker.
  Couchbase Kubernetes Operator utiliza `spec.serverGroups` para programar Pods y asociarlos con Server Groups.

  ## Relación con replicas
  Replica count crea copias de vBuckets.
  Server Group Awareness intenta mantener vBuckets activos y sus replicas en failure domains diferentes.

  ## Regla de diseño
  Replica count no sustituye Server Groups.
  Server Groups no sustituyen capacity planning.
  MDS no sustituye high availability.
  EOFSG
  ```

**Salida esperada:** El documento debe diferenciar MDS, Server Groups, zonas físicas y replicas y describir cómo se complementan sin declararlos equivalentes.

### Tarea 7.6. Validar tres zonas y tres grupos

- {% include step_label.html %} Cuenta Availability Zones y Server Groups declarados para detener la práctica si cualquiera de los dos niveles no contiene exactamente tres failure domains.

  ```bash
  ZONES=$(
    kubectl get nodes \
      -o json \
    | jq -r '
        [
          .items[].metadata.labels["topology.kubernetes.io/zone"]
        ]
        | map(select(. != null))
        | unique
        | length
      '
  )

  SERVER_GROUPS=$(
    kubectl get couchbasecluster "$CB_CLUSTER" \
      -n "$CB_NAMESPACE" \
      -o json \
    | jq -r '
        (.spec.serverGroups // [])
        | unique
        | length
      '
  )

  echo "Availability Zones: $ZONES"
  echo "Operator Server Groups: $SERVER_GROUPS"

  if [[ "$ZONES" -eq 3 && "$SERVER_GROUPS" -eq 3 ]]; then
    echo "Tres failure domains físicos y lógicos validados."
  else
    echo "ERROR: la topología no contiene tres zonas y tres Server Groups."
  fi
  ```

**Salida esperada:** Debe imprimirse `Availability Zones: 3`, `Operator Server Groups: 3` y `Tres failure domains físicos y lógicos validados.`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

--- 

## 📈 Tarea 8. Simular crecimiento y capacidad N+1 — 7 min

### Tarea 8.1. Definir el modelo transparente

El simulador proyecta el supuesto agresivo de crecimiento mensual y calcula cuatro ratios para el Data Service:

```text
RAM ratio
disk ratio
N+1 RAM ratio
N+1 disk ratio
```

El mayor ratio se utiliza únicamente como indicador pedagógico:

```text
LOW    < 0.70
MEDIUM < 0.90
HIGH   >= 0.90
```

### Tarea 8.2. Crear y ejecutar el simulador

- {% include step_label.html %} Crea un simulador que proyecte la demanda de RAM y disco, incluya pérdida de un Data node y evalúe todos los escenarios en los meses 0, 6, 12, 18 y 24.

  ```bash
  cat > scripts/capacity_simulator.py << 'PY8'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent

  inputs = json.loads(
      (root / "models" / "sizing-inputs.json").read_text()
  )
  scenarios = json.loads(
      (root / "models" / "mds-scenarios.json").read_text()
  )
  ram = json.loads(
      (root / "outputs" / "data-ram-sizing.json").read_text()
  )
  disk = json.loads(
      (root / "outputs" / "data-disk-sizing.json").read_text()
  )

  growth = inputs["case_policies"]["monthly_growth_rate"]
  horizon = inputs["case_policies"]["growth_horizon_months"]

  current_ram = ram["total_ram_with_headroom_gib"]

  selected_disk = sum(
      item["magma_case_model_gib"]
      if item["selected_engine"] == "magma"
      else item["couchstore_case_model_gib"]
      for item in disk
  )

  months = [0, 6, 12, 18, horizon]

  print("CAPACITY SIMULATOR")
  print("=" * 116)
  print(
      f"Growth assumption: {growth*100:.0f}% monthly "
      f"(aggressive case assumption)"
  )

  for month in months:
      factor = (1 + growth) ** month
      demand_ram = current_ram * factor
      demand_disk = selected_disk * factor

      print(f"\nMONTH {month} growth_factor={factor:.2f}")

      for scenario in scenarios.values():
          data_class = next(
              c
              for c in scenario["classes"]
              if c["name"] == "data"
          )

          nodes = data_class["nodes"]
          ram_per_node = data_class["ram_gib_per_node"]
          disk_per_node = data_class["storage_gib_per_node"]

          total_ram = nodes * ram_per_node
          total_disk = nodes * disk_per_node

          n1_nodes = max(nodes - 1, 1)
          n1_ram = n1_nodes * ram_per_node
          n1_disk = n1_nodes * disk_per_node

          ram_ratio = demand_ram / total_ram
          disk_ratio = demand_disk / total_disk
          n1_ram_ratio = demand_ram / n1_ram
          n1_disk_ratio = demand_disk / n1_disk

          worst = max(
              ram_ratio,
              disk_ratio,
              n1_ram_ratio,
              n1_disk_ratio
          )

          if worst < 0.70:
              state = "LOW"
          elif worst < 0.90:
              state = "MEDIUM"
          else:
              state = "HIGH"

          print(
              f"{scenario['label']:<36} "
              f"RAM={ram_ratio:>5.2f} "
              f"DISK={disk_ratio:>5.2f} "
              f"N+1_RAM={n1_ram_ratio:>5.2f} "
              f"N+1_DISK={n1_disk_ratio:>5.2f} "
              f"state={state}"
          )
  PY8
  ```
  ```bash
  python scripts/capacity_simulator.py \
    | tee outputs/capacity-simulation.txt
  ```

> **NOTA:** LOW, MEDIUM y HIGH no son estados de Couchbase ni predicciones de SLA; únicamente comparan la demanda modelada con la capacidad declarada en los escenarios.
{: .lab-note .info .compact}

**Salida esperada:** El reporte debe mostrar cinco periodos, cuatro ratios por escenario y evidenciar cuándo el crecimiento supera capacidad normal o N+1 sin afirmar una fecha productiva de saturación.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

## 📊 Tarea 9. Consultar métricas reales del clúster EKS — 4 min

El clúster real no valida el sizing empresarial; sirve para demostrar cómo obtener señales que alimentarían una revisión de capacidad. En Couchbase 7.6 el endpoint REST de estadísticas del bucket continúa disponible.

### Tarea 9.1. Capturar estadísticas del bucket

- {% include step_label.html %} Consulta las series del bucket y extrae últimas muestras no nulas de métricas documentadas para evitar que los primeros valores `null` oculten el estado observado.

  ```bash
  curl -fsS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/travel-sample/stats \
    | jq '
        def last_non_null(name):
          (.op.samples[name] // [])
          | map(select(. != null))
          | if length > 0 then .[-1] else null end;

        {
          get_hits: last_non_null("get_hits"),
          get_misses: last_non_null("get_misses"),
          ep_bg_fetched: last_non_null("ep_bg_fetched"),
          ep_resident_items_rate: last_non_null("ep_resident_items_rate"),
          ep_queue_size: last_non_null("ep_queue_size"),
          mem_used: last_non_null("mem_used"),
          curr_items: last_non_null("curr_items")
        }
      ' \
    | tee metrics/travel-sample-stats.json
  ```

**Salida esperada:** `travel-sample-stats.json` debe contener las siete claves seleccionadas; algunas pueden valer `0`, pero el comando no debe fallar por series ausentes o muestras iniciales nulas.

### Tarea 9.2. Interpretar correctamente las señales

- {% include step_label.html %} Crea un lector que describa background fetches, residencia, queue, memoria e items sin convertir una sola muestra en una conclusión de capacidad.

  ```bash
  cat > scripts/measure_real_cluster.py << 'PY9'
  import json
  from pathlib import Path

  root = Path(__file__).resolve().parent.parent
  data = json.loads(
      (root / "metrics" / "travel-sample-stats.json").read_text()
  )

  print("REAL CLUSTER OBSERVATION")
  print("=" * 76)
  print(f"GET hits sample           : {data.get('get_hits')}")
  print(f"GET misses sample         : {data.get('get_misses')}")
  print(f"items fetched from disk   : {data.get('ep_bg_fetched')}")
  print(f"resident items rate       : {data.get('ep_resident_items_rate')}")
  print(f"disk queue size sample    : {data.get('ep_queue_size')}")
  print(f"memory used sample        : {data.get('mem_used')}")
  print(f"current items sample      : {data.get('curr_items')}")
  print()
  print(
      "These samples validate observability; "
      "they do not validate the 260M-document capacity model."
  )
  PY9
  ```
  ```bash
  python scripts/measure_real_cluster.py \
    | tee outputs/real-cluster-observation.txt
  ```

**Salida esperada:** El lector debe identificar `ep_bg_fetched` como items recuperados desde disco y separar la observación real del modelo de 260 millones de documentos.

- {% include step_label.html %} Captura CPU y memoria actuales de los Pods para conservar una referencia Kubernetes del entorno reducido en el mismo momento de la observación.

  ```bash
  kubectl top pods \
    -n "$CB_NAMESPACE" \
    | tee metrics/kubernetes-pod-usage.txt
  ```

**Salida esperada:** `kubectl top` debe listar CPU y memoria de los Pods del namespace y guardar la muestra en `metrics/kubernetes-pod-usage.txt`; un error indicaría que Metrics Server aún no está disponible.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

## ✅ Tarea 10. Validar y generar dossier final — 3 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea una suite estructural que compruebe inputs, artefactos, resultados numéricos, tres escenarios, tres zonas y tres Server Groups antes de generar el dossier.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab7/validate.sh
  ```

**Salida esperada:** `validate.sh` debe comprobar documentos, throughput, RAM, disco, escenarios, zonas, Server Groups, Data + Query, simulación y métricas mediante condiciones objetivas.

- {% include step_label.html %} Valida la sintaxis del script, ejecútalo y conserva la salida completa; cualquier `FAIL` debe corregirse antes de consolidar el dossier final.

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh

  ./scripts/validate.sh \
    | tee outputs/validation-final.txt
  ```

**Salida esperada:** `bash -n` no debe producir salida y la ejecución debe terminar con `RESULTADO: <n> PASS / 0 FAIL`.

### Tarea 10.2. Generar dossier

- {% include step_label.html %} Consolida perfiles, cálculos, topología, simulación, Server Groups, métricas y validación en un único Markdown que permanezca disponible después de eliminar EKS.

  ```bash
  {
    echo "# DOSSIER FINAL - LAB 7"
    echo
    echo "## Workload"
    cat outputs/workload-profile.txt
    echo
    echo "## Data RAM"
    cat outputs/data-ram-sizing.txt
    echo
    echo "## Data Disk"
    cat outputs/data-disk-sizing.txt
    echo
    echo "## Query"
    cat outputs/query-sizing.txt
    echo
    echo "## Index"
    cat outputs/index-sizing.txt
    echo
    echo "## Specialized services"
    cat outputs/specialized-services-sizing.txt
    echo
    echo "## MDS"
    cat outputs/mds-topology.txt
    echo
    echo "## Server Groups"
    cat outputs/couchbase-server-groups.json
    echo
    echo "## Pod to Zone map"
    cat outputs/pod-zone-map.txt
    echo
    echo "## Capacity simulation"
    cat outputs/capacity-simulation.txt
    echo
    echo "## Real cluster observation"
    cat outputs/real-cluster-observation.txt
    echo
    echo "## Validation"
    cat outputs/validation-final.txt
  } | tee outputs/final-sizing-dossier.md
  ```

**Salida esperada:** `outputs/final-sizing-dossier.md` debe reunir todos los entregables principales y conservar las evidencias de Server Groups y observabilidad además de los cálculos.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

- {% include step_label.html %} Conserva los modelos, scripts, métricas y reportes porque constituyen los entregables principales del laboratorio y confirma el resultado esperado.

  ```bash
  find models outputs metrics scripts \
    -maxdepth 1 \
    -type f \
    | sort
  ```

\> **NOTA:** `travel-sample` no se elimina porque la práctica no lo modifica destructivamente y puede reutilizarse en laboratorios posteriores.
{: .lab-note .info .compact}

**Salida esperada:** La lista ordenada debe incluir modelos, scripts, métricas y reportes del laboratorio, confirmando que los entregables permanecen disponibles.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Detén con `Ctrl+C` el port-forward de 8091 para liberar el puerto local y evitar conexiones activas mientras se elimina la infraestructura EKS.

**Salida esperada:** El proceso debe finalizar y devolver el prompt de Git Bash; el puerto local 8091 ya no debe conservar un túnel hacia el Service de Couchbase.

- {% include step_label.html %} Ejecuta la acción `delete` del script de ciclo de vida para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  cd /c/LABS/couchbase-nosql/lab7
  source lab.env
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe completar la eliminación del control plane, nodegroup y recursos administrados sin dejar el clúster registrado en la región.

- {% include step_label.html %} Confirma que AWS ya no pueda describir el clúster para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:** AWS debe responder `ResourceNotFoundException`, confirmando que el plano de control del clúster ya no existe en la región configurada.

  ```text
  ResourceNotFoundException
  ```