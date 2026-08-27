-- Objetivo: perfilar la capa Bronze sin corregirla, para saber que se recibio antes de procesarlo.
-- Requiere / entradas: objetos publicados en s3://lakehouse/bronze/ por scripts/cargar_bronze.sh.
-- Produce / modifica: nada; solo lee y muestra. Bronze es inmutable.
-- Resultado esperado: conteos por lote y los valores anomalos visibles.
-- Guia: se lee todo como texto (all_varchar) a proposito; tipar aca seria empezar a limpiar.

-- ============================================================
-- Schema-on-read
--
-- La capa Bronze no tiene esquema declarado: son archivos. DuckDB los
-- interpreta en el momento de leerlos. Con all_varchar = true, ningun
-- valor se convierte todavia, asi que un "31/02/2026" se ve tal cual en
-- lugar de romper la lectura o convertirse en NULL en silencio.
--
-- Eso es exactamente lo que uno quiere de una capa de aterrizaje: que el
-- dato quede como llego, para poder auditarlo despues contra el origen.
-- ============================================================

CREATE OR REPLACE TEMP VIEW bronze_eventos AS
SELECT *, regexp_extract(filename, 'lote=([^/]+)', 1) AS lote_id
FROM read_csv(
    's3://lakehouse/bronze/lote=*/eventos.csv',
    all_varchar = true, filename = true, delim = ',', quote = '"',
    escape = '"', header = true
);

CREATE OR REPLACE TEMP VIEW bronze_impresiones AS
SELECT *, regexp_extract(filename, 'lote=([^/]+)', 1) AS lote_id
FROM read_csv(
    's3://lakehouse/bronze/lote=*/impresiones.csv',
    all_varchar = true, filename = true, delim = ',', quote = '"',
    escape = '"', header = true
);

-- ============================================================
-- 1. Volumen recibido por lote
-- ============================================================

SELECT 'eventos' AS entidad, lote_id, COUNT(*) AS filas
FROM bronze_eventos
GROUP BY lote_id
UNION ALL
SELECT 'impresiones', lote_id, COUNT(*)
FROM bronze_impresiones
GROUP BY lote_id
ORDER BY entidad, lote_id;

-- ============================================================
-- 2. Tipos de evento recibidos
--
-- Cualquier valor fuera del catalogo conocido es un defecto de origen.
-- Se lista sin filtrar para que aparezca 'pestaneo', que es el tipo
-- invalido que el exportador inyecto a proposito.
-- ============================================================

SELECT
    tipo_evento,
    COUNT(*) AS filas,
    CASE
        WHEN tipo_evento IN ('impresion', 'vista', 'scroll', 'clic', 'reproduccion',
                             'completado', 'guardado', 'compartido', 'me_gusta',
                             'no_me_interesa')
        THEN 'conocido'
        ELSE 'DESCONOCIDO'
    END AS estado
FROM bronze_eventos
GROUP BY tipo_evento
ORDER BY estado DESC, filas DESC;

-- ============================================================
-- 3. Fechas que no se pueden convertir
--
-- try_cast devuelve NULL en vez de fallar. Es la forma de encontrar los
-- valores problematicos sin que la consulta de perfilado se caiga.
-- ============================================================

SELECT
    lote_id,
    COUNT(*) AS filas,
    COUNT(*) FILTER (WHERE try_cast(ocurrido_en AS TIMESTAMP) IS NULL) AS fechas_no_convertibles
FROM bronze_eventos
GROUP BY lote_id
ORDER BY lote_id;

SELECT evento_id, ocurrido_en, lote_id
FROM bronze_eventos
WHERE try_cast(ocurrido_en AS TIMESTAMP) IS NULL
ORDER BY evento_id
LIMIT 10;

-- ============================================================
-- 4. Numeros escritos con coma decimal
--
-- No son errores: son un formato distinto. La diferencia entre "dato
-- invalido" y "dato mal escrito" es la que decide si la fila se rechaza
-- o se normaliza, y el perfilado tiene que dejarla ver antes de decidir.
-- ============================================================

SELECT evento_id, segundos_visibles, porcentaje_scroll, lote_id
FROM bronze_eventos
WHERE segundos_visibles LIKE '%,%'
   OR porcentaje_scroll LIKE '%,%'
ORDER BY evento_id
LIMIT 10;

-- ============================================================
-- 5. Valores fuera de rango y campos obligatorios vacios
--
-- Los corchetes hacen visibles los espacios y las cadenas vacias, que de
-- otro modo se confunden con un valor legitimo al mirar la salida.
-- ============================================================

SELECT
    evento_id,
    '[' || coalesce(contenido_id, 'NULO') || ']' AS contenido_visible,
    '[' || coalesce(dispositivo, 'NULO') || ']' AS dispositivo_visible,
    '[' || coalesce(porcentaje_scroll, 'NULO') || ']' AS scroll_visible,
    lote_id
FROM bronze_eventos
WHERE contenido_id IS NULL
   OR trim(contenido_id) = ''
   OR try_cast(replace(porcentaje_scroll, ',', '.') AS DOUBLE) > 100
   OR dispositivo <> trim(dispositivo)
ORDER BY evento_id
LIMIT 10;

-- ============================================================
-- 6. Claves duplicadas
-- ============================================================

SELECT evento_id, COUNT(*) AS repeticiones
FROM bronze_eventos
GROUP BY evento_id
HAVING COUNT(*) > 1
ORDER BY repeticiones DESC, evento_id
LIMIT 10;

-- ============================================================
-- 7. Cobertura de la dimension de usuarios
--
-- El lake recibe seudonimos, no identificadores de persona. Este control
-- verifica que todo evento tenga su seudonimo en la dimension: si falta,
-- es una clave desconocida y la fila no puede entrar a Silver.
-- ============================================================

WITH usuarios AS (
    SELECT DISTINCT seudonimo
    FROM read_csv('s3://lakehouse/bronze/lote=*/usuarios.csv',
                  all_varchar = true, header = true)
)
SELECT
    e.lote_id,
    COUNT(*) AS eventos,
    COUNT(*) FILTER (WHERE u.seudonimo IS NULL) AS con_seudonimo_desconocido
FROM bronze_eventos AS e
LEFT JOIN usuarios AS u
    ON u.seudonimo = e.usuario_seudonimo
GROUP BY e.lote_id
ORDER BY e.lote_id;
