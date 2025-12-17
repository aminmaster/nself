import logging
from typing import Annotated

from fastapi import Depends, HTTPException
from graphiti_core import Graphiti  # type: ignore
from graphiti_core.edges import EntityEdge  # type: ignore
from graphiti_core.errors import EdgeNotFoundError, GroupsEdgesNotFoundError, NodeNotFoundError
from graphiti_core.llm_client import LLMClient  # type: ignore
from graphiti_core.nodes import EntityNode, EpisodicNode  # type: ignore

from graph_service.config import ZepEnvDep
from graph_service.dto import FactResult

logger = logging.getLogger(__name__)


class ZepGraphiti(Graphiti):
    def __init__(
        self,
        uri: str | None = None,
        user: str | None = None,
        password: str | None = None,
        llm_client: LLMClient | None = None,
        graph_driver=None,
    ):
        super().__init__(uri, user, password, llm_client, graph_driver=graph_driver)

    async def save_entity_node(self, name: str, uuid: str, group_id: str, summary: str = ''):
        new_node = EntityNode(
            name=name,
            uuid=uuid,
            group_id=group_id,
            summary=summary,
        )
        await new_node.generate_name_embedding(self.embedder)
        await new_node.save(self.driver)
        return new_node
    
    # ... (rest of methods unchanged, I assume I don't need to replace them if I target specific block? 
    # Wait, replace_file_content replaces block. I need to be careful not to delete methods.)
    # I will stick to modifying __init__ and get_graphiti independently.

async def get_graphiti(settings: ZepEnvDep):
    if settings.graph_driver_type == 'falkordb':
        from graphiti_core.driver.falkordb_driver import FalkorDriver
        driver = FalkorDriver(
            host=settings.falkordb_host,
            port=settings.falkordb_port
        )
        client = ZepGraphiti(graph_driver=driver)
    else:
        client = ZepGraphiti(
            uri=settings.neo4j_uri,
            user=settings.neo4j_user,
            password=settings.neo4j_password,
        )
    
    if settings.openai_base_url is not None:
        client.llm_client.config.base_url = settings.openai_base_url
    if settings.openai_api_key is not None:
        client.llm_client.config.api_key = settings.openai_api_key
    if settings.model_name is not None:
        client.llm_client.model = settings.model_name
    
    try:
        yield client
    finally:
        await client.close()


async def initialize_graphiti(settings: ZepEnvDep):
    if settings.graph_driver_type == 'falkordb':
        from graphiti_core.driver.falkordb_driver import FalkorDriver
        driver = FalkorDriver(
            host=settings.falkordb_host,
            port=settings.falkordb_port
        )
        client = ZepGraphiti(graph_driver=driver)
    else:
        client = ZepGraphiti(
            uri=settings.neo4j_uri,
            user=settings.neo4j_user,
            password=settings.neo4j_password,
        )
    await client.build_indices_and_constraints()


def get_fact_result_from_edge(edge: EntityEdge):
    return FactResult(
        uuid=edge.uuid,
        name=edge.name,
        fact=edge.fact,
        valid_at=edge.valid_at,
        invalid_at=edge.invalid_at,
        created_at=edge.created_at,
        expired_at=edge.expired_at,
    )


ZepGraphitiDep = Annotated[ZepGraphiti, Depends(get_graphiti)]
