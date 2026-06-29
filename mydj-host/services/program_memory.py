from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass
from time import time

from models.schemas import TrackInfo


@dataclass(frozen=True)
class TalkMemory:
    timestamp: float
    previous_title: str | None
    next_title: str
    text: str


_recent_talks: deque[TalkMemory] = deque(maxlen=12)


def _signature(text: str) -> str:
    words = re.findall(r"[A-Za-z']+", text.lower())
    return " ".join(words[:14])


def remember_talk(
    *,
    text: str,
    next_track: TrackInfo,
    previous_track: TrackInfo | None,
) -> None:
    clean = re.sub(r"\s+", " ", text).strip()
    if not clean:
        return
    _recent_talks.append(
        TalkMemory(
            timestamp=time(),
            previous_title=previous_track.title if previous_track else None,
            next_title=next_track.title,
            text=clean,
        )
    )


def prompt_guidance() -> str:
    if not _recent_talks:
        return ""

    snippets = []
    seen: set[str] = set()
    for item in list(_recent_talks)[-5:]:
        sig = _signature(item.text)
        if not sig or sig in seen:
            continue
        seen.add(sig)
        snippets.append(f"- Avoid repeating this recent opening/idea: {item.text[:120]}")

    if not snippets:
        return ""

    return (
        "## PROGRAM MEMORY\n"
        "Keep continuity, but vary phrasing and avoid repeating recent bits:\n"
        + "\n".join(snippets)
        + "\n"
    )


def recent_talks() -> list[TalkMemory]:
    return list(_recent_talks)
