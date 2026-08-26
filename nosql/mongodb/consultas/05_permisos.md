# 05. Permisos y aislamiento en MongoDB

Este archivo se ejecuta con **usuarios restringidos**, no con la cuenta root. Los crea
[`nosql/mongodb/02_usuarios_y_permisos.js`](../02_usuarios_y_permisos.js).

> **IMPORTANTE:** varios bloques **deben fallar**. Ese es el objetivo. Un permiso que nunca se
> prueba es un permiso que nadie sabe si funciona.

## Abrir las sesiones

Usuario de lectura analítica:

```bash
docker compose exec mongodb-eventos mongosh \
  -u bdia_mongo_lectura -p lectura_local \
  --authenticationDatabase bdia_nexomedia bdia_nexomedia
```

Usuario de ingesta:

```bash
docker compose exec mongodb-eventos mongosh \
  -u bdia_mongo_ingesta -p ingesta_local \
  --authenticationDatabase bdia_nexomedia bdia_nexomedia
```

---

## Qué puede hacer cada usuario

**Objetivo:** ver los privilegios efectivos antes de probarlos.

Como administrador:

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
practica.getUsers();
practica.getRoles({ showPrivileges: true, showBuiltinRoles: false });
```

### Comandos y operadores

| Elemento/sintaxis | Qué hace | Para qué se utiliza acá |
|---|---|---|
| `getUsers()` | Lista usuarios y sus roles | Confirma qué rol tiene cada uno |
| `getRoles({showPrivileges: true})` | Detalla las acciones de cada rol | Muestra el permiso por **acción** y por **colección** |

**Observá:** los privilegios se expresan como `{resource: {db, collection}, actions: [...]}`.
La granularidad llega hasta la **colección**, no hasta el documento.

---

## Lo que el usuario de lectura SÍ puede

**Objetivo:** comprobar que el perfil analítico funciona para lo que tiene que funcionar.

```javascript
db.eventos_interaccion.countDocuments({});
```

```javascript
db.eventos_interaccion.aggregate([
    { $match: { tipo_evento: "vista" } },
    { $group: { _id: "$contexto.dispositivo", eventos: { $sum: 1 } } },
    { $sort: { eventos: -1 } }
]).toArray();
```

```javascript
db.cuerpos_contenido.findOne({ formato: "articulo" });
```

**Qué hace:** el análisis de consumo completo, sin credenciales administrativas.

---

## Bloques que DEBEN fallar

### 1. Leer los comentarios

```javascript
db.comentarios.findOne();
```

> Error esperado: `not authorized on bdia_nexomedia to execute command { find: "comentarios" ... }`

**Por qué:** `comentarios` es la única colección con **texto libre escrito por personas**. Un
esquema puede garantizar la forma de un documento, no que alguien no haya dejado un teléfono o un
domicilio dentro de un comentario. El perfil analítico no la necesita, así que no la tiene.

Es el mismo criterio que en PostgreSQL deja al analista fuera de `personas.usuarios`.

### 2. Escribir un evento

```javascript
db.eventos_interaccion.insertOne({
    evento_id: "EV-INTRUSO-01",
    usuario_id: NumberInt(1),
    contenido_id: NumberInt(1),
    tipo_evento: "vista",
    ocurrido_en: new Date()
});
```

> Error esperado: `not authorized ... { insert: "eventos_interaccion" ... }`

**Por qué:** leer y escribir son perfiles distintos. Quien analiza no fabrica datos.

### 3. Borrar

```javascript
db.eventos_interaccion.deleteMany({ tipo_evento: "vista" });
```

> Error esperado: `not authorized ... { delete: "eventos_interaccion" ... }`

### 4. Crear un índice

```javascript
db.eventos_interaccion.createIndex({ pais: 1 });
```

> Error esperado: `not authorized ... { createIndexes: ... }`

**Por qué:** un índice mal elegido sobre una colección de cientos de miles de documentos degrada
la escritura de todo el sistema. Es una operación de administración, no de análisis.

---

## El usuario de ingesta: el espejo

Con la sesión de `bdia_mongo_ingesta`:

```javascript
db.eventos_interaccion.insertOne({
    evento_id: "EV-INGESTA-01",
    usuario_id: NumberInt(1),
    sesion_id: "S-000001-prueba",
    contenido_id: NumberInt(1),
    tipo_evento: "vista",
    ocurrido_en: new Date(),
    contexto: { dispositivo: "movil", canal: "directo", pais: "AR", superficie: "home" }
});
```

**Qué hace:** funciona. Es el único permiso que tiene.

Y ahora el que **debe fallar**:

```javascript
db.eventos_interaccion.findOne();
```

> Error esperado: `not authorized ... { find: "eventos_interaccion" ... }`

**Por qué esto importa:** es el usuario con el que corre
[`orquestador/consumir_stream.py`](../../../orquestador/consumir_stream.py), el proceso que drena
el stream de Redis. Ese proceso escucha tráfico entrante, así que es el más expuesto del sistema.
Si quedara comprometido, **no serviría para exfiltrar el historial de nadie**, porque no puede
leerlo.

Es el principio de mínimo privilegio aplicado donde más rinde: el componente más expuesto es el
que menos puede hacer.

Limpiar la prueba, como administrador:

```javascript
const practica = db.getSiblingDB("bdia_nexomedia");
practica.eventos_interaccion.deleteMany({ evento_id: /^EV-INGESTA-/ });
```

---

## El límite de MongoDB, declarado

MongoDB **no tiene un equivalente al Row Level Security de PostgreSQL.**

No se puede expresar "este usuario solo ve los documentos cuyo `usuario_id` sea el suyo". O ve la
colección entera, o no la ve. Comprobalo: no hay ninguna forma de escribir el rol de arriba que
restrinja por valor de campo.

| Motor | Granularidad máxima del control de acceso |
|---|---|
| **PostgreSQL** | Tabla, **columna** y **fila** (RLS) |
| **MongoDB** | Base de datos, colección y acción |
| **Redis** | Comando y patrón de clave |
| **Neo4j Community** | Ninguna: usuario o nada |

Esa asimetría es la razón concreta por la que **los datos personales de este sistema viven en
PostgreSQL**, y en MongoDB solo hay comportamiento referenciado por id. No es una preferencia:
es el único motor del stack que puede imponer el aislamiento entre personas.

### Cómo se compensa

1. El clickstream guarda `usuario_id`, nunca correo ni nombre.
2. El export al lakehouse reemplaza el id por un seudónimo
   ([`orquestador/exportar_bronze.py`](../../../orquestador/exportar_bronze.py)).
3. El índice TTL acota cuánto tiempo existe el dato crudo.
4. Los dos perfiles de acceso están separados, que es lo que sí permite el motor.

Ninguna de las cuatro reemplaza al RLS. Juntas hacen que su ausencia deje de ser crítica, porque
lo que MongoDB guarda ya no alcanza para identificar a nadie.
