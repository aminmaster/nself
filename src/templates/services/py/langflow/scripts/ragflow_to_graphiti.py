#!/usr/bin/env python3
"""
RAGFlow to Graphiti Bridge Script

This script extracts RAPTOR-processed chunks from RAGFlow's Elasticsearch index
and pipelines them into Graphiti for entity/relation extraction into Neo4j.

Usage:
    python3 ragflow_to_graphiti.py

Environment:
    - Expects to run within the Docker network or with access to aio-es and aio-graphiti
"""

import os
import sys
import requests
from datetime import datetime
from elasticsearch import Elasticsearch
from typing import List, Dict, Any

# Configuration
ES_HOST = os.getenv("ELASTICSEARCH_HOST", "http://aio-es:9200")
GRAPHITI_HOST = os.getenv("GRAPHITI_HOST", "http://aio-graphiti:8000")
GROUP_ID = "equilibria_whitepaper"
BATCH_SIZE = 10

def connect_to_elasticsearch() -> Elasticsearch:
    """Connect to Elasticsearch"""
    print(f"[ES] Connecting to {ES_HOST}...")
    es = Elasticsearch([ES_HOST])
    if not es.ping():
        raise Exception("Failed to connect to Elasticsearch")
    print("[ES] Connected successfully")
    return es

def find_ragflow_index(es: Elasticsearch) -> str:
    """Find the RAGFlow index (starts with ragflow_)"""
    indices = list(es.indices.get_alias(index="ragflow_*").keys())
    if not indices:
        raise Exception("No RAGFlow indices found in Elasticsearch")
    
    index_name = indices[0]
    print(f"[ES] Found RAGFlow index: {index_name}")
    return index_name

def extract_chunks(es: Elasticsearch, index_name: str) -> List[Dict[str, Any]]:
    """Extract all chunks from the RAGFlow index using scroll API"""
    print(f"[ES] Extracting chunks from {index_name}...")
    
    chunks = []
    query = {"query": {"match_all": {}}}
    
    # Initial scroll
    result = es.search(
        index=index_name,
        body=query,
        scroll='5m',
        size=1000
    )
    
    scroll_id = result['_scroll_id']
    hits = result['hits']['hits']
    chunks.extend(hits)
    
    print(f"[ES] Retrieved {len(hits)} chunks (batch 1)")
    
    # Continue scrolling
    batch_num = 2
    while hits:
        result = es.scroll(scroll_id=scroll_id, scroll='5m')
        scroll_id = result['_scroll_id']
        hits = result['hits']['hits']
        if hits:
            chunks.extend(hits)
            print(f"[ES] Retrieved {len(hits)} chunks (batch {batch_num})")
            batch_num += 1
    
    print(f"[ES] Total chunks extracted: {len(chunks)}")
    return chunks

def transform_to_messages(chunks: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Transform RAGFlow chunks into Graphiti Message format"""
    messages = []
    
    for i, chunk in enumerate(chunks):
        source = chunk.get('_source', {})
        content = source.get('content_with_weight', '') or source.get('content', '')
        
        if not content:
            continue
        
        # Extract metadata
        doc_id = source.get('doc_id', 'unknown')
        
        message = {
            "uuid": f"ragflow_chunk_{doc_id}_{i}",
            "content": content,
            "role_type": "system",
            "role": "RAGFlow RAPTOR Chunk",
            "name": f"Chunk {i+1}",
            "timestamp": datetime.utcnow().isoformat() + "Z",
            "source_description": f"RAGFlow Document {doc_id}"
        }
        messages.append(message)
    
    print(f"[Transform] Converted {len(messages)} chunks to messages")
    return messages

def send_to_graphiti(messages: List[Dict[str, Any]]) -> None:
    """Send messages to Graphiti in batches"""
    endpoint = f"{GRAPHITI_HOST}/messages"
    total = len(messages)
    
    print(f"[Graphiti] Sending {total} messages in batches of {BATCH_SIZE}...")
    
    for i in range(0, total, BATCH_SIZE):
        batch = messages[i:i+BATCH_SIZE]
        payload = {
            "group_id": GROUP_ID,
            "messages": batch,
            "entity_types": None,
            "edge_types": None
        }
        
        try:
            response = requests.post(endpoint, json=payload, timeout=30)
            response.raise_for_status()
            print(f"[Graphiti] Batch {i//BATCH_SIZE + 1}/{(total + BATCH_SIZE - 1)//BATCH_SIZE} sent successfully")
        except requests.exceptions.RequestException as e:
            print(f"[Graphiti] Error sending batch {i//BATCH_SIZE + 1}: {str(e)}")
            sys.exit(1)
    
    print("[Graphiti] All messages sent successfully")

def main():
    print("=" * 60)
    print("RAGFlow → Graphiti Bridge Script")
    print("=" * 60)
    
    try:
        # Step 1: Connect to Elasticsearch
        es = connect_to_elasticsearch()
        
        # Step 2: Find RAGFlow index
        index_name = find_ragflow_index(es)
        
        # Step 3: Extract chunks
        chunks = extract_chunks(es, index_name)
        
        if not chunks:
            print("[Error] No chunks found in RAGFlow index")
            sys.exit(1)
        
        # Step 4: Transform to messages
        messages = transform_to_messages(chunks)
        
        # Step 5: Send to Graphiti
        send_to_graphiti(messages)
        
        print("=" * 60)
        print("✅ Sync completed successfully!")
        print(f"   Processed: {len(chunks)} chunks")
        print(f"   Sent to Graphiti: {len(messages)} messages")
        print("=" * 60)
        
    except Exception as e:
        print(f"[Fatal Error] {str(e)}")
        sys.exit(1)

if __name__ == "__main__":
    main()
