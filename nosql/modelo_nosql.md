# Modelo NoSQL

Este documento describe el modelo de datos de los tres motores NoSQL del sistema (MongoDB
documental, Redis clave-valor y Neo4j grafo) y justifica las decisiones de embebido, referencia,
duplicación y desnormalización que se tomaron en cada uno.

La consigna pide explícitamente que usar NoSQL no signifique evitar el modelado. Lo que sigue
es el modelado.

---

## 1. MongoDB: base documental

### 1.1 Colecciones

| Colección | Qué guarda | Por qué acá |
|---|---|---|
| `eventos_interaccion` | Clickstream crudo | Volumen alto de escritura, esquema que varía por tipo de evento |
| `cuerpos_contenido` | Cuerpo del contenido en bloques | Texto largo, estructura heterogénea, nunca se filtra ni se ordena en SQL |
| `comentarios` | Comentarios con respuestas embebidas | Documento auto-contenido, se lee entero o no se lee |
| `busquedas` | Consultas del buscador y sus resultados | Subdocumento de filtros con claves opcionales |
| `telemetria_reproduccion` | Latidos del reproductor | Serie temporal pura → colección **timeseries** |

### 1.2 Documento de ejemplo: `eventos_interaccion`

```json
{
  "_id": ObjectId("..."),
  "evento_id": "EV-00012345",
  "usuario_id": 842,
  "sesion_id": "S-000842-2026071508",
  "contenido_id": 1177,
  "tipo_evento": "scroll",
  "ocurrido_en": ISODate("2026-07-15T08:42:11Z"),
  "contexto": {
    "dispositivo": "movil",
    "canal": "redes",
    "pais": "AR",
    "superficie": "articulo"
  },
  "metricas": {
    "segundos_visibles": 214,
    "porcentaje_scroll": 78.4
  }
}
```

El mismo `_id` con `tipo_evento: "impresion"` **no** trae `metricas`; trae en cambio:

```json
  "origen_recomendacion": {
    "estrategia": "hibrido",
    "posicion": 3,
    "variante_ab": "tratamiento"
  }
```

Y con `tipo_evento: "me_gusta"` no trae ninguno de los dos.

**Esa variabilidad es el argumento central.** En un modelo relacional habría tres caminos, y
los tres son peores:

| Alternativa relacional | Problema |
|---|---|
| Una tabla con todas las columnas | 6 columnas nullables; el 70% de las filas tiene la mayoría en `NULL` |
| Una tabla por tipo de evento | 10 tablas casi idénticas; cada consulta transversal es un `UNION ALL` de 10 |
| Una tabla EAV (entidad-atributo-valor) | Pierde el tipado y obliga a un pivote en cada lectura |

### 1.3 Embebido contra referencia

La regla que se aplicó, en las tres colecciones donde hubo que decidir:

> Se **embebe** cuando el subdocumento (a) se lee siempre junto al padre, (b) tiene cardinalidad
> acotada y (c) se reemplaza en conjunto. Si falla cualquiera de las tres, se **referencia**.

| Relación | Decisión | Justificación |
|---|---|---|
| `cuerpos_contenido.bloques` | **Embebido** | Se leen siempre juntos, son unidades (no miles) y el editor los guarda de una vez |
| `comentarios.respuestas` | **Embebido** | Ídem; el límite está declarado: con cientos de respuestas por comentario habría que referenciarlas |
| `eventos.contexto` y `eventos.metricas` | **Embebido** | Son parte indivisible del evento |
| `contenido_id`, `usuario_id` | **Referencia** a PostgreSQL | Ahí está la fuente de verdad, la integridad referencial y el control de acceso por fila |
| `busquedas.resultados` | **Referencia** (array de ids) | Los contenidos cambian; guardar una copia congelaría el título de hace tres meses |

**Lo que a propósito NO se duplicó:** el título, la sección y el estado del contenido. Duplicarlos
haría que el clickstream se pudiera leer sin salir de MongoDB, pero:

- crearía dos fuentes de verdad para el mismo dato;
- renombrar una sección obligaría a reescribir millones de documentos;
- el estado de publicación quedaría fuera del alcance del Row Level Security, que es
  justamente la barrera que impide recomendar borradores.

El `JOIN` entre motores lo resuelve la aplicación: pide los ids a MongoDB o Redis y trae los
datos del catálogo desde PostgreSQL. Es un costo de integración explícito y aceptado.

### 1.4 Validadores

Todas las colecciones críticas llevan `$jsonSchema` con `validationAction: "error"`. El
validador exige **el contrato mínimo** (`usuario_id`, `contenido_id`, `tipo_evento`,
`ocurrido_en`) y deja libres `metricas` y `origen_recomendacion`.

Ese equilibrio es deliberado: si el validador enumerara todos los campos posibles, agregar un
tipo de evento nuevo sería una migración, y se perdería exactamente la ventaja por la que se
eligió una base documental.

### 1.5 Índices

| Índice | Tipo | Consulta que sostiene |
|---|---|---|
| `{usuario_id: 1, ocurrido_en: -1}` | Compuesto | Historial reciente de un usuario (feature store) |
| `{contenido_id: 1, ocurrido_en: -1}` | Compuesto | Métricas de consumo de un contenido |
| `{sesion_id: 1, ocurrido_en: 1}` | Compuesto | Reconstrucción de una sesión |
| `{"origen_recomendacion.estrategia": 1, ...}` | **Parcial** (`tipo_evento: "impresion"`) | Atribución de recomendaciones; indexa el 30% de la colección |
| `{ocurrido_en: 1}` con `expireAfterSeconds` | **TTL** | Retención del clickstream (90 días en producción) |
| `{"bloques.tipo": 1}` | **Multikey** | "Qué contenidos incluyen una cita" |
| `{"bloques.texto": "text"}` | **Texto** (español) | Búsqueda literal dentro del cuerpo |
| `{creado_en: 1}` con `partialFilterExpression` | **Parcial** (`estado: "pendiente"`) | Bandeja del moderador |

### 1.6 Colección timeseries

`telemetria_reproduccion` se declara con `timeField: "ocurrido_en"`, `metaField: "origen"` y
`granularity: "seconds"`. MongoDB agrupa internamente las mediciones por metadato y ventana
temporal, lo que reduce el almacenamiento de forma notoria frente a un documento por medición.

**El límite, declarado:** una colección timeseries no admite `updateOne` ni `deleteOne` sobre
una medición individual, ni índices únicos. Por eso la telemetría vive ahí y el clickstream de
negocio (que sí puede necesitar corrección) vive en una colección común.

### 1.7 Escalabilidad

- **Sharding** por `hash(usuario_id)`: el clickstream se consulta casi siempre por usuario, así
  que esa clave reparte parejo y mantiene local la consulta más frecuente. Shardear por fecha
  concentraría toda la escritura en el shard del día en curso.
- **Índice TTL**: acota el crecimiento y cumple con la minimización de datos. El valor
  analítico ya quedó agregado en la capa Gold del lakehouse. En producción, 90 días; en este
  entorno el valor está subido a propósito, porque con 90 días el reaper borraría el dataset
  sintético (ventana fija) y las verificaciones por conteo exacto dejarían de funcionar.
- **Índices parciales**: reducen el costo de escritura, que es lo que importa en una colección
  dominada por inserts.

### 1.8 Control de acceso

Dos perfiles separados, creados por `nosql/mongodb/02_usuarios_y_permisos.js`:

| Usuario | Puede | No puede |
|---|---|---|
| `bdia_mongo_lectura` | `find` sobre `eventos_interaccion`, `cuerpos_contenido` y `busquedas` | Leer `comentarios`, escribir, borrar, crear índices |
| `bdia_mongo_ingesta` | `insert` sobre `eventos_interaccion` | **Leer** cualquier cosa |

Dos decisiones a destacar:

- El perfil analítico **no puede leer `comentarios`**: es la única colección con texto libre
  escrito por personas, donde alguien puede haber dejado un dato personal que ningún esquema
  controla.
- El usuario de ingesta **no puede leer**. Es el que corre en `consumir_stream.py`, el componente
  más expuesto del sistema: si quedara comprometido, no serviría para exfiltrar el historial de
  nadie.

**El límite del motor, declarado:** MongoDB no tiene un equivalente al Row Level Security. No se
puede expresar "este usuario solo ve los documentos cuyo `usuario_id` sea el suyo": o ve la
colección entera, o no la ve. Es la razón concreta por la que los datos personales viven en
PostgreSQL y acá solo hay comportamiento referenciado por id.

---

## 2. Redis: clave-valor

### 2.1 Espacio de claves

| Clave | Estructura | TTL | Por qué esa estructura |
|---|---|---|---|
| `rec:trending:global` | ZSET | `ttl` | El caso de uso **es** un ranking; `ZREVRANGE` devuelve el top-N ordenado en O(log n + N) |
| `rec:trending:seccion:<slug>` | ZSET | `ttl` | Ídem, por sección |
| `rec:usuario:<id>:top` | ZSET | `ttl` | Feed híbrido precalculado |
| `usuario:<id>:vistos` | SET | `ttl` x8 | La pregunta es de pertenencia (`SISMEMBER`), y eso es O(1) |
| `usuario:<id>:features` | HASH | `ttl` x8 | Se leen varios campos juntos con un `HGETALL` y se actualizan de a uno |
| `contenido:<id>:meta` | HASH | `ttl` x4 | Cache de metadatos para no golpear PostgreSQL al renderizar |
| `sesion:<token>` | STRING | 30 min | Valor opaco con expiración natural |
| `ratelimit:<usuario>:<minuto>` | STRING + `INCR`/`EXPIRE` | 60 s | Contador atómico que se destruye solo |
| `cola:eventos` | STREAM | — | Necesita orden, grupos de consumo y confirmación; una lista no da ninguna de las tres |

El `ttl` es el parámetro `--ttl` de `publicar_serving.py`. **En producción sería 900 segundos**:
si el pipeline se cae, a los quince minutos el sitio vuelve al ranking global en lugar de servir
recomendaciones de ayer. En este entorno el valor por defecto es de 24 horas, para que se pueda
revisar al día siguiente sin volver a correr el pipeline.

### 2.2 Qué NO guarda Redis

**Nada que no se pueda reconstruir.** Todo lo que hay en Redis sale de PostgreSQL o de la capa
Gold: si el servidor se pierde, se vuelve a correr `orquestador/publicar_serving.py`.

Esa propiedad es la que habilita las decisiones que siguen: sin durabilidad (`appendonly no`),
sin transacciones y en memoria. Redis no es una base de datos en esta arquitectura, es un
resultado calculado.

**Tampoco guarda contenido no publicado.** Solo se cachean los contenidos que pasan por
`catalogo.vw_contenidos_publicables`. Redis no tiene Row Level Security: lo que no debe salir,
no sale de PostgreSQL.

### 2.3 Política de memoria y su compromiso

La configuración es `maxmemory 256mb` con `maxmemory-policy allkeys-lru`. Es correcta para los
caches y **es peligrosa para el stream**: bajo presión de memoria, Redis podría desalojar
`cola:eventos` junto con el resto.

En producción esto se resuelve separando el stream a otra instancia (o a otro índice de base con
su propia política). Se deja documentado como el compromiso que es, no resuelto en silencio.

### 2.4 Aislamiento

Redis no tiene permisos por fila ni por tabla. Lo que sí tiene son **ACL por comando y por
patrón de clave**:

```
ACL SETUSER app_lectura on >clave ~rec:* ~contenido:* ~usuario:* +@read -@dangerous
```

**El límite, declarado:** `~usuario:*` alcanza a *todos* los usuarios. Redis no puede expresar
"solo las claves de este usuario final", así que el aislamiento entre personas sigue siendo
responsabilidad de la aplicación. Es una diferencia real con el RLS de PostgreSQL, y es la razón
por la que los datos personales sensibles no viven en Redis.

---

## 3. Neo4j: base de grafos

### 3.1 Modelo

**Nodos**

| Etiqueta | Propiedades | Restricción |
|---|---|---|
| `:Usuario` | `usuario_id`, `pais`, `plan` | `usuario_id` único |
| `:Contenido` | `contenido_id`, `titulo`, `seccion`, `seccion_raiz`, `tipo`, `nivel_acceso`, `estado`, `fecha_publicacion` | `contenido_id` único |
| `:Seccion` | `slug`, `nombre`, `raiz` | `slug` único |
| `:Etiqueta` | `slug`, `nombre` | `slug` único |

**Relaciones**

| Relación | Propiedades | Dirección |
|---|---|---|
| `(:Usuario)-[:VIO]->(:Contenido)` | `veces`, `ultima_vez`, `completo` | Usuario → Contenido |
| `(:Usuario)-[:GUARDO]->(:Contenido)` | — | Usuario → Contenido |
| `(:Usuario)-[:SIGUE]->(:Seccion)` | — | Usuario → Sección |
| `(:Usuario)-[:NO_LE_INTERESA]->(:Seccion)` | — | Usuario → Sección |
| `(:Usuario)-[:ESCRIBIO]->(:Contenido)` | — | Autor → Contenido |
| `(:Contenido)-[:PERTENECE_A]->(:Seccion)` | — | Contenido → Sección |
| `(:Contenido)-[:TIENE_ETIQUETA]->(:Etiqueta)` | `relevancia` | Contenido → Etiqueta |
| `(:Contenido)-[:SIMILAR_A]->(:Contenido)` | `score`, `origen` | Contenido → Contenido |

### 3.2 Patrones de recorrido

| Consulta | Patrón | Saltos |
|---|---|---|
| Co-visualización | `(u)-[:VIO]->(c)<-[:VIO]-(otro)-[:VIO]->(rec)` | 3 |
| Explicabilidad | `shortestPath((u)-[*..6]-(c))` | variable |
| Contenidos puente | `(a)<-[:VIO]-(u)-[:VIO]->(b)` con secciones distintas | 2 |
| Etiquetas afines | `(e1)<-[:TIENE_ETIQUETA]-(c)-[:TIENE_ETIQUETA]->(e2)` | 2 |
| Cold start | `(nuevo)-[:TIENE_ETIQUETA]->(e)<-[:TIENE_ETIQUETA]-(parecido)<-[:VIO]-(u)` | 3 |

### 3.3 Por qué un grafo y no más SQL

La consulta de co-visualización en SQL son dos self-joins de la tabla de eventos; a tres saltos
son tres, y el planificador deja de encontrar un buen plan. En Cypher, cada salto es una flecha
más en el patrón.

Pero el argumento decisivo es otro: **el grafo devuelve el camino recorrido junto con el
resultado**. Eso convierte una recomendación en una recomendación explicable ("porque leíste X,
igual que otras personas que además leyeron Y") sin ningún trabajo extra. Reconstruir esa
explicación desde un ranking de SQL exigiría una segunda consulta por cada recomendación.

### 3.4 Desnormalización deliberada

Los nodos `:Contenido` llevan copiados `titulo`, `seccion`, `estado` y `nivel_acceso`, que son
datos maestros de PostgreSQL.

Se acepta la duplicación porque **el grafo es una proyección regenerable**: se borra y se
reconstruye entero en cada corrida del pipeline, y no es fuente de verdad de nada. Sin esas
propiedades, cada recorrido tendría que volver a PostgreSQL para saber si el contenido se puede
mostrar, y eso anularía la ventaja de resolver el recorrido en el grafo.

El precio es la latencia de actualización: entre que se despublica una nota y que se reconstruye
el grafo, el grafo la sigue considerando publicada. Por eso la API resuelve los títulos y valida
el acceso contra PostgreSQL antes de devolver la respuesta.

### 3.4.b Control de acceso: lo que Neo4j Community no puede

**La edición Community no tiene control de acceso basado en roles.** Se pueden crear usuarios, y
ahí termina: todos tienen acceso completo. `SHOW ROLES` devuelve *Unsupported administration
command*, y `SHOW USERS` muestra la columna `roles` en `NULL` para todos.

Está comprobado en `nosql/neo4j/consultas/03_limitaciones_community.cypher`, que contiene el
comando que falla.

Como el motor no puede restringir el **acceso**, este diseño restringe el **dato**: los nodos
`:Usuario` tienen `usuario_id`, `pais` y `plan`, y nada más. Quien leyera el grafo entero no
obtendría un solo identificador directo de persona. Si el grafo guardara correos o nombres, elegir
la Community Edition sería inadmisible.

### 3.5 Escalabilidad

- Restricciones de unicidad: además de garantizar la unicidad, crean el índice que hace que el
  `MERGE` de la carga sea O(log n) en lugar de un barrido completo.
- Índices por `estado`, `seccion_raiz` y `nivel_acceso`: sostienen los filtros que aparecen en
  todas las consultas de recomendación.
- Índice sobre la propiedad `score` de `SIMILAR_A`: acelera el filtro por umbral de similitud.
- Profundidad acotada en los recorridos: sin `*..6` o similar, un grafo denso hace explotar la
  cantidad de caminos.
- Carga con `UNWIND` por lotes: una transacción por fila sería dos órdenes de magnitud más lenta.

---

## 4. Resumen: qué motor resuelve qué

| Pregunta del negocio | Motor | Por qué |
|---|---|---|
| ¿Qué contenidos existen y quién puede verlos? | PostgreSQL | Integridad referencial, RLS, ACID |
| ¿De qué habla este contenido? | pgvector | Similitud semántica con prefiltrado de acceso |
| ¿Qué hizo cada usuario, minuto a minuto? | MongoDB | Volumen, esquema variable, TTL |
| ¿Qué le muestro **ahora**, en menos de 1 ms? | Redis | Ranking precalculado en memoria |
| ¿Qué leyó la gente parecida a esta, y por qué? | Neo4j | Recorridos multi-salto explicables |
| ¿Qué estrategia conviene dejar prendida? | DuckDB → Gold | OLAP columnar sobre el lakehouse |

Ninguna de las seis se resolvería bien en los otros cinco motores. Ese es el argumento de usar
varios motores especializados, y también su costo: seis sistemas para operar, consistencia
eventual entre ellos y un pipeline que los mantiene sincronizados. El informe técnico desarrolla
ese balance.
