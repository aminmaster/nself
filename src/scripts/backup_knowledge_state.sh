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
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo "📂 Starting Backup to: $BACKUP_DIR"

# -------------------------------------------------------------
# 1. RAGFlow Database (Postgres)
# -------------------------------------------------------------
echo "Creating RAGFlow Database Dump..."
docker exec equilibria_aio_db pg_dump -U postgres -d ragflow > "${BACKUP_DIR}/ragflow_db.sql"
echo "✔ RAGFlow DB backed up."

# -------------------------------------------------------------
# 2. RAGFlow Artifacts (Minio)
# -------------------------------------------------------------
echo "Archiving RAGFlow Minio Artifacts..."
# We backup the docker volume directly using a temporary container to avoid installing mc client
# Assuming volume name is aio_minio_data based on ai-ops.sh
docker run --rm \
  -v aio_ragflow_data:/data \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar -czf "/backup/ragflow_data.tar.gz" -C /data .

echo "✔ RAGFlow Data Volume backed up."

# -------------------------------------------------------------
# 3. Neo4j Database (Graph)
# -------------------------------------------------------------
echo "Archiving Neo4j Database..."
docker run --rm \
  -v aio_neo4j_data:/data \
  -v "${BACKUP_DIR}:/backup" \
  alpine tar -czf "/backup/neo4j_data.tar.gz" -C /data .

echo "✔ Neo4j Data Volume backed up."

# -------------------------------------------------------------
# 4. Final compression
# -------------------------------------------------------------
echo "Finalizing archive..."
cd "$BACKUP_ROOT"
tar -czf "kg_backup_${TIMESTAMP}.tar.gz" "${TIMESTAMP}"
rm -rf "${TIMESTAMP}"

echo "✅ Backup Complete!"
echo "📍 Location: ${BACKUP_ROOT}/kg_backup_${TIMESTAMP}.tar.gz"
echo "To restore, extract this archive and restore the SQL/Volumes."
