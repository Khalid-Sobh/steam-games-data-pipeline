"""
DAG 1 — Steam: ingest to data lake
────────────────────────────────────
Schedule : daily at 02:00 UTC  (also triggerable manually)
What it does:
  1. Uploads ingest_job.py to GCS/scripts/ (idempotent)
  2. Downloads games.json from Kaggle → streams to GCS/raw/
  3. Submits a Dataproc Serverless Spark batch job that reads
     GCS/raw/games.json and writes clean Parquet to GCS/processed/
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta

from airflow import DAG
from airflow.models import Variable
from airflow.operators.python import PythonOperator
from airflow.operators.trigger_dagrun import TriggerDagRunOperator
from airflow.providers.google.cloud.operators.dataproc import (
    DataprocCreateBatchOperator,
)

# ── Read every config from Airflow Variables (set automatically via
#    AIRFLOW_VAR_* env vars in docker-compose.yml — no manual setup needed) ──

PROJECT  = Variable.get("GCP_PROJECT")
BUCKET   = Variable.get("GCS_BUCKET")
REGION   = Variable.get("GCP_REGION")
SA_EMAIL = f"pipeline-sa@{PROJECT}.iam.gserviceaccount.com"

RAW_PATH    = f"gs://{BUCKET}/raw/games.json"
OUT_PATH    = f"gs://{BUCKET}/processed/steam/"
SCRIPT_PATH = f"gs://{BUCKET}/scripts/ingest_job.py"
TEMP_BUCKET = f"{BUCKET}-dataproc-temp"
SUBNET_URI  = f"projects/{PROJECT}/regions/{REGION}/subnetworks/pipeline-subnet"

LOCAL_SCRIPT = "/opt/airflow/spark/ingest_job.py"

DEFAULT_ARGS = {
    "owner":            "steam-pipeline",
    "retries":          2,
    "retry_delay":      timedelta(minutes=5),
    "email_on_failure": False,
}


# ── Task callables ────────────────────────────────────────────────────────────

def upload_spark_script() -> None:
    """Upload ingest_job.py to GCS/scripts/ (overwrites if changed)."""
    from google.cloud import storage

    client = storage.Client()
    bucket = client.bucket(BUCKET)
    blob   = bucket.blob("scripts/ingest_job.py")
    blob.upload_from_filename(LOCAL_SCRIPT)
    print(f"Uploaded Spark script → {SCRIPT_PATH}")


def download_kaggle_to_gcs() -> None:
    """
    Authenticate with Kaggle using Variables, download the Steam dataset,
    and stream games.json directly to GCS raw zone.
    No data is kept on the Airflow container's disk after upload.
    """
    import kaggle
    from google.cloud import storage

    # Kaggle creds come from Airflow Variables (set by docker-compose env vars)
    os.environ["KAGGLE_USERNAME"] = Variable.get("KAGGLE_USERNAME")
    os.environ["KAGGLE_KEY"]      = Variable.get("KAGGLE_KEY")
    kaggle.api.authenticate()

    download_dir = "/tmp/steam_dataset"
    os.makedirs(download_dir, exist_ok=True)

    print("Downloading Steam dataset from Kaggle...")
    kaggle.api.dataset_download_files(
        dataset="fronkongames/steam-games-dataset",
        path=download_dir,
        unzip=True,
        quiet=False,
    )

    local_file = os.path.join(download_dir, "games.json")
    if not os.path.exists(local_file):
        raise FileNotFoundError(
            f"Expected games.json at {local_file}. "
            "Check the Kaggle dataset structure."
        )

    print(f"Uploading games.json to {RAW_PATH} ...")
    client = storage.Client()
    bucket = client.bucket(BUCKET)
    blob   = bucket.blob("raw/games.json")
    blob.upload_from_filename(local_file)
    print("Upload complete.")

    # Clean up temp files
    os.remove(local_file)


# ── DAG definition ────────────────────────────────────────────────────────────

with DAG(
    dag_id="steam_01_ingest_to_lake",
    description="Download Steam dataset from Kaggle, process with Spark on Dataproc, land Parquet in GCS",
    default_args=DEFAULT_ARGS,
    start_date=datetime(2026, 4, 4),
    schedule_interval="0 2 * * *",   # daily at 02:00 UTC
    catchup=False,
    max_active_runs=1,
    tags=["steam", "ingest", "spark", "dataproc"],
) as dag:

    t_upload_script = PythonOperator(
        task_id="upload_spark_script_to_gcs",
        python_callable=upload_spark_script,
    )

    t_download_kaggle = PythonOperator(
        task_id="download_kaggle_to_gcs",
        python_callable=download_kaggle_to_gcs,
    )

    t_spark_ingest = DataprocCreateBatchOperator(
        task_id="spark_ingest_dataproc_serverless",
        project_id=PROJECT,
        region=REGION,
        # Unique batch ID per run (prevents collisions on daily reruns)
        batch_id="steam-ingest-{{ ds_nodash }}-{{ ts_nodash[:6] }}",
        batch={
            "pyspark_batch": {
                "main_python_file_uri": SCRIPT_PATH,
                "args": [
                    "--input",  RAW_PATH,
                    "--output", OUT_PATH,
                ],
            },
            "runtime_config": {
                "version": "2.1",
            },
            "environment_config": {
                "execution_config": {
                    "service_account": SA_EMAIL,
                    "subnetwork_uri":  SUBNET_URI,
                },
            },
        },
        gcp_conn_id="google_cloud_default",
    )

    # Upload script and download data can run in parallel, then Spark runs
    t_trigger_dag2 = TriggerDagRunOperator(
        task_id="trigger_lake_to_warehouse",
        trigger_dag_id="steam_02_lake_to_warehouse",
        wait_for_completion=False,  # fire and move on; DAG 2 manages itself
    )

    [t_upload_script, t_download_kaggle] >> t_spark_ingest >> t_trigger_dag2
