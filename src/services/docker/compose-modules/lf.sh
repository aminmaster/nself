# lf.sh - LangFlow Stack Module

generate_lf_stack() {
  local service_name="lf"
  
  cat <<EOF

  # LangFlow Stack
  lf-db:
    image: postgres:16-alpine
    container_name: \${PROJECT_NAME}_lf_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: langflow
    volumes:
      - lf_db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  lf-app:
    image: langflowai/langflow:latest
    container_name: \${PROJECT_NAME}_lf_app
    restart: unless-stopped
    ports:
      - "7860:7860"
    environment:
      LANGFLOW_DATABASE_URL: postgresql://postgres:${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}@lf-db:5432/langflow
      LANGFLOW_AUTO_LOGIN: "false"
      LANGFLOW_SUPERUSER: ${NSELF_ADMIN_USER:-admin}
      LANGFLOW_SUPERUSER_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      LANGFLOW_SECRET_KEY: \${AUTH_JWT_SECRET:-equilibria_secret_key}
    depends_on:
      lf-db:
        condition: service_healthy
    volumes:
      - lf_app_data:/app/langflow
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "python3 -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_STREAM); s.settimeout(5); s.connect((\"localhost\", 7860))'"]
      interval: 15s
      timeout: 10s
      retries: 5

EOF
}

export -f generate_lf_stack
