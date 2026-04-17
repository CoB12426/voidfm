from __future__ import annotations

import logging
import random

logger = logging.getLogger(__name__)

# ステーションIDフレーズ一覧
_PHRASES: list[str] = [
    "VoidFM.",
    "You're listening to VoidFM.",
    "This is VoidFM.",
    "VoidFM — your personal radio.",
    "VoidFM. Music, always.",
    "You're tuned in to VoidFM.",
    "VoidFM. Let the music play.",
    "VoidFM. This is your station.",
]

# 事前生成した音声キャッシュ（起動時の warmup で埋める）
_audio_cache: list[bytes] = []


async def warmup(cfg: dict) -> None:
    """全フレーズを TTS で生成してキャッシュする（起動時のみ呼ぶ）。"""
    import services.tts_client as tts_client
    _audio_cache.clear()
    for phrase in _PHRASES:
        try:
            audio = await tts_client.synthesize_speech(cfg=cfg, text=phrase)
            _audio_cache.append(audio)
            logger.info("[station_id] cached: %r (%d bytes)", phrase, len(audio))
        except Exception as e:
            logger.warning("[station_id] pre-gen failed for %r: %s", phrase, e)
    logger.info("[station_id] warmup done: %d/%d phrases cached", len(_audio_cache), len(_PHRASES))


async def get_audio(cfg: dict) -> bytes:
    """キャッシュからランダムに 1 件返す。キャッシュ未生成なら動的生成。"""
    if _audio_cache:
        return random.choice(_audio_cache)
    # フォールバック: キャッシュが空なら 1 件だけ生成
    import services.tts_client as tts_client
    phrase = random.choice(_PHRASES)
    logger.warning("[station_id] cache empty, generating on demand: %r", phrase)
    return await tts_client.synthesize_speech(cfg=cfg, text=phrase)
