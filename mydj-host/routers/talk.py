from __future__ import annotations

import logging
import random
import re
import time

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse

from models.schemas import TalkRequest
from config import get_config
import services.llm_client as llm_client
import services.tts_client as tts_client
import services.prompt_builder as prompt_builder

logger = logging.getLogger(__name__)
router = APIRouter()


_CLOSING_PATTERNS: tuple[str, ...] = (
    r"\bwrap(?:ping)?\s+up\b",
    r"\bthat\s+wraps\b",
    r"\bsigning\s+off\b",
    r"\bgoodbye\b",
    r"\buntil\s+next\s+time\b",
)


def _postprocess_talk_text(text: str) -> str:
    t = re.sub(r"\s+", " ", text).strip()
    for p in _CLOSING_PATTERNS:
        t = re.sub(p, "", t, flags=re.IGNORECASE).strip(" ,.!?\t\n")
    if not t:
        return "Here comes the next track."
    if t[-1] not in ".!?":
        t = f"{t}."
    return t


def _clamp_talk_length(text: str, talk_length: str) -> str:
    limits = {
        "short": 180,
        "medium": 320,
        "long": 520,
    }
    limit = limits.get(talk_length, 320)
    if len(text) <= limit:
        return text

    clipped = text[:limit].rstrip()
    # 可能なら文末で切る
    cut = max(clipped.rfind("."), clipped.rfind("!"), clipped.rfind("?"))
    if cut >= int(limit * 0.6):
        clipped = clipped[: cut + 1].rstrip()
    else:
        clipped = clipped.rstrip(" ,;:") + "."
    return clipped


@router.post("/talk")
async def talk(http_request: Request, body: TalkRequest) -> StreamingResponse:
    req_id = format(random.randint(0, 0xFFFF), "04x")
    t0 = time.perf_counter()

    cfg = get_config()

    prefs = body.preferences
    llm_model   = (prefs.llm_model   if prefs and prefs.llm_model   else None) or cfg["llm"]["default_model"]
    talk_length = (prefs.talk_length if prefs and prefs.talk_length else None) or cfg["dj"]["default_talk_length"]
    weather_city  = (prefs.weather_city  if prefs and prefs.weather_city  else None)
    personality   = (prefs.personality   if prefs and prefs.personality   else None)
    username      = (prefs.username      if prefs and prefs.username      else None)
    dj_name       = (prefs.dj_name       if prefs and prefs.dj_name       else None)
    custom_prompt = (prefs.custom_prompt if prefs and prefs.custom_prompt else None)

    if talk_length not in ("short", "medium", "long"):
        talk_length = cfg["dj"]["default_talk_length"]

    logger.info(
        "[%s] ← track=%r  prev=%r  length=%s",
        req_id,
        body.next_track.title,
        body.previous_track.title if body.previous_track else None,
        talk_length,
    )

    # ── プロンプト構築 ────────────────────────────────────────────────────
    try:
        prompt = await prompt_builder.build_prompt(
            next_track=body.next_track,
            previous_track=body.previous_track,
            talk_length=talk_length,
            personality=personality,
            is_mid_song=body.is_mid_song,
            cfg=cfg,
            weather_city=weather_city,
            username=username,
            dj_name=dj_name,
            custom_prompt=custom_prompt,
            track_history=body.track_history,
        )
    except Exception as exc:
        logger.exception("[%s] ✗ prompt build failed", req_id)
        raise HTTPException(status_code=500, detail=f"prompt build failed: {exc}") from exc

    # ── LLM テキスト生成 ─────────────────────────────────────────────────
    t_llm_start = time.perf_counter()
    try:
        talk_text = await llm_client.generate_text(
            ollama_url=cfg["llm"]["ollama_url"],
            model=llm_model,
            prompt=prompt,
        )
        talk_text = _postprocess_talk_text(talk_text)
        talk_text = _clamp_talk_length(talk_text, talk_length)
    except Exception as exc:
        elapsed = time.perf_counter() - t_llm_start
        logger.error("[%s] ✗ LLM failed (%.1fs): %s", req_id, elapsed, exc)
        raise HTTPException(status_code=500, detail=f"LLM failed: {exc}") from exc

    t_llm_done = time.perf_counter()
    logger.info(
        '[%s] LLM %.1fs → "%s..." (%d chars)',
        req_id,
        t_llm_done - t_llm_start,
        talk_text[:40].replace("\n", " "),
        len(talk_text),
    )

    # ── クライアント切断チェック ──────────────────────────────────────────
    if await http_request.is_disconnected():
        logger.debug("[%s] client disconnected after LLM — aborting TTS", req_id)
        raise HTTPException(status_code=499, detail="Client disconnected")

    # ── TTS 音声合成 ──────────────────────────────────────────────────────
    t_tts_start = time.perf_counter()
    try:
        audio_bytes = await tts_client.synthesize_speech(cfg=cfg, text=talk_text)
    except Exception as exc:
        elapsed = time.perf_counter() - t_tts_start
        logger.error("[%s] ✗ TTS failed (%.1fs): %s", req_id, elapsed, exc)
        raise HTTPException(status_code=500, detail=f"TTS failed: {exc}") from exc

    t_tts_done = time.perf_counter()
    audio_format = cfg["tts"].get("audio_format", "mp3")
    logger.info(
        "[%s] TTS %.1fs → %d bytes (%s)",
        req_id,
        t_tts_done - t_tts_start,
        len(audio_bytes),
        audio_format,
    )
    logger.info("[%s] DONE %.1fs total", req_id, t_tts_done - t0)

    content_type = "audio/mpeg" if audio_format == "mp3" else \
                   "audio/ogg"  if audio_format == "opus" else \
                   "audio/wav"

    return StreamingResponse(
        content=iter([audio_bytes]),
        media_type=content_type,
    )
