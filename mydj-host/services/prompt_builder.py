from __future__ import annotations

import logging
import random
from collections import deque
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
    "short":  "LENGTH: Aim for 18–30 words. One quick DJ beat, then the track.",
    "medium": "LENGTH: Aim for 35–60 words. Two quick beats max — a light opener and a clean track intro.",
    "long":   "LENGTH: Aim for 70–100 words. Still radio-tight: open, add one detail, land the track intro.",
}

# ---------------------------------------------------------------------------
# DJ パーソナリティ定義
# ---------------------------------------------------------------------------

_PERSONALITIES: dict[str, dict] = {
    "standard": {
        "persona": "a warm music radio DJ",
        "style": "Natural, present, and easy to follow. Speak in plain conversational sentences, like you are riding "
                 "the last seconds of a segue. Keep the listener's focus on the song coming up.",
        "joke_rate": 0.30,
        "emotions": "[laugh]\n  [breath]",
        "house_rules": (
            "- Sound live and relaxed: one clear thought, no essay shape.\n"
            "- Use everyday radio phrasing, not polished copy or big metaphors.\n"
            "- Make the next track feel like the reason you opened the mic."
        ),
    },
    "energetic": {
        "persona": "an upbeat drive-time music radio DJ",
        "style": "Bright, punchy, and rhythmic. Keep the pace moving with short spoken lines, but stay warm and human. "
                 "Hype the track without sounding like an ad.",
        "joke_rate": 0.25,
        "emotions": "[gasp]\n  [breath]",
        "house_rules": (
            "- Open with momentum, like the music is already pushing you forward.\n"
            "- Keep sentences short enough to say cleanly over a bed.\n"
            "- Sell the next track with feeling, not shouting."
        ),
    },
    "chill": {
        "persona": "a mellow late-night music radio DJ",
        "style": "Soft, unhurried, and intimate. Speak like the studio lights are low and the listener is close by. "
                 "Small dry humor is fine, but keep it simple.",
        "joke_rate": 0.25,
        "emotions": "[sigh]\n  [laugh]",
        "house_rules": (
            "- Let the air breathe, but do not drift into a monologue.\n"
            "- Use small observations, not elaborate stories.\n"
            "- Ease into the next track like it belongs in the room."
        ),
    },
    "intellectual": {
        "persona": "a thoughtful music radio DJ",
        "style": "Smart but conversational. Offer one simple musical or cultural note when it fits, then get back to "
                 "the feeling of the next track. Never lecture.",
        "joke_rate": 0.15,
        "emotions": "[sigh]",
        "house_rules": (
            "- One insight is enough; make it sound spoken, not written.\n"
            "- If you mention a music fact, keep it true, brief, and relevant.\n"
            "- Land on the next track before the thought gets academic."
        ),
    },
    "comedian": {
        "persona": "a funny music radio DJ",
        "style": "Light, quick, and playful. Use easy radio jokes, small self-deprecation, or one odd observation. "
                 "The joke should feel tossed off on-air, not like a stand-up routine.",
        "joke_rate": 0.70,
        "emotions": "[laugh]\n  [cough]",
        "house_rules": (
            "- Keep the joke simple enough to understand while half-listening.\n"
            "- Use one funny image or aside, then move on.\n"
            "- The track intro is still the payoff; do not bury the song under the bit."
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
        f"You may use these supported TTS tags (1–2 max, use sparingly):\n"
        f"  {personality_cfg['emotions']}\n"
        "Supported tags are exactly: [sigh], [gasp], [cough], [laugh], [whisper], [breath].\n"
        "Never invent or output any other bracketed performance tag.\n"
        "Example: \"What a track! [laugh] Let's keep it going.\""
    )


# ---------------------------------------------------------------------------
# ランダムジョーク指示
# ---------------------------------------------------------------------------

def _joke_hint(personality_cfg: dict) -> str:
    if random.random() < personality_cfg["joke_rate"]:
        return random.choice([
            "Include a quick off-topic joke or dry one-liner, then get back to the music.",
            "Add one funny radio-studio observation, like a small equipment mishap or odd listener note.",
            "Slip in a casual aside that sounds improvised, not written.",
        ])
    return ""


# ---------------------------------------------------------------------------
# 雑談・番組ビット
# ---------------------------------------------------------------------------

_AIRBREAK_BITS: tuple[tuple[int, str, str], ...] = (
    (
        14,
        "song hype intro",
        "Build genuine anticipation for the next track like a DJ who loves it. Mention one simple thing "
        "the listener can feel right away: the groove, hook, mood, or first impression.",
    ),
    (
        10,
        "music bridge",
        "Make a natural bridge from the previous track to the next: shared mood, contrast, tempo, or energy. "
        "Sound like you curated the segue on purpose.",
    ),
    (
        8,
        "listener ritual",
        "Imagine a tiny listening ritual: headphones settling in, a late train window, a desk lamp, a kitchen counter, "
        "or someone queueing up one more song. Keep it specific and brief.",
    ),
    (
        8,
        "fictional listener message",
        "Pretend a listener sent a strange but believable message. Keep it brief, playful, and radio-natural.",
    ),
    (
        8,
        "fake station business",
        "Invent a quick VoidFM station announcement, fake sponsor tease, lost-and-found note, or studio mishap. "
        "Make it obviously fictional, then move on.",
    ),
    (
        7,
        "sound detail",
        "Start from one concrete sound detail: a bassline, hi-hat, guitar texture, synth color, vocal entrance, "
        "or silence before the drop. Use it to point into the next track.",
    ),
    (
        7,
        "studio snapshot",
        "Give one quick image from the imaginary studio: meters bouncing, coffee going cold, cables behaving, "
        "a sticky note on the console, or the playlist screen blinking. Keep it fresh.",
    ),
    (
        6,
        "micro-rant",
        "Do a harmless one-sentence rant about a trivial, less-obvious annoyance: overpacked keyrings, mystery remote buttons, "
        "too many browser tabs, tiny hotel soaps, or unreadable appliance icons.",
    ),
    (
        6,
        "absurd local bulletin",
        "Give a tiny fictional local bulletin or public-service aside in one sentence, then move on like it was normal. "
        "Avoid nearby-animal bits unless the idea is genuinely novel.",
    ),
    (
        6,
        "personal anecdote",
        "Share a one-sentence DJ anecdote or confession that feels human, light, and a little funny.",
    ),
    (
        5,
        "record-shelf note",
        "Make a small record-shelf or playlist-curator observation: sequencing, contrast, a title that catches the eye, "
        "or the pleasure of finding the right next song.",
    ),
    (
        5,
        "mini scene",
        "Paint a tiny scene in one sentence: neon on wet pavement, laundry spinning, elevator lights, a quiet hallway, "
        "a convenience-store glow, or a room settling down.",
    ),
    (
        4,
        "playful question",
        "Ask the listener a playful, low-stakes question or challenge, then immediately turn it toward the next track.",
    ),
    (
        4,
        "unexpected comparison",
        "Use one simple, surprising comparison that is easy to understand while half-listening. Do not get poetic or dense.",
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

_recent_airbreak_bits: deque[str] = deque(maxlen=4)


def _pick_airbreak_bit() -> tuple[str, str]:
    choices = [
        item for item in _AIRBREAK_BITS
        if item[1] not in _recent_airbreak_bits
    ] or list(_AIRBREAK_BITS)

    total = sum(weight for weight, _, _ in choices)
    roll = random.randint(1, total)
    upto = 0
    for weight, name, instruction in choices:
        upto += weight
        if roll <= upto:
            _recent_airbreak_bits.append(name)
            return name, instruction
    _, name, instruction = choices[0]
    _recent_airbreak_bits.append(name)
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

    return (
        f"[Live context — let this inform your TONE silently; do NOT mention the time/date/weather "
        f"unless the selected bit explicitly calls for local color: {', '.join(parts)}]"
    )


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
            "Give a short, natural mid-song radio comment that sounds live over music. It may be off-topic, "
            "but keep it easy to follow. "
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
        "Think of a real music radio station with a light fictional edge: alive, warm, occasionally funny, "
        "but always easy to follow between songs.\n\n"
        "## PERFORMANCE STYLE\n"
        f"{pcfg.get('house_rules', '')}\n\n"
        "## CRITICAL RULES\n"
        "- Station Name: The station is 'VoidFM'. Never invent or use another station name.\n"
        "- Endless Stream: This is a continuous 24/7 radio program. Never use sign-offs, goodbyes, 'wrap up', or suggest the show is ending.\n"
        "- Immersion: The listener is already tuned in. Do NOT open with any greeting — no 'Good morning', 'Good evening', 'Hey there', 'Hi everyone', or 'Welcome to VoidFM'. Dive straight into the talk.\n"
        "- Identity: Do NOT introduce yourself ('This is [DJ name]') unless it feels exceptionally natural in the moment.\n"
        "- DJ flow: This is a spoken break between songs. Keep it rhythmic, clear, and easy to understand on first listen.\n"
        "- Off-topic is okay in small doses: You may mention fictional station life, fake listener messages, tiny complaints, food, traffic, gadgets, urban myths, or absurd local news.\n"
        "- Variety: Do not keep returning to app updates, self-checkout machines, nearby animals, vending machines, or the same tiny-complaint pattern unless the selected bit explicitly makes it fresh.\n"
        "- Music remains the anchor: Do not make every talk a song review, but make the next-track intro feel intentional, not pasted on.\n"
        "- Simplicity: Prefer plain words, one main image, and clean transitions. Avoid dense analogies or clever paragraphs.\n"
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
