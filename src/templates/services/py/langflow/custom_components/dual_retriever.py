from langflow.custom import CustomComponent
from typing import Optional, Dict, Any, List
import json
import asyncio

# These imports will be available in our custom Docker image
try:
    from graphiti_core import Graphiti
    from graphiti_core.driver.neo4j_driver import Neo4jDriver
    from graphiti_core.driver.falkordb_driver import FalkorDriver
except ImportError:
    # Fallback for development/validation before build
    pass

class EquilibriaDualRetriever(CustomComponent):
    display_name = "Equilibria Dual-Graph Retriever"
    description = "Orchestrates parallel retrieval from Neo4j (Structural) and FalkorDB (Temporal)."

    def build_config(self):
        return {
            "query": {"display_name": "User Query", "multiline": True},
            "neo4j_uri": {"display_name": "Neo4j URI", "value": "bolt://aio-neo4j:7687"},
            "neo4j_user": {"display_name": "Neo4j User", "value": "neo4j"},
            "neo4j_password": {"display_name": "Neo4j Password", "password": True},
            "falkordb_host": {"display_name": "FalkorDB Host", "value": "aio-falkordb"},
            "falkordb_port": {"display_name": "FalkorDB Port", "value": 6379},
            "falkordb_password": {"display_name": "FalkorDB Password", "password": True},
            "group_id": {"display_name": "Session/Group ID", "value": "default"},
        }

    async def build(self, query: str, neo4j_uri: str, neo4j_user: str, neo4j_password: str,
              falkordb_host: str, falkordb_port: int, falkordb_password: str,
              group_id: str) -> str:
        
        # 1. Initialize Drivers
        neo4j_driver = Neo4jDriver(uri=neo4j_uri, user=neo4j_user, password=neo4j_password)
        falkor_driver = FalkorDriver(host=falkordb_host, port=falkordb_port, password=falkordb_password)
        
        # 2. Initialize Graphiti instances
        # One for Structural, one for Temporal
        graph_structural = Graphiti(graph_driver=neo4j_driver)
        graph_temporal = Graphiti(graph_driver=falkor_driver)
        
        # 3. Parallel Search
        try:
            # We use the search utility from graphiti_core
            # Note: We might need to wrap these in asyncio.gather if they are async
            results_structural = await graph_structural.search(query, group_id=group_id)
            results_temporal = await graph_temporal.search(query, group_id=group_id)
            
            # 4. Merge results
            combined_results = {
                "query": query,
                "structural": results_structural.model_dump() if hasattr(results_structural, "model_dump") else results_structural,
                "temporal": results_temporal.model_dump() if hasattr(results_temporal, "model_dump") else results_temporal,
                "timestamp": str(datetime.now())
            }
            
            return json.dumps(combined_results, indent=2)
            
        except Exception as e:
            return json.dumps({"error": str(e), "trace": "EquilibriaDualRetriever failure"})
        finally:
            await neo4j_driver.close()
            await falkor_driver.close()
