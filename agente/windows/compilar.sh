#!/usr/bin/env bash
# Compila los paquetes de Windows (agente + ventana + servicio, todo en C#).
#
#   ./compilar.sh                 x86 y x64
#   ./compilar.sh x86             solo uno
#
# Corre en Linux (o en cualquier sistema con el SDK de .NET): un net48 compila
# fuera de Windows con los ensamblados de referencia de NuGet. Deja en dist/:
#   print-server-agente-windows-x86.exe   Windows de 32 bits (corre también en 64)
#   print-server-agente-windows-x64.exe   Windows de 64 bits
#
# PDFium es el motor de PDF de Chrome, compilado por bblanchon/pdfium-binaries.
# Va FIJADO por versión y por sha256: un binario que se mete en computadoras
# ajenas no se baja «el último» sin mirar. Para subirlo, cambiar la versión y
# las huellas juntas (salen de `sha256sum pdfium-win-*.tgz`).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

PDFIUM_VERSION='chromium/8086'
declare -A PDFIUM_SHA256=(
  [x86]='4958b594e9709df44b8d69af3f90e62be54e335785c469217a2d364e6f141a54'
  [x64]='1fd8af952832dbb0eb16d9249f68fe09e5f5ebf7c3dd9f6066ea2720cc28487d'
)

ARQUITECTURAS=("$@")
[[ ${#ARQUITECTURAS[@]} -gt 0 ]] || ARQUITECTURAS=(x86 x64)

DIST="$PWD/dist"
mkdir -p "$DIST"
command -v dotnet >/dev/null || export PATH="$HOME/.dotnet:$PATH"

for ARQ in "${ARQUITECTURAS[@]}"; do
  ESPERADO="${PDFIUM_SHA256[$ARQ]:-}"
  [[ -n "$ESPERADO" ]] || { echo "No conozco la arquitectura «$ARQ» (x86 o x64)"; exit 64; }

  echo "→ PDFium $PDFIUM_VERSION ($ARQ)"
  TGZ="$DIST/pdfium-win-$ARQ.tgz"
  if [[ ! -f "$TGZ" ]] || [[ "$(sha256sum "$TGZ" | cut -d' ' -f1)" != "$ESPERADO" ]]; then
    curl -fsSL -o "$TGZ" \
      "https://github.com/bblanchon/pdfium-binaries/releases/download/$PDFIUM_VERSION/pdfium-win-$ARQ.tgz"
  fi
  SHA="$(sha256sum "$TGZ" | cut -d' ' -f1)"
  [[ "$SHA" == "$ESPERADO" ]] || { echo "PDFium $ARQ no es el esperado (sha256 $SHA)"; exit 1; }
  rm -rf "$DIST/pdfium-$ARQ" && mkdir -p "$DIST/pdfium-$ARQ/src"
  tar -xzf "$TGZ" -C "$DIST/pdfium-$ARQ/src"
  cp "$DIST/pdfium-$ARQ/src/bin/pdfium.dll" "$DIST/pdfium-$ARQ/pdfium.dll"
  # Sus licencias viajan con él: van junto a la DLL en Archivos de programa.
  {
    for f in "$DIST/pdfium-$ARQ/src/LICENSE" "$DIST/pdfium-$ARQ"/src/licenses/*; do
      printf '==== %s ====\n' "$(basename "$f")"
      cat "$f"
      printf '\n'
    done
  } > "$DIST/pdfium-licencias.txt"

  echo "→ compilando ($ARQ)"
  SALIDA="$DIST/compilado-$ARQ"
  rm -rf "$SALIDA"
  dotnet build print-server.csproj -c Release -nologo -v quiet \
    "-p:Arquitectura=$ARQ" "-p:PdfiumDll=$DIST/pdfium-$ARQ/pdfium.dll" \
    "-p:PdfiumLicencias=$DIST/pdfium-licencias.txt" -p:ExigirPdfium=true \
    "-p:BaseIntermediateOutputPath=$DIST/obj-$ARQ/" -o "$SALIDA"

  PAQUETE="$DIST/print-server-agente-windows-$ARQ.exe"
  cp "$SALIDA/print-server.exe" "$PAQUETE"
  echo "   $PAQUETE · $(du -h "$PAQUETE" | cut -f1) · sha256 $(sha256sum "$PAQUETE" | cut -c1-16)…"
done
