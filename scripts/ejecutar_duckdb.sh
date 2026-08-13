#!/bin/sh
# ejecuta un archivo SQL de DuckDB con el acceso a MinIO (y a PostgreSQL cuando corresponde) ya configurado.

set -eu

archivo="${1:?Uso: ejecutar_duckdb.sh /sql/NN_archivo.sql}"
base="/workspace/nexomedia.duckdb"

usuario_s3="${MINIO_TRANSFORMADOR_USER:?Falta MINIO_TRANSFORMADOR_USER: el transformador no debe usar credenciales root}"
clave_s3="${MINIO_TRANSFORMADOR_PASSWORD:?Falta MINIO_TRANSFORMADOR_PASSWORD}"

configuracion="INSTALL httpfs; LOAD httpfs;
CREATE OR REPLACE SECRET minio_local (
  TYPE s3,
  KEY_ID '$usuario_s3',
  SECRET '$clave_s3',
  REGION 'us-east-1',
  ENDPOINT 'minio-lake:9000',
  URL_STYLE 'path',
  USE_SSL false
);"

case "$archivo" in
  */04_*|*/05_*)
    configuracion="$configuracion
INSTALL postgres; LOAD postgres;
ATTACH 'host=postgres-operacional port=5432 dbname=$POSTGRES_DB user=$POSTGRES_USER password=$POSTGRES_PASSWORD' AS pg (TYPE postgres);"
    ;;
esac

duckdb "$base" -c "$configuracion" -c ".read $archivo"

chmod 0777 /workspace
chmod 0666 "$base"
