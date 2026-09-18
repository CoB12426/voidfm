from __future__ import annotations

import os
import sys
import logging
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:
    import tomli as tomllib  # type: ignore[no-redef]

logger = logging.getLogger(__name__)

# パッケージ版は VOIDFM_CONFIG で ~/.config/voidfm/config.toml を渡す。
_CONFIG_PATH = Path(
    os.environ.get("VOIDFM_CONFIG") or Path(__file__).parent / "config.toml"
).expanduser()

_REQUIRED_KEYS_COMMON: list[tuple[str, str]] = [
    ("server", "port"),
    ("server", "host"),
    ("dj", "default_talk_length"),
]

_REQUIRED_KEYS_LLM_OLLAMA: list[tuple[str, str]] = [
    ("llm", "ollama_url"),
]

_REQUIRED_KEYS_LLM_OPENAI_COMPATIBLE: list[tuple[str, str]] = [
    ("llm", "base_url"),
]


def load_config() -> dict:
    if not _CONFIG_PATH.exists():
        logger.critical(
            "%s not found. Copy config.toml.example and edit it.",
            _CONFIG_PATH,
        )
        sys.exit(1)

    with _CONFIG_PATH.open("rb") as f:
        config = tomllib.load(f)

    config.setdefault("llm", {})
    config["llm"].setdefault("default_model", "auto")
    _resolve_voice_paths(config, _CONFIG_PATH.parent)

    llm_provider = config.get("llm", {}).get("provider", "ollama")
    llm_provider = str(llm_provider).lower().replace("-", "_")
    if llm_provider == "openai":
        llm_provider = "openai_compatible"

    if llm_provider not in ("ollama", "openai_compatible"):
        logger.critical("Unsupported llm.provider: %r", llm_provider)
        sys.exit(1)

    llm_keys = (
        _REQUIRED_KEYS_LLM_OPENAI_COMPATIBLE
        if llm_provider == "openai_compatible"
        else _REQUIRED_KEYS_LLM_OLLAMA
    )

    missing: list[str] = []
    for section, key in _REQUIRED_KEYS_COMMON + llm_keys:
        if section not in config or key not in config[section]:
            missing.append(f"[{section}].{key}")

    if missing:
        logger.critical(
            "config.toml is missing required keys: %s", ", ".join(missing)
        )
        sys.exit(1)

    port = config["server"]["port"]
    if not isinstance(port, int) or not (1 <= port <= 65535):
        logger.critical("Invalid port number: %d (must be 1-65535)", port)
        sys.exit(1)

    host = config["server"]["host"]
    if not isinstance(host, str) or not host:
        logger.critical("Invalid host: %r (must be non-empty string)", host)
        sys.exit(1)

    return config


def _resolve_voice_paths(config: dict, base_dir: Path) -> None:
    """参照音声の相対パスを config.toml のあるディレクトリ基準にする。"""
    tts = config.get("tts", {})

    def resolve(value: object) -> object:
        if not isinstance(value, str) or not value:
            return value
        path = Path(value).expanduser()
        return str(path if path.is_absolute() else base_dir / path)

    if "default_ref_audio" in tts:
        tts["default_ref_audio"] = resolve(tts["default_ref_audio"])
    voices = tts.get("voices")
    if isinstance(voices, dict):
        for name, value in voices.items():
            voices[name] = resolve(value)


_config: dict | None = None


def get_config() -> dict:
    global _config
    if _config is None:
        _config = load_config()
    return _config
