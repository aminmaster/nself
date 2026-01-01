# Generate RAGFlow specific configurations (Official InfiniFlow Setup)
generate_ragflow_configs() {
  local service_name="$1"
  local ragflow_vol_dir="./.volumes/${service_name}/ragflow"
  local nginx_dir="${ragflow_vol_dir}/nginx"
  
  mkdir -p "$nginx_dir"

  # 1. Official Nginx Server Block (ragflow.conf)
  cat <<'NGINX_CONF' > "${nginx_dir}/ragflow.conf"
server {
    listen 80;
    server_name _;
    root /ragflow/web/dist;

    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 9;
    gzip_types text/plain application/javascript application/x-javascript text/css application/xml text/javascript application/x-httpd-php image/jpeg image/gif image/png;
    gzip_vary on;
    gzip_disable "MSIE [1-6]\.";

    location ~ ^/api/v1/admin {
        proxy_pass http://localhost:9381;
        include proxy.conf;
    }

    location ~ ^/(v1|api) {
        proxy_pass http://localhost:9380;
        include proxy.conf;
    }

    location / {
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    # Cache-Control: max-age~@~AExpires
    location ~ ^/static/(css|js|media)/ {
        expires 10y;
        access_log off;
    }
}
NGINX_CONF

  # 2. Official Proxy Configuration (proxy.conf)
  cat <<'PROXY_CONF' > "${nginx_dir}/proxy.conf"
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
proxy_buffer_size 1024k;
proxy_buffers 16 1024k;
proxy_busy_buffers_size 2048k;
proxy_temp_file_write_size 2048k;
PROXY_CONF

  # 3. Official Main Nginx Config (nginx.conf)
  cat <<'MAIN_NGINX_CONF' > "${nginx_dir}/nginx.conf"
user  root;
worker_processes  auto;

error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;

events {
    worker_connections  1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';

    access_log  /var/log/nginx/access.log  main;

    sendfile        on;
    #tcp_nopush     on;

    keepalive_timeout  65;

    #gzip  on;
    client_max_body_size 1024M;

    include /etc/nginx/conf.d/ragflow.conf;
}
MAIN_NGINX_CONF

  # 4. Official Service Configuration Template (Hydrated during generation)
  cat <<SERVICE_CONF > "${ragflow_vol_dir}/service_conf.yaml.template"
ragflow:
  host: 0.0.0.0
  http_port: 9380
admin:
  host: 0.0.0.0
  http_port: 9381
mysql:
  name: 'ragflow'
  user: 'postgres'
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'aio-db'
  port: 5432
  max_connections: 900
  stale_timeout: 300
  max_allowed_packet: 1073741824
postgres:
  name: 'ragflow'
  user: 'postgres'
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'aio-db'
  port: 5432
  max_connections: 100
  stale_timeout: 30
minio:
  user: '${NSELF_ADMIN_USER:-admin}'
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'aio-minio:9000'
  bucket: ''
  prefix_path: ''
es:
  hosts: 'http://aio-es:9200'
  username: ''
  password: ''
redis:
  db: 1
  username: ''
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'aio-redis:6379'
SERVICE_CONF
}

# Generate AIO Stack (RAGFlow + Langflow + Graphiti + Neo4j + MLFlow + FalkorDB)
generate_aio_stack() {
  local index="$1"
  local service_name="$2" # usually "ai-ops" - used for directory paths
  local port="$3" # usually 80 (internal nginx port)

  # Configuration
  local subdomain="${AIO_SUBDOMAIN:-brain}"
  local api_url="https://${subdomain}.${BASE_DOMAIN}"

  # Generate RAGFlow specific configurations
  generate_ragflow_configs "$service_name"
  
  # Clone Graphiti source code if missing
  local graphiti_dir="./services/${service_name}/graphiti"
  if [[ ! -d "$graphiti_dir" ]]; then
    echo "Cloning Graphiti source code..." >&2
    mkdir -p "$(dirname "$graphiti_dir")"
    git clone https://github.com/getzep/graphiti.git "$graphiti_dir" >&2
  fi

  # ============================================
  # AI Operating System (AIO) Stack
  # Core: RAGFlow (Ingestion) & Langflow (Orchestration)
  # Graph: Neo4j (Structural) & FalkorDB (Temporal User State)
  # Infrastructure: Postgres, Redis, Minio, Elasticsearch
  # ============================================

  # Dummy service to satisfy nself dependency
  cat <<EOF
  ${service_name}:
    image: alpine:latest
    command: "true"
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}

  # 1. AIO Init (Database & Permission Setup)
  aio-init:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_aio_init
    restart: "no"
    environment:
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: aio-db
      DB_PORT: 5432
    entrypoint: ["/bin/sh", "-c"]
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    volumes:
      - ./.volumes/${service_name}/es:/mnt/es-data
      - ./.volumes/${service_name}/langflow:/mnt/langflow-data
    command:
      - |
        set -e
        echo "1. Waiting for Database..."
        until nc -z aio-db 5432; do echo "Waiting for aio-db..."; sleep 1; done

        echo "2. Initializing AIO Databases..."
        export PGPASSWORD="\$\${DB_PASSWORD}"
        
        create_db() {
          local dbname=\$\$1
          local max_retries=30
          local count=0
          
          echo "Checking/Creating database \$\$dbname..."
          until psql -h aio-db -U postgres -lqt >/dev/null 2>&1 || [ \$\$count -eq \$\$max_retries ]; do
            echo "Waiting for Postgres to be ready for connections (Attempt \$\$count/\$\$max_retries)..."
            sleep 2
            count=\$((\$\$count + 1))
          done

          if ! psql -h aio-db -U postgres -lqt | cut -d \| -f 1 | grep -qw "\$\$dbname"; then
            echo "Creating database \$\$dbname..."
            psql -h aio-db -U postgres -c "CREATE DATABASE \$\$dbname;"
          else
            echo "Database \$\$dbname already exists."
          fi
        }

        create_db "mlflow"
        create_db "langflow"
        create_db "ragflow"

        echo "3. Fixing permissions..."
        chown -R 1000:1000 /mnt/es-data || true
        chown -R 1000:1000 /mnt/langflow-data || true

        echo "All initialization tasks completed."

  # 2. AIO Storage (Minio - for RAGFlow)
  aio-minio:
    image: minio/minio:latest
    container_name: \${PROJECT_NAME}_aio_minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${NSELF_ADMIN_USER:-admin}
      MINIO_ROOT_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
    volumes:
      - ./.volumes/${service_name}/minio:/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

  # 3. AIO Search (Elasticsearch - for RAGFlow)
  aio-es:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
    container_name: \${PROJECT_NAME}_aio_es
    restart: unless-stopped
    environment:
      discovery.type: single-node
      xpack.security.enabled: "false"
      ES_JAVA_OPTS: "-Xms1g -Xmx1g"
      bootstrap.memory_lock: "true"
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - ./.volumes/${service_name}/es:/usr/share/elasticsearch/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -vq '\"status\":\"red\"'"]
      interval: 30s
      timeout: 20s
      retries: 10
      start_period: 60s

  # 4. AIO Ingestion (RAGFlow Server - Official v0.23.0 Setup)
  aio-ragflow:
    image: infiniflow/ragflow:v0.23.0
    container_name: \${PROJECT_NAME}_aio_ragflow
    restart: unless-stopped
    ports:
      - "9380:9380"  # Python API
      - "9381:9381"  # Admin API
    command:
      - --enable-adminserver
    environment:
      DATABASE_TYPE: postgres
      DB_TYPE: postgres
      DB_NAME: ragflow
      DB_USER: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: aio-db
      DB_PORT: 5432
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_HOST: aio-db
      POSTGRES_PORT: 5432
      POSTGRES_DBNAME: ragflow
      STORAGE_TYPE: minio
      STORAGE_IMPL: MINIO
      MINIO_HOST: aio-minio
      MINIO_PORT: 9000
      MINIO_USER: ${NSELF_ADMIN_USER:-admin}
      MINIO_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DOC_ENGINE: elasticsearch
      ES_HOST: aio-es
      ES_PORT: 9200
      REDIS_HOST: aio-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${REDIS_PASSWORD:-aiopassword}}
      SANDBOX_ENABLED: 1
      SANDBOX_HOST: aio-ragflow-sandbox
      SANDBOX_PORT: 9385
      TIME_ZONE: UTC
      GUNICORN_TIMEOUT: 600
      REGISTER_ENABLED: 0
    depends_on:
      aio-db:
        condition: service_healthy
      aio-es:
        condition: service_healthy
      aio-minio:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
      aio-redis:
        condition: service_healthy
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    volumes:
      - ./.volumes/${service_name}/ragflow/nginx/ragflow.conf:/etc/nginx/conf.d/ragflow.conf:ro
      - ./.volumes/${service_name}/ragflow/nginx/proxy.conf:/etc/nginx/proxy.conf:ro
      - ./.volumes/${service_name}/ragflow/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./.volumes/${service_name}/ragflow/service_conf.yaml.template:/ragflow/conf/service_conf.yaml.template:ro
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost/v1/system/config"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  aio-ragflow-sandbox:
    image: infiniflow/sandbox-executor-manager:latest
    container_name: \${PROJECT_NAME}_aio_ragflow_sandbox
    restart: unless-stopped
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    ports:
      - "9385:9385"
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}

  # 5. AIO Metadata (Postgres)
  aio-db:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_aio_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: postgres
      PGDATA: /var/lib/postgresql/data/pgdata
    volumes:
      - ./.volumes/${service_name}/db:/var/lib/postgresql/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD", "pg_isready"]
      interval: 10s
      timeout: 5s
      retries: 5

  # 6. AIO Cache (Redis)
  aio-redis:
    image: redis:7-alpine
    container_name: \${PROJECT_NAME}_aio_redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}"]
    volumes:
      - ./.volumes/${service_name}/redis:/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  # 7. AIO Graphiti (Knowledge Management)
  aio-graphiti:
    build:
      context: ./services/${service_name}/graphiti
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_aio_graphiti
    restart: unless-stopped
    environment:
      PORT: 8000
      OPENAI_API_KEY: \${OPENAI_API_KEY}
      NEO4J_URI: bolt://aio-neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      GRAPHITI_DATABASE: neo4j
      GRAPH_DRIVER_TYPE: falkordb
      FALKORDB_HOST: aio-falkordb
      FALKORDB_PORT: 6379
      FALKORDB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${FALKORDB_PASSWORD:-aiopassword}}
    volumes:
      - ./.volumes/${service_name}/graphiti/data:/app/data
    depends_on:
      aio-neo4j:
        condition: service_healthy
      aio-falkordb:
        condition: service_healthy
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}

  # 8. AIO Neo4j (Structural Graph)
  aio-neo4j:
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_aio_neo4j
    restart: unless-stopped
    environment:
      NEO4J_AUTH: neo4j/${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      NEO4J_server_memory_pagecache_size: 512m
      NEO4J_server_memory_heap_max__size: 1G
      NEO4J_PLUGINS: '["apoc"]'
    volumes:
      - ./.volumes/${service_name}/neo4j/data:/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474/browser/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10

  # 9. AIO FalkorDB (Temporal Graph)
  aio-falkordb:
    image: falkordb/falkordb:latest
    container_name: \${PROJECT_NAME}_aio_falkordb
    restart: unless-stopped
    entrypoint: ["/bin/sh", "-c"]
    command: 
      - |
        redis-server --loadmodule /var/lib/falkordb/bin/falkordb.so --requirepass "\${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}" --protected-mode yes
    volumes:
      - ./.volumes/${service_name}/falkordb/data:/data
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5

  aio-falkordb-browser:
    image: falkordb/falkordb-browser:latest
    container_name: \${PROJECT_NAME}_aio_falkordb_browser
    restart: unless-stopped
    environment:
      REDIS_HOST: aio-falkordb
      REDIS_PORT: 6379
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}

  # 10. AIO MLFlow (Tracking)
  local mlflow_dir="./services/${service_name}/mlflow"
  if [[ ! -d "$mlflow_dir" ]]; then
    mkdir -p "$mlflow_dir"
    printf "FROM ghcr.io/mlflow/mlflow:latest\nRUN pip install --no-cache-dir psycopg2-binary\n" > "$mlflow_dir/Dockerfile"
  fi

  aio-mlflow:
    build:
      context: ./services/${service_name}/mlflow
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_aio_mlflow
    restart: unless-stopped
    command: >
      /bin/sh -c "mlflow server
      --backend-store-uri \$\${MLFLOW_BACKEND_STORE_URI}
      --default-artifact-root /mlflow/artifacts
      --host 0.0.0.0
      --port 5000
      --no-serve-artifacts
      --allowed-hosts '*'"
    environment:
      MLFLOW_BACKEND_STORE_URI: postgresql://postgres:${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}@aio-db:5432/mlflow
      MLFLOW_HOST: 0.0.0.0
      MLFLOW_PORT: 5000
    depends_on:
      aio-db:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    volumes:
      - ./.volumes/${service_name}/mlflow/artifacts:/mlflow/artifacts
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}

  # 11. AIO Langflow (Orchestration Brain)
  aio-langflow:
    image: langflowai/langflow:latest
    container_name: \${PROJECT_NAME}_aio_langflow
    restart: unless-stopped
    ports:
      - "7860:7860"
    environment:
      LANGFLOW_DATABASE_URL: postgresql://postgres:${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}@aio-db:5432/langflow
      LANGFLOW_AUTO_LOGIN: "False"
      LANGFLOW_SUPERUSER: ${NSELF_ADMIN_USER:-admin}
      LANGFLOW_SUPERUSER_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      LANGFLOW_SECRET_KEY: \${AUTH_JWT_SECRET:-equilibria_secret_key}
      LANGFLOW_CONFIG_DIR: /app/langflow
    volumes:
      - ./.volumes/${service_name}/langflow:/app/langflow
    depends_on:
      aio-db:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
EOF
}

export -f generate_aio_stack
