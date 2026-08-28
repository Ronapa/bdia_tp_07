-- Objetivo: contrastar la capa Gold contra la Silver y contra el sistema operacional.
-- Requiere / entradas: Gold cargada por 04_cargar_gold.sql.
-- Produce / modifica: nada; solo lee y aborta si algun control no cierra
-- Resultado esperado: la lista de controles y el mensaje CONTROLES_OK
-- Guia: un pipeline sin conciliacion entre capas no es un pipeline, es una copia con pasos.

-- ============================================================
-- 1. Balance de calidad por lote
-- ============================================================
SELECT entidad, lote_id, recibidas, aceptadas, rechazadas,
       round(100.0 * rechazadas / recibidas, 2) AS porcentaje_rechazo
FROM resumen_calidad
ORDER BY entidad, lote_id;

-- ============================================================
-- 2. Detalle de los rechazos con su linaje ( Es lo usable vs lo rechazado con motivo )
-- Cada fila rechazada se puede rastrear hasta el archivo y la linea de origen. Es lo que convierte "hay 6 filas mal" en algo accionable.
-- ============================================================

SELECT
    entidad,
    codigo_error,
    clave,
    regexp_extract(archivo_origen, 'lote=([^/]+)', 1) AS lote,
    numero_fila
FROM rechazos
ORDER BY entidad, codigo_error, clave;

-- ============================================================
-- 3. Conciliacion Silver contra Gold
-- Las mismas magnitudes calculadas por dos caminos distintos tienen que dar lo mismo. Si no dan, hubo perdida de filas en la carga.
-- ============================================================

SELECT
    'vistas' AS magnitud,
    (SELECT count(*) FROM silver_eventos
     WHERE tipo_evento IN ('vista', 'reproduccion', 'completado')) AS en_silver,
    (SELECT coalesce(sum(vistas), 0) FROM pg.analitica.fact_consumo_diario) AS en_gold
UNION ALL
SELECT
    'impresiones',
    (SELECT count(*) FROM silver_impresiones),
    (SELECT coalesce(sum(impresiones), 0) FROM pg.analitica.fact_impresiones_diario)
UNION ALL
SELECT
    'clics',
    (SELECT count_if(clic) FROM silver_impresiones),
    (SELECT coalesce(sum(clics), 0) FROM pg.analitica.fact_impresiones_diario)
ORDER BY magnitud;

-- ============================================================
-- 4. Rendimiento por estrategia (agregados en postgress )
-- Es la salida que responde la pregunta de negocio del caso de uso.Se lee desde Gold, que es lo que despues consume el tablero.
-- ============================================================

SELECT
    e.codigo AS estrategia,
    e.motor,
    sum(f.impresiones) AS impresiones,
    sum(f.clics) AS clics,
    round(sum(f.clics) * 100.0 / sum(f.impresiones), 3) AS ctr_porcentaje,
    max(f.contenidos_distintos) AS max_contenidos_por_dia
FROM pg.analitica.fact_impresiones_diario AS f
JOIN pg.analitica.dim_estrategia AS e
    ON e.estrategia_key = f.estrategia_key
GROUP BY e.codigo, e.motor
ORDER BY ctr_porcentaje DESC;

-- ====================================================================================
-- 5. Cobertura del catalogo
-- Que porcentaje del catalogo publicado llega efectivamente a mostrarse.
-- Una cobertura baja significa que el recomendador concentra el trafico en pocos contenidos: es rentable a corto plazo y empobrece el producto.
-- ====================================================================================

WITH publicados AS (
    SELECT count(*) AS total FROM silver_contenidos WHERE estado = 'publicado'
),
recomendados AS (
    SELECT count(DISTINCT contenido_id) AS total FROM silver_impresiones
)
SELECT
    publicados.total AS contenidos_publicados,
    recomendados.total AS contenidos_recomendados,
    round(100.0 * recomendados.total / publicados.total, 2) AS cobertura_porcentaje
FROM publicados, recomendados;

-- ============================================================
-- Comparacion de las dos fuentes de vecinos
--
-- La similitud semantica (pgvector) y la co-ocurrencia (DuckDB) miden
-- cosas distintas: la primera, de que habla el contenido; la segunda,
-- que consume la misma gente. Que coincidan poco no es un error, es el
-- motivo por el que la estrategia hibrida combina las dos.
-- ============================================================

SELECT
    origen,
    count(*) AS pares,
    count(DISTINCT contenido_id) AS contenidos_cubiertos,
    round(avg(score), 4) AS score_promedio
FROM pg.recomendacion.ranking_items_similares
GROUP BY origen
ORDER BY origen;

SELECT
    count(*) AS pares_en_ambas_fuentes
FROM pg.recomendacion.ranking_items_similares AS a
JOIN pg.recomendacion.ranking_items_similares AS b
    ON b.contenido_id = a.contenido_id
    AND b.contenido_similar_id = a.contenido_similar_id
WHERE a.origen = 'embedding'
  AND b.origen = 'coocurrencia';

-- ============================================================
-- 7. Controles que deben pasar
-- ============================================================

SELECT
    CASE
        WHEN (SELECT count(*) FROM resumen_calidad
              WHERE aceptadas + rechazadas <> recibidas) > 0
            THEN error('El balance de calidad no cierra')

        WHEN (SELECT count(*) FROM silver_eventos
              WHERE tipo_evento IN ('vista', 'reproduccion', 'completado'))
             <> (SELECT coalesce(sum(vistas), 0) FROM pg.analitica.fact_consumo_diario)
            THEN error('Las vistas de Silver no coinciden con las de Gold')

        WHEN (SELECT count(*) FROM silver_impresiones)
             <> (SELECT coalesce(sum(impresiones), 0)
                 FROM pg.analitica.fact_impresiones_diario)
            THEN error('Las impresiones de Silver no coinciden con las de Gold')

        WHEN (SELECT count(*) FROM pg.analitica.fact_impresiones_diario
              WHERE clics > impresiones) > 0
            THEN error('Hay dias con mas clics que impresiones')

        WHEN (SELECT count(*) FROM pg.analitica.agg_popularidad WHERE score <= 0) > 0
            THEN error('Hay contenidos con score de popularidad no positivo')

        WHEN (SELECT count(*) FROM pg.recomendacion.ranking_items_similares
              WHERE contenido_id = contenido_similar_id) > 0
            THEN error('Hay contenidos marcados como similares a si mismos')

        ELSE 'CONTROLES_OK'
    END AS control;
