# zep.sh - Hippocampus (Zep) Service Module
# Defines the new Memory Engine service replacing the legacy backend

echo "Generating Hippocampus (Zep) service config..."

cat >>docker-compose.yml <<EOF

  hippocampus:
    build:
      context: ../zep/hippocampus
      dockerfile: Dockerfile
    container_name: equilibria_hippocampus
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
      # Log level
      - LOG_LEVEL=\${LOG_LEVEL:-info}
    depends_on:
      - neo4j
      - postgres
      - redis
    networks:
      - \${DOCKER_NETWORK}
    volumes:
      # Mount source code for development
      - ../zep/hippocampus:/app
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

EOF
