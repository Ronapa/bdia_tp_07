-- Objetivo: medir que parte del catalogo llega a mostrarse y cuanto sesgo introduce el recomendador.
-- Requiere / entradas: impresiones y capa Gold cargadas.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: contenidos nunca recomendados, concentracion del trafico y diversidad por usuario.
-- Guia: son las metricas que un recomendador optimizado solo por CTR nunca muestra.

-- ============================================================
-- Consulta 1: El long tail que nadie ve
--
-- Pregunta de negocio: cuanto del catalogo publicado no llega nunca a
-- un lector.
--
-- Es una consulta de ausencia: NOT EXISTS sobre impresiones. Con un JOIN
-- comun estos contenidos simplemente no aparecerian en el resultado y el
-- problema seria invisible, que es exactamente como se vuelve cronico.
-- ============================================================



SELECT
    a.seccion_raiz,
    COUNT(*) AS nunca_recomendados,
    ROUND(AVG(EXTRACT(DAY FROM CURRENT_TIMESTAMP - c.fecha_publicacion)), 0) AS antiguedad_promedio_dias,
    COUNT(*) FILTER (WHERE c.nivel_acceso = 2) AS de_los_cuales_premium
FROM catalogo.contenidos AS c
JOIN catalogo.vw_arbol_secciones AS a
    ON a.seccion_id = c.seccion_id
WHERE c.estado = 'publicado'
  AND NOT EXISTS (
        SELECT 1
        FROM recomendacion.impresiones AS i
        WHERE i.contenido_id = c.id
  )
GROUP BY a.seccion_raiz
ORDER BY nunca_recomendados DESC;

-- Cobertura global, en una linea.
SELECT
    COUNT(*) AS publicados,
    COUNT(*) FILTER (
        WHERE EXISTS (SELECT 1 FROM recomendacion.impresiones AS i WHERE i.contenido_id = c.id)
    ) AS recomendados_alguna_vez,
    ROUND(
        100.0 * COUNT(*) FILTER (
            WHERE EXISTS (SELECT 1 FROM recomendacion.impresiones AS i WHERE i.contenido_id = c.id)
        ) / COUNT(*),
        2
    ) AS cobertura_porcentaje
FROM catalogo.contenidos AS c
WHERE c.estado = 'publicado';

-- ============================================================
-- Consulta 2: Concentracion del trafico
--
-- Pregunta de negocio: que porcentaje de las impresiones se lleva el 10%
-- mas recomendado del catalogo.
--
-- Es una curva de Lorenz aproximada. NTILE reparte los contenidos en
-- deciles por volumen de impresiones y la suma acumulada muestra la
-- concentracion. Un recomendador sano tiene una curva pronunciada; uno
-- que colapso sobre unos pocos contenidos la tiene casi vertical.
-- ============================================================

WITH por_contenido AS (
    SELECT
        i.contenido_id,
        COUNT(*) AS impresiones
    FROM recomendacion.impresiones AS i
    GROUP BY i.contenido_id
),
deciles AS (
    SELECT
        contenido_id,
        impresiones,
        NTILE(10) OVER (ORDER BY impresiones DESC) AS decil
    FROM por_contenido
)
SELECT
    decil,
    COUNT(*) AS contenidos,
    SUM(impresiones) AS impresiones,
    ROUND(100.0 * SUM(impresiones) / SUM(SUM(impresiones)) OVER (), 2) AS porcentaje_del_total,
    ROUND(
        100.0 * SUM(SUM(impresiones)) OVER (ORDER BY decil)
        / SUM(SUM(impresiones)) OVER (),
        2
    ) AS acumulado_porcentaje
FROM deciles
GROUP BY decil
ORDER BY decil;

-- ============================================================
-- Consulta 3: Diversidad del feed por usuario
--
-- Pregunta de negocio: le estamos mostrando a cada persona un mundo cada
-- vez mas chico.
--
-- Compara cuantas secciones distintas recibio cada usuario contra
-- cuantas existen. Un valor bajo y sostenido es una burbuja de filtro:
-- el recomendador acierta y, a la vez, empobrece la experiencia.
-- ============================================================

WITH diversidad AS (
    SELECT
        i.usuario_id,
        COUNT(*) AS impresiones,
        COUNT(DISTINCT a.seccion_raiz) AS secciones_recibidas,
        COUNT(DISTINCT i.contenido_id) AS contenidos_distintos
    FROM recomendacion.impresiones AS i
    JOIN catalogo.contenidos AS c
        ON c.id = i.contenido_id
    JOIN catalogo.vw_arbol_secciones AS a
        ON a.seccion_id = c.seccion_id
    GROUP BY i.usuario_id
    HAVING COUNT(*) >= 20
),
total_secciones AS (
    SELECT COUNT(DISTINCT seccion_raiz) AS total FROM catalogo.vw_arbol_secciones
)
SELECT
    CASE
        WHEN d.secciones_recibidas = 1 THEN '1 seccion (burbuja severa)'
        WHEN d.secciones_recibidas = 2 THEN '2 secciones'
        WHEN d.secciones_recibidas <= 4 THEN '3-4 secciones'
        ELSE '5 o mas secciones'
    END AS tramo_diversidad,
    COUNT(*) AS usuarios,
    ROUND(AVG(d.impresiones), 0) AS impresiones_promedio,
    ROUND(AVG(d.contenidos_distintos), 0) AS contenidos_promedio,
    ROUND(100.0 * AVG(d.secciones_recibidas) / MAX(t.total), 1) AS cobertura_secciones_porcentaje
FROM diversidad AS d
CROSS JOIN total_secciones AS t
GROUP BY 1
ORDER BY 1;


-- ============================================================
-- Consulta 4: Contenido que solo ve quien paga
--
-- Pregunta de negocio: el muro de pago esta dejando afuera a la mayoria
-- de la audiencia de una seccion.
--
-- Cruza el nivel de acceso del catalogo con el nivel de los usuarios que
-- efectivamente lo recibieron. Es una consulta de gobierno de producto,
-- no de rendimiento.
-- ============================================================

SELECT
    a.seccion_raiz,
    c.nivel_acceso,
    COUNT(DISTINCT c.id) AS contenidos,
    COUNT(i.id) AS impresiones,
    COUNT(DISTINCT i.usuario_id) AS usuarios_alcanzados,
    ROUND(
        100.0 * COUNT(DISTINCT i.usuario_id)
        / NULLIF((SELECT COUNT(*) FROM personas.usuarios WHERE activo), 0),
        2
    ) AS porcentaje_de_la_audiencia
FROM catalogo.contenidos AS c
JOIN catalogo.vw_arbol_secciones AS a
    ON a.seccion_id = c.seccion_id
LEFT JOIN recomendacion.impresiones AS i
    ON i.contenido_id = c.id
WHERE c.estado = 'publicado'
GROUP BY a.seccion_raiz, c.nivel_acceso
ORDER BY a.seccion_raiz, c.nivel_acceso;

-- ============================================================
-- Consulta 5: Contenidos que retienen contra contenidos que atraen
--
-- Pregunta de negocio: que notas se leen hasta el final, mas alla de
-- cuantos clics hicieron.
--
-- El CTR mide el titulo; la tasa de finalizacion mide el contenido. Un
-- recomendador optimizado solo por clics premia al primero, que es la
-- receta del titulo enganoso.
-- ============================================================

WITH consumo AS (
    SELECT
        f.contenido_key AS contenido_id,
        SUM(f.vistas) AS vistas,
        SUM(f.vistas_completas) AS completadas
    FROM analitica.fact_consumo_diario AS f
    GROUP BY f.contenido_key
    HAVING SUM(f.vistas) >= 10
),
impresiones AS (
    SELECT
        i.contenido_id,
        COUNT(*) AS impresiones,
        COUNT(*) FILTER (WHERE i.clic) AS clics
    FROM recomendacion.impresiones AS i
    GROUP BY i.contenido_id
    HAVING COUNT(*) >= 20
)
SELECT
    d.titulo,
    d.seccion_raiz,
    im.impresiones,
    ROUND(100.0 * im.clics / im.impresiones, 2) AS ctr_porcentaje,
    co.vistas,
    ROUND(100.0 * co.completadas / co.vistas, 2) AS finalizacion_porcentaje,
    CASE
        WHEN 100.0 * im.clics / im.impresiones > 5
             AND 100.0 * co.completadas / co.vistas < 15
        THEN 'atrae y no retiene'
        WHEN 100.0 * im.clics / im.impresiones < 3
             AND 100.0 * co.completadas / co.vistas > 30
        THEN 'retiene y no atrae'
        ELSE 'equilibrado'
    END AS diagnostico
FROM consumo AS co
JOIN impresiones AS im
    ON im.contenido_id = co.contenido_id
JOIN analitica.dim_contenido AS d
    ON d.contenido_key = co.contenido_id
ORDER BY finalizacion_porcentaje DESC
LIMIT 20;
