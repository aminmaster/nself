#!/usr/bin/env bash
# custom-services-templates.sh - Generate Docker services from template-based CS_ variables

# Generate custom service from template-based CS_ variable
generate_template_based_service() {
  local index="$1"
  local service_name="$2"
  local template_type="$3"
  local service_port="$4"

  # Special handling for multi-container stacks (like AI-OPS) that generate their own headers
  if [[ "$template_type" == "ai-ops" ]]; then
      generate_aio_stack "$index" "$service_name" "$service_port"
      return 0
  fi

  # Skip if service directory doesn't exist (template not copied)
  [[ ! -d "services/$service_name" ]] && return 0

  cat <<EOF

  # Custom Service ${index}: ${service_name}
  ${service_name}:
EOF

  # Special handling based on template type
  case "$template_type" in
    neo4j)
      cat <<EOF
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_${service_name}
    restart: unless-stopped
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
EOF
      ;;

    graphiti)
      cat <<EOF
    build:
      context: ./services/${service_name}
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_${service_name}
    restart: unless-stopped
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
EOF
      ;;

    *)
      # Standard buildable service
      cat <<EOF
    build:
      context: ./services/${service_name}
      dockerfile: Dockerfile
    container_name: \${PROJECT_NAME}_${service_name}
    restart: unless-stopped
    networks:
      - \${DOCKER_NETWORK:-\${PROJECT_NAME}_network}
EOF
      ;;
  esac

  # Add ports if specified
  if [[ -n "$service_port" && "$service_port" != "0" ]]; then
    cat <<EOF
    ports:
      - "${service_port}:${service_port}"
EOF
  fi

  # Add environment variables
  cat <<EOF
    environment:
      - ENV=\${ENV:-dev}
      - NODE_ENV=\${ENV:-dev}
      - APP_ENV=\${ENV:-dev}
      - ENVIRONMENT=\${ENV:-dev}
      - PROJECT_NAME=\${PROJECT_NAME}
      - BASE_DOMAIN=\${BASE_DOMAIN:-localhost}
      - SERVICE_NAME=${service_name}
      - SERVICE_PORT=${service_port}
      - PORT=${service_port}
      - POSTGRES_HOST=postgres
      - POSTGRES_PORT=5432
      - POSTGRES_DB=\${POSTGRES_DB}
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - REDIS_PASSWORD=\${REDIS_PASSWORD:-}
      - HASURA_GRAPHQL_ENDPOINT=http://hasura:8080/v1/graphql
      - HASURA_ADMIN_SECRET=\${HASURA_GRAPHQL_ADMIN_SECRET}
      - OPENAI_API_KEY=\${OPENAI_API_KEY:-}
      - ANTHROPIC_API_KEY=\${ANTHROPIC_API_KEY:-}
      - COHERE_API_KEY=\${COHERE_API_KEY:-}
      - HUGGINGFACE_API_KEY=\${HUGGINGFACE_API_KEY:-}
      - OPENROUTER_API_KEY=\${OPENROUTER_API_KEY:-}
      - OPENROUTER_MODEL_TXT=\${OPENROUTER_MODEL_TXT:-x-ai/grok-4.1-fast}
      - OPENROUTER_MODEL_IMG=\${OPENROUTER_MODEL_IMG:-}
      - OPENROUTER_MODEL_EMB=\${OPENROUTER_MODEL_EMB:-}
EOF

  # Add Neo4j-specific vars for Neo4j itself
  if [[ "$template_type" == "neo4j" ]]; then
    cat <<EOF
      - NEO4J_AUTH=neo4j/\${NEO4J_PASSWORD}
EOF
  fi

  # Add Neo4j connection vars for other services (NOT Neo4j itself to avoid config collision)
  if [[ "$template_type" != "neo4j" ]]; then
    cat <<EOF
      - NEO4J_URI=\${NEO4J_URI:-bolt://graph:7687}
      - NEO4J_USERNAME=\${NEO4J_USER:-neo4j}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD}
EOF
  fi

  # Add GraphRAG-specific environment variables
  if [[ "$template_type" == "graphrag" ]] || [[ "$template_type" == "graph-builder" ]]; then
    cat <<EOF
      - NLTK_DATA=/app/data/nltk
      - HF_HOME=/app/data/hf_cache
EOF
  fi

  # Add Graphiti-specific environment variables
  if [[ "$template_type" == "graphiti" ]]; then
    cat <<EOF
      - NEO4J_URI=\${NEO4J_URI:-bolt://neo4j:7687}
      - NEO4J_USER=\${NEO4J_USER:-neo4j}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD}
      - OPENAI_API_KEY=\${OPENAI_API_KEY}
      - GRAPHITI_DATABASE=\${GRAPHITI_DATABASE:-neo4j}
      - GRAPH_DRIVER_TYPE=falkordb
      - FALKORDB_HOST=falkordb
      - FALKORDB_PORT=6379
EOF
  fi

  # Auto-detect volume mode by template type
  # Pre-built images: named data volume only (host mount would overwrite container code)
  # Named volumes: database-like services need persistent storage in specific paths
  # Host mount: development services (default) - enables live reload
  
  local volume_mode="host"  # Default for development services
  
  case "$template_type" in
    # Pre-built AI service images - NO host /app mount
    graphrag|graph-builder)
      volume_mode="prebuilt"
      ;;
    falkordb)
      # FalkorDB is a database service using prebuilt image
      image="falkordb/falkordb:latest"
      volume_mode="prebuilt"
      restart="always"
      ;;
    graphiti)
      # Build from source, but treat as prebuilt (no code mount)
      volume_mode="prebuilt"
      ;;
    # Database-like services with specific volume paths
    neo4j|redis-stack)
      volume_mode="named"
      ;;
  esac

  # Add volumes based on detected mode
  case "$volume_mode" in
    prebuilt)
      # Pre-built: only mount a data directory for persistence
      cat <<EOF
    volumes:
      - ${service_name}_data:/app/data
EOF
      ;;
    named)
      # Neo4j and similar - specific paths
      if [[ "$template_type" == "neo4j" ]]; then
        cat <<EOF
    volumes:
      - ./.volumes/${service_name}/data:/data
      - ./.volumes/${service_name}/logs:/logs
      - ./.volumes/${service_name}/import:/var/lib/neo4j/import
      - ./.volumes/${service_name}/plugins:/plugins
EOF
      fi
      ;;
    host|*)
      # Standard development volumes with code mounting
      cat <<EOF
    volumes:
      - ./services/${service_name}:/app
EOF
      # Add language-specific volume exclusions
      case "$template_type" in
        *js|*ts|node*|express*|nest*|fastify*|hono*|bullmq*|bun|deno)
          echo "      - /app/node_modules"
          ;;
        py*|fastapi|django*|flask|celery)
          echo "      - /app/.venv"
          echo "      - /app/__pycache__"
          ;;
        go|grpc|gin|echo|fiber)
          echo "      - /app/vendor"
          ;;
        java*|spring*|kotlin*|ktor)
          echo "      - /app/target"
          echo "      - /app/.gradle"
          ;;
        rust*|actix*)
          echo "      - /app/target"
          echo "      - /app/Cargo.lock"
          ;;
        php*|laravel)
          echo "      - /app/vendor"
          ;;
        ruby*|rails|sinatra)
          echo "      - /app/vendor"
          ;;
      esac
      ;;
  esac

  # Add resource limits if specified (smart defaults)
  local memory_var="CS_${index}_MEMORY"
  local cpu_var="CS_${index}_CPU"
  local replicas_var="CS_${index}_REPLICAS"

  # Only add deploy section if any resource constraints are specified
  if [[ -n "${!memory_var:-}" ]] || [[ -n "${!cpu_var:-}" ]] || [[ -n "${!replicas_var:-}" ]]; then
    cat <<EOF
    deploy:
      resources:
        limits:
          memory: \${${memory_var}:-512M}
          cpus: '\${${cpu_var}:-0.5}'
      replicas: \${${replicas_var}:-1}
EOF
  fi

  # Add dependencies (Postgres/Redis)
  cat <<EOF
    depends_on:
      - postgres
      - redis
EOF

  if [[ "${HASURA_ENABLED:-false}" == "true" ]]; then
     echo "      - hasura"
  fi

  # Add healthcheck if port is exposed
  if [[ -n "$service_port" && "$service_port" != "0" ]]; then
    # Use appropriate health check based on template type
    case "$template_type" in
      *go*|*grpc*|*rust*)
        # These containers might not have curl, use a simple TCP check
        cat <<EOF
    healthcheck:
      test: ["CMD", "/bin/sh", "-c", "nc -z localhost ${service_port} || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
        ;;
      neo4j)
        # Neo4j specific healthcheck
        cat <<EOF
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10
      start_period: 60s
EOF
        ;;
      *llamaindex*)
        # LlamaIndex uses /healthz
        cat <<EOF
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${service_port}/healthz"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
        ;;
      graphiti)
        # Graphiti uses /healthcheck
        cat <<EOF
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${service_port}/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
        ;;
      falkordb)
        # FalkorDB Healthcheck (Redis Protocol)
        cat <<EOF
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
        ;;
      *)
        # Most other containers should have curl or wget
        cat <<EOF
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${service_port}/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s
EOF
        ;;
    esac
  fi
}

# Generate all template-based custom services
generate_template_custom_services() {
  local services_found=false

  # Check for CS_ variables (format: service_name:template_type:port)
  for i in {1..20}; do
    local cs_var="CS_${i}"
    local cs_value="${!cs_var:-}"

    # Fallback to CUSTOM_SERVICE_N
    if [[ -z "$cs_value" ]]; then
      local custom_service_var="CUSTOM_SERVICE_${i}"
      cs_value="${!custom_service_var:-}"
    fi

    [[ -z "$cs_value" ]] && continue

    # Parse CS_ format: service_name:template_type:port
    IFS=':' read -r service_name template_type port <<< "$cs_value"

    # Skip if essential fields are missing
    [[ -z "$service_name" || -z "$template_type" ]] && continue

    if [[ "$services_found" == "false" ]]; then
      echo ""
      echo "  # ============================================"
      echo "  # Custom Services (from templates)"
      echo "  # ============================================"
      services_found=true
    fi

    generate_template_based_service "$i" "$service_name" "$template_type" "${port:-8000}"
  done
}

# Export functions
export -f generate_template_based_service
export -f generate_template_custom_services