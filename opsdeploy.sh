#!/bin/bash

# deploy.sh - unified nself orchestration utility

# Configuration
PROJECT_NAME="equilibria"
export PROJECT_NAME
PROJECTS_ROOT="$HOME/projects"
NSELF_DIR="${HOME}/.nself"
NSELF_BIN="${NSELF_DIR}/bin/nself"

# Help message
show_help() {
    echo "Usage: ./deploy.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --update    Standard update (build --force, start --fresh)"
    echo "  --partial   Partial nuke (preserves secrets, clears stale artifacts)"
    echo "  --full      Full nuke (clears everything, requires wizard)"
    echo "  --deep      Deep nuke (Full nuke + docker image prune)"
    echo "  --dev       Set web frontend to development mode (hot-reload)"
    echo "  --pro       Set web frontend to production mode (default)"
    echo "  --project   [name] Override project directory (default: equilibria)"
    echo "  --help      Show this help message"
}

# Validation
if [ ! -f "$NSELF_BIN" ]; then
    echo "ERROR: nself binary not found at $NSELF_BIN"
    exit 1
fi

# Function to restore SSL certs
restore_ssl() {
    echo "Restoring SSL certificates..."
    cd "$PROJECTS_ROOT/$PROJECT_NAME"
    if [ -d "$PROJECTS_ROOT/backups/ssl" ]; then
        cp "$PROJECTS_ROOT/backups/ssl/"* .
        if [ -f "manage_certs.sh" ]; then
            chmod +x manage_certs.sh
            BACKUP_FILE="certs_backup_20251129_085705.tar.gz"
            if [ ! -f "$BACKUP_FILE" ]; then
                BACKUP_FILE=$(ls -t certs_backup_*.tar.gz | head -n 1)
            fi

            if [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
                echo "Restoring from $BACKUP_FILE..."
                ./manage_certs.sh restore "$BACKUP_FILE"
                rm -rf "$BACKUP_FILE" ssl_* manage_certs.sh
                echo "SSL Restoration Complete."
            else
                echo "ERROR: No SSL backup file (*.tar.gz) found to restore."
            fi
        else
            echo "WARNING: manage_certs.sh not found after copy!"
        fi
    else
        echo "ERROR: Backup SSL directory not found at $PROJECTS_ROOT/backups/ssl"
    fi
}

# Function to update nself templates
update_nself() {
    echo "Updating nself templates at $NSELF_DIR..."
    (cd "$NSELF_DIR" && git pull origin main)
}

# Function to update project-specific repositories (web only)
update_repos() {
    echo "Checking for project repository updates..."
    
    # Update Web Frontend if it exists
    if [ -d "$PROJECTS_ROOT/web" ]; then
        echo "Updating web frontend at $PROJECTS_ROOT/web..."
        (cd "$PROJECTS_ROOT/web" && git pull origin main)
    fi

    # Update the project target directory itself if it's a git repo
    if [ -d "$TARGET_DIR/.git" ]; then
        echo "Updating project infrastructure at $TARGET_DIR..."
        (cd "$TARGET_DIR" && git pull origin main)
    fi
}

# Function to pre-pull Docker images
pre_pull_images() {
    echo "Checking for missing Docker images..."
    
    # Source project .env for variables like RAGFLOW_IMAGE_TAG
    # Priority: .env.$WEB_DEPLOY_MODE -> .env.prod -> .env (shim)
    # SECRETS: Always source .env.secrets if it exists to resolve warnings
    # PRO TIP: We use 'set -a' to automatically export sourced variables so 'docker compose config' sees them!
    set -a
    
    # 1. Source SECRETS first (so they are available for everything)
    if [ -f "$TARGET_DIR/.env.secrets" ]; then
        echo "🔐 Sourcing secrets from: .env.secrets"
        source "$TARGET_DIR/.env.secrets"
    fi

    # 2. Source ENVIRONMENT (prod, etc.)
    if [ -n "$WEB_DEPLOY_MODE" ] && [ -f "$TARGET_DIR/.env.$WEB_DEPLOY_MODE" ]; then
        echo "📄 Sourcing environment from: .env.$WEB_DEPLOY_MODE"
        source "$TARGET_DIR/.env.$WEB_DEPLOY_MODE"
    elif [ -f "$TARGET_DIR/.env.prod" ]; then
        echo "📄 Sourcing environment from: .env.prod (Fallback)"
        source "$TARGET_DIR/.env.prod"
    elif [ -f "$TARGET_DIR/.env" ]; then
        echo "📄 Sourcing environment from: .env (Shim)"
        source "$TARGET_DIR/.env"
    else
        echo "⚠️  No environment file found. Using default image tags."
    fi
    set +a

    # List of images to check (Defaults, will be overwritten if docker-compose.yml is found)
    IMAGES=(
        "alpine:latest"
        "postgres:15-alpine"
        "minio/minio:latest"
        "docker.elastic.co/elasticsearch/elasticsearch:8.11.3"
        "infiniflow/ragflow:${RAGFLOW_IMAGE_TAG:-v0.23.1}"
        "infiniflow/sandbox-executor-manager:latest"
        "redis:7-alpine"
        "neo4j:5.26"
        "falkordb/falkordb:latest"
        "falkordb/falkordb-browser:latest"
    )

    # Dynamic Parsing: Try to find images dynamically from generated docker-compose.yml
    if [ -f "$TARGET_DIR/docker-compose.yml" ]; then
        echo "🔍 Found docker-compose.yml, processing configuration..."
        
        # Ensure we are in the target directory for .env pickup and relative path resolution
        pushd "$TARGET_DIR" > /dev/null
        
        # 1. Structural Image Discovery
        # - IF 'build' exists -> Scrape Dockerfile for base image (Dependency)
        # - IF 'build' missing -> Use 'image' key (Direct Pull)
        
        # Redirect stderr to /dev/null to hide warnings for non-critical internal variables
        FULL_CONFIG=$(docker compose config 2>/dev/null)
        
        if command -v python3 &>/dev/null; then
             echo "🔍 analyzing stack configuration..."
             
             # Python script to extract TRUE source images
             DETECTED_IMAGES=$(echo "$FULL_CONFIG" | python3 -c "
import sys, yaml, os, re

def get_base_images(dockerfile_path):
    images = []
    if os.path.exists(dockerfile_path):
        with open(dockerfile_path, 'r') as f:
            for line in f:
                # Simple parser for 'FROM image AS alias' or 'FROM image'
                if line.strip().upper().startswith('FROM'):
                    parts = line.split()
                    if len(parts) > 1:
                        img = parts[1]
                        # Skip usage of aliases (FROM base AS builder -> FROM builder)
                        # This is a naive check; ideally we track aliases. 
                        # But standard FROM usually points to external image or previous stage.
                        # If it points to previous stage alias, 'docker pull' will fail safely/quickly.
                        if img.lower() != 'scratch':
                            images.append(img)
    return images

try:
    data = yaml.safe_load(sys.stdin)
    to_pull = set()
    built_images = set()
    
    services = data.get('services', {})
    
    # Pass 1: Identify all images that are built locally
    for svc_data in services.values():
        if 'build' in svc_data and 'image' in svc_data:
            built_images.add(svc_data['image'])

    # Pass 2: Collect images to pull
    for svc_name, svc_data in services.items():
        # STRATEGY 1: IT IS A BUILD
        if 'build' in svc_data:
            build = svc_data['build']
            if isinstance(build, str):
                context = build
                dockerfile = 'Dockerfile'
            else:
                context = build.get('context', '.')
                dockerfile = build.get('dockerfile', 'Dockerfile')
            
            # Context is usually absolute from 'docker compose config'
            df_path = os.path.join(context, dockerfile)
            
            # Scrape the Dockerfile for BASE images
            bases = get_base_images(df_path)
            for b in bases:
                to_pull.add(b)

        # STRATEGY 2: IT IS A PULL (No Build)
        elif 'image' in svc_data:
            img = svc_data['image']
            # Only pull if it's NOT built locally by another service
            if img not in built_images:
                to_pull.add(img)

    for img in to_pull:
        print(img)
        
except Exception as e:
    sys.exit(1)
")
            
            # Convert to array
            if [ $? -eq 0 ]; then
                mapfile -t RAW_IMAGES <<< "$DETECTED_IMAGES"
            else
                 echo "⚠️  Python parsing failed. Falling back to simple config."
                 DETECTED_IMAGES=$(docker compose config --images 2>/dev/null | sort | uniq | grep -v "^$")
                 mapfile -t RAW_IMAGES <<< "$DETECTED_IMAGES"
            fi
            
            # Simple deduplication and cleanup (no filtering needed!)
            FILTERED_IMAGES=()
            SORTED_UNIQUE=$(printf "%s\n" "${RAW_IMAGES[@]}" | sort | uniq)
            mapfile -t CANDIDATES <<< "$SORTED_UNIQUE"
            
            for img in "${CANDIDATES[@]}"; do
                if [[ -z "$img" ]]; then continue; fi
                # We still ignore 'scratch' or obvious variable failures if any crept in
                if [[ "$img" == "scratch" ]]; then continue; fi
                FILTERED_IMAGES+=("$img")
            done

            if [ ${#FILTERED_IMAGES[@]} -gt 0 ]; then
                IMAGES=("${FILTERED_IMAGES[@]}")
                echo "📋 Detected ${#IMAGES[@]} source images to pull."
            fi
        else
            echo "⚠️  Python3 not found. Falling back to default list."
        fi
        
        popd > /dev/null
    fi

    for img in "${IMAGES[@]}"; do
        # Check if image exists locally
        if [[ "$(docker images -q "$img" 2> /dev/null)" == "" ]]; then
             echo "⬇️  Pulling missing image: $img"
             
             # Retry logic for unstable connections
             count=0
             max_retries=5
             pulled=false
             
             while [ $count -lt $max_retries ]; do
                if docker pull "$img"; then
                    echo "✅ Successfully pulled $img"
                    pulled=true
                    break
                else
                    count=$((count+1))
                    echo "❌ Failed to pull $img. Retrying ($count/$max_retries) in 5s..."
                    sleep 5
                fi
             done
             
             if [ "$pulled" = false ]; then
                echo "🚨 FATAL: Could not pull $img after $max_retries attempts. Aborting deployment."
                exit 1
             fi
        else
             echo "✅ Image present: $img"
        fi
    done
}

# Parse arguments
MODE=""
export WEB_DEPLOY_MODE="" # Default empty, will prompt if not set via flag
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --update) MODE="update" ;;
        --partial) MODE="partial" ;;
        --full) MODE="full" ;;
        --deep) MODE="deep" ;;
        --dev) export WEB_DEPLOY_MODE="dev" ;;
        --pro) export WEB_DEPLOY_MODE="prod" ;;
        --project) PROJECT_NAME="$2"; shift ;;
        --help) show_help; exit 0 ;;
        *) echo "Unknown option: $1"; show_help; exit 1 ;;
    esac
    shift
done

# If no web mode selected, prompt user
if [ -z "$WEB_DEPLOY_MODE" ]; then
    echo "Please select Web Frontend deployment mode:"
    PS3="Choose a mode: "
    select wm in "prod" "dev"; do
        export WEB_DEPLOY_MODE=$wm
        break
    done
fi

# If no mode selected, prompt user
if [ -z "$MODE" ]; then
    echo "No mode specified. Please select a mode:"
    PS3="Choose an action: "
    select m in "update" "partial" "full" "deep"; do
        MODE=$m
        break
    done
fi

read -p "Project directory [$PROJECT_NAME]: " input
PROJECT_NAME="${input:-$PROJECT_NAME}"
TARGET_DIR="$PROJECTS_ROOT/$PROJECT_NAME"

if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory $TARGET_DIR does not exist."
    exit 1
fi

# Always update nself and code before proceeding
update_nself
update_nself
update_repos
# pre_pull_images removed from here, moved to inside case blocks to run AFTER build

case $MODE in
    update)
        echo "🚀 Starting standard update for $PROJECT_NAME..."
        cd "$TARGET_DIR" || exit 1
        $NSELF_BIN stop
        $NSELF_BIN build --force
        
        read -p "Do you want to rebuild any specific services without cache? (e.g. 'aio-graphiti' or leave empty): " REBUILD_SERVICES
        if [ -n "$REBUILD_SERVICES" ]; then
            echo "Forcing no-cache build for: $REBUILD_SERVICES"
            docker compose build --no-cache $REBUILD_SERVICES
        fi
        
        pre_pull_images
        $NSELF_BIN start --verbose --fresh
        ;;
    partial)
        echo "🧹 Starting partial nuke for $PROJECT_NAME (Web: $WEB_DEPLOY_MODE)..."
        cd "$TARGET_DIR" || exit 1
        $NSELF_BIN stop
        # Preserve secrets (.env files) but clear EVERYTHING else
        sudo find . -maxdepth 1 \( ! -name '.env*' -o -name '.env.runtime' \) ! -name '.' -exec rm -rf {} +
        docker volume prune --filter "all=1"
        
        $NSELF_BIN build --force
        
        read -p "Do you want to rebuild any specific services without cache? (e.g. 'aio-graphiti' or leave empty): " REBUILD_SERVICES
        if [ -n "$REBUILD_SERVICES" ]; then
            echo "Forcing no-cache build for: $REBUILD_SERVICES"
            docker compose build --no-cache $REBUILD_SERVICES
        fi
        
        restore_ssl
        pre_pull_images
        $NSELF_BIN start --verbose --fresh
        ;;
    full)
        echo "🧨 Starting full nuke for $PROJECT_NAME (Web: $WEB_DEPLOY_MODE)..."
        cd "$TARGET_DIR" || exit 1
        $NSELF_BIN stop
        # Full cleanup
        sudo find . -maxdepth 1 ! -name . -exec rm -rf {} +
        docker volume prune --filter "all=1"
        
        $NSELF_BIN init --wizard
        $NSELF_BIN build --force
        
        read -p "Do you want to rebuild any specific services without cache? (e.g. 'aio-graphiti' or leave empty): " REBUILD_SERVICES
        if [ -n "$REBUILD_SERVICES" ]; then
            echo "Forcing no-cache build for: $REBUILD_SERVICES"
            docker compose build --no-cache $REBUILD_SERVICES
        fi
        
        restore_ssl
        pre_pull_images
        $NSELF_BIN start --verbose --fresh
        ;;
    deep)
        echo "💀 Starting DEEP nuke for $PROJECT_NAME (Web: $WEB_DEPLOY_MODE)..."
        cd "$TARGET_DIR" || exit 1
        $NSELF_BIN stop
        # Full cleanup
        sudo find . -maxdepth 1 ! -name . -exec rm -rf {} +
        docker volume prune --filter "all=1"
        docker image prune -a --force
        docker builder prune -a --force
        
        $NSELF_BIN init --wizard
        $NSELF_BIN build --force
        restore_ssl
        pre_pull_images
        $NSELF_BIN start --verbose --fresh
        ;;
esac

echo "✅ Operation $MODE completed for $PROJECT_NAME."
