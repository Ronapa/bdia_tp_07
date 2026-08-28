#!/usr/bin/env python3
"""Publica en Redis la capa de serving online del recomendador.

Redis no guarda nada que no pueda reconstruirse: todo lo que hay aca sale
de PostgreSQL o de la capa Gold del lakehouse. Si el servidor se pierde,
se vuelve a correr este script.

Esa es justamente la razon por la que puede no tener durabilidad, no
tener transacciones y vivir en memoria: no es una base de datos, es un
cache calculado. Y es lo que permite que el camino del request no toque
ninguna de las otras cuatro bases.

Estructuras publicadas y por que cada una:

    ZSET  rec:trending:global            ranking global por popularidad
    ZSET  rec:trending:seccion:<slug>    ranking por seccion
    ZSET  rec:usuario:<id>:top           feed hibrido precalculado
          -> ZSET porque el caso de uso ES un ranking: ZREVRANGE devuelve
             el top-N ya ordenado, en O(log n + N), sin ordenar nada.

    SET   usuario:<id>:vistos            deduplicacion de impresiones
          -> SET porque la pregunta es de pertenencia (SISMEMBER), y esa
             es O(1).

    HASH  usuario:<id>:features          feature store online
    HASH  contenido:<id>:meta            cache de metadatos del catalogo
          -> HASH porque se leen varios campos juntos con un solo HGETALL
             y se pueden actualizar de a uno sin reescribir el resto.

    STREAM cola:eventos                  buffer de ingesta del clickstream
          -> STREAM porque necesita orden, lectura por grupos de consumo
             y confirmacion; una lista simple no da ninguna de las tres.

Uso:
    python publicar_serving.py
    python publicar_serving.py --top 30 --ttl 900

Variables de entorno:
    REDIS_HOST, REDIS_PORT, REDIS_PASSWORD, POSTGRES_*
"""
from __future__ import annotations

import argparse
import os
from collections import defaultdict

import psycopg2
import redis

# Pesos de la estrategia hibrida. Suman 1 y estan expuestos como
# constantes para que la mezcla sea auditable y no un numero magico
# perdido dentro de una consulta.
PESO_POPULARIDAD = 0.30
PESO_SEMANTICO = 0.35
PESO_COOCURRENCIA = 0.35


def conectar_bd():
    return psycopg2.connect(
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        dbname=os.environ.get("POSTGRES_DB", "bdia_nexomedia"),
        user=os.environ.get("POSTGRES_USER", "bdia_user"),
        password=os.environ.get("POSTGRES_PASSWORD", ""),
    )


def conectar_redis():
    # Aca se conecta con el usuario administrador: este script ESCRIBE la capa de serving.
    # El usuario app_lectura se crea al final y es el que usa la API;
    # no puede publicar porque no tiene @write.
    return redis.Redis(
        host=os.environ.get("REDIS_HOST", "localhost"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD") or None,
        decode_responses=True,
    )


def limpiar_claves(cliente: redis.Redis, patrones: list[str]) -> int:
    """Borra por patron con SCAN, nunca con KEYS.

    KEYS recorre el espacio de claves completo bloqueando el servidor, que
    es de un solo hilo. En una base chica no se nota; en produccion es un
    incidente. SCAN itera de a bloques y no bloquea.
    """
    borradas = 0
    for patron in patrones:
        for lote in _por_lotes(cliente.scan_iter(match=patron, count=500), 500):
            if lote:
                borradas += cliente.delete(*lote)
    return borradas


def _por_lotes(iterable, tamano: int):
    lote = []
    for elemento in iterable:
        lote.append(elemento)
        if len(lote) >= tamano:
            yield lote
            lote = []
    if lote:
        yield lote


def publicar_trending(cur, cliente: redis.Redis, ttl: int, top: int) -> int:
    """Publica los rankings de popularidad desde la capa Gold."""

    # 24h: el trending tiene que reflejar lo que esta pasando ahora.
    # El feed hibrido (mas abajo) usa 7d: ahi la popularidad es una
    # red de contencion, no la noticia del dia, y una ventana corta
    # dejaria a los usuarios frios sin candidatos.
    cur.execute(
        """
        SELECT p.contenido_id, p.seccion, p.score
        FROM analitica.agg_popularidad AS p
        WHERE p.ventana = '24h'
        ORDER BY p.score DESC;
        """
    )
    filas = cur.fetchall()
    if not filas:
        raise SystemExit(
            "analitica.agg_popularidad esta vacia. "
            "Correr primero el pipeline de DuckDB (analitico/04_cargar_gold.sql)."
        )

    por_seccion: dict[str, list] = defaultdict(list)
    # Pipeline sin transaccion: no hay invariante entre claves que exija
    # MULTI/EXEC. Lo que se gana es dejar de pagar un round-trip por comando;
    # Redis no es la fuente de verdad, si un ZADD queda a medias la proxima corrida reconstruye todo.
    tuberia = cliente.pipeline(transaction=False)
    global_ = {}

    for contenido_id, seccion, score in filas:
        global_[str(contenido_id)] = float(score)
        por_seccion[seccion].append((str(contenido_id), float(score)))

    tuberia.delete("rec:trending:global")
    tuberia.zadd("rec:trending:global", global_)
    tuberia.expire("rec:trending:global", ttl)

    for seccion, elementos in por_seccion.items():
        clave = f"rec:trending:seccion:{seccion.lower().replace(' ', '-')}"
        tuberia.delete(clave)
        tuberia.zadd(clave, dict(elementos[:top]))
        tuberia.expire(clave, ttl)

    tuberia.execute()
    return len(por_seccion) + 1


def publicar_metadatos(cur, cliente: redis.Redis, ttl: int) -> int:
    """Cachea los metadatos que el feed necesita para renderizar.

    Solo se cachean los contenidos PUBLICADOS. Un borrador nunca llega a
    Redis: si llegara, cualquier error de la capa de aplicacion podria
    exponerlo, y Redis no tiene Row Level Security que lo impida.
    Lo que no debe salir, no sale de PostgreSQL.
    """
    cur.execute(
        """
        SELECT contenido_id, titulo, seccion, seccion_slug, tipo_contenido, nivel_acceso
        FROM catalogo.vw_contenidos_publicables;
        """
    )
    filas = cur.fetchall()
    tuberia = cliente.pipeline(transaction=False)

    for contenido_id, titulo, seccion, slug, tipo, nivel in filas:
        clave = f"contenido:{contenido_id}:meta"
        tuberia.hset(
            clave,
            mapping={
                "titulo": titulo,
                "seccion": seccion,
                "seccion_slug": slug,
                "tipo": tipo,
                "nivel_acceso": nivel,
            },
        )
        tuberia.expire(clave, ttl * 4)

    tuberia.execute()
    return len(filas)


def publicar_feeds_usuario(cur, cliente: redis.Redis, ttl: int, top: int) -> int:
    """Precalcula el feed hibrido de cada usuario y lo deja listo para leer.

    Toda la mezcla de senales se hace aca, una vez por corrida. El camino
    del request queda reducido a un ZREVRANGE, que es lo que permite
    servir el feed en menos de un milisegundo.

    El orden de las operaciones no es casual: primero se calculan los
    candidatos, despues se restan los vetos y lo ya visto. Restar al
    final garantiza que ningun contenido vetado sobreviva por un empate
    de puntajes.
    """

    # 7d, no 24h: aca popularidad cubre cold start, no el ranking editorial del dia.
    # Ver publicar_trending.
    cur.execute(
        """
        SELECT contenido_id, score
        FROM analitica.agg_popularidad
        WHERE ventana = '7d';
        """
    )
    popularidad = {fila[0]: float(fila[1]) for fila in cur.fetchall()}
    maximo_popularidad = max(popularidad.values()) if popularidad else 1.0

    cur.execute(
        """
        SELECT contenido_id, contenido_similar_id, origen, score
        FROM recomendacion.ranking_items_similares;
        """
    )
    vecinos: dict[str, dict[int, list]] = {
        "embedding": defaultdict(list),
        "coocurrencia": defaultdict(list),
    }
    for contenido_id, similar_id, origen, score in cur.fetchall():
        if origen in vecinos:
            vecinos[origen][contenido_id].append((similar_id, float(score)))

    cur.execute(
        """
        SELECT usuario_id, contenido_id
        FROM recomendacion.impresiones
        WHERE clic
        GROUP BY usuario_id, contenido_id;
        """
    )
    historial: dict[int, set[int]] = defaultdict(set)
    for usuario_id, contenido_id in cur.fetchall():
        historial[usuario_id].add(contenido_id)

    cur.execute("SELECT usuario_id, contenido_id FROM recomendacion.vw_vetos_usuario;")
    vetos: dict[int, set[int]] = defaultdict(set)
    for usuario_id, contenido_id in cur.fetchall():
        vetos[usuario_id].add(contenido_id)

    cur.execute(
        """
        SELECT
            u.id,
            COALESCE(p.nivel_acceso, 0) AS nivel_acceso,
            u.consentimiento_personalizacion
        FROM personas.usuarios AS u
        LEFT JOIN personas.suscripciones AS s
            ON s.usuario_id = u.id AND s.estado = 'activa'
        LEFT JOIN personas.planes AS p
            ON p.id = s.plan_id
        WHERE u.activo;
        """
    )
    usuarios = cur.fetchall()

    cur.execute(
        """
        SELECT contenido_id, nivel_acceso
        FROM catalogo.vw_contenidos_publicables;
        """
    )
    nivel_contenido = dict(cur.fetchall())

    tuberia = cliente.pipeline(transaction=False)
    publicados = 0

    for usuario_id, nivel_usuario, consentimiento in usuarios:
        vistos = historial.get(usuario_id, set())
        vetados = vetos.get(usuario_id, set())

        candidatos: dict[int, float] = defaultdict(float)

        # Senal 1: popularidad. Es la unica que se aplica SIEMPRE, incluso
        # sin consentimiento y sin historial: es la red de contencion del
        # cold start.
        for contenido_id, score in popularidad.items():
            candidatos[contenido_id] += PESO_POPULARIDAD * (score / maximo_popularidad)

        # Senales 2 y 3: solo con consentimiento de personalizacion.
        if consentimiento and vistos:
            for visto in vistos:
                for similar_id, score in vecinos["embedding"].get(visto, []):
                    candidatos[similar_id] += PESO_SEMANTICO * score / len(vistos)
                for similar_id, score in vecinos["coocurrencia"].get(visto, []):
                    candidatos[similar_id] += PESO_COOCURRENCIA * score / len(vistos)

        # Filtros duros, al final: nivel de acceso, vetos y ya visto.
        finales = {
            str(contenido_id): puntaje
            for contenido_id, puntaje in candidatos.items()
            if contenido_id in nivel_contenido
            and nivel_contenido[contenido_id] <= nivel_usuario
            and contenido_id not in vetados
            and contenido_id not in vistos
        }
        if not finales:
            continue

        mejores = dict(
            sorted(finales.items(), key=lambda par: par[1], reverse=True)[:top]
        )
        clave = f"rec:usuario:{usuario_id}:top"
        tuberia.delete(clave)
        tuberia.zadd(clave, mejores)
        tuberia.expire(clave, ttl)

        # Conjunto de ya vistos: dedup de impresiones en el request path.
        if vistos:
            clave_vistos = f"usuario:{usuario_id}:vistos"
            tuberia.delete(clave_vistos)
            tuberia.sadd(clave_vistos, *[str(v) for v in vistos])
            tuberia.expire(clave_vistos, ttl * 8)

        # Feature store online: lo que el modelo necesita en el momento
        # del request y no puede salir a buscar a PostgreSQL.
        tuberia.hset(
            f"usuario:{usuario_id}:features",
            mapping={
                "nivel_acceso": nivel_usuario,
                "consentimiento": int(bool(consentimiento)),
                "contenidos_vistos": len(vistos),
                "vetos": len(vetados),
                "candidatos": len(finales),
            },
        )
        tuberia.expire(f"usuario:{usuario_id}:features", ttl * 8)


        # 500: techo de comandos buffered. Sin esto, 2000 usuarios x
        # varios HSET/ZADD acumulan decenas de miles de comandos en
        # memoria del cliente antes de un solo execute().
        publicados += 1
        if publicados % 500 == 0:
            tuberia.execute()
            tuberia = cliente.pipeline(transaction=False)

    tuberia.execute()
    return publicados


def preparar_stream(cliente: redis.Redis) -> None:
    """Deja creado el stream de ingesta con su grupo de consumo.

    El stream es el amortiguador entre la aplicacion y MongoDB: absorbe
    los picos de escritura y permite que el consumidor procese por lotes.
    MAXLEN aproximado acota la memoria; el dato definitivo vive en Mongo.
    """
    cliente.delete("cola:eventos")
    cliente.xadd(
        "cola:eventos",
        {"tipo": "arranque", "detalle": "stream inicializado"},
        maxlen=10000,
        approximate=True,
    )
    try:
        cliente.xgroup_create("cola:eventos", "ingestores", id="0")
    except redis.ResponseError as error:
        if "BUSYGROUP" not in str(error):
            raise


def configurar_acl(cliente: redis.Redis) -> None:
    """Crea un usuario de solo lectura acotado por patron de clave.

    Es el aislamiento que ofrece Redis: no tiene permisos por fila ni por
    tabla, pero si por comando y por patron de clave. El servicio que
    renderiza el feed puede leer rankings y metadatos, y no puede tocar
    el stream, ni escribir, ni ejecutar comandos administrativos.

    Limite declarado: `~rec:usuario:*` alcanza a TODOS los usuarios. Redis
    no puede expresar "solo las claves de este usuario final", asi que el
    aislamiento entre personas sigue siendo responsabilidad de la
    aplicacion. Es una diferencia real con el RLS de PostgreSQL y esta
    documentada en el informe.
    """
    try:
        cliente.acl_setuser(
            "app_lectura",
            enabled=True,
            passwords=["+lectura_local"],
            keys=["rec:*", "contenido:*", "usuario:*"],
            # +@connection habilita PING y AUTH, que cualquier cliente necesita
            # para abrir la conexion. Sin esa categoria, el healthcheck de la
            # API falla con NOPERM aunque las lecturas funcionen.
            commands=[
                "+@read",
                "+@keyspace",
                "+@connection",
                "-@dangerous",
                "-@admin",
                "-@write",
            ],
            reset=True,
        )
        print("  Usuario Redis 'app_lectura' creado (solo lectura, claves acotadas)")
    except redis.ResponseError as error:
        print(f"  No se pudo configurar la ACL: {error}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--top", type=int, default=25, help="Cantidad de contenidos por ranking."
    )
    # El TTL es una decision de producto: frescura contra disponibilidad.
    # En produccion serian ~900 segundos, para que un feed obsoleto deje de
    # servirse aunque el pipeline falle. Aca el default es 24 horas para que
    # el entorno se pueda revisar al dia siguiente sin volver a correr todo;
    # con 900 segundos, los rankings expiran antes de que nadie los mire.
    parser.add_argument(
        "--ttl",
        type=int,
        default=86400,
        help="Vida util en segundos de los rankings (produccion: 900).",
    )
    argumentos = parser.parse_args()

    conexion = conectar_bd()
    cur = conexion.cursor()
    cliente = conectar_redis()

    try:
        cliente.ping()
    except redis.RedisError as error:
        raise SystemExit(f"No se pudo conectar a Redis: {error}")

    try:
        print("--- Limpiando la capa de serving anterior ---")
        # cola:eventos no se borra aca: tiene grupo de consumo. 
        # Se recrea en preparar_stream para no dejar un stream a medias
        # (claves borradas, grupo huérfano).
        borradas = limpiar_claves(cliente, ["rec:*", "usuario:*", "contenido:*"])
        print(f"  {borradas} claves borradas")

        print("--- Publicando rankings de popularidad ---")
        rankings = publicar_trending(cur, cliente, argumentos.ttl, argumentos.top)
        print(f"  {rankings} rankings (global + por seccion)")

        print("--- Cacheando metadatos del catalogo publicado ---")
        metadatos = publicar_metadatos(cur, cliente, argumentos.ttl)
        print(f"  {metadatos} contenidos cacheados")

        print("--- Precalculando el feed hibrido por usuario ---")
        feeds = publicar_feeds_usuario(cur, cliente, argumentos.ttl, argumentos.top)
        print(f"  {feeds} feeds publicados")

        print("--- Preparando el stream de ingesta ---")
        preparar_stream(cliente)

        print("--- Configurando el control de acceso ---")
        configurar_acl(cliente)

    finally:
        cur.close()
        conexion.close()

    # Verificacion: si el feed quedo vacio, el recomendador no tiene que
    # servir; tiene que fallar y que alguien lo mire.
    if feeds == 0:
        raise SystemExit("No se publico ningun feed de usuario.")
    if cliente.zcard("rec:trending:global") == 0:
        raise SystemExit("El ranking global quedo vacio.")

    print(f"\nCapa de serving publicada.")
    print(f"  Claves totales      : {cliente.dbsize()}")
    print(f"  Memoria utilizada   : {cliente.info('memory')['used_memory_human']}")
    print(f"  Trending global     : {cliente.zcard('rec:trending:global')} contenidos")


if __name__ == "__main__":
    main()
