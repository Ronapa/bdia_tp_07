# TP Integrador — Sistema de recomendación de contenidos

**Bases de Datos para Inteligencia Artificial — CEIA, FIUBA**
Docente: Esp. Lic. Martín Aníbal Lacheski · Año 2026

**Caso de uso 10** — Sistema de recomendación de contenidos
**Impronta del grupo:** *NexoMedia*, un medio digital multiformato (artículos, videos, podcasts,
newsletters y galerías).

## Integrantes

| Integrante | Aportes principales |
|---|---|
| *Federica Pavese* | Índices, vistas y seguridad en PostgreSQL; embeddings, índices vectoriales y consultas de similitud. |
| *Leandro Saraco* | Generador de datos sintéticos, datos de referencia, carga y verificaciones de PostgreSQL; muestras, informe y guía práctica. |
| *Maximiliano Lulic* | Infraestructura inicial con Docker Compose; modelo documental y carga del clickstream en MongoDB; grafo de recomendación en Neo4j. |
| *Pablo Salvagni* | Conciliación Silver/Gold, serving en Redis y orquestación; stream de ingesta, API, consultas, README y diagramas finales. |
| *Rodrigo Parra* | Informe y modelos iniciales; schemas y modelo relacional; MinIO, capas Bronze/Silver/Gold y demo de recomendaciones. |

---

## Descripción breve de la solución

*NexoMedia* publica unas 30 piezas por día y tiene miles en su archivo, pero la portada muestra
veinte. Todo lo demás es, en la práctica, invisible.

Este trabajo diseña la **capa de datos** que permitiría sostener un sistema de recomendación
personalizado sobre ese catálogo: qué datos se necesitan, dónde vive cada uno, cómo se consultan,
cómo se protegen y cómo escalan. No entrena ningún modelo: el objeto del trabajo es la solución
de datos.

La solución es **políglota**: cinco motores, cada uno resolviendo la pregunta que los otros cuatro
resuelven mal.

| Pregunta del negocio | Motor |
|---|---|
| ¿Qué contenidos existen y quién puede verlos? | **PostgreSQL 17** |
| ¿De qué habla este contenido? | **pgvector** |
| ¿Qué hizo cada usuario, minuto a minuto? | **MongoDB 8** |
| ¿Qué le muestro *ahora*, en menos de 1 ms? | **Redis 8** |
| ¿Qué leyó la gente parecida a esta, y por qué? | **Neo4j 5.26** |
| ¿Qué estrategia de recomendación conviene dejar prendida? | **DuckDB + MinIO** |

El sistema implementa **cinco estrategias de recomendación**, cada una apoyada en el motor que
mejor la resuelve, y registra qué se le mostró a cada usuario para poder medirlas.

La correspondencia no es uno a uno, y conviene ser preciso: dos estrategias se **calculan** en
DuckDB y se **sirven** desde Redis, y MongoDB no resuelve ninguna estrategia por sí mismo — es la
fuente del comportamiento con el que se calculan todas.

| Estrategia | Dónde se calcula | Desde dónde se sirve |
|---|---|---|
| `popularidad` | DuckDB (capa Gold) | Redis (ZSET) |
| `contenido_similar` | pgvector | PostgreSQL, en el momento |
| `colaborativo_item` | DuckDB (co-ocurrencia) | PostgreSQL (tabla precalculada) |
| `grafo_covisualizacion` | Neo4j | Neo4j, en el momento |
| `hibrido` | Python, mezclando las tres señales | Redis (ZSET precalculado) |

---

## Ruta rápida

Requisitos: Docker con Compose v2, ~8 GB de RAM libres y ~15 GB de disco.

```bash
cp .env.example .env
```

En Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Verificá que el entorno pueda levantar:

```bash
sh scripts/verificar_entorno.sh
```

Levantá y construí todo con un solo comando:

```bash
sh scripts/ejecutar_pipeline.sh
```

> La primera corrida descarga las imágenes y el modelo de embeddings (~500 MB) y tarda entre 15
> y 30 minutos. Las siguientes, unos pocos minutos.

Resultado esperado al final:

```text
--- Paso 14: verificacion final ---
NOTICE:  Conteos verificados contra control.control_cargas.
NOTICE:  Controles de integridad aprobados.
Verificacion aprobada.

Pipeline completo.
  pgAdmin        : http://127.0.0.1:8090
  Mongo Express  : http://127.0.0.1:8091
  Neo4j Browser  : http://127.0.0.1:7476
  MinIO Consola  : http://127.0.0.1:9011
  API demo       : http://127.0.0.1:8020/docs
```

Para ver las cinco estrategias funcionando sobre un mismo usuario:

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/demo_recomendaciones.py --usuario 1
```

> Si tu Docker no tiene el plugin `compose`, usá `docker-compose` en lugar de `docker compose`.
> Los scripts del proyecto lo detectan solos.

---

## Servicios

| Servicio | Responsabilidad | Acceso local |
|---|---|---|
| `postgres-operacional` | Catálogo, personas, permisos, impresiones, embeddings, capa Gold | `127.0.0.1:5440` |
| `pgadmin-operacional` | Cliente web de PostgreSQL | <http://127.0.0.1:8090> |
| `mongodb-eventos` | Clickstream, cuerpos, comentarios, búsquedas, telemetría | `127.0.0.1:27020` |
| `mongo-express-eventos` | Visor web de MongoDB (opcional) | <http://127.0.0.1:8091> |
| `redis-serving` | Rankings, feature store, caché, stream de ingesta | `127.0.0.1:6390` |
| `neo4j-grafo` | Grafo de recomendación y explicabilidad | <http://127.0.0.1:7476> |
| `minio-lake` | Object storage del lakehouse | <http://127.0.0.1:9011> |
| `minio-admin` | Cliente `mc` para publicar la capa Bronze | — |
| `duckdb-transformer` | Procesa Bronze → Silver → Gold | — |
| `orquestador` | Genera los datos y carga los cinco motores | — |
| `api-recomendador` | API de demostración. Usa usuarios de mínimo privilegio en los cuatro motores; arranca al final con el perfil `consumo` | <http://127.0.0.1:8020/docs> |

Todos los puertos se publican **solo en `127.0.0.1`**. Las credenciales de `.env.example` son
didácticas y exclusivamente locales.

En Neo4j Browser configurá la *Connect URL* como `bolt://127.0.0.1:7690`, porque el valor
predeterminado del navegador apunta al puerto `7687`.

---

## Configuración

| Variable | Valor predeterminado | Uso |
|---|---|---|
| `POSTGRES_PORT` | `5440` | Puerto del host para PostgreSQL |
| `PGADMIN_PORT` | `8090` | pgAdmin |
| `MONGO_PORT` | `27020` | MongoDB |
| `MONGO_EXPRESS_PORT` | `8091` | Mongo Express |
| `REDIS_PORT` | `6390` | Redis |
| `NEO4J_HTTP_PORT` / `NEO4J_BOLT_PORT` | `7476` / `7690` | Neo4j |
| `MINIO_API_PORT` / `MINIO_CONSOLE_PORT` | `9010` / `9011` | MinIO |
| `API_PORT` | `8020` | API de recomendación |
| `API_DB_USER` / `API_DB_PASSWORD` | `bdia_api` | Rol de PostgreSQL con el que se conecta la API: **no es superusuario**, así que está sujeto a RLS |
| `MONGO_LECTURA_*` / `REDIS_LECTURA_*` / `NEO4J_CONSULTA_*` | usuarios acotados | Con los que la API consulta MongoDB, Redis y Neo4j |
| `MONGO_INGESTA_USER` / `MONGO_INGESTA_PASSWORD` | `bdia_mongo_ingesta` | Usuario de MongoDB que solo puede escribir eventos, nunca leerlos |
| `MINIO_TRANSFORMADOR_*` | `bdia_lake_transformador` | Usuario de MinIO acotado al bucket `lakehouse` que usa DuckDB en lugar de root |
| `SEMILLA` | `42` | Fija el dataset por completo |
| `ESCALA` | `media` | `chica` / `media` / `grande` |
| `MODELO_EMBEDDING` | `intfloat/multilingual-e5-small` | Modelo de 384 dimensiones |
| `EMBEDDINGS_MODO` | `modelo` | `simulado` para correr sin descargar el modelo |

Los puertos están elegidos para no chocar con las prácticas de las clases 2 a 6.

---

## Datos principales identificados

| Tipo | Ejemplos | Dónde vive |
|---|---|---|
| Estructurado | Usuarios, planes, suscripciones, contenidos, secciones, etiquetas, impresiones | PostgreSQL |
| Semiestructurado | Metadatos por tipo de contenido, diffs de versiones, eventos del clickstream | `JSONB` + MongoDB |
| No estructurado | Cuerpos en bloques, transcripciones, comentarios | MongoDB |
| Vectorial | Embeddings de contenido y perfiles de usuario | pgvector, `VECTOR(384)` |
| Analítico | Dimensiones, hechos, agregados de popularidad | DuckDB → `analitica.*` |
| Sensible | Correo (cifrado + hash), año de nacimiento, historial de lectura | PostgreSQL con RLS; clickstream con índice TTL |
| Auditoría | Cambios sobre contenidos, usuarios, suscripciones y moderaciones | `auditoria.eventos` |

Muestras versionadas y legibles sin levantar nada: [`data/ejemplos/`](data/ejemplos/).

---

## Estructura del repositorio

```text
bdia_tp_07/
├── README.md                     este archivo
├── docker-compose.yml            11 servicios, puertos solo en 127.0.0.1
├── Dockerfile.orquestador        imagen Python (clientes de los 5 motores)
├── Dockerfile.duckdb             imagen DuckDB (multi-stage)
├── .env.example                  credenciales y puertos (copiar a .env)
│
├── docs/
│   ├── informe.md                informe técnico: los 15 puntos de la consigna
│   ├── guia-practica.md          recorrido paso a paso del entorno
│   └── diagramas/                modelo conceptual, lógico, físico y arquitectura (.mmd)
│
├── data/ejemplos/                muestra de cada estructura de datos
│
├── db/                           PostgreSQL
│   ├── estructura/               01..07  schemas, tablas, particiones, auditoría
│   ├── indices_vistas/           01..03  índices, vistas, vista materializada
│   ├── seguridad/                01..04  roles, RLS, auditoría, anonimización
│   ├── datos/                    01      datos de referencia
│   └── consultas/                00..06  verificación, consultas y pruebas de aislamiento
│
├── nosql/
│   ├── modelo_nosql.md           modelo documental, clave-valor y grafo
│   ├── mongodb/                  carga, índices, usuarios y 5 archivos de consultas
│   ├── redis/                    estructuras de serving y sus consultas
│   └── neo4j/                    restricciones, índices, usuarios y 3 archivos de Cypher
│
├── vectorial/
│   ├── modelo_vectorial.md       qué se vectoriza, con qué metadatos y qué acceso
│   ├── 01_crear_indices_vectoriales.sql
│   └── consultas/                similitud y comparación de índices
│
├── analitico/                    DuckDB — Medallion
│   ├── 01_perfilar_bronze.sql    schema-on-read, sin corregir nada
│   ├── 02_procesar_silver.sql    tipado, limpieza, sesionización y rechazos
│   ├── 03_publicar_silver.sql    Parquet ZSTD al lake
│   ├── 04_cargar_gold.sql        modelo dimensional + co-ocurrencia → PostgreSQL
│   └── 05_verificar_calidad.sql  conciliación Silver ↔ Gold
│
├── orquestador/                  Python
│   ├── generar_datos.py          dataset sintético determinista
│   ├── cargar_postgres.py        COPY masivo + pgcrypto para el correo
│   ├── cargar_mongo.py           carga masiva del clickstream
│   ├── generar_embeddings.py     embeddings y perfiles vectoriales
│   ├── exportar_bronze.py        export seudonimizado al lakehouse
│   ├── publicar_serving.py       capa de serving en Redis
│   ├── consumir_stream.py        drena el stream de ingesta hacia MongoDB
│   ├── cargar_neo4j.py           construcción del grafo
│   ├── recomendador_api.py       API de demostración
│   └── demo_recomendaciones.py   las 5 estrategias por consola
│
├── scripts/                      *.sh POSIX, con `set -eu`
│   ├── comun.sh                  detecta `docker compose` o `docker-compose`
│   ├── verificar_entorno.sh      chequea Docker, puertos y recursos
│   ├── ejecutar_pipeline.sh      reconstruye todo end-to-end (14 pasos)
│   ├── ejecutar_sql.sh           corre un .sql dentro de PostgreSQL
│   ├── ejecutar_mongo.sh         corre un .js dentro de MongoDB
│   ├── ejecutar_cypher.sh        corre un .cypher dentro de Neo4j
│   ├── ejecutar_duckdb.sh        corre un .sql de DuckDB con el acceso al lake resuelto
│   ├── cargar_bronze.sh          publica la capa Bronze en MinIO (con manifiesto)
│   ├── configurar_minio.sh       usuarios acotados al lakehouse: lectura y transformador
│   ├── generar_documentacion.sh  regenera los diagramas .png y exporta el informe a .pdf
│   ├── detener_proyecto.sh       detiene todo sin perder datos (incluye el perfil consumo)
│   └── reiniciar_proyecto.sh     vuelve al estado inicial (DESTRUCTIVO)
│
└── anexos/material_complementario.md
```

---

## Instrucciones para revisar la implementación

**1. El modelo relacional y la seguridad, desde pgAdmin**

Entrá a <http://127.0.0.1:8090>, registrá el servidor con host `postgres-operacional`, puerto
`5432` y las credenciales de `.env`. Los scripts SQL están montados en `/home/pgadmin/db`.

Abrí y ejecutá bloque por bloque [`db/consultas/05_prueba_aislamiento.sql`](db/consultas/05_prueba_aislamiento.sql)
y [`db/consultas/06_prueba_aislamiento_api.sql`](db/consultas/06_prueba_aislamiento_api.sql): son
la demostración de que el Row Level Security funciona, para los usuarios finales y para el rol con
el que se conecta la API. **Varios bloques deben fallar**, y ese es el resultado esperado.

**2. Las consultas representativas**

```bash
docker compose exec -T postgres-operacional \
  sh /scripts/ejecutar_sql.sh /sql/consultas/02_rendimiento_estrategias.sql
```

**3. El modelo documental**

Los cuatro archivos de [`nosql/mongodb/consultas/`](nosql/mongodb/consultas/) están pensados para
copiar y pegar en el shell de MongoDB o en Compass, bloque por bloque.

**4. El grafo**

Entrá al Neo4j Browser en <http://127.0.0.1:7476> y pegá las consultas de
[`nosql/neo4j/consultas/`](nosql/neo4j/consultas/). La de explicabilidad devuelve la recomendación
junto con la frase que la justifica.

**5. La capa de serving**

```bash
docker compose exec -T redis-serving \
  redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" ZREVRANGE rec:trending:global 0 9 WITHSCORES
```

**6. El lakehouse**

Entrá a la consola de MinIO en <http://127.0.0.1:9011> y navegá el bucket `lakehouse`:
`bronze/` (CSV crudo por lote), `silver/` (Parquet), `calidad/` (rechazos y resumen).

---

## Consultas incluidas

La consigna pide un mínimo de 5. El proyecto entrega **102 consultas representativas**, cada una
con la pregunta de negocio que responde escrita arriba, más **32 bloques de prueba de seguridad**
cuyo resultado esperado es un error.

El detalle por archivo está en la tabla canónica de [`docs/informe.md`](docs/informe.md) §10.

| Motor | Consultas | Dónde |
|---|---|---|
| PostgreSQL | 17 | `db/consultas/` |
| pgvector | 16 | `vectorial/consultas/` |
| MongoDB | 23 | `nosql/mongodb/consultas/` |
| Neo4j | 9 | `nosql/neo4j/consultas/` |
| Redis | 23 | `nosql/redis/consultas/` |
| DuckDB | 14 | `analitico/` |
| Pruebas de aislamiento | 32 | `db/consultas/`, `nosql/mongodb/consultas/` y `nosql/neo4j/consultas/` |

---

## Principales decisiones de diseño

1. **PostgreSQL guarda lo que se filtra; MongoDB, lo que se lee.** El cuerpo del contenido es
   texto largo de estructura variable que nunca se filtra ni se ordena en SQL: traerlo en cada
   consulta del feed sería pagar IO por datos que no se usan.
2. **Los embeddings viven en la misma base que el catálogo.** Eso permite **prefiltrar** por
   estado, vigencia y nivel de acceso en la misma consulta que la similitud. Con una base
   vectorial separada habría que filtrar después, y los ids no autorizados ya habrían salido.
3. **Redis no guarda nada que no se pueda reconstruir.** Por eso puede no tener durabilidad ni
   transacciones: no es una base de datos, es un resultado calculado.
4. **El grafo es una proyección regenerable**, lo que autoriza a desnormalizar título, estado y
   nivel de acceso en cada nodo sin costo de consistencia.
5. **Ningún identificador directo de persona sale hacia el lakehouse:** el export pasa por la
   vista anonimizada y reemplaza `usuario_id` por un seudónimo.
6. **El servicio que atiende tráfico está sujeto al mismo RLS que todos, y no usa credenciales
   administrativas en ningún motor.** La API se conecta con `bdia_api` en PostgreSQL —no es
   superusuario, así que si un endpoint se olvidara de filtrar el motor lo corta igual— y con
   usuarios acotados en Redis, MongoDB y Neo4j. Registrar una impresión a nombre de otro usuario
   falla con *new row violates row-level security policy*, no con una validación del código.
7. **Todo paso que puede perder datos tiene un control que aborta.** Las verificaciones encontraron
   cinco defectos reales durante el desarrollo, cuatro de ellos silenciosos (§8.2 del informe).

---

## Reiniciar o cerrar

Detener sin perder datos:

```bash
sh scripts/detener_proyecto.sh
```

> **Ojo con `docker compose stop` a secas:** no detiene la API. El servicio `api-recomendador`
> está declarado con el perfil `consumo` —arranca al final del pipeline, porque depende de usuarios
> que crean pasos intermedios—, y los perfiles de Compose funcionan igual en las dos direcciones:
> lo que no se levanta con `up` tampoco se detiene con `stop` si no se nombra el perfil. El script
> lo resuelve; a mano sería `docker compose --profile consumo stop`.

Volver al estado inicial (**DESTRUCTIVO**: borra volúmenes, la base local de DuckDB y los datos
generados):

```bash
sh scripts/reiniciar_proyecto.sh
```

Comprobar el determinismo del dataset: reiniciar y volver a correr el pipeline debe reproducir
exactamente los mismos conteos.

---

## Problemas frecuentes

- **`sh scripts/verificar_entorno.sh` dice que un puerto está ocupado.** Cambiá el valor en `.env`
  y volvé a intentar. Es lo más común si tenés levantadas las prácticas de otras clases.
- **`docker compose` no existe.** Usá `docker-compose`. Los scripts detectan cuál está disponible.
- **Neo4j no llega a `healthy`.** Suele ser memoria: necesita ~1 GB. Verificá con
  `docker compose logs neo4j-grafo`. Si aparece *Unrecognized setting*, hay una variable
  `NEO4J_*` mal escrita en el compose.
- **El paso de embeddings tarda mucho o falla sin red.** Poné `EMBEDDINGS_MODO=simulado` en `.env`:
  genera vectores deterministas por hashing y el pipeline corre completo sin descargar el modelo.
  Sirve para revisar la implementación, no para evaluar la calidad del ranking.
- **La capa Gold quedó con datos de otra corrida.** Bronze es inmutable dentro de una versión del
  dataset. Si cambiaste `SEMILLA` o `ESCALA`, `scripts/cargar_bronze.sh` detecta el cambio por el
  manifiesto y republica el lote; si algo quedó a medias, corré `scripts/reiniciar_proyecto.sh`.
- **La verificación aborta con "Conteos inesperados".** Es el comportamiento correcto: la carga
  quedó incompleta. Reiniciá el proyecto y volvé a correr el pipeline.
- **Detuve todo pero la API sigue corriendo y ocupa el puerto 8020.** `docker compose stop` no
  alcanza a los servicios con perfil. Usá `sh scripts/detener_proyecto.sh`, o
  `docker compose --profile consumo stop`. Lo mismo vale para `ps`: sin el perfil, la API no
  aparece en el listado.

---

## Limitaciones y posibles mejoras

**Limitaciones declaradas**

- No es un Lakehouse completo: falta formato transaccional de tabla (Delta, Iceberg), *time
  travel* y catálogo de metadatos.
- El pipeline es un script secuencial, no un DAG orquestado con reintentos.
- El volumen es de demostración: el `EXPLAIN` muestra la *forma* del plan, no tiempos
  representativos de producción.
- La seudonimización no equivale a anonimización: si se compromete la clave del HMAC, un atacante
  puede probar identificadores candidatos y vincular registros. La clave vive en
  `control.secretos`, no en el código, pero en producción iría en un gestor de secretos.
- La API **no autentica**: la identidad llega en la cabecera `X-Usuario-Id`, que simula un token ya
  validado, y cualquiera puede enviarla. Lo que sí está resuelto es la **autorización**: a qué tiene
  derecho un usuario sale siempre de la base y lo impone el RLS, nunca lo declara el cliente.
- **Neo4j Community no soporta roles**, así que el usuario separado del grafo no puede ser de solo
  lectura. Se compensa no guardando datos personales en el grafo.
- La auditoría es append-only para los roles de aplicación, pero no frente a un superusuario.
- Los datos son sintéticos: la estructura latente fue puesta a mano, así que los resultados
  muestran que el diseño funciona, no qué estrategia ganaría con datos reales.
- Una sola instancia de cada motor; no hay alta disponibilidad ni réplicas.

**Mejoras propuestas**

1. Orquestar el pipeline con Airflow, con alertas sobre los controles de calidad.
2. Réplica de lectura de PostgreSQL para aislar la carga analítica.
3. Migrar Silver a Apache Iceberg.
4. Búsqueda híbrida literal + semántica con *reciprocal rank fusion*.
5. Medir el recall real de HNSW contra el kNN exacto y ajustar `ef_search` con ese dato.
6. Reemplazar Redis Streams por Kafka cuando el volumen de ingesta lo justifique.

---

## Documentos del trabajo

| Documento | Contenido |
|---|---|
| [`docs/informe.md`](docs/informe.md) | Informe técnico completo: los 15 puntos de la consigna |
| [`docs/guia-practica.md`](docs/guia-practica.md) | Recorrido paso a paso del entorno |
| [`nosql/modelo_nosql.md`](nosql/modelo_nosql.md) | Modelo documental, clave-valor y grafo |
| [`vectorial/modelo_vectorial.md`](vectorial/modelo_vectorial.md) | Modelo de datos vectorial |
| [`docs/diagramas/`](docs/diagramas/) | Modelo conceptual, lógico, físico y arquitectura |
| [`anexos/material_complementario.md`](anexos/material_complementario.md) | Material de apoyo |
