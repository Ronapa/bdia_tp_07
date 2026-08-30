#!/bin/sh
# Objetivo: regenerar los entregables derivados de la documentacion: diagramas en PNG e informe en PDF.
# Requiere / entradas: docs/diagramas/*.mmd y docs/informe.md; Docker con acceso a internet la primera vez.
# Produce / modifica: docs/diagramas/*.png y docs/informe.pdf.
# Resultado esperado: cuatro PNG y un PDF, listados al final.
# Guia: es un paso OPCIONAL; el proyecto corre sin ejecutarlo. Los artefactos estan versionados.
set -eu

cd "$(dirname "$0")/.."

USUARIO="$(id -u):$(id -g)"

# ============================================================
# 1. Diagramas
#
# Los .mmd son la fuente: texto versionable que GitHub y GitLab renderizan
# de forma nativa. Los .png se generan para el informe en PDF y para que
# revisar el trabajo no exija tener mermaid-cli.
#
# Node corre siempre dentro de un contenedor, nunca instalado en la maquina.
# ============================================================

echo "--- Generando diagramas ---"
for archivo in docs/diagramas/*.mmd; do
    nombre="$(basename "$archivo" .mmd)"
    docker run --rm -v "$PWD/docs/diagramas:/data" -u "$USUARIO" \
        minlag/mermaid-cli -i "${nombre}.mmd" -o "${nombre}.png" -w 2400 >/dev/null
    echo "  ${nombre}.png"
done

# ============================================================
# 2. Informe en PDF
#
# La fuente es docs/informe.md. El PDF se genera para la entrega porque la
# consigna lo lista como entregable, pero el markdown es lo que se edita:
# nunca al reves.
# ============================================================

echo "--- Generando el informe en PDF ---"
docker run --rm -v "$PWD/docs:/data" -u "$USUARIO" \
    pandoc/latex informe.md -o informe.pdf \
    --pdf-engine=xelatex \
    -V geometry:margin=2.5cm \
    -V lang=es \
    -V fontsize=10pt \
    -V colorlinks=true \
    --toc --toc-depth=2 >/dev/null

echo ""
ls -lh docs/informe.pdf docs/diagramas/*.png | awk '{print "  " $9 "  " $5}'
echo ""
echo "Documentos generados."
