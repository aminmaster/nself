#!/usr/bin/env bash
# frontend-apps.sh - Generate frontend app Docker services

# Setup web app directory - clone repo or scaffold, then copy Docker files
setup_web_app() {
  local nself_templates_dir="${NSELF_ROOT:-$HOME/projects/nself}/src/templates/services/js/sveltekit"
  local web_service_dir="./services/web"
  local repo_url="${WEB_REPO_URL:-}"
  local framework="${WEB_FRAMEWORK:-sveltekit}"
  
  # Check if directory already exists with content
  if [[ -d "$web_service_dir"  ]] && [[ -n "$(ls -A "$web_service_dir" 2>/dev/null | grep -v '^\.dockerignore$' | grep -v '^Dockerfile$')" ]]; then
    echo "⚠ Web app directory already exists with content" >&2
    
    if [[ -n "$repo_url" ]]; then
      echo "Repository: $repo_url" >&2
      echo "" >&2
      read -p "Pull latest from remote? [y/N]: " -n 1 -r >&2
      echo "" >&2
      
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        cd "$web_service_dir"
        git pull origin main >&2
        cd - > /dev/null
        echo "✓ Pulled latest code" >&2
      else
        echo "✓ Skipping update, using existing code" >&2
      fi
    else
      echo "✓ Skipping - using existing code" >&2
    fi
  else
    # Directory doesn't exist or is empty - need to create it
    mkdir -p "$web_service_dir"
    
    if [[ -n "$repo_url" ]]; then
      # Clone from repository
      echo "Cloning from $repo_url..." >&2
      if git clone "$repo_url" "$web_service_dir" >&2; then
        echo "✓ Cloned repository successfully" >&2
      else
        echo "✗ Failed to clone repository" >&2
        exit 1
      fi
    else
      # Scaffold new app based on framework
      echo "Scaffolding new $framework app..." >&2
      
      case "$framework" in
        sveltekit)
          # Use npm create with non-interactive flags
          npx -y create-svelte@latest "$web_service_dir" -- --template skeleton --types typescript --no-prettier --no-eslint --no-playwright >&2
          ;;
        nextjs)
          npx -y create-next-app@latest "$web_service_dir" --typescript --tailwind --app --no-src-dir --import-alias "@/*" >&2
          ;;
        nuxtjs)
          npx -y nuxi@latest init "$web_service_dir" >&2
          ;;
        react-vite)
          npm create vite@latest "$web_service_dir" -- --template react-ts >&2
          ;;
        *)
          echo "✗ Unknown framework: $framework" >&2
          exit 1
          ;;
      esac
      
      echo "✓ Scaffolded new $framework app" >&2
    fi
  fi
  
  # Now copy Docker configuration files (after app exists)
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