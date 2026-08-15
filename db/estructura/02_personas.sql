-- Objetivo: modelar la identidad de los usuarios, sus roles y su nivel de acceso al catalogo.
-- Requiere / entradas: schemas y extensiones creados por 01_crear_schemas_y_extensiones.sql.
-- Produce / modifica: tablas del schema personas; no carga filas.
-- Resultado esperado: seis tablas creadas con sus restricciones de dominio.
-- Guia: es la raiz del modelo; ninguna tabla de aca referencia otros schemas.

-- ============================================================
-- Tabla: personas.roles
--
-- Roles funcionales del sistema, no roles de PostgreSQL.
-- El mapeo entre unos y otros se define en
-- db/seguridad/01_roles_y_permisos.sql.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.roles (
    id          SERIAL PRIMARY KEY,
    codigo      TEXT UNIQUE NOT NULL,
    nombre      TEXT NOT NULL,
    descripcion TEXT
);

-- ============================================================
-- Tabla: personas.planes
--
-- nivel_acceso ordena los planes: un contenido con nivel_acceso = 2
-- solo puede ser visto por un usuario cuyo plan tenga nivel >= 2.
-- Modelarlo como entero ordinal y no como texto permite escribir la
-- regla de negocio como una comparacion, tanto en las consultas como
-- en las politicas de Row Level Security.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.planes (
    id           SERIAL PRIMARY KEY,
    codigo       TEXT UNIQUE NOT NULL,
    nombre       TEXT NOT NULL,
    nivel_acceso INTEGER NOT NULL CHECK (nivel_acceso BETWEEN 0 AND 2)
);

-- ============================================================
-- Tabla: personas.usuarios
--
-- Dato sensible: el correo electronico.
-- Se guarda dos veces y nunca en claro:
--   email_hash    -> HMAC estable, permite buscar y garantizar unicidad
--   email_cifrado -> pgp_sym_encrypt, solo lo descifra quien tiene la clave
--
-- consentimiento_personalizacion gobierna si el usuario puede entrar
-- al perfil vectorial y a las recomendaciones personalizadas; sin el,
-- el sistema solo puede ofrecer contenido popular o contextual.
--
-- seudonimo es el identificador estable y no reversible con el que la
-- persona aparece en la capa analitica. Se PERSISTE en vez de calcularse
-- al vuelo, por una sutileza de PostgreSQL: una vista sin
-- security_invoker corre con los privilegios de su dueno, pero eso elude
-- los permisos de TABLA, no los de FUNCION. Como personas.seudonimo()
-- tiene revocado el EXECUTE a PUBLIC, una vista que la invocara fallaria
-- con "permission denied for function" justamente para el analista, que
-- es quien tiene que poder consultarla.
--
-- Persistirlo resuelve ademas un problema de costo: la capa analitica
-- deja de pagar un HMAC por fila en cada consulta.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.usuarios (
    id                             BIGSERIAL PRIMARY KEY,
    email_hash                     TEXT UNIQUE NOT NULL,
    email_cifrado                  BYTEA NOT NULL,
    seudonimo                      TEXT UNIQUE,
    alias                          TEXT NOT NULL,
    pais                           TEXT NOT NULL,
    anio_nacimiento                INTEGER CHECK (anio_nacimiento BETWEEN 1920 AND 2012),
    consentimiento_personalizacion BOOLEAN NOT NULL DEFAULT FALSE,
    activo                         BOOLEAN NOT NULL DEFAULT TRUE,
    fecha_alta                     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Tabla: personas.usuarios_roles
--
-- Resuelve la relacion muchos a muchos entre usuarios y roles.
--
-- Un usuario puede tener varios roles (un editor tambien lee).
-- Un rol lo tienen muchos usuarios.
--
-- Relacion:
-- usuarios N:M roles
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.usuarios_roles (
    usuario_id  BIGINT NOT NULL REFERENCES personas.usuarios(id),
    rol_id      INTEGER NOT NULL REFERENCES personas.roles(id),
    otorgado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    otorgado_por BIGINT REFERENCES personas.usuarios(id),

    PRIMARY KEY (usuario_id, rol_id)
);

-- ============================================================
-- Tabla: personas.suscripciones
--
-- Historico de suscripciones: no se pisa la fila al cambiar de plan,
-- se cierra la anterior con `hasta` y se abre una nueva. Eso permite
-- responder "que nivel de acceso tenia este usuario en marzo", que es
-- lo que necesita el analisis de conversion.
--
-- El indice unico parcial de 01_indices.sql garantiza que no haya dos
-- suscripciones activas simultaneas para el mismo usuario.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.suscripciones (
    id         BIGSERIAL PRIMARY KEY,
    usuario_id BIGINT NOT NULL REFERENCES personas.usuarios(id),
    plan_id    INTEGER NOT NULL REFERENCES personas.planes(id),
    desde      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    hasta      TIMESTAMPTZ,
    estado     TEXT NOT NULL DEFAULT 'activa'
               CHECK (estado IN ('activa', 'vencida', 'cancelada')),

    -- PostgreSQL solo admite funciones inmutables en un CHECK, asi que la
    -- coherencia contra "ahora" (una suscripcion activa no puede estar vencida)
    -- se controla en la consulta de calidad de db/consultas/00_verificar_carga.sql.
    CHECK (hasta IS NULL OR hasta > desde)
);

-- ============================================================
-- Tabla: personas.consentimientos
--
-- Registro de gobierno de datos: que finalidad acepto cada usuario y
-- cuando. Es append-only por diseno; revocar un consentimiento inserta
-- una fila nueva con otorgado = FALSE en vez de actualizar la anterior.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.consentimientos (
    id          BIGSERIAL PRIMARY KEY,
    usuario_id  BIGINT NOT NULL REFERENCES personas.usuarios(id),
    finalidad   TEXT NOT NULL
                CHECK (finalidad IN ('personalizacion', 'analitica', 'comunicaciones')),
    otorgado    BOOLEAN NOT NULL,
    registrado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Funcion: personas.nivel_acceso_actual()
--
-- Nivel de acceso vigente del usuario de la sesion:
-- 0 = anonimo, 1 = registrado, 2 = premium.
--
-- Se define aca y no en 01_crear_schemas_y_extensiones.sql porque una
-- funcion LANGUAGE sql valida su cuerpo al momento de crearse, y esta
-- consulta suscripciones y planes.
--
-- SECURITY DEFINER a proposito: el rol lector NO tiene permiso de
-- lectura sobre personas.suscripciones. La funcion es el unico camino
-- por el que su nivel de acceso llega a las politicas de RLS, y devuelve
-- un entero, no las filas.
--
-- Sin suscripcion activa el usuario queda en nivel 0 aunque este
-- registrado: el default vuelve a ser el mas restrictivo.
-- ============================================================

CREATE OR REPLACE FUNCTION personas.nivel_acceso_actual()
RETURNS INTEGER
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, pg_temp
AS $$
    SELECT COALESCE(MAX(p.nivel_acceso), 0)
    FROM personas.suscripciones AS s
    JOIN personas.planes AS p
        ON p.id = s.plan_id
    WHERE s.usuario_id = personas.usuario_actual()
      AND s.estado = 'activa'
      AND s.desde <= CURRENT_TIMESTAMP
      AND (s.hasta IS NULL OR s.hasta > CURRENT_TIMESTAMP);
$$;
