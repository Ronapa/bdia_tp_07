#!/bin/sh
# ejecuta un script de mongosh dentro del contenedor de MongoDB con la autenticacion
# "docker compose exec -T mongodb-eventos sh /scripts/ejecutar_mongo.sh /js/NN_archivo.js"
set -eu

archivo="${1:?Uso: ejecutar_mongo.sh /js/NN_archivo.js}"

mongosh --quiet \
    --host localhost --port 27017 \
    --username "$MONGO_INITDB_ROOT_USERNAME" \
    --password "$MONGO_INITDB_ROOT_PASSWORD" \
    --authenticationDatabase admin \
    "$archivo"
