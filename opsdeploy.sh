#!/bin/bash

# deploy.sh - unified nself orchestration utility

# Configuration
PROJECT_NAME="equilibria"
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
    # Priority: .env (Active Shim) -> .env.prod (Fallback) -> .env.dev (Fallback)
    if [ -f "$TARGET_DIR/.env" ]; then
        echo "📄 Sourcing environment from: .env"
        source "$TARGET_DIR/.env"
    elif [ -n "$WEB_DEPLOY_MODE" ] && [ -f "$TARGET_DIR/.env.$WEB_DEPLOY_MODE" ]; then
        echo "📄 Sourcing environment from: .env.$WEB_DEPLOY_MODE"
        source "$TARGET_DIR/.env.$WEB_DEPLOY_MODE"
    elif [ -f "$TARGET_DIR/.env.prod" ]; then
        echo "📄 Sourcing environment from: .env.prod (Fallback)"
        source "$TARGET_DIR/.env.prod"
    else
        echo "⚠️  No .env file found. Using default image tags."
    fi

    # List of images to check
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
pre_pull_images

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
        $NSELF_BIN start --verbose --fresh
        ;;
esac

echo "✅ Operation $MODE completed for $PROJECT_NAME."
