-- Objetivo: crear los schemas y extensiones sobre los que se apoya toda la solucion de datos.
-- Requiere / entradas: base recien creada por la imagen pgvector/pgvector:pg17.
-- Produce / modifica: seis schemas, las extensiones vector y pgcrypto, y las funciones de contexto de sesion.
-- Resultado esperado: los seis schemas visibles en pgAdmin y `SELECT extname FROM pg_extension` con vector y pgcrypto.
-- Guia: separar por schema permite otorgar permisos por area de responsabilidad en lugar de tabla por tabla.

-- ============================================================
-- 1. Extensiones
--
-- vector    : tipo VECTOR y operadores de distancia para la
--             busqueda por similitud (Clase 6).
-- pgcrypto  : cifrado del correo electronico y hashing con sal
--             para poder buscar sin exponer el dato (Clase 7).
-- ============================================================

CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- 2. Schemas
--
-- personas      : identidad, roles, planes y preferencias.
-- catalogo      : contenidos publicables y su taxonomia.
-- recomendacion : estrategias, embeddings, impresiones y rankings.
-- analitica     : capa Gold cargada por DuckDB desde el lakehouse.
-- auditoria     : traza append-only de cambios y accesos sensibles.
-- control       : metadatos de las cargas del pipeline.
--
-- La separacion no es cosmetica: cada schema recibe un conjunto
-- distinto de permisos en db/seguridad/01_roles_y_permisos.sql.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS personas;
CREATE SCHEMA IF NOT EXISTS catalogo;
CREATE SCHEMA IF NOT EXISTS recomendacion;
CREATE SCHEMA IF NOT EXISTS analitica;
CREATE SCHEMA IF NOT EXISTS auditoria;
CREATE SCHEMA IF NOT EXISTS control;

-- ============================================================
-- 3. Contexto de sesion de la aplicacion
--
-- La aplicacion se conecta con un unico rol de base de datos y
-- declara que usuario final esta operando mediante:
--
--     SELECT set_config('app.usuario_id', '123', TRUE);
--
-- Las politicas de Row Level Security leen ese valor a traves de
-- personas.usuario_actual(). Si la variable no esta seteada, la
-- funcion devuelve NULL y las politicas no dejan ver nada: el
-- comportamiento por defecto es "no autorizado", no "todo visible".
-- ============================================================

CREATE OR REPLACE FUNCTION personas.usuario_actual()
RETURNS BIGINT
LANGUAGE sql
STABLE
AS $$
    SELECT NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT;
$$;

-- La segunda funcion de contexto, personas.nivel_acceso_actual(), se
-- define al final de 02_personas.sql: una funcion LANGUAGE sql valida
-- su cuerpo al crearse, y esa consulta las tablas de suscripciones y
-- planes, que todavia no existen en este punto.

-- Verificacion
SELECT n.nspname AS esquema, p.proname AS funcion
FROM pg_proc AS p
JOIN pg_namespace AS n
    ON n.oid = p.pronamespace
WHERE n.nspname = 'personas'
ORDER BY p.proname;
