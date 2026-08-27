#!/usr/bin/env python3
"""Calcula los embeddings del catalogo y el perfil vectorial de cada usuario.

Modelo: intfloat/multilingual-e5-small -> 384 dimensiones.

La dimension no es arbitraria: es la que produce ese modelo, y es la que
declara la columna VECTOR(384) en db/estructura/06_embeddings.sql. Los
embeddings de modelos distintos viven en espacios vectoriales distintos y
NO son comparables entre si; por eso cada fila guarda que modelo la genero.

Dos modos, controlados por EMBEDDINGS_MODO:

    modelo    (default) descarga y usa sentence-transformers.
    simulado  usa el truco de hashing: cada token se proyecta a una
              dimension por hash y el vector se normaliza. Produce un
              espacio vectorial pobre pero COHERENTE (dos textos que
              comparten palabras quedan cerca), asi que el pipeline
              corre entero sin descargar nada. Sirve para revisar la
              implementacion, no para evaluar la calidad del ranking.

Sobre el perfil de usuario: se calcula como el centroide de los embeddings
de los contenidos que la persona consumio, ponderado por el tipo de evento.
Solo se calcula para quienes dieron consentimiento_personalizacion; es una
regla de gobierno de datos y db/consultas/00_verificar_carga.sql la
verifica y aborta si se viola.

Uso:
    python generar_embeddings.py
    python generar_embeddings.py --modo simulado
    python generar_embeddings.py --lote 128 --minimo-eventos 5

Variables de entorno:
    POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
    MONGO_HOST, MONGO_PORT, MONGO_DATABASE, MONGO_INITDB_ROOT_USERNAME, MONGO_INITDB_ROOT_PASSWORD
    MODELO_EMBEDDING, EMBEDDINGS_MODO
"""
from __future__ import annotations

import argparse
import hashlib
import math
import os
import re
from collections import defaultdict

import psycopg2
from psycopg2.extras import execute_batch
from pymongo import MongoClient

MODELO_POR_DEFECTO = "intfloat/multilingual-e5-small"
DIMENSION = 384

# Peso de cada tipo de evento en el centroide del perfil. Un 'completado'
# dice mucho mas sobre el interes que una 'impresion', que ni siquiera
# implica que la persona haya mirado.
PESOS_EVENTO = {
    "completado": 3.0,
    "guardado": 3.0,
    "compartido": 2.5,
    "me_gusta": 2.5,
    "reproduccion": 2.0,
    "vista": 1.5,
    "scroll": 1.0,
    "clic": 1.0,
    "impresion": 0.0,
    "no_me_interesa": -2.0,
}


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


def formatear_vector(valores) -> str:
    """Serializa el vector al literal que entiende pgvector."""
    return "[" + ",".join(f"{v:.8f}" for v in valores) + "]"


def requiere_prefijo_e5(modelo_nombre: str) -> bool:
    """Los modelos de la familia E5 se entrenan para recuperacion asimetrica.

    Esperan el prefijo "query: " en la consulta y "passage: " en el texto
    indexado. Omitirlos degrada el ranking sin producir ningun error
    visible, que es la peor forma de equivocarse.
    """
    return "e5" in modelo_nombre.lower()


def prefijo_pasaje(modelo_nombre: str) -> str:
    return "passage: " if requiere_prefijo_e5(modelo_nombre) else ""


def prefijo_consulta(modelo_nombre: str) -> str:
    return "query: " if requiere_prefijo_e5(modelo_nombre) else ""


def texto_con_contexto(seccion: str, titulo: str, bajada: str, etiquetas: str) -> str:
    """Arma el texto que se vectoriza.

    Antepone la seccion y suma las etiquetas: es *contextual retrieval*.
    Un titulo suelto ("Las cifras que explican el escrutinio") es ambiguo
    fuera de contexto; con la seccion adelante, el vector cae en la zona
    correcta del espacio. Lo que se guarda en texto_fuente es exactamente
    esto, para poder reproducir y auditar cada embedding.
    """
    partes = [seccion, titulo]
    if bajada:
        partes.append(bajada)
    if etiquetas:
        partes.append(f"Temas: {etiquetas}")
    return ". ".join(partes)


def normalizar(vector: list[float]) -> list[float]:
    norma = math.sqrt(sum(v * v for v in vector))
    if norma == 0:
        return vector
    return [v / norma for v in vector]


def embedding_simulado(texto: str) -> list[float]:
    """Truco de hashing: proyecta cada token a una dimension por hash.

    No es un modelo de lenguaje ni pretende serlo. Lo unico que garantiza
    es que dos textos con vocabulario compartido queden cerca, que alcanza
    para que el pipeline y las consultas de similitud corran de punta a
    punta sin acceso a internet.
    """
    vector = [0.0] * DIMENSION
    tokens = re.findall(r"\w+", texto.lower())
    for token in tokens:
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        indice = int.from_bytes(digest[:4], "big") % DIMENSION
        signo = 1.0 if digest[4] % 2 == 0 else -1.0
        vector[indice] += signo
    return normalizar(vector)


class Codificador:
    """Envuelve las dos formas de producir vectores tras una misma interfaz."""

    def __init__(self, modo: str, modelo_nombre: str) -> None:
        self.modo = modo
        self.modelo_nombre = modelo_nombre
        self._modelo = None

        if modo == "modelo":
            from sentence_transformers import SentenceTransformer

            print(f"[embeddings] Cargando modelo: {modelo_nombre}", flush=True)
            self._modelo = SentenceTransformer(modelo_nombre)
            dimension = self._modelo.get_sentence_embedding_dimension()
            if dimension != DIMENSION:
                raise SystemExit(
                    f"El modelo {modelo_nombre} produce {dimension} dimensiones y el esquema "
                    f"declara VECTOR({DIMENSION}). Cambiar el modelo o migrar la columna."
                )
            print(f"[embeddings] Modelo listo (dimension {dimension})", flush=True)
        else:
            print(f"[embeddings] Modo simulado: vectores por hashing, dimension {DIMENSION}")

    @property
    def nombre_registrado(self) -> str:
        """Lo que se guarda en la columna modelo_embedding."""
        return self.modelo_nombre if self.modo == "modelo" else "simulado-hashing-384"

    def codificar(self, textos: list[str], tipo: str = "passage") -> list[list[float]]:
        if self.modo == "simulado":
            return [embedding_simulado(texto) for texto in textos]

        prefijo = (prefijo_pasaje(self.modelo_nombre) if tipo == "passage"
                   else prefijo_consulta(self.modelo_nombre))
        vectores = self._modelo.encode(
            [prefijo + texto for texto in textos], normalize_embeddings=True
        )
        return [vector.tolist() for vector in vectores]


def cargar_embeddings_contenido(cur, codificador: Codificador, tamano_lote: int) -> int:
    """Vectoriza el catalogo completo, incluidos los no publicados.

    Se vectorizan tambien los borradores y despublicados a proposito: el
    editor necesita buscar entre sus propios borradores. Lo que impide que
    esos vectores lleguen a un lector no es que falten, es el prefiltrado
    de la consulta y las politicas de RLS.
    """
    cur.execute(
        """
        SELECT
            c.id,
            s.nombre AS seccion,
            c.titulo,
            COALESCE(c.bajada, '') AS bajada,
            COALESCE(STRING_AGG(e.nombre, ', ' ORDER BY e.nombre), '') AS etiquetas
        FROM catalogo.contenidos AS c
        JOIN catalogo.secciones AS s
            ON s.id = c.seccion_id
        LEFT JOIN catalogo.contenidos_etiquetas AS ce
            ON ce.contenido_id = c.id
        LEFT JOIN catalogo.etiquetas AS e
            ON e.id = ce.etiqueta_id
        GROUP BY c.id, s.nombre, c.titulo, c.bajada
        ORDER BY c.id;
        """
    )
    filas = cur.fetchall()
    if not filas:
        raise SystemExit("No hay contenidos cargados. Correr primero cargar_postgres.py")

    cur.execute("TRUNCATE TABLE recomendacion.embeddings_contenido CASCADE;")

    total = 0
    for inicio in range(0, len(filas), tamano_lote):
        lote = filas[inicio:inicio + tamano_lote]
        textos = [texto_con_contexto(f[1], f[2], f[3], f[4]) for f in lote]
        vectores = codificador.codificar(textos, tipo="passage")

        execute_batch(
            cur,
            """
            INSERT INTO recomendacion.embeddings_contenido (
                contenido_id, embedding, modelo_embedding, texto_fuente
            )
            VALUES (%s, %s::vector, %s, %s);
            """,
            [
                (fila[0], formatear_vector(vector), codificador.nombre_registrado, texto)
                for fila, vector, texto in zip(lote, vectores, textos)
            ],
            page_size=200,
        )
        total += len(lote)
        print(f"  {total}/{len(filas)} contenidos vectorizados...")

    return total


def cargar_perfiles_usuario(cur, base_mongo, codificador: Codificador,
                            minimo_eventos: int) -> int:
    """Construye el perfil como centroide ponderado de lo consumido.

    Es una operacion entre motores: el comportamiento esta en MongoDB y
    los vectores en PostgreSQL. Se resuelve en la aplicacion porque
    ninguno de los dos puede consultar al otro; ese costo de integracion
    es exactamente el precio del enfoque poliglota, y esta declarado.

    El 'no_me_interesa' pesa negativo: aleja el centroide de lo que la
    persona rechazo, en vez de limitarse a no acercarlo.
    """
    cur.execute("TRUNCATE TABLE recomendacion.perfiles_usuario;")

    cur.execute(
        "SELECT id FROM personas.usuarios WHERE consentimiento_personalizacion ORDER BY id;"
    )
    con_consentimiento = {fila[0] for fila in cur.fetchall()}
    print(f"  Usuarios con consentimiento: {len(con_consentimiento)}")

    # Acumula el peso de cada par (usuario, contenido) desde el clickstream.
    pesos: dict[int, dict[int, float]] = defaultdict(lambda: defaultdict(float))
    cursor = base_mongo.eventos_interaccion.find(
        {"tipo_evento": {"$in": [t for t, p in PESOS_EVENTO.items() if p != 0]}},
        {"usuario_id": 1, "contenido_id": 1, "tipo_evento": 1, "_id": 0},
    )
    for evento in cursor:
        usuario = evento["usuario_id"]
        if usuario not in con_consentimiento:
            continue
        pesos[usuario][evento["contenido_id"]] += PESOS_EVENTO[evento["tipo_evento"]]

    # Trae los vectores del catalogo una sola vez.
    cur.execute(
        "SELECT contenido_id, embedding::text FROM recomendacion.embeddings_contenido;"
    )
    vectores_contenido = {
        contenido_id: [float(x) for x in texto.strip("[]").split(",")]
        for contenido_id, texto in cur.fetchall()
    }

    filas = []
    for usuario_id, consumos in pesos.items():
        utiles = {c: p for c, p in consumos.items()
                  if c in vectores_contenido and p != 0}
        if len(utiles) < minimo_eventos:
            # Cold start: con poco historial el centroide es ruido. Se deja
            # sin perfil a proposito para que el recomendador caiga a la
            # estrategia de popularidad, que es la respuesta correcta.
            continue

        acumulado = [0.0] * DIMENSION
        for contenido_id, peso in utiles.items():
            vector = vectores_contenido[contenido_id]
            for indice in range(DIMENSION):
                acumulado[indice] += vector[indice] * peso

        filas.append((
            usuario_id,
            formatear_vector(normalizar(acumulado)),
            codificador.nombre_registrado,
            len(utiles),
        ))

    execute_batch(
        cur,
        """
        INSERT INTO recomendacion.perfiles_usuario (
            usuario_id, embedding, modelo_embedding, cantidad_eventos
        )
        VALUES (%s, %s::vector, %s, %s);
        """,
        filas,
        page_size=200,
    )
    return len(filas)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--modo", choices=["modelo", "simulado"],
                        default=os.environ.get("EMBEDDINGS_MODO", "modelo"),
                        help="Como generar los vectores.")
    parser.add_argument("--modelo", default=os.environ.get("MODELO_EMBEDDING", MODELO_POR_DEFECTO),
                        help="Nombre del modelo de sentence-transformers.")
    parser.add_argument("--lote", type=int, default=64,
                        help="Cantidad de textos por lote de codificacion.")
    parser.add_argument("--minimo-eventos", type=int, default=4,
                        help="Eventos distintos minimos para construir un perfil de usuario.")
    argumentos = parser.parse_args()

    codificador = Codificador(argumentos.modo, argumentos.modelo)

    conexion = conectar_bd()
    conexion.autocommit = False
    cur = conexion.cursor()
    cliente_mongo = conectar_mongo()
    base_mongo = cliente_mongo[os.environ.get("MONGO_DATABASE", "bdia_nexomedia")]

    try:
        print("--- Vectorizando el catalogo ---")
        contenidos = cargar_embeddings_contenido(cur, codificador, argumentos.lote)

        print("--- Construyendo perfiles de usuario ---")
        perfiles = cargar_perfiles_usuario(
            cur, base_mongo, codificador, argumentos.minimo_eventos
        )

        cur.execute("ANALYZE recomendacion.embeddings_contenido;")
        cur.execute("ANALYZE recomendacion.perfiles_usuario;")
        conexion.commit()
    except Exception:
        conexion.rollback()
        raise
    finally:
        cur.close()
        conexion.close()
        cliente_mongo.close()

    print(f"\nEmbeddings de contenido : {contenidos}")
    print(f"Perfiles de usuario     : {perfiles}")
    print(f"Modelo registrado       : {codificador.nombre_registrado}")
    print("\nSiguiente paso: vectorial/01_crear_indices_vectoriales.sql")


if __name__ == "__main__":
    main()
