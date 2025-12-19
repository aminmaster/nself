#!/usr/bin/env bash
# ai-ops.sh - AI Operating System (AIO) Full Stack Generator
# Renamed from dify.sh. Generates a unified stack with 'aio-' prefix.

# Generate AIO Stack (Dify + Graphiti + Neo4j + MLFlow + FalkorDB)
generate_aio_stack() {
  local index="$1"
  local service_name="$2" # usually "dify" or "ai-ops" - used for directory paths
  local port="$3" # usually 80 (internal nginx port)

  # Configuration
  local version="${DIFY_VERSION:-1.11.1}"
  local subdomain="${DIFY_SUBDOMAIN:-dify}"
  local secret_key="${DIFY_SECRET_KEY:-$(openssl rand -base64 32)}"
  local redis_password="${DIFY_REDIS_PASSWORD:-aioredispass}"
  local plugin_daemon_key="${DIFY_PLUGIN_DAEMON_KEY:-$(openssl rand -base64 32)}"
  local inner_api_key="${DIFY_INNER_API_KEY:-$(openssl rand -base64 32)}"
  local api_url="https://${subdomain}.${BASE_DOMAIN}"
  local web_url="https://${subdomain}.${BASE_DOMAIN}"
  
  echo ""
  echo "  # ============================================"
  echo "  # AI Operating System (AIO) Stack"
  echo "  # Includes: Dify v${version}, Graphiti, Neo4j, FalkorDB, MLFlow"
  echo "  # Includes: Dify v${version}, Graphiti, Neo4j, FalkorDB, MLFlow"
  echo "  # ============================================"

  # Ensure MLFlow Dockerfile exists (required for Postgres support)
  local mlflow_dir="./services/${service_name}/mlflow"
  mkdir -p "$mlflow_dir"
  if [[ ! -f "$mlflow_dir/Dockerfile" ]]; then
      cat > "$mlflow_dir/Dockerfile" <<DOCKERFILE
FROM ghcr.io/mlflow/mlflow:latest
RUN pip install psycopg2-binary
DOCKERFILE
  fi

  # 1. AIO Dify Nginx (Entrypoint/Gateway)
  cat <<EOF
  aio-dify-nginx:
    image: nginx:latest
    container_name: \${PROJECT_NAME}_aio_dify_nginx
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
      # Mount official templates downloaded by Init script to services/${service_name}
      - ./services/${service_name}/nginx/nginx.conf.template:/etc/nginx/nginx.conf.template
      - ./services/${service_name}/nginx/proxy.conf.template:/etc/nginx/proxy.conf.template
      - ./services/${service_name}/nginx/https.conf.template:/etc/nginx/https.conf.template
      - ./services/${service_name}/nginx/docker-entrypoint.sh:/docker-entrypoint-mount.sh
      - ./services/${service_name}/nginx/conf.d:/etc/nginx/conf.d
    entrypoint: [ "sh", "-c", "cp /docker-entrypoint-mount.sh /docker-entrypoint.sh && sed -i 's/\r$$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh && /docker-entrypoint.sh" ]
    depends_on:
      - aio-dify-api
      - aio-dify-web
      - aio-dify-plugin-daemon
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - nginx
          # Legacy aliases if needed?
          - dify-nginx
EOF

  # 1.5 AIO Init (Permissions + DB Init + Migrations)
  # Runs as root to fix permissions, then switches context for DB ops
  cat <<EOF
  aio-init:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_aio_init
    restart: "no"
    user: root
    environment:
      - LOG_LEVEL=INFO
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=aio-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
    entrypoint: []
    command:
      - /bin/bash
      - -c
      - |
        set -e
        echo "1. Installing Dependencies..."
        apt-get update && apt-get install -y netcat-openbsd

        echo "2. Setting Permissions..."
        mkdir -p /app/api/storage /app/daemon_storage/cwd /app/daemon_storage/archives
        chown -R 1001:1001 /app/api/storage /app/daemon_storage

        echo "3. Waiting for Database..."
        while ! nc -z aio-db 5432; do sleep 1; done

        echo "4. Initializing MLFlow Database..."
        python3 -c "import psycopg2; from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT;
        try:
            conn = psycopg2.connect(dbname='postgres', user='postgres', password='\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}', host='aio-db', port=5432);
            conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT);
            cur = conn.cursor();
            cur.execute(\"SELECT 1 FROM pg_database WHERE datname = 'mlflow'\");
            if not cur.fetchone():
                print('Creating database mlflow...');
                cur.execute(\"CREATE DATABASE mlflow\");
            else:
                print('Database mlflow already exists.');
            cur.close();
            conn.close();
        except Exception as e:
            print(f'Error initializing MLFlow DB: {e}');
            exit(1);"

        echo "4. Running Dify Migrations..."
        flask db upgrade

        echo "5. Initializing FalkorDB security..."
        if [[ -n "${FALKORDB_PASSWORD:-}" ]]; then
          echo "Setting up FalkorDB ACLs..."
          # Install redis-tools if not present
          apt-get install -y redis-tools
          
          # Wait for FalkorDB
          while ! nc -z aio-falkordb 6379; do sleep 1; done
          
          # Set up the admin user
          # Note: We use 'default' password too if FALKORDB_PASSWORD is provided to secure the instance fully
          redis-cli -h aio-falkordb ACL SETUSER "${FALKORDB_USER:-falkor_admin}" on ">${FALKORDB_PASSWORD}" allkeys allchannels allcommands +@all
          redis-cli -h aio-falkordb CONFIG SET requirepass "${FALKORDB_PASSWORD}"
          echo "FalkorDB security initialized."
        fi

        echo "All initialization tasks completed."
    volumes:
      - ./.volumes/${service_name}/storage:/app/api/storage
      - ./.volumes/${service_name}/plugin_daemon:/app/daemon_storage
    depends_on:
      aio-db:
        condition: service_healthy
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 2. Dify API
  cat <<EOF
  aio-dify-api:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_aio_dify_api
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DIFY_PORT=5001
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=aio-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=aio-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - CELERY_BROKER_URL=redis://:${redis_password}@aio-redis:6379/1
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
      - VECTOR_STORE=weaviate
      - WEAVIATE_ENDPOINT=http://aio-weaviate:8080
      - WEAVIATE_API_KEY=\${DIFY_WEAVIATE_API_KEY:-aio-weaviate-key}
      - CONSOLE_API_URL=${api_url}
      - CONSOLE_WEB_URL=${web_url}
      - SERVICE_API_URL=${api_url}
      - APP_API_URL=${api_url}
      - APP_WEB_URL=${web_url}
      - DIFY_PLUGIN_DAEMON_URL=http://aio-dify-plugin-daemon:5002
      - PLUGIN_DAEMON_URL=http://aio-dify-plugin-daemon:5002
      - DIFY_PLUGIN_DAEMON_API_KEY=${plugin_daemon_key}
      - PLUGIN_DAEMON_KEY=${plugin_daemon_key}
    volumes:
      - ./.volumes/${service_name}/storage:/app/api/storage
    depends_on:
      aio-db:
        condition: service_healthy
      aio-redis:
        condition: service_started
      aio-weaviate:
        condition: service_started
      aio-init:
        condition: service_completed_successfully
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - api
          - dify-api
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 10s
      retries: 5
EOF

  # 3. Dify Worker
  cat <<EOF
  aio-dify-worker:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_aio_dify_worker
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DIFY_PORT=5001
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=aio-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=aio-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - CELERY_BROKER_URL=redis://:${redis_password}@aio-redis:6379/1
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
      - VECTOR_STORE=weaviate
      - WEAVIATE_ENDPOINT=http://aio-weaviate:8080
      - WEAVIATE_API_KEY=\${DIFY_WEAVIATE_API_KEY:-aio-weaviate-key}
      - DIFY_PLUGIN_DAEMON_URL=http://aio-dify-plugin-daemon:5002
      - PLUGIN_DAEMON_URL=http://aio-dify-plugin-daemon:5002
      - DIFY_PLUGIN_DAEMON_API_KEY=${plugin_daemon_key}
      - PLUGIN_DAEMON_KEY=${plugin_daemon_key}
    volumes:
      - ./.volumes/${service_name}/storage:/app/api/storage
    command: /bin/bash /entrypoint.sh python -m celery -A app.celery worker -P gevent -c 1 -Q dataset,generation,mail,ops_trace --loglevel INFO
    depends_on:
      aio-db:
        condition: service_healthy
      aio-redis:
        condition: service_started
      aio-weaviate:
        condition: service_started
      aio-init:
        condition: service_completed_successfully
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 4. Dify Web
  cat <<EOF
  aio-dify-web:
    image: langgenius/dify-web:${version}
    container_name: \${PROJECT_NAME}_aio_dify_web
    restart: unless-stopped
    environment:
      - CONSOLE_API_URL=${api_url}
      - APP_API_URL=${api_url}
      - SENTRY_DSN=
      - HOSTNAME=0.0.0.0
    depends_on:
      - aio-dify-api
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - web
          - dify-web
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:3000"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

  # 5. Dify Sandbox
  cat <<EOF
  aio-dify-sandbox:
    image: langgenius/dify-sandbox:0.2.1
    container_name: \${PROJECT_NAME}_aio_dify_sandbox
    restart: unless-stopped
    environment:
      - API_KEY=dify-sandbox
      - GIN_MODE=release
      - WORKER_TIMEOUT=15
      - ENABLE_NETWORK=true
      - HTTP_PROXY=http://aio-ssrf:3128
      - HTTPS_PROXY=http://aio-ssrf:3128
      - SANDBOX_PORT=8194
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - sandbox
          - dify-sandbox
EOF

  # New Plugin Daemon
  cat <<EOF
  aio-dify-plugin-daemon:
    image: langgenius/dify-plugin-daemon:0.5.1-local
    container_name: \${PROJECT_NAME}_aio_dify_plugin_daemon
    restart: unless-stopped
    environment:
      - LOG_LEVEL=INFO
      - SECRET_KEY=${secret_key}
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=aio-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - REDIS_HOST=aio-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - REDIS_DB=1
      - SERVER_PORT=5002
      - SERVER_KEY=${plugin_daemon_key}
      - DIFY_INNER_API_URL=http://aio-dify-api:5001
      - DIFY_INNER_API_KEY=${inner_api_key}
      - PLUGIN_MAX_PACKAGE_SIZE=52428800
      - PLUGIN_DEBUGGING_HOST=0.0.0.0
      - PLUGIN_DEBUGGING_PORT=5003
      - PLUGIN_REMOTE_INSTALLING_HOST=0.0.0.0
      - PLUGIN_REMOTE_INSTALLING_PORT=5003
      - PLUGIN_WORKING_PATH=/app/storage/cwd
      - FORCE_VERIFYING_SIGNATURE=false
      - PLUGIN_S3_USE_AWS=false
      - PLUGIN_DAEMON_PORT=5002
      - DIFY_BIND_ADDRESS=0.0.0.0
    volumes:
      - ./.volumes/${service_name}/plugin_daemon:/app/storage
    depends_on:
      - aio-db
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - plugin_daemon
          - dify-plugin-daemon
EOF

  # 6. AIO DB (Postgres)
  cat <<EOF
  aio-db:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_aio_db
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - POSTGRES_DB=dify
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - ./.volumes/${service_name}/db:/var/lib/postgresql/data
    networks:
      - \${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5
EOF

  # 7. AIO Redis
  cat <<EOF
  aio-redis:
    image: redis:6-alpine
    container_name: \${PROJECT_NAME}_aio_redis
    restart: unless-stopped
    command: redis-server --requirepass "${redis_password}"
    volumes:
      - ./.volumes/${service_name}/redis:/data
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 8. AIO Weaviate
  cat <<EOF
  aio-weaviate:
    image: semitechnologies/weaviate:1.27.0
    container_name: \${PROJECT_NAME}_aio_weaviate
    restart: unless-stopped
    environment:
      - QUERY_DEFAULTS_LIMIT=25
      - AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=false
      - DEFAULT_VECTORIZER_MODULE=none
      - CLUSTER_HOSTNAME=node1
      - AUTHENTICATION_APIKEY_ENABLED=true
      - AUTHENTICATION_APIKEY_ALLOWED_KEYS=\${DIFY_WEAVIATE_API_KEY:-aio-weaviate-key}
      - AUTHENTICATION_APIKEY_USERS=hello@dify.ai
      - AUTHORIZATION_ADMINLIST_ENABLED=true
      - AUTHORIZATION_ADMINLIST_USERS=hello@dify.ai
      - PERSISTENCE_DATA_PATH=/var/lib/weaviate
    volumes:
      - ./.volumes/${service_name}/weaviate:/var/lib/weaviate
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 9. AIO SSRF
  cat <<EOF
  aio-ssrf:
    image: ubuntu/squid:latest
    container_name: \${PROJECT_NAME}_aio_ssrf
    restart: unless-stopped
    environment:
      - HTTP_PROXY=http://aio-ssrf:3128
      - HTTP_PORT=3128
      - COREDUMP_DIR=/var/spool/squid
      - REVERSE_PROXY_PORT=8194
      - SANDBOX_HOST=aio-dify-sandbox
      - SANDBOX_PORT=8194
    volumes:
      - ./services/${service_name}/ssrf/squid.conf.template:/etc/squid/squid.conf.template
      - ./services/${service_name}/ssrf/docker-entrypoint.sh:/docker-entrypoint-mount.sh
    entrypoint: [ "sh", "-c", "cp /docker-entrypoint-mount.sh /docker-entrypoint.sh && sed -i 's/\r$$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh && /docker-entrypoint.sh" ]
    depends_on:
      - aio-dify-sandbox
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 10. AIO Graphiti
  cat <<EOF
  aio-graphiti:
    image: zepai/graphiti:latest
    container_name: \${PROJECT_NAME}_aio_graphiti
    restart: unless-stopped
    environment:
      - PORT=8000
      - OPENAI_API_KEY=\${OPENAI_API_KEY}
      - NEO4J_URI=bolt://aio-neo4j:7687
      - NEO4J_USER=\${NEO4J_USER:-neo4j}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD}
      - GRAPHITI_DATABASE=neo4j
      - GRAPH_DRIVER_TYPE=falkordb
      - FALKORDB_HOST=aio-falkordb
      - FALKORDB_PORT=6379
    volumes:
      - ./.volumes/${service_name}/graphiti/data:/app/data
    depends_on:
      - aio-neo4j
      - aio-falkordb
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - graphiti
          - dify-graphiti
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

  # 11. AIO FalkorDB
  cat <<EOF
  aio-falkordb:
    image: falkordb/falkordb:latest
    container_name: \${PROJECT_NAME}_aio_falkordb
    restart: unless-stopped
    volumes:
      - ./.volumes/${service_name}/falkordb/data:/data
    networks:
      - \${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "\${FALKORDB_PASSWORD}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

  # 11.5 AIO FalkorDB Browser
  aio-falkordb-browser:
    image: falkordb/falkordb-browser:latest
    container_name: \${PROJECT_NAME}_aio_falkordb_browser
    restart: unless-stopped
    environment:
      - FALKORDB_URL=${FALKORDB_URL:-falkor://aio-falkordb:6379}
      - FALKORDB_HOST=aio-falkordb
      - FALKORDB_PORT=6379
      - REDIS_HOST=aio-falkordb
      - REDIS_PORT=6379
    networks:
      - \${DOCKER_NETWORK}
    depends_on:
      aio-falkordb:
        condition: service_healthy

EOF

  # 12. AIO Neo4j
  cat <<EOF
  aio-neo4j:
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_aio_neo4j
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=neo4j/\${NEO4J_PASSWORD}
      - NEO4J_dbms_memory_pagecache_size=512m
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=1G
    volumes:
      - ./.volumes/${service_name}/neo4j/data:/data
      - ./.volumes/${service_name}/neo4j/logs:/logs
      - ./.volumes/${service_name}/neo4j/import:/var/lib/neo4j/import
      - ./.volumes/${service_name}/neo4j/plugins:/plugins
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - neo4j
          - dify-neo4j
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s
EOF

  # 13. AIO MLFlow
  cat <<EOF
  aio-mlflow:
    build:
      context: ./services/${service_name}/mlflow
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_aio_mlflow
    restart: unless-stopped
    environment:
      - MLFLOW_BACKEND_STORE_URI=postgresql://postgres:\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}@aio-db:5432/mlflow
      - MLFLOW_DEFAULT_ARTIFACT_ROOT=/mlflow/artifacts
      - MLFLOW_HOST=0.0.0.0
      - MLFLOW_PORT=5000
    command: mlflow server --backend-store-uri postgresql://postgres:\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}@aio-db:5432/mlflow --default-artifact-root /mlflow/artifacts --host 0.0.0.0 --port 5000 --serve-artifacts
    volumes:
      - ./.volumes/${service_name}/mlflow/artifacts:/mlflow/artifacts
    depends_on:
      aio-db:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - mlflow
          - dify-mlflow
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
}

export -f generate_aio_stack

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
  local api_url="https://${subdomain}.${BASE_DOMAIN}"
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
      - ./services/${service_name}/nginx/nginx.conf.template:/etc/nginx/nginx.conf.template
      - ./services/${service_name}/nginx/proxy.conf.template:/etc/nginx/proxy.conf.template
      - ./services/${service_name}/nginx/https.conf.template:/etc/nginx/https.conf.template
      - ./services/${service_name}/nginx/docker-entrypoint.sh:/docker-entrypoint-mount.sh
      - ./services/${service_name}/nginx/conf.d:/etc/nginx/conf.d
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

  # 1.5 Dify Permissions Init (Fix volume ownership)
  cat <<EOF
  dify-permissions-init:
    image: alpine:latest
    container_name: \${PROJECT_NAME}_dify_permissions_init
    command: sh -c "mkdir -p /app/api/storage /app/daemon_storage/cwd /app/daemon_storage/archives && chown -R 1001:1001 /app/api/storage /app/daemon_storage"
    volumes:
      - ./.volumes/dify/storage:/app/api/storage
      - ./.volumes/dify/plugin_daemon:/app/daemon_storage
    network_mode: none
EOF

  # 1.6 Dify Database Migration (Explicit Schema Init)
  cat <<EOF
  dify-db-migrate:
    image: langgenius/dify-api:${version}
    container_name: \${PROJECT_NAME}_dify_db_migrate
    restart: "no"
    environment:
      - LOG_LEVEL=INFO
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${DIFY_DB_PASSWORD:-\${POSTGRES_PASSWORD}}
      - DB_HOST=dify-db
      - DB_PORT=5432
      - DB_DATABASE=dify
      - STORAGE_TYPE=local
      - STORAGE_LOCAL_PATH=/app/api/storage
    entrypoint: ["/bin/bash", "-c", "flask db upgrade"]
    depends_on:
      dify-db:
        condition: service_healthy
    networks:
      - \${DOCKER_NETWORK}
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
      - DIFY_PLUGIN_DAEMON_URL=http://dify-plugin-daemon:5002
      - PLUGIN_DAEMON_URL=http://dify-plugin-daemon:5002
      - DIFY_PLUGIN_DAEMON_API_KEY=${plugin_daemon_key}
      - PLUGIN_DAEMON_KEY=${plugin_daemon_key}
    volumes:
      - ./.volumes/dify/storage:/app/api/storage
    depends_on:
      dify-db:
        condition: service_healthy
      dify-redis:
        condition: service_started
      dify-weaviate:
        condition: service_started
      dify-permissions-init:
        condition: service_completed_successfully
      dify-db-migrate:
        condition: service_completed_successfully
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
      - DIFY_PLUGIN_DAEMON_URL=http://dify-plugin-daemon:5002
      - PLUGIN_DAEMON_URL=http://dify-plugin-daemon:5002
      - DIFY_PLUGIN_DAEMON_API_KEY=${plugin_daemon_key}
      - PLUGIN_DAEMON_KEY=${plugin_daemon_key}
    volumes:
      - ./.volumes/dify/storage:/app/api/storage
    command: /bin/bash /entrypoint.sh python -m celery -A app.celery worker -P gevent -c 1 -Q dataset,generation,mail,ops_trace --loglevel INFO
    depends_on:
      dify-db:
        condition: service_healthy
      dify-redis:
        condition: service_started
      dify-weaviate:
        condition: service_started
      dify-permissions-init:
        condition: service_completed_successfully
      dify-db-migrate:
        condition: service_completed_successfully
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
      - HOSTNAME=0.0.0.0
    depends_on:
      - dify-api
    networks:
      ${DOCKER_NETWORK}:
        aliases:
          - web
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://127.0.0.1:3000"]
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
      - PLUGIN_S3_USE_AWS=false
      - PLUGIN_DAEMON_PORT=5002
      - DIFY_BIND_ADDRESS=0.0.0.0
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
      - ./services/${service_name}/ssrf/squid.conf.template:/etc/squid/squid.conf.template
      - ./services/${service_name}/ssrf/docker-entrypoint.sh:/docker-entrypoint-mount.sh
    entrypoint: [ "sh", "-c", "cp /docker-entrypoint-mount.sh /docker-entrypoint.sh && sed -i 's/\r$$//' /docker-entrypoint.sh && chmod +x /docker-entrypoint.sh && /docker-entrypoint.sh" ]
    depends_on:
      - dify-sandbox
    networks:
      - \${DOCKER_NETWORK}
EOF

  # 10. Graphiti (Knowledge Graph API)
  cat <<EOF
  dify-graphiti:
    image: zepai/graphiti:latest
    container_name: \${PROJECT_NAME}_dify_graphiti
    restart: unless-stopped
    environment:
      - PORT=8000
      - OPENAI_API_KEY=\${OPENAI_API_KEY}
      - NEO4J_URI=bolt://dify-neo4j:7687
      - NEO4J_USER=\${NEO4J_USER:-neo4j}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD}
      - GRAPHITI_DATABASE=neo4j
      - GRAPH_DRIVER_TYPE=falkordb
      - FALKORDB_HOST=dify-falkordb
      - FALKORDB_PORT=6379
    volumes:
      - ./.volumes/dify/graphiti/data:/app/data
    depends_on:
      - dify-neo4j
      - dify-falkordb
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - graphiti
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

  # 11. FalkorDB (User Memory Graph)
  cat <<EOF
  dify-falkordb:
    image: falkordb/falkordb:latest
    container_name: \${PROJECT_NAME}_dify_falkordb
    restart: unless-stopped
    volumes:
      - ./.volumes/dify/falkordb/data:/data
    networks:
      - \${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF

  # 12. Neo4j (Static Knowledge Graph)
  cat <<EOF
  dify-neo4j:
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_dify_neo4j
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=neo4j/\${NEO4J_PASSWORD}
      - NEO4J_dbms_memory_pagecache_size=512m
      - NEO4J_dbms_memory_heap_initial__size=512m
      - NEO4J_dbms_memory_heap_max__size=1G
    volumes:
      - ./.volumes/dify/neo4j/data:/data
      - ./.volumes/dify/neo4j/logs:/logs
      - ./.volumes/dify/neo4j/import:/var/lib/neo4j/import
      - ./.volumes/dify/neo4j/plugins:/plugins
    networks:
      - \${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s
EOF

  # 13. MLFlow (Model Lifecycle)
  # Uses the standard MLFlow image but mounts volume for artifacts
  cat <<EOF
  dify-mlflow:
    image: ghcr.io/mlflow/mlflow:latest
    container_name: \${PROJECT_NAME}_dify_mlflow
    restart: unless-stopped
    environment:
      - MLFLOW_BACKEND_STORE_URI=postgresql://postgres:\${POSTGRES_PASSWORD}@dify-db:5432/mlflow
      - MLFLOW_DEFAULT_ARTIFACT_ROOT=/mlflow/artifacts
      - MLFLOW_HOST=0.0.0.0
      - MLFLOW_PORT=5000
    command: mlflow server --backend-store-uri postgresql://postgres:\${POSTGRES_PASSWORD}@dify-db:5432/mlflow --default-artifact-root /mlflow/artifacts --host 0.0.0.0 --port 5000 --serve-artifacts
    volumes:
      - ./.volumes/dify/mlflow/artifacts:/mlflow/artifacts
    depends_on:
      dify-db:
        condition: service_healthy
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - mlflow
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
}


export -f generate_dify_stack
