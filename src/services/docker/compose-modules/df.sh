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
      test: ["CMD", "curl", "-f", "http://localhost:8080/v1/.well-known/ready"]
      interval: 10s
      timeout: 10s
      retries: 10
      start_period: 30s

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
    depends_on:
      df-db:
        condition: service_healthy
      df-redis:
        condition: service_healthy
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
    depends_on:
      df-api:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

  df-web:
    image: langgenius/dify-web:latest
    container_name: \${PROJECT_NAME}_df_web
    restart: unless-stopped
    environment:
      CONSOLE_API_URL: http://df-api:5001
      APP_API_URL: http://df-api:5001
    depends_on:
      df-api:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:3000 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5

EOF
}

export -f generate_df_stack
