import os
from datetime import date, timedelta

import requests
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.ml.models import run_all_models
from app.ml.cycle import CYCLE_LENGTH, fetch_daily_weather, build_daily_plan
from app.routers.forecast import supabase

router = APIRouter()

# run_all_models() returns the best model's NAME; this maps it to its result key
MODEL_KEYS = {
    "SARIMA": "sarima",
    "LSTM": "lstm",
    "SARIMA+LSTM": "sarima_lstm",
    "SARIMA+LightGBM": "sarima_lgbm",
    "Random Forest": "random_forest",
}


class CycleRequest(BaseModel):
    start_date: date


# Plain "def" (not async) so FastAPI runs this long job in a worker thread
@router.post("/plan")
def plan_cycle(req: CycleRequest):
    start = req.start_date
    end = start + timedelta(days=CYCLE_LENGTH - 1)

    # 1) ML forecast of the 15-day cycle total, per block
    block_totals = {}
    summary = {}
    for block in ("Block A", "Block B"):
        rows = (
            supabase.table("production_logs")
            .select("*")
            .eq("block", block)
            .order("date")
            .execute()
            .data
        )
        if len(rows) < 3:
            raise HTTPException(
                status_code=400,
                detail=f"Not enough data for {block}. Need at least 3 records.",
            )

        result = run_all_models(rows, block, 1)
        best_name = result["best_model"]
        best = result[MODEL_KEYS[best_name]]
        total = max(0.0, float(best["forecast_kg"]))

        block_totals[block] = total
        summary[block] = {
            "model": best_name,
            "cycle_total_kg": round(total, 2),
            "mae": float(best["mae"]),
            "rmse": float(best["rmse"]),
            "r2": float(best["r2"]),
        }

        # Keep the GIS map and dashboard in sync with this forecast
        supabase.table("forecast_results").insert({
            "model_name": best_name,
            "block": block,
            "forecast_kg": round(total, 2),
            "mae": float(best["mae"]),
            "rmse": float(best["rmse"]),
            "r2": float(best["r2"]),
            "forecast_date": start.isoformat(),
        }).execute()

    # 2) Daily weather for the cycle
    try:
        weather = fetch_daily_weather(
            start,
            end,
            float(os.getenv("FARM_LAT", "7.762639")),
            float(os.getenv("FARM_LON", "122.567028")),
        )
    except requests.RequestException as e:
        raise HTTPException(
            status_code=502,
            detail=f"Could not get the weather forecast (Open-Meteo): {e}",
        )

    # 3) Split each block's total across its tap days by weather
    try:
        days = build_daily_plan(start, block_totals, weather)
    except ValueError as e:
        raise HTTPException(status_code=502, detail=str(e))

    return {
        "start_date": start.isoformat(),
        "end_date": end.isoformat(),
        "blocks": summary,
        "days": days,
        "weather_source": "open-meteo",
    }