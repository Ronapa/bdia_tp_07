// Objetivo: producir recomendaciones explicables y medir la burbuja de filtro.
// Requiere / entradas: grafo cargado por orquestador/cargar_neo4j.py.
// Produce / modifica: nada; solo lee.
// Resultado esperado: caminos de recomendacion legibles y metricas de diversidad por usuario.
// Guia: estas son las consultas que ningun otro motor del stack puede responder con esta claridad.

:param usuario => 1;
:param nivel => 1;

// ============================================================
// Consulta 1: Recomendacion con su explicacion
//
// Pregunta de negocio: por que le estamos mostrando esto a esta persona.
//
// Un recomendador que no puede explicarse es un problema de producto y,
// cada vez mas, un problema regulatorio. El grafo devuelve el CAMINO
// junto con el resultado: el "porque" no hay que reconstruirlo despues,
// sale de la misma consulta.
//
// El camino es literalmente la explicacion:
//   "Te recomendamos Y porque leiste X, y otras 14 personas que tambien
//    leyeron X leyeron Y."
// ============================================================

MATCH (u:Usuario {usuario_id: $usuario})-[:VIO]->(puente:Contenido)<-[:VIO]-(otro:Usuario)
MATCH (otro)-[:VIO]->(recomendado:Contenido)
WHERE recomendado.estado = 'publicado'
  AND recomendado.nivel_acceso <= $nivel
  AND NOT EXISTS { (u)-[:VIO]->(recomendado) }
WITH recomendado, puente, count(DISTINCT otro) AS lectores
ORDER BY lectores DESC
WITH recomendado, collect({nota: puente.titulo, lectores: lectores})[0] AS mejor_puente,
     sum(lectores) AS score
RETURN
    recomendado.contenido_id AS contenido_id,
    recomendado.titulo AS recomendacion,
    score,
    'Porque leiste "' + mejor_puente.nota + '", igual que otras ' +
        toString(mejor_puente.lectores) + ' personas que ademas leyeron esta nota.'
        AS explicacion
ORDER BY score DESC
LIMIT 5;

// ============================================================
// Consulta 2: El camino mas corto entre un lector y un contenido
//
// Pregunta de negocio: que tan lejos esta este contenido del universo
// de interes de esta persona.
//
// shortestPath resuelve en una linea algo que en SQL requeriria una CTE
// recursiva con control de ciclos y de profundidad.
// ============================================================

MATCH (u:Usuario {usuario_id: $usuario}), (c:Contenido {contenido_id: 250})
MATCH camino = shortestPath((u)-[:VIO|TIENE_ETIQUETA|PERTENECE_A|SIMILAR_A*..6]-(c))
RETURN
    length(camino) AS saltos,
    [nodo IN nodes(camino) |
        coalesce(nodo.titulo, nodo.nombre, 'usuario ' + toString(nodo.usuario_id))
    ] AS camino_legible;

// ============================================================
// Consulta 3: Burbuja de filtro
//
// Pregunta de negocio: le estamos mostrando a esta persona un mundo cada
// vez mas chico.
//
// Compara cuantas secciones distintas consumio el usuario contra
// cuantas secciones alcanzaria si siguieramos recomendandole por
// co-visualizacion. Si el segundo numero no es mayor que el primero, el
// recomendador esta encerrando al lector en lo que ya leia.
//
// Es una metrica de calidad que el negocio necesita y que ninguna
// medida de precision captura: un recomendador que siempre acierta y
// nunca sorprende tiene CTR alto y usuarios que se aburren.
// ============================================================

MATCH (u:Usuario)-[:VIO]->(visto:Contenido)
WITH u, count(DISTINCT visto.seccion_raiz) AS secciones_consumidas,
     count(DISTINCT visto) AS contenidos_vistos
WHERE contenidos_vistos >= 5

CALL (u) {
    MATCH (u)-[:VIO]->(:Contenido)<-[:VIO]-(:Usuario)-[:VIO]->(alcanzable:Contenido)
    WHERE alcanzable.estado = 'publicado'
    RETURN count(DISTINCT alcanzable.seccion_raiz) AS secciones_alcanzables
}

RETURN
    u.usuario_id AS usuario_id,
    contenidos_vistos,
    secciones_consumidas,
    secciones_alcanzables,
    secciones_alcanzables - secciones_consumidas AS apertura
ORDER BY apertura ASC
LIMIT 15;

// ============================================================
// Consulta 4: Contenidos puente entre secciones
//
// Pregunta de negocio: que notas hacen que un lector de Politica lea
// tambien Economia.
//
// Son las notas mas valiosas del catalogo para ampliar el consumo, y
// no las encuentra ninguna metrica de popularidad: pueden tener pocas
// vistas y aun asi conectar dos audiencias que no se tocan.
// ============================================================

MATCH (a:Contenido)<-[:VIO]-(u:Usuario)-[:VIO]->(b:Contenido)
WHERE a.seccion_raiz < b.seccion_raiz
  AND a.estado = 'publicado' AND b.estado = 'publicado'
WITH a.seccion_raiz AS seccion_origen, b.seccion_raiz AS seccion_destino,
     count(DISTINCT u) AS lectores_cruzados
RETURN seccion_origen, seccion_destino, lectores_cruzados
ORDER BY lectores_cruzados DESC
LIMIT 10;

// ============================================================
// Consulta 5: Autores que retienen
//
// Pregunta de negocio: que firmas hacen que la gente vuelva.
//
// Recorre usuario -> contenido -> autor y cuenta cuantos lectores
// distintos leyeron dos o mas notas del mismo autor.
// ============================================================

MATCH (autor:Usuario)-[:ESCRIBIO]->(c:Contenido)<-[:VIO]-(lector:Usuario)
WHERE c.estado = 'publicado' AND autor <> lector
WITH autor, lector, count(DISTINCT c) AS notas_leidas
WITH autor,
     count(lector) AS lectores,
     sum(CASE WHEN notas_leidas >= 2 THEN 1 ELSE 0 END) AS lectores_recurrentes
WHERE lectores >= 10
RETURN
    autor.usuario_id AS autor_id,
    lectores,
    lectores_recurrentes,
    round(100.0 * lectores_recurrentes / lectores, 1) AS porcentaje_recurrencia
ORDER BY porcentaje_recurrencia DESC
LIMIT 10;
