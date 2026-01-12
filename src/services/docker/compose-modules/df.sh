# df.sh - Dify Stack Module (Recovered & Isolated)

generate_df_stack() {
  local service_name="df"
  
  cat <<EOF

  # Dify Isolated Infrastructure
  df-db:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_df_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: dify
    volumes:
      - df_db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  df-redis:
    image: redis:7-alpine
    container_name: \${PROJECT_NAME}_df_redis
    restart: unless-stopped
    command: redis-server --requirepass "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}"
    volumes:
      - df_redis_data:/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  df-weaviate:
    image: semitechnologies/weaviate:1.27.0
    container_name: \${PROJECT_NAME}_df_weaviate
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
      - df_weaviate_data:/var/lib/weaviate
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:8080/v1/.well-known/ready || exit 1"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 30s
      start_period: 30s


  # Dify Init Service (DB Migrations)
  df-init:
    image: langgenius/dify-api:latest
    container_name: \${PROJECT_NAME}_df_init
    entrypoint: ["/bin/bash", "-c"]
    command: ["flask db upgrade"]
    environment:
      DB_USERNAME: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: df-db
      DB_PORT: 5432
      DB_DATABASE: dify
      REDIS_HOST: df-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      WEAVIATE_HOST: df-weaviate
      WEAVIATE_PORT: 8080
      WEAVIATE_API_KEY: \${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      STORAGE_TYPE: local
      STORAGE_LOCAL_PATH: /app/api/storage
    depends_on:
      df-db:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}
    restart: "no"

  # Dify Services
  df-api:
    image: langgenius/dify-api:latest
    container_name: \${PROJECT_NAME}_df_api
    restart: unless-stopped
    environment:
      DB_USERNAME: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: df-db
      DB_PORT: 5432
      DB_DATABASE: dify
      REDIS_HOST: df-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      WEAVIATE_HOST: df-weaviate
      WEAVIATE_PORT: 8080
      WEAVIATE_API_KEY: \${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      STORAGE_TYPE: local
      STORAGE_LOCAL_PATH: /app/api/storage
      SECRET_KEY: \${DIFY_SECRET_KEY:-sk-9f73s3ljTXVcMT3Blbkfk1TWf4YHlM4dT_XqD_vP_-iwO3AZZ}
      VECTOR_STORE: weaviate
      WEAVIATE_ENDPOINT: http://df-weaviate:8080
      CONSOLE_CORS_ALLOW_ORIGINS: \${CONSOLE_CORS_ALLOW_ORIGINS:-*}
      WEB_API_CORS_ALLOW_ORIGINS: \${WEB_API_CORS_ALLOW_ORIGINS:-*}
      COOKIE_DOMAIN: .${BASE_DOMAIN}
      PLUGIN_DAEMON_URL: http://df-plugin-daemon:5002
      PLUGIN_DAEMON_KEY: \${PLUGIN_DAEMON_KEY:-lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi}
    depends_on:
      df-init:
        condition: service_completed_successfully
      df-db:
        condition: service_healthy
      df-redis:
        condition: service_healthy
    volumes:
      - df_storage_data:/app/api/storage
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(5); s.connect((\"localhost\", 5001))'"]
      interval: 10s
      timeout: 5s
      retries: 5

  df-worker:
    image: langgenius/dify-api:latest
    container_name: \${PROJECT_NAME}_df_worker
    restart: unless-stopped
    command: python main.py worker
    environment:
      DB_USERNAME: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: df-db
      REDIS_HOST: df-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      WEAVIATE_HOST: df-weaviate
      WEAVIATE_PORT: 8080
      WEAVIATE_API_KEY: \${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      STORAGE_TYPE: local
      STORAGE_LOCAL_PATH: /app/api/storage
    depends_on:
      df-api:
        condition: service_healthy
    volumes:
      - df_storage_data:/app/api/storage
    networks:
      - ${DOCKER_NETWORK}

  # Dify Worker Beat (Celery Scheduler)
  df-worker-beat:
    image: langgenius/dify-api:latest
    container_name: \${PROJECT_NAME}_df_worker_beat
    restart: unless-stopped
    command: celery -A app.celery worker -B
    environment:
      MODE: beat
      DB_USERNAME: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: df-db
      DB_PORT: 5432
      DB_DATABASE: dify
      REDIS_HOST: df-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      WEAVIATE_HOST: df-weaviate
      WEAVIATE_PORT: 8080
      WEAVIATE_API_KEY: \${DIFY_WEAVIATE_API_KEY:-dify-weaviate-key}
      STORAGE_TYPE: local
      STORAGE_LOCAL_PATH: /app/api/storage
      CODE_EXECUTION_ENDPOINT: http://df-sandbox:8194
      CODE_EXECUTION_API_KEY: \${SANDBOX_API_KEY:-dify-sandbox}
    depends_on:
      df-db:
        condition: service_healthy
      df-redis:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

  # Dify Sandbox (Code Execution Environment)
  df-sandbox:
    image: langgenius/dify-sandbox:0.2.12
    container_name: \${PROJECT_NAME}_df_sandbox
    restart: unless-stopped
    environment:
      API_KEY: \${SANDBOX_API_KEY:-dify-sandbox}
      GIN_MODE: release
      WORKER_TIMEOUT: 15
      ENABLE_NETWORK: true
      HTTP_PROXY: http://df-ssrf-proxy:3128
      HTTPS_PROXY: http://df-ssrf-proxy:3128
      SANDBOX_PORT: 8194
    volumes:
      - df_sandbox_dependencies:/dependencies
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8194/health"]
      interval: 10s
      timeout: 5s
      retries: 3

  # Dify Plugin Daemon (Plugin Manager)
  df-plugin-daemon:
    image: langgenius/dify-plugin-daemon:0.5.2-local
    container_name: \${PROJECT_NAME}_df_plugin_daemon
    restart: unless-stopped
    environment:
      LOG_OUTPUT_FORMAT: text
      DB_DATABASE: dify_plugin
      DB_USERNAME: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: df-db
      DB_PORT: 5432
      REDIS_HOST: df-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      SERVER_PORT: 5002
      SERVER_KEY: \${PLUGIN_DAEMON_KEY:-lYkiYYT6owG+71oLerGzA7GXCgOT++6ovaezWAjpCjf+Sjc3ZtU+qUEi}
      MAX_PLUGIN_PACKAGE_SIZE: 52428800
      HTTP_PROXY: http://df-ssrf-proxy:3128
      HTTPS_PROXY: http://df-ssrf-proxy:3128
      PPROF_ENABLED: false
      DIFY_INNER_API_URL: http://df-api:5001
      DIFY_INNER_API_KEY: \${PLUGIN_DIFY_INNER_API_KEY:-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1}
      PLUGIN_DIFY_INNER_API_URL: http://df-api:5001
      PLUGIN_DIFY_INNER_API_KEY: \${PLUGIN_DIFY_INNER_API_KEY:-QaHbTe77CtuXmsfyhR7+vRjI/+XbV1AaFy691iy+kGDv2Jvy0/eAh8Y1}
      PLUGIN_REMOTE_INSTALLING_HOST: 0.0.0.0
      PLUGIN_REMOTE_INSTALLING_PORT: 5003
      PLUGIN_WORKING_PATH: /app/storage/cwd
      PYTHON_ENV_INIT_TIMEOUT: 120
      PLUGIN_MAX_EXECUTION_TIMEOUT: 600
      PIP_MIRROR_URL: ""
      PLUGIN_STORAGE_TYPE: local
      PLUGIN_STORAGE_LOCAL_ROOT: /app/storage
      PLUGIN_INSTALLED_PATH: plugin
      PLUGIN_PACKAGE_CACHE_PATH: plugin_packages
      PLUGIN_MEDIA_CACHE_PATH: assets
      THIRD_PARTY_SIGNATURE_VERIFICATION_ENABLED: true
      FORCE_VERIFYING_SIGNATURE: false
    volumes:
      - df_plugin_storage:/app/storage
      - df_plugins:/app/plugins
    depends_on:
      df-db:
        condition: service_healthy
      df-redis:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

  # Dify SSRF Proxy (Security Proxy)
  df-ssrf-proxy:
    image: ubuntu/squid:latest
    container_name: \${PROJECT_NAME}_df_ssrf_proxy
    restart: unless-stopped
    environment:
      HTTP_PORT: 3128
      COREDUMP_DIR: /var/spool/squid
    volumes:
      - df_squid_cache:/var/spool/squid
    networks:
      - ${DOCKER_NETWORK}

  df-web:
    image: langgenius/dify-web:latest
    container_name: \${PROJECT_NAME}_df_web
    restart: unless-stopped
    environment:
      CONSOLE_API_URL: https://${DIFY_SUBDOMAIN:-df}.${BASE_DOMAIN}
      APP_API_URL: https://${DIFY_SUBDOMAIN:-df}.${BASE_DOMAIN}
      NEXT_PUBLIC_COOKIE_DOMAIN: .${BASE_DOMAIN}
    depends_on:
      df-api:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

EOF
}

export -f generate_df_stack
