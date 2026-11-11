# RubberTap: project notes for Claude Code

## What this is
An Android app plus an ML backend that forecasts rubber-farm yield. It is a
university Thesis 2 project; the defense is in November 2026.
Single user by design: Mr. Arnel, the farm owner (Ipil, Zamboanga Sibugay).
There is NO login or registration, on purpose.

## What the panel requires (the project must show all three)
1. A more effective GIS: spatial view of the blocks with the ML forecast on the map.
2. An experimental research design: compare models systematically on the same
   data and the same split, using MAE, RMSE and R2.
3. More advanced ML than Random Forest: SARIMA, LSTM and the hybrids
   (SARIMA+LSTM, SARIMA+LightGBM). Random Forest stays only as the baseline.

## Farm facts
- Two blocks: Block A and Block B, about 1,000 trees each, about 4 hectares
  in total, tapped alternately.
- 15-day cycle. Block A is tapped on days 1,3,5,7,9,11,13. Block B on days
  2,4,6,8,10,12,14,15.
- Mr. Arnel records ONE total per block per 15-day cycle (not per day).
- He weighs on the 15th and the 30th, so cycles are the calendar halves:
  1st-15th and 16th-end of month (the 31st joins the second half; February's
  ends on the 28th/29th). cycle_bounds() in backend/app/ml/cycle.py and
  cycleBounds() in frontend/lib/cycle_plan.dart must stay identical.
- The calendar shows history: finished cycles with a recorded total are filled
  daily by the GitHub job with ESTIMATES (the real total split by real
  historical weather, status 'recorded'); cycles never recorded show grey;
  the current half is planned in full from the forecast.
- Farm coordinates are set in the code (Block A's first corner is the reference point).

## Folder layout (C:\Users\Administrator\Desktop\rubbertap)
tools/make_icon.py       draws the launcher icon (python tools/make_icon.py install)
frontend/                Flutter app (Android)
  lib/main.dart          theme + bottom navigation (DO NOT change the bottom nav)
  lib/theme.dart         palette, text styles, shared widgets (Panel, Figure, Tag...).
                         AppColors/AppText are getters that follow AppColors.dark
                         (Dark mode), so never put them in `const` widgets.
                         Fonts: Outfit (headings) + Work Sans, bundled in assets/fonts
  lib/motion.dart        Reveal (ease-in), AnimatedCount, HeroPanel (coloured card)
  lib/weather_sky.dart   animated sky behind the Weather tab (follows the weather;
                         --dart-define=SKY=Rain:day previews a sky, off by default)
  lib/settings_store.dart saved settings (Dark mode); screens/settings_screen.dart
                         is the gear icon at the top right of every tab
  lib/rain_alerts.dart   rain notifications (WorkManager + local notifications)
  lib/screens/           dashboard, production_log, gis, forecast, weather
  lib/cycle_plan.dart    cycle calendar + daily plan (must match backend cycle.py)
  lib/tapping_advice.dart advice for the tapping morning (Open-Meteo hourly)
  lib/farm_weather.dart  weather now + hourly (Weather tab, rain alerts)
  lib/record_store.dart  offline copy of records + records waiting to send
  lib/update_check.dart  "new version available" notice (app_versions table)
  lib/farm_geometry.dart block outlines (PLACEHOLDERS until real corners)
backend/                 Python ML (FastAPI kept for local development)
  run_forecasts.py       the daily job: forecast + cycles -> Supabase
  evaluate.py            Chapter 4 tables (writes nothing to Supabase)
  import_records.py      check/import real records, remove synthetic ones
  publish_release.py     upload a new APK + app_versions row (service key)
  app/ml/                models.py (5 models), cycle.py (calendar + plan),
                         auto_cycle.py (automatic cycles + recorded history)
  sql/                   production_history.sql (record history + restore)
  tests/test_cycles.py   cycle checks (run: python tests/test_cycles.py)
  .env                   secrets. NEVER commit it or paste keys into any file.
.github/workflows/       forecast.yml: daily 06:13 + 12:13 Manila job on GitHub Actions
data/                    Sir Arnel's real records; git-ignored on purpose

## Stack
Flutter + Supabase (data, Realtime, Storage for APKs; row-level security is
OFF) + Python ML run daily by GitHub Actions (results saved in Supabase; the
phone only reads them) + Open-Meteo as the ONE weather source (calendar,
plan, tapping advice, Weather tab, rain alerts; free, no key; the harvest
form has no weather: each day's real weather is seen on the calendar)
+ MapLibre (maplibre_gl)
with Esri satellite / OSM tiles and 3D block shapes.
Release: app ID com.rubbertap.app, signed with the key in
C:\Users\Administrator\.rubbertap\ (never in the repo); always build with
`flutter build apk --release --split-per-abi`, raise the +build number, then
`python publish_release.py --notes "..."`.

## How to run (Windows PowerShell, three terminals)
1. Emulator:  emulator -avd RubberTapDevice -gpu swiftshader_indirect -no-snapshot
   (PATH needs C:\Android\emulator and C:\Android\platform-tools)
2. Backend:   cd backend; venv\Scripts\activate; uvicorn app.main:app --reload --port 8000
3. App:       cd frontend; flutter run -d emulator-5554
Notes: run flutter from the frontend folder. The emulator reaches the PC at
10.0.2.2. On a USB phone use `adb reverse tcp:8000 tcp:8000` and
`--dart-define=API_URL=http://127.0.0.1:8000`. If ADB hangs: taskkill /F /IM adb.exe
and restart it.

## Known problems (be honest about these, do not hide them)
- ML evaluation was rebuilt on 2026-11-09 (backend/app/ml/models.py): all five
  models share one walk-forward, one-step-ahead test on the last 20% of cycles,
  features use past data only, hybrids are scored on their own predictions,
  naive baselines are included. `python evaluate.py` (in backend/) writes the
  Chapter 4 tables to backend/results/. Numbers are only findings once the
  data is real (see the synthetic-data point below).
- The LSTM is a real LSTM written in NumPy (gradients verified numerically),
  because TensorFlow does not install on Python 3.15 and PyTorch is too big for
  Render's free tier.
- One forecast run takes about 30-40 s per block on the dev PC; on Render's
  0.1 CPU it will be far slower, so training there must run as a background job.
- The weather weights that split a cycle total across tap days are ASSUMPTIONS
  (backend/app/ml/cycle.py), not learned from data.
- Real data since 2026-11-10: Sir Arnel's 18 records (9 cycles per block,
  15 May - 30 Oct 2026; 15 Jul, 30 Jul, 30 Aug missing) are in Supabase and in
  data/arnel_records.csv. The 96 synthetic rows were deleted (kept in
  production_logs_history). 9 cycles is too few to compare the models
  (needs ~15+ per block) or to train the LSTMs (need 12); older records are
  needed for Chapter 4. Never present synthetic results as findings.
- Old forecast_runs / forecast_results rows (ids up to run 4) and the cycle
  Oct 30 - Nov 13 were made from synthetic data; they were not deleted.
- The farm_blocks table has placeholder tree counts and areas. Replace them with real values.
- Row-level security is OFF on the app's tables (no login by design), so anyone
  with the app's public key could change records. Mitigation since 2026-11-09:
  every insert/update/delete of production_logs is copied by a trigger into
  production_logs_history (RLS on, no policies: the app key cannot read or
  change it). Restore queries: backend/sql/production_history.sql.
- Weather: no service has a station at the farm; all are model estimates on
  ~10-25 km grids, so tapping advice and rain alerts are general guidance.
  OpenWeatherMap was removed on 2026-11-10 (its key is no longer in the app).
  Checked 2026-11-11 (May-Nov 2026): Open-Meteo reports some rain on all 187
  days and agrees with NASA POWER on rainy/not for only 73% of days. So a day
  is labelled Rainy from 1 mm (weather_label, both sides), and the calendar
  words a day from that date's rain AND sunshine (dayWeatherText in
  cycle_plan.dart; cut-offs 1 / 2.5 / 5 / 10 mm and 6 h of sun are the app's
  own grouping, not an official scale). Saved labels of older recorded days
  are still the old all-Rainy ones; the app words them from the rain amount.
- The models run on GitHub Actions at 06:13 and 12:13 Manila (backup) and save
  results to Supabase; the app reads them, so it needs no PC. Pulling a screen
  down only reloads saved results; a fresh run is started from the
  GitHub Actions tab (an Edge Function trigger was planned, not built).

## Conventions
- UI: calm palette from theme.dart (forest green = Block A, bronze = Block B).
  Plain language for a non-technical client; no jargon such as MAE or RMSE on screen.
- Make small, surgical edits instead of rewriting files. When there are real
  trade-offs, show the options before choosing a direction.
- After editing Dart code, run `flutter analyze` and report any errors.
- Keep secrets out of the repo. The GitHub repo is private.
