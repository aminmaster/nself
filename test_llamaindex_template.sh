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
echo "Testing generation of llamaindex service..."
# Simulate CUSTOM_SERVICE_1=rag:llamaindex:8001
export CS_1="rag:llamaindex:8001"

# Create services directory
mkdir -p services

# Run generation
generate_custom_services "true"

# Verify directory creation
if [[ -d "services/rag" ]]; then
  echo "SUCCESS: services/rag directory created"
else
  echo "FAILURE: services/rag directory NOT created"
  exit 1
fi

# Verify file content
if [[ -f "services/rag/main.py" ]]; then
  echo "SUCCESS: services/rag/main.py created"
  if grep -q "llama_index" "services/rag/main.py"; then
    echo "SUCCESS: content looks correct"
  else
    echo "FAILURE: content incorrect"
    cat "services/rag/main.py"
    exit 1
  fi
else
  echo "FAILURE: services/rag/main.py NOT created"
  exit 1
fi

# Verify Dockerfile
if [[ -f "services/rag/Dockerfile" ]]; then
  echo "SUCCESS: services/rag/Dockerfile created"
else
  echo "FAILURE: services/rag/Dockerfile NOT created"
  exit 1
fi

# Test docker-compose inclusion
echo "Testing docker-compose inclusion..."
add_custom_services "$COMPOSE_FILE"

if grep -q "rag:" "$COMPOSE_FILE"; then
  echo "SUCCESS: Service added to docker-compose.yml"
else
  echo "FAILURE: Service NOT added to docker-compose.yml"
  cat "$COMPOSE_FILE"
  exit 1
fi

# Cleanup
rm -rf services/rag "$COMPOSE_FILE"
echo "All tests passed!"
