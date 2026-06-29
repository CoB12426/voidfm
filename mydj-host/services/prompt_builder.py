from __future__ import annotations

import logging
import random
from datetime import datetime, timedelta
from typing import Optional

import httpx

from models.schemas import TrackInfo
import services.program_memory as program_memory

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
        "persona": "a charismatic late-night radio DJ",
        "style": "Warm and believable, with the loose spontaneity of a real live radio host. Let tiny jokes and odd observations breathe.",
        "joke_rate": 0.45,
        "emotions": "(excited)\n  (laugh)",
    },
    "energetic": {
        "persona": "a high-energy club DJ",
        "style": "Fast, punchy, and playful. Hype the room, but also toss in ridiculous little live-radio asides.",
        "joke_rate": 0.35,
        "emotions": "(excited)",
    },
    "chill": {
        "persona": "a mellow late-night radio host",
        "style": "Soft, unhurried, like a late-night chat with a friend. Use dry humor and odd little thoughts.",
        "joke_rate": 0.40,
        "emotions": "(sigh)\n  (laugh)",
    },
    "intellectual": {
        "persona": "a knowledgeable music critic and radio host",
        "style": "Thoughtful and articulate, but not trapped in music trivia. Make culture, daily life, and tiny absurdities sound interesting.",
        "joke_rate": 0.25,
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
            "Include a quick off-topic joke or dry one-liner.",
            "Add a funny fake observation about daily life, radio, technology, food, traffic, or tiny inconveniences.",
            "Slip in a witty aside that sounds improvised, not written.",
        ])
    return ""


# ---------------------------------------------------------------------------
# 雑談・番組ビット
# ---------------------------------------------------------------------------

_AIRBREAK_BITS: tuple[tuple[int, str, str], ...] = (
    (
        18,
        "offbeat observation",
        "Open with a small, funny observation about ordinary life. It does not need to connect to the songs.",
    ),
    (
        14,
        "micro-rant",
        "Do a harmless tiny rant about something trivial, like cables, parking lots, app updates, vending machines, or office lighting.",
    ),
    (
        13,
        "fictional listener message",
        "Pretend a listener sent a strange but believable message. Keep it brief and clearly playful.",
    ),
    (
        13,
        "fake station business",
        "Invent a quick VoidFM station announcement, fake sponsor tease, or studio mishap. Make it satirical and obviously fictional.",
    ),
    (
        12,
        "absurd local bulletin",
        "Give a tiny fictional local bulletin or public-service aside, then move on like it was normal.",
    ),
    (
        10,
        "personal anecdote",
        "Share a one-sentence DJ anecdote or confession that feels human and a little funny.",
    ),
    (
        9,
        "music bridge",
        "Make a natural bridge from the previous track to the next, but avoid sounding like a review.",
    ),
    (
        6,
        "listener interaction",
        "Talk directly to the listener with a playful question or challenge, without requiring an answer.",
    ),
    (
        5,
        "local color",
        "You may use the time or weather as local color, but avoid saying it is a perfect time or perfect weather for music.",
    ),
)


def _pick_airbreak_bit() -> tuple[str, str]:
    total = sum(weight for weight, _, _ in _AIRBREAK_BITS)
    roll = random.randint(1, total)
    upto = 0
    for weight, name, instruction in _AIRBREAK_BITS:
        upto += weight
        if roll <= upto:
            return name, instruction
    _, name, instruction = _AIRBREAK_BITS[0]
    return name, instruction


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

    # 天気・時刻は偏りやすいため、素材として控えめに渡す
    include_exact_time = random.random() < 0.20
    include_date       = random.random() < 0.10
    include_weather    = bool(weather_str) and random.random() < 0.15

    parts = [time_label]
    if include_exact_time:
        parts.append(time_str)
    if include_date:
        parts.append(date_str)
    if include_weather:
        parts.append(f"weather: {weather_str}")

    return f"[Optional live context, use rarely: {', '.join(parts)}]"


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
    next_track: TrackInfo,
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
        context, pcfg, next_track, previous_track,
        length_instruction, is_mid_song, username, dj_name, custom_prompt, track_history,
    )

    logger.debug("Built prompt (personality=%s, mid_song=%s): %s", personality, is_mid_song, prompt)
    return prompt


def _build(
    context: str,
    pcfg: dict,
    next_track: TrackInfo,
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
        bit_name, bit_instruction = _pick_airbreak_bit()
        return (
            f"{context}\n\n"
            f"You are {persona}. {style}\n"
            f"{name_line}{username_line}"
            "Give a short, natural mid-song radio comment. It may be off-topic. "
            f"Today's bit type: {bit_name}. {bit_instruction} "
            "Always complete your sentences fully. "
            "Output only the talk itself, no preamble.\n\n"
            f"Now playing: \"{next_track.title}\" by {next_track.artist}\n\n"
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
        and previous_track.title == next_track.title
        and previous_track.artist == next_track.artist
    )

    if same_track:
        next_line = "■ Next track (about to play): Another track from the queue\n"
    else:
        next_line = f"■ Next track (about to play): \"{next_track.title}\" by {next_track.artist}\n"

    bit_name, bit_instruction = _pick_airbreak_bit()

    if previous_track and not same_track:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Start with the selected off-topic bit or joke. This should be the main flavor.\n"
            "2. Mention the previous track only if it helps the flow; otherwise skip it.\n"
            "3. Land the plane by introducing the next track naturally."
        )
    elif previous_track and same_track:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Start with the selected off-topic bit or joke. This should be the main flavor.\n"
            "2. Avoid naming the same song twice.\n"
            "3. Tease that another track is coming next, without naming a song title."
        )
    else:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Start with the selected off-topic bit or joke. This should be the main flavor.\n"
            "2. Introduce the next track naturally near the end."
        )

    joke = _joke_hint(pcfg)
    joke_line = f"\n[Extra instruction: {joke}]" if joke else ""

    guidelines = (
        "## ROLE & TASK\n"
        f"You are {persona}. {style}\n"
        "The music is currently paused. Deliver a smooth, engaging between-song radio airbreak in English.\n"
        "Think of a satirical open-world game radio station: alive, funny, slightly weird, and not always about music.\n\n"
        "## CRITICAL RULES\n"
        "- Station Name: The station is 'VoidFM'. Never invent or use another station name.\n"
        "- Endless Stream: This is a continuous 24/7 radio program. Never use sign-offs, goodbyes, 'wrap up', or suggest the show is ending.\n"
        "- Immersion: The listener is already tuned in. Do NOT say 'Welcome to VoidFM' or use generic greetings like 'Hey there' or 'Hi everyone'. Dive straight into the talk.\n"
        "- Identity: Do NOT introduce yourself ('This is [DJ name]') unless it feels exceptionally natural in the moment.\n"
        "- Off-topic is good: You may talk about fictional station life, fake listener messages, tiny complaints, food, traffic, gadgets, urban myths, or absurd local news.\n"
        "- Music is not the whole point: Do not make every talk a song review. The next-track intro can be just the final sentence.\n"
        "- Time/weather restraint: Usually do NOT mention the time, date, or weather. Never default to 'perfect weather/time for music'. Use it only when the selected bit asks for local color.\n"
        "- Continuity: Speak only about the current moment context. Do not mention yesterday or tomorrow.\n"
        "- Safety: Keep jokes playful, fictional, and non-hateful. No slurs, explicit sexual content, real-person defamation, or instructions for wrongdoing.\n"
        "- Professionalism: Always complete your sentences fully. Never cut off mid-thought.\n\n"
        "## OUTPUT FORMAT\n"
        "Output ONLY the spoken words for the text-to-speech engine. No quotes, no preamble, no meta-text."
    )
    memory = program_memory.prompt_guidance()

    return (
        f"{context}\n\n"
        f"{guidelines}\n\n"
        f"{memory}\n"
        f"{name_line}{username_line}"
        f"{history_line}"
        f"{prev_line}"
        f"{next_line}"
        f"\n## SELECTED AIRBREAK BIT\n"
        f"{bit_name}: {bit_instruction}\n"
        f"\n{structure}"
        f"{joke_line}\n\n"
        f"{emo}\n\n"
        f"{length_instruction}"
        f"{custom_line}"
    )
