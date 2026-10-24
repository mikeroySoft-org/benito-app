"""Seed a SCRATCH benito-server through its public HTTP API with a known week of data.

Used by test_benito_query.py. Never point this at a real server: it registers a demo
account and writes events. Times are fixed local times in America/Los_Angeles, except
the timers, which the server only accepts within the last 24 hours.
"""
from __future__ import annotations

import datetime as dt
import json
import urllib.request
from typing import Any, Dict, Optional
from zoneinfo import ZoneInfo

PT = ZoneInfo("America/Los_Angeles")
UTC = dt.timezone.utc


def pt(day: int, hh: int, mm: int = 0) -> str:
    """October `day` 2026 at hh:mm Pacific, as UTC RFC 3339."""
    return dt.datetime(2026, 10, day, hh, mm, tzinfo=PT).astimezone(UTC).isoformat()


class Api:
    def __init__(self, base: str) -> None:
        self.base = base.rstrip("/")
        self.token: Optional[str] = None

    def call(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", f"Bearer {self.token}")
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else None


# (day, type, subtype, start (h, m), end (day, h, m) or None, extra fields)
EVENTS = [
    (19, "feed_breast", None, (6, 0), (19, 6, 25), {"side": "L"}),
    (19, "medicine", "Vitamin D", (8, 0), None, {"amount_value": 1, "amount_unit": "drops"}),
    (19, "feed_bottle", "formula", (9, 30), (19, 9, 45), {"amount_value": 4, "amount_unit": "oz"}),
    (19, "diaper", "wet", (10, 0), None, {}),
    (19, "diaper", "dirty", (13, 0), None, {}),
    (19, "sleep", None, (13, 30), (19, 15, 0), {}),
    (19, "feed_breast", None, (15, 10), (19, 15, 30), {"side": "R", "payload_json": {"paused_seconds": 300}}),
    (19, "activity", "walk", (16, 0), (19, 16, 40), {}),
    (19, "diaper", "both", (18, 0), None, {}),
    # Overnight sleep with a 30-minute pause: splits across Oct 19 and Oct 20.
    (19, "sleep", None, (22, 0), (20, 5, 30), {"payload_json": {"paused_seconds": 1800}}),
    # A nursing log with no end time counts as a feed but adds no minutes.
    (20, "feed_breast", None, (6, 10), None, {"side": "BOTH"}),
    (20, "diaper", "wet", (7, 0), None, {}),
    (20, "feed_bottle", "breastmilk", (10, 0), None, {"amount_value": 120, "amount_unit": "ml"}),
    (20, "diaper", "wet", (11, 0), None, {}),
    (20, "activity", "car_ride", (12, 0), (20, 12, 30), {}),
    (20, "pump", None, (14, 0), None, {"amount_value": 3, "amount_unit": "oz"}),
    (20, "diaper", "dirty", (16, 0), None, {}),
    (20, "activity", "crying", (17, 0), (20, 17, 25), {"payload_json": {"paused_seconds": 120}}),
    # Nursing across midnight: 10 minutes on Oct 20, 20 on Oct 21.
    (20, "feed_breast", None, (23, 50), (21, 0, 20), {"side": "L"}),
    (21, "sleep", None, (1, 0), (21, 4, 0), {}),
    (21, "diaper", "both", (9, 0), None, {}),
    (21, "feed_solid", None, (12, 0), None, {"notes": "rice cereal"}),
    (21, "feed_bottle", "formula", (15, 0), (21, 15, 20), {"amount_value": 3.5, "amount_unit": "oz"}),
    (21, "activity", "crying", (19, 0), (21, 19, 45), {}),
    # Sleep still open (no end): counts zero hours.
    (21, "sleep", None, (20, 0), None, {}),
    (22, "feed_breast", None, (7, 0), (22, 7, 30), {"side": "R"}),
    (22, "diaper", "wet", (8, 0), None, {}),
    (22, "temperature", None, (9, 0), None, {"amount_value": 99.1, "amount_unit": "F"}),
    (22, "feed_breast", None, (11, 0), (22, 11, 20), {"side": "L"}),
    (22, "diaper", "dirty", (12, 0), None, {}),
    (22, "sleep", None, (13, 0), (22, 14, 30), {}),
    (22, "note", None, (16, 0), None, {"notes": "first smile at grandma"}),
]


def seed(base: str, now: dt.datetime) -> Dict[str, Any]:
    api = Api(base)
    reg = api.call("POST", "/auth/register",
                   {"name": "Demo Parent", "email": "demo@example.com", "password": "demo-password-123"})
    api.token = reg["token"]
    fam = api.call("POST", "/families", {"name": "Demo family", "child_name": "Benito",
                                         "child_birthdate": "2026-09-15"})
    child = fam["child"]["id"]
    pip = api.call("POST", "/children", {"name": "Pip", "birthdate": "2026-09-15"})["id"]

    for day, etype, sub, (h, m), end, extra in EVENTS:
        body: Dict[str, Any] = {"child_id": child, "type": etype, "started_at": pt(day, h, m), **extra}
        if sub is not None:
            body["subtype"] = sub
        if end is not None:
            body["ended_at"] = pt(*end)
        api.call("POST", "/events", body)
    # Deleted events must not count.
    gone = api.call("POST", "/events", {"child_id": child, "type": "diaper", "subtype": "dirty",
                                        "started_at": pt(20, 20, 0)})
    api.call("DELETE", f"/events/{gone['id']}")
    # The second child keeps --child honest.
    api.call("POST", "/events", {"child_id": pip, "type": "diaper", "subtype": "wet",
                                 "started_at": pt(22, 10, 0)})

    def at(minutes_ago: int) -> Dict[str, str]:
        return {"at": (now - dt.timedelta(minutes=minutes_ago)).isoformat()}

    # Crying timer with a 5-minute pause, stopped: the server writes the activity event.
    t = api.call("POST", "/timers", {"child_id": child, "kind": "crying", **at(30)})
    api.call("POST", f"/timers/{t['id']}/pause", at(20))
    api.call("POST", f"/timers/{t['id']}/resume", at(15))
    api.call("POST", f"/timers/{t['id']}/stop", at(5))
    # Sleep timer still running after a 10-minute pause: 40 minutes active at `now`.
    t = api.call("POST", "/timers", {"child_id": child, "kind": "sleep", **at(50)})
    api.call("POST", f"/timers/{t['id']}/pause", at(40))
    api.call("POST", f"/timers/{t['id']}/resume", at(30))
    # Nursing timer paused right now: 4 minutes active, pause still open.
    t = api.call("POST", "/timers", {"child_id": child, "kind": "feed_breast", "side": "L", **at(6)})
    api.call("POST", f"/timers/{t['id']}/pause", at(2))
    return {"api": api, "child": child, "pip": pip}
