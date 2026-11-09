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
- Farm coordinates are set in the code (Block A's first corner is the reference point).

## Folder layout (C:\Users\Administrator\Desktop\rubbertap)
frontend/                Flutter app (Android)
  lib/main.dart          theme + bottom navigation (DO NOT change the bottom nav)
  lib/theme.dart         palette, text styles, shared widgets (Panel, Figure, Tag...)
  lib/rain_alerts.dart   rain notifications (WorkManager + local notifications)
  lib/screens/           dashboard, production_log, gis, forecast, weather
backend/                 FastAPI (ML only)
  app/main.py            app + routers
  app/routers/           forecast.py (/forecast/run), cycle.py (/cycle/plan)
  app/ml/                models.py (5 models), cycle.py (daily allocation by weather)
  .env                   secrets. NEVER commit it or paste keys into any file.

## Stack
Flutter + Supabase (data; row-level security is OFF) + FastAPI (ML) +
OpenWeatherMap (weather inside the app) + Open-Meteo (weather for the 15-day
plan, in the backend) + flutter_map with OpenStreetMap tiles.

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
- The harvest data in Supabase may be synthetic (rows with notes = 'SYNTHETIC').
  Mr. Arnel's real records are not all loaded yet. Never present synthetic
  results as findings.
- The farm_blocks table has placeholder tree counts and areas. Replace them with real values.
- Free OpenWeatherMap data updates about every 2 hours and forecasts come in 3-hour steps.
- The backend only runs on the developer's PC. Planned: deploy to Render
  (free tier is 512 MB / 0.1 CPU and sleeps after 15 minutes), train on the
  server, store results in Supabase, and let the phone read the stored results.

## Conventions
- UI: calm palette from theme.dart (forest green = Block A, bronze = Block B).
  Plain language for a non-technical client; no jargon such as MAE or RMSE on screen.
- Make small, surgical edits instead of rewriting files. When there are real
  trade-offs, show the options before choosing a direction.
- After editing Dart code, run `flutter analyze` and report any errors.
- Keep secrets out of the repo. The GitHub repo is private.
