from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from dotenv import load_dotenv
import os

load_dotenv()

app = FastAPI(
    title="RubberTap ML API",
    description="ML Forecasting API for Rubber Farm Yield Prediction",
    version="1.0.0"
)

# Allow Flutter app to connect
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
def root():
    return {
        "app": "RubberTap ML API",
        "version": "1.0.0",
        "status": "running"
    }

@app.get("/health")
def health():
    return {"status": "healthy"}

# Import routers
from app.routers import forecast
app.include_router(forecast.router, prefix="/forecast", tags=["Forecast"])

from app.routers import cycle
app.include_router(cycle.router, prefix="/cycle", tags=["Cycle"])