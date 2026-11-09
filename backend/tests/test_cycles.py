"""
Checks for the farm's cycle calendar and the daily plan.
Run from the backend folder:  python tests/test_cycles.py
(The app's copy of this logic is checked by frontend/test/cycle_plan_test.dart.)
"""

import sys
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.ml.auto_cycle import plan_window  # noqa: E402
from app.ml.cycle import build_daily_plan, cycle_bounds  # noqa: E402

D = date
failures = []


def check(name, got, expected):
    if got != expected:
        failures.append(f"{name}: got {got}, expected {expected}")


# Sir Arnel's real weigh dates are cycle ends
for w in ["2026-05-15", "2026-05-30", "2026-06-15", "2026-06-30", "2026-08-15",
          "2026-09-15", "2026-09-30", "2026-10-15", "2026-10-30"]:
    check(f"{w} ends a cycle", cycle_bounds(D.fromisoformat(w))[1], D.fromisoformat(w))

check("31st starts a 16-day cycle", cycle_bounds(D(2026, 11, 10)), (D(2026, 10, 31), D(2026, 11, 15)))
check("16th-30th", cycle_bounds(D(2026, 11, 20)), (D(2026, 11, 16), D(2026, 11, 30)))
check("year change", cycle_bounds(D(2027, 1, 5)), (D(2026, 12, 31), D(2027, 1, 15)))
check("February", cycle_bounds(D(2027, 2, 20)), (D(2027, 2, 16), D(2027, 2, 28)))
check("after February", cycle_bounds(D(2027, 3, 3)), (D(2027, 3, 1), D(2027, 3, 15)))
check("leap year", cycle_bounds(D(2028, 2, 20)), (D(2028, 2, 16), D(2028, 2, 29)))

# Three years: every day in exactly one cycle, no gaps or overlaps
d, prev = D(2026, 1, 1), None
while d < D(2029, 1, 1):
    s, e = cycle_bounds(d)
    if not (s <= d <= e and 13 <= (e - s).days + 1 <= 16):
        failures.append(f"bad cycle {s}..{e} for {d}")
    if prev and (s, e) != prev and s != prev[1] + timedelta(days=1):
        failures.append(f"gap or overlap between {prev} and {(s, e)}")
    prev, d = (s, e), d + timedelta(days=1)

# Daily job: never overlaps an older plan
old = {"start_date": "2026-10-30", "end_date": "2026-11-13", "status": "active"}
check("old plan still running", plan_window([old], D(2026, 11, 10)), None)
check("rest of cycle after old plan", plan_window([{**old, "status": "ended"}], D(2026, 11, 14)),
      (D(2026, 11, 14), D(2026, 11, 15), D(2026, 10, 31)))
check("next full cycle", plan_window([{**old, "status": "ended"}], D(2026, 11, 16)),
      (D(2026, 11, 16), D(2026, 11, 30), D(2026, 11, 16)))
check("no cycles yet", plan_window([], D(2026, 11, 10)), (D(2026, 10, 31), D(2026, 11, 15), D(2026, 10, 31)))
check("cancelled ignored", plan_window([{**old, "status": "cancelled"}], D(2026, 11, 10)),
      (D(2026, 10, 31), D(2026, 11, 15), D(2026, 10, 31)))

# Plan: totals kept, partial cycles scaled
w = {(D(2026, 10, 31) + timedelta(days=i)).isoformat(): {"code": 0, "rain": 0, "temp": 30, "wind": 5}
     for i in range(16)}
full = build_daily_plan(D(2026, 10, 31), {"Block A": 60, "Block B": 45}, w, end=D(2026, 11, 15))
check("16-day cycle tap days", (sum(x["block"] == "Block A" for x in full),
                                sum(x["block"] == "Block B" for x in full)), (7, 9))
for b, total in (("Block A", 60.0), ("Block B", 45.0)):
    check(f"{b} sums to its forecast", round(sum(x["predicted_yield"] for x in full if x["block"] == b), 1), total)
part = build_daily_plan(D(2026, 11, 14), {"Block A": 60, "Block B": 45}, w,
                        end=D(2026, 11, 15), anchor=D(2026, 10, 31))
check("partial cycle", ([x["day"] for x in part], round(sum(x["predicted_yield"] for x in part), 1)),
      ([15, 16], 10.0))

if failures:
    print("FAILED:\n  " + "\n  ".join(failures))
    sys.exit(1)
print("All cycle checks passed.")
