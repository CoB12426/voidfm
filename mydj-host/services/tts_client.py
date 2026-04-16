from __future__ import annotations

import asyncio
import logging
import tempfile
from pathlib import Path

import httpx
import services.llm_client as llm_client

logger = logging.getLogger(__name__)

_TIMEOUT_TTS = 180.0

# s2.cpp を同時に複数起動すると VRAM が枯渇してクラッシュするため直列化する
_tts_semaphore = asyncio.Semaphore(1)


async def synthesize_speech(
    cfg: dict,
    text: str,
    dj_voice: str = "default",
) -> bytes:
    mode = cfg["tts"].get("mode", "http")
    if mode == "subprocess":
        return await _synthesize_subprocess(cfg, text, dj_voice)
    else:
        return await _synthesize_http(cfg, text, dj_voice)


# ---------------------------------------------------------------------------
# HTTP モード（fish-speech API サーバー）
# ---------------------------------------------------------------------------

async def _synthesize_http(cfg: dict, text: str, dj_voice: str = "default") -> bytes:
    fish_speech_url: str = cfg["tts"]["fish_speech_url"]
    speaker: str = dj_voice if dj_voice != "default" else cfg["tts"].get("default_speaker", "default")
    audio_format: str = cfg["tts"].get("audio_format", "mp3")

    url = f"{fish_speech_url.rstrip('/')}/v1/tts"
    payload: dict = {
        "text": text,
        "format": audio_format,
        "streaming": False,
    }
    if speaker and speaker != "default":
        payload["reference_id"] = speaker

    logger.info("TTS HTTP: speaker=%s, format=%s, text_length=%d", speaker, audio_format, len(text))
    
    client = llm_client._get_http_client()
    for attempt in range(2):  # 最大2回リトライ
        try:
            response = await client.post(url, json=payload, timeout=_TIMEOUT_TTS)
            response.raise_for_status()
            break
        except (httpx.TimeoutException, httpx.ConnectError, httpx.NetworkError) as e:
            if attempt == 0:
                logger.warning("TTS HTTP request failed (attempt 1/2): %s. Retrying...", e)
                await asyncio.sleep(1.0)
            else:
                logger.error("TTS HTTP request failed (attempt 2/2)")
                raise

    content_type = response.headers.get("content-type", "")
    if "audio" not in content_type and "octet-stream" not in content_type:
        raise ValueError(f"TTS response is not audio. content-type={content_type!r}")

    logger.info("TTS HTTP response bytes: %d", len(response.content))
    return response.content


# ---------------------------------------------------------------------------
# subprocess モード（s2.cpp バイナリ直接呼び出し）
# ---------------------------------------------------------------------------

async def _synthesize_subprocess(cfg: dict, text: str, dj_voice: str = "default") -> bytes:
    async with _tts_semaphore:
        return await _synthesize_subprocess_inner(cfg, text, dj_voice)


async def _synthesize_subprocess_inner(cfg: dict, text: str, dj_voice: str = "default") -> bytes:
    binary: str = cfg["tts"]["s2_binary"]
    model: str = cfg["tts"]["s2_model"]
    tokenizer: str = cfg["tts"]["s2_tokenizer"]

    # voice ごとの reference audio パスを解決
    # config.toml で [tts.voices] male = "/path/to/male.wav" のように設定
    ref_audio: str | None = None
    if dj_voice != "default":
        voices: dict = cfg["tts"].get("voices", {})
        ref_audio = voices.get(dj_voice)

    # 途中で切れた読み上げを避けるため、ここではテキストを切り詰めない。
    # 長文制御はプロンプト側（talk_length 指示）で行う。

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        output_path = tmp.name

    # GPU デバイス設定（config.toml の [tts] cuda_device で指定、-1 で CPU のみ）
    cuda_device: int = cfg["tts"].get("cuda_device", 0)

    cmd = [binary, "-m", model, "-t", tokenizer, "-text", text, "-o", output_path]
    if cuda_device >= 0:
        cmd += ["-c", str(cuda_device)]  # CUDA GPU を使用
    if ref_audio:
        cmd += ["-pa", ref_audio]  # -ref → -pa (prompt audio)

    logger.info("TTS subprocess: %s", " ".join(cmd))

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_TTS)

        if proc.returncode != 0:
            raise RuntimeError(
                f"s2.cpp exited with code {proc.returncode}: {stderr.decode()}"
            )

        wav_bytes = Path(output_path).read_bytes()
        logger.info("TTS subprocess output bytes: %d", len(wav_bytes))
        return wav_bytes

    finally:
        Path(output_path).unlink(missing_ok=True)
