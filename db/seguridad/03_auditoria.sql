-- Objetivo: dejar traza inalterable de todo cambio sobre las tablas sensibles del modelo.
-- Requiere / entradas: tablas de auditoria creadas por db/estructura/07_auditoria.sql.
-- Produce / modifica: funcion de trigger, triggers sobre cuatro tablas y los REVOKE que hacen la traza append-only.
-- Resultado esperado: un UPDATE sobre catalogo.contenidos inserta una fila en auditoria.eventos; un DELETE sobre esa fila falla.
-- Guia: la auditoria no sirve de nada si quien altera el dato puede tambien borrar la evidencia.

-- ============================================================
-- 1. Funcion generica de auditoria
--
-- Una sola funcion para todas las tablas. Usa TG_TABLE_SCHEMA,
-- TG_TABLE_NAME y TG_OP, que PostgreSQL provee en cada disparo, y
-- serializa las filas con to_jsonb(). Eso permite auditar una tabla
-- nueva agregando un trigger, sin escribir una linea de codigo.
--
-- SECURITY DEFINER es indispensable: los roles de aplicacion NO tienen
-- INSERT sobre auditoria.eventos (justamente para que no puedan
-- fabricar traza falsa). El trigger corre con los privilegios del
-- dueno de la funcion y logra insertar igual.
--
-- En UPDATE se guardan las dos versiones de la fila. Guardar solo la
-- nueva convertiria la auditoria en un log de estados sin capacidad de
-- responder "que decia antes", que suele ser la pregunta que importa.
-- ============================================================

CREATE OR REPLACE FUNCTION auditoria.fn_auditar()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = auditoria, pg_temp
AS $$
DECLARE
    fila_anterior JSONB;
    fila_nueva    JSONB;
    identificador TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        fila_nueva := to_jsonb(NEW);
    ELSIF TG_OP = 'UPDATE' THEN
        fila_anterior := to_jsonb(OLD);
        fila_nueva    := to_jsonb(NEW);
    ELSE
        fila_anterior := to_jsonb(OLD);
    END IF;

    identificador := COALESCE(fila_nueva ->> 'id', fila_anterior ->> 'id');

    INSERT INTO auditoria.eventos (
        usuario_bd, usuario_app, accion, esquema, tabla,
        registro_id, datos_anteriores, datos_nuevos
    )
    VALUES (
        CURRENT_USER,
        NULLIF(current_setting('app.usuario_id', TRUE), '')::BIGINT,
        TG_OP,
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        identificador,
        fila_anterior,
        fila_nueva
    );

    -- Un trigger AFTER ignora el valor de retorno, pero devolverlo
    -- mantiene la funcion utilizable tambien como BEFORE.
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

-- ============================================================
-- 2. Triggers
--
-- Se auditan las tablas donde un cambio no declarado tiene consecuencias:
--
--   catalogo.contenidos          -> publicar o despublicar una nota
--   catalogo.moderaciones        -> decisiones de moderacion
--   personas.usuarios            -> alta, baja y cambios de identidad
--   personas.suscripciones       -> cambios de nivel de acceso
--
-- NO se auditan las impresiones: son cientos de miles de INSERT y la
-- traza pesaria mas que el dato auditado, sin agregar informacion que
-- la propia tabla no tenga ya.
-- ============================================================

DROP TRIGGER IF EXISTS tg_auditar_contenidos ON catalogo.contenidos;
CREATE TRIGGER tg_auditar_contenidos
    AFTER INSERT OR UPDATE OR DELETE ON catalogo.contenidos
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();

DROP TRIGGER IF EXISTS tg_auditar_moderaciones ON catalogo.moderaciones;
CREATE TRIGGER tg_auditar_moderaciones
    AFTER INSERT OR UPDATE OR DELETE ON catalogo.moderaciones
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();

DROP TRIGGER IF EXISTS tg_auditar_usuarios ON personas.usuarios;
CREATE TRIGGER tg_auditar_usuarios
    AFTER INSERT OR UPDATE OR DELETE ON personas.usuarios
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();

DROP TRIGGER IF EXISTS tg_auditar_suscripciones ON personas.suscripciones;
CREATE TRIGGER tg_auditar_suscripciones
    AFTER INSERT OR UPDATE OR DELETE ON personas.suscripciones
    FOR EACH ROW EXECUTE FUNCTION auditoria.fn_auditar();

-- ============================================================
-- 3. La traza es append-only
--
-- Nadie, salvo el dueno de la base, puede modificar ni borrar un evento
-- de auditoria. El INSERT tampoco se otorga: entra solo por la funcion
-- SECURITY DEFINER del trigger, asi que no se puede fabricar traza.
--
-- Nota honesta sobre el alcance: un superusuario sigue pudiendo borrar
-- la tabla. Una traza realmente inmutable exige sacarla del alcance del
-- DBA (replica append-only, WORM, firma). Aca se implementa la barrera
-- que corresponde a la capa de datos y se documenta el limite.
-- ============================================================

REVOKE ALL ON auditoria.eventos FROM PUBLIC;
REVOKE ALL ON auditoria.accesos_sensibles FROM PUBLIC;

REVOKE UPDATE, DELETE, TRUNCATE ON auditoria.eventos
    FROM bdia_lector, bdia_editor, bdia_moderador, bdia_analista, bdia_admin;
REVOKE UPDATE, DELETE, TRUNCATE ON auditoria.accesos_sensibles
    FROM bdia_lector, bdia_editor, bdia_moderador, bdia_analista, bdia_admin;

GRANT USAGE ON SCHEMA auditoria TO bdia_admin;
GRANT SELECT ON auditoria.eventos, auditoria.accesos_sensibles TO bdia_admin;

-- La aplicacion si necesita poder registrar accesos de lectura, porque
-- eso no lo puede hacer un trigger (PostgreSQL no dispara triggers en SELECT).
GRANT INSERT ON auditoria.accesos_sensibles TO bdia_admin;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA auditoria TO bdia_admin;

-- ============================================================
-- 4. Verificacion
-- ============================================================

SELECT
    n.nspname AS esquema,
    c.relname AS tabla,
    t.tgname  AS trigger
FROM pg_trigger AS t
JOIN pg_class AS c
    ON c.oid = t.tgrelid
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
WHERE NOT t.tgisinternal
  AND t.tgname LIKE 'tg_auditar_%'
ORDER BY n.nspname, c.relname;
