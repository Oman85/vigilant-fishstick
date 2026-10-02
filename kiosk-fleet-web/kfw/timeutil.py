"""Times, the way every file here writes them: ISO 8601, culture-invariant."""
from __future__ import annotations

import re
from datetime import datetime, timezone

_FRACTION = re.compile(r"(\.\d{1,6})\d*")


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def utc_iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def local_iso(dt: datetime) -> str:
    return dt.astimezone().strftime("%Y-%m-%dT%H:%M:%S")


def local_date(dt: datetime) -> str:
    return dt.astimezone().strftime("%Y-%m-%d")


def parse_utc(text) -> datetime | None:
    """"2026-09-18T14:33:33Z", with or without a fraction or an offset, as an
    aware UTC datetime - or None. A time with no zone at all is taken as UTC.
    Never raises: a half-written file must not stop anything."""
    if text is None:
        return None
    s = str(text).strip()
    if not s:
        return None
    if s.endswith("Z") or s.endswith("z"):
        s = s[:-1] + "+00:00"
    # .NET writes seven fractional digits; Python takes up to six.
    s = _FRACTION.sub(lambda m: m.group(1)[:7], s, count=1)
    try:
        dt = datetime.fromisoformat(s)
    except ValueError:
        for fmt in ("%m/%d/%Y %H:%M:%S", "%Y-%m-%d %H:%M:%S"):
            try:
                dt = datetime.strptime(s, fmt)
                break
            except ValueError:
                continue
        else:
            return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def parse_local(text) -> datetime | None:
    """The CSV's EventTimeLocal ("2026-09-18T16:33:33"), as an aware local time."""
    if not text:
        return None
    try:
        return datetime.strptime(str(text).strip(), "%Y-%m-%dT%H:%M:%S").astimezone()
    except ValueError:
        return None


def minutes_between(a: datetime, b: datetime) -> float:
    return (a - b).total_seconds() / 60.0


def format_minutes(minutes) -> str:
    """7m, 5h, 3d"""
    if minutes is None or minutes == "":
        return ""
    try:
        m = float(minutes)
    except (TypeError, ValueError):
        return ""
    m = max(0.0, m)
    if m < 60:
        return f"{int(m)}m"
    if m < 2880:
        return f"{int(m // 60)}h"
    return f"{int(m // 1440)}d"
