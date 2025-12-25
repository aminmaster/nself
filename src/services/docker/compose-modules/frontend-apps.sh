#!/usr/bin/env bash
# frontend-apps.sh - Generate frontend app Docker services

# Setup web app directory - clone repo or scaffold, then copy Docker files
setup_web_app() {
  local index=${1:-1}
  local nself_templates_dir="${NSELF_ROOT:-$HOME/projects/nself}/src/templates/services/js/sveltekit"
  
  # Load indexed variables safely
  local app_name repo_url framework
  eval "app_name=\"\${FRONTEND_APP_${index}_NAME:-web}\""
  eval "repo_url=\"\${FRONTEND_APP_${index}_REPO_URL:-\${WEB_REPO_URL:-}}\""
  eval "framework=\"\${FRONTEND_APP_${index}_FRAMEWORK:-\${WEB_FRAMEWORK:-sveltekit}}\""
  
  local web_service_dir="./services/${app_name}"
  
  echo "📦 Setting up frontend app: ${app_name} (Dir: ${web_service_dir})" >&2

  # Check if directory already exists with content (excluding Docker files)
  if [[ -d "$web_service_dir" ]] && [[ -n "$(ls -A "$web_service_dir" 2>/dev/null | grep -v '^\.dockerignore$' | grep -v '^Dockerfile$')" ]]; then
    # Directory exists with code
    echo "✓ Web app directory exists" >&2
    
    # If repo URL is set, perform non-interactive pull to ensure latest code
    if [[ -n "$repo_url" ]]; then
      echo "Pulling latest from $repo_url..." >&2
      (cd "$web_service_dir" && git reset --hard HEAD && git pull origin main) >&2 2>&1 || echo "⚠ Git pull failed (continuing anyway)" >&2
    fi
  else
    # Directory doesn't exist or is empty - create it
    mkdir -p "$web_service_dir"
    
    if [[ -n "$repo_url" ]]; then
      # Clone from repository (non-interactive)
      echo "Cloning from $repo_url..." >&2
      if git clone "$repo_url" "$web_service_dir" >&2 2>&1; then
        echo "✓ Cloned repository successfully" >&2
      else
        echo "✗ Failed to clone repository - skipping" >&2
      fi
    elif [[ -n "$framework" ]] && [[ "$framework" != "sveltekit" ]] ; then
      # Only scaffold non-sveltekit frameworks automatically
      echo "Scaffolding new $framework app..." >&2
      
      case "$framework" in
        nextjs)
          npx -y create-next-app@latest "$web_service_dir" --typescript --tailwind --app --no-src-dir --import-alias "@/*" >&2 2>&1 || echo "✗ Scaffold failed" >&2
          ;;
        react-vite)
          npm create vite@latest "$web_service_dir" -- --template react-ts >&2 2>&1 || echo "✗ Scaffold failed" >&2
          ;;
      esac
    fi
  fi
  
  # Always ENFORCE Docker configuration files from nself (Our source of truth)
  # For now SvelteKit template works for most modern JS frameworks
  if [[ -f "$nself_templates_dir/Dockerfile" ]]; then
    cp -f "$nself_templates_dir/Dockerfile" "$web_service_dir/Dockerfile"
    echo "✓ Standardized Dockerfile from nself templates" >&2
  fi
  
  if [[ -f "$nself_templates_dir/.dockerignore" ]]; then
    cp -f "$nself_templates_dir/.dockerignore" "$web_service_dir/.dockerignore"
    echo "✓ Standardized .dockerignore from nself templates" >&2
  fi
}

# Generate a single frontend app service
generate_frontend_app() {
  local index=${1:-1}
  local project_name=${PROJECT_NAME:-equilibria}
  
  local app_name port
  eval "app_name=\"\${FRONTEND_APP_${index}_NAME:-web}\""
  eval "port=\"\${FRONTEND_APP_${index}_PORT:-\${PORT:-3000}}\""
  
  # Detection for WEB_TARGET default and volumes
  local target="production"
  local volumes_block=""
  if [[ "${WEB_DEPLOY_MODE:-}" == "dev" ]]; then
    target="development"
    volumes_block="    volumes:
      - ./services/${app_name}:/app
      - /app/node_modules"
  fi

  # Service name includes project prefix for consistency
  local service_name="${project_name}_${app_name}"

  cat <<EOF
  ${service_name}:
    build:
      context: ./services/${app_name}
      dockerfile: Dockerfile
      target: \${WEB_TARGET:-${target}}
      args:
        - PORT=\${PORT:-${port}}
    container_name: ${service_name}
    restart: unless-stopped
    environment:
      - NODE_ENV=\${NODE_ENV:-production}
      - PORT=\${PORT:-${port}}
      - HOST=0.0.0.0
      - ORIGIN=https://${BASE_DOMAIN:-equilibria.org}
      - WEB_PORT=\${PORT:-${port}}
      # Backend service connections (internal Docker network)
      # Neo4J for document knowledge graphs and system ontology
      - VITE_NEO4J_URI=\${NEO4J_URI:-bolt+s://neo4j.${BASE_DOMAIN:-equilibria.org}}
      - VITE_NEO4J_USER=\${NEO4J_USER:-neo4j}
      - VITE_NEO4J_PASSWORD=\${NEO4J_PASSWORD:-}
      # FalkorDB for user conversations and context
      - VITE_FALKORDB_URI=\${FALKORDB_URI:-bolt+s://falkordb.${BASE_DOMAIN:-equilibria.org}}
      - VITE_FALKORDB_USER=\${FALKORDB_USER:-falkor_admin}
      - VITE_FALKORDB_PASSWORD=\${FALKORDB_PASSWORD:-}
      - VITE_NHOST_AUTH_URL=\${NHOST_AUTH_URL:-https://auth.${BASE_DOMAIN:-equilibria.org}}
      - VITE_HASURA_URL=\${HASURA_URL:-https://api.${BASE_DOMAIN:-equilibria.org}/v1/graphql}
      - VITE_DIFY_URL=\${DIFY_URL:-https://dify.${BASE_DOMAIN:-equilibria.org}/v1}
      - VITE_DIFY_API_KEY=\${DIFY_API_KEY:-\${DIFY_INNER_API_KEY:-}}
      - VITE_GRAPHITI_URL=\${GRAPHITI_URL:-https://graphiti.${BASE_DOMAIN:-equilibria.org}}
${volumes_block}
    networks:
      - \${DOCKER_NETWORK:-${project_name}_network}
EOF
}

# Main function to generate all frontend app services
generate_frontend_apps() {
  local count=${FRONTEND_APP_COUNT:-0}
  
  if [[ "$count" -le 0 ]]; then
    # Compatibility with single-app config
    if [[ "${FRONTEND_ENABLED:-false}" == "true" ]]; then
      setup_web_app 1
      generate_frontend_app 1
    fi
    return
  fi

  local i
  for ((i=1; i<=count; i++)); do
    setup_web_app "$i"
    generate_frontend_app "$i"
  done
}

# Export functions
export -f setup_web_app
export -f generate_frontend_app
export -f generate_frontend_apps