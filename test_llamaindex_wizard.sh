#!/bin/bash
set -euo pipefail

# Mock wizard environment
source src/lib/utils/display.sh
source src/lib/init/wizard/prompts.sh
source src/lib/init/wizard/wizard-core.sh

# Mock confirm_action
confirm_action() {
  local prompt="$1"
  # Read from input stream
  read response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Mock user input
# Sequence:
# 1. Add custom services? (y)
# 2. Service name (default)
# 3. Service type (6 = llamaindex)
# 4. Service port (default 8001)
# 5. Add another? (n)
input_sequence=(
  "y"         # Add custom services
  ""          # Service name
  "6"         # Service type (llamaindex)
  "8001"      # Port
  "n"         # Add another
)

# Function to feed input
input_feeder() {
  for input in "${input_sequence[@]}"; do
    echo "$input"
    sleep 0.2
  done
}

# Run the wizard step
echo "Running wizard test..."
config=()
wizard_custom_services config < <(input_feeder)

# Verify results
echo "Verifying configuration..."
found_llamaindex=false

for item in "${config[@]}"; do
  echo "Config: $item"
  # Expect: CUSTOM_SERVICE_1=service-1:llamaindex:8001
  if [[ "$item" =~ CUSTOM_SERVICE_1=.*:llamaindex:.* ]]; then
    found_llamaindex=true
  fi
done

if [[ "$found_llamaindex" == "true" ]]; then
  echo "SUCCESS: LlamaIndex configuration verified!"
else
  echo "FAILURE: LlamaIndex configuration NOT found"
  exit 1
fi
