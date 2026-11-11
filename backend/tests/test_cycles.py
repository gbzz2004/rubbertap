"""
Checks for the farm's cycle calendar and the daily plan.
Run from the backend folder:  python tests/test_cycles.py
(The app's copy of this logic is checked by frontend/test/cycle_plan_test.dart.)
"""

import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.ml.auto_cycle import (is_calendar_cycle, label_cycle_weather, plan_window,  # noqa: E402
                               recorded_cycle_totals)
from app.ml.cycle import build_daily_plan, cycle_bounds, weather_label  # noqa: E402

D = date
failures = []


def check(name, got, expected):
    if got != expected:
        failures.append(f"{name}: got {got}, expected {expected}")


# Cycles are the calendar halves of the month
check("1st-15th", cycle_bounds(D(2026, 6, 3)), (D(2026, 6, 1), D(2026, 6, 15)))
check("15th is the end", cycle_bounds(D(2026, 6, 15)), (D(2026, 6, 1), D(2026, 6, 15)))
check("16th-30th", cycle_bounds(D(2026, 6, 16)), (D(2026, 6, 16), D(2026, 6, 30)))
check("31st joins the 16th-end cycle", cycle_bounds(D(2026, 10, 31)), (D(2026, 10, 16), D(2026, 10, 31)))
check("a 30th weigh date", cycle_bounds(D(2026, 10, 30)), (D(2026, 10, 16), D(2026, 10, 31)))
check("February", cycle_bounds(D(2027, 2, 20)), (D(2027, 2, 16), D(2027, 2, 28)))
check("leap year", cycle_bounds(D(2028, 2, 29)), (D(2028, 2, 16), D(2028, 2, 29)))

# Three years: every day in exactly one cycle, no gaps or overlaps
d, prev = D(2026, 1, 1), None
while d < D(2029, 1, 1):
    s, e = cycle_bounds(d)
    if not (s <= d <= e and 13 <= (e - s).days + 1 <= 16 and s.day in (1, 16)):
        failures.append(f"bad cycle {s}..{e} for {d}")
    if prev and (s, e) != prev and s != prev[1] + timedelta(days=1):
        failures.append(f"gap or overlap between {prev} and {(s, e)}")
    prev, d = (s, e), d + timedelta(days=1)

# Sir Arnel's records land in the right halves
recs = [{"date": "2026-06-15", "block": "Block A", "yield_kg": 38, "notes": ""},
        {"date": "2026-10-30", "block": "Block B", "yield_kg": 38, "notes": ""},
        {"date": "2026-11-15", "block": "Block A", "yield_kg": 60, "notes": ""},   # running: skipped
        {"date": "2026-05-15", "block": "Block A", "yield_kg": 1, "notes": "SYNTHETIC"}]
check("records to cycles", recorded_cycle_totals(recs, D(2026, 11, 10)),
      {(D(2026, 6, 1), D(2026, 6, 15)): {"Block A": 38.0},
       (D(2026, 10, 16), D(2026, 10, 31)): {"Block B": 38.0}})

# Daily job: plans today's calendar half in full, once
check("plan Nov 1-15", plan_window([], D(2026, 11, 10)), (D(2026, 11, 1), D(2026, 11, 15)))
done = {"start_date": "2026-11-01", "end_date": "2026-11-15", "status": "active"}
check("already planned", plan_window([done], D(2026, 11, 10)), None)
check("next half", plan_window([done], D(2026, 11, 16)), (D(2026, 11, 16), D(2026, 11, 30)))
check("old plan is not a calendar cycle",
      is_calendar_cycle({"start_date": "2026-10-30", "end_date": "2026-11-13"}), False)
check("calendar cycle", is_calendar_cycle(done), True)

# Plan: totals kept on 15- and 16-day cycles
for start, end in ((D(2026, 11, 1), D(2026, 11, 15)), (D(2026, 10, 16), D(2026, 10, 31))):
    w = {(start + timedelta(days=i)).isoformat(): {"code": 0, "rain": 0, "temp": 30, "wind": 5}
         for i in range((end - start).days + 1)}
    plan = build_daily_plan(start, {"Block A": 60, "Block B": 45}, w, end=end)
    for b, total in (("Block A", 60.0), ("Block B", 45.0)):
        check(f"{start}: {b} sums to its forecast",
              round(sum(x["predicted_yield"] for x in plan if x["block"] == b), 1), total)

# Day weather label: by that day's own rain amount, not by "any drizzle"
check("drizzle trace is not a rainy day", weather_label(51, 10, 0.4), "Cloudy")
check("1 mm is rainy", weather_label(51, 10, 1.0), "Rainy")
check("dry clear day", weather_label(0, 10, 0.0), "Sunny")
check("dry windy day", weather_label(3, 35, 0.2), "Windy")

# Cycle weather label: saved on each record for the models, not shown in the app
def _day(code, rain, wind):
    return {"code": code, "rain": rain, "wind": wind}


check("rainy", label_cycle_weather([_day(61, 5 if i < 13 else 0, 10) for i in range(15)]), "Rainy")
check("windy", label_cycle_weather([_day(3, 0, 35) for _ in range(15)]), "Windy")
check("sunny", label_cycle_weather([_day(0 if i < 10 else 3, 0, 10) for i in range(15)]), "Sunny")
check("cloudy", label_cycle_weather([_day(3, 0.2, 10) for _ in range(15)]), "Cloudy")

if failures:
    print("FAILED:\n  " + "\n  ".join(failures))
    sys.exit(1)
print("All cycle checks passed.")
