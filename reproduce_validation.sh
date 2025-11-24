#!/bin/bash

# Mock prompt_input from prompts.sh
prompt_input() {
  local prompt="$1"
  local default="$2"
  local result_var="$3"
  local pattern="${4:-.*}"
  
  # Simulate input "backend"
  local input="backend"
  
  echo "Testing pattern: '$pattern' against input: '$input'"
  
  if echo "$input" | grep -q "$pattern"; then
    echo "MATCH"
  else
    echo "NO MATCH"
  fi
}

# Test with the pattern from wizard-core.sh
prompt_input "Service name" "default" res "^[a-z][a-z0-9_-]*$"

# Test with a simpler pattern to debug
prompt_input "Service name" "default" res "^[a-z].*$"
