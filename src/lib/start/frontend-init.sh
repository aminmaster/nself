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

# Initialize a single frontend app
init_frontend_app() {
  local app_name="$1"
  local framework="$2"
  local port="$3"
  
  # Check if app already exists
  if [[ -f "routes/${app_name}/package.json" ]] || [[ -d "routes/${app_name}/src" ]]; then
    printf "   ${COLOR_DIM}Frontend app '${app_name}' already initialized, skipping${COLOR_RESET}\n"
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
  
  # Change to routes directory
  cd routes || return 1
  
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
    printf "   ${COLOR_GREEN}✓${COLOR_RESET} Static HTML app created at routes/${app_name}\n"
    cd ..
    return 0
  fi
  
  # Run the framework CLI command
  printf "   ${COLOR_DIM}Running: ${cmd}${COLOR_RESET}\n\n"
  
  if eval "$cmd"; then
    cd ..
    printf "\n   ${COLOR_GREEN}✓${COLOR_RESET} Frontend app '${app_name}' initialized successfully\n"
    printf "   ${COLOR_DIM}Location: routes/${app_name}${COLOR_RESET}\n"
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
  
  # Check if routes directory exists
  if [[ ! -d "routes" ]]; then
    printf "${COLOR_YELLOW}⚠${COLOR_RESET}  Routes directory not found. Run 'nself build' first.\n"
    return 1
  fi
  
  printf "\n${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
  printf "${COLOR_BOLD} Frontend App Initialization${COLOR_RESET}\n"
  printf "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
  
  local initialized=0
  local skipped=0
  local failed=0
  
  # Iterate through all frontend apps
  for i in $(seq 1 "$frontend_count"); do
    local app_name_var="FRONTEND_APP_${i}_NAME"
    local framework_var="FRONTEND_APP_${i}_FRAMEWORK"
    local port_var="FRONTEND_APP_${i}_PORT"
    
    local app_name="${!app_name_var}"
    local framework="${!framework_var}"
    local port="${!port_var:-3000}"
    
    if [[ -z "$app_name" ]]; then
      continue
    fi
    
    if init_frontend_app "$app_name" "$framework" "$port"; then
      if [[ -f "routes/${app_name}/package.json" ]] || [[ -d "routes/${app_name}/src" ]]; then
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
  
  printf "\n${COLOR_DIM}💡 Access your apps at:${COLOR_RESET}\n"
  for i in $(seq 1 "$frontend_count"); do
    local app_name_var="FRONTEND_APP_${i}_NAME"
    local port_var="FRONTEND_APP_${i}_PORT"
    local app_name="${!app_name_var}"
    local port="${!port_var:-3000}"
    
    if [[ -n "$app_name" ]]; then
      printf "   ${COLOR_CYAN}${app_name}${COLOR_RESET}: http://localhost:${port}\n"
    fi
  done
  printf "\n"
  
  return 0
}

# Export function
export -f scaffold_frontend_apps
export -f init_frontend_app
export -f get_framework_command
