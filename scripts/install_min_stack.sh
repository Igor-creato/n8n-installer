#!/usr/bin/env bash
sed -i '/wordpress:/,/networks: \[proxy\]/{/wordpress:/!{/networks: \[proxy\]/!d}}' "$COMPOSE_FILE"
sed -i '/wp-db:/,/networks: \[proxy\]/{/wp-db:/!{/networks: \[proxy\]/!d}}' "$COMPOSE_FILE"
fi


# Права на acme.json внутри volume Traefik (создастся автоматически)
# (Traefik v3 сам создаст файл, когда запросит сертификат)


# === Старт ===
cd "$STACK_DIR"
docker compose pull
docker compose up -d


# === Вывод доступов ===
cat <<INFO


============================================================
УСТАНОВКА ЗАВЕРШЕНА
============================================================


ДОМЕНЫ И URL:
Сайт: https://${SITE_HOST}
n8n: https://${N8N_HOST}
Supabase API: https://${SUPABASE_HOST}
• Auth: https://${SUPABASE_HOST}/auth/v1
• REST: https://${SUPABASE_HOST}/rest/v1
• Storage: https://${SUPABASE_HOST}/storage/v1
• Realtime: wss://${SUPABASE_HOST}/realtime/v1
• Functions: https://${SUPABASE_HOST}/functions/v1
• Meta: https://${SUPABASE_HOST}/meta/v1
Studio: https://${STUDIO_HOST}


n8n (BasicAuth):
Пользователь: ${N8N_BASIC_AUTH_USER}
Пароль: ${N8N_BASIC_AUTH_PASSWORD}
ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}


Supabase ключи:
JWT_SECRET: ${JWT_SECRET}
ANON_KEY: ${ANON_KEY}
SERVICE_ROLE_KEY:${SERVICE_ROLE_KEY}
SECRET_KEY_BASE: ${SECRET_KEY_BASE}


Postgres:
Хост: db
Порт: 5432
БД: ${POSTGRES_DB}
Пользователь: postgres (а также служебные роли Supabase)
Пароль: ${POSTGRES_PASSWORD}
Строка: postgresql://postgres:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}


Storage (локальные файлы): том Docker supabase_storage


Studio (BasicAuth, через Traefik):
Пользователь: ${STUDIO_USER}
Пароль: ${STUDIO_PASS}


WordPress / MariaDB (если выбран WordPress):
DB_HOST: wp-db:3306
DB_NAME: ${WP_DB_NAME}
DB_USER: ${WP_DB_USER}
DB_PASSWORD: ${WP_DB_PASSWORD}
ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}


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