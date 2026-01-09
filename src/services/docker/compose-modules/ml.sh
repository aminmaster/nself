# ml.sh - MLflow Stack Module

generate_ml_stack() {
  local service_name="ml"
  
  cat <<EOF

  # MLflow Stack
  ml-db:
    image: postgres:16-alpine
    container_name: \${PROJECT_NAME}_ml_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: mlflow
    volumes:
      - ml_db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  ml-minio:
    image: minio/minio:latest
    container_name: \${PROJECT_NAME}_ml_minio
    restart: unless-stopped
    command: server /data
    environment:
      MINIO_ROOT_USER: ${NSELF_ADMIN_USER:-admin}
      MINIO_ROOT_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
    volumes:
      - ml_minio_data:/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 5

  ml-app:
    image: ghcr.io/mlflow/mlflow:latest
    container_name: \${PROJECT_NAME}_ml_app
    restart: unless-stopped
    ports:
      - "${MLFLOW_PORT:-5000}:5000"
    environment:
      MLFLOW_BACKEND_STORE_URI: postgresql://postgres:${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}@ml-db:5432/mlflow
      MLFLOW_DEFAULT_ARTIFACT_ROOT: s3://mlflow/
      MLFLOW_S3_ENDPOINT_URL: http://ml-minio:9000
      AWS_ACCESS_KEY_ID: ${NSELF_ADMIN_USER:-admin}
      AWS_SECRET_ACCESS_KEY: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
    command: >
      mlflow server
      --backend-store-uri \$\${MLFLOW_BACKEND_STORE_URI}
      --default-artifact-root \$\${MLFLOW_DEFAULT_ARTIFACT_ROOT}
      --host 0.0.0.0
      --port 5000
    depends_on:
      ml-db:
        condition: service_healthy
      ml-minio:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

EOF
}

export -f generate_ml_stack
