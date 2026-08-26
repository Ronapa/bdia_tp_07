// Objetivo: crear un usuario separado para consultar el grafo y dejar documentado hasta donde llega Neo4j Community.
// Requiere / entradas: Neo4j en ejecucion, autenticado como administrador.
// Produce / modifica: el usuario bdia_grafo_consulta; NO produce un usuario de solo lectura.
// Resultado esperado: el usuario existe y su columna `roles` viene en NULL.
// Guia: la evidencia ejecutable de la limitacion esta en consultas/03_limitaciones_community.cypher.
// Seguridad: leer el punto 3 antes de asumir que este usuario esta acotado. NO lo esta.

// ============================================================
// IMPORTANTE: que se puede y que no en la edicion Community
//
// Neo4j Community Edition **no tiene control de acceso basado en roles**.
// Se pueden crear usuarios, y ahi termina: todos los usuarios tienen
// acceso completo a la base. No existe forma de crear un usuario de solo
// lectura, ni de restringir por etiqueta de nodo, tipo de relacion o
// propiedad.
//
// El control granular (roles, privilegios por etiqueta, seguridad a nivel
// de propiedad) es una funcion de la edicion Enterprise.
//
// Esto se comprobo contra el contenedor de este proyecto, y el punto 3 de
// este archivo lo deja demostrado. Se documenta como lo que es: una
// limitacion del motor elegido, no una omision del diseno.
//
// Comparacion con los otros motores del stack:
//
//   PostgreSQL -> permisos por tabla, por COLUMNA y por FILA (RLS)
//   MongoDB    -> permisos por accion y por coleccion; sin nivel de fila
//   Redis      -> permisos por comando y por patron de clave
//   Neo4j (CE) -> ninguno: usuario o nada
//
// Es parte del analisis de "ventajas y limitaciones frente a otras
// alternativas" que pide la consigna, y es la razon por la que el grafo
// de este sistema es una PROYECCION REGENERABLE que no contiene ningun
// dato personal mas alla del identificador de usuario. Si el grafo
// guardara correos o nombres, la eleccion de la Community Edition seria
// directamente inadmisible.
// ============================================================

// ============================================================
// 1. Usuario separado para consultas
//
// Sirve para lo que si se puede: que la aplicacion y las herramientas de
// consulta no usen la cuenta administrativa, y que revocar el acceso de
// una de ellas no obligue a rotar la contrasena de todo el sistema.
// ============================================================

DROP USER bdia_grafo_consulta IF EXISTS;

CREATE USER bdia_grafo_consulta
SET PASSWORD 'consulta_local'
SET PASSWORD CHANGE NOT REQUIRED;

SHOW USERS;

// Observar la columna `roles`: viene en NULL. En Enterprise mostraria el
// rol asignado; en Community no hay roles que mostrar.

// ============================================================
// 2. Lo que se haria en Enterprise
//
// Estas dos lineas son la solucion correcta y NO se ejecutan aca porque
// el motor las rechaza. Quedan como referencia de la alternativa:
//
//   GRANT ROLE reader TO bdia_grafo_consulta;
//   DENY READ {titulo} ON GRAPH neo4j NODES Contenido TO bdia_grafo_consulta;
//
// ============================================================

// ============================================================
// 3. La evidencia de la limitacion
//
// Esta en nosql/neo4j/consultas/03_limitaciones_community.cypher, que
// contiene un comando que DEBE fallar. Se mantiene aparte para que este
// archivo pueda correr dentro del pipeline con --fail-fast, igual que
// db/consultas/05_prueba_aislamiento.sql se mantiene fuera del pipeline
// por la misma razon.
// ============================================================
