#!/usr/bin/env bash
# Compila el agente para este sistema y lo publica en un hub.
#
#   ./publicar.sh --hub https://print.chalonasoft.com --llave cpk_...
#
# El gemelo de publicar.ps1, para Linux y macOS. La llave tiene que ser de
# administrador y de la organización que publica en ese hub (por defecto la 1):
# las descargas son del hub entero, no de una organización.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HUB=""
LLAVE=""
SOLO_COMPILAR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hub)   HUB="$2"; shift 2;;
    --llave) LLAVE="$2"; shift 2;;
    --solo-compilar) SOLO_COMPILAR=1; shift;;
    *) echo "No conozco «$1»"; exit 64;;
  esac
done

case "$(uname -s)" in
  Linux)  ARCHIVO="print-server-agente-linux-x64";;
  Darwin) ARCHIVO="print-server-agente-macos-$([[ "$(uname -m)" == arm64 ]] && echo arm64 || echo x64)";;
  *) echo "Para Windows usa publicar.ps1 en una máquina Windows."; exit 1;;
esac

echo "→ compilando $ARCHIVO"
dart pub get >/dev/null
dart compile exe bin/print_server_agente.dart -o "$ARCHIVO"

LOCAL="$(sha256sum "$ARCHIVO" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$ARCHIVO" | cut -d' ' -f1)"
echo "   $(du -h "$ARCHIVO" | cut -f1) · sha256 ${LOCAL:0:16}…"

[[ "$SOLO_COMPILAR" == "1" ]] && { echo "Listo (sin publicar)."; exit 0; }
[[ -n "$HUB" && -n "$LLAVE" ]] || { echo "Faltan --hub y --llave"; exit 64; }

echo "→ publicando en $HUB"
RESPUESTA="$(curl -sS -X POST "$HUB/v1/descargas/$ARCHIVO" \
  -H "authorization: Bearer $LLAVE" \
  -H 'content-type: application/octet-stream' \
  --data-binary "@$ARCHIVO")"

REMOTO="$(printf '%s' "$RESPUESTA" | sed -n 's/.*"sha256":"\([^"]*\)".*/\1/p')"
if [[ -z "$REMOTO" ]]; then
  echo "El hub lo rechazó: $RESPUESTA"; exit 1
fi
# Mismo sha256 a los dos lados: es lo que separa «subió» de «subió bien».
if [[ "$REMOTO" != "$LOCAL" ]]; then
  echo "El hub guardó otra cosa (sha256 $REMOTO). No lo des por publicado."; exit 1
fi

echo
echo "Publicado: $HUB/descargas/$ARCHIVO"
echo "Ya aparece en el panel, en «Instalar agente»."
