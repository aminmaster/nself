#!/usr/bin/env bash
# wizard-core.sh - Core wizard orchestration using modules
# POSIX-compliant, no Bash 4+ features

# Get script directory
WIZARD_CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STEPS_DIR="$WIZARD_CORE_DIR/steps"

# Helper functions for config and secrets
add_wizard_config() {
  local array_name="$1"
  local key="$2"
  local value="$3"
  eval "$array_name+=('CONF:$key=$value')"
}

add_wizard_secret() {
  local array_name="$1"
  local key="$2"
  local value="$3"
  eval "$array_name+=('SECR:$key=$value')"
}

export -f add_wizard_config
export -f add_wizard_secret

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

# Main modular wizard flow
run_modular_wizard() {
  # Use environment-specific file: .env.prod for production, .env for dev/staging
  local env="${NSELF_ENV:-dev}"
  local output_file=".env"
  if [[ "$env" == "prod" ]] || [[ "$env" == "production" ]]; then
    output_file=".env.prod"
  elif [[ "$env" == "staging" ]] || [[ "$env" == "stage" ]]; then
    output_file=".env.staging"
  fi

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
  # 4. Generate/copy custom services
  local custom_service_items=()
  # Use a temporary array to hold config values for iteration
  local config_items=("${config[@]}")
  for item in "${config_items[@]}"; do
    if [[ "$item" == CUSTOM_SERVICE_* ]]; then
      custom_service_items+=("$item")
    fi
  done

  # Process custom services
  if [[ ${#custom_service_items[@]} -gt 0 ]]; then
    echo "Processing custom services..."
    mkdir -p "services"
    
    for item in "${custom_service_items[@]}"; do
      # Parse item format: CUSTOM_SERVICE_N=name:type:port
      local value="${item#*=}"
      local s_name s_type s_port
      
      IFS=':' read -r s_name s_type s_port <<< "$value"
      
      if [[ -n "$s_name" && -n "$s_type" ]]; then
        # Check if service directory exists
        if [[ ! -d "services/$s_name" ]]; then
          echo ""
          echo "  - Generating service: $s_name ($s_type)"
          
          # Standard template approach
          if [[ -d "src/templates/services/$s_type" ]]; then
            cp -r "src/templates/services/$s_type" "services/$s_name"
            # Render templates
            render_service_templates "services/$s_name" "$s_name" "$s_port"
          elif [[ -d "src/templates/services/py/$s_type" ]]; then
             cp -r "src/templates/services/py/$s_type" "services/$s_name"
             render_service_templates "services/$s_name" "$s_name" "$s_port"
          elif [[ -d "src/templates/services/js/$s_type" ]]; then
             cp -r "src/templates/services/js/$s_type" "services/$s_name"
             render_service_templates "services/$s_name" "$s_name" "$s_port"
          elif [[ -d "src/templates/services/db/$s_type" ]]; then
             cp -r "src/templates/services/db/$s_type" "services/$s_name"
             render_service_templates "services/$s_name" "$s_name" "$s_port"
          else
             # Default generic template
             mkdir -p "services/$s_name"
             cat > "services/$s_name/Dockerfile" <<EOF
FROM node:18-alpine
WORKDIR /app
COPY . .
CMD ["npm", "start"]
EOF
          fi
        else
          echo "  - Service directory services/$s_name already exists (skipping)"
        fi
      fi
    done
  fi
  echo "  • Frontend applications"
  echo ""
  echo "(Press Ctrl+C anytime to exit)"
  echo ""
  press_any_key

  # Step 1: Core Settings
  wizard_core_settings config

  # Extract project name and base domain for use in other steps
  local project_name=""
  local base_domain="localhost"
  for item in "${config[@]}"; do
    if [[ "$item" == "CONF:PROJECT_NAME="* ]]; then
      project_name="${item#CONF:PROJECT_NAME=}"
    elif [[ "$item" == "PROJECT_NAME="* ]]; then
      project_name="${item#PROJECT_NAME=}"
    elif [[ "$item" == "CONF:BASE_DOMAIN="* ]]; then
      base_domain="${item#CONF:BASE_DOMAIN=}"
    elif [[ "$item" == "BASE_DOMAIN="* ]]; then
      base_domain="${item#BASE_DOMAIN=}"
    fi
  done

  # Step 2: Global Admin Credentials (MOVED)
  wizard_admin_credentials config

  # Step 3: Database Configuration
  wizard_database_config config "$project_name"

  # Step 4: Core Services
  wizard_core_services config

  # Step 5: Service Passwords
  wizard_service_passwords config "$base_domain"

  # Step 6: Optional Services
  wizard_optional_services config

  # Step 7: Email & Search
  wizard_email_search config

  # Step 8: Custom Backend Services
  wizard_custom_services config

  # Step 8b: AI Model Providers (conditional - only if AI services selected)
  if type has_ai_services_selected &>/dev/null && has_ai_services_selected config; then
    wizard_model_providers config
  fi

  # Step 9: Frontend Applications
  wizard_frontend_apps config

  # Step 10: Review and Generate
  wizard_review_generate config "$output_file"

  return 0
}

# Configure service passwords
# Configure service passwords
wizard_service_passwords() {
  local config_array_name="$1"
  local base_domain="${2:-localhost}"

  clear
  show_wizard_step 5 10 "Service Passwords"

  echo "🔑 Service Authentication"
  echo ""
  echo "Set secure passwords for services:"
  echo ""

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

  # Nhost Webhook Secret
  if [[ "$hasura_enabled" == "true" ]]; then
    echo "Nhost Webhook Secret:"
    local nhost_secret
    if confirm_action "Use auto-generated secure secret for webhooks?"; then
      nhost_secret=$(generate_password 32)
      echo "Generated: [hidden for security]"
    else
      prompt_password "Webhook secret" nhost_secret
    fi
    add_wizard_secret "$config_array_name" "NHOST_WEBHOOK_SECRET" "$nhost_secret"
    echo ""
  fi

  return 0
}

# Configure global admin credentials
wizard_admin_credentials() {
  local config_array_name="$1"

  clear
  show_wizard_step 2 10 "Global Admin Credentials"

  echo "👤 Global Admin Credentials"
  echo "These credentials will be the 'Single Key' for the entire stack,"
  echo "including the Admin Dashboard, Grafana, MinIO, RabbitMQ, and AIO services."
  echo ""

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
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Admin Dashboard Configuration"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if confirm_action "Enable nself Admin Dashboard UI?"; then
    add_wizard_config "$config_array_name" "NSELF_ADMIN_ENABLED" "true"
    add_wizard_config "$config_array_name" "NSELF_ADMIN_PORT" "3021"

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
        "ai-ops - AI Operating System (RAGFlow + Langflow + Knowledge Graph)"
        "Custom Docker image"
      )
      local selected_type
      select_option "Select type" type_options selected_type

      case $selected_type in
        0) service_type="express-js" ;;
        1) service_type="fastapi" ;;
        2) service_type="bullmq-js" ;;
        3) service_type="grpc" ;;
        4) service_type="ai-ops" ;;
        5)
          echo ""
          prompt_input "Docker image" "node:18" service_type
          ;;
      esac

      # Prompt for service-specific credentials
      if [[ "$service_type" == "ai-ops" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "AI Operating System Configuration (Unified Stack):"
        echo "  • Ingestion: RAGFlow (High-fidelity Logic)"
        echo "  • Orchestration: Langflow (Agentic Brain)"
        echo "  • Memory: Graphiti + FalkorDB (Temporal User State)"
        echo "  • Knowledge: Neo4j (Structural Graph)"
        echo "  • Ops: MLFlow (Model Management)"
        echo "  • Infrastructure: Shared Postgres, Redis, ES, Minio"
        echo ""
        echo "  [NOTE] Admin Dashboard credentials will be used"
        echo "         for Langflow and stack-wide authentication."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        local aio_version aio_subdomain aio_secret ragflow_tag
        prompt_input "AIO Version" "1.0.0" aio_version
        add_wizard_config "$config_array_name" "AIO_VERSION" "$aio_version"

        prompt_input "RAGFlow Image Tag" "v0.23.1" ragflow_tag
        add_wizard_config "$config_array_name" "RAGFLOW_IMAGE_TAG" "$ragflow_tag"

        prompt_input "AIO Subdomain (e.g. brain)" "brain" aio_subdomain
        add_wizard_config "$config_array_name" "AIO_SUBDOMAIN" "$aio_subdomain"

        # Generate Secret Key
        aio_secret=$(generate_password 32)
        add_wizard_secret "$config_array_name" "AIO_SECRET_KEY" "$aio_secret"
        
        # AIO Database Credentials - Managed by Global Admin Password
        add_wizard_config "$config_array_name" "NEO4J_USER" "neo4j"
        add_wizard_config "$config_array_name" "AIO_STACK_PRESENT" "true"
        add_wizard_config "$config_array_name" "AI_SERVICES_SELECTED" "true"
        
        # FalkorDB Database Credentials (managed by global password)
        add_wizard_config "$config_array_name" "FALKORDB_URL" "falkor://aio-falkordb:6379"

        # MLFlow Config (Auto-Enable)
        add_wizard_config "$config_array_name" "MLFLOW_ENABLED" "true"
        add_wizard_config "$config_array_name" "MLFLOW_PORT" "5000"

        add_wizard_config "$config_array_name" "AI_SERVICES_SELECTED" "true"
        add_wizard_config "$config_array_name" "AIO_STACK_PRESENT" "true"
      fi

      # Service-specific default ports
      local default_port
      case "$service_type" in
        neo4j) default_port=7474 ;;

        graphiti) default_port=8000 ;;
        llamaindex) default_port=8000 ;;
        *) default_port=$((8000 + service_count)) ;;
      esac

      echo ""
      prompt_input "Service port" "$default_port" service_port "^[0-9][0-9]*$"

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

# Configure frontend applications (now containerized)
wizard_frontend_apps() {
  local config_array_name="$1"

  clear
  show_wizard_step 9 10 "Frontend Applications"

  echo "🎨 Frontend Applications (Containerized)"
  echo ""
  echo "Frontend apps now run in Docker containers for consistency."
  echo ""

  if confirm_action "Add frontend applications?"; then
    add_wizard_config "$config_array_name" "FRONTEND_ENABLED" "true"
    local app_count=0
    local add_more=true
    local primary_frontend_selected=false

    while [[ "$add_more" == "true" ]] && [[ $app_count -lt 10 ]]; do
      app_count=$((app_count + 1))
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "Frontend App #$app_count:"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      local app_name app_framework app_port repo_url
      
      prompt_input "App name (e.g., 'web' or 'admin')" "web" app_name "^[a-z][a-z0-9-]*$"
      
      # Ask for git repository URL
      echo ""
      echo "Do you have an existing frontend repository for '$app_name'?"
      prompt_input "Git repository URL (or press Enter to scaffold new app)" "" repo_url
      
      if [[ -n "$repo_url" ]]; then
        # User provided a repo URL
        add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_REPO_URL" "$repo_url"
        echo "  ✓ Will clone from: $repo_url"
      else
        # No repo - ask for framework to scaffold
        echo ""
        echo "Framework:"
        local framework_options=(
          "SvelteKit - Recommended modern framework"
          "Next.js - React framework with SSR"
          "Nuxt.js - Vue framework with SSR"
          "React (Vite) - Fast React development"
        )
        local selected_framework
        select_option "Select framework" framework_options selected_framework

        case $selected_framework in
          0) app_framework="sveltekit" ;;
          1) app_framework="nextjs" ;;
          2) app_framework="nuxtjs" ;;
          3) app_framework="react-vite" ;;
        esac
        add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_FRAMEWORK" "$app_framework"
        echo "  ✓ Will scaffold new $app_framework app"
      fi

      echo ""
      prompt_input "Container internal port" "$((3000 + app_count - 1))" app_port "^[0-9]+$"
      
      add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_NAME" "$app_name"
      add_wizard_config "$config_array_name" "FRONTEND_APP_${app_count}_PORT" "$app_port"

      # Superadmin Credentials: Now managed via global unified login

      # Primary Frontend Logic
      if [[ "$primary_frontend_selected" == "false" ]]; then
        echo ""
        if confirm_action "Make '$app_name' the primary frontend (accessible via the main domain)?"; then
          add_wizard_config "$config_array_name" "PRIMARY_FRONTEND_PORT" "$app_port"
          add_wizard_config "$config_array_name" "PRIMARY_FRONTEND_NAME" "$app_name"
          primary_frontend_selected=true
          echo "  ✓ '$app_name' set as primary frontend."
        fi
      fi

      echo ""
      if ! confirm_action "Add another frontend app?"; then
        add_more=false
      fi
    done

    add_wizard_config "$config_array_name" "FRONTEND_APP_COUNT" "$app_count"
  else
    add_wizard_config "$config_array_name" "FRONTEND_ENABLED" "false"
    add_wizard_config "$config_array_name" "FRONTEND_APP_COUNT" "0"
  fi

  return 0
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
export -f wizard_admin_credentials
export -f wizard_custom_services
export -f wizard_frontend_apps
export -f wizard_review_generate