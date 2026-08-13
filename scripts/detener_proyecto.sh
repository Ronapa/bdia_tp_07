#!/bin/sh
# baja todo sin perder la data, no alcanza solo con el stop comun
# por el profile consumo definido

set -eu

. "$(dirname "$0")/comun.sh"

$COMPOSE --profile consumo stop

echo ""
echo "Servicios detenidos. Los datos siguen en los volumenes."
echo "  Volver a levantar : sh scripts/ejecutar_pipeline.sh"
echo "  Borrar todo       : sh scripts/reiniciar_proyecto.sh  (DESTRUCTIVO)"
