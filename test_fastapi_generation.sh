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
COMPOSE_FILE="test_docker_compose_fastapi.yml"
touch "$COMPOSE_FILE"

# Test generation
echo "Testing generation of fastapi service..."
# Simulate CUSTOM_SERVICE_1=api:fastapi:8002
export CS_1="api:fastapi:8002"

# Create services directory
mkdir -p services

# Run generation
generate_custom_services "true"

# Verify directory creation
if [[ -d "services/api" ]]; then
  echo "SUCCESS: services/api directory created"
else
  echo "FAILURE: services/api directory NOT created"
  exit 1
fi

# Test docker-compose inclusion
echo "Testing docker-compose inclusion..."
add_custom_services "$COMPOSE_FILE"

if grep -q "api:" "$COMPOSE_FILE"; then
  echo "SUCCESS: Service added to docker-compose.yml"
else
  echo "FAILURE: Service NOT added to docker-compose.yml"
  cat "$COMPOSE_FILE"
  exit 1
fi

# Cleanup
rm -rf services/api "$COMPOSE_FILE"
echo "All tests passed!"
