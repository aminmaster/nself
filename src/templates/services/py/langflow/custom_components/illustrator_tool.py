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
                "options": ["graph", "flowchart", "sequence"],
                "value": "graph"
            },
        }

    def build(self, retrieval_json: str, diagram_type: str) -> str:
        try:
            data = json.loads(retrieval_json)
            
            # Extract nodes and edges from structural (Neo4j)
            structural = data.get("structural", {})
            nodes = structural.get("nodes", [])
            edges = structural.get("edges", [])
            
            # Start Mermaid string
            mermaid = "graph TD\n"
            
            # Add nodes
            # Note: Graphiti nodes usually have labels and names
            for node in nodes:
                node_id = node.get("id", "unknown").replace("-", "_")
                label = node.get("name", node_id)
                entity_type = node.get("entity_type", "Concept")
                mermaid += f'    {node_id}["{label} ({entity_type})"]\n'
            
            # Add edges
            for edge in edges:
                src = edge.get("source", "unknown").replace("-", "_")
                dst = edge.get("target", "unknown").replace("-", "_")
                rel = edge.get("relation", "relates_to")
                mermaid += f'    {src} -- "{rel}" --> {dst}\n'
            
            # Add styling
            mermaid += "\n    classDef structural fill:#f9f,stroke:#333,stroke-width:2px;\n"
            mermaid += "    classDef temporal fill:#bbf,stroke:#333,stroke-width:2px;\n"
            
            return f"```mermaid\n{mermaid}\n```"
            
        except Exception as e:
            return f"Error generating illustration: {str(e)}"
