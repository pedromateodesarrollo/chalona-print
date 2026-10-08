# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). El número de
protocolo del WebSocket va aparte y se documenta en `docs/protocolo-ws.md`.

## 0.4.0 — 2026-10-08

### Agente en Windows: vuelve la ventana

* Lo que se descarga para Windows ya no es el agente solo sino una ventana
  (`agente/windows`, C# sobre .NET Framework 4.8, que viene con Windows 10 y
  11) con el agente dentro. Se conecta desde ahí, enseña el estado, las
  impresoras, la página de prueba y el registro, e instala o desinstala.
* **Queda como servicio de Windows de verdad** y arranca con la máquina aunque
  nadie inicie sesión. Con la 0.2 el doble clic no pedía permiso de
  administrador: la tarea de arranque no se podía crear y el agente se quedaba
  en primer plano, imprimía ese día y desaparecía al reiniciar. Ahora cada
  acción que lo necesita pide permiso a Windows (los botones llevan el escudo).
* El servicio vigila al agente y lo levanta si se cae, y lo mete en un «job»
  de Windows: si el servicio muere, no queda un agente huérfano conectado con
  la misma credencial.
* La configuración, que lleva la credencial del agente, queda solo para SYSTEM
  y administradores. Antes la heredaba de ProgramData y la podía leer
  cualquier usuario de la computadora.
* Lo que dice el agente queda en `ProgramData\print-server\agente.log`.
* Instalar encima de una versión anterior la retira —las tareas programadas de
  la 0.2 y el servicio de la 0.3.0— y trae su conexión, también desde la
  carpeta de antes del cambio de nombre (`ProgramData\chalona-print`): no hace
  falta una llave nueva.
* La 0.3.0 fue la primera con ventana. Se instaló en varias computadoras, pero
  su código nunca llegó a este repositorio; esta versión la rehace.
* `instalar.ps1` usa el mismo paquete, sin ventana.

### Agente

* El panel local dice si el agente corre como servicio (`modo`).
* La página de prueba del panel sale en el lenguaje de cada impresora (EPL,
  ZPL o texto), como la que manda el hub. Antes mandaba texto, que una
  etiquetadora no imprime.
* Los fallos al conectar se explican en español y dicen qué revisar, sin
  «Invalid argument(s)» ni «Bad state».
* En Windows, `print-server-agente instalar` ya no crea tareas programadas:
  con el servicio puesto, serían dos agentes con la misma credencial.

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
