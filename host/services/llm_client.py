from __future__ import annotations

import asyncio
import os
import logging
from urllib.parse import urlsplit, urlunsplit

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


def _provider(cfg: dict) -> str:
    return cfg.get("llm", {}).get("provider", "ollama").lower().replace("-", "_")


def _resolve_secret(value: str | None) -> str | None:
    if not value:
        return None
    if value.startswith("env:"):
        return os.getenv(value.removeprefix("env:"))
    return value


def _auth_headers(cfg: dict) -> dict[str, str]:
    llm = cfg.get("llm", {})
    api_key = _resolve_secret(llm.get("api_key"))
    if not api_key and llm.get("api_key_env"):
        api_key = os.getenv(str(llm["api_key_env"]))
    if not api_key:
        return {}
    return {"Authorization": f"Bearer {api_key}"}


def _normalize_base_url(url: str) -> str:
    url = url.strip()
    if "://" not in url:
        url = "http://" + url
    parts = urlsplit(url)
    path = parts.path
    while "//" in path:
        path = path.replace("//", "/")
    path = path.rstrip("/")
    return urlunsplit((parts.scheme, parts.netloc, path, "", ""))


def _join_url(base_url: str, path: str) -> str:
    return f"{_normalize_base_url(base_url)}/{path.lstrip('/')}"


async def generate_text(cfg: dict, model: str, prompt: str) -> str:
    provider = _provider(cfg)
    if provider in ("openai", "openai_compatible"):
        return await _generate_openai_compatible(cfg=cfg, model=model, prompt=prompt)
    if provider == "ollama":
        return await _generate_ollama(cfg=cfg, model=model, prompt=prompt)
    raise ValueError(f"Unsupported llm.provider: {provider!r}")


async def resolve_model(cfg: dict, preferred_model: str | None = None) -> str:
    """Return the model to request.

    Use "auto" to follow the currently loaded model reported by the provider.
    For llama.cpp's OpenAI-compatible server this keeps VoidFM from being tied
    to a stale model name when the local model is swapped.
    """
    provider = _provider(cfg)
    configured_model = str(cfg.get("llm", {}).get("default_model") or "auto").strip()
    requested_model = str(preferred_model or "").strip()
    candidate = requested_model or configured_model

    if candidate.lower() == "auto":
        models = await list_models(cfg)
        if not models:
            raise ValueError("No LLM models reported by provider; cannot resolve default_model='auto'")
        return models[0]

    if provider in ("openai", "openai_compatible"):
        try:
            models = await list_models(cfg)
        except Exception as exc:
            logger.warning("Could not validate LLM model %r against provider models: %s", candidate, exc)
            return candidate

        if models and candidate not in models:
            logger.info(
                "Requested LLM model %r is not available; using current provider model %r",
                candidate,
                models[0],
            )
            return models[0]

    return candidate


async def _generate_ollama(cfg: dict, model: str, prompt: str) -> str:
    ollama_url: str = cfg["llm"]["ollama_url"]
    url = f"{ollama_url.rstrip('/')}/api/generate"
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "keep_alive": cfg["llm"].get("keep_alive", "10m"),
    }
    logger.debug("Requesting Ollama LLM: model=%s", model)
    
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


async def _generate_openai_compatible(cfg: dict, model: str, prompt: str) -> str:
    llm = cfg["llm"]
    base_url: str = llm["base_url"]
    url = _join_url(base_url, "chat/completions")
    payload: dict = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
    }
    if "temperature" in llm:
        payload["temperature"] = llm["temperature"]
    if "max_tokens" in llm:
        payload["max_tokens"] = llm["max_tokens"]
    if "chat_template_kwargs" in llm:
        payload["chat_template_kwargs"] = llm["chat_template_kwargs"]

    logger.debug("Requesting OpenAI-compatible LLM: base_url=%s model=%s", base_url, model)

    client = _get_http_client()
    for attempt in range(_MAX_RETRIES + 1):
        try:
            response = await client.post(
                url,
                json=payload,
                headers=_auth_headers(cfg),
                timeout=_TIMEOUT_GENERATE,
            )
            response.raise_for_status()
            data = response.json()
            choices = data.get("choices") or []
            if not choices:
                raise ValueError("OpenAI-compatible response has no choices")
            choice = choices[0]
            text = (
                choice.get("message", {}).get("content")
                or choice.get("text")
                or ""
            ).strip()
            if not text:
                message = choice.get("message", {})
                if isinstance(message, dict) and message.get("reasoning_content"):
                    raise ValueError(
                        "OpenAI-compatible response had empty message.content "
                        "and non-empty reasoning_content. Disable reasoning/thinking "
                        "or adjust the llama.cpp chat template so final text is emitted in content."
                    )
                raise ValueError("OpenAI-compatible response text was empty")
            logger.debug("LLM response length: %d chars", len(text))
            return text
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as e:
            if attempt < _MAX_RETRIES:
                logger.warning(
                    "LLM request failed (attempt %d/%d): %s. Retrying...",
                    attempt + 1,
                    _MAX_RETRIES + 1,
                    e,
                )
                await asyncio.sleep(_RETRY_DELAY * (2 ** attempt))
            else:
                logger.error("LLM request failed after %d attempts", _MAX_RETRIES + 1)
                raise


async def list_models(cfg: dict) -> list[str]:
    provider = _provider(cfg)
    if provider in ("openai", "openai_compatible"):
        return await _list_openai_compatible_models(cfg)
    if provider == "ollama":
        return await _list_ollama_models(cfg)
    raise ValueError(f"Unsupported llm.provider: {provider!r}")


async def _list_ollama_models(cfg: dict) -> list[str]:
    ollama_url: str = cfg["llm"]["ollama_url"]
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


async def _list_openai_compatible_models(cfg: dict) -> list[str]:
    base_url: str = cfg["llm"]["base_url"]
    url = _join_url(base_url, "models")
    client = _get_http_client()

    for attempt in range(_MAX_RETRIES + 1):
        try:
            response = await client.get(
                url,
                headers=_auth_headers(cfg),
                timeout=_TIMEOUT_TAGS,
            )
            response.raise_for_status()
            data = response.json()
            models: list[str] = [
                m["id"] for m in data.get("data", [])
                if isinstance(m, dict) and "id" in m
            ]
            logger.debug("Available OpenAI-compatible models: %s", models)
            return models
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as e:
            if attempt < _MAX_RETRIES:
                logger.warning(
                    "Model list request failed (attempt %d/%d): %s. Retrying...",
                    attempt + 1,
                    _MAX_RETRIES + 1,
                    e,
                )
                await asyncio.sleep(_RETRY_DELAY * (2 ** attempt))
            else:
                logger.error("Model list request failed after %d attempts", _MAX_RETRIES + 1)
                raise
