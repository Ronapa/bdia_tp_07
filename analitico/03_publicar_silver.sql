-- Objetivo: publicar la capa Silver en el lake como Parquet, para que quede consultable fuera de DuckDB.
-- Requiere / entradas: tablas silver_* creadas por 02_procesar_silver.sql.
-- Produce / modifica: objetos en s3://lakehouse/silver/ y s3://lakehouse/calidad/.
-- Resultado esperado: nueve objetos Parquet publicados.
-- Guia: Parquet con compresion ZSTD; es columnar, tipado y lo lee cualquier motor del ecosistema.

-- ============================================================
-- Por que Parquet y no CSV
--
--   Tipado: el esquema viaja dentro del archivo, asi que nadie tiene que
--   volver a adivinar si `clic` es booleano o texto.
--
--   Columnar: una consulta que solo mira tres columnas lee tres
--   columnas. Sobre CSV hay que leer y parsear la fila entera.
--
--   Compresion: ZSTD sobre datos columnares reduce el tamano de forma
--   notoria, porque los valores de una misma columna se parecen entre si.
--
-- Silver es regenerable: se reescribe entera en cada corrida. Bronze, en
-- cambio, es inmutable y nunca se pisa. Esa asimetria es la que permite
-- reprocesar el pipeline sin miedo a perder el dato original.
-- ============================================================

COPY silver_eventos      TO 's3://lakehouse/silver/eventos/datos.parquet'      (FORMAT PARQUET, COMPRESSION ZSTD);
COPY silver_impresiones  TO 's3://lakehouse/silver/impresiones/datos.parquet'  (FORMAT PARQUET, COMPRESSION ZSTD);
COPY silver_contenidos   TO 's3://lakehouse/silver/contenidos/datos.parquet'   (FORMAT PARQUET, COMPRESSION ZSTD);
COPY silver_usuarios     TO 's3://lakehouse/silver/usuarios/datos.parquet'     (FORMAT PARQUET, COMPRESSION ZSTD);
COPY silver_estrategias  TO 's3://lakehouse/silver/estrategias/datos.parquet'  (FORMAT PARQUET, COMPRESSION ZSTD);
COPY silver_sesiones     TO 's3://lakehouse/silver/sesiones/datos.parquet'     (FORMAT PARQUET, COMPRESSION ZSTD);

COPY rechazos            TO 's3://lakehouse/calidad/rechazos/datos.parquet'    (FORMAT PARQUET, COMPRESSION ZSTD);
COPY resumen_calidad     TO 's3://lakehouse/calidad/resumen/datos.parquet'     (FORMAT PARQUET, COMPRESSION ZSTD);

-- ============================================================
-- Verificacion: leer de vuelta lo que se acaba de escribir
--
-- No alcanza con que el COPY no falle: hay que comprobar que el objeto
-- se puede volver a leer y que trae la misma cantidad de filas.
-- ============================================================

SELECT
    'silver_eventos' AS objeto,
    (SELECT count(*) FROM silver_eventos) AS filas_en_memoria,
    (SELECT count(*) FROM read_parquet('s3://lakehouse/silver/eventos/datos.parquet')) AS filas_en_lake
UNION ALL
SELECT
    'silver_impresiones',
    (SELECT count(*) FROM silver_impresiones),
    (SELECT count(*) FROM read_parquet('s3://lakehouse/silver/impresiones/datos.parquet'))
UNION ALL
SELECT
    'silver_sesiones',
    (SELECT count(*) FROM silver_sesiones),
    (SELECT count(*) FROM read_parquet('s3://lakehouse/silver/sesiones/datos.parquet'))
UNION ALL
SELECT
    'rechazos',
    (SELECT count(*) FROM rechazos),
    (SELECT count(*) FROM read_parquet('s3://lakehouse/calidad/rechazos/datos.parquet'))
ORDER BY objeto;

SELECT
    CASE
        WHEN (SELECT count(*) FROM read_parquet('s3://lakehouse/silver/eventos/datos.parquet'))
             = (SELECT count(*) FROM silver_eventos)
        THEN 'PUBLICACION_OK'
        ELSE error('La cantidad de filas publicadas no coincide con la capa Silver')
    END AS control;
