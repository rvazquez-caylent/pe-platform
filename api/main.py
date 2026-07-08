"""
PE Platform — API layer
FastAPI application served via Mangum (Lambda + API Gateway HTTP v2).

Endpoints:
  GET /health
  GET /fund/kpis
  GET /fund/nav-history
  GET /fund/cashflow
  GET /portfolio
  GET /portfolio/{company_id}/financials
  GET /allocation/sector
  GET /allocation/geo
  GET /pipeline
  GET /risk/summary
  GET /risk/leverage-bands
  GET /risk/moic-bands
"""

import base64

import boto3
from fastapi import FastAPI, HTTPException, Path
from fastapi.middleware.cors import CORSMiddleware
from mangum import Mangum
import athena

_polly = None

def _get_polly():
    global _polly
    if _polly is None:
        _polly = boto3.client("polly", region_name="us-west-2")
    return _polly

app = FastAPI(title="PE Platform API", version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["*"],
    max_age=300,
)


@app.get("/health")
def health():
    return {"status": "ok"}


# ── Fund ──────────────────────────────────────────────────────────

@app.get("/fund/kpis")
def fund_kpis():
    rows = athena.query("SELECT * FROM fund_kpis")
    return rows[0] if rows else {}


@app.get("/fund/nav-history")
def nav_history():
    return athena.query("SELECT * FROM nav_history ORDER BY quarter")


@app.get("/fund/cashflow")
def cashflow():
    return athena.query("SELECT * FROM cashflow_jcurve ORDER BY row_num")


# ── Portfolio ─────────────────────────────────────────────────────

@app.get("/portfolio")
def portfolio():
    return athena.query("SELECT * FROM portfolio_table ORDER BY fmv DESC")


@app.get("/portfolio/financials")
def all_company_financials():
    return athena.query(
        "SELECT * FROM company_financials ORDER BY company_id, year"
    )


@app.get("/portfolio/{company_id}/financials")
def company_financials(company_id: int = Path(..., gt=0)):
    rows = athena.query(
        f"SELECT * FROM company_financials WHERE company_id = {company_id} ORDER BY year"
    )
    if not rows:
        raise HTTPException(status_code=404, detail=f"No financials for company_id={company_id}")
    return rows


# ── Allocation ────────────────────────────────────────────────────

@app.get("/allocation/sector")
def sector_allocation():
    return athena.query("SELECT * FROM sector_allocation ORDER BY fmv_m DESC")


@app.get("/allocation/geo")
def geo_allocation():
    return athena.query("SELECT * FROM geo_allocation ORDER BY fmv_m DESC")


# ── Pipeline ──────────────────────────────────────────────────────

@app.get("/pipeline")
def pipeline():
    return athena.query(
        "SELECT * FROM pipeline ORDER BY stage, probability DESC"
    )


# ── Risk ──────────────────────────────────────────────────────────

@app.get("/risk/summary")
def risk_summary():
    rows = athena.query("SELECT * FROM risk_summary")
    return rows[0] if rows else {}


@app.get("/risk/leverage-bands")
def leverage_bands():
    return athena.query("SELECT * FROM risk_leverage_bands ORDER BY leverage_band")


@app.get("/risk/moic-bands")
def moic_bands():
    return athena.query("SELECT * FROM risk_moic_bands ORDER BY moic_band")


# ── TTS ───────────────────────────────────────────────────────────

@app.get("/tts")
def tts(text: str, voice: str = "Matthew"):
    if voice not in {"Matthew", "Joanna"}:
        voice = "Matthew"
    resp = _get_polly().synthesize_speech(
        Text=text[:3000],
        OutputFormat="mp3",
        VoiceId=voice,
        Engine="neural",
    )
    audio_b64 = base64.b64encode(resp["AudioStream"].read()).decode()
    return {"audio": audio_b64, "voice": voice}


# ── Lambda entrypoint ─────────────────────────────────────────────

handler = Mangum(app, lifespan="off")
