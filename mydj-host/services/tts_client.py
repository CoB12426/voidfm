from __future__ import annotations

import asyncio
import heapq
import json
import logging
import os
import tempfile
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncIterator

import httpx
import services.llm_client as llm_client

logger = logging.getLogger(__name__)

_TIMEOUT_TTS = 180.0
_S2_SERVER_START_TIMEOUT = 120.0

# s2.cpp を同時に複数起動すると VRAM が枯渇してクラッシュするため直列化する
class _PriorityGate:
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

_s2_server_process: asyncio.subprocess.Process | None = None
_s2_server_log_tasks: list[asyncio.Task[None]] = []
_owns_s2_server = False


async def startup(cfg: dict) -> None:
    """Start long-lived TTS resources owned by the host process."""
    mode = cfg["tts"].get("mode", "http")
    if mode == "s2_server":
        await _ensure_s2_server(cfg)


async def shutdown() -> None:
    """Stop long-lived TTS resources owned by the host process."""
    global _s2_server_process, _owns_s2_server

    for task in _s2_server_log_tasks:
        task.cancel()
    _s2_server_log_tasks.clear()

    if _s2_server_process is None or not _owns_s2_server:
        _s2_server_process = None
        _owns_s2_server = False
        return

    if _s2_server_process.returncode is None:
        logger.info("[tts] stopping s2.cpp server (pid=%s)", _s2_server_process.pid)
        _s2_server_process.terminate()
        try:
            await asyncio.wait_for(_s2_server_process.wait(), timeout=10.0)
        except asyncio.TimeoutError:
            logger.warning("[tts] s2.cpp server did not stop, killing it")
            _s2_server_process.kill()
            await _s2_server_process.wait()

    _s2_server_process = None
    _owns_s2_server = False


async def synthesize_speech(
    cfg: dict,
    text: str,
    speaker_override: str | None = None,
    priority: str | int = "normal",
) -> bytes:
    mode = cfg["tts"].get("mode", "http")
    if mode == "s2_server":
        return await _synthesize_s2_server(cfg, text, speaker_override, priority)
    if mode == "subprocess":
        return await _synthesize_subprocess(cfg, text, speaker_override, priority)
    return await _synthesize_http(cfg, text, speaker_override)


# ---------------------------------------------------------------------------
# HTTP モード（fish-speech API サーバー）
# ---------------------------------------------------------------------------

async def _synthesize_http(cfg: dict, text: str, speaker_override: str | None = None) -> bytes:
    fish_speech_url: str = cfg["tts"]["fish_speech_url"]
    speaker: str = speaker_override if speaker_override else cfg["tts"].get("default_speaker", "default")
    audio_format: str = cfg["tts"].get("audio_format", "mp3")

    url = f"{fish_speech_url.rstrip('/')}/v1/tts"
    payload: dict = {
        "text": text,
        "format": audio_format,
        "streaming": False,
    }
    if speaker and speaker != "default":
        payload["reference_id"] = speaker

    logger.debug("TTS HTTP: speaker=%s, format=%s, text_length=%d", speaker, audio_format, len(text))

    client = llm_client._get_http_client()
    for attempt in range(2):
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

    logger.debug("TTS HTTP response bytes: %d", len(response.content))
    return response.content


# ---------------------------------------------------------------------------
# s2_server モード（s2.cpp HTTP サーバーをホストと同じ lifespan で管理）
# ---------------------------------------------------------------------------

def _s2_bind_host(cfg: dict) -> str:
    return str(cfg["tts"].get("s2_server_host", "127.0.0.1"))


def _s2_port(cfg: dict) -> int:
    return int(cfg["tts"].get("s2_server_port", 3030))


def _s2_base_url(cfg: dict) -> str:
    if cfg["tts"].get("s2_server_url"):
        return str(cfg["tts"]["s2_server_url"]).rstrip("/")
    host = _s2_bind_host(cfg)
    connect_host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
    return f"http://{connect_host}:{_s2_port(cfg)}"


def _s2_generation_params(cfg: dict) -> dict:
    tts = cfg["tts"]
    params = {}
    for key in (
        "max_new_tokens",
        "temperature",
        "top_p",
        "top_k",
        "min_tokens_before_end",
        "n_threads",
        "verbose",
    ):
        if key in tts:
            params[key] = tts[key]
    return params


async def _drain_process_stream(stream: asyncio.StreamReader | None, name: str) -> None:
    if stream is None:
        return
    while True:
        line = await stream.readline()
        if not line:
            return
        logger.info("[s2.cpp:%s] %s", name, line.decode(errors="replace").rstrip())


async def _is_tcp_open(host: str, port: int, timeout: float = 0.5) -> bool:
    connect_host = "127.0.0.1" if host in ("0.0.0.0", "::") else host
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(connect_host, port),
            timeout=timeout,
        )
        writer.close()
        await writer.wait_closed()
        _ = reader
        return True
    except OSError:
        return False
    except asyncio.TimeoutError:
        return False


def _s2_command(cfg: dict) -> list[str]:
    tts = cfg["tts"]
    cmd = [
        str(tts["s2_binary"]),
        "-m",
        str(tts["s2_model"]),
        "-t",
        str(tts["s2_tokenizer"]),
        "--server",
        "-H",
        _s2_bind_host(cfg),
        "-P",
        str(_s2_port(cfg)),
    ]

    cuda_device = tts.get("cuda_device")
    vulkan_device = tts.get("vulkan_device")
    if isinstance(cuda_device, int) and cuda_device >= 0:
        cmd += ["-c", str(cuda_device)]
    elif isinstance(vulkan_device, int) and vulkan_device >= 0:
        cmd += ["-v", str(vulkan_device)]
    elif tts.get("metal"):
        cmd += ["-M"]

    if "n_threads" in tts:
        cmd += ["-threads", str(tts["n_threads"])]
    if "max_new_tokens" in tts:
        cmd += ["-max-tokens", str(tts["max_new_tokens"])]
    if "temperature" in tts:
        cmd += ["-temp", str(tts["temperature"])]
    if "top_p" in tts:
        cmd += ["-top-p", str(tts["top_p"])]
    if "top_k" in tts:
        cmd += ["-top-k", str(tts["top_k"])]
    if "min_tokens_before_end" in tts:
        cmd += ["--min-tokens-before-end", str(tts["min_tokens_before_end"])]

    return cmd


async def _ensure_s2_server(cfg: dict) -> None:
    global _s2_server_process, _owns_s2_server

    if _s2_server_process and _s2_server_process.returncode is None:
        return

    host = _s2_bind_host(cfg)
    port = _s2_port(cfg)
    if await _is_tcp_open(host, port):
        logger.info("[tts] using existing s2.cpp server at %s", _s2_base_url(cfg))
        _s2_server_process = None
        _owns_s2_server = False
        return

    cmd = _s2_command(cfg)
    logger.info("[tts] starting s2.cpp server: %s", " ".join(cmd))

    env = os.environ.copy()
    ld_library_path = [
        str(Path(cmd[0]).parent),
        "/models",
        env.get("LD_LIBRARY_PATH", ""),
    ]
    env["LD_LIBRARY_PATH"] = ":".join(
        dict.fromkeys(path for path in ld_library_path if path)
    )

    _s2_server_process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        env=env,
    )
    _owns_s2_server = True
    if _s2_server_process.stdout:
        _s2_server_log_tasks.append(
            asyncio.create_task(_drain_process_stream(_s2_server_process.stdout, "stdout"))
        )
    if _s2_server_process.stderr:
        _s2_server_log_tasks.append(
            asyncio.create_task(_drain_process_stream(_s2_server_process.stderr, "stderr"))
        )

    deadline = asyncio.get_running_loop().time() + float(
        cfg["tts"].get("s2_server_start_timeout", _S2_SERVER_START_TIMEOUT)
    )
    while asyncio.get_running_loop().time() < deadline:
        if _s2_server_process.returncode is not None:
            raise RuntimeError(f"s2.cpp server exited early with code {_s2_server_process.returncode}")
        if await _is_tcp_open(host, port, timeout=1.0):
            logger.info("[tts] s2.cpp server ready at %s", _s2_base_url(cfg))
            return
        await asyncio.sleep(0.5)

    message = f"s2.cpp server did not become ready at {_s2_base_url(cfg)}"
    await shutdown()
    raise TimeoutError(message)


def _reference_audio_and_text(
    cfg: dict,
    speaker_override: str | None,
) -> tuple[str | None, str | None]:
    tts = cfg["tts"]
    speaker = speaker_override if speaker_override else tts.get("default_speaker", "default")
    ref_audio: str | None = None
    ref_text: str | None = None

    if speaker and speaker != "default":
        ref_audio = tts.get("voices", {}).get(speaker)
        ref_text = tts.get("voice_texts", {}).get(speaker)

    if not ref_audio:
        ref_audio = tts.get("default_ref_audio")
        ref_text = tts.get("default_ref_text")

    return ref_audio, ref_text


async def _synthesize_s2_server(
    cfg: dict,
    text: str,
    speaker_override: str | None = None,
    priority: str | int = "normal",
) -> bytes:
    async with _tts_slot(priority):
        await _ensure_s2_server(cfg)

        url = f"{_s2_base_url(cfg)}/generate"
        ref_audio, ref_text = _reference_audio_and_text(cfg, speaker_override)
        multipart_fields: list[tuple[str, tuple]] = [("text", (None, text))]
        params = _s2_generation_params(cfg)
        if params:
            multipart_fields.append(("params", (None, json.dumps(params))))

        file_handle = None
        try:
            if ref_audio:
                if not ref_text:
                    raise ValueError(
                        "s2_server voice cloning requires default_ref_text or [tts.voice_texts]."
                    )
                file_handle = Path(ref_audio).open("rb")
                multipart_fields.append(
                    ("reference", (Path(ref_audio).name, file_handle, "audio/wav"))
                )
                multipart_fields.append(("reference_text", (None, ref_text)))

            logger.debug("TTS s2_server: url=%s text_length=%d", url, len(text))
            response = await llm_client._get_http_client().post(
                url,
                files=multipart_fields,
                timeout=_TIMEOUT_TTS,
            )
            response.raise_for_status()
        finally:
            if file_handle:
                file_handle.close()

        content_type = response.headers.get("content-type", "")
        if "audio" not in content_type and "octet-stream" not in content_type:
            raise ValueError(f"TTS response is not audio. content-type={content_type!r}")

        logger.debug("TTS s2_server response bytes: %d", len(response.content))
        return response.content


# ---------------------------------------------------------------------------
# subprocess モード（互換用: s2.cpp バイナリ直接呼び出し）
# ---------------------------------------------------------------------------

async def _synthesize_subprocess(
    cfg: dict,
    text: str,
    speaker_override: str | None = None,
    priority: str | int = "normal",
) -> bytes:
    async with _tts_slot(priority):
        return await _synthesize_subprocess_inner(cfg, text, speaker_override)


async def _synthesize_subprocess_inner(cfg: dict, text: str, speaker_override: str | None = None) -> bytes:
    binary: str = cfg["tts"]["s2_binary"]
    model: str = cfg["tts"]["s2_model"]
    tokenizer: str = cfg["tts"]["s2_tokenizer"]

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        output_path = tmp.name

    cuda_device: int = cfg["tts"].get("cuda_device", 0)
    ref_audio, ref_text = _reference_audio_and_text(cfg, speaker_override)

    cmd = [binary, "-m", model, "-t", tokenizer, "-text", text, "-o", output_path]
    if cuda_device >= 0:
        cmd += ["-c", str(cuda_device)]
    if ref_audio:
        cmd += ["-pa", ref_audio]
    if ref_text:
        cmd += ["-pt", ref_text]

    logger.debug("TTS subprocess: %s", " ".join(cmd))

    env = os.environ.copy()
    ld_library_path = [
        str(Path(binary).parent),
        "/models",
        env.get("LD_LIBRARY_PATH", ""),
    ]
    env["LD_LIBRARY_PATH"] = ":".join(
        dict.fromkeys(path for path in ld_library_path if path)
    )

    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=env,
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=_TIMEOUT_TTS)
        _ = stdout

        if proc.returncode != 0:
            raise RuntimeError(
                f"s2.cpp exited with code {proc.returncode}: {stderr.decode()}"
            )

        wav_bytes = Path(output_path).read_bytes()
        logger.debug("TTS subprocess output bytes: %d", len(wav_bytes))
        return wav_bytes

    finally:
        Path(output_path).unlink(missing_ok=True)
