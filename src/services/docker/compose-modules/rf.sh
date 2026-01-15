# rf.sh - Self-contained RAGFlow Stack Module (Infiniflow)

generate_rf_configs() {
  local service_name="$1"
  local rf_vol_dir="./.volumes/${service_name}/ragflow"
  local nginx_dir="${rf_vol_dir}/nginx"
  
  mkdir -p "$nginx_dir"

  # 1. Nginx Server Block
  cat <<'NGINX_CONF' > "${nginx_dir}/ragflow.conf"
server {
    listen 80;
    server_name _;
    root /ragflow/web/dist;

    gzip on;
    gzip_min_length 1k;
    gzip_comp_level 9;
    gzip_types text/plain application/javascript application/x-javascript text/css application/xml text/javascript application/x-httpd-php image/jpeg image/gif image/png;
    gzip_vary on;
    gzip_disable "MSIE [1-6]\.";

    location ~ ^/api/v1/admin {
        proxy_pass http://localhost:9381;
        include proxy.conf;
    }

    location ~ ^/(v1|api) {
        proxy_pass http://localhost:9380;
        include proxy.conf;
    }

    location / {
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location ~ ^/static/(css|js|media)/ {
        expires 10y;
        access_log off;
    }
}
NGINX_CONF

  # 2. Proxy Config
  cat <<'PROXY_CONF' > "${nginx_dir}/proxy.conf"
proxy_set_header Host $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_http_version 1.1;
proxy_set_header Connection "";
proxy_buffering off;
proxy_read_timeout 3600s;
proxy_send_timeout 3600s;
proxy_buffer_size 1024k;
proxy_buffers 16 1024k;
proxy_busy_buffers_size 2048k;
proxy_temp_file_write_size 2048k;
PROXY_CONF

  # 3. Main Nginx Config
  cat <<'MAIN_NGINX_CONF' > "${nginx_dir}/nginx.conf"
user  root;
worker_processes  auto;
error_log  /var/log/nginx/error.log notice;
pid        /var/run/nginx.pid;
events {
    worker_connections  1024;
}
http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  /var/log/nginx/access.log  main;
    sendfile        on;
    keepalive_timeout  65;
    client_max_body_size 1024M;
    include /etc/nginx/conf.d/ragflow.conf;
}
MAIN_NGINX_CONF

  # 4. Service Configuration Template
  cat <<SERVICE_CONF > "${rf_vol_dir}/service_conf.yaml.template"
ragflow:
  host: 0.0.0.0
  http_port: 9380
admin:
  host: 0.0.0.0
  http_port: 9381
postgres:
  name: 'ragflow'
  user: 'postgres'
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'rf-db'
  port: 5432
  max_connections: 100
  stale_timeout: 30
minio:
  user: '${NSELF_ADMIN_USER:-admin}'
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'rf-minio:9000'
  bucket: ''
  prefix_path: ''
es:
  hosts: 'http://rf-es:9200'
  username: ''
  password: ''
redis:
  db: 1
  username: ''
  password: '${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}'
  host: 'rf-redis:6379'
SERVICE_CONF
}

generate_rf_stack() {
  local service_name="rf"
  local port="${RAGFLOW_PORT:-9380}"

  # Core Configs
  generate_rf_configs "$service_name"

  cat <<EOF

  # RAGFlow Isolated Infrastructure
  rf-db:
    image: postgres:16-alpine
    container_name: \${PROJECT_NAME:-nself}_rf_db
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      POSTGRES_DB: ragflow
    volumes:
      - rf_db_data:/var/lib/postgresql/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  rf-redis:
    image: redis:7-alpine
    container_name: \${PROJECT_NAME:-nself}_rf_redis
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}"]
    volumes:
      - rf_redis_data:/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

  rf-es:
    image: docker.elastic.co/elasticsearch/elasticsearch:8.11.3
    container_name: \${PROJECT_NAME:-nself}_rf_es
    restart: unless-stopped
    environment:
      discovery.type: single-node
      xpack.security.enabled: "false"
      ES_JAVA_OPTS: "-Xms1g -Xmx1g"
    ulimits:
      memlock:
        soft: -1
        hard: -1
    volumes:
      - rf_es_data:/usr/share/elasticsearch/data
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:9200/_cluster/health | grep -vq '\"status\":\"red\"'"]
      interval: 30s
      timeout: 20s
      retries: 10

  rf-minio:
    image: minio/minio:latest
    container_name: \${PROJECT_NAME:-nself}_rf_minio
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${NSELF_ADMIN_USER:-admin}
      MINIO_ROOT_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
    volumes:
      - rf_minio_data:/data
    networks:
      - ${DOCKER_NETWORK}

  rf-init:
    image: infiniflow/ragflow:${RAGFLOW_IMAGE_TAG:-v0.23.1}
    container_name: ${PROJECT_NAME:-nself}_rf_init
    depends_on:
      rf-db:
        condition: service_healthy
    networks:
      - ${DOCKER_NETWORK}
    environment:
      DB_TYPE: postgres
      DB_NAME: ragflow
      DB_USER: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: rf-db
      DB_PORT: 5432
    entrypoint: ["/bin/sh", "-c"]
    command:
      - |
        echo "Waiting for rf-db..."
        MAX_RETRIES=30
        COUNT=0
        until python3 -c "import psycopg2; psycopg2.connect(dbname='postgres', user='postgres', password='${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}', host='rf-db')" 2>/dev/null; do
          if [ \$\$COUNT -ge \$\$MAX_RETRIES ]; then
            echo "❌ Timeout waiting for database connection after \$\${MAX_RETRIES} attempts."
            exit 1
          fi
          echo "Connecting to database (\$\$COUNT/\$\$MAX_RETRIES)..."
          sleep 5
          COUNT=\$\$((COUNT+1))
        done

        echo "Ensuring ragflow database exists..."
        python3 -c "import psycopg2; conn=psycopg2.connect(dbname='postgres', user='postgres', password='${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}', host='rf-db'); conn.autocommit=True; cur=conn.cursor(); cur.execute('SELECT 1 FROM pg_database WHERE datname=\'ragflow\''); exists=cur.fetchone(); [cur.execute('CREATE DATABASE ragflow') if not exists else None]"

        echo "Initializing RAGFlow database tables..."
        python3 -c "from common import settings; settings.init_settings(); from api.db.db_models import init_database_tables; import logging; logging.basicConfig(level=logging.INFO); init_database_tables()"
        
        echo "✅ RAGFlow database migration complete."

  rf-ragflow:
    image: infiniflow/ragflow:\${RAGFLOW_IMAGE_TAG:-v0.23.1}
    container_name: \${PROJECT_NAME:-nself}_rf_ragflow
    restart: unless-stopped
    ports:
      - "9380:9380"
      - "9381:9381"
    command: ["--enable-adminserver"]
    environment:
      DB_TYPE: postgres
      DB_NAME: ragflow
      DB_USER: postgres
      DB_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      DB_HOST: rf-db
      DB_PORT: 5432
      MINIO_HOST: rf-minio
      MINIO_USER: ${NSELF_ADMIN_USER:-admin}
      MINIO_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      ES_HOST: rf-es
      REDIS_HOST: rf-redis
      REDIS_PORT: 6379
      REDIS_PASSWORD: ${NSELF_ADMIN_PASSWORD:-${POSTGRES_PASSWORD:-aiopassword}}
      SANDBOX_HOST: rf-ragflow-sandbox
      SANDBOX_PORT: 9385
      RAGFLOW_SECRET_KEY: ${NSELF_ADMIN_PASSWORD:-aiopassword}${NSELF_ADMIN_PASSWORD:-aiopassword}
      ENABLE_ADMIN_SERVER: 1
    depends_on:
      rf-init:
        condition: service_completed_successfully
      rf-es:
        condition: service_healthy
      rf-redis:
        condition: service_healthy
    volumes:
      - ./.volumes/${service_name}/ragflow/nginx/ragflow.conf:/etc/nginx/conf.d/ragflow.conf:ro
      - ./.volumes/${service_name}/ragflow/nginx/proxy.conf:/etc/nginx/proxy.conf:ro
      - ./.volumes/${service_name}/ragflow/nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./.volumes/${service_name}/ragflow/service_conf.yaml.template:/ragflow/conf/service_conf.yaml.template:ro
      - rf_ragflow_data:/ragflow/rag
    networks:
      - ${DOCKER_NETWORK}
    healthcheck:
      test: ["CMD-SHELL", "python3 -c 'import urllib.request; urllib.request.urlopen(\"http://localhost:9380/v1/system/config\")'"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 120s

  rf-ragflow-sandbox:
    image: infiniflow/sandbox-executor-manager:latest
    container_name: \${PROJECT_NAME}_rf_ragflow_sandbox
    restart: unless-stopped
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    networks:
      - ${DOCKER_NETWORK}

EOF
}

export -f generate_rf_stack
