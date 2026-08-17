#!/usr/bin/env python3
"""Carga en PostgreSQL el dataset generado por generar_datos.py.

Usa dos mecanismos distintos segun el caso, y la diferencia es deliberada:

  COPY   para las tablas de volumen (contenidos, impresiones, versiones).
         Es un orden de magnitud mas rapido que INSERT fila por fila
         porque evita el parseo y el planeamiento por sentencia.

  INSERT para personas.usuarios, porque cada fila tiene que pasar por
         las funciones de pgcrypto: el correo NO se guarda en claro.
         COPY no puede aplicar funciones, asi que aca la seguridad
         manda sobre la velocidad.

La carga es transaccional: o entra todo o no entra nada. Una carga a
medias es peor que ninguna carga, porque deja el modelo en un estado
que ninguna verificacion contempla.

Uso:
    python cargar_postgres.py
    python cargar_postgres.py --origen /workspace/data/generado --reset

Variables de entorno:
    POSTGRES_HOST, POSTGRES_PORT, POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD
    CLAVE_CIFRADO_EMAIL   clave simetrica para pgp_sym_encrypt (default didactico)
    SAL_HASH_EMAIL        sal del HMAC que indexa el correo
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import os
from pathlib import Path

import psycopg2
from psycopg2.extras import execute_batch

CLAVE_CIFRADO = os.environ.get("CLAVE_CIFRADO_EMAIL", "nexomedia-clave-local")
SAL_HASH = os.environ.get("SAL_HASH_EMAIL", "nexomedia-sal-email")

# Orden de borrado: hijos antes que padres, para no violar las foraneas.
TABLAS_EN_ORDEN_INVERSO = [
    "recomendacion.ranking_items_similares",
    "recomendacion.impresiones",
    "recomendacion.asignaciones_ab",
    "recomendacion.perfiles_usuario",
    "recomendacion.embeddings_contenido",
    "catalogo.moderaciones",
    "catalogo.versiones_contenido",
    "catalogo.contenidos_etiquetas",
    "personas.preferencias_usuario",
    "catalogo.contenidos",
    "catalogo.etiquetas",
    "catalogo.secciones",
    "personas.consentimientos",
    "personas.suscripciones",
    "personas.usuarios_roles",
    "personas.usuarios",
    "personas.roles",
]


def conectar_bd():
    return psycopg2.connect(
        host=os.environ.get("POSTGRES_HOST", "localhost"),
        port=os.environ.get("POSTGRES_PORT", "5432"),
        dbname=os.environ.get("POSTGRES_DB", "bdia_nexomedia"),
        user=os.environ.get("POSTGRES_USER", "bdia_user"),
        password=os.environ.get("POSTGRES_PASSWORD", ""),
    )


def leer_csv(ruta: Path) -> list[dict]:
    if not ruta.exists():
        raise SystemExit(f"No se encontro {ruta}. Correr primero orquestador/generar_datos.py")
    with ruta.open(encoding="utf-8", newline="") as archivo:
        return list(csv.DictReader(archivo))


def nulo(valor: str):
    """Los CSV escriben el NULL como cadena vacia; aca se traduce de vuelta."""
    return None if valor is None or valor == "" else valor


def copiar(cur, tabla: str, columnas: list[str], filas: list[list]) -> None:
    """Carga masiva por COPY usando un buffer en memoria.

    Se serializa a CSV en memoria en vez de pasar por un archivo
    temporal: el dataset entra comodo en RAM y evita depender de que
    el contenedor tenga permisos de escritura en disco.
    """
    if not filas:
        return

    buffer = io.StringIO()
    escritor = csv.writer(buffer, quoting=csv.QUOTE_MINIMAL)
    for fila in filas:
        escritor.writerow(["" if v is None else v for v in fila])
    buffer.seek(0)

    sentencia = (
        f"COPY {tabla} ({', '.join(columnas)}) "
        "FROM STDIN WITH (FORMAT csv, NULL '')"
    )
    cur.copy_expert(sentencia, buffer)
    print(f"  {tabla:42s} {len(filas):>8d} filas")


def resetear(cur) -> None:
    print("--- Vaciando tablas (orden inverso a las foraneas) ---")
    for tabla in TABLAS_EN_ORDEN_INVERSO:
        cur.execute(f"TRUNCATE TABLE {tabla} CASCADE;")
    # La auditoria se vacia aparte: no es parte del modelo de negocio y,
    # si no se limpiara, acumularia la traza de todas las corridas previas.
    cur.execute("TRUNCATE TABLE auditoria.eventos RESTART IDENTITY;")
    cur.execute("TRUNCATE TABLE auditoria.accesos_sensibles RESTART IDENTITY;")


def mapear_por_codigo(cur, tabla: str) -> dict[str, int]:
    """Lee el mapa codigo -> id de un catalogo de referencia.

    Se resuelve contra la base y no se asume que SERIAL asigno 1, 2, 3:
    los datos de referencia se cargan con ON CONFLICT DO NOTHING y una
    segunda corrida podria dejar huecos en la secuencia.
    """
    cur.execute(f"SELECT codigo, id FROM {tabla};")
    return {codigo: identificador for codigo, identificador in cur.fetchall()}


def sincronizar_secuencias(cur) -> None:
    """Reposiciona las secuencias despues de cargar ids explicitos.

    El dataset trae ids propios para que las referencias cruzadas entre
    motores (MongoDB, Neo4j, Redis) sean estables. El precio es que las
    secuencias quedan atras: sin este paso, el primer INSERT que haga la
    aplicacion chocaria con una clave duplicada.
    """
    columnas_serial = [
        ("personas.roles", "id"),
        ("personas.usuarios", "id"),
        ("personas.suscripciones", "id"),
        ("personas.consentimientos", "id"),
        ("personas.preferencias_usuario", "id"),
        ("catalogo.secciones", "id"),
        ("catalogo.etiquetas", "id"),
        ("catalogo.contenidos", "id"),
        ("catalogo.versiones_contenido", "id"),
        ("catalogo.moderaciones", "id"),
    ]
    for tabla, columna in columnas_serial:
        cur.execute(
            f"""
            SELECT setval(
                pg_get_serial_sequence('{tabla}', '{columna}'),
                COALESCE((SELECT MAX({columna}) FROM {tabla}), 1),
                TRUE
            );
            """
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--origen", type=Path, default=Path("/workspace/data/generado"),
                        help="Directorio con los CSV generados.")
    parser.add_argument("--reset", action="store_true", default=True,
                        help="Vacia las tablas antes de cargar (activo por defecto).")
    argumentos = parser.parse_args()

    origen = argumentos.origen / "postgres"
    resumen = json.loads((argumentos.origen / "resumen.json").read_text(encoding="utf-8"))

    conexion = conectar_bd()
    conexion.autocommit = False
    cur = conexion.cursor()

    try:
        if argumentos.reset:
            resetear(cur)

        print("--- Cargando PostgreSQL ---")

        # 1. Roles
        roles = leer_csv(origen / "roles.csv")
        copiar(cur, "personas.roles", ["id", "codigo", "nombre", "descripcion"],
               [[r["id"], r["codigo"], r["nombre"], r["descripcion"]] for r in roles])

        # 2. Usuarios: uno por uno, porque el correo pasa por pgcrypto.
        #    ENCODE(HMAC(...)) permite buscar y garantizar unicidad sin
        #    guardar el dato; PGP_SYM_ENCRYPT permite recuperarlo cuando
        #    hace falta, y solo con la clave.
        usuarios = leer_csv(origen / "usuarios.csv")
        execute_batch(
            cur,
            """
            INSERT INTO personas.usuarios (
                id, email_hash, email_cifrado, seudonimo, alias, pais,
                anio_nacimiento, consentimiento_personalizacion, activo, fecha_alta
            )
            VALUES (
                %s,
                ENCODE(HMAC(%s, %s, 'sha256'), 'hex'),
                PGP_SYM_ENCRYPT(%s, %s),
                personas.seudonimo(%s),
                %s, %s, %s, %s, %s, %s
            );
            """,
            [
                (
                    u["id"], u["email"], SAL_HASH, u["email"], CLAVE_CIFRADO,
                    u["id"],
                    u["alias"], u["pais"], u["anio_nacimiento"],
                    u["consentimiento_personalizacion"] == "true",
                    u["activo"] == "true", u["fecha_alta"],
                )
                for u in usuarios
            ],
            page_size=500,
        )
        print(f"  {'personas.usuarios':42s} {len(usuarios):>8d} filas (cifradas)")

        # 3. Usuarios-roles y consentimientos
        usuarios_roles = leer_csv(origen / "usuarios_roles.csv")
        copiar(cur, "personas.usuarios_roles",
               ["usuario_id", "rol_id", "otorgado_en", "otorgado_por"],
               [[r["usuario_id"], r["rol_id"], r["otorgado_en"], nulo(r["otorgado_por"])]
                for r in usuarios_roles])

        consentimientos = leer_csv(origen / "consentimientos.csv")
        copiar(cur, "personas.consentimientos",
               ["usuario_id", "finalidad", "otorgado", "registrado_en"],
               [[c["usuario_id"], c["finalidad"], c["otorgado"], c["registrado_en"]]
                for c in consentimientos])

        # 4. Suscripciones: el CSV trae el codigo del plan, no su id.
        planes = mapear_por_codigo(cur, "personas.planes")
        suscripciones = leer_csv(origen / "suscripciones.csv")
        copiar(cur, "personas.suscripciones",
               ["id", "usuario_id", "plan_id", "desde", "hasta", "estado"],
               [[s["id"], s["usuario_id"], planes[s["plan_codigo"]],
                 s["desde"], nulo(s["hasta"]), s["estado"]] for s in suscripciones])

        # 5. Taxonomia
        secciones = leer_csv(origen / "secciones.csv")
        copiar(cur, "catalogo.secciones",
               ["id", "slug", "nombre", "seccion_padre_id", "activa"],
               [[s["id"], s["slug"], s["nombre"], nulo(s["seccion_padre_id"]), s["activa"]]
                for s in secciones])

        etiquetas = leer_csv(origen / "etiquetas.csv")
        copiar(cur, "catalogo.etiquetas", ["id", "slug", "nombre"],
               [[e["id"], e["slug"], e["nombre"]] for e in etiquetas])

        # 6. Contenidos
        tipos = mapear_por_codigo(cur, "catalogo.tipos_contenido")
        contenidos = leer_csv(origen / "contenidos.csv")
        copiar(cur, "catalogo.contenidos",
               ["id", "titulo", "bajada", "tipo_contenido_id", "seccion_id", "autor_id",
                "estado", "nivel_acceso", "idioma", "fecha_publicacion", "vigente_hasta",
                "duracion_seg", "cuerpo_ref", "metadatos", "creado_en", "actualizado_en"],
               [[c["id"], c["titulo"], c["bajada"], tipos[c["tipo_contenido_codigo"]],
                 c["seccion_id"], c["autor_id"], c["estado"], c["nivel_acceso"], c["idioma"],
                 nulo(c["fecha_publicacion"]), nulo(c["vigente_hasta"]), nulo(c["duracion_seg"]),
                 c["cuerpo_ref"], c["metadatos"], c["creado_en"], c["actualizado_en"]]
                for c in contenidos])

        contenidos_etiquetas = leer_csv(origen / "contenidos_etiquetas.csv")
        copiar(cur, "catalogo.contenidos_etiquetas",
               ["contenido_id", "etiqueta_id", "relevancia"],
               [[c["contenido_id"], c["etiqueta_id"], c["relevancia"]]
                for c in contenidos_etiquetas])

        versiones = leer_csv(origen / "versiones_contenido.csv")
        copiar(cur, "catalogo.versiones_contenido",
               ["id", "contenido_id", "numero_version", "editor_id", "cambios",
                "comentario", "creado_en"],
               [[v["id"], v["contenido_id"], v["numero_version"], v["editor_id"],
                 v["cambios"], v["comentario"], v["creado_en"]] for v in versiones])

        moderaciones = leer_csv(origen / "moderaciones.csv")
        copiar(cur, "catalogo.moderaciones",
               ["id", "objeto_tipo", "objeto_id", "contenido_id", "moderador_id",
                "accion", "motivo", "creado_en"],
               [[m["id"], m["objeto_tipo"], m["objeto_id"], nulo(m["contenido_id"]),
                 m["moderador_id"], m["accion"], m["motivo"], m["creado_en"]]
                for m in moderaciones])

        # 7. Preferencias declaradas
        preferencias = leer_csv(origen / "preferencias_usuario.csv")
        copiar(cur, "personas.preferencias_usuario",
               ["id", "usuario_id", "seccion_id", "etiqueta_id", "tipo_preferencia",
                "peso", "actualizado_en"],
               [[p["id"], p["usuario_id"], nulo(p["seccion_id"]), nulo(p["etiqueta_id"]),
                 p["tipo_preferencia"], p["peso"], p["actualizado_en"]] for p in preferencias])

        # 8. Experimento A/B e impresiones
        cur.execute("SELECT codigo, id FROM recomendacion.experimentos_ab;")
        experimentos = dict(cur.fetchall())
        asignaciones = leer_csv(origen / "asignaciones_ab.csv")
        copiar(cur, "recomendacion.asignaciones_ab",
               ["experimento_id", "usuario_id", "variante", "asignado_en"],
               [[experimentos[a["experimento_codigo"]], a["usuario_id"],
                 a["variante"], a["asignado_en"]] for a in asignaciones])

        cur.execute("SELECT codigo, id FROM recomendacion.estrategias WHERE version = '1.0';")
        estrategias = dict(cur.fetchall())
        impresiones = leer_csv(origen / "impresiones.csv")
        copiar(cur, "recomendacion.impresiones",
               ["usuario_id", "contenido_id", "estrategia_id", "posicion", "score",
                "variante_ab", "superficie", "mostrado_en", "clic", "clic_en"],
               [[i["usuario_id"], i["contenido_id"], estrategias[i["estrategia_codigo"]],
                 i["posicion"], i["score"], i["variante_ab"], i["superficie"],
                 i["mostrado_en"], i["clic"], nulo(i["clic_en"])] for i in impresiones])

        sincronizar_secuencias(cur)

        # 9. Control de cargas
        #
        # Se registra cuantas filas esperaba entregar el generador para
        # cada entidad. db/consultas/00_verificar_carga.sql compara esos
        # valores contra el COUNT(*) real y aborta si no coinciden.
        # De ese modo la verificacion no depende de constantes escritas
        # a mano en el SQL, sino del dataset que efectivamente se genero.
        entidades_postgres = {
            "personas.roles": "roles",
            "personas.usuarios": "usuarios",
            "personas.usuarios_roles": "usuarios_roles",
            "personas.suscripciones": "suscripciones",
            "personas.consentimientos": "consentimientos",
            "personas.preferencias_usuario": "preferencias_usuario",
            "catalogo.secciones": "secciones",
            "catalogo.etiquetas": "etiquetas",
            "catalogo.contenidos": "contenidos",
            "catalogo.contenidos_etiquetas": "contenidos_etiquetas",
            "catalogo.versiones_contenido": "versiones_contenido",
            "catalogo.moderaciones": "moderaciones",
            "recomendacion.asignaciones_ab": "asignaciones_ab",
            "recomendacion.impresiones": "impresiones",
        }
        cur.execute("DELETE FROM control.control_cargas WHERE lote_id = 'postgres_inicial';")
        execute_batch(
            cur,
            """
            INSERT INTO control.control_cargas (
                lote_id, entidad, filas_recibidas, filas_aceptadas,
                filas_rechazadas, estado
            )
            VALUES ('postgres_inicial', %s, %s, %s, 0, 'COMPLETADO');
            """,
            [
                (tabla, resumen["conteos"][clave], resumen["conteos"][clave])
                for tabla, clave in entidades_postgres.items()
            ],
        )

        # El trending se materializa recien ahora: antes de la carga la
        # vista no tenia nada que agregar.
        cur.execute("SELECT recomendacion.refrescar_trending();")

        # ANALYZE explicito: sin estadisticas frescas el planificador
        # subestima las tablas recien cargadas y elige Seq Scan incluso
        # donde el indice conviene. Es lo que hace comparable el EXPLAIN.
        cur.execute("ANALYZE;")

        conexion.commit()

    except Exception:
        conexion.rollback()
        raise
    finally:
        cur.close()
        conexion.close()

    print("\nCarga completa.")
    print(f"Conteos esperados del generador (semilla {resumen['semilla']}, "
          f"escala {resumen['escala']}):")
    for entidad, cantidad in sorted(resumen["conteos"].items()):
        print(f"  {entidad:28s} {cantidad:>8d}")


if __name__ == "__main__":
    main()
