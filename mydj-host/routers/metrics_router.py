from __future__ import annotations

from fastapi import APIRouter

from models.schemas import MetricsResponse
import services.runtime_metrics as runtime_metrics
import services.talk_jobs as talk_jobs

router = APIRouter()


@router.get("/metrics", response_model=MetricsResponse)
async def get_metrics() -> MetricsResponse:
    counters, events = runtime_metrics.snapshot()
    return MetricsResponse(
        counters=counters,
        recent_jobs=talk_jobs.recent_statuses(),
        recent_events=list(reversed(events[-50:])),
    )
