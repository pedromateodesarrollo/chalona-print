#!/usr/bin/env bash
# Compila el hub (AOT) e instala un servicio systemd.
#
#   ./deploy-hub.sh --local        → esta máquina: /opt/chalona-print-hub + systemd
#   ./deploy-hub.sh --produccion   → servidor remoto por SSH (DEPLOY_HOST)
#
# Requiere dart en PATH y, para --produccion, acceso SSH con sudo.
# La URL de la base y el secreto JWT viven en /etc/chalona-print-hub.env (640).
[[ -n "$BASH_VERSION" ]] || exec bash "$0" "$@"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sin valor por defecto a propósito: un despliegue tiene que decir a dónde va.
readonly DEPLOY_HOST="${DEPLOY_HOST:-}"
readonly INSTALL_DIR="${INSTALL_DIR:-/opt/chalona-print-hub}"
readonly SERVICE_NAME="chalona-print-hub"
readonly BINARY_NAME="chalona-print-hub"
readonly PORT="${PORT:-3070}"

usage() {
  cat <<'AYUDA'
deploy-hub.sh --local | --produccion

  --local        Compila e instala en ESTA máquina (systemd).
  --produccion   Compila aquí y despliega en DEPLOY_HOST por SSH.

Variables: DEPLOY_HOST (obligatoria para --produccion), INSTALL_DIR, PORT
AYUDA
}

compila() {
  echo "→ compilando (AOT)…"
  cd "$SCRIPT_DIR"
  dart pub get >/dev/null
  dart compile exe bin/chalona_print_hub.dart -o "/tmp/$BINARY_NAME"
}

unidad() {
  cat <<UNIDAD
[Unit]
Description=Hub de impresión chalona-print
After=network.target postgresql.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=/etc/chalona-print-hub.env
ExecStart=$INSTALL_DIR/$BINARY_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIDAD
}

case "${1:-}" in
  --local)
    compila
    sudo mkdir -p "$INSTALL_DIR"
    sudo cp "/tmp/$BINARY_NAME" "$INSTALL_DIR/"
    sudo cp -r "$SCRIPT_DIR/migraciones" "$INSTALL_DIR/"
    unidad | sudo tee "/etc/systemd/system/$SERVICE_NAME.service" >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    sudo systemctl restart "$SERVICE_NAME"
    systemctl status "$SERVICE_NAME" --no-pager | head -5
    ;;
  --produccion)
    [[ -n "$DEPLOY_HOST" ]] || { echo "Define DEPLOY_HOST con el servidor de destino."; exit 64; }
    compila
    echo "→ subiendo a $DEPLOY_HOST…"
    ssh "$DEPLOY_HOST" "sudo mkdir -p $INSTALL_DIR && sudo chown \$USER $INSTALL_DIR"
    # A un nombre temporal: el binario en uso no se puede sobrescribir («text
    # file busy»), así que se sustituye con el servicio parado y de un `mv`,
    # que es atómico.
    scp -q "/tmp/$BINARY_NAME" "$DEPLOY_HOST:$INSTALL_DIR/$BINARY_NAME.nuevo"
    scp -qr "$SCRIPT_DIR/migraciones" "$DEPLOY_HOST:$INSTALL_DIR/"
    unidad | ssh "$DEPLOY_HOST" "sudo tee /etc/systemd/system/$SERVICE_NAME.service >/dev/null"
    ssh "$DEPLOY_HOST" "sudo systemctl stop $SERVICE_NAME 2>/dev/null || true
      mv $INSTALL_DIR/$BINARY_NAME.nuevo $INSTALL_DIR/$BINARY_NAME
      chmod +x $INSTALL_DIR/$BINARY_NAME
      sudo systemctl daemon-reload
      sudo systemctl enable --now $SERVICE_NAME
      sleep 2
      systemctl status $SERVICE_NAME --no-pager | head -5"
    echo "→ salud:"
    curl -sf "http://$DEPLOY_HOST:$PORT/salud" || echo "(sin respuesta desde fuera; comprueba nginx y el cortafuegos)"
    ;;
  *)
    usage; exit 64;;
esac
