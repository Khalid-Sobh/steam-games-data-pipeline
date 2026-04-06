"""
DAG 2 — Steam: lake to warehouse
──────────────────────────────────
Schedule : triggered automatically by DAG 1 (no independent schedule)
           Can also be triggered manually from the Airflow UI.
What it does:
  1. Loads Parquet files from GCS/processed/steam/ into BigQuery raw_games table
  2. Runs dbt inside its own container via DockerOperator to create
     staging view + two mart tables used by the dashboard
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.providers.docker.operators.docker import DockerOperator
from airflow.providers.google.cloud.transfers.gcs_to_bigquery import (
    GCSToBigQueryOperator,
)
from docker.types import Mount

PROJECT    = Variable.get("GCP_PROJECT")
BUCKET     = Variable.get("GCS_BUCKET")
BQ_DATASET = Variable.get("BQ_DATASET")

HOST_WORKDIR   = os.environ.get("HOST_WORKDIR", "/workspaces/steam-dashboard")
DBT_HOST_PATH  = f"{HOST_WORKDIR}/dbt"
KEYS_HOST_PATH = f"{HOST_WORKDIR}/keys"

DEFAULT_ARGS = {
    "owner":            "steam-pipeline",
    "retries":          2,
    "retry_delay":      timedelta(minutes=5),
    "email_on_failure": False,
}

DBT_DOCKER_KWARGS = dict(
    image="ghcr.io/dbt-labs/dbt-bigquery:1.7.0",
    api_version="auto",
    auto_remove=True,
    docker_url="unix://var/run/docker.sock",
    network_mode="bridge",
    working_dir="/usr/app/dbt",
    entrypoint=[],
    mount_tmp_dir=False,
    mounts=[
        Mount(source=DBT_HOST_PATH,  target="/usr/app/dbt",  type="bind"),
        Mount(source=KEYS_HOST_PATH, target="/usr/app/keys", type="bind"),
    ],
    environment={
        "GOOGLE_APPLICATION_CREDENTIALS": "/usr/app/keys/sa-key.json",
        "GCP_PROJECT_ID": PROJECT,
        "BQ_DATASET":     BQ_DATASET,
        "GCP_LOCATION":   "US",
    },
)

with DAG(
    dag_id="steam_02_lake_to_warehouse",
    description="Load Parquet from GCS into BigQuery, then run dbt transforms",
    default_args=DEFAULT_ARGS,
    start_date=datetime(2026, 4, 4),
    schedule_interval=None,
    catchup=False,
    max_active_runs=1,
    tags=["steam", "warehouse", "dbt", "bigquery"],
) as dag:

    t_load_to_bq = GCSToBigQueryOperator(
        task_id="gcs_parquet_to_bigquery_raw",
        bucket=BUCKET,
        source_objects=["processed/steam/*.parquet"],
        destination_project_dataset_table=f"{PROJECT}.{BQ_DATASET}.raw_games",
        source_format="PARQUET",
        write_disposition="WRITE_TRUNCATE",
        autodetect=True,
        gcp_conn_id="google_cloud_default",
    )

    t_dbt_run = DockerOperator(
        task_id="dbt_run_transforms",
        command="dbt run --project-dir /usr/app/dbt --profiles-dir /usr/app/dbt --select staging.stg_steam_games+",
        **DBT_DOCKER_KWARGS,
    )

    t_dbt_test = DockerOperator(
        task_id="dbt_test",
        command="dbt test --project-dir /usr/app/dbt --profiles-dir /usr/app/dbt",
        **DBT_DOCKER_KWARGS,
    )

    t_load_to_bq >> t_dbt_run >> t_dbt_test