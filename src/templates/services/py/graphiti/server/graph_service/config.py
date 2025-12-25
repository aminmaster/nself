from functools import lru_cache
from typing import Annotated

from fastapi import Depends
from pydantic import AliasChoices, Field
from pydantic_settings import BaseSettings, SettingsConfigDict  # type: ignore


class Settings(BaseSettings):
    openai_api_key: str | None = Field(None)
    openai_base_url: str | None = Field(None)
    openrouter_api_key: str | None = Field(None)
    openrouter_base_url: str | None = Field(None, validation_alias=AliasChoices('OPENROUTER_BASE_URL'))
    model_name: str | None = Field(None)
    embedding_model_name: str | None = Field(None)
    neo4j_uri: str | None = Field(None)
    neo4j_user: str | None = Field(None)
    neo4j_password: str | None = Field(None)
    falkordb_url: str | None = Field(None)
    falkordb_host: str = 'falkordb'
    falkordb_port: int = 6379
    falkordb_user: str | None = Field(None, validation_alias=AliasChoices('FALKORDB_USER'))
    falkordb_password: str | None = Field(
        None, validation_alias=AliasChoices('DIFY_REDIS_PASSWORD', 'FALKORDB_PASSWORD')
    )
    graph_driver_type: str = 'falkordb'
    nhost_webhook_secret: str = Field(
        'nhost-webhook-secret', validation_alias=AliasChoices('NHOST_WEBHOOK_SECRET')
    )

    model_config = SettingsConfigDict(
        env_file='.env', extra='ignore', populate_by_name=True
    )


@lru_cache
def get_settings():
    return Settings()  # type: ignore[call-arg]


ZepEnvDep = Annotated[Settings, Depends(get_settings)]
