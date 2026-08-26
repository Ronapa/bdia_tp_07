// Objetivo: definir el modelo de grafo antes de cargarlo: restricciones de unicidad e indices.
// Requiere / entradas: Neo4j en ejecucion y autenticado.
// Produce / modifica: constraints e indices; no crea nodos ni relaciones.
// Resultado esperado: cuatro restricciones de unicidad y tres indices secundarios.
// Guia: las restricciones se crean ANTES de la carga; ademas de garantizar unicidad, crean el
//       indice que hace que el MERGE de la carga sea O(log n) en lugar de un barrido completo.

// ============================================================
// Modelo de grafo
//
// Nodos:
//   (:Usuario   {usuario_id, pais, plan})
//   (:Contenido {contenido_id, titulo, seccion, seccion_raiz, tipo,
//                nivel_acceso, estado, fecha_publicacion})
//   (:Seccion   {slug, nombre, raiz})
//   (:Etiqueta  {slug, nombre})
//
// Relaciones:
//   (:Usuario)-[:VIO {veces, ultima_vez, completo}]->(:Contenido)
//   (:Usuario)-[:GUARDO]->(:Contenido)
//   (:Usuario)-[:NO_LE_INTERESA]->(:Seccion|:Etiqueta)
//   (:Usuario)-[:SIGUE]->(:Seccion)
//   (:Usuario)-[:ESCRIBIO]->(:Contenido)
//   (:Contenido)-[:PERTENECE_A]->(:Seccion)
//   (:Contenido)-[:TIENE_ETIQUETA]->(:Etiqueta)
//   (:Contenido)-[:SIMILAR_A {score, origen}]->(:Contenido)
//
// Por que un grafo y no mas SQL:
//
//   La consulta que justifica todo el motor es la co-visualizacion:
//   "otros lectores que leyeron esto tambien leyeron aquello". En SQL
//   es un self-join de la tabla de eventos consigo misma, y cada salto
//   adicional agrega otro self-join. A tres saltos la consulta deja de
//   ser legible y el planificador deja de encontrar un buen plan.
//
//   En Cypher, cada salto es una flecha mas en el patron. Y, sobre
//   todo, el grafo puede devolver el CAMINO recorrido, que es lo que
//   convierte una recomendacion en una recomendacion explicable:
//   "porque leiste X, igual que otras 14 personas que ademas leyeron Y".
//
//   La propiedad `estado` se duplica en el nodo Contenido a proposito.
//   Es desnormalizacion deliberada: sin ella, cada recorrido tendria
//   que volver a PostgreSQL para saber si el contenido se puede
//   mostrar, y eso anularia la ventaja del grafo. El precio es que el
//   grafo se reconstruye en cada corrida del pipeline.
// ============================================================

CREATE CONSTRAINT usuario_id_unico IF NOT EXISTS
FOR (u:Usuario) REQUIRE u.usuario_id IS UNIQUE;

CREATE CONSTRAINT contenido_id_unico IF NOT EXISTS
FOR (c:Contenido) REQUIRE c.contenido_id IS UNIQUE;

CREATE CONSTRAINT seccion_slug_unico IF NOT EXISTS
FOR (s:Seccion) REQUIRE s.slug IS UNIQUE;

CREATE CONSTRAINT etiqueta_slug_unico IF NOT EXISTS
FOR (e:Etiqueta) REQUIRE e.slug IS UNIQUE;

// ============================================================
// Indices secundarios
//
// Sostienen los filtros que aparecen en TODA consulta de recomendacion:
// solo se recomienda lo publicado, y casi siempre acotado por seccion o
// por nivel de acceso.
// ============================================================

CREATE INDEX contenido_estado IF NOT EXISTS
FOR (c:Contenido) ON (c.estado);

CREATE INDEX contenido_seccion IF NOT EXISTS
FOR (c:Contenido) ON (c.seccion_raiz);

CREATE INDEX contenido_acceso IF NOT EXISTS
FOR (c:Contenido) ON (c.nivel_acceso);

// Indice sobre una propiedad de RELACION: acelera filtrar las aristas de
// similitud por umbral de score, que es lo que hace la consulta hibrida.
CREATE INDEX similar_score IF NOT EXISTS
FOR ()-[r:SIMILAR_A]-() ON (r.score);

SHOW CONSTRAINTS;
