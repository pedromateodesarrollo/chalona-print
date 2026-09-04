# chalona-print

Imprime desde donde sea, en la impresora que quieras, sin abrir un puerto.

Un terminal en el pasillo del almacén, un ERP en otro país o un script de dos
líneas mandan un trabajo por HTTP; el hub lo encola y la computadora que tiene
la impresora lo recoge por un WebSocket que abrió ella misma. Ni IP fija, ni
VPN, ni redirección de puertos en casa del cliente.

```
  Tu aplicación                    Hub                      Agente
  ─────────────                ───────────              ──────────────
  POST /v1/trabajos  ───────►  cola + estado  ◄────────  WebSocket saliente
                               REST + panel               spooler del sistema
                                                          (winspool / CUPS)
```

## Qué resuelve

* **Impresoras de red que no lo son.** Una térmica USB colgada de una PC pasa a
  estar disponible para cualquier aplicación autorizada.
* **Redes ajenas.** El agente marca hacia el hub; el firewall del cliente ni se
  entera.
* **Duplicados.** Cada trabajo lleva llave de idempotencia y el agente recuerda
  lo que ya imprimió. Un reintento no saca la etiqueta dos veces.
* **Colas.** Si la computadora está apagada, el trabajo espera; cuando vuelve,
  sale. Y si esperó demasiado, se descarta en vez de escupir el trabajo de ayer.

## Instalar el agente

Bájate el ejecutable, córrelo y contesta dos cosas: la dirección del hub y una
llave de API.

```bash
chalona-print-agente configurar --hub https://print.chalonasoft.com --llave cpk_...
chalona-print-agente instalar
```

En Windows basta con hacer doble clic: abre un asistente en el navegador, se
registra, se instala como tarea de arranque y deja un icono junto al reloj.

## Imprimir

```bash
curl -X POST https://print.chalonasoft.com/v1/trabajos \
  -H "authorization: Bearer cpk_tu_llave" \
  -H "content-type: application/json" \
  -d '{
        "impresora_nombre": "Etiquetas recepción",
        "formato": "raw",
        "contenido_b64": "XlhBXkZPNTAsNTBeQTBOLDQwXkZESG9sYV5GU15YWg==",
        "idempotencia": "mov-8891"
      }'
```

`formato` puede ser `raw` (ZPL, EPL, ESC/POS, PCL), `pdf`, `imagen` o `texto`.
El PDF y las imágenes salen solos en Linux y macOS —los resuelve CUPS—; en
Windows hacen falta un ayudante externo, y si no está, el agente lo dice y el
hub rechaza el trabajo en vez de tragárselo.

## Levantar tu propio hub

```bash
docker compose up -d
```

O a pelo:

```bash
cd hub
dart pub get
PRINT_DATABASE_URL=postgres://usuario:clave@localhost:5432/chalona_print \
  dart run bin/chalona_print_hub.dart
```

Necesita un Postgres y nada más. Las migraciones se aplican solas al arrancar.

| Variable | Por defecto | Para qué |
|---|---|---|
| `PRINT_DATABASE_URL` | — | Obligatoria |
| `PRINT_PUERTO` | 3070 | |
| `PRINT_SECRETO_JWT` | aleatoria | Fíjala: si cambia, se cierran todas las sesiones |
| `PRINT_REGISTRO` | `abierto` | `abierto`, `invitacion` o `cerrado` |
| `PRINT_CORS` | `*` | Lista de orígenes separada por comas |
| `PRINT_MAX_TRABAJO_MB` | 8 | Tope del contenido de un trabajo |
| `PRINT_TTL_HORAS` | 24 | Cuánto espera un trabajo antes de darse por perdido |
| `PRINT_MANAGER` | `manager` | Carpeta del sitio compilado |

## Cómo está armado

| Carpeta | Qué hay |
|---|---|
| `hub/` | Servidor: REST, WebSocket de agentes, cola. Dart, dos dependencias |
| `agente/` | El servicio que se instala junto a las impresoras. Dart, una dependencia |
| `manager/` | Sitio web: presentación, documentación y panel de administración |
| `docs/` | Protocolo del WebSocket y referencia del API |

## Licencia

Apache-2.0. Úsalo, cámbialo, móntalo para tus clientes.
