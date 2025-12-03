#!/usr/bin/env bash
# frontend-routes.sh - Create routes directory for frontend apps

# Create routes directory structure for frontend applications
setup_frontend_routes() {
  local project_name="${1:-$(basename "$PWD")}"
  local env="${2:-dev}"
  
  # Check if any frontend apps are configured
  local frontend_count="${FRONTEND_APP_COUNT:-0}"
  
  if [[ "$frontend_count" -eq 0 ]]; then
    return 0
  fi
  
  # Create routes directory
  if [[ ! -d "routes" ]]; then
    mkdir -p routes
    echo "✓ Created routes/ directory for frontend apps"
  fi
  
  # Add .gitkeep to ensure directory is tracked
  if [[ ! -f "routes/.gitkeep" ]]; then
    touch routes/.gitkeep
  fi
  
  # Create basic .gitignore for frontend apps
  if [[ ! -f "routes/.gitignore" ]]; then
    cat > routes/.gitignore <<'EOF'
# Frontend app dependencies
node_modules/
.pnpm-store/

# Frontend build outputs
dist/
build/
.next/
.nuxt/
.output/
.svelte-kit/

# Frontend development
.vite/
.turbo/
*.log
.DS_Store

# Frontend environment
.env*.local
EOF
    echo "✓ Created routes/.gitignore"
  fi
}

# Export function
export -f setup_frontend_routes
