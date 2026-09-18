from __future__ import annotations

from collections import Counter, deque
from time import time
from typing import Any


_counters: Counter[str] = Counter()
_events: deque[dict[str, Any]] = deque(maxlen=200)


def count(name: str, amount: int = 1) -> None:
    _counters[name] += amount


def event(name: str, **fields: Any) -> None:
    _events.append({"time": time(), "event": name, **fields})
    count(f"event.{name}")


def snapshot() -> tuple[dict[str, int], list[dict[str, Any]]]:
    return dict(_counters), list(_events)


def reset_for_tests() -> None:
    _counters.clear()
    _events.clear()
