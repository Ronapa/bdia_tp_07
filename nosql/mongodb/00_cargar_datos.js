// ============================================================
// Script 00 - Crear el modelo documental y cargar las colecciones de documentos.
// Objetivo: definir colecciones, validadores y la coleccion timeseries, y cargar
//           cuerpos de contenido, comentarios y busquedas.
// Prerrequisito: orquestador/generar_datos.py ejecutado; data/ montado en /data/practica.
// Produce: base MONGO_DATABASE con cinco colecciones; el clickstream lo carga cargar_mongo.py.
// Que observar: los validadores rechazan documentos mal formados, no los aceptan en silencio.
// Advertencia: DESTRUCTIVO; elimina y recrea unicamente la base MONGO_DATABASE.
// ============================================================

const fs = require("fs");

const nombreBase = process.env.MONGO_DATABASE || "bdia_nexomedia";
const practica = db.getSiblingDB(nombreBase);
const rutaDatos = "/data/practica/generado/mongo";

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

function leerJson(nombre) {
    const ruta = `${rutaDatos}/${nombre}.json`;
    if (!fs.existsSync(ruta)) {
        throw new Error(`No se encontro ${ruta}. Correr primero orquestador/generar_datos.py`);
    }
    return JSON.parse(fs.readFileSync(ruta, "utf8"));
}

function aFecha(documento, campos) {
    campos.forEach((campo) => {
        if (documento[campo]) {
            documento[campo] = new Date(documento[campo]);
        }
    });
    return documento;
}

print(`--- Reconstruyendo la base ${nombreBase} ---`);
practica.dropDatabase();

// ============================================================
// 1. cuerpos_contenido
//
// El caso testigo del modelo documental. Cada cuerpo tiene un array
// `bloques` cuyos elementos NO comparten esquema: un parrafo tiene
// texto, una cita tiene texto/autor/cargo, una imagen tiene url/epigrafe.
// Ademas los videos y podcasts suman `transcripcion` y las galerias
// suman `fotos`.
//
// En un modelo relacional esto exigiria una tabla por tipo de bloque
// (o una tabla generica con columnas nullables) y un JOIN + ORDER BY
// para reconstruir algo que aca se lee con un unico findOne.
//
// Los bloques van EMBEBIDOS y no referenciados porque:
//   - siempre se leen junto al cuerpo, nunca por separado;
//   - la cantidad esta acotada (unidades, no miles);
//   - se reemplazan en conjunto cuando el editor guarda.
// Los tres criterios del embebido se cumplen a la vez.
//
// contenido_id queda como REFERENCIA a PostgreSQL, que es el sistema
// de registro del catalogo. Duplicar aca el titulo o el estado crearia
// dos fuentes de verdad para el mismo dato.
// ============================================================

practica.createCollection("cuerpos_contenido", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["_id", "contenido_id", "formato", "bloques"],
            properties: {
                _id: { bsonType: "string", description: "Igual a catalogo.contenidos.cuerpo_ref" },
                contenido_id: { bsonType: "int", description: "FK logica a PostgreSQL" },
                formato: { enum: ["articulo", "video", "podcast", "newsletter", "galeria"] },
                idioma: { bsonType: "string" },
                palabras: { bsonType: "int", minimum: 0 },
                bloques: {
                    bsonType: "array",
                    minItems: 1,
                    items: {
                        bsonType: "object",
                        required: ["orden", "tipo"],
                        properties: {
                            orden: { bsonType: "int", minimum: 1 },
                            tipo: { enum: ["parrafo", "cita", "imagen", "lista", "video"] }
                        }
                    }
                }
            }
        }
    },
    validationLevel: "strict",
    validationAction: "error"
});

const cuerpos = leerJson("cuerpos_contenido").map((documento) => {
    documento.contenido_id = NumberInt(documento.contenido_id);
    documento.palabras = NumberInt(documento.palabras);
    documento.bloques = documento.bloques.map((bloque) => {
        bloque.orden = NumberInt(bloque.orden);
        return bloque;
    });
    return documento;
});
practica.cuerpos_contenido.insertMany(cuerpos);

// ============================================================
// 2. comentarios
//
// Las respuestas van embebidas por el mismo criterio que los bloques.
// El limite del embebido queda declarado: si un comentario pudiera
// juntar cientos de respuestas, o si hubiera que rankear respuestas de
// forma global (las mas votadas del sitio), convendria referenciarlas
// en su propia coleccion. El criterio es el patron de acceso.
//
// estado_moderacion vive aca y la ACCION de moderacion vive en
// catalogo.moderaciones de PostgreSQL: el estado actual es del documento,
// la traza de quien decidio que cosa es del sistema transaccional.
// ============================================================

practica.createCollection("comentarios", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["_id", "contenido_id", "usuario_id", "texto", "estado_moderacion"],
            properties: {
                contenido_id: { bsonType: "int" },
                usuario_id: { bsonType: "int" },
                texto: { bsonType: "string", minLength: 1 },
                estado_moderacion: { enum: ["aprobado", "pendiente", "rechazado"] },
                respuestas: { bsonType: "array" }
            }
        }
    },
    validationLevel: "strict",
    validationAction: "error"
});

const comentarios = leerJson("comentarios").map((documento) => {
    documento.contenido_id = NumberInt(documento.contenido_id);
    documento.usuario_id = NumberInt(documento.usuario_id);
    documento.respuestas = (documento.respuestas || []).map((respuesta) => {
        respuesta.usuario_id = NumberInt(respuesta.usuario_id);
        respuesta.orden = NumberInt(respuesta.orden);
        return aFecha(respuesta, ["creado_en"]);
    });
    return aFecha(documento, ["creado_en"]);
});
practica.comentarios.insertMany(comentarios);

// ============================================================
// 3. busquedas
//
// Documento con arrays de ids y un subdocumento de filtros con claves
// opcionales. Es semiestructurado por naturaleza: los filtros que
// ofrece el buscador cambian cada vez que el producto agrega una faceta.
// ============================================================

practica.createCollection("busquedas");

const busquedas = leerJson("busquedas").map((documento) => {
    documento.usuario_id = NumberInt(documento.usuario_id);
    documento.resultados = documento.resultados.map((id) => NumberInt(id));
    documento.clics = (documento.clics || []).map((id) => NumberInt(id));
    return aFecha(documento, ["ocurrido_en"]);
});
practica.busquedas.insertMany(busquedas);

// ============================================================
// 4. eventos_interaccion  (la carga masiva la hace cargar_mongo.py)
//
// Se crea aca con su validador para que el esquema quede documentado
// en un solo lugar. El validador es deliberadamente PERMISIVO en el
// cuerpo del evento: exige lo que toda lectura necesita (usuario,
// contenido, tipo y momento) y deja libres los subdocumentos `metricas`
// y `origen_recomendacion`, que existen o no segun el tipo de evento.
//
// Ese es el equilibrio del modelo documental: validar el contrato
// minimo sin congelar la parte que cambia. Un esquema relacional
// tendria que elegir entre columnas nullables o una tabla por tipo.
// ============================================================

practica.createCollection("eventos_interaccion", {
    validator: {
        $jsonSchema: {
            bsonType: "object",
            required: ["evento_id", "usuario_id", "contenido_id", "tipo_evento", "ocurrido_en"],
            properties: {
                evento_id: { bsonType: "string" },
                usuario_id: { bsonType: "int" },
                contenido_id: { bsonType: "int" },
                tipo_evento: {
                    enum: ["impresion", "vista", "scroll", "clic", "reproduccion",
                           "completado", "guardado", "compartido", "me_gusta", "no_me_interesa"]
                },
                ocurrido_en: { bsonType: "date" },
                contexto: { bsonType: "object" },
                metricas: { bsonType: "object" },
                origen_recomendacion: { bsonType: "object" }
            }
        }
    },
    validationLevel: "strict",
    validationAction: "error"
});

// ============================================================
// 5. telemetria_reproduccion  (coleccion TIMESERIES)
//
// Latidos del reproductor de video y podcast: una medicion cada pocos
// segundos, por usuario y por contenido.
//
// Va a una coleccion timeseries y no a una normal porque cumple el
// perfil exacto para el que MongoDB la disenó:
//   - solo se inserta, nunca se actualiza ni se borra fila a fila;
//   - siempre se consulta por rango de tiempo;
//   - los metadatos (contenido, usuario, dispositivo) se repiten mucho.
//
// MongoDB agrupa internamente las mediciones por metaField y ventana
// temporal, con lo que el almacenamiento cae de forma notoria frente a
// un documento por medicion.
//
// La contrapartida, que hay que aceptar: no admite updates ni deletes
// individuales, ni indices unicos. Por eso la telemetria vive aca y el
// clickstream de negocio vive en una coleccion comun.
//
// expireAfterSeconds implementa la politica de retencion de 90 dias sin
// ningun proceso de limpieza propio.
// ============================================================

practica.createCollection("telemetria_reproduccion", {
    timeseries: {
        timeField: "ocurrido_en",
        metaField: "origen",
        granularity: "seconds"
    },
    expireAfterSeconds: RETENCION_SEGUNDOS
});

// ============================================================
// 6. Verificacion
//
// Los conteos salen del resumen que escribio el generador, no de
// constantes copiadas a mano: si cambia la escala, la verificacion
// sigue siendo valida.
// ============================================================

const resumen = JSON.parse(fs.readFileSync("/data/practica/generado/resumen.json", "utf8"));
const esperados = {
    cuerpos_contenido: resumen.conteos.cuerpos_contenido,
    comentarios: resumen.conteos.comentarios,
    busquedas: resumen.conteos.busquedas
};

print("");
Object.entries(esperados).forEach(([coleccion, esperado]) => {
    const real = practica.getCollection(coleccion).countDocuments();
    if (real !== esperado) {
        throw new Error(`${coleccion}: se esperaban ${esperado} documentos y se cargaron ${real}`);
    }
    print(`${coleccion.padEnd(28)} ${real}`);
});

// Integridad referencial documental: ningun comentario puede apuntar a
// un contenido que no tiene cuerpo cargado. MongoDB no impone foraneas,
// asi que la verificacion es explicita y forma parte del pipeline.
const huerfanos = practica.comentarios.aggregate([
    {
        $lookup: {
            from: "cuerpos_contenido",
            localField: "contenido_id",
            foreignField: "contenido_id",
            as: "cuerpo"
        }
    },
    { $match: { cuerpo: { $size: 0 } } },
    { $count: "cantidad" }
]).toArray();

if (huerfanos.length > 0) {
    throw new Error(`Hay ${huerfanos[0].cantidad} comentarios sin cuerpo de contenido asociado`);
}

print(`\nModelo documental creado y verificado en la base ${nombreBase}.`);
print("Siguiente paso: orquestador/cargar_mongo.py (clickstream y telemetria).");
