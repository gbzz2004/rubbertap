"""
Automatic tapping cycles, run by the daily GitHub job (run_forecasts.py).

Cycles follow Sir Arnel's calendar: he weighs each cycle on the 15th and on
the 30th (last day of February), so a cycle runs (day after the previous
weigh date) .. 15th, or 16th .. 30th (see cycle_bounds in app/ml/cycle.py).

Each morning, after the forecast is saved:
  1. Cycles whose end date has passed are marked 'ended' (tidy-up).
  2. If no active cycle covers today, the calendar cycle containing today is
     created and planned. If an older cycle still overlaps it, the new one
     starts the day after that cycle ends, so plans never overlap.
     The plan splits each block's ML forecast across its tap days by the
     Open-Meteo weather forecast (app/ml/cycle.py; the weights there are
     ASSUMPTIONS, see that file).
  A running cycle and recorded harvests are never changed.
The app's "New cycle" button remains as a manual override.
"""

import os
from datetime import date, datetime, timedelta, timezone

from app.ml.cycle import build_daily_plan, cycle_bounds, fetch_daily_weather

MANILA = timezone(timedelta(hours=8))  # the Philippines has no daylight saving


def manila_today() -> date:
    return datetime.now(MANILA).date()


def _d(value) -> date:
    return date.fromisoformat(str(value)[:10])


def plan_window(cycles: list, today: date):
    """(start, end, anchor) for the cycle to create today, or None if an
    active cycle already covers today. anchor = the calendar cycle's first
    day, which fixes which block is tapped on which day."""
    live = [c for c in cycles if c.get("status") != "cancelled"]
    if any(c.get("status") == "active" and _d(c["start_date"]) <= today <= _d(c["end_date"])
           for c in live):
        return None
    anchor, end = cycle_bounds(today)
    start = anchor
    for c in live:  # never overlap an older plan
        c_end = _d(c["end_date"])
        if c_end >= start and _d(c["start_date"]) <= end:
            start = max(start, c_end + timedelta(days=1))
    if start > today:
        return None  # a plan already covers today's cycle up to a later day
    return start, end, anchor


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
    window = plan_window(cycles, today)
    if window is None:
        return "Cycle: one is already running; nothing to do."
    start, end, anchor = window

    weather = fetch_daily_weather(
        start, end,
        float(os.getenv("FARM_LAT", "7.762639")),
        float(os.getenv("FARM_LON", "122.567028")),
    )
    days = build_daily_plan(start, block_totals, weather, end=end, anchor=anchor)

    if dry_run:
        total = {b: round(sum(d["predicted_yield"] for d in days if d["block"] == b), 2)
                 for b in block_totals}
        return f"Cycle (dry run): would create {start} to {end} (cycle of {anchor}), planned kg {total}"

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


# ---------------------------------------------------------------------------
# Past cycles: per-day estimates from the REAL recorded totals
# ---------------------------------------------------------------------------
# Sir Arnel weighs once per cycle, so a past day has no measured harvest. For
# every cycle with a recorded total, each block's real total is split across
# its tap days by that day's REAL (historical) weather, using the same weights
# as the future plan. These are ESTIMATES of how the total was spread, not
# daily measurements; the cycle is saved with status 'recorded' so the app can
# label them that way. The per-day numbers always add up to the recorded total.

RECORDED = "recorded"


def recorded_cycle_totals(records: list, today: date) -> dict:
    """{(cycle start, cycle end): {block: recorded total}} for finished cycles.
    A record belongs to the farm cycle that contains its weigh date."""
    groups = {}
    for r in records:
        if r.get("notes") == "SYNTHETIC":
            continue
        start, end = cycle_bounds(_d(r["date"]))
        if end >= today:
            continue  # the running cycle keeps its forecast plan
        totals = groups.setdefault((start, end), {})
        totals[r["block"]] = round(totals.get(r["block"], 0.0) + float(r["yield_kg"]), 2)
    return groups


def _weather_for(start: date, end: date) -> dict:
    lat = float(os.getenv("FARM_LAT", "7.762639"))
    lon = float(os.getenv("FARM_LON", "122.567028"))
    weather = fetch_daily_weather(start, end, lat, lon, history=True)
    missing = [start + timedelta(days=i) for i in range((end - start).days + 1)
               if (start + timedelta(days=i)).isoformat() not in weather]
    if missing:  # the archive lags a few days; the forecast API has them
        weather.update(fetch_daily_weather(min(missing), max(missing), lat, lon))
    return weather


def backfill_recorded_cycles(db, today: date = None, dry_run: bool = False) -> str:
    """Fill (or refresh) the calendar for every past cycle with a recorded total."""
    today = today or manila_today()
    records = db.table("production_logs").select("date, block, yield_kg, notes").execute().data
    groups = recorded_cycle_totals(records, today)
    existing = (db.table("tapping_cycles").select("id, start_date, end_date")
                .eq("status", RECORDED).execute().data)
    by_dates = {(_d(c["start_date"]), _d(c["end_date"])): c for c in existing}

    # Which cycles are new, or have totals that changed since they were filled?
    todo = []
    for key, totals in sorted(groups.items()):
        cycle = by_dates.get(key)
        if cycle:
            rows = (db.table("daily_predictions").select("block, predicted_yield")
                    .eq("cycle_id", cycle["id"]).execute().data)
            sums = {}
            for row in rows:
                sums[row["block"]] = sums.get(row["block"], 0.0) + float(row["predicted_yield"])
            if set(sums) == set(totals) and all(abs(sums[b] - totals[b]) < 0.1 for b in totals):
                continue  # already filled with these totals
        todo.append((key, totals, cycle))
    stale = [c for key, c in by_dates.items() if key not in groups]  # record deleted

    if not todo and not stale:
        return f"Recorded cycles: all {len(groups)} up to date."
    if dry_run:
        return (f"Recorded cycles (dry run): would fill {len(todo)} "
                f"({', '.join(f'{k[0]}..{k[1]}' for k, _, _ in todo)}), remove {len(stale)}.")

    if todo:
        weather = _weather_for(min(k[0] for k, _, _ in todo), max(k[1] for k, _, _ in todo))
    for (start, end), totals, cycle in todo:
        days = [d for d in build_daily_plan(start, totals, weather, end=end, anchor=start)
                if "predicted_yield" in d]  # only blocks that were recorded
        if cycle:
            db.table("daily_predictions").delete().eq("cycle_id", cycle["id"]).execute()
            cycle_id = cycle["id"]
        else:
            cycle_id = db.table("tapping_cycles").insert({
                "start_date": start.isoformat(),
                "end_date": end.isoformat(),
                "status": RECORDED,
            }).execute().data[0]["id"]
        db.table("daily_predictions").insert([
            {
                "cycle_id": cycle_id,
                "tap_date": d["date"],
                "block": d["block"],
                "predicted_yield": d["predicted_yield"],
                "weather": d["weather"],
                "temperature": d["temperature"],
                "rainfall": d["rainfall"],
            }
            for d in days
        ]).execute()
    for cycle in stale:
        db.table("daily_predictions").delete().eq("cycle_id", cycle["id"]).execute()
        db.table("tapping_cycles").delete().eq("id", cycle["id"]).execute()
    return f"Recorded cycles: filled {len(todo)}, removed {len(stale)}."
