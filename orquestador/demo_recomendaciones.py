#!/usr/bin/env python3
"""Muestra por consola las cinco estrategias de recomendacion, motor por motor.

Es la demostracion mas directa del argumento poliglota: la misma pregunta
("que le recomendamos a este usuario") resuelta cinco veces, cada una en
el motor que mejor la responde, y comparando los resultados.

No usa la API: va directo a cada base. La idea es que se vea la consulta,
no el endpoint.

Uso:
    python demo_recomendaciones.py --usuario 1
    python demo_recomendaciones.py --usuario 12 --limite 5

Variables de entorno:
    POSTGRES_*, REDIS_*, NEO4J_*, MONGO_*
"""
from __future__ import annotations

import argparse
import os

import psycopg2
import redis
from neo4j import GraphDatabase
from pymongo import MongoClient


def conectar_bd():
    return psycopg2.connect(
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        dbname=os.environ.get("POSTGRES_DB", "bdia_nexomedia"),
        user=os.environ.get("POSTGRES_USER", "bdia_user"),
        password=os.environ.get("POSTGRES_PASSWORD", ""),
    )


def conectar_redis():
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "localhost"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD") or None,
        decode_responses=True,
    )


def conectar_grafo():
    return GraphDatabase.driver(
        os.environ.get("NEO4J_URI", "bolt://localhost:7687"),
        auth=(os.environ.get("NEO4J_USER", "neo4j"), os.environ.get("NEO4J_PASSWORD", "")),
    )


def conectar_mongo():
    usuario = os.environ.get("MONGO_INITDB_ROOT_USERNAME", "bdia_admin")
    clave = os.environ.get("MONGO_INITDB_ROOT_PASSWORD", "")
    host = os.environ.get("MONGO_HOST", "localhost")
    puerto = os.environ.get("MONGO_PORT", "27017")
    return MongoClient(f"mongodb://{usuario}:{clave}@{host}:{puerto}/?authSource=admin")


def titulo(cur, contenido_id: int) -> str:
    cur.execute("SELECT titulo, seccion_id FROM catalogo.contenidos WHERE id = %s;",
                (contenido_id,))
    fila = cur.fetchone()
    return fila[0] if fila else f"(contenido {contenido_id})"


def imprimir(encabezado: str, motor: str, filas: list[tuple]) -> None:
    print(f"\n--- {encabezado}  [motor: {motor}] ---")
    if not filas:
        print("  (sin resultados)")
        return
    for posicion, (contenido_id, texto, score) in enumerate(filas, start=1):
        print(f"  {posicion:>2}. [{contenido_id:>5}] {texto[:62]:<62} {score:>10.4f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--usuario", type=int, default=1, help="Id del usuario final.")
    parser.add_argument("--limite", type=int, default=8, help="Recomendaciones por estrategia.")
    argumentos = parser.parse_args()

    usuario_id = argumentos.usuario
    limite = argumentos.limite

    conexion = conectar_bd()
    cur = conexion.cursor()
    cliente_redis = conectar_redis()
    driver = conectar_grafo()
    cliente_mongo = conectar_mongo()
    base_mongo = cliente_mongo[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")]

    try:
        # ---------- Perfil del usuario ----------
        cur.execute(
            """
            SELECT
                u.alias, u.pais, u.consentimiento_personalizacion,
                COALESCE(p.codigo, 'sin_plan') AS plan,
                COALESCE(p.nivel_acceso, 0) AS nivel
            FROM personas.usuarios AS u
            LEFT JOIN personas.suscripciones AS s
                ON s.usuario_id = u.id AND s.estado = 'activa'
            LEFT JOIN personas.planes AS p
                ON p.id = s.plan_id
            WHERE u.id = %s;
            """,
            (usuario_id,),
        )
        fila = cur.fetchone()
        if fila is None:
            raise SystemExit(f"El usuario {usuario_id} no existe.")
        alias, pais, consentimiento, plan, nivel = fila

        eventos = base_mongo.eventos_interaccion.count_documents({"usuario_id": usuario_id})

        print("=" * 92)
        print(f"Usuario {usuario_id}: {alias} ({pais})")
        print(f"  Plan: {plan} (nivel de acceso {nivel})")
        print(f"  Consentimiento de personalizacion: {'si' if consentimiento else 'NO'}")
        print(f"  Eventos en el clickstream (MongoDB): {eventos}")
        print("=" * 92)

        # ---------- 1. Popularidad (Redis) ----------
        elementos = cliente_redis.zrevrange("rec:trending:global", 0, limite - 1, withscores=True)
        imprimir("popularidad", "redis (ZSET precalculado desde la capa Gold)",
                 [(int(c), titulo(cur, int(c)), s) for c, s in elementos])

        # ---------- 2. Similitud semantica (pgvector) ----------
        cur.execute(
            """
            SELECT v.contenido_id, v.titulo,
                   1 - (e.embedding <=> p.embedding) AS afinidad
            FROM recomendacion.perfiles_usuario AS p
            JOIN recomendacion.embeddings_contenido AS e ON TRUE
            JOIN catalogo.vw_contenidos_publicables AS v
                ON v.contenido_id = e.contenido_id
            WHERE p.usuario_id = %s
              AND v.nivel_acceso <= %s
            ORDER BY e.embedding <=> p.embedding
            LIMIT %s;
            """,
            (usuario_id, nivel, limite),
        )
        imprimir("contenido_similar", "pgvector (kNN sobre el perfil, con prefiltrado)",
                 [(f[0], f[1], float(f[2])) for f in cur.fetchall()])

        # ---------- 3. Colaborativo item-item (DuckDB -> Gold) ----------
        cur.execute(
            """
            WITH historial AS (
                SELECT DISTINCT contenido_id
                FROM recomendacion.impresiones
                WHERE usuario_id = %s AND clic
            )
            SELECT r.contenido_similar_id, v.titulo, SUM(r.score) AS score
            FROM recomendacion.ranking_items_similares AS r
            JOIN historial AS h ON h.contenido_id = r.contenido_id
            JOIN catalogo.vw_contenidos_publicables AS v
                ON v.contenido_id = r.contenido_similar_id
            WHERE r.origen = 'coocurrencia'
              AND v.nivel_acceso <= %s
              AND r.contenido_similar_id NOT IN (SELECT contenido_id FROM historial)
            GROUP BY r.contenido_similar_id, v.titulo
            ORDER BY score DESC
            LIMIT %s;
            """,
            (usuario_id, nivel, limite),
        )
        imprimir("colaborativo_item",
                 "duckdb (matriz de co-ocurrencia calculada sobre el lakehouse)",
                 [(f[0], f[1], float(f[2])) for f in cur.fetchall()])

        # ---------- 4. Co-visualizacion (Neo4j) ----------
        with driver.session() as sesion:
            resultado = sesion.run(
                """
                MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(puente:Contenido)
                      <-[:VIO]-(otro:Usuario)-[:VIO]->(rec:Contenido)
                WHERE rec.estado = 'publicado'
                  AND rec.nivel_acceso <= $nivel
                  AND otro <> u
                  AND NOT EXISTS { (u)-[:VIO]->(rec) }
                WITH rec, puente, count(DISTINCT otro) AS lectores
                ORDER BY lectores DESC
                WITH rec, sum(lectores) AS score,
                     collect(puente.titulo)[0] AS mejor_puente
                RETURN rec.contenido_id AS contenido_id, rec.titulo AS titulo,
                       score, mejor_puente
                ORDER BY score DESC
                LIMIT $limite
                """,
                usuario=usuario_id, nivel=nivel, limite=limite,
            ).data()
        imprimir("grafo_covisualizacion", "neo4j (dos saltos con explicacion del camino)",
                 [(f["contenido_id"], f["titulo"], float(f["score"])) for f in resultado])
        if resultado:
            print(f"      Explicacion: porque leiste \"{resultado[0]['mejor_puente'][:55]}\"")

        # ---------- 5. Hibrido (Redis, precalculado) ----------
        elementos = cliente_redis.zrevrange(f"rec:usuario:{usuario_id}:top", 0, limite - 1,
                                            withscores=True)
        imprimir("hibrido", "redis (mezcla ponderada precalculada en el pipeline)",
                 [(int(c), titulo(cur, int(c)), s) for c, s in elementos])

        # ---------- Comparacion ----------
        conjuntos = {}
        conjuntos["hibrido"] = {int(c) for c, _ in elementos}
        # Sin withscores, ZREVRANGE devuelve una lista plana de miembros.
        conjuntos["popularidad"] = {
            int(c) for c in cliente_redis.zrevrange("rec:trending:global", 0, limite - 1)
        }
        print("\n--- Coincidencia entre estrategias ---")
        interseccion = conjuntos["hibrido"] & conjuntos["popularidad"]
        print(f"  hibrido / popularidad: {len(interseccion)} de {limite} contenidos en comun")
        print("  Poca coincidencia es lo esperado: si el hibrido devolviera lo mismo que")
        print("  el ranking global, la personalizacion no estaria aportando nada.")

        # ---------- Feature store ----------
        rasgos = cliente_redis.hgetall(f"usuario:{usuario_id}:features")
        if rasgos:
            print("\n--- Feature store online (Redis HASH) ---")
            for clave, valor in sorted(rasgos.items()):
                print(f"  {clave:22s} {valor}")

    finally:
        cur.close()
        conexion.close()
        driver.close()
        cliente_mongo.close()

    print("\n" + "=" * 92)


if __name__ == "__main__":
    main()
