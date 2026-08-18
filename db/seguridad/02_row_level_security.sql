-- Objetivo: aislar los datos por usuario final dentro de una base compartida, con politicas de fila.
-- Requiere / entradas: roles creados por 01_roles_y_permisos.sql y funciones de contexto de 01_crear_schemas_y_extensiones.sql.
-- Produce / modifica: politicas RLS sobre cinco tablas; no modifica datos.
-- Resultado esperado: un lector solo ve contenido publicado y accesible a su plan, y solo sus propias filas.
-- Guia: la prueba de que esto funciona esta en db/consultas/05_prueba_aislamiento.sql.

-- ============================================================
-- Como funciona el aislamiento en este sistema
--
-- La aplicacion NO abre una conexion por usuario final: usa un pool
-- con un unico rol de base de datos (bdia_api) y, al abrir la
-- transaccion, declara quien esta operando:
--
--     SELECT set_config('app.usuario_id', '123', TRUE);
--
-- El tercer argumento es TRUE (local a la transaccion) y no FALSE
-- (local a la sesion). Con un pool, FALSE deja el valor pegado a la
-- conexion: la proxima peticion que la reutilice heredaria la identidad
-- del usuario anterior. Es una fuga silenciosa y dificil de reproducir.
--
-- Las politicas leen ese valor con personas.usuario_actual(). Si la
-- variable no esta seteada la funcion devuelve NULL, las comparaciones
-- dan NULL, y NULL no es TRUE: no se ve nada. El default es negar.
--
-- FORCE ROW LEVEL SECURITY se agrega para que las politicas apliquen
-- tambien al dueno de la tabla. Un superusuario las sigue salteando
-- siempre; por eso los roles de aplicacion no son superusuarios.
-- ============================================================

-- ============================================================
-- 1. catalogo.contenidos
--
-- Tres politicas permisivas, que se combinan con OR:
--
--   lectura_publica  -> lo que cualquiera puede ver segun su plan
--   editor_propios   -> el editor ademas ve y edita lo suyo, en
--                       cualquier estado (incluidos sus borradores)
--   moderador_total  -> el moderador ve todo, porque revisar lo que
--                       todavia no se publico es su tarea
--
-- Esta es la barrera que impide la fuga que analiza el informe: que el
-- recomendador ofrezca un borrador o una nota premium a un usuario free.
-- Al estar en el motor, protege por igual al feed, a la busqueda
-- vectorial y a cualquier consulta futura que nadie recuerde filtrar.
-- ============================================================

ALTER TABLE catalogo.contenidos ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalogo.contenidos FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contenidos_lectura_publica ON catalogo.contenidos;
CREATE POLICY contenidos_lectura_publica ON catalogo.contenidos
    FOR SELECT
    TO bdia_lector, bdia_editor, bdia_moderador, bdia_api
    USING (
        estado = 'publicado'
        AND fecha_publicacion <= CURRENT_TIMESTAMP
        AND (vigente_hasta IS NULL OR vigente_hasta > CURRENT_TIMESTAMP)
        AND nivel_acceso <= personas.nivel_acceso_actual()
    );

DROP POLICY IF EXISTS contenidos_editor_propios ON catalogo.contenidos;
CREATE POLICY contenidos_editor_propios ON catalogo.contenidos
    FOR ALL
    TO bdia_editor
    USING (autor_id = personas.usuario_actual())
    WITH CHECK (autor_id = personas.usuario_actual());

DROP POLICY IF EXISTS contenidos_moderador_total ON catalogo.contenidos;
CREATE POLICY contenidos_moderador_total ON catalogo.contenidos
    FOR SELECT
    TO bdia_moderador
    USING (TRUE);

DROP POLICY IF EXISTS contenidos_admin_total ON catalogo.contenidos;
CREATE POLICY contenidos_admin_total ON catalogo.contenidos
    FOR ALL
    TO bdia_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================
-- 2. personas.preferencias_usuario
--
-- WITH CHECK ademas de USING: sin el, un usuario podria leer solo sus
-- preferencias pero INSERTAR una preferencia a nombre de otro.
-- USING gobierna lo que se lee, WITH CHECK lo que se escribe.
-- ============================================================

ALTER TABLE personas.preferencias_usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.preferencias_usuario FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS preferencias_propias ON personas.preferencias_usuario;
CREATE POLICY preferencias_propias ON personas.preferencias_usuario
    FOR ALL
    TO bdia_lector, bdia_editor, bdia_moderador, bdia_api
    USING (usuario_id = personas.usuario_actual())
    WITH CHECK (usuario_id = personas.usuario_actual());

DROP POLICY IF EXISTS preferencias_admin ON personas.preferencias_usuario;
CREATE POLICY preferencias_admin ON personas.preferencias_usuario
    FOR ALL
    TO bdia_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================
-- 3. recomendacion.impresiones
--
-- El historial de recomendaciones es un dato de comportamiento: revela
-- que lee cada persona. La politica sobre la tabla particionada se
-- propaga sola a todas las particiones, presentes y futuras.
-- ============================================================

ALTER TABLE recomendacion.impresiones ENABLE ROW LEVEL SECURITY;
ALTER TABLE recomendacion.impresiones FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS impresiones_propias ON recomendacion.impresiones;
CREATE POLICY impresiones_propias ON recomendacion.impresiones
    FOR SELECT
    TO bdia_lector, bdia_editor, bdia_moderador, bdia_api
    USING (usuario_id = personas.usuario_actual());

-- ============================================================
-- La API solo puede registrar impresiones A NOMBRE DEL USUARIO DECLARADO
--
-- Es la barrera que convierte "el servicio podria registrar actividad de
-- cualquiera" en un error del motor.
--
-- Sin ella, bastaria con que el endpoint POST /impresiones aceptara el
-- usuario_id del cuerpo del pedido para que cualquiera registrara
-- actividad ajena. La aplicacion puede validarlo, pero esa validacion
-- vive en el codigo: un refactor la pierde sin que nada falle.
--
-- WITH CHECK sin USING: gobierna lo que se escribe, no lo que se lee
-- (para leer ya esta impresiones_propias).
-- ============================================================

DROP POLICY IF EXISTS impresiones_api_insert ON recomendacion.impresiones;
CREATE POLICY impresiones_api_insert ON recomendacion.impresiones
    FOR INSERT
    TO bdia_api
    WITH CHECK (usuario_id = personas.usuario_actual());

DROP POLICY IF EXISTS impresiones_admin ON recomendacion.impresiones;
CREATE POLICY impresiones_admin ON recomendacion.impresiones
    FOR ALL
    TO bdia_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================
-- 3.b recomendacion.perfiles_usuario
--
-- El perfil vectorial es el centroide de todo lo que la persona
-- consumio: son sus intereses INFERIDOS, comprimidos en 384 numeros.
-- Es tan sensible como el historial que lo produjo, y en cierto sentido
-- mas: el historial hay que interpretarlo, el centroide ya es la
-- interpretacion.
--
-- Sin esta politica, el rol de la API leeria los perfiles de TODOS los
-- usuarios. Los endpoints filtran por usuario_id, asi que la fuga no
-- seria alcanzable desde afuera, pero la barrera volveria a estar en el
-- codigo en lugar del motor.
--
-- La regla, que vale para cualquier tabla que se agregue: otorgar SELECT
-- no alcanza; hay que preguntarse ademas QUE FILAS de esa tabla le
-- corresponden a quien consulta.
-- ============================================================

ALTER TABLE recomendacion.perfiles_usuario ENABLE ROW LEVEL SECURITY;
ALTER TABLE recomendacion.perfiles_usuario FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS perfiles_propios ON recomendacion.perfiles_usuario;
CREATE POLICY perfiles_propios ON recomendacion.perfiles_usuario
    FOR SELECT
    TO bdia_lector, bdia_editor, bdia_moderador, bdia_api
    USING (usuario_id = personas.usuario_actual());

DROP POLICY IF EXISTS perfiles_admin ON recomendacion.perfiles_usuario;
CREATE POLICY perfiles_admin ON recomendacion.perfiles_usuario
    FOR ALL
    TO bdia_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================
-- 4. personas.usuarios
--
-- Un lector solo se ve a si mismo, y la API tambien: es la fila del
-- usuario declarado en app.usuario_id.
--
-- El analista no aparece en ninguna politica porque no tiene ningun
-- GRANT sobre esta tabla, ni siquiera por columna. Una politica de fila
-- para el seria letra muerta: el permiso se corta antes.
-- ============================================================

ALTER TABLE personas.usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE personas.usuarios FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS usuarios_propio ON personas.usuarios;
CREATE POLICY usuarios_propio ON personas.usuarios
    FOR SELECT
    TO bdia_lector, bdia_editor, bdia_moderador, bdia_api
    USING (id = personas.usuario_actual());

-- El analista NO tiene ninguna politica sobre esta tabla, y es a proposito:
-- tampoco tiene GRANT, ni siquiera por columna. Su unico camino hacia los
-- datos de personas es personas.vw_usuarios_anonimizado, que devuelve
-- seudonimo, pais y tramo etario. Ver la nota del punto 6 de
-- db/seguridad/01_roles_y_permisos.sql.

DROP POLICY IF EXISTS usuarios_admin ON personas.usuarios;
CREATE POLICY usuarios_admin ON personas.usuarios
    FOR ALL
    TO bdia_admin
    USING (TRUE)
    WITH CHECK (TRUE);

-- ============================================================
-- 5. Verificacion
-- ============================================================

SELECT
    n.nspname AS esquema,
    c.relname AS tabla,
    c.relrowsecurity AS rls_activo,
    c.relforcerowsecurity AS rls_forzado,
    COUNT(p.polname) AS politicas
FROM pg_class AS c
JOIN pg_namespace AS n
    ON n.oid = c.relnamespace
LEFT JOIN pg_policy AS p
    ON p.polrelid = c.oid
WHERE c.relrowsecurity
GROUP BY n.nspname, c.relname, c.relrowsecurity, c.relforcerowsecurity
ORDER BY n.nspname, c.relname;
