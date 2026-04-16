from __future__ import annotations

import logging
import re

from fastapi import APIRouter, HTTPException
from fastapi.responses import StreamingResponse

from models.schemas import TalkRequest
from config import get_config
import services.llm_client as llm_client
import services.tts_client as tts_client
import services.prompt_builder as prompt_builder

logger = logging.getLogger(__name__)
router = APIRouter()


_EN_CLOSING_PATTERNS: tuple[str, ...] = (
    r"\bwrap(?:ping)?\s+up\b",
    r"\bthat\s+wraps\b",
    r"\bsigning\s+off\b",
    r"\bgoodbye\b",
    r"\buntil\s+next\s+time\b",
)

_JA_CLOSING_PATTERNS: tuple[str, ...] = (
    r"締めくく(?:り|ります?)",
    r"それではまた",
    r"また次回",
    r"またお会いしましょう",
)


def _postprocess_talk_text(text: str, language: str) -> str:
    t = re.sub(r"\s+", " ", text).strip()

    patterns = _JA_CLOSING_PATTERNS if language == "ja" else _EN_CLOSING_PATTERNS
    for p in patterns:
        t = re.sub(p, "", t, flags=re.IGNORECASE).strip(" ,。.!?\t\n")

    if not t:
        return "次の曲をどうぞ。" if language == "ja" else "Here comes the next track."

    # 末尾が途中で切れたようなケースを避けるため、最低限の終端句読点を補う
    if language == "ja":
        if t[-1] not in "。！？":
            t = f"{t}。"
    else:
        if t[-1] not in ".!?":
            t = f"{t}."

    return t


@router.post("/talk")
async def talk(request: TalkRequest) -> StreamingResponse:
    logger.info("Talk request received: current_track=%s, previous_track=%s",
                request.current_track.title, 
                request.previous_track.title if request.previous_track else None)
    
    cfg = get_config()

    # preferences とデフォルト設定をマージ
    prefs = request.preferences
    llm_model  = (prefs.llm_model   if prefs and prefs.llm_model   else None) or cfg["llm"]["default_model"]
    language   = (prefs.language    if prefs and prefs.language    else None) or cfg["dj"]["default_language"]
    talk_length = (prefs.talk_length if prefs and prefs.talk_length else None) or cfg["dj"]["default_talk_length"]
    dj_voice   = (prefs.dj_voice    if prefs and prefs.dj_voice    else None) or cfg["dj"].get("default_voice", "default")
    weather_city = (prefs.weather_city if prefs and prefs.weather_city else None)
    personality = (prefs.personality if prefs and prefs.personality else None)

    # パラメータの検証
    valid_languages = ["ja", "en"]
    if language not in valid_languages:
        logger.warning("Invalid language: %s, using default", language)
        language = cfg["dj"]["default_language"]
    
    valid_lengths = ["short", "medium", "long"]
    if talk_length not in valid_lengths:
        logger.warning("Invalid talk_length: %s, using default", talk_length)
        talk_length = cfg["dj"]["default_talk_length"]

    # プロンプト構築
    try:
        prompt = await prompt_builder.build_prompt(
            current_track=request.current_track,
            previous_track=request.previous_track,
            next_track=request.next_track,
            language=language,
            talk_length=talk_length,
            personality=personality,
            is_mid_song=request.is_mid_song,
            cfg=cfg,
            weather_city=weather_city,
        )
    except Exception as exc:
        logger.exception("Failed to build prompt")
        raise HTTPException(status_code=500, detail=f"プロンプト構築失敗: {exc}") from exc

    # LLM によるトークテキスト生成
    try:
        logger.debug("Generating text with model: %s", llm_model)
        talk_text = await llm_client.generate_text(
            ollama_url=cfg["llm"]["ollama_url"],
            model=llm_model,
            prompt=prompt,
        )
        talk_text = _postprocess_talk_text(talk_text, language)
        logger.info("Generated talk text: %d chars", len(talk_text))
    except Exception as exc:
        logger.exception("LLM generation failed")
        raise HTTPException(status_code=500, detail=f"LLM 生成失敗: {exc}") from exc

    # TTS による音声合成
    try:
        logger.debug("Synthesizing speech with voice: %s", dj_voice)
        wav_bytes = await tts_client.synthesize_speech(
            cfg=cfg,
            text=talk_text,
            dj_voice=dj_voice,
        )
    except Exception as exc:
        logger.exception("TTS synthesis failed")
        raise HTTPException(status_code=500, detail=f"TTS 生成失敗: {exc}") from exc

    logger.info("Returning WAV: %d bytes", len(wav_bytes))
    return StreamingResponse(
        content=iter([wav_bytes]),
        media_type="audio/wav",
    )
