#!/usr/bin/env python3
"""API minima de recomendacion: el consumidor de datos de la arquitectura.

No es el entregable del trabajo practico, que es la capa de datos. Esta
aca por dos motivos:

  1. Cierra el diagrama de arquitectura. Una capa de datos se justifica
     por las consultas que habilita; el servicio las hace tangibles.
  2. Cada endpoint se apoya en un motor distinto, y eso hace visible el
     argumento poliglota sin necesidad de explicarlo.

        GET /recomendaciones/{id}?estrategia=popularidad            -> Redis
        GET /recomendaciones/{id}?estrategia=contenido_similar      -> pgvector
        GET /recomendaciones/{id}?estrategia=colaborativo_item      -> DuckDB (Gold)
        GET /recomendaciones/{id}?estrategia=grafo_covisualizacion  -> Neo4j
        GET /recomendaciones/{id}?estrategia=hibrido                -> Redis (precalculado)
        GET /contenidos/{id}/similares                              -> pgvector
        GET /trending                                               -> Redis
        POST /impresiones                                           -> PostgreSQL

Cada respuesta declara que motor la resolvio, para que se pueda comprobar
desde afuera.

================================================================
MODELO DE SEGURIDAD
================================================================

El servicio se conecta a los cuatro motores con usuarios de minimo
privilegio, nunca con credenciales administrativas. En PostgreSQL usa el
rol **bdia_api**, que NO es superusuario ni dueno de las tablas y por lo
tanto **esta sujeto a Row Level Security**.

Eso es lo que hace que la barrera viva en el motor y no en este archivo.
Conectarse con el dueno de la base anularia el RLS, y entonces todo el
aislamiento dependeria de que cada endpoint recordara filtrar: un
`/trending` que se olvidara del nivel de acceso alcanzaria para entregar
titulos de contenido premium a un visitante anonimo.

Tres reglas que se siguen en todo el archivo:

  1. **La identidad NUNCA viene de la URL ni del cuerpo del pedido.**
     Llega en la cabecera `X-Usuario-Id`. Eso es una SIMULACION explicita
     de un token de sesion: en un sistema real la cabecera seria un JWT
     firmado y el servidor lo validaria. La autenticacion queda fuera del
     alcance de un trabajo de bases de datos.

     Ser precisos con lo que si esta resuelto: el sistema **no confia en
     lo que el cliente declare sobre a que tiene derecho** —el nivel de
     acceso sale siempre de la base—, pero **si confia en la identidad**
     que llega en la cabecera, porque no hay nada que la valide. Con un
     token firmado, las dos cosas dejarian de depender del cliente sin
     cambiar una linea de SQL.

  2. **El nivel de acceso se deriva SIEMPRE de la base**, con
     personas.nivel_acceso_actual(). No hay ningun parametro que permita
     al cliente declarar su propio nivel.

  3. **El contexto se declara con set_config(..., TRUE)**, o sea local a
     la transaccion. Con FALSE (local a la sesion) el valor queda pegado
     a la conexion: al volver al pool, la peticion siguiente heredaria la
     identidad de la anterior. Es una fuga silenciosa y dificil de
     reproducir.

Sin cabecera, la sesion queda como visitante anonimo (nivel 0) y el RLS
solo devuelve contenido publicado de acceso libre. El default es el
minimo privilegio.

Uso:
    uvicorn recomendador_api:app --host 0.0.0.0 --port 8000

Variables de entorno:
    API_DB_USER, API_DB_PASSWORD   rol restringido (bdia_api)
    POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB
    REDIS_*, NEO4J_*, MONGO_*
"""
from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Literal

import psycopg2
import redis
from fastapi import FastAPI, Header, HTTPException, Query
from neo4j import GraphDatabase
from pydantic import BaseModel
from pymongo import MongoClient

ESTRATEGIAS = Literal[
    "popularidad", "contenido_similar", "colaborativo_item",
    "grafo_covisualizacion", "hibrido",
]

app = FastAPI(
    title="NexoMedia - API de recomendacion",
    description=(
        "Demostracion de la capa de datos del TP Integrador de BDIA. "
        "Se conecta con el rol bdia_api, sujeto a Row Level Security. "
        "La identidad se declara en la cabecera X-Usuario-Id, que simula "
        "un token de sesion validado."
    ),
    version="2.0",
)

# ============================================================
# Conexiones: ninguna usa credenciales administrativas
#
# El servicio se conecta a los cuatro motores con el usuario de MENOR
# privilegio que le alcanza para su trabajo. No es simetrico entre
# motores, porque cada uno permite una granularidad distinta:
#
#   PostgreSQL -> bdia_api, sujeto a Row Level Security
#   Redis      -> app_lectura, ACL de solo lectura acotada por patron
#   MongoDB    -> bdia_mongo_lectura, sin acceso a `comentarios`
#   Neo4j      -> bdia_grafo_consulta, que NO puede ser de solo lectura
#                 porque la edicion Community no tiene roles (ver
#                 nosql/neo4j/consultas/03_limitaciones_community.cypher)
# ============================================================

_redis = redis.Redis(
    host=os.environ.get("REDIS_HOST", "localhost"),
    port=int(os.environ.get("REDIS_PORT", "6379")),
    username=os.environ.get("REDIS_LECTURA_USER", "app_lectura"),
    password=os.environ.get("REDIS_LECTURA_PASSWORD", "lectura_local"),
    decode_responses=True,
)

_neo4j = GraphDatabase.driver(
    os.environ.get("NEO4J_URI", "bolt://localhost:7687"),
    auth=(os.environ.get("NEO4J_CONSULTA_USER", "bdia_grafo_consulta"),
          os.environ.get("NEO4J_CONSULTA_PASSWORD", "consulta_local")),
)

_mongo = MongoClient(
    "mongodb://{u}:{p}@{h}:{q}/?authSource={b}".format(
        u=os.environ.get("MONGO_LECTURA_USER", "bdia_mongo_lectura"),
        p=os.environ.get("MONGO_LECTURA_PASSWORD", "lectura_local"),
        h=os.environ.get("MONGO_HOST", "localhost"),
        q=os.environ.get("MONGO_PORT", "27017"),
        b=os.environ.get("MONGO_DATABASE", "bdia_nexomedia"),
    ),
    serverSelectionTimeoutMS=3000,
)


@contextmanager
def sesion_bd(usuario_id: int | None = None):
    """Abre una transaccion con la identidad del usuario ya declarada.

    Se conecta con bdia_api, que esta sujeto a RLS. El `set_config` con
    TRUE ata el valor a esta transaccion: al cerrarla, el contexto
    desaparece y la conexion vuelve limpia al pool.
    """
    conexion = psycopg2.connect(
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        dbname=os.environ.get("POSTGRES_DB", "bdia_nexomedia"),
        user=os.environ.get("API_DB_USER", "bdia_api"),
        password=os.environ.get("API_DB_PASSWORD", ""),
    )
    try:
        cur = conexion.cursor()
        # Siempre se declara, incluso cuando es NULL: una cadena vacia
        # hace que personas.usuario_actual() devuelva NULL y la sesion
        # quede como visitante anonimo.
        cur.execute(
            "SELECT set_config('app.usuario_id', %s, TRUE);",
            (str(usuario_id) if usuario_id is not None else "",),
        )
        yield cur, conexion
        conexion.commit()
    except Exception:
        conexion.rollback()
        raise
    finally:
        conexion.close()


def identidad(x_usuario_id: str | None) -> int | None:
    """Traduce la cabecera a un id de usuario.

    SIMULACION de la validacion de un token. En produccion aca se
    verificaria la firma del JWT y se extraeria el sujeto; el resto del
    archivo no cambiaria, porque lo que sigue ya no confia en el cliente.
    """
    if x_usuario_id is None or x_usuario_id.strip() == "":
        return None
    try:
        return int(x_usuario_id)
    except ValueError:
        raise HTTPException(status_code=400, detail="X-Usuario-Id no es un entero")


def nivel_de_acceso(cur) -> int:
    """Nivel del usuario de la sesion, siempre derivado de la base.

    Nunca se acepta como parametro. Si el cliente pudiera declararlo,
    bastaria con pedir nivel 2 para recibir todo el contenido premium.
    """
    cur.execute("SELECT personas.nivel_acceso_actual();")
    return cur.fetchone()[0]


class Recomendacion(BaseModel):
    contenido_id: int
    titulo: str
    seccion: str | None = None
    nivel_acceso: int | None = None
    score: float
    explicacion: str | None = None


class Respuesta(BaseModel):
    usuario_id: int | None
    estrategia: str
    motor: str
    nivel_acceso: int
    recomendaciones: list[Recomendacion]


class ImpresionNueva(BaseModel):
    """El usuario NO viaja en el cuerpo: sale de la identidad de la sesion."""
    contenido_id: int
    estrategia: str
    posicion: int
    score: float
    superficie: str = "home"
    clic: bool = False


def resolver_contenidos(cur, ids: list[int], nivel: int) -> dict[int, tuple]:
    """Trae titulo, seccion y nivel de los contenidos accesibles.

    El filtro por nivel esta aca ademas de en el RLS: defensa en
    profundidad. Cualquiera de los dos alcanzaria; tener los dos hace que
    un error en uno no abra la puerta.
    """
    if not ids:
        return {}
    cur.execute(
        """
        SELECT contenido_id, titulo, seccion, nivel_acceso
        FROM catalogo.vw_contenidos_publicables
        WHERE contenido_id = ANY(%s)
          AND nivel_acceso <= %s;
        """,
        (ids, nivel),
    )
    return {fila[0]: (fila[1], fila[2], fila[3]) for fila in cur.fetchall()}


def armar(candidatos: list[tuple[int, float]], contenidos: dict[int, tuple],
          explicacion: str) -> list[Recomendacion]:
    return [
        Recomendacion(
            contenido_id=contenido_id,
            titulo=contenidos[contenido_id][0],
            seccion=contenidos[contenido_id][1],
            nivel_acceso=contenidos[contenido_id][2],
            score=round(float(score), 6),
            explicacion=explicacion,
        )
        for contenido_id, score in candidatos
        if contenido_id in contenidos
    ]


@app.get("/salud")
def salud():
    """Comprueba que los cuatro motores del camino de lectura responden."""
    estado = {}
    try:
        estado["redis"] = _redis.ping()
    except Exception as error:
        estado["redis"] = f"error: {error}"
    try:
        with sesion_bd() as (cur, _):
            cur.execute("SELECT 1;")
            estado["postgresql"] = cur.fetchone()[0] == 1
    except Exception as error:
        estado["postgresql"] = f"error: {error}"
    try:
        with _neo4j.session() as sesion:
            estado["neo4j"] = sesion.run("RETURN 1 AS ok").single()["ok"] == 1
    except Exception as error:
        estado["neo4j"] = f"error: {error}"
    try:
        _mongo.admin.command("ping")
        estado["mongodb"] = True
    except Exception as error:
        estado["mongodb"] = f"error: {error}"

    estado["ok"] = all(valor is True for clave, valor in estado.items() if clave != "ok")

    # Devolver 200 con "ok": false haria que el healthcheck de Docker
    # marcara como sano un servicio degradado. El codigo HTTP tiene que
    # decir la verdad.
    if not estado["ok"]:
        raise HTTPException(status_code=503, detail=estado)
    return estado


@app.get("/trending", response_model=list[Recomendacion])
def trending(
    seccion: str | None = None,
    limite: int = Query(10, ge=1, le=50),
    x_usuario_id: str | None = Header(default=None),
):
    """Ranking de popularidad servido desde Redis, filtrado por el nivel real.

    El ranking de Redis contiene TODO el catalogo publicado, incluido el
    contenido premium: es un ZSET, no tiene control de acceso. El filtro
    lo pone PostgreSQL al resolver los titulos.

    Sin cabecera, el nivel es 0 y un visitante anonimo solo recibe
    contenido de acceso libre. Esa era la fuga concreta de la version
    anterior: devolvia titulos de nivel 1 y 2 a cualquiera.
    """
    usuario_id = identidad(x_usuario_id)
    clave = f"rec:trending:seccion:{seccion.lower()}" if seccion else "rec:trending:global"

    # Se piden mas elementos de los necesarios porque el filtro por nivel
    # va a descartar algunos: sin este margen, un usuario gratuito
    # recibiria un feed mas corto que uno premium.
    elementos = _redis.zrevrange(clave, 0, (limite * 4) - 1, withscores=True)
    if not elementos:
        raise HTTPException(status_code=404, detail=f"No hay ranking publicado en {clave}")

    with sesion_bd(usuario_id) as (cur, _):
        nivel = nivel_de_acceso(cur)
        contenidos = resolver_contenidos(cur, [int(c) for c, _ in elementos], nivel)

    candidatos = [(int(c), s) for c, s in elementos if int(c) in contenidos][:limite]
    return armar(candidatos, contenidos, "Entre lo mas leido de las ultimas 24 horas")


@app.get("/contenidos/{contenido_id}/similares", response_model=list[Recomendacion])
def similares(
    contenido_id: int,
    limite: int = Query(5, ge=1, le=20),
    x_usuario_id: str | None = Header(default=None),
):
    """Vecinos semanticos con prefiltrado de acceso, resuelto por pgvector.

    No hay parametro de nivel de acceso: el cliente no declara a que
    tiene derecho, se deriva de la base.
    """
    usuario_id = identidad(x_usuario_id)

    with sesion_bd(usuario_id) as (cur, _):
        nivel = nivel_de_acceso(cur)
        cur.execute(
            """
            SELECT
                v.contenido_id,
                v.titulo,
                v.seccion,
                v.nivel_acceso,
                ROUND((1 - (e.embedding <=> base.embedding))::NUMERIC, 6) AS similitud
            FROM recomendacion.embeddings_contenido AS base
            JOIN recomendacion.embeddings_contenido AS e
                ON e.contenido_id <> base.contenido_id
            JOIN catalogo.vw_contenidos_publicables AS v
                ON v.contenido_id = e.contenido_id
            WHERE base.contenido_id = %s
              AND v.nivel_acceso <= %s
            ORDER BY e.embedding <=> base.embedding
            LIMIT %s;
            """,
            (contenido_id, nivel, limite),
        )
        filas = cur.fetchall()

    if not filas:
        raise HTTPException(
            status_code=404,
            detail=f"Sin vecinos accesibles para el contenido {contenido_id}",
        )

    return [
        Recomendacion(
            contenido_id=fila[0], titulo=fila[1], seccion=fila[2], nivel_acceso=fila[3],
            score=float(fila[4]),
            explicacion=f"Trata de temas parecidos al contenido {contenido_id}",
        )
        for fila in filas
    ]


@app.get("/recomendaciones/{usuario_id}", response_model=Respuesta)
def recomendaciones(
    usuario_id: int,
    estrategia: ESTRATEGIAS = "hibrido",
    limite: int = Query(10, ge=1, le=50),
    x_usuario_id: str | None = Header(default=None),
):
    """Devuelve recomendaciones resolviendo cada estrategia en su motor.

    El `usuario_id` de la ruta identifica el recurso, no autoriza: si no
    coincide con la identidad de la cabecera, se rechaza con 403. Tomarlo
    de la ruta sin mas permitiria leer el feed de cualquier persona.
    """
    identidad_real = identidad(x_usuario_id)
    if identidad_real is None:
        raise HTTPException(
            status_code=401,
            detail="Falta la cabecera X-Usuario-Id (simula el token de sesion)",
        )
    if identidad_real != usuario_id:
        raise HTTPException(
            status_code=403,
            detail="La identidad de la sesion no coincide con el usuario solicitado",
        )

    with sesion_bd(usuario_id) as (cur, _):
        nivel = nivel_de_acceso(cur)

        # El RLS ya limita personas.usuarios a la propia fila del usuario:
        # si no devuelve nada, el usuario no existe o esta inactivo.
        cur.execute(
            "SELECT consentimiento_personalizacion FROM personas.usuarios WHERE activo;"
        )
        fila = cur.fetchone()
        if fila is None:
            raise HTTPException(status_code=404,
                                detail=f"Usuario {usuario_id} inexistente o inactivo")
        consentimiento = bool(fila[0])

        if estrategia in ("hibrido", "popularidad"):
            motor = "redis"
            clave = (f"rec:usuario:{usuario_id}:top" if estrategia == "hibrido"
                     else "rec:trending:global")
            elementos = _redis.zrevrange(clave, 0, (limite * 4) - 1, withscores=True)
            estrategia_efectiva = estrategia
            if not elementos and estrategia == "hibrido":
                # Cold start: sin feed precalculado se cae a popularidad.
                # Es la razon por la que la estrategia de popularidad no se
                # apaga aunque tenga el CTR mas bajo.
                elementos = _redis.zrevrange("rec:trending:global", 0, (limite * 4) - 1,
                                             withscores=True)
                estrategia_efectiva = "popularidad (respaldo por cold start)"
            candidatos = [(int(c), float(s)) for c, s in elementos]
            explicacion = "Feed precalculado por la estrategia hibrida"

        elif estrategia == "contenido_similar":
            motor = "pgvector"
            estrategia_efectiva = estrategia
            explicacion = "Cercano a tu perfil de lectura"
            if not consentimiento:
                raise HTTPException(
                    status_code=403,
                    detail="El usuario no dio consentimiento para personalizacion",
                )
            cur.execute(
                """
                SELECT
                    v.contenido_id,
                    ROUND((1 - (e.embedding <=> p.embedding))::NUMERIC, 6) AS afinidad
                FROM recomendacion.perfiles_usuario AS p
                JOIN recomendacion.embeddings_contenido AS e
                    ON TRUE
                JOIN catalogo.vw_contenidos_publicables AS v
                    ON v.contenido_id = e.contenido_id
                WHERE p.usuario_id = %s
                  AND v.nivel_acceso <= %s
                  AND NOT EXISTS (
                        SELECT 1 FROM recomendacion.vw_vetos_usuario AS w
                        WHERE w.usuario_id = p.usuario_id
                          AND w.contenido_id = v.contenido_id
                  )
                ORDER BY e.embedding <=> p.embedding
                LIMIT %s;
                """,
                (usuario_id, nivel, limite),
            )
            candidatos = [(fila[0], float(fila[1])) for fila in cur.fetchall()]

        elif estrategia == "colaborativo_item":
            motor = "duckdb (capa Gold)"
            estrategia_efectiva = estrategia
            explicacion = "Lo consume la misma gente que lo que vos leiste"
            cur.execute(
                """
                WITH historial AS (
                    SELECT DISTINCT contenido_id
                    FROM recomendacion.impresiones
                    WHERE clic
                )
                SELECT
                    r.contenido_similar_id,
                    ROUND(SUM(r.score)::NUMERIC, 6) AS score
                FROM recomendacion.ranking_items_similares AS r
                JOIN historial AS h
                    ON h.contenido_id = r.contenido_id
                JOIN catalogo.vw_contenidos_publicables AS v
                    ON v.contenido_id = r.contenido_similar_id
                WHERE r.origen = 'coocurrencia'
                  AND v.nivel_acceso <= %s
                  AND r.contenido_similar_id NOT IN (SELECT contenido_id FROM historial)
                GROUP BY r.contenido_similar_id
                ORDER BY score DESC
                LIMIT %s;
                """,
                (nivel, limite),
            )
            # El historial sale de recomendacion.impresiones SIN filtrar por
            # usuario: no hace falta, porque el RLS ya limita esa tabla a las
            # filas del usuario de la sesion. Es la demostracion mas directa
            # de que la barrera esta en el motor.
            candidatos = [(fila[0], float(fila[1])) for fila in cur.fetchall()]

        else:  # grafo_covisualizacion
            motor = "neo4j"
            estrategia_efectiva = estrategia
            explicacion = "Otros lectores con intereses parecidos tambien lo leyeron"
            with _neo4j.session() as sesion:
                resultado = sesion.run(
                    """
                    MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(:Contenido)
                          <-[:VIO]-(otro:Usuario)-[:VIO]->(rec:Contenido)
                    WHERE rec.estado = 'publicado'
                      AND rec.nivel_acceso <= $nivel
                      AND otro <> u
                      AND NOT EXISTS { (u)-[:VIO]->(rec) }
                    RETURN rec.contenido_id AS contenido_id,
                           count(DISTINCT otro) * 1.0 AS score
                    ORDER BY score DESC
                    LIMIT $limite
                    """,
                    usuario=usuario_id, nivel=nivel, limite=limite,
                ).data()
            candidatos = [(fila["contenido_id"], float(fila["score"])) for fila in resultado]

        contenidos = resolver_contenidos(cur, [c for c, _ in candidatos], nivel)

    return Respuesta(
        usuario_id=usuario_id,
        estrategia=estrategia_efectiva,
        motor=motor,
        nivel_acceso=nivel,
        recomendaciones=armar(candidatos, contenidos, explicacion)[:limite],
    )


@app.post("/impresiones")
def registrar_impresion(
    impresion: ImpresionNueva,
    x_usuario_id: str | None = Header(default=None),
):
    """Registra lo que se le mostro al usuario: cierra el circuito de datos.

    Sin este registro no hay CTR, no hay experimento A/B y no hay forma de
    saber si el recomendador sirve.

    El usuario sale de la cabecera, no del cuerpo. Y aunque alguien
    modificara este codigo para aceptarlo del cuerpo, la politica
    `impresiones_api_insert` de db/seguridad/02_row_level_security.sql
    rechazaria la fila: WITH CHECK exige que usuario_id coincida con
    app.usuario_id.
    """
    usuario_id = identidad(x_usuario_id)
    if usuario_id is None:
        raise HTTPException(
            status_code=401,
            detail="Falta la cabecera X-Usuario-Id (simula el token de sesion)",
        )

    with sesion_bd(usuario_id) as (cur, _):
        cur.execute(
            "SELECT id FROM recomendacion.estrategias WHERE codigo = %s AND activa;",
            (impresion.estrategia,),
        )
        fila = cur.fetchone()
        if fila is None:
            raise HTTPException(status_code=400,
                                detail=f"Estrategia desconocida: {impresion.estrategia}")

        try:
            cur.execute(
                """
                INSERT INTO recomendacion.impresiones (
                    usuario_id, contenido_id, estrategia_id, posicion, score,
                    superficie, mostrado_en, clic, clic_en
                )
                VALUES (%s, %s, %s, %s, %s, %s, CURRENT_TIMESTAMP, %s,
                        CASE WHEN %s THEN CURRENT_TIMESTAMP END)
                RETURNING id, mostrado_en;
                """,
                (usuario_id, impresion.contenido_id, fila[0], impresion.posicion,
                 impresion.score, impresion.superficie, impresion.clic, impresion.clic),
            )
        except psycopg2.errors.InsufficientPrivilege as error:
            raise HTTPException(status_code=403, detail=str(error))

        identificador, mostrado_en = cur.fetchone()

    return {"id": identificador, "mostrado_en": mostrado_en.isoformat(), "registrada": True}
