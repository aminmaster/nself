#!/usr/bin/env bash
# mlflow-improved.sh - Hybrid MLflow service generation (Native Logic + Custom Image)

# Generate improved MLflow service with proper database handling
generate_mlflow_service_improved() {
  local enabled="${MLFLOW_ENABLED:-false}"
  [[ "$enabled" != "true" ]] && return 0

  # CRITICAL: Hybrid Approach
  # 1. Generate Custom Dockerfile (to ensure psycopg2-binary driver exists)
  # 2. Use Native Startup Logic (to ensure robust DB waiting/migration)

  # Create build directory
  mkdir -p services/mlflow

  # Generate Dockerfile
  cat > services/mlflow/Dockerfile <<'DOCKERFILE'
FROM ghcr.io/mlflow/mlflow:latest

# Install PostgreSQL adapter (required for production DB)
RUN pip install --no-cache-dir psycopg2-binary

# Ensure artifacts directory exists
RUN mkdir -p /mlflow/artifacts

# Set working directory
WORKDIR /mlflow
DOCKERFILE

  # Generate Service Definition
  cat <<EOF

  # MLflow - Machine Learning Lifecycle Platform
  mlflow:
    build:
      context: ./services/mlflow
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_mlflow
    restart: unless-stopped
    networks:
      - \${DOCKER_NETWORK}
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      MLFLOW_BACKEND_STORE_URI: postgresql://\${POSTGRES_USER:-postgres}:\${POSTGRES_PASSWORD}@postgres:5432/mlflow
      MLFLOW_DEFAULT_ARTIFACT_ROOT: /mlflow/artifacts
      MLFLOW_HOST: 0.0.0.0
      MLFLOW_PORT: \${MLFLOW_PORT:-5005}
      POSTGRES_USER: \${POSTGRES_USER:-postgres}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: mlflow
    entrypoint: ["/bin/bash", "-c"]
    command:
      - |
        set -e
        # Hybrid Logic: Use Python (available via custom image) for robust waiting and init

        echo "Waiting for PostgreSQL to be ready..."
        python -c "
import time, psycopg2, os
while True:
    try:
        psycopg2.connect(
            host='postgres',
            port=5432,
            user=os.environ['POSTGRES_USER'],
            password=os.environ['POSTGRES_PASSWORD'],
            dbname='postgres'
        )
        print('PostgreSQL is ready.')
        break
    except Exception as e:
        print(f'Waiting for database... ({e})')
        time.sleep(2)
"

        echo "Ensuring MLflow database exists..."
        python -c "
import psycopg2, os
from psycopg2.extensions import ISOLATION_LEVEL_AUTOCOMMIT
try:
    conn = psycopg2.connect(
        host='postgres',
        port=5432,
        user=os.environ['POSTGRES_USER'],
        password=os.environ['POSTGRES_PASSWORD'],
        dbname='postgres'
    )
    conn.set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT)
    cur = conn.cursor()
    cur.execute(\"SELECT 1 FROM pg_database WHERE datname = 'mlflow'\")
    if not cur.fetchone():
        print('Creating mlflow database...')
        cur.execute('CREATE DATABASE mlflow')
    else:
        print('Database mlflow already exists.')
    cur.close()
    conn.close()
except Exception as e:
    print(f'Database check failed: {e}')
    exit(1)
"

        echo "Running MLflow database migrations..."
        mlflow db upgrade \$\${MLFLOW_BACKEND_STORE_URI}

        echo "Starting MLflow server..."
        exec mlflow server \
          --backend-store-uri \$\${MLFLOW_BACKEND_STORE_URI} \
          --default-artifact-root \$\${MLFLOW_DEFAULT_ARTIFACT_ROOT} \
          --host \$\${MLFLOW_HOST} \
          --port \$\${MLFLOW_PORT} \
          --serve-artifacts
    volumes:
      - mlflow_data:/mlflow/artifacts
    ports:
      - "\${MLFLOW_PORT:-5005}:\${MLFLOW_PORT:-5005}"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:\${MLFLOW_PORT:-5005}/health')"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s
EOF
}

# Export function
export -f generate_mlflow_service_improved