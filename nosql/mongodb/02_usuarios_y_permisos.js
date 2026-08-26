// ============================================================
// Script 02 - Crear los usuarios y roles de MongoDB con minimo privilegio.
// Objetivo: que ningun consumidor del clickstream use las credenciales root.
// Prerrequisito: 00_cargar_datos.js ejecutado (las colecciones tienen que existir).
// Produce: un rol propio por perfil de acceso y dos usuarios acotados a esos roles.
// Que observar: los bloques finales DEBEN fallar; el error es el resultado esperado.
// Advertencia: idempotente, pero recrea los roles y usuarios si ya existian.
// ============================================================

const nombreBase = process.env.MONGO_DATABASE || "bdia_nexomedia";
const practica = db.getSiblingDB(nombreBase);

// ============================================================
// Lo que MongoDB puede y lo que no
//
// MongoDB tiene control de acceso basado en roles, con permisos por
// ACCION y por COLECCION. Eso alcanza para separar perfiles de acceso.
//
// Lo que NO tiene es un equivalente al Row Level Security de PostgreSQL:
// no se puede decir "este usuario solo ve los documentos cuyo usuario_id
// sea el suyo". O ve la coleccion entera, o no la ve.
//
// Esa limitacion es una de las razones por las que los datos personales
// de este sistema viven en PostgreSQL y en MongoDB solo hay
// comportamiento referenciado por id. Esta declarada en el informe.
// ============================================================

// dropRole y dropUser lanzan excepcion si el objeto no existe, en lugar
// de devolver ok = false. Estos dos helpers hacen el script idempotente:
// se puede reejecutar sin que falle la primera vez ni las siguientes.
function borrarRolSiExiste(nombre) {
    try {
        practica.runCommand({ dropRole: nombre });
        print(`  Rol previo eliminado: ${nombre}`);
    } catch (error) {
        if (!/Could not find role/.test(error.message)) {
            throw error;
        }
    }
}

function borrarUsuarioSiExiste(nombre) {
    try {
        practica.runCommand({ dropUser: nombre });
        print(`  Usuario previo eliminado: ${nombre}`);
    } catch (error) {
        if (!/User.*not found|UserNotFound/.test(error.message)) {
            throw error;
        }
    }
}

print(`--- Creando roles y usuarios en ${nombreBase} ---`);

// ============================================================
// 1. Rol de lectura analitica
//
// Puede leer el clickstream, los cuerpos de contenido y las busquedas.
//
// NO puede leer `comentarios`, y es a proposito: es la unica coleccion
// con texto libre escrito por personas, donde alguien puede haber
// dejado un dato personal que ningun esquema previo controla.
//
// Tampoco puede leer telemetria_reproduccion: es volumen puro sin valor
// analitico directo, y su lectura completa afectaria al motor.
// ============================================================

borrarRolSiExiste("rol_lectura_analitica");

practica.runCommand({
    createRole: "rol_lectura_analitica",
    privileges: [
        {
            resource: { db: nombreBase, collection: "eventos_interaccion" },
            actions: ["find"]
        },
        {
            resource: { db: nombreBase, collection: "cuerpos_contenido" },
            actions: ["find"]
        },
        {
            resource: { db: nombreBase, collection: "busquedas" },
            actions: ["find"]
        }
    ],
    roles: []
});

// ============================================================
// 2. Rol de ingesta
//
// Puede insertar y actualizar eventos, y nada mas. NO puede leerlos y NO
// puede borrarlos.
//
// Por que tambien `update` y no solo `insert`: el consumidor escribe con
// upsert sobre evento_id para ser idempotente, y un upsert que encuentra
// el documento ejecuta una actualizacion. Sin esa accion, el reintento de
// un evento ya persistido fallaria por permisos, no por duplicado.
//
// Lo que importa se conserva: es el perfil del consumidor del stream de
// Redis (orquestador/consumir_stream.py), el componente mas expuesto del
// sistema porque escucha trafico entrante. Si quedara comprometido, no
// serviria para exfiltrar el historial de nadie, porque **no puede leer**.
// ============================================================

borrarRolSiExiste("rol_ingesta_eventos");

practica.runCommand({
    createRole: "rol_ingesta_eventos",
    privileges: [
        {
            resource: { db: nombreBase, collection: "eventos_interaccion" },
            actions: ["insert", "update"]
        }
    ],
    roles: []
});

// ============================================================
// 3. Usuarios
// ============================================================

borrarUsuarioSiExiste("bdia_mongo_lectura");
borrarUsuarioSiExiste("bdia_mongo_ingesta");

practica.runCommand({
    createUser: "bdia_mongo_lectura",
    pwd: "lectura_local",
    roles: [{ role: "rol_lectura_analitica", db: nombreBase }]
});

practica.runCommand({
    createUser: "bdia_mongo_ingesta",
    pwd: "ingesta_local",
    roles: [{ role: "rol_ingesta_eventos", db: nombreBase }]
});

print("  Usuarios creados: bdia_mongo_lectura, bdia_mongo_ingesta");

// ============================================================
// 4. Verificacion
// ============================================================

print("");
const usuarios = practica.getUsers().users;
usuarios.forEach((u) => {
    const roles = u.roles.map((r) => r.role).join(", ");
    print(`${u.user.padEnd(24)} ${roles}`);
});

const esperados = ["bdia_mongo_lectura", "bdia_mongo_ingesta"];
esperados.forEach((nombre) => {
    if (!usuarios.some((u) => u.user === nombre)) {
        throw new Error(`Falta el usuario ${nombre} en la base ${nombreBase}`);
    }
});

print("\nRoles y usuarios creados y verificados.");
print("");
print("Para comprobar los limites, abrir una sesion con el usuario restringido:");
print("");
print(`  docker compose exec mongodb-eventos mongosh \\`);
print(`    -u bdia_mongo_lectura -p lectura_local \\`);
print(`    --authenticationDatabase ${nombreBase} ${nombreBase}`);
print("");
print("y ejecutar los bloques de nosql/mongodb/consultas/05_permisos.md,");
print("donde tres de ellos DEBEN fallar.");
