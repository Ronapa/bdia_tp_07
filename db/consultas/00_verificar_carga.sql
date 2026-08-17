-- Objetivo: comprobar que la carga en PostgreSQL esta completa y es internamente coherente.
-- Requiere / entradas: carga ejecutada por orquestador/cargar_postgres.py.
-- Produce / modifica: nada; solo lee y aborta si algo no cierra.
-- Resultado esperado: la lista de conteos y el mensaje "Verificacion aprobada".
-- Guia: los conteos NO estan escritos a mano; salen de control.control_cargas, que llena el cargador.
-- Seguridad: no expone datos personales; solo cuenta filas.

\set ON_ERROR_STOP on

-- ============================================================
-- 1. Conteos reales contra lo declarado por el generador
--
-- El generador registra en control.control_cargas cuantas filas dijo
-- entregar. Aca se cuentan las que efectivamente entraron. Si una FK
-- rechazo filas en silencio, o si alguien reejecuto una carga a medias,
-- este bloque lo denuncia con el detalle exacto.
-- ============================================================

DO $$
DECLARE
    registro   RECORD;
    reales     BIGINT;
    diferencias TEXT := '';
BEGIN
    FOR registro IN
        SELECT entidad, filas_aceptadas
        FROM control.control_cargas
        WHERE lote_id = 'postgres_inicial'
        ORDER BY entidad
    LOOP
        EXECUTE format('SELECT COUNT(*) FROM %s', registro.entidad) INTO reales;

        IF reales <> registro.filas_aceptadas THEN
            diferencias := diferencias || format(
                E'\n  %s: esperadas %s, encontradas %s',
                registro.entidad, registro.filas_aceptadas, reales
            );
        END IF;
    END LOOP;

    IF diferencias <> '' THEN
        RAISE EXCEPTION 'Conteos inesperados tras la carga:%', diferencias;
    END IF;

    RAISE NOTICE 'Conteos verificados contra control.control_cargas.';
END;
$$;

-- ============================================================
-- 2. Controles de integridad que las restricciones no cubren
--
-- Son reglas que cruzan tablas o filas, donde un CHECK no llega.
-- Todas deben devolver cero.
-- ============================================================

DO $$
DECLARE
    problema        TEXT;
    cantidad        BIGINT;
    acumulado       TEXT := '';
BEGIN
    -- 2.1 Un contenido publicado sin fecha de publicacion.
    SELECT COUNT(*) INTO cantidad
    FROM catalogo.contenidos
    WHERE estado = 'publicado' AND fecha_publicacion IS NULL;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(E'\n  contenidos publicados sin fecha: %s', cantidad);
    END IF;

    -- 2.2 Mas de una suscripcion activa por usuario.
    SELECT COUNT(*) INTO cantidad
    FROM (
        SELECT usuario_id
        FROM personas.suscripciones
        WHERE estado = 'activa'
        GROUP BY usuario_id
        HAVING COUNT(*) > 1
    ) AS duplicadas;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(E'\n  usuarios con varias suscripciones activas: %s', cantidad);
    END IF;

    -- 2.3 Suscripcion marcada como activa pero con fecha de fin vencida.
    --     Es la regla que no se pudo expresar como CHECK porque
    --     CURRENT_TIMESTAMP no es inmutable.
    SELECT COUNT(*) INTO cantidad
    FROM personas.suscripciones
    WHERE estado = 'activa'
      AND hasta IS NOT NULL
      AND hasta <= CURRENT_TIMESTAMP;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(E'\n  suscripciones activas ya vencidas: %s', cantidad);
    END IF;

    -- 2.4 Impresiones que cayeron en la particion DEFAULT: significa que
    --     el generador produjo una fecha fuera de los rangos declarados.
    SELECT COUNT(*) INTO cantidad FROM recomendacion.impresiones_default;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(
            E'\n  impresiones en la particion DEFAULT: %s (revisar los rangos de db/estructura/04)', cantidad);
    END IF;

    -- 2.5 Impresiones con clic sin marca de tiempo del clic.
    SELECT COUNT(*) INTO cantidad
    FROM recomendacion.impresiones
    WHERE clic AND clic_en IS NULL;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(E'\n  clics sin fecha de clic: %s', cantidad);
    END IF;

    -- 2.6 Contenidos que apuntan a una seccion inexistente en el arbol.
    SELECT COUNT(*) INTO cantidad
    FROM catalogo.contenidos AS c
    LEFT JOIN catalogo.vw_arbol_secciones AS a
        ON a.seccion_id = c.seccion_id
    WHERE a.seccion_id IS NULL;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(E'\n  contenidos con seccion fuera del arbol: %s', cantidad);
    END IF;

    -- 2.7 Perfiles vectoriales de usuarios que no dieron consentimiento.
    --     Es un control de gobierno de datos, no de integridad: si esto
    --     falla, el sistema esta personalizando sin permiso.
    SELECT COUNT(*) INTO cantidad
    FROM recomendacion.perfiles_usuario AS p
    JOIN personas.usuarios AS u
        ON u.id = p.usuario_id
    WHERE NOT u.consentimiento_personalizacion;
    IF cantidad > 0 THEN
        acumulado := acumulado || format(
            E'\n  perfiles vectoriales sin consentimiento: %s', cantidad);
    END IF;

    IF acumulado <> '' THEN
        RAISE EXCEPTION 'Controles de integridad fallidos:%', acumulado;
    END IF;

    RAISE NOTICE 'Controles de integridad aprobados.';
END;
$$;

-- ============================================================
-- 3. Resumen legible
-- ============================================================

SELECT 'personas.usuarios' AS tabla, COUNT(*) AS filas FROM personas.usuarios
UNION ALL SELECT 'personas.suscripciones', COUNT(*) FROM personas.suscripciones
UNION ALL SELECT 'personas.preferencias_usuario', COUNT(*) FROM personas.preferencias_usuario
UNION ALL SELECT 'catalogo.secciones', COUNT(*) FROM catalogo.secciones
UNION ALL SELECT 'catalogo.etiquetas', COUNT(*) FROM catalogo.etiquetas
UNION ALL SELECT 'catalogo.contenidos', COUNT(*) FROM catalogo.contenidos
UNION ALL SELECT 'catalogo.contenidos_etiquetas', COUNT(*) FROM catalogo.contenidos_etiquetas
UNION ALL SELECT 'catalogo.versiones_contenido', COUNT(*) FROM catalogo.versiones_contenido
UNION ALL SELECT 'catalogo.moderaciones', COUNT(*) FROM catalogo.moderaciones
UNION ALL SELECT 'recomendacion.impresiones', COUNT(*) FROM recomendacion.impresiones
UNION ALL SELECT 'recomendacion.embeddings_contenido', COUNT(*) FROM recomendacion.embeddings_contenido
UNION ALL SELECT 'recomendacion.perfiles_usuario', COUNT(*) FROM recomendacion.perfiles_usuario
UNION ALL SELECT 'recomendacion.ranking_items_similares', COUNT(*) FROM recomendacion.ranking_items_similares
UNION ALL SELECT 'analitica.fact_consumo_diario', COUNT(*) FROM analitica.fact_consumo_diario
UNION ALL SELECT 'analitica.fact_impresiones_diario', COUNT(*) FROM analitica.fact_impresiones_diario
UNION ALL SELECT 'analitica.agg_popularidad', COUNT(*) FROM analitica.agg_popularidad
UNION ALL SELECT 'auditoria.eventos', COUNT(*) FROM auditoria.eventos
ORDER BY tabla;

-- ============================================================
-- 4. Reparto de las impresiones entre particiones
--
-- Deja a la vista que el particionado esta operando y que ninguna fila
-- termino en la particion DEFAULT.
-- ============================================================

SELECT
    c.relname AS particion,
    pg_size_pretty(pg_relation_size(c.oid)) AS tamano,
    (SELECT COUNT(*) FROM recomendacion.impresiones AS i
     WHERE tableoid = c.oid) AS filas
FROM pg_class AS c
JOIN pg_inherits AS h
    ON h.inhrelid = c.oid
JOIN pg_class AS padre
    ON padre.oid = h.inhparent
WHERE padre.relname = 'impresiones'
ORDER BY c.relname;

\echo 'Verificacion aprobada.'
