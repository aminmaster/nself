#!/usr/bin/env bash
# setup-ssl.sh - Automate Let's Encrypt SSL setup using Certbot
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source utilities
source "$PROJECT_ROOT/src/lib/utils/display.sh"
source "$PROJECT_ROOT/src/lib/utils/env.sh"

# Load environment
load_env_with_priority

# Set derived variables required by docker-compose.yml
export DOCKER_NETWORK="${PROJECT_NAME:-myproject}_network"
# Dummy values for variables that might be required by compose validation but not used by certbot
export DATABASE_URL="${DATABASE_URL:-postgres://user:pass@localhost:5432/db}"
export REDIS_URL="${REDIS_URL:-redis://localhost:6379}"

# Check if SSL provider is Let's Encrypt
if [[ "${SSL_PROVIDER:-selfsigned}" != "letsencrypt" ]]; then
  log_warning "SSL_PROVIDER is not set to 'letsencrypt'. Skipping Certbot setup."
  exit 0
fi

BASE_DOMAIN="${BASE_DOMAIN:-localhost}"
EMAIL="${LETSENCRYPT_EMAIL:-admin@${BASE_DOMAIN}}"
STAGING="${LETSENCRYPT_ENV:-staging}"
DNS_PROVIDER="${DNS_PROVIDER:-cloudflare}"
DNS_TOKEN="${DNS_API_TOKEN:-}"

if [[ -z "$DNS_TOKEN" ]]; then
  log_error "DNS_API_TOKEN is missing. Cannot use DNS challenge."
  exit 1
fi

# Prepare Cloudflare credentials
# Prepare Cloudflare credentials
CREDENTIALS_DIR="ssl/credentials"
mkdir -p "$CREDENTIALS_DIR"

# Write credentials file (handle permissions)
if [[ -w "$CREDENTIALS_DIR" ]]; then
  cat > "$CREDENTIALS_DIR/cloudflare.ini" <<EOF
dns_cloudflare_api_token = $DNS_TOKEN
EOF
  chmod 600 "$CREDENTIALS_DIR/cloudflare.ini"
else
  # Use sudo if directory is not writable (e.g. owned by root)
  echo "dns_cloudflare_api_token = $DNS_TOKEN" | sudo tee "$CREDENTIALS_DIR/cloudflare.ini" >/dev/null
  sudo chmod 600 "$CREDENTIALS_DIR/cloudflare.ini"
fi

log_info "Requesting wildcard certificate for: *.${BASE_DOMAIN} and ${BASE_DOMAIN}"

# Construct Certbot command for DNS challenge
CERTBOT_CMD="certbot certonly --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/credentials/cloudflare.ini \
  --dns-cloudflare-propagation-seconds 30 \
  --email $EMAIL --agree-tos --no-eff-email \
  --non-interactive --expand \
  -d *.${BASE_DOMAIN} -d ${BASE_DOMAIN}"

if [[ "$STAGING" == "staging" ]]; then
  CERTBOT_CMD+=" --staging"
fi

# Run Certbot via Docker
log_info "Running Certbot (DNS Challenge)..."
docker compose run --rm --entrypoint "" certbot $CERTBOT_CMD

# Check if successful
if [[ $? -eq 0 ]]; then
  log_success "Wildcard certificate obtained successfully!"
  
  # Copy certificates to Nginx SSL directory
  log_info "Installing certificates..."
  
  docker compose run --rm --entrypoint "" certbot sh -c "
    mkdir -p /etc/nginx/ssl/${BASE_DOMAIN} && \
    cp -L /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem /etc/nginx/ssl/${BASE_DOMAIN}/fullchain.pem && \
    cp -L /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem /etc/nginx/ssl/${BASE_DOMAIN}/privkey.pem && \
    chmod 644 /etc/nginx/ssl/${BASE_DOMAIN}/fullchain.pem && \
    chmod 600 /etc/nginx/ssl/${BASE_DOMAIN}/privkey.pem
  "
  
  log_success "Certificates installed."
  
  # Reload Nginx
  log_info "Reloading Nginx..."
  docker compose exec nginx nginx -s reload
  
  log_success "SSL setup complete!"
else
  log_error "Certbot failed to obtain certificates."
  exit 1
fi
