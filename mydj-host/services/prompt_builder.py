from __future__ import annotations

import logging
import random
from datetime import datetime, timedelta
from typing import Optional

import httpx

from models.schemas import TrackInfo

logger = logging.getLogger(__name__)

# 天気情報のキャッシュ（都市 -> (取得時刻, 天気文字列)）
_weather_cache: dict[str, tuple[datetime, str]] = {}
_WEATHER_CACHE_TTL = 3600  # 1時間

# ---------------------------------------------------------------------------
# 長さ指示
# ---------------------------------------------------------------------------

_LENGTH_INSTRUCTIONS: dict[str, str] = {
    "short":  "Keep your talk to about 15–30 words.",
    "medium": "Keep your talk to about 40–70 words.",
    "long":   "Keep your talk to about 80–110 words.",
}

# ---------------------------------------------------------------------------
# DJ パーソナリティ定義
# ---------------------------------------------------------------------------

_PERSONALITIES: dict[str, dict] = {
    "standard": {
        "persona": "a professional radio DJ",
        "style": "Speak in a calm, warm, professional radio voice. Clear, inviting, and polished.",
        "joke_rate": 0.20,
        "emotions": "(excited)\n  (laugh)",
    },
    "energetic": {
        "persona": "a high-energy club DJ",
        "style": "Maximum energy! Short, punchy bursts. Hype the crowd like you're on a festival stage.",
        "joke_rate": 0.15,
        "emotions": "(excited)",
    },
    "chill": {
        "persona": "a mellow late-night radio host",
        "style": "Soft, unhurried, like a late-night chat with a friend. No rush, just good vibes.",
        "joke_rate": 0.30,
        "emotions": "(sigh)\n  (laugh)",
    },
    "intellectual": {
        "persona": "a knowledgeable music critic and radio host",
        "style": "Thoughtful and articulate — weave in music history, cultural context, and subtle trivia.",
        "joke_rate": 0.10,
        "emotions": "(sigh)",
    },
    "comedian": {
        "persona": "a comedy radio DJ who never misses a chance to make listeners laugh",
        "style": "Always land a joke, pun, or absurd aside. Comedy first — keep it snappy and surprising.",
        "joke_rate": 0.80,
        "emotions": "(laugh)\n  (excited)",
    },
}

_DEFAULT_PERSONALITY = "standard"


def _get_personality(personality: Optional[str]) -> dict:
    return _PERSONALITIES.get(personality or _DEFAULT_PERSONALITY, _PERSONALITIES[_DEFAULT_PERSONALITY])


# ---------------------------------------------------------------------------
# 感情タグガイド
# ---------------------------------------------------------------------------

def _emotion_guide(personality_cfg: dict) -> str:
    return (
        f"You may use these emotion tags (1–2 max, use sparingly):\n"
        f"  {personality_cfg['emotions']}\n"
        "  (sigh)  — a sigh\n"
        "Example: \"What a track! (laugh) Let's keep it going.\""
    )


# ---------------------------------------------------------------------------
# ランダムジョーク指示
# ---------------------------------------------------------------------------

def _joke_hint(personality_cfg: dict) -> str:
    if random.random() < personality_cfg["joke_rate"]:
        return random.choice([
            "Include a quick joke or clever pun related to the song.",
            "Add a funny or surprising fun fact to make the listener smile.",
            "Slip in a witty aside or playful remark.",
        ])
    return ""


# ---------------------------------------------------------------------------
# コンテキスト（日付・時刻・天気）
# ---------------------------------------------------------------------------

async def _get_context(cfg: dict) -> str:
    now = datetime.now()
    hour = now.hour
    minute = now.minute

    # 時間帯（常に含める）
    if 5 <= hour < 12:
        time_label = "morning"
    elif 12 <= hour < 17:
        time_label = "afternoon"
    elif 17 <= hour < 21:
        time_label = "evening"
    else:
        time_label = "night"

    # 時刻
    time_str = now.strftime("%-I:%M %p")

    # 日付・曜日
    date_str = now.strftime("%B %-d (%A)")

    # 天気取得
    city = cfg.get("dj", {}).get("weather_city", "")
    weather_str = ""
    if city:
        if city in _weather_cache:
            cache_time, cached_weather = _weather_cache[city]
            if datetime.now() - cache_time < timedelta(seconds=_WEATHER_CACHE_TTL):
                weather_str = cached_weather
            else:
                del _weather_cache[city]

        if not weather_str and city not in _weather_cache:
            try:
                async with httpx.AsyncClient(timeout=3.0) as client:
                    resp = await client.get(
                        f"https://wttr.in/{city}?format=3",
                        headers={"Accept-Language": "en"},
                    )
                    weather_str = resp.text.strip()
                    _weather_cache[city] = (datetime.now(), weather_str)
            except Exception as e:
                logger.debug("Weather fetch failed: %s", e)

    # ランダムに含める要素を決定
    include_exact_time = random.random() < 0.65
    include_date       = random.random() < 0.40
    include_weather    = bool(weather_str) and random.random() < 0.65

    parts = [time_label]
    if include_exact_time:
        parts.append(time_str)
    if include_date:
        parts.append(date_str)
    if include_weather:
        parts.append(f"weather: {weather_str}")

    return f"[Context: {', '.join(parts)}]"


# ---------------------------------------------------------------------------
# 履歴行
# ---------------------------------------------------------------------------

def _history_line(
    track_history: list | None,
    previous_track: Optional[TrackInfo],
) -> str:
    if not track_history:
        return ""
    prev_key = (previous_track.title, previous_track.artist) if previous_track else None
    filtered = [t for t in track_history if (t.title, t.artist) != prev_key]
    if not filtered:
        return ""
    items = " → ".join(f"\"{t.title}\" by {t.artist}" for t in filtered[-4:])
    return f"■ Recently played (oldest first): {items}\n"


# ---------------------------------------------------------------------------
# プロンプト構築
# ---------------------------------------------------------------------------

async def build_prompt(
    current_track: TrackInfo,
    previous_track: Optional[TrackInfo],
    talk_length: str,
    personality: Optional[str] = None,
    is_mid_song: bool = False,
    cfg: dict | None = None,
    weather_city: str | None = None,
    username: str | None = None,
    dj_name: str | None = None,
    custom_prompt: str | None = None,
    track_history: list | None = None,
) -> str:
    cfg = cfg or {}
    if weather_city:
        cfg = {**cfg, "dj": {**cfg.get("dj", {}), "weather_city": weather_city}}

    context = await _get_context(cfg)
    pcfg = _get_personality(personality)

    length_instruction = _LENGTH_INSTRUCTIONS.get(talk_length, _LENGTH_INSTRUCTIONS["medium"])

    prompt = _build(
        context, pcfg, current_track, previous_track,
        length_instruction, is_mid_song, username, dj_name, custom_prompt, track_history,
    )

    logger.debug("Built prompt (personality=%s, mid_song=%s): %s", personality, is_mid_song, prompt)
    return prompt


def _build(
    context: str,
    pcfg: dict,
    current_track: TrackInfo,
    previous_track: Optional[TrackInfo],
    length_instruction: str,
    is_mid_song: bool,
    username: str | None,
    dj_name: str | None,
    custom_prompt: str | None,
    track_history: list | None,
) -> str:
    persona = pcfg["persona"]
    style   = pcfg["style"]
    emo     = _emotion_guide(pcfg)

    name_line     = f"Your DJ name is \"{dj_name.strip()}\".\n" if dj_name and dj_name.strip() else ""
    username_line = ""
    if username and username.strip() and random.random() < 0.60:
        username_line = f"The listener's name is \"{username.strip()}\". Give them a natural shoutout if it feels right.\n"
    custom_line = f"\n[Custom instructions: {custom_prompt.strip()}]" if custom_prompt and custom_prompt.strip() else ""

    if is_mid_song:
        return (
            f"{context}\n\n"
            f"You are {persona}. {style}\n"
            f"{name_line}{username_line}"
            "Give a short, natural mid-song comment about the track currently playing. "
            "Always complete your sentences fully. "
            "Output only the talk itself, no preamble.\n\n"
            f"Now playing: \"{current_track.title}\" by {current_track.artist}\n\n"
            f"{emo}\n\n"
            f"{length_instruction}"
            f"{custom_line}"
        )

    # ---- Void Talk ----
    history_line = _history_line(track_history, previous_track)
    prev_line = (
        f"■ Previous track (just ended): \"{previous_track.title}\" by {previous_track.artist}\n"
        if previous_track else ""
    )
    same_track = (
        previous_track is not None
        and previous_track.title == current_track.title
        and previous_track.artist == current_track.artist
    )

    if same_track:
        next_line = "■ Next track (about to play): Another track from the queue\n"
    else:
        next_line = f"■ Next track (about to play): \"{current_track.title}\" by {current_track.artist}\n"

    if previous_track and not same_track:
        structure = (
            "Structure your talk naturally around these elements (all in one flowing piece):\n"
            "1. Briefly mention the previous track in a natural way (no closing phrase)\n"
            "2. A casual chat, a joke, OR a comment tied to the time/date/weather (no need to mention them every time)\n"
            "3. Introduce the next track (\"Coming up next is [song]...\")"
        )
    elif previous_track and same_track:
        structure = (
            "Structure your talk naturally around these elements (all in one flowing piece):\n"
            "1. Briefly mention the previous track in a natural way (no closing phrase)\n"
            "2. A casual chat, a joke, OR a comment tied to the time/date/weather (no need to mention them every time)\n"
            "3. Tease that another track is coming next, without naming a song title"
        )
    else:
        structure = (
            "Structure your talk around:\n"
            "1. Introducing the next track\n"
            "2. A casual chat, a joke, OR a comment about the time/date/weather (no need to mention them every time)"
        )

    joke = _joke_hint(pcfg)
    joke_line = f"\n[Extra instruction: {joke}]" if joke else ""

    return (
        f"{context}\n\n"
        f"You are {persona}. {style}\n"
        f"{name_line}{username_line}"
        "The music is paused. Deliver a between-song DJ talk in English. "
        "This radio station is called VoidFM — do not invent or use any other station name. "
        "This is a continuous endless radio program, so do NOT use sign-off/ending phrasing "
        "such as 'wrap up', 'that wraps', 'signing off', 'goodbye', or 'until next time'. "
        "Do not say anything about yesterday or tomorrow — only the current day."
        "Do not use any phrases that suggest the show has ended or is about to end."
        "Do not say 'welcome to VoidFM' or similar — the listener is already tuned in. "
        "Do not call usernames or DJ names more than once per talk, and only if it feels natural. "
        "Always complete your sentences fully — never cut off mid-thought. "
        "Output only the talk itself, no preamble.\n\n"
        f"{history_line}"
        f"{prev_line}"
        f"{next_line}"
        f"\n{structure}"
        f"{joke_line}\n\n"
        f"{emo}\n\n"
        f"{length_instruction}"
        f"{custom_line}"
    )
