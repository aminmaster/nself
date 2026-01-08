# kg.sh - Knowledge Graph Stack Module (Neo4j)

generate_kg_stack() {
  local service_name="kg"
  
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

  kg-builder:
    image: neo4j/llm-graph-builder:latest
    container_name: \${PROJECT_NAME}_kg_builder
    restart: unless-stopped
    ports:
      - "8000:8000" # Frontend/API
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

EOF
}

export -f generate_kg_stack
