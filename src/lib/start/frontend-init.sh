#!/usr/bin/env bash
# frontend-init.sh - Interactive frontend app scaffolding

# Get the appropriate framework initialization command
get_framework_command() {
  local framework="$1"
  local app_name="$2"
  
  case "${framework,,}" in
    sveltekit|svelte)
      echo "npx sv create ${app_name}"
      ;;
    nextjs|next)
      echo "npx create-next-app@latest ${app_name}"
      ;;
    react)
      echo "npm create vite@latest ${app_name} -- --template react-ts"
      ;;
    vue|vuejs)
      echo "npm create vite@latest ${app_name} -- --template vue-ts"
      ;;
    angular)
      echo "npx @angular/cli new ${app_name}"
      ;;
    static|html)
      # Static HTML - create basic structure manually
      echo "mkdir -p ${app_name}/{src,public}"
      ;;
    *)
      echo ""
      ;;
  esac
}



# Configure Vite to allow host access
configure_vite_host() {
  local app_name="$1"
  local framework="$2"
  
  # Only applies to Vite-based frameworks
  case "${framework,,}" in
    sveltekit|svelte|react|vue|vuejs)
      local vite_config=""
      if [[ -f "${app_name}/vite.config.ts" ]]; then
        vite_config="${app_name}/vite.config.ts"
      elif [[ -f "${app_name}/vite.config.js" ]]; then
        vite_config="${app_name}/vite.config.js"
      fi
      
      if [[ -n "$vite_config" ]]; then
        # Check if allowedHosts is already configured
        if grep -q "allowedHosts" "$vite_config"; then
          printf "   ${COLOR_DIM}Vite allowedHosts already configured, skipping${COLOR_RESET}\n"
        else
          printf "   ${COLOR_DIM}Configuring Vite allowed hosts...${COLOR_RESET}\n"
          
          # Determine the hostname
          local hostname="${app_name}.${BASE_DOMAIN:-localhost}"
          
          # Check if server block exists
          if grep -q "server:" "$vite_config"; then
          # Add allowedHosts to existing server block
          sed -i "/server:/a \    allowedHosts: [\"${hostname}\"]," "$vite_config"
        else
          # Add server block to defineConfig
          if grep -q "plugins: \[" "$vite_config"; then
             sed -i "/plugins: \[/i \  server: {\n    allowedHosts: [\"${hostname}\"],\n  }," "$vite_config"
          else
             # Fallback: append to end of object
             sed -i "\$s/^}/  server: {\n    allowedHosts: [\"${hostname}\"],\n  },\n}/" "$vite_config"
          fi
        fi
      fi
    fi
    ;;
  esac
}

# Initialize a single frontend app
init_frontend_app() {
  local app_name="$1"
  local framework="$2"
  local port="$3"
  
  # Check if app already exists
  if [[ -f "services/${app_name}/package.json" ]] || [[ -d "services/${app_name}/src" ]]; then
    printf "   ${COLOR_DIM}Frontend app '${app_name}' already initialized, skipping${COLOR_RESET}\n"
    # Still try to configure vite host if it's missing
    cd services || return 1
    configure_vite_host "$app_name" "$framework"
    cd ..
    return 0
  fi
  
  # Get framework command
  local cmd=$(get_framework_command "$framework" "$app_name")
  
  if [[ -z "$cmd" ]]; then
    printf "   ${COLOR_YELLOW}⚠${COLOR_RESET}  Unknown framework '${framework}', skipping\n"
    return 1
  fi
  
  printf "\n${COLOR_BOLD}🎨 Initializing ${framework} app '${app_name}'${COLOR_RESET}\n"
  printf "   ${COLOR_DIM}This will run interactively - please answer the prompts${COLOR_RESET}\n\n"
  
  # Change to services directory
  cd services || return 1
  
  # Handle static HTML specially
  if [[ "${framework,,}" == "static" ]] || [[ "${framework,,}" == "html" ]]; then
    mkdir -p "${app_name}"/{src,public}
    cat > "${app_name}/src/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>My App</title>
    <link rel="stylesheet" href="style.css">
</head>
<body>
    <h1>Welcome to your app!</h1>
    <script src="script.js"></script>
</body>
</html>
EOF
    touch "${app_name}/src/style.css"
    touch "${app_name}/src/script.js"
    printf "   ${COLOR_GREEN}✓${COLOR_RESET} Static HTML app created at services/${app_name}\n"
    cd ..
    return 0
  fi
  
  # Run the framework CLI command
  printf "   ${COLOR_DIM}Running: ${cmd}${COLOR_RESET}\n\n"
  
  if eval "$cmd"; then
    # Configure Vite to allow host access
    configure_vite_host "$app_name" "$framework"
    
    cd ..
    printf "\n   ${COLOR_GREEN}✓${COLOR_RESET} Frontend app '${app_name}' initialized successfully\n"
    printf "   ${COLOR_DIM}Location: services/${app_name}${COLOR_RESET}\n"
    return 0
  else
    cd ..
    printf "\n   ${COLOR_RED}✗${COLOR_RESET} Failed to initialize '${app_name}'\n"
    return 1
  fi
}

# Main function to scaffold all configured frontend apps
scaffold_frontend_apps() {
  local frontend_count="${FRONTEND_APP_COUNT:-0}"
  
  if [[ "$frontend_count" -eq 0 ]]; then
    return 0
  fi
  
  # Check if services directory exists
  if [[ ! -d "services" ]]; then
    printf "${COLOR_YELLOW}⚠${COLOR_RESET}  Services directory not found. Run 'nself build' first.\n"
    return 1
  fi
  
  # Check if npm/npx is available
  if ! command -v npx >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
    printf "\n${COLOR_YELLOW}⚠${COLOR_RESET}  Node.js/npm not found - frontend scaffolding skipped\n"
    printf "   ${COLOR_DIM}To initialize frontend apps, install Node.js from:${COLOR_RESET}\n"
    printf "   ${COLOR_CYAN}https://nodejs.org${COLOR_RESET} or use your package manager\n"
    printf "   ${COLOR_DIM}Then run 'nself start' again to scaffold the apps${COLOR_RESET}\n\n"
    return 0  # Non-fatal - return success
  fi
  
  printf "\n${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
  printf "${COLOR_BOLD} Frontend App Initialization${COLOR_RESET}\n"
  printf "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
  
  local initialized=0
  local skipped=0
  local failed=0
  
  # Iterate through all frontend apps
  for i in $(seq 1 "$frontend_count"); do
    # Safe indirect expansion
    local app_name framework port repo_url
    eval "app_name=\"\${FRONTEND_APP_${i}_NAME:-}\""
    eval "framework=\"\${FRONTEND_APP_${i}_FRAMEWORK:-}\""
    eval "port=\"\${FRONTEND_APP_${i}_PORT:-3000}\""
    eval "repo_url=\"\${FRONTEND_APP_${i}_REPO_URL:-}\""
    
    if [[ -z "$app_name" ]]; then
      continue
    fi

    # Skip if it's a repo-based app (already handled during build/clone)
    if [[ -n "$repo_url" ]]; then
      printf "   ${COLOR_DIM}Frontend app '${app_name}' is repo-based, skipping scaffolding${COLOR_RESET}\n"
      continue
    fi
    
    if init_frontend_app "$app_name" "$framework" "$port"; then
      if [[ -f "services/${app_name}/package.json" ]] || [[ -d "services/${app_name}/src" ]]; then
        if [[ $? -eq 0 ]]; then
          ((initialized++))
        else
          ((skipped++))
        fi
      fi
    else
      ((failed++))
    fi
  done
  
  # Summary
  printf "\n"
  if [[ $initialized -gt 0 ]]; then
    printf "${COLOR_GREEN}✓${COLOR_RESET} Initialized ${initialized} frontend app(s)\n"
  fi
  if [[ $skipped -gt 0 ]]; then
    printf "${COLOR_DIM}⊙${COLOR_RESET} Skipped ${skipped} existing app(s)\n"
  fi
  if [[ $failed -gt 0 ]]; then
    printf "${COLOR_RED}✗${COLOR_RESET} Failed to initialize ${failed} app(s)\n"
    return 1
  fi
  
  # Get domain and protocol for URL display
  local base_domain="${BASE_DOMAIN:-localhost}"
  local protocol="http"
  if [[ "${SSL_ENABLED:-false}" == "true" ]]; then
    protocol="https"
  fi
  
  printf "\n${COLOR_DIM}💡 Access your apps at:${COLOR_RESET}\n"
  for i in $(seq 1 "$frontend_count"); do
    local app_name port
    eval "app_name=\"\${FRONTEND_APP_${i}_NAME:-}\""
    eval "port=\"\${FRONTEND_APP_${i}_PORT:-3000}\""
    
    if [[ -n "$app_name" ]]; then
      # Construct URL based on environment
      if [[ "$base_domain" == "localhost" ]]; then
        printf "   ${COLOR_CYAN}${app_name}${COLOR_RESET}: ${protocol}://localhost:${port}\n"
      else
        # Use subdomain pattern: app.domain.com
        printf "   ${COLOR_CYAN}${app_name}${COLOR_RESET}: ${protocol}://${app_name}.${base_domain}\n"
      fi
    fi
  done
  printf "\n"
  
  return 0
}

# Export function
export -f scaffold_frontend_apps
export -f init_frontend_app
export -f get_framework_command
