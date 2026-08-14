---
layout: lab
title: "Práctica 11: CAMBIAR_AQUI_NOMBRE_DE_LA_PRACTICA" # CAMBIAR POR CADA PRACTICA
permalink: /lab11/lab11/
images_base: /labs/lab11/img
duration: "## minutos" # CAMBIAR POR CADA PRACTICA
objective: # CAMBIAR POR CADA PRACTICA
  - OBJECTIVO_DE_LA_PRACTICA
prerequisites: # CAMBIAR POR CADA PRACTICA
  - PREREQUISITO_1
  - PREREQUISITO_2
  - PREREQUISITO_3
  - PREREQUISITO_4
  - PREREQUISITO_X
introduction: # CAMBIAR POR CADA PRACTICA
  - INTRODUCCIÓN_DE_LA_PRACTICA_BREVE_RESUMEN_EN_UN_SOLO_PARRAFO_RECOMENDADO
slug: lab11
lab_number: 11
final_result: > # CAMBIAR POR CADA PRACTICA
  RESULTADO_FINAL_ESPERADO_DE_LA_PRACTICA_EN_UN_SOLO_PARRAFO_RECOMENDADO
notes: # CAMBIAR POR CADA PRACTICA EN CASO DE QUE SE REQUIERA
  - NOTAS_CONSIDERACIONES_ADICIONALES
  - NOTAS_CONSIDERACIONES_ADICIONALES
references: # CAMBIAR POR CADA PRACTICA LINKS ADICIONALES DE DOCUMENTACION
  - text: DESCRIPCION DEL LINK DE REFERENCIA
    url: https://developer.hashicorp.com/terraform
  - text: DESCRIPCION DEL LINK DE REFERENCIA
    url: https://learn.microsoft.com/es-es/cli/azure/
prev: /lab10/lab10/
next: /lab12/lab12/
---

---
<!-- Aquí comienzan las instrucciones paso a paso de la práctica -->
## Tarea 1. NOMBRE DE LA TAREA
DESCRIPCION DE LA TAREA

### Tarea 1.1. NOMBRE DE LA SUBTAREA
DESCRIPCION DE LA SUBTAREA

- {% include step_label.html %} Una vez descargado el archivo, haz clic derecho…
- {% include step_label.html %} Haz clic en "Abrir con Visual Studio Code"
  {% include step_image.html %}

  > **IMPORTANTE:** Si la carpeta TERRALABS no existe, creala en el Escritorio.
  {: .lab-note .important .compact}
  
  > **NOTA:** Si la carpeta Terraform no existe, creala en el directorio C:\
  {: .lab-note .info .compact}

  {% assign results = site.data.task-results[page.slug].results %}
  {% capture r1 %}{{ results[0] }}{% endcapture %}
  {% include task-result.html title="Tarea finalizada" content=r1 %}
