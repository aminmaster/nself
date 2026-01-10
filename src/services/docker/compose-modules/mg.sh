# mg.sh - Memory Graph Stack Module (FalkorDB + Graphiti)

generate_mg_stack() {
  local service_name="mg"
  local graphiti_dir="./services/mg/graphiti"
  
  # Clone Graphiti source code if missing
  if [[ ! -d "$graphiti_dir" ]]; then
    echo "Cloning Graphiti source code..." >&2
    mkdir -p "$(dirname "$graphiti_dir")"
    git clone https://github.com/getzep/graphiti.git "$graphiti_dir" >&2
  fi

  # URL encode the password for safety in URLs
  local raw_pass="${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}"
  local encoded_pass="$raw_pass"
  if command -v python3 >/dev/null 2>&1; then
    encoded_pass=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$raw_pass")
  fi

  cat <<EOF

  # Memory Graph Stack
  mg-falkordb:
    image: falkordb/falkordb:latest
    container_name: \${PROJECT_NAME}_mg_falkordb
    restart: unless-stopped
    command: ["redis-server", "--loadmodule", "/var/lib/falkordb/bin/falkordb.so", "--requirepass", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}"]
    volumes:
      - mg_falkordb_data:/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}", "ping"]
      interval: 30s
      timeout: 10s
      retries: 5

  mg-graphiti:
    build:
      context: ${graphiti_dir}
    image: \${PROJECT_NAME}_mg_graphiti:latest
    pull_policy: build
    container_name: \${PROJECT_NAME}_mg_graphiti
    restart: unless-stopped
    environment:
      NEO4J_URI: bolt://kg-neo4j:7687
      NEO4J_USER: neo4j
      NEO4J_PASSWORD: \${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      FALKORDB_HOST: mg-falkordb
      FALKORDB_PASSWORD: \${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      OPENAI_API_KEY: \${OPENAI_API_KEY}
    depends_on:
      mg-falkordb:
        condition: service_healthy
      kg-neo4j:
        condition: service_healthy
    volumes:
      - mg_graphiti_data:/app/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/healthcheck"]
      interval: 30s
      timeout: 10s
      retries: 5

  mg-falkordb-browser:
    image: falkordb/falkordb-browser:latest
    container_name: ${PROJECT_NAME}_mg_falkordb_browser
    restart: unless-stopped
    environment:
      FALKORDB_HOST: mg-falkordb
      FALKORDB_PORT: 6379
      FALKORDB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      # Pre-populate connection for UI if supported (image specific)
      REDIS_URL: redis://:${encoded_pass}@mg-falkordb:6379
      FALKORDB_URL: falkor://:${encoded_pass}@mg-falkordb:6379
      NEXTAUTH_URL: https://${FALKORDB_ROUTE:-falkordb}.${BASE_DOMAIN}
      NEXTAUTH_SECRET: ${AUTH_JWT_SECRET:-equilibria_secret_key}
      NEXTAUTH_URL_INTERNAL: http://localhost:3000
    depends_on:
      mg-falkordb:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}

EOF
}

export -f generate_mg_stack
