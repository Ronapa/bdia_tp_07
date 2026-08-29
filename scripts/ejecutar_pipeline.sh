#!/bin/sh
# Objetivo: reconstruir el proyecto completo end-to-end con un solo comando.
# Requiere / entradas: .env creado y Docker en ejecucion.
# Produce / modifica: esquema y datos en PostgreSQL, MongoDB, Redis, Neo4j y el bucket lakehouse de MinIO.
# Resultado esperado: todos los pasos en verde; los pasos de verificacion abortan si un conteo no cierra.
# Guia: cada bloque corresponde a una capa de la arquitectura descripta en docs/informe.md.
set -eu

. "$(dirname "$0")/comun.sh"

pg()    { $COMPOSE exec -T postgres-operacional sh /scripts/ejecutar_sql.sh "$1"; }
duck()  { $COMPOSE exec -T duckdb-transformer sh /scripts/ejecutar_duckdb.sh "$1"; }
mongo() { $COMPOSE exec -T mongodb-eventos sh /scripts/ejecutar_mongo.sh "$1"; }
grafo() { $COMPOSE exec -T neo4j-grafo sh /scripts/ejecutar_cypher.sh "$1"; }
py()    { archivo="$1"; shift; $COMPOSE exec -T orquestador python "/workspace/orquestador/${archivo}" "$@"; }
puerto() { grep -E "^$1=" .env | cut -d= -f2; }

echo "--- Paso 1: levantar los servicios ---"
$COMPOSE up -d --build --wait

echo "--- Paso 2: estructura relacional ---"
pg /sql/estructura/01_crear_schemas_y_extensiones.sql
pg /sql/estructura/02_personas.sql
pg /sql/estructura/03_catalogo.sql
pg /sql/estructura/04_recomendacion.sql
pg /sql/estructura/05_analitica_y_control.sql
pg /sql/estructura/06_embeddings.sql
pg /sql/estructura/07_auditoria.sql

echo "--- Paso 3: indices y vistas ---"
pg /sql/indices_vistas/01_indices.sql
pg /sql/indices_vistas/02_vistas.sql
pg /sql/indices_vistas/03_vistas_materializadas.sql

echo "--- Paso 4: seguridad, permisos y auditoria ---"
pg /sql/seguridad/01_roles_y_permisos.sql
pg /sql/seguridad/02_row_level_security.sql
pg /sql/seguridad/03_auditoria.sql
pg /sql/seguridad/04_vistas_anonimizadas.sql

echo "--- Paso 5: generar el dataset sintetico ---"
py generar_datos.py

echo "--- Paso 6: cargar PostgreSQL ---"
pg /sql/datos/01_datos_referencia.sql
py cargar_postgres.py
pg /sql/consultas/00_verificar_carga.sql

echo "--- Paso 7: cargar MongoDB ---"
mongo /js/00_cargar_datos.js
py cargar_mongo.py
mongo /js/01_indices.js
mongo /js/02_usuarios_y_permisos.js

echo "--- Paso 8: embeddings e indices vectoriales ---"
py generar_embeddings.py
pg /vectorial/01_crear_indices_vectoriales.sql

echo "--- Paso 9: publicar la capa Bronze en el lakehouse ---"
py exportar_bronze.py
$COMPOSE exec -T minio-admin sh /scripts/cargar_bronze.sh
$COMPOSE exec -T minio-admin sh /scripts/configurar_minio.sh

echo "--- Paso 10: procesar Silver y Gold con DuckDB ---"
duck /sql/01_perfilar_bronze.sql
duck /sql/02_procesar_silver.sql
duck /sql/03_publicar_silver.sql
duck /sql/04_cargar_gold.sql
duck /sql/05_verificar_calidad.sql

echo "--- Paso 11: publicar la capa de serving (Redis) ---"
py publicar_serving.py

# Drena el stream de ingesta y confirma los mensajes. Se corre sin
# --simular para no alterar los conteos del dataset determinista;
py consumir_stream.py

echo "--- Paso 12: construir el grafo de recomendacion (Neo4j) ---"
grafo /cypher/00_restricciones_e_indices.cypher
py cargar_neo4j.py
grafo /cypher/01_usuarios.cypher

echo "--- Paso 13: verificacion final ---"
pg /sql/consultas/00_verificar_carga.sql

echo ""
echo "Pipeline completo."
echo "  pgAdmin        : http://127.0.0.1:$(puerto PGADMIN_PORT)"
echo "  Mongo Express  : http://127.0.0.1:$(puerto MONGO_EXPRESS_PORT)"
echo "  Neo4j Browser  : http://127.0.0.1:$(puerto NEO4J_HTTP_PORT)"
echo "  MinIO Consola  : http://127.0.0.1:$(puerto MINIO_CONSOLE_PORT)"
