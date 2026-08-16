# Modelo de datos vectorial

Responde los cinco puntos que pide la consigna para una solución vectorial: qué se vectoriza,
qué metadatos acompañan a cada vector, cómo se vinculan con los datos originales, qué consultas
por similitud se esperan y qué restricciones de acceso aplican.

---

## 1. Qué se vectoriza

| Elemento | Tabla | Cardinalidad | Texto fuente |
|---|---|---|---|
| Contenido del catálogo | `recomendacion.embeddings_contenido` | 1 por contenido | Sección + título + bajada + etiquetas |
| Perfil de usuario | `recomendacion.perfiles_usuario` | 1 por usuario con consentimiento e historial | Centroide ponderado de lo consumido |

**No se vectoriza el cuerpo completo del contenido.** El caso de uso es recomendación, no
recuperación de pasajes: lo que hay que comparar es *de qué trata* una nota, y eso lo captura el
título más la bajada más las etiquetas. Fragmentar el cuerpo en *chunks* multiplicaría por diez
la cantidad de vectores para responder una pregunta que nadie hace.

Si el sistema tuviera además un buscador semántico dentro del texto, la decisión sería la
contraria y habría una tabla `fragmentos` con su propio embedding.

### Contextual retrieval

El texto que se vectoriza antepone la sección:

```
Mercados. Informe especial sobre cotizacion en mercados. Un repaso por bonos,
riesgo pais y tarifas en la cobertura de Mercados. Temas: bolsa, cotizacion, rueda
```

Un título suelto es ambiguo fuera de contexto; con la sección adelante, el vector cae en la zona
correcta del espacio. Lo que se guarda en `texto_fuente` es exactamente ese string, para poder
reproducir y auditar cada embedding.

---

## 2. Modelo físico

```sql
CREATE TABLE recomendacion.embeddings_contenido (
    contenido_id     BIGINT PRIMARY KEY REFERENCES catalogo.contenidos(id),
    embedding        VECTOR(384) NOT NULL,
    modelo_embedding TEXT NOT NULL,
    texto_fuente     TEXT NOT NULL,
    indexado_en      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

| Parámetro | Valor | Justificación |
|---|---|---|
| Modelo | `intfloat/multilingual-e5-small` | Multilingüe, corre en CPU, sin API ni costo por token |
| Dimensión | **384** | Es la que produce el modelo; la columna la declara y la verificación la controla |
| Métrica | Coseno (`<=>`) | Los vectores están normalizados; el coseno mide orientación, no magnitud |
| Clase de operador | `vector_cosine_ops` | **Debe** coincidir con el operador, o el índice no se usa |
| Índice principal | HNSW (`m=16`, `ef_construction=64`) | Ver §5 |
| Índice comparativo | IVFFlat (`lists=50`) | Se crea para poder medir la diferencia |

### Prefijos E5

Los modelos de la familia E5 se entrenan para recuperación asimétrica y esperan `"query: "` en la
consulta y `"passage: "` en el texto indexado. Omitirlos **degrada el ranking sin producir ningún
error visible**, que es la peor forma de equivocarse. `orquestador/generar_embeddings.py` los
aplica según el nombre del modelo.

---

## 3. Metadatos y vínculo con los datos originales

El vínculo es una **clave foránea real**: `contenido_id REFERENCES catalogo.contenidos(id)`.
No hay ids sueltos, no hay sincronización manual y no hay huérfanos posibles.

Esa es la ventaja concreta de tener los vectores en la misma base que el catálogo, frente a una
base vectorial dedicada (Chroma, Pinecone, Weaviate): en un sistema separado, el vínculo es un
string que nadie garantiza, y borrar un contenido deja su vector vivo para siempre.

### Por qué en una tabla aparte y no como columna de `contenidos`

1. `catalogo.contenidos` es la tabla caliente del OLTP. Un `VECTOR(384)` ocupa ~1,5 KB por fila:
   agregarlo ahí reduce las filas por página y encarece **todas** las consultas del feed,
   incluidas las que no miran el embedding.
2. El ciclo de vida es distinto: el catálogo se edita a mano varias veces por día; los embeddings
   se recalculan en lote cuando cambia el texto o el modelo.
3. Permite convivencia de modelos durante una migración.

### `modelo_embedding` en cada fila

Los vectores de modelos distintos viven en espacios distintos y **no son comparables**. Sin esa
columna, una migración a medias produce un ranking silenciosamente incorrecto: las consultas no
fallan, simplemente devuelven cualquier cosa.

`vectorial/01_crear_indices_vectoriales.sql` verifica que haya exactamente un modelo y una
dimensión, y aborta si no.

---

## 4. Consultas por similitud

| Consulta | Vector de consulta | Uso |
|---|---|---|
| "Más como este" | Embedding del contenido actual | Bloque de relacionados al pie de la nota |
| Feed personalizado | Perfil del usuario (centroide) | Home |
| Feed diversificado | Perfil, con tope de 2 por sección | Home, contra la burbuja de filtro |
| Detección de duplicados | Pares con similitud > 0,97 | Control editorial |
| Vecinos precalculados | kNN exacto por lote | Alimenta `ranking_items_similares` y las aristas `SIMILAR_A` del grafo |

Todas están implementadas en `vectorial/consultas/01_similitud.sql`.

### El perfil de usuario

Es el centroide de los embeddings de lo consumido, ponderado por tipo de evento:

| Evento | Peso |
|---|---|
| `completado`, `guardado` | 3,0 |
| `compartido`, `me_gusta` | 2,5 |
| `reproduccion` | 2,0 |
| `vista` | 1,5 |
| `scroll`, `clic` | 1,0 |
| `impresion` | 0,0 |
| `no_me_interesa` | **−2,0** |

El peso negativo aleja el centroide de lo que la persona rechazó, en vez de limitarse a no
acercarlo. Y `impresion` pesa cero porque una impresión no implica que la persona haya mirado.

Comprimir todo el historial en un solo vector es lo que permite resolver el feed con **una**
búsqueda por vecinos en vez de N búsquedas "más como este".

**Cold start:** con menos de 4 contenidos distintos, el centroide es ruido. En ese caso no se
calcula perfil, y el recomendador cae a popularidad. Es la respuesta correcta, y por eso la
estrategia de popularidad no se apaga aunque tenga el CTR más bajo.

---

## 5. Índices: HNSW contra IVFFlat

| | HNSW | IVFFlat |
|---|---|---|
| Estructura | Grafo jerárquico navegable | Listas invertidas por centroide |
| Entrenamiento previo | No necesita | Sí, necesita datos para calcular centroides |
| Inserciones incrementales | Buenas | Degradan hasta recrear el índice |
| Recall a igual latencia | Mejor | Peor |
| Costo de construcción | Alto | Bajo |
| Parámetro de búsqueda | `hnsw.ef_search` (default 40) | `ivfflat.probes` (default **1**) |

**Se elige HNSW** porque el catálogo crece todos los días y no hay una ventana natural para
reconstruir el índice.

### El recall silencioso de IVFFlat

Con el valor por defecto `ivfflat.probes = 1`, un `LIMIT 10` puede devolver **1 o 2 vecinos**: el
índice escanea una sola de las 50 listas, alrededor del 2% del catálogo, y si los vecinos reales
están en otra lista no aparecen. La consulta **no falla ni avisa**, simplemente devuelve de menos.

Es el riesgo real de las búsquedas aproximadas: no se equivocan ruidosamente, se equivocan en
silencio.

La solución fue distinguir los dos regímenes:

- **Cálculo por lote** (`vectorial/01_crear_indices_vectoriales.sql`): se apagan los índices con
  `SET LOCAL enable_indexscan = off` para obtener el kNN **exacto**. Es un proceso batch; la
  exactitud vale más que la latencia. La verificación aborta si el promedio de vecinos por
  contenido baja de 9.
- **Consultas en línea**: usan el índice, porque ahí la latencia sí manda.

`vectorial/consultas/02_explain_indices.sql` reproduce el efecto de forma medible.

---

## 6. Restricciones de acceso sobre los vectores

Es el punto que la consigna señala como riesgo específico de las aplicaciones conectadas a IA:
**qué pasa si la búsqueda por similitud recupera información que el usuario no debería ver.**

En este sistema, un borrador, una nota despublicada o un contenido premium recuperado por
similitud sería una fuga.

### Prefiltrado, no posfiltrado

Todas las consultas vectoriales llevan las condiciones de acceso **en el mismo `WHERE`** que el
operador de distancia:

```sql
FROM recomendacion.embeddings_contenido AS e
JOIN catalogo.vw_contenidos_publicables AS v
    ON v.contenido_id = e.contenido_id
WHERE v.nivel_acceso <= :nivel_del_usuario
ORDER BY e.embedding <=> :vector_consulta
LIMIT 10;
```

PostgreSQL evalúa el filtro **antes** de rankear. La alternativa habitual en sistemas con base
vectorial separada (traer varios vecinos y filtrarlos en la aplicación) tiene dos problemas:

1. Si los 50 son premium y el usuario es gratuito, el feed queda vacío aunque existan candidatos
   válidos más lejanos.
2. **Los ids de los contenidos descartados ya salieron de la base.** Cualquier error en la capa
   de aplicación los expone.

### Defensa en profundidad

| Capa | Mecanismo |
|---|---|
| Consulta | Prefiltrado por `estado`, `vigente_hasta` y `nivel_acceso` |
| Vista | `catalogo.vw_contenidos_publicables` con `security_invoker = TRUE`, para que el RLS aplique |
| Motor | Políticas RLS sobre `catalogo.contenidos` |
| Cálculo por lote | Los vecinos precalculados solo se computan entre contenidos publicados |
| Gobierno | El perfil vectorial solo se calcula con `consentimiento_personalizacion = TRUE` |

Las cinco son independientes: que falle una no abre la puerta.

### El costo del prefiltrado

Un índice vectorial ordena por distancia, no por estado de publicación. Cuando el `WHERE`
descarta muchas filas, PostgreSQL tiene que recorrer más candidatos del índice para llegar a 10
que pasen el filtro, o directamente abandonarlo. Es el precio de no filtrar después, y está
medido en `vectorial/consultas/02_explain_indices.sql`.

---

## 7. Comparación con la búsqueda literal

Las dos conviven, y no compiten:

| | Búsqueda literal (`tsvector` + GIN) | Búsqueda semántica (pgvector) |
|---|---|---|
| Encuentra | La palabra exacta, con stemming | El tema, con otras palabras |
| Gana con | Nombres propios, siglas, cifras | Descripciones en lenguaje natural |
| Falla con | Sinónimos y paráfrasis | Términos raros que el modelo no vio |
| Costo | Bajo | Alto (hay que calcular el embedding de la consulta) |

`idx_contenidos_titulo_tsv` sostiene la primera; `idx_embeddings_contenido_hnsw`, la segunda.

La comparación está implementada en `vectorial/consultas/03_literal_vs_semantica.sql`: mide qué
encuentra cada método, cuánto se solapan y cómo se combinan con *reciprocal rank fusion*, que es la
técnica estándar para fusionar dos rankings con escalas incomparables (`ts_rank` ronda 0,06 y la
similitud coseno 0,95: sumarlos directamente no significa nada).

---

## 8. Alternativa descartada: base vectorial dedicada

| Criterio | pgvector | Chroma / Pinecone / Weaviate |
|---|---|---|
| Prefiltrado por metadatos | Nativo, en la misma consulta | Limitado; suele terminar en posfiltrado |
| Integridad con el catálogo | Clave foránea real | Sincronización manual |
| Control de acceso | Hereda el RLS de PostgreSQL | Propio, o inexistente |
| Consistencia | Una sola transacción | Dos sistemas, consistencia eventual |
| Escala | Hasta ~10 millones de vectores con HNSW | Diseñadas para cientos de millones |
| Operación | Un motor menos | Un motor más |

Al volumen de catálogo de este proyecto, pgvector alcanza de sobra. El umbral a partir del cual
convendría migrar es el de las decenas de millones de vectores, o el de necesitar filtrado por
metadatos que PostgreSQL no pueda expresar. Ninguno de los dos se espera que se cumpla acá.
