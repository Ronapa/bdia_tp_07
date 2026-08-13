#!/bin/sh
# comprueba que la maquina puede levantar el entorno entero antes de descargar
# chequea el env tambien

set -eu

. "$(dirname "$0")/comun.sh"

echo "--- Compose ---"
echo "Comando detectado: $COMPOSE"
$COMPOSE version | head -1

echo ""
echo "--- Archivo .env ---"
if [ ! -f .env ]; then
    echo "Falta .env. Ejecutá: cp .env.example .env" >&2
    exit 1
fi
echo ".env presente."

# shellcheck disable=SC1091
. ./.env

echo ""
echo "--- Puertos requeridos ---"
faltantes=0
for par in \
    "PostgreSQL:$POSTGRES_PORT" \
    "pgAdmin:$PGADMIN_PORT" \
    "MongoDB:$MONGO_PORT" \
    "MongoExpress:$MONGO_EXPRESS_PORT" \
    "Redis:$REDIS_PORT" \
    "Neo4jHTTP:$NEO4J_HTTP_PORT" \
    "Neo4jBolt:$NEO4J_BOLT_PORT" \
    "MinIOAPI:$MINIO_API_PORT" \
    "MinIOConsola:$MINIO_CONSOLE_PORT" \
    "API:$API_PORT"
do
    nombre="${par%%:*}"
    puerto="${par##*:}"
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${puerto}\$"; then
        echo "OCUPADO  ${nombre} (${puerto}) -- cambiá el valor en .env"
        faltantes=$((faltantes + 1))
    else
        echo "libre    ${nombre} (${puerto})"
    fi
done

echo ""
echo "--- Recursos ---"
memoria_mb="$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
echo "Memoria disponible: ${memoria_mb} MB (recomendado: 6000 MB o mas)"
disco_gb="$(df -Pk . | awk 'NR==2 {print int($4/1048576)}')"
echo "Disco libre: ${disco_gb} GB (recomendado: 15 GB o mas)"

echo ""
if [ "$faltantes" -gt 0 ]; then
    echo "Hay ${faltantes} puerto(s) ocupado(s). Ajustá .env antes de continuar." >&2
    exit 1
fi
echo "Entorno listo. Continuá con: sh scripts/ejecutar_pipeline.sh"
