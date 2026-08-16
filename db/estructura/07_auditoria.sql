-- Objetivo: definir las tablas de trazabilidad sobre las que despues se montan los triggers de auditoria.
-- Requiere / entradas: schema auditoria creado por 01_crear_schemas_y_extensiones.sql.
-- Produce / modifica: tablas auditoria.eventos y auditoria.accesos_sensibles; no crea triggers.
-- Resultado esperado: dos tablas vacias listas para recibir la traza.
-- Guia: la estructura vive aca y el mecanismo (funcion, triggers y REVOKE) en db/seguridad/03_auditoria.sql.

-- ============================================================
-- Tabla: auditoria.eventos
--
-- Traza append-only de los cambios sobre las tablas sensibles.
--
-- Guarda la fila anterior y la nueva como JSONB en vez de una columna
-- por campo: una sola tabla sirve para todas las tablas auditadas y no
-- hay que migrarla cada vez que el modelo cambia. El costo es que no se
-- puede indexar por columna de negocio; se compensa con el indice GIN
-- y con los indices por (esquema, tabla, fecha).
--
-- usuario_bd  -> el rol de PostgreSQL que ejecuto la sentencia
-- usuario_app -> el usuario final declarado en app.usuario_id
--
-- Los dos, no uno: la aplicacion se conecta siempre con el mismo rol de
-- base, asi que usuario_bd solo dice "fue la app". Sin usuario_app la
-- traza no permite responder quien hizo el cambio.
-- ============================================================

CREATE TABLE IF NOT EXISTS auditoria.eventos (
    id               BIGSERIAL PRIMARY KEY,
    ocurrido_en      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    usuario_bd       TEXT NOT NULL DEFAULT CURRENT_USER,
    usuario_app      BIGINT,
    accion           TEXT NOT NULL CHECK (accion IN ('INSERT', 'UPDATE', 'DELETE')),
    esquema          TEXT NOT NULL,
    tabla            TEXT NOT NULL,
    registro_id      TEXT,
    datos_anteriores JSONB,
    datos_nuevos     JSONB,

    -- Un INSERT no tiene estado anterior y un DELETE no tiene estado nuevo.
    CHECK (accion <> 'INSERT' OR datos_anteriores IS NULL),
    CHECK (accion <> 'DELETE' OR datos_nuevos IS NULL)
);

-- ============================================================
-- Tabla: auditoria.accesos_sensibles
--
-- PostgreSQL no dispara triggers en un SELECT, asi que la lectura de
-- datos personales no se puede auditar con el mismo mecanismo que la
-- escritura. Esta tabla la escribe explicitamente la aplicacion cada
-- vez que descifra un correo o exporta datos de usuarios.
--
-- Se deja documentado el limite: la traza de lectura depende de que la
-- aplicacion la escriba. Auditarla a nivel motor requeriria pgaudit,
-- que queda fuera del alcance de esta implementacion.
-- ============================================================

CREATE TABLE IF NOT EXISTS auditoria.accesos_sensibles (
    id             BIGSERIAL PRIMARY KEY,
    ocurrido_en    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    usuario_bd     TEXT NOT NULL DEFAULT CURRENT_USER,
    usuario_app    BIGINT,
    recurso        TEXT NOT NULL,
    motivo         TEXT NOT NULL,
    filas_afectadas INTEGER NOT NULL DEFAULT 0 CHECK (filas_afectadas >= 0),
    origen_ip      INET
);
