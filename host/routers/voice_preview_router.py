from __future__ import annotations

import logging

from fastapi import APIRouter, HTTPException
from fastapi.responses import Response
from pydantic import BaseModel

from config import get_config
import services.tts_client as tts_client

logger = logging.getLogger(__name__)
router = APIRouter()

_SAMPLE_TEXT = (
    "Hey, you're locked in with VoidFM. "
    "Great music, no apologies. "
    "Let's keep this thing going."
)


class VoicePreviewRequest(BaseModel):
    speaker: str = "default"


@router.post("/voice_preview")
async def voice_preview(body: VoicePreviewRequest) -> Response:
    cfg = get_config()
    tts_mode = cfg["tts"].get("mode", "http")

    if tts_mode in ("subprocess", "s2_server"):
        voices = cfg.get("tts", {}).get("voices", {})
        allowed = {"default"} | set(voices.keys())
        if body.speaker not in allowed:
            raise HTTPException(
                status_code=400,
                detail=f"Unknown speaker: {body.speaker!r}. Available: {sorted(allowed)}",
            )

    logger.info("voice_preview: speaker=%r", body.speaker)
    try:
        audio_bytes = await tts_client.synthesize_speech(
            cfg=cfg,
            text=_SAMPLE_TEXT,
            speaker_override=body.speaker,
            priority="high",
        )
    except Exception as exc:
        logger.error("voice_preview TTS failed: %s", exc)
        raise HTTPException(status_code=500, detail=f"TTS failed: {exc}") from exc

    audio_format = cfg["tts"].get("audio_format", "mp3")
    content_type = (
        "audio/mpeg" if audio_format == "mp3"
        else "audio/ogg" if audio_format == "opus"
        else "audio/wav"
    )
    return Response(content=audio_bytes, media_type=content_type)
