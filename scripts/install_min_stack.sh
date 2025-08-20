#!/usr/bin/env bash
set -Eeuo pipefail

# --- Проверка прав ---
if [[ $EUID -ne 0 ]]; then
  echo "[!] Запускайте от root: sudo bash scripts/install_min_stack.sh"; exit 1;
fi

# --- Ввод параметров ---
read -rp "Введите корневой домен (например, site.com): " BASE_DOMAIN
BASE_DOMAIN=${BASE_DOMAIN,,}
[[ -z "$BASE_DOMAIN" ]] && { echo "Домен пустой"; exit 1; }
read -rp "Введите e-mail для Let's Encrypt: " LETSENCRYPT_EMAIL
[[ -z "$LETSENCRYPT_EMAIL" ]] && { echo "Email пустой"; exit 1; }

echo "Выберите тип сайта:"
echo "  1) WordPress"
echo "  2) Статический (Nginx)"
read -rp "Ваш выбор [1/2]: " choice
SITE_TYPE="wordpress"
[[ "$choice" == "2" ]] && SITE_TYPE="static"

# --- Пути/домены ---
STACK_DIR=/opt/n8n-stack
ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"
SUPABASE_SQL_DIR="$STACK_DIR/supabase/init"
STATIC_SITE_DIR="$STACK_DIR/site"
EDGE_FUNCS_DIR="$STACK_DIR/volumes/functions"

mkdir -p "$STACK_DIR" "$SUPABASE_SQL_DIR" "$STATIC_SITE_DIR" "$EDGE_FUNCS_DIR"

SITE_HOST="$BASE_DOMAIN"
SUPABASE_HOST="supabase.$BASE_DOMAIN"
STUDIO_HOST="studio.$BASE_DOMAIN"
N8N_HOST="n8n.$BASE_DOMAIN"

# --- Система и безопасность ---
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get full-upgrade -y
apt-get install -y ca-certificates curl gnupg lsb-release openssl apache2-utils ufw fail2ban jq git

# Docker (официальный репозиторий) — идемпотентно
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release; echo "$ID")/gpg \
    | gpg --dearmor --yes --batch -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release; echo "$ID") $(. /etc/os-release; echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# UFW
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

# Fail2Ban (минимальная тюрьма для sshd)
mkdir -p /etc/fail2ban/jail.d
cat >/etc/fail2ban/jail.d/sshd.local <<'JAIL'
[sshd]
enabled = true
bantime = 1h
findtime = 10m
maxretry = 5
JAIL
systemctl restart fail2ban || true

# --- Хелперы генерации секретов ---
randhex() { openssl rand -hex "$1"; }   # аргумент — байты
b64url()  { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now()     { date +%s; }

generate_env() {
  # Supabase ключи
  JWT_SECRET=$(randhex 32)         # HS256 секрет
  SECRET_KEY_BASE=$(randhex 32)    # для realtime
  POSTGRES_PASSWORD=$(randhex 24)

  make_jwt() {
    local role="$1" iat exp header payload unsigned sig
    iat=$(now); exp=$((iat+315360000)) # 10 лет
    header=$(printf '{"alg":"HS256","typ":"JWT"}' | b64url)
    payload=$(printf '{"role":"%s","iss":"supabase","iat":%d,"exp":%d}' "$role" "$iat" "$exp" | b64url)
    unsigned="$header.$payload"
    sig=$(printf %s "$unsigned" | openssl dgst -binary -sha256 -hmac "$JWT_SECRET" | b64url)
    echo "$unsigned.$sig"
  }
  ANON_KEY=$(make_jwt anon)
  SERVICE_ROLE_KEY=$(make_jwt service_role)

  # n8n
  N8N_BASIC_AUTH_USER="admin"
  N8N_BASIC_AUTH_PASSWORD=$(randhex 12)
  N8N_ENCRYPTION_KEY=$(randhex 32)

  # WordPress / MariaDB
  WP_DB_NAME="wordpress"
  WP_DB_USER="wpuser"
  WP_DB_PASSWORD=$(randhex 16)
  MYSQL_ROOT_PASSWORD=$(randhex 16)

  # Studio BasicAuth для Traefik
  STUDIO_USER="supabase"
  STUDIO_PASS=$(randhex 10)
  STUDIO_HTPASSWD=$(htpasswd -nbB "$STUDIO_USER" "$STUDIO_PASS" | sed -e 's/\$/$$/g')

  # --- .env ---
  cat >"$ENV_FILE" <<EOF
# Домены
BASE_DOMAIN=${BASE_DOMAIN}
SITE_HOST=${SITE_HOST}
N8N_HOST=${N8N_HOST}
SUPABASE_HOST=${SUPABASE_HOST}
STUDIO_HOST=${STUDIO_HOST}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
SITE_TYPE=${SITE_TYPE}

# n8n
N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
N8N_PROTOCOL=https

# Supabase (ключи)
JWT_SECRET=${JWT_SECRET}
ANON_KEY=${ANON_KEY}
SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
JWT_EXPIRY=3600

# Supabase (DB)
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=postgres
POSTGRES_HOST=db
POSTGRES_PORT=5432
PGRST_DB_SCHEMAS=public,storage,graphql_public
SITE_URL=https://${SITE_HOST}
API_EXTERNAL_URL=https://${SUPABASE_HOST}/auth/v1
SUPABASE_PUBLIC_URL=https://${SUPABASE_HOST}

# SMTP (по умолчанию выключено)
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASS=
SMTP_ADMIN_EMAIL=
SMTP_SENDER_NAME=Supabase
ADDITIONAL_REDIRECT_URLS=
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=true
ENABLE_ANONYMOUS_USERS=true
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false

# Studio BasicAuth через Traefik
STUDIO_HTPASSWD=${STUDIO_HTPASSWD}

# WordPress / MariaDB
WP_DB_NAME=${WP_DB_NAME}
WP_DB_USER=${WP_DB_USER}
WP_DB_PASSWORD=${WP_DB_PASSWORD}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
EOF
  chmod 600 "$ENV_FILE"
}

# --- Генерация секретов (идемпотентно) ---
if [ -f "$ENV_FILE" ] && [ -s "$ENV_FILE" ]; then
  echo "[INFO] Найден .env — пропускаем генерацию секретов"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
else
  echo "[INFO] .env не найден — генерируем секреты"
  generate_env
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# --- SQL bootstrap: расширения (векторные и полезные) ---
cat >"$SUPABASE_SQL_DIR/00_enable_extensions.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL

# --- Простейший статический сайт (если выбран static) ---
if [[ "$SITE_TYPE" == "static" ]]; then
  cat >"$STATIC_SITE_DIR/index.html" <<HTML
<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Сайт работает</title><body style="font-family:system-ui;margin:40px">
<h1>Готово!</h1><p>Домен: <b>${SITE_HOST}</b></p>
</body></html>
HTML
fi

# --- docker-compose.yml (c профилями для сайта) ---
cat >"$COMPOSE_FILE" <<'YAML'
name: n8n-supabase-stack

volumes:
  traefik_letsencrypt:
    name: traefik_letsencrypt
  n8n_data: {}
  supabase_db_data: {}
  supabase_storage: {}
  wp_data: {}
  wp_db_data: {}

networks:
  proxy:
    driver: bridge

services:
  traefik:
    image: traefik:v3.5
    container_name: traefik
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.le.acme.email=${LETSENCRYPT_EMAIL}
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.le.acme.storage=/letsencrypt/acme.json
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik_letsencrypt:/letsencrypt
    restart: unless-stopped
    networks: [proxy]

  # n8n
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    environment:
      - N8N_HOST=${N8N_HOST}
      - N8N_PROTOCOL=${N8N_PROTOCOL}
      - N8N_BASIC_AUTH_ACTIVE=true
      - N8N_BASIC_AUTH_USER=${N8N_BASIC_AUTH_USER}
      - N8N_BASIC_AUTH_PASSWORD=${N8N_BASIC_AUTH_PASSWORD}
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
    volumes:
      - n8n_data:/home/node/.n8n
    labels:
      - traefik.enable=true
      - traefik.http.routers.n8n.rule=Host(`${N8N_HOST}`)
      - traefik.http.routers.n8n.entrypoints=websecure
      - traefik.http.routers.n8n.tls.certresolver=le
      - traefik.http.services.n8n.loadbalancer.server.port=5678
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Postgres (с pgvector)
  db:
    image: supabase/postgres:15.6.1.137
    container_name: supabase-db
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 5s
      timeout: 5s
      retries: 10
    environment:
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - POSTGRES_DB=${POSTGRES_DB}
    volumes:
      - supabase_db_data:/var/lib/postgresql/data
      - ./supabase/init:/docker-entrypoint-initdb.d
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Auth (GoTrue)
  auth:
    image: supabase/gotrue:v2.178.0
    container_name: supabase-auth
    depends_on:
      db:
        condition: service_healthy
    environment:
      - GOTRUE_API_HOST=0.0.0.0
      - GOTRUE_API_PORT=9999
      - API_EXTERNAL_URL=${API_EXTERNAL_URL}
      - GOTRUE_DB_DRIVER=postgres
      - GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      - GOTRUE_SITE_URL=${SITE_URL}
      - GOTRUE_URI_ALLOW_LIST=${ADDITIONAL_REDIRECT_URLS}
      - GOTRUE_DISABLE_SIGNUP=false
      - GOTRUE_JWT_ADMIN_ROLES=service_role
      - GOTRUE_JWT_AUD=authenticated
      - GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated
      - GOTRUE_JWT_EXP=${JWT_EXPIRY}
      - GOTRUE_JWT_SECRET=${JWT_SECRET}
      - GOTRUE_EXTERNAL_EMAIL_ENABLED=${ENABLE_EMAIL_SIGNUP}
      - GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED=${ENABLE_ANONYMOUS_USERS}
      - GOTRUE_MAILER_AUTOCONFIRM=${ENABLE_EMAIL_AUTOCONFIRM}
      - GOTRUE_SMTP_ADMIN_EMAIL=${SMTP_ADMIN_EMAIL}
      - GOTRUE_SMTP_HOST=${SMTP_HOST}
      - GOTRUE_SMTP_PORT=${SMTP_PORT}
      - GOTRUE_SMTP_USER=${SMTP_USER}
      - GOTRUE_SMTP_PASS=${SMTP_PASS}
      - GOTRUE_SMTP_SENDER_NAME=${SMTP_SENDER_NAME}
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-auth.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/auth/`)
      - traefik.http.routers.supabase-auth.entrypoints=websecure
      - traefik.http.routers.supabase-auth.tls.certresolver=le
      - traefik.http.routers.supabase-auth.middlewares=supabase-auth-strip
      - traefik.http.middlewares.supabase-auth-strip.stripprefixregex.regex=^/auth/v1
      - traefik.http.services.supabase-auth.loadbalancer.server.port=9999
    restart: unless-stopped
    networks: [proxy]

  # Supabase: REST (PostgREST)
  rest:
    image: postgrest/postgrest:v13.0.4
    container_name: supabase-rest
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PGRST_DB_URI=postgres://authenticator:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      - PGRST_DB_SCHEMAS=${PGRST_DB_SCHEMAS}
      - PGRST_DB_ANON_ROLE=anon
      - PGRST_JWT_SECRET=${JWT_SECRET}
      - PGRST_DB_USE_LEGACY_GUCS=false
      - PGRST_APP_SETTINGS_JWT_SECRET=${JWT_SECRET}
      - PGRST_APP_SETTINGS_JWT_EXP=${JWT_EXPIRY}
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-rest.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/rest/`)
      - traefik.http.routers.supabase-rest.entrypoints=websecure
      - traefik.http.routers.supabase-rest.tls.certresolver=le
      - traefik.http.routers.supabase-rest.middlewares=supabase-rest-strip
      - traefik.http.middlewares.supabase-rest-strip.stripprefixregex.regex=^/rest/v1
      - traefik.http.services.supabase-rest.loadbalancer.server.port=3000
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Realtime
  realtime:
    image: supabase/realtime:v2.41.5
    container_name: supabase-realtime
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PORT=4000
      - DB_HOST=${POSTGRES_HOST}
      - DB_PORT=${POSTGRES_PORT}
      - DB_USER=supabase_admin
      - DB_PASSWORD=${POSTGRES_PASSWORD}
      - DB_NAME=${POSTGRES_DB}
      - DB_AFTER_CONNECT_QUERY=SET search_path TO _realtime
      - DB_ENC_KEY=supabaserealtime
      - API_JWT_SECRET=${JWT_SECRET}
      - SECRET_KEY_BASE=${SECRET_KEY_BASE}
      - ERL_AFLAGS=-proto_dist inet_tcp
      - RLIMIT_NOFILE=10000
      - APP_NAME=realtime
      - SEED_SELF_HOST=true
      - RUN_JANITOR=true
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-realtime.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/realtime/`)
      - traefik.http.routers.supabase-realtime.entrypoints=websecure
      - traefik.http.routers.supabase-realtime.tls.certresolver=le
      # rewrite на /socket/*
      - traefik.http.middlewares.rt-rewrite.replacepathregex.regex=^/realtime/v1/(.*)
      - traefik.http.middlewares.rt-rewrite.replacepathregex.replacement=/socket/$1
      - traefik.http.routers.supabase-realtime.middlewares=rt-rewrite
      - traefik.http.services.supabase-realtime.loadbalancer.server.port=4000
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Storage (+ imgproxy)
  storage:
    image: supabase/storage-api:v1.26.4
    container_name: supabase-storage
    depends_on:
      db:
        condition: service_healthy
      rest:
        condition: service_started
    environment:
      - ANON_KEY=${ANON_KEY}
      - SERVICE_KEY=${SERVICE_ROLE_KEY}
      - POSTGREST_URL=http://rest:3000
      - PGRST_JWT_SECRET=${JWT_SECRET}
      - DATABASE_URL=postgres://supabase_storage_admin:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
      - FILE_SIZE_LIMIT=52428800
      - STORAGE_BACKEND=file
      - FILE_STORAGE_BACKEND_PATH=/var/lib/storage
      - TENANT_ID=stub
      - REGION=stub
      - ENABLE_IMAGE_TRANSFORMATION=true
      - IMGPROXY_URL=http://imgproxy:5001
    volumes:
      - supabase_storage:/var/lib/storage
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-storage.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/storage/`)
      - traefik.http.routers.supabase-storage.entrypoints=websecure
      - traefik.http.routers.supabase-storage.tls.certresolver=le
      - traefik.http.routers.supabase-storage.middlewares=supabase-storage-strip
      - traefik.http.middlewares.supabase-storage-strip.stripprefixregex.regex=^/storage/v1
      - traefik.http.services.supabase-storage.loadbalancer.server.port=5000
    restart: unless-stopped
    networks: [proxy]

  imgproxy:
    image: darthsim/imgproxy:v3.8.0
    container_name: supabase-imgproxy
    environment:
      - IMGPROXY_BIND=:5001
      - IMGPROXY_LOCAL_FILESYSTEM_ROOT=/
      - IMGPROXY_USE_ETAG=true
      - IMGPROXY_ENABLE_WEBP_DETECTION=true
    volumes:
      - supabase_storage:/var/lib/storage
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Postgres Meta
  meta:
    image: supabase/postgres-meta:v0.91.0
    container_name: supabase-meta
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PG_META_PORT=8080
      - PG_META_DB_HOST=${POSTGRES_HOST}
      - PG_META_DB_PORT=${POSTGRES_PORT}
      - PG_META_DB_NAME=${POSTGRES_DB}
      - PG_META_DB_USER=supabase_admin
      - PG_META_DB_PASSWORD=${POSTGRES_PASSWORD}
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-meta.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/meta/`)
      - traefik.http.routers.supabase-meta.entrypoints=websecure
      - traefik.http.routers.supabase-meta.tls.certresolver=le
      - traefik.http.routers.supabase-meta.middlewares=supabase-meta-strip
      - traefik.http.middlewares.supabase-meta-strip.stripprefixregex.regex=^/meta/v1
      - traefik.http.services.supabase-meta.loadbalancer.server.port=8080
    restart: unless-stopped
    networks: [proxy]

  # Supabase: Edge Functions
  functions:
    image: supabase/edge-runtime:v1.67.4
    container_name: supabase-edge-functions
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PORT=9000
      - JWT_SECRET=${JWT_SECRET}
      - SUPABASE_URL=${SUPABASE_PUBLIC_URL}
      - SUPABASE_ANON_KEY=${ANON_KEY}
      - SUPABASE_SERVICE_ROLE_KEY=${SERVICE_ROLE_KEY}
      - SUPABASE_DB_URL=postgresql://postgres:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-functions.rule=Host(`${SUPABASE_HOST}`) && PathPrefix(`/functions/`)
      - traefik.http.routers.supabase-functions.entrypoints=websecure
      - traefik.http.routers.supabase-functions.tls.certresolver=le
      - traefik.http.routers.supabase-functions.middlewares=supabase-functions-strip
      - traefik.http.middlewares.supabase-functions-strip.stripprefixregex.regex=^/functions/v1
      - traefik.http.services.supabase-functions.loadbalancer.server.port=9000
    restart: unless-stopped
    networks: [proxy]

  # Supabase Studio
  studio:
    image: supabase/studio:2025.06.30-sha-6f5982d
    container_name: supabase-studio
    depends_on:
      meta:
        condition: service_started
    environment:
      - STUDIO_PG_META_URL=http://meta:8080
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
      - DEFAULT_ORGANIZATION_NAME=Default Organization
      - DEFAULT_PROJECT_NAME=Default Project
      - SUPABASE_URL=${SUPABASE_PUBLIC_URL}
      - SUPABASE_PUBLIC_URL=${SUPABASE_PUBLIC_URL}
      - SUPABASE_ANON_KEY=${ANON_KEY}
      - SUPABASE_SERVICE_KEY=${SERVICE_ROLE_KEY}
      - AUTH_JWT_SECRET=${JWT_SECRET}
      - NEXT_PUBLIC_ENABLE_LOGS=true
    labels:
      - traefik.enable=true
      - traefik.http.routers.supabase-studio.rule=Host(`${STUDIO_HOST}`)
      - traefik.http.routers.supabase-studio.entrypoints=websecure
      - traefik.http.routers.supabase-studio.tls.certresolver=le
      - traefik.http.routers.supabase-studio.middlewares=studio-auth
      - traefik.http.middlewares.studio-auth.basicauth.users=${STUDIO_HTPASSWD}
      - traefik.http.services.supabase-studio.loadbalancer.server.port=3000
    restart: unless-stopped
    networks: [proxy]

  # --- Сайт: WordPress (apache) ---
  wordpress:
    image: wordpress:apache
    container_name: wp
    profiles: ["wordpress"]
    environment:
      - WORDPRESS_DB_HOST=wp-db:3306
      - WORDPRESS_DB_USER=${WP_DB_USER}
      - WORDPRESS_DB_PASSWORD=${WP_DB_PASSWORD}
      - WORDPRESS_DB_NAME=${WP_DB_NAME}
      - WORDPRESS_CONFIG_EXTRA=define('WP_HOME','https://${SITE_HOST}'); define('WP_SITEURL','https://${SITE_HOST}');
    volumes:
      - wp_data:/var/www/html
    depends_on:
      - wp-db
    labels:
      - traefik.enable=true
      - traefik.http.routers.site.rule=Host(`${SITE_HOST}`)
      - traefik.http.routers.site.entrypoints=websecure
      - traefik.http.routers.site.tls.certresolver=le
      - traefik.http.services.site.loadbalancer.server.port=80
    restart: unless-stopped
    networks: [proxy]

  wp-db:
    image: mariadb:11.4
    container_name: wp-db
    profiles: ["wordpress"]
    environment:
      - MARIADB_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MARIADB_DATABASE=${WP_DB_NAME}
      - MARIADB_USER=${WP_DB_USER}
      - MARIADB_PASSWORD=${WP_DB_PASSWORD}
    volumes:
      - wp_db_data:/var/lib/mysql
    restart: unless-stopped
    networks: [proxy]

  # --- Сайт: Статический Nginx ---
  site-static:
    image: nginx:alpine
    container_name: site-static
    profiles: ["static"]
    volumes:
      - ./site:/usr/share/nginx/html:ro
    labels:
      - traefik.enable=true
      - traefik.http.routers.site-static.rule=Host(`${SITE_HOST}`)
      - traefik.http.routers.site-static.entrypoints=websecure
      - traefik.http.routers.site-static.tls.certresolver=le
      - traefik.http.services.site-static.loadbalancer.server.port=80
    restart: unless-stopped
    networks: [proxy]
YAML

# --- Запуск ---
cd "$STACK_DIR"
docker compose pull
if [[ "$SITE_TYPE" == "wordpress" ]]; then
  docker compose --profile wordpress up -d
else
  docker compose --profile static up -d
fi

# === Авто-инициализация ролей Supabase и расширений (идемпотентно) ===
echo "[INFO] Ждём Postgres (health=healthy)..."
for i in {1..60}; do
  status=$(docker inspect -f '{{.State.Health.Status}}' supabase-db 2>/dev/null || echo "unknown")
  [ "$status" = "healthy" ] && echo "[INFO] Postgres healthy" && break
  sleep 2
done

echo "[INFO] Инициализируем роли/расширения в Postgres..."
docker exec -i supabase-db psql -U postgres -d "${POSTGRES_DB:-postgres}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    EXECUTE 'CREATE ROLE supabase_admin LOGIN SUPERUSER PASSWORD ''''${POSTGRES_PASSWORD}''''';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticator') THEN
    EXECUTE 'CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD ''''${POSTGRES_PASSWORD}''''';
  ELSE
    EXECUTE 'ALTER ROLE authenticator WITH PASSWORD ''''${POSTGRES_PASSWORD}''''';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    EXECUTE 'CREATE ROLE anon NOLOGIN';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    EXECUTE 'CREATE ROLE authenticated NOLOGIN';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_auth_admin') THEN
    EXECUTE 'CREATE ROLE supabase_auth_admin LOGIN PASSWORD ''''${POSTGRES_PASSWORD}''''';
  ELSE
    EXECUTE 'ALTER ROLE supabase_auth_admin WITH PASSWORD ''''${POSTGRES_PASSWORD}''''';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'supabase_storage_admin') THEN
    EXECUTE 'CREATE ROLE supabase_storage_admin LOGIN PASSWORD ''''${POSTGRES_PASSWORD}''''';
  ELSE
    EXECUTE 'ALTER ROLE supabase_storage_admin WITH PASSWORD ''''${POSTGRES_PASSWORD}''''';
  END IF;
END
\$\$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS vector;
SQL

echo "[INFO] Перезапускаем сервисы Supabase..."
docker compose restart auth rest realtime storage functions studio

# --- Вывод доступов ---
cat <<INFO

============================================================
 УСТАНОВКА ЗАВЕРШЕНА
============================================================

ДОМЕНЫ И URL:
  Сайт:            https://${SITE_HOST}
  n8n:             https://${N8N_HOST}
  Supabase API:    https://${SUPABASE_HOST}
    • Auth:        https://${SUPABASE_HOST}/auth/v1
    • REST:        https://${SUPABASE_HOST}/rest/v1
    • Storage:     https://${SUPABASE_HOST}/storage/v1
    • Realtime:    wss://${SUPABASE_HOST}/realtime/v1
    • Functions:   https://${SUPABASE_HOST}/functions/v1
    • Meta:        https://${SUPABASE_HOST}/meta/v1
  Studio:          https://${STUDIO_HOST}

n8n (BasicAuth):
  Пользователь:    ${N8N_BASIC_AUTH_USER}
  Пароль:          ${N8N_BASIC_AUTH_PASSWORD}
  ENCRYPTION_KEY:  ${N8N_ENCRYPTION_KEY}

Supabase ключи:
  JWT_SECRET:      ${JWT_SECRET}
  ANON_KEY:        ${ANON_KEY}
  SERVICE_ROLE_KEY:${SERVICE_ROLE_KEY}
  SECRET_KEY_BASE: ${SECRET_KEY_BASE}

Postgres:
  Хост:            db
  Порт:            5432
  БД:              ${POSTGRES_DB}
  Пользователь:    postgres (а также служебные роли Supabase)
  Пароль:          ${POSTGRES_PASSWORD}
  Строка:          postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}

Storage (локальные файлы): том Docker supabase_storage

Studio (BasicAuth, через Traefik):
  Пользователь:    supabase
  Пароль:          ${STUDIO_PASS:-<см. при первом запуске>}

WordPress / MariaDB (если выбран WordPress):
  DB_HOST:         wp-db:3306
  DB_NAME:         ${WP_DB_NAME}
  DB_USER:         ${WP_DB_USER}
  DB_PASSWORD:     ${WP_DB_PASSWORD}
  ROOT_PASSWORD:   ${MYSQL_ROOT_PASSWORD}

Все значения сохранены в: ${ENV_FILE}

Для обновления:
  cd ${STACK_DIR} && docker compose pull && docker compose up -d

Резервные копии:
  • DB: volume supabase_db_data
  • Файлы: supabase_storage, wp_data, wp_db_data, n8n_data
  • Certs: traefik_letsencrypt
  Данные сохраняются при перезапусках и обновлениях.

============================================================
INFO
