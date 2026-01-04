import os
import asyncio
from celery import Celery
from datetime import datetime
from elasticsearch import Elasticsearch
from graphiti_core.nodes import EpisodeType
from graph_service.zep_graphiti import initialize_graphiti, get_settings, create_llm_client, ZepGraphiti
from graph_service.config import Settings
from graph_service.utils.model_factory import ModelFactory

# Initialize Celery
rabbit_user = os.getenv("RABBITMQ_USER", "admin")
rabbit_pass = os.getenv("RABBITMQ_PASSWORD", "kP8z4s5OMdFOVD1i")
rabbit_host = os.getenv("RABBITMQ_HOST", "rabbitmq")
broker_url = f"amqp://{rabbit_user}:{rabbit_pass}@{rabbit_host}:5672//"

app = Celery('graphiti_tasks', broker=broker_url)

# Helper for async execution in sync worker
def run_async(coro):
    loop = asyncio.get_event_loop()
    return loop.run_until_complete(coro)

@app.task(name='sync_ragflow')
def sync_ragflow(group_id="equilibria_whitepaper"):
    """
    Background task to sync RAGFlow chunks to Graphiti.
    This replaces the legacy REST bridge.
    """
    print(f"🚀 Starting RAGFlow sync for group: {group_id}")
    
    settings = get_settings()
    es_host = os.getenv("ELASTICSEARCH_HOST", "http://aio-es:9200")
    
    # 1. Connect to ES
    es = Elasticsearch([es_host])
    indices = list(es.indices.get_alias(index="ragflow_*").keys())
    if not indices:
        print("❌ No RAGFlow indices found")
        return False
    
    index_name = indices[0]
    
    # 2. Extract Chunks
    query = {"query": {"match_all": {}}}
    result = es.search(index=index_name, body=query, scroll='5m', size=1000)
    scroll_id = result['_scroll_id']
    hits = result['hits']['hits']
    chunks = list(hits)
    
    while hits:
        result = es.scroll(scroll_id=scroll_id, scroll='5m')
        scroll_id = result['_scroll_id']
        hits = result['hits']['hits']
        if hits:
            chunks.extend(hits)
    
    print(f"📊 Extracted {len(chunks)} chunks from ES")

    # 3. Ingest into Graphiti
    async def process_ingestion():
        llm_client = create_llm_client(settings)
        # Re-using the driver logic from initialize_graphiti
        from graph_service.zep_graphiti import ZepGraphiti
        from graphiti_core.driver.falkordb_driver import FalkorDriver
        from graphiti_core.driver.neo4j_driver import Neo4jDriver
        
        # Determine driver (redundant but safe)
        if settings.falkordb_url or settings.graph_driver_type == 'falkordb':
            driver = FalkorDriver(
                host=settings.falkordb_host,
                port=settings.falkordb_port,
                username=settings.falkordb_user,
                password=settings.falkordb_password
            )
        else:
            driver = Neo4jDriver(
                settings.neo4j_uri,
                settings.neo4j_user,
                settings.neo4j_password
            )
            
        client = ZepGraphiti(graph_driver=driver, llm_client=llm_client)
        
        try:
            for i, chunk in enumerate(chunks):
                source = chunk.get('_source', {})
                content = source.get('content_with_weight', '') or source.get('content', '')
                if not content: continue
                
                doc_id = source.get('doc_id', 'unknown')
                
                print(f"📝 Ingesting chunk {i+1}/{len(chunks)} (doc: {doc_id})")
                await client.add_episode(
                    uuid=f"ragflow_chunk_{doc_id}_{i}",
                    group_id=group_id,
                    name=f"Chunk {i+1}",
                    episode_body=f"RAGFlow RAPTOR Chunk: {content}",
                    reference_time=datetime.utcnow(),
                    source=EpisodeType.message,
                    source_description=f"RAGFlow Document {doc_id}"
                )
        finally:
            await client.close()

    run_async(process_ingestion())
    print("✅ RAGFlow sync completed")
    return True
