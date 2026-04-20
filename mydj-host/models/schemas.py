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
    talk_length: Optional[str] = None    # "short" | "medium" | "long"
    weather_city: Optional[str] = None   # city name or "lat,lon"; overrides config.toml
    personality: Optional[str] = None    # "standard" | "energetic" | "chill" | "intellectual" | "comedian"
    username: Optional[str] = None       # リスナーの名前（任意）
    dj_name: Optional[str] = None        # DJの名前（任意）
    custom_prompt: Optional[str] = None  # ユーザーカスタム指示（任意）


class TalkRequest(BaseModel):
    next_track: TrackInfo                            # Talk 後に再生される曲
    previous_track: Optional[TrackInfo] = None       # Talk 前に終わった曲
    preferences: Optional[DjPreferences] = None
    is_mid_song: bool = False                        # 廃止予定、互換性のため残す
    track_history: Optional[list[TrackInfo]] = None  # 直近の再生履歴（古い順）


class PingResponse(BaseModel):
    status: str
    version: str


class ConfigResponse(BaseModel):
    llm_models: list[str]
    default_llm: str
    tts_speakers: list[str]
    default_speaker: str
    server_version: str
