"""
Automatic tapping cycles, run by the daily GitHub job (run_forecasts.py).

Cycles are the calendar halves of the month: 1st-15th (weighed on the 15th)
and 16th-end of month (weighed on the 30th). See cycle_bounds in
app/ml/cycle.py.

Each morning, after the forecast is saved:
  1. Old plans that do not match a calendar cycle (made before cycles
     followed the calendar) are marked 'cancelled'; nothing is deleted.
  2. Finished cycles are marked 'ended'.
  3. The calendar cycle containing today is planned IN FULL (1st-15th or
     16th-end, including days already passed) if it is not planned yet: each
     block's ML forecast split across its tap days by the Open-Meteo weather
     (app/ml/cycle.py; the weights there are ASSUMPTIONS, see that file).
  4. Every finished cycle with a recorded total is filled with per-day
     estimates from that real total (backfill_recorded_cycles, below).
The app's "New cycle" button re-plans the current calendar cycle by hand.
"""

import os
from datetime import date, datetime, timedelta, timezone

from app.ml.cycle import build_daily_plan, cycle_bounds, fetch_daily_weather

MANILA = timezone(timedelta(hours=8))  # the Philippines has no daylight saving
RECORDED = "recorded"


def manila_today() -> date:
    return datetime.now(MANILA).date()


def _d(value) -> date:
    return date.fromisoformat(str(value)[:10])


def is_calendar_cycle(cycle: dict) -> bool:
    """True if the cycle is exactly one calendar half (1st-15th or 16th-end)."""
    start, end = _d(cycle["start_date"]), _d(cycle["end_date"])
    return cycle_bounds(start) == (start, end)


def plan_window(cycles: list, today: date):
    """(start, end) of the calendar cycle to plan today, or None if it is
    already planned (or already recorded)."""
    start, end = cycle_bounds(today)
    if any(c.get("status") in ("active", RECORDED)
           and _d(c["start_date"]) == start and _d(c["end_date"]) == end
           for c in cycles):
        return None
    return start, end


def ensure_current_cycle(db, block_totals: dict, today: date = None, dry_run: bool = False):
    """Make sure today's calendar cycle is planned. Returns a short status line."""
    today = today or manila_today()
    cycles = db.table("tapping_cycles").select("id, start_date, end_date, status").execute().data

    # 1) Old plans that are not calendar cycles: hide them (status only)
    legacy = [c for c in cycles
              if c["status"] not in ("cancelled", RECORDED) and not is_calendar_cycle(c)]
    # 2) Finished calendar cycles are no longer 'active'
    finished = [c for c in cycles if c["status"] == "active" and is_calendar_cycle(c)
                and _d(c["end_date"]) < today]
    if not dry_run:
        for c in legacy:
            db.table("tapping_cycles").update({"status": "cancelled"}).eq("id", c["id"]).execute()
            c["status"] = "cancelled"
        for c in finished:
            db.table("tapping_cycles").update({"status": "ended"}).eq("id", c["id"]).execute()
            c["status"] = "ended"

    # 3) Plan today's calendar cycle in full, if not planned yet
    window = plan_window(cycles, today)
    note = f" ({len(legacy)} old plan(s) {'would be ' if dry_run else ''}cancelled)" if legacy else ""
    if window is None:
        return "Cycle: today's cycle is already planned." + note
    start, end = window

    weather = fetch_daily_weather(
        start, end,
        float(os.getenv("FARM_LAT", "7.762639")),
        float(os.getenv("FARM_LON", "122.567028")),
    )
    days = build_daily_plan(start, block_totals, weather, end=end, anchor=start)

    if dry_run:
        total = {b: round(sum(d["predicted_yield"] for d in days if d["block"] == b), 2)
                 for b in block_totals}
        return f"Cycle (dry run): would plan {start} to {end}, kg {total}" + note

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
    return f"Cycle: planned {start} to {end} (cycle {cycle['id']})." + note


# ---------------------------------------------------------------------------
# Past cycles: per-day estimates from the REAL recorded totals
# ---------------------------------------------------------------------------
# Sir Arnel weighs once per cycle, so a past day has no measured harvest. For
# every cycle with a recorded total, each block's real total is split across
# its tap days by that day's REAL (historical) weather, using the same weights
# as the future plan. These are ESTIMATES of how the total was spread, not
# daily measurements; the cycle is saved with status 'recorded' so the app can
# label them that way. The per-day numbers always add up to the recorded total.



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
