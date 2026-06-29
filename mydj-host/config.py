from __future__ import annotations

import sys
import logging
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib  # type: ignore[no-redef]

logger = logging.getLogger(__name__)

_CONFIG_PATH = Path(__file__).parent / "config.toml"

_REQUIRED_KEYS_COMMON: list[tuple[str, str]] = [
    ("server", "port"),
    ("server", "host"),
    ("dj", "default_language"),
    ("dj", "default_talk_length"),
]

_REQUIRED_KEYS_LLM_OLLAMA: list[tuple[str, str]] = [
    ("llm", "ollama_url"),
]

_REQUIRED_KEYS_LLM_OPENAI_COMPATIBLE: list[tuple[str, str]] = [
    ("llm", "base_url"),
]

_REQUIRED_KEYS_TTS_HTTP: list[tuple[str, str]] = [
    ("tts", "fish_speech_url"),
    ("tts", "default_speaker"),
]

_REQUIRED_KEYS_TTS_SUBPROCESS: list[tuple[str, str]] = [
    ("tts", "s2_binary"),
    ("tts", "s2_model"),
    ("tts", "s2_tokenizer"),
]


def load_config() -> dict:
    if not _CONFIG_PATH.exists():
        logger.critical(
            "config.toml が見つかりません。config.toml.example をコピーして編集してください。"
        )
        sys.exit(1)

    with _CONFIG_PATH.open("rb") as f:
        config = tomllib.load(f)

    config.setdefault("llm", {})
    config["llm"].setdefault("default_model", "auto")

    llm_provider = config.get("llm", {}).get("provider", "ollama")
    llm_provider = str(llm_provider).lower().replace("-", "_")
    if llm_provider == "openai":
        llm_provider = "openai_compatible"

    tts_mode = config.get("tts", {}).get("mode", "http")

    if llm_provider not in ("ollama", "openai_compatible"):
        logger.critical("Unsupported llm.provider: %r", llm_provider)
        sys.exit(1)

    if tts_mode not in ("http", "subprocess", "s2_server"):
        logger.critical("Unsupported tts.mode: %r", tts_mode)
        sys.exit(1)

    llm_keys = (
        _REQUIRED_KEYS_LLM_OPENAI_COMPATIBLE
        if llm_provider == "openai_compatible"
        else _REQUIRED_KEYS_LLM_OLLAMA
    )
    mode_keys = (
        _REQUIRED_KEYS_TTS_SUBPROCESS if tts_mode in ("subprocess", "s2_server")
        else _REQUIRED_KEYS_TTS_HTTP
    )

    missing: list[str] = []
    for section, key in _REQUIRED_KEYS_COMMON + llm_keys + mode_keys:
        if section not in config or key not in config[section]:
            missing.append(f"[{section}].{key}")

    if missing:
        logger.critical(
            "config.toml に必須キーがありません: %s", ", ".join(missing)
        )
        sys.exit(1)

    # ポート番号の検証
    port = config["server"]["port"]
    if not isinstance(port, int) or not (1 <= port <= 65535):
        logger.critical("Invalid port number: %d (must be 1-65535)", port)
        sys.exit(1)
    
    # ホスト名の検証
    host = config["server"]["host"]
    if not isinstance(host, str) or not host:
        logger.critical("Invalid host: %r (must be non-empty string)", host)
        sys.exit(1)
    
    # TTS subprocess/s2_server モードの場合、ファイルパスの検証
    if tts_mode in ("subprocess", "s2_server"):
        config_dir = _CONFIG_PATH.parent
        for key in ["s2_binary", "s2_model", "s2_tokenizer"]:
            path = config["tts"].get(key)
            resolved = Path(path)
            if path and not resolved.is_absolute():
                resolved = config_dir / resolved
            if path and not resolved.exists():
                logger.warning("TTS resource not found: %s (path: %s)", key, path)

        for key in ["default_ref_audio"]:
            path = config["tts"].get(key)
            if path:
                resolved = Path(path)
                if not resolved.is_absolute():
                    resolved = config_dir / resolved
                if not resolved.exists():
                    logger.warning("TTS resource not found: %s (path: %s)", key, path)

    return config


_config: dict | None = None


def get_config() -> dict:
    global _config
    if _config is None:
        _config = load_config()
    return _config
