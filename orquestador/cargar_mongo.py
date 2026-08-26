#!/usr/bin/env python3
"""Carga masiva del clickstream y la telemetria en MongoDB.

Por que un script de Python y no mongosh:

    El clickstream son cientos de miles de documentos. mongosh los
    cargaria haciendo JSON.parse de un archivo entero en memoria y
    llamando a insertMany desde el interprete de JavaScript. El driver
    de Python inserta por lotes, con `ordered=False`, y usa una
    fraccion de la memoria.

    El reparto de tareas es deliberado: mongosh define y verifica el
    MODELO (colecciones, validadores, timeseries) porque es donde se
    lee mejor; el driver mueve el VOLUMEN.

Uso:
    python cargar_mongo.py
    python cargar_mongo.py --lote 5000

Variables de entorno:
    MONGO_HOST, MONGO_PORT, MONGO_DATABASE
    MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD
"""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime
from pathlib import Path

from pymongo import MongoClient


def conectar_mongo():
    usuario = os.environ.get("MONGO_INITDB_ROOT_USERNAME", "bdia_admin")
    clave = os.environ.get("MONGO_INITDB_ROOT_PASSWORD", "")
    host = os.environ.get("MONGO_HOST", "localhost")
    puerto = os.environ.get("MONGO_PORT", "27017")
    uri = f"mongodb://{usuario}:{clave}@{host}:{puerto}/?authSource=admin"
    return MongoClient(uri)


def leer_json(ruta: Path) -> list[dict]:
    if not ruta.exists():
        raise SystemExit(f"No se encontro {ruta}. Correr primero orquestador/generar_datos.py")
    with ruta.open(encoding="utf-8") as archivo:
        return json.load(archivo)


def a_fecha(texto: str) -> datetime:
    return datetime.fromisoformat(texto)


def insertar_por_lotes(coleccion, documentos: list[dict], tamano_lote: int) -> int:
    """Inserta en lotes con ordered=False.

    ordered=False permite que MongoDB siga insertando el resto del lote
    aunque un documento sea rechazado por el validador, en vez de cortar
    en el primer error. Para una carga de telemetria eso es lo correcto:
    un evento malformado no debe frenar los otros 4.999.
    """
    total = 0
    for inicio in range(0, len(documentos), tamano_lote):
        lote = documentos[inicio:inicio + tamano_lote]
        coleccion.insert_many(lote, ordered=False)
        total += len(lote)
        print(f"  {total}/{len(documentos)} documentos insertados...")
    return total


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--origen", type=Path, default=Path("/workspace/data/generado"),
                        help="Directorio con los JSON generados.")
    parser.add_argument("--lote", type=int, default=5000,
                        help="Cantidad de documentos por lote de insercion.")
    argumentos = parser.parse_args()

    origen = argumentos.origen / "mongo"
    resumen = json.loads((argumentos.origen / "resumen.json").read_text(encoding="utf-8"))

    cliente = conectar_mongo()
    base = cliente[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")]

    if "eventos_interaccion" not in base.list_collection_names():
        raise SystemExit(
            "Falta la coleccion eventos_interaccion. "
            "Correr primero nosql/mongodb/00_cargar_datos.js"
        )

    print("--- Cargando clickstream ---")
    eventos = leer_json(origen / "eventos_interaccion.json")
    for evento in eventos:
        evento["ocurrido_en"] = a_fecha(evento["ocurrido_en"])
    base.eventos_interaccion.delete_many({})
    cargados_eventos = insertar_por_lotes(base.eventos_interaccion, eventos, argumentos.lote)

    print("--- Cargando telemetria de reproduccion (timeseries) ---")
    telemetria = leer_json(origen / "telemetria_reproduccion.json")
    for medicion in telemetria:
        medicion["ocurrido_en"] = a_fecha(medicion["ocurrido_en"])
    # Una coleccion timeseries no admite delete_many selectivo eficiente;
    # se vacia recreandola solo si ya tenia datos de una corrida previa.
    if base.telemetria_reproduccion.estimated_document_count() > 0:
        opciones = base.get_collection("telemetria_reproduccion").options()
        base.drop_collection("telemetria_reproduccion")
        base.create_collection("telemetria_reproduccion", **opciones)
    cargados_telemetria = insertar_por_lotes(
        base.telemetria_reproduccion, telemetria, argumentos.lote
    )

    esperados = {
        "eventos_interaccion": resumen["conteos"]["eventos_interaccion"],
        "telemetria_reproduccion": resumen["conteos"]["telemetria_reproduccion"],
    }
    reales = {
        "eventos_interaccion": cargados_eventos,
        "telemetria_reproduccion": cargados_telemetria,
    }

    for coleccion, esperado in esperados.items():
        if reales[coleccion] != esperado:
            raise SystemExit(
                f"{coleccion}: se esperaban {esperado} documentos y se cargaron "
                f"{reales[coleccion]}"
            )
        print(f"  {coleccion:28s} {reales[coleccion]:>8d}")

    cliente.close()
    print("\nClickstream y telemetria cargados y verificados.")


if __name__ == "__main__":
    main()
