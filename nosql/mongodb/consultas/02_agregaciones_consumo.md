# 02. Agregaciones sobre el clickstream

Todos los bloques trabajan sobre `bdia_nexomedia`. Son las consultas que responden preguntas
de producto sobre el consumo real, y las que después alimentan la capa Gold del lakehouse.

## Embudo de consumo por tipo de contenido

**Objetivo:** medir cuánta gente que ve un contenido llega a terminarlo.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { tipo_evento: { $in: ["impresion", "vista", "completado"] } } },
    {
        $group: {
            _id: { contenido: "$contenido_id", etapa: "$tipo_evento" },
            eventos: { $sum: 1 }
        }
    },
    {
        $group: {
            _id: "$_id.contenido",
            etapas: { $push: { etapa: "$_id.etapa", eventos: "$eventos" } }
        }
    },
    {
        $project: {
            _id: 0,
            contenido_id: "$_id",
            impresiones: {
                $ifNull: [{ $first: { $filter: {
                    input: "$etapas", cond: { $eq: ["$$this.etapa", "impresion"] } } } }, null]
            },
            vistas: {
                $ifNull: [{ $first: { $filter: {
                    input: "$etapas", cond: { $eq: ["$$this.etapa", "vista"] } } } }, null]
            },
            completados: {
                $ifNull: [{ $first: { $filter: {
                    input: "$etapas", cond: { $eq: ["$$this.etapa", "completado"] } } } }, null]
            }
        }
    },
    { $sort: { "vistas.eventos": -1 } },
    { $limit: 10 }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$match` primero | Filtra antes de agrupar | Reduce el volumen antes del trabajo caro; además puede usar índices |
| `$group` doble | Agrupa y después reagrupa | Pivotea las etapas del embudo a un documento por contenido |
| `$push` | Acumula en un array | Junta las tres etapas del mismo contenido |
| `$filter` / `$first` | Recorren un array dentro de la expresión | Extraen la etapa buscada sin salir del pipeline |

**Qué hace:** arma un embudo impresión → vista → completado por contenido.

**Observá:** el `$match` va **primero**, no último. Es la regla más importante de un pipeline
de agregación: cada etapa procesa lo que le pasó la anterior, así que filtrar tarde significa
haber agrupado documentos que se van a descartar.

**Comparación con SQL:** el doble `$group` equivale a un `GROUP BY` con `FILTER (WHERE ...)`
por etapa. El pipeline es más verboso; a cambio, cada etapa es inspeccionable por separado.

## Distribución de la profundidad de lectura con `$bucket`

**Objetivo:** saber si la gente lee las notas o rebota.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { "metricas.porcentaje_scroll": { $exists: true } } },
    {
        $bucket: {
            groupBy: "$metricas.porcentaje_scroll",
            boundaries: [0, 25, 50, 75, 100, 1000],
            default: "fuera_de_rango",
            output: {
                eventos: { $sum: 1 },
                segundos_promedio: { $avg: "$metricas.segundos_visibles" }
            }
        }
    }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$bucket` | Agrupa por rangos definidos a mano | Convierte una variable continua en tramos de negocio |
| `boundaries` | Cortes de cada tramo | Definen los cuartiles de lectura |
| `default` | Bucket para lo que no entra | Hace visibles los valores anómalos en vez de descartarlos |

**Qué hace:** reparte las lecturas en tramos de scroll.

**Observá:** el bucket `fuera_de_rango` captura los `porcentaje_scroll` mayores a 100, que el
generador inyecta a propósito como dato sucio. Sin `default`, esos eventos se caerían del
resultado sin dejar rastro y el total no cerraría. **Una agregación que descarta en silencio
es peor que una que falla.**

## Panorama en una sola pasada con `$facet`

**Objetivo:** obtener varios cortes del mismo conjunto sin recorrerlo varias veces.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { ocurrido_en: { $gte: ISODate("2026-07-01T00:00:00Z") } } },
    {
        $facet: {
            por_dispositivo: [
                { $group: { _id: "$contexto.dispositivo", eventos: { $sum: 1 } } },
                { $sort: { eventos: -1 } }
            ],
            por_canal: [
                { $group: { _id: "$contexto.canal", eventos: { $sum: 1 } } },
                { $sort: { eventos: -1 } }
            ],
            por_tipo_evento: [
                { $group: { _id: "$tipo_evento", eventos: { $sum: 1 } } },
                { $sort: { eventos: -1 } }
            ],
            por_hora: [
                { $group: { _id: { $hour: "$ocurrido_en" }, eventos: { $sum: 1 } } },
                { $sort: { _id: 1 } }
            ],
            totales: [
                {
                    $group: {
                        _id: null,
                        eventos: { $sum: 1 },
                        usuarios: { $addToSet: "$usuario_id" }
                    }
                },
                { $project: { _id: 0, eventos: 1, usuarios: { $size: "$usuarios" } } }
            ]
        }
    }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$facet` | Ejecuta varios subpipelines sobre la misma entrada | Cinco cortes con una sola lectura de la colección |
| `$hour` | Extrae la hora de una fecha | Muestra el sesgo horario del consumo |
| `$addToSet` + `$size` | Conjunto y su cardinalidad | Cuenta usuarios únicos |

**Qué hace:** produce el tablero del último mes en un solo documento.

**Observá:** en `por_hora` se ven los dos picos que el generador sintetizó a propósito
(mañana y noche). Sin ese sesgo, cualquier recomendación contextual por franja horaria daría
lo mismo que el azar.

**Comparación con SQL:** cinco `GROUP BY` distintos, o un `UNION ALL` de cinco consultas.
`$facet` los resuelve con una sola pasada.

## Serie temporal de reproducción

**Objetivo:** consultar la colección timeseries por rango.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.telemetria_reproduccion.aggregate([
    { $match: { ocurrido_en: { $gte: ISODate("2026-07-01T00:00:00Z") } } },
    {
        $group: {
            _id: {
                dia: { $dateTrunc: { date: "$ocurrido_en", unit: "day" } },
                calidad: "$medicion.calidad"
            },
            mediciones: { $sum: 1 },
            buffer_promedio_ms: { $avg: "$medicion.buffer_ms" }
        }
    },
    { $sort: { "_id.dia": 1, "_id.calidad": 1 } },
    { $limit: 20 }
]).toArray();
```

**Qué hace:** promedia el tiempo de buffer por día y calidad de video.

**Observá:** la consulta se escribe igual que sobre una colección común. La diferencia está
abajo: MongoDB agrupa internamente las mediciones por `metaField` y ventana temporal, así que
lee muchos menos bloques. Compará el tamaño con `db.telemetria_reproduccion.stats()`.

**Límite a tener presente:** una colección timeseries **no admite** `updateOne` ni
`deleteOne` sobre una medición individual, ni índices únicos. Por eso el clickstream de
negocio, que sí puede necesitar corrección, quedó en una colección común.
