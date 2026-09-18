from __future__ import annotations

import asyncio
import heapq
import io
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

logger = logging.getLogger(__name__)

_TIMEOUT_TTS = 180.0


class _PriorityGate:
    """同時TTS推論を直列化し、VRAMの枯渇を防ぐ。"""

    def __init__(self, capacity: int) -> None:
        self._capacity = capacity
        self._active = 0
        self._counter = 0
        self._waiters: list[tuple[int, int, asyncio.Future[None]]] = []
        self._condition = asyncio.Condition()

    async def acquire(self, priority: int) -> asyncio.Future[None]:
        async with self._condition:
            loop = asyncio.get_running_loop()
            future: asyncio.Future[None] = loop.create_future()
            self._counter += 1
            item = (priority, self._counter, future)
            heapq.heappush(self._waiters, item)
            try:
                while True:
                    is_next = self._waiters and self._waiters[0] is item
                    if self._active < self._capacity and is_next:
                        heapq.heappop(self._waiters)
                        self._active += 1
                        return future
                    await self._condition.wait()
            except BaseException:
                if item in self._waiters:
                    self._waiters.remove(item)
                    heapq.heapify(self._waiters)
                    self._condition.notify_all()
                raise

    async def release(self) -> None:
        async with self._condition:
            self._active = max(0, self._active - 1)
            self._condition.notify_all()


_tts_gate = _PriorityGate(1)


def _priority_value(priority: str | int) -> int:
    if isinstance(priority, int):
        return priority
    return {
        "high": 0,
        "normal": 10,
        "low": 50,
    }.get(priority, 10)


@asynccontextmanager
async def _tts_slot(priority: str | int = "normal") -> AsyncIterator[None]:
    await _tts_gate.acquire(_priority_value(priority))
    try:
        yield
    finally:
        await _tts_gate.release()


_chatterbox_model: object | None = None


async def startup(cfg: dict) -> None:
    """プロセス起動時にTTSリソースを初期化する。"""
    _warn_if_no_voice_reference(cfg)
    await _load_chatterbox_model(cfg)


def _warn_if_no_voice_reference(cfg: dict) -> None:
    tts = cfg["tts"]
    has_default_ref = bool(tts.get("default_ref_audio"))
    has_named_voices = bool(tts.get("voices"))
    if not has_default_ref and not has_named_voices:
        logger.warning(
            "[tts] No reference audio configured. "
            "A random voice is generated each time, so the voice may change between talks. "
            "Set [tts].default_ref_audio in config.toml "
            "or register named voices under [tts.voices]."
        )


async def shutdown() -> None:
    """プロセス終了時にTTSリソースを解放する。"""
    global _chatterbox_model
    _chatterbox_model = None


async def synthesize_speech(
    cfg: dict,
    text: str,
    speaker_override: str | None = None,
    priority: str | int = "normal",
) -> bytes:
    return await _synthesize_chatterbox(cfg, text, speaker_override, priority)


# ---------------------------------------------------------------------------
# Chatterbox TTS（インプロセス推論）
# ---------------------------------------------------------------------------

async def _load_chatterbox_model(cfg: dict) -> None:
    global _chatterbox_model
    tts = cfg["tts"]
    cuda_device = int(tts.get("cuda_device", 0))
    device = "cuda" if cuda_device >= 0 else "cpu"
    model_variant: str = tts.get("chatterbox_model", "multilingual")

    logger.info("[tts] Loading Chatterbox model (device=%s, variant=%s)...", device, model_variant)

    if model_variant == "turbo":
        from chatterbox.tts_turbo import ChatterboxTurboTTS
        _chatterbox_model = await asyncio.to_thread(
            ChatterboxTurboTTS.from_pretrained, device=device
        )
    else:
        from chatterbox.mtl_tts import ChatterboxMultilingualTTS
        _chatterbox_model = await asyncio.to_thread(
            ChatterboxMultilingualTTS.from_pretrained, device=device
        )

    logger.info("[tts] Chatterbox model loaded")


def _reference_audio_path(cfg: dict, speaker_override: str | None) -> str | None:
    tts = cfg["tts"]
    speaker = speaker_override if speaker_override else tts.get("default_speaker", "default")

    if speaker and speaker != "default":
        ref_audio = tts.get("voices", {}).get(speaker)
        if ref_audio:
            return ref_audio

    return tts.get("default_ref_audio")


def _wav_bytes_from_tensor(wav: object, sample_rate: int) -> bytes:
    import soundfile as sf

    audio = wav
    if hasattr(wav, "detach"):
        tensor = wav.detach().cpu()  # type: ignore[attr-defined]
        if tensor.ndim == 2:
            tensor = tensor.transpose(0, 1)
        audio = tensor.numpy()

    buf = io.BytesIO()
    sf.write(buf, audio, int(sample_rate), format="WAV")
    buf.seek(0)
    return buf.read()


def _chatterbox_synthesize_sync(
    model: object,
    text: str,
    ref_audio: str | None,
    exaggeration: float,
    cfg_weight: float,
    model_variant: str,
) -> bytes:
    kwargs: dict = {"exaggeration": exaggeration, "cfg_weight": cfg_weight}
    if ref_audio:
        kwargs["audio_prompt_path"] = ref_audio

    if model_variant == "turbo":
        wav = model.generate(text, **kwargs)  # type: ignore[union-attr]
    else:
        # ChatterboxMultilingualTTS.generate では language_id が必須の位置引数（トークは英語専用）
        wav = model.generate(text, "en", **kwargs)  # type: ignore[union-attr]

    return _wav_bytes_from_tensor(wav, model.sr)  # type: ignore[union-attr]


async def _synthesize_chatterbox(
    cfg: dict,
    text: str,
    speaker_override: str | None = None,
    priority: str | int = "normal",
) -> bytes:
    async with _tts_slot(priority):
        if _chatterbox_model is None:
            await _load_chatterbox_model(cfg)

        tts = cfg["tts"]
        ref_audio = _reference_audio_path(cfg, speaker_override)
        exaggeration = float(tts.get("exaggeration", 0.5))
        cfg_weight = float(tts.get("cfg_weight", 0.5))
        model_variant: str = tts.get("chatterbox_model", "multilingual")

        logger.debug(
            "TTS chatterbox: text_length=%d, ref_audio=%s",
            len(text), ref_audio,
        )

        wav_bytes = await asyncio.to_thread(
            _chatterbox_synthesize_sync,
            _chatterbox_model, text, ref_audio,
            exaggeration, cfg_weight, model_variant,
        )

        logger.debug("TTS chatterbox response bytes: %d", len(wav_bytes))
        return wav_bytes
