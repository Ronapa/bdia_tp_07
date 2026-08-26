# 01. Recorrer el modelo documental

Abrí el shell de MongoDB (`docker compose exec mongodb-eventos mongosh -u bdia_admin -p ...`)
o MongoDB Compass y ejecutá cada bloque por separado. Todos trabajan sobre `bdia_nexomedia`.

El objetivo de esta primera serie es ver **por qué** estos datos están en MongoDB y no en
PostgreSQL, mirando los documentos reales en lugar de discutirlo en abstracto.

## Un cuerpo de contenido completo

**Objetivo:** ver el documento que reemplaza a lo que en un modelo relacional serían tres
o cuatro tablas.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.cuerpos_contenido.findOne({ formato: "articulo" });
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `getSiblingDB(...)` | Devuelve una referencia a otra base | Hace el bloque autocontenido: se puede copiar y pegar sin `use` previo |
| `findOne(filtro)` | Devuelve el primer documento que coincide | Alcanza para inspeccionar la forma del documento |

**Qué hace:** trae un cuerpo con su array `bloques`.

**Observá:** los elementos de `bloques` **no comparten esquema**. Un `parrafo` tiene `texto`,
una `cita` agrega `autor` y `cargo`, una `imagen` tiene `url`, `epigrafe` y `credito`. El
orden de lectura está en el campo `orden`, dentro del propio array.

**Comparación con SQL:** el equivalente relacional necesitaría `bloques_parrafo`,
`bloques_cita` y `bloques_imagen` (o una tabla genérica con la mitad de las columnas en
`NULL`), más un `UNION ALL` y un `ORDER BY` para reconstruir el artículo. Acá es un `findOne`.

## Cómo cambia el documento según el tipo de contenido

**Objetivo:** comprobar que el esquema variable es real y no una posibilidad teórica.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.cuerpos_contenido.aggregate([
    {
        $group: {
            _id: "$formato",
            documentos: { $sum: 1 },
            con_transcripcion: { $sum: { $cond: [{ $isArray: "$transcripcion" }, 1, 0] } },
            con_fotos: { $sum: { $cond: [{ $isArray: "$fotos" }, 1, 0] } },
            promedio_bloques: { $avg: { $size: "$bloques" } }
        }
    },
    { $sort: { documentos: -1 } }
]).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `$group` | Agrupa documentos por una expresión | Agrupa por formato de contenido |
| `$cond` | Condicional dentro de una expresión | Cuenta solo los documentos que tienen el campo |
| `$isArray` | Verifica que un campo sea un array | Detecta la presencia de campos opcionales |
| `$size` | Longitud de un array | Promedia la cantidad de bloques |

**Qué hace:** cuenta, por formato, cuántos documentos traen `transcripcion` y cuántos `fotos`.

**Observá:** `transcripcion` aparece solo en `video` y `podcast`; `fotos`, solo en `galeria`.
Ningún documento tiene los dos campos, y ninguno los tiene vacíos "por las dudas". En una
tabla, esas dos columnas estarían en `NULL` en el 80% de las filas.

## Un evento del clickstream, por tipo

**Objetivo:** ver el mismo fenómeno en la colección de mayor volumen.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

["vista", "reproduccion", "impresion", "me_gusta"].forEach((tipo) => {
    print(`\n=== ${tipo} ===`);
    printjson(practica.eventos_interaccion.findOne({ tipo_evento: tipo }));
});
```

**Qué hace:** imprime un evento de cada tipo.

**Observá:** los cuatro comparten el contrato mínimo (`usuario_id`, `contenido_id`,
`tipo_evento`, `ocurrido_en`, `contexto`) y difieren en el resto: `vista` trae
`metricas.porcentaje_scroll`, `reproduccion` trae `metricas.porcentaje_reproducido`,
`impresion` trae `origen_recomendacion` y `me_gusta` no trae ninguno de los tres.

Ese contrato mínimo es exactamente lo que exige el `$jsonSchema` del validador
(`nosql/mongodb/00_cargar_datos.js`). Lo variable queda libre a propósito: si el validador
enumerara todos los campos posibles, agregar un tipo de evento nuevo sería una migración.

## Consultar por notación de punto dentro de un subdocumento

**Objetivo:** filtrar por un campo anidado sin desarmar el documento.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.eventos_interaccion.find(
    {
        "contexto.dispositivo": "movil",
        "contexto.canal": "redes",
        "metricas.porcentaje_scroll": { $gte: 80 }
    },
    { evento_id: 1, usuario_id: 1, contenido_id: 1, "metricas.porcentaje_scroll": 1, _id: 0 }
).limit(5).toArray();
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza en esta consulta |
|---|---|---|
| `"a.b"` | Notación de punto | Filtra dentro de subdocumentos sin `$unwind` |
| `$gte` | Mayor o igual | Selecciona lecturas profundas |
| Proyección `{campo: 1}` | Limita las claves devueltas | Reduce el tráfico y hace legible la salida |

**Qué hace:** busca lecturas profundas desde redes sociales en móvil.

**Observá:** la condición sobre `metricas.porcentaje_scroll` descarta automáticamente los
eventos que no tienen `metricas`: un campo ausente no matchea. En SQL habría que agregar
`AND porcentaje_scroll IS NOT NULL`.

## Verificar la integridad referencial que MongoDB no impone

**Objetivo:** dejar explícito el precio de no tener claves foráneas.

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");

practica.comentarios.aggregate([
    {
        $lookup: {
            from: "cuerpos_contenido",
            localField: "contenido_id",
            foreignField: "contenido_id",
            as: "cuerpo"
        }
    },
    { $match: { cuerpo: { $size: 0 } } },
    { $count: "comentarios_huerfanos" }
]).toArray();
```

**Qué hace:** busca comentarios que apuntan a un contenido inexistente.

**Observá:** debe devolver un array vacío. MongoDB **no impide** insertar ese comentario:
la única razón por la que no hay huérfanos es que el pipeline lo verifica y aborta
(`00_cargar_datos.js` lanza `throw` si aparece alguno).

Esta es la contrapartida honesta del modelo documental, y el motivo por el cual el catálogo
y las personas viven en PostgreSQL: ahí la integridad la garantiza el motor, no la disciplina
del equipo.
