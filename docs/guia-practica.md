# Guía práctica

Recorrido paso a paso del entorno. El ritmo es el mismo en todos los pasos:
**ejecutar → observar la salida → entender qué demuestra → continuar.**

Cada paso indica **dónde ejecutarlo** y **qué observar**. Los bloques marcados con
`> **Qué observar:**` son el punto del ejercicio; el resto es andamiaje.

## Resultado esperado por capa

| Capa | Qué debe existir al terminar |
|---|---|
| Relacional | 6 schemas, 38 tablas físicas, 4 particiones mensuales con datos y ninguna fila en `DEFAULT` |
| Seguridad | 6 roles, RLS en 5 tablas, auditoría con miles de eventos, usuarios restringidos en los 4 motores |
| Documental | 5 colecciones, validadores activos, 12 índices, índice TTL activo |
| Vectorial | 3.000 embeddings de 384 dimensiones, HNSW e IVFFlat, 21.610 vecinos exactos |
| Grafo | 5.187 nodos y 97.883 aristas |
| Lakehouse | Bronze inmutable, Silver en Parquet, Gold en PostgreSQL, 6 rechazos con su código |
| Serving | 7.372 claves en Redis, feeds precalculados para 1.887 usuarios |

---

## 1. Preparar el entorno

**Dónde ejecutarlo:** terminal, desde `bdia_tp_07/`.

```bash
cp .env.example .env
```

En Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

```bash
sh scripts/verificar_entorno.sh
```

> **Qué observar:** el script informa qué comando de Compose encontró, verifica que los diez
> puertos estén libres y muestra la memoria y el disco disponibles. Si algún puerto aparece como
> `OCUPADO`, cambiá el valor en `.env` antes de seguir. Es lo más frecuente si tenés levantadas
> las prácticas de otras clases.

---

## 2. Levantar y construir todo

**Dónde ejecutarlo:** terminal, desde `bdia_tp_07/`.

```bash
sh scripts/ejecutar_pipeline.sh
```

> **Qué observar:** catorce pasos numerados. Cada uno corresponde a una capa de la arquitectura.
> La primera corrida descarga las imágenes y el modelo de embeddings; tarda entre 15 y 30 minutos.
>
> El último paso imprime `Verificacion aprobada.` Si en cambio aborta con `Conteos inesperados`,
> **ese es el comportamiento correcto**: la carga quedó incompleta y el pipeline se niega a
> declararla exitosa.

Si no tenés conexión o querés ir rápido, poné `EMBEDDINGS_MODO=simulado` en `.env`: el pipeline
corre entero con vectores deterministas generados por hashing, sin descargar el modelo.

---

## 3. Recorrer el modelo relacional

**Dónde ejecutarlo:** pgAdmin, en <http://127.0.0.1:8090>.

Registrá el servidor: **Servers > Register > Server**, con host `postgres-operacional`, puerto
`5432` y las credenciales de `.env`. Los scripts SQL están montados en `/home/pgadmin/db`.

> Dentro de Docker el host correcto es `postgres-operacional`, no `localhost`.

Abrí el **Query Tool** y ejecutá:

```sql
SELECT table_schema, COUNT(*) AS tablas
FROM information_schema.tables
WHERE table_schema IN ('personas','catalogo','recomendacion','analitica','auditoria','control')
GROUP BY table_schema ORDER BY table_schema;
```

> **Qué observar:** los seis schemas. La separación no es cosmética: cada uno recibe un conjunto
> distinto de permisos en `db/seguridad/01_roles_y_permisos.sql`.

---

## 4. Ver el particionado en acción

**Dónde ejecutarlo:** pgAdmin.

```sql
SELECT c.relname AS particion,
       pg_size_pretty(pg_relation_size(c.oid)) AS tamano,
       (SELECT COUNT(*) FROM recomendacion.impresiones AS i WHERE tableoid = c.oid) AS filas
FROM pg_class AS c
JOIN pg_inherits AS h ON h.inhrelid = c.oid
JOIN pg_class AS padre ON padre.oid = h.inhparent
WHERE padre.relname = 'impresiones'
ORDER BY c.relname;
```

> **Qué observar:** cuatro particiones mensuales con datos repartidos y **cero filas en
> `impresiones_default`**. La partición `DEFAULT` es una red de contención: sin ella, una fila
> con fecha fuera de rango voltearía la carga entera; con ella, la fila entra y la verificación la
> denuncia después.

Ahora mirá el *partition pruning*:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM recomendacion.impresiones
WHERE mostrado_en >= '2026-07-01' AND mostrado_en < '2026-08-01';
```

> **Qué observar:** el plan toca **una sola** partición. Las otras tres se descartan antes de leer
> una fila. Eso es lo que hace que el particionado por fecha valga la pena en la tabla que más
> crece del sistema.

---

## 5. Probar el aislamiento por Row Level Security

**Dónde ejecutarlo:** pgAdmin, **bloque por bloque**, con el archivo
`db/consultas/05_prueba_aislamiento.sql`.

> **IMPORTANTE:** varios bloques de este archivo **deben fallar**. Ese es el objetivo. Una barrera
> de seguridad que nunca se prueba es una barrera que nadie sabe si existe.

Bloque de referencia, como superusuario:

```sql
SELECT COUNT(*) AS totales,
       COUNT(*) FILTER (WHERE estado = 'borrador') AS borradores,
       COUNT(*) FILTER (WHERE nivel_acceso = 2) AS premium
FROM catalogo.contenidos;
```

Ahora asumí la identidad de un lector con plan gratuito:

```sql
SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '12', FALSE);

SELECT COUNT(*) AS visibles,
       COUNT(*) FILTER (WHERE estado <> 'publicado') AS no_publicados,
       COUNT(*) FILTER (WHERE nivel_acceso > 0) AS sobre_su_plan,
       personas.nivel_acceso_actual() AS nivel
FROM catalogo.contenidos;

RESET ROLE;
```

> **Qué observar:** `no_publicados` y `sobre_su_plan` tienen que dar **cero**. Si alguna diera
> distinto de cero, el recomendador podría filtrar contenido no autorizado a través de cualquier
> consulta del sistema.
>
> Un superusuario ignora siempre el RLS; por eso los cinco roles de aplicación no son
> superusuarios, y el script de creación aborta si alguno lo fuera.

Qué pasa si la aplicación se olvida de declarar quién opera:

```sql
SET ROLE bdia_lector;
SELECT set_config('app.usuario_id', '', FALSE);

SELECT personas.usuario_actual() AS usuario,
       personas.nivel_acceso_actual() AS nivel,
       (SELECT COUNT(*) FROM recomendacion.impresiones) AS impresiones_visibles,
       (SELECT COUNT(*) FROM catalogo.contenidos) AS contenidos_visibles;

RESET ROLE;
```

> **Qué observar:** `impresiones_visibles` da **cero** —la política compara contra
> `usuario_actual()` y `NULL = NULL` no es `TRUE`— mientras que `contenidos_visibles` devuelve
> solo el contenido publicado de acceso libre: la sesión queda tratada como un visitante anónimo.
>
> En los dos casos el resultado es el **menor privilegio posible**. Un olvido de la aplicación
> degrada a anónimo; nunca escala privilegios.

Y el permiso por columna:

```sql
SET ROLE bdia_analista;
SELECT * FROM personas.usuarios LIMIT 1;
RESET ROLE;
```

> **Qué observar:** falla con `permission denied for column email_hash`. **No** devuelve las
> columnas permitidas en silencio. RLS decide *qué filas*; el `GRANT` por columna decide
> *qué columnas*.

### El rol con el que se conecta la API

**Dónde ejecutarlo:** pgAdmin, con `db/consultas/06_prueba_aislamiento_api.sql`.

Es el eslabón que más importa: `bdia_api` es el único rol que atiende tráfico externo.

```sql
BEGIN;
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);

INSERT INTO recomendacion.impresiones (
    usuario_id, contenido_id, estrategia_id, posicion, score, superficie, mostrado_en
)
VALUES (9999, 1, 1, 1, 0.5, 'home', CURRENT_TIMESTAMP);

ROLLBACK;
```

> **Qué observar:** falla con `new row violates row-level security policy for table "impresiones"`.
> **El error es el resultado esperado.**
>
> Aunque alguien modificara la API para aceptar el `usuario_id` del cuerpo del pedido, el motor
> rechaza la fila. Esa es la diferencia entre una validación —que un refactor puede perder— y una
> barrera.

Comprobalo también desde afuera:

```bash
# Anonimo: no debe recibir ningun contenido de nivel > 0
curl -s "http://127.0.0.1:8020/trending?limite=50" | grep -o '"nivel_acceso":[0-9]' | sort | uniq -c

# El usuario 1 pidiendo el feed del 2: 403
curl -s -H "X-Usuario-Id: 1" "http://127.0.0.1:8020/recomendaciones/2"
```

> **Qué observar:** el primero devuelve solo `"nivel_acceso":0`. Antes de la corrección devolvía
> también niveles 1 y 2: un visitante anónimo recibía títulos de contenido premium.

---

## 6. Comprobar la auditoría

**Dónde ejecutarlo:** pgAdmin.

```sql
SELECT accion, esquema || '.' || tabla AS objeto, COUNT(*) AS eventos
FROM auditoria.eventos
GROUP BY accion, esquema, tabla
ORDER BY eventos DESC;
```

```sql
SELECT ocurrido_en, usuario_bd, usuario_app, accion,
       datos_anteriores ->> 'estado' AS estado_anterior,
       datos_nuevos ->> 'estado' AS estado_nuevo
FROM auditoria.eventos
WHERE tabla = 'contenidos'
ORDER BY ocurrido_en DESC
LIMIT 5;
```

> **Qué observar:** se guardan los dos estados, el rol de base **y** el usuario de aplicación.
> Guardar solo el estado nuevo convertiría la auditoría en un log sin capacidad de responder
> "qué decía antes", que suele ser la pregunta que importa.

Probá que la traza es append-only:

```sql
SET ROLE bdia_admin;
DELETE FROM auditoria.eventos WHERE id = 1;
RESET ROLE;
```

> **Qué observar:** falla por permisos. **El error es el resultado esperado.** Una auditoría que
> puede borrar quien altera el dato no sirve de nada.
>
> El límite, declarado: un superusuario sigue pudiendo borrar la tabla. Una traza realmente
> inmutable exige sacarla del alcance del DBA.

---

## 6.b Los usuarios restringidos de los otros motores

**Dónde ejecutarlo:** terminal.

```bash
# MongoDB: el perfil analitico NO puede leer los comentarios
docker compose exec mongodb-eventos mongosh --quiet \
  -u bdia_mongo_lectura -p lectura_local \
  --authenticationDatabase bdia_nexomedia bdia_nexomedia \
  --eval 'db.comentarios.findOne()'

# MongoDB: el usuario de ingesta NO puede leer lo que escribe
docker compose exec mongodb-eventos mongosh --quiet \
  -u bdia_mongo_ingesta -p ingesta_local \
  --authenticationDatabase bdia_nexomedia bdia_nexomedia \
  --eval 'db.eventos_interaccion.findOne()'
```

> **Qué observar:** los dos devuelven `not authorized`. El segundo es el más interesante: es el
> usuario con el que corre el consumidor del stream, que es el componente más expuesto del
> sistema. Si quedara comprometido, no serviría para exfiltrar el historial de nadie.

```bash
# Neo4j: el comando que DEBE fallar
docker compose exec -T neo4j-grafo cypher-shell -u neo4j -p bdia_neo4j_local_pass \
  "SHOW ROLES;"
```

> **Qué observar:** `Unsupported administration command: SHOW ROLES`. **Neo4j Community no tiene
> control de acceso basado en roles**: se pueden crear usuarios, pero todos tienen acceso total.
> Es una limitación del motor, no del diseño, y se compensa no guardando datos personales en el
> grafo (`nosql/neo4j/consultas/03_limitaciones_community.cypher` lo desarrolla).

```bash
# MinIO: el usuario de solo lectura no puede escribir
docker compose exec -T minio-admin sh /scripts/configurar_minio.sh
```

> **Qué observar:** el script termina en `Escritura correctamente denegada.` Si el `mc cp` llegara
> a funcionar, el script aborta con `FALLO DE SEGURIDAD`.

Los cuatro motores, y hasta dónde llega cada uno, están en la tabla de `docs/informe.md` §13.7.

---

## 7. Explorar el modelo documental

**Dónde ejecutarlo:** shell de MongoDB o MongoDB Compass.

```bash
docker compose exec mongodb-eventos mongosh \
  -u bdia_admin -p bdia_mongo_local_pass --authenticationDatabase admin
```

Con Compass, la cadena de conexión es
`mongodb://bdia_admin:bdia_mongo_local_pass@localhost:27020/?authSource=admin`.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
["vista", "reproduccion", "impresion", "me_gusta"].forEach((tipo) => {
    print(`\n=== ${tipo} ===`);
    printjson(practica.eventos_interaccion.findOne({ tipo_evento: tipo }));
});
```

> **Qué observar:** los cuatro documentos comparten el contrato mínimo (`usuario_id`,
> `contenido_id`, `tipo_evento`, `ocurrido_en`) y difieren en el resto. `vista` trae
> `metricas.porcentaje_scroll`, `reproduccion` trae `metricas.porcentaje_reproducido`,
> `impresion` trae `origen_recomendacion` y `me_gusta` no trae ninguno.
>
> Ese es el argumento por el que el clickstream no vive en tablas: como columnas serían seis
> columnas con la mayoría en `NULL`; como tablas por tipo, diez tablas casi idénticas.

Probá que el validador hace su trabajo:

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
practica.eventos_interaccion.insertOne({
    evento_id: "EV-PRUEBA-01",
    usuario_id: NumberInt(1),
    contenido_id: NumberInt(1),
    tipo_evento: "pestaneo",
    ocurrido_en: new Date()
});
```

> **Qué observar:** error `121, DocumentValidationFailure`. **Es el resultado esperado.**
> El validador es lo que impide que "esquema flexible" se convierta en "cualquier cosa entra".

Seguí con los cuatro archivos de `nosql/mongodb/consultas/`:

| Archivo | Tema |
|---|---|
| `01_modelo_documental.md` | Por qué estos datos están acá y no en PostgreSQL |
| `02_agregaciones_consumo.md` | `$group` doble, `$bucket`, `$facet`, timeseries |
| `03_lookup_y_ventanas.md` | `$lookup`, `$unwind`, `$setWindowFields`, `$text` |
| `04_indices_y_explain.md` | `explain("executionStats")`, índices parciales, validación |

---

## 8. Medir el efecto de un índice en MongoDB

**Dónde ejecutarlo:** shell de MongoDB.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.dropIndex("idx_usuario_fecha");
const sinIndice = practica.eventos_interaccion
    .find({ usuario_id: 42 }).sort({ ocurrido_en: -1 }).limit(20)
    .explain("executionStats").executionStats;

practica.eventos_interaccion.createIndex(
    { usuario_id: 1, ocurrido_en: -1 }, { name: "idx_usuario_fecha" }
);
const conIndice = practica.eventos_interaccion
    .find({ usuario_id: 42 }).sort({ ocurrido_en: -1 }).limit(20)
    .explain("executionStats").executionStats;

print(`Sin indice: examinados=${sinIndice.totalDocsExamined} ms=${sinIndice.executionTimeMillis}`);
print(`Con indice: examinados=${conIndice.totalDocsExamined} ms=${conIndice.executionTimeMillis}`);
```

> **Qué observar:** mirá `totalDocsExamined`, no los milisegundos. Con volúmenes chicos el tiempo
> puede ser parecido, e incluso el `COLLSCAN` puede ganar. Lo que **no** cambia con el volumen es
> cuántos documentos hubo que leer: esa es la métrica que se degrada linealmente cuando la
> colección crece.

---

## 9. Búsqueda vectorial

**Dónde ejecutarlo:** pgAdmin.

Abrí `vectorial/consultas/01_similitud.sql` (montado en `/home/pgadmin/vectorial`) y ejecutá la
primera consulta.

> **Qué observar:** los cinco vecinos del contenido 1 son de su misma sección o de secciones
> vecinas. El modelo capturó el tema sin que nadie le declarara la taxonomía.

Ahora el punto central del diseño:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT p.contenido_id, p.titulo
FROM recomendacion.embeddings_contenido AS e
JOIN catalogo.vw_contenidos_publicables AS p ON p.contenido_id = e.contenido_id
WHERE p.nivel_acceso <= 0
ORDER BY e.embedding <=> (
    SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1
)
LIMIT 10;
```

> **Qué observar:** las condiciones de acceso están en el **mismo `WHERE`** que el `ORDER BY` por
> distancia. PostgreSQL las evalúa **antes** de rankear: es prefiltrado.
>
> La alternativa —traer 50 vecinos y filtrarlos en la aplicación— tiene dos problemas: si los 50
> son premium y el usuario es gratuito, el feed queda vacío; y los ids de los contenidos
> descartados **ya salieron de la base**.

---

## 10. El recall silencioso de las búsquedas aproximadas

**Dónde ejecutarlo:** pgAdmin, con `vectorial/consultas/02_explain_indices.sql`.

```sql
BEGIN;
SET LOCAL enable_seqscan = off;
SET LOCAL ivfflat.probes = 1;

SELECT 'probes = 1' AS configuracion, COUNT(*) AS vecinos_devueltos
FROM (
    SELECT contenido_id FROM recomendacion.embeddings_contenido
    WHERE contenido_id <> 1
    ORDER BY embedding <=> (
        SELECT embedding FROM recomendacion.embeddings_contenido WHERE contenido_id = 1)
    LIMIT 10
) AS resultado;
COMMIT;
```

Repetilo con `SET LOCAL ivfflat.probes = 50;`.

> **Qué observar:** con `probes = 1`, IVFFlat escanea **una sola** de las 50 listas —alrededor del
> 2% del catálogo— y puede devolver menos filas que el `LIMIT` pedido. **La consulta no falla ni
> avisa.**
>
> Es el riesgo real de las búsquedas aproximadas: no se equivocan ruidosamente, se equivocan en
> silencio. Por eso el cálculo por lote de `vectorial/01_crear_indices_vectoriales.sql` apaga los
> índices para obtener el kNN exacto, y deja los índices para las consultas en línea.

---

## 11. El grafo

**Dónde ejecutarlo:** Neo4j Browser, en <http://127.0.0.1:7476>. Usuario `neo4j`, contraseña la de
`.env`.

```cypher
:param usuario => 1;
:param nivel => 1;

MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(puente:Contenido)<-[:VIO]-(otro:Usuario)
MATCH (otro)-[:VIO]->(recomendado:Contenido)
WHERE recomendado.estado = 'publicado'
  AND recomendado.nivel_acceso <= $nivel
  AND NOT EXISTS { (u)-[:VIO]->(recomendado) }
WITH recomendado, puente, count(DISTINCT otro) AS lectores
ORDER BY lectores DESC
WITH recomendado, collect({nota: puente.titulo, lectores: lectores})[0] AS mejor_puente,
     sum(lectores) AS score
RETURN recomendado.titulo AS recomendacion, score,
    'Porque leiste "' + mejor_puente.nota + '", igual que otras ' +
    toString(mejor_puente.lectores) + ' personas que ademas leyeron esta nota.' AS explicacion
ORDER BY score DESC LIMIT 5;
```

> **Qué observar:** la consulta devuelve la recomendación **y su explicación**, en el mismo
> resultado. El camino recorrido *es* la justificación. Reconstruir eso desde un ranking de SQL
> exigiría una segunda consulta por cada recomendación.

Seguí con `nosql/neo4j/consultas/`: co-visualización ponderada, mezcla de grafo y semántica,
cold start por etiquetas, `shortestPath`, burbuja de filtro, contenidos puente entre secciones y
autores que retienen.

---

## 12. El lakehouse

**Dónde ejecutarlo:** consola de MinIO, en <http://127.0.0.1:9011>.

Navegá el bucket `lakehouse`:

| Prefijo | Contenido |
|---|---|
| `bronze/lote=lote_01_historico/` | CSV crudo, más `_manifiesto.json` |
| `bronze/lote=lote_02_reciente/` | Ídem, **con ocho casos de calidad inyectados**: seis se rechazan y dos se normalizan |
| `silver/` | Parquet ZSTD tipado y limpio |
| `calidad/` | Rechazos con linaje y resumen por lote |

> **Qué observar:** los CSV de Bronze están **exactamente como llegaron**, sin corregir. Y ninguno
> trae `usuario_id`: el lake recibe seudónimos. El identificador de la persona no está prohibido
> de mirar, directamente **no llegó**.

**Dónde ejecutarlo:** terminal.

```bash
docker compose exec -T duckdb-transformer sh /scripts/ejecutar_duckdb.sh /sql/05_verificar_calidad.sql
```

> **Qué observar:** el balance por lote (`recibidas = aceptadas + rechazadas`), el detalle de los
> seis rechazos con su código y su línea de origen, la conciliación Silver ↔ Gold y el CTR por
> estrategia.
>
> La estrategia híbrida gana, popularidad pierde. Y sin embargo popularidad **no se apaga**: es la
> única que funciona con un usuario sin historial. Ese es el motivo por el que el sistema mantiene
> cinco estrategias y no una.

---

## 13. La capa de serving

**Dónde ejecutarlo:** terminal.

```bash
docker compose exec redis-serving \
  redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" ZREVRANGE rec:trending:global 0 9 WITHSCORES
```

```bash
docker compose exec redis-serving \
  redis-cli --user app_lectura --pass lectura_local SET clave-prohibida valor
```

> **Qué observar:** el segundo comando devuelve `NOPERM`. Redis aísla por comando y por patrón de
> clave, no por fila. El límite está declarado: `~usuario:*` alcanza a *todos* los usuarios, así
> que el aislamiento entre personas sigue siendo responsabilidad de la aplicación. Es la razón por
> la que los datos personales sensibles no viven acá.

Seguí con `nosql/redis/consultas/01_estructuras_de_serving.md`.

---

## 13.b La ingesta por stream

**Dónde ejecutarlo:** terminal.

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/consumir_stream.py --simular 50
```

> **Qué observar:** el script produce 50 eventos con `XADD` (lo que haría la aplicación web), los
> lee con `XREADGROUP`, los inserta en MongoDB y recién entonces los confirma con `XACK`. Termina
> con **0 pendientes**.
>
> El orden importa y no es negociable: primero MongoDB, después `XACK`. Al revés, un fallo entre
> las dos operaciones perdería el evento sin dejar rastro. Así, en el peor caso se procesa dos
> veces, que es un problema mucho menor y además detectable.
>
> Es la garantía *al menos una vez*, que es la correcta para un clickstream: perder eventos sesga
> las métricas, repetirlos no.

Corré el **mismo comando dos veces** y contá los documentos:

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/consumir_stream.py --simular 50

docker compose exec mongodb-eventos mongosh --quiet \
  -u bdia_admin -p bdia_mongo_local_pass --authenticationDatabase admin bdia_nexomedia \
  --eval 'print(db.eventos_interaccion.countDocuments({evento_id: /^EV-STREAM-/}))'
```

> **Qué observar:** después de dos corridas hay **50 documentos, no 100**. La escritura usa upsert
> sobre `evento_id`, que tiene índice único: reprocesar el mismo evento deja exactamente el mismo
> documento.
>
> Eso es lo que convierte la entrega *al menos una vez* del stream en *exactamente una vez* sobre
> el estado persistido, que es lo único que importa: los eventos repetidos no inflan las métricas.

Este paso **agrega documentos** a `eventos_interaccion`, así que altera los conteos del dataset
determinista. Por eso el pipeline lo corre sin `--simular`: solo drena el stream. Para volver a los
conteos exactos, reiniciá el proyecto.

---

## 14. Las cinco estrategias, una al lado de la otra

**Dónde ejecutarlo:** terminal.

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/demo_recomendaciones.py --usuario 1
```

> **Qué observar:** cinco listas distintas para el mismo usuario, cada una resuelta por un motor
> distinto. Al final, el porcentaje de coincidencia entre el feed híbrido y el ranking global:
> **poca coincidencia es lo esperado.** Si el híbrido devolviera lo mismo que el ranking global,
> la personalización no estaría aportando nada.

Probá también un usuario sin historial:

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/demo_recomendaciones.py --usuario 1990
```

> **Qué observar:** las estrategias personalizadas devuelven poco o nada, y popularidad sigue
> funcionando. Eso es el cold start, y es la razón de que la estrategia con peor CTR sea
> indispensable.

---

## 15. La API

**Dónde ejecutarlo:** navegador, en <http://127.0.0.1:8020/docs>.

```bash
curl -s http://127.0.0.1:8020/salud
curl -s -H "X-Usuario-Id: 1" "http://127.0.0.1:8020/recomendaciones/1?estrategia=grafo_covisualizacion&limite=3"
curl -s -H "X-Usuario-Id: 1" "http://127.0.0.1:8020/contenidos/1/similares?limite=3"
```

> **Qué observar:** cada respuesta declara **qué motor la resolvió**. Es la forma de comprobar
> desde afuera que el enfoque políglota no es una afirmación del informe sino algo verificable.

---

## 16. Reproducir el pipeline desde cero

**Dónde ejecutarlo:** terminal.

```bash
sh scripts/reiniciar_proyecto.sh
sh scripts/ejecutar_pipeline.sh
```

> **Qué observar:** los conteos finales son **idénticos** a los de la corrida anterior. El dataset
> es determinista: la misma semilla produce los mismos archivos. Sin esa propiedad, las
> verificaciones por conteo exacto no podrían existir.

---

## 17. Problemas frecuentes

- **Un puerto está ocupado.** Cambiá el valor en `.env` y volvé a correr `verificar_entorno.sh`.
- **`docker compose` no existe.** Usá `docker-compose`; los scripts detectan cuál está disponible.
- **Neo4j no llega a `healthy`.** Suele ser memoria (necesita ~1 GB). Si en los logs aparece
  *Unrecognized setting*, hay una variable `NEO4J_*` mal escrita en el compose.
- **Un `ZREVRANGE` devuelve vacío.** La clave expiró. Volvé a correr `publicar_serving.py`.
- **El paso de embeddings tarda mucho o falla sin red.** Poné `EMBEDDINGS_MODO=simulado`.
- **La capa Gold quedó con datos de otra corrida.** Cambiaste `SEMILLA` o `ESCALA`;
  `cargar_bronze.sh` lo detecta por el manifiesto y republica. Si algo quedó a medias, reiniciá.
- **La verificación aborta.** Es el comportamiento correcto. Reiniciá y volvé a correr.
- **Detuve todo pero la API sigue viva.** El servicio `api-recomendador` tiene perfil `consumo`, y
  los perfiles de Compose aplican en las dos direcciones: no se levanta con `up` ni se detiene con
  `stop` si no se nombra el perfil. Usá `sh scripts/detener_proyecto.sh`.

---

## 18. Cierre conceptual

| Concepto de la materia | Evidencia observada | Alcance |
|---|---|---|
| Modelado conceptual, lógico y físico | `docs/diagramas/`, `db/estructura/` | Completo |
| Normalización y sus anomalías | §7 del informe; catálogos, histórico de suscripciones | Completo |
| Integridad referencial y restricciones | FKs sin cascada, `CHECK` de dominio, índice único parcial | Completo |
| JSON/JSONB | `metadatos`, diffs de versiones, auditoría, GIN doble | Completo |
| Índices, vistas y vistas materializadas | Paso 4 y 8; `mv_trending_seccion` con `CONCURRENTLY` | Completo |
| Base documental | Paso 7; 5 colecciones con validadores y timeseries | Completo |
| Base clave-valor | Paso 13; 5 estructuras distintas, cada una justificada | Completo |
| Base de grafos | Paso 11; recorridos de 2-3 saltos con explicación | Completo |
| Base columnar | **No implementada**; se justifica por qué no (§3.3 del informe) | Descartada con argumento |
| Base vectorial | Pasos 9 y 10; pgvector con HNSW e IVFFlat | Completo |
| Data Warehouse / Lake / Lakehouse | Paso 12; Medallion sobre MinIO | **Lakehouse mínimo**: sin formato transaccional de tabla ni *time travel* |
| Concurrencia y ACID | Cargas transaccionales; verificación antes del `COMMIT` | Parcial: no se estudian niveles de aislamiento |
| Replicación y particionamiento | Paso 4; particionado declarativo y BRIN | Particionado implementado; replicación solo justificada |
| Multi-tenant y RLS | Pasos 5, 6 y 6.b | Completo: usuarios finales, rol de la API y los otros cuatro motores |
| Aislamiento en apps con IA | Pasos 5 y 9; prefiltrado en cinco capas y el servicio sujeto a RLS | Completo salvo la autenticación, declarada fuera de alcance |

**Lo que este trabajo no hace, y conviene decir:** no entrena ningún modelo, no autentica a los
usuarios de la API, no tiene alta disponibilidad, no orquesta el pipeline con reintentos y usa
datos sintéticos cuya estructura latente fue puesta a mano. Los resultados muestran que el
**diseño de datos** funciona; no demuestran qué estrategia de recomendación ganaría con datos
reales.

La tabla completa de qué está implementado y qué queda propuesto está en `docs/informe.md` §14.8.
