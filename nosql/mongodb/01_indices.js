// ============================================================
// Script 01 - Crear los indices del modelo documental.
// Objetivo: sostener los patrones de consulta del clickstream y aplicar la retencion.
// Prerrequisito: 00_cargar_datos.js y orquestador/cargar_mongo.py ya ejecutados.
// Produce: indices compuestos, multikey, parcial, de texto y TTL.
// Que observar: los indices se crean DESPUES de la carga; construirlos antes encarece cada insert.
// Advertencia: el indice TTL borra datos de forma automatica y permanente.
// ============================================================

const nombreBase = process.env.MONGO_DATABASE || "bdia_nexomedia";
const practica = db.getSiblingDB(nombreBase);

// ============================================================
// Politica de retencion
//
// En produccion, el clickstream crudo se conserva 90 dias:
//
//     const RETENCION_PRODUCCION = 60 * 60 * 24 * 90;
//
// En este proyecto ese valor NO se puede usar, y el motivo es concreto:
// el dataset sintetico cubre una ventana fija (abril a julio de 2026),
// asi que el reaper del TTL empieza a borrarlo apenas la fecha real del
// sistema supera esa ventana en 90 dias: de los 113.341 eventos cargados
// sobreviven unos 82.800, y el numero baja cada dia que pasa.
//
// Eso rompe la propiedad que sostiene todas las verificaciones del
// pipeline: que la misma semilla produce siempre los mismos conteos.
//
// El indice TTL se crea igual, porque el mecanismo es lo que se quiere
// demostrar; lo que se ajusta es el valor. Para ver el borrado en accion,
// bajar RETENCION_SEGUNDOS y esperar a que corra el reaper (cada 60 s).
// ============================================================

const RETENCION_SEGUNDOS = 60 * 60 * 24 * 3650; // 10 anios (produccion: 90 dias)

print(`--- Creando indices en ${nombreBase} ---`);

// ============================================================
// 1. eventos_interaccion
// ============================================================

// Patron: "el historial reciente de este usuario".
// Es la consulta del feature store y la del panel de soporte.
// El orden importa: usuario_id para filtrar, ocurrido_en descendente
// para que el LIMIT salga del indice sin ordenar despues.
practica.eventos_interaccion.createIndex(
    { usuario_id: 1, ocurrido_en: -1 },
    { name: "idx_usuario_fecha" }
);

// Patron: "todo lo que paso con este contenido en una ventana".
// Es la consulta que alimenta las metricas de consumo.
practica.eventos_interaccion.createIndex(
    { contenido_id: 1, ocurrido_en: -1 },
    { name: "idx_contenido_fecha" }
);

// Patron: reconstruir una sesion completa en orden.
practica.eventos_interaccion.createIndex(
    { sesion_id: 1, ocurrido_en: 1 },
    { name: "idx_sesion_orden" }
);

// Indice PARCIAL sobre la atribucion de recomendaciones.
// Solo los eventos de tipo 'impresion' traen origen_recomendacion:
// indexar la coleccion entera guardaria una entrada nula por cada
// evento que no es impresion. El parcial indexa el 30% de la coleccion
// y responde igual la consulta de atribucion.
practica.eventos_interaccion.createIndex(
    { "origen_recomendacion.estrategia": 1, ocurrido_en: -1 },
    {
        name: "idx_atribucion_estrategia",
        partialFilterExpression: { tipo_evento: "impresion" }
    }
);

// Indice UNICO sobre evento_id.
//
// Es lo que hace posible una ingesta idempotente. El consumidor del
// stream (orquestador/consumir_stream.py) garantiza entrega "al menos una
// vez": si el proceso cae entre la escritura en MongoDB y el XACK, el
// mensaje vuelve a entregarse y el evento se procesa dos veces.
//
// Sin este indice, el reintento insertaria un duplicado EN SILENCIO y las
// metricas quedarian infladas sin que nada lo denunciara. Con el indice,
// el reintento choca, el consumidor lo trata como exito y confirma: el
// resultado neto es exactamente una copia.
//
// Es la diferencia entre "al menos una vez" a secas y "al menos una vez
// mas deduplicacion", que en la practica equivale a exactamente una vez.
practica.eventos_interaccion.createIndex(
    { evento_id: 1 },
    { name: "idx_evento_id_unico", unique: true }
);

// Indice TTL: politica de retencion de datos personales de comportamiento.
// MongoDB borra solo los eventos con mas de 90 dias. Es la contracara
// tecnica del principio de minimizacion: el dato crudo no se conserva
// indefinidamente, porque el valor analitico ya quedo agregado en la
// capa Gold del lakehouse.
//
// El valor de RETENCION_SEGUNDOS esta subido a proposito para que el
// dataset sintetico no se borre solo; ver la nota al principio de este
// archivo. El mecanismo es el mismo que se usaria en produccion con 90 dias.
practica.eventos_interaccion.createIndex(
    { ocurrido_en: 1 },
    { name: "idx_ttl_retencion", expireAfterSeconds: RETENCION_SEGUNDOS }
);

// ============================================================
// 2. cuerpos_contenido
// ============================================================

practica.cuerpos_contenido.createIndex(
    { contenido_id: 1 },
    { name: "idx_contenido_id", unique: true }
);

// Indice MULTIKEY sobre el array de bloques: permite responder
// "que contenidos incluyen al menos una cita" sin recorrer todo.
// MongoDB indexa una entrada por elemento del array; es lo que hace
// que un campo repetido dentro de un documento siga siendo consultable.
practica.cuerpos_contenido.createIndex(
    { "bloques.tipo": 1 },
    { name: "idx_bloques_tipo" }
);

// Indice de TEXTO sobre el cuerpo: es la busqueda literal dentro del
// contenido. Convive con la busqueda vectorial de PostgreSQL, no la
// reemplaza: una encuentra la palabra exacta, la otra el significado.
practica.cuerpos_contenido.createIndex(
    { "bloques.texto": "text" },
    { name: "idx_texto_bloques", default_language: "spanish" }
);

// ============================================================
// 3. comentarios
// ============================================================

practica.comentarios.createIndex(
    { contenido_id: 1, creado_en: -1 },
    { name: "idx_contenido_fecha" }
);

// La bandeja del moderador solo mira lo pendiente: indice parcial.
practica.comentarios.createIndex(
    { creado_en: 1 },
    {
        name: "idx_pendientes_moderacion",
        partialFilterExpression: { estado_moderacion: "pendiente" }
    }
);

// Multikey sobre el array embebido de respuestas.
practica.comentarios.createIndex(
    { "respuestas.usuario_id": 1 },
    { name: "idx_respuestas_usuario" }
);

// ============================================================
// 4. busquedas
// ============================================================

practica.busquedas.createIndex({ texto: 1, ocurrido_en: -1 }, { name: "idx_texto_fecha" });
practica.busquedas.createIndex({ usuario_id: 1, ocurrido_en: -1 }, { name: "idx_usuario_fecha" });
// Multikey sobre el array de resultados: "en que busquedas aparecio este contenido".
practica.busquedas.createIndex({ resultados: 1 }, { name: "idx_resultados" });

// ============================================================
// 5. Verificacion
// ============================================================

print("");
["eventos_interaccion", "cuerpos_contenido", "comentarios", "busquedas",
 "telemetria_reproduccion"].forEach((coleccion) => {
    const indices = practica.getCollection(coleccion).getIndexes();
    print(`${coleccion.padEnd(28)} ${indices.length} indices`);
    indices.forEach((indice) => print(`    ${indice.name}`));
});

// El indice TTL es el unico que borra datos: si no existe, la politica
// de retencion no se esta aplicando y eso debe fallar ruidosamente.
const tieneTtl = practica.eventos_interaccion
    .getIndexes()
    .some((indice) => indice.expireAfterSeconds !== undefined);

if (!tieneTtl) {
    throw new Error("Falta el indice TTL de retencion sobre eventos_interaccion");
}

print("\nIndices creados y verificados.");
