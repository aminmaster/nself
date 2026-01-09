#!/usr/bin/env bash
# nginx-generator.sh - Generate nginx configs with runtime env var substitution
# Uses nginx envsubst or template variables for runtime configuration

# Generate main nginx configuration
generate_nginx_config() {
  local force="${1:-false}"

  # Cleanup existing configuration to prevent stale routes
  rm -rf nginx/sites/*.conf nginx/conf.d/*.conf 2>/dev/null || true
  mkdir -p nginx/{sites,conf.d,includes,routes,streams} 2>/dev/null || true

  # Generate main nginx.conf
  generate_main_nginx_conf

  # Generate default server block
  generate_default_server

  # Generate service routes
  generate_service_routes

  # Generate frontend app routes
  generate_frontend_routes

  # Generate custom service routes
  generate_custom_routes

  # Generate stream routes
  generate_stream_routes
}

# Generate main nginx.conf
generate_main_nginx_conf() {
  cat > nginx/nginx.conf <<'EOF'
user nginx;
worker_processes auto;
pid /var/run/nginx.pid;

events {
    worker_connections 2048;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Performance
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_names_hash_bucket_size 128;
    server_tokens off;
    client_max_body_size 100M;

    # SSL Configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Gzip
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml text/javascript
               application/json application/javascript application/xml+rss
               application/rss+xml application/atom+xml image/svg+xml
               text/x-js text/x-cross-domain-policy application/x-font-ttf
               application/x-font-opentype application/vnd.ms-fontobject
               image/x-icon;

    # Logging
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;
    error_log /var/log/nginx/error.log warn;

    # Rate limiting
    limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
    limit_req_zone $binary_remote_addr zone=api:10m rate=100r/s;

    # WebSocket connection upgrade mapping
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    # Resolver for Docker DNS
    resolver 127.0.0.11 valid=30s;

    # Include all configurations
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites/*.conf;
}



# Stream configuration for TCP/UDP proxies (e.g. Neo4j Bolt)
stream {
    log_format basic '$remote_addr [$time_local] '
                     '$protocol $status $bytes_sent $bytes_received '
                     '$session_time';
    access_log /var/log/nginx/stream.log basic;

    include /etc/nginx/streams/*.conf;
}
EOF
}

# Generate stream configurations for custom services
generate_stream_routes() {
  local services_found=false

  # Check for CS_ variables (format: service_name:template_type:port)
  for i in {1..20}; do
    local cs_var="CS_${i}"
    local cs_value="${!cs_var:-}"

    # Fallback to CUSTOM_SERVICE_N
    if [[ -z "$cs_value" ]]; then
      local custom_service_var="CUSTOM_SERVICE_${i}"
      cs_value="${!custom_service_var:-}"
    fi

    [[ -z "$cs_value" ]] && continue

    # Parse CS_ format: service_name:template_type:port
    IFS=':' read -r cs_name template_type cs_port <<< "$cs_value"
    
    # Only generate stream config for Neo4j services or AI-OPS (which has Neo4j)
    if [[ "$template_type" == "neo4j" ]] || [[ "$template_type" == "ai-ops" ]]; then
        # For ai-ops, the service name for Neo4j is likely fixed or aliased, but we use the main service name for the stream file
        if [[ "$template_type" == "ai-ops" ]]; then
           # AI-OPS uses aio-neo4j container
           cs_name="aio-neo4j"
        fi
        if [[ "$services_found" == "false" ]]; then
            echo "Generating Nginx stream routes..."
            mkdir -p nginx/streams
            services_found=true
        fi

        echo "  - Stream Route: ${cs_name} (Bolt 7687)"
        
        cat > "nginx/streams/${cs_name}.conf" <<EOF
# Stream config for ${cs_name} (Bolt)
server {
    listen 7687 ssl;
    proxy_pass ${cs_name}:7687;
    
    ssl_certificate /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/privkey.pem;
    
    ssl_session_cache shared:SSL_STREAM:10m;
    ssl_session_timeout 10m;
}
EOF
    fi
  done
}

# Generate stream configurations for custom services


# Generate default server block
generate_default_server() {
  cat > nginx/conf.d/default.conf <<EOF
# Default server - redirect HTTP to HTTPS
server {
    listen 80 default_server;
    server_name _;

    # ACME challenge for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Default HTTPS server
server {
    listen 443 ssl default_server;
    http2 on;
    server_name ${BASE_DOMAIN:-localhost};

    # SSL certificates - runtime path based on environment
    ssl_certificate /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/privkey.pem;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location / {
EOF

  # Check if containerized frontend is enabled
  if [[ "${FRONTEND_ENABLED:-false}" == "true" ]]; then
    cat >> nginx/conf.d/default.conf <<EOF
        # Proxy to containerized web app
        set \$target_frontend ${PROJECT_NAME}_${PRIMARY_FRONTEND_NAME:-web};
        proxy_pass http://\$target_frontend:${PRIMARY_FRONTEND_PORT:-3000};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
EOF
  elif [[ -n "${PRIMARY_FRONTEND_PORT:-}" ]]; then
    # Fallback: Legacy host-based frontend (for backwards compatibility)
    cat >> nginx/conf.d/default.conf <<EOF
        proxy_pass http://host.docker.internal:${PRIMARY_FRONTEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
EOF
  else
    # No frontend configured - serve default welcome page
    cat >> nginx/conf.d/default.conf <<EOF
        root /usr/share/nginx/html;
        index index.html;
        try_files \$uri \$uri/ /index.html;
EOF
  fi

  cat >> nginx/conf.d/default.conf <<EOF
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }
}
EOF
}

# Generate core service routes (Hasura, Auth, etc.)
generate_service_routes() {
  # Hasura GraphQL API route
  if [[ "${HASURA_ENABLED:-false}" == "true" ]]; then
    local hasura_route="${HASURA_ROUTE:-api}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/hasura.conf <<EOF
# Hasura GraphQL Engine
server {
    listen 443 ssl;
    http2 on;
    server_name ${hasura_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        # CORS Headers - Nginx as the single source of truth
        proxy_hide_header 'Access-Control-Allow-Origin';
        proxy_hide_header 'Access-Control-Allow-Methods';
        proxy_hide_header 'Access-Control-Allow-Headers';
        proxy_hide_header 'Access-Control-Allow-Credentials';

        add_header 'Access-Control-Allow-Origin' '\$http_origin' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;

        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '\$http_origin';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        set \$target_hasura hasura;
        proxy_pass http://\$target_hasura:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support
        proxy_read_timeout 86400;

        # Increase buffer sizes
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }
}
EOF
  fi

  # Auth service route
  if [[ "${AUTH_ENABLED:-false}" == "true" ]]; then
    local auth_route="${AUTH_ROUTE:-auth}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/auth.conf <<EOF
# Authentication Service
server {
    listen 443 ssl;
    http2 on;
    server_name ${auth_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        # CORS Headers - Nginx as the single source of truth
        proxy_hide_header 'Access-Control-Allow-Origin';
        proxy_hide_header 'Access-Control-Allow-Methods';
        proxy_hide_header 'Access-Control-Allow-Headers';
        proxy_hide_header 'Access-Control-Allow-Credentials';

        add_header 'Access-Control-Allow-Origin' '\$http_origin' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;

        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '\$http_origin';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        set \$target_auth auth;
        proxy_pass http://\$target_auth:4000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # Storage/MinIO route
    local storage_console_route="${STORAGE_CONSOLE_ROUTE:-minio}"
    local storage_route="${STORAGE_ROUTE:-storage}"
    local base_domain="${BASE_DOMAIN:-localhost}"

  if [[ "${MINIO_ENABLED:-true}" == "true" ]]; then
    cat > nginx/sites/storage.conf <<EOF
# MinIO Storage Console
server {
    listen 443 ssl;
    http2 on;
    server_name ${storage_console_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_minio_console minio;
        proxy_pass http://\$target_minio_console:9001;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}

# MinIO S3 API
server {
    listen 443 ssl;
    http2 on;
    server_name ${storage_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    client_max_body_size 1000M;

    location / {
        set \$target_minio_s3 minio;
        proxy_pass http://\$target_minio_s3:9000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # Search Service (MeiliSearch)
  if [[ "${MEILISEARCH_ENABLED:-false}" == "true" ]] || [[ "${SEARCH_ENABLED:-false}" == "true" ]]; then
    local search_route="${SEARCH_ROUTE:-search}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/search.conf <<EOF
# MeiliSearch API
server {
    listen 443 ssl;
    http2 on;
    server_name ${search_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    client_max_body_size 100M;

    location / {
        set \$target_meili meilisearch;
        proxy_pass http://\$target_meili:7700;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # Message Queue (RabbitMQ Management)
  if [[ "${RABBITMQ_ENABLED:-false}" == "true" ]]; then
    local rabbitmq_route="${RABBITMQ_ROUTE:-rabbitmq}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/rabbitmq.conf <<EOF
# RabbitMQ Management Console
server {
    listen 443 ssl;
    http2 on;
    server_name ${rabbitmq_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_rabbit rabbitmq;
        proxy_pass http://\$target_rabbit:15672;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # Optional services routes
  generate_optional_service_routes
}

# Generate optional service routes
generate_optional_service_routes() {
  local base_domain="${BASE_DOMAIN:-localhost}"

  # Check if AIO Stack is present globally
  local aio_stack_exists=false
  for i in {1..20}; do
      local cs_var="CUSTOM_SERVICE_${i}"
      local cs_val="${!cs_var:-}"
      if [[ "$cs_val" == *":ai-ops"* ]]; then
          aio_stack_exists=true
          break
      fi
  done

  # 1. Flowise
  if [[ "${FLOWISE_ENABLED:-false}" == "true" ]]; then
    local flowise_route="${FLOWISE_ROUTE:-flowise}"
    cat > nginx/sites/flowise.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${flowise_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_flowise fw-app;
        proxy_pass http://\$target_flowise:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # 2. Knowledge Graph (KG Builder)
  if [[ "${KG_ENABLED:-false}" == "true" ]]; then
    local kg_route="${KG_ROUTE:-kg}"
    cat > nginx/sites/kg.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${kg_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_kg_fe kg-builder-frontend;
        proxy_pass http://\$target_kg_fe:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # API proxy for backend
    location /api/ {
        set \$target_kg_be kg-builder-backend;
        proxy_pass http://\$target_kg_be:8000/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # 3. Langflow (Modular)
  if [[ "${LANGFLOW_ENABLED:-false}" == "true" ]] && [[ "$aio_stack_exists" == "false" ]]; then
    local langflow_route="${LANGFLOW_ROUTE:-langflow}"
    cat > nginx/sites/langflow.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${langflow_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_langflow lf-app;
        proxy_pass http://\$target_langflow:7860;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF
  fi

  # Functions
  if [[ "${FUNCTIONS_ENABLED:-false}" == "true" ]]; then
    local functions_route="${FUNCTIONS_ROUTE:-functions}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/functions.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${functions_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_functions functions;
        proxy_pass http://\$target_functions:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # Admin dashboard
    local admin_route="${ADMIN_ROUTE:-admin}"
    local base_domain="${BASE_DOMAIN:-localhost}"

  if [[ "${NSELF_ADMIN_ENABLED:-false}" == "true" ]]; then
    cat > nginx/sites/admin.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${admin_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_admin nself-admin;
        proxy_pass http://\$target_admin:3021;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi

  # MLflow Model Registry (Standalone - Skip if AIO Stack is present as it has its own)
  if [[ "${MLFLOW_ENABLED:-false}" == "true" && "$aio_stack_exists" == "false" ]]; then
    local mlflow_route="${MLFLOW_ROUTE:-mlflow}"
    local base_domain="${BASE_DOMAIN:-localhost}"
    local auth_config=""

    # Configure Basic Auth if enabled
    if [[ "${MLFLOW_BASIC_AUTH_ENABLED:-true}" == "true" ]]; then
      local auth_user="${MLFLOW_BASIC_AUTH_USER:-${NSELF_ADMIN_USER:-admin}}"
      local auth_pass="${MLFLOW_BASIC_AUTH_PASSWORD:-${NSELF_ADMIN_PASSWORD:-admin}}"
      
      echo "Generating Basic Auth for MLFlow..."
      # Generate htpasswd file
      echo "${auth_user}:$(openssl passwd -apr1 "${auth_pass}")" > nginx/conf.d/mlflow.htpasswd
      
      auth_config="
    auth_basic \"MLflow Protected Area\";
    auth_basic_user_file /etc/nginx/conf.d/mlflow.htpasswd;
"
    fi

    cat > nginx/sites/mlflow.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${mlflow_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        ${auth_config}
        proxy_pass http://ml-app:5000;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  fi

  # Unified AIO (AI Operating System) Stack Integration
  # Check for AIO custom service (ai-ops)
  local aio_subdomain=""
  
  if [[ "${AIO_SUBDOMAIN:-}" ]]; then
     aio_subdomain="${AIO_SUBDOMAIN}"
  fi

  local aio_service_name="ai-ops"
  # Check custom services for type 'ai-ops'
  for i in {1..20}; do
      local cs_var="CUSTOM_SERVICE_${i}"
      local cs_val="${!cs_var:-}"
      if [[ "$cs_val" == *":ai-ops"* ]]; then
          IFS=':' read -r s_name s_type s_port <<< "$cs_val"
          aio_service_name="$s_name"
          # Priority: AIO_SUBDOMAIN > Service Name > "brain"
          if [[ -z "$aio_subdomain" ]]; then
              aio_subdomain="${AIO_SUBDOMAIN:-${aio_service_name:-brain}}"
          fi
          break
      fi
  done

  if [[ -n "$aio_subdomain" ]]; then
    local base_domain="${BASE_DOMAIN:-localhost}"
    
    # 1. RAGFlow Site (Main User Interface)
    cat > nginx/sites/ragflow.conf <<EOF
# RAGFlow Ingestion Engine
server {
    listen 443 ssl;
    http2 on;
    server_name ${aio_subdomain}.${base_domain} ${aio_service_name}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_ragflow aio-ragflow;
        proxy_pass http://\$target_ragflow:80;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

    # 2. Langflow Site (Orchestration Interface)
    cat > nginx/sites/langflow.conf <<EOF
# Langflow Orchestration
server {
    listen 443 ssl;
    http2 on;
    server_name langflow.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_langflow aio-langflow;
        proxy_pass http://\$target_langflow:7860;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
EOF

    # 3. AI OPS Sub-services (Graphiti, Neo4j, MLFlow)
    
    # Graphiti API
    cat > nginx/sites/graphiti.conf <<GRAPHITI_CONF
server {
    listen 443 ssl;
    http2 on;
    server_name graphiti.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        # CORS Headers
        proxy_hide_header 'Access-Control-Allow-Origin';
        proxy_hide_header 'Access-Control-Allow-Methods';
        proxy_hide_header 'Access-Control-Allow-Headers';
        proxy_hide_header 'Access-Control-Allow-Credentials';

        add_header 'Access-Control-Allow-Origin' '\$http_origin' always;
        add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE' always;
        add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization' always;
        add_header 'Access-Control-Allow-Credentials' 'true' always;

        if (\$request_method = 'OPTIONS') {
            add_header 'Access-Control-Allow-Origin' '\$http_origin';
            add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS, PUT, DELETE';
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization';
            add_header 'Access-Control-Allow-Credentials' 'true';
            add_header 'Access-Control-Max-Age' 1728000;
            add_header 'Content-Type' 'text/plain; charset=utf-8';
            add_header 'Content-Length' 0;
            return 204;
        }

        set \$target_graphiti aio-graphiti;
        proxy_pass http://\$target_graphiti:8000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
GRAPHITI_CONF

    # Neo4j Browser
    cat > nginx/sites/neo4j.conf <<NEO4J_CONF
server {
    listen 443 ssl;
    http2 on;
    server_name neo4j.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_neo4j aio-neo4j;
        proxy_pass http://\$target_neo4j:7474;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
NEO4J_CONF

    # MLFlow Tracking
    local mlflow_auth_config=""
    if [[ "${AIO_MLFLOW_BASIC_AUTH_ENABLED:-true}" == "true" ]]; then
      local mlflow_user="${AIO_MLFLOW_BASIC_AUTH_USER:-${NSELF_ADMIN_USER:-admin}}"
      local mlflow_pass="${AIO_MLFLOW_BASIC_AUTH_PASSWORD:-${NSELF_ADMIN_PASSWORD:-admin}}"
      
      echo "Generating Basic Auth for MLFlow..."
      echo "${mlflow_user}:$(openssl passwd -apr1 "${mlflow_pass}")" > nginx/conf.d/mlflow.htpasswd
      
      mlflow_auth_config="
    auth_basic \"MLflow Protected Area\";
    auth_basic_user_file /etc/nginx/conf.d/mlflow.htpasswd;
"
    fi

    cat > nginx/sites/mlflow.conf <<MLFLOW_CONF
server {
    listen 443 ssl;
    http2 on;
    server_name mlflow.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    ${mlflow_auth_config}

    location / {
        set \$target_mlflow aio-mlflow;
        proxy_pass http://\$target_mlflow:5000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Port \$server_port;
    }
}
MLFLOW_CONF

    # FalkorDB Browser
    cat > nginx/sites/falkordb.conf <<FALKORDB_CONF
server {
    listen 443 ssl;
    http2 on;
    server_name falkordb.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_falkordb aio-falkordb-browser;
        proxy_pass http://\$target_falkordb:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
FALKORDB_CONF

  fi

  # Monitoring routes
  if [[ "${MONITORING_ENABLED:-false}" == "true" ]]; then
    # Grafana
    local grafana_route="${GRAFANA_ROUTE:-grafana}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    cat > nginx/sites/grafana.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${grafana_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    location / {
        set \$target_grafana grafana;
        proxy_pass http://\$target_grafana:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

    # Prometheus
    local prometheus_route="${PROMETHEUS_ROUTE:-prometheus}"
    local base_domain="${BASE_DOMAIN:-localhost}"

    # Basic Auth Configuration for Prometheus
    local auth_config=""
    if [[ "${PROMETHEUS_BASIC_AUTH_ENABLED:-true}" == "true" ]]; then
      local auth_user="${PROMETHEUS_BASIC_AUTH_USER:-${NSELF_ADMIN_USER:-admin}}"
      local auth_pass="${PROMETHEUS_BASIC_AUTH_PASSWORD:-${NSELF_ADMIN_PASSWORD:-admin}}"
      
      echo "Generating Basic Auth for Prometheus..."
      # Generate htpasswd file using openssl (available everywhere)
      # APR1-MD5 is compatible with Apache htpasswd format
      echo "${auth_user}:$(openssl passwd -apr1 "${auth_pass}")" > nginx/conf.d/prometheus.htpasswd
      
      auth_config="
    auth_basic \"Prometheus Restricted Access\";
    auth_basic_user_file /etc/nginx/conf.d/prometheus.htpasswd;
"
    fi

    cat > nginx/sites/prometheus.conf <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${prometheus_route}.${base_domain};

    ssl_certificate /etc/nginx/ssl/${base_domain}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${base_domain}/privkey.pem;

    ${auth_config}

    location / {
        set \$target_prometheus prometheus;
        proxy_pass http://\$target_prometheus:9090;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  fi
}

# Generate frontend app routes
generate_frontend_routes() {
  for i in {1..10}; do
    local app_name_var="FRONTEND_APP_${i}_NAME"
    local app_name="${!app_name_var:-}"

    if [[ -n "$app_name" ]]; then
      # Get route and port from environment (substitute at build time)
      local app_route_var="FRONTEND_APP_${i}_ROUTE"
      local app_route="${!app_route_var:-${app_name}}"
      local app_port_var="FRONTEND_APP_${i}_PORT"
      local app_port="${!app_port_var:-$((3000 + i - 1))}"

      cat > "nginx/sites/frontend-${app_name}.conf" <<EOF
# Frontend Application: $app_name
server {
    listen 443 ssl;
    http2 on;
    server_name ${app_route}.${BASE_DOMAIN:-localhost};

    ssl_certificate /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/privkey.pem;

    location / {
        # Proxy to external frontend app running on host
        proxy_pass http://host.docker.internal:${app_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # WebSocket support for hot reload
        proxy_read_timeout 86400;
    }
}

# API route for frontend's remote schema (if configured)
EOF

      # Check if remote schema is configured
      local schema_var="FRONTEND_APP_${i}_REMOTE_SCHEMA_NAME"
      if [[ -n "${!schema_var:-}" ]]; then
        local api_route_var="FRONTEND_APP_${i}_API_ROUTE"
        local api_route="${!api_route_var:-api.${app_name}}"
        local api_port_var="FRONTEND_APP_${i}_API_PORT"
        local api_port="${!api_port_var:-$((4000 + i))}"

        cat >> "nginx/sites/frontend-${app_name}.conf" <<EOF
server {
    listen 443 ssl;
    http2 on;
    server_name ${api_route}.${BASE_DOMAIN:-localhost};

    ssl_certificate /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/privkey.pem;

    location / {
        # Proxy to frontend's API endpoint
        proxy_pass http://host.docker.internal:${api_port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
      fi
    fi
  done
}

# Generate custom service routes
generate_custom_routes() {
  for i in {1..20}; do
    local cs_name_var="CS_${i}_NAME"
    local cs_name="${!cs_name_var:-}"
    local cs_port_var="CS_${i}_PORT"
    local cs_port="${!cs_port_var:-}"
    local cs_route_var="CS_${i}_ROUTE"
    local cs_route="${!cs_route_var:-}"
    local template=""

    # Fallback to CUSTOM_SERVICE_N parsing
    if [[ -z "$cs_name" ]]; then
      local custom_service_var="CUSTOM_SERVICE_${i}"
      local custom_service_value="${!custom_service_var:-}"
      
      if [[ -n "$custom_service_value" ]]; then
        IFS=':' read -r cs_name template cs_port <<< "$custom_service_value"
        cs_route="${cs_name}"
      fi
    fi
    
    # Get template from env var if not set by fallback
    if [[ -z "$template" ]]; then
      local template_var="CS_${i}_TEMPLATE"
      template="${!template_var:-}"
    fi

    # Skip generic config generation for services that manage their own Nginx config
    if [[ "$template" == "ai-ops" ]]; then
      rm -f "nginx/sites/custom-${cs_name}.conf" 2>/dev/null || true
      continue
    fi

    if [[ -n "$cs_name" ]]; then
      # Check if service is public
      local cs_public_var="CS_${i}_PUBLIC"
      local cs_public="${!cs_public_var:-true}"

      if [[ "$cs_public" == "true" ]]; then
        # Get route and port from environment (substitute at build time)
        cs_route="${cs_route:-${cs_name}}"
        cs_port="${cs_port:-$((8000 + i))}"

        cat > "nginx/sites/custom-${cs_name}.conf" <<EOF
# Custom Service: $cs_name
server {
    listen 443 ssl;
    http2 on;
    server_name ${cs_route}.${BASE_DOMAIN:-localhost};

    ssl_certificate /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/${BASE_DOMAIN:-localhost}/privkey.pem;

    location / {
        set \$upstream_${cs_name} ${cs_name};
        proxy_pass http://\$upstream_${cs_name}:${cs_port};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # API timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    # Health check endpoint
    location /health {
        set \$upstream_health_${cs_name} ${cs_name};
        proxy_pass http://\$upstream_health_${cs_name}:${cs_port}/health;
        access_log off;
    }
}
EOF
      fi
    fi
  done
}

# Generate database initialization
generate_database_init() {
  local force="${1:-false}"

  if [[ "$force" == "true" ]] || [[ ! -f "postgres/init/00-init.sql" ]]; then
    cat > postgres/init/00-init.sql <<'EOF'
-- Database initialization script
-- Uses runtime environment variables

-- Create database if not exists
SELECT 'CREATE DATABASE ${POSTGRES_DB:-myproject}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${POSTGRES_DB:-myproject}');

-- Create user if not exists
DO
$$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_user WHERE usename = '${POSTGRES_USER:-postgres}') THEN
    CREATE USER ${POSTGRES_USER:-postgres} WITH PASSWORD '${POSTGRES_PASSWORD:-postgres}';
  END IF;
END
$$;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB:-myproject} TO ${POSTGRES_USER:-postgres};

-- Create schema for Hasura
\c ${POSTGRES_DB:-myproject};
CREATE SCHEMA IF NOT EXISTS hdb_catalog;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS storage;

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS citext;

-- Create tables for each frontend app with table prefix
EOF

    # Add frontend app table creation
    for i in {1..10}; do
      local app_name_var="FRONTEND_APP_${i}_NAME"
      local app_name="${!app_name_var:-}"
      local prefix_var="FRONTEND_APP_${i}_TABLE_PREFIX"
      local prefix="${!prefix_var:-}"

      if [[ -n "$app_name" ]] && [[ -n "$prefix" ]]; then
        cat >> postgres/init/00-init.sql <<EOF

-- Tables for frontend app: $app_name
CREATE SCHEMA IF NOT EXISTS ${prefix}schema;
EOF
      fi
    done
  fi
}

# Export all functions
export -f generate_nginx_config
export -f generate_main_nginx_conf
export -f generate_default_server
export -f generate_service_routes
export -f generate_optional_service_routes
export -f generate_frontend_routes
export -f generate_custom_routes
export -f generate_stream_routes
export -f generate_database_init