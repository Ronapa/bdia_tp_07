-- Objetivo: crear los indices vectoriales y precalcular los vecinos semanticos de cada contenido.
-- Requiere / entradas: embeddings ya cargados por orquestador/generar_embeddings.py.
-- Produce / modifica: indices HNSW e IVFFlat, y filas en recomendacion.ranking_items_similares.
-- Resultado esperado: los dos indices creados y hasta 10 vecinos por contenido publicado.
-- Guia: los indices se crean DESPUES de cargar; IVFFlat directamente necesita datos para entrenarse.

-- ============================================================
-- 1. Indices
--
-- Se crean los dos para poder compararlos en
-- vectorial/consultas/02_explain_indices.sql.
--
-- HNSW (grafo jerarquico navegable):
--   + No necesita entrenamiento previo ni conocer el volumen.
--   + Mejor recall a igual latencia.
--   + Soporta bien las inserciones incrementales, que es lo que pasa
--     cuando la redaccion publica durante el dia.
--   - Construccion mas lenta y mas memoria.
--
-- IVFFlat (listas invertidas por centroide):
--   + Construccion rapida y liviana.
--   - Hay que elegir `lists` en funcion del volumen, y si el volumen
--     cambia mucho el indice se degrada hasta que se lo recrea.
--
-- Para este caso conviene HNSW: el catalogo crece todos los dias y no
-- hay una ventana natural para reconstruir el indice.
--
-- La clase de operador tiene que coincidir con el operador de la
-- consulta: vector_cosine_ops <-> el operador <=>. Si no coinciden,
-- PostgreSQL NO usa el indice y tampoco avisa: la consulta sigue
-- funcionando, solo que con un Seq Scan.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_embeddings_contenido_hnsw
    ON recomendacion.embeddings_contenido
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

-- lists como referencia de partida: aproximadamente sqrt(cantidad_filas).
-- Con 3.000 contenidos, ~55. Se deja en 50 y se ajusta midiendo.
CREATE INDEX IF NOT EXISTS idx_embeddings_contenido_ivfflat
    ON recomendacion.embeddings_contenido
    USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 50);

-- El perfil de usuario tambien se consulta por similitud, en el sentido
-- inverso: dado un contenido, que usuarios lo tendrian cerca.
CREATE INDEX IF NOT EXISTS idx_perfiles_usuario_hnsw
    ON recomendacion.perfiles_usuario
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);

ANALYZE recomendacion.embeddings_contenido;
ANALYZE recomendacion.perfiles_usuario;

-- ============================================================
-- 2. Vecinos semanticos precalculados
--
-- Resolver la similitud en el momento del request cuesta una busqueda
-- vectorial por cada tarjeta del feed. Precalcular los 10 vecinos de
-- cada contenido convierte eso en una lectura por clave primaria.
--
-- El calculo se hace con LATERAL: por cada contenido publicado, la
-- subconsulta se ejecuta con ese contenido ya fijado y puede usar el
-- indice HNSW. Es el equivalente vectorial de un top-N por grupo.
--
-- Solo se calculan vecinos entre contenidos PUBLICADOS: un vecino que
-- resulta ser un borrador no sirve para recomendar y ademas seria una
-- via para filtrar contenido no publicado.
--
-- IMPORTANTE: por que este bloque desactiva los indices.
--
-- HNSW e IVFFlat son indices APROXIMADOS: cambian recall por latencia,
-- que es exactamente lo que uno quiere en el camino del request. En un
-- calculo por lote, en cambio, uno quiere los vecinos correctos.
--
-- El efecto es medible: con IVFFlat y el valor por defecto
-- `ivfflat.probes = 1`, PostgreSQL escanea una sola de las 50 listas y
-- devuelve MENOS filas que el LIMIT 10 pedido. La consulta no falla ni
-- avisa: entrega 1 o 2 vecinos en lugar de 10.
--
-- Ese es el riesgo real de las busquedas aproximadas: no se equivocan
-- ruidosamente, se equivocan en silencio. Aca se apaga el uso de
-- indices para obtener el kNN exacto, y los indices quedan para las
-- consultas en linea, donde la latencia si manda.
-- ============================================================

-- SET LOCAL solo tiene efecto dentro de una transaccion; fuera de una,
-- PostgreSQL emite un WARNING y lo ignora. Se abre la transaccion de
-- forma explicita para que el ajuste valga y se revierta solo al COMMIT.
BEGIN;

SET LOCAL enable_indexscan = off;
SET LOCAL enable_bitmapscan = off;

DELETE FROM recomendacion.ranking_items_similares WHERE origen = 'embedding';

INSERT INTO recomendacion.ranking_items_similares (
    contenido_id, contenido_similar_id, origen, score
)
SELECT
    base.contenido_id,
    vecino.contenido_id,
    'embedding' AS origen,
    -- El operador <=> devuelve DISTANCIA coseno (0 = identico).
    -- Se guarda como score de similitud, que es lo que consume el
    -- recomendador: mayor es mejor.
    ROUND((1 - vecino.distancia)::NUMERIC, 6) AS score
FROM (
    SELECT e.contenido_id, e.embedding
    FROM recomendacion.embeddings_contenido AS e
    JOIN catalogo.contenidos AS c
        ON c.id = e.contenido_id
    WHERE c.estado = 'publicado'
) AS base
CROSS JOIN LATERAL (
    SELECT
        e2.contenido_id,
        e2.embedding <=> base.embedding AS distancia
    FROM recomendacion.embeddings_contenido AS e2
    JOIN catalogo.contenidos AS c2
        ON c2.id = e2.contenido_id
    WHERE c2.estado = 'publicado'
      AND e2.contenido_id <> base.contenido_id
    ORDER BY e2.embedding <=> base.embedding
    LIMIT 10
) AS vecino
WHERE (1 - vecino.distancia) > 0;

COMMIT;

ANALYZE recomendacion.ranking_items_similares;

-- ============================================================
-- 3. Verificacion
-- ============================================================

DO $$
DECLARE
    con_indice INTEGER;
    vecinos    BIGINT;
    dimensiones INTEGER;
    modelos    INTEGER;
BEGIN
    SELECT COUNT(*) INTO con_indice
    FROM pg_indexes
    WHERE schemaname = 'recomendacion'
      AND indexname IN ('idx_embeddings_contenido_hnsw',
                        'idx_embeddings_contenido_ivfflat',
                        'idx_perfiles_usuario_hnsw');

    IF con_indice <> 3 THEN
        RAISE EXCEPTION 'Se esperaban 3 indices vectoriales y hay %.', con_indice;
    END IF;

    -- Todos los vectores tienen que tener la misma dimension y venir del
    -- mismo modelo. Mezclar modelos produce un ranking silenciosamente
    -- incorrecto: no falla, simplemente compara espacios distintos.
    SELECT COUNT(DISTINCT vector_dims(embedding)) INTO dimensiones
    FROM recomendacion.embeddings_contenido;
    SELECT COUNT(DISTINCT modelo_embedding) INTO modelos
    FROM recomendacion.embeddings_contenido;

    IF dimensiones <> 1 OR modelos <> 1 THEN
        RAISE EXCEPTION
            'Los embeddings mezclan % dimension(es) y % modelo(s); deben ser 1 y 1.',
            dimensiones, modelos;
    END IF;

    SELECT COUNT(*) INTO vecinos
    FROM recomendacion.ranking_items_similares
    WHERE origen = 'embedding';

    IF vecinos = 0 THEN
        RAISE EXCEPTION 'No se calculo ningun vecino semantico.';
    END IF;

    -- Cada contenido publicado debe tener sus 10 vecinos (o tantos como
    -- contenidos publicados haya, si el catalogo fuera menor). Si el
    -- promedio baja de 9, el kNN esta devolviendo de menos: es el sintoma
    -- de una busqueda aproximada mal configurada.
    IF vecinos < (SELECT COUNT(*) FROM catalogo.contenidos WHERE estado = 'publicado') * 9 THEN
        RAISE EXCEPTION
            'Se calcularon solo % vecinos: el kNN devolvio menos de 9 por contenido.',
            vecinos;
    END IF;

    RAISE NOTICE 'Indices vectoriales verificados. Vecinos calculados: %', vecinos;
END;
$$;

SELECT
    modelo_embedding,
    COUNT(*) AS contenidos,
    MIN(vector_dims(embedding)) AS dimensiones
FROM recomendacion.embeddings_contenido
GROUP BY modelo_embedding;

SELECT
    origen,
    COUNT(*) AS pares,
    COUNT(DISTINCT contenido_id) AS contenidos_con_vecinos,
    ROUND(AVG(score), 4) AS score_promedio
FROM recomendacion.ranking_items_similares
GROUP BY origen
ORDER BY origen;
