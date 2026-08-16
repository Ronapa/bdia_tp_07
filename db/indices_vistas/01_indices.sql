-- Objetivo: crear los indices que sostienen los patrones de consulta reales del sistema.
-- Requiere / entradas: todas las tablas creadas por db/estructura/.
-- Produce / modifica: indices btree, parciales, compuestos, GIN y BRIN; no modifica datos.
-- Resultado esperado: los indices listados al final del script.
-- Guia: cada indice esta justificado por una consulta concreta; los indices sin consulta que los use son costo puro.

-- ============================================================
-- 1. Claves foraneas
--
-- PostgreSQL indexa automaticamente la PK, pero NO el lado "muchos"
-- de una foranea. Sin estos indices, borrar o actualizar una fila del
-- lado "uno" obliga a un Seq Scan de la tabla hija para validar la FK.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_contenidos_seccion_id
    ON catalogo.contenidos(seccion_id);

CREATE INDEX IF NOT EXISTS idx_contenidos_autor_id
    ON catalogo.contenidos(autor_id);

CREATE INDEX IF NOT EXISTS idx_contenidos_tipo_contenido_id
    ON catalogo.contenidos(tipo_contenido_id);

CREATE INDEX IF NOT EXISTS idx_contenidos_etiquetas_etiqueta_id
    ON catalogo.contenidos_etiquetas(etiqueta_id);

CREATE INDEX IF NOT EXISTS idx_versiones_contenido_contenido_id
    ON catalogo.versiones_contenido(contenido_id);

CREATE INDEX IF NOT EXISTS idx_moderaciones_contenido_id
    ON catalogo.moderaciones(contenido_id);

CREATE INDEX IF NOT EXISTS idx_secciones_seccion_padre_id
    ON catalogo.secciones(seccion_padre_id);

CREATE INDEX IF NOT EXISTS idx_preferencias_usuario_usuario_id
    ON personas.preferencias_usuario(usuario_id);

CREATE INDEX IF NOT EXISTS idx_suscripciones_usuario_id
    ON personas.suscripciones(usuario_id);

CREATE INDEX IF NOT EXISTS idx_ranking_items_similares_similar_id
    ON recomendacion.ranking_items_similares(contenido_similar_id);

-- ============================================================
-- 2. Indice parcial del feed
--
-- La consulta central del sistema (db/consultas/01_feed_personalizado.sql)
-- filtra siempre por estado = 'publicado' y ordena por fecha_publicacion.
-- Sobre 3.000 contenidos, los publicados son ~70%: el indice parcial
-- ocupa menos, entra mejor en cache y ademas le comunica al planificador
-- que la condicion del WHERE ya esta garantizada por el indice.
--
-- Es el indice que justifica el EXPLAIN de vectorial/consultas/02_explain_indices.sql.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_contenidos_publicados_fecha
    ON catalogo.contenidos(fecha_publicacion DESC)
    WHERE estado = 'publicado';

-- Variante por seccion: el feed de una seccion filtra por seccion_id y
-- nivel_acceso antes de ordenar. Indice compuesto para que el orden salga
-- del indice y no de un Sort posterior.
CREATE INDEX IF NOT EXISTS idx_contenidos_publicados_seccion_acceso
    ON catalogo.contenidos(seccion_id, nivel_acceso, fecha_publicacion DESC)
    WHERE estado = 'publicado';

-- ============================================================
-- 3. Indice unico parcial: una sola suscripcion activa por usuario
--
-- Es una regla de negocio que un CHECK no puede expresar, porque
-- involucra varias filas de la misma tabla. Un indice unico parcial si.
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_suscripciones_activa_unica
    ON personas.suscripciones(usuario_id)
    WHERE estado = 'activa';

-- ============================================================
-- 4. Indices GIN sobre JSONB
--
-- jsonb_path_ops indexa solo los caminos completos (clave + valor), no
-- las claves sueltas. Es entre 2 y 3 veces mas chico que el GIN por
-- defecto y mas rapido para el operador @>, que es el que usan las
-- consultas de metadatos. El precio es que NO soporta el operador ?
-- (existencia de clave), asi que se crean los dos: cada uno responde
-- a un patron de consulta distinto de db/consultas/03_catalogo_y_jerarquia.sql.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_contenidos_metadatos_path
    ON catalogo.contenidos USING GIN (metadatos jsonb_path_ops);

CREATE INDEX IF NOT EXISTS idx_contenidos_metadatos_claves
    ON catalogo.contenidos USING GIN (metadatos);

CREATE INDEX IF NOT EXISTS idx_versiones_contenido_cambios
    ON catalogo.versiones_contenido USING GIN (cambios jsonb_path_ops);

-- ============================================================
-- 5. Busqueda literal en espanol
--
-- Convive con la busqueda vectorial, no compite: el indice GIN sobre
-- tsvector resuelve la coincidencia exacta de terminos (nombres propios,
-- siglas) que el embedding tiende a difuminar. La comparacion entre
-- ambas esta en vectorial/consultas/03_literal_vs_semantica.sql.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_contenidos_titulo_tsv
    ON catalogo.contenidos
    USING GIN (to_tsvector('spanish', titulo || ' ' || COALESCE(bajada, '')));

-- ============================================================
-- 6. Indices de la tabla particionada de impresiones
--
-- Se crean sobre la tabla padre: PostgreSQL los propaga a cada particion
-- existente y a las que se creen despues.
--
-- (usuario_id, mostrado_en DESC) -> "que le mostramos a este usuario"
-- (estrategia_id, mostrado_en)   -> calculo de CTR por estrategia
-- BRIN sobre mostrado_en         -> las filas se insertan en orden
--                                   cronologico, asi que la correlacion
--                                   fisica es casi perfecta. Un BRIN ocupa
--                                   unos pocos KB donde un btree ocuparia
--                                   decenas de MB, y alcanza para descartar
--                                   bloques en los barridos por rango.
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_impresiones_usuario_fecha
    ON recomendacion.impresiones(usuario_id, mostrado_en DESC);

CREATE INDEX IF NOT EXISTS idx_impresiones_estrategia_fecha
    ON recomendacion.impresiones(estrategia_id, mostrado_en);

CREATE INDEX IF NOT EXISTS idx_impresiones_contenido
    ON recomendacion.impresiones(contenido_id);

CREATE INDEX IF NOT EXISTS idx_impresiones_mostrado_en_brin
    ON recomendacion.impresiones USING BRIN (mostrado_en);

-- Indice parcial sobre los clics: son ~4% de las filas, y el analisis de
-- conversion los consulta siempre solos.
CREATE INDEX IF NOT EXISTS idx_impresiones_con_clic
    ON recomendacion.impresiones(contenido_id, mostrado_en)
    WHERE clic = TRUE;

-- ============================================================
-- 7. Auditoria y capa analitica
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_auditoria_eventos_tabla_fecha
    ON auditoria.eventos(esquema, tabla, ocurrido_en DESC);

CREATE INDEX IF NOT EXISTS idx_auditoria_eventos_usuario_app
    ON auditoria.eventos(usuario_app, ocurrido_en DESC);

CREATE INDEX IF NOT EXISTS idx_agg_popularidad_ventana_score
    ON analitica.agg_popularidad(ventana, score DESC);

CREATE INDEX IF NOT EXISTS idx_fact_impresiones_fecha
    ON analitica.fact_impresiones_diario(fecha_key);

CREATE INDEX IF NOT EXISTS idx_fact_consumo_fecha
    ON analitica.fact_consumo_diario(fecha_key);

-- ============================================================
-- 8. Verificacion
-- ============================================================

SELECT
    schemaname AS esquema,
    tablename  AS tabla,
    indexname  AS indice
FROM pg_indexes
WHERE schemaname IN ('personas', 'catalogo', 'recomendacion', 'analitica', 'auditoria')
  AND indexname LIKE 'idx_%'
ORDER BY schemaname, tablename, indexname;
