-- Objetivo: crear la capa Gold del lakehouse y la tabla de control de cargas del pipeline.
-- Requiere / entradas: schemas analitica y control creados por 01_crear_schemas_y_extensiones.sql.
-- Produce / modifica: modelo dimensional del schema analitica y control.control_cargas; no carga filas.
-- Resultado esperado: cuatro dimensiones, dos hechos, una tabla de agregados y la tabla de control.
-- Guia: estas tablas NO las escribe la aplicacion; las escribe DuckDB en analitico/04_cargar_gold.sql.

-- ============================================================
-- Modelo dimensional (esquema estrella)
--
-- Se elige estrella y no copo de nieve: las dimensiones son chicas y
-- estables, y desnormalizar la jerarquia de secciones dentro de
-- dim_contenido evita un JOIN recursivo en cada consulta analitica.
-- La redundancia es deliberada y esta acotada, porque la Gold se
-- reconstruye entera en cada corrida del pipeline: no hay anomalias
-- de actualizacion posibles si nadie actualiza, solo se recarga.
--
-- Las claves sustitutas son el id de origen. Es una simplificacion
-- didactica que se declara explicitamente: en un warehouse real se
-- generarian claves propias para independizarse del sistema fuente.
-- ============================================================

CREATE TABLE IF NOT EXISTS analitica.dim_fecha (
    fecha_key    INTEGER PRIMARY KEY,
    fecha        DATE NOT NULL,
    anio         INTEGER NOT NULL,
    mes          INTEGER NOT NULL,
    dia          INTEGER NOT NULL,
    trimestre    INTEGER NOT NULL,
    dia_semana   INTEGER NOT NULL,
    es_fin_semana BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS analitica.dim_contenido (
    contenido_key  BIGINT PRIMARY KEY,
    contenido_id   BIGINT NOT NULL,
    titulo         TEXT NOT NULL,
    tipo_contenido TEXT NOT NULL,
    seccion        TEXT NOT NULL,
    seccion_raiz   TEXT NOT NULL,
    nivel_acceso   INTEGER NOT NULL,
    estado         TEXT NOT NULL,
    fecha_publicacion DATE
);

-- ============================================================
-- Tabla: analitica.dim_usuario_anonimizado
--
-- La capa analitica no necesita saber quien es el usuario, solo poder
-- agrupar por sus atributos. Por eso esta dimension nunca recibe el
-- correo ni el alias: entra el hash como identificador estable y el
-- ano de nacimiento colapsado en tramos.
--
-- Es el mecanismo de minimizacion de datos del que habla el informe:
-- el analista no puede reidentificar a nadie porque el dato nunca
-- llego a la tabla, no porque tenga prohibido mirarlo.
-- ============================================================

CREATE TABLE IF NOT EXISTS analitica.dim_usuario_anonimizado (
    usuario_key   BIGINT PRIMARY KEY,
    seudonimo     TEXT NOT NULL,
    pais          TEXT NOT NULL,
    tramo_etario  TEXT NOT NULL,
    plan          TEXT NOT NULL,
    mes_alta      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS analitica.dim_estrategia (
    estrategia_key INTEGER PRIMARY KEY,
    codigo         TEXT NOT NULL,
    version        TEXT NOT NULL,
    motor          TEXT NOT NULL
);

-- ============================================================
-- Tabla: analitica.fact_consumo_diario
--
-- Grano: un contenido, un dia, un tipo de dispositivo.
--
-- No incluye usuario_key a proposito. El grano por usuario multiplicaria
-- las filas por dos ordenes de magnitud para responder preguntas que ya
-- resuelve fact_impresiones_diario o el propio clickstream de MongoDB.
-- ============================================================

CREATE TABLE IF NOT EXISTS analitica.fact_consumo_diario (
    id                BIGSERIAL PRIMARY KEY,
    fecha_key         INTEGER NOT NULL REFERENCES analitica.dim_fecha(fecha_key),
    contenido_key     BIGINT NOT NULL REFERENCES analitica.dim_contenido(contenido_key),
    dispositivo       TEXT NOT NULL,
    vistas            INTEGER NOT NULL CHECK (vistas >= 0),
    vistas_completas  INTEGER NOT NULL CHECK (vistas_completas >= 0),
    usuarios_unicos   INTEGER NOT NULL CHECK (usuarios_unicos >= 0),
    segundos_totales  BIGINT NOT NULL CHECK (segundos_totales >= 0),
    guardados         INTEGER NOT NULL DEFAULT 0 CHECK (guardados >= 0),
    compartidos       INTEGER NOT NULL DEFAULT 0 CHECK (compartidos >= 0),

    UNIQUE (fecha_key, contenido_key, dispositivo),
    CHECK (vistas_completas <= vistas)
);

-- ============================================================
-- Tabla: analitica.fact_impresiones_diario
--
-- Grano: un dia, una estrategia, una superficie.
-- Es la tabla que responde la pregunta de negocio central del TP:
-- que estrategia de recomendacion conviene dejar prendida.
-- ============================================================

CREATE TABLE IF NOT EXISTS analitica.fact_impresiones_diario (
    id             BIGSERIAL PRIMARY KEY,
    fecha_key      INTEGER NOT NULL REFERENCES analitica.dim_fecha(fecha_key),
    estrategia_key INTEGER NOT NULL REFERENCES analitica.dim_estrategia(estrategia_key),
    superficie     TEXT NOT NULL,
    impresiones    INTEGER NOT NULL CHECK (impresiones >= 0),
    clics          INTEGER NOT NULL CHECK (clics >= 0),
    ctr            NUMERIC(6, 5) NOT NULL CHECK (ctr BETWEEN 0 AND 1),
    contenidos_distintos INTEGER NOT NULL CHECK (contenidos_distintos >= 0),

    UNIQUE (fecha_key, estrategia_key, superficie),
    CHECK (clics <= impresiones)
);

-- ============================================================
-- Tabla: analitica.agg_popularidad
--
-- Trending precalculado por ventana movil, con decaimiento temporal.
-- Es la fuente de los ZSET que se publican en Redis: el calculo pesado
-- se hace una vez por corrida del pipeline y el request path solo lee.
-- ============================================================

CREATE TABLE IF NOT EXISTS analitica.agg_popularidad (
    contenido_id BIGINT NOT NULL,
    ventana      TEXT NOT NULL CHECK (ventana IN ('24h', '7d', '30d')),
    seccion      TEXT NOT NULL,
    score        NUMERIC(12, 6) NOT NULL CHECK (score >= 0),
    vistas       INTEGER NOT NULL CHECK (vistas >= 0),
    calculado_en TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (contenido_id, ventana)
);

-- ============================================================
-- Tabla: control.secretos
--
-- Guarda los secretos que las funciones de seudonimizacion necesitan y
-- que NO pueden vivir escritos en el codigo.
--
-- El problema que resuelve: personas.seudonimo() tenia la sal escrita
-- literalmente en su cuerpo. Como el cuerpo de una funcion es visible
-- para cualquiera que pueda consultar pg_proc, y la funcion era
-- ejecutable por PUBLIC, el analista podia recorrer los ids, calcular
-- cada seudonimo y armar la tabla de correspondencias. La capa
-- analitica dejaba de ser anonima sin que nada fallara.
--
-- Con la sal aca:
--   - la tabla no tiene ningun GRANT (ver 04_vistas_anonimizadas.sql),
--     asi que solo la lee el dueno de la base;
--   - personas.seudonimo() es SECURITY DEFINER y la lee por el;
--   - el analista no puede ni leer la sal ni ejecutar la funcion.
--
-- Limite declarado: en produccion esto iria en un gestor de secretos
-- (Vault, KMS, Secrets Manager), no en una tabla de la misma base. Un
-- administrador de la base sigue pudiendo leerla. Aca alcanza para
-- demostrar el mecanismo y para sacar el secreto del control de versiones.
-- ============================================================

CREATE TABLE IF NOT EXISTS control.secretos (
    clave       TEXT PRIMARY KEY,
    valor       TEXT NOT NULL,
    descripcion TEXT,
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Tabla: control.control_cargas
--
-- Trazabilidad del pipeline: cuantas filas entraron, cuantas se
-- aceptaron y cuantas se rechazaron en cada lote. Si esta tabla no
-- existiera, una carga que descarta la mitad de los eventos se veria
-- exactamente igual que una carga correcta.
-- ============================================================

CREATE TABLE IF NOT EXISTS control.control_cargas (
    id                BIGSERIAL PRIMARY KEY,
    lote_id           TEXT NOT NULL,
    entidad           TEXT NOT NULL,
    filas_recibidas   INTEGER NOT NULL CHECK (filas_recibidas >= 0),
    filas_aceptadas   INTEGER NOT NULL CHECK (filas_aceptadas >= 0),
    filas_rechazadas  INTEGER NOT NULL CHECK (filas_rechazadas >= 0),
    estado            TEXT NOT NULL CHECK (estado IN ('COMPLETADO', 'FALLIDO')),
    cargado_en        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE (lote_id, entidad),
    CHECK (filas_aceptadas + filas_rechazadas = filas_recibidas)
);
