#!/bin/sh
# ejecuta un archivo sql dentro del contenedor de PostgreSQL
# "docker compose exec -T postgres-operacional sh /scripts/ejecutar_sql.sh /sql/..."
set -eu

archivo="${1:?Uso: ejecutar_sql.sh /sql/carpeta/NN_archivo.sql}"

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f "$archivo"
