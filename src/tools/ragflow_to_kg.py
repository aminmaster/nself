import os
import json
import time
import requests
from elasticsearch import Elasticsearch
import logging

# Initialize logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Configuration
ES_HOST = os.environ.get("ES_HOST", "http://aio-es:9200")
# We point to the internal GraphRAG API service
KG_API_URL = os.environ.get("KG_API_URL", "http://kg-graphrag-api:8000/indexing")
# The index name from your RAGFlow deployment
INDEX_NAME = os.environ.get("RAGFLOW_INDEX", "ragflow_3505ed6ee6bb11f08fc1ee3be652e0b8")

def run_kg_sync():
    logger.info(f"Connecting to Elasticsearch at {ES_HOST}...")
    try:
        es = Elasticsearch(ES_HOST)
        if not es.indices.exists(index=INDEX_NAME):
            logger.error(f"Error: Index {INDEX_NAME} does not exist.")
            return
    except Exception as e:
        logger.error(f"Failed to connect to ES: {e}")
        return

    logger.info(f"Starting Knowledge Graph Sync from {INDEX_NAME}...")
    
    # Use scroll API for systematic fetching of all chunks
    query = {
        "query": {"match_all": {}},
        "size": 50 # Batch size
    }
    
    try:
        resp = es.search(index=INDEX_NAME, body=query, scroll='5m')
        scroll_id = resp['_scroll_id']
        hits = resp['hits']['hits']
    except Exception as e:
        logger.error(f"Initial search failed: {e}")
        return
    
    total_processed = 0
    
    while hits:
        for hit in hits:
            source = hit['_source']
            content = source.get('content_with_weight', '')
            doc_name = source.get('docnm_kwd', 'Unknown Source')
            
            if content:
                logger.info(f"Processing chunk from: {doc_name}...")
                
                payload = {
                    "text": content,
                    "metadata": {
                        "source": doc_name,
                        "ragflow_id": hit['_id'],
                        "type": "ragflow_chunk"
                    }
                }
                
                try:
                    # Send to KG-GraphRAG-API for structured extraction & Neo4j merge
                    kg_resp = requests.post(KG_API_URL, json=payload, timeout=120)
                    if kg_resp.status_code == 200:
                        logger.info(f"✅ Synced: {doc_name}")
                        total_processed += 1
                    else:
                        logger.error(f"❌ KG API Error for {doc_name}: {kg_resp.status_code} - {kg_resp.text}")
                except Exception as e:
                    logger.error(f"Failed to post to KG API: {e}")
                
                # Small throttle to avoid overwhelming the LLM
                time.sleep(0.5)
        
        # Fetch next batch
        try:
            resp = es.scroll(scroll_id=scroll_id, scroll='5m')
            scroll_id = resp['_scroll_id']
            hits = resp['hits']['hits']
        except Exception as e:
            logger.error(f"Scroll error: {e}")
            break
            
    logger.info(f"🚀 KG Sync complete. Total chunks processed: {total_processed}")

if __name__ == "__main__":
    run_kg_sync()
