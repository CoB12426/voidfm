from __future__ import annotations

import logging
import random

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import Response, StreamingResponse

from models.schemas import (
    TalkJobCreateResponse,
    TalkJobScriptResponse,
    TalkJobStatusResponse,
    TalkRequest,
)
from config import get_config
import services.talk_engine as talk_engine
import services.talk_jobs as talk_jobs

logger = logging.getLogger(__name__)
router = APIRouter()


@router.post("/talk")
async def talk(http_request: Request, body: TalkRequest) -> StreamingResponse:
    req_id = format(random.randint(0, 0xFFFF), "04x")
    cfg = get_config()
    result = await talk_engine.generate_talk(
        cfg=cfg,
        body=body,
        req_id=req_id,
        is_disconnected=http_request.is_disconnected,
    )

    return StreamingResponse(
        content=iter([result.audio_bytes]),
        media_type=result.content_type,
        headers=result.headers,
    )


@router.post("/talk_jobs", response_model=TalkJobCreateResponse)
async def create_talk_job(body: TalkRequest) -> TalkJobCreateResponse:
    job = talk_jobs.submit(body)
    return TalkJobCreateResponse(job_id=job.job_id, status=job.status)


@router.get("/talk_jobs/{job_id}", response_model=TalkJobStatusResponse)
async def get_talk_job(job_id: str) -> TalkJobStatusResponse:
    job = talk_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Talk job not found")
    return talk_jobs.status(job)


@router.get("/talk_jobs/{job_id}/audio")
async def get_talk_job_audio(job_id: str) -> Response:
    result = talk_jobs.audio(job_id)
    if result is None:
        job = talk_jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Talk job not found")
        raise HTTPException(status_code=409, detail=f"Talk job is {job.status}")
    return Response(
        content=result.audio_bytes,
        media_type=result.content_type,
        headers=result.headers,
    )


@router.get("/talk_jobs/{job_id}/script", response_model=TalkJobScriptResponse)
async def get_talk_job_script(job_id: str) -> TalkJobScriptResponse:
    text = talk_jobs.script(job_id)
    if text is None:
        job = talk_jobs.get(job_id)
        if job is None:
            raise HTTPException(status_code=404, detail="Talk job not found")
        raise HTTPException(status_code=409, detail=f"Talk job is {job.status}")
    return TalkJobScriptResponse(job_id=job_id, text=text)


@router.delete("/talk_jobs/{job_id}", response_model=TalkJobStatusResponse)
async def cancel_talk_job(job_id: str) -> TalkJobStatusResponse:
    if not talk_jobs.cancel(job_id):
        raise HTTPException(status_code=404, detail="Talk job not found")
    job = talk_jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="Talk job not found")
    return talk_jobs.status(job)
