#!/bin/sh
# Objetivo: crear en MinIO los usuarios acotados al lakehouse, para que ningun consumidor use las credenciales root.
# Requiere / entradas: bucket lakehouse creado por cargar_bronze.sh; credenciales root por variables de entorno.
# Produce / modifica: dos politicas y dos usuarios: uno de solo lectura y uno de lectura-escritura.
# Resultado esperado: el de lectura no puede escribir; el transformador no puede crear buckets.
# Guia: se ejecuta dentro del contenedor minio-admin, que es el que tiene el cliente mc.
set -eu

USUARIO_LECTURA="bdia_lake_lectura"
CLAVE_LECTURA="lectura_local_lake"
USUARIO_TRANSFORMADOR="${MINIO_TRANSFORMADOR_USER:-bdia_lake_transformador}"
CLAVE_TRANSFORMADOR="${MINIO_TRANSFORMADOR_PASSWORD:-transformador_local}"

mc alias set local http://minio-lake:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# ============================================================
# 1. Politica de solo lectura sobre el lakehouse
#
# MinIO usa politicas con la misma gramatica que IAM de S3. Esta permite
# listar el bucket y descargar objetos, y nada mas: sin PutObject, sin
# DeleteObject, sin acceso a la administracion del servidor.
#
# El alcance esta acotado al bucket lakehouse: si manana hubiera otro
# bucket, este usuario no lo veria.
# ============================================================

cat > /tmp/lakehouse_lectura.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::lakehouse"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject"],
      "Resource": ["arn:aws:s3:::lakehouse/*"]
    }
  ]
}
JSON

mc admin policy create local lakehouse_lectura /tmp/lakehouse_lectura.json >/dev/null 2>&1 \
    || mc admin policy remove local lakehouse_lectura >/dev/null 2>&1 \
    && mc admin policy create local lakehouse_lectura /tmp/lakehouse_lectura.json >/dev/null

# ============================================================
# 2. Usuario y asignacion
# ============================================================

mc admin user add local "$USUARIO_LECTURA" "$CLAVE_LECTURA" >/dev/null 2>&1 || true
mc admin policy attach local lakehouse_lectura --user "$USUARIO_LECTURA" >/dev/null 2>&1 || true

echo "Usuario de solo lectura configurado: ${USUARIO_LECTURA}"

# ============================================================
# 2.b Usuario del transformador: lectura Y escritura, pero acotado
#
# DuckDB no puede usar el usuario de solo lectura: publica la capa Silver
# y los archivos de calidad con COPY ... TO 's3://...'. Necesita escribir.
#
# Lo que si se puede quitarle son las operaciones administrativas y el
# acceso a cualquier otro bucket. La diferencia contra usar las
# credenciales root es concreta: con este usuario no se pueden crear
# buckets, ni gestionar usuarios y politicas, ni tocar nada fuera de
# lakehouse.
# ============================================================

cat > /tmp/lakehouse_transformador.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::lakehouse"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::lakehouse/*"]
    }
  ]
}
JSON

mc admin policy create local lakehouse_transformador /tmp/lakehouse_transformador.json >/dev/null 2>&1 \
    || { mc admin policy remove local lakehouse_transformador >/dev/null 2>&1; \
         mc admin policy create local lakehouse_transformador /tmp/lakehouse_transformador.json >/dev/null; }

mc admin user add local "$USUARIO_TRANSFORMADOR" "$CLAVE_TRANSFORMADOR" >/dev/null 2>&1 || true
mc admin policy attach local lakehouse_transformador --user "$USUARIO_TRANSFORMADOR" >/dev/null 2>&1 || true

echo "Usuario del transformador configurado: ${USUARIO_TRANSFORMADOR}"

# ============================================================
# 3. Verificacion
#
# Dos comprobaciones, y la segunda es la que importa: el intento de
# escritura TIENE que fallar. Una politica que nunca se prueba es una
# politica que nadie sabe si funciona.
# ============================================================

mc alias set lectura http://minio-lake:9000 "$USUARIO_LECTURA" "$CLAVE_LECTURA" >/dev/null

objetos="$(mc ls --recursive lectura/lakehouse/ 2>/dev/null | wc -l | tr -d ' ')"
if [ "$objetos" -eq 0 ]; then
    echo "El usuario de lectura no puede listar el lakehouse; revisar la politica." >&2
    exit 1
fi
echo "  Lectura verificada: ${objetos} objetos visibles."

echo "prueba de escritura" > /tmp/prueba_escritura.txt
if mc cp /tmp/prueba_escritura.txt lectura/lakehouse/prueba_escritura.txt >/dev/null 2>&1; then
    echo "FALLO DE SEGURIDAD: el usuario de solo lectura pudo escribir en el lakehouse." >&2
    mc rm lectura/lakehouse/prueba_escritura.txt >/dev/null 2>&1 || true
    exit 1
fi
echo "  Escritura correctamente denegada."

# El transformador SI tiene que poder escribir en el bucket...
mc alias set transformador http://minio-lake:9000 \
    "$USUARIO_TRANSFORMADOR" "$CLAVE_TRANSFORMADOR" >/dev/null

echo "prueba de escritura" > /tmp/prueba_escritura.txt
if ! mc cp /tmp/prueba_escritura.txt transformador/lakehouse/_prueba_transformador.txt >/dev/null 2>&1; then
    echo "El transformador no puede escribir en el lakehouse; revisar la politica." >&2
    exit 1
fi
mc rm transformador/lakehouse/_prueba_transformador.txt >/dev/null 2>&1 || true
echo "  Escritura del transformador verificada."

# ...y NO tiene que poder crear buckets ni administrar el servidor.
if mc mb transformador/bucket-intruso >/dev/null 2>&1; then
    echo "FALLO DE SEGURIDAD: el transformador pudo crear un bucket." >&2
    mc rb --force transformador/bucket-intruso >/dev/null 2>&1 || true
    exit 1
fi
echo "  Creacion de buckets correctamente denegada."

rm -f /tmp/prueba_escritura.txt /tmp/lakehouse_lectura.json /tmp/lakehouse_transformador.json

echo "MinIO configurado y verificado."
