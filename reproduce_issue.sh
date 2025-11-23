#!/bin/bash
set -euo pipefail

# Mock configuration array
config=("PROJECT_NAME=equilibriaorg" "HASURA_ENABLED=true")

# Function mimicking the buggy logic in wizard-core.sh
buggy_function() {
  local config_array_name="$1"
  echo "Iterating over $config_array_name..."
  
  # This is the buggy line from wizard-core.sh:108
  # for item in "${!config_array_name}[@]"; do
  
  # To reproduce exactly how bash expands this:
  # If config_array_name is "config", ${!config_array_name} expands to "config"
  # So it becomes: for item in config[@]; do ...
  
  # However, the actual code in the file is:
  # for item in "${!config_array_name}[@]"; do
  #   eval "local cfg_item=\${${config_array_name}[$item]}"
  
  # Let's try to reproduce the exact failure mode
  # The error "equilibriaorg: unbound variable" suggests that 'equilibriaorg' is being evaluated as a variable name.
  
  # Let's simulate the exact loop structure from the file
  
  # We need to pass the NAME of the array, not the array itself
  local array_name="$1"
  
  # This is the problematic loop structure found in the file
  # Note: In the file it is: for item in "${!config_array_name}[@]"; do
  # But wait, ${!var} is indirect expansion. 
  # If var="config", ${!var} -> config.
  # So "${!var}[@]" -> "config[@]"
  # So the loop is: for item in "config[@]"
  # This iterates ONCE with item="config[@]"
  
  # BUT, if the user sees "equilibriaorg: unbound variable", it implies something is trying to access $equilibriaorg
  
  # Let's look at line 109: eval "local cfg_item=\${${config_array_name}[$item]}"
  # If item="config[@]", then this becomes: local cfg_item=${config[config[@]]}
  # This looks weird.
  
  # Let's try to reproduce the exact error message.
  
  # The actual code in the file might be slightly different than my mental model or there's a bash version nuance.
  # Let's just copy the function body logic exactly.
  
  eval "local config_values=(\"\${${config_array_name}[@]}\")"
  for cfg_item in "${config_values[@]}"; do
     echo "Value: $cfg_item"
  done
}

echo "Running reproduction..."
buggy_function config
