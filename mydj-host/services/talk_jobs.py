from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import time
import uuid
from collections import OrderedDict
from dataclasses import dataclass

from fastapi import HTTPException

from models.schemas import TalkJobStatusResponse, TalkRequest
import services.runtime_metrics as metrics
import services.talk_engine as talk_engine

logger = logging.getLogger(__name__)

_CACHE_MAX_ITEMS = 64
_RECENT_JOB_LIMIT = 50


@dataclass
class TalkJob:
    job_id: str
    body: TalkRequest
    cache_key: str
    status: str
    created_at: float
    priority: int
    started_at: float | None = None
    completed_at: float | None = None
    cancelled_at: float | None = None
    error: str | None = None
    result: talk_engine.TalkResult | None = None
    task: asyncio.Task[talk_engine.TalkResult] | None = None
    cancel_requested: bool = False
    cached: bool = False


_cfg: dict | None = None
_queue: asyncio.PriorityQueue[tuple[int, int, str]] = asyncio.PriorityQueue()
_jobs: OrderedDict[str, TalkJob] = OrderedDict()
_cache: OrderedDict[str, talk_engine.TalkResult] = OrderedDict()
_workers: list[asyncio.Task[None]] = []
_sequence = 0


def _priority_value(priority: str | int) -> int:
    if isinstance(priority, int):
        return priority
    return {
        "high": 0,
        "normal": 10,
        "low": 50,
    }.get(priority, 10)


def _cache_key(body: TalkRequest) -> str:
    payload = body.model_dump(mode="json", exclude_none=True)
    raw = json.dumps(payload, sort_keys=True, ensure_ascii=False)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def _put_cache(key: str, result: talk_engine.TalkResult) -> None:
    _cache[key] = result
    _cache.move_to_end(key)
    while len(_cache) > _CACHE_MAX_ITEMS:
        _cache.popitem(last=False)


def _trim_jobs() -> None:
    while len(_jobs) > _RECENT_JOB_LIMIT:
        first_key = next(iter(_jobs))
        job = _jobs[first_key]
        if job.status in ("queued", "running", "cancelling"):
            break
        _jobs.pop(first_key, None)


async def startup(cfg: dict, workers: int = 1) -> None:
    global _cfg
    _cfg = cfg
    if _workers:
        return
    for index in range(workers):
        _workers.append(asyncio.create_task(_worker(index)))
    logger.info("[talk_jobs] started %d worker(s)", workers)


async def shutdown() -> None:
    for job in list(_jobs.values()):
        job.cancel_requested = True
        if job.task and not job.task.done():
            job.task.cancel()
    for worker in _workers:
        worker.cancel()
    await asyncio.gather(*_workers, return_exceptions=True)
    _workers.clear()
    logger.info("[talk_jobs] stopped")


def submit(body: TalkRequest, priority: str | int = "normal") -> TalkJob:
    global _sequence

    key = _cache_key(body)
    job_id = uuid.uuid4().hex[:12]
    now = time.time()
    priority_value = _priority_value(priority)
    job = TalkJob(
        job_id=job_id,
        body=body,
        cache_key=key,
        status="queued",
        created_at=now,
        priority=priority_value,
    )

    cached = _cache.get(key)
    if cached is not None:
        job.status = "succeeded"
        job.started_at = now
        job.completed_at = now
        job.result = cached
        job.cached = True
        metrics.event("talk_job_cache_hit", job_id=job_id)
    else:
        _sequence += 1
        _queue.put_nowait((priority_value, _sequence, job_id))
        metrics.event("talk_job_queued", job_id=job_id, priority=priority_value)

    _jobs[job_id] = job
    _jobs.move_to_end(job_id)
    _trim_jobs()
    return job


def get(job_id: str) -> TalkJob | None:
    return _jobs.get(job_id)


def cancel(job_id: str) -> bool:
    job = _jobs.get(job_id)
    if job is None:
        return False
    if job.status in ("succeeded", "failed", "cancelled"):
        return True
    job.cancel_requested = True
    job.cancelled_at = time.time()
    if job.status == "queued":
        job.status = "cancelled"
    elif job.status == "running":
        job.status = "cancelling"
        if job.task and not job.task.done():
            job.task.cancel()
    metrics.event("talk_job_cancel_requested", job_id=job_id, status=job.status)
    return True


def audio(job_id: str) -> talk_engine.TalkResult | None:
    job = _jobs.get(job_id)
    if job is None or job.status != "succeeded":
        return None
    return job.result


def status(job: TalkJob) -> TalkJobStatusResponse:
    result = job.result
    return TalkJobStatusResponse(
        job_id=job.job_id,
        status=job.status,
        created_at=job.created_at,
        started_at=job.started_at,
        completed_at=job.completed_at,
        cancelled_at=job.cancelled_at,
        queue_position=_queue_position(job.job_id),
        error=job.error,
        content_type=result.content_type if result else None,
        audio_bytes=len(result.audio_bytes) if result else None,
        llm_time=result.llm_time if result else None,
        tts_time=result.tts_time if result else None,
        total_time=result.total_time if result else None,
        cached=job.cached,
        preview=result.text[:120] if result else None,
    )


def recent_statuses(limit: int = 20) -> list[TalkJobStatusResponse]:
    jobs = list(_jobs.values())[-limit:]
    return [status(job) for job in reversed(jobs)]


def _queue_position(job_id: str) -> int:
    queued_ids = [item[2] for item in list(_queue._queue)]  # noqa: SLF001
    try:
        return queued_ids.index(job_id) + 1
    except ValueError:
        return 0


async def _worker(index: int) -> None:
    while True:
        _priority, _seq, job_id = await _queue.get()
        job = _jobs.get(job_id)
        try:
            if job is None or job.status != "queued":
                continue
            if job.cancel_requested:
                job.status = "cancelled"
                job.cancelled_at = time.time()
                continue

            cached = _cache.get(job.cache_key)
            if cached is not None:
                now = time.time()
                job.status = "succeeded"
                job.started_at = now
                job.completed_at = now
                job.result = cached
                job.cached = True
                metrics.event("talk_job_cache_hit", job_id=job_id)
                continue

            if _cfg is None:
                raise RuntimeError("talk job worker started without config")

            job.status = "running"
            job.started_at = time.time()
            metrics.event("talk_job_started", job_id=job_id, worker=index)
            req_id = f"job:{job.job_id}"

            async def is_cancelled() -> bool:
                return job.cancel_requested

            job.task = asyncio.create_task(
                talk_engine.generate_talk(
                    cfg=_cfg,
                    body=job.body,
                    req_id=req_id,
                    is_disconnected=is_cancelled,
                )
            )
            result = await job.task

            if job.cancel_requested:
                job.status = "cancelled"
                job.cancelled_at = time.time()
                metrics.event("talk_job_cancelled_after_result", job_id=job_id)
                continue

            job.result = result
            job.status = "succeeded"
            job.completed_at = time.time()
            _put_cache(job.cache_key, result)
            metrics.event(
                "talk_job_succeeded",
                job_id=job_id,
                total_time=result.total_time,
                audio_bytes=len(result.audio_bytes),
            )
        except asyncio.CancelledError:
            if job is not None and job.cancel_requested:
                job.status = "cancelled"
                job.cancelled_at = time.time()
                metrics.event("talk_job_cancelled", job_id=job_id)
                continue
            raise
        except HTTPException as exc:
            if job is not None:
                job.status = "failed"
                job.completed_at = time.time()
                job.error = str(exc.detail)
                metrics.event("talk_job_failed", job_id=job_id, error=job.error)
        except Exception as exc:
            logger.exception("[talk_jobs] job failed: %s", job_id)
            if job is not None:
                job.status = "failed"
                job.completed_at = time.time()
                job.error = str(exc)
                metrics.event("talk_job_failed", job_id=job_id, error=job.error)
        finally:
            if job is not None:
                job.task = None
            _queue.task_done()
