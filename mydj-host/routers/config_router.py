from __future__ import annotations

import logging

from fastapi import APIRouter
from models.schemas import ConfigResponse
from config import get_config
import services.llm_client as llm_client

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/config", response_model=ConfigResponse)
async def get_server_config() -> ConfigResponse:
    logger.info("Config request received")
    cfg = get_config()
    default_model: str = cfg["llm"]["default_model"]
    ollama_url: str = cfg["llm"]["ollama_url"]
    # subprocess モードでは default_speaker は不要
    default_speaker: str = cfg["tts"].get("default_speaker", "default")

    try:
        logger.debug("Fetching available models from Ollama: %s", ollama_url)
        models = await llm_client.list_models(ollama_url)
        if not models:
            logger.warning("No models returned from Ollama, using default")
            models = [default_model]
        logger.info("Available models: %s", models)
    except Exception as exc:
        logger.warning("Failed to connect to Ollama (%s). Using default model only.", exc)
        models = [default_model]

    response = ConfigResponse(
        llm_models=models,
        default_llm=default_model,
        tts_speakers=[default_speaker],
        default_speaker=default_speaker,
        server_version="1.0",
    )
    logger.debug("Config response: %s", response)
    return response
