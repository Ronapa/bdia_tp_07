-- Objetivo: modelar el catalogo de contenidos publicables, su taxonomia, su ciclo editorial y su moderacion.
-- Requiere / entradas: schema personas ya creado por 02_personas.sql.
-- Produce / modifica: tablas del schema catalogo y personas.preferencias_usuario; no carga filas.
-- Resultado esperado: siete tablas creadas, con la jerarquia de secciones autoreferenciada.
-- Guia: el cuerpo del contenido NO vive aca; en PostgreSQL queda solo lo que se filtra, ordena o restringe.

-- ============================================================
-- Tabla: catalogo.tipos_contenido
--
-- articulo, video, podcast, newsletter, galeria.
-- admite_duracion marca cuales tienen duracion_seg obligatoria y
-- se usa en la consulta de calidad, no como CHECK: la regla cruza
-- dos tablas y un CHECK no puede mirar otra fila.
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.tipos_contenido (
    id              SERIAL PRIMARY KEY,
    codigo          TEXT UNIQUE NOT NULL,
    nombre          TEXT NOT NULL,
    admite_duracion BOOLEAN NOT NULL DEFAULT FALSE
);

-- ============================================================
-- Tabla: catalogo.secciones
--
-- Jerarquia autoreferenciada de hasta tres niveles:
--   Politica > Elecciones > Resultados
--
-- Se modela con seccion_padre_id y se recorre con WITH RECURSIVE
-- (ver db/consultas/03_catalogo_y_jerarquia.sql). La alternativa
-- (una tabla por nivel) fija la profundidad en el esquema y obliga
-- a migrar la base cada vez que la redaccion agrega un nivel.
--
-- Relacion:
-- secciones 1:N secciones
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.secciones (
    id               SERIAL PRIMARY KEY,
    slug             TEXT UNIQUE NOT NULL,
    nombre           TEXT NOT NULL,
    seccion_padre_id INTEGER REFERENCES catalogo.secciones(id),
    activa           BOOLEAN NOT NULL DEFAULT TRUE,

    CHECK (seccion_padre_id IS NULL OR seccion_padre_id <> id)
);

CREATE TABLE IF NOT EXISTS catalogo.etiquetas (
    id     SERIAL PRIMARY KEY,
    slug   TEXT UNIQUE NOT NULL,
    nombre TEXT NOT NULL
);

-- ============================================================
-- Tabla: catalogo.contenidos
--
-- Es la tabla caliente del sistema: la lee cada request del feed.
-- Por eso guarda solo lo que participa del filtrado y del orden:
--
--   estado + fecha_publicacion + vigente_hasta -> que se puede mostrar
--   nivel_acceso                               -> a quien se le puede mostrar
--   seccion_id + tipo_contenido_id             -> como se agrupa y diversifica
--   metadatos JSONB                            -> atributos que varian por tipo
--   cuerpo_ref                                 -> puntero al documento en MongoDB
--
-- El cuerpo (parrafos, bloques, transcripciones) vive en MongoDB:
-- es texto largo de estructura variable que nunca se filtra ni se
-- ordena en SQL, y traerlo en cada consulta del feed seria pagar IO
-- por datos que la mayoria de las veces no se usan.
--
-- metadatos JSONB absorbe los atributos que dependen del tipo de
-- contenido (duracion del podcast, cantidad de fotos de la galeria,
-- proveedor del video) sin obligar a una columna nullable por cada
-- variante ni a una tabla por tipo. El indice GIN de 01_indices.sql
-- lo hace consultable.
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.contenidos (
    id                BIGSERIAL PRIMARY KEY,
    titulo            TEXT NOT NULL,
    bajada            TEXT,
    tipo_contenido_id INTEGER NOT NULL REFERENCES catalogo.tipos_contenido(id),
    seccion_id        INTEGER NOT NULL REFERENCES catalogo.secciones(id),
    autor_id          BIGINT NOT NULL REFERENCES personas.usuarios(id),
    estado            TEXT NOT NULL DEFAULT 'borrador'
                      CHECK (estado IN ('borrador', 'en_revision', 'publicado',
                                        'despublicado', 'archivado')),
    nivel_acceso      INTEGER NOT NULL DEFAULT 0 CHECK (nivel_acceso BETWEEN 0 AND 2),
    idioma            TEXT NOT NULL DEFAULT 'es',
    fecha_publicacion TIMESTAMPTZ,
    vigente_hasta     TIMESTAMPTZ,
    duracion_seg      INTEGER CHECK (duracion_seg IS NULL OR duracion_seg > 0),
    cuerpo_ref        TEXT UNIQUE,
    metadatos         JSONB NOT NULL DEFAULT '{}'::jsonb,
    creado_en         TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actualizado_en    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Un contenido publicado sin fecha de publicacion es un dato roto:
    -- el feed lo ordenaria por NULL y la ventana de vigencia no cerraria.
    CHECK (estado <> 'publicado' OR fecha_publicacion IS NOT NULL),
    CHECK (vigente_hasta IS NULL
           OR fecha_publicacion IS NULL
           OR vigente_hasta > fecha_publicacion)
);

-- ============================================================
-- Tabla: catalogo.contenidos_etiquetas
--
-- Resuelve la relacion muchos a muchos entre contenidos y etiquetas.
--
-- Un contenido lleva varias etiquetas.
-- Una etiqueta agrupa muchos contenidos.
--
-- Relacion:
-- contenidos N:M etiquetas
--
-- Se modela como tabla puente y no como array de texto en contenidos:
-- el array ahorra un JOIN pero pierde la integridad referencial (nada
-- impide escribir una etiqueta que no existe) y hace imposible renombrar
-- una etiqueta en un solo lugar.
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.contenidos_etiquetas (
    contenido_id BIGINT NOT NULL REFERENCES catalogo.contenidos(id),
    etiqueta_id  INTEGER NOT NULL REFERENCES catalogo.etiquetas(id),
    relevancia   NUMERIC(4, 3) NOT NULL DEFAULT 1.000
                 CHECK (relevancia BETWEEN 0 AND 1),

    PRIMARY KEY (contenido_id, etiqueta_id)
);

-- ============================================================
-- Tabla: catalogo.versiones_contenido
--
-- Historial editorial. Guarda el diff en JSONB en lugar de una copia
-- completa de la fila: las ediciones tocan pocos campos y una copia
-- entera por version multiplicaria el tamano del catalogo.
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.versiones_contenido (
    id             BIGSERIAL PRIMARY KEY,
    contenido_id   BIGINT NOT NULL REFERENCES catalogo.contenidos(id),
    numero_version INTEGER NOT NULL CHECK (numero_version > 0),
    editor_id      BIGINT NOT NULL REFERENCES personas.usuarios(id),
    cambios        JSONB NOT NULL DEFAULT '{}'::jsonb,
    comentario     TEXT,
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE (contenido_id, numero_version)
);

-- ============================================================
-- Tabla: catalogo.moderaciones
--
-- Una sola tabla para moderar contenidos y comentarios.
--
-- objeto_tipo + objeto_id es una referencia polimorfica: objeto_id es
-- TEXT porque los comentarios viven en MongoDB y su _id no es un BIGINT.
-- El precio es que PostgreSQL no puede imponer la FK sobre esa columna;
-- a cambio, la bandeja del moderador se resuelve con una sola consulta
-- en vez de un UNION entre dos tablas paralelas. La integridad del lado
-- de los contenidos se recupera con la FK explicita contenido_id.
-- ============================================================

CREATE TABLE IF NOT EXISTS catalogo.moderaciones (
    id           BIGSERIAL PRIMARY KEY,
    objeto_tipo  TEXT NOT NULL CHECK (objeto_tipo IN ('contenido', 'comentario')),
    objeto_id    TEXT NOT NULL,
    contenido_id BIGINT REFERENCES catalogo.contenidos(id),
    moderador_id BIGINT NOT NULL REFERENCES personas.usuarios(id),
    accion       TEXT NOT NULL
                 CHECK (accion IN ('aprobado', 'rechazado', 'despublicado', 'marcado')),
    motivo       TEXT,
    creado_en    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CHECK (objeto_tipo <> 'contenido' OR contenido_id IS NOT NULL)
);

-- ============================================================
-- Tabla: personas.preferencias_usuario
--
-- Vive en el schema personas pero se crea aca porque referencia
-- catalogo.secciones y catalogo.etiquetas, que no existian todavia
-- cuando se ejecuto 02_personas.sql.
--
-- Modela las preferencias DECLARADAS, que son las que el usuario
-- controla explicitamente. Las preferencias INFERIDAS (las que el
-- sistema deduce del comportamiento) viven en el perfil vectorial
-- de recomendacion.perfiles_usuario. La distincion importa: el
-- 'no_interesa' declarado es un veto duro que ninguna estrategia
-- puede pisar, mientras que lo inferido solo pondera el score.
-- ============================================================

CREATE TABLE IF NOT EXISTS personas.preferencias_usuario (
    id                BIGSERIAL PRIMARY KEY,
    usuario_id        BIGINT NOT NULL REFERENCES personas.usuarios(id),
    seccion_id        INTEGER REFERENCES catalogo.secciones(id),
    etiqueta_id       INTEGER REFERENCES catalogo.etiquetas(id),
    tipo_preferencia  TEXT NOT NULL CHECK (tipo_preferencia IN ('sigue', 'no_interesa')),
    peso              NUMERIC(4, 3) NOT NULL DEFAULT 1.000 CHECK (peso BETWEEN 0 AND 1),
    actualizado_en    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    -- Cada preferencia apunta a una seccion o a una etiqueta, nunca a las dos
    -- ni a ninguna. El OR exclusivo se escribe comparando los NULL.
    CHECK ((seccion_id IS NULL) <> (etiqueta_id IS NULL))
);
