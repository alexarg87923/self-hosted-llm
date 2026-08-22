#!/bin/bash

set -euo pipefail

echo "Removing commands if they exist"

rm -f ./start_container.sh
rm -f ./stop_container.sh
rm -f ./reset_container.sh

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

WG_BIND_IP="10.0.2.2"

if ! ip -4 addr show | grep -qw "${WG_BIND_IP}"; then
  echo "Error: WireGuard address ${WG_BIND_IP} is not present on this host." >&2
  echo "Start the VPN first, then retry." >&2
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
    echo "Open WebUI: http://${WG_BIND_IP}:3000"
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

echo "Stopping ollama and open-webui..."
docker compose -p self-hosted-llm down --remove-orphans || true

for name in ollama open-webui; do
  if docker ps --format '{{.Names}}' | grep -q "^${name}$"; then
    echo "Container ${name} still running, stopping directly..."
    docker stop "${name}" 2>/dev/null || true
    docker rm "${name}" 2>/dev/null || true
  fi
done

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

echo "Resetting ollama and open-webui..."

echo "Checking if stop_container.sh exists..."
if [ -f "./stop_container.sh" ]; then
  echo "Executing stop_container.sh..."
  ./stop_container.sh || true
fi

echo "Removing named containers..."
${DOCKER_CMD} rm -f ollama open-webui 2>/dev/null || true

echo "Removing named volumes..."
${DOCKER_CMD} volume rm ollama_data open-webui_data 2>/dev/null || true

echo "Removing named network..."
${DOCKER_CMD} network rm self-hosted-llm 2>/dev/null || true

echo "Removing project images..."
${DOCKER_CMD} rmi -f ollama/ollama:rocm ghcr.io/open-webui/open-webui:main 2>/dev/null || true

echo "Reset complete."
EOF

chmod +x start_container.sh stop_container.sh reset_container.sh

echo "Scripts ready:"
echo "  ./start_container.sh  - Start ollama and open-webui"
echo "  ./stop_container.sh   - Stop ollama and open-webui"
echo "  ./reset_container.sh  - Delete named ollama/open-webui containers, volumes, and images"

if [ "$EUID" -ne 0 ]; then
  SUDO="sudo"
else
  SUDO=""
fi

SERVICE_NAME="self-hosted-llm"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

echo ""
echo "Installing ${SERVICE_NAME} systemd service..."
echo "Project directory: ${SCRIPT_DIR}"

${SUDO} tee "${SERVICE_FILE}" > /dev/null << SERVICE_EOF
[Unit]
Description=Self-hosted Ollama and Open WebUI
After=docker.service network-online.target wireguard-vpn.service
Wants=network-online.target
Requires=docker.service

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

${SUDO} systemctl daemon-reload
${SUDO} systemctl enable "${SERVICE_NAME}.service"

echo ""
echo "Installation complete!"
echo ""
echo "To start the service:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo ""
echo "To stop the service:"
echo "  sudo systemctl stop ${SERVICE_NAME}"
echo ""
echo "To check service status:"
echo "  sudo systemctl status ${SERVICE_NAME}"
echo ""
echo "To reset named ollama/open-webui resources:"
echo "  ${SCRIPT_DIR}/reset_container.sh"
echo ""
echo "Note: The reset command is not integrated into systemd as it is destructive."
echo "      Run it manually when needed."