from __future__ import annotations

import logging
import random
from datetime import datetime, timedelta
from typing import Optional

import httpx

from models.schemas import TrackInfo
import services.program_memory as program_memory

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# 言語設定
# ---------------------------------------------------------------------------

_LANGUAGE_CONFIG: dict[str, dict] = {
    "en": {
        "label": "English",
        "output_instruction": "Deliver the airbreak in natural English.",
        "style_note": "",
    },
    "ja": {
        "label": "日本語",
        "output_instruction": (
            "Deliver the airbreak entirely in natural Japanese (日本語). "
            "Use casual, spoken Japanese — the relaxed conversational style you'd hear on FM radio. "
            "English loanwords (カタカナ) are fine where they sound natural. "
            "Do NOT output any English sentences."
        ),
        "style_note": "Japanese radio style: short sentences, natural pauses implied by rhythm, light particle use.",
    },
    "zh": {
        "label": "中文",
        "output_instruction": (
            "Deliver the airbreak entirely in natural Mandarin Chinese (普通话). "
            "Use casual, conversational style — not written or formal Chinese."
        ),
        "style_note": "",
    },
    "ko": {
        "label": "한국어",
        "output_instruction": (
            "Deliver the airbreak entirely in natural Korean (한국어). "
            "Use casual conversational style."
        ),
        "style_note": "",
    },
    "fr": {
        "label": "Français",
        "output_instruction": "Deliver the airbreak entirely in natural, conversational French.",
        "style_note": "",
    },
    "de": {
        "label": "Deutsch",
        "output_instruction": "Deliver the airbreak entirely in natural, conversational German.",
        "style_note": "",
    },
    "es": {
        "label": "Español",
        "output_instruction": "Deliver the airbreak entirely in natural, conversational Spanish.",
        "style_note": "",
    },
}

_DEFAULT_LANGUAGE = "en"


def _get_language_config(language: Optional[str]) -> dict:
    return _LANGUAGE_CONFIG.get(language or _DEFAULT_LANGUAGE, _LANGUAGE_CONFIG[_DEFAULT_LANGUAGE])


# 天気情報のキャッシュ（都市 -> (取得時刻, 天気文字列)）
_weather_cache: dict[str, tuple[datetime, str]] = {}
_WEATHER_CACHE_TTL = 3600  # 1時間

# ---------------------------------------------------------------------------
# 長さ指示
# ---------------------------------------------------------------------------

_LENGTH_INSTRUCTIONS: dict[str, str] = {
    "short":  "LENGTH: Aim for 20–35 words. One tight thought, then out.",
    "medium": "LENGTH: Aim for 50–80 words. Two or three beats — bit, track mention, move on.",
    "long":   "LENGTH: Aim for 90–130 words. Take your time: open strong, develop the bit, land the track intro.",
}

# ---------------------------------------------------------------------------
# DJ パーソナリティ定義
# ---------------------------------------------------------------------------

_PERSONALITIES: dict[str, dict] = {
    "standard": {
        "persona": "a charismatic late-night radio DJ",
        "style": "Warm, loose, and believable — the natural confidence of someone who has done this for years. "
                 "Let observations breathe. Sound like you're talking to one person, not a crowd.",
        "joke_rate": 0.45,
        "emotions": "(excited)\n  (laugh)",
        "house_rules": (
            "- Deliver the airbreak like a seasoned pro: relaxed timing, no rushing.\n"
            "- A small pause of thought is fine — don't fill every gap with filler words.\n"
            "- Keep one foot in the music: the track intro should feel like a natural landing."
        ),
    },
    "energetic": {
        "persona": "a high-energy club and festival DJ",
        "style": "Punchy, fast, and infectious. Every sentence should feel like it's pushing the energy forward. "
                 "Short bursts, no meandering.",
        "joke_rate": 0.35,
        "emotions": "(excited)",
        "house_rules": (
            "- Open with impact — first word should land hard.\n"
            "- Sentences are short. Fragments are fine when they hit right.\n"
            "- The track intro is a hype moment, not a footnote — sell it."
        ),
    },
    "chill": {
        "persona": "a mellow late-night radio host",
        "style": "Soft, unhurried. Speak like you're having a quiet conversation at 2 AM with a friend who "
                 "can't sleep. Dry humor and odd little thoughts welcome.",
        "joke_rate": 0.40,
        "emotions": "(sigh)\n  (laugh)",
        "house_rules": (
            "- Never rush. Let ideas trail off naturally before landing.\n"
            "- Lowercase energy: small observations, not big announcements.\n"
            "- The track intro can be almost an afterthought — whisper it in."
        ),
    },
    "intellectual": {
        "persona": "a knowledgeable music critic and cultural radio host",
        "style": "Thoughtful and specific. Draw unexpected connections between music, culture, and everyday life. "
                 "Make the listener feel like they just learned something without being lectured.",
        "joke_rate": 0.25,
        "emotions": "(sigh)",
        "house_rules": (
            "- Lead with an insight, not a punchline.\n"
            "- If you reference an album or artist, say something true and specific about them.\n"
            "- The track intro should feel earned — the end of a thought, not a pivot."
        ),
    },
    "comedian": {
        "persona": "a comedy radio DJ who treats every airbreak as a mini stand-up set",
        "style": "Always land a joke, pun, or absurd aside. Structure: setup → punchline → music pivot. "
                 "Speed is your friend. Commit to the bit.",
        "joke_rate": 0.85,
        "emotions": "(laugh)\n  (excited)",
        "house_rules": (
            "- The bit IS the airbreak. Music info is just the closing tag.\n"
            "- If the joke doesn't land in two sentences, cut it and try something else.\n"
            "- Self-deprecating, absurdist, or observational — any style is fine, but commit fully."
        ),
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
        20,
        "song hype intro",
        "Build genuine anticipation for the next track. Talk it up like a DJ who loves this song — "
        "mention what makes it special (the drop, the hook, the vibe, the memory it triggers). "
        "Make the listener lean in before it starts.",
    ),
    (
        16,
        "offbeat observation",
        "Open with a small, funny observation about ordinary life. It does not need to connect to the songs.",
    ),
    (
        12,
        "micro-rant",
        "Do a harmless tiny rant about something trivial, like cables, parking lots, app updates, vending machines, or office lighting.",
    ),
    (
        11,
        "fictional listener message",
        "Pretend a listener sent a strange but believable message. Keep it brief and clearly playful.",
    ),
    (
        11,
        "fake station business",
        "Invent a quick VoidFM station announcement, fake sponsor tease, or studio mishap. Make it satirical and obviously fictional.",
    ),
    (
        10,
        "music bridge",
        "Make a natural, specific bridge from the previous track to the next — a shared mood, contrasting energy, "
        "or an unexpected sonic link. Sound like you curated this transition on purpose.",
    ),
    (
        8,
        "absurd local bulletin",
        "Give a tiny fictional local bulletin or public-service aside, then move on like it was normal.",
    ),
    (
        7,
        "personal anecdote",
        "Share a one-sentence DJ anecdote or confession that feels human and a little funny.",
    ),
    (
        3,
        "listener interaction",
        "Talk directly to the listener with a playful question or challenge, without requiring an answer.",
    ),
    (
        2,
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

    if 5 <= hour < 12:
        time_label = "morning"
    elif 12 <= hour < 17:
        time_label = "afternoon"
    elif 17 <= hour < 21:
        time_label = "evening"
    else:
        time_label = "night"

    time_str = now.strftime("%-I:%M %p")
    date_str = now.strftime("%B %-d (%A)")

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
    items = " → ".join(_track_label(t) for t in filtered[-4:])
    return f"■ Recently played (oldest first): {items}\n"


def _track_label(t: TrackInfo) -> str:
    base = f"\"{t.title}\" by {t.artist}"
    if t.album:
        base += f" (from {t.album})"
    return base


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
    language: str | None = None,
) -> str:
    cfg = cfg or {}
    if weather_city:
        cfg = {**cfg, "dj": {**cfg.get("dj", {}), "weather_city": weather_city}}

    # 言語: 引数 → config.toml → デフォルト(en) の優先順
    resolved_language = language or cfg.get("dj", {}).get("default_language") or _DEFAULT_LANGUAGE

    context = await _get_context(cfg)
    pcfg = _get_personality(personality)
    lcfg = _get_language_config(resolved_language)

    length_instruction = _LENGTH_INSTRUCTIONS.get(talk_length, _LENGTH_INSTRUCTIONS["medium"])

    prompt = _build(
        context, pcfg, lcfg, next_track, previous_track,
        length_instruction, is_mid_song, username, dj_name, custom_prompt, track_history,
    )

    logger.debug(
        "Built prompt (personality=%s, language=%s, mid_song=%s): %s",
        personality, resolved_language, is_mid_song, prompt,
    )
    return prompt


def _build(
    context: str,
    pcfg: dict,
    lcfg: dict,
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

    output_instruction = lcfg["output_instruction"]
    style_note_line = f"\n{lcfg['style_note']}" if lcfg.get("style_note") else ""

    if is_mid_song:
        bit_name, bit_instruction = _pick_airbreak_bit()
        return (
            f"{context}\n\n"
            f"You are {persona}. {style}\n"
            f"{name_line}{username_line}"
            f"{output_instruction}{style_note_line}\n"
            "Give a short, natural mid-song radio comment. It may be off-topic. "
            f"Today's bit type: {bit_name}. {bit_instruction} "
            "Always complete your sentences fully. "
            "Output only the talk itself, no preamble.\n\n"
            f"Now playing: {_track_label(next_track)}\n\n"
            f"{emo}\n\n"
            f"{length_instruction}"
            f"{custom_line}"
        )

    # ---- Void Talk ----
    history_line = _history_line(track_history, previous_track)
    prev_line = (
        f"■ Previous track (just ended): {_track_label(previous_track)}\n"
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
        next_line = f"■ Next track (about to play): {_track_label(next_track)}\n"

    bit_name, bit_instruction = _pick_airbreak_bit()

    if previous_track and not same_track:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Open with the selected bit — this is the main flavor.\n"
            "2. Mention the previous track only if it helps the flow; otherwise skip it.\n"
            "3. Land the plane by introducing the next track naturally. "
            "If the bit is 'song hype intro', steps 1 and 3 can merge — spend the whole airbreak selling the next track."
        )
    elif previous_track and same_track:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Open with the selected bit — this is the main flavor.\n"
            "2. Avoid naming the same song twice.\n"
            "3. Tease that another track is coming next, without naming a song title."
        )
    else:
        structure = (
            "Structure the airbreak as one flowing live-radio moment:\n"
            "1. Open with the selected bit — this is the main flavor.\n"
            "2. Introduce the next track naturally near the end. "
            "If the bit is 'song hype intro', spend the whole airbreak building anticipation for the next track."
        )

    joke = _joke_hint(pcfg)
    joke_line = f"\n[Extra instruction: {joke}]" if joke else ""

    guidelines = (
        "## ROLE & TASK\n"
        f"You are {persona}.\n"
        f"{style}\n\n"
        f"The music is currently paused. {output_instruction}{style_note_line}\n"
        "Think of a satirical open-world game radio station: alive, funny, slightly weird, and not always about music.\n\n"
        "## PERFORMANCE STYLE\n"
        f"{pcfg.get('house_rules', '')}\n\n"
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
