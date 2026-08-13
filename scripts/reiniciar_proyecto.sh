#!/bin/sh
# volver al estado inicial

set -eu

. "$(dirname "$0")/comun.sh"

$COMPOSE --profile consumo down -v --remove-orphans
rm -rf ./duckdb_data
rm -rf ./data/generado

echo "Proyecto reiniciado."
