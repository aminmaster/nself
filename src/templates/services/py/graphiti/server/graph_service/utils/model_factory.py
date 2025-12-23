from typing import Any, Dict, Optional, Type
from pydantic import BaseModel, create_model, Field

class ModelFactory:
    """
    Factory for dynamically creating Pydantic models from JSON-based ontology definitions.
    Used to steer Graphiti's AI extraction engine with custom entity and edge types.
    """
    
    # Reserved fields that should not be overridden in custom models
    RESERVED_FIELDS = {
        "uuid", "name", "group_id", "labels", "created_at", "summary",
        "fact", "source_node_uuid", "target_node_uuid", "episodes",
        "valid_at", "invalid_at", "expired_at"
    }

    @staticmethod
    def _map_type(type_str: str) -> Type:
        """Maps JSON type strings to Python types."""
        type_map = {
            "string": str,
            "float": float,
            "int": int,
            "bool": bool,
            "number": float
        }
        return type_map.get(type_str.lower(), str)

    @classmethod
    def create_models(cls, type_definitions: Optional[Dict[str, Any]]) -> Optional[Dict[str, Type[BaseModel]]]:
        """
        Translates a dictionary of type definitions into a dictionary of Pydantic models.
        
        Args:
            type_definitions: Dict mapping type names to their schema (summary, attributes).
            
        Returns:
            Dict mapping type names to Pydantic model classes, or None if input is empty.
        """
        if not type_definitions:
            return None
            
        models: Dict[str, Type[BaseModel]] = {}
        
        for type_name, definition in type_definitions.items():
            summary = definition.get("summary", f"Custom {type_name} definition.")
            attributes = definition.get("attributes", {})
            
            fields = {}
            for attr_name, attr_def in attributes.items():
                if attr_name in cls.RESERVED_FIELDS:
                    # Skip reserved fields to prevent collisions with Graphiti base classes
                    continue
                
                attr_type = cls._map_type(attr_def.get("type", "string"))
                attr_desc = attr_def.get("description", "")
                
                # Define field with metadata for LLM prompt generation
                fields[attr_name] = (
                    Optional[attr_type], 
                    Field(default=None, description=attr_desc)
                )
            
            # Create model class dynamically
            model = create_model(
                type_name,
                **fields,
                __base__=BaseModel
            )
            
            # Inject docstring - critical for Graphiti's prompt context
            model.__doc__ = summary
            
            models[type_name] = model
            
        return models
