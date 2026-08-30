-- Objetivo: resolver el feed personalizado, que es la consulta central y mas frecuente del sistema.
-- Requiere / entradas: catalogo, preferencias e impresiones cargados.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: hasta 12 contenidos accesibles, vigentes, no vistos y no vetados.
-- Guia: es la consulta que justifica el indice parcial idx_contenidos_publicados_seccion_acceso.

-- ============================================================
-- Pregunta de negocio
--
--   Que le mostramos a este lector, ahora, en la home.
--
-- Es la consulta que corre en cada request y la que fija el diseno de
-- media base de datos. Todo lo que hace se puede leer como una lista de
-- reglas de negocio:
--
--   1. Solo contenido publicado y dentro de su ventana de vigencia.
--   2. Solo lo que su plan le permite ver.
--   3. Nada que haya vetado explicitamente.
--   4. Nada que ya haya visto.
--   5. A lo sumo dos notas por seccion, para no encerrarlo en un tema.
--   6. Ordenado por una mezcla de afinidad declarada y frescura.
--
-- Las reglas 1 y 2 estan ademas en las politicas de Row Level Security:
-- aca se escriben para que la consulta sea legible por si sola, pero si
-- alguien las olvidara, el motor las seguiria aplicando.
-- ============================================================

WITH parametros AS (
    SELECT
        1::BIGINT AS usuario_id,
        1::INTEGER AS nivel_acceso,
        12::INTEGER AS tamano_feed
),
secciones_seguidas AS (
    SELECT p.seccion_id, p.peso
    FROM personas.preferencias_usuario AS p
    CROSS JOIN parametros AS par
    WHERE p.usuario_id = par.usuario_id
      AND p.tipo_preferencia = 'sigue'
      AND p.seccion_id IS NOT NULL
),
ya_visto AS (
    SELECT DISTINCT i.contenido_id
    FROM recomendacion.impresiones AS i
    CROSS JOIN parametros AS par
    WHERE i.usuario_id = par.usuario_id
      AND i.clic
),
candidatos AS (
    SELECT
        c.contenido_id,
        c.titulo,
        c.seccion,
        c.seccion_id,
        c.tipo_contenido,
        c.nivel_acceso,
        c.fecha_publicacion,
        -- Afinidad declarada: si el usuario sigue la seccion, suma.
        COALESCE(ss.peso, 0)::NUMERIC AS afinidad,
        -- Frescura: decae con las horas desde la publicacion. Se ancla al
        -- ultimo contenido publicado y no a CURRENT_TIMESTAMP porque el
        -- dataset tiene una fecha de corte fija.
        EXP(
            -EXTRACT(EPOCH FROM (
                (SELECT MAX(fecha_publicacion) FROM catalogo.vw_contenidos_publicables)
                - c.fecha_publicacion
            )) / (72 * 3600.0)
        )::NUMERIC AS frescura
    FROM catalogo.vw_contenidos_publicables AS c
    CROSS JOIN parametros AS par
    LEFT JOIN secciones_seguidas AS ss
        ON ss.seccion_id = c.seccion_id
    WHERE c.nivel_acceso <= par.nivel_acceso
      AND NOT EXISTS (
            SELECT 1 FROM ya_visto AS v WHERE v.contenido_id = c.contenido_id
      )
      AND NOT EXISTS (
            SELECT 1
            FROM recomendacion.vw_vetos_usuario AS w
            WHERE w.usuario_id = par.usuario_id
              AND w.contenido_id = c.contenido_id
      )
),
puntuados AS (
    SELECT
        c.*,
        ROUND(0.6 * c.afinidad + 0.4 * c.frescura, 6) AS score,
        ROW_NUMBER() OVER (
            PARTITION BY c.seccion_id
            ORDER BY 0.6 * c.afinidad + 0.4 * c.frescura DESC, c.fecha_publicacion DESC
        ) AS orden_en_seccion
    FROM candidatos AS c
)
SELECT
    contenido_id,
    titulo,
    seccion,
    tipo_contenido,
    nivel_acceso,
    fecha_publicacion,
    ROUND(afinidad, 3) AS afinidad,
    ROUND(frescura, 4) AS frescura,
    score
FROM puntuados
WHERE orden_en_seccion <= 2
ORDER BY score DESC, fecha_publicacion DESC
LIMIT (SELECT tamano_feed FROM parametros);

-- ============================================================
-- Variante: el mismo feed servido desde Redis
--
-- Para comparar. La version de arriba es correcta pero toca cuatro
-- tablas y calcula exponenciales por fila; la version precalculada de
-- Redis se resuelve con un ZREVRANGE:
--
--   ZREVRANGE rec:usuario:1:top 0 11 WITHSCORES
--
-- Ese es el compromiso del diseno: PostgreSQL define la verdad y las
-- reglas, Redis sirve el resultado. El precio es que el feed de Redis
-- tiene la frescura de la ultima corrida del pipeline, no la del
-- instante. Para un feed de recomendaciones es un precio razonable;
-- para el saldo de una cuenta no lo seria.
-- ============================================================
