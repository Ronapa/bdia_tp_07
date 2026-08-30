# TP Integrador — Sistema de recomendación de contenidos

**Bases de Datos para Inteligencia Artificial — CEIA, FIUBA**
Docente: Esp. Lic. Martín Aníbal Lacheski · Año 2026

**Caso de uso 10** — Sistema de recomendación de contenidos
**Propuesta:** *NexoMedia*, un medio digital multiformato (artículos, videos, podcasts,
newsletters y galerías).

## Integrantes

| Integrante | Aportes principales |
|---|---|
| *Federica Pavese* | *(completar)* |
| *Leandro Saraco* | *(completar)* |
| *Maximiliano Lulic* | *(completar)* |
| *Pablo Salvagni* | *(completar)* |
| *Rodrigo Parra* | *(completar)* |

---
	
## Descripción breve de la solución

*NexoMedia* publica unas *X* piezas por dia y tiene miles en su archivo, pero la portada muestra
veinte. Todo lo demás es, en la práctica, invisible para el usuario.

Este trabajo diseña la **capa de datos** que permitiría sostener un sistema de recomendación
personalizado sobre ese catálogo: qué datos se necesitan, dónde vive cada uno, cómo se consultan,
cómo se protegen y cómo escalan. No entrena ningún modelo: el objeto del trabajo es la solución
de datos.

La solución es **políglota**: cinco motores, cada uno resolviendo la pregunta que los otros cuatro
resuelven mal.

---

## Cómo levantar el entorno

Requiere Docker y Docker Compose. No hace falta Python ni ninguna base instalada
en el host: todo corre en contenedores.

```bash
cp .env.example .env
sh scripts/verificar_entorno.sh    # chequea Docker y puertos libres
sh scripts/ejecutar_pipeline.sh    # reconstruye el proyecto end-to-end
```

El pipeline crea el esquema, genera el dataset sintético, carga los cinco motores,
calcula los embeddings, procesa el lakehouse y publica la capa de serving. La
primera corrida tarda porque descarga el modelo de embeddings; con
`EMBEDDINGS_MODO=simulado` en el `.env` se saltea esa descarga.

Para volver a cero: `sh scripts/reiniciar_proyecto.sh`.

---


## Accesos

Todos los puertos se publican solo en `127.0.0.1`. Las credenciales están en
`.env.example` (son locales y de desarrollo).

| Consola | URL |
|---|---|
| pgAdmin | http://127.0.0.1:8090 |
| Mongo Express | http://127.0.0.1:8091 |
| Neo4j Browser | http://127.0.0.1:7476 |
| MinIO | http://127.0.0.1:9011 |

En Neo4j Browser hay que poner la *Connect URL* a mano: `bolt://127.0.0.1:7690`,
porque el default del navegador apunta al 7687.

---

## Estructura del repositorio

| Carpeta | Contenido |
|---|---|
| `db/` | DDL, índices, vistas, seguridad, datos de referencia y consultas SQL |
| `nosql/` | MongoDB (colecciones e índices), Neo4j (grafo) y Redis (serving) |
| `vectorial/` | Índices `pgvector` y consultas de similitud |
| `analitico/` | Transformaciones Bronze → Silver → Gold en DuckDB |
| `orquestador/` | Scripts Python: generación de datos, cargas, embeddings, serving |
| `scripts/` | Utilidades de entorno y el pipeline completo |
| `docs/` | Informe técnico y diagramas |
| `data/ejemplos/` | Muestras del dataset, para leer el modelo sin levantar nada |

---

## Estado de avance

| Capa | Estado |
|---|---|
| Infraestructura Docker y scripts | Completo |
| Modelo relacional, índices y vistas | Completo |
| Seguridad: roles, RLS, auditoría, seudonimización | Completo |
| Dataset sintético y cargas | Completo |
| MongoDB y Neo4j | Completo |
| Embeddings e índices vectoriales | Completo |
| Lakehouse (MinIO + DuckDB) y serving en Redis | Completo |
| Consultas representativas | Completo |
| API de demostración y demo de estrategias | En curso |
| Informe técnico | Parcial |
| Guía práctica y anexos | Pendiente |

---

## Documentación

El detalle del diseño, los modelos y las decisiones está en
[`docs/informe.md`](docs/informe.md).