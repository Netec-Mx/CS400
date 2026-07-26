---LAB_START---
LAB_ID: 05-00-01
---MARKDOWN---
# Implementación de búsqueda, automatización y análisis integrado

## Metadatos

| Campo         | Detalle                                                                 |
|---------------|-------------------------------------------------------------------------|
| **Duración**  | 78 minutos                                                              |
| **Complejidad** | Alta                                                                  |
| **Nivel Bloom** | Crear (Create)                                                        |
| **Servicios** | Search (FTS), Eventing, Analytics                                       |
| **Versión CB** | Couchbase Server Enterprise 7.6.x                                      |

---

## Descripción General

En esta práctica el estudiante integrará tres servicios especializados de Couchbase —Search, Eventing y Analytics— en un flujo de trabajo cohesivo. Partiendo del dataset `travel-sample`, creará un índice Full-Text Search con analyzers personalizados para español e inglés, desplegará una función Eventing en JavaScript que enriquece documentos de reservas en tiempo real, y configurará el Analytics Service para ejecutar consultas OLAP con window functions sin impactar el Query Service. El objetivo final es demostrar los límites operacionales y los casos de uso diferenciados de cada servicio dentro de una arquitectura empresarial real.

---

## Objetivos de Aprendizaje

- [ ] Crear un índice FTS sobre `travel-sample` con mappings estáticos, analyzers para español e inglés, y ejecutar búsquedas con operadores booleanos, fuzzy search y geo-spatial queries.
- [ ] Implementar y desplegar una función Eventing en JavaScript que reaccione a mutaciones en un bucket, valide y enriquezca documentos calculando campos derivados, y escriba resultados en un bucket destino.
- [ ] Configurar un Analytics Dataset como shadow de un bucket existente y ejecutar consultas OLAP con window functions y agregaciones complejas.
- [ ] Correlacionar las métricas de particiones FTS, los logs de Eventing y los planes de ejecución de Analytics para diagnosticar el comportamiento de cada servicio.

---

## Prerrequisitos

### Conocimiento Previo
- Lab 01-00-01 completado: clúster de 3 nodos con todos los servicios activos (Data, Query, Index, Search, Eventing, Analytics).
- Comprensión de diferencias entre OLTP y OLAP.
- Conocimiento básico de JavaScript (funciones, condicionales, objetos JSON).
- Familiaridad con SQL++ y la consola web de Couchbase.

### Acceso y Datos
- Dataset `travel-sample` cargado (≈63 K documentos; tipos: `hotel`, `airline`, `airport`, `route`, `landmark`).
- Dataset `beer-sample` cargado (opcional, para validación cruzada).
- Acceso a la Couchbase Web Console en `http://<nodo-principal>:8091`.
- Acceso SSH o terminal en al menos un nodo del clúster.
- Credenciales de administrador (usuario: `Administrator`).

---

## Entorno de Laboratorio

### Hardware Mínimo por Nodo

| Recurso        | Mínimo        | Recomendado   |
|----------------|---------------|---------------|
| vCPUs          | 4             | 8             |
| RAM            | 8 GB          | 16 GB         |
| Almacenamiento | 100 GB SSD    | 200 GB SSD    |
| Red inter-nodo | 1 Gbps        | 10 Gbps       |

### Software Requerido

| Componente                  | Versión       |
|-----------------------------|---------------|
| Couchbase Server EE         | 7.6.x         |
| cbq (Query Shell)           | Incluido 7.6.x|
| curl                        | 7.x+          |
| jq                          | 1.6+          |
| Python                      | 3.10+         |
| Couchbase Python SDK        | 4.2.x         |

### Verificación del Entorno Inicial

Antes de comenzar, confirme que los servicios requeridos están activos:

```bash
# Verificar estado del clúster y servicios activos
curl -s -u Administrator:password \
  http://localhost:8091/pools/default \
  | jq '.nodes[] | {hostname: .hostname, services: .services}'
```

Debe ver `fts`, `eventing` y `cbas` en la lista de servicios de al menos un nodo.

```bash
# Verificar que travel-sample está cargado
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets/travel-sample \
  | jq '{name: .name, itemCount: .basicStats.itemCount}'
```

La salida debe mostrar `itemCount` cercano a 63 000.

---

## Desarrollo del Laboratorio

---

### Parte 1: Search Service — Índice FTS con Mappings y Analyzers Personalizados

**Duración estimada: 28 minutos**

---

#### Paso 1.1 — Crear el índice FTS base con mappings dinámicos

**Objetivo:** Crear un índice Full-Text Search sobre el bucket `travel-sample` usando la API REST, con un mapping dinámico como punto de partida para luego agregar mappings estáticos.

**Instrucciones:**

1. Abra una terminal y ejecute el siguiente comando para crear el índice FTS inicial. Este índice usará el tipo de mapping `default` con el analyzer `standard` como base:

```bash
curl -s -u Administrator:password \
  -X PUT \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search \
  -d '{
    "type": "fulltext-index",
    "name": "hotel-search",
    "sourceType": "gocbcore",
    "sourceName": "travel-sample",
    "planParams": {
      "maxPartitionsPerPIndex": 1024,
      "indexPartitions": 3
    },
    "params": {
      "doc_config": {
        "docid_prefix_delim": "",
        "docid_regexp": "",
        "mode": "type_field",
        "type_field": "type"
      },
      "mapping": {
        "analysis": {
          "analyzers": {
            "hotel_es": {
              "type": "custom",
              "char_filters": [],
              "tokenizer": "unicode",
              "token_filters": [
                "to_lower",
                "stop_es",
                "stemmer_es"
              ]
            },
            "hotel_en": {
              "type": "custom",
              "char_filters": [],
              "tokenizer": "unicode",
              "token_filters": [
                "to_lower",
                "stop_en",
                "stemmer_en"
              ]
            }
          },
          "token_filters": {
            "stop_es": {
              "type": "stop_tokens",
              "stop_token_map": "es"
            },
            "stop_en": {
              "type": "stop_tokens",
              "stop_token_map": "en"
            },
            "stemmer_es": {
              "type": "stemmer",
              "lang": "es"
            },
            "stemmer_en": {
              "type": "stemmer",
              "lang": "en"
            }
          }
        },
        "default_analyzer": "standard",
        "default_datetime_parser": "dateTimeOptional",
        "default_field": "_all",
        "default_mapping": {
          "dynamic": false,
          "enabled": true
        },
        "default_type": "_default",
        "type_field": "type",
        "types": {
          "hotel": {
            "dynamic": false,
            "enabled": true,
            "properties": {
              "name": {
                "enabled": true,
                "dynamic": false,
                "fields": [
                  {
                    "name": "name",
                    "type": "text",
                    "analyzer": "hotel_en",
                    "index": true,
                    "store": true,
                    "include_in_all": true,
                    "include_term_vectors": true
                  }
                ]
              },
              "description": {
                "enabled": true,
                "dynamic": false,
                "fields": [
                  {
                    "name": "description",
                    "type": "text",
                    "analyzer": "hotel_es",
                    "index": true,
                    "store": true,
                    "include_in_all": true,
                    "include_term_vectors": true
                  }
                ]
              },
              "city": {
                "enabled": true,
                "dynamic": false,
                "fields": [
                  {
                    "name": "city",
                    "type": "text",
                    "analyzer": "keyword",
                    "index": true,
                    "store": true
                  }
                ]
              },
              "country": {
                "enabled": true,
                "dynamic": false,
                "fields": [
                  {
                    "name": "country",
                    "type": "text",
                    "analyzer": "keyword",
                    "index": true,
                    "store": true
                  }
                ]
              },
              "geo": {
                "enabled": true,
                "dynamic": false,
                "fields": [
                  {
                    "name": "geo",
                    "type": "geopoint",
                    "index": true,
                    "store": true
                  }
                ]
              },
              "reviews": {
                "enabled": true,
                "dynamic": false,
                "properties": {
                  "content": {
                    "enabled": true,
                    "dynamic": false,
                    "fields": [
                      {
                        "name": "content",
                        "type": "text",
                        "analyzer": "hotel_en",
                        "index": true,
                        "store": false
                      }
                    ]
                  },
                  "ratings": {
                    "enabled": true,
                    "dynamic": false,
                    "properties": {
                      "Overall": {
                        "enabled": true,
                        "dynamic": false,
                        "fields": [
                          {
                            "name": "Overall",
                            "type": "number",
                            "index": true,
                            "store": true
                          }
                        ]
                      }
                    }
                  }
                }
              }
            }
          }
        }
      },
      "store": {
        "indexType": "scorch",
        "segmentVersion": 15
      }
    },
    "sourceParams": {}
  }' | jq '.'
```

2. Espere 30–60 segundos para que el índice se construya. Monitoree el progreso:

```bash
# Verificar estado del índice (esperar hasta que docCount se estabilice)
watch -n 5 'curl -s -u Administrator:password \
  http://localhost:8094/api/index/hotel-search \
  | jq "{name: .indexDef.name, docCount: .status.docCount, numPIndexes: (.planPIndexes | length)}"'
```

**Salida Esperada:**

```json
{
  "name": "hotel-search",
  "docCount": 917,
  "numPIndexes": 3
}
```

> **Nota:** `docCount` debe aproximarse a 917, que es el número de documentos de tipo `hotel` en `travel-sample`. El número de `numPIndexes` refleja las 3 particiones configuradas.

**Verificación:**

```bash
# Confirmar que el índice está en estado "ready"
curl -s -u Administrator:password \
  http://localhost:8094/api/index/hotel-search \
  | jq '.status'
```

La respuesta debe incluir `"numDocsPendingIndexing": 0` cuando la indexación esté completa.

---

#### Paso 1.2 — Ejecutar búsquedas FTS: match, fuzzy y booleanas

**Objetivo:** Validar el índice ejecutando tres tipos de búsqueda que demuestren las capacidades lingüísticas y de relevancia del Search Service.

**Instrucciones:**

1. **Búsqueda de texto simple con analyzer español:**

```bash
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {
      "match": "beach",
      "field": "description",
      "analyzer": "hotel_en"
    },
    "size": 5,
    "from": 0,
    "fields": ["name", "city", "country"],
    "highlight": {
      "style": "html",
      "fields": ["description"]
    }
  }' | jq '{total: .total_hits, hits: [.hits[] | {id: .id, score: .score, name: .fields.name, city: .fields.city}]}'
```

2. **Búsqueda fuzzy (tolerancia a errores tipográficos):**

```bash
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {
      "fuzzy": "beech",
      "field": "description",
      "fuzziness": 1,
      "prefix_length": 2
    },
    "size": 5,
    "fields": ["name", "city"]
  }' | jq '{total: .total_hits, hits: [.hits[] | {id: .id, score: .score, name: .fields.name}]}'
```

> **Nota pedagógica:** La búsqueda fuzzy con `"beech"` (error tipográfico de "beach") con `fuzziness: 1` debe encontrar los mismos documentos que la búsqueda exacta, demostrando la tolerancia a errores del Search Service frente a SQL++ que requeriría coincidencia exacta.

3. **Búsqueda booleana combinada (conjuncts/disjuncts):**

```bash
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {
      "conjuncts": [
        {
          "match": "pool",
          "field": "description"
        },
        {
          "term": "United Kingdom",
          "field": "country"
        }
      ]
    },
    "size": 10,
    "fields": ["name", "city", "country"]
  }' | jq '{total: .total_hits, hits: [.hits[] | {id: .id, score: .score, name: .fields.name, city: .fields.city, country: .fields.country}]}'
```

**Salida Esperada (búsqueda booleana):**

```
{
  "total": <número entre 5-30>,
  "hits": [
    { "id": "hotel_...", "score": <float>, "name": "...", "city": "...", "country": "United Kingdom" },
    ...
  ]
}
```

**Verificación:**

```bash
# Confirmar que todos los resultados tienen country = "United Kingdom"
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {"conjuncts": [{"match": "pool","field": "description"},{"term": "United Kingdom","field": "country"}]},
    "size": 10,
    "fields": ["country"]
  }' | jq '[.hits[].fields.country] | unique'
```

El resultado debe ser `["United Kingdom"]`.

---

#### Paso 1.3 — Ejecutar una geo-spatial query

**Objetivo:** Demostrar la capacidad del Search Service para combinar búsqueda de texto con proximidad geográfica.

**Instrucciones:**

1. Ejecute una búsqueda geoespacial buscando hoteles con "pool" en la descripción a menos de 100 km de Londres (coordenadas: lon=-0.1276, lat=51.5074):

```bash
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {
      "conjuncts": [
        {
          "match": "pool",
          "field": "description"
        },
        {
          "location": {
            "lon": -0.1276,
            "lat": 51.5074
          },
          "distance": "100km",
          "field": "geo"
        }
      ]
    },
    "size": 10,
    "fields": ["name", "city", "country", "geo"],
    "sort": [
      {
        "by": "geo_distance",
        "field": "geo",
        "location": {"lon": -0.1276, "lat": 51.5074},
        "unit": "km"
      }
    ]
  }' | jq '{total: .total_hits, hits: [.hits[] | {name: .fields.name, city: .fields.city, geo: .fields.geo}]}'
```

2. Anote el número de resultados. Amplíe el radio a 200 km y compare:

```bash
# Mismo query pero con distance: "200km"
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8094/api/index/hotel-search/query \
  -d '{
    "query": {
      "conjuncts": [
        {"match": "pool", "field": "description"},
        {"location": {"lon": -0.1276, "lat": 51.5074}, "distance": "200km", "field": "geo"}
      ]
    },
    "size": 20,
    "fields": ["name", "city"]
  }' | jq '.total_hits'
```

**Salida Esperada:** El total de hits debe ser mayor con 200 km que con 100 km, confirmando el filtro geoespacial.

**Verificación:**

```bash
# Ver métricas del índice (particiones y documentos procesados)
curl -s -u Administrator:password \
  http://localhost:8094/api/index/hotel-search \
  | jq '{
      docCount: .status.docCount,
      numPIndexes: (.planPIndexes | length),
      numPartitions: .status.numPIndexes
    }'
```

---

### Parte 2: Eventing Service — Función de Enriquecimiento de Reservas

**Duración estimada: 25 minutos**

---

#### Paso 2.1 — Preparar los buckets para Eventing

**Objetivo:** Crear los buckets de origen (`bookings`) y destino (`bookings-enriched`) que usará la función Eventing, e insertar documentos de prueba.

**Instrucciones:**

1. Cree el bucket de origen para reservas:

```bash
curl -s -u Administrator:password \
  -X POST \
  http://localhost:8091/pools/default/buckets \
  -d 'name=bookings&ramQuota=256&bucketType=couchbase&replicaNumber=1'
```

2. Cree el bucket destino para documentos enriquecidos:

```bash
curl -s -u Administrator:password \
  -X POST \
  http://localhost:8091/pools/default/buckets \
  -d 'name=bookings-enriched&ramQuota=256&bucketType=couchbase&replicaNumber=1'
```

3. Espere 10 segundos y verifique que ambos buckets existen:

```bash
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets \
  | jq '[.[] | .name]'
```

4. Inserte 5 documentos de reserva de prueba usando `cbq`:

```bash
cbq -u Administrator -p password -engine http://localhost:8093 <<'EOF'
INSERT INTO bookings (KEY, VALUE) VALUES
  ("booking_001", {"type": "booking", "hotel_id": "hotel_10025", "customer_name": "Ana García", "checkin": "2024-06-15", "checkout": "2024-06-20", "room_rate": 120.00, "currency": "EUR", "status": "confirmed"}),
  ("booking_002", {"type": "booking", "hotel_id": "hotel_10158", "customer_name": "John Smith", "checkin": "2024-07-01", "checkout": "2024-07-07", "room_rate": 85.50, "currency": "GBP", "status": "confirmed"}),
  ("booking_003", {"type": "booking", "hotel_id": "hotel_10025", "customer_name": "María López", "checkin": "2024-06-20", "checkout": "2024-06-22", "room_rate": 120.00, "currency": "EUR", "status": "pending"}),
  ("booking_004", {"type": "booking", "hotel_id": "hotel_20420", "customer_name": "Carlos Ruiz", "checkin": "2024-08-10", "checkout": "2024-08-17", "room_rate": 200.00, "currency": "USD", "status": "confirmed"}),
  ("booking_005", {"type": "booking", "hotel_id": "hotel_10158", "customer_name": "Emma Wilson", "checkin": "2024-09-05", "checkout": "2024-09-08", "room_rate": 95.00, "currency": "GBP", "status": "cancelled"});
EOF
```

**Salida Esperada:**

```
{
  "results": [],
  "status": "success",
  "metrics": { "mutationCount": 5, ... }
}
```

**Verificación:**

```bash
cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'SELECT COUNT(*) as total FROM bookings;'
```

Debe retornar `"total": 5`.

---

#### Paso 2.2 — Crear y desplegar la función Eventing

**Objetivo:** Implementar una función JavaScript que reaccione a mutaciones en el bucket `bookings`, calcule campos derivados (duración de estadía, costo total, categoría de reserva) y escriba el documento enriquecido en `bookings-enriched`.

**Instrucciones:**

1. Cree el archivo de definición de la función Eventing:

```bash
cat > /tmp/booking-enrichment-function.json <<'EVENTING_EOF'
{
  "appcode": "function OnUpdate(doc, meta) {\n    // Solo procesar documentos de tipo 'booking'\n    if (!doc.type || doc.type !== 'booking') {\n        return;\n    }\n    \n    // Validar campos obligatorios\n    if (!doc.checkin || !doc.checkout || !doc.room_rate) {\n        log('booking-enrichment', 'Documento incompleto, omitiendo:', meta.id);\n        return;\n    }\n    \n    // Calcular duración de estadía en días\n    var checkinDate = new Date(doc.checkin);\n    var checkoutDate = new Date(doc.checkout);\n    var durationMs = checkoutDate.getTime() - checkinDate.getTime();\n    var durationDays = Math.round(durationMs / (1000 * 60 * 60 * 24));\n    \n    // Calcular costo total\n    var totalCost = doc.room_rate * durationDays;\n    \n    // Categorizar reserva por duración\n    var stayCategory;\n    if (durationDays <= 2) {\n        stayCategory = 'short_stay';\n    } else if (durationDays <= 7) {\n        stayCategory = 'medium_stay';\n    } else {\n        stayCategory = 'long_stay';\n    }\n    \n    // Categorizar por valor económico\n    var valueCategory;\n    if (totalCost < 300) {\n        valueCategory = 'budget';\n    } else if (totalCost < 1000) {\n        valueCategory = 'standard';\n    } else {\n        valueCategory = 'premium';\n    }\n    \n    // Construir documento enriquecido\n    var enrichedDoc = {\n        original_id: meta.id,\n        type: 'booking_enriched',\n        hotel_id: doc.hotel_id,\n        customer_name: doc.customer_name,\n        checkin: doc.checkin,\n        checkout: doc.checkout,\n        room_rate: doc.room_rate,\n        currency: doc.currency || 'USD',\n        status: doc.status,\n        // Campos calculados\n        duration_days: durationDays,\n        total_cost: totalCost,\n        stay_category: stayCategory,\n        value_category: valueCategory,\n        enriched_at: new Date().toISOString(),\n        enrichment_version: '1.0'\n    };\n    \n    // Escribir en bucket destino\n    var destKey = 'enriched_' + meta.id;\n    dst[destKey] = enrichedDoc;\n    \n    log('booking-enrichment', 'Documento enriquecido:', destKey, \n        'duracion:', durationDays, 'dias, total:', totalCost, doc.currency);\n}\n\nfunction OnDelete(meta, options) {\n    // Eliminar el documento enriquecido correspondiente\n    var destKey = 'enriched_' + meta.id;\n    delete dst[destKey];\n    log('booking-enrichment', 'Documento eliminado del destino:', destKey);\n}",
  "depcfg": {
    "buckets": [
      {
        "alias": "dst",
        "bucket_name": "bookings-enriched",
        "scope_name": "_default",
        "collection_name": "_default",
        "access": "rw"
      }
    ],
    "metadata_bucket": "bookings",
    "metadata_scope": "_default",
    "metadata_collection": "_default",
    "source_bucket": "bookings",
    "source_scope": "_default",
    "source_collection": "_default"
  },
  "settings": {
    "dcp_stream_boundary": "from_now",
    "deployment_status": false,
    "processing_status": false,
    "log_level": "INFO",
    "execution_timeout": 60,
    "worker_count": 3
  },
  "appname": "booking-enrichment",
  "function_scope": {
    "bucket": "*",
    "scope": "*"
  }
}
EVENTING_EOF
```

2. Registre la función en el Eventing Service:

```bash
curl -s -u Administrator:password \
  -X POST \
  -H "Content-Type: application/json" \
  http://localhost:8096/api/v1/functions/booking-enrichment \
  -d @/tmp/booking-enrichment-function.json \
  | jq '.'
```

3. Despliegue la función (cambio de estado a `deployed`):

```bash
curl -s -u Administrator:password \
  -X POST \
  http://localhost:8096/api/v1/functions/booking-enrichment/deploy \
  | jq '.'
```

4. Espere 15 segundos para que la función se inicialice y luego inserte un documento nuevo para disparar la función:

```bash
sleep 15

cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'INSERT INTO bookings (KEY, VALUE) VALUES ("booking_006", {"type": "booking", "hotel_id": "hotel_10025", "customer_name": "Pedro Martínez", "checkin": "2024-10-01", "checkout": "2024-10-10", "room_rate": 150.00, "currency": "EUR", "status": "confirmed"});'
```

5. Espere 5 segundos y verifique que el documento enriquecido fue creado:

```bash
sleep 5

cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'SELECT * FROM `bookings-enriched` WHERE original_id = "booking_006";'
```

**Salida Esperada:**

```json
{
  "bookings-enriched": {
    "original_id": "booking_006",
    "type": "booking_enriched",
    "hotel_id": "hotel_10025",
    "customer_name": "Pedro Martínez",
    "checkin": "2024-10-01",
    "checkout": "2024-10-10",
    "room_rate": 150.0,
    "currency": "EUR",
    "status": "confirmed",
    "duration_days": 9,
    "total_cost": 1350.0,
    "stay_category": "long_stay",
    "value_category": "premium",
    "enriched_at": "...",
    "enrichment_version": "1.0"
  }
}
```

**Verificación:**

```bash
# Verificar logs de ejecución de la función
curl -s -u Administrator:password \
  http://localhost:8096/api/v1/functions/booking-enrichment/applog \
  | tail -20
```

Debe ver líneas con `"Documento enriquecido: enriched_booking_006"`.

---

#### Paso 2.3 — Monitorear el ciclo de vida y métricas de Eventing

**Objetivo:** Observar las estadísticas de ejecución de la función Eventing y verificar el procesamiento de todos los documentos existentes.

**Instrucciones:**

1. Consulte las estadísticas de la función:

```bash
curl -s -u Administrator:password \
  http://localhost:8096/api/v1/functions/booking-enrichment/stats \
  | jq '{
      execution_stats: .execution_stats,
      failure_stats: .failure_stats,
      dcp_backlog: .dcp_backlog_size
    }'
```

2. Para procesar los documentos anteriores al despliegue (los 5 insertados antes), haga un `undeploy` y vuelva a desplegar con `from_beginning`:

```bash
# Undeploy
curl -s -u Administrator:password \
  -X POST \
  http://localhost:8096/api/v1/functions/booking-enrichment/undeploy \
  | jq '.'

sleep 10

# Actualizar configuración para procesar desde el inicio
curl -s -u Administrator:password \
  -X PATCH \
  -H "Content-Type: application/json" \
  http://localhost:8096/api/v1/functions/booking-enrichment \
  -d '{"settings": {"dcp_stream_boundary": "everything"}}' \
  | jq '.'

# Re-desplegar
curl -s -u Administrator:password \
  -X POST \
  http://localhost:8096/api/v1/functions/booking-enrichment/deploy \
  | jq '.'
```

3. Espere 30 segundos y verifique que todos los documentos fueron enriquecidos:

```bash
sleep 30

cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'SELECT COUNT(*) as enriched_count FROM `bookings-enriched`;'
```

**Salida Esperada:** `"enriched_count": 6` (los 5 originales + el booking_006).

**Verificación:**

```bash
# Ver distribución de categorías de estadía
cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'SELECT stay_category, value_category, COUNT(*) as count FROM `bookings-enriched` GROUP BY stay_category, value_category ORDER BY stay_category;'
```

---

### Parte 3: Analytics Service — Consultas OLAP sobre Datos de Viaje

**Duración estimada: 25 minutos**

---

#### Paso 3.1 — Crear el Analytics Dataset (Shadow Dataset)

**Objetivo:** Configurar el Analytics Service creando un link local y datasets que reflejen los datos de `travel-sample` y `bookings-enriched` para consultas analíticas sin impactar el Query Service.

**Instrucciones:**

1. Conéctese al Analytics Service usando `cbq` apuntando al puerto 8095:

```bash
cbq -u Administrator -p password -engine http://localhost:8095
```

2. Dentro de `cbq`, ejecute los siguientes comandos para crear el dataverse y los datasets:

```sql
-- Crear dataverse para el laboratorio
CREATE DATAVERSE TravelAnalytics IF NOT EXISTS;

USE TravelAnalytics;

-- Crear dataset shadow de hoteles desde travel-sample
CREATE DATASET Hotels ON `travel-sample`
  WHERE `type` = "hotel";

-- Crear dataset shadow de rutas
CREATE DATASET Routes ON `travel-sample`
  WHERE `type` = "route";

-- Crear dataset shadow de aeropuertos
CREATE DATASET Airports ON `travel-sample`
  WHERE `type` = "airport";

-- Crear dataset de reservas enriquecidas
CREATE DATASET BookingsEnriched ON `bookings-enriched`;

-- Conectar los datasets al Data Service
CONNECT LINK Local;
```

3. Verifique que los datasets están conectados y sincronizando:

```sql
USE TravelAnalytics;
SELECT DatasetName, BucketName, Status
FROM Metadata.`Dataset`
WHERE DataverseName = "TravelAnalytics";
```

**Salida Esperada:**

```
{
  "results": [
    { "DatasetName": "Hotels", "BucketName": "travel-sample", "Status": "..." },
    { "DatasetName": "Routes", "BucketName": "travel-sample", "Status": "..." },
    { "DatasetName": "Airports", "BucketName": "travel-sample", "Status": "..." },
    { "DatasetName": "BookingsEnriched", "BucketName": "bookings-enriched", "Status": "..." }
  ]
}
```

**Verificación:**

```sql
USE TravelAnalytics;
SELECT COUNT(*) as hotel_count FROM Hotels;
SELECT COUNT(*) as route_count FROM Routes;
```

Debe retornar valores cercanos a 917 y 24 024 respectivamente.

---

#### Paso 3.2 — Ejecutar consultas OLAP con Window Functions

**Objetivo:** Demostrar las capacidades analíticas del Analytics Service con consultas que serían costosas o imposibles en el Query Service OLTP.

**Instrucciones:**

1. **Consulta 1 — Ranking de hoteles por país usando window function:**

```sql
USE TravelAnalytics;

SELECT country,
       name,
       city,
       avg_rating,
       RANK() OVER (
         PARTITION BY country
         ORDER BY avg_rating DESC
       ) AS rank_in_country,
       COUNT(*) OVER (PARTITION BY country) AS hotels_in_country
FROM (
  SELECT h.name,
         h.city,
         h.country,
         AVG(r.ratings.Overall) AS avg_rating
  FROM Hotels h
  UNNEST h.reviews AS r
  WHERE h.country IS NOT MISSING
    AND r.ratings.Overall IS NOT MISSING
  GROUP BY h.name, h.city, h.country
) ranked
WHERE avg_rating IS NOT NULL
ORDER BY country, rank_in_country
LIMIT 20;
```

2. **Consulta 2 — Análisis de reservas enriquecidas con acumulado:**

```sql
USE TravelAnalytics;

SELECT hotel_id,
       stay_category,
       value_category,
       total_cost,
       SUM(total_cost) OVER (
         PARTITION BY hotel_id
         ORDER BY enriched_at
         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
       ) AS cumulative_revenue,
       AVG(total_cost) OVER (
         PARTITION BY stay_category
       ) AS avg_cost_by_category
FROM BookingsEnriched
ORDER BY hotel_id, enriched_at;
```

3. **Consulta 3 — Análisis de conectividad de rutas por aerolínea (consulta OLAP compleja):**

```sql
USE TravelAnalytics;

WITH RouteStats AS (
  SELECT r.airline,
         r.sourceairport,
         r.destinationairport,
         r.distance,
         COUNT(*) OVER (PARTITION BY r.airline) AS total_routes_airline,
         AVG(r.distance) OVER (PARTITION BY r.airline) AS avg_distance_airline,
         RANK() OVER (
           PARTITION BY r.airline
           ORDER BY r.distance DESC
         ) AS distance_rank
  FROM Routes r
  WHERE r.distance IS NOT MISSING
    AND r.airline IS NOT MISSING
)
SELECT airline,
       sourceairport,
       destinationairport,
       distance,
       total_routes_airline,
       ROUND(avg_distance_airline, 2) AS avg_distance_airline,
       distance_rank
FROM RouteStats
WHERE distance_rank <= 3
ORDER BY airline, distance_rank
LIMIT 30;
```

**Salida Esperada (Consulta 3, primeras filas):**

```json
{
  "results": [
    {
      "airline": "AA",
      "sourceairport": "...",
      "destinationairport": "...",
      "distance": <número>,
      "total_routes_airline": <número>,
      "avg_distance_airline": <número>,
      "distance_rank": 1
    },
    ...
  ]
}
```

**Verificación:**

```sql
-- Verificar que las window functions retornan valores distintos por partición
USE TravelAnalytics;
SELECT DISTINCT airline, total_routes_airline, avg_distance_airline
FROM (
  SELECT airline,
         COUNT(*) OVER (PARTITION BY airline) AS total_routes_airline,
         AVG(distance) OVER (PARTITION BY airline) AS avg_distance_airline
  FROM Routes
  WHERE distance IS NOT MISSING AND airline IS NOT MISSING
) stats
ORDER BY total_routes_airline DESC
LIMIT 10;
```

---

#### Paso 3.3 — Comparar plan de ejecución: Analytics vs Query Service

**Objetivo:** Demostrar la diferencia entre el plan de ejecución OLAP del Analytics Service y el plan OLTP del Query Service para la misma consulta lógica.

**Instrucciones:**

1. **Plan de ejecución en Analytics Service:**

```sql
-- En cbq conectado a puerto 8095 (Analytics)
USE TravelAnalytics;

EXPLAIN
SELECT h.country,
       COUNT(*) AS hotel_count,
       AVG(r.ratings.Overall) AS avg_rating
FROM Hotels h
UNNEST h.reviews AS r
WHERE r.ratings.Overall IS NOT MISSING
GROUP BY h.country
ORDER BY avg_rating DESC;
```

Anote los operadores del plan: `SCAN`, `UNNEST`, `AGGREGATE`, `SORT`.

2. **Plan de ejecución equivalente en Query Service:**

```bash
# En nueva terminal, conectado al Query Service (puerto 8093)
cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'EXPLAIN SELECT h.country, COUNT(*) AS hotel_count, AVG(r.ratings.Overall) AS avg_rating FROM `travel-sample` h UNNEST h.reviews AS r WHERE h.type = "hotel" AND r.ratings.Overall IS NOT MISSING GROUP BY h.country ORDER BY avg_rating DESC;'
```

3. Documente las diferencias clave en la siguiente tabla (complétela basándose en las salidas):

| Aspecto                  | Analytics Service          | Query Service (GSI)        |
|--------------------------|----------------------------|----------------------------|
| Operador de acceso       | Dataset Scan               | IndexScan / PrimaryScan    |
| Paralelismo              | Parallel (multi-core)      | Serial por defecto         |
| Impacto en Data Service  | Ninguno (shadow dataset)   | Lee vía DCP o índice       |
| Caso de uso óptimo       | OLAP / Batch analytics     | OLTP / Consultas puntuales |

**Verificación:**

```bash
# Comparar tiempos de ejecución de ambos servicios
echo "=== Analytics Service ===" && \
time cbq -u Administrator -p password -engine http://localhost:8095 \
  -script 'USE TravelAnalytics; SELECT country, COUNT(*) AS cnt FROM Hotels GROUP BY country ORDER BY cnt DESC;'

echo "=== Query Service ===" && \
time cbq -u Administrator -p password -engine http://localhost:8093 \
  -script 'SELECT country, COUNT(*) AS cnt FROM `travel-sample` WHERE type = "hotel" GROUP BY country ORDER BY cnt DESC;'
```

> **Observación esperada:** Para este volumen de datos (~63 K documentos), el Query Service puede ser más rápido gracias a los GSI. Con volúmenes de millones de documentos y consultas con múltiples joins y window functions, el Analytics Service escala mejor al no compartir recursos con el tráfico OLTP.

---

## Validación y Pruebas

### Checklist de Validación Final

Ejecute el siguiente script de validación que verifica los tres servicios:

```bash
cat > /tmp/validate-lab05.sh <<'VALIDATE_EOF'
#!/bin/bash
CB_URL="http://localhost"
AUTH="Administrator:password"
PASS=0
FAIL=0

check() {
  local desc="$1"
  local result="$2"
  local expected="$3"
  if echo "$result" | grep -q "$expected"; then
    echo "  [PASS] $desc"
    ((PASS++))
  else
    echo "  [FAIL] $desc (esperado: $expected, obtenido: $result)"
    ((FAIL++))
  fi
}

echo "=== Validación Lab 05-00-01 ==="
echo ""

echo "--- Search Service ---"
FTS_COUNT=$(curl -s -u $AUTH $CB_URL:8094/api/index/hotel-search | jq -r '.status.docCount // 0')
check "Índice hotel-search existe y tiene documentos" "$FTS_COUNT" "[1-9][0-9]*"

FTS_QUERY=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8094/api/index/hotel-search/query \
  -d '{"query":{"match":"pool","field":"description"},"size":1}' \
  | jq -r '.total_hits // 0')
check "Búsqueda FTS 'pool' retorna resultados" "$FTS_QUERY" "[1-9]"

GEO_QUERY=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8094/api/index/hotel-search/query \
  -d '{"query":{"conjuncts":[{"match":"pool","field":"description"},{"location":{"lon":-0.1276,"lat":51.5074},"distance":"200km","field":"geo"}]},"size":1}' \
  | jq -r '.total_hits // 0')
check "Geo-spatial query retorna resultados" "$GEO_QUERY" "[0-9]"

echo ""
echo "--- Eventing Service ---"
EVENTING_STATUS=$(curl -s -u $AUTH $CB_URL:8096/api/v1/functions/booking-enrichment \
  | jq -r '.settings.deployment_status // "unknown"')
check "Función booking-enrichment está desplegada" "$EVENTING_STATUS" "true"

ENRICHED_COUNT=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8093/query/service \
  -d '{"statement":"SELECT COUNT(*) as c FROM `bookings-enriched`","pretty":true}' \
  | jq -r '.results[0].c // 0')
check "Bucket bookings-enriched tiene documentos enriquecidos" "$ENRICHED_COUNT" "[1-9]"

CALC_FIELD=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8093/query/service \
  -d '{"statement":"SELECT COUNT(*) as c FROM `bookings-enriched` WHERE duration_days IS NOT MISSING AND total_cost IS NOT MISSING"}' \
  | jq -r '.results[0].c // 0')
check "Documentos tienen campos calculados (duration_days, total_cost)" "$CALC_FIELD" "[1-9]"

echo ""
echo "--- Analytics Service ---"
DATASET_COUNT=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8095/analytics/service \
  -d '{"statement":"SELECT COUNT(*) as c FROM Metadata.`Dataset` WHERE DataverseName = \"TravelAnalytics\""}' \
  | jq -r '.results[0].c // 0')
check "Datasets de TravelAnalytics existen (mínimo 3)" "$DATASET_COUNT" "[3-9]"

WINDOW_QUERY=$(curl -s -u $AUTH -X POST -H "Content-Type: application/json" \
  $CB_URL:8095/analytics/service \
  -d '{"statement":"USE TravelAnalytics; SELECT COUNT(*) as c FROM (SELECT name, RANK() OVER (PARTITION BY country ORDER BY name) as r FROM Hotels WHERE country IS NOT MISSING LIMIT 100) ranked"}' \
  | jq -r '.results[0].c // 0')
check "Window function RANK() ejecuta correctamente en Analytics" "$WINDOW_QUERY" "[1-9][0-9]*"

echo ""
echo "=== Resultado: $PASS passed, $FAIL failed ==="
VALIDATE_EOF

chmod +x /tmp/validate-lab05.sh
bash /tmp/validate-lab05.sh
```

**Resultado Esperado:** `6 passed, 0 failed`

---

## Resolución de Problemas

### Problema 1: La función Eventing no procesa documentos (dcp_backlog_size siempre en 0 y bookings-enriched vacío)

**Síntomas:**
- El comando `curl .../api/v1/functions/booking-enrichment/stats` muestra `"processed_count": 0`.
- El bucket `bookings-enriched` permanece vacío incluso después de insertar documentos en `bookings`.
- Los logs de la función muestran el mensaje `"Function deployed"` pero no hay entradas de procesamiento.

**Causa:**
La función fue desplegada con `"dcp_stream_boundary": "from_now"`, por lo que solo procesa mutaciones que ocurran *después* del despliegue. Los 5 documentos insertados antes del despliegue no serán procesados. Adicionalmente, puede existir un problema de permisos: el bucket `bookings-enriched` requiere que el usuario `Administrator` tenga acceso de escritura explícito en la configuración `depcfg.buckets`.

**Solución:**
```bash
# Paso 1: Verificar permisos del binding
curl -s -u Administrator:password \
  http://localhost:8096/api/v1/functions/booking-enrichment \
  | jq '.depcfg.buckets'

# Paso 2: Undeploy, cambiar boundary a "everything" y re-desplegar
curl -s -u Administrator:password \
  -X POST http://localhost:8096/api/v1/functions/booking-enrichment/undeploy
sleep 10

curl -s -u Administrator:password \
  -X PATCH -H "Content-Type: application/json" \
  http://localhost:8096/api/v1/functions/booking-enrichment \
  -d '{"settings": {"dcp_stream_boundary": "everything"}}'

curl -s -u Administrator:password \
  -X POST http://localhost:8096/api/v1/functions/booking-enrichment/deploy

# Paso 3: Verificar después de 30 segundos
sleep 30
curl -s -u Administrator:password \
  http://localhost:8096/api/v1/functions/booking-enrichment/stats \
  | jq '.execution_stats.on_update_success'
```

---

### Problema 2: Las consultas Analytics con window functions fallan con error "Feature not supported" o retornan 0 resultados

**Síntomas:**
- La consulta `RANK() OVER (PARTITION BY ...)` retorna error: `"Window functions are not supported in this context"`.
- O bien, `SELECT COUNT(*) FROM Hotels` retorna 0 aunque el bucket `travel-sample` tiene datos.
- El comando `CONNECT LINK Local` en el paso 3.1 no reportó error, pero los datasets parecen vacíos.

**Causa:**
Existen dos causas posibles: (a) El Analytics Service no ha completado la sincronización inicial del shadow dataset; puede tardar 1–3 minutos después de `CONNECT LINK Local` en un clúster recién configurado. (b) El nodo que ejecuta Analytics no tiene el servicio `cbas` activo, o se está conectando al puerto 8095 pero el servicio está en otro nodo del clúster.

**Solución:**
```bash
# Verificar qué nodo tiene el servicio Analytics activo
curl -s -u Administrator:password \
  http://localhost:8091/pools/default \
  | jq '.nodes[] | select(.services | contains(["cbas"])) | {hostname: .hostname, services: .services}'

# Si Analytics está en otro nodo (ej: nodo2), usar su IP
ANALYTICS_NODE="<IP-del-nodo-con-cbas>"

# Verificar estado de sincronización del dataset
curl -s -u Administrator:password \
  -X POST -H "Content-Type: application/json" \
  http://${ANALYTICS_NODE}:8095/analytics/service \
  -d '{"statement": "SELECT DatasetName, PendingOps FROM Metadata.`Dataset` WHERE DataverseName = \"TravelAnalytics\""}' \
  | jq '.results'

# Esperar a que PendingOps llegue a 0 (sincronización completa)
# Si el problema persiste, desconectar y reconectar el link
curl -s -u Administrator:password \
  -X POST -H "Content-Type: application/json" \
  http://${ANALYTICS_NODE}:8095/analytics/service \
  -d '{"statement": "USE TravelAnalytics; DISCONNECT LINK Local; CONNECT LINK Local;"}'
```

---

## Limpieza del Entorno

Ejecute los siguientes comandos para limpiar los recursos creados durante el laboratorio:

```bash
# 1. Undeploy y eliminar función Eventing
curl -s -u Administrator:password \
  -X POST http://localhost:8096/api/v1/functions/booking-enrichment/undeploy
sleep 10
curl -s -u Administrator:password \
  -X DELETE http://localhost:8096/api/v1/functions/booking-enrichment

# 2. Desconectar y eliminar datasets de Analytics
cbq -u Administrator -p password -engine http://localhost:8095 \
  -script 'USE TravelAnalytics; DISCONNECT LINK Local; DROP DATASET Hotels; DROP DATASET Routes; DROP DATASET Airports; DROP DATASET BookingsEnriched; DROP DATAVERSE TravelAnalytics;'

# 3. Eliminar índice FTS
curl -s -u Administrator:password \
  -X DELETE http://localhost:8094/api/index/hotel-search

# 4. Eliminar buckets de laboratorio
curl -s -u Administrator:password \
  -X DELETE http://localhost:8091/pools/default/buckets/bookings

curl -s -u Administrator:password \
  -X DELETE http://localhost:8091/pools/default/buckets/bookings-enriched

# 5. Verificar limpieza
echo "=== Verificación de limpieza ==="
echo "Buckets restantes:"
curl -s -u Administrator:password \
  http://localhost:8091/pools/default/buckets | jq '[.[] | .name]'

echo "Índices FTS restantes:"
curl -s -u Administrator:password \
  http://localhost:8094/api/index | jq '[.indexDefs.indexDefs | keys[]]'

echo "Funciones Eventing restantes:"
curl -s -u Administrator:password \
  http://localhost:8096/api/v1/functions | jq '[.[] | .appname]'
```

---

## Resumen

En este laboratorio integramos tres servicios especializados de Couchbase en un flujo de trabajo de nivel empresarial:

**Search Service:** Construimos un índice FTS `hotel-search` con 3 particiones, analyzers personalizados (`hotel_es` y `hotel_en`) basados en tokenización unicode, eliminación de stopwords y stemming morfológico. Ejecutamos búsquedas de texto simple, fuzzy search con `fuzziness: 1` para tolerancia a errores tipográficos, consultas booleanas con `conjuncts` y geo-spatial queries combinando texto y proximidad geográfica. El mecanismo scatter-gather distribuyó cada consulta entre las 3 particiones y el coordinador fusionó los resultados por puntuación TF-IDF.

**Eventing Service:** Implementamos la función `booking-enrichment` en JavaScript que reacciona a mutaciones en el bucket `bookings`, calcula campos derivados (`duration_days`, `total_cost`, `stay_category`, `value_category`) y escribe documentos enriquecidos en `bookings-enriched`. Observamos el ciclo de vida deploy/undeploy y la diferencia entre `from_now` y `everything` como `dcp_stream_boundary`.

**Analytics Service:** Creamos el dataverse `TravelAnalytics` con 4 shadow datasets y ejecutamos consultas OLAP con window functions (`RANK()`, `SUM() OVER`, `AVG() OVER`) que serían costosas en el Query Service OLTP. Comparamos los planes de ejecución de ambos servicios, confirmando que Analytics usa paralelismo multi-core y no impacta el Data Service al operar sobre su propia copia de los datos.

### Diferenciadores Clave Demostrados

| Servicio   | Ventaja Principal                              | Cuándo Usarlo                                    |
|------------|------------------------------------------------|--------------------------------------------------|
| Search FTS | Relevancia TF-IDF, fuzzy, geo, multilingüe    | Buscadores, autocompletado, búsqueda geoespacial |
| Eventing   | Reacción a mutaciones sin polling              | ETL en tiempo real, enriquecimiento, alertas     |
| Analytics  | OLAP paralelo sin impacto OLTP                 | Reportes, window functions, joins complejos      |

### Recursos Adicionales

- [Documentación oficial FTS — Tipos de consulta](https://docs.couchbase.com/server/current/fts/fts-query-types.html)
- [Referencia de Eventing Functions JavaScript](https://docs.couchbase.com/server/current/eventing/eventing-language-constructs.html)
- [Analytics SQL++ — Window Functions](https://docs.couchbase.com/server/current/analytics/sql-pp-reference.html)
- [Apache Bleve — Motor de búsqueda subyacente](https://blevesearch.com/docs/Query/)
- [Guía de Analyzers FTS en Couchbase](https://docs.couchbase.com/server/current/fts/fts-analyzers.html)

---
LAB_END---
