-- Objetivo: resolver las consultas por similitud del recomendador con prefiltrado de negocio.
-- Requiere / entradas: embeddings e indices creados por vectorial/01_crear_indices_vectoriales.sql.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: rankings de contenidos semanticamente cercanos, ya filtrados por permisos.
-- Guia: el operador <=> devuelve DISTANCIA coseno; 0 es identico y 2 es opuesto.

-- ============================================================
-- Consulta 1: "Mas como este"
--
-- Pregunta de negocio: al terminar de leer una nota, que otras tres
-- notas le ofrecemos a este lector.
--
-- La clave esta en DONDE va el filtro. Las condiciones de estado,
-- vigencia y nivel de acceso estan en el mismo WHERE que el ORDER BY
-- por distancia: PostgreSQL las evalua ANTES de rankear. Es prefiltrado.
--
-- La alternativa habitual en sistemas con base vectorial separada es
-- traer los 50 vecinos mas cercanos y filtrarlos en la aplicacion
-- (posfiltrado). Eso tiene dos problemas:
--   1. Si los 50 vecinos son premium y el usuario es gratuito, el feed
--      queda vacio, aunque existan candidatos validos mas lejanos.
--   2. Los ids de los contenidos descartados YA salieron de la base.
--      Cualquier error de la capa de aplicacion los expone.
--
-- Aca los contenidos no autorizados nunca entran al ranking.
-- ============================================================

-- Nota de sintaxis: el alias NO puede llamarse `similar`; SIMILAR es
-- palabra reservada de SQL (el operador SIMILAR TO) y PostgreSQL rechaza
-- la consulta. Se usa `vecino`.
SELECT
    vecino.contenido_id,
    vecino.titulo,
    vecino.seccion,
    vecino.tipo_contenido,
    vecino.nivel_acceso,
    ROUND((1 - (e.embedding <=> base.embedding))::NUMERIC, 4) AS similitud
FROM recomendacion.embeddings_contenido AS base
JOIN recomendacion.embeddings_contenido AS e
    ON e.contenido_id <> base.contenido_id
JOIN catalogo.vw_contenidos_publicables AS vecino
    ON vecino.contenido_id = e.contenido_id
WHERE base.contenido_id = 1
  AND vecino.nivel_acceso <= 1          -- plan del lector: registrado
ORDER BY e.embedding <=> base.embedding
LIMIT 5;

-- ============================================================
-- Consulta 2: Feed personalizado desde el perfil vectorial
--
-- Pregunta de negocio: que le mostramos a este usuario en la home.
--
-- El perfil es el centroide de lo que consumio. Una sola busqueda por
-- vecinos reemplaza a N busquedas "mas como este", una por cada
-- contenido de su historial.
--
-- Se restan tres conjuntos, y los tres importan:
--   - lo que ya vio      -> no repetir
--   - lo que veto        -> preferencia declarada, es un veto duro
--   - lo que excede su plan -> regla de negocio y de seguridad
-- ============================================================

WITH perfil AS (
    SELECT embedding
    FROM recomendacion.perfiles_usuario
    WHERE usuario_id = 1
),
ya_visto AS (
    SELECT DISTINCT contenido_id
    FROM recomendacion.impresiones
    WHERE usuario_id = 1
      AND clic
),
vetado AS (
    SELECT contenido_id
    FROM recomendacion.vw_vetos_usuario
    WHERE usuario_id = 1
)
SELECT
    p.contenido_id,
    p.titulo,
    p.seccion,
    p.tipo_contenido,
    ROUND((1 - (e.embedding <=> (SELECT embedding FROM perfil)))::NUMERIC, 4) AS afinidad
FROM recomendacion.embeddings_contenido AS e
JOIN catalogo.vw_contenidos_publicables AS p
    ON p.contenido_id = e.contenido_id
WHERE p.nivel_acceso <= 1
  AND p.contenido_id NOT IN (SELECT contenido_id FROM ya_visto)
  AND p.contenido_id NOT IN (SELECT contenido_id FROM vetado)
ORDER BY e.embedding <=> (SELECT embedding FROM perfil)
LIMIT 10;

-- ============================================================
-- Consulta 3: Feed diversificado
--
-- Pregunta de negocio: como evitamos la burbuja de filtro.
--
-- El ranking puro por afinidad devuelve diez notas de la misma seccion,
-- porque el centroide del usuario apunta ahi. Esta variante toma los
-- mejores candidatos y despues se queda con a lo sumo dos por seccion.
--
-- Es un compromiso explicito: se resigna precision para ganar
-- diversidad. Sin este paso, el recomendador refuerza lo que el usuario
-- ya consume y el catalogo largo nunca se muestra.
-- ============================================================

WITH candidatos AS (
    SELECT
        p.contenido_id,
        p.titulo,
        p.seccion,
        p.seccion_id,
        1 - (e.embedding <=> (
            SELECT embedding FROM recomendacion.perfiles_usuario WHERE usuario_id = 1
        )) AS afinidad
    FROM recomendacion.embeddings_contenido AS e
    JOIN catalogo.vw_contenidos_publicables AS p
        ON p.contenido_id = e.contenido_id
    WHERE p.nivel_acceso <= 1
    ORDER BY e.embedding <=> (
        SELECT embedding FROM recomendacion.perfiles_usuario WHERE usuario_id = 1
    )
    LIMIT 60
),
numerados AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (PARTITION BY c.seccion_id ORDER BY c.afinidad DESC) AS orden_en_seccion
    FROM candidatos AS c
)
SELECT
    contenido_id,
    titulo,
    seccion,
    ROUND(afinidad::NUMERIC, 4) AS afinidad
FROM numerados
WHERE orden_en_seccion <= 2
ORDER BY afinidad DESC
LIMIT 10;

-- ============================================================
-- Consulta 4: Vecinos precalculados contra vecinos en vivo
--
-- Pregunta de negocio: podemos servir el "mas como este" desde una
-- tabla en lugar de calcularlo en cada request.
--
-- Compara lo guardado en ranking_items_similares (kNN exacto, calculado
-- por lote) contra el resultado que da el indice aproximado ahora.
-- La diferencia entre ambos ES el recall del indice.
-- ============================================================

WITH precalculado AS (
    SELECT contenido_similar_id, score
    FROM recomendacion.ranking_items_similares
    WHERE contenido_id = 1
      AND origen = 'embedding'
    ORDER BY score DESC
    LIMIT 10
),
en_vivo AS (
    SELECT
        e.contenido_id AS contenido_similar_id,
        ROUND((1 - (e.embedding <=> base.embedding))::NUMERIC, 6) AS score
    FROM recomendacion.embeddings_contenido AS base
    JOIN recomendacion.embeddings_contenido AS e
        ON e.contenido_id <> base.contenido_id
    WHERE base.contenido_id = 1
    ORDER BY e.embedding <=> base.embedding
    LIMIT 10
)
SELECT
    COALESCE(p.contenido_similar_id, v.contenido_similar_id) AS contenido_similar_id,
    p.score AS score_precalculado,
    v.score AS score_en_vivo,
    CASE
        WHEN p.contenido_similar_id IS NULL THEN 'solo en vivo'
        WHEN v.contenido_similar_id IS NULL THEN 'solo precalculado'
        ELSE 'coincide'
    END AS estado
FROM precalculado AS p
FULL OUTER JOIN en_vivo AS v
    ON v.contenido_similar_id = p.contenido_similar_id
ORDER BY COALESCE(p.score, v.score) DESC;

-- ============================================================
-- Consulta 5: Deteccion de contenido duplicado
--
-- Pregunta de negocio: la redaccion publico dos veces la misma nota.
--
-- Es el mismo mecanismo de similitud aplicado a un problema editorial,
-- no de recomendacion: pares con similitud muy alta que fueron
-- publicados con pocos dias de diferencia.
-- ============================================================

SELECT
    r.contenido_id,
    c1.titulo AS titulo_original,
    r.contenido_similar_id,
    c2.titulo AS titulo_similar,
    r.score,
    ABS(EXTRACT(DAY FROM c1.fecha_publicacion - c2.fecha_publicacion)) AS dias_de_diferencia
FROM recomendacion.ranking_items_similares AS r
JOIN catalogo.contenidos AS c1
    ON c1.id = r.contenido_id
JOIN catalogo.contenidos AS c2
    ON c2.id = r.contenido_similar_id
WHERE r.origen = 'embedding'
  AND r.score > 0.97
  AND r.contenido_id < r.contenido_similar_id
  AND ABS(EXTRACT(DAY FROM c1.fecha_publicacion - c2.fecha_publicacion)) <= 7
ORDER BY r.score DESC
LIMIT 10;
