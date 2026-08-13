#!/bin/sh
# ejecuta un archivo Cypher dentro del contenedor de Neo4j
# "docker compose exec -T neo4j-grafo sh /scripts/ejecutar_cypher.sh /cypher/NN_archivo.cypher"
set -eu

archivo="${1:?Uso: ejecutar_cypher.sh /cypher/NN_archivo.cypher}"

cypher-shell -u "$GRAFO_USER" -p "$GRAFO_PASSWORD" --fail-fast --file "$archivo"
