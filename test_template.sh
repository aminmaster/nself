#!/bin/bash
set -euo pipefail

# Mock environment
PROJECT_NAME="testproj"
NSELF_ROOT=$(pwd)
export PROJECT_NAME NSELF_ROOT

# Source scripts
source src/lib/build/services.sh
source src/lib/build/docker-compose.sh

# Mock output file
COMPOSE_FILE="test_docker_compose.yml"
touch "$COMPOSE_FILE"

# Test generation
echo "Testing generation of neo4j service..."
# Simulate CUSTOM_SERVICE_1=graph:neo4j:7474
export CS_1="graph:neo4j:7474"

# Create services directory
mkdir -p services

# Run generation
generate_custom_services "true"

# Verify directory creation
if [[ -d "services/graph" ]]; then
  echo "SUCCESS: services/graph directory created"
else
  echo "FAILURE: services/graph directory NOT created"
  exit 1
fi

# Verify file content
if [[ -f "services/graph/service.yml" ]]; then
  echo "SUCCESS: services/graph/service.yml created"
  if grep -q "image: neo4j" "services/graph/service.yml"; then
    echo "SUCCESS: content looks correct"
  else
    echo "FAILURE: content incorrect"
    cat "services/graph/service.yml"
    exit 1
  fi
else
  echo "FAILURE: services/graph/service.yml NOT created"
  exit 1
fi

# Test docker-compose inclusion
echo "Testing docker-compose inclusion..."
add_custom_services "$COMPOSE_FILE"

if grep -q "graph:" "$COMPOSE_FILE"; then
  echo "SUCCESS: Service added to docker-compose.yml"
else
  echo "FAILURE: Service NOT added to docker-compose.yml"
  cat "$COMPOSE_FILE"
  exit 1
fi

# Cleanup
rm -rf services/graph "$COMPOSE_FILE"
echo "All tests passed!"
