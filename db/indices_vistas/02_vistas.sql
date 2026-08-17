-- Objetivo: encapsular en vistas las reglas de negocio que se repiten en toda consulta del catalogo.
-- Requiere / entradas: tablas de db/estructura/ e indices de 01_indices.sql.
-- Produce / modifica: vistas del schema catalogo y recomendacion; no materializa datos.
-- Resultado esperado: cuatro vistas consultables.
-- Guia: una vista no acelera nada por si sola; lo que evita es que la regla se escriba distinto en cada consulta.

-- ============================================================
-- IMPORTANTE: security_invoker
--
-- Por defecto una vista se ejecuta con los privilegios de su DUENO.
-- Como estas vistas las crea el superusuario, sin security_invoker
-- cualquier rol con SELECT sobre la vista leeria las tablas base con
-- los permisos del superusuario, y las politicas de Row Level Security
-- de catalogo.contenidos quedarian anuladas. La vista se convertiria
-- en una puerta trasera silenciosa: no falla, simplemente devuelve
-- borradores y contenido premium a quien no corresponde.
--
-- Con security_invoker = TRUE la vista se evalua con los privilegios
-- de quien consulta, y el RLS se aplica como corresponde.
--
-- La unica vista que a proposito NO usa security_invoker es
-- personas.vw_usuarios_anonimizado (db/seguridad/04_vistas_anonimizadas.sql):
-- ahi la elevacion de privilegios es el mecanismo, no un descuido.
-- ============================================================

-- ============================================================
-- Vista: catalogo.vw_contenidos_publicables
--
-- "Publicable" no es lo mismo que "publicado". Un contenido es
-- publicable cuando, ademas de estar publicado, su ventana de vigencia
-- esta abierta. Esa condicion aparece en el feed, en la busqueda
-- semantica, en el trending y en el grafo: escrita cuatro veces, tarde
-- o temprano una de las cuatro se olvida de la vigencia y el sistema
-- recomienda una nota vencida.
--
-- Trae la seccion y el tipo resueltos porque practicamente ninguna
-- consulta los necesita como id.
-- ============================================================

CREATE OR REPLACE VIEW catalogo.vw_contenidos_publicables
WITH (security_invoker = TRUE) AS
SELECT
    c.id AS contenido_id,
    c.titulo,
    c.bajada,
    c.nivel_acceso,
    c.idioma,
    c.duracion_seg,
    c.fecha_publicacion,
    c.vigente_hasta,
    c.metadatos,
    c.autor_id,
    tc.codigo AS tipo_contenido,
    s.id AS seccion_id,
    s.slug AS seccion_slug,
    s.nombre AS seccion
FROM catalogo.contenidos AS c
JOIN catalogo.tipos_contenido AS tc
    ON tc.id = c.tipo_contenido_id
JOIN catalogo.secciones AS s
    ON s.id = c.seccion_id
WHERE c.estado = 'publicado'
  AND c.fecha_publicacion <= CURRENT_TIMESTAMP
  AND (c.vigente_hasta IS NULL OR c.vigente_hasta > CURRENT_TIMESTAMP);

-- ============================================================
-- Vista: catalogo.vw_arbol_secciones
--
-- Aplana la jerarquia autoreferenciada de secciones con WITH RECURSIVE:
-- devuelve para cada seccion su profundidad, su raiz y el camino
-- completo. Sin esto, agrupar el consumo "por seccion principal"
-- obliga a repetir la recursion en cada consulta analitica.
-- ============================================================

CREATE OR REPLACE VIEW catalogo.vw_arbol_secciones
WITH (security_invoker = TRUE) AS
WITH RECURSIVE arbol AS (
    SELECT
        s.id,
        s.slug,
        s.nombre,
        s.seccion_padre_id,
        1 AS profundidad,
        s.id AS seccion_raiz_id,
        s.nombre AS seccion_raiz,
        s.nombre::TEXT AS camino
    FROM catalogo.secciones AS s
    WHERE s.seccion_padre_id IS NULL

    UNION ALL

    SELECT
        h.id,
        h.slug,
        h.nombre,
        h.seccion_padre_id,
        a.profundidad + 1,
        a.seccion_raiz_id,
        a.seccion_raiz,
        (a.camino || ' > ' || h.nombre)::TEXT
    FROM catalogo.secciones AS h
    JOIN arbol AS a
        ON a.id = h.seccion_padre_id
)
SELECT
    id AS seccion_id,
    slug,
    nombre,
    seccion_padre_id,
    profundidad,
    seccion_raiz_id,
    seccion_raiz,
    camino
FROM arbol;

-- ============================================================
-- Vista: recomendacion.vw_rendimiento_estrategias
--
-- Calcula el CTR observado por estrategia y superficie directamente
-- sobre las impresiones. Es la version "en vivo" de lo que la capa
-- Gold precalcula por dia: sirve para contrastar que el pipeline
-- analitico esta produciendo los mismos numeros que el operacional.
-- ============================================================

CREATE OR REPLACE VIEW recomendacion.vw_rendimiento_estrategias
WITH (security_invoker = TRUE) AS
SELECT
    e.codigo AS estrategia,
    e.version,
    e.motor,
    i.superficie,
    COUNT(*) AS impresiones,
    COUNT(*) FILTER (WHERE i.clic) AS clics,
    ROUND(COUNT(*) FILTER (WHERE i.clic)::NUMERIC / NULLIF(COUNT(*), 0), 5) AS ctr,
    COUNT(DISTINCT i.contenido_id) AS contenidos_distintos,
    COUNT(DISTINCT i.usuario_id) AS usuarios_alcanzados
FROM recomendacion.impresiones AS i
JOIN recomendacion.estrategias AS e
    ON e.id = i.estrategia_id
GROUP BY e.codigo, e.version, e.motor, i.superficie;

-- ============================================================
-- Vista: recomendacion.vw_vetos_usuario
--
-- Reune en un solo lugar todo lo que un usuario NO puede recibir:
-- las secciones y etiquetas que marco como 'no_interesa'.
-- Cualquier estrategia debe restar este conjunto antes de rankear;
-- tenerlo como vista evita que una de las cuatro se lo saltee.
-- ============================================================

CREATE OR REPLACE VIEW recomendacion.vw_vetos_usuario
WITH (security_invoker = TRUE) AS
SELECT DISTINCT
    p.usuario_id,
    c.id AS contenido_id
FROM personas.preferencias_usuario AS p
JOIN catalogo.contenidos AS c
    ON (p.seccion_id IS NOT NULL AND c.seccion_id = p.seccion_id)
    OR (p.etiqueta_id IS NOT NULL AND EXISTS (
            SELECT 1
            FROM catalogo.contenidos_etiquetas AS ce
            WHERE ce.contenido_id = c.id
              AND ce.etiqueta_id = p.etiqueta_id
        ))
WHERE p.tipo_preferencia = 'no_interesa';
