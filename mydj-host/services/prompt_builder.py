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
    "short":  "30〜50文字程度で話してください。",
    "medium": "60〜90文字程度で話してください。",
    "long":   "100〜140文字程度で話してください。",
}

_LENGTH_INSTRUCTIONS_EN: dict[str, str] = {
    "short":  "Keep your talk to about 15–30 words.",
    "medium": "Keep your talk to about 40–70 words.",
    "long":   "Keep your talk to about 80–110 words.",
}

# ---------------------------------------------------------------------------
# DJ パーソナリティ定義
# ---------------------------------------------------------------------------

_PERSONALITIES: dict[str, dict] = {
    "standard": {
        "persona_ja": "プロのラジオDJ",
        "persona_en": "a professional radio DJ",
        "style_ja": "落ち着いた、聴きやすいプロの語り口で話します。",
        "style_en": "Speak in a calm, polished radio voice.",
        "joke_rate": 0.20,
        "emotions_ja": "(excited)\n  (laugh)",
        "emotions_en": "(excited)\n  (laugh)",
    },
    "energetic": {
        "persona_ja": "テンション高めのクラブ系DJ",
        "persona_en": "a high-energy club DJ",
        "style_ja": "テンション全開！短い合いの手やビートに乗るような語り口で盛り上げます。",
        "style_en": "Turn up the energy! Keep it punchy and hype — short bursts, big impact.",
        "joke_rate": 0.15,
        "emotions_ja": "(excited)",
        "emotions_en": "(excited)",
    },
    "chill": {
        "persona_ja": "まったりとしたカフェラジオのDJ",
        "persona_en": "a laid-back café radio host",
        "style_ja": "ゆったりとした口調で、まるで友達に話しかけるように語りかけます。",
        "style_en": "Speak softly and warmly, like chatting with a friend over coffee.",
        "joke_rate": 0.30,
        "emotions_ja": "(sigh)\n  (laugh)",
        "emotions_en": "(sigh)\n  (laugh)",
    },
    "intellectual": {
        "persona_ja": "博識な音楽評論家兼DJ",
        "persona_en": "a knowledgeable music critic and radio host",
        "style_ja": "曲の背景・音楽史・豆知識を交えながら、上品で知的なトークをします。",
        "style_en": "Speak with sophistication, weaving in music trivia, history, and cultural context.",
        "joke_rate": 0.10,
        "emotions_ja": "(sigh)",
        "emotions_en": "(sigh)",
    },
    "comedian": {
        "persona_ja": "笑いを絶やさないバラエティ系DJ",
        "persona_en": "a comedy radio DJ who loves making listeners laugh",
        "style_ja": "必ずジョーク・ダジャレ・面白いひとことを入れて、リスナーを笑わせます。",
        "style_en": "Always throw in a joke, pun, or funny remark — your goal is to make them laugh!",
        "joke_rate": 0.70,
        "emotions_ja": "(laugh)\n  (excited)",
        "emotions_en": "(laugh)\n  (excited)",
    },
}

_DEFAULT_PERSONALITY = "standard"


def _get_personality(personality: Optional[str]) -> dict:
    return _PERSONALITIES.get(personality or _DEFAULT_PERSONALITY, _PERSONALITIES[_DEFAULT_PERSONALITY])


# ---------------------------------------------------------------------------
# 感情タグガイド（パーソナリティ別）
# ---------------------------------------------------------------------------

def _emotion_guide_ja(personality_cfg: dict) -> str:
    emotions = personality_cfg["emotions_ja"]
    return (
        f"自然な箇所に以下の感情タグを1〜2個まで使えます:\n"
        f"  {emotions}\n"
        "  (sigh)  — ため息\n"
        "例:「いや〜良かったですね！(laugh) さあ次もいきましょう！」"
    )


def _emotion_guide_en(personality_cfg: dict) -> str:
    emotions = personality_cfg["emotions_en"]
    return (
        f"You may use these emotion tags (1–2 max, use sparingly):\n"
        f"  {emotions}\n"
        "  (sigh)  — a sigh\n"
        "Example: \"What a track! (laugh) Let's keep it going.\""
    )


# ---------------------------------------------------------------------------
# ランダムジョーク指示（パーソナリティの joke_rate に従う）
# ---------------------------------------------------------------------------

def _joke_hint_ja(personality_cfg: dict) -> str:
    if random.random() < personality_cfg["joke_rate"]:
        return random.choice([
            "曲の話に加えて、面白いジョークやダジャレをひとつ入れてください。",
            "リスナーが思わず笑ってしまうような短い小話や雑談を一言添えてください。",
            "曲の雰囲気に絡めた豆知識や面白いひとことを添えてください。",
        ])
    return ""


def _joke_hint_en(personality_cfg: dict) -> str:
    if random.random() < personality_cfg["joke_rate"]:
        return random.choice([
            "Include a quick joke or clever pun related to the song.",
            "Add a funny or surprising fun fact to make the listener smile.",
            "Slip in a witty aside or playful remark.",
        ])
    return ""


# ---------------------------------------------------------------------------
# コンテキスト（時刻・天気）
# ---------------------------------------------------------------------------

async def _get_context(cfg: dict) -> tuple[str, str]:
    """現在時刻と天気を取得してコンテキスト文字列にまとめる。"""
    now = datetime.now()
    hour = now.hour
    minute = now.minute

    # 12時間制の時刻文字列（日本語）
    ampm_ja = "午前" if hour < 12 else "午後"
    h12 = hour % 12 or 12
    time_str_ja = f"{ampm_ja}{h12}時" if minute == 0 else f"{ampm_ja}{h12}時{minute:02d}分"

    # 12時間制の時刻文字列（英語）
    time_str_en = now.strftime("%-I:%M %p")  # 例: "2:00 PM"

    # 時間帯
    if 5 <= hour < 12:
        time_label_en, time_label_ja = "morning", "朝"
    elif 12 <= hour < 17:
        time_label_en, time_label_ja = "afternoon", "昼"
    elif 17 <= hour < 21:
        time_label_en, time_label_ja = "evening", "夕方"
    else:
        time_label_en, time_label_ja = "night", "夜"

    city = cfg.get("dj", {}).get("weather_city", "")
    weather_str = ""
    if city:
        # キャッシュを確認
        if city in _weather_cache:
            cache_time, cached_weather = _weather_cache[city]
            if datetime.now() - cache_time < timedelta(seconds=_WEATHER_CACHE_TTL):
                weather_str = cached_weather
            else:
                # キャッシュ期限切れ
                del _weather_cache[city]
        
        # キャッシュにない場合、取得
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

    weather_en = f", weather: {weather_str}" if weather_str else ""
    weather_ja = f"、天気は{weather_str}" if weather_str else ""

    en = f"[Context: {time_label_en}, {time_str_en}{weather_en}]"
    ja = f"[状況: {time_label_ja}、時刻は{time_str_ja}{weather_ja}]"
    return en, ja


# ---------------------------------------------------------------------------
# プロンプト構築
# ---------------------------------------------------------------------------

async def build_prompt(
    current_track: TrackInfo,             # 次の曲（void talk 後に再生される曲）
    previous_track: Optional[TrackInfo],  # 直前に終わった曲
    next_track: Optional[TrackInfo],      # 次の次の曲（キューから取得できた場合）
    language: str,
    talk_length: str,
    personality: Optional[str] = None,
    is_mid_song: bool = False,
    cfg: dict | None = None,
    weather_city: str | None = None,
) -> str:
    cfg = cfg or {}
    if weather_city:
        cfg = {**cfg, "dj": {**cfg.get("dj", {}), "weather_city": weather_city}}

    context_en, context_ja = await _get_context(cfg)
    pcfg = _get_personality(personality)

    length_map = _LENGTH_INSTRUCTIONS if language == "ja" else _LENGTH_INSTRUCTIONS_EN
    length_instruction = length_map.get(talk_length, length_map["medium"])

    if language == "ja":
        prompt = _build_ja(
            context_ja, pcfg, current_track, previous_track, next_track,
            length_instruction, is_mid_song,
        )
    else:
        prompt = _build_en(
            context_en, pcfg, current_track, previous_track, next_track,
            length_instruction, is_mid_song,
        )

    logger.debug("Built prompt (personality=%s, mid_song=%s): %s", personality, is_mid_song, prompt)
    return prompt


def _build_ja(
    context: str,
    pcfg: dict,
    current_track: TrackInfo,
    previous_track: Optional[TrackInfo],
    next_track: Optional[TrackInfo],
    length_instruction: str,
    is_mid_song: bool,
) -> str:
    persona = pcfg["persona_ja"]
    style = pcfg["style_ja"]
    emotion_guide = _emotion_guide_ja(pcfg)

    if is_mid_song:
        # 曲の途中に挟む短コメント（現在は使用していないが互換性のため残す）
        return (
            f"{context}\n\n"
            f"あなたは{persona}です。{style}"
            "今まさに流れている曲について、自然な日本語でひとこと話してください。"
            "文章は必ず最後まで完結させてください。"
            "余計な前置きなしで、トーク本文だけ出力してください。\n\n"
            f"今流れている曲: {current_track.artist} の「{current_track.title}」\n\n"
            f"{emotion_guide}\n\n"
            f"{length_instruction}"
        )

    # ---- Void Talk（曲と曲の間）----
    # 各情報行
    prev_line = (
        f"■ 直前に終わった曲: {previous_track.artist} の「{previous_track.title}」\n"
        if previous_track else ""
    )
    next_line = f"■ 次の曲（これから流れる曲）: {current_track.artist} の「{current_track.title}」\n"
    after_next_line = (
        f"■ その次の曲（キュー情報）: {next_track.artist} の「{next_track.title}」\n"
        if next_track else ""
    )

    # トーク構成の指示
    if previous_track:
        structure = (
            "以下の構成でトークしてください（自然に組み合わせ、かつ文章として完結させること）:\n"
            f"1. 直前に終わった曲の紹介（「只今お送りしたのは〜でした」）\n"
            f"2. 時刻・天気に触れる、または日常の雑談・ジョークなど（毎回時間や天気を言う必要はありません）\n"
            f"3. 次の曲の予告（「続きましては〜をお送りします」）"
        )
        if next_track:
            structure += f"\n4. さらに次の曲も軽く触れてもよい（「その後は〜もお届けします」等）"
    else:
        structure = (
            "以下の構成でトークしてください:\n"
            "1. 次の曲の紹介\n"
            "2. 時刻・天気に触れる、または日常の雑談・ジョークなど（毎回時間や天気を言う必要はありません）"
        )

    # ジョーク指示（確率的）
    joke = _joke_hint_ja(pcfg)
    joke_line = f"\n【追加指示】{joke}" if joke else ""

    return (
        f"{context}\n\n"
        f"あなたは{persona}です。{style}\n"
        f"音楽が一時停止している間のDJトークを日本語で行います。\n"
        "これは終わりのない連続放送なので、締めの挨拶・終幕表現（例: 締めくくり、また次回、またお会いしましょう）は使わないでください。\n"
        f"余計な前置きなしで、トーク本文だけ出力してください。"
        "文章は必ず最後まで完結させてください。\n\n"
        f"{prev_line}"
        f"{next_line}"
        f"{after_next_line}"
        f"\n{structure}"
        f"{joke_line}\n\n"
        f"{emotion_guide}\n\n"
        f"{length_instruction}"
    )


def _build_en(
    context: str,
    pcfg: dict,
    current_track: TrackInfo,
    previous_track: Optional[TrackInfo],
    next_track: Optional[TrackInfo],
    length_instruction: str,
    is_mid_song: bool,
) -> str:
    persona = pcfg["persona_en"]
    style = pcfg["style_en"]
    emotion_guide = _emotion_guide_en(pcfg)

    if is_mid_song:
        return (
            f"{context}\n\n"
            f"You are {persona}. {style} "
            "Give a short, natural mid-song comment about the track currently playing. "
            "Always complete your sentences fully. "
            "Output only the talk itself, no preamble.\n\n"
            f"Now playing: \"{current_track.title}\" by {current_track.artist}\n\n"
            f"{emotion_guide}\n\n"
            f"{length_instruction}"
        )

    # ---- Void Talk ----
    prev_line = (
        f"■ Previous track (just ended): \"{previous_track.title}\" by {previous_track.artist}\n"
        if previous_track else ""
    )
    next_line = f"■ Next track (about to play): \"{current_track.title}\" by {current_track.artist}\n"
    after_next_line = (
        f"■ After that (from queue): \"{next_track.title}\" by {next_track.artist}\n"
        if next_track else ""
    )

    if previous_track:
        structure = (
            "Structure your talk naturally around these elements (all in one flowing piece):\n"
            "1. Briefly mention the previous track in a natural way (no closing phrase)\n"
            "2. A casual chat, a joke, OR a comment tied to the time/weather (no need to mention the time or weather every time)\n"
            "3. Introduce the next track (\"Coming up next is [song]...\")"
        )
        if next_track:
            structure += "\n4. Optionally mention what's after that (\"And after that, you'll hear...\")"
    else:
        structure = (
            "Structure your talk around:\n"
            "1. Introducing the next track\n"
            "2. A casual chat, a joke, OR a comment about the time/weather (no need to mention the time or weather every time)"
        )

    joke = _joke_hint_en(pcfg)
    joke_line = f"\n[Extra instruction: {joke}]" if joke else ""

    return (
        f"{context}\n\n"
        f"You are {persona}. {style}\n"
        "The music is paused. Deliver a between-song DJ talk in English. "
        "This is a continuous endless radio program, so do NOT use sign-off/ending phrasing "
        "such as 'wrap up', 'that wraps', 'signing off', 'goodbye', or 'until next time'. "
        "Always complete your sentences fully — never cut off mid-thought. "
        "Output only the talk itself, no preamble.\n\n"
        f"{prev_line}"
        f"{next_line}"
        f"{after_next_line}"
        f"\n{structure}"
        f"{joke_line}\n\n"
        f"{emotion_guide}\n\n"
        f"{length_instruction}"
    )


