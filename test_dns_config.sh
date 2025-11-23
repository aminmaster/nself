#!/bin/bash
set -euo pipefail

# Mock wizard environment
source src/lib/utils/display.sh
source src/lib/init/wizard/prompts.sh
source src/lib/init/wizard/steps/core-settings.sh

# Mock user input
# Sequence:
# 1. Project name (default)
# 2. Environment (1 = prod)
# 3. Domain (default)
# 4. SSL Provider (0 = letsencrypt)
# 5. Let's Encrypt Env (0 = staging)
# 6. Email (default)
# 7. DNS Provider (0 = cloudflare)
# 8. CF Token
# 9. CF Email
input_sequence=(
  ""          # Project name
  "2"         # Prod environment (select_option uses 1-based index, so 2 is prod)
  ""          # Domain
  "1"         # SSL Provider (1 = letsencrypt)
  "1"         # LE Env (1 = staging)
  ""          # Email
  "1"         # DNS Provider (1 = cloudflare)
  "my-cf-token" # CF Token
  ""          # CF Email
)

# Function to feed input
input_feeder() {
  for input in "${input_sequence[@]}"; do
    echo "Feeding: '$input'" >&2
    echo "$input"
    sleep 0.2
  done
}

# Run the wizard step
echo "Running wizard test..."
config=()
wizard_core_settings config < <(input_feeder)

# Verify results
echo "Verifying configuration..."
found_dns=false
found_token=false
found_le_env=false

for item in "${config[@]}"; do
  echo "Config: $item"
  if [[ "$item" == "DNS_PROVIDER=cloudflare" ]]; then found_dns=true; fi
  if [[ "$item" == "DNS_API_TOKEN=my-cf-token" ]]; then found_token=true; fi
  if [[ "$item" == "LETSENCRYPT_ENV=staging" ]]; then found_le_env=true; fi
done

if [[ "$found_dns" == "true" ]] && [[ "$found_token" == "true" ]] && [[ "$found_le_env" == "true" ]]; then
  echo "SUCCESS: DNS configuration verified!"
else
  echo "FAILURE: Missing configuration items"
  exit 1
fi
