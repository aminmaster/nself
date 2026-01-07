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
        
        # 1. Get External Images defined in 'image:' key
        if DETECTED_IMAGES=$(docker compose config --images 2>/dev/null); then
            # Clean up the output, dedup, and remove empty lines
            DETECTED_IMAGES=$(echo "$DETECTED_IMAGES" | sort | uniq | grep -v "^$")
            mapfile -t RAW_IMAGES <<< "$DETECTED_IMAGES"
        else
            echo "⚠️  'docker compose config' failed. Falling back to defaults."
            RAW_IMAGES=()
        fi

        # 2. Get Base Images from 'build:' contexts (Dockerfile scraping)
        echo "🔍 Scanning Dockerfiles for base images..."
        BASE_IMAGES=()
        
        # Parse docker-compose config to find build contexts and dockerfiles
        # We look for the pattern: service -> build -> context, dockerfile
        # Using a simple grep/awk approach as 'docker compose config' expands everything to absolute paths usually
        # But to be safe, we iterate through services that have a build context.
        
        # Get list of services that have a build section
        SERVICES_WITH_BUILD=$(docker compose config --services 2>/dev/null)
        
        for sv in $SERVICES_WITH_BUILD; do
            # Check if service actually has a build context (by asking docker compose to output json for that service if possible, or parsing)
            # Simpler approach: Look for directory existence. 
            # Generating full config allows us to see the absolute path to contexts.
            
            # Using grep to find build context in the full config for this service might be tricky.
            # Let's rely on the standard layout: ./services/NAME/Dockerfile or defined in compose.
            
            # Better approach: Use python/grep one-liner to parse the full config if available, 
            # but since we don't assume external tools, let's try to parse the file structure.
            # Actually, 'docker compose config' outputs a resolved YAML. We can look for 'context:' lines.
            
            # Let's try to extract paths to Dockerfiles from the resolved YAML
            # Grep context and dockerfile lines.
            # Warning: YAML parsing with grep is fragile. 
            pass
        done
        
        # Robust Implementation:
        # We will dump the full config and iterate through 'build:' blocks.
        # Since we are in bash, we can use a small python snippet if python3 is available (common on ubuntu)
        # to correctly parse the YAML and extract all (context, dockerfile) tuples.
        
        FULL_CONFIG=$(docker compose config)
        
        if command -v python3 &>/dev/null; then
             # Python script to extract dockerfile paths
             DOCKERFILES=$(echo "$FULL_CONFIG" | python3 -c "
import sys, yaml, os

try:
    data = yaml.safe_load(sys.stdin)
    if 'services' in data:
        for svc_name, svc_data in data['services'].items():
            if 'build' in svc_data:
                build = svc_data['build']
                # build can be a string (path) or dict
                if isinstance(build, str):
                    context = build
                    dockerfile = 'Dockerfile'
                else:
                    context = build.get('context', '.')
                    dockerfile = build.get('dockerfile', 'Dockerfile')
                
                # Print absolute or relative path
                print(os.path.join(context, dockerfile))
except Exception as e:
    pass # valid yaml might not possess build keys
")
             
             # Now read each Dockerfile found
             for df_path in $DOCKERFILES; do
                 # Resolve path (it might be relative to TARGET_DIR if not absolute)
                 # docker compose config usually outputs absolute paths for contexts
                 if [ -f "$df_path" ]; then
                     # Extract FROM images, handle 'AS' aliases (e.g. FROM node:20 AS builder -> node:20)
                     # Also ignore scratch
                     FROM_IMAGES=$(grep "^FROM" "$df_path" | awk '{print $2}' | grep -v "^scratch$")
                     for base in $FROM_IMAGES; do
                         BASE_IMAGES+=("$base")
                     done
                 fi
             done
        fi
        
        # Combine External and Base images
        ALL_IMAGES=("${RAW_IMAGES[@]}" "${BASE_IMAGES[@]}")
        
        # Filter out local project images (build targets) and dedup
        FILTERED_IMAGES=()
        # Use an associative array for dedup if bash 4, or verify unique
        # Simple loop with sort -u equivalent
        
        SORTED_UNIQUE=$(printf "%s\n" "${ALL_IMAGES[@]}" | sort | uniq)
        
        mapfile -t CANDIDATES <<< "$SORTED_UNIQUE"
        
        for img in "${CANDIDATES[@]}"; do
            # Skip images that start with the project name or 'equilibria' (assumed local targets)
            # Also skip empty lines or variables that failed to resolve
            if [[ -z "$img" ]]; then continue; fi
            if [[ "$img" == "${PROJECT_NAME}_"* ]] || [[ "$img" == "equilibria_"* ]]; then
                echo "⏭️  Skipping local build target: $img"
            else
                FILTERED_IMAGES+=("$img")
            fi
        done
        
        if [ ${#FILTERED_IMAGES[@]} -gt 0 ]; then
            IMAGES=("${FILTERED_IMAGES[@]}")
            echo "📋 Detected ${#IMAGES[@]} total images (run-time + build-base) to pull."
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
