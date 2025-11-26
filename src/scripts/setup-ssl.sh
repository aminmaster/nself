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

# Check if SSL provider is Let's Encrypt
if [[ "${SSL_PROVIDER:-selfsigned}" != "letsencrypt" ]]; then
  show_warning "SSL_PROVIDER is not set to 'letsencrypt'. Skipping Certbot setup."
  exit 0
fi

BASE_DOMAIN="${BASE_DOMAIN:-localhost}"
EMAIL="${LETSENCRYPT_EMAIL:-admin@${BASE_DOMAIN}}"
STAGING="${LETSENCRYPT_ENV:-staging}"

# Build domain list
DOMAINS="-d ${BASE_DOMAIN} -d www.${BASE_DOMAIN}"

# Add required service subdomains
[[ "${HASURA_ENABLED:-true}" == "true" ]] && DOMAINS+=" -d ${HASURA_ROUTE:-api}.${BASE_DOMAIN}"
[[ "${AUTH_ENABLED:-true}" == "true" ]] && DOMAINS+=" -d ${AUTH_ROUTE:-auth}.${BASE_DOMAIN}"

# Add optional service subdomains
[[ "${MINIO_ENABLED:-false}" == "true" ]] && DOMAINS+=" -d ${MINIO_ROUTE:-minio}.${BASE_DOMAIN} -d ${MINIO_CONSOLE_ROUTE:-console}.${BASE_DOMAIN}"
[[ "${NSELF_ADMIN_ENABLED:-false}" == "true" ]] && DOMAINS+=" -d ${NSELF_ADMIN_ROUTE:-admin}.${BASE_DOMAIN}"
[[ "${GRAFANA_ENABLED:-false}" == "true" ]] && DOMAINS+=" -d ${GRAFANA_ROUTE:-grafana}.${BASE_DOMAIN}"
[[ "${PROMETHEUS_ENABLED:-false}" == "true" ]] && DOMAINS+=" -d ${PROMETHEUS_ROUTE:-prometheus}.${BASE_DOMAIN}"

# Add custom service subdomains
for i in {1..10}; do
  cs_var="CS_${i}"
  if [[ -n "${!cs_var:-}" ]]; then
    # Parse custom service
    IFS=':' read -r name template port <<< "${!cs_var}"
    route_var="CS_${i}_ROUTE"
    route="${!route_var:-$name}"
    DOMAINS+=" -d ${route}.${BASE_DOMAIN}"
  fi
done

# Add frontend app subdomains
frontend_count="${FRONTEND_APP_COUNT:-0}"
for i in $(seq 1 $frontend_count); do
  name_var="FRONTEND_APP_${i}_NAME"
  name="${!name_var:-}"
  route_var="FRONTEND_APP_${i}_ROUTE"
  route="${!route_var:-$name}"
  
  if [[ -n "$name" ]]; then
    DOMAINS+=" -d ${route}.${BASE_DOMAIN}"
  fi
done

show_info "Requesting certificates for: $DOMAINS"

# Construct Certbot command
CERTBOT_CMD="certbot certonly --webroot --webroot-path /var/www/certbot \
  --email $EMAIL --agree-tos --no-eff-email \
  --non-interactive --expand \
  $DOMAINS"

if [[ "$STAGING" == "staging" ]]; then
  CERTBOT_CMD+=" --staging"
fi

# Run Certbot via Docker
show_step "Running Certbot..."
docker compose run --rm --entrypoint "" certbot $CERTBOT_CMD

# Check if successful
if [[ $? -eq 0 ]]; then
  show_success "Certificates obtained successfully!"
  
  # Copy certificates to Nginx SSL directory
  # Certbot saves to /etc/letsencrypt/live/$BASE_DOMAIN/
  # We need to copy them to /etc/nginx/ssl/$BASE_DOMAIN/ (mapped to ./nginx/ssl/$BASE_DOMAIN on host)
  
  show_step "Installing certificates..."
  
  # We use a temporary container to copy files because of permissions/volumes
  docker compose run --rm --entrypoint "" certbot sh -c "
    mkdir -p /etc/nginx/ssl/${BASE_DOMAIN} && \
    cp -L /etc/letsencrypt/live/${BASE_DOMAIN}/fullchain.pem /etc/nginx/ssl/${BASE_DOMAIN}/fullchain.pem && \
    cp -L /etc/letsencrypt/live/${BASE_DOMAIN}/privkey.pem /etc/nginx/ssl/${BASE_DOMAIN}/privkey.pem && \
    chmod 644 /etc/nginx/ssl/${BASE_DOMAIN}/fullchain.pem && \
    chmod 600 /etc/nginx/ssl/${BASE_DOMAIN}/privkey.pem
  "
  
  show_success "Certificates installed."
  
  # Reload Nginx
  show_step "Reloading Nginx..."
  docker compose exec nginx nginx -s reload
  
  show_success "SSL setup complete!"
else
  show_error "Certbot failed to obtain certificates."
  exit 1
fi
