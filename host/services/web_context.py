from __future__ import annotations

import asyncio
import logging
import re
import time
import xml.etree.ElementTree as ET
from collections import deque
from email.utils import parsedate_to_datetime
from urllib.parse import quote_plus

import httpx

logger = logging.getLogger(__name__)

# 無料・APIキー不要の情報源だけを使う:
#   - Google News RSS  … 最新のニュース・エピソード
#   - Wikipedia API    … 経歴などの背景知識
_NEWS_URL = "https://news.google.com/rss/search?q={q}&hl=en-US&gl=US&ceid=US:en"
_WIKI_URL = "https://en.wikipedia.org/w/api.php"
_USER_AGENT = "VoidFM/0.1 (https://github.com/CoB12426/VoidFM)"

_CACHE_TTL = 6 * 3600.0
_CACHE_MAX = 64
_NEWS_MAX_AGE_DAYS = 45
_MAX_HEADLINES = 3
_MAX_WIKI_CHARS = 400

_cache: dict[str, tuple[float, str]] = {}
_recent_artists: deque[str] = deque(maxlen=3)

_UNKNOWN_ARTISTS = {"", "unknown", "unknown artist", "<unknown>", "various artists"}


def settings(cfg: dict | None) -> dict:
    """[dj.web_search] の設定（未指定なら無効）。"""
    section = ((cfg or {}).get("dj") or {}).get("web_search") or {}
    return {
        "enabled": bool(section.get("enabled", False)),
        # アーティスト情報トークにする確率。残りは通常の雑談・ジョーク。
        "rate": min(max(float(section.get("rate", 0.3)), 0.0), 1.0),
        "timeout": float(section.get("timeout", 3.0)),
    }


def _normalize(artist: str) -> str:
    return re.sub(r"\s+", " ", artist).strip().lower()


def is_eligible(artist: str) -> bool:
    key = _normalize(artist)
    return key not in _UNKNOWN_ARTISTS and key not in _recent_artists


async def _fetch_news(client: httpx.AsyncClient, artist: str) -> list[str]:
    url = _NEWS_URL.format(q=quote_plus(f'"{artist}" music'))
    resp = await client.get(url)
    resp.raise_for_status()
    root = ET.fromstring(resp.text)

    now = time.time()
    lines: list[str] = []
    seen: set[str] = set()
    for item in root.iter("item"):
        title = (item.findtext("title") or "").strip()
        # 「見出し - 媒体名」の媒体名を落とす
        title = re.sub(r"\s+-\s+[^-]{2,40}$", "", title)
        if not title or title.lower() in seen:
            continue
        pub = item.findtext("pubDate")
        age_days = None
        if pub:
            try:
                age_days = (now - parsedate_to_datetime(pub).timestamp()) / 86400
            except (TypeError, ValueError):
                pass
        if age_days is not None and age_days > _NEWS_MAX_AGE_DAYS:
            continue
        seen.add(title.lower())
        when = f" ({int(age_days)} days ago)" if age_days is not None and age_days >= 1 else ""
        lines.append(f"- {title}{when}")
        if len(lines) >= _MAX_HEADLINES:
            break
    return lines


async def _fetch_wiki(client: httpx.AsyncClient, artist: str) -> str:
    resp = await client.get(
        _WIKI_URL,
        params={
            "action": "query",
            "format": "json",
            "generator": "search",
            "gsrsearch": artist,
            "gsrlimit": 5,
            "prop": "extracts",
            "exintro": 1,
            "explaintext": 1,
            "exchars": _MAX_WIKI_CHARS,
        },
    )
    resp.raise_for_status()
    pages = (resp.json().get("query") or {}).get("pages") or {}
    key = _normalize(artist)
    for page in sorted(pages.values(), key=lambda p: p.get("index", 99)):
        title = _normalize(str(page.get("title", "")))
        extract = re.sub(r"\s+", " ", str(page.get("extract", ""))).strip()
        # 別人物・別項目を拾わないよう、記事名が「名前」または「名前 (band)」等の形式のものだけ採用
        if re.search(r"\b(may|can|most commonly) refer(s)? to\b", extract[:120]):
            continue
        if extract and (title == key or re.fullmatch(rf"{re.escape(key)} \((\w+ )?(band|singer|musician|rapper|group|duo|dj|producer)\)", title)):
            return extract
    return ""


async def fetch_artist_facts(artist: str, timeout: float = 3.0) -> str:
    """アーティストの最新ニュースと背景情報をプロンプト用テキストにして返す。

    取得できなければ空文字。失敗してもトーク生成は止めない。
    """
    key = _normalize(artist)
    cached = _cache.get(key)
    if cached and time.time() - cached[0] < _CACHE_TTL:
        return cached[1]

    try:
        async with httpx.AsyncClient(
            timeout=httpx.Timeout(timeout),
            headers={"User-Agent": _USER_AGENT},
            follow_redirects=True,
        ) as client:
            news, wiki = await asyncio.gather(
                _fetch_news(client, artist),
                _fetch_wiki(client, artist),
                return_exceptions=True,
            )
    except Exception as exc:  # pragma: no cover - client 生成失敗など
        logger.warning("[web] lookup failed for %r: %s", artist, exc)
        return ""

    parts: list[str] = []
    if isinstance(news, list) and news:
        parts.append("Recent headlines:\n" + "\n".join(news))
    elif isinstance(news, Exception):
        logger.info("[web] news lookup failed for %r: %s", artist, news)
    if isinstance(wiki, str) and wiki:
        parts.append(f"Background: {wiki}")
    elif isinstance(wiki, Exception):
        logger.info("[web] wiki lookup failed for %r: %s", artist, wiki)

    facts = "\n".join(parts)
    # 失敗（両方空）も短時間キャッシュしないと毎回タイムアウト待ちになるため保存する
    if len(_cache) >= _CACHE_MAX:
        _cache.pop(min(_cache, key=lambda k: _cache[k][0]), None)
    _cache[key] = (time.time(), facts)
    return facts


def mark_used(artist: str) -> None:
    _recent_artists.append(_normalize(artist))
