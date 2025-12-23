from typing import Any, Optional
from pydantic import BaseModel, Field

from graph_service.dto.common import Message


class AddMessagesRequest(BaseModel):
    group_id: str = Field(..., description='The group id of the messages to add')
    messages: list[Message] = Field(..., description='The messages to add')
    entity_types: Optional[dict[str, Any]] = Field(default=None, description='Custom entity types for extraction')
    edge_types: Optional[dict[str, Any]] = Field(default=None, description='Custom edge types for extraction')
    edge_type_map: Optional[dict[str, list[str]]] = Field(default=None, description='Map of "SourceLabel:TargetLabel" to allowed Edge Types')
    custom_prompt: Optional[str] = Field(default=None, description='Custom prompt to steer extraction')


class AddEntityNodeRequest(BaseModel):
    uuid: str = Field(..., description='The uuid of the node to add')
    group_id: str = Field(..., description='The group id of the node to add')
    name: str = Field(..., description='The name of the node to add')
    summary: str = Field(default='', description='The summary of the node to add')
