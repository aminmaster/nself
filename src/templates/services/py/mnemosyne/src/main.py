from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
import os
import logging

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hippocampus")

app = FastAPI(title="Hippocampus Memory Engine", version="0.1.0")

class MemoryRequest(BaseModel):
    session_id: str
    role: str
    content: str
    metadata: dict = {}

@app.get("/health")
async def health_check():
    return {"status": "ok", "service": "hippocampus"}

@app.post("/memory")
async def add_memory(request: MemoryRequest):
    """
    Ingest a new memory fragment (chat message) into the Graph.
    """
    logger.info(f"Received memory for session {request.session_id}")
    # TODO: Integrate Graphiti add_fact
    return {"status": "accepted", "id": "mem_placeholder"}

@app.get("/memory/context")
async def get_context(session_id: str, query: str = None):
    """
    Retrieve temporal and graph context for a session.
    """
    # TODO: Integrate Graphiti search
    return {
        "context": f"Simulated context for session {session_id}",
        "graph_entities": []
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8090)
