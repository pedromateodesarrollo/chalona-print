# Cambios

Las versiones siguen [SemVer](https://semver.org/lang/es/). El número de
protocolo del WebSocket va aparte y se documenta en `docs/protocolo-ws.md`.

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
