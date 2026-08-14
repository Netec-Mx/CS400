#!/usr/bin/env bash
# solo la primera vez ejecuta: chmod +x scripts/create_labs.sh
# por ejemplo, para crear 10 labs ejecuta: ./scripts/create_labs.sh 2

set -euo pipefail

# Directorio raíz donde viven los labs
ROOT_DIR="labs"

# Parámetro:
# 1) número total de prácticas a crear
TOTAL_LABS="${1:-}"

if [[ -z "$TOTAL_LABS" ]]; then
  echo "Uso: $0 <numero_de_labs>"
  echo "Ejemplo: $0 5"
  exit 1
fi

mkdir -p "${ROOT_DIR}"

for i in $(seq 1 "$TOTAL_LABS"); do
  LAB_DIR="${ROOT_DIR}/lab${i}"
  IMG_DIR="${LAB_DIR}/img"
  MD_FILE="${LAB_DIR}/lab${i}.md"

  # Rutas prev/next automáticas
  if [[ "$i" -eq 1 ]]; then
    PREV_PATH="/"
  else
    PREV_NUM=$((i - 1))
    PREV_PATH="/lab${PREV_NUM}/lab${PREV_NUM}/"
  fi

  if [[ "$i" -eq "$TOTAL_LABS" ]]; then
    # Para la última práctica dejamos "/" como placeholder
    NEXT_PATH="/"
  else
    NEXT_NUM=$((i + 1))
    NEXT_PATH="/lab${NEXT_NUM}/lab${NEXT_NUM}/"
  fi

  echo "Creando estructura para ${LAB_DIR}..."

  mkdir -p "${IMG_DIR}"

  if [[ -f "${MD_FILE}" ]]; then
    echo "  -> ${MD_FILE} ya existe, se deja igual."
    continue
  fi

  cat > "${MD_FILE}" <<EOF
---
layout: lab
title: "Práctica ${i}: CAMBIAR_AQUI_NOMBRE_DE_LA_PRACTICA" # CAMBIAR POR CADA PRACTICA
permalink: /lab${i}/lab${i}/
images_base: /labs/lab${i}/img
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
slug: lab${i}
lab_number: ${i}
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
prev: ${PREV_PATH}
next: ${NEXT_PATH}
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
  
  > **NOTA:** Si la carpeta Terraform no existe, creala en el directorio C:\\
  {: .lab-note .info .compact}

  {% assign results = site.data.task-results[page.slug].results %}
  {% capture r1 %}{{ results[0] }}{% endcapture %}
  {% include task-result.html title="Tarea finalizada" content=r1 %}
EOF

done

echo "Listo. Se generaron las prácticas en ${ROOT_DIR}/"
