#!/usr/bin/env python3
"""Genera el dataset sintetico completo del portal NexoMedia.

Produce, a partir de una semilla fija, todos los archivos que despues
consumen los cargadores de cada motor:

    data/generado/postgres/*.csv   -> cargar_postgres.py
    data/generado/mongo/*.json     -> nosql/mongodb/00_cargar_datos.js y cargar_mongo.py

El dataset es DETERMINISTA: la misma semilla produce exactamente los
mismos archivos, byte a byte. Eso es lo que permite que la verificacion
del pipeline compare contra conteos exactos y falle si algo cambio.

Decisiones de realismo que importan para que el caso de uso se sostenga:

  - Popularidad con ley de potencias: unos pocos contenidos concentran
    la mayor parte de las vistas. Un reparto uniforme haria que
    cualquier estrategia de recomendacion se viera igual de buena.
  - Afinidad por seccion: cada usuario tiene dos o tres secciones
    preferidas. Sin esa estructura no hay nada que un recomendador
    pueda aprender.
  - Sesgo horario: el consumo se concentra en la manana y la noche.
  - Cold start explicito: contenidos recien publicados y usuarios
    recien registrados casi sin historial.
  - Casos borde para LEFT JOIN: usuarios sin ninguna actividad y
    contenidos que nunca fueron recomendados.

Uso:
    python generar_datos.py
    python generar_datos.py --escala chica --semilla 7
    python generar_datos.py --salida /workspace/data/generado

Variables de entorno:
    SEMILLA   semilla del generador (default 42)
    ESCALA    chica | media | grande (default media)
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import unicodedata
from datetime import datetime, timedelta, timezone
from pathlib import Path

# ============================================================
# Ventana temporal
#
# Fechas fijas y no "hoy - N dias": si la ventana se moviera con el
# reloj, las particiones declarativas de recomendacion.impresiones
# dejarian de cubrirla y la carga terminaria en la particion DEFAULT.
# ============================================================

FECHA_INICIO = datetime(2026, 4, 1, tzinfo=timezone.utc)
FECHA_CORTE = datetime(2026, 7, 31, 23, 0, tzinfo=timezone.utc)
DIAS_VENTANA = (FECHA_CORTE - FECHA_INICIO).days

ESCALAS = {
    "chica": {"usuarios": 200, "contenidos": 400, "eventos": 20_000, "impresiones": 15_000},
    "media": {"usuarios": 2_000, "contenidos": 3_000, "eventos": 150_000, "impresiones": 120_000},
    "grande": {"usuarios": 6_000, "contenidos": 9_000, "eventos": 600_000, "impresiones": 480_000},
}

# ============================================================
# Taxonomia editorial
#
# Tres niveles de secciones. El vocabulario por seccion es lo que hace
# que los embeddings tengan algo que capturar: dos notas de la misma
# subseccion comparten terminos y terminan cerca en el espacio vectorial.
# ============================================================

ARBOL_SECCIONES = {
    "Politica": {
        "Elecciones": ["Resultados", "Campana"],
        "Congreso": [],
        "Gobierno": [],
    },
    "Economia": {
        "Mercados": ["Dolar", "Acciones"],
        "Empleo": [],
        "Consumo": [],
    },
    "Sociedad": {
        "Educacion": [],
        "Salud": [],
        "Seguridad": [],
    },
    "Deportes": {
        "Futbol": ["Liga", "Seleccion"],
        "Automovilismo": [],
    },
    "Cultura": {
        "Cine": [],
        "Musica": [],
        "Libros": [],
    },
    "Tecnologia": {
        "Inteligencia Artificial": [],
        "Ciberseguridad": [],
        "Startups": [],
    },
    "Mundo": {
        "America": [],
        "Europa": [],
    },
}

VOCABULARIO = {
    "Politica": ["gobierno", "oposicion", "reforma", "decreto", "gabinete", "alianza", "mandato"],
    "Elecciones": ["padron", "escrutinio", "boleta", "candidato", "mesa", "voto", "campana"],
    "Resultados": ["escrutinio definitivo", "diferencia de votos", "participacion", "recuento"],
    "Campana": ["spot", "encuesta", "acto", "financiamiento", "debate"],
    "Congreso": ["diputados", "senado", "comision", "proyecto de ley", "quorum"],
    "Gobierno": ["ministerio", "presupuesto", "funcionario", "gestion", "anuncio"],
    "Economia": ["inflacion", "actividad", "tarifas", "deficit", "superavit"],
    "Mercados": ["bonos", "riesgo pais", "tasa", "cotizacion", "rueda"],
    "Dolar": ["tipo de cambio", "brecha", "reservas", "cepo"],
    "Acciones": ["panel lider", "papeles", "bolsa", "rendimiento"],
    "Empleo": ["paritarias", "salario", "desocupacion", "convenio", "puestos"],
    "Consumo": ["canasta", "precios", "supermercados", "ventas minoristas"],
    "Sociedad": ["comunidad", "vecinos", "servicio publico", "reclamo"],
    "Educacion": ["escuelas", "docentes", "matricula", "aprendizajes", "universidad"],
    "Salud": ["hospital", "vacunacion", "guardias", "obra social", "tratamiento"],
    "Seguridad": ["policia", "operativo", "delito", "prevencion", "denuncia"],
    "Deportes": ["equipo", "entrenador", "torneo", "fecha", "plantel"],
    "Futbol": ["gol", "arquero", "delantero", "clasico", "estadio"],
    "Liga": ["tabla de posiciones", "descenso", "libertadores", "fixture"],
    "Seleccion": ["eliminatorias", "convocatoria", "amistoso", "mundial"],
    "Automovilismo": ["carrera", "clasificacion", "circuito", "escuderia", "pole"],
    "Cultura": ["escenario", "artista", "publico", "obra", "festival"],
    "Cine": ["estreno", "director", "guion", "taquilla", "pelicula"],
    "Musica": ["album", "gira", "banda", "single", "recital"],
    "Libros": ["novela", "editorial", "autor", "ensayo", "lectura"],
    "Tecnologia": ["plataforma", "software", "dispositivo", "usuarios", "actualizacion"],
    "Inteligencia Artificial": ["modelo de lenguaje", "entrenamiento", "inferencia",
                                "dataset", "algoritmo", "automatizacion"],
    "Ciberseguridad": ["vulnerabilidad", "filtracion", "ransomware", "parche", "credenciales"],
    "Startups": ["ronda de inversion", "fundadores", "escalar", "producto minimo"],
    "Mundo": ["cumbre", "tratado", "frontera", "diplomacia", "sancion"],
    "America": ["region", "integracion", "comercio", "vecino"],
    "Europa": ["union europea", "parlamento", "energia", "acuerdo"],
}

PLANTILLAS_TITULO = [
    "{sujeto}: {hecho} y {consecuencia}",
    "Que hay detras de {hecho}",
    "{hecho}, en cinco claves",
    "Analisis | {sujeto} frente a {consecuencia}",
    "Informe especial sobre {hecho}",
    "{sujeto} y el impacto de {consecuencia}",
    "Como sigue {hecho} despues del anuncio",
    "Las cifras que explican {hecho}",
]

SUJETOS = ["El gobierno", "La oposicion", "El mercado", "El sector", "La industria",
           "Los especialistas", "El equipo", "La ciudad", "La region", "El organismo"]

TIPOS_CONTENIDO = [
    ("articulo", "Articulo", False),
    ("video", "Video", True),
    ("podcast", "Podcast", True),
    ("newsletter", "Newsletter", False),
    ("galeria", "Galeria de fotos", False),
]

PESOS_TIPO = [0.55, 0.18, 0.10, 0.09, 0.08]

DISPOSITIVOS = ["movil", "escritorio", "tablet", "smart_tv"]
PESOS_DISPOSITIVO = [0.62, 0.28, 0.07, 0.03]

CANALES = ["directo", "buscador", "redes", "newsletter", "notificacion"]
PESOS_CANAL = [0.30, 0.28, 0.24, 0.11, 0.07]

PAISES = ["AR", "UY", "CL", "ES", "MX", "PY", "BO"]
PESOS_PAIS = [0.72, 0.06, 0.05, 0.06, 0.05, 0.03, 0.03]

NOMBRES = ["Ana", "Luis", "Maria", "Carla", "Diego", "Sofia", "Martin", "Julieta", "Pablo",
           "Lucia", "Federico", "Valeria", "Nicolas", "Camila", "Ramiro", "Paula", "Ezequiel",
           "Florencia", "Gonzalo", "Micaela", "Tomas", "Agustina", "Ignacio", "Rocio"]
APELLIDOS = ["Perez", "Gomez", "Torres", "Fernandez", "Lopez", "Diaz", "Sosa", "Romero",
             "Alvarez", "Benitez", "Molina", "Silva", "Castro", "Ortiz", "Ramos", "Aguirre",
             "Medina", "Herrera", "Rojas", "Vega"]

TIPOS_EVENTO = ["impresion", "vista", "scroll", "clic", "reproduccion",
                "completado", "guardado", "compartido", "me_gusta", "no_me_interesa"]

SUPERFICIES = ["home", "seccion", "articulo", "newsletter", "busqueda"]
PESOS_SUPERFICIE = [0.44, 0.24, 0.20, 0.07, 0.05]

# codigo, version, nombre, motor, descripcion
ESTRATEGIAS = [
    ("popularidad", "1.0", "Mas leidas con decaimiento temporal", "duckdb",
     "Ranking por vistas de las ultimas 24 horas con decaimiento exponencial. Es la linea de base y la red de contencion para el cold start."),
    ("contenido_similar", "1.0", "Similitud semantica de embeddings", "pgvector",
     "Vecinos mas cercanos del contenido actual o del perfil del usuario, con prefiltrado de estado, vigencia y nivel de acceso."),
    ("colaborativo_item", "1.0", "Filtrado colaborativo item-item", "duckdb",
     "Matriz de co-ocurrencia normalizada por coseno calculada sobre la capa Silver del lakehouse."),
    ("grafo_covisualizacion", "1.0", "Co-visualizacion a dos saltos", "neo4j",
     "Recorrido usuario -> contenido -> otros usuarios -> contenido, con explicacion del camino."),
    ("hibrido", "1.0", "Mezcla ponderada de las cuatro senales", "hibrido",
     "Combina popularidad, similitud, co-ocurrencia y grafo, aplica los vetos declarados y diversifica por seccion."),
]


def sin_tildes(texto: str) -> str:
    """Normaliza a ASCII para poder usar el texto como slug."""
    return "".join(
        caracter
        for caracter in unicodedata.normalize("NFD", texto)
        if unicodedata.category(caracter) != "Mn"
    )


def slugificar(texto: str) -> str:
    limpio = sin_tildes(texto).lower()
    return "".join(caracter if caracter.isalnum() else "-" for caracter in limpio).strip("-")


def elegir(rng: random.Random, opciones: list, pesos: list):
    return rng.choices(opciones, weights=pesos, k=1)[0]


def construir_secciones() -> list[dict]:
    """Aplana ARBOL_SECCIONES en filas con id y seccion_padre_id."""
    secciones: list[dict] = []
    siguiente_id = 1

    for raiz, hijos in ARBOL_SECCIONES.items():
        id_raiz = siguiente_id
        siguiente_id += 1
        secciones.append({
            "id": id_raiz,
            "slug": slugificar(raiz),
            "nombre": raiz,
            "seccion_padre_id": "",
            "activa": "true",
            "nivel": 1,
            "raiz": raiz,
        })

        for hijo, nietos in hijos.items():
            id_hijo = siguiente_id
            siguiente_id += 1
            secciones.append({
                "id": id_hijo,
                "slug": slugificar(f"{raiz}-{hijo}"),
                "nombre": hijo,
                "seccion_padre_id": id_raiz,
                "activa": "true",
                "nivel": 2,
                "raiz": raiz,
            })

            for nieto in nietos:
                secciones.append({
                    "id": siguiente_id,
                    "slug": slugificar(f"{raiz}-{hijo}-{nieto}"),
                    "nombre": nieto,
                    "seccion_padre_id": id_hijo,
                    "activa": "true",
                    "nivel": 3,
                    "raiz": raiz,
                })
                siguiente_id += 1

    return secciones


def construir_etiquetas(secciones: list[dict]) -> tuple[list[dict], dict[int, list[int]]]:
    """Deriva las etiquetas del vocabulario de cada seccion.

    Devuelve tambien el mapa seccion_id -> etiquetas candidatas, que es
    lo que hace que las etiquetas de un contenido sean coherentes con
    su seccion en lugar de aleatorias.
    """
    etiquetas: list[dict] = []
    por_slug: dict[str, int] = {}
    candidatas: dict[int, list[int]] = {}

    for seccion in secciones:
        terminos = VOCABULARIO.get(seccion["nombre"], []) + VOCABULARIO.get(seccion["raiz"], [])
        ids_seccion = []

        for termino in terminos:
            slug = slugificar(termino)
            if slug not in por_slug:
                nuevo_id = len(etiquetas) + 1
                por_slug[slug] = nuevo_id
                etiquetas.append({"id": nuevo_id, "slug": slug, "nombre": termino})
            ids_seccion.append(por_slug[slug])

        candidatas[seccion["id"]] = ids_seccion

    return etiquetas, candidatas


def generar_usuarios(rng: random.Random, cantidad: int) -> list[dict]:
    usuarios = []
    for indice in range(1, cantidad + 1):
        nombre = rng.choice(NOMBRES)
        apellido = rng.choice(APELLIDOS)
        alias = f"{nombre.lower()}.{apellido.lower()}{indice}"

        # El ultimo 4% se da de alta en la ultima semana: son los casos
        # de cold start que ninguna estrategia personalizada puede cubrir.
        reciente = indice > cantidad * 0.96
        if reciente:
            fecha_alta = FECHA_CORTE - timedelta(days=rng.randint(0, 6), hours=rng.randint(0, 23))
        else:
            fecha_alta = FECHA_INICIO - timedelta(days=rng.randint(30, 900))

        usuarios.append({
            "id": indice,
            "email": f"{alias}@example.com",
            "alias": f"{nombre} {apellido}",
            "pais": elegir(rng, PAISES, PESOS_PAIS),
            "anio_nacimiento": rng.randint(1955, 2007),
            "consentimiento_personalizacion": "true" if rng.random() < 0.78 else "false",
            "activo": "true" if rng.random() < 0.94 else "false",
            "fecha_alta": fecha_alta.isoformat(),
            "es_nuevo": reciente,
        })
    return usuarios


def generar_planes_y_suscripciones(rng: random.Random, usuarios: list[dict]) -> list[dict]:
    """Asigna plan y arma el historico de suscripciones.

    El 12% de los usuarios tiene ademas una suscripcion anterior cerrada:
    es lo que permite responder 'que nivel de acceso tenia en mayo' y lo
    que justifica modelar suscripciones como historico y no como columna.
    """
    suscripciones = []
    siguiente_id = 1

    for usuario in usuarios:
        sorteo = rng.random()
        if sorteo < 0.55:
            plan_codigo = "registrado"
        elif sorteo < 0.80:
            plan_codigo = "premium"
        else:
            plan_codigo = "gratuito"

        alta = datetime.fromisoformat(usuario["fecha_alta"])

        if rng.random() < 0.12 and plan_codigo == "premium":
            cierre = alta + timedelta(days=rng.randint(40, 200))
            if cierre < FECHA_CORTE:
                suscripciones.append({
                    "id": siguiente_id,
                    "usuario_id": usuario["id"],
                    "plan_codigo": "registrado",
                    "desde": alta.isoformat(),
                    "hasta": cierre.isoformat(),
                    "estado": "vencida",
                })
                siguiente_id += 1
                alta = cierre

        suscripciones.append({
            "id": siguiente_id,
            "usuario_id": usuario["id"],
            "plan_codigo": plan_codigo,
            "desde": alta.isoformat(),
            "hasta": "",
            "estado": "activa",
        })
        siguiente_id += 1
        usuario["plan"] = plan_codigo
        usuario["nivel_acceso"] = {"gratuito": 0, "registrado": 1, "premium": 2}[plan_codigo]

    return suscripciones


def generar_contenidos(
    rng: random.Random,
    cantidad: int,
    secciones: list[dict],
    etiquetas_por_seccion: dict[int, list[int]],
    editores: list[int],
) -> tuple[list[dict], list[dict]]:
    """Genera el catalogo y su tabla puente de etiquetas.

    La popularidad sigue una ley de potencias sobre el rango del
    contenido: el contenido 1 recibe ordenes de magnitud mas vistas que
    el contenido 3.000. Es la forma de la distribucion real de consumo
    de un medio, y es la que hace que 'recomendar lo mas leido' sea una
    linea de base dificil de superar.
    """
    hojas = [s for s in secciones if s["nivel"] >= 2]
    contenidos = []
    contenidos_etiquetas = []

    for indice in range(1, cantidad + 1):
        seccion = rng.choice(hojas)
        vocabulario = VOCABULARIO.get(seccion["nombre"], []) or VOCABULARIO[seccion["raiz"]]
        vocabulario_raiz = VOCABULARIO[seccion["raiz"]]

        hecho = f"{rng.choice(vocabulario)} en {seccion['nombre'].lower()}"
        consecuencia = rng.choice(vocabulario_raiz)
        titulo = rng.choice(PLANTILLAS_TITULO).format(
            sujeto=rng.choice(SUJETOS), hecho=hecho, consecuencia=consecuencia
        )
        bajada = (
            f"Un repaso por {rng.choice(vocabulario)}, {rng.choice(vocabulario)} y "
            f"{rng.choice(vocabulario_raiz)} en la cobertura de {seccion['nombre']}."
        )

        tipo = elegir(rng, [t[0] for t in TIPOS_CONTENIDO], PESOS_TIPO)

        # El 4% final se publica en los ultimos tres dias: cold start del catalogo.
        reciente = indice > cantidad * 0.96
        if reciente:
            publicacion = FECHA_CORTE - timedelta(days=rng.randint(0, 2), hours=rng.randint(0, 23))
        else:
            publicacion = FECHA_INICIO + timedelta(
                days=rng.randint(0, DIAS_VENTANA - 4), hours=rng.randint(0, 23)
            )

        sorteo_estado = rng.random()
        if sorteo_estado < 0.72:
            estado = "publicado"
        elif sorteo_estado < 0.82:
            estado = "borrador"
        elif sorteo_estado < 0.88:
            estado = "en_revision"
        elif sorteo_estado < 0.95:
            estado = "despublicado"
        else:
            estado = "archivado"

        # El nivel de acceso se correlaciona con el tipo: los informes
        # largos y los podcasts son los que el medio pone tras el muro.
        sorteo_acceso = rng.random()
        if tipo in ("podcast", "newsletter") and sorteo_acceso < 0.45:
            nivel_acceso = 2
        elif sorteo_acceso < 0.20:
            nivel_acceso = 2
        elif sorteo_acceso < 0.55:
            nivel_acceso = 1
        else:
            nivel_acceso = 0

        # El 9% de los contenidos publicados tiene ventana de vigencia:
        # coberturas en vivo, promociones, resultados provisorios.
        vigente_hasta = ""
        if estado == "publicado" and rng.random() < 0.09:
            vencimiento = publicacion + timedelta(days=rng.randint(1, 40))
            vigente_hasta = vencimiento.isoformat()

        duracion = ""
        if tipo in ("video", "podcast"):
            duracion = rng.randint(90, 3600)

        metadatos = {"fuente": rng.choice(["redaccion", "agencia", "corresponsal"])}
        if tipo == "video":
            metadatos["proveedor"] = rng.choice(["propio", "youtube", "agencia"])
            metadatos["resolucion"] = rng.choice(["1080p", "720p", "4k"])
        elif tipo == "galeria":
            metadatos["cantidad_fotos"] = rng.randint(6, 40)
        elif tipo == "podcast":
            metadatos["temporada"] = rng.randint(1, 5)
            metadatos["episodio"] = rng.randint(1, 30)
        elif tipo == "newsletter":
            metadatos["envio"] = rng.choice(["matutino", "vespertino", "semanal"])
        if rng.random() < 0.25:
            metadatos["destacado"] = True
        if rng.random() < 0.15:
            metadatos["patrocinado"] = True

        contenidos.append({
            "id": indice,
            "titulo": titulo,
            "bajada": bajada,
            "tipo_contenido_codigo": tipo,
            "seccion_id": seccion["id"],
            "seccion_nombre": seccion["nombre"],
            "seccion_raiz": seccion["raiz"],
            "autor_id": rng.choice(editores),
            "estado": estado,
            "nivel_acceso": nivel_acceso,
            "idioma": "es",
            "fecha_publicacion": publicacion.isoformat() if estado in
                                 ("publicado", "despublicado", "archivado") else "",
            "vigente_hasta": vigente_hasta,
            "duracion_seg": duracion,
            "cuerpo_ref": f"CNT-{indice:06d}",
            "metadatos": json.dumps(metadatos, ensure_ascii=False, sort_keys=True),
            "creado_en": (publicacion - timedelta(hours=rng.randint(1, 72))).isoformat(),
            "actualizado_en": publicacion.isoformat(),
            "peso_popularidad": 1.0 / (indice ** 0.85),
            "es_reciente": reciente,
        })

        candidatas = etiquetas_por_seccion.get(seccion["id"], [])
        if candidatas:
            elegidas = rng.sample(candidatas, k=min(len(candidatas), rng.randint(2, 4)))
            for etiqueta_id in elegidas:
                contenidos_etiquetas.append({
                    "contenido_id": indice,
                    "etiqueta_id": etiqueta_id,
                    "relevancia": round(rng.uniform(0.4, 1.0), 3),
                })

    return contenidos, contenidos_etiquetas


def generar_historial_editorial(
    rng: random.Random, contenidos: list[dict], editores: list[int], moderadores: list[int]
) -> tuple[list[dict], list[dict]]:
    versiones = []
    moderaciones = []
    id_version = 1
    id_moderacion = 1

    for contenido in contenidos:
        cantidad_versiones = rng.choices([1, 2, 3, 4], weights=[0.5, 0.3, 0.15, 0.05], k=1)[0]
        base = datetime.fromisoformat(contenido["creado_en"])

        for numero in range(1, cantidad_versiones + 1):
            cambios = {}
            if numero > 1:
                for campo in rng.sample(["titulo", "bajada", "seccion_id", "nivel_acceso"],
                                        k=rng.randint(1, 2)):
                    cambios[campo] = {"anterior": "valor previo", "nuevo": "valor corregido"}

            versiones.append({
                "id": id_version,
                "contenido_id": contenido["id"],
                "numero_version": numero,
                "editor_id": rng.choice(editores),
                "cambios": json.dumps(cambios, ensure_ascii=False, sort_keys=True),
                "comentario": "Version inicial" if numero == 1 else "Ajustes de edicion",
                "creado_en": (base + timedelta(hours=numero * rng.randint(1, 12))).isoformat(),
            })
            id_version += 1

        if contenido["estado"] in ("publicado", "despublicado", "archivado"):
            accion = "aprobado" if contenido["estado"] == "publicado" else "despublicado"
            moderaciones.append({
                "id": id_moderacion,
                "objeto_tipo": "contenido",
                "objeto_id": str(contenido["id"]),
                "contenido_id": contenido["id"],
                "moderador_id": rng.choice(moderadores),
                "accion": accion,
                "motivo": "Revision editorial de rutina",
                "creado_en": (base + timedelta(hours=rng.randint(2, 48))).isoformat(),
            })
            id_moderacion += 1

    return versiones, moderaciones


def asignar_afinidades(rng: random.Random, usuarios: list[dict], secciones: list[dict]) -> None:
    """Cada usuario recibe dos o tres secciones raiz preferidas.

    Es la estructura latente del dataset: sin ella, el comportamiento
    seria ruido uniforme y ninguna estrategia podria superar al azar.
    """
    raices = sorted({s["raiz"] for s in secciones})
    for usuario in usuarios:
        cantidad = rng.randint(2, 3)
        usuario["afinidades"] = rng.sample(raices, k=cantidad)


def generar_preferencias(
    rng: random.Random, usuarios: list[dict], secciones: list[dict], etiquetas: list[dict]
) -> list[dict]:
    por_raiz = {}
    for seccion in secciones:
        if seccion["nivel"] == 1:
            por_raiz[seccion["nombre"]] = seccion["id"]

    preferencias = []
    id_preferencia = 1

    for usuario in usuarios:
        # Preferencias positivas: las secciones que declaro seguir.
        for raiz in usuario["afinidades"]:
            if rng.random() < 0.65:
                preferencias.append({
                    "id": id_preferencia,
                    "usuario_id": usuario["id"],
                    "seccion_id": por_raiz[raiz],
                    "etiqueta_id": "",
                    "tipo_preferencia": "sigue",
                    "peso": round(rng.uniform(0.6, 1.0), 3),
                    "actualizado_en": FECHA_CORTE.isoformat(),
                })
                id_preferencia += 1

        # Vetos: el 22% de los usuarios silencia una seccion o una etiqueta.
        if rng.random() < 0.22:
            candidatas = [r for r in por_raiz if r not in usuario["afinidades"]]
            if candidatas:
                preferencias.append({
                    "id": id_preferencia,
                    "usuario_id": usuario["id"],
                    "seccion_id": por_raiz[rng.choice(candidatas)],
                    "etiqueta_id": "",
                    "tipo_preferencia": "no_interesa",
                    "peso": 1.0,
                    "actualizado_en": FECHA_CORTE.isoformat(),
                })
                id_preferencia += 1

        if rng.random() < 0.10:
            preferencias.append({
                "id": id_preferencia,
                "usuario_id": usuario["id"],
                "seccion_id": "",
                "etiqueta_id": rng.choice(etiquetas)["id"],
                "tipo_preferencia": "no_interesa",
                "peso": 1.0,
                "actualizado_en": FECHA_CORTE.isoformat(),
            })
            id_preferencia += 1

    return preferencias


def hora_sesgada(rng: random.Random) -> int:
    """Devuelve una hora del dia con los dos picos tipicos de un medio."""
    if rng.random() < 0.45:
        return rng.choice([7, 8, 9, 10, 11])
    if rng.random() < 0.6:
        return rng.choice([19, 20, 21, 22])
    return rng.randint(0, 23)


def generar_eventos(
    rng: random.Random,
    cantidad: int,
    usuarios: list[dict],
    contenidos: list[dict],
) -> list[dict]:
    """Genera el clickstream que despues vive en MongoDB.

    El esquema del documento cambia segun tipo_evento: un 'scroll' trae
    porcentaje_scroll, una 'reproduccion' trae porcentaje_reproducido y
    una 'impresion' trae origen_recomendacion. Esa heterogeneidad es
    justamente el argumento por el que el clickstream no vive en tablas.
    """
    publicados = [c for c in contenidos if c["estado"] == "publicado"]
    pesos_publicados = [c["peso_popularidad"] for c in publicados]

    por_raiz: dict[str, list[int]] = {}
    for indice, contenido in enumerate(publicados):
        por_raiz.setdefault(contenido["seccion_raiz"], []).append(indice)

    # El 3% de los usuarios nunca genera un evento: son el caso borde
    # que hace visible la diferencia entre JOIN y LEFT JOIN.
    activos = [u for u in usuarios if not u["es_nuevo"]]
    activos = activos[: int(len(activos) * 0.97)]

    eventos = []
    for numero in range(1, cantidad + 1):
        usuario = rng.choice(activos)

        # 70% de las veces el usuario consume dentro de sus afinidades.
        if rng.random() < 0.70:
            raiz = rng.choice(usuario["afinidades"])
            indices = por_raiz.get(raiz)
            if indices:
                sub_pesos = [pesos_publicados[i] for i in indices]
                indice = rng.choices(indices, weights=sub_pesos, k=1)[0]
            else:
                indice = rng.choices(range(len(publicados)), weights=pesos_publicados, k=1)[0]
        else:
            indice = rng.choices(range(len(publicados)), weights=pesos_publicados, k=1)[0]

        contenido = publicados[indice]

        # El usuario no puede consumir contenido por encima de su plan.
        if contenido["nivel_acceso"] > usuario["nivel_acceso"]:
            continue

        publicacion = datetime.fromisoformat(contenido["fecha_publicacion"])
        margen = max((FECHA_CORTE - publicacion).days, 0)
        # El consumo se concentra en los primeros dias despues de publicar.
        desplazamiento = min(int(rng.expovariate(1 / 3.0)), margen) if margen else 0
        momento = (publicacion + timedelta(days=desplazamiento)).replace(
            hour=hora_sesgada(rng), minute=rng.randint(0, 59), second=rng.randint(0, 59)
        )
        if momento > FECHA_CORTE:
            momento = FECHA_CORTE - timedelta(minutes=rng.randint(1, 600))

        tipo_evento = rng.choices(
            TIPOS_EVENTO,
            weights=[0.30, 0.28, 0.12, 0.10, 0.07, 0.04, 0.03, 0.03, 0.02, 0.01],
            k=1,
        )[0]

        documento = {
            "evento_id": f"EV-{numero:08d}",
            "usuario_id": usuario["id"],
            "sesion_id": f"S-{usuario['id']:06d}-{momento.strftime('%Y%m%d%H')}",
            "contenido_id": contenido["id"],
            "tipo_evento": tipo_evento,
            "ocurrido_en": momento.isoformat(),
            "contexto": {
                "dispositivo": elegir(rng, DISPOSITIVOS, PESOS_DISPOSITIVO),
                "canal": elegir(rng, CANALES, PESOS_CANAL),
                "pais": usuario["pais"],
                "superficie": elegir(rng, SUPERFICIES, PESOS_SUPERFICIE),
            },
        }

        # Cada tipo de evento agrega los campos que le son propios.
        if tipo_evento in ("vista", "scroll", "completado"):
            documento["metricas"] = {
                "segundos_visibles": rng.randint(3, 900),
                "porcentaje_scroll": min(100, round(rng.betavariate(2, 3) * 130, 1)),
            }
        elif tipo_evento in ("reproduccion", "completado") and contenido["duracion_seg"]:
            documento["metricas"] = {
                "segundos_reproducidos": rng.randint(5, int(contenido["duracion_seg"])),
                "porcentaje_reproducido": round(rng.betavariate(2, 2) * 100, 1),
            }
        elif tipo_evento == "impresion":
            documento["origen_recomendacion"] = {
                "estrategia": rng.choice([e[0] for e in ESTRATEGIAS]),
                "posicion": rng.randint(1, 20),
                "variante_ab": rng.choice(["control", "tratamiento"]),
            }

        eventos.append(documento)

    return eventos


def generar_impresiones(
    rng: random.Random,
    cantidad: int,
    usuarios: list[dict],
    contenidos: list[dict],
) -> list[dict]:
    """Genera el registro de que se le mostro a cada usuario.

    El CTR se hace depender de la estrategia y de la posicion: sin esa
    dependencia, la consulta de rendimiento devolveria cinco numeros
    iguales y no habria nada que decidir.
    """
    publicados = [c for c in contenidos if c["estado"] == "publicado"]
    pesos = [c["peso_popularidad"] for c in publicados]

    # El 6% del catalogo nunca se recomienda: es el long tail que mide
    # la cobertura y el sesgo del recomendador.
    recomendables = publicados[: int(len(publicados) * 0.94)]
    pesos_recomendables = pesos[: len(recomendables)]

    ctr_base = {
        "popularidad": 0.041,
        "contenido_similar": 0.056,
        "colaborativo_item": 0.062,
        "grafo_covisualizacion": 0.058,
        "hibrido": 0.071,
    }
    codigos = [e[0] for e in ESTRATEGIAS]
    activos = [u for u in usuarios if not u["es_nuevo"]]

    impresiones = []
    for _ in range(cantidad):
        usuario = rng.choice(activos)
        estrategia = rng.choices(codigos, weights=[0.24, 0.20, 0.18, 0.16, 0.22], k=1)[0]

        indice = rng.choices(range(len(recomendables)), weights=pesos_recomendables, k=1)[0]
        contenido = recomendables[indice]
        if contenido["nivel_acceso"] > usuario["nivel_acceso"]:
            continue

        posicion = min(int(rng.paretovariate(1.4)), 20)
        momento = FECHA_INICIO + timedelta(
            days=rng.randint(0, DIAS_VENTANA - 1),
            hours=hora_sesgada(rng),
            minutes=rng.randint(0, 59),
        )

        # El clic cae con la posicion: es el sesgo de posicion clasico.
        probabilidad = ctr_base[estrategia] * math.exp(-0.18 * (posicion - 1))
        hubo_clic = rng.random() < probabilidad

        impresiones.append({
            "usuario_id": usuario["id"],
            "contenido_id": contenido["id"],
            "estrategia_codigo": estrategia,
            "posicion": posicion,
            "score": round(rng.uniform(0.1, 0.99), 6),
            "variante_ab": rng.choice(["control", "tratamiento"]),
            "superficie": elegir(rng, SUPERFICIES, PESOS_SUPERFICIE),
            "mostrado_en": momento.isoformat(),
            "clic": "true" if hubo_clic else "false",
            "clic_en": (momento + timedelta(seconds=rng.randint(2, 120))).isoformat()
                       if hubo_clic else "",
        })

    return impresiones


def generar_cuerpos(rng: random.Random, contenidos: list[dict]) -> list[dict]:
    """Cuerpo del contenido: bloques heterogeneos segun el tipo.

    Es el ejemplo canonico de dato no estructurado con esquema variable:
    un articulo tiene parrafos y citas, una galeria tiene imagenes con
    epigrafe y un podcast tiene transcripcion con marcas de tiempo.
    Normalizarlo en tablas exigiria una tabla por tipo de bloque.
    """
    cuerpos = []
    for contenido in contenidos:
        vocabulario = (VOCABULARIO.get(contenido["seccion_nombre"], [])
                       or VOCABULARIO[contenido["seccion_raiz"]])
        bloques = []

        for numero in range(1, rng.randint(4, 9)):
            sorteo = rng.random()
            if sorteo < 0.72:
                bloques.append({
                    "orden": numero,
                    "tipo": "parrafo",
                    "texto": " ".join(
                        f"El informe menciona {rng.choice(vocabulario)} como factor central."
                        for _ in range(rng.randint(2, 4))
                    ),
                })
            elif sorteo < 0.85:
                bloques.append({
                    "orden": numero,
                    "tipo": "cita",
                    "texto": f"Lo que cambio fue {rng.choice(vocabulario)}.",
                    "autor": rng.choice(NOMBRES) + " " + rng.choice(APELLIDOS),
                    "cargo": rng.choice(["analista", "funcionario", "vocero", "investigador"]),
                })
            else:
                bloques.append({
                    "orden": numero,
                    "tipo": "imagen",
                    "url": f"https://cdn.nexomedia.example/{contenido['cuerpo_ref']}-{numero}.jpg",
                    "epigrafe": f"Registro de {rng.choice(vocabulario)}",
                    "credito": rng.choice(["Prensa", "Agencia", "Archivo"]),
                })

        documento = {
            "_id": contenido["cuerpo_ref"],
            "contenido_id": contenido["id"],
            "formato": contenido["tipo_contenido_codigo"],
            "idioma": "es",
            "palabras": sum(len(b.get("texto", "").split()) for b in bloques),
            "bloques": bloques,
        }

        if contenido["tipo_contenido_codigo"] in ("video", "podcast"):
            documento["transcripcion"] = [
                {
                    "desde_seg": segundo,
                    "texto": f"Se analiza {rng.choice(vocabulario)} en detalle.",
                }
                for segundo in range(0, min(int(contenido["duracion_seg"] or 120), 600), 60)
            ]

        if contenido["tipo_contenido_codigo"] == "galeria":
            documento["fotos"] = [
                {"orden": i, "url": f"https://cdn.nexomedia.example/g{contenido['id']}-{i}.jpg"}
                for i in range(1, rng.randint(6, 15))
            ]

        cuerpos.append(documento)

    return cuerpos


def generar_comentarios(
    rng: random.Random, contenidos: list[dict], usuarios: list[dict]
) -> list[dict]:
    """Comentarios con respuestas EMBEBIDAS.

    Se embeben porque siempre se leen junto al comentario padre, son
    pocas por comentario y no se consultan por si solas. Si en cambio
    hubiera que rankear respuestas de forma global, convendria
    referenciarlas: el criterio es el patron de acceso, no el gusto.
    """
    publicados = [c for c in contenidos if c["estado"] == "publicado"]
    comentarios = []
    numero = 0

    for contenido in publicados:
        if rng.random() > 0.35:
            continue
        for _ in range(rng.randint(1, 5)):
            numero += 1
            autor = rng.choice(usuarios)
            momento = datetime.fromisoformat(contenido["fecha_publicacion"]) + timedelta(
                hours=rng.randint(1, 200)
            )
            if momento > FECHA_CORTE:
                continue

            respuestas = []
            for indice_respuesta in range(rng.choices([0, 1, 2], weights=[0.6, 0.3, 0.1], k=1)[0]):
                respondedor = rng.choice(usuarios)
                respuestas.append({
                    "orden": indice_respuesta + 1,
                    "usuario_id": respondedor["id"],
                    "texto": rng.choice([
                        "Coincido con el analisis.",
                        "Faltan datos de contexto.",
                        "Buena cobertura del tema.",
                    ]),
                    "creado_en": (momento + timedelta(hours=indice_respuesta + 1)).isoformat(),
                })

            comentarios.append({
                "_id": f"COM-{numero:07d}",
                "contenido_id": contenido["id"],
                "usuario_id": autor["id"],
                "texto": rng.choice([
                    "Me parece que el enfoque deja afuera lo mas importante.",
                    "Muy claro el resumen, gracias por la nota.",
                    "Seria util ver la serie historica completa.",
                    "No estoy de acuerdo con la conclusion.",
                ]),
                "creado_en": momento.isoformat(),
                "estado_moderacion": rng.choices(
                    ["aprobado", "pendiente", "rechazado"], weights=[0.86, 0.10, 0.04], k=1
                )[0],
                "respuestas": respuestas,
            })

    return comentarios


def generar_busquedas(
    rng: random.Random, usuarios: list[dict], contenidos: list[dict], etiquetas: list[dict]
) -> list[dict]:
    publicados = [c["id"] for c in contenidos if c["estado"] == "publicado"]
    busquedas = []

    for numero in range(1, int(len(usuarios) * 2.5) + 1):
        usuario = rng.choice(usuarios)
        termino = rng.choice(etiquetas)["nombre"]
        momento = FECHA_INICIO + timedelta(
            days=rng.randint(0, DIAS_VENTANA - 1), hours=hora_sesgada(rng)
        )
        resultados = rng.sample(publicados, k=min(len(publicados), rng.randint(3, 10)))

        busquedas.append({
            "_id": f"BUS-{numero:07d}",
            "usuario_id": usuario["id"],
            "sesion_id": f"S-{usuario['id']:06d}-{momento.strftime('%Y%m%d%H')}",
            "texto": termino,
            "filtros": {
                "seccion": rng.choice([None] + sorted({c["seccion_raiz"] for c in contenidos})),
                "tipo": rng.choice([None, "articulo", "video", "podcast"]),
            },
            "resultados": resultados,
            "clics": rng.sample(resultados, k=min(len(resultados), rng.randint(0, 2))),
            "ocurrido_en": momento.isoformat(),
        })

    return busquedas


def generar_telemetria(rng: random.Random, contenidos: list[dict], usuarios: list[dict],
                       cantidad: int) -> list[dict]:
    """Latidos de reproduccion: la serie temporal del reproductor.

    Va a una coleccion timeseries de MongoDB. Es el caso en el que la
    coleccion especializada gana: muchisimas escrituras chicas, siempre
    ordenadas por tiempo, que se consultan por rango y nunca se editan.
    """
    reproducibles = [c for c in contenidos
                     if c["estado"] == "publicado" and c["duracion_seg"]]
    if not reproducibles:
        return []

    telemetria = []
    for _ in range(cantidad):
        contenido = rng.choice(reproducibles)
        usuario = rng.choice(usuarios)
        inicio = datetime.fromisoformat(contenido["fecha_publicacion"]) + timedelta(
            days=rng.randint(0, 20), hours=hora_sesgada(rng)
        )
        if inicio > FECHA_CORTE:
            inicio = FECHA_CORTE - timedelta(hours=rng.randint(1, 72))

        telemetria.append({
            "ocurrido_en": inicio.isoformat(),
            "medicion": {
                "segundo_reproduccion": rng.randint(0, int(contenido["duracion_seg"])),
                "buffer_ms": rng.randint(0, 1800),
                "calidad": rng.choice(["360p", "720p", "1080p"]),
            },
            "origen": {
                "contenido_id": contenido["id"],
                "usuario_id": usuario["id"],
                "dispositivo": elegir(rng, DISPOSITIVOS, PESOS_DISPOSITIVO),
            },
        })

    return telemetria


def escribir_csv(ruta: Path, filas: list[dict], columnas: list[str]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with ruta.open("w", encoding="utf-8", newline="") as archivo:
        escritor = csv.DictWriter(
            archivo, fieldnames=columnas, extrasaction="ignore", quoting=csv.QUOTE_ALL
        )
        escritor.writeheader()
        escritor.writerows(filas)
    print(f"  {ruta.name:32s} {len(filas):>8d} filas")


def escribir_json(ruta: Path, documentos: list[dict]) -> None:
    ruta.parent.mkdir(parents=True, exist_ok=True)
    with ruta.open("w", encoding="utf-8") as archivo:
        archivo.write("[\n")
        for indice, documento in enumerate(documentos):
            coma = "," if indice < len(documentos) - 1 else ""
            archivo.write(json.dumps(documento, ensure_ascii=False, sort_keys=True) + coma + "\n")
        archivo.write("]\n")
    print(f"  {ruta.name:32s} {len(documentos):>8d} documentos")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--semilla", type=int, default=int(os.environ.get("SEMILLA", "42")),
                        help="Semilla del generador. Fija el dataset por completo.")
    parser.add_argument("--escala", choices=sorted(ESCALAS), default=os.environ.get("ESCALA", "media"),
                        help="Volumen del dataset.")
    parser.add_argument("--salida", type=Path,
                        default=Path("/workspace/data/generado"),
                        help="Directorio de salida.")
    argumentos = parser.parse_args()

    rng = random.Random(argumentos.semilla)
    escala = ESCALAS[argumentos.escala]

    print(f"--- Generando dataset (escala={argumentos.escala}, semilla={argumentos.semilla}) ---")

    secciones = construir_secciones()
    etiquetas, etiquetas_por_seccion = construir_etiquetas(secciones)
    usuarios = generar_usuarios(rng, escala["usuarios"])
    suscripciones = generar_planes_y_suscripciones(rng, usuarios)
    asignar_afinidades(rng, usuarios, secciones)

    # Los primeros 40 usuarios son la redaccion: editores y moderadores.
    editores = [u["id"] for u in usuarios[:30]]
    moderadores = [u["id"] for u in usuarios[30:40]]

    contenidos, contenidos_etiquetas = generar_contenidos(
        rng, escala["contenidos"], secciones, etiquetas_por_seccion, editores
    )
    versiones, moderaciones = generar_historial_editorial(rng, contenidos, editores, moderadores)
    preferencias = generar_preferencias(rng, usuarios, secciones, etiquetas)
    impresiones = generar_impresiones(rng, escala["impresiones"], usuarios, contenidos)
    eventos = generar_eventos(rng, escala["eventos"], usuarios, contenidos)
    cuerpos = generar_cuerpos(rng, contenidos)
    comentarios = generar_comentarios(rng, contenidos, usuarios)
    busquedas = generar_busquedas(rng, usuarios, contenidos, etiquetas)
    telemetria = generar_telemetria(rng, contenidos, usuarios, escala["eventos"] // 5)

    roles = [
        {"id": 1, "codigo": "lector", "nombre": "Lector", "descripcion": "Usuario final del portal"},
        {"id": 2, "codigo": "suscriptor", "nombre": "Suscriptor", "descripcion": "Lector con plan pago"},
        {"id": 3, "codigo": "editor", "nombre": "Editor", "descripcion": "Crea y edita contenidos"},
        {"id": 4, "codigo": "moderador", "nombre": "Moderador", "descripcion": "Revisa y modera"},
        {"id": 5, "codigo": "analista", "nombre": "Analista", "descripcion": "Consulta indicadores"},
        {"id": 6, "codigo": "administrador", "nombre": "Administrador", "descripcion": "Gobierna la plataforma"},
    ]

    usuarios_roles = []
    for usuario in usuarios:
        rol_id = 1
        if usuario["id"] in editores:
            rol_id = 3
        elif usuario["id"] in moderadores:
            rol_id = 4
        elif usuario["plan"] == "premium":
            rol_id = 2
        usuarios_roles.append({
            "usuario_id": usuario["id"],
            "rol_id": rol_id,
            "otorgado_en": usuario["fecha_alta"],
            "otorgado_por": "",
        })
    # Un punado de analistas, para que el rol no quede vacio.
    for usuario in usuarios[40:46]:
        usuarios_roles.append({
            "usuario_id": usuario["id"], "rol_id": 5,
            "otorgado_en": usuario["fecha_alta"], "otorgado_por": "",
        })

    consentimientos = [
        {
            "usuario_id": u["id"],
            "finalidad": "personalizacion",
            "otorgado": u["consentimiento_personalizacion"],
            "registrado_en": u["fecha_alta"],
        }
        for u in usuarios
    ]

    asignaciones_ab = [
        {
            "experimento_codigo": "hibrido_vs_popularidad",
            "usuario_id": u["id"],
            "variante": "tratamiento" if u["id"] % 2 == 0 else "control",
            "asignado_en": FECHA_INICIO.isoformat(),
        }
        for u in usuarios
    ]

    print("\nPostgreSQL:")
    destino_pg = argumentos.salida / "postgres"
    escribir_csv(destino_pg / "roles.csv", roles, ["id", "codigo", "nombre", "descripcion"])
    escribir_csv(destino_pg / "secciones.csv", secciones,
                 ["id", "slug", "nombre", "seccion_padre_id", "activa"])
    escribir_csv(destino_pg / "etiquetas.csv", etiquetas, ["id", "slug", "nombre"])
    escribir_csv(destino_pg / "usuarios.csv", usuarios,
                 ["id", "email", "alias", "pais", "anio_nacimiento",
                  "consentimiento_personalizacion", "activo", "fecha_alta"])
    escribir_csv(destino_pg / "usuarios_roles.csv", usuarios_roles,
                 ["usuario_id", "rol_id", "otorgado_en", "otorgado_por"])
    escribir_csv(destino_pg / "suscripciones.csv", suscripciones,
                 ["id", "usuario_id", "plan_codigo", "desde", "hasta", "estado"])
    escribir_csv(destino_pg / "consentimientos.csv", consentimientos,
                 ["usuario_id", "finalidad", "otorgado", "registrado_en"])
    escribir_csv(destino_pg / "contenidos.csv", contenidos,
                 ["id", "titulo", "bajada", "tipo_contenido_codigo", "seccion_id", "autor_id",
                  "estado", "nivel_acceso", "idioma", "fecha_publicacion", "vigente_hasta",
                  "duracion_seg", "cuerpo_ref", "metadatos", "creado_en", "actualizado_en"])
    escribir_csv(destino_pg / "contenidos_etiquetas.csv", contenidos_etiquetas,
                 ["contenido_id", "etiqueta_id", "relevancia"])
    escribir_csv(destino_pg / "versiones_contenido.csv", versiones,
                 ["id", "contenido_id", "numero_version", "editor_id", "cambios",
                  "comentario", "creado_en"])
    escribir_csv(destino_pg / "moderaciones.csv", moderaciones,
                 ["id", "objeto_tipo", "objeto_id", "contenido_id", "moderador_id",
                  "accion", "motivo", "creado_en"])
    escribir_csv(destino_pg / "preferencias_usuario.csv", preferencias,
                 ["id", "usuario_id", "seccion_id", "etiqueta_id", "tipo_preferencia",
                  "peso", "actualizado_en"])
    escribir_csv(destino_pg / "asignaciones_ab.csv", asignaciones_ab,
                 ["experimento_codigo", "usuario_id", "variante", "asignado_en"])
    escribir_csv(destino_pg / "impresiones.csv", impresiones,
                 ["usuario_id", "contenido_id", "estrategia_codigo", "posicion", "score",
                  "variante_ab", "superficie", "mostrado_en", "clic", "clic_en"])

    print("\nMongoDB:")
    destino_mongo = argumentos.salida / "mongo"
    escribir_json(destino_mongo / "cuerpos_contenido.json", cuerpos)
    escribir_json(destino_mongo / "comentarios.json", comentarios)
    escribir_json(destino_mongo / "busquedas.json", busquedas)
    escribir_json(destino_mongo / "eventos_interaccion.json", eventos)
    escribir_json(destino_mongo / "telemetria_reproduccion.json", telemetria)

    # El resumen se guarda para que los cargadores y las verificaciones
    # comparen contra el, en lugar de contra constantes repetidas.
    resumen = {
        "semilla": argumentos.semilla,
        "escala": argumentos.escala,
        "fecha_inicio": FECHA_INICIO.isoformat(),
        "fecha_corte": FECHA_CORTE.isoformat(),
        "conteos": {
            "roles": len(roles),
            "secciones": len(secciones),
            "etiquetas": len(etiquetas),
            "usuarios": len(usuarios),
            "usuarios_roles": len(usuarios_roles),
            "suscripciones": len(suscripciones),
            "consentimientos": len(consentimientos),
            "contenidos": len(contenidos),
            "contenidos_etiquetas": len(contenidos_etiquetas),
            "versiones_contenido": len(versiones),
            "moderaciones": len(moderaciones),
            "preferencias_usuario": len(preferencias),
            "asignaciones_ab": len(asignaciones_ab),
            "impresiones": len(impresiones),
            "eventos_interaccion": len(eventos),
            "cuerpos_contenido": len(cuerpos),
            "comentarios": len(comentarios),
            "busquedas": len(busquedas),
            "telemetria_reproduccion": len(telemetria),
        },
    }
    ruta_resumen = argumentos.salida / "resumen.json"
    ruta_resumen.write_text(json.dumps(resumen, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"\nResumen escrito en {ruta_resumen}")
    print(f"Contenidos publicados: {sum(1 for c in contenidos if c['estado'] == 'publicado')}")
    print("Dataset generado.")


if __name__ == "__main__":
    main()
