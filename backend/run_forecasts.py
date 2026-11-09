"""
Run all forecasting models for both blocks and save the results to Supabase.

This is what GitHub Actions runs (daily, on the "Update forecast" button, and
after a new harvest record). The phone app only READS the saved results, so it
never waits for training and never needs the developer's PC.

Writes:
  forecast_runs     one row per run: status (running -> done/failed) and the
                    full comparison for both blocks (same output as /forecast/run)
  forecast_results  one row per block and model, best model saved LAST, so the
                    dashboard and GIS map (which show the newest row) show the best

Usage (from the backend folder):
  python run_forecasts.py                    # trigger = manual
  python run_forecasts.py --trigger schedule
  python run_forecasts.py --dry-run          # run the models, write nothing
Needs SUPABASE_URL and SUPABASE_KEY (from .env locally, from GitHub Secrets in Actions).
"""

import argparse
import os
import sys
import time
from datetime import date
from pathlib import Path

from dotenv import load_dotenv

from app.ml.auto_cycle import backfill_recorded_cycles, ensure_current_cycle, manila_today
from app.ml.models import run_all_models

BLOCKS = ("Block A", "Block B")
MODEL_KEYS = ["sarima", "lstm", "sarima_lstm", "sarima_lgbm", "random_forest"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--trigger", default="manual",
                        help="why this run started: schedule, button, new_record, manual")
    parser.add_argument("--dry-run", action="store_true", help="run the models but write nothing")
    parser.add_argument("--today", help="pretend today is YYYY-MM-DD (testing the cycle step)")
    args = parser.parse_args()
    today = date.fromisoformat(args.today) if args.today else manila_today()

    load_dotenv(Path(__file__).with_name(".env"))
    url, key = os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_KEY")
    if not url or not key:
        sys.exit("SUPABASE_URL and SUPABASE_KEY must be set")
    from supabase import create_client
    db = create_client(url, key)

    run_id = None
    if not args.dry_run:
        row = db.table("forecast_runs").insert(
            {"status": "running", "trigger": args.trigger}).execute().data
        run_id = row[0]["id"]

    try:
        results = {}
        for block in BLOCKS:
            rows = (db.table("production_logs").select("*").eq("block", block)
                    .order("date").execute().data)
            if len(rows) < 3:
                print(f"{block}: only {len(rows)} records, skipped")
                continue
            t0 = time.time()
            res = run_all_models(rows, block, 1)
            results[block] = res
            best = next(res[k] for k in MODEL_KEYS if res[k]["model"] == res["best_model"])
            print(f"{block}: best {res['best_model']}, next cycle {best['forecast_kg']} kg, "
                  f"MAE {best['mae']} ({time.time() - t0:.0f}s)")
            if res["evaluation"]["data_warning"]:
                print(f"  WARNING: {res['evaluation']['data_warning']}")

        if not results:
            raise RuntimeError("No block has enough records to forecast")
        if args.dry_run:
            print(ensure_current_cycle(db, _best_totals(results), today, dry_run=True))
            print(backfill_recorded_cycles(db, today, dry_run=True))
            print("Dry run: nothing written.")
            return

        # Keep the dashboard and GIS map in sync (best model saved last).
        # One insert per row: a batch insert gives every row the same timestamp.
        for block, res in results.items():
            keys = sorted(MODEL_KEYS, key=lambda k: res[k]["model"] == res["best_model"])
            for k in keys:
                db.table("forecast_results").insert({
                    "model_name": res[k]["model"],
                    "block": block,
                    "forecast_kg": res[k]["forecast_kg"],
                    "mae": res[k]["mae"],
                    "rmse": res[k]["rmse"],
                    "r2": res[k]["r2"],
                }).execute()

        db.table("forecast_runs").update(
            {"status": "done", "results": results}).eq("id", run_id).execute()
        print(f"Saved run {run_id}.")
    except Exception as e:
        if run_id is not None:
            db.table("forecast_runs").update(
                {"status": "failed", "error": str(e)[:2000]}).eq("id", run_id).execute()
        raise

    # Start and plan the next 15-day cycle when the last one has ended.
    # The forecast above is already saved even if this step fails.
    if len(results) == len(BLOCKS):
        print(ensure_current_cycle(db, _best_totals(results), today))
    else:
        print("Cycle: skipped, not every block has a forecast yet.")

    # Fill the calendar for past cycles from their recorded totals
    print(backfill_recorded_cycles(db, today))


def _best_totals(results: dict) -> dict:
    """Each block's next-cycle forecast from its best model."""
    totals = {}
    for block, res in results.items():
        best = next(res[k] for k in MODEL_KEYS if res[k]["model"] == res["best_model"])
        totals[block] = max(0.0, float(best["forecast_kg"]))
    return totals


if __name__ == "__main__":
    main()
