# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). El número de
protocolo del WebSocket va aparte y se documenta en `docs/protocolo-ws.md`.

## 0.2.3 — 2026-09-08

### Agente

* Las etiquetadoras Honeywell sin emulación en el nombre recibían texto plano.
  El driver solo pone `- ESim` / `- ZSim` cuando hay emulación; en su lenguaje
  nativo la cola se llama `- DP`, y ese nombre no tenía ninguna de las pistas
  que buscábamos. «Honeywell PC42t (203 dpi) - DP» y «Honeywell PC42E-T
  (203 dpi) - DP» caían a texto: la etiquetadora no sacaba nada y el trabajo
  quedaba en «hecho» —el fallo silencioso de siempre—. Ahora se reconocen por
  el sufijo `- DP` y por la familia del modelo (PC42, PC43, PD43, PM43), y se
  les manda EPL, que es lo que respondieron en la prueba con las máquinas
  delante. Una PC42t en `- ZSim` sigue recibiendo ZPL: la emulación declarada
  manda sobre la familia.

## 0.2.2 — 2026-09-04

### Agente

* La página de prueba fallaba en toda impresora con más de 30 caracteres en el
  nombre. El recorte remataba con puntos suspensivos, que no existen en latin1,
  y el trabajo moría al construirse —sin llegar al spooler— con un
  «Contains invalid characters» que no señalaba a ninguna parte. El nombre de
  la cola se limpia ahora antes de armar el comando, venga de donde venga.

## 0.2.1 — 2026-09-04

### Agente

* Windows: `correr` se moría nada más arrancar. Windows no tiene SIGTERM y
  `watch()` lo rechaza de forma asíncrona, así que el fallo no llegaba al
  `catch` sino que subía como excepción sin capturar. Instalado como tarea de
  SYSTEM no hay consola donde verlo: la máquina quedaba sin agente y sin un
  solo mensaje que lo dijera.
* `desinstalar` para el proceso además de borrar la tarea, y tolera que solo
  esté puesta una de las dos.
* El icono de la bandeja comprueba que el shell lo aceptó, en vez de quedarse
  corriendo para siempre sin icono y sin error.
* `instalar` sin ser administrador lo dice, en vez de un volcado de pila.

## 0.2.0 — 2026-09-04

### Agente

* La página de prueba la arma el agente, en el lenguaje de cada impresora:
  EPL, ZPL o texto. Ni el hub ni el panel saben qué habla la impresora de
  enfrente, y mandarle texto a una etiquetadora en modo ESim no imprime nada
  **y deja el trabajo en «hecho»**: falla en silencio.

### Hub

* Formato `prueba`, sin contenido: lo pone el agente. A los agentes anteriores
  a la 0.2.0 se les degrada a texto.

### Sitio

* Las impresoras se pueden filtrar por computadora.

## 0.1.0 — 2026-09-04

Primera versión pública.

### Hub

* REST y WebSocket en un solo proceso, sobre Postgres. Las migraciones se
  aplican al arrancar.
* Organizaciones, usuarios con rol, llaves de API con permisos y dominios que
  acotan una llave a una sucursal o a un cliente.
* Cola con llave de idempotencia, reenvío al reconectar y caducidad de lo que
  esperó demasiado.
* Historial por trabajo; el contenido se borra pasada la retención.
* Publica los ejecutables del agente en `/descargas`.

### Agente

* Windows por FFI al spooler (`winspool.drv`), Linux y macOS por CUPS.
* `raw`, `texto`, y `pdf`/`imagen` donde el sistema sabe rasterizarlos.
* Se instala con la dirección del hub y una llave; se registra solo.
* Servicio del sistema, icono en la bandeja de Windows y panel local.
* Registro en disco de lo ya impreso: un reenvío no imprime dos veces.

### Sitio

* Presentación, documentación del API generada desde una sola fuente y panel de
  administración.
