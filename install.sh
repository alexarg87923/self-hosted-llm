#!/bin/bash

set -euo pipefail

echo "Removing commands if they exist"

rm -f ./start_container.sh
rm -f ./stop_container.sh
rm -f ./reset_container.sh
rm -f ./install_service.sh

echo "Installing self-hosted LLM container management scripts..."

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f "${SCRIPT_DIR}/docker-compose.yaml" ]; then
  echo "Error: docker-compose.yaml not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

# create start_container.sh
cat > start_container.sh << 'EOF'
#!/bin/bash

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
  echo "You may need to add your user to the docker group: sudo usermod -aG docker $USER" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! docker exec wireguard-client ip link show wg0 >/dev/null 2>&1; then
  echo "Error: WireGuard tunnel is not up in container wireguard-client." >&2
  echo "Start the VPN first: sudo systemctl start wireguard-vpn" >&2
  exit 1
fi

echo "Starting ollama and open-webui..."
if ! docker compose -p self-hosted-llm up -d; then
  echo "Error: Failed to start containers." >&2
  exit 1
fi

echo "Waiting for containers to be ready..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
  ollama_up=0
  webui_up=0
  if docker ps --format '{{.Names}}' | grep -q '^ollama$'; then
    ollama_up=1
  fi
  if docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    webui_up=1
  fi
  if [ "$ollama_up" -eq 1 ] && [ "$webui_up" -eq 1 ]; then
    echo "Containers ollama and open-webui are running."
    echo "Open WebUI: http://10.0.2.3:3060"
    exit 0
  fi
  attempt=$((attempt + 1))
  sleep 1
done

echo "Warning: Containers may not be fully ready yet." >&2
exit 0
EOF

# create stop_container.sh
cat > stop_container.sh << 'EOF'
#!/bin/bash

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
  echo "You may need to add your user to the docker group: sudo usermod -aG docker $USER" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping self-hosted-llm compose project..."
docker compose -p self-hosted-llm down --remove-orphans || true

echo "Containers stopped."
EOF

# create reset_container.sh
cat > reset_container.sh << 'EOF'
#!/bin/bash

DOCKER_CMD="docker"
if ! docker ps > /dev/null 2>&1; then
  if sudo docker ps > /dev/null 2>&1; then
    DOCKER_CMD="sudo docker"
  else
    echo "Error: Current user does not have permission to use Docker" >&2
    echo "Please ensure you can run 'docker ps' or 'sudo docker ps' successfully" >&2
    echo "You may need to add your user to the docker group: sudo usermod -aG docker $USER" >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

COMPOSE_PROJECT="self-hosted-llm"
TARGET="${1:-}"

usage() {
  echo "Usage: $0 <ollama|open-webui>" >&2
  echo "  ollama       Reset only the ollama service" >&2
  echo "  open-webui   Reset only the open-webui service" >&2
  exit 1
}

case "$TARGET" in
  ollama|open-webui) ;;
  -h|--help|"") usage ;;
  *)
    echo "Error: unknown target '${TARGET}'" >&2
    usage
    ;;
esac

belongs_to_project() {
  local kind="$1"
  local name="$2"
  local project=""
  case "$kind" in
    container)
      project=$(${DOCKER_CMD} inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
      ;;
    volume)
      project=$(${DOCKER_CMD} volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
      ;;
  esac
  [ "$project" = "$COMPOSE_PROJECT" ]
}

remove_if_project_container() {
  local name="$1"
  if ${DOCKER_CMD} inspect "$name" >/dev/null 2>&1 && belongs_to_project container "$name"; then
    echo "Removing leftover container ${name}..."
    ${DOCKER_CMD} rm -f "$name" 2>/dev/null || true
  fi
}

remove_if_project_volume() {
  local name="$1"
  if ${DOCKER_CMD} volume inspect "$name" >/dev/null 2>&1 && belongs_to_project volume "$name"; then
    echo "Removing leftover volume ${name}..."
    ${DOCKER_CMD} volume rm "$name" 2>/dev/null || true
  fi
}

reset_service() {
  local service="$1"
  local volume="$2"
  local image="$3"

  echo "Resetting ${COMPOSE_PROJECT} service ${service} only..."
  ${DOCKER_CMD} compose -p "${COMPOSE_PROJECT}" stop "$service" || true
  ${DOCKER_CMD} compose -p "${COMPOSE_PROJECT}" rm -f -v "$service" || true
  remove_if_project_container "$service"
  remove_if_project_volume "$volume"
  echo "Removing image ${image}..."
  ${DOCKER_CMD} rmi -f "$image" 2>/dev/null || true
}

if [ "$TARGET" = "ollama" ]; then
  reset_service ollama ollama_data ollama/ollama:rocm
else
  reset_service open-webui open-webui_data ghcr.io/open-webui/open-webui:main
fi

echo "Reset complete."
EOF

# create install_service.sh
cat > install_service.sh << 'EOF'
#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
  echo "You may need to add your user to the docker group: sudo usermod -aG docker $USER" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/start_container.sh" ]; then
  echo "Error: start_container.sh not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/stop_container.sh" ]; then
  echo "Error: stop_container.sh not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/reset_container.sh" ]; then
  echo "Error: reset_container.sh not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

if [ ! -f "${SCRIPT_DIR}/docker-compose.yaml" ]; then
  echo "Error: docker-compose.yaml not found in ${SCRIPT_DIR}" >&2
  exit 1
fi

echo "Installing self-hosted LLM systemd service..."
echo "Project directory: ${SCRIPT_DIR}"

SERVICE_NAME="self-hosted-llm"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "${SERVICE_FILE}" << SERVICE_EOF
[Unit]
Description=Self-hosted Ollama and Open WebUI
After=docker.service wireguard-vpn.service
Requires=docker.service
Wants=wireguard-vpn.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
ExecStart=${SCRIPT_DIR}/start_container.sh
ExecStop=${SCRIPT_DIR}/stop_container.sh
ExecReload=/bin/bash -c '${SCRIPT_DIR}/stop_container.sh && ${SCRIPT_DIR}/start_container.sh'
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "Service file created: ${SERVICE_FILE}"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

echo ""
echo "Service installed successfully!"
echo ""
echo "To start the service:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "To stop the service:"
echo "  sudo systemctl stop ${SERVICE_NAME}"
echo ""
echo "To enable the service (start on boot):"
echo "  sudo systemctl enable ${SERVICE_NAME}"
echo ""
echo "To check service status:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo ""
echo "To reset one service in this compose project:"
echo "  ${SCRIPT_DIR}/reset_container.sh ollama"
echo "  ${SCRIPT_DIR}/reset_container.sh open-webui"
echo ""
echo "Note: The reset command is not integrated into systemd as it is destructive."
echo "      Run it manually when needed."
EOF

chmod +x start_container.sh stop_container.sh reset_container.sh install_service.sh

echo "Scripts ready:"
echo "  ./start_container.sh     - Start ollama and open-webui"
echo "  ./stop_container.sh      - Stop ollama and open-webui"
echo "  ./reset_container.sh <ollama|open-webui> - Reset one service in this compose project"
echo "  sudo ./install_service.sh - Install the systemd service"

if [ "$EUID" -ne 0 ]; then
  sudo ./install_service.sh
else
  ./install_service.sh
fi

echo ""
echo "Installation complete!"

# self destruct to remove attack vectors
rm -- "$0"