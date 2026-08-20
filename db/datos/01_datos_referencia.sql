-- Objetivo: cargar los catalogos estables del dominio, que no dependen del generador sintetico.
-- Requiere / entradas: estructura creada por db/estructura/.
-- Produce / modifica: filas en planes, tipos_contenido, estrategias y experimentos_ab.
-- Resultado esperado: 3 planes, 5 tipos de contenido, 5 estrategias y 1 experimento A/B.
-- Guia: son datos de referencia, no datos de prueba; en produccion vivirian en una migracion igual que esta.

-- ============================================================
-- 1. Planes
--
-- nivel_acceso es el que compara la politica de RLS contra
-- catalogo.contenidos.nivel_acceso. El orden importa; los codigos, no.
-- ============================================================

INSERT INTO personas.planes (codigo, nombre, nivel_acceso)
VALUES
    ('gratuito', 'Acceso libre', 0),
    ('registrado', 'Registrado sin cargo', 1),
    ('premium', 'Suscripcion premium', 2)
ON CONFLICT (codigo) DO NOTHING;

-- ============================================================
-- 2. Tipos de contenido
-- ============================================================

INSERT INTO catalogo.tipos_contenido (codigo, nombre, admite_duracion)
VALUES
    ('articulo', 'Articulo', FALSE),
    ('video', 'Video', TRUE),
    ('podcast', 'Podcast', TRUE),
    ('newsletter', 'Newsletter', FALSE),
    ('galeria', 'Galeria de fotos', FALSE)
ON CONFLICT (codigo) DO NOTHING;

-- ============================================================
-- 3. Estrategias de recomendacion
--
-- La columna motor deja explicito que cada estrategia se apoya en un
-- motor distinto. Es el resumen operativo del argumento poliglota:
-- ninguna de las cinco se resolveria bien en los otros cuatro.
-- ============================================================

INSERT INTO recomendacion.estrategias (codigo, version, nombre, motor, descripcion)
VALUES
    ('popularidad', '1.0', 'Mas leidas con decaimiento temporal', 'duckdb',
     'Ranking por vistas recientes con decaimiento exponencial. Linea de base y red de contencion para el cold start.'),
    ('contenido_similar', '1.0', 'Similitud semantica de embeddings', 'pgvector',
     'Vecinos mas cercanos del contenido actual o del perfil del usuario, con prefiltrado de estado, vigencia y nivel de acceso.'),
    ('colaborativo_item', '1.0', 'Filtrado colaborativo item-item', 'duckdb',
     'Matriz de co-ocurrencia normalizada por coseno, calculada sobre la capa Silver del lakehouse.'),
    ('grafo_covisualizacion', '1.0', 'Co-visualizacion a dos saltos', 'neo4j',
     'Recorrido usuario -> contenido -> otros usuarios -> contenido, con explicacion del camino recorrido.'),
    ('hibrido', '1.0', 'Mezcla ponderada de las cuatro senales', 'hibrido',
     'Combina popularidad, similitud, co-ocurrencia y grafo, aplica los vetos declarados y diversifica por seccion.')
ON CONFLICT (codigo, version) DO NOTHING;

-- ============================================================
-- 4. Experimento A/B
-- ============================================================

INSERT INTO recomendacion.experimentos_ab (codigo, nombre, desde, hasta)
VALUES
    ('hibrido_vs_popularidad',
     'Estrategia hibrida contra ranking por popularidad',
     '2026-04-01 00:00:00+00',
     NULL)
ON CONFLICT (codigo) DO NOTHING;

-- ============================================================
-- 5. Verificacion
-- ============================================================

DO $$
DECLARE
    planes INTEGER;
    tipos INTEGER;
    estrategias INTEGER;
BEGIN
    SELECT COUNT(*) INTO planes FROM personas.planes;
    SELECT COUNT(*) INTO tipos FROM catalogo.tipos_contenido;
    SELECT COUNT(*) INTO estrategias FROM recomendacion.estrategias;

    IF planes <> 3 OR tipos <> 5 OR estrategias <> 5 THEN
        RAISE EXCEPTION
            'Datos de referencia incompletos: planes=%, tipos=%, estrategias=%',
            planes, tipos, estrategias;
    END IF;
END;
$$;

SELECT 'planes' AS catalogo, COUNT(*) AS cantidad FROM personas.planes
UNION ALL
SELECT 'tipos_contenido', COUNT(*) FROM catalogo.tipos_contenido
UNION ALL
SELECT 'estrategias', COUNT(*) FROM recomendacion.estrategias
UNION ALL
SELECT 'experimentos_ab', COUNT(*) FROM recomendacion.experimentos_ab
ORDER BY catalogo;
