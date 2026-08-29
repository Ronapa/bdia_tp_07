-- Objetivo: demostrar que el aislamiento por Row Level Security funciona de verdad.
-- Requiere / entradas: roles y politicas de db/seguridad/, y datos cargados.
-- Produce / modifica: escribe en auditoria.eventos por el trigger; no modifica datos de negocio.
-- Resultado esperado: cada rol ve exactamente lo suyo; los bloques marcados DEBEN FALLAR.
-- Guia: ejecutar bloque por bloque desde pgAdmin conectado como bdia_user (superusuario).
-- Seguridad: usa SET ROLE para cambiar de identidad sin abrir conexiones nuevas.

-- ============================================================
-- IMPORTANTE
--
-- Varios bloques de este archivo DEBEN fallar. Ese es el objetivo:
-- una barrera de seguridad que nunca se prueba es una barrera que nadie
-- sabe si existe.
--
-- La prueba se hace con SET ROLE. Un superusuario ignora siempre el RLS,
-- asi que mientras la sesion sea bdia_user no se ve ninguna restriccion;
-- recien al asumir un rol de aplicacion aparecen las politicas.
-- ============================================================

-- ============================================================
-- 1. Linea de base: lo que ve el superusuario
-- ============================================================

SELECT
    COUNT(*) AS contenidos_totales,
    COUNT(*) FILTER (WHERE estado = 'publicado') AS publicados,
    COUNT(*) FILTER (WHERE estado = 'borrador') AS borradores,
    COUNT(*) FILTER (WHERE nivel_acceso = 2) AS premium
FROM catalogo.contenidos;

-- ============================================================
-- 2. Un lector con plan gratuito
--
-- Se elige un usuario cuyo plan sea 'gratuito' (nivel de acceso 0).
-- No deberia ver ningun borrador ni ningun contenido premium.
-- ============================================================

SELECT u.id AS usuario_gratuito
FROM personas.usuarios AS u
JOIN personas.suscripciones AS s
    ON s.usuario_id = u.id AND s.estado = 'activa'
JOIN personas.planes AS p
    ON p.id = s.plan_id
WHERE p.codigo = 'gratuito'
ORDER BY u.id
LIMIT 1;

-- Con la semilla 42 y escala media, el primer usuario gratuito es el 12.
-- Reemplazar por el id devuelto arriba si difiere.
SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '12', FALSE);

SELECT
    COUNT(*) AS contenidos_visibles,
    COUNT(*) FILTER (WHERE estado <> 'publicado') AS no_publicados_visibles,
    COUNT(*) FILTER (WHERE nivel_acceso > 0) AS por_encima_de_su_plan,
    personas.nivel_acceso_actual() AS nivel_detectado
FROM catalogo.contenidos;

-- no_publicados_visibles y por_encima_de_su_plan TIENEN que dar cero.
-- Si alguna diera distinto de cero, el recomendador podria filtrar
-- contenido no autorizado a traves de cualquier consulta del sistema.

-- Sus impresiones: solo las propias.
SELECT
    COUNT(*) AS impresiones_visibles,
    COUNT(DISTINCT usuario_id) AS usuarios_distintos_visibles
FROM recomendacion.impresiones;

-- usuarios_distintos_visibles tiene que ser 1 (o 0 si no tiene ninguna).

RESET ROLE;

-- ============================================================
-- 3. El mismo rol, sin declarar quien es
--
-- Si la aplicacion olvida el set_config, personas.usuario_actual()
-- devuelve NULL y personas.nivel_acceso_actual() devuelve 0. El efecto
-- es distinto segun la tabla, y la diferencia es intencional:
--
--   Datos personales (impresiones, preferencias): la politica compara
--   contra usuario_actual(); NULL = NULL da NULL, y NULL no es TRUE.
--   No se ve NADA.
--
--   Catalogo: la politica compara nivel_acceso <= 0, asi que la sesion
--   queda tratada como un visitante anonimo y ve solo el contenido
--   publicado de acceso libre.
--
-- En los dos casos el default es el MENOR privilegio posible. Un olvido
-- de la aplicacion degrada a usuario anonimo; nunca escala privilegios.
-- ============================================================

SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '', FALSE);

SELECT
    personas.usuario_actual() AS usuario_detectado,
    personas.nivel_acceso_actual() AS nivel_detectado,
    (SELECT COUNT(*) FROM recomendacion.impresiones) AS impresiones_visibles;

RESET ROLE;

-- ============================================================
-- 4. Un lector premium
--
-- Debe ver los contenidos de nivel 0, 1 y 2, y seguir sin ver borradores.
-- ============================================================

SELECT u.id AS usuario_premium
FROM personas.usuarios AS u
JOIN personas.suscripciones AS s
    ON s.usuario_id = u.id AND s.estado = 'activa'
JOIN personas.planes AS p
    ON p.id = s.plan_id
WHERE p.codigo = 'premium'
ORDER BY u.id
LIMIT 1;

-- Con la semilla 42, el primer usuario premium es el 2.
SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '2', FALSE);

SELECT
    personas.nivel_acceso_actual() AS nivel_detectado,
    COUNT(*) AS contenidos_visibles,
    COUNT(*) FILTER (WHERE nivel_acceso = 2) AS premium_visibles,
    COUNT(*) FILTER (WHERE estado <> 'publicado') AS no_publicados_visibles
FROM catalogo.contenidos;

RESET ROLE;

-- ============================================================
-- 5. Un editor ve sus propios borradores
--
-- La politica contenidos_editor_propios se suma (OR) a la de lectura
-- publica: el editor ve lo publicado como cualquiera, MAS lo suyo en
-- cualquier estado.
-- ============================================================

SET ROLE bdia_editor;
SELECT set_config('app.usuario_id', '1', FALSE);

SELECT
    COUNT(*) AS contenidos_visibles,
    COUNT(*) FILTER (WHERE autor_id = 1) AS propios,
    COUNT(*) FILTER (WHERE autor_id = 1 AND estado = 'borrador') AS borradores_propios,
    COUNT(*) FILTER (WHERE autor_id <> 1 AND estado = 'borrador') AS borradores_ajenos
FROM catalogo.contenidos;

-- borradores_ajenos TIENE que ser cero.

RESET ROLE;

-- ============================================================
-- 6. El moderador ve todo
-- ============================================================

SET ROLE bdia_moderador;
SELECT set_config('app.usuario_id', '31', FALSE);

SELECT
    COUNT(*) AS contenidos_visibles,
    COUNT(*) FILTER (WHERE estado = 'borrador') AS borradores_visibles
FROM catalogo.contenidos;

RESET ROLE;

-- ============================================================
-- 7. El analista y los permisos por columna
--
-- El analista puede leer id, alias y pais de personas.usuarios, y nada
-- mas. RLS decide QUE FILAS; el grant por columna decide QUE COLUMNAS.
-- ============================================================

SET ROLE bdia_analista;

-- Caso valido: solo las columnas permitidas.
SELECT id, alias, pais
FROM personas.usuarios
ORDER BY id
LIMIT 3;

-- La vista anonimizada, que es el camino previsto para el analista.
SELECT seudonimo, pais, tramo_etario, plan
FROM personas.vw_usuarios_anonimizado
ORDER BY seudonimo
LIMIT 5;

RESET ROLE;

-- ============================================================
-- 8. Bloques que DEBEN fallar
--
-- Ejecutar cada uno por separado. El error es el resultado esperado.
-- ============================================================

SET ROLE bdia_analista;

-- 8.1 SELECT * sobre usuarios.
-- Error esperado: permission denied for column email_hash
-- Observar que NO devuelve las columnas permitidas en silencio: falla.
SELECT * FROM personas.usuarios LIMIT 1;

RESET ROLE;

SET ROLE bdia_analista;

-- 8.2 Leer el correo cifrado.
-- Error esperado: permission denied for column email_cifrado
SELECT id, email_cifrado FROM personas.usuarios LIMIT 1;

RESET ROLE;

SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '12', FALSE);

-- 8.3 Escribir una preferencia a nombre de otro usuario.
-- Error esperado: new row violates row-level security policy
-- Es la clausula WITH CHECK: sin ella el usuario podria leer solo lo
-- suyo y escribir sobre cualquiera.
INSERT INTO personas.preferencias_usuario (usuario_id, seccion_id, tipo_preferencia, peso)
VALUES (99, 1, 'sigue', 1.0);

RESET ROLE;

SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '12', FALSE);

-- 8.4 Leer la tabla de suscripciones, que el lector no tiene otorgada.
-- Error esperado: permission denied for table suscripciones
-- Observar el contraste: personas.nivel_acceso_actual() SI puede leerla,
-- porque es SECURITY DEFINER y devuelve un entero, no las filas.
SELECT * FROM personas.suscripciones LIMIT 1;

RESET ROLE;

SET ROLE bdia_editor;
SELECT set_config('app.usuario_id', '1', FALSE);

-- 8.5 Publicar una nota a nombre de otro autor.
-- Error esperado: new row violates row-level security policy
INSERT INTO catalogo.contenidos (
    titulo, tipo_contenido_id, seccion_id, autor_id, estado, fecha_publicacion
)
VALUES ('Nota firmada por otro', 1, 1, 2, 'publicado', CURRENT_TIMESTAMP);

RESET ROLE;

-- ============================================================
-- 9. Caso valido de contraste
--
-- El mismo INSERT, con el autor correcto, funciona.
-- ============================================================

SET ROLE bdia_editor;
SELECT set_config('app.usuario_id', '1', FALSE);

INSERT INTO catalogo.contenidos (
    titulo, bajada, tipo_contenido_id, seccion_id, autor_id, estado, nivel_acceso
)
VALUES ('Borrador de prueba de aislamiento', 'Se borra al final del script.',
        1, 1, 1, 'borrador', 0)
RETURNING id, titulo, estado, autor_id;

RESET ROLE;

-- Limpieza de la prueba.
DELETE FROM catalogo.contenidos WHERE titulo = 'Borrador de prueba de aislamiento';

-- ============================================================
-- 10. La auditoria registro todo
--
-- El INSERT y el DELETE de arriba dejaron su traza, con el usuario de
-- aplicacion incluido.
-- ============================================================

SELECT
    ocurrido_en,
    usuario_bd,
    usuario_app,
    accion,
    esquema || '.' || tabla AS objeto,
    datos_nuevos ->> 'titulo' AS titulo_nuevo,
    datos_anteriores ->> 'titulo' AS titulo_anterior
FROM auditoria.eventos
WHERE tabla = 'contenidos'
ORDER BY ocurrido_en DESC
LIMIT 5;
