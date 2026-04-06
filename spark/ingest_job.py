"""
Steam Games Ingestion Job
─────────────────────────
Reads games.json from GCS raw zone, cleans and transforms the data,
writes Parquet files to GCS processed zone.

Run via Dataproc Serverless — do NOT run locally.
"""

import argparse
import json
from datetime import datetime

from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col,
    year,
    when,
    regexp_extract,
    lit,
)
from pyspark.sql.types import (
    ArrayType,
    BooleanType,
    FloatType,
    IntegerType,
    LongType,
    StringType,
    StructField,
    StructType,
)


def parse_args():
    parser = argparse.ArgumentParser(description="Steam Games Ingestion Job")
    parser.add_argument(
        "--input",
        required=True,
        help="GCS path to games.json  (e.g. gs://bucket/raw/games.json)",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="GCS path for Parquet output (e.g. gs://bucket/processed/steam/)",
    )
    return parser.parse_args()


def build_spark_session() -> SparkSession:
    return (
        SparkSession.builder
        .appName("SteamGamesIngest")
        .config("spark.sql.legacy.timeParserPolicy", "LEGACY")
        .getOrCreate()
    )


def parse_date(date_str: str) -> str | None:
    """
    Parse Steam release date strings into ISO format (YYYY-MM-DD).
    Steam uses 'Dec 3, 2013' (no leading zero) and 'Dec 03, 2013' (with zero).
    Returns None if the string cannot be parsed.
    """
    if not date_str:
        return None
    for fmt in ("%b %d, %Y", "%b %d, %Y", "%Y-%m-%d", "%d %b, %Y"):
        try:
            return datetime.strptime(date_str.strip(), fmt).date().isoformat()
        except ValueError:
            continue
    return None


SCHEMA = StructType([
    StructField("app_id",           StringType(),          True),
    StructField("name",             StringType(),          True),
    StructField("release_date",     StringType(),          True),
    StructField("estimated_owners", StringType(),          True),
    StructField("peak_ccu",         IntegerType(),         True),
    StructField("price",            FloatType(),           True),
    StructField("dlc_count",        IntegerType(),         True),
    StructField("metacritic_score", IntegerType(),         True),
    StructField("windows",          BooleanType(),         True),
    StructField("mac",              BooleanType(),         True),
    StructField("linux",            BooleanType(),         True),
    StructField("genres",           ArrayType(StringType()), True),
    StructField("developers",       ArrayType(StringType()), True),
    StructField("publishers",       ArrayType(StringType()), True),
])


def load_records(spark: SparkSession, gcs_path: str) -> list[dict]:
    """
    games.json has the structure: { "appId": { ...fields... }, ... }
    PySpark cannot read this top-level map directly, so we load it as
    a single text file, parse with stdlib json, then parallelize.
    """
    raw_text = spark.sparkContext.textFile(gcs_path).collect()
    raw = json.loads("".join(raw_text))

    records = []
    for app_id, game in raw.items():
        records.append({
            "app_id":           str(app_id),
            "name":             str(game.get("name") or ""),
            "release_date":     parse_date(game.get("release_date") or ""),
            "estimated_owners": str(game.get("estimated_owners") or ""),
            "peak_ccu":         int(game.get("peak_ccu") or 0),
            "price":            float(game.get("price") or 0.0),
            "dlc_count":        int(game.get("dlc_count") or 0),
            "metacritic_score": int(game.get("metacritic_score") or 0),
            "windows":          bool(game.get("windows", False)),
            "mac":              bool(game.get("mac", False)),
            "linux":            bool(game.get("linux", False)),
            "genres":           list(game.get("genres") or []),
            "developers":       list(game.get("developers") or []),
            "publishers":       list(game.get("publishers") or []),
        })
    return records


def transform(df):
    return (
        df
        # Date already parsed to ISO string in Python — just cast
        .withColumn("release_date", col("release_date").cast("date"))
        .withColumn("release_year", year(col("release_date")))
        # Parse lower bound of estimated owners range ("20000 - 50000" → 20000)
        .withColumn(
            "owners_lower",
            regexp_extract(col("estimated_owners"), r"^([\d,]+)", 1)
            .cast(LongType()),
        )
        # Bucket price into tiers for dashboard Tile 2
        .withColumn(
            "price_tier",
            when(col("price") == 0.0,   lit("Free"))
            .when(col("price") < 10.0,  lit("Budget"))
            .when(col("price") < 30.0,  lit("Mid"))
            .otherwise(                  lit("Premium")),
        )
        # Basic quality filters
        .filter(col("name") != "")
        .filter(col("release_year").isNotNull())
        .filter(col("release_year") >= 1970)
        # Drop the raw string columns that are now parsed
        .drop("estimated_owners")
    )


def main():
    args  = parse_args()
    spark = build_spark_session()

    print(f"Reading games.json from {args.input}")
    records = load_records(spark, args.input)
    print(f"Loaded {len(records):,} raw records")

    df_raw   = spark.createDataFrame(records, schema=SCHEMA)
    df_clean = transform(df_raw)

    count = df_clean.count()
    print(f"Writing {count:,} clean records to {args.output}")

    df_clean.write.mode("overwrite").parquet(args.output)
    print("Done.")


if __name__ == "__main__":
    main()