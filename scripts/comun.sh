#!/bin/sh
# chequea que version de docker-compose hay disponible

if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif docker-compose version >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo "No se encontro Compose. Instalá el plugin 'docker compose' o el binario 'docker-compose'." >&2
    exit 1
fi
