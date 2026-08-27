-- Objetivo: convertir la capa Bronze en datos tipados, limpios y trazables, separando lo aceptado de lo rechazado.
-- Requiere / entradas: objetos en s3://lakehouse/bronze/ y el perfilado de 01_perfilar_bronze.sql.
-- Produce / modifica: tablas silver_*, evaluados_*, rechazos y resumen_calidad en la base local de DuckDB.
-- Resultado esperado: cada fila de Bronze termina aceptada o rechazada con un codigo, sin desapariciones.
-- Guia: ninguna fila se descarta en silencio; ese es el contrato de esta capa.

-- ============================================================
-- Principio de la capa Silver
--
--   Bronze responde "que llego".
--   Silver responde "que de eso es utilizable, y por que no lo demas".
--
-- La regla que ordena todo el archivo: la suma de aceptadas y rechazadas
-- tiene que dar exactamente las recibidas. Un pipeline que filtra sin
-- contar convierte un problema de calidad de datos en un numero
-- ligeramente equivocado tres capas mas arriba, donde ya nadie lo puede
-- rastrear.
-- ============================================================

-- ============================================================
-- 1. Macros de conversion tolerante
--
-- Devuelven NULL en lugar de fallar. Asi una fila mal escrita no voltea
-- el proceso: queda marcada y sigue el pipeline hasta la tabla de
-- rechazos, donde alguien la puede mirar.
-- ============================================================

CREATE OR REPLACE MACRO texto_limpio(valor) AS
    nullif(regexp_replace(trim(valor), '\s+', ' ', 'g'), '');

CREATE OR REPLACE MACRO entero_seguro(valor) AS
    try_cast(trim(valor) AS BIGINT);

CREATE OR REPLACE MACRO decimal_seguro(valor) AS
    try_cast(replace(trim(valor), ',', '.') AS DECIMAL(18, 6));

CREATE OR REPLACE MACRO booleano_seguro(valor) AS CASE
    WHEN lower(trim(valor)) IN ('true', 't', '1', 'si', 'sí', 's') THEN TRUE
    WHEN lower(trim(valor)) IN ('false', 'f', '0', 'no', 'n') THEN FALSE
END;

-- Acepta ISO 8601 y los dos formatos con barras que aparecen en Bronze.
CREATE OR REPLACE MACRO fecha_hora_segura(valor) AS coalesce(
    try_cast(trim(valor) AS TIMESTAMP),
    try_strptime(trim(valor), '%d/%m/%Y %H:%M:%S'),
    try_strptime(trim(valor), '%Y/%m/%d %H:%M:%S')
);

-- ============================================================
-- 2. Capas raw: texto tal cual, mas linaje
--
-- Cada fila conserva de donde vino (archivo, lote, numero de fila) y una
-- copia JSON del registro original. Sin linaje, la tabla de rechazos
-- dice "hay 8 filas mal" y no dice cuales ni de donde salieron.
-- ============================================================

CREATE OR REPLACE TABLE raw_eventos AS
SELECT
    *,
    regexp_extract(filename, 'lote=([^/]+)', 1) AS lote_id,
    filename AS archivo_origen,
    row_number() OVER (PARTITION BY filename) + 1 AS numero_fila,
    current_timestamp AS ingerido_en,
    to_json(struct_pack(
        evento_id := evento_id,
        usuario_seudonimo := usuario_seudonimo,
        contenido_id := contenido_id,
        tipo_evento := tipo_evento,
        ocurrido_en := ocurrido_en
    )) AS evidencia_original
FROM read_csv(
    's3://lakehouse/bronze/lote=*/eventos.csv',
    all_varchar = true, filename = true, delim = ',', quote = '"',
    escape = '"', header = true
);

CREATE OR REPLACE TABLE raw_impresiones AS
SELECT
    *,
    regexp_extract(filename, 'lote=([^/]+)', 1) AS lote_id,
    filename AS archivo_origen,
    row_number() OVER (PARTITION BY filename) + 1 AS numero_fila,
    current_timestamp AS ingerido_en
FROM read_csv(
    's3://lakehouse/bronze/lote=*/impresiones.csv',
    all_varchar = true, filename = true, delim = ',', quote = '"',
    escape = '"', header = true
);

-- ============================================================
-- 3. Dimensiones (se procesan primero: las usan las validaciones)
--
-- Los archivos de dimension se repiten identicos en los dos lotes, asi
-- que se deduplica por clave. Es un snapshot, no un incremento.
-- ============================================================

CREATE OR REPLACE TABLE silver_contenidos AS
SELECT DISTINCT ON (contenido_id)
    entero_seguro(contenido_id) AS contenido_id,
    texto_limpio(titulo) AS titulo,
    texto_limpio(tipo_contenido) AS tipo_contenido,
    texto_limpio(seccion) AS seccion,
    texto_limpio(seccion_raiz) AS seccion_raiz,
    entero_seguro(nivel_acceso) AS nivel_acceso,
    texto_limpio(estado) AS estado,
    try_cast(fecha_publicacion AS TIMESTAMP) AS fecha_publicacion
FROM read_csv('s3://lakehouse/bronze/lote=*/contenidos.csv',
              all_varchar = true, header = true)
WHERE entero_seguro(contenido_id) IS NOT NULL;

CREATE OR REPLACE TABLE silver_usuarios AS
SELECT DISTINCT ON (seudonimo)
    texto_limpio(seudonimo) AS seudonimo,
    texto_limpio(pais) AS pais,
    texto_limpio(tramo_etario) AS tramo_etario,
    texto_limpio(plan) AS plan,
    try_cast(mes_alta AS DATE) AS mes_alta
FROM read_csv('s3://lakehouse/bronze/lote=*/usuarios.csv',
              all_varchar = true, header = true)
WHERE texto_limpio(seudonimo) IS NOT NULL;

CREATE OR REPLACE TABLE silver_estrategias AS
SELECT DISTINCT ON (estrategia_id)
    entero_seguro(estrategia_id) AS estrategia_id,
    texto_limpio(codigo) AS codigo,
    texto_limpio(version) AS version,
    texto_limpio(motor) AS motor
FROM read_csv('s3://lakehouse/bronze/lote=*/estrategias.csv',
              all_varchar = true, header = true);

-- ============================================================
-- 4. Evaluacion de los eventos
--
-- Un unico CASE con precedencia: cada fila recibe a lo sumo UN codigo de
-- error, el primero que aplica. Sin precedencia, una fila con tres
-- defectos aparecería tres veces y el balance dejaria de cerrar.
--
-- Catalogo de codigos (en mayusculas y en ingles, como en el resto del
-- repositorio de la materia):
--   FALTA_OBLIGATORIO         campo requerido vacio o no convertible
--   DUPLICADO                 evento_id repetido dentro del conjunto
--   FECHA_INVALIDA            ocurrido_en no se pudo interpretar
--   TIPO_EVENTO_DESCONOCIDO   valor fuera del catalogo de la aplicacion
--   FUERA_DE_RANGO            porcentaje mayor a 100 o negativo
--   CONTENIDO_DESCONOCIDO     contenido_id que no esta en la dimension
--   USUARIO_DESCONOCIDO       seudonimo que no esta en la dimension
-- ============================================================

CREATE OR REPLACE TABLE evaluados_eventos AS
WITH normalizados AS (
    SELECT
        texto_limpio(evento_id) AS evento_id,
        texto_limpio(usuario_seudonimo) AS usuario_seudonimo,
        texto_limpio(sesion_id) AS sesion_id,
        entero_seguro(contenido_id) AS contenido_id,
        lower(texto_limpio(tipo_evento)) AS tipo_evento,
        fecha_hora_segura(ocurrido_en) AS ocurrido_en,
        lower(texto_limpio(dispositivo)) AS dispositivo,
        lower(texto_limpio(canal)) AS canal,
        upper(texto_limpio(pais)) AS pais,
        lower(texto_limpio(superficie)) AS superficie,
        decimal_seguro(segundos_visibles) AS segundos_visibles,
        decimal_seguro(porcentaje_scroll) AS porcentaje_scroll,
        decimal_seguro(segundos_reproducidos) AS segundos_reproducidos,
        decimal_seguro(porcentaje_reproducido) AS porcentaje_reproducido,
        texto_limpio(estrategia_origen) AS estrategia_origen,
        entero_seguro(posicion_origen) AS posicion_origen,
        texto_limpio(variante_ab) AS variante_ab,
        lote_id,
        archivo_origen,
        numero_fila,
        ingerido_en,
        evidencia_original,
        row_number() OVER (
            PARTITION BY texto_limpio(evento_id)
            ORDER BY lote_id, numero_fila
        ) AS ocurrencia
    FROM raw_eventos
)
SELECT
    *,
    CASE
        WHEN evento_id IS NULL
          OR usuario_seudonimo IS NULL
          OR contenido_id IS NULL
          OR tipo_evento IS NULL           THEN 'FALTA_OBLIGATORIO'
        WHEN ocurrencia > 1                THEN 'DUPLICADO'
        WHEN ocurrido_en IS NULL           THEN 'FECHA_INVALIDA'
        WHEN tipo_evento NOT IN ('impresion', 'vista', 'scroll', 'clic', 'reproduccion',
                                 'completado', 'guardado', 'compartido', 'me_gusta',
                                 'no_me_interesa')
                                           THEN 'TIPO_EVENTO_DESCONOCIDO'
        WHEN porcentaje_scroll IS NOT NULL
             AND (porcentaje_scroll < 0 OR porcentaje_scroll > 100)
                                           THEN 'FUERA_DE_RANGO'
        WHEN porcentaje_reproducido IS NOT NULL
             AND (porcentaje_reproducido < 0 OR porcentaje_reproducido > 100)
                                           THEN 'FUERA_DE_RANGO'
        WHEN NOT EXISTS (
                SELECT 1 FROM silver_contenidos AS c
                WHERE c.contenido_id = normalizados.contenido_id
             )                             THEN 'CONTENIDO_DESCONOCIDO'
        WHEN NOT EXISTS (
                SELECT 1 FROM silver_usuarios AS u
                WHERE u.seudonimo = normalizados.usuario_seudonimo
             )                             THEN 'USUARIO_DESCONOCIDO'
    END AS codigo_error
FROM normalizados;

CREATE OR REPLACE TABLE silver_eventos AS
SELECT * EXCLUDE (ocurrencia, codigo_error, evidencia_original)
FROM evaluados_eventos
WHERE codigo_error IS NULL;

-- ============================================================
-- 5. Evaluacion de las impresiones
-- ============================================================

CREATE OR REPLACE TABLE evaluados_impresiones AS
WITH normalizados AS (
    SELECT
        texto_limpio(usuario_seudonimo) AS usuario_seudonimo,
        entero_seguro(contenido_id) AS contenido_id,
        texto_limpio(estrategia_codigo) AS estrategia_codigo,
        entero_seguro(posicion) AS posicion,
        decimal_seguro(score) AS score,
        texto_limpio(variante_ab) AS variante_ab,
        lower(texto_limpio(superficie)) AS superficie,
        fecha_hora_segura(mostrado_en) AS mostrado_en,
        booleano_seguro(clic) AS clic,
        fecha_hora_segura(clic_en) AS clic_en,
        lote_id, archivo_origen, numero_fila, ingerido_en
    FROM raw_impresiones
)
SELECT
    *,
    CASE
        WHEN usuario_seudonimo IS NULL
          OR contenido_id IS NULL
          OR estrategia_codigo IS NULL     THEN 'FALTA_OBLIGATORIO'
        WHEN mostrado_en IS NULL           THEN 'FECHA_INVALIDA'
        WHEN clic IS NULL                  THEN 'BOOLEANO_INVALIDO'
        WHEN posicion IS NULL OR posicion < 1 OR posicion > 50
                                           THEN 'FUERA_DE_RANGO'
        WHEN clic AND clic_en IS NULL      THEN 'CLIC_SIN_FECHA'
        WHEN NOT EXISTS (
                SELECT 1 FROM silver_contenidos AS c
                WHERE c.contenido_id = normalizados.contenido_id
             )                             THEN 'CONTENIDO_DESCONOCIDO'
        WHEN NOT EXISTS (
                SELECT 1 FROM silver_estrategias AS e
                WHERE e.codigo = normalizados.estrategia_codigo
             )                             THEN 'ESTRATEGIA_DESCONOCIDA'
    END AS codigo_error
FROM normalizados;

CREATE OR REPLACE TABLE silver_impresiones AS
SELECT * EXCLUDE (codigo_error)
FROM evaluados_impresiones
WHERE codigo_error IS NULL;

-- ============================================================
-- 6. Sesionizacion
--
-- Reconstruye las sesiones de lectura a partir de eventos sueltos: dos
-- eventos del mismo usuario pertenecen a la misma sesion si no pasaron
-- mas de 30 minutos entre ellos.
--
-- Es un calculo con funcion de ventana que solo tiene sentido en la capa
-- analitica: hacerlo en el sistema operacional obligaria a recorrer todo
-- el historial del usuario en cada request.
-- ============================================================

CREATE OR REPLACE TABLE silver_sesiones AS
WITH ordenados AS (
    SELECT
        usuario_seudonimo,
        contenido_id,
        tipo_evento,
        ocurrido_en,
        dispositivo,
        lag(ocurrido_en) OVER (
            PARTITION BY usuario_seudonimo ORDER BY ocurrido_en
        ) AS anterior
    FROM silver_eventos
),
marcados AS (
    SELECT
        *,
        CASE
            WHEN anterior IS NULL THEN 1
            WHEN date_diff('minute', anterior, ocurrido_en) > 30 THEN 1
            ELSE 0
        END AS inicia_sesion
    FROM ordenados
),
numeradas AS (
    SELECT
        *,
        sum(inicia_sesion) OVER (
            PARTITION BY usuario_seudonimo ORDER BY ocurrido_en
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        ) AS numero_sesion
    FROM marcados
)
SELECT
    usuario_seudonimo,
    numero_sesion,
    min(ocurrido_en) AS inicio,
    max(ocurrido_en) AS fin,
    date_diff('second', min(ocurrido_en), max(ocurrido_en)) AS duracion_seg,
    count(*) AS eventos,
    count(DISTINCT contenido_id) AS contenidos_distintos,
    any_value(dispositivo) AS dispositivo
FROM numeradas
GROUP BY usuario_seudonimo, numero_sesion;

-- ============================================================
-- 7. Rechazos y balance de calidad
-- ============================================================

CREATE OR REPLACE TABLE rechazos AS
SELECT
    'eventos' AS entidad, lote_id, archivo_origen, numero_fila,
    evento_id AS clave, codigo_error, evidencia_original, ingerido_en
FROM evaluados_eventos
WHERE codigo_error IS NOT NULL
UNION ALL
SELECT
    'impresiones', lote_id, archivo_origen, numero_fila,
    usuario_seudonimo || '|' || coalesce(contenido_id::VARCHAR, 'NULO'),
    codigo_error, NULL, ingerido_en
FROM evaluados_impresiones
WHERE codigo_error IS NOT NULL;

CREATE OR REPLACE TABLE resumen_calidad AS
SELECT
    'eventos' AS entidad,
    lote_id,
    count(*) AS recibidas,
    count_if(codigo_error IS NULL) AS aceptadas,
    count_if(codigo_error IS NOT NULL) AS rechazadas,
    current_timestamp AS procesado_en
FROM evaluados_eventos
GROUP BY lote_id
UNION ALL
SELECT
    'impresiones', lote_id, count(*),
    count_if(codigo_error IS NULL), count_if(codigo_error IS NOT NULL),
    current_timestamp
FROM evaluados_impresiones
GROUP BY lote_id;

-- ============================================================
-- 8. Inspeccion
-- ============================================================

SELECT entidad, lote_id, recibidas, aceptadas, rechazadas
FROM resumen_calidad
ORDER BY entidad, lote_id;

SELECT entidad, codigo_error, count(*) AS filas
FROM rechazos
GROUP BY entidad, codigo_error
ORDER BY entidad, filas DESC;

-- El balance tiene que cerrar para cada entidad y lote.
SELECT
    CASE
        WHEN count(*) = 0 THEN 'BALANCE_OK'
        ELSE error('El balance de calidad no cierra en ' || count(*) || ' combinacion(es)')
    END AS control
FROM resumen_calidad
WHERE aceptadas + rechazadas <> recibidas;
