import logging
from typing import Annotated

from fastapi import Depends, HTTPException
from graphiti_core import Graphiti  # type: ignore
from graphiti_core.edges import EntityEdge  # type: ignore
from graphiti_core.errors import EdgeNotFoundError, GroupsEdgesNotFoundError, NodeNotFoundError
from graphiti_core.llm_client import LLMClient  # type: ignore
from graphiti_core.nodes import EntityNode, EpisodicNode  # type: ignore
from urllib.parse import urlparse

from graphiti_core.driver.falkordb_driver import FalkorDriver
from graphiti_core.driver.neo4j_driver import Neo4jDriver

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
    async def get_entity_edge(self, uuid: str):
        try:
            edge = await EntityEdge.get_by_uuid(self.driver, uuid)
            return edge
        except EdgeNotFoundError as e:
            raise HTTPException(status_code=404, detail=e.message) from e

    async def delete_group(self, group_id: str):
        try:
            edges = await EntityEdge.get_by_group_ids(self.driver, [group_id])
        except GroupsEdgesNotFoundError:
            logger.warning(f'No edges found for group {group_id}')
            edges = []

        nodes = await EntityNode.get_by_group_ids(self.driver, [group_id])

        episodes = await EpisodicNode.get_by_group_ids(self.driver, [group_id])

        for edge in edges:
            await edge.delete(self.driver)

        for node in nodes:
            await node.delete(self.driver)

        for episode in episodes:
            await episode.delete(self.driver)

    async def delete_entity_edge(self, uuid: str):
        try:
            edge = await EntityEdge.get_by_uuid(self.driver, uuid)
            await edge.delete(self.driver)
        except EdgeNotFoundError as e:
            raise HTTPException(status_code=404, detail=e.message) from e

    async def delete_episodic_node(self, uuid: str):
        try:
            episode = await EpisodicNode.get_by_uuid(self.driver, uuid)
            await episode.delete(self.driver)
        except NodeNotFoundError as e:
            raise HTTPException(status_code=404, detail=e.message) from e

def configure_llm_client(client: ZepGraphiti, settings: ZepEnvDep):
    llm_key = settings.openrouter_api_key or settings.openai_api_key
    llm_base_url = settings.openrouter_base_url or settings.openai_base_url
    
    if llm_base_url is not None:
        client.llm_client.config.base_url = llm_base_url
    if llm_key is not None:
        client.llm_client.config.api_key = llm_key
    if settings.model_name is not None:
        client.llm_client.model = settings.model_name
    
    logger.info(f"Configured Graphiti LLM client with model: {client.llm_client.model} (base_url: {client.llm_client.config.base_url})")


async def get_graphiti(settings: ZepEnvDep):
    if settings.falkordb_url or settings.graph_driver_type == 'falkordb':
        password = settings.falkordb_password
        if settings.falkordb_url:
            parsed = urlparse(settings.falkordb_url)
            host = parsed.hostname or 'localhost'
            port = parsed.port or 6379
            username = parsed.username
            password = parsed.password or password
            logger.info(f"Connecting to FalkorDB via URL: {host}:{port} as {username or 'legacy-auth'} (has_password: {bool(password)})")
            driver = FalkorDriver(
                host=host,
                port=port,
                username=username,
                password=password
            )
        else:
            username = None
            logger.info(f"Connecting to FalkorDB via settings: {settings.falkordb_host}:{settings.falkordb_port} as legacy-auth (has_password: {bool(password)})")
            driver = FalkorDriver(
                host=settings.falkordb_host,
                port=settings.falkordb_port,
                username=username,
                password=password
            )
        client = ZepGraphiti(graph_driver=driver)
    else:
        client = ZepGraphiti(
            uri=settings.neo4j_uri or "bolt://localhost:7687",
            user=settings.neo4j_user or "neo4j",
            password=settings.neo4j_password or "password",
        )
    
    configure_llm_client(client, settings)
    
    try:
        yield client
    finally:
        await client.close()


async def initialize_graphiti(settings: ZepEnvDep):
    if settings.falkordb_url or settings.graph_driver_type == 'falkordb':
        password = settings.falkordb_password
        if settings.falkordb_url:
            parsed = urlparse(settings.falkordb_url)
            host = parsed.hostname or 'localhost'
            port = parsed.port or 6379
            username = parsed.username
            password = parsed.password or password
            logger.info(f"Initializing FalkorDB via URL: {host}:{port} as {username or 'legacy-auth'} (has_password: {bool(password)})")
            driver = FalkorDriver(
                host=host,
                port=port,
                username=username,
                password=password
            )
        else:
            username = None
            logger.info(f"Initializing FalkorDB via settings: {settings.falkordb_host}:{settings.falkordb_port} as legacy-auth (has_password: {bool(password)})")
            driver = FalkorDriver(
                host=settings.falkordb_host,
                port=settings.falkordb_port,
                username=username,
                password=password
            )
        client = ZepGraphiti(graph_driver=driver)
    else:
        client = ZepGraphiti(
            uri=settings.neo4j_uri or "bolt://localhost:7687",
            user=settings.neo4j_user or "neo4j",
            password=settings.neo4j_password or "password",
        )
    
    configure_llm_client(client, settings)
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
