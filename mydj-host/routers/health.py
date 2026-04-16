from __future__ import annotations

from fastapi import APIRouter
from models.schemas import PingResponse

router = APIRouter()


@router.get("/ping", response_model=PingResponse)
async def ping() -> PingResponse:
    return PingResponse(status="ok", version="1.0")
