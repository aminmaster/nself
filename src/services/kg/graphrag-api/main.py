import os
import logging
from typing import List, Optional, Dict, Any
from fastapi import FastAPI, HTTPException, Body
from pydantic import BaseModel
from neo4j import GraphDatabase
from neo4j_graphrag.retrievers import VectorRetriever, VectorCypherRetriever, HybridRetriever
from neo4j_graphrag.llm import OpenAILLM, AnthropicLLM
from neo4j_graphrag.embeddings.openai import OpenAIEmbeddings
from dotenv import load_dotenv

# Initialize logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

load_dotenv()

app = FastAPI(title="KG GraphRAG API")

# Configuration from environment
NEO4J_URI = os.getenv("NEO4J_URI", "bolt://kg-neo4j:7687")
NEO4J_USERNAME = os.getenv("NEO4J_USERNAME", "neo4j")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD", "aiopassword")

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
ANTHROPIC_API_KEY = os.getenv("ANTHROPIC_API_KEY")
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY")
LLM_BASE_URL = os.getenv("LLM_BASE_URL")

DEFAULT_MODEL = os.getenv("DEFAULT_MODEL", "gpt-4o-mini")
EMBEDDING_MODEL = os.getenv("EMBEDDING_MODEL", "text-embedding-3-small")
VECTOR_INDEX_NAME = os.getenv("VECTOR_INDEX_NAME", "kg_embeddings")

# Initialize Neo4j Driver
try:
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USERNAME, NEO4J_PASSWORD))
    driver.verify_connectivity()
    logger.info("Connected to Neo4j successfully")
except Exception as e:
    logger.error(f"Failed to connect to Neo4j: {e}")
    driver = None

# Initialize LLM & Embeddings
def get_llm():
    provider = os.getenv("DEFAULT_LLM_PROVIDER", "openai").lower()
    
    # Handle OpenRouter specifically if provider is set to 'openrouter'
    if provider == "openrouter":
        base_url = LLM_BASE_URL or "https://openrouter.ai/api/v1"
        api_key = OPENROUTER_API_KEY or OPENAI_API_KEY
        return OpenAILLM(model_name=DEFAULT_MODEL, api_key=api_key, base_url=base_url)
        
    if provider == "openai":
        return OpenAILLM(model_name=DEFAULT_MODEL, api_key=OPENAI_API_KEY, base_url=LLM_BASE_URL)
    elif provider == "anthropic":
        return AnthropicLLM(model_name=DEFAULT_MODEL, api_key=ANTHROPIC_API_KEY)
    else:
        raise ValueError(f"Unsupported LLM provider: {provider}")

def get_embedder():
    return OpenAIEmbeddings(model=EMBEDDING_MODEL, api_key=OPENAI_API_KEY)

# Data Models
class SearchRequest(BaseModel):
    query: str
    top_k: int = 5
    retriever_type: str = "hybrid" # vector, hybrid, cypher
    custom_cypher: Optional[str] = None

class IndexRequest(BaseModel):
    text: str
    metadata: Optional[Dict[str, Any]] = None

class SearchResponse(BaseModel):
    answer: str
    context: List[Dict[str, Any]]
    metadata: Dict[str, Any]

@app.get("/health")
async def health():
    if not driver:
        return {"status": "degraded", "error": "Neo4j connection missing"}
    try:
        driver.verify_connectivity()
        return {
            "status": "healthy",
            "neo4j": "connected",
            "vector_index": VECTOR_INDEX_NAME
        }
    except Exception as e:
        return {"status": "unhealthy", "error": str(e)}

@app.post("/indexing")
async def indexing(request: IndexRequest):
    if not driver:
        raise HTTPException(status_code=500, detail="Neo4j driver not initialized")
    
    try:
        from neo4j_graphrag.experimental.pipeline.kg_builder import SimpleKGPipeline
        
        llm = get_llm()
        embedder = get_embedder()
        
        pipeline = SimpleKGPipeline(
            driver=driver,
            llm=llm,
            embedder=embedder,
            entities=[], # Auto-extract
            relations=[], # Auto-extract
            on_error="ignore"
        )
        
        pipeline.run_async(text=request.text)
        return {"success": true, "message": "Indexing task started in background"}
    except Exception as e:
        logger.exception("Indexing failed")
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/community")
async def community_detection():
    # Placeholder for triggering Leiden + Community Summaries
    # This usually requires running multiple Cypher queries or using the Leiden library directly
    return {"success": true, "message": "Community detection triggered (Placeholder)"}

@app.post("/search", response_model=SearchResponse)
async def search(request: SearchRequest):
    if not driver:
        raise HTTPException(status_code=500, detail="Neo4j driver not initialized")

    try:
        embedder = get_embedder()
        llm = get_llm()

        # 1. Initialize Retriever based on type
        if request.retriever_type == "vector":
            retriever = VectorRetriever(
                driver,
                index_name=VECTOR_INDEX_NAME,
                embedder=embedder,
                return_properties=["text", "source"]
            )
        elif request.retriever_type == "cypher":
            # Using VectorCypherRetriever for contextual graph search
            # If custom_cypher is provided, we'd use a more generic CypherRetriever if available,
            # but VectorCypher is standard for RAG.
            cypher_query = request.custom_cypher or "MATCH (n:Entity)-[r]->(m) RETURN n.name, type(r), m.name LIMIT 10"
            retriever = VectorCypherRetriever(
                driver,
                index_name=VECTOR_INDEX_NAME,
                embedder=embedder,
                retrieval_query=cypher_query
            )
        else: # Default to hybrid
            retriever = HybridRetriever(
                driver,
                vector_index_name=VECTOR_INDEX_NAME,
                fulltext_index_name="kg_fulltext", # Assumes fulltext index exists
                embedder=embedder,
                return_properties=["text", "source"]
            )

        # 2. Retrieve Context
        search_result = retriever.search(query_text=request.query, top_k=request.top_k)
        
        # 3. Generate Answer using LLM
        # Note: neo4j-graphrag handles the RAG prompt construction in their QueryEngine if preferred,
        # but manual construction is more transparent for a debug console.
        context_str = "\n".join([str(item.content) for item in search_result.items])
        prompt = f"Context:\n{context_str}\n\nQuestion: {request.query}\n\nAnswer the question based on the context above."
        
        response = llm.invoke(prompt)

        return SearchResponse(
            answer=response.content,
            context=[{"content": item.content, "score": item.score} for item in search_result.items],
            metadata={
                "retriever_type": request.retriever_type,
                "top_k": request.top_k
            }
        )

    except Exception as e:
        logger.exception("Search failed")
        raise HTTPException(status_code=500, detail=str(e))

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
