from __future__ import annotations

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
import services.llm_client as llm_client

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    cfg = get_config()  # 起動時に設定を検証
    logger.info(
        "mydj-host 起動: host=%s port=%d",
        cfg["server"]["host"],
        cfg["server"]["port"],
    )
    yield
    # シャットダウン時にHTTPクライアントをクローズ
    await llm_client.close_http_client()
    logger.info("mydj-host 終了")


app = FastAPI(title="mydj-host", version="1.0", lifespan=lifespan)

app.include_router(health_router)
app.include_router(config_router)
app.include_router(talk_router)


if __name__ == "__main__":
    cfg = get_config()
    uvicorn.run(
        "main:app",
        host=cfg["server"]["host"],
        port=cfg["server"]["port"],
        reload=False,
    )
