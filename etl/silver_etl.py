"""
Silver ETL — Bronze → Silver layer transformation
Reads Bronze CSVs directly from S3 (bypassing catalog to avoid Hive-partition
path misinterpretation), normalises types, enriches with derived PE metrics,
and writes Parquet to the Silver S3 prefix.

Job arguments:
  --target_bucket     S3 bucket for the data lake   (scp3-dev-data-lake-...)
  --bronze_prefix     S3 key prefix for Bronze       (bronze)
  --target_prefix     S3 key prefix for Silver       (silver)
  --load_date         Partition date to read         (2026-06-04)
"""

import sys
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job
from pyspark.sql import functions as F
from pyspark.sql.window import Window
from pyspark.sql.types import IntegerType, DoubleType, BooleanType

args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "target_bucket",
    "bronze_prefix",
    "target_prefix",
    "load_date",
])

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

BUCKET       = args["target_bucket"]
BRONZE       = args["bronze_prefix"]
PREFIX       = args["target_prefix"]
LOAD_DATE    = args["load_date"]


def bronze(entity_dir):
    """Read a Bronze CSV directly from S3, header-aware, all columns as strings."""
    path = f"s3://{BUCKET}/{BRONZE}/{entity_dir}/load_date={LOAD_DATE}/"
    dyf = glueContext.create_dynamic_frame.from_options(
        connection_type="s3",
        connection_options={"paths": [path], "recurse": False},
        format="csv",
        format_options={"withHeader": True, "separator": ",", "quoteChar": '"'},
        transformation_ctx=f"bronze_{entity_dir}",
    )
    return dyf.toDF()


def write_silver(df, entity):
    path = f"s3://{BUCKET}/{PREFIX}/{entity}/"
    df.coalesce(1).write.mode("overwrite").parquet(path)
    print(f"✅  silver/{entity}/  —  {df.count()} rows")


# ── 1. portfolio_companies ─────────────────────────────────────────
portco = bronze("portfolio-companies").select(
    F.col("id").cast(IntegerType()),
    "name", "sector", "subsector", "geography",
    F.col("entry_year").cast(IntegerType()),
    F.col("entry_ev").cast(DoubleType()),
    F.col("entry_ebitda").cast(DoubleType()),
    F.col("entry_multiple").cast(DoubleType()),
    F.col("invested_capital").cast(DoubleType()),
    F.col("ownership_pct").cast(DoubleType()),
    F.col("current_ev").cast(DoubleType()),
    F.col("current_ebitda").cast(DoubleType()),
    F.col("current_multiple").cast(DoubleType()),
    F.col("fmv").cast(DoubleType()),
    F.col("moic").cast(DoubleType()),
    F.col("irr").cast(DoubleType()),
    "status",
    F.col("debt").cast(DoubleType()),
    F.col("employees").cast(IntegerType()),
    "description",
    F.col("realized").cast(DoubleType()),
).withColumn(
    "holding_years", F.lit(2026) - F.col("entry_year")
).withColumn(
    "multiple_expansion", F.round(F.col("current_multiple") - F.col("entry_multiple"), 2)
).withColumn(
    "gross_value_creation_m", F.round(F.col("fmv") - F.col("invested_capital"), 2)
).withColumn(
    "total_value_m", F.round(F.col("fmv") + F.col("realized"), 2)
).withColumn(
    "net_leverage_x",
    F.when(
        F.col("current_ebitda") > 0,
        F.round(F.col("debt") / F.col("current_ebitda"), 2)
    ),
)

write_silver(portco, "portfolio_companies")

# ── 2. company_financials (revenue + EBITDA joined) ────────────────
rev = bronze("company-revenue").select(
    F.col("company_id").cast(IntegerType()),
    "company_name",
    F.col("year").cast(IntegerType()),
    F.col("is_estimate").cast(BooleanType()),
    F.col("revenue_m").cast(DoubleType()),
)

ebitda_df = bronze("company-ebitda").select(
    F.col("company_id").cast(IntegerType()),
    F.col("year").cast(IntegerType()),
    F.col("ebitda_m").cast(DoubleType()),
)

win = Window.partitionBy("company_id").orderBy("year")

fin = (
    rev.join(ebitda_df, on=["company_id", "year"], how="left")
    .withColumn(
        "ebitda_margin_pct",
        F.when(F.col("revenue_m") > 0,
            F.round(F.col("ebitda_m") / F.col("revenue_m") * 100, 2)),
    )
    .withColumn(
        "revenue_yoy_pct",
        F.round(
            (F.col("revenue_m") - F.lag("revenue_m").over(win))
            / F.abs(F.lag("revenue_m").over(win)) * 100, 2),
    )
    .withColumn(
        "ebitda_yoy_pct",
        F.round(
            (F.col("ebitda_m") - F.lag("ebitda_m").over(win))
            / F.abs(F.lag("ebitda_m").over(win)) * 100, 2),
    )
)

write_silver(fin, "company_financials")

# ── 3. quarterly_cashflows ─────────────────────────────────────────
win_cf = Window.orderBy("row_num").rowsBetween(
    Window.unboundedPreceding, Window.currentRow
)

cf = (
    bronze("cashflows").select(
        F.col("row_num").cast(IntegerType()),
        "quarter",
        F.col("contributions_m").cast(DoubleType()),
        F.col("distributions_m").cast(DoubleType()),
        F.col("net_cashflow_m").cast(DoubleType()),
    )
    .withColumn("cum_contributions_m", F.round(F.sum("contributions_m").over(win_cf), 2))
    .withColumn("cum_distributions_m", F.round(F.sum("distributions_m").over(win_cf), 2))
    .withColumn("cum_net_cashflow_m",  F.round(F.sum("net_cashflow_m").over(win_cf), 2))
)

write_silver(cf, "quarterly_cashflows")

# ── 4. fund_history ────────────────────────────────────────────────
fh = bronze("fund-history").select(
    "quarter",
    F.col("nav_m").cast(DoubleType()),
    F.col("net_irr").cast(DoubleType()),
    F.col("tvpi").cast(DoubleType()),
)

write_silver(fh, "fund_history")

# ── 5. fund_metrics ────────────────────────────────────────────────
fm = (
    bronze("fund-metrics").select(
        "fund_name", "short_name",
        F.col("vintage").cast(IntegerType()),
        "strategy", "geography",
        F.col("committed_capital").cast(DoubleType()),
        F.col("called_capital").cast(DoubleType()),
        F.col("uncalled_capital").cast(DoubleType()),
        F.col("distributions").cast(DoubleType()),
        F.col("nav").cast(DoubleType()),
        F.col("total_value").cast(DoubleType()),
        F.col("tvpi").cast(DoubleType()),
        F.col("dpi").cast(DoubleType()),
        F.col("rvpi").cast(DoubleType()),
        F.col("net_irr").cast(DoubleType()),
        F.col("gross_irr").cast(DoubleType()),
        F.col("moic").cast(DoubleType()),
        F.col("management_fee_pct").cast(DoubleType()),
        F.col("carry_pct").cast(DoubleType()),
        F.col("hurdle_rate_pct").cast(DoubleType()),
        F.col("num_portcos").cast(IntegerType()),
        F.to_date("as_of_date").alias("as_of_date"),
    )
    .withColumn(
        "deployed_pct",
        F.round(F.col("called_capital") / F.col("committed_capital") * 100, 2),
    )
    .withColumn(
        "unrealised_pct",
        F.round(F.col("nav") / F.col("total_value") * 100, 2),
    )
)

write_silver(fm, "fund_metrics")

# ── 6. deal_pipeline ───────────────────────────────────────────────
pl = (
    bronze("deal-pipeline").select(
        F.col("id").cast(IntegerType()),
        "name", "sector", "subsector", "source", "stage",
        F.col("target_ev_m").cast(DoubleType()),
        F.col("equity_m").cast(DoubleType()),
        F.col("ev_ebitda").cast(DoubleType()),
        F.col("probability").cast(DoubleType()),
        "owner", "description", "notes",
    )
    .withColumn(
        "weighted_equity_m",
        F.round(F.col("equity_m") * F.col("probability") / 100, 2),
    )
)

write_silver(pl, "deal_pipeline")

# ── 7. sector_breakdown ────────────────────────────────────────────
sb = bronze("sector-breakdown").select(
    "sector",
    F.col("fmv_m").cast(DoubleType()),
    F.col("company_count").cast(IntegerType()),
    F.col("portfolio_pct").cast(DoubleType()),
)

write_silver(sb, "sector_breakdown")

# ── 8. geo_breakdown ───────────────────────────────────────────────
gb = bronze("geo-breakdown").select(
    "region",
    F.col("fmv_m").cast(DoubleType()),
    F.col("company_count").cast(IntegerType()),
)

write_silver(gb, "geo_breakdown")

job.commit()
print("✅  Silver ETL complete")
