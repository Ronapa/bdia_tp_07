-- Objetivo: construir la capa Gold y cargarla en PostgreSQL, cerrando el circuito hacia el recomendador.
-- Requiere / entradas: capa Silver de 02_procesar_silver.sql y la conexion pg del script ejecutar_duckdb.sh.
-- Produce / modifica: schema analitica, control.control_cargas y ranking_items_similares con origen coocurrencia.
-- Resultado esperado: dimensiones, hechos, popularidad y matriz item-item cargados y verificados.
-- Guia: la verificacion corre ANTES del COMMIT; una carga incompleta nunca llega a publicarse.
-- Seguridad: DESTRUCTIVO sobre el schema analitica; lo reconstruye entero en cada corrida.

.bail on

-- ============================================================
-- Estrategia de carga: recarga completa (full reload)
--
-- La capa Gold no se actualiza incrementalmente: se borra y se rehace
-- dentro de una unica transaccion. Con este volumen es mas simple y mas
-- confiable que un merge incremental, y elimina de raiz la posibilidad
-- de que queden filas de una corrida anterior mezcladas con las nuevas.
--
-- El limite de la decision, declarado: con decenas de millones de filas
-- diarias la recarga completa deja de ser viable y habria que pasar a
-- cargas incrementales por particion de fecha.
-- ============================================================

BEGIN TRANSACTION;

-- Borrado en orden hijo -> padre.
DELETE FROM pg.analitica.fact_consumo_diario;
DELETE FROM pg.analitica.fact_impresiones_diario;
DELETE FROM pg.analitica.agg_popularidad;
DELETE FROM pg.analitica.dim_contenido;
DELETE FROM pg.analitica.dim_usuario_anonimizado;
DELETE FROM pg.analitica.dim_estrategia;
DELETE FROM pg.analitica.dim_fecha;
DELETE FROM pg.control.control_cargas WHERE lote_id <> 'postgres_inicial';
DELETE FROM pg.recomendacion.ranking_items_similares WHERE origen = 'coocurrencia';

-- ============================================================
-- 1. dim_fecha
--
-- Se genera a partir de las fechas que realmente aparecen en los hechos.
-- fecha_key con formato YYYYMMDD: es legible, ordenable y no depende de
-- ninguna secuencia.
-- ============================================================

INSERT INTO pg.analitica.dim_fecha
SELECT
    year(fecha) * 10000 + month(fecha) * 100 + day(fecha) AS fecha_key,
    fecha,
    year(fecha), month(fecha), day(fecha), quarter(fecha),
    dayofweek(fecha) AS dia_semana,
    dayofweek(fecha) IN (0, 6) AS es_fin_semana
FROM (
    SELECT DISTINCT CAST(ocurrido_en AS DATE) AS fecha FROM silver_eventos
    UNION
    SELECT DISTINCT CAST(mostrado_en AS DATE) FROM silver_impresiones
) AS fechas
WHERE fecha IS NOT NULL
ORDER BY fecha;

-- ============================================================
-- 2. dim_contenido
--
-- Desnormaliza la jerarquia de secciones: guarda la seccion y su raiz en
-- la misma fila. Es un esquema estrella, no copo de nieve: la redundancia
-- se acepta a cambio de evitar un JOIN recursivo en cada consulta
-- analitica, y no genera anomalias porque la dimension se recarga entera.
-- ============================================================

INSERT INTO pg.analitica.dim_contenido
SELECT
    contenido_id AS contenido_key,
    contenido_id,
    titulo,
    tipo_contenido,
    seccion,
    seccion_raiz,
    nivel_acceso,
    estado,
    CAST(fecha_publicacion AS DATE)
FROM silver_contenidos
ORDER BY contenido_id;

-- ============================================================
-- 3. dim_usuario_anonimizado
--
-- La clave sustituta se deriva del orden del seudonimo. No se usa el
-- identificador de la persona: ese dato nunca entro al lake.
-- ============================================================

INSERT INTO pg.analitica.dim_usuario_anonimizado
SELECT
    row_number() OVER (ORDER BY seudonimo) AS usuario_key,
    seudonimo,
    pais,
    tramo_etario,
    plan,
    year(mes_alta) * 100 + month(mes_alta) AS mes_alta
FROM silver_usuarios
ORDER BY seudonimo;

INSERT INTO pg.analitica.dim_estrategia
SELECT estrategia_id, codigo, version, motor
FROM silver_estrategias
ORDER BY estrategia_id;

-- ============================================================
-- 4. fact_consumo_diario
--
-- Grano: contenido x dia x dispositivo.
--
-- No incluye al usuario: agregar esa dimension multiplicaria las filas
-- por dos ordenes de magnitud para responder preguntas que ya cubren
-- fact_impresiones_diario y el clickstream crudo de MongoDB.
-- ============================================================

INSERT INTO pg.analitica.fact_consumo_diario (
    fecha_key, contenido_key, dispositivo, vistas, vistas_completas,
    usuarios_unicos, segundos_totales, guardados, compartidos
)
SELECT
    year(CAST(ocurrido_en AS DATE)) * 10000
        + month(CAST(ocurrido_en AS DATE)) * 100
        + day(CAST(ocurrido_en AS DATE)) AS fecha_key,
    contenido_id AS contenido_key,
    coalesce(dispositivo, 'desconocido') AS dispositivo,
    -- 'completado' cuenta como vista: terminar un contenido implica
    -- haberlo visto. Definirlo asi no es una comodidad para satisfacer el
    -- CHECK vistas_completas <= vistas, es la definicion correcta.
    --
    -- La alternativa de contar solo 'vista' y 'reproduccion' obliga a
    -- agregar un HAVING que descarte los grupos que violan el CHECK, y eso
    -- pierde filas EN SILENCIO. La conciliacion Silver/Gold de
    -- 05_verificar_calidad.sql lo denuncia, pero conviene no llegar ahi.
    count_if(tipo_evento IN ('vista', 'reproduccion', 'completado')) AS vistas,
    count_if(tipo_evento = 'completado') AS vistas_completas,
    count(DISTINCT usuario_seudonimo) AS usuarios_unicos,
    CAST(coalesce(sum(segundos_visibles), 0) AS BIGINT) AS segundos_totales,
    count_if(tipo_evento = 'guardado') AS guardados,
    count_if(tipo_evento = 'compartido') AS compartidos
FROM silver_eventos
GROUP BY 1, 2, 3
HAVING count_if(tipo_evento IN ('vista', 'reproduccion', 'completado')) > 0;

-- ============================================================
-- 5. fact_impresiones_diario
--
-- Es la tabla que responde la pregunta central del caso de uso: que
-- estrategia de recomendacion conviene dejar prendida.
-- ============================================================

INSERT INTO pg.analitica.fact_impresiones_diario (
    fecha_key, estrategia_key, superficie, impresiones, clics, ctr,
    contenidos_distintos
)
SELECT
    year(CAST(mostrado_en AS DATE)) * 10000
        + month(CAST(mostrado_en AS DATE)) * 100
        + day(CAST(mostrado_en AS DATE)) AS fecha_key,
    e.estrategia_id AS estrategia_key,
    i.superficie,
    count(*) AS impresiones,
    count_if(i.clic) AS clics,
    round(count_if(i.clic) * 1.0 / count(*), 5) AS ctr,
    count(DISTINCT i.contenido_id) AS contenidos_distintos
FROM silver_impresiones AS i
JOIN silver_estrategias AS e
    ON e.codigo = i.estrategia_codigo
GROUP BY 1, 2, 3;

-- ============================================================
-- 6. agg_popularidad
--
-- Trending por ventana movil con decaimiento exponencial.
--
-- El decaimiento es lo que diferencia "trending" de "ranking historico":
-- sin el, las notas viejas con muchas vistas acumuladas taparian para
-- siempre a las que estan explotando ahora.
--
-- La ventana se ancla al ultimo evento del dataset y no a la fecha del
-- sistema, porque el dataset es sintetico y tiene una fecha de corte fija.
--
-- La constante de decaimiento ESCALA CON LA VENTANA (un cuarto de su
-- largo). Usar la misma constante de 24 horas para las tres haria que, en
-- la ventana de 30 dias, un evento del borde pesara exp(-30), o sea 9e-14:
-- cero para cualquier efecto practico. La ventana larga terminaria
-- midiendo lo mismo que la corta y su score se redondearia a cero.
-- ============================================================

CREATE OR REPLACE TEMP TABLE corte AS
SELECT max(ocurrido_en) AS momento FROM silver_eventos;

INSERT INTO pg.analitica.agg_popularidad (
    contenido_id, ventana, seccion, score, vistas
)
SELECT
    e.contenido_id,
    v.ventana,
    any_value(c.seccion_raiz) AS seccion,
    round(sum(exp(-date_diff('hour', e.ocurrido_en, corte.momento) / v.decaimiento)), 6) AS score,
    count(*) AS vistas
FROM silver_eventos AS e
JOIN silver_contenidos AS c
    ON c.contenido_id = e.contenido_id
CROSS JOIN corte
CROSS JOIN (VALUES ('24h', 24, 6.0), ('7d', 168, 42.0), ('30d', 720, 180.0))
    AS v(ventana, horas, decaimiento)
WHERE e.tipo_evento IN ('vista', 'reproduccion', 'completado')
  AND c.estado = 'publicado'
  AND date_diff('hour', e.ocurrido_en, corte.momento) BETWEEN 0 AND v.horas
GROUP BY e.contenido_id, v.ventana;

-- ============================================================
-- 7. Matriz de co-ocurrencia item-item  (filtrado colaborativo)
--
-- Dos contenidos son parecidos si mucha gente consumio los dos.
--
-- La cuenta cruda favorece a lo popular: una nota muy leida co-ocurre
-- con todo. Por eso se normaliza con la similitud coseno:
--
--     score(a,b) = co(a,b) / sqrt(n(a) * n(b))
--
-- Asi un par que co-ocurre 50 veces entre contenidos de 60 lectores vale
-- mas que uno que co-ocurre 80 veces entre contenidos de 5.000.
--
-- Se descartan los usuarios con historial desmesurado: no aportan senal
-- de afinidad y hacen explotar el producto cartesiano.
-- ============================================================

CREATE OR REPLACE TEMP TABLE consumo_usuario AS
SELECT DISTINCT usuario_seudonimo, contenido_id
FROM silver_eventos AS e
JOIN silver_contenidos AS c
    USING (contenido_id)
WHERE e.tipo_evento IN ('vista', 'completado', 'guardado', 'me_gusta')
  AND c.estado = 'publicado';

CREATE OR REPLACE TEMP TABLE usuarios_utiles AS
SELECT usuario_seudonimo
FROM consumo_usuario
GROUP BY usuario_seudonimo
HAVING count(*) BETWEEN 2 AND 200;

CREATE OR REPLACE TEMP TABLE popularidad_item AS
SELECT contenido_id, count(*) AS lectores
FROM consumo_usuario
JOIN usuarios_utiles USING (usuario_seudonimo)
GROUP BY contenido_id;

CREATE OR REPLACE TEMP TABLE coocurrencia AS
SELECT
    a.contenido_id AS contenido_id,
    b.contenido_id AS contenido_similar_id,
    count(*) AS coocurrencias
FROM consumo_usuario AS a
JOIN consumo_usuario AS b
    ON a.usuario_seudonimo = b.usuario_seudonimo
    AND a.contenido_id <> b.contenido_id
JOIN usuarios_utiles AS u
    ON u.usuario_seudonimo = a.usuario_seudonimo
GROUP BY a.contenido_id, b.contenido_id
HAVING count(*) >= 2;

INSERT INTO pg.recomendacion.ranking_items_similares (
    contenido_id, contenido_similar_id, origen, score, calculado_en
)
SELECT contenido_id, contenido_similar_id, 'coocurrencia' AS origen, score, current_timestamp
FROM (
    SELECT
        co.contenido_id,
        co.contenido_similar_id,
        round(co.coocurrencias / sqrt(pa.lectores * pb.lectores), 6) AS score,
        row_number() OVER (
            PARTITION BY co.contenido_id
            ORDER BY co.coocurrencias / sqrt(pa.lectores * pb.lectores) DESC,
                     co.contenido_similar_id
        ) AS posicion
    FROM coocurrencia AS co
    JOIN popularidad_item AS pa
        ON pa.contenido_id = co.contenido_id
    JOIN popularidad_item AS pb
        ON pb.contenido_id = co.contenido_similar_id
) AS rankeado
WHERE posicion <= 10
  AND score > 0;

-- ============================================================
-- 8. Control de cargas
-- ============================================================

INSERT INTO pg.control.control_cargas (
    lote_id, entidad, filas_recibidas, filas_aceptadas, filas_rechazadas, estado
)
SELECT lote_id, entidad, recibidas, aceptadas, rechazadas, 'COMPLETADO'
FROM resumen_calidad;

-- ============================================================
-- 9. Verificacion critica, ANTES del COMMIT
--
-- Verificar despues de confirmar seria inutil: la carga incompleta ya
-- estaria publicada y el recomendador ya la estaria usando.
-- ============================================================

WITH verificacion AS (
    SELECT
        (SELECT count(*) FROM pg.analitica.dim_fecha) AS fechas,
        (SELECT count(*) FROM pg.analitica.dim_contenido) AS contenidos,
        (SELECT count(*) FROM pg.analitica.dim_usuario_anonimizado) AS usuarios,
        (SELECT count(*) FROM pg.analitica.fact_consumo_diario) AS consumo,
        (SELECT count(*) FROM pg.analitica.fact_impresiones_diario) AS impresiones,
        (SELECT count(*) FROM pg.analitica.agg_popularidad) AS popularidad,
        (SELECT count(*) FROM pg.recomendacion.ranking_items_similares
         WHERE origen = 'coocurrencia') AS coocurrencia,
        (SELECT count(*) FROM silver_contenidos) AS contenidos_silver
)
SELECT
    CASE
        WHEN fechas = 0        THEN error('dim_fecha quedo vacia')
        WHEN contenidos <> contenidos_silver
            THEN error(printf('dim_contenido tiene %d filas y Silver tiene %d',
                              contenidos, contenidos_silver))
        WHEN usuarios = 0      THEN error('dim_usuario_anonimizado quedo vacia')
        WHEN consumo = 0       THEN error('fact_consumo_diario quedo vacia')
        WHEN impresiones = 0   THEN error('fact_impresiones_diario quedo vacia')
        WHEN popularidad = 0   THEN error('agg_popularidad quedo vacia')
        WHEN coocurrencia = 0  THEN error('No se calculo ninguna co-ocurrencia item-item')
        ELSE printf('Gold verificada: %d fechas, %d contenidos, %d usuarios, %d consumo, '
                    || '%d impresiones, %d popularidad, %d coocurrencias',
                    fechas, contenidos, usuarios, consumo, impresiones,
                    popularidad, coocurrencia)
    END AS control
FROM verificacion;

COMMIT;
