-- Objetivo: decidir con datos que estrategia de recomendacion conviene dejar prendida.
-- Requiere / entradas: impresiones cargadas y capa Gold construida por DuckDB.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: CTR por estrategia con su desvio contra el promedio y su cobertura.
-- Guia: es la consulta orientada a la toma de decisiones que pide la consigna.



-- ============================================================
-- Consulta 1: CTR por estrategia contra el promedio general
--
-- Pregunta de negocio: cual de las cinco estrategias justifica su costo.
--
-- El CTR suelto no alcanza para decidir: hay que verlo contra el
-- promedio y contra el volumen. Una estrategia con CTR altisimo sobre
-- 200 impresiones no es una estrategia, es ruido estadistico.
--
-- La funcion de ventana calcula el promedio general SIN una segunda
-- consulta ni una subconsulta correlacionada: AVG(...) OVER () recorre
-- el mismo conjunto ya agregado.
-- ============================================================

WITH por_estrategia AS (
    SELECT
        e.codigo AS estrategia,
        e.motor,
        COUNT(*) AS impresiones,
        COUNT(*) FILTER (WHERE i.clic) AS clics,
        COUNT(DISTINCT i.contenido_id) AS contenidos_distintos,
        COUNT(DISTINCT i.usuario_id) AS usuarios_alcanzados
    FROM recomendacion.impresiones AS i
    JOIN recomendacion.estrategias AS e
        ON e.id = i.estrategia_id
    GROUP BY e.codigo, e.motor
    HAVING COUNT(*) >= 500
)
SELECT
    estrategia,
    motor,
    impresiones,
    clics,
    ROUND(100.0 * clics / impresiones, 3) AS ctr_porcentaje,
    ROUND(100.0 * AVG(clics::NUMERIC / impresiones) OVER (), 3) AS ctr_promedio_general,
    ROUND(
        100.0 * (clics::NUMERIC / impresiones - AVG(clics::NUMERIC / impresiones) OVER ()),
        3
    ) AS diferencia_vs_promedio,
    contenidos_distintos,
    usuarios_alcanzados,
    RANK() OVER (ORDER BY clics::NUMERIC / impresiones DESC) AS posicion
FROM por_estrategia
ORDER BY posicion;




-- ============================================================
-- Consulta 2: CTR por estrategia y superficie
--
-- Pregunta de negocio: la estrategia que gana en la home, gana tambien
-- al pie de un articulo.
--
-- Es la pregunta que evita una decision equivocada: apagar una
-- estrategia que rinde mal en promedio pero es la mejor en la superficie
-- donde mas trafico hay.
-- ============================================================

SELECT
    e.codigo AS estrategia,
    i.superficie,
    COUNT(*) AS impresiones,
    COUNT(*) FILTER (WHERE i.clic) AS clics,
    ROUND(100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*), 3) AS ctr_porcentaje,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*)
        - FIRST_VALUE(100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*)) OVER (
              PARTITION BY i.superficie
              ORDER BY COUNT(*) FILTER (WHERE i.clic)::NUMERIC / COUNT(*) DESC
          ),
        3
    ) AS distancia_al_mejor_de_la_superficie
FROM recomendacion.impresiones AS i
JOIN recomendacion.estrategias AS e
    ON e.id = i.estrategia_id
GROUP BY e.codigo, i.superficie
HAVING COUNT(*) >= 200
ORDER BY i.superficie, ctr_porcentaje DESC;




-- ============================================================
-- Consulta 3: Efecto de la posicion en el feed
--
-- Pregunta de negocio: cuanto del CTR se explica por la calidad de la
-- recomendacion y cuanto por estar arriba de todo.
--
-- Es el sesgo de posicion. Sin medirlo, cualquier comparacion entre estrategias 
-- esta contaminada: la que aparece mas arriba gana siempre.
-- ============================================================

SELECT
    i.posicion,
    COUNT(*) AS impresiones,
    COUNT(*) FILTER (WHERE i.clic) AS clics,
    ROUND(100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*), 3) AS ctr_porcentaje,
    ROUND(
        100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*)
        / NULLIF(FIRST_VALUE(100.0 * COUNT(*) FILTER (WHERE i.clic) / COUNT(*))
                 OVER (ORDER BY i.posicion), 0),
        3
    ) AS proporcion_vs_posicion_1
FROM recomendacion.impresiones AS i
WHERE i.posicion <= 10
GROUP BY i.posicion
ORDER BY i.posicion;




-- ============================================================
-- Consulta 4: Experimento A/B
--
-- Pregunta de negocio: la variante nueva mejora de verdad.
--
-- Compara las dos variantes sobre el mismo periodo y la misma poblacion.
-- Sin la tabla de asignaciones esto no seria un experimento sino una
-- comparacion entre grupos que se autoseleccionaron.
-- ============================================================

SELECT
    a.variante,
    COUNT(DISTINCT a.usuario_id) AS usuarios_asignados,
    COUNT(i.id) AS impresiones,
    COUNT(*) FILTER (WHERE i.clic) AS clics,
    ROUND(100.0 * COUNT(*) FILTER (WHERE i.clic) / NULLIF(COUNT(i.id), 0), 3) AS ctr_porcentaje
FROM recomendacion.asignaciones_ab AS a
JOIN recomendacion.experimentos_ab AS x
    ON x.id = a.experimento_id
LEFT JOIN recomendacion.impresiones AS i
    ON i.usuario_id = a.usuario_id
    AND i.variante_ab = a.variante
    AND i.mostrado_en >= x.desde
WHERE x.codigo = 'hibrido_vs_popularidad'
GROUP BY a.variante
ORDER BY a.variante;




-- ============================================================
-- Consulta 5: Evolucion semanal desde la capa Gold
--
-- Pregunta de negocio: el CTR de la estrategia hibrida esta mejorando o
-- fue un buen mes aislado.
--
-- Se lee desde analitica, no desde las impresiones: es la consulta que
-- iria a un tablero y no tiene por que golpear la base operacional.
-- ============================================================

SELECT
    DATE_TRUNC('week', d.fecha)::DATE AS semana,
    e.codigo AS estrategia,
    SUM(f.impresiones) AS impresiones,
    SUM(f.clics) AS clics,
    ROUND(100.0 * SUM(f.clics) / NULLIF(SUM(f.impresiones), 0), 3) AS ctr_porcentaje,
    ROUND(
        100.0 * SUM(f.clics) / NULLIF(SUM(f.impresiones), 0)
        - LAG(100.0 * SUM(f.clics) / NULLIF(SUM(f.impresiones), 0)) OVER (
              PARTITION BY e.codigo ORDER BY DATE_TRUNC('week', d.fecha)
          ),
        3
    ) AS variacion_vs_semana_anterior
FROM analitica.fact_impresiones_diario AS f
JOIN analitica.dim_fecha AS d
    ON d.fecha_key = f.fecha_key
JOIN analitica.dim_estrategia AS e
    ON e.estrategia_key = f.estrategia_key
GROUP BY DATE_TRUNC('week', d.fecha), e.codigo
HAVING SUM(f.impresiones) >= 100
ORDER BY semana, ctr_porcentaje DESC;
