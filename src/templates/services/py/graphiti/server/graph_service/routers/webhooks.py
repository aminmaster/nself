from fastapi import APIRouter, Header, status
from pydantic import BaseModel
from typing import Optional
import logging

from graph_service.zep_graphiti import ZepGraphitiDep

logger = logging.getLogger(__name__)

router = APIRouter()

class NhostWebhookPayload(BaseModel):
    event: dict
    created_at: str
    id: str
    trigger: dict
    table: dict
    data: dict

@router.post('/user-created', status_code=status.HTTP_200_OK)
async def user_created_webhook(
    payload: NhostWebhookPayload,
    graphiti: ZepGraphitiDep,
    x_nhost_webhook_secret: Optional[str] = Header(None)
):
    """
    Webhook triggered by Nhost when a new user is created.
    Initializes a dedicated graph context for the user.
    """
    # In production, we should verify x_nhost_webhook_secret
    
    user_data = payload.data.get('new', {})
    user_id = user_data.get('id')
    
    if not user_id:
        logger.error("No user ID found in Nhost webhook payload")
        return {"status": "ignored", "reason": "no_user_id"}

    logger.info(f"Provisioning graph for new user: {user_id}")
    
    # Initialize indices and constraints for this user's group/graph
    # Graphiti clones the driver when group_id is provided
    # We use user_id as the partition/graph name
    user_graph = graphiti.driver.clone(database=user_id)
    await user_graph.build_indices_and_constraints()
    
    return {"status": "success", "user_id": user_id}
