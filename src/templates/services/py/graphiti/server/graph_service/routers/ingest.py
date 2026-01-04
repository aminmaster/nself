import logging
from typing import Annotated

from fastapi import APIRouter, Depends, status
from graphiti_core.nodes import EpisodeType  # type: ignore
from graphiti_core.utils.maintenance.graph_data_operations import clear_data  # type: ignore

from graph_service.dto import AddEntityNodeRequest, AddMessagesRequest, Result
from graph_service.zep_graphiti import ZepGraphitiDep
from graph_service.utils.model_factory import ModelFactory

logger = logging.getLogger(__name__)

router = APIRouter()

@router.post('/messages', status_code=status.HTTP_202_ACCEPTED)
async def add_messages(
    request: AddMessagesRequest,
    graphiti: ZepGraphitiDep,
):
    """
    Ingest messages into the knowledge graph.
    NOTE: Bulk sync is handled by the Celery worker.
    """
    # Dynamic model generation from request JSON
    entity_types = ModelFactory.create_models(request.entity_types)
    edge_types = ModelFactory.create_models(request.edge_types)
    
    # Parse edge_type_map from "Source:Target" strings to (Source, Target) tuples
    parsed_edge_type_map = None
    if request.edge_type_map:
        parsed_edge_type_map = {}
        for signature, types in request.edge_type_map.items():
            if ":" in signature:
                source, target = signature.split(":")
                parsed_edge_type_map[(source.strip(), target.strip())] = types
            else:
                logger.warning(f"Invalid edge_type_map signature: {signature}. Expected 'Source:Target'")

    for m in request.messages:
        await graphiti.add_episode(
            uuid=m.uuid,
            group_id=request.group_id,
            name=m.name,
            episode_body=f'{m.role or ""}({m.role_type}): {m.content}',
            reference_time=m.timestamp,
            source=EpisodeType.message,
            source_description=m.source_description,
            entity_types=entity_types,
            edge_types=edge_types,
            edge_type_map=parsed_edge_type_map,
            custom_prompt=request.custom_prompt or '',
        )

    return Result(message='Messages ingested successfully', success=True)


@router.post('/entity-node', status_code=status.HTTP_201_CREATED)
async def add_entity_node(
    request: AddEntityNodeRequest,
    graphiti: ZepGraphitiDep,
):
    node = await graphiti.save_entity_node(
        name=request.name,
        uuid=request.uuid,
        group_id=request.group_id,
        summary=request.summary,
    )
    return Result(message=f'Entity node {node.uuid} created', success=True)


@router.delete('/group/{group_id}', status_code=status.HTTP_204_NO_CONTENT)
async def delete_group(
    group_id: str,
    graphiti: ZepGraphitiDep,
):
    await graphiti.delete_group(group_id)


@router.delete('/entity-edge/{uuid}', status_code=status.HTTP_204_NO_CONTENT)
async def delete_entity_edge(
    uuid: str,
    graphiti: ZepGraphitiDep,
):
    await graphiti.delete_entity_edge(uuid)


@router.delete('/episodic-node/{uuid}', status_code=status.HTTP_204_NO_CONTENT)
async def delete_episodic_node(
    uuid: str,
    graphiti: ZepGraphitiDep,
):
    await graphiti.delete_episodic_node(uuid)


@router.post('/clear', status_code=status.HTTP_204_NO_CONTENT)
async def clear_graph(
    graphiti: ZepGraphitiDep,
):
    await clear_data(graphiti.driver)
    await graphiti.build_indices_and_constraints()
