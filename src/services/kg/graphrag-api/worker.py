import os
import logging
import asyncio
from celery import Celery
from elasticsearch import Elasticsearch
import requests
import time

# Setup logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Initialize Celery
rabbit_user = os.getenv("RABBITMQ_USER", "admin")
rabbit_pass = os.getenv("RABBITMQ_PASSWORD", "kP8z4s5OMdFOVD1i")
rabbit_host = os.getenv("RABBITMQ_HOST", "rabbitmq")
broker_url = f"amqp://{rabbit_user}:{rabbit_pass}@{rabbit_host}:5672//"

app = Celery('kg_tasks', broker=broker_url)

# Configuration
ES_HOST = os.environ.get("ES_HOST", "http://aio-es:9200")
KG_API_URL = os.environ.get("KG_API_URL", "http://kg-graphrag-api:8000/indexing")

@app.task(name='sync_ragflow_to_kg')
def sync_ragflow_to_kg(index_name=None):
    """
    Background task to sync RAGFlow chunks to Neo4j KG.
    """
    logger.info(f"🚀 Starting RAGFlow sync to KG")
    
    # 1. Connect to ES
    try:
        es = Elasticsearch([ES_HOST])
        if not index_name:
            # Try to auto-detect the first RAGFlow index
            indices = list(es.indices.get_alias(index="ragflow_*").keys())
            if not indices:
                logger.error("❌ No RAGFlow indices found")
                return False
            index_name = indices[0]
            
        logger.info(f"🔍 Using index: {index_name}")
        
        # 2. Extract Chunks using Scroll API
        query = {"query": {"match_all": {}}}
        resp = es.search(index=index_name, body=query, scroll='5m', size=100)
        scroll_id = resp['_scroll_id']
        hits = resp['hits']['hits']
        
        total_processed = 0
        
        while hits:
            for hit in hits:
                source = hit['_source']
                content = source.get('content_with_weight', '') or source.get('content', '')
                doc_name = source.get('docnm_kwd', 'Unknown Source')
                
                if content:
                    payload = {
                        "text": content,
                        "metadata": {
                            "source": doc_name,
                            "ragflow_id": hit['_id'],
                            "type": "ragflow_chunk"
                        }
                    }
                    
                    try:
                        kg_resp = requests.post(KG_API_URL, json=payload, timeout=120)
                        if kg_resp.status_code == 200:
                            total_processed += 1
                        else:
                            logger.error(f"❌ KG API Error for {doc_name}: {kg_resp.status_code}")
                    except Exception as e:
                        logger.error(f"Failed to post to KG API: {e}")
                    
                    time.sleep(0.5) # Throttle
            
            # Fetch next batch
            resp = es.scroll(scroll_id=scroll_id, scroll='5m')
            scroll_id = resp['_scroll_id']
            hits = resp['hits']['hits']

        logger.info(f"✅ RAGFlow sync to KG completed. Processed {total_processed} chunks.")
        return True
    except Exception as e:
        logger.error(f"❌ RAGFlow sync to KG failed: {str(e)}", exc_info=True)
        return False
