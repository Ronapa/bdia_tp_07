-- Objetivo: definir el modelo de datos vectorial dentro de la misma base que el catalogo.
-- Requiere / entradas: extension vector instalada y schema catalogo creado.
-- Produce / modifica: tablas recomendacion.embeddings_contenido y recomendacion.perfiles_usuario.
-- Resultado esperado: dos tablas con columnas VECTOR(384); los indices se crean recien despues de cargar.
-- Guia: la dimension 384 no es arbitraria, es la que produce intfloat/multilingual-e5-small.

-- ============================================================
-- Tabla: recomendacion.embeddings_contenido
--
-- Por que una tabla aparte y no una columna en catalogo.contenidos:
--
--   1. catalogo.contenidos es la tabla caliente del OLTP. Un VECTOR(384)
--      son ~1.5 KB por fila: agregarlo alli reduce la cantidad de filas
--      por pagina y encarece TODAS las consultas del feed, incluidas las
--      que no miran el embedding.
--   2. El ciclo de vida es distinto. El catalogo se edita a mano varias
--      veces por dia; los embeddings se recalculan en lote cuando cambia
--      el texto o cuando se cambia de modelo.
--   3. Permite convivencia de modelos: al migrar de modelo se cargan las
--      filas nuevas y se comparan contra las viejas antes de cortar.
--
-- modelo_embedding se guarda en cada fila porque los vectores de modelos
-- distintos viven en espacios distintos y NO son comparables entre si.
-- Sin esa columna, una migracion a medias produce un ranking silenciosamente
-- incorrecto: las consultas no fallan, simplemente devuelven cualquier cosa.
--
-- texto_fuente conserva exactamente el texto que se vectorizo. Es lo que
-- permite reproducir un embedding y auditar por que dos contenidos quedaron
-- cerca en el espacio vectorial.
--
-- Relacion:
-- contenidos 1:1 embeddings_contenido
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.embeddings_contenido (
    contenido_id     BIGINT PRIMARY KEY REFERENCES catalogo.contenidos(id),
    embedding        VECTOR(384) NOT NULL,
    modelo_embedding TEXT NOT NULL,
    texto_fuente     TEXT NOT NULL,
    indexado_en      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Tabla: recomendacion.perfiles_usuario
--
-- El perfil es el centroide de los embeddings de los contenidos que el
-- usuario consumio, ponderado por cuanto los consumio. Comprimir todo el
-- historial en un solo vector es lo que permite resolver el feed con una
-- unica busqueda por vecinos en vez de N busquedas "mas como este".
--
-- Restriccion de gobierno de datos: solo se calcula para usuarios con
-- consentimiento_personalizacion = TRUE. La regla se aplica en el
-- generador (orquestador/generar_embeddings.py) y se verifica en
-- db/consultas/00_verificar_carga.sql: un perfil de un usuario sin
-- consentimiento hace fallar la carga.
--
-- cantidad_eventos deja explicito el cold start: con pocos eventos el
-- centroide es ruido y el recomendador debe caer a popularidad.
-- ============================================================

CREATE TABLE IF NOT EXISTS recomendacion.perfiles_usuario (
    usuario_id       BIGINT PRIMARY KEY REFERENCES personas.usuarios(id),
    embedding        VECTOR(384) NOT NULL,
    modelo_embedding TEXT NOT NULL,
    cantidad_eventos INTEGER NOT NULL CHECK (cantidad_eventos > 0),
    calculado_en     TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
