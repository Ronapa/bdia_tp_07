# Material complementario

Anexos que no entran en el informe pero sostienen sus afirmaciones.

---

## A. Mapa de la consigna al repositorio

Dónde está resuelto cada punto de "Actividades a realizar".

| # | Actividad | Dónde |
|---|---|---|
| 1 | Análisis del caso de uso | `docs/informe.md` §1 |
| 2 | Relevamiento de datos necesarios | `docs/informe.md` §2 · `data/ejemplos/` |
| 3 | Modelo conceptual | `docs/informe.md` §4 · `docs/diagramas/modelo_conceptual.mmd` |
| 4 | Modelo lógico y equivalentes por tecnología | `docs/informe.md` §5-6 · `nosql/modelo_nosql.md` · `vectorial/modelo_vectorial.md` |
| 5 | Normalización y desnormalización | `docs/informe.md` §7 |
| 6 | Selección tecnológica | `docs/informe.md` §3 |
| 7 | Modelo físico e implementación mínima | `db/` · `nosql/` · `vectorial/` · `analitico/` · `docs/informe.md` §8 |
| 8 | Consultas representativas | **102** consultas + 32 bloques de prueba de seguridad; tabla canónica en `docs/informe.md` §10 |
| 9 | Semiestructurados, no estructurados y búsqueda vectorial | `docs/informe.md` §11 · `vectorial/modelo_vectorial.md` |
| 10 | Arquitectura de datos | `docs/informe.md` §12 · `docs/diagramas/arquitectura.mmd` |
| 11 | Seguridad, permisos y aislamiento | `docs/informe.md` §13 · `db/seguridad/` · `db/consultas/05_prueba_aislamiento.sql` · `db/consultas/06_prueba_aislamiento_api.sql` · `nosql/mongodb/consultas/05_permisos.md` · `nosql/neo4j/consultas/03_limitaciones_community.cypher` |
| 12 | Escalabilidad y rendimiento | `docs/informe.md` §14 · alcance implementado/propuesto en §14.8 |

Entregables mínimos exigidos:

| Entregable | Archivo |
|---|---|
| Informe técnico | `docs/informe.md` |
| Modelo conceptual | `docs/diagramas/modelo_conceptual.mmd` |
| Modelo lógico relacional | `docs/diagramas/modelo_logico.mmd` · `db/estructura/` |
| Modelo físico o equivalente | `docs/diagramas/modelo_fisico_poliglota.mmd` · DDL de cada motor |
| Arquitectura general de datos | `docs/diagramas/arquitectura.mmd` y su `.png` |
| Archivos de implementación mínima | `db/` `nosql/` `vectorial/` `analitico/` `orquestador/` |
| Datos de ejemplo | `data/ejemplos/` |
| Consultas representativas | 102, distribuidas por motor (tabla canónica en `docs/informe.md` §10) |
| README del proyecto | `README.md` |

---

## B. Regenerar los diagramas y exportar el informe a PDF

Los diagramas están escritos en Mermaid (`.mmd`) y el informe en Markdown: **esas son las fuentes**
y son las que se editan. Los `.png` y el `.pdf` son artefactos derivados. Un solo comando los
regenera:

```bash
sh scripts/generar_documentacion.sh
```

El script corre Mermaid CLI y Pandoc/LaTeX en contenedores, así que no hace falta instalarlos en el
host. Es un paso **opcional** para ejecutar el proyecto. La regla de fondo es editar siempre las
fuentes `.mmd` y `.md`, nunca los artefactos generados.

GitHub y GitLab renderizan Mermaid de forma nativa, así que los `.mmd` se ven como diagramas
directamente en el navegador del repositorio.

---

## C. Catálogo de códigos de error de la capa Silver

Cada fila rechazada recibe **un solo** código, el primero que aplica según la precedencia definida
en `analitico/02_procesar_silver.sql`. Sin esa precedencia, una fila con tres defectos aparecería
tres veces y el balance dejaría de cerrar.

### Eventos

| Código | Significado |
|---|---|
| `FALTA_OBLIGATORIO` | Falta `evento_id`, `usuario_seudonimo`, `contenido_id` o `tipo_evento` |
| `DUPLICADO` | `evento_id` repetido dentro del conjunto |
| `FECHA_INVALIDA` | `ocurrido_en` no se pudo interpretar en ninguno de los tres formatos aceptados |
| `TIPO_EVENTO_DESCONOCIDO` | Valor fuera del catálogo de diez tipos |
| `FUERA_DE_RANGO` | Porcentaje de scroll o de reproducción fuera de 0–100 |
| `CONTENIDO_DESCONOCIDO` | `contenido_id` que no está en la dimensión |
| `USUARIO_DESCONOCIDO` | Seudónimo que no está en la dimensión |

### Impresiones

| Código | Significado |
|---|---|
| `FALTA_OBLIGATORIO` | Falta seudónimo, contenido o estrategia |
| `FECHA_INVALIDA` | `mostrado_en` ilegible |
| `BOOLEANO_INVALIDO` | `clic` no interpretable como booleano |
| `FUERA_DE_RANGO` | Posición fuera de 1–50 |
| `CLIC_SIN_FECHA` | `clic = true` sin `clic_en` |
| `CONTENIDO_DESCONOCIDO` | Contenido inexistente |
| `ESTRATEGIA_DESCONOCIDA` | Estrategia inexistente |

### Lo que se normaliza en vez de rechazar

| Defecto | Tratamiento |
|---|---|
| Coma decimal (`45,5`) | `decimal_seguro()` la convierte a punto |
| Fecha con barras (`15/07/2026 18:30:00`) | `fecha_hora_segura()` prueba tres formatos |
| Espacios y mayúsculas (`"  MOVIL  "`) | `texto_limpio()` + `lower()` |
| Booleano en español (`"Si"`, `"No"`) | `booleano_seguro()` acepta ambos idiomas |

La distinción entre **dato inválido** (se rechaza) y **dato mal escrito** (se normaliza) es la
decisión más importante de la capa Silver. Confundirlas hace que un pipeline descarte datos buenos
o acepte datos rotos.

---

## D. Pesos y parámetros del recomendador

Todos los números que gobiernan las recomendaciones, en un solo lugar, para que sean auditables.

### Estrategia híbrida (`orquestador/publicar_serving.py`)

| Señal | Peso | Origen |
|---|---|---|
| Popularidad | 0,30 | `analitica.agg_popularidad`, ventana de 7 días |
| Similitud semántica | 0,35 | `ranking_items_similares`, `origen = 'embedding'` |
| Co-ocurrencia | 0,35 | `ranking_items_similares`, `origen = 'coocurrencia'` |

Filtros duros aplicados **después** de la mezcla: nivel de acceso, vetos declarados y contenido
ya visto. El orden importa: restar al final impide que un contenido vetado sobreviva por un empate.

### Perfil vectorial (`orquestador/generar_embeddings.py`)

| Tipo de evento | Peso |
|---|---|
| `completado`, `guardado` | 3,0 |
| `compartido`, `me_gusta` | 2,5 |
| `reproduccion` | 2,0 |
| `vista` | 1,5 |
| `scroll`, `clic` | 1,0 |
| `impresion` | 0,0 |
| `no_me_interesa` | −2,0 |

Mínimo de 4 contenidos distintos para construir el perfil. Por debajo, el centroide es ruido y el
sistema cae a popularidad.

### Decaimiento temporal de la popularidad (`analitico/04_cargar_gold.sql`)

| Ventana | Constante de decaimiento |
|---|---|
| 24 h | 6 h |
| 7 d | 42 h |
| 30 d | 180 h |

La constante escala con la ventana (un cuarto de su largo). Con una constante fija de 24 horas,
un evento del borde de la ventana de 30 días pesaba `exp(-30) ≈ 9·10⁻¹⁴`: la ventana larga medía
lo mismo que la corta y su score se redondeaba a cero.

### Feed en PostgreSQL (`db/consultas/01_feed_personalizado.sql`)

`score = 0,6 · afinidad_declarada + 0,4 · frescura`, con frescura `= exp(−horas/72)` y un máximo
de dos contenidos por sección.

---

## E. Comandos útiles

```bash
# Estado de los servicios (el perfil incluye la API)
docker compose --profile consumo ps

# Detener todo sin perder datos
sh scripts/detener_proyecto.sh

# Logs de un servicio
docker compose logs -f postgres-operacional

# psql interactivo
docker compose exec postgres-operacional psql -U bdia_user -d bdia_nexomedia

# Ejecutar un SQL suelto
docker compose exec -T postgres-operacional sh /scripts/ejecutar_sql.sh /sql/consultas/03_catalogo_y_jerarquia.sql

# Shell de MongoDB
docker compose exec mongodb-eventos mongosh -u bdia_admin -p bdia_mongo_local_pass --authenticationDatabase admin

# Cypher suelto
docker compose exec -T neo4j-grafo sh /scripts/ejecutar_cypher.sh /cypher/consultas/01_covisualizacion.cypher

# DuckDB interactivo sobre la base del pipeline
docker compose exec duckdb-transformer duckdb /workspace/nexomedia.duckdb

# Listar el lakehouse
docker compose exec -T minio-admin sh -c \
  'mc alias set local http://minio-lake:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null && mc ls --recursive local/lakehouse/'

# Regenerar solo el dataset, a otra escala
docker compose exec -T orquestador python /workspace/orquestador/generar_datos.py --escala chica

# Tamaño de las tablas más grandes
docker compose exec -T postgres-operacional psql -U bdia_user -d bdia_nexomedia -c "
SELECT schemaname || '.' || relname AS tabla,
       pg_size_pretty(pg_total_relation_size(relid)) AS total
FROM pg_catalog.pg_statio_user_tables
ORDER BY pg_total_relation_size(relid) DESC LIMIT 10;"
```

---

## F. Sobre los datos sintéticos

El dataset no es aleatorio: tiene una **estructura latente** puesta a propósito, sin la cual
ninguna estrategia de recomendación podría superar al azar.

| Propiedad | Cómo se generó | Para qué |
|---|---|---|
| Popularidad ley de potencias | `peso = 1 / rango^0,85` | Que "recomendar lo más leído" sea una línea de base difícil de superar |
| Afinidad por sección | 2–3 secciones raíz por usuario; el 70% del consumo cae ahí | Que haya algo que un recomendador pueda aprender |
| Sesgo horario | 45% mañana, 25% noche | Que la recomendación contextual tenga sentido |
| Decaimiento del consumo | Distribución exponencial desde la publicación | Que el trending con decaimiento se distinga de un ranking histórico |
| CTR por estrategia | 3,6% a 7,1% según estrategia | Que la comparación entre estrategias arroje un ganador |
| Sesgo de posición | `exp(−0,18 · (posición − 1))` | Que el análisis de CTR tenga que corregirlo |
| Cold start | 4% de usuarios y contenidos recientes | Que el caso borde exista de verdad |
| Casos borde para `LEFT JOIN` | 3% de usuarios sin actividad; 6% de contenidos nunca recomendados | Que las consultas de ausencia devuelvan algo |

**El límite, declarado:** como la estructura fue puesta a mano, los resultados comparativos entre
estrategias muestran que el **diseño de datos** funciona, no qué estrategia ganaría con datos
reales. Un dataset real tendría correlaciones que este no tiene y ruido que este no reproduce.

---

## G. Bibliografía y referencias

**Documentación oficial consultada**

- PostgreSQL 17 — Row Level Security, particionado declarativo, `security_invoker` en vistas
- pgvector — índices HNSW e IVFFlat, clases de operador, `ef_search` y `probes`
- MongoDB 8 — validación con `$jsonSchema`, colecciones timeseries, índices parciales y TTL
- Redis 8 — conjuntos ordenados, streams con grupos de consumo, ACL
- Neo4j 5 — Cypher, restricciones de unicidad, índices sobre propiedades de relación
- DuckDB 1.4 — extensiones `httpfs` y `postgres`, `read_csv` con `all_varchar`, macros

**Conceptos aplicados de la materia**

| Clase | Contenido aplicado |
|---|---|
| 2 | Modelado conceptual, lógico y físico; E-R; DDL, DML y DQL |
| 3 | Integridad referencial, normalización, JOINs, subconsultas, agregaciones, índices, vistas, JSONB |
| 4 | Bases documentales, clave-valor y de grafos; criterios de selección |
| 5 | Data Warehouse, Data Lake, Lakehouse y arquitectura Medallion |
| 6 | Embeddings, índices vectoriales, búsqueda por similitud, particionamiento |
| 7 | Row Level Security, aislamiento en aplicaciones conectadas a modelos de lenguaje |

**Modelo de embeddings**

`intfloat/multilingual-e5-small` — 384 dimensiones, multilingüe, corre en CPU. Se eligió por
tamaño y por ser el mismo que utiliza la práctica de la Clase 6, lo que permite comparar
resultados con el material de la cátedra.
