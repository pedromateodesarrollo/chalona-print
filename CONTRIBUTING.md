# Contribuir

## Levantar el entorno

```bash
# Base de datos (o usa la tuya)
docker compose up -d bd

# Hub
cd hub && dart pub get
PRINT_DATABASE_URL=postgres://print:print@localhost:5432/print_server \
  dart run bin/print_server_hub.dart

# Sitio (proxy al hub local en :3071 — ajusta vite.config.js si usas otro puerto)
cd manager && npm install && npm run dev

# Agente, sin gastar papel
cd agente && dart pub get
PRINT_AGENTE_CONFIG=/tmp/agente.json dart run bin/print_server_agente.dart \
  configurar --hub http://localhost:3070 --llave cpk_...
# y en /tmp/agente.json pon  "driver": "falso"
```

El driver `falso` escribe los trabajos en una carpeta en vez de imprimirlos.
Con él se prueba el ciclo entero —cola, reenvíos, idempotencia, fallos— sin
tener una impresora delante.

## Antes de mandar un cambio

```bash
cd hub && dart analyze && dart test
cd agente && dart analyze && dart test
cd manager && npm run build
```

Si tocas el API, la documentación se escribe en `manager/src/docs.js` y de ahí
sale sola la página y `docs/api.md`:

```bash
cd manager && npm run docs
```

## Migraciones

Una migración aplicada no se edita: se añade otra. Van en `hub/migraciones/`
con número correlativo, y el hub las aplica al arrancar.

## Cómo se escribe aquí

* **Español**, en el código y en los comentarios.
* Los comentarios explican **por qué**, no qué. Lo que hace el código ya se lee
  en el código; lo que no se ve es la razón por la que está así.
* Dependencias, las mínimas. El agente se instala en computadoras ajenas: cada
  paquete que traiga es algo que alguien tendrá que auditar.
