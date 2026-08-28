#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)" >&2
  exit 1
fi

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

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  if [ -f "${SCRIPT_DIR}/.env.EXAMPLE" ]; then
    cp "${SCRIPT_DIR}/.env.EXAMPLE" "${SCRIPT_DIR}/.env"
    echo "Created .env from .env.EXAMPLE. Edit ports and COMPOSE_PROFILES before starting."
  else
    echo "Error: .env not found and .env.EXAMPLE is missing." >&2
    exit 1
  fi
fi

# create start_container.sh
cat > start_container.sh << 'EOF'
#!/bin/bash

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE=./.env
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found. Copy .env.EXAMPLE to .env and configure." >&2
  exit 1
fi

set -o allexport
# shellcheck disable=SC1091
source "$ENV_FILE"
set +o allexport

WEBUI_PORT="${WEBUI_PORT:-3060}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"

if [ -z "$COMPOSE_PROFILES" ]; then
  echo "Error: COMPOSE_PROFILES is not set in .env" >&2
  echo "Use ollama, open-webui, or ollama,open-webui" >&2
  exit 1
fi

want_ollama=0
want_webui=0
case ",${COMPOSE_PROFILES}," in
  *,ollama,*) want_ollama=1 ;;
esac
case ",${COMPOSE_PROFILES}," in
  *,open-webui,*) want_webui=1 ;;
esac

if [ "$want_ollama" -eq 0 ] && [ "$want_webui" -eq 0 ]; then
  echo "Error: COMPOSE_PROFILES must include ollama and/or open-webui" >&2
  exit 1
fi

echo "Starting compose profiles: ${COMPOSE_PROFILES}"
if ! docker compose -p self-hosted-llm up -d; then
  echo "Error: Failed to start containers." >&2
  exit 1
fi

echo "Waiting for containers to be ready..."
max_attempts=30
attempt=0
while [ $attempt -lt $max_attempts ]; do
  ready=1
  if [ "$want_ollama" -eq 1 ] && ! docker ps --format '{{.Names}}' | grep -q '^ollama$'; then
    ready=0
  fi
  if [ "$want_webui" -eq 1 ] && ! docker ps --format '{{.Names}}' | grep -q '^open-webui$'; then
    ready=0
  fi
  if [ "$ready" -eq 1 ]; then
    echo "Requested containers are running."
    if [ "$want_webui" -eq 1 ]; then
      echo "Open WebUI published on 0.0.0.0:${WEBUI_PORT}"
    fi
    if [ "$want_ollama" -eq 1 ]; then
      echo "Ollama API published on 0.0.0.0:${OLLAMA_PORT}"
    fi
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

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
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

if [ "$EUID" -ne 0 ]; then
  echo "Error: This script must be run as root (use sudo)" >&2
  exit 1
fi

if ! docker ps > /dev/null 2>&1; then
  echo "Error: Current user does not have permission to use Docker" >&2
  echo "Please ensure you can run 'docker ps' successfully" >&2
  exit 1
fi

DOCKER_CMD="docker"

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
  local name="$1"
  local project
  project=$(${DOCKER_CMD} inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2>/dev/null || true)
  [ "$project" = "$COMPOSE_PROJECT" ]
}

remove_if_project_container() {
  local name="$1"
  if ${DOCKER_CMD} inspect "$name" >/dev/null 2>&1 && belongs_to_project "$name"; then
    echo "Removing leftover container ${name}..."
    ${DOCKER_CMD} rm -f "$name" 2>/dev/null || true
  fi
}

reset_service() {
  local service="$1"
  local image="$2"

  echo "Resetting ${COMPOSE_PROJECT} service ${service} only..."
  ${DOCKER_CMD} compose -p "${COMPOSE_PROJECT}" stop "$service" || true
  ${DOCKER_CMD} compose -p "${COMPOSE_PROJECT}" rm -f "$service" || true
  remove_if_project_container "$service"
  echo "Removing image ${image}..."
  ${DOCKER_CMD} rmi -f "$image" 2>/dev/null || true
}

if [ "$TARGET" = "ollama" ]; then
  reset_service ollama ollama/ollama:rocm
else
  reset_service open-webui ghcr.io/open-webui/open-webui:main
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

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
  echo "Warning: .env file not found in ${SCRIPT_DIR}" >&2
  echo "Copy .env.EXAMPLE to .env and configure before starting the service." >&2
else
  set -o allexport
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +o allexport
fi

CADDY_DIR="/etc/caddy"
CADDYFILE="${CADDY_DIR}/Caddyfile"
CADDY_CONF_D="${CADDY_DIR}/conf.d"
CADDY_SITE_NAME="self-hosted-llm.caddy"
CADDY_TEMPLATE_FILE="${SCRIPT_DIR}/${CADDY_SITE_NAME}"
CADDY_SITE_FILE="${CADDY_CONF_D}/${CADDY_SITE_NAME}"
CADDY_IMPORT="import /etc/caddy/conf.d/*"

caddyfile_is_import_only() {
  local stripped
  stripped="$(grep -vE '^[[:space:]]*(#|$)' "$CADDYFILE" 2>/dev/null || true)"
  [ "$stripped" = "$CADDY_IMPORT" ]
}

install_caddy_dropin() {
  if [ -z "${DOMAIN:-}" ]; then
    echo "DOMAIN is empty: skipping Caddy site config"
    return 0
  fi

  if [ ! -f "$CADDY_TEMPLATE_FILE" ]; then
    echo "Error: ${CADDY_TEMPLATE_FILE} not found" >&2
    exit 1
  fi

  if [ ! -d "$CADDY_DIR" ]; then
    echo "Error: ${CADDY_DIR} not found. Install Caddy before setting DOMAIN." >&2
    exit 1
  fi

  if ! command -v caddy >/dev/null 2>&1; then
    echo "Error: caddy is not in PATH" >&2
    exit 1
  fi

  local domain="$DOMAIN"
  domain="${domain#http://}"
  domain="${domain#https://}"
  domain="${domain%/}"
  if [ -z "$domain" ]; then
    echo "Error: DOMAIN is empty after removing scheme/trailing slash" >&2
    exit 1
  fi

  local webui_port="${WEBUI_PORT:-3060}"

  echo "Installing Caddy drop-in for ${domain} -> 127.0.0.1:${webui_port}"

  mkdir -p "$CADDY_CONF_D"

  if [ -f "$CADDYFILE" ] && caddyfile_is_import_only; then
    echo "Caddyfile already imports ${CADDY_CONF_D}"
  else
    if [ -f "$CADDYFILE" ]; then
      local backup="${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"
      cp -a "$CADDYFILE" "$backup"
      echo "Backed up ${CADDYFILE} to ${backup}"
    fi
    printf '%s\n' "$CADDY_IMPORT" > "$CADDYFILE"
    echo "Wrote ${CADDYFILE} with: ${CADDY_IMPORT}"
  fi

  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//\$\{DOMAIN\}/${domain}}"
    line="${line//\$\{WEBUI_PORT\}/${webui_port}}"
    printf '%s\n' "$line"
  done < "$CADDY_TEMPLATE_FILE" > "$CADDY_SITE_FILE"

  if getent group caddy >/dev/null 2>&1; then
    chown root:caddy "$CADDYFILE" "$CADDY_CONF_D" "$CADDY_SITE_FILE"
  fi
  chmod 644 "$CADDYFILE" "$CADDY_SITE_FILE"
  chmod 755 "$CADDY_CONF_D"

  echo "Wrote ${CADDY_SITE_FILE}"

  if ! caddy validate --config "$CADDYFILE"; then
    echo "Error: Caddy config validation failed" >&2
    exit 1
  fi

  if systemctl is-active --quiet caddy; then
    systemctl reload caddy
    echo "Reloaded caddy"
  else
    echo "Caddy is not running. Start it with: sudo systemctl start caddy"
  fi
}

echo "Installing self-hosted LLM systemd service..."
echo "Project directory: ${SCRIPT_DIR}"

SERVICE_NAME="self-hosted-llm"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

WAIT_UNITS=""
IFS=',' read -ra WAIT_FOR_PARTS <<< "${WAIT_FOR:-}"
for part in "${WAIT_FOR_PARTS[@]}"; do
  unit="${part#"${part%%[![:space:]]*}"}"
  unit="${unit%"${unit##*[![:space:]]}"}"
  [ -z "$unit" ] && continue
  WAIT_UNITS="${WAIT_UNITS} ${unit}"
done

AFTER_LINE="After=docker.service${WAIT_UNITS}"
WANTS_LINE=""
if [ -n "${WAIT_UNITS}" ]; then
  WANTS_LINE="Wants=${WAIT_UNITS# }"
  echo "systemd will wait for:${WAIT_UNITS}"
else
  echo "WAIT_FOR is empty: unit will wait for docker.service only"
fi

cat > "${SERVICE_FILE}" << SERVICE_EOF
[Unit]
Description=Self-hosted Ollama and Open WebUI
${AFTER_LINE}
Requires=docker.service
${WANTS_LINE}

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${SCRIPT_DIR}
EnvironmentFile=-${SCRIPT_DIR}/.env
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

install_caddy_dropin

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
echo "  sudo ${SCRIPT_DIR}/reset_container.sh ollama"
echo "  sudo ${SCRIPT_DIR}/reset_container.sh open-webui"
echo ""
echo "Note: The reset command is not integrated into systemd as it is destructive."
echo "      Run it manually when needed."
echo ""
echo "Caddy site file (when DOMAIN is set): ${CADDY_SITE_FILE}"
echo "Re-run this script after changing DOMAIN or WEBUI_PORT."
EOF

chmod +x start_container.sh stop_container.sh reset_container.sh install_service.sh

echo "Scripts ready:"
echo "  sudo ./start_container.sh     - Start ollama and open-webui"
echo "  sudo ./stop_container.sh      - Stop ollama and open-webui"
echo "  sudo ./reset_container.sh <ollama|open-webui> - Reset one service in this compose project"
echo "  sudo ./install_service.sh     - Install the systemd service and Caddy drop-in"

# self destruct to remove attack vectors
rm -- "$0"