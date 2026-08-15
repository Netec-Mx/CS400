---
layout: lab
title: "Práctica 6: Implementación de seguridad en un entorno productivo"
permalink: /lab6/lab6/
images_base: /labs/lab6/img
duration: "84 minutos"
objective:
  - Evaluar la superficie de exposición inicial de Couchbase Server Enterprise 7.6.2 sobre Amazon EKS y documentar una línea base.
  - Diseñar un modelo RBAC granular por collection con cuentas de servicio diferenciadas y validar autenticación y autorización.
  - Crear una CA privada y certificados X.509 con OpenSSL, almacenarlos como Kubernetes Secrets y habilitar Managed TLS mediante Couchbase Kubernetes Operator.
  - Habilitar cifrado completo entre nodos mediante nodeToNodeEncryption=All y verificar administración y Query Service sobre TLS.
  - Configurar autenticación de clientes mediante certificados X.509 y preparar una identidad X.509 administrativa para que Couchbase Kubernetes Operator conserve acceso durante la reconciliación.
  - Habilitar auditoría, descubrir dinámicamente eventos auditables de Couchbase 7.6 y consolidar audit.log desde todos los Pods.
  - Aplicar medidas de hardening relacionadas con TLS, secretos, exposición de servicios y retención de auditoría.
  - Comparar la postura inicial y final mediante una matriz documentada y una suite de validación reproducible.
prerequisites:
  - Tener una cuenta AWS con permisos para Amazon EKS, EC2, VPC, IAM, CloudFormation y Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2, eksctl 0.215.0 o superior, kubectl, Helm 3, curl, jq y OpenSSL disponibles desde Git Bash.
  - Comprender TLS, PKI, certificados X.509, CA, SAN, autenticación, autorización y RBAC.
  - Conocer operaciones básicas SQL++, KV y administración de Couchbase Server.
introduction:
  - En esta práctica transformarás una instalación Couchbase operativa sobre Amazon EKS en un entorno con controles de seguridad representativos de una postura productiva. Crearás identidades RBAC con menor privilegio, generarás una PKI privada y migrarás el clúster a Managed TLS mediante Kubernetes Secrets y Couchbase Kubernetes Operator. Después habilitarás autenticación X.509 de clientes, auditoría por nodo y cifrado completo entre miembros del clúster. La práctica no certifica cumplimiento normativo; demuestra controles técnicos reproducibles de defensa en profundidad, menor privilegio y auditabilidad.
slug: lab6
lab_number: 6
final_result: >
  Al finalizar la práctica habrás documentado la superficie inicial del clúster, creado una collection aislada para pruebas de autorización, implementado cuentas de servicio con privilegios mínimos, preparado certificados X.509 de servidor y de administración para el Operator, habilitado Managed TLS y client certificate authentication de forma declarativa, configurado cifrado completo entre nodos, autenticado un cliente mediante X.509, habilitado y analizado auditoría consolidada desde todos los Pods y generado una matriz de postura final con evidencias locales.
notes:
  - Los 84 minutos corresponden únicamente a tareas funcionales de seguridad de Couchbase. La creación y eliminación de Amazon EKS quedan fuera del tiempo.
  - Todos los comandos locales deben ejecutarse desde Git Bash integrado en Visual Studio Code.
  - La práctica utiliza Couchbase Server Enterprise 7.6.2 y Couchbase Kubernetes Operator 2.92.0.
  - La topología utiliza dos Pods Data + Query, un Pod Index + Search y un Pod Analytics + Eventing sobre tres workers m6i.xlarge.
  - No se utiliza SSH ni SCP hacia Pods. Los certificados se entregan mediante Kubernetes Secrets y el Operator administra su aplicación.
  - Las IP de Pods son efímeras y nunca se incluyen como identidad permanente en certificados X.509.
  - El estado de client certificate permanece en enable; el Operator recibe un certificado con CN Administrator antes de activar la política y mandatory se explica pero no se fuerza.
  - nodeToNodeEncryption se configura en All para cifrar control y datos entre nodos.
  - La auditoría de Couchbase es por nodo; la práctica consolida audit.log desde todos los Pods.
references:
  - text: Conceptos de TLS en Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/concept-tls.html
  - text: Configuración de TLS con Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/howto-tls.html
  - text: Tutorial de TLS con Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/tutorial-tls.html
  - text: Roles y permisos de seguridad en Couchbase Server
    url: https://docs.couchbase.com/server/7.6/learn/security/roles.html
  - text: Configuración de autenticación mediante certificados de cliente
    url: https://docs.couchbase.com/server/7.6/manage/manage-security/enable-client-certificate-handling.html
  - text: Autenticación mediante certificados cliente con Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/howto-tls-client-certificates.html
  - text: API REST para configuración de auditoría en Couchbase Server
    url: https://docs.couchbase.com/server/7.6/rest-api/rest-auditing.html
  - text: Configuración de cifrado entre nodos en Couchbase Server
    url: https://docs.couchbase.com/server/current/manage/manage-nodes/apply-node-to-node-encryption.html
prev: /lab5/lab5/
next: /lab7/lab7/
---

--- 

> **IMPORTANTE:** Ejecuta los bloques `bash` desde Git Bash en Visual Studio Code; PowerShell y CMD interpretan de forma distinta heredocs, permisos y rutas.
{: .lab-note .important .compact}

## 📁 Preparación del directorio de trabajo

- {% include step_label.html %} Abre **Visual Studio Code**, selecciona **File → Open Folder** y abre `C:\LABS\couchbase-nosql` para validar el resultado antes de continuar.

**Salida esperada:** Visual Studio Code debe mostrar `C:\LABS\couchbase-nosql` como carpeta raíz del workspace y permitir acceder a los laboratorios existentes.

- {% include step_label.html %} Crea los directorios que almacenarán manifiestos, certificados, claves privadas, scripts, auditoría y evidencias y confirma el resultado esperado.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab6/{scripts,manifests,certs/ca,certs/server,certs/operator,certs/client,certs/private,audit-logs,outputs}
  cd /c/LABS/couchbase-nosql/lab6
  pwd
  ```

**Salida esperada:** `pwd` debe devolver `/c/LABS/couchbase-nosql/lab6`; los subdirectorios `scripts`, `manifests`, `certs/operator`, `certs/client`, `certs/private`, `audit-logs` y `outputs` quedan creados.

- {% include step_label.html %} Protege claves privadas, credenciales temporales y logs frente a una confirmación accidental en Git para validar el resultado antes de continuar.

  ```bash
  cat > .gitignore << 'EOF'
  lab.env
  secrets.env
  certs/**/*.key
  certs/**/*.csr
  certs/**/*.srl
  certs/private/
  audit-logs/*.log
  audit-logs/*.jsonl
  *.tmp
  EOF
  ```

> **IMPORTANTE:** Un Secret de Kubernetes no sustituye una bóveda; en producción cifra los Secrets de EKS con AWS KMS y administra las credenciales externamente.
{: .lab-note .important .compact}

**Salida esperada:** `.gitignore` debe incluir `lab.env`, `secrets.env`, claves privadas, CSR y logs de auditoría para evitar incorporarlos accidentalmente al repositorio.

---

## ☁️ Preparación de infraestructura

## Crear variables

- {% include step_label.html %} Crea `lab.env` con la configuración común y una credencial exclusiva de práctica; el archivo permanecerá excluido de Git durante el laboratorio.

  ```bash
  cat > lab.env << 'EOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab06"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"
  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_OPERATOR_VERSION="2.92.0"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"
  export CB_BUCKET="travel-sample"
  export CB_SCOPE="inventory"
  export CB_COLLECTION="security_lab6"
  EOF
  ```

**Salida esperada:** `lab.env` debe contener región, nombre de EKS, namespace, clúster, imagen Enterprise 7.6.2 y nombres del bucket, scope y collection del laboratorio.

- {% include step_label.html %} Carga `lab.env` en la terminal activa y confirma las variables principales antes de ejecutar scripts que dependan de esta configuración.

  ```bash
  source lab.env
  ```

**Salida esperada:** `source lab.env` no debe imprimir errores; variables como `$AWS_REGION`, `$EKS_CLUSTER`, `$CB_NAMESPACE` y `$CB_CLUSTER` quedan disponibles en la sesión.

## Crear script EKS

- {% include step_label.html %} Crea un script de ciclo de vida para que el laboratorio pueda crear, validar y destruir Amazon EKS de forma reproducible.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab6/eks-cluster.sh
  ```

**Salida esperada:** `scripts/eks-cluster.sh` debe contener las acciones `create`, `status` y `delete`, validar dependencias y usar `lab.env` como única fuente de configuración.

- {% include step_label.html %} Asigna permisos al script, valida su sintaxis y crea Amazon EKS para comprobar que el ciclo de vida funciona con la configuración declarada.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada:** `bash -n` no debe producir salida; la creación debe finalizar con tres workers `m6i.xlarge` en estado `Ready`, distribuidos en las zonas configuradas.

## StorageClass y Operator

- {% include step_label.html %} Crea almacenamiento gp3 con binding diferido para los PVC Couchbase y confirma la condición esperada antes de continuar con la práctica.

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

**Salida esperada:** `manifests/storageclass-gp3.yaml` debe definir `gp3-couchbase`, `ebs.csi.aws.com`, `ext4`, `WaitForFirstConsumer` y permitir expansión de volumen.

- {% include step_label.html %} Aplica la definición de StorageClass al clúster y consulta el recurso para confirmar el aprovisionador, el binding diferido y la expansión.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  ```

**Salida esperada:** Kubernetes debe responder `storageclass.storage.k8s.io/gp3-couchbase created` o `unchanged`, confirmando que la StorageClass está disponible.

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 sin crear automáticamente el clúster y confirma la condición esperada antes de continuar con la práctica.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```
  ```bash
  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace couchbase \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```
  ```bash
  kubectl wait -n couchbase --for=condition=Available deployment --all --timeout=5m
  ```

**Salida esperada:** Helm debe instalar o actualizar `cb-operator`; `kubectl wait` debe finalizar con los deployments del namespace `couchbase` en condición `Available`.

## Crear Couchbase inicialmente sin Managed TLS

- {% include step_label.html %} Crea el Secret administrativo para autenticar al Operator sin exponer sus valores y preparar el despliegue inicial del clúster Couchbase.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace couchbase \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe responder `secret/cb-admin created` o `configured`; la salida no debe revelar los valores de usuario ni contraseña administrativa.

- {% include step_label.html %} Define cuatro Pods Couchbase MDS con almacenamiento persistente y conserva Managed TLS deshabilitado para establecer una línea base comparable.

  ```bash
  cat > manifests/couchbase-cluster.yaml << 'EOF'
  apiVersion: couchbase.com/v2
  kind: CouchbaseCluster
  metadata:
    name: cb-cs400
    namespace: couchbase
  spec:
    image: couchbase/server:enterprise-7.6.2
    security:
      adminSecret: cb-admin
    securityContext:
      fsGroup: 1000
    networking:
      exposeAdminConsole: false
  
    servers:
      - name: data-query
        size: 2
        services: [data, query]
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
  EOF
  ```

**Salida esperada:** El manifiesto debe definir cuatro Pods: dos Data+Query, uno Index+Search y uno Analytics+Eventing, cada uno con un PVC de 30 GiB sobre `gp3-couchbase`.

- {% include step_label.html %} Aplica el CouchbaseCluster, espera la condición `Available` y revisa que los cuatro Pods queden preparados antes de cargar el bucket de ejemplo.

  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```
  ```bash
  kubectl wait -n couchbase --for=condition=Available couchbasecluster/cb-cs400 --timeout=15m
  kubectl get pods -n couchbase -o wide
  ```

**Salida esperada:** `kubectl wait` debe confirmar `condition met`; `kubectl get pods` debe mostrar cuatro Pods Couchbase `1/1 Running` sin miembros `Pending` o reinicios continuos.

## Cargar travel-sample y abrir puertos iniciales

- {% include step_label.html %} Identifica dinámicamente un Pod que anuncie Data y Query Service, evitando depender de nombres internos generados por el Operator para crear los túneles.

  ```bash
  MGMT_POD=$(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}'
  )
  
  [[ -n "$MGMT_POD" ]] || {
    echo "ERROR: no se encontró ningún Pod Couchbase en ejecución." >&2
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
    echo "ERROR: no se encontró un Pod con Data + Query Service." >&2
    exit 1
  }
  
  echo "Data + Query Pod seleccionado: $DATA_QUERY_POD"
  ```

**Salida esperada:** Debe mostrarse `Data + Query Pod seleccionado: cb-cs400-000X`; el Pod elegido debe anunciar simultáneamente los servicios `kv` y `n1ql`.

- {% include step_label.html %} Publica temporalmente la administración HTTP en 8091 desde una terminal dedicada y mantenla activa hasta completar la línea base previa a TLS.

  ```bash
  kubectl port-forward -n couchbase "pod/${DATA_QUERY_POD}" 8091:8091
  ```

**Salida esperada:** La terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8091 -> 8091` y su equivalente IPv6 mientras el túnel administrativo esté activo.

- {% include step_label.html %} Publica Query Service por el puerto local 8093 en otra terminal, manteniendo separado el túnel administrativo para observar ambos procesos.

  ```bash
  kubectl port-forward -n couchbase "pod/${DATA_QUERY_POD}" 8093:8093
  ```

**Salida esperada:** La segunda terminal debe permanecer mostrando `Forwarding from 127.0.0.1:8093 -> 8093`, confirmando acceso local al Query Service del mismo Pod.

- {% include step_label.html %} Instala `travel-sample` sólo cuando no exista para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  if ! curl -fsS -u "$CB_USER:$CB_PASS" \
      http://localhost:8091/pools/default/buckets/travel-sample >/dev/null 2>&1; then
    curl -s -u "$CB_USER:$CB_PASS" \
      -X POST http://localhost:8091/sampleBuckets/install \
      -d '["travel-sample"]' | jq .
  fi
  ```

**Salida esperada:** Si el bucket no existe, Couchbase debe aceptar la instalación de `travel-sample`; si ya existe, el comando no realiza cambios ni devuelve un fallo.

---

## 🔎 Tarea 1. Línea base de seguridad y exposición — 7 min

### Tarea 1.1. Revisar Services Kubernetes

- {% include step_label.html %} Lista los Services creados por el Operator y registra su tipo para separar exposición Kubernetes de puertos internos del proceso Couchbase.

  ```bash
  kubectl get svc -n couchbase -o wide \
    | tee outputs/kubernetes-services-baseline.txt
  ```

**Salida esperada:** La tabla debe listar los Services del namespace `couchbase` con sus tipos, ClusterIP y puertos; el inventario queda guardado en `kubernetes-services-baseline.txt`.

- {% include step_label.html %} Confirma que el laboratorio no haya creado un `LoadBalancer` público para Couchbase para dejar una evidencia reproducible del resultado obtenido.

  ```bash
  kubectl get svc -n couchbase -o json \
    | jq '[.items[] | {
        name: .metadata.name,
        type: .spec.type,
        externalIPs: .spec.externalIPs,
        loadBalancer: .status.loadBalancer
      }]'
  ```

**Salida esperada:** El JSON debe mostrar los Services con su `type`; no debe aparecer un `LoadBalancer` público creado por el laboratorio ni direcciones externas inesperadas.

### Tarea 1.2. Capturar seguridad inicial

- {% include step_label.html %} Consulta la configuración antes de Managed TLS y guarda la respuesta para compararla al final para validar el resultado antes de continuar.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/security \
    | tee outputs/security-settings-baseline.json \
    | jq '{
        tlsMinVersion,
        disableUIOverHttp,
        disableUIOverHttps,
        clusterEncryptionLevel
      }'
  ```

**Salida esperada:** El JSON debe registrar los valores iniciales de `tlsMinVersion`, `disableUIOverHttp`, `disableUIOverHttps` y `clusterEncryptionLevel` antes de activar Managed TLS.

### Tarea 1.3. Inventariar identidades

- {% include step_label.html %} Lista usuarios locales y roles actuales antes de crear las cuentas de servicio y confirma la condición esperada antes de continuar con la práctica.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/rbac/users/local \
    | jq '[.[] | {
        id,
        groups,
        roles: [.roles[]?.role]
      }]' \
    | tee outputs/rbac-users-baseline.json
  ```

**Salida esperada:** Debe mostrarse un arreglo JSON de usuarios RBAC locales; en un clúster recién creado puede ser `[]`, y la evidencia queda en `outputs/rbac-users-baseline.json`.

### Tarea 1.4. Crear matriz baseline

- {% include step_label.html %} Documenta la postura inicial por capas para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  cat > outputs/security-posture-baseline.md << 'EOF'
  
  # Matriz de postura de seguridad — estado inicial
  
  | Superficie | Estado inicial | Control requerido |
  |---|---|---|
  | Couchbase público | Sin LoadBalancer del laboratorio | Mantener privado |
  | Administración | HTTP por port-forward local | Migrar a 18091/TLS |
  | Query | HTTP por port-forward local | Migrar a 18093/TLS |
  | Node-to-node | Sin Managed TLS explícito | nodeToNodeEncryption=All |
  | RBAC | Administrator predominante | Cuentas granulares |
  | mTLS | No configurado | X.509 client auth |
  | Auditoría | Por validar | Habilitar y consolidar |
  | Claves privadas | No existen aún | Excluir de Git |
  EOF
  ```

**Salida esperada:** `security-posture-baseline.md` debe contener la matriz inicial con exposición, transporte, RBAC, mTLS, auditoría y protección de claves antes del hardening.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}
{% include support-prompt.html task="tarea1" %}

---

## 👤 Tarea 2. Diseñar y validar RBAC granular — 15 min

### Tarea 2.1. Crear collection aislada

- {% include step_label.html %} Recrea `security_lab6`, carga tres documentos conocidos y crea su índice primario mediante sentencias independientes para detectar cualquier fallo.

  ```bash
  statements=(
    'DROP COLLECTION IF EXISTS `travel-sample`.inventory.security_lab6;'
  
    'CREATE COLLECTION IF NOT EXISTS `travel-sample`.inventory.security_lab6;'
  
    'UPSERT INTO `travel-sample`.inventory.security_lab6 (KEY, VALUE)
     VALUES
       ("sec_001", {"type":"security_test","owner":"reader","value":100}),
       ("sec_002", {"type":"security_test","owner":"query","value":200}),
       ("sec_003", {"type":"security_test","owner":"index","value":300});'
  
    'CREATE PRIMARY INDEX IF NOT EXISTS idx_security_lab6_primary
     ON `travel-sample`.inventory.security_lab6;'
  )
  ```
  ```bash
  STEP=1
  
  for statement in "${statements[@]}"; do
  
    echo
    echo "Ejecutando sentencia ${STEP}..."
  
    response=$(
      curl -sS -u "$CB_USER:$CB_PASS" \
        -X POST http://localhost:8093/query/service \
        --data-urlencode "statement=${statement}"
    )
  
    echo "$response" | jq '{status, errors}'
  
    STATUS=$(echo "$response" | jq -r '.status // "unknown"')
  
    if [[ "$STATUS" != "success" ]]; then
      echo "ERROR: la sentencia ${STEP} no finalizó correctamente."
      echo "Sentencia:"
      echo "$statement"
      echo
      echo "Respuesta completa:"
      echo "$response" | jq '.'
      break
    fi
  
    STEP=$((STEP + 1))
  done
  ```

**Salida esperada:** Las cuatro sentencias deben devolver `status: success`; `security_lab6` queda creada con tres documentos conocidos y el índice primario `idx_security_lab6_primary`.

### Tarea 2.2. Generar contraseñas temporales

- {% include step_label.html %} Genera cuatro contraseñas aleatorias para las identidades de servicio y guárdalas en un archivo excluido de Git antes de crear los usuarios.

  ```bash
  cat > secrets.env << EOF
  export SVC_READER_PASS="$(openssl rand -base64 24 | tr -d '\n')"
  export SVC_QUERY_PASS="$(openssl rand -base64 24 | tr -d '\n')"
  export SVC_INDEX_PASS="$(openssl rand -base64 24 | tr -d '\n')"
  export SVC_MTLS_FALLBACK_PASS="$(openssl rand -base64 24 | tr -d '\n')"
  EOF
  ```

**Salida esperada:** `secrets.env` debe contener cuatro variables de contraseña generadas por OpenSSL, distintas entre sí, sin imprimir sus valores en la terminal.

- {% include step_label.html %} Restringe los permisos de `secrets.env`, carga sus valores en la terminal y verifica únicamente sus metadatos, sin imprimir las contraseñas.

  ```bash
  chmod 600 secrets.env
  source secrets.env
  ls -l secrets.env
  ```

**Salida esperada:** `ls -l secrets.env` debe mostrar permisos restrictivos equivalentes a `-rw-------`; `source` debe cargar las cuatro variables sin mostrar su contenido.

### Tarea 2.3. Crear grupos granulares

- {% include step_label.html %} Crea tres grupos con permisos limitados a la collection experimental y confirma la condición esperada antes de continuar con la práctica.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/groups/app-data-readers \
    -d 'description=Lectura KV de security_lab6' \
    -d 'roles=data_reader[travel-sample:inventory:security_lab6]'
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/groups/app-query-executors \
    -d 'description=SELECT sobre security_lab6' \
    -d 'roles=query_select[travel-sample:inventory:security_lab6]'
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/groups/app-index-admins \
    -d 'description=Gestion GSI de security_lab6' \
    -d 'roles=query_manage_index[travel-sample:inventory:security_lab6]'
  ```

**Salida esperada:** Los tres `PUT` deben completarse sin error HTTP; deben existir los grupos `app-data-readers`, `app-query-executors` y `app-index-admins` con roles limitados a `security_lab6`.

- {% include step_label.html %} Verifica que los tres grupos realmente quedaron creados con los roles correctos

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/rbac/groups \
    | jq '[
        .[]
        | select(
            .id == "app-data-readers"
            or .id == "app-query-executors"
            or .id == "app-index-admins"
          )
        | {
            id,
            description,
            roles
          }
      ]'
  ```
### Tarea 2.4. Crear usuarios de servicio

- {% include step_label.html %} Crea usuarios sin roles directos para que sus privilegios provengan únicamente de los grupos para validar el resultado antes de continuar.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/users/local/svc-reader \
    --data-urlencode 'name=Lab6 KV Reader' \
    --data-urlencode "password=${SVC_READER_PASS}" \
    --data-urlencode 'groups=app-data-readers'
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/users/local/svc-query \
    --data-urlencode 'name=Lab6 Query Reader' \
    --data-urlencode "password=${SVC_QUERY_PASS}" \
    --data-urlencode 'groups=app-query-executors'
  ```
  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X PUT http://localhost:8091/settings/rbac/users/local/svc-index \
    --data-urlencode 'name=Lab6 Index Manager' \
    --data-urlencode "password=${SVC_INDEX_PASS}" \
    --data-urlencode 'groups=app-index-admins'
  ```

**Salida esperada:** Los tres usuarios `svc-reader`, `svc-query` y `svc-index` deben crearse sin roles directos y quedar asociados únicamente con su grupo RBAC correspondiente.

- {% include step_label.html %} Verifica que los usuarios sí quedaron creados y asociados a sus grupos.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/settings/rbac/users/local \
    | jq '[
        .[]
        | select(
            .id == "svc-reader"
            or .id == "svc-query"
            or .id == "svc-index"
          )
        | {
            id,
            name,
            groups,
            roles
          }
      ]'
  ```
### Tarea 2.5. Crear cliente Python y probar data_reader

- {% include step_label.html %} Define un Pod Python aislado, con recursos limitados y una sesión temporal, para instalar el SDK y ejecutar las pruebas de autorización KV.

  ```bash
  cat > manifests/security-client.yaml << 'EOF'
  apiVersion: v1
  kind: Pod
  metadata:
    name: cb-security-client
    namespace: couchbase
  spec:
    restartPolicy: Never
    containers:
      - name: client
        image: python:3.12-slim
        command: ["sh", "-c", "sleep 10800"]
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
  EOF
  ```

**Salida esperada:** `security-client.yaml` debe definir el Pod `cb-security-client` con Python 3.12, `restartPolicy: Never` y límites de CPU y memoria adecuados para las pruebas.

- {% include step_label.html %} Crea el Pod cliente, espera que quede `Ready` e instala una versión compatible del SDK de Couchbase para ejecutar las pruebas KV posteriores.

  ```bash
  kubectl apply -f manifests/security-client.yaml
  kubectl wait -n couchbase --for=condition=Ready pod/cb-security-client --timeout=3m
  ```
  ```bash
  kubectl exec -n couchbase cb-security-client -- \
    sh -c '
      export DEBIAN_FRONTEND=noninteractive
  
      apt-get update >/dev/null &&
      apt-get install -y --no-install-recommends \
        curl \
        openssl \
        ca-certificates >/dev/null &&
      rm -rf /var/lib/apt/lists/* &&
      pip install \
        --quiet \
        --root-user-action=ignore \
        "couchbase>=4.4,<5"
    '
  ```

**Salida esperada:** Kubernetes debe mostrar `pod/cb-security-client condition met`; el Pod debe quedar con `curl`, `openssl`, certificados raíz y Couchbase Python SDK 4.x disponibles.

- {% include step_label.html %} Define un cliente Python que pruebe una lectura permitida y una escritura rechazada con `svc-reader`, diferenciando los privilegios efectivos.

  ```bash
  cat > scripts/test-reader.py << 'PYEOF'
  import os
  from datetime import timedelta
  from couchbase.auth import PasswordAuthenticator
  from couchbase.cluster import Cluster
  from couchbase.exceptions import CouchbaseException
  from couchbase.options import ClusterOptions
  
  cluster = Cluster(
      os.environ["CB_HOST"],
      ClusterOptions(
          PasswordAuthenticator(
              os.environ["CB_USERNAME"],
              os.environ["CB_PASSWORD"]
          )
      )
  )
  cluster.wait_until_ready(timedelta(seconds=20))
  
  collection = (
      cluster.bucket("travel-sample")
      .scope("inventory")
      .collection("security_lab6")
  )
  
  print("GET_ALLOWED:", collection.get("sec_001").content_as[dict])
  
  try:
      collection.upsert("sec_reader_write", {"type":"should_fail"})
      print("UPSERT_UNEXPECTEDLY_ALLOWED")
  except CouchbaseException as exc:
      print("UPSERT_DENIED:", type(exc).__name__)
  
  cluster.close()
  PYEOF
  ```

**Salida esperada:** `test-reader.py` debe contener una lectura `GET` permitida y un `upsert` controlado que capture la excepción de autorización sin finalizar el script abruptamente.

- {% include step_label.html %} Copia el cliente al Pod y ejecútalo con la identidad `svc-reader` para comprobar mediante el SDK los privilegios efectivos sobre la collection.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    scripts/test-reader.py \
    couchbase/cb-security-client:/tmp/test-reader.py
  ```
  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    cb-security-client \
    -- \
    env \
      CB_HOST="couchbase://cb-cs400-srv" \
      CB_USERNAME="svc-reader" \
      CB_PASSWORD="$SVC_READER_PASS" \
      python /tmp/test-reader.py \
    | tee outputs/rbac-reader-test.txt
  ```

**Salida esperada:** La ejecución debe imprimir `GET_ALLOWED:` con el documento `sec_001` y `UPSERT_DENIED:` con una excepción de autorización; no debe aparecer `UPSERT_UNEXPECTEDLY_ALLOWED`.

### Tarea 2.6. Probar query_select

- {% include step_label.html %} Ejecuta un `SELECT` con `svc-query` y confirma que la identidad sólo consulta la collection autorizada mediante su grupo de RBAC granular.

  ```bash
  curl -sS -u "svc-query:${SVC_QUERY_PASS}" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT
        META(s).id,
        s.owner,
        s.`value` AS security_value
      FROM `travel-sample`.inventory.security_lab6 AS s
      ORDER BY s.`value`;' \
    | tee outputs/rbac-query-positive.json \
    | jq '{status, resultCount: .metrics.resultCount, results, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: success`, tres documentos ordenados por `security_value` y ningún error, confirmando que `svc-query` puede ejecutar SELECT sobre `security_lab6`

- {% include step_label.html %} Intenta un INSERT con la misma identidad; debe autenticarse pero recibir rechazo de autorización para validar el resultado antes de continuar.

  ```bash
  curl -s -u "svc-query:${SVC_QUERY_PASS}" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      INSERT INTO `travel-sample`.inventory.security_lab6 (KEY, VALUE)
      VALUES ("sec_query_write", {"type":"should_fail"});' \
    | tee outputs/rbac-query-negative.json \
    | jq '{status, errors}'
  ```

**Salida esperada:** La autenticación de `svc-query` debe funcionar, pero el `INSERT` debe regresar un estado no exitoso con un error de autorización por falta de permiso de escritura.

### Tarea 2.7. Probar query_manage_index

- {% include step_label.html %} Crea un índice con `svc-index` y después intenta leer documentos para demostrar separación entre administración de GSI y lectura de datos.

  ```bash
  for i in $(seq 1 12); do
  
    RESPONSE=$(
      curl -sS -u "svc-index:${SVC_INDEX_PASS}" \
        -X POST http://localhost:8093/query/service \
        --data-urlencode 'statement=
          CREATE INDEX IF NOT EXISTS idx_security_lab6_owner
          ON `travel-sample`.inventory.security_lab6(owner);'
    )
  
    STATUS=$(echo "$RESPONSE" | jq -r '.status // "unknown"')
    ERROR_MSG=$(echo "$RESPONSE" | jq -r '.errors[0].msg // ""')
  
    echo "Intento $i - status=$STATUS"
  
    if [[ "$STATUS" == "success" ]]; then
      echo "Índice creado correctamente."
      break
    fi
  
    if echo "$ERROR_MSG" | grep -q "PrepareUnpause"; then
      echo "Index Service todavía está en transición; esperando 5 segundos..."
      sleep 5
      continue
    fi
  
    echo "$RESPONSE" | jq '{status,errors}'
    break
  done
  ```
  ```bash
  curl -s -u "svc-index:${SVC_INDEX_PASS}" \
    -X POST http://localhost:8093/query/service \
    --data-urlencode 'statement=
      SELECT * FROM `travel-sample`.inventory.security_lab6 LIMIT 1;' \
    | tee outputs/rbac-index-read-negative.json \
    | jq '{status, errors}'
  ```

**Salida esperada:** `CREATE INDEX` debe terminar en `status: success`; si aparece `PrepareUnpause` se reintenta. El `SELECT` debe fallar por ausencia de `query_select`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}
{% include support-prompt.html task="tarea2" %}


---

## 🔐 Tarea 3. Crear CA, certificados X.509 y Kubernetes Secrets — 17 min

Couchbase Server requiere que el certificado utilizado por Managed TLS incluya los SAN esperados por el Operator. Antes de activar client certificate authentication también se prepara una identidad X.509 administrativa para Couchbase Kubernetes Operator, evitando que la reconciliación pierda acceso cuando el servidor comience a solicitar certificados cliente.

### Tarea 3.1. Crear la CA privada

- {% include step_label.html %} Define explícitamente una CA X.509 con `CA:TRUE`, capacidad de firma y un DN estable para que todos los certificados del laboratorio compartan una raíz de confianza verificable.

  ```bash
  cat > certs/ca/ca.cnf << 'EOF'
  [req]
  prompt = no
  default_md = sha256
  distinguished_name = dn
  x509_extensions = v3_ca
  
  [dn]
  C = MX
  ST = Lab
  L = EKS
  O = CouchbaseLab
  OU = Security
  CN = CouchbaseLab6-CA
  
  [v3_ca]
  basicConstraints = critical,CA:TRUE,pathlen:1
  keyUsage = critical,keyCertSign,cRLSign
  subjectKeyIdentifier = hash
  authorityKeyIdentifier = keyid:always,issuer
  EOF
  ```

**Salida esperada:** `certs/ca/ca.cnf` debe declarar `CA:TRUE`, `keyCertSign` y el DN `CN=CouchbaseLab6-CA`, sin utilizar argumentos `/C=...` susceptibles a conversión por MSYS.

- {% include step_label.html %} Genera la clave RSA privada de la CA y emite el certificado raíz autofirmado con el archivo de configuración, manteniendo la clave restringida al usuario del laboratorio.

  ```bash
  openssl genrsa \
    -out certs/private/ca.key \
    4096
  
  chmod 600 certs/private/ca.key
  
  openssl req \
    -new \
    -x509 \
    -sha256 \
    -days 3650 \
    -key certs/private/ca.key \
    -out certs/ca/ca.crt \
    -config certs/ca/ca.cnf
  ```

**Salida esperada:** Deben crearse `ca.key` y `ca.crt` sin errores; la clave queda restringida al propietario y el certificado raíz tiene una vigencia aproximada de diez años.

- {% include step_label.html %} Verifica las extensiones críticas de la CA antes de utilizarla para firmar certificados de servidor y cliente, evitando propagar una cadena inválida al clúster.

  ```bash
  openssl x509 \
    -in certs/ca/ca.crt \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext basicConstraints \
    -ext keyUsage
  ```

**Salida esperada:** `subject` e `issuer` deben identificar `CouchbaseLab6-CA`; las extensiones deben mostrar `CA:TRUE` y `Certificate Sign` o su equivalente.

### Tarea 3.2. Definir SAN compatibles con Operator

- {% include step_label.html %} Define la identidad del certificado servidor con los SAN utilizados por los Pods y Services del clúster, incluyendo `localhost` para comprobaciones internas controladas.

  ```bash
  cat > certs/server/server-san.cnf << 'EOF'
  [req]
  prompt = no
  default_md = sha256
  distinguished_name = dn
  req_extensions = req_ext
  
  [dn]
  C = MX
  ST = Lab
  L = EKS
  O = CouchbaseLab
  OU = CouchbaseServer
  CN = cb-cs400
  
  [req_ext]
  subjectAltName = @alt_names
  
  [server_ext]
  basicConstraints = critical,CA:FALSE
  keyUsage = critical,digitalSignature,keyEncipherment
  extendedKeyUsage = serverAuth
  subjectKeyIdentifier = hash
  authorityKeyIdentifier = keyid,issuer
  subjectAltName = @alt_names
  
  [alt_names]
  DNS.1 = *.cb-cs400
  DNS.2 = *.cb-cs400.couchbase
  DNS.3 = *.cb-cs400.couchbase.svc
  DNS.4 = *.cb-cs400.couchbase.svc.cluster.local
  DNS.5 = cb-cs400-srv
  DNS.6 = cb-cs400-srv.couchbase
  DNS.7 = cb-cs400-srv.couchbase.svc
  DNS.8 = *.cb-cs400-srv.couchbase.svc.cluster.local
  DNS.9 = localhost
  EOF
  ```

> **IMPORTANTE:** Los SAN siguen el patrón requerido para Pods, Service discovery y `localhost`; no agregues IP de Pods porque son efímeras y no representan una identidad estable.
{: .lab-note .important .compact}

**Salida esperada:** El archivo debe contener los nueve SAN de `cb-cs400`, `CA:FALSE`, `serverAuth`, firma digital y cifrado de clave para el certificado servidor.

### Tarea 3.3. Emitir y verificar el certificado servidor

- {% include step_label.html %} Genera la clave privada del servidor, crea el CSR y firma el certificado con la CA del laboratorio aplicando las extensiones `server_ext` definidas previamente.

  ```bash
  openssl genrsa \
    -out certs/private/server.key \
    2048
  
  chmod 600 certs/private/server.key
  
  openssl req \
    -new \
    -sha256 \
    -key certs/private/server.key \
    -out certs/server/server.csr \
    -config certs/server/server-san.cnf
  
  openssl x509 \
    -req \
    -sha256 \
    -days 730 \
    -in certs/server/server.csr \
    -CA certs/ca/ca.crt \
    -CAkey certs/private/ca.key \
    -CAcreateserial \
    -out certs/server/server.crt \
    -extensions server_ext \
    -extfile certs/server/server-san.cnf
  ```

**Salida esperada:** Deben existir `server.key`, `server.csr` y `server.crt`; OpenSSL debe informar que el CSR fue firmado por `CouchbaseLab6-CA` sin errores.

- {% include step_label.html %} Valida cadena, propósito TLS y SAN antes de crear Kubernetes Secrets, deteniendo el flujo si el certificado no puede verificarse contra la CA privada.

  ```bash
  openssl verify \
    -purpose sslserver \
    -CAfile certs/ca/ca.crt \
    certs/server/server.crt
  
  openssl x509 \
    -in certs/server/server.crt \
    -noout \
    -subject \
    -issuer \
    -dates \
    -ext basicConstraints \
    -ext keyUsage \
    -ext extendedKeyUsage \
    -ext subjectAltName
  ```

**Salida esperada:** `openssl verify` debe devolver `certs/server/server.crt: OK`; el issuer debe ser `CouchbaseLab6-CA` y los SAN deben incluir `DNS:localhost`.

### Tarea 3.4. Crear certificado cliente administrativo para Couchbase Operator

- {% include step_label.html %} Define una identidad X.509 de cliente cuyo CN sea `Administrator`, porque el Operator debe poder autenticarse con la misma cuenta declarada en `spec.security.adminSecret`.

  ```bash
  cat > certs/operator/operator.cnf << 'EOF'
  [req]
  prompt = no
  default_md = sha256
  distinguished_name = dn
  
  [dn]
  C = MX
  ST = Lab
  L = EKS
  O = CouchbaseLab
  OU = Operator
  CN = Administrator
  
  [client_ext]
  basicConstraints = critical,CA:FALSE
  keyUsage = critical,digitalSignature
  extendedKeyUsage = clientAuth
  subjectKeyIdentifier = hash
  authorityKeyIdentifier = keyid,issuer
  EOF
  ```

**Salida esperada:** `certs/operator/operator.cnf` debe declarar `CN=Administrator`, `CA:FALSE`, `Digital Signature` y `clientAuth` para una identidad administrativa de cliente.

- {% include step_label.html %} Genera la clave, CSR y certificado cliente del Operator con la misma CA privada, asegurando que la identidad administrativa exista antes de habilitar la política X.509.

  ```bash
  openssl genrsa \
    -out certs/private/operator.key \
    2048
  
  chmod 600 certs/private/operator.key
  
  openssl req \
    -new \
    -sha256 \
    -key certs/private/operator.key \
    -out certs/operator/operator.csr \
    -config certs/operator/operator.cnf
  
  openssl x509 \
    -req \
    -sha256 \
    -days 730 \
    -in certs/operator/operator.csr \
    -CA certs/ca/ca.crt \
    -CAkey certs/private/ca.key \
    -CAcreateserial \
    -out certs/operator/operator.crt \
    -extensions client_ext \
    -extfile certs/operator/operator.cnf
  ```

**Salida esperada:** Deben existir `operator.key`, `operator.csr` y `operator.crt`; el certificado debe quedar firmado por `CouchbaseLab6-CA` sin errores de OpenSSL.

- {% include step_label.html %} Verifica que el certificado sea válido para autenticación TLS de cliente y que su CN coincida exactamente con el usuario almacenado en `cb-admin`.

  ```bash
  openssl verify \
    -purpose sslclient \
    -CAfile certs/ca/ca.crt \
    certs/operator/operator.crt
  
  ADMIN_SECRET_USER=$(
    kubectl get secret cb-admin \
      -n "$CB_NAMESPACE" \
      -o jsonpath='{.data.username}' \
    | base64 -d
  )
  
  OPERATOR_CERT_CN=$(
    openssl x509 \
      -in certs/operator/operator.crt \
      -noout \
      -subject \
      -nameopt RFC2253 \
    | sed -n 's/.*CN=\([^,]*\).*/\1/p'
  )
  
  echo "adminSecret username : $ADMIN_SECRET_USER"
  echo "Operator cert CN     : $OPERATOR_CERT_CN"
  
  if [[ "$ADMIN_SECRET_USER" == "$OPERATOR_CERT_CN" ]]; then
    echo "Identidad del Operator validada correctamente."
  else
    echo "ERROR: el CN del certificado no coincide con adminSecret."
    exit 1
  fi
  ```

**Salida esperada:** `openssl verify` debe devolver `operator.crt: OK`; ambos valores deben ser `Administrator` y debe imprimirse `Identidad del Operator validada correctamente.`.

### Tarea 3.5. Crear Kubernetes Secrets para servidor, CA y Operator

- {% include step_label.html %} Crea los tres Secrets TLS antes de modificar el CouchbaseCluster, de modo que el Operator encuentre simultáneamente servidor, CA e identidad cliente administrativa.

  ```bash
  kubectl create secret tls couchbase-server-ca \
    --namespace "$CB_NAMESPACE" \
    --cert certs/ca/ca.crt \
    --key certs/private/ca.key \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```
  ```bash
  kubectl create secret tls couchbase-server-tls \
    --namespace "$CB_NAMESPACE" \
    --cert certs/server/server.crt \
    --key certs/private/server.key \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```
  ```bash
  kubectl create secret tls couchbase-operator-tls \
    --namespace "$CB_NAMESPACE" \
    --cert certs/operator/operator.crt \
    --key certs/private/operator.key \
    --dry-run=client \
    -o yaml \
    | kubectl apply -f -
  ```

**Salida esperada:** Kubernetes debe crear o configurar `couchbase-server-ca`, `couchbase-server-tls` y `couchbase-operator-tls` antes de iniciar la reconciliación TLS.

- {% include step_label.html %} Comprueba que los tres Secrets utilicen el formato TLS esperado por `secretSource` y conserva sus nombres como evidencia previa al cambio declarativo.

  ```bash
  kubectl get secret \
    couchbase-server-ca \
    couchbase-server-tls \
    couchbase-operator-tls \
    -n "$CB_NAMESPACE" \
    -o custom-columns='NAME:.metadata.name,TYPE:.type'
  ```

**Salida esperada:** Los tres recursos deben aparecer con `TYPE` igual a `kubernetes.io/tls`, confirmando que contienen las claves estándar `tls.crt` y `tls.key`.

### Tarea 3.6. Validar certificados almacenados en Kubernetes

- {% include step_label.html %} Compara el fingerprint SHA-256 del certificado servidor local con el contenido del Secret para detectar cualquier sustitución o carga accidental antes del rollout.

  ```bash
  LOCAL_FP=$(
    openssl x509 \
      -in certs/server/server.crt \
      -noout \
      -fingerprint \
      -sha256 \
    | cut -d= -f2
  )
  
  SECRET_FP=$(
    kubectl get secret couchbase-server-tls \
      -n "$CB_NAMESPACE" \
      -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    | openssl x509 \
        -noout \
        -fingerprint \
        -sha256 \
    | cut -d= -f2
  )
  
  echo "Local : $LOCAL_FP"
  echo "Secret: $SECRET_FP"
  
  if [[ "$LOCAL_FP" == "$SECRET_FP" ]]; then
    echo "Certificado servidor sincronizado correctamente."
  else
    echo "ERROR: el Secret no contiene el certificado servidor esperado."
    exit 1
  fi
  ```

**Salida esperada:** Los fingerprints SHA-256 deben ser idénticos y debe aparecer `Certificado servidor sincronizado correctamente.` antes de habilitar Managed TLS.

- {% include step_label.html %} Confirma que el certificado almacenado para el Operator conserva el CN administrativo y que puede validarse con la CA usada como trust pool del clúster.

  ```bash
  kubectl get secret couchbase-operator-tls \
    -n "$CB_NAMESPACE" \
    -o jsonpath='{.data.tls\.crt}' \
    | base64 -d \
    > /tmp/operator-from-secret.crt
  
  openssl verify \
    -purpose sslclient \
    -CAfile certs/ca/ca.crt \
    /tmp/operator-from-secret.crt
  
  openssl x509 \
    -in /tmp/operator-from-secret.crt \
    -noout \
    -subject \
    -issuer
  
  rm -f /tmp/operator-from-secret.crt
  ```

**Salida esperada:** OpenSSL debe devolver `OK`; el subject debe contener `CN=Administrator` y el issuer debe identificar `CouchbaseLab6-CA`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}
{% include support-prompt.html task="tarea3" %}

---

## 🔒 Tarea 4. Habilitar Managed TLS, mTLS opcional y cifrado entre nodos — 10 min

### Tarea 4.1. Aplicar Managed TLS y client certificate authentication declarativamente

- {% include step_label.html %} Detén con `Ctrl+C` los port-forward de 8091 y 8093 antes de iniciar la reconciliación, evitando que una sustitución normal de Pods se interprete como fallo del laboratorio.

**Salida esperada:** Las dos terminales dedicadas deben regresar al prompt; los puertos locales 8091 y 8093 dejan de depender de los Pods que el Operator puede reemplazar.

- {% include step_label.html %} Declara en una sola operación el certificado servidor, la identidad cliente del Operator, el mapping `subject.cn`, TLS 1.2 y cifrado completo entre nodos.

  ```bash
  cat > manifests/enable-managed-tls.json << 'EOF'
  {
    "spec": {
      "networking": {
        "exposeAdminConsole": false,
        "tls": {
          "rootCAs": [
            "couchbase-server-ca"
          ],
          "secretSource": {
            "serverSecretName": "couchbase-server-tls",
            "clientSecretName": "couchbase-operator-tls"
          },
          "clientCertificatePolicy": "enable",
          "clientCertificatePaths": [
            {
              "path": "subject.cn"
            }
          ],
          "tlsMinimumVersion": "TLS1.2",
          "nodeToNodeEncryption": "All"
        }
      }
    }
  }
  EOF
  ```
  ```bash
  kubectl patch couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    --type merge \
    --patch-file manifests/enable-managed-tls.json
  ```

**Salida esperada:** Kubernetes debe responder `couchbasecluster.couchbase.com/cb-cs400 patched`; el Operator inicia una reconciliación que puede reemplazar temporalmente los Pods mediante SwapRebalance.

> **IMPORTANTE:** `clientCertificatePolicy: enable` mantiene disponibles mecanismos alternativos cuando un cliente no presenta certificado; no uses `mandatory` en esta práctica porque obligaría a todos los clientes a presentar una identidad X.509.
{: .lab-note .important .compact}

- {% include step_label.html %} Verifica inmediatamente el estado deseado almacenado en el CR para confirmar que el Operator recibió los tres componentes de Managed TLS antes de esperar el rollout.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{
        rootCAs: .spec.networking.tls.rootCAs,
        serverSecretName: .spec.networking.tls.secretSource.serverSecretName,
        clientSecretName: .spec.networking.tls.secretSource.clientSecretName,
        clientCertificatePolicy: .spec.networking.tls.clientCertificatePolicy,
        clientCertificatePaths: .spec.networking.tls.clientCertificatePaths,
        tlsMinimumVersion: .spec.networking.tls.tlsMinimumVersion,
        nodeToNodeEncryption: .spec.networking.tls.nodeToNodeEncryption
      }'
  ```

**Salida esperada:** El JSON debe mostrar `couchbase-server-ca`, ambos Secrets TLS, `clientCertificatePolicy: "enable"`, `path: "subject.cn"`, `TLS1.2` y `nodeToNodeEncryption: "All"`.

### Tarea 4.2. Esperar reconciliación y estabilización real

- {% include step_label.html %} Crea una espera de estabilización que exige cuatro Pods `Running/Ready` y el mismo conjunto de nombres y UID durante 60 segundos consecutivos.

  ```bash
  cat > scripts/wait-couchbase-stable.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"
  
  EXPECTED_PODS=4
  STABLE_REQUIRED=6
  STABLE_COUNT=0
  PREVIOUS=""
  
  echo "Esperando que Couchbase termine la reconciliación de Managed TLS..."
  
  for i in $(seq 1 90); do
  
    AVAILABLE=$(
      kubectl get couchbasecluster "$CB_CLUSTER" \
        -n "$CB_NAMESPACE" \
        -o json \
      | jq -r '
          [
            .status.conditions[]?
            | select(.type == "Available")
            | .status
          ][0] // "False"
        '
    )
  
    CURRENT=$(
      kubectl get pods \
        -n "$CB_NAMESPACE" \
        -l "couchbase_cluster=$CB_CLUSTER" \
        -o json \
      | jq -r '
          .items[]
          | [
              .metadata.name,
              .metadata.uid,
              (.status.phase // ""),
              ((.status.containerStatuses[0].ready // false) | tostring)
            ]
          | @tsv
        ' \
      | sort
    )
  
    TOTAL=$(printf '%s
  ' "$CURRENT" | sed '/^$/d' | wc -l)
    READY=$(
      printf '%s
  ' "$CURRENT" \
      | awk -F'	' '$3=="Running" && $4=="true" {n++} END {print n+0}'
    )
  
    if [[ "$AVAILABLE" == "True" \
          && "$TOTAL" -eq "$EXPECTED_PODS" \
          && "$READY" -eq "$EXPECTED_PODS" \
          && "$CURRENT" == "$PREVIOUS" ]]; then
      STABLE_COUNT=$((STABLE_COUNT + 1))
    else
      STABLE_COUNT=0
    fi
  
    echo "Intento $i - Available=$AVAILABLE Pods=$TOTAL Ready=$READY Estable=${STABLE_COUNT}/$STABLE_REQUIRED"
  
    if [[ "$STABLE_COUNT" -ge "$STABLE_REQUIRED" ]]; then
      echo "Clúster estable durante 60 segundos consecutivos."
      exit 0
    fi
  
    PREVIOUS="$CURRENT"
    sleep 10
  done
  
  echo "ERROR: el clúster no alcanzó estabilidad dentro del tiempo previsto." >&2
  exit 1
  EOF
  ```
  ```bash
  chmod +x scripts/wait-couchbase-stable.sh
  bash -n scripts/wait-couchbase-stable.sh
  ./scripts/wait-couchbase-stable.sh
  ```

**Salida esperada:** El script debe terminar con `Clúster estable durante 60 segundos consecutivos.`; los cuatro Pods deben conservar nombres y UID durante toda la ventana final.

- {% include step_label.html %} Revisa los Pods y eventos sólo después de superar la ventana estable para detectar problemas persistentes y no transiciones normales del Operator.

  ```bash
  kubectl get pods \
    -n "$CB_NAMESPACE" \
    -l "couchbase_cluster=$CB_CLUSTER" \
    -o wide
  
  kubectl get events \
    -n "$CB_NAMESPACE" \
    --sort-by=.lastTimestamp \
    | tail -n 25
  ```

**Salida esperada:** Deben existir cuatro Pods Couchbase `1/1 Running`; los eventos recientes no deben mostrar fallos persistentes de certificados, admisión o reconciliación.

### Tarea 4.3. Preparar el cliente TLS y localizar Data + Query

- {% include step_label.html %} Copia la CA al Pod cliente Linux para que las comprobaciones TLS no dependan de Schannel ni del almacén de certificados de Windows.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- mkdir -p /tmp/lab6-certs
  
  MSYS_NO_PATHCONV=1 kubectl cp \
    certs/ca/ca.crt \
    "$CB_NAMESPACE/cb-security-client:/tmp/lab6-certs/ca.crt"
  ```

**Salida esperada:** `/tmp/lab6-certs/ca.crt` debe quedar disponible dentro de `cb-security-client` para validar la cadena TLS proporcionada por cada nodo Couchbase.

- {% include step_label.html %} Comprueba desde Linux que los cuatro nodos acepten la CA privada; esta validación detecta inmediatamente cualquier nodo que aún presente un certificado autogenerado.

  ```bash
  for pod in $(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER" \
      -o jsonpath='{.items[*].metadata.name}'
  ); do
  
    HOST="${pod}.${CB_CLUSTER}.${CB_NAMESPACE}.svc"
  
    CODE=$(
      MSYS_NO_PATHCONV=1 kubectl exec \
        -n "$CB_NAMESPACE" \
        cb-security-client \
        -- \
        curl -sS \
          --connect-timeout 5 \
          --cacert /tmp/lab6-certs/ca.crt \
          -u "$CB_USER:$CB_PASS" \
          -o /dev/null \
          -w '%{http_code}' \
          "https://${HOST}:18091/pools/default"
    )
  
    echo "${pod}: HTTP ${CODE}"
  done
  ```

**Salida esperada:** Cada uno de los cuatro Pods debe responder `HTTP 200`; un error de confianza TLS en cualquiera de ellos debe detener el avance hacia mTLS.

- {% include step_label.html %} Detecta un nodo Data + Query probando el Query Service TLS real en cada Pod, sin inferir servicios a partir del nombre ordinal generado por el Operator.

  ```bash
  DATA_QUERY_POD=""
  
  for pod in $(
    kubectl get pods \
      -n "$CB_NAMESPACE" \
      -l "couchbase_cluster=$CB_CLUSTER" \
      -o jsonpath='{.items[*].metadata.name}'
  ); do
  
    HOST="${pod}.${CB_CLUSTER}.${CB_NAMESPACE}.svc"
  
    RESPONSE=$(
      MSYS_NO_PATHCONV=1 kubectl exec \
        -n "$CB_NAMESPACE" \
        cb-security-client \
        -- \
        curl -sS \
          --connect-timeout 4 \
          --cacert /tmp/lab6-certs/ca.crt \
          -u "$CB_USER:$CB_PASS" \
          "https://${HOST}:18093/query/service" \
          --data-urlencode 'statement=SELECT 1 AS probe_value;' \
        2>/dev/null || true
    )
  
    if echo "$RESPONSE" \
        | jq -e '.status == "success" and .results[0].probe_value == 1' \
        >/dev/null 2>&1; then
  
      DATA_QUERY_POD="$pod"
      break
    fi
  done
  
  if [[ -n "$DATA_QUERY_POD" ]]; then
    export DATA_QUERY_POD
    export CB_TLS_HOST="${DATA_QUERY_POD}.${CB_CLUSTER}.${CB_NAMESPACE}.svc"
  
    echo "Data + Query Pod: $DATA_QUERY_POD"
    echo "TLS host: $CB_TLS_HOST"
  else
    echo "ERROR: no se encontró un nodo con Query Service TLS operativo."
  fi
  ```

**Salida esperada:** Debe mostrarse un Pod ordinal como `cb-cs400-000X` y un host TLS del tipo `cb-cs400-000X.cb-cs400.couchbase.svc`.

### Tarea 4.4. Verificar certificado y servicios TLS

- {% include step_label.html %} Verifica dentro del cliente Linux la cadena que entrega el nodo Data + Query y confirma que el issuer sea la CA creada por el laboratorio.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    sh -c "openssl s_client \
      -connect '${CB_TLS_HOST}:18091' \
      -servername '${CB_TLS_HOST}' \
      -CAfile /tmp/lab6-certs/ca.crt \
      </dev/null 2>/dev/null \
      | openssl x509 -noout -subject -issuer -dates"
  ```

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    sh -c "openssl s_client \
      -connect '${CB_TLS_HOST}:18091' \
      -servername '${CB_TLS_HOST}' \
      -CAfile /tmp/lab6-certs/ca.crt \
      </dev/null 2>&1 \
      | grep 'Verify return code'"
  ```

**Salida esperada:** El issuer debe contener `CouchbaseLab6-CA` y OpenSSL debe mostrar `Verify return code: 0 (ok)`.

- {% include step_label.html %} Comprueba administración y Query Service por TLS utilizando la misma CA y el hostname cubierto por los SAN del certificado.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/pools/default" \
    | jq '{
        clusterName,
        nodes: [.nodes[] | {
          hostname,
          status
        }]
      }'
  ```

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=SELECT 1 AS tls_test;' \
    | jq '{status,results,errors}'
  ```

**Salida esperada:** Administración debe devolver los nodos `healthy`; Query debe devolver `status: success` y `tls_test: 1`, ambos sin desactivar la verificación de certificado.

### Tarea 4.5. Deshabilitar UI HTTP y comprobar cifrado interno

- {% include step_label.html %} Deshabilita UI HTTP y conserva TLS 1.2 mínimo mediante una petición verificada desde el cliente Linux del laboratorio.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "https://${CB_TLS_HOST}:18091/settings/security" \
      -d 'disableUIOverHttp=true' \
      -d 'disableUIOverHttps=false' \
      -d 'tlsMinVersion=tlsv1.2'
  ```

**Salida esperada:** La petición debe finalizar sin error TLS o HTTP; los valores se comprueban inmediatamente mediante una lectura independiente.

- {% include step_label.html %} Consulta la configuración efectiva y guarda localmente la evidencia para confirmar TLS mínimo, UI HTTP deshabilitada y cifrado completo entre nodos.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/security" \
    | tee outputs/security-settings-after-tls.json \
    | jq '{
        tlsMinVersion,
        disableUIOverHttp,
        disableUIOverHttps,
        clusterEncryptionLevel
      }'
  ```

**Validación:**

- `disableUIOverHttp=true`.
- `tlsMinVersion=tlsv1.2` o superior.
- `clusterEncryptionLevel=all`.

**Salida esperada:** El JSON debe mostrar `disableUIOverHttp=true`, `disableUIOverHttps=false`, TLS 1.2 o superior y `clusterEncryptionLevel=all`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}
{% include support-prompt.html task="tarea4" %}

---


## 🪪 Tarea 5. Crear y validar una identidad mTLS de aplicación — 7 min

La política de certificados cliente ya fue declarada por Couchbase Kubernetes Operator durante la Tarea 4. En esta tarea no se modifica `/settings/clientCertAuth`; únicamente se crea una identidad de aplicación, se verifica el estado efectivo y se demuestra autenticación X.509 real sin contraseña.

### Tarea 5.1. Crear certificado cliente de aplicación

- {% include step_label.html %} Define el DN y las extensiones de un certificado cliente con CN `svc-mtls-client`, reutilizando la CA del laboratorio y evitando argumentos `-subj` sensibles a MSYS.

  ```bash
  cat > certs/client/client.cnf << 'EOF'
  [req]
  prompt = no
  default_md = sha256
  distinguished_name = dn
  
  [dn]
  C = MX
  ST = Lab
  L = EKS
  O = CouchbaseLab
  OU = Clients
  CN = svc-mtls-client
  
  [client_ext]
  basicConstraints = critical,CA:FALSE
  keyUsage = critical,digitalSignature
  extendedKeyUsage = clientAuth
  subjectKeyIdentifier = hash
  authorityKeyIdentifier = keyid,issuer
  EOF
  ```

**Salida esperada:** `client.cnf` debe declarar `CN=svc-mtls-client`, `CA:FALSE`, `Digital Signature` y `clientAuth`, sin utilizar un DN escrito directamente en la línea de comandos.

- {% include step_label.html %} Genera la clave, CSR y certificado de `svc-mtls-client`, firmándolo con la misma CA que Couchbase utiliza para validar certificados cliente del laboratorio.

  ```bash
  openssl genrsa \
    -out certs/private/client.key \
    2048
  
  chmod 600 certs/private/client.key
  
  openssl req \
    -new \
    -sha256 \
    -key certs/private/client.key \
    -out certs/client/client.csr \
    -config certs/client/client.cnf
  
  openssl x509 \
    -req \
    -sha256 \
    -days 365 \
    -in certs/client/client.csr \
    -CA certs/ca/ca.crt \
    -CAkey certs/private/ca.key \
    -CAcreateserial \
    -out certs/client/client.crt \
    -extensions client_ext \
    -extfile certs/client/client.cnf
  ```

**Salida esperada:** OpenSSL debe confirmar la firma del CSR y generar `client.key`, `client.csr` y `client.crt` sin errores de extensiones o cadena.

- {% include step_label.html %} Verifica propósito, subject e issuer del certificado antes de copiarlo al Pod cliente, evitando interpretar un error de identidad como un problema de Couchbase.

  ```bash
  openssl verify \
    -purpose sslclient \
    -CAfile certs/ca/ca.crt \
    certs/client/client.crt
  
  openssl x509 \
    -in certs/client/client.crt \
    -noout \
    -subject \
    -issuer \
    -ext extendedKeyUsage \
    -ext keyUsage
  ```

**Salida esperada:** `openssl verify` debe devolver `client.crt: OK`; el subject debe contener `CN=svc-mtls-client` y el issuer debe identificar `CouchbaseLab6-CA`.

- {% include step_label.html %} Copia certificado y clave al Pod Linux utilizado para las pruebas y restringe la clave privada para ejecutar mTLS sin depender de la pila TLS de Windows.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl cp \
    certs/client/client.crt \
    "$CB_NAMESPACE/cb-security-client:/tmp/lab6-certs/client.crt"
  
  MSYS_NO_PATHCONV=1 kubectl cp \
    certs/private/client.key \
    "$CB_NAMESPACE/cb-security-client:/tmp/lab6-certs/client.key"
  
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- chmod 600 /tmp/lab6-certs/client.key
  ```

**Salida esperada:** El Pod debe contener `/tmp/lab6-certs/client.crt` y `client.key`; la clave privada debe conservar permisos restrictivos dentro del contenedor.

### Tarea 5.2. Crear usuario RBAC correspondiente al CN

- {% include step_label.html %} Crea el usuario local `svc-mtls-client` con lectura restringida a la collection experimental, haciendo coincidir exactamente el identificador RBAC con el CN del certificado.

  ```bash
  source secrets.env
  
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -X PUT \
      "https://${CB_TLS_HOST}:18091/settings/rbac/users/local/svc-mtls-client" \
      --data-urlencode 'name=Lab6 mTLS Client' \
      --data-urlencode "password=${SVC_MTLS_FALLBACK_PASS}" \
      --data-urlencode 'roles=data_reader[travel-sample:inventory:security_lab6]' \
      -o /dev/null \
      -w 'svc-mtls-client: HTTP %{http_code}\n'
  ```

**Salida esperada:** El comando debe mostrar `HTTP 200` para `svc-mtls-client`; la contraseña fallback no debe imprimirse y la identidad queda disponible para el mapping X.509.

- {% include step_label.html %} Consulta el usuario recién creado para comprobar que el ID coincide con el CN y que su autorización se limita a `data_reader` sobre `security_lab6`.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/rbac/users/local/svc-mtls-client" \
    | jq '{
        id,
        domain,
        roles
      }'
  ```

**Salida esperada:** El JSON debe mostrar `id: "svc-mtls-client"`, `domain: "local"` y el rol `data_reader` limitado al bucket, scope y collection del laboratorio.

### Tarea 5.3. Verificar la política declarativa y efectiva de certificados cliente

- {% include step_label.html %} Comprueba en el `CouchbaseCluster` que la política mTLS continúa administrada por Operator y referencia la identidad administrativa creada antes del rollout.

  ```bash
  kubectl get couchbasecluster "$CB_CLUSTER" \
    -n "$CB_NAMESPACE" \
    -o json \
    | jq '{
        clientSecretName:
          .spec.networking.tls.secretSource.clientSecretName,
        clientCertificatePolicy:
          .spec.networking.tls.clientCertificatePolicy,
        clientCertificatePaths:
          .spec.networking.tls.clientCertificatePaths
      }'
  ```

**Salida esperada:** El CR debe mostrar `clientSecretName: "couchbase-operator-tls"`, `clientCertificatePolicy: "enable"` y un path `subject.cn`.

- {% include step_label.html %} Lee la configuración efectiva de Couchbase mediante HTTPS para confirmar que la reconciliación convirtió la declaración del Operator en `state=enable` y mapping por CN.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/clientCertAuth" \
    | tee outputs/client-cert-auth.json \
    | jq '.'
  ```

**Salida esperada:** El JSON debe mostrar `"state":"enable"` y al menos un elemento en `prefixes` con `"path":"subject.cn"`; `prefix` y `delimiter` pueden aparecer como cadenas vacías.

### Tarea 5.4. Autenticar `svc-mtls-client` sin usuario ni contraseña

- {% include step_label.html %} Presenta únicamente certificado y clave a `/whoami`, captura la identidad devuelta y evita usar sólo HTTP 200 como evidencia porque ese endpoint también describe sesiones anónimas.

  ```bash
  MTLS_IDENTITY=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-security-client \
      -- \
      curl -sS \
        --cacert /tmp/lab6-certs/ca.crt \
        --cert /tmp/lab6-certs/client.crt \
        --key /tmp/lab6-certs/client.key \
        "https://${CB_TLS_HOST}:18091/whoami"
  )
  
  echo "$MTLS_IDENTITY" \
    | tee outputs/mtls-management-response.json \
    | jq '.'
  ```

**Salida esperada:** La respuesta debe contener `id: "svc-mtls-client"` y `domain: "local"` sin que el comando proporcione `-u`, usuario o contraseña.

- {% include step_label.html %} Valida programáticamente la identidad X.509 devuelta para detener el laboratorio si el certificado fue aceptado por TLS pero no fue asociado con el usuario RBAC esperado.

  ```bash
  MTLS_USER=$(echo "$MTLS_IDENTITY" | jq -r '.id // ""')
  MTLS_DOMAIN=$(echo "$MTLS_IDENTITY" | jq -r '.domain // ""')
  
  if [[ "$MTLS_USER" == "svc-mtls-client" \
        && "$MTLS_DOMAIN" == "local" ]]; then
    echo "mTLS autenticado correctamente como svc-mtls-client."
  else
    echo "ERROR: el certificado no resolvió la identidad esperada."
    exit 1
  fi
  ```

**Salida esperada:** Debe imprimirse `mTLS autenticado correctamente como svc-mtls-client.`; cualquier identidad vacía o `anonymous` debe detener el avance.

### Tarea 5.5. Validar comportamiento sin identidad cliente

- {% include step_label.html %} Consulta `/whoami` sin certificado ni credenciales para demostrar que la política `enable` no inventa una identidad y mantiene la sesión como anónima.

  ```bash
  ANON_IDENTITY=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-security-client \
      -- \
      curl -sS \
        --cacert /tmp/lab6-certs/ca.crt \
        "https://${CB_TLS_HOST}:18091/whoami"
  )
  
  echo "$ANON_IDENTITY" | jq '.'
  
  ANON_DOMAIN=$(echo "$ANON_IDENTITY" | jq -r '.domain // ""')
  
  if [[ "$ANON_DOMAIN" == "anonymous" ]]; then
    echo "Acceso sin identidad permanece anónimo."
  else
    echo "ERROR: se obtuvo una identidad inesperada."
    exit 1
  fi
  ```

**Salida esperada:** `/whoami` debe indicar `domain: "anonymous"` y el script debe imprimir `Acceso sin identidad permanece anónimo.` sin confundir HTTP 200 con autenticación.

- {% include step_label.html %} Intenta acceder sin certificado ni credenciales a un recurso administrativo protegido para comprobar que una sesión anónima no obtiene privilegios sobre el clúster.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -o /dev/null \
      -w 'Sin identidad en recurso protegido: HTTP %{http_code}\n' \
      "https://${CB_TLS_HOST}:18091/pools/default"
  ```

**Salida esperada:** El recurso protegido debe responder `HTTP 401`, confirmando que confiar en la CA sin presentar identidad o credenciales no concede acceso administrativo.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}
{% include support-prompt.html task="tarea5" %}

---

## 🧾 Tarea 6. Habilitar auditoría y generar eventos — 10 min

### Tarea 6.1. Descubrir eventos auditables

- {% include step_label.html %} Consulta los descriptors de la versión instalada mediante el canal TLS verificado, evitando depender de IDs históricos.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit/descriptors" \
    | tee outputs/audit-descriptors.json \
    | jq '[.[] | {
        id,
        name,
        module,
        description
      }]'
  ```

**Salida esperada:** `audit-descriptors.json` debe contener los descriptors reales de Couchbase 7.6.2 con `id`, `name`, `module` y `description`.

- {% include step_label.html %} Consulta los descriptors filterable disponibles en Couchbase Server 7.6.2 para identificar los eventos reales de la versión antes de modificar su estado.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit/descriptors" \
    | tee outputs/audit-descriptors.json \
    | jq '[.[] | {
        id,
        name,
        module,
        description
      }]'
  ```

**Salida esperada:** `audit-descriptors.json` ebe contener los eventos filterable reales de Couchbase 7.6.2 con sus campos id, name, module y description.

- {% include step_label.html %} Consulta también los eventos non-filterable para identificar acciones que siempre serán auditadas cuando el servicio de auditoría permanezca habilitado.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit/nonFilterableDescriptors" \
    | tee outputs/audit-non-filterable-descriptors.json \
    | jq '[.[] | {
        id,
        name,
        module,
        description
      }]'
  ```

**Salida esperada:** El archivo debe incluir los eventos non-filterable de la versión; entre ellos pueden aparecer login success y login failure, que no pueden deshabilitarse individualmente.

- {% include step_label.html %} Filtra descriptors relacionados con autenticación, usuarios, Query y documentos para identificar los eventos que serán relevantes durante las pruebas de seguridad.

  ```bash
  jq '
    [
      .[]
      | select(
          (
            (.name // "") + " " +
            (.description // "") + " " +
            (.module // "")
          )
          | test("login|auth|user|query|document|select|mutat"; "i")
        )
    ]
  ' outputs/audit-descriptors.json \
    | tee outputs/audit-security-descriptors.json
  ```

**Salida esperada:** audit-security-descriptors.json debe mostrar los eventos filterable relacionados con autenticación, Query, usuarios o documentos; los IDs pueden variar entre versiones.

### Tarea 6.2. Habilitar auditoría y eventos necesarios

- {% include step_label.html %} Captura la configuración vigente antes de modificarla para conservar evidencia del estado de auditoría, rotación, retención y eventos actualmente deshabilitados.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit" \
    | tee outputs/audit-settings-before.json \
    | jq '{
        auditdEnabled,
        logPath,
        rotateInterval,
        rotateSize,
        pruneAge,
        disabled
      }'
  ```

**Salida esperada:** El JSON debe registrar el estado previo de auditdEnabled, la ruta de logs, rotación, retención y todos los IDs filterable presentes en disabled.

- {% include step_label.html %} Obtén dinámicamente los IDs de authentication succeeded y SELECT statement de N1QL para evitar codificar identificadores históricos en el laboratorio.

  ```bash
  AUTH_SUCCESS_ID=$(
    jq -r '
      .[]
      | select(
          .module == "memcached"
          and (.name | ascii_downcase) == "authentication succeeded"
        )
      | .id
    ' outputs/audit-descriptors.json \
    | head -n1
  )
  
  N1QL_SELECT_ID=$(
    jq -r '
      .[]
      | select(
          .module == "n1ql"
          and (.name | ascii_downcase) == "select statement"
        )
      | .id
    ' outputs/audit-descriptors.json \
    | head -n1
  )
  
  echo "Authentication succeeded ID: $AUTH_SUCCESS_ID"
  echo "N1QL SELECT ID             : $N1QL_SELECT_ID"
  
  [[ -n "$AUTH_SUCCESS_ID" && -n "$N1QL_SELECT_ID" ]] || {
    echo "ERROR: no fue posible localizar los eventos requeridos."
    exit 1
  }
  ```

**Salida esperada:** Deben mostrarse dos IDs válidos; en Couchbase Server 7.6.2 normalmente corresponden a authentication succeeded y SELECT statement del módulo n1ql.

- {% include step_label.html %} Conserva la lista de eventos deshabilitados pero retira únicamente los IDs que se utilizarán en las pruebas, evitando habilitar indiscriminadamente todos los eventos filterable.

  ```bash
  CURRENT_DISABLED=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-security-client \
      -- \
      curl -sS \
        --cacert /tmp/lab6-certs/ca.crt \
        -u "$CB_USER:$CB_PASS" \
        "https://${CB_TLS_HOST}:18091/settings/audit" \
    | jq -r \
        --argjson auth "$AUTH_SUCCESS_ID" \
        --argjson query "$N1QL_SELECT_ID" '
          [
            .disabled[]
            | select(. != $auth and . != $query)
          ]
          | join(",")
        '
  )
  
  echo "Lista disabled ajustada:"
  echo "$CURRENT_DISABLED"
  ```

**Salida esperada:** La salida debe conservar los demás IDs deshabilitados y excluir los identificadores seleccionados para autenticación correcta y SELECT de N1QL.

- {% include step_label.html %} Habilita auditoría, configura rotación y retención y aplica la lista ajustada para registrar específicamente los eventos necesarios durante las pruebas posteriores.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "https://${CB_TLS_HOST}:18091/settings/audit" \
      -d 'auditdEnabled=true' \
      -d 'rotateInterval=86400' \
      -d 'rotateSize=20971520' \
      -d 'pruneAge=604800' \
      --data-urlencode "disabled=${CURRENT_DISABLED}" \
      -o /dev/null \
      -w 'Audit config: HTTP %{http_code}\n'
  ```

**Salida esperada:** El comando debe devolver Audit config: HTTP 200, indicando que Couchbase aceptó la configuración de auditoría, rotación, retención y filtrado.

- {% include step_label.html %} Verifica inmediatamente que auditoría esté activa y que los dos eventos seleccionados ya no aparezcan en la lista disabled.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit" \
    | jq \
        --argjson auth "$AUTH_SUCCESS_ID" \
        --argjson query "$N1QL_SELECT_ID" '{
          auditdEnabled,
          rotateInterval,
          rotateSize,
          pruneAge,
          authenticationSucceededDisabled:
            (.disabled | index($auth)),
          n1qlSelectDisabled:
            (.disabled | index($query))
        }'
  ```

**Salida esperada:** Debe mostrarse auditdEnabled=true, los valores de rotación configurados y null para authenticationSucceededDisabled y n1qlSelectDisabled.

### Tarea 6.3. Generar actividad auditable

- {% include step_label.html %} Genera una autenticación administrativa correcta y otra incorrecta desde el mismo cliente para producir eventos comparables.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -o /dev/null \
      "https://${CB_TLS_HOST}:18091/pools/default"
  
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u 'svc-query:password-incorrecto-lab6' \
      -o /dev/null \
      -w 'Login incorrecto HTTP %{http_code}
  ' \
      "https://${CB_TLS_HOST}:18091/pools/default"
  ```

**Salida esperada:** La primera petición debe completar silenciosamente; la segunda debe imprimir un código HTTP de rechazo, normalmente `401`.

- {% include step_label.html %} Ejecuta una consulta autorizada con `svc-query` sobre Query Service TLS y conserva la respuesta como evidencia auditable.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "svc-query:${SVC_QUERY_PASS}" \
      -X POST \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=
        SELECT META(s).id, s.owner
        FROM `travel-sample`.inventory.security_lab6 AS s
        LIMIT 3;' \
    | tee outputs/audit-query-event.json \
    | jq '{status, resultCount: .metrics.resultCount, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: success` y hasta tres filas, dejando `audit-query-event.json` como evidencia local.

- {% include step_label.html %} Ejecuta un SELECT no autorizado con `svc-reader` para generar una denegación RBAC deliberada sin confundirla con un fallo TLS.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "svc-reader:${SVC_READER_PASS}" \
      -X POST \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=
        SELECT * FROM `travel-sample`.inventory.security_lab6 LIMIT 1;' \
    | tee outputs/audit-query-denied.json \
    | jq '{status, errors}'
  ```

**Salida esperada:** La respuesta debe ser no exitosa y mostrar un error RBAC por ausencia de `query_select`; la conexión TLS debe completarse correctamente.

### Tarea 6.4. Confirmar audit activo

- {% include step_label.html %} Captura la configuración final y confirma los valores de activación, rotación y retención configurados.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/audit" \
    | tee outputs/audit-settings-after.json \
    | jq '{
        auditdEnabled,
        rotateInterval,
        rotateSize,
        pruneAge
      }'
  ```

**Salida esperada:** El JSON debe confirmar `auditdEnabled=true`, `rotateInterval=86400`, `rotateSize=20971520` y `pruneAge=604800`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}
{% include support-prompt.html task="tarea6" %}

---


## 📑 Tarea 7. Consolidar y analizar audit logs — 7 min

La auditoría de Couchbase se registra por nodo. Una revisión de un único `audit.log` no representa necesariamente toda la actividad del clúster.

### Tarea 7.1. Recolectar logs desde todos los Pods Couchbase

- {% include step_label.html %} Crea un script que recorra los Pods Couchbase, copie `audit.log` cuando exista y añada el nombre del Pod como metadato de origen.

  ```bash
  cat > scripts/collect-audit-logs.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail
  
  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  OUT_DIR="${ROOT_DIR}/audit-logs"
  
  mkdir -p "$OUT_DIR"
  rm -f "${OUT_DIR}"/*.log "${OUT_DIR}/audit-all.jsonl"
  
  mapfile -t PODS < <(
    kubectl get pods -n couchbase \
      -o name \
      | grep '^pod/cb-cs400-' \
      | cut -d/ -f2
  )
  
  for pod in "${PODS[@]}"; do
    echo "Procesando ${pod}..."
  
    if MSYS_NO_PATHCONV=1 kubectl exec -n couchbase "$pod" -- \
        test -f /opt/couchbase/var/lib/couchbase/logs/audit.log
    then
      MSYS_NO_PATHCONV=1 kubectl exec -n couchbase "$pod" -- \
        cat /opt/couchbase/var/lib/couchbase/logs/audit.log \
        > "${OUT_DIR}/${pod}-audit.log"
  
      python - "$pod" \
        "${OUT_DIR}/${pod}-audit.log" \
        >> "${OUT_DIR}/audit-all.jsonl" << 'PYEOF'
  import json
  import sys
  
  pod = sys.argv[1]
  path = sys.argv[2]
  
  with open(path, encoding="utf-8", errors="replace") as handle:
      for line in handle:
          line = line.strip()
          if not line:
              continue
  
          try:
              event = json.loads(line)
              event["_source_pod"] = pod
              print(json.dumps(event, ensure_ascii=False))
          except json.JSONDecodeError:
              pass
  PYEOF
    else
      echo "  audit.log todavía no existe en ${pod}"
    fi
  done
  
  echo
  echo "Archivos recolectados:"
  ls -lh "${OUT_DIR}" || true
  EOF
  ```

**Salida esperada:** `collect-audit-logs.sh` debe recorrer los cuatro Pods Couchbase, copiar `audit.log` cuando exista y preparar `audit-all.jsonl` agregando `_source_pod` a cada evento válido.

- {% include step_label.html %} Asigna permisos al recolector y ejecútalo para consolidar los registros distribuidos en un archivo local apto para análisis y evidencia.

  ```bash
  chmod +x scripts/collect-audit-logs.sh
  ./scripts/collect-audit-logs.sh
  ```

**Salida esperada:** La ejecución debe mostrar `Procesando cb-cs400-000X...` por cada Pod y terminar listando uno o más archivos `*-audit.log` y `audit-all.jsonl` en `audit-logs`.

### Tarea 7.2. Analizar eventos consolidados

- {% include step_label.html %} Crea un analizador tolerante a campos opcionales, ya que diferentes tipos de eventos exponen estructuras distintas y confirma el resultado esperado.

  ```bash
  cat > scripts/analyze-audit.py << 'PYEOF'
  import json
  from collections import Counter
  from pathlib import Path
  
  root = Path(__file__).resolve().parent.parent
  path = root / "audit-logs" / "audit-all.jsonl"
  
  if not path.exists():
      raise SystemExit("No existe audit-all.jsonl")
  
  events = []
  
  with path.open(encoding="utf-8") as handle:
      for line in handle:
          try:
              events.append(json.loads(line))
          except json.JSONDecodeError:
              continue
  
  print(f"Eventos consolidados: {len(events)}")
  print()
  
  by_name = Counter(
      event.get("name", "unknown")
      for event in events
  )
  
  by_pod = Counter(
      event.get("_source_pod", "unknown")
      for event in events
  )
  
  print("=== Eventos por nombre ===")
  for name, count in by_name.most_common(20):
      print(f"{count:5d}  {name}")
  
  print()
  print("=== Eventos por Pod ===")
  for pod, count in by_pod.most_common():
      print(f"{count:5d}  {pod}")
  
  print()
  print("=== Muestra de eventos con identidad ===")
  shown = 0
  
  for event in reversed(events):
      real_user = event.get("real_userid") or {}
      remote = event.get("remote") or {}
  
      user = real_user.get("user", "?")
      domain = real_user.get("domain", "?")
      remote_ip = remote.get("ip", "?")
  
      if user != "?":
          print(
              f"{event.get('timestamp','?')} | "
              f"{event.get('name','?')} | "
              f"{domain}:{user} | "
              f"remote={remote_ip} | "
              f"pod={event.get('_source_pod','?')}"
          )
          shown += 1
  
      if shown >= 15:
          break
  PYEOF
  ```

**Salida esperada:** `analyze-audit.py` debe cargar `audit-all.jsonl`, contar eventos por nombre y Pod y mostrar hasta 15 registros recientes que incluyan una identidad reconocible.

- {% include step_label.html %} Ejecuta el analizador sobre el registro consolidado y guarda un resumen de eventos, identidades y resultados para revisar las pruebas de seguridad.

  ```bash
  
  python scripts/analyze-audit.py \
    | tee outputs/audit-analysis.txt
  ```

**Salida esperada:** La terminal debe imprimir `Eventos consolidados: <n>`, resúmenes por nombre y Pod y una muestra de identidades; el mismo contenido queda en `audit-analysis.txt`.

### Tarea 7.3. Filtrar cuentas de servicio

- {% include step_label.html %} Busca eventos asociados con las identidades utilizadas en las pruebas de autorización y mTLS para validar el resultado antes de continuar.

  ```bash
  jq -c '
    select(
      (.real_userid.user // "") == "svc-query"
      or (.real_userid.user // "") == "svc-reader"
      or (.real_userid.user // "") == "svc-mtls-client"
    )
    | {
        timestamp,
        id,
        name,
        real_userid,
        remote,
        _source_pod
      }
  ' audit-logs/audit-all.jsonl \
    | tee outputs/audit-service-accounts.jsonl
  ```

**Interpretación:**

El campo `_source_pod` no pertenece al formato nativo de Couchbase; lo añade el script para conservar la procedencia del evento durante la consolidación.

**Salida esperada:** `audit-service-accounts.jsonl` debe contener los eventos encontrados para `svc-query`, `svc-reader` o `svc-mtls-client`, incluyendo timestamp, nombre y `_source_pod`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}
{% include support-prompt.html task="tarea7" %}

---

## 🛡️ Tarea 8. Aplicar hardening adicional — 5 min

### Tarea 8.1. Verificar superficie Kubernetes final

- {% include step_label.html %} Confirma que no se haya creado un Service `LoadBalancer` público para Couchbase durante el laboratorio para obtener evidencia.

  ```bash
  kubectl get svc -n couchbase \
    -o json \
    | jq '[
        .items[]
        | {
            name: .metadata.name,
            type: .spec.type,
            clusterIP: .spec.clusterIP
          }
      ]' \
    | tee outputs/kubernetes-services-final.json
  ```

**Salida esperada:** `kubernetes-services-final.json` debe listar los Services finales con nombre, tipo y ClusterIP; no debe aparecer un `LoadBalancer` público creado durante el laboratorio.

### Tarea 8.2. Verificar Managed TLS en el CR

- {% include step_label.html %} Extrae la sección declarativa TLS del CouchbaseCluster y consérvala como evidencia de que los certificados son administrados por Operator.

  ```bash
  kubectl get couchbasecluster cb-cs400 \
    -n couchbase \
    -o json \
    | jq '.spec.networking.tls' \
    | tee outputs/operator-tls-final.json
  ```

**Salida esperada:** `operator-tls-final.json` debe mostrar `rootCAs`, `serverSecretName`, `clientSecretName`, `clientCertificatePolicy`, `clientCertificatePaths`, `tlsMinimumVersion` y `nodeToNodeEncryption: "All"` declarados en el CouchbaseCluster.

### Tarea 8.3. Capturar seguridad final de Couchbase

- {% include step_label.html %} Verifica TLS mínimo, UI HTTP y cifrado interno desde el endpoint seguro y confirma la condición esperada antes de continuar con la práctica.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      "https://${CB_TLS_HOST}:18091/settings/security" \
    | tee outputs/security-settings-final.json \
    | jq '{
        tlsMinVersion,
        disableUIOverHttp,
        disableUIOverHttps,
        honorCipherOrder,
        clusterEncryptionLevel
      }'
  ```

**Salida esperada:** El JSON debe confirmar TLS mínimo, `disableUIOverHttp=true` y `clusterEncryptionLevel=all`; `security-settings-final.json` conserva la postura final de transporte.

### Tarea 8.4. Documentar controles fuera de alcance

- {% include step_label.html %} Registra controles productivos recomendados que deliberadamente no se implementan en los 84 minutos para validar el resultado antes de continuar.

  ```bash
  cat > outputs/out-of-scope-hardening.md << 'EOF'
  
  # Controles recomendados fuera del alcance del Lab 6
  
  - EKS Secrets Encryption mediante AWS KMS.
  - Rotación automatizada de certificados con cert-manager, Vault PKI o PKI corporativa.
  - Security Groups y NetworkPolicies específicos por productor y consumidor.
  - SAML/SSO corporativo para administradores.
  - Envío de audit logs hacia un SIEM.
  - Rotación automatizada de passwords y secretos.
  - Backup cifrado y pruebas periódicas de restauración.
  - Evaluación completa contra CIS Benchmark y políticas internas.
  - Gestión de la CA mediante una plataforma empresarial.
  EOF
  ```

**Salida esperada:** `out-of-scope-hardening.md` debe listar los controles productivos no implementados, como KMS, rotación PKI, NetworkPolicies, SSO, SIEM y backups cifrados.

> **NOTA:** No declares “cumplimiento productivo” o “CIS compliant” por completar esta práctica. Se implementa un subconjunto representativo de controles.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}
{% include support-prompt.html task="tarea8" %}

---

## 📋 Tarea 9. Documentar la postura final — 3 min

### Tarea 9.1. Crear matriz final

- {% include step_label.html %} Documenta únicamente controles que fueron implementados o verificados durante el laboratorio para validar el resultado antes de continuar.

  ```bash
  cat > outputs/security-posture-final.md << 'EOF'
  
  # Matriz de postura de seguridad — estado final
  
  | Superficie | Estado final | Evidencia |
  |---|---|---|
  | Exposición pública Couchbase | Sin LoadBalancer público del laboratorio | kubernetes-services-final.json |
  | Administración | TLS verificado por 18091 | Managed TLS + cliente Linux |
  | Query | TLS verificado por 18093 | Query Service HTTPS desde cb-security-client |
  | TLS mínimo | TLS 1.2 | security-settings-final.json |
  | Node-to-node | All | Operator + Couchbase settings |
  | UI HTTP | Deshabilitada | disableUIOverHttp=true |
  | RBAC reader | KV read sin write | rbac-reader-test.txt |
  | RBAC query | SELECT sin INSERT | pruebas positiva/negativa |
  | RBAC index | Gestión GSI sin lectura | prueba svc-index |
  | Client X.509 | Habilitado declarativamente por Operator | operator-tls-final.json + client-cert-auth.json |
  | mTLS | Identidad svc-mtls-client resuelta como usuario local | mtls-management-response.json |
  | Auditoría | Habilitada | audit-settings-after.json |
  | Retención audit | 7 días | pruneAge=604800 |
  | Vista cluster-wide | Logs consolidados por Pod | audit-all.jsonl |
  | Material privado en Git | Excluido | .gitignore |
  EOF
  ```

**Salida esperada:** `security-posture-final.md` debe contener la matriz final con cada control realmente implementado y la evidencia local asociada a TLS, RBAC, mTLS y auditoría.

- {% include step_label.html %} Muestra la matriz final para comprobar que cada control tenga estado, evidencia y observaciones antes de generar el reporte consolidado.

  ```bash
  cat outputs/security-posture-final.md
  ```

**Salida esperada:** La terminal debe imprimir la matriz completa de postura final, incluyendo estado y archivo de evidencia para exposición, TLS, RBAC, mTLS y auditoría.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}
{% include support-prompt.html task="tarea9" %}

---

## ✅ Tarea 10. Validación integral y reporte — 3 min

### Tarea 10.1. Crear validate.sh

- {% include step_label.html %} Crea una suite final basada en estados objetivos para validar TLS, RBAC, mTLS, auditoría y configuración declarativa sin depender de mensajes transitorios del Operator.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab6/validate.sh
  ```

**Salida esperada:** `validate.sh` debe comprobar Query TLS con `probe_value`, HTTPS, cifrado inter-node, RBAC, identidad mTLS real, client certificate auth, auditoría, logs y estado declarativo del Operator.

- {% include step_label.html %} Asigna permisos a la suite, ejecútala y conserva la salida completa para impedir que la limpieza continúe cuando exista al menos una validación fallida.

  ```bash
  chmod +x scripts/validate.sh
  
  ./scripts/validate.sh \
    | tee outputs/validation-final.txt
  ```

**Salida esperada:** La ejecución debe terminar con líneas `PASS` para todos los controles y `RESULTADO: <n> PASS / 0 FAIL`; la evidencia queda en `outputs/validation-final.txt`.

### Tarea 10.2. Generar reporte consolidado

- {% include step_label.html %} Agrupa las evidencias esenciales para que permanezcan disponibles después de destruir EKS y conserva evidencia suficiente para la revisión posterior.

  ```bash
  {
    echo "============================================================"
    echo "REPORTE FINAL - LAB 6 SEGURIDAD"
    echo "Fecha: $(date)"
    echo "============================================================"
  
    echo
    echo "--- VALIDACIÓN ---"
    cat outputs/validation-final.txt
  
    echo
    echo "--- SECURITY SETTINGS ---"
    cat outputs/security-settings-final.json
  
    echo
    echo "--- CLIENT CERT AUTH ---"
    cat outputs/client-cert-auth.json
  
    echo
    echo "--- AUDIT SETTINGS ---"
    cat outputs/audit-settings-after.json
  
    echo
    echo "--- AUDIT ANALYSIS ---"
    cat outputs/audit-analysis.txt
  
    echo
    echo "--- POSTURA FINAL ---"
    cat outputs/security-posture-final.md
  } | tee outputs/final-summary.txt
  ```

**Salida esperada:** `final-summary.txt` debe reunir la validación, settings de seguridad, client certificate auth, auditoría, análisis de logs y matriz final antes de destruir EKS.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}
{% include support-prompt.html task="tarea10" %}

---

## 🧹 Limpieza funcional

La limpieza es opcional si la siguiente práctica reutilizará el clúster. Si vas a destruir EKS, no es necesario revertir Managed TLS primero.

## Eliminar identidades temporales

- {% include step_label.html %} Elimina usuarios y grupos creados para las pruebas para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  for user in svc-reader svc-query svc-index svc-mtls-client; do
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-security-client \
      -- \
      curl -sS \
        --cacert /tmp/lab6-certs/ca.crt \
        -u "$CB_USER:$CB_PASS" \
        -X DELETE \
        "https://${CB_TLS_HOST}:18091/settings/rbac/users/local/${user}" \
        -o /dev/null || true
  done
  
  for group in app-data-readers app-query-executors app-index-admins; do
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "$CB_NAMESPACE" \
      cb-security-client \
      -- \
      curl -sS \
        --cacert /tmp/lab6-certs/ca.crt \
        -u "$CB_USER:$CB_PASS" \
        -X DELETE \
        "https://${CB_TLS_HOST}:18091/settings/rbac/groups/${group}" \
        -o /dev/null || true
  done
  ```

**Salida esperada:** Los DELETE deben completar sin errores bloqueantes; `svc-reader`, `svc-query`, `svc-index`, `svc-mtls-client` y los tres grupos temporales dejan de existir.

## Eliminar collection experimental

- {% include step_label.html %} Elimina `security_lab6`; las collections originales de `travel-sample` permanecen intactas y conserva evidencia suficiente para la revisión posterior.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n "$CB_NAMESPACE" \
    cb-security-client \
    -- \
    curl -sS \
      --cacert /tmp/lab6-certs/ca.crt \
      -u "$CB_USER:$CB_PASS" \
      -X POST \
      "https://${CB_TLS_HOST}:18093/query/service" \
      --data-urlencode 'statement=
        DROP COLLECTION IF EXISTS `travel-sample`.inventory.security_lab6;' \
    | jq '{status, errors}'
  ```

**Salida esperada:** Query Service debe devolver `status: success`; `security_lab6` y sus índices asociados deben desaparecer sin modificar las collections originales de `travel-sample`.

- {% include step_label.html %} Elimina el Pod cliente Python para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  kubectl delete pod cb-security-client \
    -n couchbase \
    --ignore-not-found
  ```

**Salida esperada:** Kubernetes debe responder `pod "cb-security-client" deleted` o no generar error si ya no existe debido a `--ignore-not-found`.

---

## ☁️ Eliminación de Amazon EKS

- {% include step_label.html %} Confirma que la evidencia final existe antes de destruir EKS, incluso si la limpieza funcional ya eliminó `cb-security-client` y sus archivos temporales.

  ```bash
  test -s outputs/validation-final.txt   && test -s outputs/final-summary.txt   && echo "Evidencias finales disponibles; EKS puede eliminarse."
  ```

**Salida esperada:** Debe imprimirse `Evidencias finales disponibles; EKS puede eliminarse.`; la eliminación del Pod cliente durante la limpieza no afecta los archivos guardados localmente.

- {% include step_label.html %} Elimina Amazon EKS utilizando el script de ciclo de vida para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  cd /c/LABS/couchbase-nosql/lab6
  source lab.env
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada:** `eksctl` debe mostrar el progreso de eliminación del managed node group y del control plane hasta finalizar sin errores de CloudFormation o recursos pendientes.

- {% include step_label.html %} Confirma que AWS ya no encuentre el clúster para obtener evidencia objetiva del resultado antes de continuar con la actividad siguiente.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:** AWS CLI debe devolver `ResourceNotFoundException`, confirmando que el control plane de `$EKS_CLUSTER` ya no existe en `$AWS_REGION`.

  ```text
  ResourceNotFoundException
  ```