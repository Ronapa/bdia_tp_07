// Objetivo: recomendar por co-visualizacion, que es la consulta que justifica usar un grafo.
// Requiere / entradas: grafo cargado por orquestador/cargar_neo4j.py.
// Produce / modifica: nada; solo lee.
// Resultado esperado: contenidos recomendados con la cantidad de lectores que los conectan.
// Guia: ejecutar bloque por bloque en el Neo4j Browser (http://127.0.0.1:7476).

// ============================================================
// Consulta 1: "Otros lectores que leyeron esto tambien leyeron"
//
// Pregunta de negocio: que le recomendamos a un usuario a partir de lo
// que hicieron lectores parecidos, sin necesitar ningun modelo entrenado.
//
// El recorrido es de dos saltos:
//   usuario -> contenido que vio <- otro usuario -> contenido que ese otro vio
//
// En SQL serian dos self-joins de la tabla de eventos y una NOT EXISTS.
// Aca es una sola linea de patron, y agregar un tercer salto es agregar
// una flecha mas.
//
// Los tres filtros del WHERE no son cosmetica:
//   estado = 'publicado'   -> no recomendar borradores
//   nivel_acceso <= $plan  -> no recomendar lo que el usuario no puede leer
//   NOT (u)-[:VIO]->(rec)  -> no recomendar lo que ya leyo
// ============================================================

// Los parametros se declaran una vez y valen para todo el archivo.
:param nivel => 1;
:param usuario => 1;

MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(comun:Contenido)<-[:VIO]-(otro:Usuario)
MATCH (otro)-[v:VIO]->(recomendado:Contenido)
WHERE recomendado.estado = 'publicado'
  AND recomendado.nivel_acceso <= $nivel
  AND NOT EXISTS { (u)-[:VIO]->(recomendado) }
  AND NOT EXISTS { (u)-[:NO_LE_INTERESA]->(:Seccion)<-[:PERTENECE_A]-(recomendado) }
  AND otro <> u
RETURN
    recomendado.contenido_id AS contenido_id,
    recomendado.titulo       AS titulo,
    recomendado.seccion      AS seccion,
    count(DISTINCT otro)     AS lectores_en_comun,
    sum(v.veces)             AS intensidad
ORDER BY lectores_en_comun DESC, intensidad DESC
LIMIT 10;

// ============================================================
// Consulta 2: Co-visualizacion ponderada
//
// Pregunta de negocio: los lectores que comparten UN contenido con vos
// no valen lo mismo que los que comparten diez.
//
// La primera version cuenta lectores en comun sin mirar cuanto se
// parecen. Esta pondera cada vecino por su solapamiento total, que es
// una aproximacion barata al filtrado colaborativo basado en usuarios.
// ============================================================

MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(:Contenido)<-[:VIO]-(otro:Usuario)
WHERE otro <> u
WITH u, otro, count(*) AS solapamiento
WHERE solapamiento >= 2
MATCH (otro)-[:VIO]->(recomendado:Contenido)
WHERE recomendado.estado = 'publicado'
  AND recomendado.nivel_acceso <= $nivel
  AND NOT EXISTS { (u)-[:VIO]->(recomendado) }
WITH recomendado, sum(solapamiento) AS score, count(DISTINCT otro) AS vecinos
RETURN
    recomendado.contenido_id AS contenido_id,
    recomendado.titulo       AS titulo,
    recomendado.seccion      AS seccion,
    score,
    vecinos
ORDER BY score DESC
LIMIT 10;

// ============================================================
// Consulta 3: Mezcla de grafo y similitud semantica
//
// Pregunta de negocio: como combinamos "otros lo leyeron" con
// "trata de lo mismo".
//
// Las aristas SIMILAR_A vienen de pgvector: se calcularon en PostgreSQL
// y se proyectaron al grafo. Que las dos senales convivan como aristas
// del mismo grafo es lo que permite mezclarlas en una sola consulta,
// en lugar de resolver dos rankings y unirlos en la aplicacion.
// ============================================================

MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(visto:Contenido)
WITH u, collect(DISTINCT visto) AS historial, collect(DISTINCT visto.contenido_id) AS ids_vistos

CALL (u, historial) {
    MATCH (u)-[:VIO]->(:Contenido)<-[:VIO]-(otro:Usuario)-[:VIO]->(c:Contenido)
    WHERE c.estado = 'publicado' AND NOT c IN historial
    RETURN c AS candidato, count(DISTINCT otro) * 1.0 AS grafo, 0.0 AS semantica
    UNION
    MATCH (v:Contenido)-[s:SIMILAR_A]->(c:Contenido)
    WHERE v IN historial AND c.estado = 'publicado' AND NOT c IN historial
      AND s.score > 0.90
    RETURN c AS candidato, 0.0 AS grafo, sum(s.score) AS semantica
}
WITH candidato, sum(grafo) AS grafo, sum(semantica) AS semantica
WHERE candidato.nivel_acceso <= $nivel
RETURN
    candidato.contenido_id AS contenido_id,
    candidato.titulo       AS titulo,
    candidato.seccion      AS seccion,
    round(grafo, 2)        AS senal_grafo,
    round(semantica, 2)    AS senal_semantica,
    round(0.6 * grafo + 0.4 * semantica, 3) AS score_hibrido
ORDER BY score_hibrido DESC
LIMIT 10;

// ============================================================
// Consulta 4: Cold start del contenido
//
// Pregunta de negocio: como recomendamos una nota publicada hace una
// hora, que todavia nadie leyo.
//
// El filtrado colaborativo no puede: sin lectores, no hay aristas VIO y
// el contenido es invisible. El grafo si puede, apoyandose en las
// aristas de contenido (etiquetas y similitud), que existen desde el
// momento de la publicacion.
//
// Es el argumento concreto por el que la estrategia hibrida existe:
// cada senal tapa el agujero de la otra.
// ============================================================

MATCH (nuevo:Contenido)
WHERE nuevo.estado = 'publicado'
  AND NOT EXISTS { (:Usuario)-[:VIO]->(nuevo) }
MATCH (nuevo)-[:TIENE_ETIQUETA]->(e:Etiqueta)<-[:TIENE_ETIQUETA]-(parecido:Contenido)
WHERE parecido <> nuevo
MATCH (u:Usuario)-[:VIO]->(parecido)
RETURN
    nuevo.contenido_id AS contenido_sin_historial,
    nuevo.titulo       AS titulo,
    count(DISTINCT e)  AS etiquetas_compartidas,
    count(DISTINCT u)  AS lectores_potenciales
ORDER BY lectores_potenciales DESC
LIMIT 10;
