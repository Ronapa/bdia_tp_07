#!/usr/bin/env python3
"""Consume el stream de ingesta de Redis y persiste los eventos en MongoDB.

Resuelve el tramo `Redis Stream -> MongoDB` del diagrama de arquitectura.

Conviven dos caminos de carga, y responden a cosas distintas:

    cargar_mongo.py    carga por lote el historico del dataset sintetico.
    consumir_stream.py es el camino de la ingesta EN VIVO: la aplicacion
                       escribe en el stream y este proceso lo drena.

Por que un stream y no una lista:

    Un STREAM da tres cosas que una lista (LPUSH/RPOP) no da:
    orden garantizado, grupos de consumo -que permiten repartir el
    trabajo entre varios procesos sin duplicar- y confirmacion explicita
    con XACK. Si el consumidor se cae despues de leer y antes de
    confirmar, el mensaje queda PENDIENTE y otro consumidor lo reclama
    con XCLAIM. Con RPOP, ese evento se habria perdido.

Este script escribe en MongoDB con el usuario **bdia_mongo_ingesta**, que
solo puede insertar en eventos_interaccion: no puede leer, ni modificar,
ni borrar. Si el proceso quedara comprometido, no serviria para
exfiltrar el historial de nadie.

Uso:
    python consumir_stream.py --simular 50      # produce y consume 50 eventos
    python consumir_stream.py                   # solo drena lo que haya
    python consumir_stream.py --reclamar        # ademas recupera lo pendiente

La escritura es IDEMPOTENTE: reejecutar con --simular no duplica eventos,
porque cada uno se escribe con upsert sobre evento_id, que tiene indice
unico. Es lo que convierte la entrega "al menos una vez" del stream en
"exactamente una vez" sobre el estado persistido.

Variables de entorno:
    REDIS_HOST, REDIS_PORT, REDIS_PASSWORD
    MONGO_HOST, MONGO_PORT, MONGO_DATABASE
    MONGO_INGESTA_USER, MONGO_INGESTA_PASSWORD
"""
from __future__ import annotations

import argparse
import os
import random
from datetime import datetime, timedelta, timezone

import redis
from pymongo import MongoClient, ReplaceOne

CLAVE_STREAM = "cola:eventos"
GRUPO = "ingestores"

TIPOS_EVENTO = ["vista", "scroll", "clic", "guardado", "compartido", "me_gusta"]
DISPOSITIVOS = ["movil", "escritorio", "tablet"]
CANALES = ["directo", "buscador", "redes"]


def conectar_redis():
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "localhost"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD") or None,
        decode_responses=True,
    )


def conectar_mongo_ingesta():
    """Conecta con el usuario de ingesta, no con root.

    El usuario lo crea nosql/mongodb/02_usuarios_y_permisos.js y solo
    tiene la accion `insert` sobre eventos_interaccion.
    """
    usuario = os.environ.get("MONGO_INGESTA_USER", "bdia_mongo_ingesta")
    clave = os.environ.get("MONGO_INGESTA_PASSWORD", "ingesta_local")
    host = os.environ.get("MONGO_HOST", "localhost")
    puerto = os.environ.get("MONGO_PORT", "27017")
    base = os.environ.get("MONGO_DATABASE", "bdia_nexomedia")
    return MongoClient(
        f"mongodb://{usuario}:{clave}@{host}:{puerto}/?authSource={base}"
    )


def asegurar_grupo(cliente: redis.Redis) -> None:
    """Crea el stream y su grupo de consumo si no existen."""
    try:
        cliente.xgroup_create(CLAVE_STREAM, GRUPO, id="0", mkstream=True)
        print(f"  Grupo de consumo creado: {GRUPO}")
    except redis.ResponseError as error:
        if "BUSYGROUP" not in str(error):
            raise


def producir(cliente: redis.Redis, cantidad: int, semilla: int) -> int:
    """Simula la escritura de la aplicacion web.

    En el sistema real, esto lo haria el front al registrar cada
    interaccion. Aca se genera para poder demostrar el ciclo completo.

    MAXLEN aproximado acota la memoria del stream: el dato definitivo
    vive en MongoDB, asi que el stream es un buffer, no un archivo.
    """
    rng = random.Random(semilla)
    ahora = datetime.now(timezone.utc)

    for indice in range(cantidad):
        momento = ahora - timedelta(seconds=rng.randint(0, 600))
        cliente.xadd(
            CLAVE_STREAM,
            {
                "evento_id": f"EV-STREAM-{indice + 1:06d}",
                "usuario_id": rng.randint(1, 200),
                "contenido_id": rng.randint(1, 400),
                "tipo_evento": rng.choice(TIPOS_EVENTO),
                "ocurrido_en": momento.isoformat(),
                "dispositivo": rng.choice(DISPOSITIVOS),
                "canal": rng.choice(CANALES),
                "pais": "AR",
                "superficie": "home",
            },
            maxlen=10000,
            approximate=True,
        )
    return cantidad


def a_documento(campos: dict) -> dict:
    """Traduce la entrada plana del stream al documento de MongoDB.

    El stream guarda pares clave-valor planos (Redis no anida); la
    coleccion espera el subdocumento `contexto`. La traduccion se hace
    aca, en el borde, para que el documento almacenado respete el mismo
    validador $jsonSchema que el resto del clickstream.
    """
    return {
        "evento_id": campos["evento_id"],
        "usuario_id": int(campos["usuario_id"]),
        "sesion_id": f"S-{int(campos['usuario_id']):06d}-stream",
        "contenido_id": int(campos["contenido_id"]),
        "tipo_evento": campos["tipo_evento"],
        "ocurrido_en": datetime.fromisoformat(campos["ocurrido_en"]),
        "contexto": {
            "dispositivo": campos.get("dispositivo", "desconocido"),
            "canal": campos.get("canal", "directo"),
            "pais": campos.get("pais", "AR"),
            "superficie": campos.get("superficie", "home"),
        },
    }


def persistir(coleccion, entradas: list) -> tuple[int, int]:
    """Escribe un lote en MongoDB de forma IDEMPOTENTE y devuelve los ids a confirmar.

    Usa ReplaceOne con upsert sobre evento_id en lugar de insert_many.
    La diferencia importa:

        insert_many  -> un reintento choca con el indice unico y aborta
                        el lote entero; ademas hay que distinguir el error
                        "duplicado" (esperado) de cualquier otro (grave).
        ReplaceOne   -> reprocesar el mismo evento deja exactamente el
                        mismo documento. El reintento es inofensivo.

    Es lo que convierte la garantia "al menos una vez" del stream en
    "exactamente una vez" sobre el estado persistido, que es lo unico que
    de verdad importa: los eventos repetidos no inflan las metricas.
    """
    operaciones = []
    confirmables = []
    descartados = 0

    for identificador, campos in entradas:
        # El mensaje de arranque que deja publicar_serving.py no es un
        # evento: se confirma y se descarta.
        if "evento_id" not in campos:
            confirmables.append(identificador)
            descartados += 1
            continue
        documento = a_documento(campos)
        operaciones.append(
            ReplaceOne({"evento_id": documento["evento_id"]}, documento, upsert=True)
        )
        confirmables.append(identificador)

    if operaciones:
        coleccion.bulk_write(operaciones, ordered=False)

    return confirmables, descartados


def consumir(cliente: redis.Redis, coleccion, consumidor: str,
             tamano_lote: int) -> tuple[int, int]:
    """Drena el stream: lee, persiste y confirma.

    El orden importa y no es negociable: primero se escribe en MongoDB,
    despues se confirma con XACK. Al reves, un fallo entre las dos
    operaciones perderia el evento sin dejar rastro.

    Asi, en el peor caso el evento se procesa dos veces, y como la
    escritura es idempotente (ver persistir), eso no tiene consecuencias.
    Perder eventos sesga las metricas; repetirlos, con upsert, no.
    """
    procesados = 0
    descartados = 0

    while True:
        respuesta = cliente.xreadgroup(
            GRUPO, consumidor, {CLAVE_STREAM: ">"}, count=tamano_lote, block=1000
        )
        if not respuesta:
            break

        for _, entradas in respuesta:
            confirmables, sin_evento = persistir(coleccion, entradas)
            procesados += len(confirmables) - sin_evento
            descartados += sin_evento

            # XACK recien despues de que MongoDB confirmo la escritura.
            if confirmables:
                cliente.xack(CLAVE_STREAM, GRUPO, *confirmables)

            print(f"  {procesados} eventos persistidos y confirmados...")

    return procesados, descartados


def reclamar_pendientes(cliente: redis.Redis, coleccion, consumidor: str,
                        inactividad_ms: int) -> int:
    """Recupera, PROCESA y confirma los mensajes que otro consumidor abandono.

    Es lo que hace tolerante a fallas al grupo de consumo: si un
    consumidor muere entre el XREADGROUP y el XACK, sus mensajes quedan en
    la lista de pendientes con su nombre. XAUTOCLAIM se los transfiere a
    otro consumidor pasado un tiempo de inactividad.

    Reclamar no alcanza: hay que persistir y confirmar. Una version
    anterior de esta funcion solo contaba los mensajes reclamados y no
    hacia nada con ellos, con lo cual quedaban pendientes para siempre,
    ahora a nombre de este consumidor. El sintoma era silencioso: el
    proceso terminaba diciendo que habia reclamado N mensajes y esos N
    eventos nunca llegaban a MongoDB.
    """
    reclamados = 0
    cursor = "0-0"

    while True:
        cursor, entradas, _ = cliente.xautoclaim(
            CLAVE_STREAM, GRUPO, consumidor,
            min_idle_time=inactividad_ms, start_id=cursor, count=100,
        )
        if not entradas:
            break

        confirmables, _ = persistir(coleccion, entradas)
        if confirmables:
            cliente.xack(CLAVE_STREAM, GRUPO, *confirmables)
        reclamados += len(entradas)

        if cursor == "0-0":
            break

    if reclamados:
        print(f"  {reclamados} mensajes reclamados, persistidos y confirmados")
    return reclamados


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--simular", type=int, default=0,
                        help="Cantidad de eventos a producir antes de consumir.")
    parser.add_argument("--lote", type=int, default=100,
                        help="Mensajes por lectura del grupo de consumo.")
    parser.add_argument("--consumidor", default="consumidor-1",
                        help="Nombre de este consumidor dentro del grupo.")
    parser.add_argument("--semilla", type=int, default=int(os.environ.get("SEMILLA", "42")),
                        help="Semilla del simulador de eventos.")
    parser.add_argument("--reclamar", action="store_true",
                        help="Reclama, procesa y confirma los pendientes de consumidores caidos.")
    parser.add_argument("--inactividad-ms", type=int, default=60000,
                        help="Milisegundos sin confirmar tras los que un mensaje se puede reclamar.")
    argumentos = parser.parse_args()

    cliente = conectar_redis()
    try:
        cliente.ping()
    except redis.RedisError as error:
        raise SystemExit(f"No se pudo conectar a Redis: {error}")

    cliente_mongo = conectar_mongo_ingesta()
    coleccion = cliente_mongo[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")] \
        .eventos_interaccion

    try:
        asegurar_grupo(cliente)

        pendientes_antes = cliente.xpending(CLAVE_STREAM, GRUPO)["pending"]
        print(f"--- Estado inicial: {cliente.xlen(CLAVE_STREAM)} entradas en el stream, "
              f"{pendientes_antes} pendientes ---")

        if argumentos.simular > 0:
            print(f"--- Simulando {argumentos.simular} eventos de la aplicacion ---")
            producir(cliente, argumentos.simular, argumentos.semilla)

        if argumentos.reclamar:
            reclamar_pendientes(cliente, coleccion, argumentos.consumidor,
                                argumentos.inactividad_ms)

        print("--- Consumiendo ---")
        procesados, descartados = consumir(
            cliente, coleccion, argumentos.consumidor, argumentos.lote
        )

        pendientes_despues = cliente.xpending(CLAVE_STREAM, GRUPO)["pending"]

        print("")
        print(f"Eventos persistidos en MongoDB : {procesados}")
        print(f"Entradas de control descartadas: {descartados}")
        print(f"Pendientes sin confirmar       : {pendientes_despues}")

        # Un pendiente que sobrevive al drenaje es un evento que se leyo y
        # no se pudo escribir. No es un detalle: es perdida de datos.
        if pendientes_despues > 0:
            raise SystemExit(
                f"Quedaron {pendientes_despues} mensajes sin confirmar. "
                "Reejecutar con --reclamar para recuperarlos."
            )

    finally:
        cliente_mongo.close()

    print("\nStream drenado y confirmado.")


if __name__ == "__main__":
    main()
