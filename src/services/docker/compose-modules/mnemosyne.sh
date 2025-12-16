# mnemosyne.sh - Mnemosyne Memory & Context Engine
# Defines the new Memory Engine service replacing the legacy backend

echo "Generating Mnemosyne Memory Service config..."

cat >>docker-compose.yml <<EOF

  # Mnemosyne (Memory Service)
  mnemosyne:
    build:
      context: ./services/mnemosyne
      dockerfile: Dockerfile
    container_name: equilibria_mnemosyne
    restart: unless-stopped
    ports:
      - "8090:8090"
    environment:
      - PORT=8090
      - ENVIRONMENT=\${ENVIRONMENT}
      - NEO4J_URI=\${NEO4J_URI:-bolt://neo4j:7687}
      - NEO4J_USERNAME=\${NEO4J_USERNAME:-neo4j}
      - NEO4J_PASSWORD=\${NEO4J_PASSWORD}
      - OPENAI_API_KEY=\${OPENAI_API_KEY}
      - DATABASE_URL=\${DATABASE_URL}
      - REDIS_URL=\${REDIS_URL:-redis://redis:6379/0}
      - LOG_LEVEL=\${LOG_LEVEL:-info}
    depends_on:
      - neo4j
      - postgres
      - redis
    networks:
      - \${DOCKER_NETWORK}
    volumes:
      # Mount source from the project service directory
      - ./services/mnemosyne:/app
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

EOF
