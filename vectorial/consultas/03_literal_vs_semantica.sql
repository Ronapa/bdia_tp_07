-- Objetivo: comparar la busqueda literal contra la semantica sobre el mismo catalogo.
-- Requiere / entradas: indice GIN sobre tsvector (db/indices_vistas/01_indices.sql) y embeddings cargados.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: cada metodo encuentra cosas que el otro no; la union es mejor que cualquiera de los dos.
-- Guia: no son alternativas, son complementarias; el informe explica cuando gana cada una.

-- ============================================================
-- Las dos busquedas, en una linea
--
--   Literal (tsvector + GIN):  encuentra la PALABRA.
--   Semantica (pgvector):      encuentra el TEMA.
--
-- La literal gana con nombres propios, siglas y cifras: terminos que el
-- embedding tiende a difuminar porque los vio poco durante el
-- entrenamiento. La semantica gana cuando el usuario describe lo que
-- busca con sus propias palabras, sin usar los terminos del texto.
--
-- Nota sobre el vector de la consulta: pgvector necesita el embedding
-- del texto buscado, y calcularlo requiere el modelo. Desde SQL puro no
-- se puede. Por eso estas consultas usan como vector de consulta el
-- embedding de un contenido existente, que es lo que hace de verdad el
-- recomendador ("mas como este"). Para buscar por texto libre esta el
-- endpoint /contenidos/{id}/similares de la API, que si tiene el modelo.
-- ============================================================

-- ============================================================
-- Consulta 1: Busqueda literal
--
-- Pregunta de negocio: que notas mencionan explicitamente "escrutinio".
--
-- plainto_tsquery conecta todas las palabras con AND, que es demasiado
-- restrictivo para un buscador: si el usuario escribe tres terminos y la
-- nota tiene dos, no aparece. Se convierte a OR con regexp_replace y se
-- ordena por ts_rank, que pondera cuantos terminos coinciden.
-- ============================================================

WITH consulta AS (
    SELECT to_tsquery(
        'spanish',
        regexp_replace(
            plainto_tsquery('spanish', 'escrutinio padron electoral')::TEXT,
            ' & ', ' | ', 'g'
        )
    ) AS q
)
SELECT
    c.contenido_id,
    c.titulo,
    c.seccion,
    ROUND(
        ts_rank(
            to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')),
            consulta.q
        )::NUMERIC,
        5
    ) AS relevancia_literal
FROM catalogo.vw_contenidos_publicables AS c
CROSS JOIN consulta
WHERE to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')) @@ consulta.q
ORDER BY relevancia_literal DESC
LIMIT 10;

-- ============================================================
-- Consulta 2: Busqueda semantica sobre el mismo tema
--
-- Toma como punto de partida el contenido mejor rankeado por la busqueda
-- literal y pide sus vecinos semanticos.
-- ============================================================

WITH consulta AS (
    SELECT to_tsquery(
        'spanish',
        regexp_replace(
            plainto_tsquery('spanish', 'escrutinio padron electoral')::TEXT,
            ' & ', ' | ', 'g'
        )
    ) AS q
),
ancla AS (
    SELECT c.contenido_id
    FROM catalogo.vw_contenidos_publicables AS c
    CROSS JOIN consulta
    WHERE to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')) @@ consulta.q
    ORDER BY ts_rank(
        to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')), consulta.q
    ) DESC
    LIMIT 1
)
SELECT
    v.contenido_id,
    v.titulo,
    v.seccion,
    ROUND((1 - (e.embedding <=> base.embedding))::NUMERIC, 5) AS similitud_semantica
FROM ancla
JOIN recomendacion.embeddings_contenido AS base
    ON base.contenido_id = ancla.contenido_id
JOIN recomendacion.embeddings_contenido AS e
    ON e.contenido_id <> base.contenido_id
JOIN catalogo.vw_contenidos_publicables AS v
    ON v.contenido_id = e.contenido_id
ORDER BY e.embedding <=> base.embedding
LIMIT 10;

-- ============================================================
-- Consulta 3: El solapamiento entre los dos metodos
--
-- Pregunta de negocio: conviene tener las dos busquedas, o alcanza con una.
--
-- Un FULL OUTER JOIN entre los dos rankings deja ver que encuentra cada
-- uno y que encuentran los dos. Si el solapamiento fuera total, una de
-- las dos sobraria.
-- ============================================================

WITH consulta AS (
    SELECT to_tsquery(
        'spanish',
        regexp_replace(
            plainto_tsquery('spanish', 'escrutinio padron electoral')::TEXT,
            ' & ', ' | ', 'g'
        )
    ) AS q
),
literal AS (
    SELECT
        c.contenido_id,
        c.titulo,
        ROW_NUMBER() OVER (
            ORDER BY ts_rank(
                to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')), consulta.q
            ) DESC
        ) AS posicion
    FROM catalogo.vw_contenidos_publicables AS c
    CROSS JOIN consulta
    WHERE to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')) @@ consulta.q
    LIMIT 10
),
ancla AS (
    SELECT contenido_id FROM literal WHERE posicion = 1
),
semantica AS (
    SELECT
        v.contenido_id,
        v.titulo,
        ROW_NUMBER() OVER (ORDER BY e.embedding <=> base.embedding) AS posicion
    FROM ancla
    JOIN recomendacion.embeddings_contenido AS base
        ON base.contenido_id = ancla.contenido_id
    JOIN recomendacion.embeddings_contenido AS e
        ON e.contenido_id <> base.contenido_id
    JOIN catalogo.vw_contenidos_publicables AS v
        ON v.contenido_id = e.contenido_id
    ORDER BY e.embedding <=> base.embedding
    LIMIT 10
)
SELECT
    COALESCE(l.contenido_id, s.contenido_id) AS contenido_id,
    COALESCE(l.titulo, s.titulo) AS titulo,
    l.posicion AS posicion_literal,
    s.posicion AS posicion_semantica,
    CASE
        WHEN l.contenido_id IS NULL THEN 'solo semantica'
        WHEN s.contenido_id IS NULL THEN 'solo literal'
        ELSE 'ambas'
    END AS lo_encuentra
FROM literal AS l
FULL OUTER JOIN semantica AS s
    ON s.contenido_id = l.contenido_id
ORDER BY COALESCE(l.posicion, 99), COALESCE(s.posicion, 99);

-- ============================================================
-- Consulta 4: Mezcla de los dos rankings (Reciprocal Rank Fusion)
--
-- Pregunta de negocio: como se combinan dos rankings que puntuan en
-- escalas incomparables.
--
-- ts_rank devuelve valores en torno a 0,06 y la similitud coseno en
-- torno a 0,95: sumarlos directamente es sumar peras y manzanas. RRF
-- resuelve el problema ignorando los puntajes y usando solo la POSICION:
--
--     score(d) = suma sobre cada ranking de  1 / (k + posicion)
--
-- k = 60 es el valor habitual de la literatura; amortigua el peso de las
-- primeras posiciones para que un ranking no domine al otro.
--
-- Es la tecnica estandar de busqueda hibrida. Queda implementada aca
-- como demostracion; el buscador del producto no forma parte del alcance.
-- ============================================================

WITH consulta AS (
    SELECT to_tsquery(
        'spanish',
        regexp_replace(
            plainto_tsquery('spanish', 'escrutinio padron electoral')::TEXT,
            ' & ', ' | ', 'g'
        )
    ) AS q
),
literal AS (
    SELECT
        c.contenido_id,
        c.titulo,
        ROW_NUMBER() OVER (
            ORDER BY ts_rank(
                to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')), consulta.q
            ) DESC
        ) AS posicion
    FROM catalogo.vw_contenidos_publicables AS c
    CROSS JOIN consulta
    WHERE to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, '')) @@ consulta.q
    LIMIT 20
),
ancla AS (
    SELECT contenido_id FROM literal WHERE posicion = 1
),
semantica AS (
    SELECT
        v.contenido_id,
        v.titulo,
        ROW_NUMBER() OVER (ORDER BY e.embedding <=> base.embedding) AS posicion
    FROM ancla
    JOIN recomendacion.embeddings_contenido AS base
        ON base.contenido_id = ancla.contenido_id
    JOIN recomendacion.embeddings_contenido AS e
        ON e.contenido_id <> base.contenido_id
    JOIN catalogo.vw_contenidos_publicables AS v
        ON v.contenido_id = e.contenido_id
    ORDER BY e.embedding <=> base.embedding
    LIMIT 20
)
SELECT
    COALESCE(l.contenido_id, s.contenido_id) AS contenido_id,
    COALESCE(l.titulo, s.titulo) AS titulo,
    l.posicion AS posicion_literal,
    s.posicion AS posicion_semantica,
    ROUND(
        COALESCE(1.0 / (60 + l.posicion), 0) + COALESCE(1.0 / (60 + s.posicion), 0),
        6
    ) AS score_rrf
FROM literal AS l
FULL OUTER JOIN semantica AS s
    ON s.contenido_id = l.contenido_id
ORDER BY score_rrf DESC
LIMIT 10;

-- ============================================================
-- Consulta 5: Donde falla cada metodo
--
-- Pregunta de negocio: cuando conviene mostrar una y cuando la otra.
--
-- Busca un termino que aparece en pocos titulos. La literal devuelve
-- exactamente esos y nada mas; la semantica devuelve un conjunto mas
-- amplio del mismo tema, incluyendo notas que no usan la palabra.
-- ============================================================

SELECT
    'literal' AS metodo,
    COUNT(*) AS resultados
FROM catalogo.vw_contenidos_publicables AS c
WHERE to_tsvector('spanish', c.titulo || ' ' || COALESCE(c.bajada, ''))
      @@ plainto_tsquery('spanish', 'ransomware')

UNION ALL

SELECT
    'semantica (similitud > 0,90)',
    COUNT(*)
FROM recomendacion.embeddings_contenido AS e
JOIN catalogo.vw_contenidos_publicables AS v
    ON v.contenido_id = e.contenido_id
WHERE (1 - (e.embedding <=> (
        SELECT e2.embedding
        FROM recomendacion.embeddings_contenido AS e2
        JOIN catalogo.vw_contenidos_publicables AS v2
            ON v2.contenido_id = e2.contenido_id
        WHERE v2.seccion = 'Ciberseguridad'
        LIMIT 1
      ))) > 0.90;

-- ============================================================
-- Conclusion, para el informe
--
-- La busqueda literal es barata, exacta y no necesita ningun modelo:
-- para un buscador de sitio es el punto de partida correcto.
--
-- La semantica cuesta mas (hay que calcular el embedding de la consulta)
-- y a cambio encuentra contenido que no comparte ni una palabra con lo
-- buscado. En un recomendador esa es exactamente la capacidad que hace
-- falta, porque el usuario no escribio nada: lo unico que hay es su
-- historial.
--
-- Por eso el sistema usa la literal para el buscador y la semantica para
-- recomendar, y RRF queda documentado como el camino para unirlas si el
-- producto lo pidiera.
-- ============================================================
