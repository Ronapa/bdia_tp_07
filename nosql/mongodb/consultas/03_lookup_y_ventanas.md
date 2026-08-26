# 03. Relaciones entre colecciones y funciones de ventana

Todos los bloques trabajan sobre `bdia_nexomedia`.

Estas consultas muestran cómo MongoDB resuelve lo que en el modelo relacional serían `JOIN` y
`OVER (PARTITION BY ...)`, y dónde conviene no hacerlo.

## `$lookup`: unir el clickstream con el cuerpo del contenido

**Objetivo:** ver qué contenidos generan más eventos, trayendo su formato y su cantidad de
bloques.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { tipo_evento: "vista" } },
    { $group: { _id: "$contenido_id", vistas: { $sum: 1 } } },
    { $sort: { vistas: -1 } },
    { $limit: 15 },
    {
        $lookup: {
            from: "cuerpos_contenido",
            localField: "_id",
            foreignField: "contenido_id",
            as: "cuerpo"
        }
    },
    { $unwind: "$cuerpo" },
    {
        $project: {
            _id: 0,
            contenido_id: "$_id",
            vistas: 1,
            formato: "$cuerpo.formato",
            palabras: "$cuerpo.palabras",
            bloques: { $size: "$cuerpo.bloques" }
        }
    }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$lookup` | Trae documentos de otra colección | Equivale a un `LEFT JOIN` |
| `$unwind` | Desarma un array en un documento por elemento | Convierte el array de un solo elemento en un subdocumento plano |
| `$project` | Selecciona y renombra campos | Deja el resultado listo para leer |

**Qué hace:** los quince contenidos más vistos, con los datos de su cuerpo.

**Observá:** el `$lookup` va **después** del `$limit`, no antes. Ese orden es lo que hace la
diferencia entre 15 búsquedas y una por cada evento de la colección. `$lookup` es la etapa más
cara del pipeline: cuanto más tarde entre, mejor.

**Comparación con SQL:** `LEFT JOIN` seguido de `LIMIT`. La diferencia práctica es que el
planificador de PostgreSQL puede reordenar el JOIN por su cuenta; en MongoDB el orden que
escribís es el orden que se ejecuta.

## Cuándo NO usar `$lookup`

**Objetivo:** entender por qué el título del contenido no está en la colección de eventos.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

// Esta consulta es correcta pero es la que NO conviene ejecutar en el
// camino caliente: para mostrar un feed hay que resolver el titulo, y
// el titulo es de PostgreSQL.
practica.eventos_interaccion.aggregate([
    { $match: { usuario_id: 1 } },
    { $sort: { ocurrido_en: -1 } },
    { $limit: 10 },
    {
        $lookup: {
            from: "cuerpos_contenido",
            localField: "contenido_id",
            foreignField: "contenido_id",
            pipeline: [{ $project: { formato: 1, palabras: 1, _id: 0 } }],
            as: "cuerpo"
        }
    }
]).toArray();
```

**Observá:** MongoDB **no puede** unir contra PostgreSQL. El título, la sección y el estado de
publicación viven allá, que es donde tienen integridad referencial y control de acceso por
fila.

**La decisión de diseño, explícita:** el clickstream guarda `contenido_id` y nada más. Las tres
alternativas y por qué se descartaron:

| Alternativa | Por qué no |
|---|---|
| Duplicar título y sección en cada evento | Dos fuentes de verdad; renombrar una sección obligaría a reescribir millones de documentos |
| Replicar el catálogo entero a MongoDB | Duplica el problema de consistencia y el control de acceso queda fuera del RLS |
| Resolver el `JOIN` en la aplicación | **Es lo que se hace**: la API pide los ids a MongoDB o Redis y trae los datos del catálogo desde PostgreSQL, donde el RLS sigue aplicando |

## `$setWindowFields`: ranking dentro de cada sección

**Objetivo:** rankear contenidos dentro de su grupo, que es lo que en SQL hace
`RANK() OVER (PARTITION BY ...)`.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { tipo_evento: { $in: ["vista", "completado"] } } },
    {
        $group: {
            _id: { contenido: "$contenido_id", dispositivo: "$contexto.dispositivo" },
            eventos: { $sum: 1 },
            segundos: { $sum: { $ifNull: ["$metricas.segundos_visibles", 0] } }
        }
    },
    {
        $setWindowFields: {
            partitionBy: "$_id.dispositivo",
            sortBy: { eventos: -1 },
            output: {
                posicion: { $rank: {} },
                acumulado: { $sum: "$eventos", window: { documents: ["unbounded", "current"] } },
                promedio_dispositivo: { $avg: "$eventos" }
            }
        }
    },
    { $match: { posicion: { $lte: 3 } } },
    {
        $project: {
            _id: 0,
            dispositivo: "$_id.dispositivo",
            contenido_id: "$_id.contenido",
            eventos: 1,
            posicion: 1,
            promedio_dispositivo: { $round: ["$promedio_dispositivo", 2] },
            diferencia_vs_promedio: {
                $round: [{ $subtract: ["$eventos", "$promedio_dispositivo"] }, 2]
            }
        }
    },
    { $sort: { dispositivo: 1, posicion: 1 } }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$setWindowFields` | Calcula funciones de ventana | Equivale a `OVER (PARTITION BY ... ORDER BY ...)` |
| `partitionBy` / `sortBy` | Definen la ventana | Rankean dentro de cada dispositivo |
| `$rank` | Posición dentro de la partición | Igual que `RANK()` en SQL |
| `window: {documents: [...]}` | Marco de la ventana | Suma acumulada hasta la fila actual |

**Qué hace:** el top 3 de contenidos por dispositivo, con su desvío respecto del promedio de
ese dispositivo.

**Observá:** `promedio_dispositivo` se calcula sobre **toda** la partición, no sobre las tres
filas que sobreviven al `$match` posterior. Es exactamente el comportamiento de una función de
ventana en SQL, y la razón por la que no se puede reemplazar con un segundo `$group`.

## Búsqueda de texto dentro del cuerpo

**Objetivo:** usar el índice de texto de `cuerpos_contenido`.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.cuerpos_contenido.find(
    { $text: { $search: "escrutinio padron" } },
    { puntaje: { $meta: "textScore" }, contenido_id: 1, formato: 1, _id: 0 }
).sort({ puntaje: { $meta: "textScore" } }).limit(5).toArray();
```

**Qué hace:** busca términos literales dentro de los bloques de texto.

**Observá:** encuentra las apariciones **exactas** de las palabras (con stemming en español).
No encuentra un contenido que hable del mismo tema con otras palabras: eso lo resuelve la
búsqueda vectorial de `vectorial/consultas/`.

Las dos búsquedas son complementarias, y el informe lo desarrolla: la literal gana con nombres
propios, siglas y cifras; la semántica gana cuando el usuario describe el tema con sus propias
palabras.
