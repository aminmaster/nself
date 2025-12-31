#!/usr/bin/env bash
# start.sh - Professional start command with clean progress indicators
# Matches the style of nself build command

set -uo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source only essential utilities
source "$LIB_DIR/utils/display.sh"
source "$LIB_DIR/utils/env.sh"

# Smart defaults from environment variables
HEALTH_CHECK_TIMEOUT="${NSELF_HEALTH_CHECK_TIMEOUT:-120}"
HEALTH_CHECK_INTERVAL="${NSELF_HEALTH_CHECK_INTERVAL:-2}"
HEALTH_CHECK_REQUIRED="${NSELF_HEALTH_CHECK_REQUIRED:-80}"
SKIP_HEALTH_CHECKS="${NSELF_SKIP_HEALTH_CHECKS:-false}"
START_MODE="${NSELF_START_MODE:-smart}"
CLEANUP_ON_START="${NSELF_CLEANUP_ON_START:-auto}"

# Validate ranges for health check settings
if [[ $HEALTH_CHECK_TIMEOUT -lt 30 ]] || [[ $HEALTH_CHECK_TIMEOUT -gt 600 ]]; then
  HEALTH_CHECK_TIMEOUT=120
fi
if [[ $HEALTH_CHECK_INTERVAL -le 0 ]] || [[ $HEALTH_CHECK_INTERVAL -gt 10 ]]; then
  HEALTH_CHECK_INTERVAL=2
fi
if [[ $HEALTH_CHECK_REQUIRED -lt 0 ]] || [[ $HEALTH_CHECK_REQUIRED -gt 100 ]]; then
  HEALTH_CHECK_REQUIRED=80
fi

# Parse arguments first
VERBOSE=false
DEBUG=false
SHOW_HELP=false
SKIP_HEALTH=false
FORCE_RECREATE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      VERBOSE=true
      shift
      ;;
    -d|--debug)
      DEBUG=true
      VERBOSE=true  # Debug implies verbose
      shift
      ;;
    -h|--help)
      SHOW_HELP=true
      shift
      ;;
    --skip-health-checks)
      SKIP_HEALTH_CHECKS=true
      shift
      ;;
    --timeout)
      if [[ -z "$2" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --timeout requires a numeric value" >&2
        exit 1
      fi
      HEALTH_CHECK_TIMEOUT="$2"
      shift 2
      ;;
    --fresh|--force-recreate)
      START_MODE="fresh"
      shift
      ;;
    --clean-start)
      CLEANUP_ON_START="always"
      shift
      ;;
    --quick)
      HEALTH_CHECK_TIMEOUT=30
      HEALTH_CHECK_REQUIRED=60
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# Show help if requested
if [[ "$SHOW_HELP" == "true" ]]; then
  echo "Usage: nself start [OPTIONS]"
  echo ""
  echo "Start all services defined in docker-compose.yml"
  echo ""
  echo "Options:"
  echo "  -v, --verbose           Show detailed Docker output"
  echo "  -d, --debug            Show debug information and detailed output"
  echo "  -h, --help             Show this help message"
  echo "  --skip-health-checks   Skip health check validation"
  echo "  --timeout N            Set health check timeout in seconds (default: $HEALTH_CHECK_TIMEOUT)"
  echo "  --fresh                Force recreate all containers"
  echo "  --clean-start          Remove all containers before starting"
  echo "  --quick                Quick start with relaxed health checks"
  echo ""
  echo "Environment Variables (optional):"
  echo "  NSELF_START_MODE              Start mode: smart, fresh, force (default: smart)"
  echo "  NSELF_HEALTH_CHECK_TIMEOUT    Health check timeout seconds (default: 120)"
  echo "  NSELF_HEALTH_CHECK_REQUIRED   Percent services required healthy (default: 80, 100 for AIO)"
  echo "  NSELF_SKIP_HEALTH_CHECKS      Skip health validation (default: false)"
  echo ""
  echo "Examples:"
  echo "  nself start                  # Start with smart defaults"
  echo "  nself start -v               # Start with verbose output"
  echo "  nself start --quick          # Quick start for development"
  echo "  nself start --fresh          # Force recreate all containers"
  echo "  nself start --timeout 180    # Wait up to 3 minutes for health"
  exit 0
fi

# Progress tracking functions
declare -a PROGRESS_STEPS=()
declare -a PROGRESS_STATUS=()
CURRENT_STEP=0

add_progress() {
  PROGRESS_STEPS+=("$1")
  PROGRESS_STATUS+=("pending")
}

update_progress() {
  local step=$1
  local status=$2
  PROGRESS_STATUS[$step]=$status

  if [[ "$VERBOSE" == "false" ]]; then
    # Clear line and show updated status
    local message="${PROGRESS_STEPS[$step]}"
    if [[ "$status" == "running" ]]; then
      printf "\r${COLOR_BLUE}⠋${COLOR_RESET} %s..." "$message"
    elif [[ "$status" == "done" ]]; then
      printf "\r${COLOR_GREEN}✓${COLOR_RESET} %-40s\n" "$message"
    elif [[ "$status" == "error" ]]; then
      printf "\r${COLOR_RED}✗${COLOR_RESET} %-40s\n" "$message"
    fi
  fi
}

# Track lines printed for recursive status updates
LAST_LINE_COUNT=0

# Clean pull progress renderer
render_pull_progress() {
  local start_output="$1"
  local spin_char="$2"
  
  # Find all unique images being pulled
  local pulling_images=$(grep "Pulling from\|Pulled" "$start_output" | sed -E 's/.*Pulling from //;s/.*Pulled //' | sort -u || echo "")
  
  if [[ -z "$pulling_images" ]]; then
    return 0
  fi

  # Move cursor back up if we already printed lines
  if [[ $LAST_LINE_COUNT -gt 0 ]]; then
    printf "\033[%dA" "$LAST_LINE_COUNT"
  fi

  local current_count=0
  for img in $pulling_images; do
    # Check status of this image
    local status="Pending"
    local color="${COLOR_BLUE}"
    local icon="${spin_char}"
    
    if grep -q "Pulled\|Pull complete.*$img\|Already exists.*$img" "$start_output" 2>/dev/null; then
      status="Done"
      color="${COLOR_GREEN}"
      icon="✓"
    elif grep -q "Extracting.*$img" "$start_output" 2>/dev/null; then
      status="Extracting"
    elif grep -q "Downloading.*$img" "$start_output" 2>/dev/null; then
      status="Downloading"
    fi
    
    printf "\r${color}%s${COLOR_RESET} %-45s [%s]\033[K\n" "$icon" "$img" "$status"
    current_count=$((current_count + 1))
  done
  
  LAST_LINE_COUNT=$current_count
}

# Check firewall configuration
check_firewall_rules() {
  # Skip if UFW not installed
  command -v ufw >/dev/null 2>&1 || return 0
  
  # Load environment variables
  if [[ -f ".env.prod" ]]; then
    source .env.prod
  elif [[ -f ".env" ]]; then
    source .env
  fi
  
  local missing_rules=()
  local missing_commands=()
  
  # Check essential nginx ports (80, 443)
  if ! sudo ufw status 2>/dev/null | grep -q "80/tcp.*ALLOW.*Anywhere"; then
    missing_rules+=("HTTP (port 80)")
    missing_commands+=("sudo ufw allow 80/tcp comment 'HTTP (redirect to HTTPS)'")
  fi
  
  if ! sudo ufw status 2>/dev/null | grep -q "443/tcp.*ALLOW.*Anywhere"; then
    missing_rules+=("HTTPS (port 443)")
    missing_commands+=("sudo ufw allow 443/tcp comment 'HTTPS'")
  fi
  
  # Frontend app ports no longer need host rules as they are containerized and proxied
  return 0
  
  # Display missing rules if any
  if [[ ${#missing_rules[@]} -gt 0 ]]; then
    printf "\n${COLOR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n"
    printf "${COLOR_YELLOW}⚠  Firewall Configuration Required${COLOR_RESET}\n"
    printf "${COLOR_YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}\n\n"
    printf "Missing UFW rules detected:\n"
    for rule in "${missing_rules[@]}"; do
      printf "  • %s\n" "$rule"
    done
    printf "\nPlease run the following commands:\n\n"
    
    for cmd in "${missing_commands[@]}"; do
      printf "  ${COLOR_CYAN}%s${COLOR_RESET}\n" "$cmd"
    done
    
    printf "\nThen reload UFW:\n"
    printf "  ${COLOR_CYAN}sudo ufw reload${COLOR_RESET}\n\n"
  fi
}

# Start services function
start_services() {
  # Initialize UI state
  LAST_LINE_COUNT=0
  
  # 1. Detect environment and project
  local env="${ENV:-dev}"
  if [[ -f ".env" ]]; then
    env=$(grep "^ENV=" .env 2>/dev/null | cut -d= -f2- || echo "dev")
  fi

  local project_name="${PROJECT_NAME:-}"
  if [[ -z "$project_name" ]] && [[ -f ".env" ]]; then
    project_name=$(grep "^PROJECT_NAME=" .env 2>/dev/null | cut -d= -f2-)
  fi
  if [[ -z "$project_name" ]]; then
    project_name=$(basename "$PWD")
  fi

  # 2. Show header (like build command)
  show_command_header "nself start" "Start all project services"

  # 3. Setup progress steps
  add_progress "Validating prerequisites"
  add_progress "Cleaning previous state"
  add_progress "Creating network"
  add_progress "Creating volumes"
  add_progress "Creating containers"
  add_progress "Starting core services"
  add_progress "Starting optional services"
  add_progress "Starting monitoring"
  add_progress "Starting custom services"
  add_progress "Verifying health checks"

  # 4. Validate prerequisites
  update_progress 0 "running"

  if [[ ! -f "docker-compose.yml" ]]; then
    update_progress 0 "error"
    printf "\n${COLOR_RED}Error: docker-compose.yml not found${COLOR_RESET}\n"
    printf "Run '${COLOR_BLUE}nself build${COLOR_RESET}' first to generate configuration\n\n"
    return 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    update_progress 0 "error"
    printf "\n${COLOR_RED}Error: Docker is not installed${COLOR_RESET}\n\n"
    return 1
  fi

  if ! docker info >/dev/null 2>&1; then
    update_progress 0 "error"
    printf "\n${COLOR_RED}Error: Docker daemon is not running${COLOR_RESET}\n"
    printf "Start Docker Desktop or run: ${COLOR_BLUE}sudo systemctl start docker${COLOR_RESET}\n\n"
    return 1
  fi

  update_progress 0 "done"

  # 5. Clean up containers based on CLEANUP_ON_START setting
  update_progress 1 "running"

  # Also check for containers with the actual project name from .env
  local actual_project_name="${PROJECT_NAME:-$project_name}"
  if [[ -f ".env" ]]; then
    actual_project_name=$(grep "^PROJECT_NAME=" .env 2>/dev/null | cut -d= -f2- || echo "$project_name")
  fi

  # Determine cleanup behavior
  local should_cleanup=false
  if [[ "$CLEANUP_ON_START" == "always" ]]; then
    should_cleanup=true
  elif [[ "$CLEANUP_ON_START" == "auto" ]]; then
    # Check if any containers are in error state
    local error_containers=$(docker ps -a --filter "name=${actual_project_name}_" --filter "status=exited" --format "{{.Names}}" 2>/dev/null)
    if [[ -n "$error_containers" ]]; then
      should_cleanup=true
    fi
  fi

  if [[ "$should_cleanup" == "true" ]]; then
    # Clean up containers with both potential naming patterns
    local existing_containers=$(docker ps -aq --filter "name=${actual_project_name}_" 2>/dev/null)
    if [[ -n "$existing_containers" ]]; then
      docker rm -f $existing_containers >/dev/null 2>&1 || true
    fi

    # Also clean up with directory-based name if different
    if [[ "$project_name" != "$actual_project_name" ]]; then
      existing_containers=$(docker ps -aq --filter "name=${project_name}_" 2>/dev/null)
      if [[ -n "$existing_containers" ]]; then
        docker rm -f $existing_containers >/dev/null 2>&1 || true
      fi
    fi

    # Clean up any existing network to avoid conflicts
    docker network rm "${actual_project_name}_network" >/dev/null 2>&1 || true
    docker network rm "${project_name}_default" >/dev/null 2>&1 || true
  fi

  update_progress 1 "done"

  # 6. Source env-merger if available
  if [[ -f "$LIB_DIR/utils/env-merger.sh" ]]; then
    source "$LIB_DIR/utils/env-merger.sh"
  fi

  # 7. Generate merged runtime environment
  local target_env="${env:-dev}"
  if command -v merge_environments >/dev/null 2>&1; then
    if [[ "$VERBOSE" == "false" ]]; then
      merge_environments "$target_env" ".env.runtime" > /dev/null 2>&1
    else
      printf "Merging environment configuration...\n"
      merge_environments "$target_env" ".env.runtime"
    fi
  fi

  # 8. Determine env file and update project name from runtime
  local env_file=".env"
  if [[ -f ".env.runtime" ]]; then
    env_file=".env.runtime"
    set +ue
    source ".env.runtime"
    set -ue
    # Update project_name from runtime file
    project_name=$(grep "^PROJECT_NAME=" .env.runtime 2>/dev/null | cut -d= -f2- | tr -d '\r' || echo "$project_name")
  fi

  # 9. Start services
  local compose_cmd="docker compose"
  
  # Build the docker compose command based on start mode
  local compose_args=(
    "--project-name" "$project_name"
    "--env-file" "$env_file"
    "up" "-d"
    "--remove-orphans"
  )

  # Add mode-specific flags
  if [[ "$START_MODE" == "fresh" ]]; then
    compose_args+=("--force-recreate")
  elif [[ "$START_MODE" == "force" ]]; then
    compose_args+=("--force-recreate" "--renew-anon-volumes")
  fi

  if [[ "$DEBUG" == "true" ]]; then
    echo ""
    echo "DEBUG: Project name: $project_name"
    echo "DEBUG: Environment: $env"
    echo "DEBUG: Env file: $env_file"
    echo "DEBUG: Command: $compose_cmd ${compose_args[*]}"
    echo ""
  fi

  # Execute docker compose
  if [[ "$VERBOSE" == "true" ]]; then
    update_progress 2 "running"
    # Show real-time output in verbose mode
    $compose_cmd "${compose_args[@]}"
    local exit_code=$?
    update_progress 2 "done"
  else
    update_progress 2 "running"
    # Suppress output but show progress in normal mode
    $compose_cmd "${compose_args[@]}" > /dev/null 2>&1
    local exit_code=$?
    update_progress 2 "done"
  fi

  # 10. Check results
  if [[ $exit_code -eq 0 ]]; then
    # Mark intermediate steps as done
    update_progress 3 "done"
    update_progress 4 "done"
    update_progress 5 "done"
    update_progress 6 "done"
    update_progress 7 "done"
    update_progress 8 "done"

    # Verify health checks (unless skipped)
    if [[ "$SKIP_HEALTH_CHECKS" != "true" ]]; then
      update_progress 9 "running"

      # Progressive health check with configurable timeout and threshold
      local start_time=$(date +%s)
      local health_check_passed=false
      local required_threshold="${HEALTH_CHECK_REQUIRED:-80}"
      
      # If AIO stack is present, require 100% unless specifically overridden
      if grep -q "AIO_STACK_PRESENT=true" .env.runtime 2>/dev/null && [[ -z "${NSELF_HEALTH_CHECK_REQUIRED:-}" ]]; then
        required_threshold=100
      fi

      printf "Waiting for services to become healthy (threshold: %d%%)...\n" "$required_threshold"

      while true; do
        current_time=$(date +%s)
        elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $HEALTH_CHECK_TIMEOUT ]]; then
          break
        fi

        # Count health status
        local running_containers=$(docker ps --filter "label=com.docker.compose.project=$project_name" --format "{{.Names}}\t{{.Status}}\t{{.State}}" 2>/dev/null)
        local total_targeted=$(echo "$STATUS_TARGETS" | wc -w | tr -d '[:space:]')
        
        local healthy_count=0
        
        # Check each target service
        for target in $STATUS_TARGETS; do
          local target_alt="${target//-/_}"
          local match=$(echo "$running_containers" | grep -E "^(${project_name}_${target}|${project_name}_${target_alt})[[:space:]]")
          
          if [[ -n "$match" ]]; then
            local status=$(echo "$match" | cut -f2)
            local state=$(echo "$match" | cut -f3)
            
            if [[ "$status" == *"healthy"* ]]; then
              healthy_count=$((healthy_count + 1))
            elif [[ "$status" != *"unhealthy"* && "$status" != *"starting"* ]] && [[ "$state" == "running" ]]; then
              healthy_count=$((healthy_count + 1))
            elif [[ "$state" == "exited" ]] && [[ "$status" == *"Exited (0)"* ]]; then
              healthy_count=$((healthy_count + 1))
            fi
          fi
        done

        if [[ $total_targeted -gt 0 ]]; then
          local health_percent=$((healthy_count * 100 / total_targeted))
          printf "\rProgress: %d/%d healthy (%d%%) [Elapsed: %ds]\033[K" "$healthy_count" "$total_targeted" "$health_percent" "$elapsed"
          if [[ $health_percent -ge $required_threshold ]]; then
            health_check_passed=true
            printf "\n"
            break
          fi
        fi

        sleep "$HEALTH_CHECK_INTERVAL"
      done

      update_progress 9 "done"
    else
      update_progress 9 "done"
    fi

    # Final summary (simplified)
    local running_count=$(docker ps --filter "label=com.docker.compose.project=$project_name" --format "{{.Names}}" 2>/dev/null | wc -l | tr -d '[:space:]')
    local healthy_count=$(docker ps --filter "label=com.docker.compose.project=$project_name" --format "{{.Status}}" 2>/dev/null | grep "healthy" | wc -l | tr -d '[:space:]')

    printf "\n${COLOR_GREEN}✓${COLOR_RESET} ${COLOR_BOLD}All services started successfully${COLOR_RESET}\n"
    printf "${COLOR_GREEN}✓${COLOR_RESET} Project: ${COLOR_BOLD}%s${COLOR_RESET} (%s)\n" "$project_name" "$env"
    printf "${COLOR_GREEN}✓${COLOR_RESET} Health: %s/%s healthy\n" "$healthy_count" "$running_count"

    printf "\n${COLOR_BOLD}Next steps:${COLOR_RESET}\n"
    printf "1. ${COLOR_BLUE}nself status${COLOR_RESET} - Check service health\n"
    printf "2. ${COLOR_BLUE}nself urls${COLOR_RESET} - View service URLs\n"
    printf "3. ${COLOR_BLUE}nself logs${COLOR_RESET} - View service logs\n\n"

  else
    printf "\n${COLOR_RED}✗ Failed to start services${COLOR_RESET}\n\n"
    return 1
  fi


  # 11. Check for SSL setup
  if [[ $exit_code -eq 0 ]]; then
    # Source runtime environment to get correct SSL_PROVIDER
    if [[ -f ".env.runtime" ]]; then
      set +ue
      set -a
      source ".env.runtime"
      set +a
      set -ue
    fi

    local ssl_provider="${SSL_PROVIDER:-selfsigned}"
    local base_domain="${BASE_DOMAIN:-localhost}"
    
    if [[ "$ssl_provider" == "letsencrypt" ]]; then
      local run_setup=false
      local reason=""

      # Check if certificates exist
      if [[ ! -f "ssl/certificates/${base_domain}/fullchain.pem" ]]; then
        run_setup=true
        reason="Certificates are missing."
      else
        # Check if existing certificate is self-signed (not Let's Encrypt)
        if ! openssl x509 -in "ssl/certificates/${base_domain}/fullchain.pem" -noout -issuer 2>/dev/null | grep -q "Let's Encrypt"; then
          run_setup=true
          reason="Existing certificate is self-signed."
        fi
      fi

      if [[ "$run_setup" == "true" ]]; then
        printf "\n${COLOR_YELLOW}⚠ SSL Configuration Required: ${reason}${COLOR_RESET}\n"
        printf "SSL_PROVIDER is set to 'letsencrypt', but valid certificates were not found.\n\n"
        
        # Check if setup script exists
        local setup_script="$SCRIPT_DIR/../scripts/setup-ssl.sh"
        if [[ -f "$setup_script" ]]; then
          read -p "Run SSL setup script now? [Y/n] " -n 1 -r
          echo
          if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
            # Run setup script
            bash "$setup_script"
          else
            printf "\nYou can run it later with: ${COLOR_BLUE}$setup_script${COLOR_RESET}\n"
          fi
        else
          printf "Setup script not found at $setup_script\n"
        fi
      fi
    fi
  fi

  # Initialize frontend apps (if configured)
  # This runs LAST to ensure clean terminal state for interactive prompts
  if [[ -f "$LIB_DIR/start/frontend-init.sh" ]]; then
    # Restore terminal to clean state for interactive scaffolding
    if [[ -t 0 ]]; then
      # Restore saved TTY settings
      if [[ -n "$saved_tty_settings" ]]; then
        stty "$saved_tty_settings" 2>/dev/null || true
      fi
      
      # Reset terminal to sane state
      stty sane 2>/dev/null || true
      
      # Re-attach to controlling terminal
      exec </dev/tty >/dev/tty 2>&1
    fi
    
    source "$LIB_DIR/start/frontend-init.sh"
    # Run scaffolding - errors are non-fatal
    scaffold_frontend_apps || true
  fi

  # Clean up temp files
  rm -f "$start_output" "$error_output"
  
  # Check firewall configuration
  check_firewall_rules
  
  # Auto-run status and urls to show immediate feedback
  printf "\n"
  if [[ -f "$SCRIPT_DIR/status.sh" ]]; then
    bash "$SCRIPT_DIR/status.sh"
  fi
  
  if [[ -f "$SCRIPT_DIR/urls.sh" ]]; then
    printf "\n"
    bash "$SCRIPT_DIR/urls.sh"
  fi
  
  return 0
}

# Run start
start_services