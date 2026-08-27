#!/usr/bin/env python3
"""Exporta la capa Bronze del lakehouse a partir de los sistemas operacionales.

Bronze es el dato crudo tal como llega: sin tipar, sin limpiar y sin
corregir. DuckDB lo lee schema-on-read en la capa Silver.

Dos decisiones de diseño que se ven en el codigo:

1. MINIMIZACION DE DATOS.
   Ningun identificador directo de persona sale hacia el lake. Los
   eventos y las impresiones se exportan con el SEUDONIMO que produce
   personas.seudonimo(), no con usuario_id. La capa analitica puede
   contar usuarios unicos, armar cohortes y calcular co-ocurrencia sin
   poder reidentificar a nadie: el dato sensible no llega, no es que
   este prohibido mirarlo.

2. DOS LOTES, UNO SUCIO A PROPOSITO.
   lote_01_historico sale limpio; lote_02_reciente lleva errores
   inyectados (fechas invalidas, claves inexistentes, valores fuera de
   rango, coma decimal, booleanos en espanol). Sin datos sucios, la capa
   Silver no tendria nada que demostrar y la tabla de rechazos estaria
   siempre vacia.

Uso:
    python exportar_bronze.py
    python exportar_bronze.py --sin-errores

Variables de entorno:
    POSTGRES_*, MONGO_*
"""
from __future__ import annotations

import argparse
import csv
import json
import os
import shutil
from datetime import datetime, timezone
from pathlib import Path

import psycopg2
from pymongo import MongoClient

FECHA_CORTE_LOTES = datetime(2026, 7, 1, tzinfo=timezone.utc)

COLUMNAS_EVENTOS = [
    "evento_id", "usuario_seudonimo", "sesion_id", "contenido_id", "tipo_evento",
    "ocurrido_en", "dispositivo", "canal", "pais", "superficie",
    "segundos_visibles", "porcentaje_scroll", "segundos_reproducidos",
    "porcentaje_reproducido", "estrategia_origen", "posicion_origen", "variante_ab",
]

COLUMNAS_IMPRESIONES = [
    "usuario_seudonimo", "contenido_id", "estrategia_codigo", "posicion", "score",
    "variante_ab", "superficie", "mostrado_en", "clic", "clic_en",
]


def conectar_bd():
    return psycopg2.connect(
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        dbname=os.environ.get("POSTGRES_DB", "bdia_nexomedia"),
        user=os.environ.get("POSTGRES_USER", "bdia_user"),
        password=os.environ.get("POSTGRES_PASSWORD", ""),
    )


def conectar_mongo():
    usuario = os.environ.get("MONGO_INITDB_ROOT_USERNAME", "bdia_admin")
    clave = os.environ.get("MONGO_INITDB_ROOT_PASSWORD", "")
    host = os.environ.get("MONGO_HOST", "localhost")
    puerto = os.environ.get("MONGO_PORT", "27017")
    return MongoClient(f"mongodb://{usuario}:{clave}@{host}:{puerto}/?authSource=admin")


def escribir_csv(ruta: Path, columnas: list[str], filas: list[dict]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with ruta.open("w", encoding="utf-8", newline="") as archivo:
        escritor = csv.DictWriter(archivo, fieldnames=columnas,
                                  extrasaction="ignore", quoting=csv.QUOTE_ALL)
        escritor.writeheader()
        escritor.writerows(filas)
    print(f"  {str(ruta.relative_to(ruta.parents[2])):46s} {len(filas):>8d} filas")


def aplanar_evento(documento: dict, seudonimos: dict[int, str]) -> dict:
    contexto = documento.get("contexto", {})
    metricas = documento.get("metricas", {})
    origen = documento.get("origen_recomendacion", {})
    return {
        "evento_id": documento["evento_id"],
        "usuario_seudonimo": seudonimos.get(documento["usuario_id"], ""),
        "sesion_id": documento.get("sesion_id", ""),
        "contenido_id": documento["contenido_id"],
        "tipo_evento": documento["tipo_evento"],
        "ocurrido_en": documento["ocurrido_en"].isoformat(),
        "dispositivo": contexto.get("dispositivo", ""),
        "canal": contexto.get("canal", ""),
        "pais": contexto.get("pais", ""),
        "superficie": contexto.get("superficie", ""),
        "segundos_visibles": metricas.get("segundos_visibles", ""),
        "porcentaje_scroll": metricas.get("porcentaje_scroll", ""),
        "segundos_reproducidos": metricas.get("segundos_reproducidos", ""),
        "porcentaje_reproducido": metricas.get("porcentaje_reproducido", ""),
        "estrategia_origen": origen.get("estrategia", ""),
        "posicion_origen": origen.get("posicion", ""),
        "variante_ab": origen.get("variante_ab", ""),
    }


def inyectar_errores(eventos: list[dict]) -> list[dict]:
    """Agrega al lote reciente los defectos que la capa Silver debe atrapar.

    Cada fila corresponde a un codigo de error distinto del catalogo de
    analitico/02_procesar_silver.sql. Estan escritas a mano para que la
    correspondencia entre defecto y codigo sea evidente al leerlas.
    """
    if not eventos:
        return eventos

    plantilla = dict(eventos[0])
    sucios = []

    # CLAVE_DESCONOCIDA: seudonimo que no existe en la dimension de usuarios.
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-01", "usuario_seudonimo": "U-000000000000"})
    sucios.append(fila)

    # FECHA_INVALIDA: 31 de febrero.
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-02", "ocurrido_en": "31/02/2026 10:00:00"})
    sucios.append(fila)

    # DUPLICADO: repite el evento_id de la primera fila real del lote.
    fila = dict(plantilla)
    fila.update({"evento_id": eventos[0]["evento_id"]})
    sucios.append(fila)

    # FUERA_DE_RANGO: un scroll del 150%.
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-04", "tipo_evento": "scroll",
                 "porcentaje_scroll": "150.0"})
    sucios.append(fila)

    # TIPO_EVENTO_DESCONOCIDO: un tipo que la aplicacion nunca emite.
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-05", "tipo_evento": "pestaneo"})
    sucios.append(fila)

    # FALTA_OBLIGATORIO: sin contenido_id.
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-06", "contenido_id": ""})
    sucios.append(fila)

    # Estas dos NO son errores: son formatos sucios que la capa Silver
    # tiene que NORMALIZAR, no rechazar. Sirven para mostrar la diferencia
    # entre "dato mal escrito" y "dato invalido".
    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-07", "tipo_evento": "vista",
                 "segundos_visibles": "45,5", "ocurrido_en": "15/07/2026 18:30:00"})
    sucios.append(fila)

    fila = dict(plantilla)
    fila.update({"evento_id": "EV-SUCIO-08", "tipo_evento": "vista",
                 "porcentaje_scroll": "62,5", "dispositivo": "  MOVIL  "})
    sucios.append(fila)

    print(f"  Errores inyectados en el lote reciente: {len(sucios)}")
    return eventos + sucios


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--salida", type=Path,
                        default=Path("/workspace/data/generado/bronze"),
                        help="Directorio de la capa Bronze.")
    parser.add_argument("--sin-errores", action="store_true",
                        help="No inyecta datos sucios en el lote reciente.")
    argumentos = parser.parse_args()

    if argumentos.salida.exists():
        shutil.rmtree(argumentos.salida)

    conexion = conectar_bd()
    cur = conexion.cursor()
    cliente_mongo = conectar_mongo()
    base_mongo = cliente_mongo[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")]

    try:
        print("--- Resolviendo seudonimos (ningun usuario_id sale hacia el lake) ---")
        cur.execute("SELECT id, seudonimo FROM personas.usuarios;")
        seudonimos = dict(cur.fetchall())
        print(f"  {len(seudonimos)} usuarios seudonimizados")

        print("--- Exportando eventos desde MongoDB ---")
        eventos_historico, eventos_reciente = [], []
        for documento in base_mongo.eventos_interaccion.find({}, {"_id": 0}):
            fila = aplanar_evento(documento, seudonimos)
            if documento["ocurrido_en"].replace(tzinfo=timezone.utc) < FECHA_CORTE_LOTES:
                eventos_historico.append(fila)
            else:
                eventos_reciente.append(fila)

        if not argumentos.sin_errores:
            eventos_reciente = inyectar_errores(eventos_reciente)

        print("--- Exportando impresiones desde PostgreSQL ---")
        cur.execute(
            """
            SELECT
                u.seudonimo AS usuario_seudonimo,
                i.contenido_id, e.codigo AS estrategia_codigo, i.posicion, i.score,
                i.variante_ab, i.superficie, i.mostrado_en, i.clic, i.clic_en
            FROM recomendacion.impresiones AS i
            JOIN recomendacion.estrategias AS e
                ON e.id = i.estrategia_id
            JOIN personas.usuarios AS u
                ON u.id = i.usuario_id
            ORDER BY i.mostrado_en;
            """
        )
        impresiones_historico, impresiones_reciente = [], []
        for fila in cur.fetchall():
            registro = dict(zip(COLUMNAS_IMPRESIONES, fila))
            registro["mostrado_en"] = registro["mostrado_en"].isoformat()
            registro["clic_en"] = (registro["clic_en"].isoformat()
                                   if registro["clic_en"] else "")
            registro["clic"] = "true" if registro["clic"] else "false"
            if fila[7] < FECHA_CORTE_LOTES:
                impresiones_historico.append(registro)
            else:
                impresiones_reciente.append(registro)

        print("--- Exportando dimensiones desde PostgreSQL ---")
        cur.execute(
            """
            SELECT
                c.id AS contenido_id, c.titulo, tc.codigo AS tipo_contenido,
                s.nombre AS seccion, a.seccion_raiz, c.nivel_acceso, c.estado,
                c.fecha_publicacion
            FROM catalogo.contenidos AS c
            JOIN catalogo.tipos_contenido AS tc
                ON tc.id = c.tipo_contenido_id
            JOIN catalogo.secciones AS s
                ON s.id = c.seccion_id
            JOIN catalogo.vw_arbol_secciones AS a
                ON a.seccion_id = c.seccion_id
            ORDER BY c.id;
            """
        )
        columnas_contenidos = ["contenido_id", "titulo", "tipo_contenido", "seccion",
                               "seccion_raiz", "nivel_acceso", "estado", "fecha_publicacion"]
        contenidos = []
        for fila in cur.fetchall():
            registro = dict(zip(columnas_contenidos, fila))
            registro["fecha_publicacion"] = (registro["fecha_publicacion"].isoformat()
                                             if registro["fecha_publicacion"] else "")
            contenidos.append(registro)

        # La dimension de usuarios sale de la VISTA ANONIMIZADA, no de la
        # tabla. Es el mismo mecanismo que usa el analista, aplicado al
        # pipeline: el lake no recibe un solo correo ni una sola edad exacta.
        cur.execute(
            """
            SELECT seudonimo, pais, tramo_etario, plan, mes_alta
            FROM personas.vw_usuarios_anonimizado
            ORDER BY seudonimo;
            """
        )
        columnas_usuarios = ["seudonimo", "pais", "tramo_etario", "plan", "mes_alta"]
        usuarios = [dict(zip(columnas_usuarios,
                             [f[0], f[1], f[2], f[3], f[4].isoformat()]))
                    for f in cur.fetchall()]

        cur.execute("SELECT id, codigo, version, motor FROM recomendacion.estrategias;")
        estrategias = [
            {"estrategia_id": f[0], "codigo": f[1], "version": f[2], "motor": f[3]}
            for f in cur.fetchall()
        ]

        print("\n--- Escribiendo la capa Bronze ---")
        resumen = json.loads(
            (argumentos.salida.parent / "resumen.json").read_text(encoding="utf-8")
        )
        lotes = {
            "lote_01_historico": (eventos_historico, impresiones_historico),
            "lote_02_reciente": (eventos_reciente, impresiones_reciente),
        }
        for nombre, (eventos, impresiones) in lotes.items():
            destino = argumentos.salida / f"lote={nombre}"
            escribir_csv(destino / "eventos.csv", COLUMNAS_EVENTOS, eventos)
            escribir_csv(destino / "impresiones.csv", COLUMNAS_IMPRESIONES, impresiones)
            escribir_csv(destino / "contenidos.csv", columnas_contenidos, contenidos)
            escribir_csv(destino / "usuarios.csv", columnas_usuarios, usuarios)
            escribir_csv(destino / "estrategias.csv",
                         ["estrategia_id", "codigo", "version", "motor"], estrategias)

            # Manifiesto del lote.
            #
            # Bronze es inmutable DENTRO de una version del dataset: una vez
            # publicado, no se pisa. Pero al regenerar el dataset con otra
            # semilla o escala, el contenido del lote cambia aunque el nombre
            # sea el mismo, y el lake quedaria con datos viejos sin que nada
            # lo denuncie: una corrida a escala media terminaria construyendo
            # la capa Gold con el Bronze de otra corrida a escala chica.
            #
            # El manifiesto resuelve las dos cosas a la vez: scripts/cargar_bronze.sh
            # lo compara contra el publicado, y solo reescribe el lote si
            # cambio la version del dataset.
            manifiesto = {
                "lote": nombre,
                "semilla": resumen["semilla"],
                "escala": resumen["escala"],
                "archivos": {
                    "eventos.csv": len(eventos),
                    "impresiones.csv": len(impresiones),
                    "contenidos.csv": len(contenidos),
                    "usuarios.csv": len(usuarios),
                    "estrategias.csv": len(estrategias),
                },
            }
            (destino / "_manifiesto.json").write_text(
                json.dumps(manifiesto, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
            )

    finally:
        cur.close()
        conexion.close()
        cliente_mongo.close()

    print("\nCapa Bronze lista.")
    print("Siguiente paso: scripts/cargar_bronze.sh (publica los objetos en MinIO)")


if __name__ == "__main__":
    main()
