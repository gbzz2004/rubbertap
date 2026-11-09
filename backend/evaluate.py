"""
Model comparison for Chapter 4 (does NOT write anything to Supabase).

Runs the same evaluation the app uses (app/ml/models.py: walk-forward,
one-step-ahead, identical test cycles for every model) on both blocks and
saves two tables:

  results/metrics.csv      MAE, RMSE, R2, MAPE per block and model (+ baselines)
  results/predictions.csv  every test cycle: actual vs each model's prediction

Usage (from the backend folder, venv active):
  python evaluate.py                       # data from Supabase production_logs
  python evaluate.py --csv records.csv     # columns: date, block, yield_kg, weather[, notes]
"""

import argparse
import csv
import os
from pathlib import Path

from dotenv import load_dotenv

from app.ml.models import run_all_models

BLOCKS = ("Block A", "Block B")
MODEL_KEYS = ["sarima", "lstm", "sarima_lstm", "sarima_lgbm", "random_forest"]


def load_rows(csv_path):
    if csv_path:
        with open(csv_path, newline="", encoding="utf-8-sig") as f:
            rows = list(csv.DictReader(f))
        return {b: [r for r in rows if r["block"] == b] for b in BLOCKS}
    load_dotenv(Path(__file__).with_name(".env"))
    from supabase import create_client
    client = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_KEY"))
    return {
        b: client.table("production_logs").select("*").eq("block", b).order("date").execute().data
        for b in BLOCKS
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--csv", help="read records from this CSV instead of Supabase")
    parser.add_argument("--out", default="results", help="output folder (default: results)")
    args = parser.parse_args()

    out = Path(args.out)
    out.mkdir(exist_ok=True)
    metric_rows, pred_rows = [], []

    for block, rows in load_rows(args.csv).items():
        if len(rows) < 3:
            print(f"{block}: only {len(rows)} records, skipped")
            continue
        print(f"\n{block}: running all models...")
        res = run_all_models(rows, block, 1)
        ev = res["evaluation"]
        if not ev["evaluated"]:
            print(f"  Only {ev['n_cycles']} cycles: not enough to evaluate.")
            continue

        print(f"  {ev['train_cycles']} training cycles, {ev['test_cycles']} test cycles "
              f"({ev['test_dates'][0]} to {ev['test_dates'][-1]}), SARIMA = {ev['sarima_spec']}")
        if ev["data_warning"]:
            print(f"  WARNING: {ev['data_warning']}")
        print(f"  {'Model':24}{'MAE':>8}{'RMSE':>8}{'R2':>8}{'MAPE%':>8}")

        entries = [(res[k]["model"], "model", res[k]) for k in MODEL_KEYS if res[k]["evaluated"]]
        entries += [(name, "naive baseline", m) for name, m in ev["baselines"].items()]
        for name, kind, m in sorted(entries, key=lambda e: e[2]["mae"]):
            star = " *" if name == res["best_model"] else ""
            print(f"  {name + star:24}{m['mae']:8.3f}{m['rmse']:8.3f}{m['r2']:8.3f}{m['mape']:8.2f}")
            metric_rows.append({
                "block": block, "model": name, "kind": kind,
                "mae": m["mae"], "rmse": m["rmse"], "r2": m["r2"], "mape": m["mape"],
                "best": name == res["best_model"],
                "train_cycles": ev["train_cycles"], "test_cycles": ev["test_cycles"],
                "synthetic_rows": ev["synthetic_rows"],
            })
        for k in MODEL_KEYS:
            if "error" in res[k]:
                print(f"  NOTE {res[k]['model']}: {res[k]['error']}")

        for i, (d, actual) in enumerate(zip(ev["test_dates"], ev["test_actual"])):
            row = {"block": block, "date": d, "actual_kg": actual}
            for k in MODEL_KEYS:
                preds = res[k]["test_predictions"]
                row[res[k]["model"]] = preds[i] if i < len(preds) else ""
            pred_rows.append(row)

    for name, rows in (("metrics.csv", metric_rows), ("predictions.csv", pred_rows)):
        if rows:
            with open(out / name, "w", newline="", encoding="utf-8") as f:
                writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                writer.writeheader()
                writer.writerows(rows)
    print(f"\nSaved {out / 'metrics.csv'} and {out / 'predictions.csv'}  (* = best by MAE)")


if __name__ == "__main__":
    main()
