# API de print-server

Todo lo que hace el panel se puede hacer por API: no hay nada reservado a la interfaz. La base es la dirección de tu hub, y las respuestas son JSON.

> Generado desde `manager/src/docs.js` con `npm run docs`. No lo edites a mano.

## Autenticación

### Llave de API

Para las aplicaciones. Va en la cabecera `authorization: Bearer cpk_...` (también se acepta `x-api-key`). No caduca; se revoca desde el panel o por API.

```bash
curl -H "authorization: Bearer cpk_ab12cd34_..." https://TU-HUB/v1/impresoras
```

### Permisos de una llave

`trabajos:escribir` manda a imprimir · `trabajos:leer` consulta · `impresoras:leer` lista impresoras · `agentes:registrar` deja instalar agentes · `admin` abre todo el API, incluida la gestión de usuarios y de otras llaves.

### Llaves acotadas a un dominio

Una llave puede quedar encerrada en un dominio. Entonces solo ve sus impresoras, solo imprime ahí y los agentes que instale nacen en ese dominio. Sin dominio, la llave alcanza toda la organización.

### Sesión de persona

La del panel. `POST /v1/auth/login` devuelve un JWT que dura siete días y viaja en la misma cabecera.

## Dominios

### `GET /v1/dominios`

*Acceso: llave · sesión*

Los dominios de la organización, con cuántos agentes e impresoras tienen.

Un dominio agrupa computadoras, impresoras y llaves: una sucursal, un almacén, un cliente. Una llave acotada a un dominio solo se ve a sí misma.

### `POST /v1/dominios`

*Acceso: admin*

Crea un dominio.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `nombre` | texto | sí |  |
| `slug` | texto | no | Se deriva del nombre si no lo mandas |
| `descripcion` | texto | no |  |

### `PATCH /v1/dominios/:id`

*Acceso: admin*

Cambia nombre o descripción.

### `DELETE /v1/dominios/:id`

*Acceso: admin*

Borra un dominio vacío.

Con agentes o llaves dentro devuelve `409 dominio_en_uso`: borrarlo los dejaría fuera de toda regla de acceso, imprimiendo igual.

## Sesión

### `POST /v1/auth/registro`

*Acceso: público*

Crea una organización y su primer usuario administrador.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `correo` | texto | sí | Único en el hub |
| `clave` | texto | sí | Ocho caracteres o más |
| `organizacion` | texto | sí | Nombre visible |
| `nombre` | texto | no | De la persona |

Solo si el hub corre con PRINT_REGISTRO=abierto.

```json
{ "token": "eyJ...", "usuario": { "id": 1, "rol": "admin", "org": 1 } }
```

### `POST /v1/auth/login`

*Acceso: público*

Devuelve el token de sesión.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `correo` | texto | sí |  |
| `clave` | texto | sí |  |

```json
{ "token": "eyJ...", "usuario": { … } }
```

### `GET /v1/yo`

*Acceso: sesión*

Quién soy y a qué organización pertenezco.

## Impresoras

### `GET /v1/impresoras`

*Acceso: llave · sesión*

Las impresoras de la organización, con su estado actual.

| Parámetro | Tipo | | |
|---|---|---|---|
| `agente` | número | no | Filtra por agente |

Estados: `lista`, `ocupada`, `pausada`, `sin_papel`, `error`, `ausente` (el agente ya no la ve) y `sin_agente` (la computadora está apagada).

```json
{
  "impresoras": [{
    "id": 7,
    "nombre": "Etiquetas recepción",
    "sistema": "ZDesigner GK420d",
    "estado": "lista",
    "detalle": "",
    "cola": 0,
    "formatos": ["raw", "texto"],
    "agente": 2,
    "agente_conectado": true
  }]
}
```

### `GET /v1/impresoras/:id`

*Acceso: llave · sesión*

Una impresora.

### `PATCH /v1/impresoras/:id`

*Acceso: sesión*

Cambia el nombre visible o la marca de predeterminada.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `nombre` | texto | no | El nombre con el que la ve la gente |
| `predeterminada` | sí/no | no | Una por agente |

## Trabajos

### `POST /v1/trabajos`

*Acceso: llave · sesión*

Manda algo a imprimir.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `impresora` | número | sí* | Id de la impresora |
| `impresora_nombre` | texto | sí* | Alternativa al id: nombre visible o del sistema |
| `formato` | texto | no | `raw` (por defecto), `pdf`, `imagen`, `texto` o `prueba` |
| `contenido_b64` | texto | sí* | El contenido en base64 |
| `texto` | texto | sí* | Alternativa: texto plano, sin codificar |
| `copias` | número | no | 1 a 999 |
| `nombre` | texto | no | Cómo se llama el trabajo en la cola |
| `idempotencia` | texto | no | Llave para que un reintento no imprima dos veces |
| `opciones` | objeto | no | Opciones del driver, p. ej. `{"cups.media": "A4"}` |

`impresora` o `impresora_nombre`, y `contenido_b64` o `texto`. Si mandas `idempotencia` y esa llave ya existe, se devuelve el trabajo anterior con `"repetido": true` y **no se imprime otra vez**.

El formato `prueba` va sin contenido: la arma el agente en el lenguaje que hable esa impresora (EPL, ZPL o texto). Es la única forma de que una prueba funcione tanto en una láser como en una etiquetadora.

```json
{
  "id": 128,
  "estado": "enviado",
  "impresora": 7,
  "agente_conectado": true
}
```

```bash
curl -X POST https://TU-HUB/v1/trabajos \
  -H "authorization: Bearer cpk_..." \
  -H "content-type: application/json" \
  -d '{
        "impresora_nombre": "Etiquetas recepción",
        "formato": "raw",
        "contenido_b64": "XlhBXkZPNTAsNTBeQTBOLDQwXkZESG9sYV5GU15YWg==",
        "idempotencia": "mov-8891"
      }'
```

### `GET /v1/trabajos`

*Acceso: llave · sesión*

Los últimos trabajos.

| Parámetro | Tipo | | |
|---|---|---|---|
| `estado` | texto | no | en_cola, enviado, imprimiendo, hecho, fallido, cancelado |
| `impresora` | número | no |  |
| `limite` | número | no | Hasta 200; por defecto 50 |

### `GET /v1/trabajos/:id`

*Acceso: llave · sesión*

Un trabajo con su historia: cuándo se encoló, se envió y qué contestó el agente.

### `POST /v1/trabajos/:id/cancelar`

*Acceso: llave · sesión*

Cancela un trabajo que todavía no salió.

Solo mientras está `en_cola` o `enviado`. Lo que ya imprimió, imprimió.

## Agentes

### `GET /v1/agentes`

*Acceso: llave · sesión*

Las computadoras con agente y si están conectadas ahora mismo.

### `POST /v1/agentes/registrar`

*Acceso: llave (agentes:registrar)*

Da de alta una computadora y devuelve su credencial.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `huella` | texto | sí | Identidad estable de la máquina |
| `nombre` | texto | no |  |
| `dominio` | número o slug | no | Solo si la llave no está acotada ya |
| `plataforma` | texto | no |  |
| `version` | texto | no |  |

Lo llama el agente solo al instalarse; no hay que ejecutarlo a mano. Es idempotente por `huella`: reinstalar renueva la credencial en vez de duplicar el agente.

```json
{ "agente": 2, "credencial": "cag_2_..." }
```

### `PATCH /v1/agentes/:id`

*Acceso: sesión*

Le cambia el nombre.

### `POST /v1/agentes/:id/revocar`

*Acceso: admin*

Le quita la credencial y lo desconecta al instante.

### `DELETE /v1/agentes/:id`

*Acceso: admin*

Lo borra junto con sus impresoras.

## Llaves

### `GET /v1/llaves`

*Acceso: admin*

Las llaves de la organización (nunca el secreto).

### `POST /v1/llaves`

*Acceso: admin*

Crea una llave. El secreto se enseña una sola vez.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `nombre` | texto | sí | Para saber después qué la usa |
| `permisos` | lista | no | Por defecto: imprimir, leer impresoras y registrar agentes |
| `dominio` | número o slug | no | Acota la llave a un dominio; vacío = toda la organización |

```json
{ "id": 3, "prefijo": "ab12cd34", "llave": "cpk_ab12cd34_…" }
```

### `DELETE /v1/llaves/:id`

*Acceso: admin*

La revoca. La fila queda para saber qué imprimió.

## Usuarios

### `GET /v1/usuarios`

*Acceso: admin*

Los usuarios de la organización.

### `POST /v1/usuarios`

*Acceso: admin*

Da de alta a alguien.

| Campo | Tipo | Obligatorio | |
|---|---|---|---|
| `correo` | texto | sí |  |
| `clave` | texto | sí |  |
| `rol` | texto | no | `admin` u `operador` |
| `nombre` | texto | no |  |

### `POST /v1/usuarios/:id/clave`

*Acceso: sesión*

Cambia una clave. La propia siempre; la de otros, con rol admin.

### `DELETE /v1/usuarios/:id`

*Acceso: admin*

Da de baja a alguien.

## Descargas

### `GET /v1/descargas`

*Acceso: público*

Qué ejecutables del agente publica este hub, con tamaño y sha256.

Público a propósito: una máquina que va a instalar el agente todavía no tiene credencial ninguna.

```json
{
  "descargas": [{
    "archivo": "print-server-agente-linux-x64",
    "url": "/descargas/print-server-agente-linux-x64",
    "sistema": "linux",
    "bytes": 7617144,
    "sha256": "…"
  }]
}
```

### `GET /descargas/:archivo`

*Acceso: público*

Baja un ejecutable o el script de instalación.

### `POST /v1/descargas/:archivo`

*Acceso: admin de la organización publicadora*

Publica un ejecutable. El cuerpo son los bytes, sin envolver.

Solo se aceptan los nombres conocidos del agente y los dos instaladores: la carpeta se sirve sin credencial, y admitir un nombre cualquiera sería admitir escritura en ella. Y solo publica la organización que levantó el hub (`PRINT_ORG_PUBLICADORA`, por defecto 1): las descargas son del hub entero, no de una organización. Lo usan `agente/publicar.ps1` y `agente/publicar.sh`; **compara el sha256 que devuelve** con el del archivo local antes de darlo por publicado.

```json
{ "archivo": "…", "url": "/descargas/…", "bytes": 7617144, "sha256": "…" }
```

```bash
curl -X POST https://TU-HUB/v1/descargas/print-server-agente-linux-x64 \
  -H "authorization: Bearer cpk_admin" \
  -H "content-type: application/octet-stream" \
  --data-binary @print-server-agente-linux-x64
```

### `DELETE /v1/descargas/:archivo`

*Acceso: admin de la organización publicadora*

Retira un ejecutable publicado.

## Salud

### `GET /salud`

*Acceso: público*

Comprueba que el hub responde y llega a su base de datos.

## Errores

| HTTP | Código | Cuándo |
|---|---|---|
| 401 | `no_autenticado` | Falta la credencial o no vale |
| 403 | `sin_permiso` · `requiere_admin` | La llave no llega a tanto |
| 404 | `impresora_no_encontrada` | Ni por id ni por nombre |
| 409 | `impresora_ambigua` | Dos impresoras con ese nombre; manda el id |
| 409 | `dominio_en_uso` | El dominio todavía tiene agentes o llaves |
| 403 | `no_publicas_aqui` | Publicar descargas es de la organización que levantó el hub |
| 409 | `impresora_ausente` | El agente ya no la ve en su sistema |
| 413 | `contenido_grande` | Pasa del tope del hub |
| 415 | `formato_no_soportado` | Esa impresora no admite ese formato |
| 429 | `demasiados_intentos` | Freno del login |
