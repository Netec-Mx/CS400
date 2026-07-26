<img src="images/neteclogo (2).png" alt="logo" width="300"/>

# Operaciones Avanzadas en Couchbase

Este curso avanzado está diseñado para profesionales que requieren operar, optimizar y mantener plataformas Couchbase en entornos productivos de alta demanda. A lo largo del curso, el participante profundizará en la arquitectura interna del sistema, gestión avanzada de servicios (Data, Query, Index, Search, Analytics y Eventing), así como en estrategias de alta disponibilidad, seguridad, dimensionamiento y operación en Kubernetes.

Se abordarán escenarios reales de operación, incluyendo tuning de rendimiento, análisis de carga, troubleshooting y manejo de fallas, permitiendo al participante desarrollar habilidades para administrar clusters Couchbase bajo condiciones críticas y garantizar su estabilidad, eficiencia y escalabilidad.

## Estructura

- `CapituloXX/README.md`: guía de laboratorio por capítulo.

## Lista de laboratorios

### Capítulo 1

- [Análisis de la arquitectura y distribución interna de un clúster](Capitulo01/README.md#análisis-de-la-arquitectura-y-distribución-interna-de-un-clúster)
  - Descripción: Analizar la arquitectura y la distribución interna de un clúster Couchbase en Amazon EKS, identificando la topología, los vBuckets, las réplicas, el flujo de mutaciones y la separación de servicios.
  - Duración estimada: 60 min

### Capítulo 2

- [Configuración y análisis del Data Service bajo presión de memoria](Capitulo02/README.md#configuración-y-análisis-del-data-service-bajo-presión-de-memoria)
  - Descripción: Configurar y analizar el Data Service en Amazon EKS bajo condiciones de presión de memoria, observando cuotas, resident ratio, políticas de ejection, persistencia, réplicas y durabilidad.
  - Duración estimada: 84 min

### Capítulo 3

- [Diagnóstico y optimización de consultas SQL++](Capitulo03/README.md#diagnóstico-y-optimización-de-consultas-sql)
  - Descripción: Diagnosticar y optimizar consultas SQL++ en Amazon EKS mediante EXPLAIN, ADVISE y PROFILE, utilizando estadísticas, prepared statements, timeout y mecanismos de control de carga.
  - Duración estimada: 108 min

### Capítulo 4

- [Diseño de una estrategia de indexación para alta carga](Capitulo04/README.md#diseño-de-una-estrategia-de-indexación-para-alta-carga)
  - Descripción: Definir en Amazon EKS una estrategia de indexación para alta carga que combine índices simples, compuestos, parciales y covering indexes, además de particionamiento, réplicas, mantenimiento y recuperación.
  - Duración estimada: 90 min

### Capítulo 5

- [Implementación de búsqueda, automatización y análisis integrado](Capitulo05/README.md#implementación-de-búsqueda-automatización-y-análisis-integrado)
  - Descripción: Implementar en Amazon EKS una solución integrada que utilice Search para búsquedas, Eventing para automatización y Analytics para ingesta y consultas analíticas, considerando métricas y límites operativos.
  - Duración estimada: 78 min

### Capítulo 6

- [Implementación de seguridad en un entorno productivo](Capitulo06/README.md#implementación-de-seguridad-en-un-entorno-productivo)
  - Descripción: Implementar controles de seguridad en un entorno productivo sobre Amazon EKS, incluyendo RBAC, TLS, auditoría, registros, manejo de secretos, hardening y seguridad de red.
  - Duración estimada: 84 min

### Capítulo 7

- [Diseño de sizing y topología para una carga empresarial](Capitulo07/README.md#diseño-de-sizing-y-topología-para-una-carga-empresarial)
  - Descripción: Diseñar el sizing y la topología de un clúster Couchbase en Amazon EKS para una carga empresarial, considerando perfiles de carga, servicios, almacenamiento, Multidimensional Scaling, crecimiento, headroom y costos.
  - Duración estimada: 78 min

### Capítulo 8

- [Escalamiento y rebalanceo del clúster bajo carga](Capitulo08/README.md#escalamiento-y-rebalanceo-del-clúster-bajo-carga)
  - Descripción: Ejecutar en Amazon EKS el escalamiento y rebalanceo de un clúster bajo carga, incorporando y removiendo nodos, gestionando datos, índices y servicios, y utilizando CLI, REST API y scripts.
  - Duración estimada: 96 min

### Capítulo 9

- [Simulación de fallos y recuperación entre clústeres](Capitulo09/README.md#simulación-de-fallos-y-recuperación-entre-clústeres)
  - Descripción: Simular fallos y ejecutar la recuperación entre clústeres en Amazon EKS mediante réplicas, failover, Server Groups, Zone Awareness y XDCR, considerando RPO, RTO y escenarios multi-región.
  - Duración estimada: 78 min

### Capítulo 10

- [Despliegue y recuperación de Couchbase en Kubernetes](Capitulo10/README.md#despliegue-y-recuperación-de-couchbase-en-kubernetes)
  - Descripción: Desplegar y recuperar Couchbase en Kubernetes con Amazon EKS mediante el Couchbase Kubernetes Operator, CRDs, el recurso CouchbaseCluster, persistencia, configuración de pods, reconciliación, logs y eventos.
  - Duración estimada: 84 min

### Capítulo 11

- [Construcción de un dashboard operativo y alertas](Capitulo11/README.md#construcción-de-un-dashboard-operativo-y-alertas)
  - Descripción: Construir en Amazon EKS un dashboard operativo y un conjunto de alertas con Prometheus y Grafana, incorporando métricas críticas, logs, eventos y baselines de los servicios Couchbase.
  - Duración estimada: 72 min

### Capítulo 12

- [Ejecución de carga, análisis y optimización](Capitulo12/README.md#ejecución-de-carga-análisis-y-optimización)
  - Descripción: Ejecutar pruebas de carga en Amazon EKS para operaciones KV y consultas SQL++, analizar throughput, latencia, percentiles, errores y saturación, y aplicar tuning de memoria, CPU, red y almacenamiento.
  - Duración estimada: 48 min

### Capítulo 13

- [Diagnóstico, recuperación y mantenimiento del clúster](Capitulo13/README.md#diagnóstico-recuperación-y-mantenimiento-del-clúster)
  - Descripción: Diagnosticar incidentes y ejecutar la recuperación y el mantenimiento de un clúster en Amazon EKS, correlacionando métricas, logs y eventos, y aplicando backup, restore, rolling upgrades, rollback y runbooks.
  - Duración estimada: 48 min
------------


## 📬 Contacto y más información

Si tienes alguna pregunta o necesitas soporte durante la realización de los laboratorios, no dudes en **contactar al equipo de Netec**. También puedes encontrar más recursos y cursos en nuestra página oficial:

👉 https://netec.com

---

¡Bienvenido! Te recomendamos realizar los laboratorios en el orden presentado, ya que cada práctica construye la infraestructura y los conocimientos necesarios para la siguiente, culminando con un escenario completo de migración y operación.
