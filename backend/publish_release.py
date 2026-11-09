"""
Publish a new app version so installed phones offer the update.

What it does:
  1. Reads the version from frontend/pubspec.yaml (e.g. 1.0.1+2: name 1.0.1, code 2)
  2. Uploads the release APKs to the public, download-only Storage bucket "releases"
  3. Adds a row to app_versions; phones see it on their next start

Before running:
  - Raise the version in frontend/pubspec.yaml (the number after + must go up)
  - Build: cd frontend; flutter build apk --release --split-per-abi
  - backend/.env must contain SUPABASE_SERVICE_KEY (Supabase: Project Settings >
    API Keys > service_role / secret key). This key can change ANYTHING in the
    database: keep it only in backend/.env, never in the app, never in Git,
    never in GitHub Secrets.

Usage (from the backend folder, venv active):
  python publish_release.py --notes "Map labels fixed. Faster forecast screen."
"""

import argparse
import os
import re
import sys
from pathlib import Path

from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
PUBSPEC = ROOT / "frontend" / "pubspec.yaml"
APK_DIR = ROOT / "frontend" / "build" / "app" / "outputs" / "flutter-apk"
BUCKET = "releases"
APKS = {  # file built by flutter -> phone type
    "app-arm64-v8a-release.apk": "arm64",   # almost all phones since ~2017
    "app-armeabi-v7a-release.apk": "armv7",  # very old / very cheap phones
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--notes", default="", help="what's new, shown on the phone")
    args = parser.parse_args()

    load_dotenv(Path(__file__).with_name(".env"))
    url, key = os.getenv("SUPABASE_URL"), os.getenv("SUPABASE_SERVICE_KEY")
    if not url or not key:
        sys.exit("SUPABASE_URL and SUPABASE_SERVICE_KEY must be in backend/.env")

    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)", PUBSPEC.read_text(), re.M)
    if not m:
        sys.exit("Could not read 'version: x.y.z+N' from frontend/pubspec.yaml")
    name, code = m.group(1), int(m.group(2))

    missing = [f for f in APKS if not (APK_DIR / f).exists()]
    if missing:
        sys.exit(f"Build first (flutter build apk --release --split-per-abi). Missing: {missing}")
    newest_apk = max((APK_DIR / f).stat().st_mtime for f in APKS)
    if newest_apk < PUBSPEC.stat().st_mtime:
        sys.exit("pubspec.yaml changed after the last build. Rebuild the APKs first.")

    from supabase import create_client
    db = create_client(url, key)

    rows = (db.table("app_versions").select("version_code")
            .order("version_code", desc=True).limit(1).execute().data)
    if rows and rows[0]["version_code"] >= code:
        sys.exit(f"Version code {code} is not higher than the published "
                 f"{rows[0]['version_code']}. Raise the number after + in pubspec.yaml.")

    urls = {}
    for file, abi in APKS.items():
        target = f"RubberTap-{name}-{abi}.apk"
        with open(APK_DIR / file, "rb") as f:
            db.storage.from_(BUCKET).upload(
                target, f.read(),
                {"content-type": "application/vnd.android.package-archive", "upsert": "true"})
        urls[abi] = db.storage.from_(BUCKET).get_public_url(target)
        print(f"Uploaded {target}")

    db.table("app_versions").insert({
        "version_code": code,
        "version_name": name,
        "apk_url": urls["arm64"],
        "apk_url_armv7": urls["armv7"],
        "notes": args.notes,
    }).execute()
    print(f"Published RubberTap {name} (code {code}). Phones will offer it on their next start.")
    print(f"Direct download: {urls['arm64']}")


if __name__ == "__main__":
    main()
