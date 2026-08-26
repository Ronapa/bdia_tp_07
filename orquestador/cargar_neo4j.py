#!/usr/bin/env python3
"""Construye el grafo de recomendacion en Neo4j.

Toma los nodos del catalogo desde PostgreSQL (que es el sistema de
registro) y las aristas de comportamiento desde MongoDB (que es donde
vive el clickstream). El grafo es, por definicion, una vista derivada:
se reconstruye entero en cada corrida y nunca es la fuente de verdad
de nada.

Esa decision es lo que permite desnormalizar sin miedo. El nodo
:Contenido lleva copiados el titulo, la seccion, el estado y el nivel de
acceso; si fueran datos maestros, mantenerlos sincronizados seria un
problema. Como son una proyeccion regenerable, no lo es.

Uso:
    python cargar_neo4j.py
    python cargar_neo4j.py --min-vistas 2 --lote 5000

Variables de entorno:
    NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD
    POSTGRES_*, MONGO_*
"""
from __future__ import annotations

import argparse
import os
from collections import defaultdict

import psycopg2
from neo4j import GraphDatabase
from pymongo import MongoClient

# Eventos que se consideran "consumo" para armar la arista VIO.
EVENTOS_CONSUMO = {"vista", "completado", "reproduccion", "scroll"}
EVENTOS_GUARDADO = {"guardado", "compartido", "me_gusta"}


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


def conectar_grafo():
    return GraphDatabase.driver(
        os.environ.get("NEO4J_URI", "bolt://localhost:7687"),
        auth=(os.environ.get("NEO4J_USER", "neo4j"),
              os.environ.get("NEO4J_PASSWORD", "")),
    )


def ejecutar_por_lotes(sesion, consulta: str, filas: list[dict], tamano: int,
                       etiqueta: str) -> int:
    """Envia las filas con UNWIND por lotes.

    UNWIND + un solo MERGE por lote es el patron de carga masiva de
    Cypher: una transaccion por fila seria dos ordenes de magnitud mas
    lento porque cada una paga su propio commit.
    """
    total = 0
    for inicio in range(0, len(filas), tamano):
        lote = filas[inicio:inicio + tamano]
        sesion.run(consulta, filas=lote)
        total += len(lote)
        print(f"  {etiqueta}: {total}/{len(filas)}")
    return total


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--lote", type=int, default=5000,
                        help="Filas por transaccion de carga.")
    parser.add_argument("--min-vistas", type=int, default=1,
                        help="Vistas minimas para crear la arista VIO.")
    argumentos = parser.parse_args()

    conexion = conectar_bd()
    cur = conexion.cursor()
    cliente_mongo = conectar_mongo()
    base_mongo = cliente_mongo[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")]
    driver = conectar_grafo()

    try:
        # ---------- Nodos del catalogo, desde PostgreSQL ----------
        cur.execute(
            """
            SELECT
                c.id, c.titulo, s.nombre AS seccion, a.seccion_raiz,
                tc.codigo AS tipo, c.nivel_acceso, c.estado,
                c.fecha_publicacion, c.autor_id
            FROM catalogo.contenidos AS c
            JOIN catalogo.secciones AS s
                ON s.id = c.seccion_id
            JOIN catalogo.vw_arbol_secciones AS a
                ON a.seccion_id = c.seccion_id
            JOIN catalogo.tipos_contenido AS tc
                ON tc.id = c.tipo_contenido_id
            ORDER BY c.id;
            """
        )
        contenidos = [
            {
                "contenido_id": f[0], "titulo": f[1], "seccion": f[2], "seccion_raiz": f[3],
                "tipo": f[4], "nivel_acceso": f[5], "estado": f[6],
                "fecha_publicacion": f[7].isoformat() if f[7] else None, "autor_id": f[8],
            }
            for f in cur.fetchall()
        ]

        cur.execute(
            """
            SELECT u.id, u.pais, COALESCE(p.codigo, 'gratuito') AS plan
            FROM personas.usuarios AS u
            LEFT JOIN personas.suscripciones AS s
                ON s.usuario_id = u.id AND s.estado = 'activa'
            LEFT JOIN personas.planes AS p
                ON p.id = s.plan_id
            ORDER BY u.id;
            """
        )
        usuarios = [{"usuario_id": f[0], "pais": f[1], "plan": f[2]} for f in cur.fetchall()]

        cur.execute("SELECT slug, nombre, seccion_raiz FROM catalogo.vw_arbol_secciones;")
        secciones = [{"slug": f[0], "nombre": f[1], "raiz": f[2]} for f in cur.fetchall()]

        cur.execute("SELECT slug, nombre FROM catalogo.etiquetas;")
        etiquetas = [{"slug": f[0], "nombre": f[1]} for f in cur.fetchall()]

        cur.execute(
            """
            SELECT ce.contenido_id, e.slug, ce.relevancia
            FROM catalogo.contenidos_etiquetas AS ce
            JOIN catalogo.etiquetas AS e
                ON e.id = ce.etiqueta_id;
            """
        )
        contenido_etiqueta = [
            {"contenido_id": f[0], "slug": f[1], "relevancia": float(f[2])}
            for f in cur.fetchall()
        ]

        cur.execute(
            """
            SELECT c.id, s.slug
            FROM catalogo.contenidos AS c
            JOIN catalogo.secciones AS s
                ON s.id = c.seccion_id;
            """
        )
        contenido_seccion = [{"contenido_id": f[0], "slug": f[1]} for f in cur.fetchall()]

        cur.execute(
            """
            SELECT p.usuario_id, s.slug, p.tipo_preferencia
            FROM personas.preferencias_usuario AS p
            JOIN catalogo.secciones AS s
                ON s.id = p.seccion_id
            WHERE p.seccion_id IS NOT NULL;
            """
        )
        preferencias = [
            {"usuario_id": f[0], "slug": f[1], "tipo": f[2]} for f in cur.fetchall()
        ]

        cur.execute(
            """
            SELECT contenido_id, contenido_similar_id, score
            FROM recomendacion.ranking_items_similares
            WHERE origen = 'embedding';
            """
        )
        similares = [
            {"origen_id": f[0], "destino_id": f[1], "score": float(f[2])}
            for f in cur.fetchall()
        ]

        # ---------- Aristas de comportamiento, desde MongoDB ----------
        print("--- Agregando el clickstream en aristas ---")
        vistas: dict[tuple[int, int], dict] = defaultdict(
            lambda: {"veces": 0, "completo": False, "ultima_vez": None}
        )
        guardados: set[tuple[int, int]] = set()

        cursor = base_mongo.eventos_interaccion.find(
            {"tipo_evento": {"$in": sorted(EVENTOS_CONSUMO | EVENTOS_GUARDADO)}},
            {"usuario_id": 1, "contenido_id": 1, "tipo_evento": 1, "ocurrido_en": 1, "_id": 0},
        )
        for evento in cursor:
            clave = (evento["usuario_id"], evento["contenido_id"])
            if evento["tipo_evento"] in EVENTOS_GUARDADO:
                guardados.add(clave)
                continue
            registro = vistas[clave]
            registro["veces"] += 1
            if evento["tipo_evento"] == "completado":
                registro["completo"] = True
            momento = evento["ocurrido_en"].isoformat()
            if registro["ultima_vez"] is None or momento > registro["ultima_vez"]:
                registro["ultima_vez"] = momento

        aristas_vio = [
            {
                "usuario_id": usuario, "contenido_id": contenido,
                "veces": datos["veces"], "completo": datos["completo"],
                "ultima_vez": datos["ultima_vez"],
            }
            for (usuario, contenido), datos in vistas.items()
            if datos["veces"] >= argumentos.min_vistas
        ]
        aristas_guardo = [
            {"usuario_id": u, "contenido_id": c} for (u, c) in sorted(guardados)
        ]

        # ---------- Carga ----------
        with driver.session() as sesion:
            print("--- Reconstruyendo el grafo ---")
            # El grafo es una proyeccion: se borra entero y se rehace.
            # CALL {} IN TRANSACTIONS evita cargar todo el borrado en una
            # sola transaccion, que con volumen alto agota la memoria.
            sesion.run("MATCH (n) CALL (n) { DETACH DELETE n } IN TRANSACTIONS OF 10000 ROWS;")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MERGE (s:Seccion {slug: fila.slug})
                SET s.nombre = fila.nombre, s.raiz = fila.raiz
            """, secciones, argumentos.lote, "Seccion")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MERGE (e:Etiqueta {slug: fila.slug})
                SET e.nombre = fila.nombre
            """, etiquetas, argumentos.lote, "Etiqueta")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MERGE (u:Usuario {usuario_id: fila.usuario_id})
                SET u.pais = fila.pais, u.plan = fila.plan
            """, usuarios, argumentos.lote, "Usuario")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MERGE (c:Contenido {contenido_id: fila.contenido_id})
                SET c.titulo = fila.titulo,
                    c.seccion = fila.seccion,
                    c.seccion_raiz = fila.seccion_raiz,
                    c.tipo = fila.tipo,
                    c.nivel_acceso = fila.nivel_acceso,
                    c.estado = fila.estado,
                    c.fecha_publicacion = fila.fecha_publicacion
            """, contenidos, argumentos.lote, "Contenido")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (c:Contenido {contenido_id: fila.contenido_id})
                MATCH (s:Seccion {slug: fila.slug})
                MERGE (c)-[:PERTENECE_A]->(s)
            """, contenido_seccion, argumentos.lote, "PERTENECE_A")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (c:Contenido {contenido_id: fila.contenido_id})
                MATCH (e:Etiqueta {slug: fila.slug})
                MERGE (c)-[r:TIENE_ETIQUETA]->(e)
                SET r.relevancia = fila.relevancia
            """, contenido_etiqueta, argumentos.lote, "TIENE_ETIQUETA")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (u:Usuario {usuario_id: fila.usuario_id})
                MATCH (c:Contenido {contenido_id: fila.contenido_id})
                MERGE (u)-[:ESCRIBIO]->(c)
            """, [{"usuario_id": c["autor_id"], "contenido_id": c["contenido_id"]}
                  for c in contenidos], argumentos.lote, "ESCRIBIO")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (u:Usuario {usuario_id: fila.usuario_id})
                MATCH (s:Seccion {slug: fila.slug})
                FOREACH (_ IN CASE WHEN fila.tipo = 'sigue' THEN [1] ELSE [] END |
                    MERGE (u)-[:SIGUE]->(s))
                FOREACH (_ IN CASE WHEN fila.tipo = 'no_interesa' THEN [1] ELSE [] END |
                    MERGE (u)-[:NO_LE_INTERESA]->(s))
            """, preferencias, argumentos.lote, "SIGUE/NO_LE_INTERESA")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (u:Usuario {usuario_id: fila.usuario_id})
                MATCH (c:Contenido {contenido_id: fila.contenido_id})
                MERGE (u)-[r:VIO]->(c)
                SET r.veces = fila.veces,
                    r.completo = fila.completo,
                    r.ultima_vez = fila.ultima_vez
            """, aristas_vio, argumentos.lote, "VIO")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (u:Usuario {usuario_id: fila.usuario_id})
                MATCH (c:Contenido {contenido_id: fila.contenido_id})
                MERGE (u)-[:GUARDO]->(c)
            """, aristas_guardo, argumentos.lote, "GUARDO")

            ejecutar_por_lotes(sesion, """
                UNWIND $filas AS fila
                MATCH (a:Contenido {contenido_id: fila.origen_id})
                MATCH (b:Contenido {contenido_id: fila.destino_id})
                MERGE (a)-[r:SIMILAR_A {origen: 'embedding'}]->(b)
                SET r.score = fila.score
            """, similares, argumentos.lote, "SIMILAR_A")

            # ---------- Verificacion ----------
            resumen = sesion.run("""
                MATCH (n)
                WITH labels(n)[0] AS etiqueta, count(*) AS nodos
                RETURN etiqueta, nodos ORDER BY etiqueta
            """).data()
            relaciones = sesion.run("""
                MATCH ()-[r]->()
                RETURN type(r) AS relacion, count(*) AS cantidad ORDER BY relacion
            """).data()

            print("\nNodos:")
            for fila in resumen:
                print(f"  {fila['etiqueta']:12s} {fila['nodos']:>8d}")
            print("Relaciones:")
            for fila in relaciones:
                print(f"  {fila['relacion']:16s} {fila['cantidad']:>8d}")

            esperado_contenidos = len(contenidos)
            real = next((f["nodos"] for f in resumen if f["etiqueta"] == "Contenido"), 0)
            if real != esperado_contenidos:
                raise SystemExit(
                    f"Se esperaban {esperado_contenidos} nodos Contenido y hay {real}"
                )
            if not any(f["relacion"] == "VIO" for f in relaciones):
                raise SystemExit("El grafo no tiene ninguna relacion VIO: no hay comportamiento.")

    finally:
        cur.close()
        conexion.close()
        cliente_mongo.close()
        driver.close()

    print("\nGrafo construido y verificado.")


if __name__ == "__main__":
    main()
