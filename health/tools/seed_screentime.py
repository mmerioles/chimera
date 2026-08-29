#!/usr/bin/env python3
"""Post synthetic screen-time data through the real ingest API.

Deliberately goes over HTTP rather than straight into Postgres: it exercises
auth, validation, dedupe and the rollup rebuild, so if the seed works the
phone's upload path works too.

    python3 tools/seed_screentime.py --days 60 --token "$INGEST_TOKEN"
"""
from __future__ import annotations

import argparse
import json
import random
import urllib.error
import urllib.request
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

# (package, label, weight, preferred local hours, typical session seconds)
APPS = [
    ("com.instagram.android",    "Instagram", 22, list(range(7, 10)) + list(range(12, 14)) + list(range(21, 26)), (45, 900)),
    ("com.google.android.youtube", "YouTube",  18, list(range(12, 14)) + list(range(19, 25)), (180, 2700)),
    ("com.android.chrome",       "Chrome",     14, list(range(8, 23)), (60, 900)),
    ("com.reddit.frontpage",     "Reddit",     11, list(range(11, 14)) + list(range(22, 26)), (90, 1200)),
    ("com.google.android.apps.messaging", "Messages", 10, list(range(8, 23)), (20, 240)),
    ("com.slack",                "Slack",       8, list(range(9, 18)), (40, 420)),
    ("com.spotify.music",        "Spotify",     7, list(range(7, 10)) + list(range(16, 19)), (20, 180)),
    ("com.google.android.gm",    "Gmail",       6, list(range(8, 19)), (30, 300)),
    ("com.google.android.apps.maps", "Maps",    4, list(range(8, 20)), (60, 600)),
    ("com.strava",               "Strava",      3, list(range(6, 9)) + list(range(17, 20)), (60, 420)),
    ("com.duolingo",             "Duolingo",    3, list(range(20, 23)), (180, 600)),
    ("com.amazon.kindle",        "Kindle",      2, list(range(21, 24)), (300, 1800)),
]


def pick_app(rng: random.Random, hour: int):
    """Weight apps by how plausible they are at this hour of day."""
    weights = [w * (3 if hour in hours else 1) for _, _, w, hours, _ in APPS]
    return rng.choices(APPS, weights=weights, k=1)[0]


def build_day(rng: random.Random, day: datetime, tz: ZoneInfo) -> dict:
    """One day of pickups.

    Pickup times are drawn, then sorted, then each burst is clipped to end
    before the next one starts. Without that clipping, bursts overlap and the
    day totals more screen time than the day contains - which makes the
    dashboard look plausible per-app while being nonsense in aggregate.
    """
    weekend = day.weekday() >= 5
    pickups = rng.randint(50, 80) if weekend else rng.randint(38, 65)

    # Hour-of-day shape: quiet overnight, bumps at breakfast, lunch, evening.
    hour_weights = [1, 1, 1, 1, 1, 2, 5, 12, 14, 10, 9, 10, 14, 12, 9, 9, 11, 14, 16, 18, 20, 22, 20, 12]
    if weekend:
        hour_weights = [3, 2, 1, 1, 1, 1, 2, 5, 9, 14, 16, 16, 15, 14, 13, 13, 14, 15, 16, 17, 19, 21, 19, 12]

    starts = sorted(
        datetime.combine(
            day.date(),
            time(rng.choices(range(24), weights=hour_weights, k=1)[0],
                 rng.randrange(60), rng.randrange(60)),
            tzinfo=tz,
        )
        for _ in range(pickups)
    )

    day_start = datetime.combine(day.date(), time(0, 0), tzinfo=tz)
    day_end = day_start + timedelta(days=1)

    app_sessions, screen_sessions, unlocks = [], [], []
    seen: dict[str, str] = {}

    for i, start_local in enumerate(starts):
        # The phone goes back in the pocket before the next pickup.
        next_start = starts[i + 1] if i + 1 < len(starts) else day_end
        ceiling = next_start - timedelta(seconds=30)
        if ceiling <= start_local:
            continue

        unlocks.append({"ts": start_local.isoformat()})
        cursor = start_local

        for _ in range(rng.choices([1, 2, 3, 4], weights=[58, 26, 11, 5], k=1)[0]):
            if cursor >= ceiling:
                break
            pkg, label, _w, _h, (lo, hi) = pick_app(rng, cursor.hour)
            seen[pkg] = label
            duration = rng.randint(lo, hi)
            if rng.random() < 0.04:           # the occasional evening-swallower
                duration = int(duration * rng.uniform(2, 4))
            end = min(cursor + timedelta(seconds=duration), ceiling)
            if end <= cursor:
                break
            app_sessions.append(
                {"package": pkg, "start": cursor.isoformat(), "end": end.isoformat()}
            )
            cursor = end + timedelta(seconds=rng.randint(0, 3))

        if cursor > start_local:
            screen_sessions.append(
                {"start": start_local.isoformat(),
                 "end": min(cursor, ceiling).isoformat()}
            )

    return {
        "device_id": "seed-s26p",
        "schema_version": 1,
        "window_start": day_start.isoformat(),
        "window_end": day_end.isoformat(),
        "apps": [{"package": p, "label": l} for p, l in seen.items()],
        "app_sessions": app_sessions,
        "screen_sessions": screen_sessions,
        "unlocks": unlocks,
    }


def post(url: str, token: str, payload: dict) -> dict:
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://localhost:8000/v1/ingest/phone_screentime")
    ap.add_argument("--token", required=True)
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--tz", default="America/New_York")
    ap.add_argument("--seed", type=int, default=20260829)
    args = ap.parse_args()

    tz = ZoneInfo(args.tz)
    rng = random.Random(args.seed)
    today = datetime.now(tz)

    total_sessions = 0
    for offset in range(args.days, -1, -1):
        day = today - timedelta(days=offset)
        payload = build_day(rng, day, tz)
        try:
            result = post(args.url, args.token, payload)
        except urllib.error.HTTPError as exc:
            print(f"FAILED {day.date()}: {exc.code} {exc.read().decode()[:400]}")
            return 1
        total_sessions += len(payload["app_sessions"])
        print(
            f"{day.date()}  sessions={len(payload['app_sessions']):4d}  "
            f"unlocks={len(payload['unlocks']):3d}  "
            f"derived={result['detail']['derived_observations']:4d}"
        )

    print(f"\nseeded {args.days + 1} days, {total_sessions} app sessions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
