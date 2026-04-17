from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from config import get_config
import services.station_id as station_id

logger = logging.getLogger(__name__)
router = APIRouter()


@router.get("/station_id")
async def get_station_id() -> StreamingResponse:
    cfg = get_config()
    try:
        audio_bytes = await station_id.get_audio(cfg)
    except Exception as exc:
        logger.exception("station_id generation failed")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    audio_format = cfg["tts"].get("audio_format", "mp3")
    content_type = "audio/mpeg" if audio_format == "mp3" else \
                   "audio/ogg"  if audio_format == "opus" else \
                   "audio/wav"

    return StreamingResponse(
        content=iter([audio_bytes]),
        media_type=content_type,
    )
