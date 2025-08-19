#!/bin/bash
set -e

# Source utilities
source "$(dirname "$0")/utils.sh"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# --- Guard для prometheus.yml: гарантируем именно ФАЙЛ до первого docker compose up ---
PROM_DIR="$REPO_ROOT/monitoring"
PROM_FILE="$PROM_DIR/prometheus.yml"

mkdir -p "$PROM_DIR"

# Если по ошибке существует каталог с именем prometheus.yml — удаляем
if [ -d "$PROM_FILE" ]; then
  log_warning "[fix] Found directory instead of file at $PROM_FILE — removing"
  rm -rf "$PROM_FILE"
fi

# Если файла нет — создаём дефолт
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

# ------------------ OPTIONAL SITE INSTALLER ------------------
add_site_interactive() {
  echo
  read -r -p "Установить сайт? (none/wordpress/static) [none]: " SITE_TYPE
  SITE_TYPE="${SITE_TYPE:-none}"

  if [[ "$SITE_TYPE" == "none" ]]; then
    return 0
  fi

  read -r -p "Домен сайта (например, site.example.com): " SITE_DOMAIN
  if [[ -z "$SITE_DOMAIN" ]]; then
    echo "Домен не задан, пропуск..."
    return 0
  fi

  # Генерация паролей для WP, если нужно
  if [[ "$SITE_TYPE" == "wordpress" ]]; then
    if ! command -v openssl >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y openssl
    fi
    WP_DB_PASS=$(openssl rand -base64 24 | tr -d '=+/')
    WP_DB_ROOT_PASS=$(openssl rand -base64 24 | tr -d '=+/')
  fi

  # Обновляем .env
  pushd "$REPO_ROOT" >/dev/null
  if [[ ! -f ".env" && -f ".env.example" ]]; then cp .env.example .env; fi
  if [[ ! -f ".env" ]]; then touch .env; fi

  sed -i "/^SITE_TYPE=/d" .env || true
  sed -i "/^SITE_DOMAIN=/d" .env || true
  {
    echo "SITE_TYPE=$SITE_TYPE"
    echo "SITE_DOMAIN=$SITE_DOMAIN"
  } >> .env

  if [[ "$SITE_TYPE" == "wordpress" ]]; then
    sed -i "/^WP_DB_NAME=/d" .env || true
    sed -i "/^WP_DB_USER=/d" .env || true
    sed -i "/^WP_DB_PASSWORD=/d" .env || true
    sed -i "/^WP_DB_ROOT_PASSWORD=/d" .env || true
    {
      echo "WP_DB_NAME=${WP_DB_NAME:-wordpress}"
      echo "WP_DB_USER=${WP_DB_USER:-wpuser}"
      echo "WP_DB_PASSWORD=$WP_DB_PASS"
      echo "WP_DB_ROOT_PASSWORD=$WP_DB_ROOT_PASS"
    } >> .env
  fi

  # Запуск профиля
  if [[ "$SITE_TYPE" == "wordpress" ]]; then
    log_info "Запускаю WordPress..."
    docker compose --profile wordpress up -d
    log_success "WordPress: https://$SITE_DOMAIN"
  elif [[ "$SITE_TYPE" == "static" ]]; then
    log_info "Запускаю статический сайт..."
    docker compose --profile static up -d
    log_success "Static site: https://$SITE_DOMAIN"
  fi

  popd >/dev/null
}
# ---------------- END OPTIONAL SITE INSTALLER ----------------

# ------------------ PROXY CHOICE ------------------
add_proxy_interactive() {
  echo
  read -r -p "Выбери прокси (traefik/caddy) [caddy]: " REVERSE_PROXY
  REVERSE_PROXY="${REVERSE_PROXY:-caddy}"

  pushd "$REPO_ROOT" >/dev/null
  sed -i "/^REVERSE_PROXY=/d" .env || true
  echo "REVERSE_PROXY=$REVERSE_PROXY" >> .env

  if [[ "$REVERSE_PROXY" == "traefik" ]]; then
    log_info "Запуск Traefik..."
    docker compose -f docker-compose.yml -f docker-compose.traefik.yml up -d traefik
  else
    log_info "Запуск Caddy..."
    docker compose -f docker-compose.yml -f docker-compose.caddy.yml up -d caddy
  fi
  popd >/dev/null
}
# ---------------- END PROXY CHOICE ----------------

# Запуск стандартных шагов инсталлятора
log_info "========== STEP 1: System Preparation =========="
bash "$SCRIPT_DIR/01_system_preparation.sh" || { log_error "System Preparation failed"; exit 1; }
log_success "System preparation complete!"

log_info "========== STEP 2: Installing Docker =========="
bash "$SCRIPT_DIR/02_install_docker.sh" || { log_error "Docker Installation failed"; exit 1; }
log_success "Docker installation complete!"

log_info "========== STEP 3: Generating Secrets and Configuration =========="
bash "$SCRIPT_DIR/03_generate_secrets.sh" || { log_error "Secret/Config Generation failed"; exit 1; }
log_success "Secret/Config Generation complete!"

log_info "========== STEP 4: Running Service Selection Wizard =========="
bash "$SCRIPT_DIR/04_wizard.sh" || { log_error "Service Selection Wizard failed"; exit 1; }
log_success "Service Selection Wizard complete!"

log_info "========== STEP 5: Running Services =========="
bash "$SCRIPT_DIR/05_run_services.sh" || { log_error "Running Services failed"; exit 1; }
log_success "Running Services complete!"

# Новый шаги
add_site_interactive
add_proxy_interactive

log_info "========== STEP 6: Final Report =========="
bash "$SCRIPT_DIR/06_final_report.sh" || { log_error "Final Report failed"; exit 1; }
log_success "Final Report complete!"

exit 0
