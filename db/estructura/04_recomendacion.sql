-- Objetivo: modelar las estrategias de recomendacion, lo que se le mostro a cada usuario y los rankings precalculados.
-- Requiere / entradas: schemas personas y catalogo ya creados.
-- Produce / modifica: tablas del schema recomendacion, incluida la tabla particionada de impresiones.
-- Resultado esperado: cinco tablas mas cinco particiones mensuales y una particion DEFAULT.
-- Guia: impresiones es la tabla que mas crece del sistema; su diseno esta gobernado por eso.

-- ============================================================
-- Tabla: recomendacion.estrategias
--
-- Cada estrategia se versiona. Cuando se cambia el algoritmo se
-- inserta una fila nueva en vez de actualizar la existente: si se
-- pisara la version, todas las impresiones historicas quedarian
-- atribuidas a un algoritmo que ya no es el que las genero y el
-- analisis de CTR compararia peras con manzanas.
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.estrategias (
    id          SERIAL PRIMARY KEY,
    codigo      TEXT NOT NULL,
    version     TEXT NOT NULL DEFAULT '1.0',
    nombre      TEXT NOT NULL,
    descripcion TEXT,
    motor       TEXT NOT NULL
                CHECK (motor IN ('postgresql', 'pgvector', 'duckdb', 'neo4j', 'redis', 'hibrido')),
    activa      BOOLEAN NOT NULL DEFAULT TRUE,
    creada_en   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE (codigo, version)
);

-- ============================================================
-- Tabla: recomendacion.experimentos_ab y asignaciones_ab
--
-- Sin registro de que variante vio cada usuario, la comparacion de
-- estrategias no es un experimento: es una correlacion. La asignacion
-- se guarda una sola vez por usuario y experimento para que la variante
-- sea estable entre sesiones.
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.experimentos_ab (
    id      SERIAL PRIMARY KEY,
    codigo  TEXT UNIQUE NOT NULL,
    nombre  TEXT NOT NULL,
    desde   TIMESTAMPTZ NOT NULL,
    hasta   TIMESTAMPTZ,

    CHECK (hasta IS NULL OR hasta > desde)
);

CREATE TABLE IF NOT EXISTS recomendacion.asignaciones_ab (
    experimento_id INTEGER NOT NULL REFERENCES recomendacion.experimentos_ab(id),
    usuario_id     BIGINT NOT NULL REFERENCES personas.usuarios(id),
    variante       TEXT NOT NULL CHECK (variante IN ('control', 'tratamiento')),
    asignado_en    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (experimento_id, usuario_id)
);

-- ============================================================
-- Tabla: recomendacion.impresiones  (PARTICIONADA POR RANGO)
--
-- Registra que se le mostro a quien, con que estrategia, en que
-- posicion y si hubo clic. Es el cierre del circuito: sin impresiones
-- no se puede calcular CTR ni saber si una recomendacion sirvio.
--
-- Por que particionar:
--   - Crece de forma lineal con trafico x posiciones del feed; es, por
--     lejos, la tabla mas grande del modelo.
--   - Todas las consultas analiticas filtran por rango de fechas, asi
--     que el particionado por mes permite descartar particiones enteras
--     antes de leer una sola fila (partition pruning).
--   - La retencion se implementa con DETACH + DROP de una particion,
--     que es una operacion de metadatos, en lugar de un DELETE masivo
--     que infla el WAL y deja la tabla llena de tuplas muertas.
--
-- La clave primaria incluye mostrado_en porque PostgreSQL exige que la
-- columna de particionado forme parte de toda restriccion unica.
--
-- Relacion:
-- usuarios 1:N impresiones
-- contenidos 1:N impresiones
-- estrategias 1:N impresiones
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.impresiones (
    id            BIGSERIAL,
    usuario_id    BIGINT NOT NULL REFERENCES personas.usuarios(id),
    contenido_id  BIGINT NOT NULL REFERENCES catalogo.contenidos(id),
    estrategia_id INTEGER NOT NULL REFERENCES recomendacion.estrategias(id),
    posicion      SMALLINT NOT NULL CHECK (posicion BETWEEN 1 AND 50),
    score         NUMERIC(9, 6) NOT NULL CHECK (score >= 0),
    variante_ab   TEXT NOT NULL DEFAULT 'control',
    superficie    TEXT NOT NULL DEFAULT 'home'
                  CHECK (superficie IN ('home', 'seccion', 'articulo', 'newsletter', 'busqueda')),
    mostrado_en   TIMESTAMPTZ NOT NULL,
    clic          BOOLEAN NOT NULL DEFAULT FALSE,
    clic_en       TIMESTAMPTZ,

    PRIMARY KEY (id, mostrado_en),

    CHECK (clic = FALSE OR clic_en IS NOT NULL),
    CHECK (clic_en IS NULL OR clic_en >= mostrado_en)
) PARTITION BY RANGE (mostrado_en);

-- Particiones mensuales. Las fechas son fijas a proposito: el generador
-- de datos usa una ventana determinista (ver orquestador/generar_datos.py),
-- de modo que el mismo comando reproduce siempre el mismo reparto de filas.
CREATE TABLE IF NOT EXISTS recomendacion.impresiones_2026_04
    PARTITION OF recomendacion.impresiones
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');

CREATE TABLE IF NOT EXISTS recomendacion.impresiones_2026_05
    PARTITION OF recomendacion.impresiones
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');

CREATE TABLE IF NOT EXISTS recomendacion.impresiones_2026_06
    PARTITION OF recomendacion.impresiones
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');

CREATE TABLE IF NOT EXISTS recomendacion.impresiones_2026_07
    PARTITION OF recomendacion.impresiones
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');

CREATE TABLE IF NOT EXISTS recomendacion.impresiones_2026_08
    PARTITION OF recomendacion.impresiones
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

-- Particion DEFAULT: red de contencion. Sin ella, insertar una fila con
-- una fecha fuera de todos los rangos falla y voltea la carga entera.
-- Con ella la fila entra, y la consulta de calidad la denuncia despues.
CREATE TABLE IF NOT EXISTS recomendacion.impresiones_default
    PARTITION OF recomendacion.impresiones DEFAULT;

-- ============================================================
-- Tabla: recomendacion.ranking_items_similares
--
-- Vecinos precalculados de cada contenido. La columna origen permite
-- que las tres estrategias convivan en la misma tabla:
--
--   embedding    -> similitud semantica (pgvector)
--   coocurrencia -> filtrado colaborativo item-item (DuckDB)
--   grafo        -> co-visualizacion a dos saltos (Neo4j)
--
-- Tenerlas juntas es lo que hace barata la comparacion: una sola
-- consulta con GROUP BY origen responde "que estrategia propone
-- vecinos mas diversos" sin unir tres tablas de formas distintas.
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.ranking_items_similares (
    contenido_id         BIGINT NOT NULL REFERENCES catalogo.contenidos(id),
    contenido_similar_id BIGINT NOT NULL REFERENCES catalogo.contenidos(id),
    origen               TEXT NOT NULL
                         CHECK (origen IN ('embedding', 'coocurrencia', 'grafo')),
    score                NUMERIC(9, 6) NOT NULL CHECK (score >= 0),
    calculado_en         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (contenido_id, contenido_similar_id, origen),

    CHECK (contenido_id <> contenido_similar_id)
);
