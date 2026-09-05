# Seguridad

## Reportar un fallo

Escribe a **pedromateo.desarrollo@gmail.com** con «print-server» en el asunto.
Si el fallo permite imprimir en impresoras ajenas, leer trabajos de otra
organización o suplantar a un agente, dilo en la primera línea.

No abras un issue público para eso. Para todo lo demás, los issues son el sitio.

## Qué puede hacer cada pieza

Conviene saberlo antes de instalar esto en la computadora de un cliente.

**El agente** corre como servicio del sistema —SYSTEM en Windows, root en
Linux— porque necesita llegar al spooler. Manda al spooler los bytes que le
llegan del hub, tal cual, sin interpretarlos: es lo que hace falta para ZPL o
ESC/POS. No lee archivos, no abre puertos hacia fuera y no acepta conexiones
entrantes salvo su panel local en `127.0.0.1`.

**El hub** puede mandar a imprimir en cualquier impresora de cualquier agente
conectado. Un hub comprometido —o una llave de API filtrada— puede gastar papel
y etiquetas, o imprimir lo que quiera en un sitio físico al que quizá no debería
llegar. No puede leer nada de la máquina del agente.

**El panel local del agente** (`127.0.0.1:7717`) no pide clave. Enseña el estado
y permite una impresión de prueba. Es deliberado: quien está sentado en esa
computadora ya podría imprimir desde cualquier programa. Escucha solo en
loopback, así que nadie de la red lo alcanza.

## Cómo se guardan las credenciales

| Qué | Cómo |
|---|---|
| Claves de usuario | PBKDF2-HMAC-SHA256, 210 000 iteraciones, sal por clave |
| Llaves de API | Solo el sha256 del secreto. El secreto se enseña una vez |
| Credenciales de agente | Igual: solo el hash |
| Sesiones del panel | JWT HS256 con `PRINT_SECRETO_JWT`, siete días |

Las comparaciones van en tiempo constante. La llave de API no se guarda en la
máquina del agente: se usa una vez para darlo de alta y lo que queda es la
credencial de ese agente, revocable por separado.

## El contenido de los trabajos

Va en la base de datos, sin cifrar, hasta que se imprime. Puede ser una factura.

Pasado `PRINT_RETENCION_DIAS` (siete por defecto) se borra el contenido de los
trabajos terminados y queda solo el historial: cuándo se mandó, a dónde y qué
contestó el agente. Si tus documentos son sensibles, baja ese número.

El registro del hub **no** escribe nunca contenido de trabajos ni credenciales.

## Aislamiento

Cada organización ve lo suyo, y el filtro va en cada consulta. No hay RLS: el
aislamiento es del código, así que un fallo ahí es un fallo de aislamiento —por
eso interesa que lo reporten.

Dentro de una organización, un **dominio** acota una llave a una sucursal o a un
cliente. Una llave sin dominio alcanza toda la organización.

## Publicar ejecutables

`/descargas/` se sirve sin credencial: es lo que necesita una máquina que aún no
tiene ninguna. Por eso publicar está doblemente cerrado — solo los nombres
conocidos del agente, y solo la organización que levantó el hub
(`PRINT_ORG_PUBLICADORA`). Quien sustituye ese archivo le cambia el programa a
todos los que instalen desde ahí.

Los scripts de publicación comparan el sha256 antes de dar nada por publicado, y
`GET /v1/descargas` enseña el de cada archivo para que puedas comprobarlo tú.

## Lo que todavía no hace

Se dice aquí para que nadie lo dé por hecho:

* **No verifica el correo.** El registro abierto acepta cualquier dirección; en
  un hub expuesto a internet conviene `PRINT_REGISTRO=cerrado` o `invitacion`.
* **No firma los ejecutables.** Windows enseñará el aviso de SmartScreen.
* **No cifra el contenido en reposo.** Cífralo en el disco de la base si tus
  documentos lo piden.
* **No limita cuánto imprime una llave.** Una llave filtrada puede vaciarte un
  rollo de etiquetas antes de que la revoques.
