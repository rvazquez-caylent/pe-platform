"""
Gold ETL — Silver → Gold layer transformation
Reads Silver Parquet tables directly from S3 and produces 9 dashboard-ready
Gold tables, one per logical view needed by the API layer.

Gold tables produced:
  fund_kpis            — single row: all fund-level KPIs + deployment metrics
  nav_history          — quarterly NAV / IRR / TVPI time series
  cashflow_jcurve      — quarterly cashflows with J-curve cumulative series
  sector_allocation    — sector FMV, count, weight, HHI contribution
  geo_allocation       — geography FMV, count, weight, HHI contribution
  portfolio_table      — one row per portco: KPIs + latest financials + risk flag
  company_financials   — full revenue / EBITDA history with growth rates
  pipeline             — deal pipeline with stage/sector aggregates
  risk_metrics         — HHI scores, leverage distribution, watchlist, return bands

Job arguments:
  --target_bucket    S3 bucket for the data lake   (scp3-dev-data-lake-...)
  --silver_prefix    S3 key prefix for Silver input (silver)
  --target_prefix    S3 key prefix for Gold output  (gold)
"""

import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.types import DoubleType, IntegerType, StringType

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "target_bucket",
    "silver_prefix",
    "target_prefix",
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
spark.conf.set("spark.sql.analyzer.failAmbiguousSelfJoin", "false")
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

BUCKET = args["target_bucket"]
SILVER = args["silver_prefix"]
GOLD   = args["target_prefix"]


def silver(entity):
    return spark.read.parquet(f"s3://{BUCKET}/{SILVER}/{entity}/")


def write_gold(df, entity):
    path = f"s3://{BUCKET}/{GOLD}/{entity}/"
    df.coalesce(1).write.mode("overwrite").parquet(path)
    print(f"✅  gold/{entity}/  —  {df.count()} rows")


# ── Load Silver tables ─────────────────────────────────────────────
portco   = silver("portfolio_companies")
fin      = silver("company_financials")
cf       = silver("quarterly_cashflows")
fh       = silver("fund_history")
fm       = silver("fund_metrics")
sb       = silver("sector_breakdown")
gb       = silver("geo_breakdown")
pl       = silver("deal_pipeline")

# ── 1. fund_kpis ───────────────────────────────────────────────────
# Single row — all fund-level KPIs enriched with portfolio summary stats
total_fmv      = portco.agg(F.sum("fmv")).collect()[0][0]
total_invested = portco.agg(F.sum("invested_capital")).collect()[0][0]
active_count   = portco.filter(F.col("status") == "Active").count()
watch_count    = portco.filter(F.col("status") == "Watch").count()

fund_kpis = fm.withColumn("total_fmv_m",        F.lit(total_fmv)) \
              .withColumn("total_invested_m",    F.lit(total_invested)) \
              .withColumn("active_companies",    F.lit(active_count)) \
              .withColumn("watch_companies",     F.lit(watch_count))

write_gold(fund_kpis, "fund_kpis")

# ── 2. nav_history ─────────────────────────────────────────────────
# Fund history ordered for the NAV / IRR / TVPI chart
nav_history = fh.orderBy("quarter")

write_gold(nav_history, "nav_history")

# ── 3. cashflow_jcurve ─────────────────────────────────────────────
# Quarterly cashflows ordered for J-curve chart
cashflow_jcurve = cf.orderBy("row_num")

write_gold(cashflow_jcurve, "cashflow_jcurve")

# ── 4. sector_allocation ───────────────────────────────────────────
# Sector weights with HHI contribution (pct^2 / 10000)
total_sb_fmv = sb.agg(F.sum("fmv_m")).collect()[0][0]

sector_allocation = sb.withColumn(
    "weight_pct", F.round(F.col("fmv_m") / F.lit(total_sb_fmv) * 100, 2)
).withColumn(
    "hhi_contribution", F.round(F.pow(F.col("weight_pct") / 100, 2) * 10000, 2)
).orderBy(F.col("fmv_m").desc())

hhi_sector = sector_allocation.agg(
    F.round(F.sum("hhi_contribution"), 0).alias("hhi_sector")
).collect()[0][0]

sector_allocation = sector_allocation.withColumn("hhi_sector", F.lit(hhi_sector))

write_gold(sector_allocation, "sector_allocation")

# ── 5. geo_allocation ──────────────────────────────────────────────
total_gb_fmv = gb.agg(F.sum("fmv_m")).collect()[0][0]

geo_allocation = gb.withColumn(
    "weight_pct", F.round(F.col("fmv_m") / F.lit(total_gb_fmv) * 100, 2)
).withColumn(
    "hhi_contribution", F.round(F.pow(F.col("weight_pct") / 100, 2) * 10000, 2)
).orderBy(F.col("fmv_m").desc())

hhi_geo = geo_allocation.agg(
    F.round(F.sum("hhi_contribution"), 0).alias("hhi_geo")
).collect()[0][0]

geo_allocation = geo_allocation.withColumn("hhi_geo", F.lit(hhi_geo))

write_gold(geo_allocation, "geo_allocation")

# ── 6. portfolio_table ─────────────────────────────────────────────
# Portco row joined with latest actual financial year
win_latest = Window.partitionBy("company_id").orderBy(F.col("year").desc())
latest_fin = (
    fin.filter(F.col("is_estimate") == False)
       .withColumn("_rn", F.row_number().over(win_latest))
       .filter(F.col("_rn") == 1)
       .select(
           "company_id",
           F.col("year").alias("latest_fin_year"),
           F.col("revenue_m").alias("latest_revenue_m"),
           F.col("ebitda_m").alias("latest_ebitda_m"),
           F.col("ebitda_margin_pct").alias("latest_ebitda_margin_pct"),
           F.col("revenue_yoy_pct").alias("latest_revenue_yoy_pct"),
       )
)

portfolio_table = portco.join(latest_fin, portco.id == latest_fin.company_id, "left") \
    .drop("company_id") \
    .withColumn(
        "risk_flag",
        F.when(F.col("status") == "Watch", F.lit("WATCH"))
         .when(F.col("net_leverage_x") > 6.0, F.lit("HIGH_LEVERAGE"))
         .when(F.col("moic") < 1.0, F.lit("BELOW_COST"))
         .otherwise(F.lit("OK"))
    ).orderBy(F.col("fmv").desc())

write_gold(portfolio_table, "portfolio_table")

# ── 7. company_financials ──────────────────────────────────────────
# Full history — include a CAGR column for revenue and EBITDA
first_yr = fin.filter(F.col("is_estimate") == False) \
              .groupBy("company_id") \
              .agg(
                  F.min("year").alias("first_year"),
                  F.first("revenue_m", ignorenulls=True).alias("first_revenue_m"),
              )

last_yr = fin.filter(F.col("is_estimate") == False) \
             .groupBy("company_id") \
             .agg(
                 F.max("year").alias("last_year"),
                 F.last("revenue_m", ignorenulls=True).alias("last_revenue_m"),
             )

cagr_df = first_yr.join(last_yr, "company_id").withColumn(
    "revenue_cagr_pct",
    F.when(
        (F.col("first_revenue_m") > 0) & (F.col("last_year") > F.col("first_year")),
        F.round(
            (F.pow(F.col("last_revenue_m") / F.col("first_revenue_m"),
                   F.lit(1.0) / (F.col("last_year") - F.col("first_year"))) - 1) * 100,
            2
        )
    )
).select("company_id", "revenue_cagr_pct")

company_financials = fin.join(cagr_df, "company_id", "left") \
    .orderBy("company_id", "year")

write_gold(company_financials, "company_financials")

# ── 8. pipeline ────────────────────────────────────────────────────
# Deal pipeline enriched with stage-level aggregates
stage_agg = pl.groupBy("stage").agg(
    F.count("*").alias("stage_count"),
    F.round(F.sum("equity_m"), 2).alias("stage_equity_m"),
    F.round(F.sum("weighted_equity_m"), 2).alias("stage_weighted_m"),
    F.round(F.avg("probability"), 1).alias("stage_avg_prob"),
)

pipeline = pl.join(stage_agg, "stage", "left").orderBy("stage", "probability")

write_gold(pipeline, "pipeline")

# ── 9. risk_metrics ────────────────────────────────────────────────
# Portfolio-level risk aggregations:
#   - HHI scores (sector + geo)
#   - Leverage distribution bands
#   - Watchlist
#   - MOIC / IRR distribution buckets

lev_bands = portco.withColumn(
    "leverage_band",
    F.when(F.col("net_leverage_x") <= 3.0, F.lit("≤3x Conservative"))
     .when(F.col("net_leverage_x") <= 5.0, F.lit("3-5x Moderate"))
     .when(F.col("net_leverage_x") <= 7.0, F.lit("5-7x Elevated"))
     .otherwise(F.lit(">7x High"))
).groupBy("leverage_band").agg(
    F.count("*").alias("company_count"),
    F.round(F.sum("fmv"), 2).alias("fmv_m"),
)

moic_bands = portco.withColumn(
    "moic_band",
    F.when(F.col("moic") < 1.0,  F.lit("<1x Below cost"))
     .when(F.col("moic") < 1.5,  F.lit("1-1.5x Low"))
     .when(F.col("moic") < 2.0,  F.lit("1.5-2x Moderate"))
     .when(F.col("moic") < 3.0,  F.lit("2-3x Good"))
     .otherwise(F.lit("≥3x Excellent"))
).groupBy("moic_band").agg(
    F.count("*").alias("company_count"),
    F.round(F.sum("fmv"), 2).alias("fmv_m"),
    F.round(F.avg("irr"), 2).alias("avg_irr"),
)

# Combine into a single risk summary row
avg_leverage   = portco.agg(F.round(F.avg("net_leverage_x"), 2)).collect()[0][0]
max_leverage   = portco.agg(F.round(F.max("net_leverage_x"), 2)).collect()[0][0]
weighted_moic  = portco.agg(
    F.round(F.sum(F.col("fmv") * F.col("moic")) / F.sum("fmv"), 2)
).collect()[0][0]
weighted_irr   = portco.agg(
    F.round(F.sum(F.col("fmv") * F.col("irr")) / F.sum("fmv"), 2)
).collect()[0][0]

risk_summary = spark.createDataFrame([{
    "hhi_sector":          float(hhi_sector),
    "hhi_geo":             float(hhi_geo),
    "avg_net_leverage_x":  float(avg_leverage),
    "max_net_leverage_x":  float(max_leverage),
    "weighted_avg_moic":   float(weighted_moic),
    "weighted_avg_irr":    float(weighted_irr),
    "active_count":        int(active_count),
    "watch_count":         int(watch_count),
}])

write_gold(risk_summary, "risk_summary")
write_gold(lev_bands,    "risk_leverage_bands")
write_gold(moic_bands,   "risk_moic_bands")

job.commit()
print("✅  Gold ETL complete")
