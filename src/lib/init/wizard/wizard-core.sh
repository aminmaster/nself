#!/usr/bin/env bash
# wizard-core.sh - Core wizard orchestration using modules
# POSIX-compliant, no Bash 4+ features

# Get script directory
WIZARD_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="$WIZARD_CORE_DIR/steps"

# Source step modules
source_wizard_steps() {
  local steps_dir="${1:-$STEPS_DIR}"

  # Source each step module
  for module in "$steps_dir"/*.sh; do
    if [[ -f "$module" ]]; then
      source "$module"
    fi
  done
}

# Run the configuration wizard
run_modular_wizard() {
  local output_file="${1:-.env}"

  # Set up trap for Ctrl+C
  trap 'echo ""; echo ""; log_info "Wizard cancelled"; echo "Run nself init --wizard to try again."; echo ""; exit 0' INT TERM

  # Configuration array
  local config=()

  # Source all wizard steps
  source_wizard_steps

  # Welcome screen
  clear
  show_wizard_header "nself Configuration Wizard" "Setup Your Project Step by Step"

  echo "Welcome to nself! Let's configure your project."
  echo "This wizard will walk you through the essential settings."
  echo ""
  echo "📝 We'll configure:"
  echo "  • Project name and domain"
  echo "  • Database settings"
  echo "  • Core services"
  echo "  • Optional services"
  echo "  • Frontend applications"
  echo ""
  echo "(Press Ctrl+C anytime to exit)"
  echo ""
  press_any_key

  # Step 1: Core Settings
  wizard_core_settings config

  # Extract project name for use in other steps
  local project_name=""
  for item in "${config[@]}"; do
    if [[ "$item" == CONF:PROJECT_NAME=* ]]; then
      project_name="${item#CONF:PROJECT_NAME=}"
      break
    elif [[ "$item" == PROJECT_NAME=* ]]; then
      project_name="${item#PROJECT_NAME=}"
      break
    fi
  done

  # Step 2: Database Configuration
  wizard_database_config config "$project_name"

  # Step 3: Core Services
  wizard_core_services config

  # Step 4: Service Passwords
  wizard_service_passwords config

  # Step 5: Admin Dashboard
  wizard_admin_dashboard config

  # Step 6: Optional Services
  wizard_optional_services config

  # Step 7: Email & Search
  wizard_email_search config

  # Step 8: Custom Backend Services
  wizard_custom_services config

  # Step 9: Frontend Applications
  wizard_frontend_apps config

  # Step 10: Review and Generate
  wizard_review_generate config "$output_file"

  return 0
}

# Configure service passwords
wizard_service_passwords() {
  local config_array_name="$1"

  clear
  show_wizard_step 4 10 "Service Passwords"

  echo "🔑 Service Authentication"
  echo ""
  echo "Set secure passwords for services:"
  echo ""

  # Hasura Admin Secret
  local hasura_enabled=false
  # Hasura Admin Secret
  local hasura_enabled=false
  eval "local config_values=(\"\${${config_array_name}[@]}\")"
  for cfg_item in "${config_values[@]}"; do
    if [[ "$cfg_item" == "CONF:HASURA_ENABLED=true" ]] || [[ "$cfg_item" == "HASURA_ENABLED=true" ]]; then
      hasura_enabled=true
      break
    fi
    if [[ "$cfg_item" == "CONF:AUTH_ENABLED=true" ]] || [[ "$cfg_item" == "AUTH_ENABLED=true" ]]; then
      hasura_enabled=true
      break
    fi
  done

  if [[ "$hasura_enabled" == "true" ]]; then
    echo "Hasura Admin Secret:"
    local hasura_secret
    if confirm_action "Use auto-generated secure password?"; then
      hasura_secret=$(generate_password 32)
      echo "Generated: [hidden for security]"
    else
      prompt_password "Admin secret" hasura_secret
    fi
    add_wizard_secret "$config_array_name" "HASURA_GRAPHQL_ADMIN_SECRET" "$hasura_secret"
    echo ""
  fi

  # JWT Secret
  echo "JWT Secret (for authentication tokens):"
  local jwt_secret
  if confirm_action "Use auto-generated secure secret?"; then
    jwt_secret=$(generate_password 64)
    echo "Generated: [hidden for security]"
  else
    prompt_password "JWT secret" jwt_secret
  fi
  add_wizard_secret "$config_array_name" "AUTH_JWT_SECRET" "$jwt_secret"

  echo ""

  # Storage/MinIO credentials
  local storage_enabled=false
  # Storage/MinIO credentials
  local storage_enabled=false
  eval "local config_values=(\"\${${config_array_name}[@]}\")"
  for cfg_item in "${config_values[@]}"; do
    if [[ "$cfg_item" == "CONF:STORAGE_ENABLED=true" ]] || [[ "$cfg_item" == "STORAGE_ENABLED=true" ]]; then
      storage_enabled=true
      break
    fi
  done

  if [[ "$storage_enabled" == "true" ]]; then
    echo "Storage Service Credentials:"
    local storage_access_key storage_secret_key

    prompt_input "Access key" "minioadmin" storage_access_key
    if confirm_action "Use auto-generated secret key?"; then
      storage_secret_key=$(generate_password 40)
      echo "Generated: [hidden for security]"
    else
      prompt_password "Secret key" storage_secret_key
    fi

    add_wizard_config "$config_array_name" "STORAGE_ACCESS_KEY" "$storage_access_key"
    add_wizard_secret "$config_array_name" "STORAGE_SECRET_KEY" "$storage_secret_key"
    echo ""
  fi





  return 0
}

# Configure admin dashboard
wizard_admin_dashboard() {
  local config_array_name="$1"

  clear
  show_wizard_step 5 10 "Admin Dashboard"

  echo "🎛 Admin Dashboard"
  echo ""

  if confirm_action "Enable nself admin dashboard?"; then
    add_wizard_config "$config_array_name" "NSELF_ADMIN_ENABLED" "true"
    add_wizard_config "$config_array_name" "NSELF_ADMIN_PORT" "3021"

    echo ""
    echo "Dashboard authentication:"
    local admin_user admin_password

    prompt_input "Admin username" "admin" admin_user
    if confirm_action "Use auto-generated password?"; then
      admin_password=$(generate_password 16)
      echo "Generated: [hidden for security]"
    else
      prompt_password "Admin password" admin_password
    fi

    add_wizard_config "$config_array_name" "NSELF_ADMIN_USER" "$admin_user"
    add_wizard_secret "$config_array_name" "NSELF_ADMIN_PASSWORD" "$admin_password"

    # Generate admin password hash for nself-admin service
    local admin_hash=""
    if command -v python3 >/dev/null 2>&1; then
      # Use python/bcrypt if available
      # We use || true to prevent script exit if python command fails (e.g. missing module)
      admin_hash=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$admin_password', bcrypt.gensalt()).decode())" 2>/dev/null || true)
    fi
    
    
    # Fallback if python/bcrypt failed or returned empty
    if [[ -z "$admin_hash" ]]; then
       # Try htpasswd with bcrypt (available on most systems)
       if command -v htpasswd >/dev/null 2>&1; then
         admin_hash=$(htpasswd -bnBC 10 "" "$admin_password" | tr -d ':\n' | sed 's/^//')
       # Try openssl with SHA-512 crypt as second fallback (nself-admin should support this)
       elif command -v openssl >/dev/null 2>&1; then
         admin_hash=$(openssl passwd -6 "$admin_password")
       else
         # Last resort: warn user and use plaintext (nself-admin will prompt for password reset)
         echo ""
         echo "⚠️  Warning: Could not generate password hash (bcrypt/htpasswd/openssl unavailable)"
         echo "   You'll need to set the admin password on first login"
         admin_hash="$admin_password"
       fi
    fi
    
    add_wizard_secret "$config_array_name" "ADMIN_PASSWORD_HASH" "$admin_hash"
    add_wizard_secret "$config_array_name" "ADMIN_SECRET_KEY" "$(generate_password 64)"

    echo ""
    echo "Dashboard features to enable:"

    if confirm_action "Enable real-time monitoring?"; then
      add_wizard_config "$config_array_name" "NSELF_ADMIN_MONITORING" "true"
    fi

    if confirm_action "Enable log viewer?"; then
      add_wizard_config "$config_array_name" "NSELF_ADMIN_LOGS" "true"
    fi

    if confirm_action "Enable database manager?"; then
      add_wizard_config "$config_array_name" "NSELF_ADMIN_DATABASE" "true"
    fi
  else
    add_wizard_config "$config_array_name" "NSELF_ADMIN_ENABLED" "false"
  fi

  return 0
}

# Configure custom backend services
wizard_custom_services() {
  local config_array_name="$1"

  clear
  show_wizard_step 8 10 "Custom Backend Services"

  echo "🔧 Custom Backend Services"
  echo ""

  if confirm_action "Add custom backend services?"; then
    local service_count=0
    local add_more=true

    while [[ "$add_more" == "true" ]] && [[ $service_count -lt 10 ]]; do
      service_count=$((service_count + 1))
      echo ""
      echo "Service #$service_count:"

      local service_name service_type service_port

      prompt_input "Service name" "service-$service_count" service_name "^[a-z][a-z0-9_-]*$"

      echo ""
      echo "Service type:"
      local type_options=(
        "express-js - Express.js REST API"
        "fastapi - Python FastAPI"
        "bullmq-js - BullMQ job processor"
        "grpc - gRPC service"
        "neo4j - Neo4j Graph Database"
        "llamaindex - LlamaIndex RAG API"
        "Custom Docker image"
      )
      local selected_type
      select_option "Select type" type_options selected_type

      case $selected_type in
        0) service_type="express-js" ;;
        1) service_type="fastapi" ;;
        2) service_type="bullmq-js" ;;
        3) service_type="grpc" ;;
        4) service_type="neo4j" ;;
        5) service_type="llamaindex" ;;
        6)
          echo ""
          prompt_input "Docker image" "node:18" service_type
          ;;
      esac

      # Prompt for service-specific credentials
      if [[ "$service_type" == "neo4j" ]]; then
        echo ""
        echo "Neo4j Configuration:"
        local neo4j_user neo4j_password
        prompt_input "Neo4j username" "neo4j" neo4j_user
        
        if confirm_action "Use auto-generated password?"; then
          neo4j_password=$(generate_password 24)
          echo "Generated: [hidden for security]"
        else
          prompt_password "Neo4j password" neo4j_password
        fi
        
        add_wizard_config "$config_array_name" "NEO4J_USER" "$neo4j_user"
        add_wizard_secret "$config_array_name" "NEO4J_PASSWORD" "$neo4j_password"
      elif [[ "$service_type" == "llamaindex" ]]; then
        echo ""
        echo "LlamaIndex Configuration:"
        # Check if OPENAI_API_KEY is already set
        local openai_key_set=false
        local openrouter_key_set=false
        eval "local config_values=(\"\${${config_array_name}[@]}\")"
        for cfg_item in "${config_values[@]}"; do
          if [[ "$cfg_item" == "SECR:OPENAI_API_KEY="* ]]; then
            openai_key_set=true
          fi
          if [[ "$cfg_item" == "SECR:OPENROUTER_API_KEY="* ]]; then
            openrouter_key_set=true
          fi
        done
        
        if [[ "$openai_key_set" == "false" ]]; then
          local openai_key
          prompt_password "OpenAI API Key (optional, press Enter to skip)" openai_key
          if [[ -n "$openai_key" ]]; then
            add_wizard_secret "$config_array_name" "OPENAI_API_KEY" "$openai_key"
          fi
        fi
        
        if [[ "$openrouter_key_set" == "false" ]]; then
          local openrouter_key
          prompt_password "OpenRouter API Key (recommended for multi-model access)" openrouter_key
          if [[ -n "$openrouter_key" ]]; then
            add_wizard_secret "$config_array_name" "OPENROUTER_API_KEY" "$openrouter_key"
          fi
        fi
      fi

      echo ""
      prompt_input "Service port" "$((8000 + service_count))" service_port "^[0-9][0-9]*$"

      add_wizard_config "$config_array_name" "CUSTOM_SERVICE_${service_count}" "${service_name}:${service_type}:${service_port}"

      echo ""
      if ! confirm_action "Add another service?"; then
        add_more=false
      fi
    done

    add_wizard_config "$config_array_name" "CUSTOM_SERVICES_COUNT" "$service_count"
  else
    add_wizard_config "$config_array_name" "CUSTOM_SERVICES_COUNT" "0"
  fi

  return 0
}

# Configure frontend applications
wizard_frontend_apps() {
  local config_array_name="$1"

  clear
  show_wizard_step 9 10 "Frontend Applications"

  echo "🎨 Frontend Applications"
  echo ""

  if confirm_action "Add frontend applications?"; then
    local app_count=0
    local add_more=true

    while [[ "$add_more" == "true" ]] && [[ $app_count -lt 10 ]]; do
      app_count=$((app_count + 1))
      echo ""
      echo "Frontend App #$app_count:"

      local app_name app_framework app_port

      prompt_input "App name" "app$app_count" app_name "^[a-z][a-z0-9-]*$"

      echo ""
      echo "Framework:"
      local framework_options=(
        "Next.js - React framework with SSR"
        "React - Create React App"
        "Vue.js - Progressive framework"
        "Angular - Enterprise framework"
        "Svelte - Compiled framework"
        "Static HTML - Plain HTML/CSS/JS"
      )
      local selected_framework
      select_option "Select framework" framework_options selected_framework

      case $selected_framework in
        0) app_framework="nextjs" ;;
        1) app_framework="react" ;;
        2) app_framework="vue" ;;
        3) app_framework="angular" ;;
        4) app_framework="svelte" ;;
        5) app_framework="static" ;;
      esac

      echo ""
      prompt_input "App port" "$((3000 + app_count - 1))" app_port "^[0-9]+$"

      add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_NAME" "$app_name"
      add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_FRAMEWORK" "$app_framework"
      add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_PORT" "$app_port"
      # Frontend apps are external - no DIR needed

      echo ""
      if ! confirm_action "Add another frontend app?"; then
        add_more=false
      fi
    done

    add_wizard_config "$config_array_name" "FRONTEND_APP_COUNT" "$app_count"
  else
    add_wizard_config "$config_array_name" "FRONTEND_APP_COUNT" "0"
  fi

  return 0
}

# Review and generate configuration
# Add configuration item
add_wizard_config() {
  local array_name="$1"
  local key="$2"
  local value="$3"
  eval "$array_name+=('CONF:$key=$value')"
}

# Add secret item
add_wizard_secret() {
  local array_name="$1"
  local key="$2"
  local value="$3"
  eval "$array_name+=('SECR:$key=$value')"
}

# Review and generate configuration
wizard_review_generate() {
  local config_array_name="$1"
  local output_file="$2"

  clear
  show_wizard_step 10 10 "Review Configuration"

  echo "📋 Configuration Summary"
  echo ""
  echo "Review your configuration:"
  echo ""

  # Display configuration
  eval "local config_items=(\"\${${config_array_name}[@]}\")"
  
  # Check environment mode
  local env_mode="dev"
  for item in "${config_items[@]}"; do
    if [[ "$item" == "CONF:ENV=prod" ]] || [[ "$item" == "ENV=prod" ]]; then
      env_mode="prod"
      break
    fi
  done

  # Display items (masking secrets)
  local display_count=0
  for item in "${config_items[@]}"; do
    local type="${item%%:*}"
    local content="${item#*:}"
    
    # Handle legacy items without prefix
    if [[ "$type" == "$content" ]]; then
      type="CONF"
    fi

    if [[ "$type" == "SECR" ]]; then
      local key="${content%%=*}"
      echo "  $key=[hidden]"
    else
      echo "  $content"
    fi
    
    ((display_count+=1))
    if [[ $display_count -ge 20 ]]; then
      break
    fi
  done

  local total_items=${#config_items[@]}
  if [[ $total_items -gt 20 ]]; then
    echo "  ... and $((total_items - 20)) more settings"
  fi

  echo ""
  if [[ "$env_mode" == "prod" ]]; then
    echo "Configuration will be saved to:"
    echo "  - .env.prod    (Configuration)"
    echo "  - .env.secrets (Secrets - DO NOT COMMIT)"
  else
    echo "Configuration will be saved to: $output_file"
  fi
  echo ""

  if confirm_action "Generate configuration?"; then
    # Create backup if file exists
    if [[ -f "$output_file" ]]; then
      local backup_file="${output_file}.backup.$(date +%Y%m%d_%H%M%S)"
      cp "$output_file" "$backup_file"
      echo "Backed up existing config to: $backup_file"
    fi

    if [[ "$env_mode" == "prod" ]]; then
      # Production: Split into .env.prod and .env.secrets
      {
        echo "# nself Production Configuration"
        echo "# Generated by wizard on $(date)"
        echo ""
        for item in "${config_items[@]}"; do
          local type="${item%%:*}"
          local content="${item#*:}"
          # Handle legacy items
          if [[ "$type" == "$content" ]]; then type="CONF"; fi
          
          if [[ "$type" == "CONF" ]]; then
            echo "$content"
          fi
        done
      } > ".env.prod"

      {
        echo "# nself Production Secrets"
        echo "# Generated by wizard on $(date)"
        echo "# DO NOT COMMIT THIS FILE TO VERSION CONTROL"
        echo ""
        for item in "${config_items[@]}"; do
          local type="${item%%:*}"
          local content="${item#*:}"
          # Handle legacy items
          if [[ "$type" == "$content" ]]; then type="CONF"; fi
          
          if [[ "$type" == "SECR" ]]; then
            # Escape $ as $$ for docker-compose variable interpolation
            # This prevents hashes like $6$salt$hash or $2a$... from being corrupted
            local escaped_content="${content//\$/\$\$}"
            echo "$escaped_content"
          fi
        done
      } > ".env.secrets"
      chmod 600 ".env.secrets"
      
      echo ""
      echo "✅ Configuration generated successfully!"
      echo "Created .env.prod and .env.secrets"
      
      # Ensure .env has the correct environment set
      if ! grep -q "^ENV=" .env 2>/dev/null; then
        echo "ENV=prod" >> .env
      else
        sed -i 's/^ENV=.*/ENV=prod/' .env
      fi
    else
      # Development: Everything in one file
      {
        echo "# nself Configuration"
        echo "# Generated by wizard on $(date)"
        echo ""
        for item in "${config_items[@]}"; do
          local content="${item#*:}"
          echo "$content"
        done
      } > "$output_file"
      
      echo ""
      echo "✅ Configuration generated successfully!"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Review generated files"
    echo "  2. Run: nself build"
    echo "  3. Run: nself start"
  else
    echo ""
    echo "Configuration not saved."
    echo "Run 'nself init --wizard' to try again."
  fi

  return 0
}

# Export functions
export -f add_wizard_config
export -f add_wizard_secret

# Export functions
export -f source_wizard_steps
export -f run_modular_wizard
export -f wizard_service_passwords
export -f wizard_admin_dashboard
export -f wizard_custom_services
export -f wizard_frontend_apps
export -f wizard_review_generate