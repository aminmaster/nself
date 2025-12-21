#!/usr/bin/env bash
# frontend-apps.sh - Generate frontend app Docker services

# Generate a single frontend app service
generate_frontend_app() {
  local service_name=${1:-web}
  local project_name=${PROJECT_NAME:-equilibria}
  
  cat <<EOF
  ${project_name}_web:
    build:
      context: ./services/web
      dockerfile: Dockerfile
      target: production
    container_name: ${project_name}_web
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - PORT=3000
      - HOST=0.0.0.0
      - ORIGIN=https://equilibria.org
      # Backend service connections (internal Docker network)
      - NEO4J_URI=bolt://${project_name}_aio_falkordb:6379
      - VITE_NEO4J_URI=bolt://${project_name}_aio_falkordb:6379
      - NEO4J_USER=\${NEO4J_USER:-}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD:-}
      - VITE_NEO4J_USER=\${NEO4J_USER:-}
      - VITE_NEO4J_PASSWORD=\${NEO4J_PASSWORD:-}
      - VITE_NHOST_AUTH_URL=\${NHOST_AUTH_URL:-https://auth.equilibria.org}
      - VITE_HASURA_URL=\${HASURA_URL:-https://api.equilibria.org/v1/graphql}
      - VITE_DIFY_URL=\${DIFY_URL:-https://dify.equilibria.org}
      - VITE_DIFY_API_KEY=\${DIFY_API_KEY:-}
      - VITE_GRAPHITI_URL=\${GRAPHITI_URL:-http://${project_name}_aio_graphiti:8000}
    networks:
      - \${DOCKER_NETWORK:-${project_name}_network}
    depends_on:
      ${project_name}_aio_falkordb:
        condition: service_healthy
      ${project_name}_aio_hasura:
        condition: service_healthy

EOF
}

# Main function to generate all frontend app services
generate_frontend_apps() {
  generate_frontend_app "web"
}

# Export functions
export -f generate_frontend_app
export -f generate_frontend_apps