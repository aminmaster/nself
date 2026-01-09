# kg.sh - Knowledge Graph Stack Module (Neo4j)

generate_kg_stack() {
  local service_name="kg"
  local kg_builder_dir="./services/kg/llm-graph-builder"
  
  # Clone the Neo4j LLM Graph Builder repo if missing
  if [[ ! -d "$kg_builder_dir" ]]; then
    echo "Cloning Neo4j LLM Graph Builder source..." >&2
    mkdir -p "$(dirname "$kg_builder_dir")"
    git clone https://github.com/neo4j-labs/llm-graph-builder.git "$kg_builder_dir" >&2
  fi

  # Patch the Dockerfile to increase network timeout for unstable connections
  if [[ -f "$kg_builder_dir/frontend/Dockerfile" ]]; then
    if ! grep -q "network-timeout" "$kg_builder_dir/frontend/Dockerfile"; then
       echo "Patching KG Builder Dockerfile for network stability..." >&2
       sed -i 's/yarn install/yarn install --network-timeout 1000000/' "$kg_builder_dir/frontend/Dockerfile"
    fi
  fi

  cat <<EOF

  # Knowledge Graph Stack
  kg-neo4j:
    image: neo4j:5.26
    container_name: \${PROJECT_NAME}_kg_neo4j
    restart: unless-stopped
    environment:
      NEO4J_AUTH: neo4j/\${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      NEO4J_server_memory_pagecache_size: 1G
      NEO4J_server_memory_heap_max__size: 2G
      NEO4J_PLUGINS: '["apoc"]'
      NEO4J_dbms_security_procedures_unrestricted: 'apoc.*'
      NEO4J_dbms_security_procedures_allowlist: 'apoc.*'
      NEO4J_apoc_import_file_enabled: 'true'
      NEO4J_apoc_export_file_enabled: 'true'
    volumes:
      - kg_neo4j_data:/data
      - kg_neo4j_logs:/logs
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "wget --no-verbose --tries=1 --spider http://localhost:7474/browser/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 10

  kg-builder-backend:
    build:
      context: ${kg_builder_dir}/backend
      dockerfile: Dockerfile
    image: \${PROJECT_NAME}_kg_builder_backend:latest
    pull_policy: build
    container_name: \${PROJECT_NAME}_kg_builder_backend
    restart: unless-stopped
    # ports:
    #   - "${KG_BACKEND_PORT:-8001}:8000"
    environment:
      NEO4J_URI: bolt://kg-neo4j:7687
      NEO4J_USERNAME: neo4j
      NEO4J_PASSWORD: \${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      ANTHROPIC_API_KEY: \${ANTHROPIC_API_KEY}
      OPENAI_API_KEY: \${OPENAI_API_KEY}
      MODEL: \${KG_EXTRACTOR_MODEL:-anthropic/claude-sonnet-4.5}
    depends_on:
      kg-neo4j:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
      interval: 30s
      timeout: 10s
      retries: 5

  kg-builder-frontend:
    build:
      context: ${kg_builder_dir}/frontend
      dockerfile: Dockerfile
      args:
        - VITE_BACKEND_API_URL=https://${KG_ROUTE:-kg}.${BASE_DOMAIN}/api
        - VITE_LLM_MODELS_PROD=openai_gpt_4o,openai_gpt_4o_mini,diffbot,gemini_1.5_flash
        - VITE_CHAT_MODES=vector,graph_vector,graph,fulltext,entity_vector,global_vector
        - VITE_ENV=PROD
    image: \${PROJECT_NAME}_kg_builder_frontend:latest
    pull_policy: build
    container_name: \${PROJECT_NAME}_kg_builder_frontend
    restart: unless-stopped
    # ports:
    #   - "${KG_FRONTEND_PORT:-8000}:8080"
    depends_on:
      - kg-builder-backend
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/"]
      interval: 30s
      timeout: 10s
      retries: 5

EOF
}

export -f generate_kg_stack
