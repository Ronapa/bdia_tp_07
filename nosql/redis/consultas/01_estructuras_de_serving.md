# 01. La capa de serving en Redis

Todos los bloques se ejecutan desde el cliente de Redis. Para abrirlo:

```bash
docker compose exec redis-serving redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)"
```

O, sin entrar al shell interactivo:

```bash
docker compose exec -T redis-serving \
  redis-cli -a "$(grep REDIS_PASSWORD .env | cut -d= -f2)" <comando>
```

> Redis avisa que pasar la contraseña por línea de comandos es inseguro. En este entorno local es
> aceptable; en producción se usaría `REDISCLI_AUTH` o un archivo de configuración.

La capa entera la publica `orquestador/publicar_serving.py`. **Nada de lo que hay acá es fuente de
verdad**: todo sale de PostgreSQL o de la capa Gold, y se puede reconstruir corriendo ese script.

---

## Panorama del espacio de claves

**Objetivo:** ver qué hay publicado y cuánta memoria ocupa.

```
DBSIZE
INFO memory
```

```
SCAN 0 MATCH rec:* COUNT 20
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `DBSIZE` | Cantidad de claves | Panorama rápido |
| `SCAN cursor MATCH patron` | Itera el espacio de claves de a bloques | Recorre sin bloquear el servidor |
| `INFO memory` | Estadísticas de memoria | Dimensionar `maxmemory` |

**Observá:** se usa `SCAN` y **nunca** `KEYS`. `KEYS` recorre el espacio de claves completo
bloqueando el servidor, que es de un solo hilo. Con 7.000 claves no se nota; con millones es un
incidente de producción.

---

## ZSET: el ranking de popularidad

**Objetivo:** servir el trending con una sola lectura.

```
ZREVRANGE rec:trending:global 0 9 WITHSCORES
ZCARD rec:trending:global
TTL rec:trending:global
```

Por sección:

```
ZREVRANGE rec:trending:seccion:economia 0 4 WITHSCORES
```

Posición de un contenido puntual dentro del ranking:

```
ZREVRANK rec:trending:global 28
ZSCORE rec:trending:global 28
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `ZREVRANGE clave inicio fin` | Rango descendente por puntaje | Devuelve el top-N **ya ordenado** |
| `WITHSCORES` | Incluye el puntaje | Permite ver la magnitud, no solo el orden |
| `ZREVRANK` | Posición de un miembro | "¿En qué puesto está esta nota?" |
| `TTL` | Segundos de vida restantes | Confirma que el ranking expira solo |

**Qué hace:** devuelve las diez notas más leídas de las últimas 24 horas.

**Observá:** el conjunto ordenado ya está ordenado. `ZREVRANGE` cuesta O(log n + N): no hay
`ORDER BY`, no hay `Sort`, no hay que recorrer nada. Esa es la razón por la que el ranking vive
acá y no se calcula en el request.

**Comparación con SQL:** el equivalente es la consulta de `analitica.agg_popularidad` con
`ORDER BY score DESC LIMIT 10`, que necesita leer el índice y proyectar. Funciona, pero paga el
costo en cada request en vez de una vez por corrida del pipeline.

---

## ZSET: el feed híbrido precalculado

**Objetivo:** ver el resultado de la estrategia híbrida para un usuario.

```
ZREVRANGE rec:usuario:1:top 0 9 WITHSCORES
ZCARD rec:usuario:1:top
```

Comparar dos usuarios distintos:

```
ZREVRANGE rec:usuario:1:top 0 4
ZREVRANGE rec:usuario:2:top 0 4
```

**Observá:** los dos feeds son distintos. Si fueran iguales, la personalización no estaría
aportando nada y bastaría con el ranking global.

**Cómo se calculó:** `publicar_serving.py` mezcla tres señales con pesos explícitos
(0,30 popularidad + 0,35 similitud semántica + 0,35 co-ocurrencia), y **después** resta los
filtros duros: nivel de acceso, vetos declarados y contenido ya visto. El orden importa: restar al
final garantiza que ningún contenido vetado sobreviva por un empate de puntajes.

---

## Operaciones entre conjuntos ordenados

**Objetivo:** combinar rankings sin recalcularlos.

```
ZUNIONSTORE tmp:mezcla 2 rec:trending:global rec:usuario:1:top WEIGHTS 0.3 0.7
ZREVRANGE tmp:mezcla 0 9 WITHSCORES
DEL tmp:mezcla
```

Intersección: qué recomendaciones del feed personalizado están además en el trending.

```
ZINTERSTORE tmp:comunes 2 rec:trending:global rec:usuario:1:top
ZCARD tmp:comunes
DEL tmp:comunes
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `ZUNIONSTORE dst N k1 k2 WEIGHTS w1 w2` | Une conjuntos ordenados ponderando puntajes | Mezcla dos estrategias en el servidor |
| `ZINTERSTORE` | Intersección | Mide el solapamiento entre estrategias |

**Observá:** la mezcla se resuelve **dentro** de Redis, sin traer los dos rankings a la
aplicación. Es el argumento por el que un ZSET no es "una lista con puntaje": trae un álgebra de
conjuntos ordenados incorporada.

**Un solapamiento alto entre el feed personalizado y el trending es una señal de alarma**: quiere
decir que la personalización está devolviendo lo mismo que el ranking global.

---

## SET: deduplicación de impresiones

**Objetivo:** no volver a mostrar lo que el usuario ya vio.

```
SCARD usuario:1:vistos
SISMEMBER usuario:1:vistos 28
SRANDMEMBER usuario:1:vistos 5
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `SISMEMBER` | ¿Pertenece? | La pregunta exacta del caso de uso, en **O(1)** |
| `SCARD` | Cardinalidad | Cuántos contenidos consumió |
| `SRANDMEMBER` | Muestra aleatoria | Inspección |

**Observá:** la pregunta del negocio es de pertenencia, no de orden ni de rango. Un SET la
responde en tiempo constante. Con una lista habría que recorrerla; con un ZSET se pagaría el
costo del orden sin usarlo.

**Comparación con SQL:** `WHERE contenido_id NOT IN (SELECT ... FROM impresiones WHERE usuario_id = ...)`
resuelve lo mismo, pero cuesta un acceso a índice por cada candidato del feed.

---

## HASH: feature store online y caché de metadatos

**Objetivo:** ver los rasgos que el recomendador necesita en el momento del request.

```
HGETALL usuario:1:features
HGET usuario:1:features nivel_acceso
```

Caché de metadatos del catálogo:

```
HGETALL contenido:28:meta
HMGET contenido:28:meta titulo seccion nivel_acceso
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `HGETALL` | Todos los campos | Trae el registro completo en un viaje |
| `HMGET` | Varios campos puntuales | Trae solo lo que se va a renderizar |
| `HSET` | Escribe un campo | Actualiza un rasgo sin reescribir el resto |

**Observá:** el HASH permite actualizar `contenidos_vistos` sin tocar los otros cuatro campos.
Si el valor fuera un `STRING` con un JSON adentro, cada actualización reescribiría todo el
documento.

**Importante:** en `contenido:*:meta` **solo hay contenidos publicados**. Un borrador nunca llega
a Redis. Redis no tiene Row Level Security: lo que no debe salir, no sale de PostgreSQL.

---

## STREAM: el buffer de ingesta

**Objetivo:** ver el amortiguador entre la aplicación y MongoDB.

```
XINFO STREAM cola:eventos
XLEN cola:eventos
XINFO GROUPS cola:eventos
```

Simular la escritura de un evento y su consumo:

```
XADD cola:eventos * tipo vista usuario_id 1 contenido_id 28
XREADGROUP GROUP ingestores consumidor-1 COUNT 5 STREAMS cola:eventos >
```

Confirmar el procesamiento (el id sale del `XREADGROUP` anterior):

```
XACK cola:eventos ingestores <id-del-mensaje>
XPENDING cola:eventos ingestores
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `XADD clave * campo valor` | Agrega una entrada | Escritura del evento |
| `XREADGROUP GROUP g c` | Lee como parte de un grupo de consumo | Reparte el trabajo entre consumidores |
| `XACK` | Confirma el procesamiento | Sin `XACK`, el mensaje sigue pendiente |
| `XPENDING` | Mensajes leídos y no confirmados | Detecta consumidores caídos |

**Qué hace:** demuestra el ciclo completo de ingesta: escribir, leer por grupo, confirmar.

**Observá:** el mensaje queda **pendiente** hasta el `XACK`. Si el consumidor se cae después de
leer y antes de confirmar, el mensaje se recupera con `XCLAIM`. Una lista (`LPUSH`/`RPOP`) no da
esa garantía: si el consumidor se cae después del `RPOP`, el evento se perdió.

**Por qué no Kafka:** a escala real, Kafka. Para este volumen agregaría tres servicios (broker,
coordinación, registro de esquemas) sin beneficio, y Redis ya está en el stack por otra razón.

---

## TTL y política de memoria

**Objetivo:** entender qué expira y qué puede desalojarse.

```
TTL rec:trending:global
TTL rec:usuario:1:top
TTL usuario:1:vistos
CONFIG GET maxmemory
CONFIG GET maxmemory-policy
```

**Observá:** todas las claves tienen vencimiento. El TTL no es solo higiene de memoria: **es el
mecanismo que garantiza que un feed obsoleto deje de servirse** aunque el pipeline falle.

**Sobre el valor del TTL.** El valor es una decisión de producto —frescura contra
disponibilidad—, no un detalle técnico. En producción, un feed de recomendaciones usaría unos
**900 segundos**: si el pipeline se cae, a los quince minutos el sitio vuelve al ranking global en
lugar de servir recomendaciones de ayer.

En este proyecto el valor por defecto es **24 horas**, para que el entorno se pueda revisar al día
siguiente sin volver a correr el pipeline. Con 900 segundos, los bloques de este archivo
devolverían vacío antes de que nadie llegara a ejecutarlos. Se ajusta con:

```bash
docker compose exec -T orquestador \
  python /workspace/orquestador/publicar_serving.py --ttl 900
```

Si un `ZREVRANGE` devuelve vacío, lo más probable es que la clave haya expirado: volvé a correr
`publicar_serving.py`.

**El compromiso, explícito:** `allkeys-lru` es correcto para los cachés y **es peligroso para el
stream**. Bajo presión de memoria, Redis podría desalojar `cola:eventos` junto con el resto. En
producción se resuelve separando el stream a otra instancia o a otro índice de base con su propia
política. Se documenta como el compromiso que es, no se resuelve en silencio.

---

## Control de acceso

**Objetivo:** ver hasta dónde llega el aislamiento que ofrece Redis.

```
ACL LIST
ACL GETUSER app_lectura
```

Probar el usuario restringido:

```bash
docker compose exec redis-serving redis-cli --user app_lectura --pass lectura_local
```

Dentro de esa sesión, lo permitido:

```
ZREVRANGE rec:trending:global 0 4
HGETALL contenido:28:meta
```

Y lo que **debe fallar**:

```
SET clave-prohibida valor
```

```
ZREVRANGE analitica:algo 0 4
```

```
FLUSHALL
```

> **IMPORTANTE:** los tres últimos bloques deben devolver `NOPERM`. Ese es el resultado esperado.

**Observá:** Redis restringe por **comando** y por **patrón de clave**, no por fila ni por tabla.

**El límite, declarado:** `~usuario:*` alcanza a *todos* los usuarios. Redis no puede expresar
"solo las claves de este usuario final", así que el aislamiento entre personas sigue siendo
responsabilidad de la aplicación. Es una diferencia real con el Row Level Security de PostgreSQL,
y es exactamente la razón por la que los datos personales sensibles no viven acá.

---

## Cierre conceptual

| Estructura | Por qué esa y no otra | Consulta que la justifica |
|---|---|---|
| ZSET | El caso de uso **es** un ranking | `ZREVRANGE` del feed y del trending |
| SET | La pregunta es de pertenencia | `SISMEMBER` de deduplicación |
| HASH | Varios campos leídos juntos, actualizados de a uno | `HGETALL` del feature store |
| STRING + `INCR` | Contador atómico que se destruye solo | *Sin bloque: no la publica el pipeline* |
| STREAM | Orden + grupos de consumo + confirmación | Ingesta del clickstream |

> **Sobre `STRING` + `INCR`.** Es la única fila del cuadro sin bloque ejecutable arriba,
> porque `publicar_serving.py` no crea esa clave. El *rate limiting*
> (`ratelimit:<usuario>:<minuto>`, especificado en `nosql/modelo_nosql.md`) lo escribiría la
> aplicación en el momento del request, con `INCR` seguido de `EXPIRE 60`: la clave nace con
> el primer pedido del minuto y se destruye sola al terminarlo. Lo mismo vale para
> `sesion:<token>`. Se mantienen en el cuadro porque completan el argumento de la sección
> —cada pregunta usa la estructura que le corresponde, y un contador con vencimiento no
> necesita ni ZSET ni HASH—, pero en este entorno no hay clave que inspeccionar hasta que
> haya tráfico real.


Y la propiedad que hace posible todo lo anterior: **nada de esto es fuente de verdad**. 
Por eso **Redis** puede correr sin durabilidad, sin transacciones y en memoria, 
que es lo que le permite responder en menos de un milisegundo.
