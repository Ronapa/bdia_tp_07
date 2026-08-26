// Objetivo: demostrar, con un comando que falla, que Neo4j Community no tiene control de acceso por roles.
// Requiere / entradas: usuario creado por nosql/neo4j/01_usuarios.cypher.
// Produce / modifica: nada; solo lee y falla donde tiene que fallar.
// Resultado esperado: SHOW USERS funciona con roles en NULL; SHOW ROLES falla.
// Guia: ejecutar en el Neo4j Browser, bloque por bloque. NO se incluye en el pipeline porque aborta.

// ============================================================
// IMPORTANTE
//
// El segundo bloque de este archivo DEBE fallar. Ese es el objetivo:
// una limitacion que se afirma sin comprobarla es una suposicion.
// ============================================================

// ============================================================
// 1. Los usuarios existen, pero no tienen roles
// ============================================================

SHOW USERS;

// Observar la columna `roles`: viene en NULL para todos los usuarios,
// incluido neo4j. No es que esten sin asignar: es que en la edicion
// Community el concepto de rol no existe.
//
// Consecuencia directa: bdia_grafo_consulta tiene EXACTAMENTE los mismos
// privilegios que el administrador. Un usuario separado sirve para rotar
// credenciales de forma independiente, y para nada mas.

// ============================================================
// 2. El comando que DEBE fallar
//
// Error esperado:
//   Unsupported administration command: SHOW ROLES
// ============================================================

SHOW ROLES;

// ============================================================
// 3. Lo que se haria en Enterprise
//
// Estas tres lineas tambien fallan en Community, y son la solucion
// correcta cuando el motor la soporta:
//
//   CREATE ROLE lector_grafo;
//   GRANT MATCH {*} ON GRAPH neo4j NODES Contenido TO lector_grafo;
//   DENY READ {titulo} ON GRAPH neo4j NODES Contenido TO lector_grafo;
//
// Enterprise permite ademas seguridad a nivel de PROPIEDAD, que es mas
// fino que lo que ofrece MongoDB y comparable al GRANT por columna de
// PostgreSQL.
// ============================================================

// ============================================================
// 4. Como se compensa en este diseno
//
// Comprobar que el grafo no contiene ningun dato personal directo:
// ============================================================

MATCH (u:Usuario)
RETURN keys(u) AS propiedades_del_nodo_usuario
LIMIT 1;

// Devuelve usuario_id, pais y plan. Ni correo, ni alias, ni fecha de
// nacimiento: quien lea el grafo entero no obtiene un solo identificador
// directo de persona.
//
// Esa es la mitigacion real: como el motor no puede restringir el
// acceso, se restringe el DATO. Si el grafo guardara correos, elegir la
// edicion Community seria inadmisible.
