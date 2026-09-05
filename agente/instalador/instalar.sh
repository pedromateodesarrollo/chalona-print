#!/usr/bin/env bash
# Instalador del agente de print-server para Linux y macOS.
#
#   curl -fsSL https://TU-HUB/descargas/instalar.sh | sudo bash -s -- \
#     --hub https://TU-HUB --llave cpk_...
#
# Baja el ejecutable que toca, lo deja en /usr/local/bin, conecta la máquina
# con el hub y lo deja arrancando con el sistema.
set -euo pipefail

HUB=""
LLAVE=""
NOMBRE="$(hostname)"
DESTINO="${DESTINO:-/usr/local/bin}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub)    HUB="$2"; shift 2;;
    --llave)  LLAVE="$2"; shift 2;;
    --nombre) NOMBRE="$2"; shift 2;;
    *) echo "No conozco «$1»"; exit 64;;
  esac
done

[[ -n "$HUB" ]]   || { echo "Falta --hub https://tu-hub"; exit 64; }
[[ -n "$LLAVE" ]] || { echo "Falta --llave cpk_… (créala en el panel, en «Llaves de API»)"; exit 64; }
[[ "$(id -u)" == "0" ]] || { echo "Corre esto con sudo: el servicio y la configuración van a rutas del sistema."; exit 77; }

case "$(uname -s)" in
  Linux)  ARCHIVO="print-server-agente-linux-x64";;
  Darwin) ARCHIVO="print-server-agente-macos-arm64";;
  *) echo "Sistema no soportado por este instalador: $(uname -s)"; exit 1;;
esac

echo "→ bajando $ARCHIVO de $HUB"
TMP="$(mktemp)"
curl -fsSL "$HUB/descargas/$ARCHIVO" -o "$TMP" || {
  echo "No pude bajarlo. ¿Está publicado en $HUB/descargas/$ARCHIVO?"; exit 1; }

install -m 0755 "$TMP" "$DESTINO/print-server-agente"
rm -f "$TMP"

echo "→ conectando con el hub"
"$DESTINO/print-server-agente" configurar --hub "$HUB" --llave "$LLAVE" --nombre "$NOMBRE"

echo "→ instalando el servicio"
"$DESTINO/print-server-agente" instalar

echo
echo "Listo. La computadora «$NOMBRE» ya aparece en el panel del hub."
echo "Panel local de esta máquina: http://127.0.0.1:7717"
