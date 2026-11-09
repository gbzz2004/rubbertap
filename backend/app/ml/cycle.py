"""Per-day yield plan for one 15-day tapping cycle.

The ML models forecast the cycle TOTAL for each block. This module splits
that total across the block's tap days using each day's weather forecast,
so the daily numbers always add up to the ML forecast.

IMPORTANT: the weather weights below are ASSUMED values, not learned from
data. Mr. Arnel records one total per block per cycle, so there is nothing
to learn a per-day weather effect from yet. Once daily yields are recorded
(the calendar's "Record actual yield"), these weights can be calibrated.
"""
from datetime import date, timedelta
import requests

CYCLE_LENGTH = 15
BLOCK_A_DAYS = {1, 3, 5, 7, 9, 11, 13}       # 7 tap days
BLOCK_B_DAYS = {2, 4, 6, 8, 10, 12, 14, 15}  # 8 tap days

# --- ASSUMED weather weights (tune or calibrate later) ---
WEATHER_BASE_WEIGHT = {"Sunny": 1.0, "Cloudy": 0.95, "Windy": 0.85}
RAIN_START_WEIGHT = 0.85   # weight for a rainy day with ~0 mm of rain
RAIN_PENALTY_PER_MM = 0.02  # each mm of rain lowers the weight by this much
RAIN_MIN_WEIGHT = 0.40      # heavy rain never goes below this
WINDY_KMH = 30.0

# WMO weather codes (Open-Meteo) that mean drizzle / rain / showers / storm
RAIN_CODES = {51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82, 95, 96, 99}


def weather_label(code: int, wind_kmh: float) -> str:
    if code in RAIN_CODES:
        return "Rainy"
    if wind_kmh >= WINDY_KMH:
        return "Windy"
    if code in (0, 1):
        return "Sunny"
    return "Cloudy"


def weather_weight(label: str, rain_mm: float) -> float:
    if label == "Rainy":
        return max(RAIN_MIN_WEIGHT, RAIN_START_WEIGHT - RAIN_PENALTY_PER_MM * rain_mm)
    return WEATHER_BASE_WEIGHT[label]


def fetch_daily_weather(start: date, end: date, lat: float, lon: float) -> dict:
    """Daily weather from Open-Meteo (free, no key, up to 16 days ahead)."""
    resp = requests.get(
        "https://api.open-meteo.com/v1/forecast",
        params={
            "latitude": lat,
            "longitude": lon,
            "daily": "weather_code,precipitation_sum,temperature_2m_max,wind_speed_10m_max",
            "timezone": "Asia/Manila",
            "start_date": start.isoformat(),
            "end_date": end.isoformat(),
        },
        timeout=15,
    )
    resp.raise_for_status()
    daily = resp.json()["daily"]

    weather = {}
    for i, day in enumerate(daily["time"]):
        weather[day] = {
            "code": int(daily["weather_code"][i] or 0),
            "rain": float(daily["precipitation_sum"][i] or 0.0),
            "temp": daily["temperature_2m_max"][i],
            "wind": float(daily["wind_speed_10m_max"][i] or 0.0),
        }
    return weather


def build_daily_plan(start: date, block_totals: dict, weather: dict) -> list:
    """Split each block's ML cycle total across its tap days by weather."""
    days = []
    for n in range(1, CYCLE_LENGTH + 1):
        d = start + timedelta(days=n - 1)
        w = weather.get(d.isoformat())
        if w is None:
            raise ValueError(f"No weather data for {d.isoformat()}")

        label = weather_label(w["code"], w["wind"])
        days.append({
            "day": n,
            "date": d.isoformat(),
            "block": "Block A" if n in BLOCK_A_DAYS else "Block B",
            "weather": label,
            "temperature": w["temp"],
            "rainfall": round(w["rain"], 2),
            "_weight": weather_weight(label, w["rain"]),
        })

    for block, total in block_totals.items():
        block_days = [x for x in days if x["block"] == block]
        weight_sum = sum(x["_weight"] for x in block_days)
        for x in block_days:
            x["predicted_yield"] = round(total * x["_weight"] / weight_sum, 2)

    for x in days:
        del x["_weight"]
    return days