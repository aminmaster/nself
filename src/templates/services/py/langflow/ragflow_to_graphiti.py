import os
import json
import time
import requests
from elasticsearch import Elasticsearch

# Configuration
ES_HOST = os.environ.get("ES_HOST", "http://aio-es:9200")
GRAPHITI_URL = os.environ.get("GRAPHITI_URL", "http://aio-graphiti:8000")
INDEX_NAME = os.environ.get("RAGFLOW_INDEX", "ragflow_3505ed6ee6bb11f08fc1ee3be652e0b8")
GROUP_ID = os.environ.get("GROUP_ID", "equilibria_structural")

def run_extraction():
    print(f"Connecting to Elasticsearch at {ES_HOST}...")
    es = Elasticsearch(ES_HOST)
    
    if not es.indices.exists(index=INDEX_NAME):
        print(f"Error: Index {INDEX_NAME} does not exist.")
        return

    print(f"Starting extraction from {INDEX_NAME} for group {GROUP_ID}...")
    
    # Use scroll API for potentially large datasets
    query = {
        "query": {"match_all": {}},
        "size": 100
    }
    
    resp = es.search(index=INDEX_NAME, body=query, scroll='2m')
    scroll_id = resp['_scroll_id']
    hits = resp['hits']['hits']
    
    total_processed = 0
    
    while hits:
        messages = []
        for hit in hits:
            content = hit['_source'].get('content_with_weight', '')
            if content:
                messages.append({
                    "role": "system",
                    "content": content,
                    "name": "RAGFlow",
                    "timestamp": hit['_source'].get('create_time', None)
                })
        
        if messages:
            print(f"Sending {len(messages)} segments to Graphiti...")
            try:
                graphiti_resp = requests.post(
                    f"{GRAPHITI_URL}/messages",
                    json={
                        "group_id": GROUP_ID,
                        "messages": messages
                    },
                    timeout=60
                )
                graphiti_resp.raise_for_status()
                total_processed += len(messages)
            except Exception as e:
                print(f"Error sending to Graphiti: {e}")
        
        # Next batch
        resp = es.scroll(scroll_id=scroll_id, scroll='2m')
        scroll_id = resp['_scroll_id']
        hits = resp['hits']['hits']
        
    print(f"Extraction complete. Total segments processed: {total_processed}")

if __name__ == "__main__":
    run_extraction()
