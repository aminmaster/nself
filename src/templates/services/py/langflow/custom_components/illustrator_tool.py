from langflow.custom import CustomComponent
from typing import Optional, Dict, Any, List
import json

class IllustratorTool(CustomComponent):
    display_name = "Equilibria Illustrator"
    description = "Converts dual-graph retrieval results into interactive Mermaid diagrams."

    def build_config(self):
        return {
            "retrieval_json": {"display_name": "Retrieval JSON", "multiline": True},
            "diagram_type": {
                "display_name": "Diagram Type",
                "options": ["Bi-Modal Graph", "Structural Only", "Temporal Only"],
                "value": "Bi-Modal Graph"
            },
            "orientation": {
                "display_name": "Orientation",
                "options": ["TD", "LR"],
                "value": "TD"
            }
        }

    def build(self, retrieval_json: str, diagram_type: str, orientation: str) -> str:
        try:
            data = json.loads(retrieval_json)
            
            # Extract data
            structural = data.get("structural", {})
            temporal = data.get("temporal", {})
            
            # Initialize Mermaid
            mermaid = f"graph {orientation}\n"
            
            # Helper to sanitize IDs
            def clean_id(raw_id):
                return str(raw_id).replace("-", "_").replace(":", "_").replace(" ", "_")

            # Helper to generate nodes/edges
            def add_graph_elements(graph_data, prefix=""):
                output = ""
                nodes = graph_data.get("nodes", [])
                edges = graph_data.get("edges", [])
                
                for node in nodes:
                    node_id = clean_id(node.get("id", "unknown"))
                    # If prefix provided (e.g. for subgraph separation), optionally prefix ID
                    # But if IDs are shared across graphs, we might want to keep them same.
                    # For now, assuming distinct IDs or wanting to merge same concepts.
                    
                    label = node.get("name", node.get("label", node_id))
                    entity_type = node.get("entity_type", "Node")
                    
                    # styling based on type? 
                    output += f'    {node_id}["{label}<br/>({entity_type})"]\n'
                
                for edge in edges:
                    src = clean_id(edge.get("source", "unknown"))
                    dst = clean_id(edge.get("target", "unknown"))
                    rel = edge.get("relation", edge.get("type", "related"))
                    output += f'    {src} -- "{rel}" --> {dst}\n'
                return output

            # 1. Structural Subgraph (Neo4j)
            if diagram_type in ["Bi-Modal Graph", "Structural Only"] and structural:
                mermaid += "\n    subgraph Structural [Structural Knowledge]\n"
                mermaid += "    direction TB\n"
                mermaid += add_graph_elements(structural)
                mermaid += "    end\n"

            # 2. Temporal Subgraph (FalkorDB)
            if diagram_type in ["Bi-Modal Graph", "Temporal Only"] and temporal:
                mermaid += "\n    subgraph Temporal [Temporal Episodic]\n"
                mermaid += "    direction TB\n"
                mermaid += add_graph_elements(temporal)
                mermaid += "    end\n"

            # Styling
            mermaid += "\n    classDef default fill:#fff,stroke:#333,stroke-width:1px;\n"
            mermaid += "    style Structural fill:#e1f5fe,stroke:#01579b,stroke-width:2px,color:#01579b\n"
            mermaid += "    style Temporal fill:#f3e5f5,stroke:#4a148c,stroke-width:2px,color:#4a148c\n"
            
            return f"```mermaid\n{mermaid}\n```"
            
        except Exception as e:
            return f"Error generating illustration: {str(e)}"
