from __future__ import annotations

import logging
import re
import time
from dataclasses import dataclass
from typing import Awaitable, Callable

from fastapi import HTTPException

from models.schemas import TalkRequest
import services.llm_client as llm_client
import services.program_memory as program_memory
import services.prompt_builder as prompt_builder
import services.runtime_metrics as metrics
import services.tts_client as tts_client

logger = logging.getLogger(__name__)

DisconnectChecker = Callable[[], Awaitable[bool]]


@dataclass(frozen=True)
class TalkResult:
    audio_bytes: bytes
    content_type: str
    headers: dict[str, str]
    text: str
    llm_time: float
    tts_time: float
    total_time: float


_CLOSING_PATTERNS: tuple[str, ...] = (
    r"\bthat\s+wraps\s+it\s+up\b",
    r"\bwrap(?:ping)?\s+up\b",
    r"\bthat\s+wraps\b",
    r"\bsigning\s+off\b",
    r"\bgoodbye\b",
    r"\buntil\s+next\s+time\b",
)

_SUPPORTED_TTS_TAGS: frozenset[str] = frozenset({
    "sigh",
    "gasp",
    "cough",
    "laugh",
    "whisper",
    "breath",
})
_TTS_TAG_PATTERN = re.compile(r"\[([A-Za-z][A-Za-z _-]{0,31})\]")


def _filter_tts_tags(text: str) -> str:
    def replace(match: re.Match[str]) -> str:
        tag = match.group(1).strip().lower()
        return f"[{tag}]" if tag in _SUPPORTED_TTS_TAGS else ""

    return re.sub(r"\s+", " ", _TTS_TAG_PATTERN.sub(replace, text)).strip()


def postprocess_talk_text(text: str) -> str:
    t = _filter_tts_tags(text)
    for p in _CLOSING_PATTERNS:
        t = re.sub(p, "", t, flags=re.IGNORECASE).strip(" ,.!?\t\n")
    t = re.sub(r"\s+([,.!?;:])", r"\1", t).strip()
    if not t:
        return "Here comes the next track."
    if t[-1] not in ".!?":
        t = f"{t}."
    return t


def clamp_talk_length(text: str, talk_length: str) -> str:
    limits = {
        "short": 180,
        "medium": 320,
        "long": 800,
    }
    limit = limits.get(talk_length, 320)
    if len(text) <= limit:
        return text

    clipped = text[:limit].rstrip()
    cut = max(clipped.rfind("."), clipped.rfind("!"), clipped.rfind("?"))
    if cut >= int(limit * 0.6):
        clipped = clipped[: cut + 1].rstrip()
    else:
        clipped = clipped.rstrip(" ,;:.!?")
        if len(clipped) >= limit:
            clipped = clipped[: limit - 1].rstrip(" ,;:.!?")
        clipped = f"{clipped}."
    return clipped


def content_type_for_format(audio_format: str) -> str:
    if audio_format == "mp3":
        return "audio/mpeg"
    if audio_format == "opus":
        return "audio/ogg"
    return "audio/wav"


async def generate_talk(
    *,
    cfg: dict,
    body: TalkRequest,
    req_id: str,
    is_disconnected: DisconnectChecker | None = None,
) -> TalkResult:
    t0 = time.perf_counter()

    prefs = body.preferences
    requested_llm_model = prefs.llm_model if prefs and prefs.llm_model else None
    tts_speaker = (
        prefs.tts_speaker if prefs and prefs.tts_speaker else None
    ) or cfg["tts"].get("default_speaker", "default")
    talk_length = (
        prefs.talk_length if prefs and prefs.talk_length else None
    ) or cfg["dj"]["default_talk_length"]
    weather_city = prefs.weather_city if prefs and prefs.weather_city else None
    personality = prefs.personality if prefs and prefs.personality else None
    username = prefs.username if prefs and prefs.username else None
    dj_name = prefs.dj_name if prefs and prefs.dj_name else None
    custom_prompt = prefs.custom_prompt if prefs and prefs.custom_prompt else None
    language = prefs.language if prefs and prefs.language else None

    if talk_length not in ("short", "medium", "long"):
        talk_length = cfg["dj"]["default_talk_length"]

    logger.info(
        "[%s] ← track=%r  prev=%r  length=%s",
        req_id,
        body.next_track.title,
        body.previous_track.title if body.previous_track else None,
        talk_length,
    )

    try:
        llm_model = await llm_client.resolve_model(cfg, requested_llm_model)
    except Exception as exc:
        logger.exception("[%s] ✗ LLM model resolve failed", req_id)
        metrics.event("talk_model_resolve_failed", req_id=req_id, error=str(exc))
        raise HTTPException(status_code=500, detail=f"LLM model resolve failed: {exc}") from exc

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
            language=language,
        )
    except Exception as exc:
        logger.exception("[%s] ✗ prompt build failed", req_id)
        metrics.event("talk_prompt_failed", req_id=req_id, error=str(exc))
        raise HTTPException(status_code=500, detail=f"prompt build failed: {exc}") from exc

    t_llm_start = time.perf_counter()
    try:
        talk_text = await llm_client.generate_text(
            cfg=cfg,
            model=llm_model,
            prompt=prompt,
        )
        talk_text = postprocess_talk_text(talk_text)
        talk_text = clamp_talk_length(talk_text, talk_length)
    except Exception as exc:
        elapsed = time.perf_counter() - t_llm_start
        logger.error("[%s] ✗ LLM failed (%.1fs): %s", req_id, elapsed, exc)
        metrics.event("talk_llm_failed", req_id=req_id, elapsed=elapsed, error=str(exc))
        raise HTTPException(status_code=500, detail=f"LLM failed: {exc}") from exc

    t_llm_done = time.perf_counter()
    llm_time = t_llm_done - t_llm_start
    logger.info(
        '[%s] LLM %.1fs → "%s..." (%d chars)',
        req_id,
        llm_time,
        talk_text[:40].replace("\n", " "),
        len(talk_text),
    )

    if is_disconnected and await is_disconnected():
        logger.debug("[%s] client disconnected after LLM — aborting TTS", req_id)
        metrics.event("talk_cancelled_before_tts", req_id=req_id)
        raise HTTPException(status_code=499, detail="Client disconnected")

    t_tts_start = time.perf_counter()
    try:
        audio_bytes = await tts_client.synthesize_speech(
            cfg=cfg,
            text=talk_text,
            speaker_override=tts_speaker,
        )
    except Exception as exc:
        elapsed = time.perf_counter() - t_tts_start
        logger.error("[%s] ✗ TTS failed (%.1fs): %s", req_id, elapsed, exc)
        metrics.event("talk_tts_failed", req_id=req_id, elapsed=elapsed, error=str(exc))
        raise HTTPException(status_code=500, detail=f"TTS failed: {exc}") from exc

    t_tts_done = time.perf_counter()
    tts_time = t_tts_done - t_tts_start
    total_time = t_tts_done - t0
    audio_format = cfg["tts"].get("audio_format", "mp3")

    logger.info(
        "[%s] TTS %.1fs → %d bytes (%s)",
        req_id,
        tts_time,
        len(audio_bytes),
        audio_format,
    )
    logger.info("[%s] DONE %.1fs total", req_id, total_time)

    program_memory.remember_talk(
        text=talk_text,
        next_track=body.next_track,
        previous_track=body.previous_track,
    )
    metrics.event(
        "talk_done",
        req_id=req_id,
        llm_time=llm_time,
        tts_time=tts_time,
        total_time=total_time,
        audio_bytes=len(audio_bytes),
    )

    return TalkResult(
        audio_bytes=audio_bytes,
        content_type=content_type_for_format(audio_format),
        headers={
            "X-VoidFM-LLM-Time": f"{llm_time:.2f}",
            "X-VoidFM-TTS-Time": f"{tts_time:.2f}",
            "X-VoidFM-Total-Time": f"{total_time:.2f}",
        },
        text=talk_text,
        llm_time=llm_time,
        tts_time=tts_time,
        total_time=total_time,
    )
