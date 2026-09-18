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
    configured_default_model: str = cfg["llm"].get("default_model", "auto")
    default_speaker: str = cfg["tts"].get("default_speaker", "default")

    voices = cfg.get("tts", {}).get("voices", {})
    tts_speakers = ["default"] + list(voices.keys())
    tts_speakers = list(dict.fromkeys(tts_speakers))

    try:
        logger.debug("Fetching available models from LLM provider")
        models = await llm_client.list_models(cfg)
        if not models:
            logger.warning("No models returned from LLM provider, using default")
            models = [configured_default_model]
        logger.info("Available models: %s", models)
    except Exception as exc:
        logger.warning("Failed to fetch LLM models (%s). Using default model only.", exc)
        models = [configured_default_model]

    try:
        default_model = await llm_client.resolve_model(cfg)
    except Exception as exc:
        logger.warning("Failed to resolve default LLM model (%s). Using configured default.", exc)
        default_model = configured_default_model

    if default_model not in models:
        models = [default_model] + [m for m in models if m != default_model]

    response_default_speaker = default_speaker
    if response_default_speaker not in tts_speakers:
        response_default_speaker = tts_speakers[0] if tts_speakers else "default"

    response = ConfigResponse(
        llm_models=models,
        default_llm=default_model,
        tts_speakers=tts_speakers,
        default_speaker=response_default_speaker,
        server_version="1.0",
    )
    logger.debug("Config response: %s", response)
    return response
