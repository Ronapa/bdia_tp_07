#!/bin/sh
# Objetivo: publicar en MinIO la capa Bronze del lakehouse, particionada por lote.
# Requiere / entradas: data/generado/bronze/ ya escrito por orquestador/exportar_bronze.py.
# Produce / modifica: objetos en s3://lakehouse/bronze/lote=<nombre>/; no toca Silver ni Gold.
# Resultado esperado: cada lote publicado o declarado sin cambios, con su cantidad de objetos.
# Guia: Bronze es inmutable dentro de una version del dataset; cambia solo si cambia el manifiesto.
set -eu

origen="/data/practica/generado/bronze"

if [ ! -d "$origen" ]; then
    echo "No se encontro $origen. Correr primero orquestador/exportar_bronze.py" >&2
    exit 1
fi

mc alias set local http://minio-lake:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
mc mb --ignore-existing local/lakehouse >/dev/null

for ruta_lote in "$origen"/lote=*; do
    [ -d "$ruta_lote" ] || continue
    lote="$(basename "$ruta_lote")"
    destino="local/lakehouse/bronze/${lote}"

    if [ ! -f "$ruta_lote/_manifiesto.json" ]; then
        echo "El lote ${lote} no tiene _manifiesto.json. Regenerar con exportar_bronze.py" >&2
        exit 1
    fi

    # La imagen minio/mc no trae `find`: se cuentan los archivos con un
    # glob de shell, que es POSIX y esta siempre disponible.
    set -- "$ruta_lote"/*
    esperados=$#

    # Inmutabilidad con control de version.
    #
    # Si el manifiesto publicado es identico al local, el lote ya esta y no
    # se toca: Bronze no se reescribe. Si difiere, cambio la version del
    # dataset (otra semilla u otra escala) y hay que reemplazarlo entero;
    # dejarlo como estaba haria que las capas Silver y Gold se construyeran
    # sobre datos de otra corrida.
    manifiesto_local="$(cat "$ruta_lote/_manifiesto.json")"
    manifiesto_remoto="$(mc cat "$destino/_manifiesto.json" 2>/dev/null || echo '')"

    if [ "$manifiesto_local" = "$manifiesto_remoto" ]; then
        echo "Bronze: ${lote} ya publicado con el mismo manifiesto; no se modifica."
        continue
    fi

    if [ -n "$manifiesto_remoto" ]; then
        echo "Bronze: ${lote} cambio de version del dataset; se reemplaza."
        mc rm --recursive --force "$destino/" >/dev/null 2>&1 || true
    fi

    mc cp --recursive "$ruta_lote/" "$destino/" >/dev/null
    cargados="$(mc ls "$destino/" | wc -l | tr -d ' ')"
    [ "$cargados" = "$esperados" ] || {
        echo "Se esperaban ${esperados} objetos en ${lote} y se cargaron ${cargados}" >&2
        exit 1
    }
    echo "Bronze: ${lote} publicado (${cargados} objetos)."
done

echo "Bronze publicado."
