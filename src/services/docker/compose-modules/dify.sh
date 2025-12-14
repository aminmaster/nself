#!/usr/bin/env bash
# dify.sh - Dify.ai Full Stack Service Generator

# Generate Dify Stack (11 Containers -> now 12 with plugin_daemon)
# Updated to match Dify v1.11.1 Strict Compliance
generate_dify_stack() {
  local index="$1"
  local service_name="$2" # usually "dify"
  local port="$3" # usually 80 (internal nginx port)

  # Configuration
  local version="${DIFY_VERSION:-1.11.1}"
  local subdomain="${DIFY_SUBDOMAIN:-dify}"
  local secret_key="${DIFY_SECRET_KEY:-$(openssl rand -base64 32)}"
  local redis_password="${DIFY_REDIS_PASSWORD:-difyredispass}"
  local plugin_daemon_key="${DIFY_PLUGIN_DAEMON_KEY:-$(openssl rand -base64 32)}"
  local inner_api_key="${DIFY_INNER_API_KEY:-$(openssl rand -base64 32)}"
  local api_url="https://${subdomain}.${BASE_DOMAIN}/api"
  local web_url="https://${subdomain}.${BASE_DOMAIN}"
  
  echo ""
  echo "  # ============================================"
  echo "  # Dify.ai Full Stack (v${version})"
  echo "  # ============================================"

  # 1. Internal Nginx (Entrypoint)
  # Needs complete environment variables to avoid syntax errors in templates
  cat <<EOF
  dify-nginx:
    image: nginx:latest
    container_name: \${PROJECT_NAME}_dify_nginx
    restart: unless-stopped
    environment:
      - NGINX_PORT=80
      - NGINX_SSL_PORT=443
      - NGINX_SERVER_NAME=_
      - NGINX_HTTPS_ENABLED=false
      - NGINX_CLIENT_MAX_BODY_SIZE=100M
      - NGINX_KEEPALIVE_TIMEOUT=65
      - NGINX_PROXY_READ_TIMEOUT=3600s
      - NGINX_PROXY_SEND_TIMEOUT=3600s
      - NGINX_WORKER_PROCESSES=auto
      - CONSOLE_API_URL=${api_url}
      - APP_API_URL=${api_url}
    volumes:
      # Mount official templates downloaded by Init script
      - ./services/dify/nginx/nginx.conf.template:/etc/nginx/nginx.conf.template
      - ./services/dify/nginx/proxy.conf.template:/etc/nginx/proxy.conf.template
      - ./services/dify/nginx/https.conf.template:/etc/nginx/https.conf.template
      - ./services/dify/nginx/docker-entrypoint.sh:/docker-entrypoint-mount.sh
      - ./services/dify/nginx/conf.d:/etc/nginx/conf.d
    entrypoint: [ "sh", "-c", "cp /docker-entrypoint-mount.sh /docker-entrypoint.sh && sed -i 's/\r\$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh && /docker-entrypoint.sh" ]
    depends_on:
      - dify-api
      - dify-web
      - dify-plugin-daemon
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - nginx
EOF

  # 2. Dify API
  cat <<EOF
  dify-api:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_dify_api
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DIFY_PORT=5001
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=dify-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=dify-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - CELERY_BROKER_URL=redis://:${redis_password}@dify-redis:6379/1
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
      - VECTOR_STORE=weaviate
      - WEAVIATE_ENDPOINT=http://dify-weaviate:8080
      - WEAVIATE_API_KEY=\${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      - CONSOLE_API_URL=${api_url}
      - CONSOLE_WEB_URL=${web_url}
      - SERVICE_API_URL=${api_url}
      - APP_API_URL=${api_url}
      - APP_WEB_URL=${web_url}
    volumes:
      - ./.volumes/dify/storage:/app/api/storage
    depends_on:
      - dify-db
      - dify-redis
      - dify-weaviate
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - api
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 10s
      retries: 5
EOF

  # 3. Dify Worker
  cat <<EOF
  dify-worker:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_dify_worker
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DIFY_PORT=5001
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=dify-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=dify-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - CELERY_BROKER_URL=redis://:${redis_password}@dify-redis:6379/1
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
      - VECTOR_STORE=weaviate
      - WEAVIATE_ENDPOINT=http://dify-weaviate:8080
      - WEAVIATE_API_KEY=\${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
    volumes:
      - ./.volumes/dify/storage:/app/api/storage
    command: /bin/bash /entrypoint.sh python -m celery -A app.celery worker -P gevent -c 1 -Q dataset,generation,mail,ops_trace --loglevel INFO
    depends_on:
      - dify-db
      - dify-redis
      - dify-weaviate
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 4. Dify Web
  cat <<EOF
  dify-web:
    image: langgenius/dify-web:${version}
    container_name: \${PROJECT_NAME}_dify_web
    restart: unless-stopped
    environment:
      - CONSOLE_API_URL=${api_url}
      - APP_API_URL=${api_url}
      - SENTRY_DSN=
    depends_on:
      - dify-api
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - web
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:3000"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

  # 5. Dify Sandbox (Code Execution)
  cat <<EOF
  dify-sandbox:
    image: langgenius/dify-sandbox:0.2.1
    container_name: \${PROJECT_NAME}_dify_sandbox
    restart: unless-stopped
    environment:
      - API_KEY=dify-sandbox
      - GIN_MODE=release
      - WORKER_TIMEOUT=15
      - ENABLE_NETWORK=true
      - HTTP_PROXY=http://dify-ssrf:3128
      - HTTPS_PROXY=http://dify-ssrf:3128
      - SANDBOX_PORT=8194
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - sandbox
EOF

  # NEW: Dify Plugin Daemon (Required for 1.11.x)
  # Uses shared env vars similar to API
  cat <<EOF
  dify-plugin-daemon:
    image: langgenius/dify-plugin-daemon:0.5.1-local
    container_name: \${PROJECT_NAME}_dify_plugin_daemon
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=dify-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=dify-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - SERVER_PORT=5002
      - SERVER_KEY=${plugin_daemon_key}
      - DIFY_INNER_API_URL=http://dify-api:5001
      - DIFY_INNER_API_KEY=${inner_api_key}
      - PLUGIN_MAX_PACKAGE_SIZE=52428800
      - PLUGIN_DEBUGGING_HOST=0.0.0.0
      - PLUGIN_DEBUGGING_PORT=5003
      - PLUGIN_REMOTE_INSTALLING_HOST=0.0.0.0
      - PLUGIN_REMOTE_INSTALLING_PORT=5003
      - PLUGIN_WORKING_PATH=/app/storage/cwd
      - FORCE_VERIFYING_SIGNATURE=false
    volumes:
      - ./.volumes/dify/plugin_daemon:/app/storage
    depends_on:
      - dify-db
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - plugin_daemon
EOF

  # 6. Dify DB (Postgres 15 with pgvector)
  cat <<EOF
  dify-db:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_dify_db
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - POSTGRES_DB=dify
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - ./.volumes/dify/db:/var/lib/postgresql/data
    networks:
      - \${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF

  # 7. Dify Redis (Redis 6)
  cat <<EOF
  dify-redis:
    image: redis:6-alpine
    container_name: \${PROJECT_NAME}_dify_redis
    restart: unless-stopped
    command: redis-server --requirepass "${redis_password}"
    volumes:
      - ./.volumes/dify/redis:/data
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 8. Dify Weaviate (Vector DB)
  cat <<EOF
  dify-weaviate:
    image: semitechnologies/weaviate:1.27.0
    container_name: \${PROJECT_NAME}_dify_weaviate
    restart: unless-stopped
    environment:
      - QUERY_DEFAULTS_LIMIT=25
      - AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=false
      - DEFAULT_VECTORIZER_MODULE=none
      - CLUSTER_HOSTNAME=node1
      - AUTHENTICATION_APIKEY_ENABLED=true
      - AUTHENTICATION_APIKEY_ALLOWED_KEYS=\${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      - AUTHENTICATION_APIKEY_USERS=hello@dify.ai
      - AUTHORIZATION_ADMINLIST_ENABLED=true
      - AUTHORIZATION_ADMINLIST_USERS=hello@dify.ai
      - PERSISTENCE_DATA_PATH=/var/lib/weaviate
    volumes:
      - ./.volumes/dify/weaviate:/var/lib/weaviate
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 9. SSRF Proxy
  cat <<EOF
  dify-ssrf:
    image: ubuntu/squid:latest
    container_name: \${PROJECT_NAME}_dify_ssrf
    restart: unless-stopped
    environment:
      - HTTP_PORT=3128
      - COREDUMP_DIR=/var/spool/squid
      - REVERSE_PROXY_PORT=8194
      - SANDBOX_HOST=dify-sandbox
      - SANDBOX_PORT=8194
    volumes:
      - ./services/dify/ssrf/squid.conf.template:/etc/squid/squid.conf.template
      - ./services/dify/ssrf/docker-entrypoint.sh:/docker-entrypoint-mount.sh
    entrypoint: [ "sh", "-c", "cp /docker-entrypoint-mount.sh /docker-entrypoint.sh && sed -i 's/\r$$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh && /docker-entrypoint.sh" ]
    depends_on:
      - dify-sandbox
    networks:
      - \${DOCKER_NETWORK}
EOF
}

export -f generate_dify_stack
