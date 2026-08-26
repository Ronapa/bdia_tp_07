# 04. Índices, planes de ejecución y escritura

Todos los bloques trabajan sobre `bdia_nexomedia`.

## Medir antes y después del índice

**Objetivo:** ver el efecto real de un índice, en vez de asumirlo.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion
    .find({ usuario_id: 42 })
    .sort({ ocurrido_en: -1 })
    .limit(20)
    .explain("executionStats").executionStats;
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `explain("executionStats")` | Devuelve el plan y lo que costó ejecutarlo | Permite comparar planes con números, no con impresiones |
| `totalDocsExamined` | Documentos leídos | Es la métrica que importa: cuánto se leyó de más |
| `nReturned` | Documentos devueltos | El ideal es que se parezca a `totalDocsExamined` |

**Qué hace:** muestra el plan de la consulta más caliente del feature store.

**Observá:** con `idx_usuario_fecha` creado, `totalDocsExamined` debería ser cercano a
`nReturned` (unos 20) y el `winningPlan` debería mostrar `IXSCAN`. Sin índice sería `COLLSCAN`
y `totalDocsExamined` sería la colección entera.

Para verlo con tus propios ojos, borrá el índice, medí y volvé a crearlo:

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

> **Importante:** con volúmenes chicos la diferencia de tiempo puede ser despreciable, e
> incluso el `COLLSCAN` puede ganar. Lo que **no** cambia con el volumen es
> `totalDocsExamined`: esa es la métrica a mirar, porque es la que se degrada linealmente
> cuando la colección crece.

## Por qué el índice de atribución es parcial

**Objetivo:** comparar el tamaño de un índice parcial contra el que indexa todo.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

// Solo los eventos de tipo 'impresion' tienen origen_recomendacion.
practica.eventos_interaccion.aggregate([
    {
        $group: {
            _id: { $cond: [{ $eq: ["$tipo_evento", "impresion"] }, "impresion", "otro"] },
            eventos: { $sum: 1 }
        }
    }
]).toArray();

// Tamaño de cada índice en bytes.
practica.eventos_interaccion.stats().indexSizes;
```

**Qué hace:** muestra qué proporción de la colección cubre el índice parcial.

**Observá:** `idx_atribucion_estrategia` indexa alrededor del 30% de los documentos.
Un índice común guardaría además una entrada nula por cada evento que no es impresión, sin
responder ninguna consulta adicional: los eventos sin `origen_recomendacion` nunca se filtran
por estrategia.

## La consulta de atribución que justifica ese índice

**Objetivo:** medir qué estrategia genera más impresiones y con qué contexto.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.aggregate([
    { $match: { tipo_evento: "impresion" } },
    {
        $group: {
            _id: {
                estrategia: "$origen_recomendacion.estrategia",
                variante: "$origen_recomendacion.variante_ab"
            },
            impresiones: { $sum: 1 },
            posicion_promedio: { $avg: "$origen_recomendacion.posicion" },
            usuarios: { $addToSet: "$usuario_id" }
        }
    },
    {
        $project: {
            _id: 0,
            estrategia: "$_id.estrategia",
            variante: "$_id.variante",
            impresiones: 1,
            posicion_promedio: { $round: ["$posicion_promedio", 2] },
            usuarios_alcanzados: { $size: "$usuarios" }
        }
    },
    { $sort: { impresiones: -1 } }
]).toArray();
```

**Qué hace:** reparte las impresiones por estrategia y variante del experimento A/B.

**Observá:** este resultado tiene que ser **coherente** con el de
`recomendacion.vw_rendimiento_estrategias` en PostgreSQL. Son dos sistemas distintos midiendo
el mismo fenómeno; que coincidan es la prueba de que el pipeline no está perdiendo eventos por
el camino.

## Escritura y validación

**Objetivo:** comprobar que el validador rechaza lo que tiene que rechazar.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

// Caso válido.
practica.eventos_interaccion.insertOne({
    evento_id: "EV-PRUEBA-01",
    usuario_id: NumberInt(1),
    sesion_id: "S-000001-2026073110",
    contenido_id: NumberInt(1),
    tipo_evento: "vista",
    ocurrido_en: new Date(),
    contexto: { dispositivo: "movil", canal: "directo", pais: "AR", superficie: "home" },
    metricas: { segundos_visibles: NumberInt(45), porcentaje_scroll: 62.5 }
});
```

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

// Caso inválido: tipo_evento fuera del enum.
// Error esperado: código 121, DocumentValidationFailure.
practica.eventos_interaccion.insertOne({
    evento_id: "EV-PRUEBA-02",
    usuario_id: NumberInt(1),
    contenido_id: NumberInt(1),
    tipo_evento: "pestaneo",
    ocurrido_en: new Date()
});
```

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

// Caso inválido: falta contenido_id, que es obligatorio.
// Error esperado: código 121, DocumentValidationFailure.
practica.eventos_interaccion.insertOne({
    evento_id: "EV-PRUEBA-03",
    usuario_id: NumberInt(1),
    tipo_evento: "vista",
    ocurrido_en: new Date()
});
```

> **IMPORTANTE:** los dos últimos bloques **deben fallar**. Ese es el resultado esperado.
> El validador con `validationAction: "error"` es lo que impide que "esquema flexible" se
> convierta en "cualquier cosa entra".

Limpiar la prueba:

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
practica.eventos_interaccion.deleteMany({ evento_id: /^EV-PRUEBA-/ });
```

## Actualización de un documento embebido

**Objetivo:** ver el costo real de haber embebido las respuestas.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

const comentario = practica.comentarios.findOne({ "respuestas.0": { $exists: true } });

practica.comentarios.updateOne(
    { _id: comentario._id },
    {
        $push: {
            respuestas: {
                orden: NumberInt(comentario.respuestas.length + 1),
                usuario_id: NumberInt(7),
                texto: "Agrego un dato que falta.",
                creado_en: new Date()
            }
        }
    }
);

practica.comentarios.findOne({ _id: comentario._id });
```

**Observá:** agregar una respuesta reescribe el documento entero. Con dos o tres respuestas es
irrelevante; con doscientas empezaría a doler, y ahí el embebido dejaría de ser la decisión
correcta.

**Comparación con SQL:** en un modelo relacional sería un `INSERT` en `respuestas` sin tocar el
comentario. El intercambio es claro: MongoDB paga en la escritura lo que ahorra en la lectura.
Como los comentarios se leen mucho más de lo que se responden, el intercambio conviene.

Revertir:

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
practica.comentarios.updateMany({}, { $pull: { respuestas: { usuario_id: NumberInt(7),
                                                             texto: "Agrego un dato que falta." } } });
```
