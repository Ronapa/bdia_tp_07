-- Objetivo: demostrar que el rol con el que se conecta la API esta sujeto al mismo RLS que los demas.
-- Requiere / entradas: roles y politicas de db/seguridad/, y datos cargados.
-- Produce / modifica: nada (todo dentro de transacciones que se revierten).
-- Resultado esperado: la API solo ve y escribe lo del usuario declarado; los bloques marcados DEBEN fallar.
-- Guia: ejecutar bloque por bloque desde pgAdmin conectado como bdia_user (superusuario).
-- Seguridad: usa SET ROLE para asumir la identidad de bdia_api sin abrir conexiones nuevas.

-- ============================================================
-- Por que existe este archivo
--
-- db/consultas/05_prueba_aislamiento.sql prueba el RLS con los roles de
-- los usuarios finales. Este prueba el eslabon que faltaba: el rol
-- TECNICO con el que se conecta el servicio.
--
-- Es el que mas importa, porque es el unico que atiende trafico de
-- internet.
--
-- Si el servicio se conectara con el dueno de la base, que es
-- superusuario, el RLS quedaria anulado y todo el aislamiento dependeria
-- de que cada endpoint recordara filtrar: bastaria con que /trending se
-- olvidara del nivel de acceso para que un visitante anonimo recibiera
-- titulos de contenido premium.
--
-- Con bdia_api, que no es superusuario, las consultas del servicio siguen
-- filtrando (defensa en profundidad) y, si alguna se olvidara, el motor
-- la corta igual. Eso es lo que este archivo demuestra.
-- ============================================================



-- ============================================================
-- 1. El rol existe y NO es superusuario
--
-- Es la precondicion de todo lo demas: un superusuario ignora siempre
-- las politicas de RLS.
-- ============================================================

SELECT
    rolname AS rol,
    rolsuper AS es_superusuario,
    rolbypassrls AS puede_saltear_rls
FROM pg_roles
WHERE rolname = 'bdia_api';

-- Las dos ultimas columnas TIENEN que dar false.



-- ============================================================
-- 2. Que puede leer y que no
-- ============================================================

SELECT
    table_schema || '.' || table_name AS objeto,
    STRING_AGG(DISTINCT privilege_type, ', ' ORDER BY privilege_type) AS privilegios
FROM information_schema.role_table_grants
WHERE grantee = 'bdia_api'
GROUP BY table_schema, table_name
ORDER BY objeto;

-- Observar que NO aparecen: personas.suscripciones, personas.planes,
-- catalogo.moderaciones, catalogo.versiones_contenido, ni nada de
-- auditoria o control. La API no los necesita, asi que no los tiene.



-- ============================================================
-- 3. Sin identidad declarada: visitante anonimo
--
-- Es el estado en el que queda una peticion sin la cabecera
-- X-Usuario-Id. El default es el minimo privilegio, no el maximo.
-- ============================================================

BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '', TRUE);

SELECT
    personas.usuario_actual() AS usuario,
    personas.nivel_acceso_actual() AS nivel,
    (SELECT COUNT(*) FROM catalogo.contenidos) AS contenidos_visibles,
    (SELECT COUNT(*) FROM catalogo.contenidos WHERE nivel_acceso > 0) AS por_encima_del_nivel,
    (SELECT COUNT(*) FROM catalogo.contenidos WHERE estado <> 'publicado') AS no_publicados,
    (SELECT COUNT(*) FROM recomendacion.impresiones) AS impresiones_visibles;

ROLLBACK;

-- por_encima_del_nivel, no_publicados e impresiones_visibles TIENEN que
-- dar cero. contenidos_visibles es mayor que cero: un anonimo si puede
-- ver el contenido publicado de acceso libre, que es lo correcto.



-- ============================================================
-- 4. Con identidad: solo ve lo suyo
--
-- El usuario 2 es premium con la semilla 42. Cambiar el id si difiere.
-- ============================================================

BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);

SELECT
    personas.nivel_acceso_actual() AS nivel,
    (SELECT COUNT(*) FROM catalogo.contenidos WHERE estado <> 'publicado') AS no_publicados,
    (SELECT COUNT(DISTINCT usuario_id) FROM recomendacion.impresiones) AS usuarios_en_impresiones,
    (SELECT COUNT(*) FROM personas.usuarios) AS usuarios_visibles,
    (SELECT COUNT(*) FROM recomendacion.perfiles_usuario) AS perfiles_visibles;

ROLLBACK;

-- no_publicados TIENE que dar cero.
-- usuarios_en_impresiones TIENE que dar 1 (solo el propio).
-- usuarios_visibles TIENE que dar 1 (solo su propia fila).
-- perfiles_visibles TIENE que dar 1 (solo su propio perfil vectorial).
--
-- Ese ultimo control se agrego despues de encontrar la fuga: el rol tenia
-- SELECT sobre recomendacion.perfiles_usuario sin RLS y veia los 1.451
-- perfiles. Los endpoints filtraban, asi que desde afuera no se notaba.
-- El perfil vectorial es el centroide de todo lo que la persona consumio:
-- son sus intereses inferidos, y es tan sensible como el historial que lo
-- produjo.

-- ============================================================
-- 5. El contexto es local a la transaccion
--
-- Con set_config(..., TRUE) el valor muere con la transaccion. Es lo que
-- impide que, al devolver la conexion al pool, la peticion siguiente
-- herede la identidad de la anterior.
--
-- Con FALSE (local a la sesion) esta consulta devolveria 2, y eso seria
-- una fuga silenciosa y muy dificil de reproducir en produccion.
-- ============================================================

BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);
COMMIT;

SET ROLE bdia_api;
SELECT COALESCE(personas.usuario_actual()::TEXT, 'NULL') AS usuario_tras_el_commit;
RESET ROLE;

-- TIENE que devolver NULL.



-- ============================================================
-- 6. Bloques que DEBEN fallar
--
-- Ejecutar cada uno por separado. El error es el resultado esperado.
-- ============================================================

-- 6.1 Escribir una impresion a nombre de otro usuario.
-- Error esperado: new row violates row-level security policy for table "impresiones"
--
-- Es la prueba central. Aunque alguien modificara la API para aceptar el
-- usuario_id del cuerpo del pedido, la politica impresiones_api_insert
-- rechaza la fila: WITH CHECK exige que coincida con app.usuario_id.
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);

INSERT INTO recomendacion.impresiones (
    usuario_id, contenido_id, estrategia_id, posicion, score, superficie, mostrado_en
)
VALUES (9999, 1, 1, 1, 0.5, 'home', CURRENT_TIMESTAMP);

ROLLBACK;

-- 6.2 El mismo INSERT a nombre propio: funciona.
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);

INSERT INTO recomendacion.impresiones (
    usuario_id, contenido_id, estrategia_id, posicion, score, superficie, mostrado_en
)
VALUES (2, 1, 1, 1, 0.5, 'home', CURRENT_TIMESTAMP)
RETURNING id, usuario_id, contenido_id;

ROLLBACK;

-- 6.3 Leer la tabla de suscripciones.
-- Error esperado: permission denied for table suscripciones
--
-- Observar el contraste: personas.nivel_acceso_actual() SI puede leerla,
-- porque es SECURITY DEFINER y devuelve un entero, no las filas. La API
-- obtiene el nivel del usuario sin poder enumerar quien tiene que plan.
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT * FROM personas.suscripciones LIMIT 1;
ROLLBACK;

-- 6.4 Leer la traza de auditoria.
-- Error esperado: permission denied for schema auditoria
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT * FROM auditoria.eventos LIMIT 1;
ROLLBACK;

-- 6.5 Modificar el catalogo.
-- Error esperado: permission denied for table contenidos
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);
UPDATE catalogo.contenidos SET titulo = 'alterado' WHERE id = 1;
ROLLBACK;

-- 6.6 Leer la sal de seudonimizacion.
-- Error esperado: permission denied for schema control
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT * FROM control.secretos;
ROLLBACK;



-- ============================================================
-- 7. Resumen de lo demostrado
--
--   La API no puede ver contenido no publicado.
--   La API no puede ver contenido por encima del plan del usuario.
--   La API no puede ver impresiones ni datos de otros usuarios.
--   La API no puede ver el perfil vectorial de otros usuarios.
--   La API no puede escribir a nombre de otro usuario.
--   La API no puede leer suscripciones, auditoria ni secretos.
--   La API no puede modificar el catalogo.
--   El contexto de identidad no sobrevive a la transaccion.
--
-- Nada de eso depende del codigo del servicio: son politicas y permisos
-- del motor. Un endpoint escrito con un descuido no abre ninguna de esas
-- puertas.
--
-- Lo que si queda fuera del alcance, y esta declarado en el informe: la
-- AUTENTICACION. La cabecera X-Usuario-Id simula un token validado, y
-- cualquiera puede enviarla.
--
-- La distincion importa y conviene decirla con precision:
--
--   AUTORIZACION (a que tiene derecho)  -> resuelta en el motor. Nada de
--       lo que declare el cliente cambia que filas ve o que puede escribir.
--   AUTENTICACION (quien dice ser)      -> fuera de alcance. Con un JWT
--       firmado se cerraria, sin cambiar una linea de este archivo.
-- ============================================================
