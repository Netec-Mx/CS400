---
title: "Acceso temporal a Couchbase Web Console mediante AWS LoadBalancer"
---

## Objetivo

Exponer temporalmente la Web Console de Couchbase Server mediante un `Service` de Kubernetes de tipo `LoadBalancer`, evitando la dependencia de `kubectl port-forward` durante el laboratorio.

> **IMPORTANTE:** Este procedimiento está diseñado únicamente para un laboratorio. Publica el puerto administrativo HTTP `8091` mediante un balanceador accesible desde Internet y no implementa TLS, DNS corporativo ni restricciones de origen. El Service debe eliminarse al terminar la práctica.
{: .lab-note .important .compact}

## Prerrequisitos

- El clúster EKS debe estar operativo.
- El namespace `couchbase` debe existir.
- El `CouchbaseCluster` debe llamarse `cb-cs400`.
- Los Pods Couchbase deben utilizar la etiqueta `couchbase_cluster=cb-cs400`.
- El manifiesto `manifests/couchbase-webui-loadbalancer.yaml` debe estar disponible en el directorio del laboratorio.

## 1. Confirmar que Couchbase está disponible

- {% include step_label.html %} Comprueba que el recurso administrado por Couchbase Kubernetes Operator haya alcanzado la condición `Available` antes de publicar su consola administrativa.

  ```bash
  kubectl wait \
    -n couchbase \
    --for=condition=Available \
    couchbasecluster/cb-cs400 \
    --timeout=15m
  ```

**Salida esperada:**

```text
couchbasecluster.couchbase.com/cb-cs400 condition met
```

- {% include step_label.html %} Verifica que el selector utilizado por el Service localice únicamente los Pods pertenecientes al clúster `cb-cs400`.

  ```bash
  kubectl get pods \
    -n couchbase \
    -l couchbase_cluster=cb-cs400 \
    -o wide
  ```

**Salida esperada:**

Deben aparecer los cuatro Pods Couchbase del laboratorio en estado `Running`.

## 2. Crear el Service público de laboratorio

- {% include step_label.html %} Aplica un Service independiente de tipo `LoadBalancer` para exponer solamente el puerto administrativo HTTP `8091` sin modificar el recurso `CouchbaseCluster`.

  ```bash
  kubectl apply \
    -f manifests/couchbase-webui-loadbalancer.yaml
  ```

**Salida esperada:**

```text
service/cb-cs400-webui-public created
```

> **NOTA:** Se utiliza un Service independiente para evitar alterar el modelo de networking administrado por Couchbase Kubernetes Operator. La configuración oficial del Operator para `adminConsoleServiceTemplate: LoadBalancer` está orientada a public networking con TLS y DNS dinámico.
{: .lab-note .info .compact}

## 3. Esperar la creación del Load Balancer

- {% include step_label.html %} Observa el Service hasta que AWS asigne un hostname externo; la creación del balanceador puede tardar varios minutos.

  ```bash
  kubectl get service cb-cs400-webui-public \
    -n couchbase \
    -w
  ```

Cuando la columna `EXTERNAL-IP` deje de mostrar `<pending>`, presiona `Ctrl+C`.

Ejemplo:

```text
NAME                       TYPE           CLUSTER-IP      EXTERNAL-IP                              PORT(S)
cb-cs400-webui-public      LoadBalancer   10.100.10.20    abc123.us-west-2.elb.amazonaws.com       8091:31234/TCP
```

- {% include step_label.html %} Guarda el hostname asignado por AWS para reutilizarlo en las validaciones posteriores sin copiarlo manualmente.

  ```bash
  CB_WEBUI_HOST=$(
    kubectl get service cb-cs400-webui-public \
      -n couchbase \
      -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
  )

  echo "Couchbase Web UI: http://${CB_WEBUI_HOST}:8091"
  ```

**Salida esperada:**

```text
Couchbase Web UI: http://<hostname-aws>:8091
```

## 4. Validar conectividad antes de abrir el navegador

- {% include step_label.html %} Comprueba mediante REST que el balanceador puede alcanzar Couchbase antes de iniciar la Web Console desde el navegador.

  ```bash
  curl -sS \
    -o /dev/null \
    -w 'HTTP_STATUS=%{http_code}\n' \
    -u Administrator:Password123! \
    "http://${CB_WEBUI_HOST}:8091/pools/default"
  ```

**Salida esperada:**

```text
HTTP_STATUS=200
```

Si el hostname ya existe pero todavía no responde, espera entre 30 y 90 segundos y repite la validación mientras AWS completa el registro de targets.

## 5. Acceder a Couchbase Web Console

- {% include step_label.html %} Abre el endpoint público asignado por AWS para utilizar la Web Console mediante una conexión estable que no dependa de `kubectl port-forward`.

  ```text
  http://<CB_WEBUI_HOST>:8091
  ```

Utiliza las credenciales del laboratorio:

| Campo | Valor |
| --- | --- |
| Usuario | `Administrator` |
| Contraseña | `Password123!` |

Puedes obtener nuevamente la URL con:

```bash
echo "http://${CB_WEBUI_HOST}:8091"
```

## 6. Validar el Service y sus endpoints

- {% include step_label.html %} Revisa la definición del Service y el hostname externo para conservar evidencia de que Kubernetes está utilizando un recurso de tipo `LoadBalancer`.

  ```bash
  kubectl get service cb-cs400-webui-public \
    -n couchbase \
    -o wide
  ```

- {% include step_label.html %} Comprueba que el Service tenga endpoints asociados con Pods Couchbase antes de atribuir cualquier problema de acceso al balanceador de AWS.

  ```bash
  kubectl get endpointslice \
    -n couchbase \
    -l kubernetes.io/service-name=cb-cs400-webui-public \
    -o wide
  ```

Debe existir al menos un `EndpointSlice` con direcciones de los Pods seleccionados.

## 7. Diagnóstico si `EXTERNAL-IP` permanece en `<pending>`

- {% include step_label.html %} Consulta los eventos del Service para identificar errores de permisos, subredes o aprovisionamiento del balanceador en AWS.

  ```bash
  kubectl describe service cb-cs400-webui-public \
    -n couchbase
  ```

Revisa especialmente la sección:

```text
Events:
```

- {% include step_label.html %} Comprueba si el AWS Load Balancer Controller está instalado; Amazon EKS lo recomienda para aprovisionar NLB en clústeres que no utilizan EKS Auto Mode.

  ```bash
  kubectl get deployment \
    -n kube-system \
    aws-load-balancer-controller
  ```

Si el recurso no existe, el clúster puede recurrir al controlador cloud legado para Services `LoadBalancer`, dependiendo de su configuración. Para un curso donde se requiera explícitamente NLB y comportamiento consistente, instala AWS Load Balancer Controller siguiendo la documentación oficial de Amazon EKS.

## 8. Eliminar la exposición al finalizar

- {% include step_label.html %} Elimina el Service público al terminar la práctica para que Kubernetes solicite también la eliminación del Load Balancer creado en AWS y evitar costos innecesarios.

  ```bash
  kubectl delete \
    -f manifests/couchbase-webui-loadbalancer.yaml
  ```

**Salida esperada:**

```text
service "cb-cs400-webui-public" deleted
```

- {% include step_label.html %} Confirma que el Service dejó de existir antes de eliminar el clúster EKS o continuar con la limpieza general del laboratorio.

  ```bash
  kubectl get service cb-cs400-webui-public \
    -n couchbase
  ```

**Salida esperada:**

```text
Error from server (NotFound)
```

## Integración recomendada en el laboratorio

Este bloque puede incorporarse después de confirmar que `CouchbaseCluster` está `Available` y antes de cualquier tarea que requiera inspección visual desde Web Console.

La ruta de acceso queda:

```text
Navegador del participante
          |
          | HTTP :8091
          v
AWS Load Balancer público
          |
          v
Service cb-cs400-webui-public
          |
          v
Pods cb-cs400-*
          |
          v
Couchbase Web Console
```

`kubectl port-forward` puede conservarse únicamente como alternativa de diagnóstico y no como dependencia para usar la interfaz durante toda la práctica.

## Referencias

- Couchbase Kubernetes Operator — Configure Public Networking:
  https://docs.couchbase.com/operator/current/howto-public-networking.html

- Couchbase Kubernetes Operator — CouchbaseCluster Resource:
  https://docs.couchbase.com/operator/current/resource/couchbasecluster.html

- Amazon EKS — Route internet traffic with AWS Load Balancer Controller:
  https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html

- Amazon EKS — Route TCP and UDP traffic with Network Load Balancers:
  https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html
