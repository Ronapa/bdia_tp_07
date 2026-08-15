# Informe técnico

## Trabajo Práctico Integrador — Bases de Datos para Inteligencia Artificial

**Carrera de Especialización en Inteligencia Artificial — FIUBA**
**Docente:** Esp. Lic. Martín Aníbal Lacheski
**Caso de uso:** 10 — Sistema de recomendación de contenidos
**Impronta del grupo:** *NexoMedia*, medio digital multiformato

**Integrantes**

| Integrante | Aportes principales |
|---|---|
| *(completar)* | *(completar)* |
| *(completar)* | *(completar)* |
| *(completar)* | *(completar)* |
| *(completar)* | *(completar)* |

---

## 1. Descripción del caso de uso

### 1.1 El problema

*NexoMedia* es un medio digital que publica artículos, videos, podcasts, newsletters y galerías
de fotos, organizados en una jerarquía editorial de tres niveles (Política > Elecciones >
Resultados). Publica del orden de 30 piezas por día y acumula miles en su archivo.

El problema es de descubrimiento: **la portada muestra veinte piezas y el catálogo tiene miles.**
Todo lo que no entra en la portada es, en la práctica, invisible. Eso produce tres efectos
concretos:

1. **Pérdida de valor del archivo.** Contenido vigente y pertinente que nunca vuelve a mostrarse.
2. **Baja conversión a suscripción.** El contenido premium no llega a los lectores que estarían
   dispuestos a pagarlo.
3. **Decisiones editoriales a ciegas.** La redacción no tiene forma de saber qué funciona más
   allá de las vistas del día.

Se busca diseñar la **capa de datos** que permitiría sostener un sistema de recomendación
personalizado: no el modelo, sino los datos que ese modelo necesitaría para existir, y las
garantías de integridad, seguridad y escalabilidad que los rodean.

### 1.2 Usuarios del sistema

| Rol | Qué hace | Qué necesita ver | Qué NO debe ver |
|---|---|---|---|
| **Lector** | Consume contenido, declara preferencias | Contenido publicado y vigente de su nivel de acceso | Borradores, contenido premium si no paga, datos de otros usuarios |
| **Suscriptor** | Lector con plan pago | Además, el contenido premium | Ídem |
| **Editor** | Crea y edita contenidos | Sus propios borradores en cualquier estado | Borradores de otros editores |
| **Moderador** | Revisa contenido y comentarios | Todo el catálogo, en cualquier estado | Datos personales de los lectores |
| **Analista** | Consulta indicadores | Métricas agregadas y usuarios anonimizados | Correos, edades exactas, cualquier identificador directo |
| **Administrador** | Gobierna la plataforma | Todo, incluida la auditoría | — |

### 1.3 Procesos que la solución debe soportar

- **Publicación editorial:** borrador → revisión → publicado → despublicado → archivado, con
  versionado y moderación.
- **Consumo:** registro de cada interacción del lector con cada pieza.
- **Recomendación:** generación de sugerencias por cinco estrategias distintas y registro de qué
  se mostró efectivamente.
- **Medición:** cálculo de CTR (*click-through rate*, la proporción de recomendaciones mostradas
  que terminan en un clic), cobertura, diversidad y retención por estrategia.
- **Gobierno de datos:** consentimiento, seudonimización, retención y auditoría.

### 1.4 Riesgos identificados en relación con los datos

Cada fila describe un riesgo concreto y el mecanismo que lo mitiga. Varios de esos mecanismos
(Row Level Security en particular) se explican recién en la sección de seguridad (§13); acá
alcanza con una definición mínima para seguir la tabla: **Row Level Security (RLS)** es un
mecanismo de PostgreSQL que filtra automáticamente qué filas puede ver o modificar cada rol,
directamente en el motor, sin que la aplicación tenga que acordarse de aplicar ese filtro en
cada consulta.

| Riesgo | Impacto | Mitigación implementada |
|---|---|---|
| El recomendador expone un borrador o contenido premium | Fuga de contenido, pérdida de ingresos | Prefiltrado dentro de la consulta vectorial + Row Level Security (§13) |
| Datos personales de comportamiento sin límite de retención | Exposición regulatoria | Índice TTL sobre el clickstream (90 días en producción); la capa Gold conserva solo agregados |
| El analista reidentifica usuarios | Violación de privacidad | Seudonimización + generalización + permisos por columna (§13) |
| Personalización sin consentimiento | Violación de privacidad | El perfil vectorial solo se calcula con consentimiento; la verificación aborta si no |
| Burbuja de filtro | Degradación del producto | Métricas de diversidad y cobertura (§10); diversificación por sección |
| Inconsistencia entre motores | Recomendaciones incorrectas | Conciliación Silver/Gold que aborta si los números no cierran (§8.1) |
| Pérdida silenciosa de filas en el pipeline | Métricas equivocadas sin síntoma | Balance aceptadas + rechazadas = recibidas, verificado |

---

## 2. Relevamiento de datos necesarios

### 2.1 Clasificación

Antes de elegir con qué se construye cada parte (§3), conviene mirar qué datos hay que guardar y
qué exige cada uno: forma, volumen, con qué urgencia se escribe y se lee, qué tan sensible es.
Esas exigencias son las que después van a decidir el motor; acá se plantean sin nombrar ninguno.

**Datos con forma fija y estable.** Corresponden a este grupo el catálogo editorial (contenidos,
secciones, etiquetas, versiones, moderaciones), la identidad y el negocio (usuarios, roles,
planes, suscripciones, consentimientos, preferencias) y el funcionamiento del recomendador
(estrategias, experimentos A/B, asignaciones e impresiones). En todos los casos cada registro
tiene los mismos campos y las relaciones entre entidades son claras (un contenido pertenece a una
sección, una suscripción pertenece a un usuario). Esas relaciones deben mantenerse siempre
válidas: una impresión que apunta a un contenido inexistente no es una variante posible, es un
dato corrupto. Es también el grupo que se consulta de forma inmediata, con baja tolerancia a la
inconsistencia (necesita ACID: que cada escritura sea atómica, consistente, aislada y durable, la
garantía estándar de una base transaccional), porque es la información contra la que se decide,
en el momento, qué puede ver cada usuario. Dentro de este grupo hay además datos sensibles:
correo electrónico y año de nacimiento son identificadores, directos o combinables, que no deben
viajar en texto plano ni permitir reidentificar a alguien fuera de su propio acceso. El
tratamiento técnico concreto de esa sensibilidad (cifrado, seudonimización, generalización,
permisos por columna) se desarrolla en la sección de seguridad (§13).

**Datos con forma variable.** Los metadatos por tipo de contenido, el diff de cada versión
editorial, el estado anterior y nuevo que registra la auditoría, los eventos del clickstream y los
filtros del buscador no tienen un conjunto fijo de columnas: un evento de "video reproducido"
trae campos que uno de "búsqueda" no tiene, y el diff de una versión editorial cambia de forma
según qué se haya modificado. Forzar estos datos a una tabla de columnas fijas produce, según el
caso, columnas mayormente vacías o una tabla distinta por variante; el detalle se retoma en §3.1
y §7.3. El clickstream en particular es también un dato sensible (revela intereses y hábitos de
lectura) y uno de los que necesitan trazabilidad junto con la auditoría: qué cambió, quién lo
cambió y cuándo, de forma que ese registro no se pueda alterar después de escrito, y, en la carga
de datos, cuántas filas entraron y cuántas se rechazaron, con el motivo, para que una pérdida no
pase inadvertida. El mecanismo concreto se explica en §8.1 y §13.6.

**Datos no estructurados.** El cuerpo del contenido en bloques heterogéneos, las transcripciones
de video y podcast, los comentarios con sus respuestas y la representación vectorial del
contenido caen en este grupo: texto largo de estructura libre en los primeros tres casos, y una
lista fija de 384 números en el último. Esa "representación vectorial" (o **embedding**) resume
el significado de un contenido de forma tal que dos contenidos con temas parecidos tengan listas
de números cercanas entre sí, lo que permite buscar "contenido similar" sin que dos piezas
compartan ni una palabra en común. Necesita comparación numérica de cercanía entre listas, algo
que una tabla relacional convencional no resuelve con una consulta simple; se retoma en detalle
en §11.

Además de la forma, hay dos datos que se leen por lotes con tolerancia a la demora en vez de
consultarse de forma inmediata: los agregados históricos (cuántos clics tuvo cada estrategia, qué contenido
es tendencia) y las etapas intermedias necesarias para producirlos. Se leen por rangos amplios de
tiempo, se escriben por lote y toleran estar minutos desactualizados, porque nadie necesita que un
tablero de CTR refleje el segundo exacto. Cómo se organiza esa canalización de datos crudo, limpio
y agregado es una decisión de arquitectura, no del relevamiento; se explica en §12.2. El
identificador de usuario y la dirección IP son sensibles por la misma razón que el correo: no
deberían viajar fuera de donde son estrictamente necesarios (el identificador, hacia el análisis
agregado; la IP, fuera del registro de seguridad) porque ahí ya no hace falta saber *quién* es
cada fila.

La siguiente tabla resume el relevamiento completo: la forma de cada dato, si se consulta de
forma inmediata o por lotes, y si es sensible.

| Dato | Forma | Patrón de uso | Sensible |
|---|---|---|---|
| Usuarios, roles, planes, suscripciones, consentimientos, preferencias | Fija | Inmediata | Correo y año de nacimiento sí |
| Contenidos, secciones, etiquetas, versiones, moderaciones | Fija | Inmediata | No |
| Estrategias, experimentos A/B, asignaciones, impresiones | Fija | Inmediata | No |
| Metadatos por tipo de contenido | Variable | Inmediata | No |
| Diff de cada versión editorial | Variable | Inmediata | No |
| Estado anterior y nuevo en la auditoría | Variable | Por lotes; requiere trazabilidad | No |
| Eventos del clickstream | Variable | Inmediata (escritura); por lotes (lectura agregada) | Sí, revela hábitos de lectura |
| Filtros del buscador | Variable | Inmediata | No |
| Cuerpo, transcripciones, comentarios | No estructurada | Inmediata | No |
| Representación vectorial del contenido | No estructurada (vector de 384 números) | Inmediata | No |
| Agregados históricos (CTR, tendencia) | Fija (ya agregada) | Por lotes | No |
| Identificador de usuario | Fija | Inmediata | Sí, no debe salir del ámbito operacional |
| Dirección IP | Fija | Inmediata, solo en registro de seguridad | Sí, dato de localización/red |

### 2.2 Datos de ejemplo

Se va a incluir una muestra versionada de cada estructura, legible sin levantar el entorno, y un
dataset completo generado con un generador determinista (misma semilla, mismos archivos siempre),
a una escala pensada para que el pipeline completo corra y se verifique en minutos, no para
representar el tráfico de un medio en producción.

El diseño de varios motores especializados que se justifica en §3 se piensa para el volumen
proyectado a un año de operación real (§14.1: cientos de millones de impresiones), varios
órdenes de magnitud mayor que
lo que va a generar cualquier corrida de prueba: la muestra sirve para demostrar y verificar la
arquitectura, no para dimensionarla.

El generador va a incorporar deliberadamente casos que ejerciten el diseño: popularidad con ley
de potencia, afinidad por sección, sesgo horario, cold start de usuarios y contenidos, usuarios
sin actividad y contenidos nunca recomendados, y defectos inyectados para ejercitar la capa de
calidad del pipeline analítico.

> **Pendiente.** Esta sección se completa con los volúmenes reales (usuarios, contenidos, eventos,
> embeddings, aristas del grafo, etc.) una vez que el generador de datos y el pipeline estén
> implementados y haya corrido al menos una vez de punta a punta. Hasta entonces, cualquier número
> concreto acá sería una expectativa, no un dato verificado.

---

## 3. Justificación de la selección tecnológica

§2 mostró qué datos hay y qué exige cada uno — forma fija o variable, integridad referencial,
volumen y velocidad de escritura, tolerancia a la demora, sensibilidad. Esta sección explica qué
motor responde a cada una de esas exigencias, por qué hacen falta varios y no uno solo, y bajo qué
criterio se eligió cada uno.

### 3.1 Por qué no alcanza con una sola base de datos

Las necesidades relevadas en §2 no son variaciones del mismo problema: son preguntas de naturaleza
distinta. Quién es un usuario y qué puede ver es una pregunta de filas y columnas exactas, que no
tolera ambigüedad. Qué hizo cada usuario llega a un ritmo de decenas de miles de eventos por hora
y con forma variable según el tipo de evento. Qué contenido se parece a otro sin compartir
etiquetas ni sección es una pregunta de cercanía semántica, no de coincidencia exacta. Qué
usuarios consumieron cosas parecidas a las de otro es una pregunta de recorrido sobre relaciones,
no de columnas. Y qué mostrar en la portada tiene que responderse en milisegundos, aceptando que
la respuesta tenga minutos de atraso.

Cada una de esas preguntas tiene una forma de dato y un patrón de acceso distintos. Elegir con qué
resolverlas no depende solo de esa forma, sino del volumen de datos y de eventos que se espera
manejar: a poca escala, un único motor bien usado alcanza para todas; a medida que ese volumen
crece, cada pregunta empieza a pedir un motor especializado, porque el costo de resolverlas todas
en el mismo lugar deja de ser parejo. La alternativa más seria que se evaluó y se descartó es
**hacer todo en un solo motor relacional**: es viable y sería lo correcto a escala chica. Este
proyecto optó por diseñar pensando en la escalabilidad del sistema en producción y no en los
valores del dataset de prueba, por lo que se decidió distribuir el trabajo entre varios motores
especializados desde el diseño, en vez de partir de uno solo y migrar más adelante.

### 3.2 Criterios y resultado

| Motor | Tipo de dato | Volumen esperado | Patrón de consulta | Consistencia | Por qué gana |
|---|---|---|---|---|---|
| **PostgreSQL + pgvector** | Estructurado + JSONB + vectores | 10⁴–10⁶ filas por tabla; 10⁵ vectores | Punto y rango, con `JOIN` y filtros compuestos | **Fuerte (ACID)** | Único con integridad referencial, RLS y búsqueda vectorial en la misma transacción |
| **MongoDB** | Semiestructurado | 10⁶–10⁹ documentos | Append masivo; lectura por usuario o contenido | Eventual | Esquema variable por tipo de evento; TTL y sharding nativos |
| **Redis** | Rankings y features | 10⁴–10⁶ claves | Lectura por clave, sub-milisegundo | Ninguna (es cache) | Estructuras que resuelven ranking y deduplicación sin cómputo |
| **Neo4j** | Relaciones | 10⁵ nodos, 10⁶ aristas | Recorridos de 2–3 saltos | Eventual | Costo constante por salto y devuelve el camino, que es la explicación |
| **DuckDB + MinIO** | Columnar analítico | 10⁶–10⁸ filas | Agregaciones sobre rangos amplios | Por lote | OLAP embebido sobre Parquet; la extensión `postgres` carga Gold sin ETL externo |

`pgvector` agrega a PostgreSQL soporte de tipo `VECTOR` y dos algoritmos de indexación para
buscar por similitud sin recorrer toda la tabla: **HNSW** e **IVFFlat**. Los dos aproximan la
búsqueda del vecino más cercano (a cambio de velocidad, no garantizan encontrar exactamente los
`k` más cercanos); la comparación entre ambos se retoma en §14.4 y §10.

### 3.3 Alternativas evaluadas y descartadas

| Alternativa | Por qué no |
|---|---|
| **Todo en un solo motor relacional** | Desarrollado en §3.1: es la alternativa más seria y viable a escala chica, pero el proyecto se diseñó para el volumen proyectado a producción, no para el del dataset de prueba |
| **Base vectorial dedicada** (Chroma, Pinecone, Weaviate) | Rompe el prefiltrado por metadatos, obliga a sincronizar dos sistemas y saca los vectores del alcance del RLS. pgvector alcanza hasta ~10⁷ vectores |
| **Cassandra** (columnar distribuida) | Diseñada para escritura distribuida a escala de decenas de terabytes. El volumen no la justifica y su modelo de consulta obligaría a una tabla por patrón de acceso |
| **Elasticsearch** | `tsvector` + pgvector cubren búsqueda literal y semántica sin un motor más |
| **Data Warehouse gestionado** (BigQuery, Snowflake) | Buen encaje funcional, descartado por costo y por el requisito de que todo levante con Docker en una máquina |
| **Kafka** en lugar de Redis Streams | Correcto a escala real; para este volumen agrega tres servicios (broker, ZooKeeper/KRaft, schema registry) sin beneficio |

### 3.4 El costo de usar varios motores especializados

Usar un motor distinto por tipo de pregunta no es gratuito. Se declara explícitamente qué se paga:

- **Consistencia eventual** entre motores. El grafo y Redis reflejan el estado de la última
  corrida del pipeline, no el instante.
- **Complejidad operativa:** seis sistemas para monitorear, respaldar y actualizar.
- **Costo de integración:** las uniones entre motores las resuelve la aplicación, no un `JOIN`.
- **Curva de aprendizaje:** el equipo necesita SQL, agregaciones de MongoDB, Cypher y las
  particularidades de Redis.

La contrapartida es que cada consulta corre en el motor que la resuelve bien. El umbral de
decisión es concreto: **por debajo de ~10⁵ eventos diarios, PostgreSQL solo sería la elección
correcta.** El dataset de ejemplo (§2.2: 113.341 eventos en total, no por día) está deliberadamente
por debajo de ese umbral porque su función es verificar la arquitectura, no justificar su
necesidad; el diseño apunta al escenario donde el tráfico real ya superó ese umbral, que es el que
se proyecta en §14.1.

### 3.5 Decisiones de diseño que resultaron determinantes

Como síntesis de esta sección, cinco decisiones atraviesan el resto del documento:

1. **Separar lo que se filtra de lo que se lee.** PostgreSQL guarda lo que participa del filtrado,
   el orden y el control de acceso; el texto largo vive en MongoDB.
2. **Prefiltrar, nunca posfiltrar,** en la búsqueda vectorial.
3. **Redis no guarda nada que no se pueda reconstruir,** lo que permite renunciar a durabilidad
   y transacciones.
4. **El grafo es una proyección regenerable,** lo que autoriza a desnormalizar sin costo de
   consistencia.
5. **Ningún identificador directo de persona sale hacia el lakehouse.**

---

## 4. Modelo conceptual

Con las necesidades ya relevadas (§2) y el criterio tecnológico ya definido (§3), esta sección
ordena esas necesidades en un **modelo conceptual**: qué entidades existen en el dominio del
problema, qué atributos tiene cada una y cómo se relacionan entre sí, todavía sin decidir en qué
motor se van a guardar ni cómo se van a representar en tablas o documentos concretos. Esa decisión
de implementación llega recién en el modelo lógico (§5) y en el modelo por tecnología (§6). Ver
`docs/diagramas/modelo_conceptual.mmd`.

### 4.1 Entidades principales

| Entidad | Atributos relevantes | Restricciones del dominio |
|---|---|---|
| **Usuario** | correo, alias, país, año de nacimiento, consentimiento | Correo único; consentimiento explícito para personalizar |
| **Plan** | código, nivel de acceso (0–2) | El nivel ordena: 2 incluye a 1, que incluye a 0 |
| **Suscripción** | desde, hasta, estado | Una sola activa por usuario a la vez |
| **Sección** | nombre, sección padre | Jerarquía de hasta 3 niveles; sin ciclos |
| **Contenido** | título, estado, nivel de acceso, publicación, vigencia, metadatos | Publicado ⇒ tiene fecha; vigencia posterior a publicación |
| **Etiqueta** | nombre, relevancia en la relación | — |
| **Versión** | número, editor, diff | Número único por contenido |
| **Moderación** | objeto, acción, motivo | Sobre contenido o comentario |
| **Estrategia** | código, versión, motor | Código+versión único; nunca se pisa una versión |
| **Impresión** | posición, score, clic, superficie | Clic ⇒ tiene fecha de clic, posterior a la impresión |
| **Preferencia** | tipo (sigue / no interesa), peso | Apunta a una sección **o** a una etiqueta, nunca a ambas |

### 4.2 Relaciones y cardinalidades

La **cardinalidad** indica cuántas instancias de una entidad pueden asociarse con cuántas
instancias de otra. **1:N** ("uno a muchos") significa que una instancia de la primera entidad
puede tener varias de la segunda, pero cada una de la segunda pertenece a una sola de la primera:
`Usuario 1:N Suscripcion` quiere decir que un usuario puede tener muchas suscripciones a lo largo
del tiempo, pero cada suscripción es de un único usuario. **N:M** ("muchos a muchos") significa
que instancias de ambas entidades pueden asociarse libremente entre sí: `Contenido N:M Etiqueta`
quiere decir que un contenido puede tener varias etiquetas y una etiqueta puede estar en varios
contenidos. **1:1** ("uno a uno") significa que cada instancia de una entidad se asocia con, como
máximo, una sola de la otra.

```
Usuario        1:N  Suscripcion          Usuario     N:M  Rol
Usuario        1:N  Preferencia          Plan        1:N  Suscripcion
Usuario        1:N  Contenido (autor)    Seccion     1:N  Seccion (jerarquía)
Seccion        1:N  Contenido            Contenido   N:M  Etiqueta
Contenido      1:N  Version              Contenido   1:N  Moderacion
Contenido      1:1  Embedding            Usuario     1:1  PerfilVectorial
Usuario        1:N  Impresion            Contenido   1:N  Impresion
Estrategia     1:N  Impresion            Contenido   N:M  Contenido (similitud)
Usuario        1:N  Evento               Contenido   1:N  Evento
Contenido      1:1  CuerpoContenido      Contenido   1:N  Comentario
```

---

## 5. Modelo lógico relacional

El modelo conceptual (§4) definió qué entidades existen y cómo se relacionan, sin comprometerse
con ninguna tecnología. Esta sección da el siguiente paso solo para la parte que se implementa en
PostgreSQL: convierte esas entidades en tablas concretas, con columnas tipadas, claves y
restricciones, organizadas en **schemas** (agrupaciones de tablas dentro de la misma base, que en
PostgreSQL sirven además como unidad de permisos). Cómo se reparte el resto del modelo entre los
demás motores se ve en §6. Ver `docs/diagramas/modelo_logico.mmd` y `db/estructura/`.

### 5.1 Organización en schemas

| Schema | Contenido | Permisos |
|---|---|---|
| `personas` | Identidad, roles, planes, suscripciones, preferencias, consentimientos | Restringido; RLS |
| `catalogo` | Contenidos, taxonomía, versiones, moderación | Lectura amplia; RLS sobre contenidos |
| `recomendacion` | Estrategias, embeddings, perfiles, impresiones, rankings | RLS sobre impresiones |
| `analitica` | Capa Gold (dimensiones, hechos, agregados) | Solo lectura para el analista |
| `auditoria` | Traza append-only | Solo el administrador puede leerla; nadie puede modificarla |
| `control` | Control de cargas del pipeline | Solo lectura |

Separar por schema no es cosmético: cada uno recibe un conjunto distinto de permisos (`GRANT`,
la instrucción de PostgreSQL que habilita a un rol a operar sobre un objeto concreto).

### 5.2 Claves y restricciones

- **Primarias:** la **clave primaria** (o **PK**, *primary key*) es la columna, o combinación de
  columnas, que identifica una fila de forma única dentro de la tabla. Acá se genera con `SERIAL`
  para catálogos chicos y `BIGSERIAL` para tablas de volumen (ambos son enteros autoincrementales;
  el segundo admite un rango mayor), y es compuesta en las **tablas puente** (tablas que existen
  solo para conectar dos entidades entre sí en una relación de muchos a muchos, ver §5.3). En
  `recomendacion.impresiones` la PK es `(id, mostrado_en)` porque PostgreSQL exige que la columna
  de particionado forme parte de toda restricción única.
- **Foráneas:** todas explícitas, **sin `ON DELETE CASCADE`**. Borrar un usuario con historial
  debe fallar, no propagarse en silencio.
- **`CHECK` que codifican reglas del dominio:** estados válidos, niveles de acceso 0–2, un
  contenido publicado tiene fecha, un clic tiene fecha de clic, una preferencia apunta a sección
  *o* a etiqueta (`(seccion_id IS NULL) <> (etiqueta_id IS NULL)`). Un `CHECK` evalúa cada fila de
  forma aislada, sin ver las demás filas de la tabla.
- **Índice único parcial** `WHERE estado = 'activa'` para garantizar una sola suscripción activa
  por usuario: es una regla que compara una fila contra las demás, y por eso un `CHECK` (que solo
  ve la fila propia) no puede expresarla.

### 5.3 Relaciones muchos a muchos

Se modelan como tablas puente `usuarios_roles`, `contenidos_etiquetas` (con atributo `relevancia`
en la relación), `asignaciones_ab` y `ranking_items_similares` (con `origen` en la clave, lo que
permite que las tres estrategias de vecinos convivan en la misma tabla).

`contenidos_etiquetas` en particular se modela así y no como array de texto: el array ahorra un
`JOIN` pero pierde la integridad referencial y hace imposible renombrar una etiqueta en un solo
lugar.

---

## 6. Modelo de implementación por tecnología

Con la elección de motores ya justificada (§3), esta sección resume qué estructura concreta tiene
cada uno. Además del relacional, la solución define un modelo por cada paradigma:

- **Documental, clave-valor y grafo:** `nosql/modelo_nosql.md`
- **Vectorial:** `vectorial/modelo_vectorial.md`
- **Dimensional (Gold):** `db/estructura/05_analitica_y_control.sql`

Se resumen aquí las decisiones y el detalle está en esos documentos.

| Paradigma | Motor | Estructuras | Decisión central |
|---|---|---|---|
| Relacional | PostgreSQL | 6 schemas, 31 tablas (+6 particiones) | Todo lo que necesita integridad y control de acceso |
| Documental | MongoDB | 5 colecciones, 1 timeseries | Embebido cuando se lee junto, referencia a PostgreSQL siempre |
| Clave-valor | Redis | ZSET, SET, HASH, STRING, STREAM | Nada que no se pueda reconstruir |
| Grafo | Neo4j | 4 tipos de nodo, 8 de relación | Proyección regenerable; se desnormaliza sin costo |
| Vectorial | pgvector | `VECTOR(384)`, HNSW + IVFFlat | En la misma base que el catálogo, para poder prefiltrar |
| Columnar analítico | DuckDB + Parquet | Medallion Bronze/Silver/Gold | Separa OLAP de OLTP sin infraestructura adicional |

---

## 7. Normalización, desnormalización y decisiones de diseño

### 7.1 Dónde se normaliza y por qué

**Normalizar** es organizar los datos en tablas de forma que cada hecho se guarde en un solo
lugar, sin repetirlo en varias filas. La ventaja es que evita las **anomalías** que aparecen
cuando un mismo dato está duplicado: si el nombre de una sección vive escrito en cada contenido
que pertenece a ella, cambiarlo obliga a actualizar todas esas filas a la vez (y alguna puede
quedar afuera), insertar un contenido sin sección clara se vuelve ambiguo, y borrar el último
contenido de una sección puede borrar, de hecho, la sección entera. La desventaja es que los datos
quedan repartidos en más tablas, así que reconstruir la información completa exige más `JOIN`. El
núcleo transaccional de este proyecto está en **tercera forma normal** (cada columna depende de la
clave primaria completa, y solo de ella; nada depende de otra columna que no sea la clave), que es
el nivel de normalización habitual para datos operacionales. Los casos concretos:

| Decisión | Anomalía que evita |
|---|---|
| `tipos_contenido` como catálogo, no como texto en `contenidos` | Actualización: renombrar "Galería de fotos" tocaría miles de filas y podrían quedar variantes |
| `planes` como catálogo con `nivel_acceso` | Inconsistencia: dos filas con el mismo plan y distinto nivel |
| `secciones` autoreferenciada en vez de columnas `nivel_1`, `nivel_2`, `nivel_3` | Inserción: no se podría agregar un cuarto nivel sin migrar el esquema |
| `contenidos_etiquetas` como tabla puente | Repetición y pérdida de integridad de las etiquetas |
| `suscripciones` como histórico en vez de columna `plan_id` en `usuarios` | Eliminación: cambiar de plan borraría el historial y con él la posibilidad de analizar conversión |

### 7.2 Dónde se desnormaliza, y qué se paga

Estas desnormalizaciones usan estructuras (Neo4j, Redis, vistas materializadas) que ya se
justificaron en §3 y se detallan en §6 y §12:

| Desnormalización | Motivo | Costo aceptado |
|---|---|---|
| `analitica.dim_contenido` guarda sección y sección raíz | Evita un `WITH RECURSIVE` en cada consulta analítica | Redundancia; nula en efecto porque la Gold se recarga entera |
| Nodos `:Contenido` de Neo4j replican título, estado y nivel de acceso | Sin ellos, cada recorrido volvería a PostgreSQL | El grafo puede quedar desactualizado entre corridas; la API revalida contra PostgreSQL |
| `contenido:<id>:meta` en Redis | Evita golpear PostgreSQL al renderizar | Cache con TTL; se acepta desactualización de minutos |
| `ranking_items_similares` precalculado | Convierte una búsqueda vectorial por tarjeta en una lectura por clave | Frescura de la última corrida del pipeline |
| `mv_trending_seccion` materializada | La consulta agrega cientos de miles de filas | Frescura del último `REFRESH` |

El criterio, en una línea: **se desnormaliza lo que se puede regenerar, nunca lo que es fuente de
verdad.**

### 7.3 Uso de JSONB

`JSONB` es el tipo de columna de PostgreSQL que guarda un documento JSON completo (claves y
valores anidados, de forma variable) dentro de una sola celda, con la posibilidad de indexar y
consultar su contenido interno. Es la vía que tiene una tabla relacional para absorber un dato de
forma variable sin salir del motor. La columna `metadatos` absorbe los atributos que dependen del
tipo de contenido: `resolucion` solo existe en
videos, `cantidad_fotos` solo en galerías, `envio` solo en newsletters. Como columnas serían tres
columnas con 80% de `NULL`; como tablas por tipo, cinco tablas casi idénticas. Es el mismo
problema que se describe para el clickstream completo en §3.1, aplicado acá a un solo campo en
lugar de a una colección entera.

Se indexan de dos formas porque responden preguntas distintas. **GIN** (*Generalized Inverted
Index*) es el tipo de índice de PostgreSQL pensado para columnas donde cada fila puede tener
varios valores indexables a la vez, como las claves de un JSONB o las palabras de un texto: acá se
usa `jsonb_path_ops` para el operador de contención `@>` (más chico y más rápido) y GIN por
defecto para el operador de existencia `?`.

**Lo que NO va en JSONB:** nada que se use para filtrar en el camino caliente ni que requiera
integridad referencial. `estado`, `nivel_acceso` y `seccion_id` son columnas, no claves de un JSON.
