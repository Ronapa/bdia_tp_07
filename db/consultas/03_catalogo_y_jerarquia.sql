-- Objetivo: consultar el catalogo por su jerarquia, sus etiquetas y sus metadatos variables.
-- Requiere / entradas: catalogo cargado y vistas de db/indices_vistas/02_vistas.sql.
-- Produce / modifica: nada; solo lee.
-- Resultado esperado: el arbol de secciones recorrido, rankings por seccion y consultas sobre JSONB.
-- Guia: cubre relaciones jerarquicas, N:M y datos semiestructurados, que son tres puntos de la consigna.

-- ============================================================
-- Consulta 1: El arbol de secciones completo
--
-- Pregunta de negocio: como se organiza editorialmente el sitio.
--
-- WITH RECURSIVE recorre la relacion autoreferenciada. El caso base son
-- las secciones sin padre; el paso recursivo baja un nivel por iteracion
-- y va acumulando el camino.
--
-- La alternativa sin recursion seria un LEFT JOIN por nivel, que fija la
-- profundidad maxima en el codigo: agregar un cuarto nivel obligaria a
-- reescribir todas las consultas del sistema.
-- ============================================================


WITH RECURSIVE arbol AS (
    SELECT
        s.id,
        s.nombre,
        s.seccion_padre_id,
        1 AS profundidad,
        s.nombre::TEXT AS camino,
        ARRAY[s.id] AS rama
    FROM catalogo.secciones AS s
    WHERE s.seccion_padre_id IS NULL

    UNION ALL

    SELECT
        h.id,
        h.nombre,
        h.seccion_padre_id,
        a.profundidad + 1,
        (a.camino || ' > ' || h.nombre)::TEXT,
        a.rama || h.id
    FROM catalogo.secciones AS h
    JOIN arbol AS a
        ON a.id = h.seccion_padre_id
    -- Guarda contra ciclos: sin esta condicion, un dato corrupto con una
    -- seccion que se referencia a si misma haria que la consulta no
    -- termine nunca.
    WHERE NOT h.id = ANY(a.rama)
      AND a.profundidad < 10
)
SELECT
    REPEAT('   ', profundidad - 1) || nombre AS seccion,
    profundidad,
    camino,
    (SELECT COUNT(*) FROM catalogo.contenidos AS c
     WHERE c.seccion_id = arbol.id AND c.estado = 'publicado') AS contenidos_publicados
FROM arbol
ORDER BY camino;

-- ============================================================
-- Consulta 2: Contenidos publicados por seccion raiz
--
-- Pregunta de negocio: que peso tiene cada area de la redaccion.
--
-- Usa la vista vw_arbol_secciones, que ya resolvio la recursion: agrupar
-- por seccion_raiz sin ella exigiria repetir el WITH RECURSIVE en cada
-- consulta analitica del sistema.
-- ============================================================

SELECT
    a.seccion_raiz,
    COUNT(*) AS contenidos,
    COUNT(*) FILTER (WHERE c.estado = 'publicado') AS publicados,
    COUNT(*) FILTER (WHERE c.estado = 'borrador') AS borradores,
    COUNT(*) FILTER (WHERE c.nivel_acceso = 2) AS premium,
    ROUND(100.0 * COUNT(*) FILTER (WHERE c.nivel_acceso = 2) / COUNT(*), 1) AS porcentaje_premium,
    ROUND(AVG(c.duracion_seg) FILTER (WHERE c.duracion_seg IS NOT NULL), 0) AS duracion_promedio_seg
FROM catalogo.contenidos AS c
JOIN catalogo.vw_arbol_secciones AS a
    ON a.seccion_id = c.seccion_id
GROUP BY a.seccion_raiz
ORDER BY contenidos DESC;

-- ============================================================
-- Consulta 3: Top de contenidos por seccion
--
-- Pregunta de negocio: cual es la nota mas leida de cada seccion.
--
-- RANK() OVER (PARTITION BY ...) resuelve el clasico top-N por grupo.
-- Sin funciones de ventana habria que escribir una subconsulta
-- correlacionada por cada seccion, que ademas escala mal.
-- ============================================================

WITH consumo AS (
    SELECT
        f.contenido_key AS contenido_id,
        SUM(f.vistas) AS vistas,
        SUM(f.vistas_completas) AS completadas,
        SUM(f.usuarios_unicos) AS usuarios
    FROM analitica.fact_consumo_diario AS f
    GROUP BY f.contenido_key
),
rankeado AS (
    SELECT
        d.seccion_raiz,
        d.contenido_id,
        d.titulo,
        d.tipo_contenido,
        c.vistas,
        c.completadas,
        ROUND(100.0 * c.completadas / NULLIF(c.vistas, 0), 1) AS tasa_finalizacion,
        RANK() OVER (PARTITION BY d.seccion_raiz ORDER BY c.vistas DESC) AS posicion,
        ROUND(AVG(c.vistas) OVER (PARTITION BY d.seccion_raiz), 1) AS vistas_promedio_seccion
    FROM consumo AS c
    JOIN analitica.dim_contenido AS d
        ON d.contenido_key = c.contenido_id
    WHERE d.estado = 'publicado'
)
SELECT
    seccion_raiz,
    posicion,
    titulo,
    tipo_contenido,
    vistas,
    vistas_promedio_seccion,
    ROUND(vistas - vistas_promedio_seccion, 1) AS diferencia_vs_promedio,
    tasa_finalizacion
FROM rankeado
WHERE posicion <= 3
ORDER BY seccion_raiz, posicion;




-- ============================================================
-- Consulta 4: Etiquetas mas usadas y su rendimiento
--
-- Pregunta de negocio: que temas convocan.
--
-- Recorre la relacion N:M entre contenidos y etiquetas. La tabla puente
-- es la que permite responder esto: con las etiquetas guardadas como
-- array de texto dentro de contenidos habria que desarmar el array en
-- cada consulta y no habria forma de garantizar que "elecciones" y
-- "Elecciones" son la misma etiqueta.
-- ============================================================

SELECT
    e.nombre AS etiqueta,
    COUNT(DISTINCT ce.contenido_id) AS contenidos,
    COUNT(DISTINCT c.seccion_id) AS secciones_distintas,
    ROUND(AVG(ce.relevancia), 3) AS relevancia_promedio,
    COALESCE(SUM(f.vistas), 0) AS vistas_totales
FROM catalogo.etiquetas AS e
JOIN catalogo.contenidos_etiquetas AS ce
    ON ce.etiqueta_id = e.id
JOIN catalogo.contenidos AS c
    ON c.id = ce.contenido_id
LEFT JOIN analitica.fact_consumo_diario AS f
    ON f.contenido_key = c.id
WHERE c.estado = 'publicado'
GROUP BY e.nombre
HAVING COUNT(DISTINCT ce.contenido_id) >= 3
ORDER BY vistas_totales DESC, contenidos DESC
LIMIT 20;




-- ============================================================
-- Consulta 5: Metadatos variables con JSONB
--
-- Pregunta de negocio: cuantos videos publicamos en 4k, y con que
-- proveedor.
--
-- Es la consulta que justifica haber usado JSONB en vez de una columna
-- por atributo. `resolucion` solo existe en los videos, `cantidad_fotos`
-- solo en las galerias, `envio` solo en los newsletters. Como columnas,
-- serian tres columnas con 80% de NULL cada una.
--
-- Los dos operadores responden preguntas distintas:
--   @>  contencion: "el JSON contiene este par clave-valor"  -> GIN jsonb_path_ops
--   ?   existencia: "el JSON tiene esta clave"               -> GIN por defecto
-- ============================================================

SELECT
    c.metadatos ->> 'proveedor' AS proveedor,
    c.metadatos ->> 'resolucion' AS resolucion,
    COUNT(*) AS videos,
    COUNT(*) FILTER (WHERE c.metadatos @> '{"destacado": true}') AS destacados,
    COUNT(*) FILTER (WHERE c.metadatos ? 'patrocinado') AS patrocinados
FROM catalogo.contenidos AS c
JOIN catalogo.tipos_contenido AS tc
    ON tc.id = c.tipo_contenido_id
WHERE tc.codigo = 'video'
  AND c.metadatos ? 'resolucion'
GROUP BY 1, 2
ORDER BY videos DESC;

-- Contenidos patrocinados y destacados a la vez: el operador @> usa el
-- indice GIN jsonb_path_ops y filtra por el par completo.
SELECT
    c.id,
    c.titulo,
    tc.codigo AS tipo,
    c.metadatos
FROM catalogo.contenidos AS c
JOIN catalogo.tipos_contenido AS tc
    ON tc.id = c.tipo_contenido_id
WHERE c.metadatos @> '{"patrocinado": true, "destacado": true}'
  AND c.estado = 'publicado'
ORDER BY c.fecha_publicacion DESC
LIMIT 10;



-- ============================================================
-- Consulta 6: Historial editorial de un contenido
--
-- Pregunta de negocio: quien toco esta nota y que cambio.
--
-- Combina las versiones (JSONB con el diff) con la moderacion.
-- jsonb_object_keys desarma el diff para mostrar que campos se editaron.
-- ============================================================

SELECT
    v.numero_version,
    v.editor_id,
    v.creado_en,
    v.comentario,
    COALESCE(
        (SELECT STRING_AGG(clave, ', ' ORDER BY clave)
         FROM jsonb_object_keys(v.cambios) AS clave),
        'sin cambios registrados'
    ) AS campos_modificados
FROM catalogo.versiones_contenido AS v
WHERE v.contenido_id = 1
ORDER BY v.numero_version;
