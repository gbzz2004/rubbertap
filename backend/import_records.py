"""
Import Mr. Arnel's real harvest records and remove the synthetic ones.

Steps (each is a separate command, so nothing happens by surprise):

  1. Check only (writes NOTHING):
       python import_records.py records.csv
     Reads the file, cleans it up and reports problems: unreadable lines,
     duplicates, two records for one block in the same cycle, missing cycles,
     unusual amounts, records already in Supabase.

  2. Import (adds the real records; skips ones already in Supabase):
       python import_records.py records.csv --import

  3. Remove the synthetic records (only after the real ones are in):
       python import_records.py --delete-synthetic --yes
     Every deleted row is also kept in production_logs_history
     (see sql/production_history.sql), so this can be undone.

CSV columns: date, block, yield_kg, weather (optional), notes (optional).
Dates may be 2025-01-15, 15/01/2025, Jan 15 2025 or 15 Jan 2025.
Blocks may be "Block A", "A" or "a". yield_kg is ONE block's 15-day TOTAL.
"""

import argparse
import csv
import os
import statistics
import sys
from datetime import date, datetime
from pathlib import Path

from dotenv import load_dotenv

DATE_FORMATS = ["%Y-%m-%d", "%d/%m/%Y", "%m/%d/%Y", "%b %d %Y", "%B %d %Y",
                "%d %b %Y", "%d %B %Y", "%b %d, %Y", "%B %d, %Y"]
WEATHER = {"sunny": "Sunny", "clear": "Sunny", "cloudy": "Cloudy",
           "rainy": "Rainy", "rain": "Rainy", "windy": "Windy"}


def parse_date(text: str) -> date:
    text = " ".join(text.strip().split())
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(text, fmt).date()
        except ValueError:
            pass
    raise ValueError(f"unreadable date '{text}'")


def parse_block(text: str) -> str:
    t = text.strip().lower().replace("block", "").strip()
    if t in ("a", "b"):
        return f"Block {t.upper()}"
    raise ValueError(f"unknown block '{text}' (use A or B)")


def read_file(path: Path):
    rows, problems = [], []
    with open(path, newline="", encoding="utf-8-sig") as f:
        sample = f.read(2048)
        f.seek(0)
        has_header = "date" in sample.lower().splitlines()[0]
        reader = csv.reader(f)
        if has_header:
            next(reader)
        for n, cells in enumerate(reader, start=2 if has_header else 1):
            cells = [c.strip() for c in cells]
            if not any(cells):
                continue
            try:
                if len(cells) < 3:
                    raise ValueError("needs at least date, block, kg")
                kg = float(cells[2].lower().replace("kg", "").replace(",", "").strip())
                if kg <= 0:
                    raise ValueError(f"kg must be more than 0 (got {kg})")
                weather = cells[3] if len(cells) > 3 else ""
                if weather and weather.lower() not in WEATHER:
                    raise ValueError(f"unknown weather '{weather}' (Sunny, Cloudy, Rainy, Windy)")
                rows.append({
                    "line": n,
                    "date": parse_date(cells[0]),
                    "block": parse_block(cells[1]),
                    "yield_kg": round(kg, 2),
                    "weather": WEATHER.get(weather.lower()) if weather else None,
                    "notes": cells[4] if len(cells) > 4 else "",
                })
            except ValueError as e:
                problems.append(f"line {n}: {e}  ->  {','.join(cells)}")
    return rows, problems


def check(rows, existing):
    """Warnings worth a human look. None of them stop the import."""
    warnings = []
    today = date.today()
    for r in rows:
        if r["date"] > today:
            warnings.append(f"line {r['line']}: date {r['date']} is in the future")
    for block in ("Block A", "Block B"):
        b = sorted((r for r in rows if r["block"] == block), key=lambda r: r["date"])
        if not b:
            warnings.append(f"{block}: no records in the file")
            continue
        for prev, cur in zip(b, b[1:]):
            gap = (cur["date"] - prev["date"]).days
            if gap == 0:
                warnings.append(f"{block}: two records on {cur['date']} (lines {prev['line']} and {cur['line']})")
            elif gap < 10:
                warnings.append(f"{block}: {prev['date']} and {cur['date']} are only {gap} days apart "
                                f"(same cycle?) lines {prev['line']}, {cur['line']}")
            elif gap > 20:
                missing = round(gap / 15) - 1
                warnings.append(f"{block}: {gap} days between {prev['date']} and {cur['date']} "
                                f"(about {missing} cycle(s) missing?)")
        if len(b) >= 4:
            med = statistics.median(r["yield_kg"] for r in b)
            for r in b:
                if r["yield_kg"] > med * 2 or r["yield_kg"] < med / 2:
                    warnings.append(f"line {r['line']}: {block} {r['date']} = {r['yield_kg']} kg, "
                                    f"far from the usual {med:.1f} kg (typo?)")
    already = {(e["date"], e["block"]) for e in existing if e.get("notes") != "SYNTHETIC"}
    for r in rows:
        if (r["date"].isoformat(), r["block"]) in already:
            warnings.append(f"line {r['line']}: {r['block']} {r['date']} is already in Supabase (will be skipped)")
    return warnings


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("file", nargs="?", help="CSV file with the records")
    p.add_argument("--import", dest="do_import", action="store_true", help="add the records to Supabase")
    p.add_argument("--delete-synthetic", action="store_true", help="remove rows with notes = SYNTHETIC")
    p.add_argument("--yes", action="store_true", help="confirm --delete-synthetic")
    args = p.parse_args()

    load_dotenv(Path(__file__).with_name(".env"))
    from supabase import create_client
    db = create_client(os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_KEY"))
    existing = db.table("production_logs").select("id,date,block,yield_kg,notes").execute().data

    if args.delete_synthetic:
        synthetic = [e for e in existing if e.get("notes") == "SYNTHETIC"]
        real = [e for e in existing if e.get("notes") != "SYNTHETIC"]
        print(f"Supabase has {len(real)} real and {len(synthetic)} synthetic records.")
        if not real:
            sys.exit("Refusing: import the real records first, so the app is never left empty.")
        if not args.yes:
            sys.exit("Add --yes to delete the synthetic records (they stay in the history table).")
        db.table("production_logs").delete().eq("notes", "SYNTHETIC").execute()
        left = db.table("production_logs").select("id").eq("notes", "SYNTHETIC").execute().data
        print(f"Deleted {len(synthetic) - len(left)} synthetic records. Real records kept: {len(real)}.")
        return

    if not args.file:
        p.error("give the CSV file, or --delete-synthetic")
    rows, problems = read_file(Path(args.file))
    print(f"Read {len(rows)} records "
          f"(Block A: {sum(r['block'] == 'Block A' for r in rows)}, "
          f"Block B: {sum(r['block'] == 'Block B' for r in rows)}).")
    if rows:
        print(f"Dates: {min(r['date'] for r in rows)} to {max(r['date'] for r in rows)}")
    for msg in problems:
        print("  CANNOT READ", msg)
    for msg in check(rows, existing):
        print("  CHECK      ", msg)
    if problems:
        sys.exit("Fix the unreadable lines first; nothing was imported.")
    if not args.do_import:
        print("Check only: nothing was written. Add --import to save these records.")
        return

    already = {(e["date"], e["block"]) for e in existing if e.get("notes") != "SYNTHETIC"}
    new = [r for r in rows if (r["date"].isoformat(), r["block"]) not in already]
    if new:
        db.table("production_logs").insert([
            {"date": r["date"].isoformat(), "block": r["block"], "yield_kg": r["yield_kg"],
             "weather": r["weather"], "notes": r["notes"]}
            for r in new
        ]).execute()
    print(f"Imported {len(new)} records; skipped {len(rows) - len(new)} already in Supabase.")


if __name__ == "__main__":
    main()
