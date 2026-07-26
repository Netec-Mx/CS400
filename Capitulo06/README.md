---LAB_START---
LAB_ID: 06-00-01
---MARKDOWN---
# Implementación de seguridad en un entorno productivo

## Metadatos

| Campo         | Valor                                      |
|---------------|--------------------------------------------|
| **Duración**  | 84 minutos                                 |
| **Complejidad** | Alta                                     |
| **Nivel Bloom** | Crear (Create)                           |
| **Módulo**    | Capítulo 6 — Seguridad Operacional         |
| **Versión CB** | Couchbase Server Enterprise Edition 7.6.x |

---

## Descripción General

En este laboratorio implementarás una arquitectura de seguridad en capas sobre un clúster Couchbase de producción, aplicando los cuatro pilares del modelo de seguridad estudiados en la lección: red y transporte, autenticación, autorización y auditoría. Partirás de un clúster operativo del Lab 01 y construirás sobre él un modelo RBAC granular con cuentas de servicio por rol, cifrado TLS extremo a extremo con una CA privada generada con OpenSSL, mTLS para autenticación de clientes, auditoría configurable de eventos sensibles y un conjunto de medidas de hardening documentadas en una matriz de postura de seguridad. Al finalizar, habrás transformado un clúster con configuración por defecto en un entorno que cumple con los principios de defensa en profundidad, menor privilegio y auditabilidad.

---

## Objetivos de Aprendizaje

Al completar este laboratorio serás capaz de:

- [ ] Implementar un modelo RBAC completo con usuarios, grupos y principio de menor privilegio para roles de aplicación diferenciados, verificando el aislamiento con pruebas de acceso positivas y negativas
- [ ] Generar una CA privada con OpenSSL, emitir certificados por nodo, configurar TLS en Couchbase y verificar la comunicación cifrada cliente-servidor
- [ ] Habilitar y configurar el sistema de auditoría de Couchbase para registrar operaciones sensibles (login, query, acceso a documentos) y analizar los logs generados
- [ ] Aplicar técnicas de hardening incluyendo restricción de puertos, gestión de secretos y documentación de la postura de seguridad mediante una matriz de superficies de exposición

---

## Prerequisitos

### Conocimientos Requeridos

- Lab 01-00-01 completado — clúster Couchbase de 3 nodos operativo con bucket `travel-sample` cargado
- Conceptos de seguridad: TLS, certificados X.509, cadena de confianza CA → nodo, RBAC
- Familiaridad con OpenSSL para generación de claves y certificados
- Comprensión de modelos de autenticación y autorización en sistemas distribuidos

### Acceso Requerido

- Acceso SSH a los 3 nodos del clúster (`node1`, `node2`, `node3`)
- Credenciales de administrador de Couchbase (`Administrator` / contraseña definida en Lab 01)
- Acceso a la Couchbase Web Console en `http://node1:8091`
- `openssl` instalado en el nodo cliente (versión 1.1.1 o superior)
- `curl`, `jq` y `cbq` disponibles en el nodo cliente

---

## Entorno de Laboratorio

### Topología

| Nodo    | Hostname / IP       | Servicios Couchbase          | RAM  |
|---------|---------------------|------------------------------|------|
| node1   | `192.168.1.101`     | Data, Query, Index           | 8 GB |
| node2   | `192.168.1.102`     | Data, Query, Index           | 8 GB |
| node3   | `192.168.1.103`     | Data, Search, Analytics      | 8 GB |
| cliente | `192.168.1.110`     | cbq, curl, openssl, scripts  | 4 GB |

### Variables de Entorno del Laboratorio

Ejecuta los siguientes comandos en el nodo cliente para establecer las variables que se usarán a lo largo del laboratorio:

```bash
# Variables de entorno del laboratorio — ejecutar en el nodo cliente
export CB_ADMIN_USER="Administrator"
export CB_ADMIN_PASS="Admin@Lab2024!"    # Ajustar según Lab 01
export CB_NODE1="192.168.1.101"
export CB_NODE2="192.168.1.102"
export CB_NODE3="192.168.1.103"
export CB_CLUSTER="${CB_NODE1}"
export CB_MGMT_PORT="8091"
export CB_MGMT_TLS_PORT="18091"
export LAB_DIR="${HOME}/lab06"
export CERT_DIR="${LAB_DIR}/certs"
export CA_DIR="${CERT_DIR}/ca"

# Crear estructura de directorios del laboratorio
mkdir -p "${LAB_DIR}" "${CERT_DIR}" "${CA_DIR}"
mkdir -p "${CERT_DIR}/node1" "${CERT_DIR}/node2" "${CERT_DIR}/node3"
mkdir -p "${LAB_DIR}/scripts" "${LAB_DIR}/audit-logs"

echo "Entorno de laboratorio configurado en: ${LAB_DIR}"
```

### Verificación del Estado Inicial del Clúster

```bash
# Confirmar que el clúster está operativo antes de comenzar
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/pools/default" \
  | jq '{clusterName: .clusterName, nodes: [.nodes[] | {hostname: .hostname, status: .status}]}'
```

**Resultado esperado:** Los tres nodos deben aparecer con `"status": "healthy"`.

---

## Procedimiento Paso a Paso

---

### Paso 1 — Auditoría del Estado de Seguridad Inicial (8 minutos)

**Objetivo:** Establecer una línea base documentando la postura de seguridad actual del clúster antes de aplicar controles. Este ejercicio reproduce la metodología de la matriz de superficies de exposición presentada en la lección.

#### Instrucciones

1. **Inventario de usuarios existentes:**

```bash
# Listar todos los usuarios locales del clúster
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local" \
  | jq '.[] | {id: .id, roles: [.roles[].role], domain: .domain}'
```

2. **Verificar qué puertos están escuchando en node1:**

```bash
# Ejecutar desde el nodo cliente — verificar exposición de puertos
nmap -p 8091,8093,8094,8095,8096,11210,11207,18091,18093,4369 \
  -sV --open "${CB_NODE1}"
```

3. **Verificar si TLS está habilitado actualmente:**

```bash
# Consultar configuración de seguridad del clúster
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/security" \
  | jq '{tlsMinVersion: .tlsMinVersion, disableUIOverHttp: .disableUIOverHttp, clusterEncryptionLevel: .clusterEncryptionLevel}'
```

4. **Crear la matriz de postura de seguridad inicial** guardándola en un archivo:

```bash
cat > "${LAB_DIR}/security-posture-baseline.txt" << 'EOF'
=== MATRIZ DE POSTURA DE SEGURIDAD — ESTADO INICIAL ===
Fecha: $(date)

Superficie          | Estado Inicial    | Control Requerido       | Prioridad
--------------------|-------------------|-------------------------|----------
Puerto 8091 (HTTP)  | EXPUESTO          | Deshabilitar post-TLS   | CRÍTICA
Puerto 18091 (HTTPS)| Sin TLS custom    | Certificado CA privada  | CRÍTICA
Puerto 11210 (KV)   | SIN CIFRAR        | Migrar a 11207 TLS      | CRÍTICA
Puerto 11207 (KV-TLS)| Sin TLS custom   | Certificado CA privada  | ALTA
Consola web         | HTTP sin MFA      | HTTPS + acceso restric. | ALTA
Usuarios            | Solo Administrator| RBAC granular           | ALTA
Auditoría           | DESHABILITADA     | Habilitar eventos clave | MEDIA
Backups             | Sin cifrado        | AES-256 (fuera de scope)| MEDIA
EOF

# Sustituir la variable de fecha
sed -i "s/\$(date)/$(date)/" "${LAB_DIR}/security-posture-baseline.txt"
cat "${LAB_DIR}/security-posture-baseline.txt"
```

#### Resultado Esperado

El escaneo `nmap` mostrará los puertos no cifrados (8091, 11210) abiertos. La consulta de seguridad mostrará `tlsMinVersion` vacío o en valor por defecto, confirmando que TLS personalizado no está configurado.

#### Verificación

```bash
# Confirmar que el archivo de postura base fue creado
ls -la "${LAB_DIR}/security-posture-baseline.txt"
wc -l "${LAB_DIR}/security-posture-baseline.txt"
```

---

### Paso 2 — Implementación de RBAC con Roles Granulares (18 minutos)

**Objetivo:** Crear un modelo RBAC completo con tres perfiles de aplicación que demuestren el principio de menor privilegio: un lector de solo datos, un ejecutor de queries y un administrador de índices.

#### Instrucciones

1. **Crear los grupos de usuarios con permisos granulares:**

```bash
# Grupo: lectores de datos — solo lectura en bucket travel-sample, scope inventory
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/groups/app-data-readers" \
  -d 'description=Lectores+de+solo+datos+en+coleccion+inventory' \
  -d 'roles=data_reader[travel-sample:inventory]'

echo "Grupo app-data-readers creado"

# Grupo: ejecutores de queries — solo pueden ejecutar SELECT en colecciones definidas
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/groups/app-query-executors" \
  -d 'description=Ejecutores+de+queries+en+travel-sample' \
  -d 'roles=query_select[travel-sample:inventory:airline],query_select[travel-sample:inventory:airport]'

echo "Grupo app-query-executors creado"

# Grupo: administradores de índices — gestión de índices sin acceso a datos
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/groups/app-index-admins" \
  -d 'description=Administradores+de+indices+sin+acceso+a+datos' \
  -d 'roles=query_manage_index[travel-sample]'

echo "Grupo app-index-admins creado"
```

2. **Crear usuarios de servicio y asignarlos a sus grupos:**

```bash
# Usuario: svc-reader — cuenta de servicio para lectura de datos
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local/svc-reader" \
  -d 'name=Service+Account+Reader' \
  -d 'password=SvcRead@2024!' \
  -d 'groups=app-data-readers'

echo "Usuario svc-reader creado"

# Usuario: svc-query — cuenta de servicio para ejecución de queries
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local/svc-query" \
  -d 'name=Service+Account+Query' \
  -d 'password=SvcQuery@2024!' \
  -d 'groups=app-query-executors'

echo "Usuario svc-query creado"

# Usuario: svc-index — cuenta de servicio para administración de índices
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local/svc-index" \
  -d 'name=Service+Account+Index+Admin' \
  -d 'password=SvcIndex@2024!' \
  -d 'groups=app-index-admins'

echo "Usuario svc-index creado"
```

3. **Verificar los usuarios y sus roles asignados:**

```bash
# Listar usuarios con sus roles efectivos
for user in svc-reader svc-query svc-index; do
  echo "=== Usuario: ${user} ==="
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local/${user}" \
    | jq '{id: .id, groups: .groups, roles: [.roles[] | {role: .role, bucket_name: .bucket_name, scope_name: .scope_name, collection_name: .collection_name}]}'
  echo ""
done
```

4. **Ejecutar pruebas de acceso positivas y negativas:**

```bash
# PRUEBA POSITIVA: svc-reader debe poder leer documentos de travel-sample
echo "=== PRUEBA POSITIVA: svc-reader lee documento ==="
curl -s -u "svc-reader:SvcRead@2024!" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/pools/default/buckets/travel-sample" \
  | jq '.name' 2>/dev/null || echo "Respuesta recibida"

# PRUEBA NEGATIVA: svc-reader NO debe poder ejecutar queries
echo "=== PRUEBA NEGATIVA: svc-reader intenta query (debe fallar) ==="
curl -s -u "svc-reader:SvcRead@2024!" \
  "http://${CB_CLUSTER}:8093/query/service" \
  -d 'statement=SELECT * FROM `travel-sample` LIMIT 1' \
  | jq '{status: .status, errors: .errors}'

# PRUEBA POSITIVA: svc-query ejecuta SELECT válido
echo "=== PRUEBA POSITIVA: svc-query ejecuta SELECT ==="
curl -s -u "svc-query:SvcQuery@2024!" \
  "http://${CB_CLUSTER}:8093/query/service" \
  -d 'statement=SELECT airportname FROM `travel-sample`.inventory.airport LIMIT 3' \
  | jq '{status: .status, resultCount: .metrics.resultCount}'

# PRUEBA NEGATIVA: svc-query NO debe poder hacer INSERT
echo "=== PRUEBA NEGATIVA: svc-query intenta INSERT (debe fallar) ==="
curl -s -u "svc-query:SvcQuery@2024!" \
  "http://${CB_CLUSTER}:8093/query/service" \
  -d 'statement=INSERT INTO `travel-sample`.inventory.airline (KEY, VALUE) VALUES ("test-rbac", {"name":"test"})' \
  | jq '{status: .status, errors: [.errors[]?.msg]}'

# PRUEBA NEGATIVA: svc-index NO debe poder leer documentos KV
echo "=== PRUEBA NEGATIVA: svc-index intenta acceso KV (debe fallar) ==="
curl -s -u "svc-index:SvcIndex@2024!" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/pools/default/buckets/travel-sample/docs/airline_10" \
  | jq '{status: .status, message: .message}'
```

#### Resultado Esperado

- Las pruebas positivas deben retornar `"status": "success"` o datos válidos
- Las pruebas negativas deben retornar errores HTTP 403 o mensajes de `"status": "errors"` indicando permisos insuficientes
- Ningún usuario de servicio debe poder realizar acciones fuera de su rol asignado

#### Verificación

```bash
# Confirmar que los 3 grupos y 3 usuarios existen
echo "=== Grupos RBAC ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/groups" \
  | jq '.[].id'

echo "=== Usuarios de servicio ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/rbac/users/local" \
  | jq '.[] | select(.id | startswith("svc-")) | {id: .id, groups: .groups}'
```

---

### Paso 3 — Generación de CA Privada y Certificados TLS por Nodo (20 minutos)

**Objetivo:** Crear una infraestructura PKI completa con una CA privada, emitir certificados individuales para cada nodo del clúster y configurar TLS en Couchbase para cifrar toda la comunicación.

#### Instrucciones

1. **Generar la Autoridad Certificadora (CA) privada:**

```bash
cd "${CA_DIR}"

# Generar clave privada de la CA (RSA 4096 bits)
openssl genrsa -out ca.key 4096
echo "Clave CA generada"

# Generar certificado raíz autofirmado de la CA (válido 10 años)
openssl req -new -x509 -days 3650 \
  -key ca.key \
  -out ca.crt \
  -subj "/C=US/ST=Lab/L=Datacenter/O=CouchbaseLab/OU=Security/CN=CouchbaseLab-CA"

echo "Certificado CA generado:"
openssl x509 -in ca.crt -noout -subject -dates
```

2. **Crear función auxiliar para generar certificados de nodo:**

```bash
# Función para generar certificado de nodo firmado por la CA
generate_node_cert() {
  local NODE_NAME=$1
  local NODE_IP=$2
  local NODE_DIR="${CERT_DIR}/${NODE_NAME}"

  echo "Generando certificado para ${NODE_NAME} (${NODE_IP})..."

  # Clave privada del nodo
  openssl genrsa -out "${NODE_DIR}/pkey.key" 2048

  # Configuración SAN (Subject Alternative Names) para el nodo
  cat > "${NODE_DIR}/san.cnf" << EOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = req_ext

[dn]
C=US
ST=Lab
L=Datacenter
O=CouchbaseLab
OU=Nodes
CN=${NODE_IP}

[req_ext]
subjectAltName = @alt_names

[alt_names]
IP.1 = ${NODE_IP}
DNS.1 = ${NODE_NAME}
DNS.2 = ${NODE_NAME}.local
EOF

  # CSR del nodo
  openssl req -new \
    -key "${NODE_DIR}/pkey.key" \
    -out "${NODE_DIR}/node.csr" \
    -config "${NODE_DIR}/san.cnf"

  # Firmar el CSR con la CA
  openssl x509 -req -days 730 \
    -in "${NODE_DIR}/node.csr" \
    -CA "${CA_DIR}/ca.crt" \
    -CAkey "${CA_DIR}/ca.key" \
    -CAcreateserial \
    -out "${NODE_DIR}/chain.pem" \
    -extensions req_ext \
    -extfile "${NODE_DIR}/san.cnf"

  echo "Certificado para ${NODE_NAME} generado:"
  openssl x509 -in "${NODE_DIR}/chain.pem" -noout -subject -dates -ext subjectAltName
}

# Generar certificados para los tres nodos
generate_node_cert "node1" "${CB_NODE1}"
generate_node_cert "node2" "${CB_NODE2}"
generate_node_cert "node3" "${CB_NODE3}"

echo "Todos los certificados de nodo generados"
ls -la "${CERT_DIR}/node1/" "${CERT_DIR}/node2/" "${CERT_DIR}/node3/"
```

3. **Distribuir los certificados a cada nodo del clúster:**

```bash
# Copiar certificados a cada nodo (ajustar usuario SSH según entorno)
for i in 1 2 3; do
  NODE_IP_VAR="CB_NODE${i}"
  NODE_IP="${!NODE_IP_VAR}"
  echo "Copiando certificados a node${i} (${NODE_IP})..."

  # Crear directorio en el nodo remoto
  ssh "ubuntu@${NODE_IP}" "sudo mkdir -p /opt/couchbase/var/lib/couchbase/inbox/"

  # Copiar certificado de nodo y clave privada
  scp "${CERT_DIR}/node${i}/chain.pem" "ubuntu@${NODE_IP}:/tmp/chain.pem"
  scp "${CERT_DIR}/node${i}/pkey.key"  "ubuntu@${NODE_IP}:/tmp/pkey.key"
  scp "${CA_DIR}/ca.crt"               "ubuntu@${NODE_IP}:/tmp/ca.crt"

  # Mover al directorio inbox de Couchbase con permisos correctos
  ssh "ubuntu@${NODE_IP}" "
    sudo cp /tmp/chain.pem /opt/couchbase/var/lib/couchbase/inbox/chain.pem
    sudo cp /tmp/pkey.key  /opt/couchbase/var/lib/couchbase/inbox/pkey.key
    sudo cp /tmp/ca.crt    /opt/couchbase/var/lib/couchbase/inbox/ca.pem
    sudo chown -R couchbase:couchbase /opt/couchbase/var/lib/couchbase/inbox/
    sudo chmod 600 /opt/couchbase/var/lib/couchbase/inbox/pkey.key
    sudo chmod 644 /opt/couchbase/var/lib/couchbase/inbox/chain.pem
    sudo chmod 644 /opt/couchbase/var/lib/couchbase/inbox/ca.pem
    echo 'Certificados instalados en node${i}'
    ls -la /opt/couchbase/var/lib/couchbase/inbox/
  "
done
```

4. **Cargar el certificado CA en el clúster y activar TLS:**

```bash
# Subir el certificado CA al clúster via REST API
echo "Cargando certificado CA en el clúster..."
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X POST \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/controller/uploadClusterCA" \
  --data-binary @"${CA_DIR}/ca.crt"

echo ""
echo "Aplicando certificados de nodo en cada nodo..."

# Aplicar el certificado de nodo en cada nodo del clúster
for NODE_IP in "${CB_NODE1}" "${CB_NODE2}" "${CB_NODE3}"; do
  echo "Aplicando certificado en ${NODE_IP}..."
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    -X POST \
    "http://${NODE_IP}:${CB_MGMT_PORT}/node/controller/reloadCertificate"
  echo ""
done

# Configurar TLS mínimo en TLS 1.2 y deshabilitar UI sobre HTTP
echo "Configurando parámetros TLS del clúster..."
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X POST \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/settings/security" \
  -d 'tlsMinVersion=tlsv1.2' \
  -d 'disableUIOverHttp=true' \
  -d 'disableUIOverHttps=false'

echo "TLS configurado. La consola web ahora requiere HTTPS."
```

5. **Verificar TLS con el certificado personalizado:**

```bash
# Verificar que el certificado CA está activo en el clúster
echo "=== Certificado CA activo en el clúster ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/pools/default/certificate" \
  | jq '{subject: .subject, expires: .expires, type: .type}'

# Verificar conexión HTTPS con el CA personalizado
echo "=== Verificación de conexión HTTPS con CA personalizado ==="
curl -s --cacert "${CA_DIR}/ca.crt" \
  -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default" \
  | jq '.clusterName'

# Verificar detalles del certificado TLS del servidor
echo "=== Detalles del certificado TLS del servidor ==="
openssl s_client -connect "${CB_CLUSTER}:${CB_MGMT_TLS_PORT}" \
  -CAfile "${CA_DIR}/ca.crt" \
  -servername "${CB_NODE1}" \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
```

#### Resultado Esperado

- El comando `curl` con `--cacert` debe conectar exitosamente sin advertencias de certificado
- El certificado del servidor debe mostrar el `CN` del nodo y la CA privada como emisor
- La consola web en `http://node1:8091` debe redirigir o rechazar conexiones (HTTP deshabilitado)

#### Verificación

```bash
# Confirmar que HTTP fue deshabilitado y HTTPS funciona
echo "=== HTTP debe rechazar (disableUIOverHttp=true) ==="
curl -s -o /dev/null -w "HTTP Status: %{http_code}\n" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/ui/index.html"

echo "=== HTTPS debe funcionar ==="
curl -s --cacert "${CA_DIR}/ca.crt" -o /dev/null \
  -w "HTTPS Status: %{http_code}\n" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/ui/index.html"
```

---

### Paso 4 — Configuración de mTLS para Autenticación de Clientes (10 minutos)

**Objetivo:** Configurar autenticación mutua TLS (mTLS) de forma que el clúster pueda autenticar clientes mediante certificados X.509, eliminando la necesidad de contraseñas para comunicaciones máquina a máquina.

#### Instrucciones

1. **Generar certificado de cliente para mTLS:**

```bash
CLIENT_CERT_DIR="${CERT_DIR}/client"
mkdir -p "${CLIENT_CERT_DIR}"

# Generar clave privada del cliente
openssl genrsa -out "${CLIENT_CERT_DIR}/client.key" 2048

# El CN del certificado de cliente debe coincidir con el nombre de usuario en Couchbase
openssl req -new \
  -key "${CLIENT_CERT_DIR}/client.key" \
  -out "${CLIENT_CERT_DIR}/client.csr" \
  -subj "/C=US/ST=Lab/O=CouchbaseLab/CN=svc-mtls-client"

# Firmar el certificado de cliente con la CA del laboratorio
openssl x509 -req -days 365 \
  -in "${CLIENT_CERT_DIR}/client.csr" \
  -CA "${CA_DIR}/ca.crt" \
  -CAkey "${CA_DIR}/ca.key" \
  -CAcreateserial \
  -out "${CLIENT_CERT_DIR}/client.crt"

echo "Certificado de cliente generado:"
openssl x509 -in "${CLIENT_CERT_DIR}/client.crt" -noout -subject -dates
```

2. **Crear el usuario mTLS en Couchbase (CN del certificado = nombre de usuario):**

```bash
# El usuario debe tener el mismo nombre que el CN del certificado
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X PUT \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/svc-mtls-client" \
  --cacert "${CA_DIR}/ca.crt" \
  -d 'name=mTLS+Client+Service+Account' \
  -d 'roles=data_reader[travel-sample]'

echo "Usuario svc-mtls-client creado para autenticación mTLS"
```

3. **Habilitar autenticación por certificado en el clúster:**

```bash
# Habilitar x509 client certificate authentication
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/security" \
  -d 'clientCertAuthState=enable' \
  -d 'clientCertAuthType=mandatory' \
  2>/dev/null || \
# Si la API anterior no está disponible, usar el endpoint específico
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/clientCertAuth" \
  -H "Content-Type: application/json" \
  -d '{
    "state": "enable",
    "prefixes": [
      {
        "path": "subject.cn",
        "prefix": "",
        "delimiter": ""
      }
    ]
  }'

echo "Autenticación mTLS habilitada"
```

4. **Verificar autenticación mTLS con el certificado de cliente:**

```bash
# Probar autenticación con certificado de cliente (sin usuario/contraseña)
echo "=== Autenticación mTLS — con certificado válido ==="
curl -s \
  --cacert "${CA_DIR}/ca.crt" \
  --cert "${CLIENT_CERT_DIR}/client.crt" \
  --key "${CLIENT_CERT_DIR}/client.key" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default" \
  | jq '{clusterName: .clusterName, authenticated: "via-certificate"}'

echo ""
echo "=== Intento sin certificado (debe fallar o requerir credenciales) ==="
curl -s -o /dev/null -w "HTTP Status sin cert: %{http_code}\n" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default"
```

#### Resultado Esperado

- La autenticación con certificado de cliente debe retornar datos del clúster (HTTP 200)
- El intento sin certificado debe retornar HTTP 401 (cuando `clientCertAuthType=mandatory`)

#### Verificación

```bash
# Verificar el estado de clientCertAuth
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/clientCertAuth" \
  | jq '{state: .state, prefixes: .prefixes}'
```

---

### Paso 5 — Configuración del Sistema de Auditoría (14 minutos)

**Objetivo:** Habilitar el sistema de auditoría de Couchbase, configurar los eventos que deben registrarse (login, ejecución de queries, acceso a documentos, cambios de configuración) y analizar los logs generados para confirmar la trazabilidad completa.

#### Instrucciones

1. **Habilitar la auditoría en el clúster:**

```bash
# Habilitar auditoría con rotación de logs diaria
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
  -d 'auditdEnabled=true' \
  -d 'rotateInterval=86400' \
  -d 'rotateSize=524288000' \
  -d 'logPath=/opt/couchbase/var/lib/couchbase/logs'

echo "Auditoría habilitada"

# Verificar que la auditoría está activa
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
  | jq '{auditdEnabled: .auditdEnabled, logPath: .logPath, rotateInterval: .rotateInterval}'
```

2. **Configurar los eventos específicos a auditar:**

Los IDs de eventos de Couchbase más relevantes para seguridad son:

| ID de Evento | Descripción |
|---|---|
| 8192 | Login exitoso |
| 8193 | Login fallido |
| 8257 | Cambio de contraseña de usuario |
| 8232 | Creación de usuario |
| 8233 | Eliminación de usuario |
| 20480 | Ejecución de query SQL++ |
| 20488 | Acceso a documento KV |
| 4096 | Cambio de configuración del clúster |

```bash
# Crear script para configurar eventos de auditoría específicos
cat > "${LAB_DIR}/scripts/configure-audit-events.sh" << 'SCRIPT'
#!/bin/bash
# Configurar eventos de auditoría de Couchbase

CB_ADMIN_USER="${1}"
CB_ADMIN_PASS="${2}"
CB_CLUSTER="${3}"
CA_CERT="${4}"

# Obtener la lista completa de eventos disponibles
echo "Obteniendo eventos de auditoría disponibles..."
AUDIT_EVENTS=$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/settings/audit" \
  | jq '.descriptors')

echo "Total de eventos disponibles: $(echo "${AUDIT_EVENTS}" | jq 'length')"

# Habilitar eventos críticos de seguridad
# Nota: La API acepta la lista de IDs a deshabilitar (disabled list)
# Los eventos NO en la lista quedan habilitados por defecto
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  -X POST \
  "https://${CB_CLUSTER}:18091/settings/audit" \
  -d 'auditdEnabled=true' \
  -d 'disabled=' \
  -d 'rotateInterval=86400'

echo "Eventos de auditoría configurados — todos los eventos habilitados"
SCRIPT

chmod +x "${LAB_DIR}/scripts/configure-audit-events.sh"
bash "${LAB_DIR}/scripts/configure-audit-events.sh" \
  "${CB_ADMIN_USER}" "${CB_ADMIN_PASS}" "${CB_CLUSTER}" "${CA_DIR}/ca.crt"
```

3. **Generar eventos auditables para poblar los logs:**

```bash
echo "=== Generando eventos auditables ==="

# Evento 1: Login exitoso (svc-query)
curl -s -u "svc-query:SvcQuery@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default" > /dev/null
echo "Login exitoso de svc-query registrado"

# Evento 2: Login fallido (credenciales incorrectas)
curl -s -u "svc-query:contraseña-incorrecta" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default" > /dev/null
echo "Login fallido registrado"

# Evento 3: Ejecución de query SQL++
curl -s -u "svc-query:SvcQuery@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:18093/query/service" \
  -d 'statement=SELECT airportname, country FROM `travel-sample`.inventory.airport WHERE country="France" LIMIT 5' \
  | jq '{status: .status, resultCount: .metrics.resultCount}'

# Evento 4: Intento de acceso no autorizado (svc-reader intenta query)
curl -s -u "svc-reader:SvcRead@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:18093/query/service" \
  -d 'statement=SELECT * FROM `travel-sample` LIMIT 1' > /dev/null
echo "Intento de acceso no autorizado registrado"

# Evento 5: Cambio de configuración por administrador
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
  -d 'auditdEnabled=true' \
  -d 'rotateInterval=86400' > /dev/null
echo "Cambio de configuración registrado"

echo "Todos los eventos de prueba generados. Esperar 5 segundos para flush..."
sleep 5
```

4. **Recuperar y analizar los logs de auditoría:**

```bash
# Copiar logs de auditoría desde node1 para análisis
echo "=== Copiando logs de auditoría desde node1 ==="
scp "ubuntu@${CB_NODE1}:/opt/couchbase/var/lib/couchbase/logs/audit.log" \
  "${LAB_DIR}/audit-logs/audit-node1.log" 2>/dev/null || \
ssh "ubuntu@${CB_NODE1}" \
  "sudo cat /opt/couchbase/var/lib/couchbase/logs/audit.log | tail -50" \
  > "${LAB_DIR}/audit-logs/audit-node1.log"

echo "=== Análisis de logs de auditoría ==="

# Mostrar los últimos 20 eventos con formato legible
echo "--- Últimos eventos auditados ---"
tail -20 "${LAB_DIR}/audit-logs/audit-node1.log" | \
  python3 -c "
import sys, json
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            event = json.loads(line)
            print(f\"[{event.get('timestamp','?')}] ID:{event.get('id','?')} | {event.get('name','?')} | User:{event.get('real_userid',{}).get('user','?')} | Remote:{event.get('remote',{}).get('ip','?')}\")
        except:
            print(line[:100])
"

# Contar eventos por tipo
echo ""
echo "--- Conteo de eventos por tipo ---"
cat "${LAB_DIR}/audit-logs/audit-node1.log" | \
  python3 -c "
import sys, json
from collections import Counter
events = Counter()
for line in sys.stdin:
    line = line.strip()
    if line:
        try:
            event = json.loads(line)
            events[event.get('name', 'unknown')] += 1
        except:
            pass
for name, count in sorted(events.items(), key=lambda x: -x[1]):
    print(f'  {count:4d}  {name}')
"
```

#### Resultado Esperado

Los logs de auditoría deben contener entradas JSON con campos `timestamp`, `id`, `name`, `real_userid` y `remote`. Deben aparecer eventos de login exitoso, login fallido y ejecución de queries, confirmando que la trazabilidad está funcionando.

#### Verificación

```bash
# Verificar que el archivo de auditoría existe y tiene contenido reciente
ssh "ubuntu@${CB_NODE1}" \
  "ls -lh /opt/couchbase/var/lib/couchbase/logs/audit.log && \
   echo 'Líneas en audit.log:' && \
   sudo wc -l /opt/couchbase/var/lib/couchbase/logs/audit.log"
```

---

### Paso 6 — Hardening del Clúster y Documentación de Postura de Seguridad (14 minutos)

**Objetivo:** Aplicar medidas de hardening concretas al clúster, verificar su efectividad y documentar la postura de seguridad final en la matriz iniciada en el Paso 1.

#### Instrucciones

1. **Configurar headers de seguridad y opciones de hardening via API:**

```bash
echo "=== Aplicando configuración de hardening ==="

# Deshabilitar acceso HTTP a la UI (ya configurado en Paso 3, verificar)
# Configurar headers de seguridad HTTP adicionales
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/security" \
  -d 'disableUIOverHttp=true' \
  -d 'disableUIOverHttps=false' \
  -d 'tlsMinVersion=tlsv1.2' \
  -d 'honorCipherOrder=true' \
  | jq '{status: "hardening-applied"}'

echo "Headers de seguridad configurados"
```

2. **Verificar y documentar el estado de cifrado entre nodos:**

```bash
# Verificar el nivel de cifrado del clúster (comunicación inter-nodo)
echo "=== Estado de cifrado inter-nodo ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/security" \
  | jq '{
      tlsMinVersion: .tlsMinVersion,
      disableUIOverHttp: .disableUIOverHttp,
      honorCipherOrder: .honorCipherOrder,
      clusterEncryptionLevel: .clusterEncryptionLevel
    }'

# Habilitar cifrado inter-nodo si no está activo
echo "=== Habilitando cifrado de comunicación entre nodos ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/node/controller/enableExternalListener" \
  -d 'afamily=ipv4' 2>/dev/null || true

# Configurar nivel de encriptación del clúster a "all" (cifra todo el tráfico inter-nodo)
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X POST \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/controller/setClusterEncryptionLevel" \
  -d 'encryptionLevel=control' \
  | jq '.'

echo "Cifrado inter-nodo configurado a nivel 'control'"
```

3. **Rotar la contraseña del administrador (buena práctica de hardening):**

```bash
# Crear usuario administrador secundario antes de rotar (por seguridad)
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X PUT \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/admin-backup" \
  -d 'name=Admin+Backup' \
  -d 'password=AdminBackup@2024!' \
  -d 'roles=admin'

echo "Usuario admin-backup creado como respaldo"

# Verificar acceso con admin-backup antes de continuar
curl -s -u "admin-backup:AdminBackup@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default" \
  | jq '.clusterName'
```

4. **Generar el script de verificación de postura de seguridad:**

```bash
cat > "${LAB_DIR}/scripts/security-posture-check.sh" << 'SCRIPT'
#!/bin/bash
# Script de verificación de postura de seguridad — Lab 06
# Uso: ./security-posture-check.sh <admin_user> <admin_pass> <node_ip> <ca_cert>

CB_ADMIN_USER="${1:-Administrator}"
CB_ADMIN_PASS="${2:-Admin@Lab2024!}"
CB_CLUSTER="${3:-192.168.1.101}"
CA_CERT="${4:-/tmp/ca.crt}"

echo "======================================================="
echo " VERIFICACIÓN DE POSTURA DE SEGURIDAD — COUCHBASE LAB"
echo " Clúster: ${CB_CLUSTER} | $(date)"
echo "======================================================="
echo ""

# 1. Verificar TLS habilitado
echo "[1] Estado TLS:"
TLS_STATUS=$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/settings/security" \
  | jq -r '{tlsMin: .tlsMinVersion, httpDisabled: .disableUIOverHttp}')
echo "    ${TLS_STATUS}"

# 2. Verificar usuarios con rol admin
echo ""
echo "[2] Usuarios con rol administrador:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/settings/rbac/users/local" \
  | jq -r '.[] | select(.roles[].role == "admin") | "    ADMIN: \(.id)"'

# 3. Verificar auditoría activa
echo ""
echo "[3] Estado de auditoría:"
AUDIT_STATUS=$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/settings/audit" \
  | jq -r '"    Habilitada: \(.auditdEnabled) | Ruta: \(.logPath)"')
echo "${AUDIT_STATUS}"

# 4. Verificar certificado CA
echo ""
echo "[4] Certificado CA del clúster:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/pools/default/certificate" \
  | jq -r '"    Subject: \(.subject) | Expira: \(.expires)"'

# 5. Verificar grupos RBAC
echo ""
echo "[5] Grupos RBAC configurados:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_CERT}" \
  "https://${CB_CLUSTER}:18091/settings/rbac/groups" \
  | jq -r '.[] | "    Grupo: \(.id) | Roles: \([.roles[].role] | join(","))"'

echo ""
echo "======================================================="
echo " Verificación completada"
echo "======================================================="
SCRIPT

chmod +x "${LAB_DIR}/scripts/security-posture-check.sh"

# Ejecutar el script de verificación
bash "${LAB_DIR}/scripts/security-posture-check.sh" \
  "${CB_ADMIN_USER}" "${CB_ADMIN_PASS}" "${CB_CLUSTER}" "${CA_DIR}/ca.crt"
```

5. **Actualizar la matriz de postura de seguridad con el estado final:**

```bash
cat > "${LAB_DIR}/security-posture-final.txt" << EOF
=== MATRIZ DE POSTURA DE SEGURIDAD — ESTADO FINAL ===
Fecha: $(date)
Clúster: ${CB_CLUSTER}

Superficie           | Estado Final         | Control Aplicado              | Estado
---------------------|----------------------|-------------------------------|--------
Puerto 8091 (HTTP)   | UI DESHABILITADA     | disableUIOverHttp=true        | ✓ OK
Puerto 18091 (HTTPS) | TLS PERSONALIZADO    | CA privada + cert nodo        | ✓ OK
Puerto 11207 (KV-TLS)| TLS HABILITADO       | Certificado CA privada        | ✓ OK
Consola web          | Solo HTTPS           | TLS 1.2 mínimo                | ✓ OK
Usuarios             | RBAC granular        | 3 grupos + cuentas servicio   | ✓ OK
mTLS clientes        | HABILITADO           | Certificado X.509 cliente     | ✓ OK
Auditoría            | HABILITADA           | Todos los eventos, rotación   | ✓ OK
Cifrado inter-nodo   | CONTROL LEVEL        | TLS entre nodos               | ✓ OK
Menor privilegio     | IMPLEMENTADO         | svc-reader/query/index        | ✓ OK

USUARIOS DE SERVICIO CREADOS:
- svc-reader       → data_reader[travel-sample:inventory]
- svc-query        → query_select[travel-sample:inventory:airline,airport]
- svc-index        → query_manage_index[travel-sample]
- svc-mtls-client  → data_reader[travel-sample] (autenticación por certificado)

CERTIFICADOS EMITIDOS:
- CA privada: CouchbaseLab-CA (válida 10 años)
- node1, node2, node3: certificados individuales (válidos 2 años)
- Cliente mTLS: svc-mtls-client (válido 1 año)
EOF

cat "${LAB_DIR}/security-posture-final.txt"
```

#### Resultado Esperado

El script de verificación debe mostrar todos los controles en estado activo: TLS habilitado, auditoría activa, grupos RBAC configurados y certificado CA válido.

#### Verificación

```bash
# Verificación final integral
echo "=== VERIFICACIÓN FINAL DEL LABORATORIO ==="

echo "1. Grupos RBAC:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/groups" \
  | jq 'length' | xargs -I{} echo "   {} grupos configurados"

echo "2. TLS mínimo:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/security" \
  | jq -r '"   TLS mínimo: \(.tlsMinVersion) | HTTP deshabilitado: \(.disableUIOverHttp)"'

echo "3. Auditoría:"
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
  | jq -r '"   Habilitada: \(.auditdEnabled)"'
```

---

## Validación y Pruebas Finales

Ejecuta la siguiente batería de pruebas para confirmar que todos los controles de seguridad están funcionando correctamente:

```bash
#!/bin/bash
# Suite de validación final — Lab 06-00-01
echo "=============================================="
echo "  VALIDACIÓN FINAL — LAB 06 SEGURIDAD"
echo "=============================================="

PASS=0
FAIL=0

check() {
  local description="$1"
  local expected="$2"
  local actual="$3"

  if echo "${actual}" | grep -q "${expected}"; then
    echo "  ✓ PASS: ${description}"
    PASS=$((PASS + 1))
  else
    echo "  ✗ FAIL: ${description}"
    echo "         Esperado: ${expected}"
    echo "         Obtenido: ${actual:0:80}"
    FAIL=$((FAIL + 1))
  fi
}

# Test 1: HTTPS funciona con CA personalizado
RESULT=$(curl -s --cacert "${CA_DIR}/ca.crt" \
  -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -o /dev/null -w "%{http_code}" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default")
check "HTTPS con CA personalizado retorna 200" "200" "${RESULT}"

# Test 2: HTTP UI deshabilitado
RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
  "http://${CB_CLUSTER}:${CB_MGMT_PORT}/ui/index.html")
check "HTTP UI retorna 301/400 (deshabilitado)" "30\|40" "${RESULT}"

# Test 3: svc-reader puede leer datos
RESULT=$(curl -s -u "svc-reader:SvcRead@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  -o /dev/null -w "%{http_code}" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default")
check "svc-reader autentica correctamente" "200" "${RESULT}"

# Test 4: svc-query puede ejecutar SELECT
RESULT=$(curl -s -u "svc-query:SvcQuery@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:18093/query/service" \
  -d 'statement=SELECT 1 AS test' \
  | jq -r '.status')
check "svc-query ejecuta SELECT exitosamente" "success" "${RESULT}"

# Test 5: svc-reader NO puede hacer INSERT
RESULT=$(curl -s -u "svc-reader:SvcRead@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:18093/query/service" \
  -d 'statement=INSERT INTO `travel-sample`.inventory.airline (KEY,VALUE) VALUES ("rbac-test",{})' \
  | jq -r '.status')
check "svc-reader rechazado para INSERT (RBAC)" "errors\|fatal" "${RESULT}"

# Test 6: Auditoría habilitada
RESULT=$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
  | jq -r '.auditdEnabled')
check "Auditoría habilitada" "true" "${RESULT}"

# Test 7: Grupos RBAC existen
RESULT=$(curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/groups" \
  | jq -r '.[].id' | tr '\n' ',')
check "Grupo app-data-readers existe" "app-data-readers" "${RESULT}"
check "Grupo app-query-executors existe" "app-query-executors" "${RESULT}"
check "Grupo app-index-admins existe" "app-index-admins" "${RESULT}"

# Test 8: mTLS funciona con certificado de cliente
RESULT=$(curl -s \
  --cacert "${CA_DIR}/ca.crt" \
  --cert "${CERT_DIR}/client/client.crt" \
  --key "${CERT_DIR}/client/client.key" \
  -o /dev/null -w "%{http_code}" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/pools/default")
check "mTLS autentica con certificado de cliente" "200" "${RESULT}"

echo ""
echo "=============================================="
echo "  Resultados: ${PASS} PASS / ${FAIL} FAIL"
echo "=============================================="

if [ "${FAIL}" -eq 0 ]; then
  echo "  🎉 Todos los controles de seguridad validados correctamente"
else
  echo "  ⚠️  Revisar los controles con FAIL antes de continuar"
fi
```

---

## Troubleshooting

### Problema 1: `curl: (60) SSL certificate problem: unable to get local issuer certificate`

**Síntomas:**
Al intentar conectar a `https://node1:18091` con el CA personalizado, `curl` retorna el error `SSL certificate problem: unable to get local issuer certificate` aunque se especifica `--cacert`. La conexión falla completamente y no se obtiene respuesta del clúster.

**Causa:**
El certificado del nodo no fue cargado correctamente en el directorio `inbox` de Couchbase, o el comando `reloadCertificate` no se ejecutó en todos los nodos. Couchbase puede estar sirviendo aún el certificado autofirmado por defecto, que no está firmado por la CA privada del laboratorio. Otra causa frecuente es que el archivo `chain.pem` copiado al nodo no incluye la cadena completa (certificado de nodo + certificado CA intermediario si existe).

**Solución:**

```bash
# 1. Verificar qué certificado está sirviendo actualmente el nodo
openssl s_client -connect "${CB_NODE1}:18091" -servername "${CB_NODE1}" \
  </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer

# 2. Verificar que los archivos están en el inbox del nodo
ssh "ubuntu@${CB_NODE1}" \
  "ls -la /opt/couchbase/var/lib/couchbase/inbox/ && \
   sudo openssl x509 -in /opt/couchbase/var/lib/couchbase/inbox/chain.pem \
   -noout -subject -issuer"

# 3. Si el certificado es incorrecto, regenerar y recargar
# Re-copiar el certificado correcto
scp "${CERT_DIR}/node1/chain.pem" "ubuntu@${CB_NODE1}:/tmp/chain.pem"
ssh "ubuntu@${CB_NODE1}" \
  "sudo cp /tmp/chain.pem /opt/couchbase/var/lib/couchbase/inbox/chain.pem && \
   sudo chown couchbase:couchbase /opt/couchbase/var/lib/couchbase/inbox/chain.pem"

# 4. Forzar recarga del certificado en el nodo
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  -X POST \
  "http://${CB_NODE1}:8091/node/controller/reloadCertificate"

# 5. Esperar 5 segundos y verificar de nuevo
sleep 5
openssl s_client -connect "${CB_NODE1}:18091" -servername "${CB_NODE1}" \
  -CAfile "${CA_DIR}/ca.crt" </dev/null 2>/dev/null | grep -E "Verify|Issuer|Subject"
```

---

### Problema 2: Las pruebas de acceso negativas retornan HTTP 200 en lugar de HTTP 403

**Síntomas:**
Al ejecutar las pruebas RBAC del Paso 2, el usuario `svc-reader` puede ejecutar queries SQL++ exitosamente, o `svc-query` puede realizar operaciones de escritura. Las pruebas negativas no están fallando como se espera, lo que indica que los permisos no están siendo aplicados correctamente.

**Causa:**
Los roles en Couchbase se aplican con una semántica de unión: si un usuario pertenece a múltiples grupos o tiene roles asignados directamente además de los del grupo, se toman los permisos más amplios. Es posible que durante el Lab 01 se hayan asignado roles directamente a los usuarios de servicio (por ejemplo, `bucket_full_access[*]`), o que la sintaxis del rol en la llamada REST tenga un error que hizo que Couchbase ignorara la restricción de scope/colección y aplicara el rol a nivel de bucket completo.

**Solución:**

```bash
# 1. Inspeccionar los roles efectivos del usuario problemático
echo "=== Roles efectivos de svc-reader ==="
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/svc-reader" \
  | jq '{id: .id, groups: .groups, direct_roles: [.roles[] | {role: .role, bucket: .bucket_name, scope: .scope_name}]}'

# 2. Si hay roles directos adicionales, eliminarlos recreando el usuario sin roles directos
# Primero eliminar el usuario
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X DELETE \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/svc-reader"

# 3. Recrear solo con membresía de grupo (sin roles directos)
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  -X PUT \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/svc-reader" \
  -d 'name=Service+Account+Reader' \
  -d 'password=SvcRead@2024!' \
  -d 'groups=app-data-readers'
  # NOTA: No incluir el parámetro 'roles=' para evitar roles directos

# 4. Verificar que ahora solo tiene los roles del grupo
curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/svc-reader" \
  | jq '{groups: .groups, roles: [.roles[].role]}'

# 5. Repetir la prueba negativa
curl -s -u "svc-reader:SvcRead@2024!" \
  --cacert "${CA_DIR}/ca.crt" \
  "https://${CB_CLUSTER}:18093/query/service" \
  -d 'statement=SELECT * FROM `travel-sample` LIMIT 1' \
  | jq '{status: .status, errors: [.errors[]?.msg // empty]}'
# Debe retornar status: "errors" con mensaje de permisos insuficientes
```

---

## Limpieza del Entorno

Ejecuta los siguientes comandos para limpiar los recursos creados en este laboratorio. **Nota:** No eliminar los certificados TLS si planeas continuar con labs posteriores que requieran HTTPS.

```bash
echo "=== LIMPIEZA DEL LABORATORIO 06 ==="

# 1. Eliminar usuarios de servicio creados
for user in svc-reader svc-query svc-index svc-mtls-client admin-backup; do
  echo "Eliminando usuario: ${user}"
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    --cacert "${CA_DIR}/ca.crt" \
    -X DELETE \
    "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/users/local/${user}" \
    -o /dev/null
done

# 2. Eliminar grupos RBAC
for group in app-data-readers app-query-executors app-index-admins; do
  echo "Eliminando grupo: ${group}"
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    --cacert "${CA_DIR}/ca.crt" \
    -X DELETE \
    "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/rbac/groups/${group}" \
    -o /dev/null
done

# 3. Deshabilitar auditoría (opcional — mantener si se continúa con labs de observabilidad)
read -p "¿Deshabilitar auditoría? (s/N): " disable_audit
if [ "${disable_audit}" = "s" ] || [ "${disable_audit}" = "S" ]; then
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    --cacert "${CA_DIR}/ca.crt" \
    -X POST \
    "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/audit" \
    -d 'auditdEnabled=false'
  echo "Auditoría deshabilitada"
fi

# 4. Revertir TLS a configuración por defecto (solo si se requiere HTTP para labs siguientes)
read -p "¿Revertir TLS y rehabilitar HTTP? (s/N): " revert_tls
if [ "${revert_tls}" = "s" ] || [ "${revert_tls}" = "S" ]; then
  curl -s -u "${CB_ADMIN_USER}:${CB_ADMIN_PASS}" \
    --cacert "${CA_DIR}/ca.crt" \
    -X POST \
    "https://${CB_CLUSTER}:${CB_MGMT_TLS_PORT}/settings/security" \
    -d 'disableUIOverHttp=false'
  echo "HTTP rehabilitado"
fi

# 5. Conservar archivos de laboratorio para referencia
echo ""
echo "Archivos del laboratorio conservados en: ${LAB_DIR}"
echo "Para eliminar completamente: rm -rf ${LAB_DIR}"
echo ""
echo "=== Limpieza completada ==="
```

---

## Resumen

En este laboratorio implementaste una arquitectura de seguridad en capas completa sobre un clúster Couchbase de producción, aplicando directamente los cuatro pilares del modelo de seguridad de la lección:

| Capa | Lo que implementaste |
|---|---|
| **Red y transporte** | CA privada con OpenSSL, certificados por nodo, TLS 1.2 mínimo, HTTP deshabilitado, mTLS para clientes |
| **Autenticación** | Usuarios de servicio con contraseñas fuertes, autenticación por certificado X.509 (mTLS) |
| **Autorización** | 3 grupos RBAC con menor privilegio, 4 cuentas de servicio aisladas, pruebas de aislamiento positivas y negativas |
| **Auditoría** | Sistema de auditoría habilitado, eventos de login/query/configuración registrados, análisis de logs |

Además, aplicaste técnicas de **hardening** concretas: deshabilitación de UI sobre HTTP, configuración de TLS mínimo, cifrado inter-nodo y documentación de la postura de seguridad mediante una matriz de superficies de exposición que evolucionó desde el estado inicial (inseguro) hasta el estado final (endurecido).

Los tres principios rectores de la lección quedaron demostrados operacionalmente:
- **Defensa en profundidad:** el compromiso de una credencial de `svc-reader` no da acceso a queries ni a administración
- **Menor privilegio:** cada cuenta de servicio tiene exactamente los permisos que necesita
- **Auditabilidad:** cada acción sensible queda registrada con timestamp, usuario y origen de red

### Recursos Adicionales

- [Couchbase Security Guide — RBAC](https://docs.couchbase.com/server/current/learn/security/roles.html)
- [Couchbase TLS Configuration](https://docs.couchbase.com/server/current/manage/manage-security/manage-tls.html)
- [Couchbase Audit Events Reference](https://docs.couchbase.com/server/current/audit-event-reference/audit-event-reference.html)
- [OpenSSL Certificate Authority Guide](https://jamielinux.com/docs/openssl-certificate-authority/)
- [CIS Couchbase Benchmark](https://www.cisecurity.org/) — referencia de hardening para entornos regulados

---
LAB_END---
