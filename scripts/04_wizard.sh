#!/bin/bash
# Script to guide user through service selection for n8n-installer (safe version)
set -e

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

# Utils + logs
if [ -f "$(dirname "$0")/utils.sh" ]; then
  source "$(dirname "$0")/utils.sh"
else
  log_info()    { printf "\033[1;34m[INFO]\033[0m %s\n" "$*"; }
  log_error()   { printf "\033[1;31m[ERROR]\033[0m %s\n" "$*"; }
  log_warning() { printf "\033[1;33m[WARN]\033[0m %s\n" "$*"; }
  log_success() { printf "\033[1;32m[SUCCESS]\033[0m %s\n" "$*"; }
fi

# Ensure whiptail
if ! command -v whiptail >/dev/null 2>&1; then
  log_error "'whiptail' не установлен."
  log_info "Установите: sudo apt-get install -y whiptail"
  exit 1
fi

# Preserve / restore DEBIAN_FRONTEND for whiptail
ORIGINAL_DEBIAN_FRONTEND="$DEBIAN_FRONTEND"
export DEBIAN_FRONTEND=dialog

# Read current COMPOSE_PROFILES from .env
CURRENT_PROFILES_VALUE=""
if [ -f "$ENV_FILE" ]; then
  LINE_CONTENT=$(grep "^COMPOSE_PROFILES=" "$ENV_FILE" || true)
  if [ -n "$LINE_CONTENT" ]; then
    CURRENT_PROFILES_VALUE=$(echo "$LINE_CONTENT" | cut -d'=' -f2- | sed 's/^"//' | sed 's/"$//')
  fi
fi
current_profiles_for_matching=",$CURRENT_PROFILES_VALUE,"

# ---------------- Available services ----------------
base_services_data=(
  "n8n" "n8n, n8n-worker, n8n-import (Workflow Automation)"
  "dify" "Dify (AI Application Development Platform with LLMOps)"
  "flowise" "Flowise (AI Agent Builder)"
  "monitoring" "Monitoring Suite (Prometheus, Grafana, cAdvisor, Node-Exporter)"
  "portainer" "Portainer (Docker management UI)"
  "langfuse" "Langfuse Suite (AI Observability - includes Clickhouse, Minio)"
  "qdrant" "Qdrant (Vector Database)"
  "supabase" "Supabase (Backend as a Service)"
  "weaviate" "Weaviate (Vector Database with API Key Auth)"
  "neo4j" "Neo4j (Graph Database)"
  "letta" "Letta (Agent Server & SDK)"
  "gotenberg" "Gotenberg (Document Conversion API)"
  "crawl4ai" "Crawl4ai (Web Crawler for AI)"
  "open-webui" "Open WebUI (ChatGPT-like Interface)"
  "searxng" "SearXNG (Private Metasearch Engine)"
  "ollama" "Ollama (Local LLM Runner - select hardware in next step)"
  "comfyui" "ComfyUI (Node-based Stable Diffusion UI)"
)

services=()
idx=0
while [ $idx -lt ${#base_services_data[@]} ]; do
  tag="${base_services_data[idx]}"
  description="${base_services_data[idx+1]}"
  status="OFF"

  if [ -n "$CURRENT_PROFILES_VALUE" ] && [ "$CURRENT_PROFILES_VALUE" != '""' ]; then
    if [[ "$tag" == "ollama" ]]; then
      if [[ "$current_profiles_for_matching" == *",cpu,"* || \
            "$current_profiles_for_matching" == *",gpu-nvidia,"* || \
            "$current_profiles_for_matching" == *",gpu-amd,"* ]]; then
        status="ON"
      fi
    elif [[ "$current_profiles_for_matching" == *",$tag,"* ]]; then
      status="ON"
    fi
  else
    case "$tag" in
      "n8n"|"flowise"|"monitoring") status="ON" ;;
      *) status="OFF" ;;
    esac
  fi

  services+=("$tag" "$description" "$status")
  idx=$((idx + 2))
done

# Main service checklist
CHOICES=$(whiptail --title "Service Selection Wizard" --checklist \
"Выберите сервисы для установки.
Стрелки — навигация, ПРОБЕЛ — выбрать/снять, ENTER — подтвердить." \
32 90 17 \
"${services[@]}" \
3>&1 1>&2 2>&3)

# Restore DEBIAN_FRONTEND
if [ -n "$ORIGINAL_DEBIAN_FRONTEND" ]; then
  export DEBIAN_FRONTEND="$ORIGINAL_DEBIAN_FRONTEND"
else
  unset DEBIAN_FRONTEND
fi

# Cancel?
if [ $? -ne 0 ]; then
  log_info "Выбор сервисов отменён пользователем."
  [ -f "$ENV_FILE" ] || touch "$ENV_FILE"
  sed -i.bak "/^COMPOSE_PROFILES=/d" "$ENV_FILE" 2>/dev/null || true
  echo "COMPOSE_PROFILES=" >> "$ENV_FILE"
  exit 0
fi

# Parse selected
selected_profiles=()
ollama_selected=0
if [ -n "$CHOICES" ]; then
  eval "temp_choices=($CHOICES)"
  for choice in "${temp_choices[@]}"; do
    if [ "$choice" == "ollama" ]; then
      ollama_selected=1
    else
      selected_profiles+=("$choice")
    fi
  done
fi

# Ollama hardware profile if selected
if [ $ollama_selected -eq 1 ]; then
  default_ollama_hardware="cpu"
  ollama_hw_on_cpu="OFF"; ollama_hw_on_gpu_nvidia="OFF"; ollama_hw_on_gpu_amd="OFF"

  if [[ "$current_profiles_for_matching" == *",cpu,"* ]]; then
    ollama_hw_on_cpu="ON"; default_ollama_hardware="cpu"
  elif [[ "$current_profiles_for_matching" == *",gpu-nvidia,"* ]]; then
    ollama_hw_on_gpu_nvidia="ON"; default_ollama_hardware="gpu-nvidia"
  elif [[ "$current_profiles_for_matching" == *",gpu-amd,"* ]]; then
    ollama_hw_on_gpu_amd="ON"; default_ollama_hardware="gpu-amd"
  else
    ollama_hw_on_cpu="ON"; default_ollama_hardware="cpu"
  fi

  CHOSEN_OLLAMA_PROFILE=$(whiptail --title "Ollama Hardware Profile" --default-item "$default_ollama_hardware" --radiolist \
"Выберите профиль аппаратного ускорения для Ollama." \
15 78 3 \
"cpu" "CPU (для большинства)" "$ollama_hw_on_cpu" \
"gpu-nvidia" "NVIDIA GPU (нужны драйверы/CUDA)" "$ollama_hw_on_gpu_nvidia" \
"gpu-amd" "AMD GPU (нужны драйверы ROCm)" "$ollama_hw_on_gpu_amd" \
3>&1 1>&2 2>&3)

  if [ $? -eq 0 ] && [ -n "$CHOSEN_OLLAMA_PROFILE" ]; then
    selected_profiles+=("$CHOSEN_OLLAMA_PROFILE")
    log_info "Ollama hardware profile: $CHOSEN_OLLAMA_PROFILE"
  else
    log_info "Профиль Ollama не выбран — Ollama будет пропущен."
  fi
fi

# Compose profiles -> .env
if [ ${#selected_profiles[@]} -eq 0 ]; then
  COMPOSE_PROFILES_VALUE=""
  log_info "Не выбрано дополнительных сервисов."
else
  COMPOSE_PROFILES_VALUE=$(IFS=,; echo "${selected_profiles[*]}")
  log_info "Активные Docker Compose профили: $COMPOSE_PROFILES_VALUE"
fi

[ -f "$ENV_FILE" ] || { log_warning "'.env' не найден, создаю пустой"; touch "$ENV_FILE"; }
sed -i.bak "/^COMPOSE_PROFILES=/d" "$ENV_FILE" 2>/dev/null || true
echo "COMPOSE_PROFILES=${COMPOSE_PROFILES_VALUE}" >> "$ENV_FILE"

# ---- Site selection (wordpress/static/none) ----
SITE_TYPE_CUR=""; SITE_DOMAIN_CUR=""
if [ -f "$ENV_FILE" ]; then
  SITE_TYPE_CUR="$(grep -E '^SITE_TYPE=' "$ENV_FILE" | cut -d= -f2- || true)"
  SITE_DOMAIN_CUR="$(grep -E '^SITE_DOMAIN=' "$ENV_FILE" | cut -d= -f2- || true)"
fi

# Precompute ON/OFF safely (no inline $() in radiolist)
SITE_NONE_ON="OFF"; SITE_WP_ON="OFF"; SITE_STATIC_ON="OFF"
case "${SITE_TYPE_CUR:-}" in
  "")        SITE_NONE_ON="ON" ;;
  "none")    SITE_NONE_ON="ON" ;;
  "wordpress") SITE_WP_ON="ON" ;;
  "static")  SITE_STATIC_ON="ON" ;;
esac

SITE_TYPE=$(whiptail --title "Site installation" --radiolist \
"Установить сайт? (WordPress или статический сайт из ./site)" \
14 70 3 \
"none" "Не устанавливать сайт" "$SITE_NONE_ON" \
"wordpress" "Сайт на WordPress" "$SITE_WP_ON" \
"static" "Простой статический сайт (Nginx)" "$SITE_STATIC_ON" \
3>&1 1>&2 2>&3) || SITE_TYPE="${SITE_TYPE_CUR:-none}"

[ -n "$SITE_TYPE" ] || SITE_TYPE="none"

SITE_DOMAIN="$SITE_DOMAIN_CUR"
if [ "$SITE_TYPE" != "none" ]; then
  HINT_DOMAIN="${SITE_DOMAIN_CUR:-site.example.com}"
  SITE_DOMAIN=$(whiptail --title "Site domain" --inputbox \
"Введите полный домен сайта (FQDN), например: site.example.com" \
10 70 "$HINT_DOMAIN" \
3>&1 1>&2 2>&3) || SITE_DOMAIN="$SITE_DOMAIN_CUR"
  if [ -z "$SITE_DOMAIN" ]; then
    log_warning "Домен сайта не задан — установка сайта будет пропущена."
    SITE_TYPE="none"
  fi
fi

# Update .env with site settings
sed -i.bak "/^SITE_TYPE=/d" "$ENV_FILE" 2>/dev/null || true
sed -i.bak "/^SITE_DOMAIN=/d" "$ENV_FILE" 2>/dev/null || true
echo "SITE_TYPE=$SITE_TYPE" >> "$ENV_FILE"
echo "SITE_DOMAIN=$SITE_DOMAIN" >> "$ENV_FILE"

# WordPress DB secrets (generate if needed)
if [ "$SITE_TYPE" = "wordpress" ]; then
  WP_DB_NAME=$(grep -E '^WP_DB_NAME=' "$ENV_FILE" | cut -d= -f2- || true)
  WP_DB_USER=$(grep -E '^WP_DB_USER=' "$ENV_FILE" | cut -d= -f2- || true)
  WP_DB_PASSWORD=$(grep -E '^WP_DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || true)
  WP_DB_ROOT_PASSWORD=$(grep -E '^WP_DB_ROOT_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || true)

  [ -n "$WP_DB_NAME" ] || WP_DB_NAME="wordpress"
  [ -n "$WP_DB_USER" ] || WP_DB_USER="wpuser"

  if [ -z "$WP_DB_PASSWORD" ] || [ -z "$WP_DB_ROOT_PASSWORD" ]; then
    if ! command -v openssl >/dev/null 2>&1; then
      log_info "Устанавливаю openssl для генерации паролей..."
      sudo apt-get update -y && sudo apt-get install -y openssl
    fi
    [ -n "$WP_DB_PASSWORD" ] || WP_DB_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/')
    [ -n "$WP_DB_ROOT_PASSWORD" ] || WP_DB_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '=+/')
    # Overwrite (idempotent)
    sed -i.bak "/^WP_DB_NAME=/d" "$ENV_FILE" 2>/dev/null || true
    sed -i.bak "/^WP_DB_USER=/d" "$ENV_FILE" 2>/dev/null || true
    sed -i.bak "/^WP_DB_PASSWORD=/d" "$ENV_FILE" 2>/dev/null || true
    sed -i.bak "/^WP_DB_ROOT_PASSWORD=/d" "$ENV_FILE" 2>/dev/null || true
    {
      echo "WP_DB_NAME=$WP_DB_NAME"
      echo "WP_DB_USER=$WP_DB_USER"
      echo "WP_DB_PASSWORD=$WP_DB_PASSWORD"
      echo "WP_DB_ROOT_PASSWORD=$WP_DB_ROOT_PASSWORD"
    } >> "$ENV_FILE"
  fi
fi

# Ensure ./site exists for static
if [ "$SITE_TYPE" = "static" ]; then
  mkdir -p "$PROJECT_ROOT/site"
  if [ ! -f "$PROJECT_ROOT/site/index.html" ]; then
    cat > "$PROJECT_ROOT/site/index.html" <<'HTML'
<!doctype html>
<html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Static site</title>
<body style="font-family:system-ui,Segoe UI,Roboto,sans-serif;margin:40px">
<h1>It works!</h1><p>Статический сайт отдаётся из ./site и проксируется Caddy/Traefik.</p>
</body></html>
HTML
  fi
fi

# ---- Reverse proxy choice (caddy/traefik) ----
REVERSE_PROXY_CUR=$(grep -E '^REVERSE_PROXY=' "$ENV_FILE" | cut -d= -f2- || true)
[ -n "$REVERSE_PROXY_CUR" ] || REVERSE_PROXY_CUR="caddy"

# Precompute ON/OFF
RP_CADDY_ON="OFF"; RP_TRAEFIK_ON="OFF"
if [ "$REVERSE_PROXY_CUR" = "caddy" ]; then RP_CADDY_ON="ON"; fi
if [ "$REVERSE_PROXY_CUR" = "traefik" ]; then RP_TRAEFIK_ON="ON"; fi

REVERSE_PROXY=$(whiptail --title "Reverse proxy" --radiolist \
"Выберите реверс‑прокси (будет запущен ПОСЛЕДНИМ после всех сервисов)" \
12 60 2 \
"caddy" "Caddy (просто, автоконфиг SSL)" "$RP_CADDY_ON" \
"traefik" "Traefik (labels, dashboard, гибкая маршрутизация)" "$RP_TRAEFIK_ON" \
3>&1 1>&2 2>&3) || REVERSE_PROXY="$REVERSE_PROXY_CUR"

sed -i.bak "/^REVERSE_PROXY=/d" "$ENV_FILE" 2>/dev/null || true
echo "REVERSE_PROXY=$REVERSE_PROXY" >> "$ENV_FILE"

# Summary for user
log_success "Сохранено в $ENV_FILE:"
echo "  - COMPOSE_PROFILES=${COMPOSE_PROFILES_VALUE}"
echo "  - SITE_TYPE=${SITE_TYPE}"
[ -n "$SITE_DOMAIN" ] && echo "  - SITE_DOMAIN=${SITE_DOMAIN}"
echo "  - REVERSE_PROXY=${REVERSE_PROXY}"
if [ "$SITE_TYPE" = "wordpress" ]; then
  echo "  - WP_DB_NAME=${WP_DB_NAME}"
  echo "  - WP_DB_USER=${WP_DB_USER}"
fi

# Make runnable
chmod +x "$SCRIPT_DIR/04_wizard.sh"

exit 0
