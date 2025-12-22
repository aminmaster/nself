#!/usr/bin/env bash
# frontend-apps.sh - Generate frontend app Docker services

# Setup web app directory - clone repo or scaffold, then copy Docker files
setup_web_app() {
  local nself_templates_dir="${NSELF_ROOT:-$HOME/projects/nself}/src/templates/services/js/sveltekit"
  local web_service_dir="./services/web"
  local repo_url="${WEB_REPO_URL:-}"
  local framework="${WEB_FRAMEWORK:-sveltekit}"
  
  # Check if directory already exists with content (excluding Docker files)
  if [[ -d "$web_service_dir" ]] && [[ -n "$(ls -A "$web_service_dir" 2>/dev/null | grep -v '^\.dockerignore$' | grep -v '^Dockerfile$')" ]]; then
    # Directory exists with code - skip clone/scaffold during build
    echo "✓ Web app directory exists, skipping clone/scaffold" >&2
    
    # If repo URL is set and we're in interactive mode, offer to pull
    if [[ -n "$repo_url" ]] && [[ -t 0 ]]; then
      echo "Repository: $repo_url" >&2
      echo "" >&2
      read -t 5 -p "Pull latest from remote? [y/N]: " -n 1 -r response >&2 2>/dev/null || response="n"
      echo "" >&2
      
      if [[ "$response" =~ ^[Yy]$ ]]; then
        cd "$web_service_dir"
        git pull origin main >&2 2>&1 || echo "⚠ Git pull failed" >&2
        cd - > /dev/null
        echo "✓ Pulled latest code" >&2
      fi
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
        # Don't exit, just skip - Dockerfile will still be copied
      fi
    elif [[ -n "$framework" ]] && [[ "$framework" != "sveltekit" ]] ; then
      # Only scaffold non-sveltekit frameworks automatically
      # For sveltekit, we assume the repo exists
      echo "Scaffolding new $framework app..." >&2
      
      case "$framework" in
        nextjs)
          npx -y create-next-app@latest "$web_service_dir" --typescript --tailwind --app --no-src-dir --import-alias "@/*" >&2 2>&1 || echo "✗ Scaffold failed" >&2
          ;;
        nuxtjs)
          npx -y nuxi@latest init "$web_service_dir" >&2 2>&1 || echo "✗ Scaffold failed" >&2
          ;;
        react-vite)
          npm create vite@latest "$web_service_dir" -- --template react-ts >&2 2>&1 || echo "✗ Scaffold failed" >&2
          ;;
      esac
      
      if [[ -d "$web_service_dir" ]] && [[ -n "$(ls -A "$web_service_dir" 2>/dev/null)" ]]; then
        echo "✓ Scaffolded new $framework app" >&2
      fi
    else
      # SvelteKit or no framework - just note it
      echo "⚠ Web app directory is empty - you'll need to clone your repo manually" >&2
    fi
  fi
  
  # Always copy Docker configuration files (whether app exists or not)
  if [[ -f "$nself_templates_dir/Dockerfile" ]]; then
    cp "$nself_templates_dir/Dockerfile" "$web_service_dir/Dockerfile"
    echo "✓ Copied Dockerfile to $web_service_dir" >&2
  fi
  
  if [[ -f "$nself_templates_dir/.dockerignore" ]]; then
    cp "$nself_templates_dir/.dockerignore" "$web_service_dir/.dockerignore"
    echo "✓ Copied .dockerignore to $web_service_dir" >&2
  fi
}

# Generate a single frontend app service
generate_frontend_app() {
  local service_name=${1:-web}
  local project_name=${PROJECT_NAME:-equilibria}
  local target="production"
  local port="3000"
  local node_env="production"
  local volumes_block=""

  if [[ "${WEB_DEPLOY_MODE:-}" == "dev" ]]; then
    target="development"
    port="5173"
    node_env="development"
    volumes_block="    volumes:
      - ./services/web:/app
      - /app/node_modules"
  fi

  cat <<EOF
  ${project_name}_web:
    build:
      context: ./services/web
      dockerfile: Dockerfile
      target: $target
    container_name: ${project_name}_web
    restart: unless-stopped
    environment:
      - NODE_ENV=$node_env
      - PORT=$port
      - HOST=0.0.0.0
      - ORIGIN=https://equilibria.org
      # Backend service connections (internal Docker network)
      # Neo4J for document knowledge graphs and system ontology
      - NEO4J_URI=${NEO4J_URI:-bolt://${project_name}_aio_neo4j:7687}
      - NEO4J_USER=neo4j
      - NEO4J_PASSWORD=${NEO4J_PASSWORD:-}
      # FalkorDB for user conversations and context
      - FALKORDB_URI=${FALKORDB_URI:-bolt://${project_name}_aio_falkordb:6379}
      - FALKORDB_USER=${FALKORDB_USER:-falkor_admin}
      - FALKORDB_PASSWORD=${FALKORDB_PASSWORD:-}
      - VITE_NHOST_AUTH_URL=\${NHOST_AUTH_URL:-https://auth.equilibria.org}
      - VITE_HASURA_URL=\${HASURA_URL:-https://api.equilibria.org/v1/graphql}
      - VITE_DIFY_URL=\${DIFY_URL:-https://dify.equilibria.org}
      - VITE_DIFY_API_KEY=\${DIFY_API_KEY:-}
      - VITE_GRAPHITI_URL=\${GRAPHITI_URL:-http://${project_name}_aio_graphiti:8000}
$volumes_block
    networks:
      - \${DOCKER_NETWORK:-${project_name}_network}
EOF
}

# Main function to generate all frontend app services
generate_frontend_apps() {
  # Setup web app (clone/scaffold) and copy Docker files
  setup_web_app
  
  # Generate Docker compose config
  generate_frontend_app "web"
}

# Export functions
export -f setup_web_app
export -f generate_frontend_app
export -f generate_frontend_apps