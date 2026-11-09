from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from typing import Optional
import os
from supabase import create_client
from app.ml.models import run_all_models

router = APIRouter()

# Supabase client
supabase = create_client(
    os.getenv("SUPABASE_URL"),
    os.getenv("SUPABASE_KEY")
)

class ForecastRequest(BaseModel):
    block: str  # "Block A" or "Block B"
    periods: Optional[int] = 1  # How many 15-day cycles to forecast

class ForecastResponse(BaseModel):
    block: str
    sarima: dict
    lstm: dict
    sarima_lstm: dict
    sarima_lgbm: dict
    random_forest: dict
    best_model: str
    recommendations: list
    evaluation: Optional[dict] = None

@router.post("/run", response_model=ForecastResponse)
async def run_forecast(request: ForecastRequest):
    try:
        # Fetch historical data from Supabase
        response = supabase.table("production_logs")\
            .select("*")\
            .eq("block", request.block)\
            .order("date")\
            .execute()
        
        data = response.data
        
        if len(data) < 3:
            raise HTTPException(
                status_code=400,
                detail=f"Not enough data for {request.block}. Need at least 3 records."
            )
        
        # Run all ML models
        results = run_all_models(data, request.block, request.periods)
        
        # Save results to Supabase. The best model is saved LAST because the
        # dashboard and GIS map show the newest row.
        model_keys = ["sarima", "lstm", "sarima_lstm", "sarima_lgbm", "random_forest"]
        model_keys.sort(key=lambda k: results[k]["model"] == results["best_model"])
        for model_name in model_keys:
            result = results[model_name]
            supabase.table("forecast_results").insert({
                "model_name": model_name,
                "block": request.block,
                "forecast_kg": result.get("forecast_kg", 0),
                "mae": result.get("mae", 0),
                "rmse": result.get("rmse", 0),
                "r2": result.get("r2", 0),
            }).execute()
        
        return ForecastResponse(
            block=request.block,
            **results
        )
    
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/results/{block}")
async def get_forecast_results(block: str):
    try:
        response = supabase.table("forecast_results")\
            .select("*")\
            .eq("block", block)\
            .order("created_at", desc=True)\
            .limit(20)\
            .execute()
        return {"block": block, "results": response.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@router.get("/compare")
async def compare_models():
    try:
        response = supabase.table("forecast_results")\
            .select("*")\
            .order("created_at", desc=True)\
            .limit(50)\
            .execute()
        return {"results": response.data}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))