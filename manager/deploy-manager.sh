#!/usr/bin/env bash
# Compila el sitio (presentación + documentación + panel) y lo sube al hub.
#
#   ./deploy-manager.sh --produccion   → DEPLOY_HOST, carpeta del hub
#   ./deploy-manager.sh --local        → /opt/chalona-print-hub/manager
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sin valor por defecto a propósito: un despliegue tiene que decir a dónde va.
readonly DEPLOY_HOST="${DEPLOY_HOST:-}"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/chalona-print-hub}"

cd "$SCRIPT_DIR"
echo "→ compilando el sitio…"
npm install --silent
npm run docs --silent
npm run build --silent

case "${1:-}" in
  --local)
    sudo rm -rf "$INSTALL_DIR/manager"
    sudo cp -r dist "$INSTALL_DIR/manager"
    ;;
  --produccion)
    [[ -n "$DEPLOY_HOST" ]] || { echo "Define DEPLOY_HOST con el servidor de destino."; exit 64; }
    echo "→ subiendo a $DEPLOY_HOST…"
    tar -C dist -czf /tmp/chalona-print-manager.tgz .
    scp -q /tmp/chalona-print-manager.tgz "$DEPLOY_HOST:/tmp/"
    ssh "$DEPLOY_HOST" "rm -rf $INSTALL_DIR/manager && mkdir -p $INSTALL_DIR/manager && tar -C $INSTALL_DIR/manager -xzf /tmp/chalona-print-manager.tgz && rm /tmp/chalona-print-manager.tgz && ls $INSTALL_DIR/manager"
    ;;
  *)
    echo "Uso: ./deploy-manager.sh --local | --produccion"; exit 64;;
esac
echo "listo."
