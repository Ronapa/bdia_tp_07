-- Objetivo: precalcular el trending por seccion, que es la consulta mas repetida y la mas cara del feed.
-- Requiere / entradas: vistas de 02_vistas.sql y datos cargados en recomendacion.impresiones.
-- Produce / modifica: vista materializada mv_trending_seccion y la funcion que la refresca.
-- Resultado esperado: la vista existe; queda vacia hasta el primer REFRESH posterior a la carga.
-- Guia: PostgreSQL no soporta CREATE OR REPLACE MATERIALIZED VIEW, por eso el DROP previo.

-- ============================================================
-- Vista materializada: recomendacion.mv_trending_seccion
--
-- Por que materializar y no dejarla como vista comun:
--
--   La consulta agrega cientos de miles de impresiones y las cruza con
--   el catalogo. En una vista comun ese trabajo se repite en cada
--   request del home; materializada se paga una vez por refresco.
--
--   El dato tolera estar desactualizado. El trending de las ultimas
--   24 horas no cambia de forma perceptible entre un minuto y el
--   siguiente: cambiar frescura por latencia es un buen negocio aca,
--   y seria un pesimo negocio en la tabla de suscripciones.
--
-- El decaimiento temporal (exp(-horas/24)) es lo que hace que una nota
-- con muchas vistas de hace tres dias no tape a una que esta explotando
-- ahora. Sin el, el trending se convierte en un ranking historico.
--
-- ventana_horas se deja como columna para poder comparar la version
-- calculada aca contra analitica.agg_popularidad, que produce DuckDB.
-- ============================================================

DROP MATERIALIZED VIEW IF EXISTS recomendacion.mv_trending_seccion;

CREATE MATERIALIZED VIEW recomendacion.mv_trending_seccion AS
WITH ventana AS (
    -- La ventana se ancla al ultimo evento cargado y no a CURRENT_TIMESTAMP:
    -- el dataset es sintetico y tiene una fecha de corte fija, asi que anclar
    -- a "ahora" dejaria el trending vacio apenas pasa un dia.
    SELECT COALESCE(MAX(mostrado_en), CURRENT_TIMESTAMP) AS corte
    FROM recomendacion.impresiones
),
clics_recientes AS (
    SELECT
        i.contenido_id,
        COUNT(*) AS impresiones,
        COUNT(*) FILTER (WHERE i.clic) AS clics,
        SUM(
            CASE WHEN i.clic THEN
                EXP(-EXTRACT(EPOCH FROM (v.corte - i.mostrado_en)) / (24 * 3600.0))
            ELSE 0 END
        ) AS score_decaido
    FROM recomendacion.impresiones AS i
    CROSS JOIN ventana AS v
    WHERE i.mostrado_en >= v.corte - INTERVAL '7 days'
    GROUP BY i.contenido_id
)
SELECT
    p.seccion_id,
    p.seccion_slug,
    p.contenido_id,
    p.titulo,
    p.tipo_contenido,
    p.nivel_acceso,
    p.fecha_publicacion,
    cr.impresiones,
    cr.clics,
    ROUND(cr.score_decaido::NUMERIC, 6) AS score,
    168 AS ventana_horas,
    ROW_NUMBER() OVER (
        PARTITION BY p.seccion_id
        ORDER BY cr.score_decaido DESC, p.fecha_publicacion DESC
    ) AS posicion_en_seccion
FROM catalogo.vw_contenidos_publicables AS p
JOIN clics_recientes AS cr
    ON cr.contenido_id = p.contenido_id;

-- El indice UNICO es obligatorio para poder usar REFRESH CONCURRENTLY.
-- Sin el, cada refresco bloquea las lecturas de la vista.
CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_trending_seccion_unico
    ON recomendacion.mv_trending_seccion(seccion_id, contenido_id);

CREATE INDEX IF NOT EXISTS idx_mv_trending_seccion_posicion
    ON recomendacion.mv_trending_seccion(seccion_id, posicion_en_seccion);

-- ============================================================
-- Funcion de refresco
--
-- CONCURRENTLY permite que el home siga leyendo mientras se recalcula.
-- Es mas lento y necesita el indice unico, pero evita el bloqueo, que es
-- justamente lo que uno quiere evitar en la consulta mas caliente.
-- ============================================================

CREATE OR REPLACE FUNCTION recomendacion.refrescar_trending()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY recomendacion.mv_trending_seccion;
EXCEPTION
    WHEN OTHERS THEN
        -- La primera vez la vista nunca fue poblada y CONCURRENTLY no aplica.
        REFRESH MATERIALIZED VIEW recomendacion.mv_trending_seccion;
END;
$$;
