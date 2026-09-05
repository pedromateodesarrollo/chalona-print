# print-server

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

Los ejecutables están en
[releases](https://github.com/pedromateodesarrollo/print-server/releases), y tu
propio hub los sirve en `/descargas/` una vez publicados.

En Windows basta con hacer doble clic: abre un asistente en el navegador, se
registra, se instala como servicio de arranque y deja un icono junto al reloj.

En Linux y macOS, una línea:

```bash
curl -fsSL https://tu-hub/descargas/instalar.sh | sudo bash -s -- \
  --hub https://tu-hub --llave cpk_...
```

O a mano, con el binario ya bajado:

```bash
print-server-agente configurar --hub https://print.chalonasoft.com --llave cpk_...
print-server-agente instalar
```

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
PRINT_DATABASE_URL=postgres://usuario:clave@localhost:5432/print_server \
  dart run bin/print_server_hub.dart
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

## Publicar los ejecutables en tu hub

El hub sirve los ejecutables del agente en `/descargas/`, y los scripts los
compilan y los suben:

```bash
cd agente
./publicar.sh --hub https://tu-hub --llave cpk_llave_admin      # Linux y macOS
```

```powershell
cd agente
.\publicar.ps1 -Hub https://tu-hub -Llave cpk_llave_admin       # Windows
```

Windows necesita su propia máquina: `dart compile exe` genera para el sistema
donde corre y no cruza. Por eso hay dos scripts y no uno.

Publicar está reservado a la organización que levantó el hub
(`PRINT_ORG_PUBLICADORA`, por defecto la 1) y solo acepta los nombres conocidos
del agente: la carpeta se sirve sin credencial, así que dejar subir cualquier
nombre sería dejar escribir en ella.

## Cómo está armado

| Carpeta | Qué hay |
|---|---|
| `hub/` | Servidor: REST, WebSocket de agentes, cola. Dart, dos dependencias |
| `agente/` | El servicio que se instala junto a las impresoras. Dart, una dependencia |
| `manager/` | Sitio web: presentación, documentación y panel de administración |
| `docs/` | Protocolo del WebSocket y referencia del API |

## Seguridad

El agente corre como servicio del sistema y manda al spooler lo que le llega,
tal cual. Antes de instalarlo en la computadora de un cliente conviene leer
[SECURITY.md](SECURITY.md): qué puede hacer cada pieza, cómo se guardan las
credenciales, cuánto se conserva el contenido de los trabajos y qué **no** hace
todavía.

Fallos de seguridad: pedromateo.desarrollo@gmail.com, no un issue público.

## Licencia

Apache-2.0. Úsalo, cámbialo, móntalo para tus clientes.
