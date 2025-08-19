#!/bin/bash
set -e

source "$(dirname "$0")/utils.sh"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." &> /dev/null && pwd )"

log_info "== Update starting =="

# --- Guard для prometheus.yml: гарантируем именно ФАЙЛ до любых compose up ---
PROM_DIR="$PROJECT_ROOT/monitoring"
PROM_FILE="$PROM_DIR/prometheus.yml"

mkdir -p "$PROM_DIR"

if [ -d "$PROM_FILE" ]; then
  log_warning "[fix] Found directory instead of file at $PROM_FILE — removing"
  rm -rf "$PROM_FILE"
fi

if [ ! -f "$PROM_FILE" ]; then
  cat > "$PROM_FILE" <<'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF
  chmod 644 "$PROM_FILE"
  log_info "[fix] Created default $PROM_FILE"
fi
# --- End Guard ---

# Подтянем последние изменения из git
if command -v git >/dev/null 2>&1; then
  cd "$PROJECT_ROOT"
  git reset --hard HEAD || log_warning "git reset не выполнен"
  git pull || log_warning "git pull не выполнен"
else
  log_warning "git не найден, пропускаю обновление репозитория"
fi

# Обновление пакетов
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update && sudo apt-get upgrade -y
fi

cd "$PROJECT_ROOT"

# Подгружаем .env
if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-n8nstack}"

# Обновляем сервисы
log_info "== docker compose pull =="
docker compose -f docker-compose.yml pull || true

if [[ "${REVERSE_PROXY:-caddy}" == "traefik" ]]; then
  docker compose -f docker-compose.yml -f docker-compose.traefik.yml pull || true
else
  docker compose -f docker-compose.yml -f docker-compose.caddy.yml pull || true
fi

log_info "== docker compose up (без прокси) =="
docker compose -f docker-compose.yml up -d --remove-orphans

log_info "== docker compose up (прокси) =="
if [[ "${REVERSE_PROXY:-caddy}" == "traefik" ]]; then
  docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d traefik
else
  docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d caddy
fi

log_success "Update finished!"
exit 0
