---
layout: lab
title: "Práctica 1: Análisis de la arquitectura y distribución interna de un clúster"
permalink: /lab1/lab1/
images_base: /labs/lab1/img
duration: "60 minutos"
objective:
  - Preparar las herramientas locales necesarias para administrar AWS, Amazon EKS, Kubernetes y Couchbase desde Visual Studio Code con Git Bash.
  - Crear de forma reproducible un clúster Amazon EKS con nodos administrados y almacenamiento persistente basado en Amazon EBS gp3.
  - Instalar Couchbase Kubernetes Operator y desplegar Couchbase Server Enterprise 7.6.2 con una topología MDS de cuatro Pods.
  - Cargar travel-sample y analizar la distribución de 1024 vBuckets activos y réplicas entre los dos Pods que ejecutan Data Service.
  - Correlacionar Pods de Kubernetes, servicios Couchbase, Cluster Map, REST API y Web Console para documentar la topología observada.
  - Eliminar al finalizar el clúster EKS y sus recursos asociados para evitar mantener infraestructura de laboratorio generando costos.
prerequisites:
  - Contar con una cuenta de AWS habilitada para crear Amazon EKS, EC2, VPC, IAM, CloudFormation y volúmenes Amazon EBS.
  - Tener Visual Studio Code y Git Bash instalados en Windows.
  - Tener AWS CLI v2 configurado con credenciales válidas para la cuenta de laboratorio.
  - Tener eksctl 0.215.0 o superior disponible en PATH.
  - Tener kubectl compatible con Kubernetes 1.35 y disponible en PATH.
  - Tener Helm 3 instalado para desplegar Couchbase Kubernetes Operator.
  - Tener curl y jq disponibles desde Git Bash.
  - Disponer de acceso a Internet para descargar imágenes de contenedor, charts de Helm y dependencias de Amazon EKS.
introduction:
  - En esta práctica desplegarás Couchbase Server Enterprise 7.6.2 sobre Amazon EKS utilizando Couchbase Kubernetes Operator. Crearás una topología MDS con dos Pods Data + Query, un Pod Index + Search y un Pod Analytics + Eventing. Después cargarás travel-sample, analizarás el Cluster Map y comprobarás cómo los 1024 vBuckets activos y sus réplicas se distribuyen únicamente entre los Pods que ejecutan Data Service. Amazon EKS funcionará como infraestructura del laboratorio; el objetivo principal seguirá siendo comprender la arquitectura interna de Couchbase y la relación entre servicios, nodos, vBuckets y mecanismos de administración.
slug: lab1
lab_number: 1
final_result: >
  Al finalizar la práctica tendrás un clúster Couchbase Server Enterprise 7.6.2 administrado por Couchbase Kubernetes Operator sobre Amazon EKS. Habrás identificado la topología MDS, comprobado la distribución de vBuckets activos y réplicas entre dos nodos Data, consultado el Cluster Map mediante REST API, relacionado Pods de Kubernetes con nodos Couchbase y eliminado de forma controlada la infraestructura AWS creada para el laboratorio.
notes:
  - Todos los comandos de terminal deben ejecutarse desde Git Bash dentro de Visual Studio Code.
  - La práctica fija Kubernetes 1.35 para mantener compatibilidad con Couchbase Kubernetes Operator 2.9.x.
  - El clúster utiliza instancias EC2 administradas por EKS y volúmenes Amazon EBS; estos recursos pueden generar cargos mientras permanezcan activos.
  - La eliminación de Amazon EKS al final de la práctica es obligatoria salvo que el instructor indique expresamente conservarlo.
  - Las contraseñas empleadas son exclusivas del laboratorio y no deben reutilizarse en ambientes reales.
references:
  - text: Instalación de AWS CLI
    url: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
  - text: Instalación de eksctl para Amazon EKS
    url: https://docs.aws.amazon.com/eks/latest/eksctl/installation.html
  - text: Instalación oficial de eksctl
    url: https://eksctl.io/installation/
  - text: Instalación de kubectl en Windows
    url: https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/
  - text: Instalación de Helm
    url: https://helm.sh/docs/intro/install/
  - text: Instalación de jq
    url: https://jqlang.org/download/
  - text: Introducción a Amazon EKS con eksctl
    url: https://docs.aws.amazon.com/eks/latest/userguide/getting-started-eksctl.html
  - text: Amazon EBS CSI Driver para Amazon EKS
    url: https://docs.aws.amazon.com/eks/latest/userguide/ebs-csi.html
  - text: Prerrequisitos y preparación de Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/prerequisite-and-setup.html
  - text: Instalación de Couchbase Kubernetes Operator con Helm
    url: https://docs.couchbase.com/operator/current/helm-setup-guide.html
  - text: Creación de un clúster Couchbase con Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/howto-couchbase-create.html
  - text: Volúmenes persistentes en Couchbase Kubernetes Operator
    url: https://docs.couchbase.com/operator/current/concept-persistent-volumes.html
  - text: vBuckets en Couchbase Server 7.6
    url: https://docs.couchbase.com/server/7.6/learn/buckets-memory-and-storage/vbuckets.html
  - text: Instalación de buckets de ejemplo en Couchbase Server
    url: https://docs.couchbase.com/server/current/manage/manage-settings/install-sample-buckets.html
prev: /
next: /lab2/lab2/
---

---
<!-- Aquí comienzan las instrucciones paso a paso de la práctica -->

## 📁 Preparación del directorio de trabajo

En esta práctica crearás la infraestructura Amazon EKS desde tu equipo Windows y almacenarás scripts, manifiestos y resultados dentro del directorio `lab1`. Los archivos generados se conservarán aunque el clúster EKS sea eliminado al finalizar.

### 🗂️ Crear y abrir el subdirectorio de la práctica

- {% include step_label.html %} Abre **Visual Studio Code** y espera su carga completa, porque utilizarás el Explorador y la terminal integrada para crear scripts, manifiestos Kubernetes y evidencias del laboratorio.

- {% include step_label.html %} En **File → Open Folder**, abre `C:\LABS\couchbase-nosql` para mantener la práctica dentro del directorio raíz utilizado durante el curso. **Crea la carpeta sino existe en la misma ruta**

  ```text
  C:\LABS\couchbase-nosql
  ```

- {% include step_label.html %} Selecciona **Terminal → New Terminal** y confirma que el perfil activo sea **Git Bash**, ya que los scripts del laboratorio utilizan Bash, variables de entorno y utilidades POSIX.

- {% include step_label.html %} Ejecuta los comandos siguientes para crear la estructura de `lab1` destinada a scripts, manifiestos y resultados sin generar error si alguna carpeta ya existe.

  ```bash
  mkdir -p /c/LABS/couchbase-nosql/lab1/{scripts,manifests,outputs}
  cd /c/LABS/couchbase-nosql/lab1
  ```

- {% include step_label.html %} Ejecuta `pwd` y `find` para confirmar la ubicación activa y verificar que los tres subdirectorios requeridos quedaron disponibles antes de crear infraestructura.

  ```bash
  pwd
  find . -maxdepth 1 -type d | sort
  ```

**Salida esperada:**

```text
/c/LABS/couchbase-nosql/lab1
.
./manifests
./outputs
./scripts
```

> **IMPORTANTE:** No ejecutes scripts de creación de infraestructura desde otra ruta. Los archivos YAML y las evidencias se generan mediante rutas relativas a `lab1`.
{: .lab-note .important .compact}

---

## 🧰 Herramientas requeridas y enlaces oficiales

La siguiente tabla concentra las herramientas utilizadas durante la práctica. Instálalas únicamente desde los sitios oficiales indicados para reducir problemas de versiones, binarios modificados o paquetes no soportados.

| Herramienta | Uso en la práctica | Descarga / instalación oficial |
|---|---|---|
| AWS CLI v2 | Autenticación y consultas de recursos AWS | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| eksctl | Creación y eliminación reproducible de Amazon EKS | https://eksctl.io/installation/ |
| kubectl | Administración del clúster Kubernetes | https://kubernetes.io/docs/tasks/tools/install-kubectl-windows/ |
| Helm 3 | Instalación de Couchbase Kubernetes Operator | https://helm.sh/docs/intro/install/ |
| jq | Procesamiento de respuestas JSON | https://jqlang.org/download/ |
| Git for Windows | Git Bash y herramientas de terminal | https://git-scm.com/download/win |
| Visual Studio Code | Editor y terminal integrada | https://code.visualstudio.com/download |
| Couchbase Operator | Documentación y descargas del producto | https://www.couchbase.com/downloads/ |

> **NOTA:** Couchbase Kubernetes Operator 2.9.x soporta Couchbase Server Enterprise 7.2–8.0 y plataformas Kubernetes 1.31–1.35. Por esta razón el script fija Amazon EKS en Kubernetes 1.35 en lugar de utilizar automáticamente una versión posterior.
{: .lab-note .info .compact}

---

## 🔎 Tarea 1. Validar herramientas locales y acceso a AWS

En esta tarea confirmarás que las herramientas de administración están disponibles y que AWS CLI puede identificar la cuenta antes de generar recursos facturables.

### Tarea 1.1. Comprobar versiones instaladas

- {% include step_label.html %} Ejecuta las verificaciones siguientes para confirmar que AWS CLI, `eksctl`, `kubectl`, Helm y `jq` pueden resolverse desde el `PATH` utilizado por Git Bash.

  ```bash
  aws --version
  eksctl version
  kubectl version --client
  helm version --short
  jq --version
  ```

**Validación:**

- `aws --version` debe indicar AWS CLI v2.
- `eksctl version` debe ser `0.215.0` o superior.
- `kubectl version --client` debe responder sin intentar conectarse todavía a un clúster.
- Helm debe corresponder a la línea 3.x.
- `jq` debe devolver su versión instalada.

> **IMPORTANTE:** Si un comando devuelve `command not found`, instala la herramienta mediante el enlace oficial de la tabla anterior, cierra y vuelve a abrir Git Bash para actualizar el `PATH`.
{: .lab-note .important .compact}

### Tarea 1.2. Validar la identidad AWS activa

- {% include step_label.html %} Ejecuta `aws sts get-caller-identity` para confirmar que las credenciales actuales son válidas y registrar la cuenta donde se crearán EKS, EC2, VPC, IAM y EBS.

  ```bash
  aws sts get-caller-identity
  ```

**Salida esperada aproximada:**

```json
{
    "UserId": "...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/..."
}
```

- {% include step_label.html %} Guarda la identidad en `outputs/aws-identity.json` para conservar una evidencia de la cuenta empleada sin almacenar claves de acceso ni secretos.

  ```bash
  aws sts get-caller-identity --output json > outputs/aws-identity.json
  cat outputs/aws-identity.json | jq .
  ```

> **IMPORTANTE:** Nunca registres `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, tokens de sesión o archivos de credenciales dentro del repositorio del laboratorio.
{: .lab-note .important .compact}

### Tarea 1.3. Definir variables comunes del laboratorio

- {% include step_label.html %} Crea el archivo `lab.env` con nombres y versiones reutilizables para evitar diferencias entre los comandos de creación, validación y eliminación.

  ```bash
  cat > lab.env << 'EOF'
  export AWS_REGION="us-west-2"
  export EKS_CLUSTER="cb-cs400-lab01"
  export EKS_VERSION="1.35"
  export EKS_NODEGROUP="cb-workers"
  export CB_NAMESPACE="couchbase"
  export CB_CLUSTER="cb-cs400"
  export CB_USER="Administrator"
  export CB_PASS="Password123!"
  export CB_IMAGE="couchbase/server:enterprise-7.6.2"
  export CB_OPERATOR_VERSION="2.92.0"
  EOF
  ```

- {% include step_label.html %} Carga las variables en la terminal actual y muestra únicamente valores no sensibles para confirmar que el laboratorio utilizará la región y nombres previstos.

  ```bash
  source lab.env
  printf 'AWS_REGION=%s\nEKS_CLUSTER=%s\nEKS_VERSION=%s\nCB_CLUSTER=%s\nCB_IMAGE=%s\n' \
    "$AWS_REGION" "$EKS_CLUSTER" "$EKS_VERSION" "$CB_CLUSTER" "$CB_IMAGE"
  ```

**Salida esperada:**

```text
AWS_REGION=us-west-2
EKS_CLUSTER=cb-cs400-lab01
EKS_VERSION=1.35
CB_CLUSTER=cb-cs400
CB_IMAGE=couchbase/server:enterprise-7.6.2
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r1 %}{{ results[0] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r1 %}

{% include support-prompt.html task="tarea1" %}

---

## ☁️ Tarea 2. Crear el script de ciclo de vida de Amazon EKS

En esta tarea construirás `eks-cluster.sh`, responsable de crear y eliminar la infraestructura EKS. El script evita depender de pasos manuales en la consola de AWS y proporciona una operación de limpieza repetible al terminar.

### Tarea 2.1. Crear el script eks-cluster.sh

- {% include step_label.html %} Crea `scripts/eks-cluster.sh` con validaciones previas, generación del archivo `eksctl`, creación de EKS, instalación del EBS CSI Driver y eliminación completa mediante `eksctl delete cluster`.

  ```bash
  curl -L -o scripts/eks-cluster.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab1/eks-cluster.sh
  ```

- {% include step_label.html %} Asigna permiso de ejecución al script y valida su sintaxis con Bash antes de permitir que cree recursos dentro de la cuenta AWS.

  ```bash
  chmod +x scripts/eks-cluster.sh
  bash -n scripts/eks-cluster.sh
  ```

**Salida esperada:**

`bash -n` no debe mostrar ninguna salida. Cualquier mensaje indica un error de sintaxis que debe corregirse antes de continuar.

> **NOTA:** El script fija tres nodos administrados `m6i.large`. Esta configuración está dimensionada para un laboratorio temporal con cuatro Pods Couchbase; no representa un sizing de producción.
{: .lab-note .info .compact}

### Tarea 2.2. Comprender la infraestructura que generará eksctl

- {% include step_label.html %} Revisa `manifests/eks-cluster.yaml` después de ejecutar la creación en la siguiente subtarea y relaciona los componentes declarados con la infraestructura que AWS aprovisionará.

| Componente | Función en el laboratorio |
|---|---|
| Amazon EKS Control Plane | Ejecuta la API y componentes administrados de Kubernetes |
| Managed Node Group | Proporciona tres instancias EC2 para ejecutar los Pods |
| VPC / subnets | Proporciona conectividad a EKS y a sus nodos |
| EKS Pod Identity Agent | Permite asignar permisos AWS a add-ons compatibles |
| Amazon EBS CSI Driver | Aprovisiona PersistentVolumes respaldados por EBS |
| CoreDNS | Resolución DNS interna de Kubernetes |
| VPC CNI | Integración de networking de Pods con la VPC |

> **IMPORTANTE:** `eksctl create cluster` crea recursos mediante AWS CloudFormation. La eliminación debe realizarse con el mismo nombre y región para permitir que `eksctl` retire correctamente las pilas relacionadas.
{: .lab-note .important .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r2 %}{{ results[1] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r2 %}

{% include support-prompt.html task="tarea2" %}

---

## 🚀 Tarea 3. Crear Amazon EKS y validar almacenamiento

En esta tarea ejecutarás el script de infraestructura. La operación creará recursos AWS reales, por lo que primero validarás la identidad y después confirmarás nodos, add-ons y disponibilidad del EBS CSI Driver.

### Tarea 3.1. Crear el clúster EKS

- {% include step_label.html %} Carga nuevamente `lab.env` para garantizar que la terminal utiliza los nombres y la región definidos por la práctica antes de iniciar el aprovisionamiento.

  ```bash
  source lab.env
  ```

- {% include step_label.html %} Ejecuta la acción `create` del script para generar EKS, el Managed Node Group, los add-ons y la configuración local de `kubectl`. **El cluster tarda aproximadamente 16 minutos**

  ```bash
  ./scripts/eks-cluster.sh create
  ```

**Salida esperada aproximada:**

Al finalizar deben aparecer mensajes equivalentes a:

```text
EKS cluster "cb-cs400-lab01" ... is ready
node/... condition met
```

### Tarea 3.2. Verificar control plane y nodos

- {% include step_label.html %} Ejecuta el subcomando `status` para confirmar que el clúster existe y que los tres nodos administrados responden desde el contexto Kubernetes local.

  ```bash
  ./scripts/eks-cluster.sh status
  ```

- {% include step_label.html %} Consulta directamente los nodos para comprobar que el `STATUS` sea `Ready` y registrar versión, IP interna y tipo de instancia de cada worker.

  ```bash
  kubectl get nodes \
    -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone \
    -o wide
  ```

**Validación:**

Deben existir tres nodos `Ready`.

### Tarea 3.3. Verificar el EBS CSI Driver

- {% include step_label.html %} Consulta el add-on administrado por Amazon EKS para confirmar que `aws-ebs-csi-driver` llegó al estado `ACTIVE` antes de solicitar volúmenes persistentes.

  ```bash
  aws eks describe-addon \
    --cluster-name "$EKS_CLUSTER" \
    --addon-name aws-ebs-csi-driver \
    --region "$AWS_REGION" \
    --query 'addon.{name:addonName,status:status,version:addonVersion}' \
    --output table
  ```

**Salida esperada aproximada:**

```text
-----------------------------------------
|             DescribeAddon             |
+----------------------+----------------+
| name                 | status         |
+----------------------+----------------+
| aws-ebs-csi-driver   | ACTIVE         |
+----------------------+----------------+
```

- {% include step_label.html %} Comprueba que los Pods del controlador EBS estén disponibles en `kube-system`, porque esos componentes atenderán las solicitudes de PersistentVolumeClaim.

  ```bash
  kubectl get pods -n kube-system \
    -l app.kubernetes.io/name=aws-ebs-csi-driver
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r3 %}{{ results[2] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r3 %}

{% include support-prompt.html task="tarea3" %}

---

## 🗄️ Tarea 4. Preparar almacenamiento gp3 e instalar Couchbase Kubernetes Operator

En esta tarea crearás una StorageClass basada en Amazon EBS gp3 y desplegarás únicamente el Operator y el Admission Controller. El clúster Couchbase se declarará después mediante YAML para mantener visible su diseño MDS.

### Tarea 4.1. Crear la StorageClass gp3

- {% include step_label.html %} Crea `manifests/storageclass-gp3.yaml` con `WaitForFirstConsumer`, permitiendo que Kubernetes seleccione la zona de disponibilidad después de conocer dónde se programará el Pod Couchbase.

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

- {% include step_label.html %} Aplica la StorageClass y consulta sus propiedades para confirmar que el provisioner sea `ebs.csi.aws.com` y el modo de binding sea `WaitForFirstConsumer`.

  ```bash
  kubectl apply -f manifests/storageclass-gp3.yaml
  kubectl get storageclass gp3-couchbase -o wide
  ```

**Salida esperada aproximada:**

```text
NAME              PROVISIONER      RECLAIMPOLICY   VOLUMEBINDINGMODE
gp3-couchbase     ebs.csi.aws.com  Delete          WaitForFirstConsumer
```

### Tarea 4.2. Instalar Couchbase Kubernetes Operator con Helm

- {% include step_label.html %} Agrega el repositorio oficial de charts de Couchbase y actualiza su índice local para que Helm conozca las versiones disponibles del Operator.

  ```bash
  helm repo add couchbase https://couchbase-partners.github.io/helm-charts/
  helm repo update
  ```

- {% include step_label.html %} Consulta las versiones disponibles del chart y confirma que la línea 2.92.x está disponible antes de fijar la versión utilizada por el laboratorio.

  ```bash
  helm search repo couchbase/couchbase-operator --versions | head -n 10
  ```

- {% include step_label.html %} Instala Couchbase Kubernetes Operator 2.92.0 y el Admission Controller en el namespace `couchbase`, deshabilitando el clúster predeterminado del chart para crear después nuestra topología MDS personalizada.

  ```bash
  helm upgrade --install cb-operator couchbase/couchbase-operator \
    --namespace couchbase \
    --create-namespace \
    --version "$CB_OPERATOR_VERSION" \
    --set install.couchbaseCluster=false
  ```

- {% include step_label.html %} Espera la disponibilidad del Operator y del Admission Controller antes de aplicar recursos `CouchbaseCluster`, evitando que una validación ocurra mientras los componentes todavía inician.

  ```bash
  kubectl wait \
    --namespace couchbase \
    --for=condition=Available \
    deployment \
    --all \
    --timeout=5m
  ```

- {% include step_label.html %} Lista los deployments y las CustomResourceDefinitions de Couchbase para comprobar que Kubernetes ya reconoce los recursos administrados por el Operator.

  ```bash
  kubectl get deployments -n couchbase
  kubectl api-resources | grep -i couchbase
  ```

**Validación:**

Deben estar disponibles el Operator y el Admission Controller, y `kubectl api-resources` debe incluir `CouchbaseCluster`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r4 %}{{ results[3] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r4 %}

{% include support-prompt.html task="tarea4" %}

---

## 🧩 Tarea 5. Desplegar Couchbase Server Enterprise 7.6.2 con MDS

En esta tarea definirás un clúster de cuatro Pods. Dos Pods ejecutarán Data + Query para permitir vBuckets activos y réplicas; los servicios especializados quedarán separados en clases MDS independientes.

### Tarea 5.1. Crear el secreto administrativo

- {% include step_label.html %} Genera `manifests/cb-admin-secret.yaml` con `kubectl create secret --dry-run` para evitar escribir manualmente valores Base64 y conservar una definición reproducible.

  ```bash
  kubectl create secret generic cb-admin \
    --namespace couchbase \
    --from-literal=username="$CB_USER" \
    --from-literal=password="$CB_PASS" \
    --dry-run=client \
    -o yaml \
    > manifests/cb-admin-secret.yaml
  ```

- {% include step_label.html %} Aplica el secreto en el namespace y consulta únicamente sus claves, sin decodificar el contenido sensible en la terminal.

  ```bash
  kubectl apply -f manifests/cb-admin-secret.yaml
  kubectl get secret cb-admin -n couchbase \
    -o json | jq '.data | keys'
  ```

**Salida esperada:**

```json
[
  "password",
  "username"
]
```

### Tarea 5.2. Crear el manifiesto CouchbaseCluster

- {% include step_label.html %} Crea `manifests/couchbase-cluster.yaml` con cuatro Pods organizados en tres clases de servidor y almacenamiento persistente EBS gp3 para conservar datos durante reemplazos de Pods dentro del laboratorio.

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
      exposeAdminConsole: true
      adminConsoleServices:
        - data

    servers:
      - name: data-query
        size: 2
        services:
          - data
          - query
        volumeMounts:
          default: couchbase-volume

      - name: index-search
        size: 1
        services:
          - index
          - search
        volumeMounts:
          default: couchbase-volume

      - name: analytics-eventing
        size: 1
        services:
          - analytics
          - eventing
        volumeMounts:
          default: couchbase-volume

    volumeClaimTemplates:
      - metadata:
          name: couchbase-volume
        spec:
          storageClassName: gp3-couchbase
          resources:
            requests:
              storage: 10Gi
  EOF
  ```

> **NOTA:** Dos Pods ejecutan Data Service deliberadamente. Con un solo nodo Data no existiría otro destino KV donde colocar la réplica de cada vBucket, aunque el bucket solicitara `replicaNumber=1`.
{: .lab-note .info .compact}

### Tarea 5.3. Desplegar la topología declarativa

- {% include step_label.html %} Aplica el manifiesto para entregar al Operator el estado deseado del clúster; a partir de este momento el Operator creará Pods, configurará Couchbase e iniciará los rebalanceos necesarios.

  ```bash
  kubectl apply -f manifests/couchbase-cluster.yaml
  ```

- {% include step_label.html %} Observa periódicamente los Pods del namespace hasta que existan cuatro Pods Couchbase en estado `Running`, además de los componentes del Operator. **Puede tardar hasta 1 minuto o minuto y medio en aparcer el primero**

  ```bash
  kubectl get pods -n couchbase -o wide
  ```

- {% include step_label.html %} Espera que el recurso `CouchbaseCluster` reporte condición disponible antes de cargar datos y consultar el Cluster Map.

  ```bash
  kubectl wait \
    --namespace couchbase \
    --for=condition=Available \
    couchbasecluster/cb-cs400 \
    --timeout=15m
  ```

- {% include step_label.html %} Consulta el estado resumido del recurso para verificar que el Operator terminó la reconciliación de la topología solicitada.

  ```bash
  kubectl get couchbasecluster cb-cs400 \
    -n couchbase \
    -o wide
  ```

### Tarea 5.4. Verificar PersistentVolumeClaims y EBS

- {% include step_label.html %} Lista los PVC para confirmar que los cuatro Pods Couchbase disponen de almacenamiento solicitado mediante `gp3-couchbase` y que todos estén en estado `Bound`.

  ```bash
  kubectl get pvc -n couchbase
  ```

- {% include step_label.html %} Lista los PersistentVolumes para correlacionar cada PVC con un volumen dinámicamente aprovisionado por el EBS CSI Driver.

  ```bash
  kubectl get pv \
    -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,CLASS:.spec.storageClassName,CAPACITY:.spec.capacity.storage,CLAIM:.spec.claimRef.name'
  ```

**Validación:**

Todos los PVC Couchbase deben mostrar `STATUS=Bound`.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r5 %}{{ results[4] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r5 %}

{% include support-prompt.html task="tarea5" %}

---

## 🌐 Tarea 6. Acceder a la Web Console y validar la topología MDS

En esta tarea utilizarás `kubectl port-forward` para acceder de manera temporal a la Web Console sin crear un LoadBalancer público y comprobarás los servicios asignados por el Operator.

### Tarea 6.1. Identificar los servicios Kubernetes creados

- {% include step_label.html %} Lista los Services del namespace para identificar los endpoints generados automáticamente por el Operator, incluido el servicio de administración terminado en `-ui`.

  ```bash
  kubectl get service -n couchbase
  ```

**Resultado esperado aproximado:**

Debes observar servicios relacionados con `cb-cs400`, entre ellos un servicio de administración semejante a:

```text
cb-cs400-ui
```

### Tarea 6.2. Crear el port-forward administrativo

- {% include step_label.html %} Ejecuta el siguiente comando en una **segunda terminal Git Bash** y mantenla abierta para exponer localmente el puerto 8091 de Couchbase únicamente durante la práctica.

  ```bash
  kubectl port-forward \
    -n couchbase \
    service/cb-cs400-ui \
    8091:8091
  ```

**Salida esperada:**

```text
Forwarding from 127.0.0.1:8091 -> 8091
```

> **IMPORTANTE:** No cierres esta segunda terminal mientras utilices la Web Console o los comandos `curl` dirigidos a `localhost:8091`.
{: .lab-note .important .compact}

### Tarea 6.3. Validar Couchbase mediante REST API

- {% include step_label.html %} Regresa a la terminal principal y consulta `/pools/default` para comprobar que Couchbase responde a través del port-forward y expone los nodos administrados por el Operator.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '{
        clusterName: .clusterName,
        rebalanceStatus: .rebalanceStatus,
        nodes: [
          .nodes[] |
          {
            hostname: .hostname,
            status: .status,
            membership: .clusterMembership,
            services: .services
          }
        ]
      }'
  ```

**Validación:**

Debes identificar:

- 2 nodos con `kv` y `n1ql`.
- 1 nodo con `index` y `fts`.
- 1 nodo con `cbas` y `eventing`.
- Todos los nodos deben mostrarse `healthy` y `active`.

### Tarea 6.4. Correlacionar Kubernetes y Couchbase

- {% include step_label.html %} Ejecuta la primera consulta para registrar los Pods y nodos EC2 donde fueron programados, distinguiendo la infraestructura Kubernetes de los servicios internos de Couchbase.

  ```bash
  kubectl get pods -n couchbase \
    -o custom-columns='POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,POD_IP:.status.podIP'
  ```

- {% include step_label.html %} Ejecuta la consulta REST nuevamente y compara los hostnames Couchbase con los Pods mostrados por Kubernetes para reconocer que un Pod Couchbase representa un miembro del clúster administrado.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default \
    | jq '[.nodes[] | {hostname, services, status}]'
  ```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r6 %}{{ results[5] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r6 %}

{% include support-prompt.html task="tarea6" %}

---

## 🧳 Tarea 7. Cargar travel-sample y comprobar su disponibilidad

En esta tarea instalarás el dataset oficial `travel-sample` mediante la REST API de Couchbase y esperarás hasta que su carga termine antes de analizar vBuckets.

### Tarea 7.1. Consultar los sample buckets disponibles

- {% include step_label.html %} Solicita la lista de datasets de muestra para verificar que `travel-sample` está disponible en la imagen Couchbase Server utilizada por los Pods.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/sampleBuckets \
    | jq .
  ```

### Tarea 7.2. Instalar travel-sample

- {% include step_label.html %} Envía la solicitud de instalación para que Couchbase cree y cargue `travel-sample` con sus scopes, collections y documentos de ejemplo.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    -X POST \
    http://localhost:8091/sampleBuckets/install \
    -d '["travel-sample"]' \
    | tee outputs/travel-sample-install.json \
    | jq .
  ```

**Salida esperada aproximada:**

La respuesta debe incluir una tarea relacionada con `travel-sample`.

### Tarea 7.3. Esperar la carga del dataset

- {% include step_label.html %} Ejecuta el bucle siguiente para consultar el bucket hasta que su `itemCount` supere 60 000 documentos, evitando continuar con un mapa todavía en proceso de carga.

  ```bash
  while true; do
    ITEM_COUNT=$(
      curl -s -u "$CB_USER:$CB_PASS" \
        http://localhost:8091/pools/default/buckets/travel-sample \
        | jq -r '.basicStats.itemCount // 0'
    )

    echo "travel-sample itemCount=${ITEM_COUNT}"

    if [ "$ITEM_COUNT" -ge 60000 ] 2>/dev/null; then
      break
    fi

    sleep 10
  done
  ```

- {% include step_label.html %} Guarda un resumen del bucket para documentar cantidad de documentos, cuota, réplicas y tipo de bucket antes de estudiar su vBucket map.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/buckets/travel-sample \
    | jq '{
        name: .name,
        itemCount: .basicStats.itemCount,
        bucketType: .bucketType,
        replicaNumber: .replicaNumber,
        ramQuota: .quota.rawRAM
      }' \
    | tee outputs/travel-sample-summary.json
  ```

**Validación:**

`replicaNumber` debe mostrar `1` y `itemCount` debe ser mayor a 60 000.

{% assign results = site.data.task-results[page.slug].results %}
{% capture r7 %}{{ results[6] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r7 %}

{% include support-prompt.html task="tarea7" %}

---

## 🧠 Tarea 8. Analizar el Cluster Map y la distribución de vBuckets

En esta tarea consultarás el mapa utilizado por Couchbase para localizar vBuckets. La principal evidencia será que únicamente los dos Pods con Data Service participan en el `serverList` KV y comparten activos y réplicas.

### Tarea 8.1. Obtener el resumen del vBucketServerMap

- {% include step_label.html %} Consulta el endpoint del bucket y proyecta los campos principales del mapa para identificar el número de vBuckets, réplicas y servidores Data participantes.

  ```bash
  curl -sS \
    -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/b/travel-sample \
    | jq '{
        name: .name,
        nodeLocator: .nodeLocator,
        numVBuckets: (.vBucketServerMap.vBucketMap | length),
        numReplicas: .vBucketServerMap.numReplicas,
        serverList: .vBucketServerMap.serverList
      }'
  ```

**Salida esperada conceptual:**

```json
{
  "name": "travel-sample",
  "nodeLocator": "vbucket",
  "numVBuckets": 1024,
  "numReplicas": 1,
  "serverList": [
    "...:11210",
    "...:11210"
  ]
}
```

> **IMPORTANTE:** `serverList` debe contener los dos miembros que ejecutan Data Service. Los Pods dedicados exclusivamente a Index/Search y Analytics/Eventing no almacenan vBuckets KV del bucket.
{: .lab-note .important .compact}

### Tarea 8.2. Examinar los primeros vBuckets

- {% include step_label.html %} Muestra las primeras diez entradas de `vBucketMap` para observar el formato `[activo, réplica]`, donde cada número referencia una posición de `serverList`.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/b/travel-sample \
    | jq '.vBucketServerMap.vBucketMap[0:10]'
  ```

**Salida esperada conceptual:**

Las posiciones deben alternar entre los índices de los dos Data nodes, por ejemplo:

```json
[
  [0, 1],
  [1, 0]
]
```

La distribución exacta puede variar.

### Tarea 8.3. Contar vBuckets activos por Data node

- {% include step_label.html %} Ejecuta la consulta `jq` siguiente para agrupar la posición activa de los 1024 vBuckets y obtener la cantidad correspondiente a cada servidor Data.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/b/travel-sample \
    | jq '
      .vBucketServerMap as $m
      | $m.vBucketMap
      | group_by(.[0])
      | map({
          node_index: .[0][0],
          node: $m.serverList[.[0][0]],
          active_vbuckets: length
        })
    '
  ```

### Tarea 8.4. Contar vBuckets réplica por Data node

- {% include step_label.html %} Agrupa ahora la posición de réplica para comprobar que el segundo elemento del mapa utiliza el otro Data node y que existen 1024 asignaciones de réplica.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/b/travel-sample \
    | jq '
      .vBucketServerMap as $m
      | $m.vBucketMap
      | map(select(.[1] >= 0))
      | group_by(.[1])
      | map({
          node_index: .[0][1],
          node: $m.serverList[.[0][1]],
          replica_vbuckets: length
        })
    '
  ```

### Tarea 8.5. Validar los totales

- {% include step_label.html %} Ejecuta el resumen siguiente para confirmar que el mapa contiene exactamente 1024 vBuckets y que todas las entradas poseen una réplica válida.

  ```bash
  curl -s -u "$CB_USER:$CB_PASS" \
    http://localhost:8091/pools/default/b/travel-sample \
    | jq '{
        total_vbuckets: (.vBucketServerMap.vBucketMap | length),
        replicas_asignadas: (
          [.vBucketServerMap.vBucketMap[] | select(.[1] >= 0)] | length
        )
      }'
  ```

**Salida esperada:**

```json
{
  "total_vbuckets": 1024,
  "replicas_asignadas": 1024
}
```

> **NOTA:** Couchbase utiliza CRC32 sobre la clave para determinar el vBucket correspondiente. Evita representar el cálculo simplemente como `CRC32(key) % 1024`; para esta práctica la fuente de verdad será el `vBucketServerMap` entregado por Couchbase.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r8 %}{{ results[7] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r8 %}

{% include support-prompt.html task="tarea8" %}

---

## 🖥️ Tarea 9. Explorar y validar la arquitectura mediante CLI y REST

En esta tarea correlacionarás la topología declarada en Kubernetes con la información administrativa que expone Couchbase mediante REST y SQL++. El análisis se realizará sin depender de la Web Console ni de una sesión `kubectl port-forward`, de modo que las evidencias puedan repetirse y almacenarse de forma consistente.

### Tarea 9.1. Validar el estado general del CouchbaseCluster

- {% include step_label.html %} Consulta el recurso `CouchbaseCluster` para confirmar que el Operator terminó la reconciliación y que la condición `Available` permanece activa antes de analizar los servicios internos.

  ```bash
  kubectl get couchbasecluster cb-cs400 \
    -n couchbase \
    -o json \
    | jq '{
        name: .metadata.name,
        generation: .metadata.generation,
        conditions: [
          .status.conditions[]
          | {
              type,
              status,
              reason
            }
        ]
      }' \
    | tee outputs/couchbasecluster-status.json
  ```

**Salida esperada:**

La respuesta debe incluir una condición equivalente a:

```json
{
  "type": "Available",
  "status": "True"
}
```

- {% include step_label.html %} Verifica los Pods creados por el Operator para confirmar que las cuatro instancias Couchbase permanecen `Running`, `Ready` y sin reinicios inesperados.

  ```bash
  kubectl get pods \
    -n couchbase \
    -l couchbase_cluster=cb-cs400 \
    -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,PHASE:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName' \
    | tee outputs/couchbase-pods.txt
  ```

**Salida esperada:**

Deben aparecer cuatro Pods Couchbase con:

```text
READY=true
PHASE=Running
RESTARTS=0
```

> **NOTA:** El estado `Running` de Kubernetes confirma que el contenedor está activo, pero no sustituye la validación de salud interna de Couchbase que realizarás en el siguiente paso.
{: .lab-note .info .compact}

### Tarea 9.2. Consultar nodos y servicios MDS mediante REST

- {% include step_label.html %} Selecciona dinámicamente un Pod Couchbase y ejecuta la consulta REST desde el propio clúster para evitar depender de conexiones `port-forward` desde Windows.

  ```bash
  CB_ADMIN_POD=$(
    kubectl get pods \
      -n couchbase \
      -l couchbase_cluster=cb-cs400 \
      -o jsonpath='{.items[0].metadata.name}'
  )

  echo "Pod administrativo temporal: ${CB_ADMIN_POD}"
  ```

- {% include step_label.html %} Consulta `/pools/default` desde el Pod seleccionado y guarda la topología lógica, el estado de rebalance y los servicios asignados a cada miembro.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$CB_ADMIN_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      http://127.0.0.1:8091/pools/default \
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
    | tee outputs/cluster-services.json
  ```

**Salida esperada:**

La respuesta debe representar la distribución MDS definida en el manifiesto:

| Tipo esperado        | Cantidad | Servicios REST esperados |
| -------------------- | -------: | ------------------------ |
| Data + Query         |        2 | `kv`, `n1ql`             |
| Index + Search       |        1 | `index`, `fts`           |
| Analytics + Eventing |        1 | `cbas`, `eventing`       |

Los cuatro miembros deben indicar:

```text
status = healthy
clusterMembership = active
rebalanceStatus = none
```

- {% include step_label.html %} Resume automáticamente cuántos nodos ejecutan cada servicio para comprobar que la topología real coincide con las server classes declaradas.

  ```bash
  jq '
    [
      .nodes[].services[]
    ]
    | group_by(.)
    | map({
        service: .[0],
        nodes: length
      })
  ' outputs/cluster-services.json \
    | tee outputs/service-distribution.json
  ```

**Salida esperada:**

Debe observarse una distribución equivalente a:

```text
kv       → 2
n1ql     → 2
index    → 1
fts      → 1
cbas     → 1
eventing → 1
```

### Tarea 9.3. Examinar `travel-sample`, replicas y vBuckets

- {% include step_label.html %} Consulta el bucket `travel-sample` mediante REST para registrar tipo, cantidad de documentos, replica count y cuota de memoria sin depender de la interfaz gráfica.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$CB_ADMIN_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      http://127.0.0.1:8091/pools/default/buckets/travel-sample \
    | jq '{
        name: .name,
        itemCount: .basicStats.itemCount,
        bucketType: .bucketType,
        replicaNumber: .replicaNumber,
        ramQuota: .quota.rawRAM
      }' \
    | tee outputs/travel-sample-summary.json
  ```

**Salida esperada:**

La respuesta debe incluir valores equivalentes a:

```text
name = travel-sample
itemCount > 0
bucketType = membase
replicaNumber = 1
nodeLocator = vbucket
numVBuckets = 1024
```

> **IMPORTANTE:** El número de vBuckets se obtiene contando las entradas de `.vBucketServerMap.vBucketMap`; `numVBuckets` no es una propiedad directa del objeto `vBucketServerMap`.
{: .lab-note .important .compact}

- {% include step_label.html %} Calcula la distribución de vBuckets activos para comprobar cómo Couchbase reparte las 1024 particiones lógicas entre los dos Data nodes.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$CB_ADMIN_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      http://127.0.0.1:8091/pools/default/b/travel-sample \
    | jq '
      .vBucketServerMap as $m
      | $m.vBucketMap
      | group_by(.[0])
      | map({
          node_index: .[0][0],
          node: $m.serverList[.[0][0]],
          active_vbuckets: length
        })
    ' \
    | tee outputs/active-vbucket-distribution.json
  ```

**Salida esperada:**

Con dos Data nodes y el clúster balanceado, el resultado será aproximadamente:

```text
Data node 0 → 512 active vBuckets
Data node 1 → 512 active vBuckets
```

- {% include step_label.html %} Calcula ahora la distribución de replicas para diferenciar claramente la copia activa de la copia secundaria asignada por el vBucket map.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$CB_ADMIN_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      http://127.0.0.1:8091/pools/default/b/travel-sample \
    | jq '
      .vBucketServerMap as $m
      | $m.vBucketMap
      | map(select(.[1] >= 0))
      | group_by(.[1])
      | map({
          node_index: .[0][1],
          node: $m.serverList[.[0][1]],
          replica_vbuckets: length
        })
    ' \
    | tee outputs/replica-vbucket-distribution.json
  ```

**Salida esperada:**

Con una réplica y dos Data nodes, es normal obtener aproximadamente:

```text
Data node 0 → 512 replica vBuckets
Data node 1 → 512 replica vBuckets
```

> **NOTA:** Aunque los conteos de activos y replicas sean iguales, no representan las mismas copias. Una entrada `[0,1]` significa activo en el nodo 0 y replica en el nodo 1; `[1,0]` representa la distribución inversa.
{: .lab-note .info .compact}


### Tarea 9.4. Validar scopes y collections mediante SQL++

- {% include step_label.html %} Localiza dinámicamente un Pod con Query Service para ejecutar consultas SQL++ dentro de Kubernetes y evitar exponer el puerto 8093 al equipo local.

  ```bash
  QUERY_POD=$(
    MSYS_NO_PATHCONV=1 kubectl exec \
      -n couchbase \
      "$CB_ADMIN_POD" \
      -c couchbase-server \
      -- \
      curl -sS \
        -u Administrator:Password123! \
        http://127.0.0.1:8091/pools/default \
    | jq -r '
        .nodes[]
        | select(.services | index("n1ql"))
        | .hostname
      ' \
    | head -n 1 \
    | cut -d. -f1
  )

  echo "Query Pod: ${QUERY_POD}"
  ```

- {% include step_label.html %} Consulta el catálogo de collections para confirmar que `travel-sample.inventory` contiene las collections utilizadas posteriormente en las pruebas SQL++.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$QUERY_POD" \
    -c couchbase-server \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      -X POST \
      http://127.0.0.1:8093/query/service \
      --data-urlencode 'statement=
        SELECT `bucket`,
              `scope`,
              name
        FROM system:keyspaces
        WHERE `bucket` = "travel-sample"
          AND `scope` = "inventory"
        ORDER BY name;' \
    | jq '{
        status,
        results,
        errors
      }' \
    | tee outputs/inventory-collections.json
  ```

**Salida esperada:**

Entre los resultados deben aparecer collections como:

```text
airline
airport
route
```

### Tarea 9.5. Validar SQL++ sobre `airline`

- {% include step_label.html %} Ejecuta una consulta de agregación para comprobar que Query Service puede acceder correctamente a `travel-sample.inventory.airline`.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$QUERY_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      -X POST \
      http://127.0.0.1:8093/query/service \
      --data-urlencode 'statement=
        SELECT COUNT(*) AS total_airlines
        FROM `travel-sample`.inventory.airline;' \
    | jq '{
        status,
        results,
        metrics
      }' \
    | tee outputs/query-airline-count.json
  ```

**Salida esperada:**

```text
status = success
total_airlines > 0
```

- {% include step_label.html %} Ejecuta una consulta independiente con `META()` para recuperar una clave real y algunos atributos de un documento sin mezclar campos no agrupados con la agregación anterior.

  ```bash
  MSYS_NO_PATHCONV=1 kubectl exec \
    -n couchbase \
    "$QUERY_POD" \
    -- \
    curl -sS \
      -u Administrator:Password123! \
      -X POST \
      http://127.0.0.1:8093/query/service \
      --data-urlencode 'statement=
        SELECT META(a).id AS document_id,
               a.name,
               a.country
        FROM `travel-sample`.inventory.airline AS a
        ORDER BY META(a).id
        LIMIT 1;' \
    | jq '{
        status,
        results
      }' \
    | tee outputs/query-airline-sample.json
  ```

**Salida esperada:**

La respuesta debe incluir:

```text
status = success
document_id
name
country
```

### Tarea 9.6. Consolidar la evidencia de arquitectura

- {% include step_label.html %} Genera un resumen único que reúna topología, bucket, distribución de vBuckets y collections para conservar evidencia reproducible de la arquitectura observada.

  ```bash
  {
    echo "# Evidencia de arquitectura — Lab 1"
    echo

    echo "## CouchbaseCluster"
    cat outputs/couchbasecluster-status.json
    echo

    echo "## Servicios MDS"
    cat outputs/service-distribution.json
    echo

    echo "## travel-sample"
    cat outputs/travel-sample-summary.json
    echo

    echo "## Active vBuckets"
    cat outputs/active-vbucket-distribution.json
    echo

    echo "## Replica vBuckets"
    cat outputs/replica-vbucket-distribution.json
    echo

    echo "## Inventory collections"
    cat outputs/inventory-collections.json
    echo

    echo "## SQL++ validation"
    cat outputs/query-airline-count.json
    echo
    cat outputs/query-airline-sample.json
  } | tee outputs/architecture-validation.md
  ```

### Salida esperada

El archivo:

```text
outputs/architecture-validation.md
```

debe contener evidencia de:

```text
CouchbaseCluster Available
4 miembros healthy/active
MDS 2 Data+Query, 1 Index+Search, 1 Analytics+Eventing
travel-sample disponible
1024 vBuckets
1 replica
inventory collections disponibles
SQL++ status=success
```

> **NOTA:** La Web Console puede utilizarse como herramienta visual opcional cuando exista un mecanismo estable de acceso administrativo. No forma parte del camino crítico de esta práctica; REST, SQL++ y Kubernetes constituyen las evidencias reproducibles.
{: .lab-note .info .compact}

{% assign results = site.data.task-results[page.slug].results %}
{% capture r9 %}{{ results[8] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r9 %}

{% include support-prompt.html task="tarea9" %}

---

## 📊 Tarea 10. Generar un reporte automático de topología

En esta tarea crearás un reporte de texto que combine información Kubernetes y Couchbase, proporcionando una evidencia reutilizable del estado alcanzado antes de eliminar la infraestructura.

### Tarea 10.1. Crear topology-report.sh

- {% include step_label.html %} Crea el script de reporte para registrar nodos Kubernetes, Pods Couchbase, servicios MDS, bucket y distribución de vBuckets dentro de un único archivo.

  ```bash
  cat > scripts/topology-report.sh << 'EOF'
  #!/usr/bin/env bash
  set -Eeuo pipefail

  ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  source "${ROOT_DIR}/lab.env"

  # Valores esperados para este laboratorio.
  CB_NAMESPACE="${CB_NAMESPACE:-couchbase}"
  CB_CLUSTER="${CB_CLUSTER:-cb-cs400}"

  # Validar que las credenciales estén disponibles.
  if [[ -z "${CB_USER:-}" || -z "${CB_PASS:-}" ]]; then
    echo "ERROR: CB_USER o CB_PASS no están definidos en lab.env."
    exit 1
  fi

  # Seleccionar dinámicamente un Pod Couchbase operativo.
  CB_ADMIN_POD=$(
    kubectl get pods \
      -n "${CB_NAMESPACE}" \
      -l "couchbase_cluster=${CB_CLUSTER}" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}'
  )

  if [[ -z "${CB_ADMIN_POD}" ]]; then
    echo "ERROR: No se encontró un Pod Couchbase Running."
    exit 1
  fi

  # Ejecutar llamadas REST desde el contenedor Couchbase.
  # Esto elimina la dependencia de kubectl port-forward.
  cb_rest() {
    local endpoint="$1"

    MSYS_NO_PATHCONV=1 kubectl exec \
      -n "${CB_NAMESPACE}" \
      "${CB_ADMIN_POD}" \
      -c couchbase-server \
      -- \
      curl --fail-with-body -sS \
        -u "${CB_USER}:${CB_PASS}" \
        "http://127.0.0.1:8091${endpoint}"
  }

  echo "============================================================"
  echo "REPORTE DE TOPOLOGÍA - COUCHBASE SOBRE AMAZON EKS"
  echo "Fecha: $(date)"
  echo "Namespace: ${CB_NAMESPACE}"
  echo "Cluster: ${CB_CLUSTER}"
  echo "Pod administrativo: ${CB_ADMIN_POD}"
  echo "============================================================"

  echo
  echo "--- 1. NODOS KUBERNETES ---"

  kubectl get nodes \
    -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone

  echo
  echo "--- 2. PODS DEL NAMESPACE COUCHBASE ---"

  kubectl get pods \
    -n "${CB_NAMESPACE}" \
    -o wide

  echo
  echo "--- 3. NODOS Y SERVICIOS COUCHBASE ---"

  cb_rest "/pools/default" \
    | jq '{
        rebalanceStatus,
        nodes: [
          .nodes[]
          | {
              hostname,
              status,
              membership: .clusterMembership,
              services
            }
        ]
      }'

  echo
  echo "--- 4. BUCKET travel-sample ---"

  cb_rest "/pools/default/buckets/travel-sample" \
    | jq '{
        name: .name,
        itemCount: .basicStats.itemCount,
        replicaNumber: .replicaNumber,
        bucketType: .bucketType,
        ramQuota: .quota.rawRAM
      }'

  echo
  echo "--- 5. RESUMEN DEL CLUSTER MAP ---"

  cb_rest "/pools/default/b/travel-sample" \
    | jq '{
        nodeLocator: .nodeLocator,
        numVBuckets: (.vBucketServerMap.vBucketMap | length),
        numReplicas: .vBucketServerMap.numReplicas,
        serverList: .vBucketServerMap.serverList
      }'

  echo
  echo "--- 6. vBUCKETS ACTIVOS POR DATA NODE ---"

  cb_rest "/pools/default/b/travel-sample" \
    | jq '
        .vBucketServerMap as $m
        | $m.vBucketMap
        | group_by(.[0])
        | map({
            node_index: .[0][0],
            node: $m.serverList[.[0][0]],
            active_vbuckets: length
          })
      '

  echo
  echo "--- 7. vBUCKETS RÉPLICA POR DATA NODE ---"

  cb_rest "/pools/default/b/travel-sample" \
    | jq '
        .vBucketServerMap as $m
        | $m.vBucketMap
        | map(select(.[1] >= 0))
        | group_by(.[1])
        | map({
            node_index: .[0][1],
            node: $m.serverList[.[0][1]],
            replica_vbuckets: length
          })
      '

  echo
  echo "--- 8. DISTRIBUCIÓN DE SERVICIOS MDS ---"

  cb_rest "/pools/default" \
    | jq '
        [.nodes[].services[]]
        | group_by(.)
        | map({
            service: .[0],
            nodes: length
          })
      '

  echo
  echo "--- 9. ESTADO GENERAL ---"

  cb_rest "/pools/default" \
    | jq '{
        rebalanceStatus,
        healthyNodes: (
          [.nodes[] | select(.status == "healthy")] | length
        ),
        activeNodes: (
          [.nodes[] | select(.clusterMembership == "active")] | length
        ),
        totalNodes: (.nodes | length)
      }'

  echo
  echo "============================================================"
  echo "FIN DEL REPORTE"
  echo "============================================================"
  EOF
  ```

- {% include step_label.html %} Asigna permisos, valida la sintaxis y ejecuta el reporte mientras el port-forward de 8091 permanece activo.

  ```bash
  chmod +x scripts/topology-report.sh
  bash -n scripts/topology-report.sh

  ./scripts/topology-report.sh \
    | tee outputs/topology-output.txt
  ```

### Tarea 10.2. Revisar la evidencia generada

- {% include step_label.html %} Abre el archivo generado y confirma que contenga los siete bloques de información antes de realizar la eliminación final del entorno.

  ```bash
  less outputs/topology-output.txt
  ```

- {% include step_label.html %} Verifica que el archivo tenga contenido y conserva esta salida dentro de `lab1` como evidencia aun después de borrar Amazon EKS.

  ```bash
  wc -l outputs/topology-output.txt
  ```

### Tarea 10.3. Documentar la arquitectura observada

- {% include step_label.html %} Completa la tabla siguiente utilizando exclusivamente los valores observados en REST API, Web Console y Kubernetes para construir el mapa final del laboratorio.

| Capa | Componente | Cantidad | Responsabilidad |
|---|---|---:|---|
| AWS | Amazon EKS | 1 | Plano de control Kubernetes administrado |
| AWS | EC2 Managed Nodes | 3 | Capacidad de cómputo para Pods |
| AWS | Amazon EBS gp3 | 4 o más | Almacenamiento persistente solicitado por Couchbase |
| Kubernetes | Couchbase Operator | 1 | Reconciliación del estado del clúster Couchbase |
| Couchbase | Data + Query | 2 | KV/vBuckets y ejecución SQL++ |
| Couchbase | Index + Search | 1 | GSI y Full Text Search |
| Couchbase | Analytics + Eventing | 1 | Analítica y procesamiento reactivo |
| Couchbase | travel-sample | 1 bucket | Dataset utilizado para observar distribución |

{% assign results = site.data.task-results[page.slug].results %}
{% capture r10 %}{{ results[9] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r10 %}

{% include support-prompt.html task="tarea10" %}

---

## ✅ Tarea 11. Ejecutar la validación final del laboratorio

En esta tarea automatizarás las comprobaciones principales antes de destruir el entorno. La validación confirma que EKS, Couchbase, travel-sample y el mapa de vBuckets alcanzaron el estado previsto.

### Tarea 11.1. Crear validate.sh

- {% include step_label.html %} Crea `scripts/validate.sh` para comprobar nodos Kubernetes, Pods Couchbase, servicios MDS, bucket, vBuckets y réplica sin depender de inspecciones visuales.

  ```bash
  curl -L -o scripts/validate.sh https://raw.githubusercontent.com/Netec-Mx/CS400/refs/heads/main/labs/lab1/validate.sh
  ```

- {% include step_label.html %} Ejecuta la validación mientras el port-forward continúa activo y no inicies la eliminación hasta obtener `0 FAIL`.

  ```bash
  chmod +x scripts/validate.sh
  bash -n scripts/validate.sh
  ./scripts/validate.sh
  ```

**Resultado esperado:**

```text
RESULTADO: 20 PASS / 0 FAIL
```

{% assign results = site.data.task-results[page.slug].results %}
{% capture r11 %}{{ results[10] }}{% endcapture %}
{% include task-result.html title="Tarea finalizada" content=r11 %}

{% include support-prompt.html task="tarea11" %}

---

## 🧹 Eliminación de Amazon EKS

En esta tarea retirarás la infraestructura creada por el laboratorio. Esta tarea forma parte del procedimiento normal porque EKS, EC2 y EBS pueden continuar generando cargos mientras existan.

### Tarea 12.1. Conservar las evidencias locales

- {% include step_label.html %} Lista los archivos generados para confirmar que `outputs/topology-output.txt`, los manifiestos y los scripts permanecen guardados localmente antes de eliminar la infraestructura remota.

  ```bash
  find . -maxdepth 2 -type f | sort
  ```

> **IMPORTANTE:** Detén el proceso de `kubectl port-forward` en la segunda terminal con `Ctrl+C` antes de destruir el clúster.
{: .lab-note .important .compact}

### Tarea 12.2. Eliminar el clúster mediante el mismo script

- {% include step_label.html %} Ejecuta la acción `delete` para ordenar a `eksctl` eliminar el clúster EKS y las pilas CloudFormation asociadas con el entorno creado por esta práctica.

  ```bash
  source lab.env
  ./scripts/eks-cluster.sh delete
  ```

**Salida esperada aproximada:**

```text
Clúster cb-cs400-lab01 eliminado correctamente.
```

### Tarea 12.3. Confirmar que EKS ya no existe

- {% include step_label.html %} Consulta el clúster por nombre y confirma que AWS ya no puede describirlo, demostrando que el control plane fue eliminado.

  ```bash
  aws eks describe-cluster \
    --name "$EKS_CLUSTER" \
    --region "$AWS_REGION"
  ```

**Salida esperada:**

El comando debe devolver un error equivalente a:

```text
ResourceNotFoundException
```

- {% include step_label.html %} Consulta `eksctl get cluster` para verificar adicionalmente que `cb-cs400-lab01` ya no aparece como clúster disponible en la región.

  ```bash
  eksctl get cluster --region "$AWS_REGION"
  ```

> **NOTA:** La eliminación de EKS retira los recursos administrados por las pilas creadas por `eksctl`. En un laboratorio compartido nunca elimines recursos ajenos que no pertenezcan al nombre definido en `lab.env`.
{: .lab-note .info .compact}