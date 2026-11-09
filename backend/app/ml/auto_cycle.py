"""
Automatic 15-day tapping cycles, run by the daily GitHub job (run_forecasts.py).

Each morning, after the forecast is saved:
  1. Cycles whose end date has passed are marked 'ended' (tidy-up).
  2. If no active cycle covers today, the next cycle is created and planned:
       - back to back: it starts the day after the last cycle ended, so the
         15-day rhythm never drifts (even if the job missed a day or two);
       - after a long break (no cycle for 15+ days) it starts today.
     The plan splits each block's ML forecast total across its tap days by
     the Open-Meteo weather forecast (app/ml/cycle.py; the weights there are
     ASSUMPTIONS, see that file).
  A running cycle and recorded harvests are never changed.
The app's "New cycle" button remains as a manual override.
"""

import os
from datetime import date, datetime, timedelta, timezone

from app.ml.cycle import CYCLE_LENGTH, build_daily_plan, fetch_daily_weather

MANILA = timezone(timedelta(hours=8))  # the Philippines has no daylight saving


def manila_today() -> date:
    return datetime.now(MANILA).date()


def _d(value) -> date:
    return date.fromisoformat(str(value)[:10])


def next_cycle_start(cycles: list, today: date):
    """The start date for a new cycle, or None if none is needed today."""
    live = [c for c in cycles if c.get("status") != "cancelled"]
    if any(_d(c["start_date"]) <= today <= _d(c["end_date"]) for c in live
           if c.get("status") == "active"):
        return None  # a cycle is running
    if any(_d(c["start_date"]) > today for c in live if c.get("status") == "active"):
        return None  # a future cycle is already planned
    ends = [_d(c["end_date"]) for c in live]
    if ends:
        candidate = max(ends) + timedelta(days=1)
        if candidate <= today and (today - candidate).days < CYCLE_LENGTH:
            return candidate  # back to back with the last cycle
    return today  # first cycle, or after a long break


def ensure_current_cycle(db, block_totals: dict, today: date = None, dry_run: bool = False):
    """Make sure a planned cycle covers today. Returns a short status line."""
    today = today or manila_today()
    cycles = db.table("tapping_cycles").select("id, start_date, end_date, status").execute().data

    # 1) Tidy-up: cycles that are over are no longer 'active'
    finished = [c for c in cycles if c["status"] == "active" and _d(c["end_date"]) < today]
    if finished and not dry_run:
        for c in finished:
            db.table("tapping_cycles").update({"status": "ended"}).eq("id", c["id"]).execute()
            c["status"] = "ended"

    # 2) Is a new cycle needed?
    start = next_cycle_start(cycles, today)
    if start is None:
        return "Cycle: one is already running; nothing to do."
    end = start + timedelta(days=CYCLE_LENGTH - 1)

    weather = fetch_daily_weather(
        start, end,
        float(os.getenv("FARM_LAT", "7.762639")),
        float(os.getenv("FARM_LON", "122.567028")),
    )
    days = build_daily_plan(start, block_totals, weather)

    if dry_run:
        total = {b: round(sum(d["predicted_yield"] for d in days if d["block"] == b), 2)
                 for b in block_totals}
        return f"Cycle (dry run): would create {start} to {end}, planned kg {total}"

    cycle = db.table("tapping_cycles").insert({
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "status": "active",
    }).execute().data[0]
    db.table("daily_predictions").insert([
        {
            "cycle_id": cycle["id"],
            "tap_date": d["date"],
            "block": d["block"],
            "predicted_yield": d["predicted_yield"],
            "weather": d["weather"],
            "temperature": d["temperature"],
            "rainfall": d["rainfall"],
        }
        for d in days
    ]).execute()
    return f"Cycle: created {start} to {end} (cycle {cycle['id']})."
