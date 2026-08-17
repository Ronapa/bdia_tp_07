-- Objetivo: dar al analista los atributos que necesita para segmentar, sin exponer datos personales.
-- Requiere / entradas: roles de 01_roles_y_permisos.sql, tablas de personas y control.secretos.
-- Produce / modifica: la sal de seudonimizacion, dos funciones y la vista personas.vw_usuarios_anonimizado.
-- Resultado esperado: el analista consulta la vista y obtiene tramos etarios y seudonimos, nunca correos.
-- Guia: esta vista, a proposito, NO usa security_invoker; la elevacion de privilegios es el mecanismo.
-- Seguridad: la sal NO vive en el codigo; sin ella el seudonimo seria reversible por fuerza bruta.

-- ============================================================
-- 1. La sal de seudonimizacion
--
-- Se genera una vez, al azar, y queda en control.secretos. Nunca se
-- regenera: si cambiara, todos los seudonimos previamente exportados al
-- lakehouse dejarian de corresponderse con los nuevos y la capa
-- analitica perderia la continuidad historica.
--
-- La tabla no recibe ningun GRANT: solo la lee el dueno de la base y,
-- a traves de el, las funciones SECURITY DEFINER de este archivo.
-- ============================================================

INSERT INTO control.secretos (clave, valor, descripcion)
VALUES (
    'sal_seudonimo',
    ENCODE(public.gen_random_bytes(32), 'hex'),
    'Sal del HMAC que produce los seudonimos de la capa analitica'
)
ON CONFLICT (clave) DO NOTHING;

REVOKE ALL ON control.secretos FROM PUBLIC;

-- ============================================================
-- 2. Seudonimizacion
--
-- El seudonimo es un HMAC-SHA256 del id con la sal del sistema,
-- truncado. Sirve para lo unico que el analista necesita: reconocer que
-- dos filas corresponden a la misma persona.
--
-- Por que HMAC y no un simple hash con la sal concatenada: HMAC esta
-- construido para resistir ataques de extension de longitud, que es el
-- modo de falla clasico de `hash(sal || dato)`.
--
-- SECURITY DEFINER porque tiene que leer control.secretos, que el
-- analista no puede leer. Y el EXECUTE se le revoca a PUBLIC en el
-- punto 5: si el analista pudiera ejecutarla, recorreria los ids y
-- reconstruiria la tabla de correspondencias, que es exactamente el
-- ataque que esta funcion debe impedir.
--
-- Limite declarado: sigue siendo SEUDONIMIZACION, no anonimizacion. Con
-- acceso a la sal, el mapeo es reconstruible. Para publicar los datos
-- fuera de la organizacion haria falta ademas agregacion con k-anonimato.
-- ============================================================

-- Nota sobre search_path y funciones calificadas:
-- una funcion SECURITY DEFINER siempre fija su search_path, para que
-- nadie pueda anteponer un schema propio y suplantar una funcion. Por eso
-- `public` NO esta en la lista, y las funciones de pgcrypto (que viven
-- en public) se llaman con el nombre completo: public.hmac.
CREATE OR REPLACE FUNCTION personas.seudonimo(p_usuario_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, control, pg_temp
AS $$
    SELECT 'U-' || SUBSTRING(
        ENCODE(
            public.hmac(
                p_usuario_id::TEXT,
                (SELECT valor FROM control.secretos WHERE clave = 'sal_seudonimo'),
                'sha256'
            ),
            'hex'
        ),
        1, 12
    );
$$;

-- Poblar el seudonimo de las filas ya cargadas. Es idempotente: solo
-- toca las que todavia no lo tienen, asi que reejecutar el script no
-- reescribe seudonimos ya publicados hacia el lakehouse.
UPDATE personas.usuarios
SET seudonimo = personas.seudonimo(id)
WHERE seudonimo IS NULL;

-- ============================================================
-- 3. Generalizacion de la edad
--
-- La edad exacta, cruzada con pais y seccion favorita, reidentifica a
-- una persona con muy poca informacion extra. Colapsarla en tramos
-- conserva el poder de segmentacion y destruye la unicidad.
--
-- Se calcula la EDAD contra un ano de referencia, en lugar de comparar
-- el ano de nacimiento contra constantes.
--
-- Comparar el ano de nacimiento contra constantes (`anio >= 2000 ->
-- '18-25'`) parece equivalente y no lo es: la equivalencia se rompe sola
-- con el paso del tiempo, porque un nacido en 2000 tiene 26 anios en 2026.
-- Ademas, el CHECK de personas.usuarios admite nacimientos hasta 2012, o
-- sea menores de edad, que necesitan su propio tramo.
--
-- El ano de referencia sale de control.secretos para que los tramos sean
-- estables entre corridas: si dependiera de CURRENT_DATE, un mismo
-- usuario podria cambiar de tramo de un dia para el otro y las cohortes
-- historicas dejarian de cerrar.
-- ============================================================

INSERT INTO control.secretos (clave, valor, descripcion)
VALUES (
    'anio_referencia_tramos',
    '2026',
    'Ano contra el que se calculan los tramos etarios de la capa analitica'
)
ON CONFLICT (clave) DO NOTHING;

CREATE OR REPLACE FUNCTION personas.tramo_etario(p_anio_nacimiento INTEGER)
RETURNS TEXT
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = personas, control, pg_temp
AS $$
    SELECT CASE
        WHEN p_anio_nacimiento IS NULL THEN 'sin_dato'
        WHEN edad.anios < 18 THEN 'menor_de_18'
        WHEN edad.anios <= 25 THEN '18-25'
        WHEN edad.anios <= 35 THEN '26-35'
        WHEN edad.anios <= 45 THEN '36-45'
        WHEN edad.anios <= 55 THEN '46-55'
        WHEN edad.anios <= 65 THEN '56-65'
        ELSE '66+'
    END
    FROM (
        SELECT (SELECT valor::INTEGER FROM control.secretos
                WHERE clave = 'anio_referencia_tramos') - p_anio_nacimiento AS anios
    ) AS edad;
$$;

-- ============================================================
-- 4. Vista anonimizada
--
-- Sin security_invoker: la vista corre con los privilegios de su dueno,
-- que si puede leer personas.usuarios completa. El analista obtiene
-- exactamente las columnas transformadas y ninguna mas.
--
-- Este es el patron inverso al de db/indices_vistas/02_vistas.sql, y la
-- diferencia entre los dos casos es la clave del diseno:
--
--   vistas del catalogo -> security_invoker = TRUE : la vista NO debe
--                          poder mas que quien la consulta.
--   vista anonimizada   -> security_invoker = FALSE: la vista SI debe
--                          poder mas, porque es el unico camino
--                          controlado hacia el dato sensible.
-- ============================================================

-- IMPORTANTE: la vista lee u.seudonimo (columna persistida) y NO invoca
-- personas.seudonimo(). Una vista sin security_invoker elude los permisos
-- de TABLA de su dueno, pero NO los de FUNCION: si la invocara, el
-- analista recibiria "permission denied for function seudonimo". Se
-- comprobo empiricamente al revocar el EXECUTE.
CREATE OR REPLACE VIEW personas.vw_usuarios_anonimizado AS
SELECT
    u.seudonimo,
    u.pais,
    personas.tramo_etario(u.anio_nacimiento) AS tramo_etario,
    COALESCE(pl.codigo, 'sin_plan') AS plan,
    u.consentimiento_personalizacion,
    u.activo,
    DATE_TRUNC('month', u.fecha_alta)::DATE AS mes_alta
FROM personas.usuarios AS u
LEFT JOIN personas.suscripciones AS s
    ON s.usuario_id = u.id
    AND s.estado = 'activa'
LEFT JOIN personas.planes AS pl
    ON pl.id = s.plan_id;

GRANT SELECT ON personas.vw_usuarios_anonimizado TO bdia_analista;

-- ============================================================
-- 5. Las funciones NO son ejecutables por cualquiera
--
-- PostgreSQL otorga EXECUTE a PUBLIC por defecto en toda funcion nueva.
-- Ese default es lo que hacia reversible la anonimizacion: el analista
-- podia llamar a personas.seudonimo(1), personas.seudonimo(2), ... y
-- construir el mapeo completo.
--
-- Se revoca a PUBLIC y no se otorga a nadie. La vista sigue funcionando
-- porque se ejecuta con los privilegios de su dueno, que si puede.
-- ============================================================

REVOKE EXECUTE ON FUNCTION personas.seudonimo(BIGINT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION personas.tramo_etario(INTEGER) FROM PUBLIC;

-- personas.seudonimo() no se le otorga a NADIE: es la que permite
-- enumerar (id -> seudonimo) y reconstruir el mapeo.
--
-- personas.tramo_etario() si se le otorga al analista. No es un riesgo:
-- recibe un ano de nacimiento y devuelve un tramo, o sea que solo puede
-- decir algo sobre un dato que el analista ya tendria que conocer. A
-- cambio, evita duplicar la definicion de los tramos dentro de la vista.
GRANT EXECUTE ON FUNCTION personas.tramo_etario(INTEGER) TO bdia_analista;

-- ============================================================
-- 6. Verificacion
--
-- Tres controles. Los tres tienen que pasar para que la afirmacion
-- "el analista no puede reidentificar" sea cierta y no una intencion.
-- ============================================================

DO $$
DECLARE
    columnas_prohibidas INTEGER;
    ejecutable_publico  INTEGER;
    sal                 TEXT;
BEGIN
    -- 6.1 La vista no expone identificadores directos.
    SELECT COUNT(*) INTO columnas_prohibidas
    FROM information_schema.columns
    WHERE table_schema = 'personas'
      AND table_name = 'vw_usuarios_anonimizado'
      AND column_name IN ('email_hash', 'email_cifrado', 'alias', 'anio_nacimiento', 'id');

    IF columnas_prohibidas > 0 THEN
        RAISE EXCEPTION
            'La vista anonimizada expone % columna(s) con datos personales directos.',
            columnas_prohibidas;
    END IF;

    -- 6.2 Las funciones de seudonimizacion no son ejecutables por PUBLIC.
    SELECT COUNT(*) INTO ejecutable_publico
    FROM pg_proc AS p
    JOIN pg_namespace AS n
        ON n.oid = p.pronamespace
    WHERE n.nspname = 'personas'
      AND p.proname IN ('seudonimo', 'tramo_etario')
      AND has_function_privilege('public', p.oid, 'EXECUTE');

    -- Y la vista NO debe invocar personas.seudonimo(): si lo hiciera,
    -- el analista no podria consultarla.
    IF EXISTS (
        SELECT 1 FROM pg_views
        WHERE schemaname = 'personas'
          AND viewname = 'vw_usuarios_anonimizado'
          AND definition LIKE '%seudonimo(%'
    ) THEN
        RAISE EXCEPTION
            'La vista anonimizada invoca personas.seudonimo(); debe leer la columna persistida.';
    END IF;

    IF ejecutable_publico > 0 THEN
        RAISE EXCEPTION
            'Hay % funcion(es) de seudonimizacion ejecutables por PUBLIC; el seudonimo seria reversible.',
            ejecutable_publico;
    END IF;

    -- 6.3 La sal existe y no es un valor previsible.
    SELECT valor INTO sal FROM control.secretos WHERE clave = 'sal_seudonimo';
    IF sal IS NULL OR LENGTH(sal) < 32 THEN
        RAISE EXCEPTION 'La sal de seudonimizacion falta o es demasiado corta.';
    END IF;

    RAISE NOTICE 'Anonimizacion verificada: vista sin datos directos, funciones no publicas, sal presente.';
END;
$$;

SELECT
    column_name AS columna,
    data_type   AS tipo
FROM information_schema.columns
WHERE table_schema = 'personas'
  AND table_name = 'vw_usuarios_anonimizado'
ORDER BY ordinal_position;
