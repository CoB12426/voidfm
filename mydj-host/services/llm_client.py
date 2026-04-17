from __future__ import annotations

import asyncio
import logging
from contextlib import asynccontextmanager

import httpx

logger = logging.getLogger(__name__)

_TIMEOUT_GENERATE = 120.0
_TIMEOUT_TAGS = 5.0
_MAX_RETRIES = 2
_RETRY_DELAY = 1.0  # 秒

# グローバルHTTPクライアント（接続プーリング・再利用）
_http_client: httpx.AsyncClient | None = None


def _get_http_client() -> httpx.AsyncClient:
    """シングルトンHTTPクライアントを取得。"""
    global _http_client
    if _http_client is None:
        _http_client = httpx.AsyncClient(
            timeout=httpx.Timeout(30.0, connect=10.0),
            limits=httpx.Limits(max_keepalive_connections=5),
        )
    return _http_client


async def close_http_client() -> None:
    """HTTPクライアントをクローズ（アプリケーション終了時に呼ぶ）。"""
    global _http_client
    if _http_client is not None:
        await _http_client.aclose()
        _http_client = None


async def generate_text(
    ollama_url: str,
    model: str,
    prompt: str,
) -> str:
    url = f"{ollama_url.rstrip('/')}/api/generate"
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "keep_alive": 0,  # モデルをメモリに保持し続ける
    }
    logger.debug("Requesting LLM: model=%s", model)
    
    client = _get_http_client()
    for attempt in range(_MAX_RETRIES + 1):
        try:
            response = await client.post(url, json=payload, timeout=_TIMEOUT_GENERATE)
            response.raise_for_status()
            data = response.json()
            text: str = data.get("response", "").strip()
            logger.debug("LLM response length: %d chars", len(text))
            return text
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as e:
            if attempt < _MAX_RETRIES:
                logger.warning("LLM request failed (attempt %d/%d): %s. Retrying...", 
                             attempt + 1, _MAX_RETRIES + 1, e)
                await asyncio.sleep(_RETRY_DELAY * (2 ** attempt))  # exponential backoff
            else:
                logger.error("LLM request failed after %d attempts", _MAX_RETRIES + 1)
                raise


async def list_models(ollama_url: str) -> list[str]:
    url = f"{ollama_url.rstrip('/')}/api/tags"
    client = _get_http_client()
    
    for attempt in range(_MAX_RETRIES + 1):
        try:
            response = await client.get(url, timeout=_TIMEOUT_TAGS)
            response.raise_for_status()
            data = response.json()
            models: list[str] = [m["name"] for m in data.get("models", [])]
            logger.debug("Available Ollama models: %s", models)
            return models
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as e:
            if attempt < _MAX_RETRIES:
                logger.warning("Model list request failed (attempt %d/%d): %s. Retrying...", 
                             attempt + 1, _MAX_RETRIES + 1, e)
                await asyncio.sleep(_RETRY_DELAY * (2 ** attempt))
            else:
                logger.error("Model list request failed after %d attempts", _MAX_RETRIES + 1)
                raise
