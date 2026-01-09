# fw.sh - Flowise Stack Module

generate_fw_stack() {
  local service_name="fw"
  
  cat <<EOF

  # Flowise Stack
  fw-db:
    image: postgres:16-alpine
    container_name: \${PROJECT_NAME}_fw_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: flowise
    volumes:
      - fw_db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  fw-app:
    image: flowiseai/flowise:latest
    container_name: \${PROJECT_NAME}_fw_app
    restart: unless-stopped
    ports:
      - "${FLOWISE_PORT:-3002}:3000"
    environment:
      DATABASE_TYPE: postgres
      DATABASE_HOST: fw-db
      DATABASE_PORT: 5432
      DATABASE_USER: postgres
      DATABASE_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DATABASE_NAME: flowise
      FLOWISE_USERNAME: \${NSELF_ADMIN_USER:-admin}
      FLOWISE_PASSWORD: \${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
    depends_on:
      fw-db:
        condition: service_healthy
    volumes:
      - fw_app_data:/root/.flowise
    networks:
      - ${DOCKER_NETWORK}

EOF
}

export -f generate_fw_stack
