#!/bin/bash
set -e

# ==============================================================================
# Equilibria Knowledge Graph Backup Script
# ==============================================================================
# This script creates a snapshot of the expensive-to-compute Knowledge Graph state.
# It backs up:
# 1. RAGFlow Database (Postgres) - Stores chunks, parsing status, dataset links
# 2. RAGFlow Artifacts (Minio) - Stores parsed files, GraphRAG community reports
# 3. Neo4j Database - Stores the structural graph (if populated)
# ==============================================================================

BACKUP_ROOT="${HOME}/backups/knowledge_graph"
# -------------------------------------------------------------
# ARGUMENT PARSING
# -------------------------------------------------------------
MODE="backup"
ARCHIVE_PATH=""

if [[ "$1" == "--restore" ]]; then
  MODE="restore"
  ARCHIVE_PATH="$2"
  if [[ -z "$ARCHIVE_PATH" ]]; then
    echo "❌ Error: You must provide the archive path for restore."
    echo "Usage: $0 --restore /path/to/archive.tar.gz"
    exit 1
  fi
fi

if [[ "$MODE" == "backup" ]]; then
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
    mkdir -p "$BACKUP_DIR"

    echo "📂 Starting Backup to: $BACKUP_DIR"

    # 1. RAGFlow Database (Postgres)
    echo "Creating RAGFlow Database Dump..."
    docker exec equilibria_aio_db pg_dump -U postgres -c -d ragflow > "${BACKUP_DIR}/ragflow_db.sql"
    echo "✔ RAGFlow DB backed up."

    # 2. RAGFlow Artifacts (Minio)
    echo "Archiving RAGFlow Minio Artifacts..."
    docker stop equilibria_aio_minio || true
    # Using correct volume name: equilibria_aio_minio_data
    docker run --rm \
      -v equilibria_aio_minio_data:/data \
      -v "${BACKUP_DIR}:/backup" \
      alpine tar -czf "/backup/ragflow_minio_data.tar.gz" -C /data .
    docker start equilibria_aio_minio
    echo "✔ RAGFlow Minio Artifacts backed up."

    # 3. RAGFlow Vectors (Elasticsearch)
    echo "Archiving RAGFlow Vectors (Elasticsearch)..."
    docker stop equilibria_aio_es || true
    # Using correct volume name: equilibria_aio_es_data
    docker run --rm \
      -v equilibria_aio_es_data:/data \
      -v "${BACKUP_DIR}:/backup" \
      alpine tar -czf "/backup/ragflow_es_data.tar.gz" -C /data .
    docker start equilibria_aio_es
    echo "✔ RAGFlow Vector Indices backed up."

    # 4. Neo4j Database (Graph)
    echo "Archiving Neo4j Database..."
    docker stop equilibria_aio_neo4j || true
    # Using correct volume name: equilibria_aio_neo4j_data
    docker run --rm \
      -v equilibria_aio_neo4j_data:/data \
      -v "${BACKUP_DIR}:/backup" \
      alpine tar -czf "/backup/neo4j_data.tar.gz" -C /data .
    docker start equilibria_aio_neo4j
    echo "✔ Neo4j Data Volume backed up."

    # 5. Final compression
    echo "Finalizing archive..."
    cd "$BACKUP_ROOT"
    tar -czf "kg_backup_${TIMESTAMP}.tar.gz" "${TIMESTAMP}"
    rm -rf "${TIMESTAMP}"

    echo "✅ Backup Complete!"
    echo "📍 Location: ${BACKUP_ROOT}/kg_backup_${TIMESTAMP}.tar.gz"

elif [[ "$MODE" == "restore" ]]; then
    echo "⚠️  WARNING: This will OVERWRITE RAGFlow (DB/Minio/ES) and Neo4j data."
    echo "    Archive: $ARCHIVE_PATH"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi

    echo "📂 Extracting archive..."
    WORK_DIR=$(mktemp -d)
    tar -xzf "$ARCHIVE_PATH" -C "$WORK_DIR"
    EXTRACTED_DIR=$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)

    # 1. Restore Postgres
    echo "Restoring RAGFlow Database..."
    cat "${EXTRACTED_DIR}/ragflow_db.sql" | docker exec -i equilibria_aio_db psql -U postgres -d ragflow
    echo "✔ RAGFlow DB restored."

    # 2. Restore Minio Volume
    echo "Restoring RAGFlow Minio Artifacts..."
    docker run --rm -v equilibria_aio_minio_data:/data alpine sh -c 'rm -rf /data/*'
    docker run --rm \
      -v equilibria_aio_minio_data:/data \
      -v "${EXTRACTED_DIR}:/backup" \
      alpine tar -xzf "/backup/ragflow_minio_data.tar.gz" -C /data
    echo "✔ RAGFlow Minio Artifacts restored."

    # 3. Restore Elasticsearch Volume
    echo "Restoring RAGFlow Vector Indices..."
    docker stop equilibria_aio_es || true
    docker run --rm -v equilibria_aio_es_data:/data alpine sh -c 'rm -rf /data/*'
    docker run --rm \
      -v equilibria_aio_es_data:/data \
      -v "${EXTRACTED_DIR}:/backup" \
      alpine tar -xzf "/backup/ragflow_es_data.tar.gz" -C /data
    docker start equilibria_aio_es
    echo "✔ RAGFlow Vector Indices restored."

    # 4. Restore Neo4j Volume
    echo "Restoring Neo4j Data Volume..."
    docker stop equilibria_aio_neo4j || true
    docker run --rm -v equilibria_aio_neo4j_data:/data alpine sh -c 'rm -rf /data/*'
    docker run --rm \
      -v equilibria_aio_neo4j_data:/data \
      -v "${EXTRACTED_DIR}:/backup" \
      alpine tar -xzf "/backup/neo4j_data.tar.gz" -C /data
    docker start equilibria_aio_neo4j
    echo "✔ Neo4j Data Volume restored."

    rm -rf "$WORK_DIR"
    echo "✅ Restoration Complete! You may need to restart RAGFlow container."
    echo "   nself start --fresh (without build)"
fi
