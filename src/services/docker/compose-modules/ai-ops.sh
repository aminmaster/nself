#!/usr/bin/env bash
# ai-ops.sh - AI Operating System (AIO) Full Stack Generator
# Unified stack for the Equilibria Brain.

# Generate AIO Stack (RAGFlow + Langflow + Graphiti + Neo4j + MLFlow + FalkorDB)
generate_aio_stack() {
  local index="$1"
  local service_name="$2" # usually "ai-ops" - used for directory paths
  local port="$3" # usually 80 (internal nginx port)

  # Configuration
  local subdomain="${AIO_SUBDOMAIN:-brain}"
  local redis_password="${AIO_REDIS_PASSWORD:-aioredispass}"
  local api_url="https://${subdomain}.${BASE_DOMAIN}"
  
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
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # Ensure MLFlow Dockerfile exists
  local mlflow_dir="./services/${service_name}/mlflow"
  mkdir -p "$mlflow_dir"
  if [[ ! -f "$mlflow_dir/Dockerfile" ]]; then
      cat > "$mlflow_dir/Dockerfile" <<DOCKERFILE
FROM ghcr.io/mlflow/mlflow:latest
RUN pip install psycopg2-binary
DOCKERFILE
  fi

  # Ensure Graphiti source exists
  local graphiti_dir="./services/${service_name}/graphiti"
  if [[ ! -d "$graphiti_dir" ]]; then
      local nself_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
      local template_src="$nself_root/templates/services/py/graphiti"
      if [[ -d "$template_src" ]]; then
          mkdir -p "$graphiti_dir"
          cp -r "$template_src"/* "$graphiti_dir/"
          find "$graphiti_dir" -name "*.template" -type f | while read t; do
              mv "$t" "${t%.template}"
          done
      fi
  fi

  # 1. AIO Init (Database & Permission Setup)
  cat <<EOF
  aio-init:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_aio_init
    restart: "no"
    environment:
      - DB_PASSWORD=\${POSTGRES_PASSWORD:-aiopassword}
      - DB_HOST=aio-db
      - DB_PORT=5432
    entrypoint: ["/bin/sh", "-c"]
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
    volumes:
      - ./.volumes/${service_name}/es:/mnt/es-data
    command:
      - |
        set -e
        echo "1. Waiting for Database..."
        until nc -z aio-db 5432; do echo "Waiting for aio-db..."; sleep 1; done

        echo "2. Initializing AIO Databases..."
        export PGPASSWORD="\$\${DB_PASSWORD}"
        
        create_db() {
          local dbname=\$\$1
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

        echo "All initialization tasks completed."
EOF

  # 2. AIO Storage (Minio - for RAGFlow)
  cat <<EOF
  aio-minio:
    image: minio/minio:latest
    container_name: \${PROJECT_NAME}_aio_minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=admin
      - MINIO_ROOT_PASSWORD=\${POSTGRES_PASSWORD:-aiopassword}
    volumes:
      - ./.volumes/${service_name}/minio:/data
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
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
      - discovery.type=single-node
      - xpack.security.enabled=false
      - "ES_JAVA_OPTS=-Xms2g -Xmx2g"
    volumes:
      - ./.volumes/${service_name}/es:/usr/share/elasticsearch/data
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -vq '\"status\":\"red\"'"]
      interval: 30s
      timeout: 20s
      retries: 3

  # 4. AIO Ingestion (RAGFlow Server)
  aio-ragflow:
    image: infiniflow/ragflow:latest
    container_name: \${PROJECT_NAME}_aio_ragflow
    restart: unless-stopped
    # Port 80 is handled by internal Nginx
    # (Removed host port 80 mapping to avoid conflict with Nginx)
    environment:
      - DOC_ENGINE=elasticsearch
      - DATABASE_TYPE=postgres
      - DB_NAME=ragflow
      - DB_USER=postgres
      - DB_PASSWORD=\${POSTGRES_PASSWORD:-aiopassword}
      - DB_HOST=aio-db
      - DB_PORT=5432
      - STORAGE_TYPE=minio
      - MINIO_HOST=aio-minio
      - MINIO_PORT=9000
      - MINIO_USER=admin
      - MINIO_PASSWORD=\${POSTGRES_PASSWORD:-aiopassword}
      - ES_HOST=aio-es
      - ES_PORT=9200
      - REDIS_HOST=aio-redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=${redis_password}
      - TIME_ZONE=UTC
      - GUNICORN_TIMEOUT=600
      - SANDBOX_ENABLED=1
      - SANDBOX_HOST=aio-ragflow-sandbox
      - SANDBOX_PORT=9385
    depends_on:
      aio-db:
        condition: service_healthy
      aio-es:
        condition: service_healthy
      aio-minio:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - ragflow

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
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # 5. AIO Metadata (Postgres)
  cat <<EOF
  aio-db:
    image: postgres:15-alpine
    container_name: \${PROJECT_NAME}_aio_db
    restart: unless-stopped
    environment:
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD:-aiopassword}
      - POSTGRES_DB=postgres
      - PGDATA=/var/lib/postgresql/data/pgdata
    volumes:
      - ./.volumes/${service_name}/db:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
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
    command: redis-server --requirepass "${redis_password}"
    volumes:
      - ./.volumes/${service_name}/redis:/data
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # 7. AIO Graphiti (Knowledge Management)
  cat <<EOF
  aio-graphiti:
    build:
      context: ./services/${service_name}/graphiti
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_aio_graphiti
    restart: unless-stopped
    environment:
      - PORT=8000
      - OPENAI_API_KEY=\${OPENAI_API_KEY}
      - NEO4J_URI=bolt://aio-neo4j:7687
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD:-aiopassword}
      - GRAPHITI_DATABASE=neo4j
      - GRAPH_DRIVER_TYPE=falkordb
      - FALKORDB_HOST=aio-falkordb
      - FALKORDB_PORT=6379
      - FALKORDB_PASSWORD=\${FALKORDB_PASSWORD:-\${AIO_REDIS_PASSWORD}}
    volumes:
      - ./.volumes/${service_name}/graphiti/data:/app/data
    depends_on:
      aio-neo4j:
        condition: service_healthy
      aio-falkordb:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # 8. AIO Neo4j (Structural Graph)
  cat <<EOF
  aio-neo4j:
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_aio_neo4j
    restart: unless-stopped
    environment:
      - NEO4J_AUTH=neo4j/\${NEO4J_PASSWORD:-aiopassword}
      - NEO4J_dbms_memory_pagecache_size=512m
      - NEO4J_dbms_memory_heap_max__size=1G
    volumes:
      - ./.volumes/${service_name}/neo4j/data:/data
    networks:
      ${DOCKER_NETWORK:-${PROJECT_NAME}_network}:
        aliases:
          - neo4j
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
EOF

  # 9. AIO FalkorDB (Temporal Graph)
  cat <<EOF
  aio-falkordb:
    image: falkordb/falkordb:latest
    container_name: \${PROJECT_NAME}_aio_falkordb
    restart: unless-stopped
    environment:
      - REDIS_ARGS=--requirepass \${FALKORDB_PASSWORD:-aioredispass}
    volumes:
      - ./.volumes/${service_name}/falkordb/data:/data
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5

  aio-falkordb-browser:
    image: falkordb/falkordb-browser:latest
    container_name: \${PROJECT_NAME}_aio_falkordb_browser
    restart: unless-stopped
    environment:
      - REDIS_HOST=aio-falkordb
      - REDIS_PORT=6379
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # 10. AIO MLFlow (Tracking)
  cat <<EOF
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
      --port 5000"
    environment:
      - MLFLOW_BACKEND_STORE_URI=postgresql://postgres:\${POSTGRES_PASSWORD:-aiopassword}@aio-db:5432/mlflow
      - MLFLOW_HOST=0.0.0.0
      - MLFLOW_PORT=5000
    depends_on:
      aio-db:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF

  # 11. AIO Langflow (Orchestration Brain)
  cat <<EOF
  aio-langflow:
    image: langflowai/langflow:latest
    container_name: \${PROJECT_NAME}_aio_langflow
    restart: unless-stopped
    ports:
      - "7860:7860"
    environment:
      - LANGFLOW_DATABASE_URL=postgresql://postgres:\${POSTGRES_PASSWORD:-aiopassword}@aio-db:5432/langflow
    depends_on:
      aio-db:
        condition: service_healthy
      aio-init:
        condition: service_completed_successfully
    networks:
      - ${DOCKER_NETWORK:-${PROJECT_NAME}_network}
EOF
}

export -f generate_aio_stack
