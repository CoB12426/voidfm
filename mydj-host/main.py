from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from typing import AsyncGenerator

import uvicorn
from fastapi import FastAPI

from config import get_config
from routers.health import router as health_router
from routers.config_router import router as config_router
from routers.talk import router as talk_router
from routers.station_id_router import router as station_id_router
import services.llm_client as llm_client
import services.tts_client as tts_client
import services.station_id as station_id

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


async def _warmup(cfg: dict) -> None:
    """LLM・TTS モデルを起動時にメモリへロードしておく（バックグラウンド）。"""
    # LLM warm-up
    try:
        logger.info("[warmup] LLM loading ...")
        await llm_client.generate_text(
            ollama_url=cfg["llm"]["ollama_url"],
            model=cfg["llm"]["default_model"],
            prompt="Hi",
        )
        logger.info("[warmup] LLM ready")
    except Exception as e:
        logger.warning("[warmup] LLM failed (non-fatal): %s", e)

    # TTS warm-up
    try:
        logger.info("[warmup] TTS loading ...")
        await tts_client.synthesize_speech(cfg=cfg, text="Hello.")
        logger.info("[warmup] TTS ready")
    except Exception as e:
        logger.warning("[warmup] TTS failed (non-fatal): %s", e)

    # Station ID pre-generation
    try:
        await station_id.warmup(cfg)
    except Exception as e:
        logger.warning("[warmup] station_id failed (non-fatal): %s", e)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    cfg = get_config()  # 起動時に設定を検証
    logger.info(
        "mydj-host 起動: host=%s port=%d",
        cfg["server"]["host"],
        cfg["server"]["port"],
    )
    asyncio.create_task(_warmup(cfg))  # バックグラウンドでモデルをプリロード
    yield
    # シャットダウン時にHTTPクライアントをクローズ
    await llm_client.close_http_client()
    logger.info("mydj-host 終了")


app = FastAPI(title="mydj-host", version="1.0", lifespan=lifespan)

app.include_router(health_router)
app.include_router(config_router)
app.include_router(talk_router)
app.include_router(station_id_router)


if __name__ == "__main__":
    cfg = get_config()
    uvicorn.run(
        "main:app",
        host=cfg["server"]["host"],
        port=cfg["server"]["port"],
        reload=False,
    )
