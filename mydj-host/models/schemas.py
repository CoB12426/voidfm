from __future__ import annotations

from typing import Optional
from pydantic import BaseModel, field_validator


class TrackInfo(BaseModel):
    title: str
    artist: str
    album: Optional[str] = None
    
    @field_validator('title', 'artist')
    @classmethod
    def validate_non_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError('Title and artist must be non-empty strings')
        return v.strip()


class DjPreferences(BaseModel):
    llm_model: Optional[str] = None
    language: Optional[str] = None       # "ja" | "en"
    talk_length: Optional[str] = None    # "short" | "medium" | "long"
    dj_voice: Optional[str] = None       # "default" | "JAMES" | "E-GIRL" | "ETHAN"
    weather_city: Optional[str] = None   # city name or "lat,lon"; overrides config.toml
    personality: Optional[str] = None    # "standard" | "energetic" | "chill" | "intellectual" | "comedian"


class TalkRequest(BaseModel):
    current_track: TrackInfo                    # 次の曲（void talk 後に再生される曲）
    previous_track: Optional[TrackInfo] = None  # 直前に終わった曲
    preferences: Optional[DjPreferences] = None
    is_mid_song: bool = False                   # 廃止予定、互換性のため残す


class PingResponse(BaseModel):
    status: str
    version: str


class ConfigResponse(BaseModel):
    llm_models: list[str]
    default_llm: str
    tts_speakers: list[str]
    default_speaker: str
    server_version: str
