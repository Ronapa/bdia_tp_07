-- Objetivo: medir el efecto de los indices vectoriales en lugar de asumirlo.
-- Requiere / entradas: indices creados por vectorial/01_crear_indices_vectoriales.sql.
-- Produce / modifica: nada; solo planes de ejecucion.
-- Resultado esperado: Seq Scan sin indice, Index Scan con HNSW, y menos filas leidas.
-- Guia: ejecutar bloque por bloque desde pgAdmin y comparar los planes.

-- ============================================================
-- 1. Busqueda exacta: sin indice
--
-- Con enable_indexscan apagado, PostgreSQL calcula la distancia contra
-- TODOS los vectores y despues ordena. Es exacto y es O(n).
-- ============================================================

BEGIN;
SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;

EXPLAIN (ANALYZE, BUFFERS)
SELECT contenido_id
FROM recomendacion.embeddings_contenido
ORDER BY embedding <=> (
    SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
)
LIMIT 10;

COMMIT;

-- ============================================================
-- 2. Busqueda aproximada: con indice
--
-- Ahora el planificador puede elegir HNSW o IVFFlat.
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT contenido_id
FROM recomendacion.embeddings_contenido
ORDER BY embedding <=> (
    SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
)
LIMIT 10;

-- ============================================================
-- 3. Forzar HNSW y ajustar ef_search
--
-- ef_search controla cuantos candidatos explora el grafo antes de
-- devolver el top-K. Mas alto = mejor recall y mas latencia.
-- El valor por defecto es 40.
-- ============================================================

BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL hnsw.ef_search = 100;

EXPLAIN (ANALYZE, BUFFERS)
SELECT contenido_id
FROM recomendacion.embeddings_contenido
ORDER BY embedding <=> (
    SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
)
LIMIT 10;

COMMIT;

-- ============================================================
-- 4. El problema del recall silencioso de IVFFlat
--
-- ivfflat.probes indica cuantas de las 50 listas se recorren.
-- Con el valor por defecto (1), se recorre una sola lista: alrededor
-- de un 2% del catalogo. Si los verdaderos vecinos estan en otra lista,
-- no aparecen, y la consulta NO da ningun error.
--
-- Este bloque lo hace visible: contar cuantas filas devuelve un
-- LIMIT 10 con probes = 1 y con probes = 50.
--
-- Es la razon por la que el calculo por lote de
-- vectorial/01_crear_indices_vectoriales.sql apaga los indices.
-- ============================================================

BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL enable_indexscan = on;
SET LOCAL ivfflat.probes = 1;

SELECT 'probes = 1' AS configuracion, COUNT(*) AS vecinos_devueltos
FROM (
    SELECT contenido_id
    FROM recomendacion.embeddings_contenido
    WHERE contenido_id <> 1
    ORDER BY embedding <=> (
        SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
    )
    LIMIT 10
) AS resultado;

COMMIT;

BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL ivfflat.probes = 50;

SELECT 'probes = 50' AS configuracion, COUNT(*) AS vecinos_devueltos
FROM (
    SELECT contenido_id
    FROM recomendacion.embeddings_contenido
    WHERE contenido_id <> 1
    ORDER BY embedding <=> (
        SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
    )
    LIMIT 10
) AS resultado;

COMMIT;

-- ============================================================
-- 5. El costo del prefiltrado
--
-- Un indice vectorial ordena por distancia, no por estado de
-- publicacion. Cuando el WHERE descarta muchas filas, PostgreSQL tiene
-- que recorrer mas candidatos del indice para llegar a 10 que pasen el
-- filtro, o directamente abandonar el indice.
--
-- Es el compromiso real del prefiltrado, y es el precio que se paga a
-- cambio de que no se filtre contenido no autorizado.
-- ============================================================

EXPLAIN (ANALYZE, BUFFERS)
SELECT p.contenido_id, p.titulo
FROM recomendacion.embeddings_contenido AS e
JOIN catalogo.vw_contenidos_publicables AS p
    ON p.contenido_id = e.contenido_id
WHERE p.nivel_acceso <= 0
ORDER BY e.embedding <=> (
    SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
)
LIMIT 10;

-- ============================================================
-- 6. Tamano de cada indice
--
-- Deja a la vista lo que cuesta cada estructura. Con volumenes chicos
-- el indice puede pesar mas que la tabla; lo que importa es como
-- escalan, no el valor absoluto de este dataset.
-- ============================================================

SELECT
    indexrelname AS indice,
    pg_size_pretty(pg_relation_size(indexrelid)) AS tamano,
    idx_scan AS veces_usado
FROM pg_stat_user_indexes
WHERE schemaname = 'recomendacion'
  AND indexrelname LIKE '%embedding%' OR indexrelname LIKE '%perfiles%'
ORDER BY pg_relation_size(indexrelid) DESC;

-- ============================================================
-- Nota honesta sobre la escala de esta practica
--
-- Con unos pocos miles de vectores, la busqueda exacta puede ser tan
-- rapida como la aproximada, e incluso mas. Los indices vectoriales
-- empiezan a pagar a partir de cientos de miles de filas.
--
-- Lo que NO cambia con la escala es la forma del plan: O(n) contra
-- O(log n). Eso es lo que hay que mirar en el EXPLAIN, no los
-- milisegundos de este dataset.
-- ============================================================
