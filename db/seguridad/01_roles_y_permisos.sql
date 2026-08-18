-- Objetivo: crear los roles de PostgreSQL del sistema y otorgarles el minimo privilegio que necesitan.
-- Requiere / entradas: todas las tablas y vistas creadas por db/estructura/ y db/indices_vistas/.
-- Produce / modifica: seis roles de login y sus GRANT; no modifica datos.
-- Resultado esperado: los seis roles listados al final, cada uno con acceso solo a lo suyo.
-- Guia: los roles NO son superusuarios ni duenos de las tablas, porque si lo fueran saltearian el RLS.
-- Seguridad: las contrasenas son didacticas y solo sirven en el entorno local de la practica.

-- ============================================================
-- 1. Roles
--
-- Los cinco roles funcionales del caso de uso, mas el rol tecnico con el
-- que se conecta la API, se materializan como roles de PostgreSQL.
--
-- Es deliberado que ninguno sea SUPERUSER ni dueno de las tablas: un
-- superusuario ignora siempre las politicas de Row Level Security, con
-- lo cual la demostracion del aislamiento seria falsa.
--
-- No existe CREATE ROLE IF NOT EXISTS, asi que el script se hace
-- idempotente consultando pg_roles.
-- ============================================================

DO $$
DECLARE
    rol           TEXT;
    contrasena    TEXT;
    definiciones  TEXT[][] := ARRAY[
        ['bdia_lector',    'lector_local'],
        ['bdia_editor',    'editor_local'],
        ['bdia_moderador', 'moderador_local'],
        ['bdia_analista',  'analista_local'],
        ['bdia_admin',     'admin_local'],
        ['bdia_api',       'api_local']
    ];
    i INTEGER;
BEGIN
    FOR i IN 1 .. array_length(definiciones, 1) LOOP
        rol        := definiciones[i][1];
        contrasena := definiciones[i][2];

        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = rol) THEN
            EXECUTE format('CREATE ROLE %I LOGIN PASSWORD %L', rol, contrasena);
            RAISE NOTICE 'Rol creado: %', rol;
        ELSE
            RAISE NOTICE 'Rol ya existente: %', rol;
        END IF;
    END LOOP;
END;
$$;

-- ============================================================
-- 2. Acceso a los schemas
--
-- USAGE sobre el schema es condicion necesaria pero no suficiente:
-- habilita a nombrar los objetos, no a leerlos.
-- ============================================================

GRANT USAGE ON SCHEMA personas, catalogo, recomendacion
    TO bdia_lector, bdia_editor, bdia_moderador;

GRANT USAGE ON SCHEMA analitica, personas, catalogo, recomendacion
    TO bdia_analista;

GRANT USAGE ON SCHEMA personas, catalogo, recomendacion, analitica, auditoria, control
    TO bdia_admin;

GRANT USAGE ON SCHEMA personas, catalogo, recomendacion, analitica
    TO bdia_api;

-- ============================================================
-- 3. Rol lector (usuario final del portal)
--
-- Lee el catalogo (filtrado por RLS) y administra sus propias
-- preferencias. No ve la tabla de usuarios, ni las moderaciones,
-- ni las versiones editoriales.
-- ============================================================

GRANT SELECT ON catalogo.contenidos,
                catalogo.secciones,
                catalogo.etiquetas,
                catalogo.tipos_contenido,
                catalogo.contenidos_etiquetas
    TO bdia_lector;

GRANT SELECT ON catalogo.vw_contenidos_publicables,
                catalogo.vw_arbol_secciones
    TO bdia_lector;

GRANT SELECT, INSERT, UPDATE, DELETE ON personas.preferencias_usuario TO bdia_lector;
GRANT SELECT ON recomendacion.impresiones TO bdia_lector;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA personas TO bdia_lector;

-- ============================================================
-- 4. Rol editor
--
-- Todo lo del lector, mas la escritura de sus propios contenidos.
-- El RLS de 02_row_level_security.sql limita ese "sus propios".
-- ============================================================

GRANT bdia_lector TO bdia_editor;

GRANT SELECT, INSERT, UPDATE ON catalogo.contenidos TO bdia_editor;
GRANT SELECT, INSERT, DELETE ON catalogo.contenidos_etiquetas TO bdia_editor;
GRANT SELECT, INSERT ON catalogo.versiones_contenido TO bdia_editor;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA catalogo TO bdia_editor;

-- ============================================================
-- 5. Rol moderador
--
-- Ve todo el catalogo, incluidos borradores y despublicados, porque
-- justamente su trabajo es revisar lo que todavia no se publico.
-- Puede registrar acciones de moderacion pero no editar el contenido.
-- ============================================================

GRANT bdia_lector TO bdia_moderador;

GRANT SELECT ON catalogo.contenidos TO bdia_moderador;
GRANT SELECT, INSERT ON catalogo.moderaciones TO bdia_moderador;
GRANT SELECT ON catalogo.versiones_contenido TO bdia_moderador;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA catalogo TO bdia_moderador;

-- ============================================================
-- 6. Rol analista
--
-- Trabaja sobre la capa Gold, que ya nace sin datos personales.
--
-- IMPORTANTE: el analista NO tiene ningun acceso a personas.usuarios,
-- ni siquiera por columna.
--
-- Un GRANT SELECT (id, alias, pais) pareceria suficiente, porque deja
-- afuera el correo y la edad. No lo es: `alias` es el nombre real de la
-- persona y, con el id a la vista, alcanzaria con ejecutar
-- personas.seudonimo(id) para construir la tabla de correspondencias
-- seudonimo -> persona. Eso no debilita la anonimizacion de la capa
-- analitica: la anula por completo.
--
-- El unico camino del analista hacia los datos de personas es la vista
-- personas.vw_usuarios_anonimizado (db/seguridad/04_vistas_anonimizadas.sql),
-- que devuelve seudonimo, pais y tramo etario, y nada mas.
-- ============================================================

GRANT SELECT ON ALL TABLES IN SCHEMA analitica TO bdia_analista;
GRANT SELECT ON recomendacion.vw_rendimiento_estrategias TO bdia_analista;
GRANT SELECT ON catalogo.secciones, catalogo.tipos_contenido TO bdia_analista;

REVOKE ALL ON personas.usuarios FROM bdia_analista;

-- ============================================================
-- 6.b Permisos a nivel de columna
--
-- El mecanismo sigue siendo parte del temario (Clase 7) y se demuestra,
-- pero sobre una tabla SIN datos personales: el analista puede leer el
-- codigo y el motor de cada estrategia, y no su descripcion interna.
--
-- Es el complemento del RLS: RLS decide QUE FILAS, el grant por columna
-- decide QUE COLUMNAS. Un SELECT * sobre esa tabla falla con
-- "permission denied for column"; no devuelve las permitidas en silencio.
-- ============================================================

REVOKE ALL ON recomendacion.estrategias FROM bdia_analista;
GRANT SELECT (id, codigo, version, motor, activa) ON recomendacion.estrategias
    TO bdia_analista;

-- ============================================================
-- 7. Rol de la aplicacion (API de recomendacion)
--
-- Es el rol con el que se conecta el servicio api-recomendador.
--
-- Por que existe: hasta que se creo, la API se conectaba con el dueno de
-- la base, que es superusuario y por lo tanto IGNORA el Row Level
-- Security. Toda la barrera de aislamiento quedaba entonces en manos del
-- codigo de la aplicacion, que es exactamente lo que el RLS existe para
-- evitar. Con bdia_api, un endpoint que se olvide de filtrar no filtra
-- de mas: el motor lo corta igual.
--
-- El rol NO recibe acceso a personas.suscripciones ni personas.planes.
-- El nivel de acceso del usuario llega por personas.nivel_acceso_actual(),
-- que es SECURITY DEFINER y devuelve un entero, no las filas. Asi el
-- servicio no puede enumerar quien tiene que plan.
--
-- Tampoco recibe acceso a auditoria ni a control.
-- ============================================================

GRANT SELECT ON catalogo.contenidos,
                catalogo.secciones,
                catalogo.etiquetas,
                catalogo.tipos_contenido,
                catalogo.contenidos_etiquetas
    TO bdia_api;

GRANT SELECT ON catalogo.vw_contenidos_publicables,
                catalogo.vw_arbol_secciones,
                recomendacion.vw_vetos_usuario
    TO bdia_api;

GRANT SELECT ON recomendacion.embeddings_contenido,
                recomendacion.perfiles_usuario,
                recomendacion.ranking_items_similares,
                recomendacion.estrategias
    TO bdia_api;

GRANT SELECT ON analitica.agg_popularidad TO bdia_api;

-- Solo lectura de sus propias preferencias y de su propia fila de usuario;
-- el RLS de 02_row_level_security.sql define que "propias" significa las
-- del usuario declarado en app.usuario_id.
GRANT SELECT ON personas.preferencias_usuario TO bdia_api;
GRANT SELECT ON personas.usuarios TO bdia_api;

-- La unica escritura que necesita: registrar lo que efectivamente mostro.
GRANT SELECT, INSERT ON recomendacion.impresiones TO bdia_api;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA recomendacion TO bdia_api;

-- ============================================================
-- 8. Rol administrador
-- ============================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA
    personas, catalogo, recomendacion TO bdia_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA analitica, control TO bdia_admin;
GRANT SELECT ON ALL TABLES IN SCHEMA auditoria TO bdia_admin;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA personas, catalogo, recomendacion TO bdia_admin;

-- ============================================================
-- 9. Verificacion
-- ============================================================

-- Se listan por nombre exacto y no con LIKE 'bdia_%': el dueno de la
-- base tambien se llama bdia_user y ese si es superusuario.
SELECT
    r.rolname AS rol,
    r.rolsuper AS es_superusuario,
    r.rolcanlogin AS puede_conectarse
FROM pg_roles AS r
WHERE r.rolname IN ('bdia_lector', 'bdia_editor', 'bdia_moderador',
                    'bdia_analista', 'bdia_admin', 'bdia_api')
ORDER BY r.rolname;

-- Ningun rol de la aplicacion puede ser superusuario: si lo fuera,
-- el Row Level Security no se aplicaria y el aislamiento seria ficticio.
DO $$
DECLARE
    superusuarios INTEGER;
BEGIN
    SELECT COUNT(*) INTO superusuarios
    FROM pg_roles
    WHERE rolname IN ('bdia_lector', 'bdia_editor', 'bdia_moderador',
                      'bdia_analista', 'bdia_admin', 'bdia_api')
      AND rolsuper;

    IF superusuarios > 0 THEN
        RAISE EXCEPTION 'Hay % rol(es) de aplicacion con SUPERUSER; el RLS no se aplicaria.', superusuarios;
    END IF;
END;
$$;
