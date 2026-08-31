# Informe técnico

## Trabajo Práctico Integrador — Bases de Datos para Inteligencia Artificial

**Carrera de Especialización en Inteligencia Artificial — FIUBA**
**Docente:** Esp. Lic. Martín Aníbal Lacheski
**Caso de uso:** 10 — Sistema de recomendación de contenidos
**Impronta del grupo:** *NexoMedia*, medio digital multiformato

**Integrantes**

| Integrante | Usuario de GitHub | Aportes principales |
|---|---|---|
| Federica Pavese | `federica-pavese` | Índices, vistas y vista materializada del modelo relacional. Roles, permisos, RLS, auditoría y seudonimización en PostgreSQL. |
| Leandro Saraco | `lsaraco` | *(completar)* |
| Maximiliano Lulic | `maxisoadgh` | *(completar)* |
| Pablo Salvagni | `PabloSalvagni` | Conciliación de calidad Silver/Gold, capa de serving en Redis y orquestación del pipeline. Consumidor del stream de ingesta y consultas SQL representativas. |
| Rodrigo Parra | `Ronapa` | *(completar)* |

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

> **Estado verificado.** Los volúmenes reproducibles de la escala media se detallan en §2.3 y §9.
> El pipeline completo ya genera, carga y concilia las capas operacionales, vectoriales,
> documentales, analíticas y de serving.

### 2.3 Implementación y verificación del bloque de datos

La previsión anterior se materializó con `orquestador/generar_datos.py`, un generador
determinístico: la misma semilla produce los mismos archivos byte a byte. Admite las escalas
`chica`, `media` y `grande`, y guarda por separado los CSV que consume PostgreSQL, los JSON que
usará el bloque documental y un `resumen.json` con los conteos de la corrida.

La escala media con semilla 42 se ejecutó y verificó con estos volúmenes:

| Estructura | Volumen |
|---|---:|
| Usuarios | 2.000 |
| Contenidos | 3.000 (2.161 publicados) |
| Secciones / etiquetas | 32 / 155 |
| Impresiones en PostgreSQL | 92.334 |
| Eventos de clickstream preparados para MongoDB | 113.341 |
| Telemetría de reproducción | 30.000 mediciones |
| Cuerpos / comentarios / búsquedas | 3.000 / 2.301 / 5.000 |
| Eventos de auditoría producidos durante la carga | 9.591 |

El generador incluye popularidad con ley de potencias, afinidad por sección, sesgo horario,
`cold start`, usuarios sin actividad y contenidos nunca recomendados. Esos casos evitan un
dataset uniforme que haría indistinguibles las estrategias y además ejercitan los `LEFT JOIN`
del modelo.

Los catálogos estables se cargan antes del dataset: tres planes, cinco tipos de contenido, cinco
estrategias y un experimento A/B. Después `orquestador/cargar_postgres.py` ejecuta la carga
transaccionalmente: usa `COPY` para las tablas de volumen, pero inserta los usuarios aplicando
`HMAC-SHA256`, `pgp_sym_encrypt` y la función de seudonimización. Al terminar sincroniza las
secuencias, refresca la vista de tendencias, ejecuta `ANALYZE` y registra catorce entidades en
`control.control_cargas`.

La verificación compara los conteos reales con ese registro de control y aborta ante filas
perdidas, clics sin fecha, suscripciones inconsistentes, contenidos fuera del árbol o perfiles
sin consentimiento. La corrida media se cargó dos veces con reset y ambas finalizaron con las
92.334 impresiones repartidas entre abril y julio de 2026, sin filas en la partición `DEFAULT`.

Los archivos JSON ya se generan para conservar identificadores estables entre motores, pero en
este bloque no se crean colecciones ni se carga MongoDB; esa implementación queda para el bloque
NoSQL.

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
correcta.** El dataset de ejemplo (§2.2) está deliberadamente por debajo de ese umbral, y además
concentra en una sola corrida un volumen que en producción correspondería a varios días: su función
es verificar la arquitectura, no justificar su necesidad. El diseño apunta al escenario donde el
tráfico real ya superó ese umbral, que es el que se proyecta en §14.1.

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

### 5.4 Índices, vistas y estructuras de optimización

El modelo lógico se completa con estructuras que responden a los patrones de consulta esperados.
No se crean índices de forma indiscriminada: cada índice agrega costo de almacenamiento y de
escritura, por lo que debe estar asociado a una consulta o restricción concreta. La implementación
se encuentra en `db/indices_vistas/`.

`01_indices.sql` agrega índices sobre el lado dependiente de las claves foráneas, que PostgreSQL
no crea automáticamente, y estructuras específicas para los caminos de mayor uso:

- índices parciales y compuestos para recuperar contenido publicado por fecha, sección y nivel de
  acceso;
- un índice único parcial que garantiza una sola suscripción activa por usuario;
- índices GIN sobre `JSONB` para consultas por contención y existencia de claves;
- un índice GIN sobre `tsvector` para búsqueda literal en español;
- índices por usuario, estrategia, contenido y fecha sobre la tabla particionada de impresiones;
- un índice BRIN sobre `mostrado_en`, adecuado porque las impresiones se insertan en orden
  cronológico;
- un índice parcial sobre las impresiones que terminaron en clic;
- índices para recorridos de auditoría y consultas de la capa analítica.

`02_vistas.sql` centraliza reglas que, si se repitieran en cada consulta, podrían implementarse de
forma diferente o incompleta:

| Vista | Responsabilidad |
|---|---|
| `catalogo.vw_contenidos_publicables` | Expone únicamente contenido publicado y dentro de su ventana de vigencia |
| `catalogo.vw_arbol_secciones` | Aplana la jerarquía de secciones e informa raíz, profundidad y camino |
| `recomendacion.vw_rendimiento_estrategias` | Calcula impresiones, clics, CTR, cobertura y usuarios alcanzados |
| `recomendacion.vw_vetos_usuario` | Reúne los contenidos excluidos por preferencias de tipo `no_interesa` |

Estas vistas usan `security_invoker = TRUE`: se evalúan con los permisos de quien consulta y no
con los del usuario que las creó. Esto evita que una vista creada por el dueño de la base se
convierta en una vía para eludir las políticas de Row Level Security.

Finalmente, `03_vistas_materializadas.sql` precalcula
`recomendacion.mv_trending_seccion`. La consulta agrega impresiones recientes, aplica decaimiento
temporal a los clics y ordena los contenidos dentro de cada sección. Se materializa porque es una
consulta frecuente y costosa cuyo resultado tolera algunos minutos de desactualización.

La vista tiene un índice único por sección y contenido, necesario para ejecutar
`REFRESH MATERIALIZED VIEW CONCURRENTLY` sin bloquear las lecturas. La función
`recomendacion.refrescar_trending()` intenta ese refresco concurrente y recurre al refresco común
durante la primera carga. Para que el dataset sintético siga siendo reproducible, la ventana
temporal se ancla al último evento cargado y no al reloj actual.

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

---

## 8. Implementación mínima realizada

Todo el proyecto levanta con Docker Compose y se reconstruye con un comando.

| Componente | Estado | Archivos |
|---|---|---|
| PostgreSQL: 6 schemas, 38 tablas físicas (6 particiones), 29 índices operacionales, 4 vistas | Implementado | `db/estructura/`, `db/indices_vistas/` |
| Seguridad: 6 roles, RLS, auditoría, vistas anonimizadas | Implementado | `db/seguridad/` |
| Generador de datos determinista | Implementado | `orquestador/generar_datos.py` |
| MongoDB: 5 colecciones, validadores, timeseries, 12 índices | Implementado | `nosql/mongodb/` |
| Vectorial: embeddings, HNSW, IVFFlat, vecinos precalculados | Implementado | `vectorial/`, `orquestador/generar_embeddings.py` |
| Neo4j: 5.187 nodos, 97.883 aristas, restricciones e índices | Implementado | `nosql/neo4j/`, `orquestador/cargar_neo4j.py` |
| Lakehouse: Medallion completo con calidad y linaje | Implementado | `analitico/`, `orquestador/exportar_bronze.py` |
| Redis: 7 estructuras, feeds precalculados, ACL | Implementado | `orquestador/publicar_serving.py` |
| API de recomendación (demostración) | Implementado | `orquestador/recomendador_api.py` |

### 8.1 Verificaciones que abortan el pipeline

Todo paso que puede perder datos tiene un control que **falla ruidosamente**:

| Control | Dónde | Qué detecta |
|---|---|---|
| Conteos contra `control.control_cargas` | `db/consultas/00_verificar_carga.sql` | Filas perdidas en la carga |
| Integridad entre tablas | Ídem | Publicados sin fecha, suscripciones duplicadas, filas en la partición DEFAULT |
| Gobierno de datos | Ídem | Perfiles vectoriales de usuarios sin consentimiento |
| Conteos y referencias | `nosql/mongodb/00_cargar_datos.js` | Comentarios huérfanos |
| Balance de calidad | `analitico/02_procesar_silver.sql` | `aceptadas + rechazadas ≠ recibidas` |
| Conciliación Silver ↔ Gold | `analitico/05_verificar_calidad.sql` | Divergencia entre capas |
| Un solo modelo y dimensión | `vectorial/01_crear_indices_vectoriales.sql` | Embeddings mezclados |
| kNN completo | Ídem | Menos de 9 vecinos por contenido |

### 8.2 Tres defectos que estos controles encontraron durante el desarrollo

Se documentan porque ilustran por qué los controles son parte del diseño y no un adorno:

1. **kNN silenciosamente incompleto.** El cálculo por lote devolvía 1 o 2 vecinos donde se pedían
   10: PostgreSQL elegía el índice IVFFlat y, con `ivfflat.probes = 1`, escaneaba el 2% del
   catálogo. La consulta no fallaba. Se resolvió apagando los índices en el cálculo por lote
   (exactitud) y dejándolos para las consultas en línea (latencia).
2. **Filas perdidas en la capa Gold.** Un `HAVING` descartaba 6 grupos que violaban el `CHECK`
   `vistas_completas <= vistas`. Lo detectó la conciliación Silver/Gold. La causa real era una
   definición equivocada: un evento `completado` **es** una vista.
3. **Gold construida sobre Bronze de otra corrida.** Bronze es inmutable, así que al regenerar el
   dataset a otra escala el lake conservó los archivos viejos. Se resolvió con un manifiesto por
   lote: la inmutabilidad ahora es *dentro de una versión del dataset*.

Y los dos de seguridad, que no aparecieron probando la aplicación sino preguntándole al motor qué
podía hacer cada rol:

4. **La API ignoraba el RLS.** Se conectaba con el dueño de la base. `/trending` devolvía títulos
   de contenido premium a un visitante anónimo, y nada fallaba.
5. **El rol de la API podía leer los 1.451 perfiles vectoriales.** Los endpoints filtraban, así que
   desde afuera no se notaba. Se encontró revisando los `GRANT`, no las respuestas.

La lección práctica: **probar la aplicación no alcanza para auditar los permisos.** Hay que
sentarse en la sesión de cada rol y preguntarle a la base qué le deja hacer.

---

## 9. Datos de ejemplo utilizados

Ver §2.2. Muestra versionada en `data/ejemplos/`.

**Defectos inyectados en el lote reciente de Bronze,** uno por código de error, para que la capa
Silver tenga algo real que atrapar:

| Defecto | Código resultante |
|---|---|
| Seudónimo inexistente | `USUARIO_DESCONOCIDO` |
| Fecha `31/02/2026` | `FECHA_INVALIDA` |
| `evento_id` repetido | `DUPLICADO` |
| `porcentaje_scroll = 150` | `FUERA_DE_RANGO` |
| `tipo_evento = "pestaneo"` | `TIPO_EVENTO_DESCONOCIDO` |
| Sin `contenido_id` | `FALTA_OBLIGATORIO` |
| Coma decimal (`45,5`) y fecha con barras | *Normalizado, no rechazado* |
| Espacios y mayúsculas (`"  MOVIL  "`) | *Normalizado, no rechazado* |

Los dos últimos son deliberados: marcan la diferencia entre **dato inválido** (se rechaza) y
**dato mal escrito** (se normaliza). Confundirlos hace que un pipeline descarte datos buenos o
acepte datos rotos.

---

## 10. Consultas representativas

La consigna pide un mínimo de 5. El proyecto entrega **102 consultas representativas**, cada una
con la pregunta de negocio que responde escrita arriba, más **32 bloques de prueba de seguridad**
que se cuentan aparte porque su resultado esperado es un error.

### Tabla canónica

Es la única fuente del conteo: el README y la conclusión la referencian en lugar de repetir un
número.

| Motor | Archivo | Consultas | Técnicas principales |
|---|---|---|---|
| PostgreSQL | `db/consultas/01_feed_personalizado.sql` | 1 | CTE, `NOT EXISTS`, `ROW_NUMBER()`, índice parcial |
| PostgreSQL | `db/consultas/02_rendimiento_estrategias.sql` | 5 | `HAVING`, `AVG() OVER ()`, `RANK()`, `LAG()`, experimento A/B |
| PostgreSQL | `db/consultas/03_catalogo_y_jerarquia.sql` | 6 | `WITH RECURSIVE`, N:M, `JSONB` con `@>` y `?` |
| PostgreSQL | `db/consultas/04_cobertura_y_sesgo.sql` | 5 | `NOT EXISTS`, `NTILE`, diversidad, long tail |
| pgvector | `vectorial/consultas/01_similitud.sql` | 5 | `<=>` con prefiltrado, diversificación, duplicados |
| pgvector | `vectorial/consultas/02_explain_indices.sql` | 6 | `EXPLAIN`, HNSW vs. IVFFlat, `probes`, `ef_search` |
| pgvector | `vectorial/consultas/03_literal_vs_semantica.sql` | 5 | `tsvector` + GIN, solapamiento, *reciprocal rank fusion* |
| MongoDB | `nosql/mongodb/consultas/01_modelo_documental.md` | 5 | Esquema variable, notación de punto, `$lookup` de control |
| MongoDB | `nosql/mongodb/consultas/02_agregaciones_consumo.md` | 4 | `$group` doble, `$bucket`, `$facet`, timeseries |
| MongoDB | `nosql/mongodb/consultas/03_lookup_y_ventanas.md` | 4 | `$lookup`, `$unwind`, `$setWindowFields`, `$text` |
| MongoDB | `nosql/mongodb/consultas/04_indices_y_explain.md` | 10 | `explain("executionStats")`, índices parciales, validadores |
| Neo4j | `nosql/neo4j/consultas/01_covisualizacion.cypher` | 4 | Recorridos de 2 saltos, mezcla con similitud, cold start |
| Neo4j | `nosql/neo4j/consultas/02_explicabilidad_y_diversidad.cypher` | 5 | `shortestPath`, burbuja de filtro, contenidos puente |
| Redis | `nosql/redis/consultas/01_estructuras_de_serving.md` | 23 | ZSET, SET, HASH, STREAM, `ZUNIONSTORE`, ACL |
| DuckDB | `analitico/01_perfilar_bronze.sql` | 7 | Perfilado schema-on-read, deteccion de anomalias |
| DuckDB | `analitico/05_verificar_calidad.sql` | 7 | Conciliacion Silver ↔ Gold, CTR, cobertura, co-ocurrencia |
| **Total** | | **102** | |

No se cuentan como consultas los pasos de transformación de
`analitico/02_procesar_silver.sql`, `03_publicar_silver.sql` y `04_cargar_gold.sql`: son el
pipeline que construye las capas, no preguntas sobre los datos.

### Bloques de prueba de seguridad

Se cuentan aparte porque **su resultado esperado es un error**: comprueban barreras, no responden
preguntas de negocio.

| Archivo | Bloques | Qué demuestra |
|---|---|---|
| `db/consultas/05_prueba_aislamiento.sql` | 10 | RLS por rol de usuario final, permisos por columna |
| `db/consultas/06_prueba_aislamiento_api.sql` | 7 | El rol de la API está sujeto al mismo RLS |
| `nosql/mongodb/consultas/05_permisos.md` | 11 | Permisos por acción y colección; el límite del motor |
| `nosql/neo4j/consultas/03_limitaciones_community.cypher` | 4 | Community Edition no tiene control de acceso por roles |
| **Total** | **32** | |

---

## 11. Datos semiestructurados, no estructurados y búsqueda vectorial

Desarrollado en §2.1, `nosql/modelo_nosql.md` y `vectorial/modelo_vectorial.md`. Se resumen las
respuestas a las preguntas de la consigna:

**¿Qué datos podrían vectorizarse?** Título, bajada, sección y etiquetas de cada contenido; y el
perfil de cada usuario como centroide ponderado de lo consumido. **No** el cuerpo completo: el
caso de uso es recomendación, no recuperación de pasajes.

**¿Qué necesidad resuelve la búsqueda por similitud?** Encontrar contenido relacionado cuando no
comparte etiquetas ni sección, y resolver el feed personalizado con **una** búsqueda en lugar de
N. Además cubre el cold start del contenido: una nota publicada hace una hora tiene embedding
desde el primer minuto, mientras que el filtrado colaborativo necesita lectores.

**¿Qué metadatos acompañan a los vectores?** `modelo_embedding` (los espacios vectoriales de
modelos distintos no son comparables), `texto_fuente` (reproducibilidad y auditoría),
`indexado_en`, y la clave foránea al catálogo.

**¿Qué riesgos aparecen si se recupera información incorrecta o no autorizada?** Es el riesgo
central del caso. Un borrador, una nota despublicada o contenido premium recuperado por
similitud sería una fuga. Mitigación en cinco capas independientes, detalladas en §13.

---

## 12. Arquitectura de datos

Ver `docs/diagramas/arquitectura.mmd`.

### 12.1 Flujo

> El diagrama completo, en imagen: [`docs/diagramas/arquitectura.png`](diagramas/arquitectura.png).
> La fuente versionable es `arquitectura.mmd`, que GitHub y GitLab renderizan de forma nativa.

```
Aplicacion web/movil
   |
   +-- eventos ------> Redis STREAM (buffer) ----> MongoDB  [clickstream crudo]
   |                   consumir_stream.py drena y confirma con XACK
   |
   +-- escrituras ---> PostgreSQL  [catalogo, personas, permisos, impresiones]
                            |
      export por lote ------+---> MinIO  s3://lakehouse/bronze/lote=<n>/  (CSV, inmutable)
                                          |
                                DuckDB ---+---> silver/  (Parquet ZSTD, tipado, sesionizado,
                                          |               + rechazos con linaje)
                                          |
                                DuckDB ---+---> gold     (modelo dimensional)
                                          |
               +--------------------------+--------------------------+
               v                          v                          v
      PostgreSQL analitica.*      Redis (ZSET / HASH)        Neo4j (SIMILAR_A)
               |                          |                          |
               +------------+-------------+--------------------------+
                            v
                 API de recomendacion ---> registra impresiones ---> PostgreSQL
                            |                                            |
                            +--------- el circuito se cierra ------------+
```

### 12.2 Por qué una arquitectura por capas y no una simple

Una arquitectura simple —todo en PostgreSQL, consultas analíticas sobre las mismas tablas— sería
suficiente hasta cierta escala, y el informe lo reconoce (§3.1). Se elige la arquitectura por
capas por tres razones concretas:

1. **Aislamiento de cargas.** Una consulta analítica que barre 90 días de impresiones compite por
   caché y CPU con el feed. Separarlas es lo que impide que un tablero degrade el sitio.
2. **Trazabilidad.** Bronze inmutable permite reprocesar el pipeline entero cuando se descubre un
   error de transformación, sin haber perdido el dato original.
3. **Calidad explícita.** La capa Silver hace visible lo que se descartó y por qué. Sin ella, una
   carga que pierde el 5% de los eventos se ve igual que una correcta.

Es un **Lakehouse en versión mínima**: object storage con archivos abiertos (Parquet), motor de
consulta desacoplado (DuckDB) y estructura Medallion. **No es un Lakehouse completo:** no hay
formato transaccional de tabla (Delta, Iceberg), ni *time travel*, ni catálogo de metadatos, ni
control de concurrencia entre escritores. Se declara el alcance para no sobrevender la
arquitectura.

### 12.3 Componentes

| Capa | Componente | Responsabilidad |
|---|---|---|
| Ingesta | Redis Streams | Amortigua picos de escritura del clickstream |
| Operacional | PostgreSQL + pgvector | Fuente de verdad; ACID; RLS; búsqueda semántica |
| Operacional | MongoDB | Clickstream y contenido no estructurado |
| Lake | MinIO | Object storage S3 del Bronze y el Silver |
| Transformación | DuckDB | Bronze → Silver → Gold |
| Serving | Redis | Rankings, features y caché |
| Serving | Neo4j | Recorridos y explicabilidad |
| Consumo | FastAPI | Demostración de los patrones de acceso |

---

## 13. Estrategia de seguridad, permisos y aislamiento

La seguridad de PostgreSQL se construye en capas. Los permisos determinan qué objetos puede usar
cada rol; Row Level Security (RLS) decide qué filas le corresponden; la auditoría registra los
cambios; y la seudonimización permite analizar comportamiento sin entregar identificadores
directos. Ninguno de estos mecanismos alcanza por sí solo: se complementan para que un error de
la aplicación no se convierta automáticamente en una exposición de datos.

### 13.1 Roles y mínimo privilegio

`db/seguridad/01_roles_y_permisos.sql` traduce los usuarios del dominio a seis roles de base de
datos: lector, editor, moderador, analista, administrador y un rol técnico reservado para la API.
Ninguno es superusuario ni dueño de las tablas, porque esos privilegios permitirían omitir RLS y
volverían ficticia la demostración de aislamiento.

| Rol | Alcance principal |
|---|---|
| `bdia_lector` | Consulta el catálogo permitido y administra sus preferencias |
| `bdia_editor` | Hereda al lector y trabaja sobre sus propios contenidos |
| `bdia_moderador` | Revisa el catálogo completo y registra moderaciones |
| `bdia_analista` | Consulta la capa Gold y los datos seudonimizados |
| `bdia_admin` | Administra los datos y consulta la auditoría |
| `bdia_api` | Tiene solo las lecturas y escrituras necesarias para servir recomendaciones |

Los permisos se otorgan explícitamente sobre schemas, tablas, vistas, columnas y secuencias.
`USAGE` sobre un schema permite nombrar sus objetos, pero no leerlos: por eso cada acceso se
completa con el `GRANT` mínimo necesario. En particular, el analista no puede consultar la tabla
de usuarios y la API no recibe acceso a auditoría ni a los secretos de control.

### 13.2 Aislamiento por fila

La aplicación no necesita abrir una conexión distinta por cada lector. Usa un rol técnico y, al
comenzar la transacción, declara qué usuario está operando:

```sql
SELECT set_config('app.usuario_id', '123', TRUE);
```

El tercer argumento hace que la identidad dure solo durante esa transacción. Esto es importante
cuando se usa un pool: si el valor quedara asociado a la conexión, el siguiente pedido podría
heredar la identidad anterior. Las políticas recuperan el contexto mediante
`personas.usuario_actual()`; si no fue declarado, el acceso no se amplía.

`db/seguridad/02_row_level_security.sql` aplica RLS sobre cinco tablas:

| Tabla | Regla principal |
|---|---|
| `catalogo.contenidos` | El lector ve contenido publicado, vigente y permitido por su plan; el editor también ve lo propio y el moderador todo el catálogo |
| `personas.preferencias_usuario` | Cada usuario consulta y modifica únicamente sus preferencias |
| `recomendacion.impresiones` | Cada usuario consulta su historial y la API solo registra impresiones a su nombre |
| `recomendacion.perfiles_usuario` | Cada usuario accede exclusivamente a su perfil vectorial |
| `personas.usuarios` | Cada usuario y la API recuperan solamente la fila de la identidad declarada |

`USING` restringe qué filas pueden verse o modificarse; `WITH CHECK` valida qué filas pueden
insertarse o quedar como resultado de una actualización. Sin esta segunda condición, alguien
podría no ver datos ajenos y aun así escribir a nombre de otra persona.

### 13.3 Permisos por columna y seguridad de las vistas

RLS decide qué filas son accesibles, pero no qué columnas. El analista recibe acceso a un conjunto
limitado de columnas de `recomendacion.estrategias`, suficiente para comparar códigos, versiones y
motores sin exponer su descripción interna. Sobre `personas.usuarios` no recibe ningún permiso:
su único acceso es la vista preparada para análisis.

Las vistas operacionales de `db/indices_vistas/02_vistas.sql` usan
`security_invoker = TRUE`. Esto hace que se evalúen con los permisos de quien consulta y evita que
una vista creada por el dueño de la base se convierta en una puerta trasera hacia borradores o
contenido restringido.

La vista `personas.vw_usuarios_anonimizado` usa el patrón inverso de manera deliberada: necesita
leer la tabla original con los privilegios de su dueño para devolver únicamente atributos
transformados. El analista puede consultar esa salida controlada, pero no la fuente sensible.

### 13.4 Datos sensibles y seudonimización

El correo se guarda cifrado para su eventual recuperación y como HMAC para búsqueda y unicidad,
sin persistirlo en texto claro. Para la capa analítica,
`db/seguridad/04_vistas_anonimizadas.sql` crea además un seudónimo estable mediante HMAC-SHA256 y
una sal aleatoria almacenada en `control.secretos`.

La sal se genera una sola vez. Si cambiara entre corridas, un mismo usuario recibiría distintos
seudónimos y se perdería la continuidad histórica. La función que construye el seudónimo no puede
ser ejecutada por el analista: de lo contrario podría recorrer los identificadores y reconstruir
el mapeo completo.

La edad exacta también puede facilitar la reidentificación, por lo que se reemplaza por tramos
calculados contra un año de referencia estable. La vista analítica entrega seudónimo, país, tramo
etario, plan, consentimiento, estado y mes de alta; no expone id, alias, correo ni año de
nacimiento.

El resultado sigue siendo seudonimización, no anonimización irreversible. Quien accediera a la
sal podría reconstruir la relación; publicar los datos fuera de la organización requeriría
medidas adicionales de agregación y anonimización.

### 13.5 Auditoría

`db/seguridad/03_auditoria.sql` instala una función genérica y triggers sobre contenidos,
moderaciones, usuarios y suscripciones. Cada `INSERT`, `UPDATE` o `DELETE` registra el usuario de
base, el usuario de aplicación, la operación, la tabla, el identificador y los estados anterior y
nuevo en JSONB.

La función usa `SECURITY DEFINER`: puede escribir la traza sin entregar ese permiso a quien
modifica el dato original. Los roles de aplicación no pueden fabricar eventos ni modificar,
truncar o borrar los existentes. No se auditan las impresiones porque su propio carácter de
registro de eventos ya conserva la actividad y duplicarlas haría crecer la traza sin aportar la
misma utilidad.

La barrera tiene un límite explícito: el dueño o un superusuario todavía podría alterar la tabla.
Una auditoría inmutable incluso frente al DBA exigiría almacenamiento externo append-only, WORM o
firma criptográfica.

### 13.6 Estado de verificación

Los cuatro scripts incluyen controles sobre roles, políticas, triggers, funciones y columnas
expuestas. `db/consultas/05_prueba_aislamiento.sql` y
`db/consultas/06_prueba_aislamiento_api.sql` ejercitan accesos permitidos y operaciones que deben
fallar. Las verificaciones de MongoDB, Redis, Neo4j y MinIO completan el análisis en la sección
siguiente, con las limitaciones propias de cada motor declaradas de forma explícita.

### 13.7 Aislamiento en los otros motores

Cada motor ofrece una granularidad distinta, y esa asimetría es un resultado del análisis, no un
detalle de implementación. La columna **Estado** distingue lo implementado de lo que el motor no
permite.

| Motor | Mecanismo | Estado | Granularidad máxima | Límite |
|---|---|---|---|---|
| **PostgreSQL** | Roles, RLS, permisos por columna | Implementado | Tabla, **columna** y **fila** | Un superusuario siempre saltea el RLS |
| **MongoDB** | Rol propio por perfil, dos usuarios acotados | Implementado (`nosql/mongodb/02_usuarios_y_permisos.js`) | Base, colección y acción | **No tiene equivalente al RLS**: o ve la colección entera, o no la ve |
| **Redis** | ACL por comando y patrón de clave | Implementado (`orquestador/publicar_serving.py`) | Comando y patrón de clave | `~usuario:*` alcanza a *todos*; el aislamiento entre personas queda en la aplicación |
| **MinIO** | Política de bucket + usuario de solo lectura | Implementado (`scripts/configurar_minio.sh`) | Bucket, prefijo y acción | El lake ya recibe datos seudonimizados, así que el control es una segunda barrera |
| **Neo4j** | Usuario separado | **Limitación del motor** (`nosql/neo4j/01_usuarios.cypher`) | Ninguna: usuario o nada | **Community Edition no tiene control de acceso basado en roles.** No existe forma de crear un usuario de solo lectura |

#### La limitación de Neo4j, comprobada

No es una suposición: `nosql/neo4j/consultas/03_limitaciones_community.cypher` contiene el comando
que lo demuestra.

```
SHOW ROLES;
-->  Unsupported administration command: SHOW ROLES
```

Y `SHOW USERS` devuelve la columna `roles` en `NULL` para todos los usuarios, incluido el
administrador. Un usuario creado con `CREATE USER` tiene exactamente los mismos privilegios que
`neo4j`: sirve para rotar credenciales de forma independiente, y para nada más. El control
granular —roles, privilegios por etiqueta de nodo, seguridad a nivel de propiedad— es una función
de la edición Enterprise.

**Cómo se compensa.** Como el motor no puede restringir el acceso, se restringe el **dato**: los
nodos `:Usuario` del grafo tienen `usuario_id`, `pais` y `plan`, y nada más. Ni correo, ni alias,
ni fecha de nacimiento. Quien leyera el grafo entero no obtendría un solo identificador directo de
persona. Si el grafo guardara datos personales, elegir la Community Edition sería inadmisible.

En producción, el acceso pasaría además por un servicio que solo expone consultas parametrizadas y
el puerto Bolt no se publicaría: es el patrón habitual cuando el motor no puede imponer el límite.

#### La consecuencia de diseño

Esa tabla es la razón concreta por la que **los datos personales de este sistema viven en
PostgreSQL**. No es una preferencia: es el único motor del stack que puede imponer el aislamiento
entre personas a nivel de fila. En los demás solo hay comportamiento referenciado por id, y hacia
el lakehouse ni siquiera eso: sale seudonimizado.

### 13.8 El riesgo específico de una aplicación conectada a IA

El recomendador es un canal de exfiltración potencial: puede ofrecer un borrador, una nota
despublicada o contenido premium a quien no corresponde. Cinco capas independientes lo impiden:

1. **Prefiltrado dentro de la consulta vectorial**, nunca posfiltrado en la aplicación.
2. **Vistas con `security_invoker`**, para que el RLS aplique a través de ellas.
3. **Políticas RLS** en el motor, que protegen incluso a las consultas que nadie recuerde filtrar.
4. **Cálculo por lote acotado** a contenidos publicados: un borrador nunca entra a
   `ranking_items_similares` ni a Redis.
5. **Consentimiento** como condición para construir el perfil.

### 13.9 El servicio que consume esos datos

Las cinco capas anteriores solo valen si **quien consulta está sujeto a ellas**. Ese fue el punto
más débil de una versión anterior de este trabajo, y se corrigió.

**El problema.** La API se conectaba con el dueño de la base, que es superusuario y por lo tanto
**ignora el Row Level Security**. Toda la barrera quedaba en manos del código del servicio: si un
endpoint se olvidaba de filtrar, no había red debajo. Y uno se olvidaba: `/trending` devolvía
títulos de contenido premium a un visitante anónimo. Además aceptaba el `usuario_id` en la URL sin
autenticar, dejaba que el cliente declarara su propio `nivel_acceso` y permitía registrar
impresiones a nombre de cualquiera.

**La corrección**, toda en la capa de datos:

| Medida | Dónde |
|---|---|
| Rol `bdia_api`, no superusuario, sujeto a RLS | `db/seguridad/01_roles_y_permisos.sql` |
| Política `WITH CHECK` que impide escribir a nombre de otro | `db/seguridad/02_row_level_security.sql` |
| El nivel de acceso se deriva de `personas.nivel_acceso_actual()`, nunca del cliente | `orquestador/recomendador_api.py` |
| Sin acceso a `suscripciones`, `planes`, `auditoria` ni `control` | `db/seguridad/01_roles_y_permisos.sql` |
| `set_config(..., TRUE)`: el contexto muere con la transacción | `orquestador/recomendador_api.py` |
| Prefiltrado por nivel en todos los endpoints, incluido `/trending` | `orquestador/recomendador_api.py` |
| RLS sobre `recomendacion.perfiles_usuario`: el rol veía los 1.451 perfiles vectoriales | `db/seguridad/02_row_level_security.sql` |

**La segunda fuga**, encontrada revisando qué podía leer el rol y no qué devolvía la API: `bdia_api`
tenía `SELECT` sobre `recomendacion.perfiles_usuario` sin RLS. Los endpoints filtraban por
`usuario_id`, así que no era alcanzable desde afuera, pero la barrera estaba otra vez en el código.
El perfil vectorial es el centroide de todo lo que la persona consumió: son sus intereses
**inferidos**, y en cierto sentido es más sensible que el historial, porque el historial hay que
interpretarlo y el centroide ya es la interpretación.

La lección, aplicable a cualquier tabla que se agregue: **otorgar `SELECT` no alcanza; hay que
preguntarse además qué filas de esa tabla le corresponden a quien consulta.**

#### Mínimo privilegio en los cuatro motores

La API no usa credenciales administrativas en ninguno:

| Motor | Usuario | Qué puede |
|---|---|---|
| PostgreSQL | `bdia_api` | Sujeto a RLS; sin acceso a `suscripciones`, `planes`, `auditoria` ni `control` |
| Redis | `app_lectura` | Solo lectura, acotada a los patrones `rec:*`, `contenido:*`, `usuario:*` |
| MongoDB | `bdia_mongo_lectura` | `find` sobre tres colecciones; **sin acceso a `comentarios`** |
| Neo4j | `bdia_grafo_consulta` | Usuario separado, pero **no de solo lectura**: la Community Edition no tiene roles |

Y el transformador DuckDB usa `bdia_lake_transformador`, acotado al bucket `lakehouse`: puede leer
y escribir ahí —lo necesita, publica Silver en Parquet— y no puede crear buckets ni administrar el
servidor.

Dos detalles que completan el mínimo privilegio, y que sin ellos la afirmación sería a medias:

- **Las credenciales root de MinIO no se declaran en el contenedor del transformador.** Aunque el
  script no las usara, estar en el entorno alcanza: un `docker compose exec` las recupera. Un
  secreto que un proceso no necesita es un secreto que no debería poder leer.
- **El script no tiene repliegue a root.** `${MINIO_TRANSFORMADOR_USER:?...}` aborta si la variable
  falta. Un repliegue silencioso convertiría un error de configuración en una escalada de
  privilegios que nadie notaría, porque todo seguiría funcionando.

Como esos usuarios los crean pasos del pipeline, la API **arranca al final**, con el perfil de
Compose `consumo`. Su `/salud` devuelve **503** si algún motor no responde: un healthcheck que
diera 200 con `"ok": false` marcaría como sano un servicio degradado.

`db/consultas/06_prueba_aislamiento_api.sql` lo demuestra con siete bloques, seis de los cuales
**deben fallar**. El más importante:

```sql
SET LOCAL ROLE bdia_api;
SELECT set_config('app.usuario_id', '2', TRUE);
INSERT INTO recomendacion.impresiones (usuario_id, ...) VALUES (9999, ...);
-->  ERROR: new row violates row-level security policy for table "impresiones"
```

Aunque alguien modificara la API para aceptar el `usuario_id` del cuerpo del pedido, el motor
rechaza la fila. **Esa es la diferencia entre una validación y una barrera.**

#### Lo que queda fuera del alcance

La **autenticación**. La identidad llega en la cabecera `X-Usuario-Id`, que simula un token de
sesión ya validado; en producción sería un JWT firmado y el servidor verificaría la firma.

Es una decisión de alcance, no un descuido: la autenticación es un problema de la capa de
aplicación y de una materia distinta.

Conviene ser preciso sobre qué queda resuelto y qué no, porque la diferencia importa:

| | Estado |
|---|---|
| **A qué tiene derecho** el usuario (nivel de acceso, qué filas ve, qué puede escribir) | **No se confía en el cliente.** Sale siempre de la base, y el RLS lo impone |
| **Quién dice ser** el usuario | **Se confía en la cabecera.** Cualquiera puede enviar `X-Usuario-Id: 2` y asumir esa identidad |

Es decir: el sistema resuelve la **autorización** en el motor y deja la **autenticación**
declarada como fuera de alcance. Reemplazar la cabecera por un JWT validado cerraría la segunda
fila sin cambiar una sola línea de SQL, porque todo lo que depende de la identidad ya se resuelve
a partir de `app.usuario_id`, no de lo que el cliente afirme sobre sus permisos.

## 14. Escalabilidad y rendimiento

### 14.1 Qué crece y a qué ritmo

| Estructura | Crecimiento | Proyección a 1 año |
|---|---|---|
| `recomendacion.impresiones` | Lineal en tráfico × posiciones | Cientos de millones |
| MongoDB `eventos_interaccion` | Lineal en tráfico | Miles de millones (acotado por TTL) |
| `telemetria_reproduccion` | Lineal en reproducciones × duración | El mayor de todos; acotado por TTL |
| `catalogo.contenidos` | ~30/día | Decenas de miles |
| Embeddings | 1 por contenido | Decenas de miles |
| Aristas `VIO` en Neo4j | Usuarios × contenidos consumidos | Cientos de millones |

### 14.2 Consultas críticas

| Consulta | Frecuencia | Estrategia |
|---|---|---|
| Feed personalizado | Cada request | Precalculada en Redis; `ZREVRANGE` en O(log n + N) |
| "Más como este" | Cada vista de artículo | Precalculada en `ranking_items_similares` |
| Trending | Cada carga de portada | Vista materializada + ZSET |
| CTR por estrategia | Por hora | Capa Gold; nunca toca la base operacional |
| Registro de impresiones | Cada request | `INSERT` en la partición del mes; sin trigger de auditoría |

### 14.3 Qué se particiona

`recomendacion.impresiones` con particionado declarativo mensual. Las tres razones:

- Todas las consultas analíticas filtran por rango de fechas → *partition pruning*.
- La retención se implementa con `DETACH` + `DROP` de una partición, que es una operación de
  metadatos, en lugar de un `DELETE` masivo que infla el WAL.
- Los índices se mantienen chicos y caben en memoria.

Se incluye una **partición `DEFAULT` como red de contención**: sin ella, una fila con fecha fuera
de rango voltea la carga entera. Con ella la fila entra y la verificación la denuncia después.

MongoDB: sharding por `hash(usuario_id)`. Shardear por fecha concentraría toda la escritura en el
shard del día en curso.

### 14.4 Qué se indexa y por qué

Cada índice está justificado por una consulta concreta; los índices sin consulta que los use son
costo puro.

| Índice | Justificación |
|---|---|
| Parcial `WHERE estado = 'publicado'` | El feed nunca mira otra cosa; ocupa menos y entra mejor en caché |
| Compuesto `(seccion_id, nivel_acceso, fecha_publicacion DESC)` | El orden sale del índice, sin `Sort` posterior |
| **BRIN** sobre `mostrado_en` | Las filas se insertan en orden cronológico: correlación física casi perfecta. Ocupa KB donde un btree ocuparía MB |
| GIN `jsonb_path_ops` | Operador `@>`; 2–3× más chico que el GIN por defecto |
| GIN por defecto sobre `metadatos` | Operador `?`, que `jsonb_path_ops` no soporta |
| HNSW sobre embeddings | Recorridos O(log n) en lugar de O(n) |
| Parcial `WHERE clic = TRUE` | Los clics son ~4% de las filas y se consultan solos |

### 14.5 Qué se precalcula

Vista materializada de trending (`REFRESH CONCURRENTLY`, que requiere índice único y evita
bloquear la consulta más caliente); vecinos semánticos y de co-ocurrencia; feeds por usuario en
Redis; capa Gold completa.

### 14.6 Qué se separa

Analítico de operacional (DuckDB sobre el lake); serving de fuente de verdad (Redis); recorridos
de relaciones (Neo4j); clickstream de catálogo (MongoDB). El siguiente paso natural sería una
réplica de lectura de PostgreSQL para el analista.

### 14.7 Compromisos, explícitos

| Se gana | Se paga |
|---|---|
| Latencia sub-milisegundo en el feed | Frescura: el feed refleja la última corrida del pipeline |
| Consultas analíticas sin impacto en el sitio | Consistencia eventual entre capas |
| Cada consulta en el motor que la resuelve bien | Seis sistemas para operar |
| Escritura barata del clickstream | Sin integridad referencial en MongoDB; hay que verificarla en el pipeline |
| Búsqueda semántica rápida | Índices aproximados: recall < 100%, y el error es silencioso |

---

### 14.8 Alcance: qué está implementado y qué queda propuesto

Tabla única para evitar la ambigüedad más costosa de un informe técnico: presentar como existente
algo que solo está diseñado. Todo lo marcado **Implementado** se puede ejecutar y verificar; lo
marcado **Propuesto** está justificado en el texto pero no corre.

| Componente | Estado | Verificable con |
|---|---|---|
| Modelo relacional, particionado, índices, vistas | Implementado | `db/estructura/`, `db/indices_vistas/` |
| RLS, roles, permisos por columna, auditoría | Implementado | `db/consultas/05_prueba_aislamiento.sql` y `db/consultas/06_prueba_aislamiento_api.sql` |
| Seudonimización irreversible para el analista | Implementado | `db/seguridad/04_vistas_anonimizadas.sql` |
| Búsqueda vectorial con prefiltrado, HNSW e IVFFlat | Implementado | `vectorial/consultas/` |
| Modelo documental, validadores, timeseries, TTL | Implementado | `nosql/mongodb/` |
| Usuarios y roles restringidos en MongoDB | Implementado | `nosql/mongodb/consultas/05_permisos.md` |
| Grafo, restricciones e índices | Implementado | `nosql/neo4j/consultas/` |
| Usuario separado en Neo4j | Implementado, **sin poder ser de solo lectura** | `nosql/neo4j/consultas/03_limitaciones_community.cypher` |
| ACL de Redis por comando y patrón | Implementado | `nosql/redis/consultas/01_estructuras_de_serving.md` |
| Política de solo lectura en MinIO | Implementado | `scripts/configurar_minio.sh` |
| Lakehouse Medallion con calidad y linaje | Implementado | `analitico/` |
| Ingesta por stream con grupos de consumo, `XACK` y escritura idempotente | Implementado | `orquestador/consumir_stream.py` |
| Mínimo privilegio efectivo: cada consumidor con su usuario acotado | Implementado | `docker-compose.yml`, `scripts/ejecutar_duckdb.sh` |
| API sujeta a RLS | Implementado | `db/consultas/06_prueba_aislamiento_api.sql` |
| **Autenticación de la API** | **Propuesto** | Cabecera `X-Usuario-Id` que simula un token ya validado. La *autorización* sí está resuelta en el motor |
| **Réplica de lectura para el analista** | **Propuesto** | §14.6 |
| **Sharding de MongoDB** | **Propuesto** | §14.3 |
| **Formato transaccional de tabla (Iceberg/Delta)** | **Propuesto** | §12.2 |
| **Orquestación con reintentos (Airflow)** | **Propuesto** | §15.4 |
| **Gestor de secretos externo** | **Propuesto** | La sal vive en `control.secretos` |
| **Alta disponibilidad y réplicas** | **Propuesto** | §15.3 |

---

## 15. Conclusiones

### 15.1 Qué se demostró

Que el caso de uso 10 admite una solución de datos completa —conceptual, lógica, física y
arquitectónica— donde **cada decisión responde a un patrón de consulta concreto** y no a una
preferencia tecnológica. Los cinco motores están porque cada uno resuelve una pregunta que los
otros cuatro resuelven mal, y eso quedó demostrado con las consultas de §10 y con la demo que muestra
las cinco estrategias devolviendo resultados distintos sobre el mismo usuario.

### 15.2 Qué resultó más valioso

**Los controles que abortan, y revisar los permisos del rol en lugar de la salida del endpoint.**
Entre unos y otros aparecieron cinco defectos reales, y **cuatro eran silenciosos**: no producían
ningún error, solo resultados plausibles y equivocados.

Los tres del pipeline de datos: un kNN que devolvía de menos sin fallar, grupos descartados en Gold
y una capa Gold construida sobre datos de otra corrida. Ninguno habría aparecido en una revisión de
código; los tres producían números plausibles y equivocados.

La lección es directamente aplicable: **en una capa de datos para IA, el fallo silencioso es el
modo de fallo dominante.** Un modelo entrenado sobre datos con un 5% de filas perdidas no falla,
solo rinde peor, y nadie sabe por qué.

### 15.3 Limitaciones declaradas

- **No es un Lakehouse completo:** falta formato transaccional de tabla, *time travel* y catálogo
  de metadatos.
- **No hay orquestación:** el pipeline es un script secuencial, no un DAG con reintentos.
- **El volumen es de demostración:** las decisiones apuntan a escalas donde estos números no
  llegan; el `EXPLAIN` muestra la *forma* del plan, no tiempos representativos.
- **La seudonimización no equivale a anonimización:** si se compromete la clave del HMAC, un
  atacante puede probar identificadores candidatos y vincular los registros.
- **La auditoría no es inmutable** frente a un superusuario.
- **Los datos son sintéticos.** La estructura latente (afinidades, popularidad) fue puesta a mano,
  así que los resultados de las estrategias muestran que el diseño funciona, no qué estrategia
  ganaría con datos reales.
- **No hay alta disponibilidad:** una sola instancia de cada motor.

### 15.4 Próximos pasos

1. Orquestar el pipeline con Airflow, con reintentos y alertas sobre los controles de calidad.
2. Réplica de lectura de PostgreSQL para aislar la carga analítica.
3. Migrar Silver a Apache Iceberg para obtener *time travel* y escrituras concurrentes.
4. Búsqueda híbrida literal + semántica con *reciprocal rank fusion*.
5. Medir el recall real de HNSW contra el kNN exacto y ajustar `ef_search` con ese dato.
6. Reemplazar Redis Streams por Kafka cuando el volumen de ingesta lo justifique.
