"""Aplica db/estructura/ en orden sobre PostgreSQL y verifica las invariantes
que el informe (docs/informe.md, §5 y §7) promete sobre el modelo relacional:
los 6 schemas, la PK compuesta de impresiones, los CHECK de dominio y que
ninguna FK use ON DELETE CASCADE.

No requiere datos cargados: valida solo el DDL. Se puede correr contra un
volumen ya inicializado o contra uno recién creado por docker compose.

Uso: python orquestador/validar_modelo_relacional.py
"""

import os
import sys
from pathlib import Path

import psycopg2
from dotenv import load_dotenv

RAIZ = Path(__file__).resolve().parent.parent
ESTRUCTURA = RAIZ / "db" / "estructura"

ESQUEMAS_ESPERADOS = {
    "personas",
    "catalogo",
    "recomendacion",
    "analitica",
    "auditoria",
    "control",
}


def conectar():
    load_dotenv(RAIZ / ".env")
    return psycopg2.connect(
        host="localhost",
        port=os.environ["POSTGRES_PORT"],
        dbname=os.environ["POSTGRES_DB"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
    )


def aplicar_estructura(conexion):
    archivos = sorted(ESTRUCTURA.glob("*.sql"))
    if not archivos:
        raise SystemExit(f"No se encontraron .sql en {ESTRUCTURA}")

    with conexion:
        with conexion.cursor() as cursor:
            for archivo in archivos:
                print(f"  -> {archivo.relative_to(RAIZ)}")
                cursor.execute(archivo.read_text(encoding="utf-8"))
    print(f"Los {len(archivos)} scripts corrieron sin error.")


def verificar_schemas(cursor, fallas):
    cursor.execute(
        """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name = ANY(%s)
        """,
        (list(ESQUEMAS_ESPERADOS),),
    )
    encontrados = {fila[0] for fila in cursor.fetchall()}
    faltantes = ESQUEMAS_ESPERADOS - encontrados
    if faltantes:
        print(f"FALLA  faltan schemas: {sorted(faltantes)}", file=sys.stderr)
        fallas.append("schemas")
    else:
        print("OK  6 schemas presentes (personas, catalogo, recomendacion, "
              "analitica, auditoria, control)")


def verificar_pk_impresiones(cursor, fallas):
    cursor.execute(
        """
        SELECT a.attname
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = 'recomendacion.impresiones'::regclass
          AND i.indisprimary
        ORDER BY a.attnum
        """
    )
    columnas = [fila[0] for fila in cursor.fetchall()]
    if columnas == ["id", "mostrado_en"]:
        print("OK  PK compuesta (id, mostrado_en) en recomendacion.impresiones")
    else:
        print(f"FALLA  PK de impresiones esperada [id, mostrado_en], "
              f"encontrada {columnas}", file=sys.stderr)
        fallas.append("pk_impresiones")


def verificar_check(cursor, fallas, patron_sql, minimo, descripcion, clave):
    cursor.execute(
        "SELECT count(*) FROM pg_constraint WHERE pg_get_constraintdef(oid) ILIKE %s",
        (patron_sql,),
    )
    cantidad = cursor.fetchone()[0]
    if cantidad >= minimo:
        print(f"OK  {descripcion}")
    else:
        print(f"FALLA  se esperaban al menos {minimo} CHECK de {descripcion}, "
              f"se encontraron {cantidad}", file=sys.stderr)
        fallas.append(clave)


def verificar_sin_cascade(cursor, fallas):
    cursor.execute("SELECT count(*) FROM pg_constraint WHERE confdeltype = 'c'")
    cantidad = cursor.fetchone()[0]
    if cantidad == 0:
        print("OK  ninguna FK usa ON DELETE CASCADE")
    else:
        print(f"FALLA  se encontraron {cantidad} FK con ON DELETE CASCADE "
              f"(no debería haber ninguna)", file=sys.stderr)
        fallas.append("cascade")


def main():
    conexion = conectar()
    try:
        print("--- Aplicando db/estructura/ en orden ---")
        aplicar_estructura(conexion)

        print()
        print("--- Verificando invariantes del informe ---")
        fallas = []
        with conexion.cursor() as cursor:
            verificar_schemas(cursor, fallas)
            verificar_pk_impresiones(cursor, fallas)
            verificar_check(
                cursor, fallas, "%nivel_acceso >= 0%", 2,
                "CHECK de nivel_acceso 0-2 (planes y contenidos)", "nivel_acceso",
            )
            verificar_check(
                cursor, fallas, "%seccion_id%etiqueta_id%", 1,
                "CHECK sección XOR etiqueta en preferencias_usuario", "xor_preferencia",
            )
            verificar_sin_cascade(cursor, fallas)

        print()
        if fallas:
            print(f"{len(fallas)} verificación(es) fallaron: {fallas}", file=sys.stderr)
            sys.exit(1)
        print("Todas las verificaciones pasaron. El modelo relacional coincide "
              "con lo que describe el informe.")
    finally:
        conexion.close()


if __name__ == "__main__":
    main()
