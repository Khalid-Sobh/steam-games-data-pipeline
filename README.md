# Steam Games Data Pipeline


An end-to-end data engineering pipeline that ingests, processes, and visualizes data from 110,000+ Steam games from [Steam Games Dataset](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) — built entirely on GCP with a fully automated daily schedule.

**Stack:** Docker · Airflow · dbt · Spark (Dataproc Serverless) · Terraform · GCP (GCS + BigQuery) · Looker Studio

---

## Architecture

![Project Logo](docs/SteamGamesDataPipeline.drawio.png)



---

## Dashboard

**[View Live Dashboard →](https://lookerstudio.google.com/reporting/ad078584-4712-4d52-a500-92a11449cd6e)**

![Steam Games Dashboard](docs/dashboard.PNG)

| Tile | Chart type | Question answered |
|------|-----------|-------------------|
| 1 | Stacked bar chart | How many games were released per year, broken down by price tier? |
| 2 | Horizontal bar chart | Which genres have the highest average Metacritic score? |

---

## Technologies used

| Layer | Tool | Role |
|-------|------|------|
| Infrastructure | Terraform | Provisions GCS, BigQuery, Dataproc VPC, IAM |
| Orchestration | Apache Airflow 2.9 | Schedules and monitors both pipelines |
| Ingestion | Kaggle API | Downloads the Steam dataset |
| Processing | Apache Spark 3.5 on Dataproc Serverless | Cleans and transforms raw JSON → Parquet |
| Data lake | Google Cloud Storage | Stores raw JSON and processed Parquet |
| Data warehouse | Google BigQuery | Stores raw and transformed tables |
| Transformation | dbt 1.7 | Creates staging view and dashboard mart tables |
| Containerisation | Docker + Compose | Runs Airflow and dbt locally |
| Dashboard | Looker Studio | Visualises the two mart tables |




---
## Pipeline overview

Two Airflow DAGs run sequentially every day. DAG 1 triggers DAG 2 automatically on completion.

**DAG 1 — `steam_01_ingest_to_lake`** (runs daily at 02:00 UTC)
1. Uploads `ingest_job.py` to GCS
2. Downloads `games.json` from Kaggle → streams to GCS raw zone
3. Submits a Dataproc Serverless Spark batch job that reads from GCS raw and writes clean Parquet to GCS processed zone
4. Triggers DAG 2

**DAG 2 — `steam_02_lake_to_warehouse`** (triggered by DAG 1)
1. Loads Parquet from GCS processed zone into BigQuery `raw_games` table
2. Runs dbt to create staging view and two mart tables
3. Runs dbt tests

---

## Project structure

```
steam-pipeline/
├── terraform/                      # GCP infrastructure
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── airflow/
│   └── dags/
│       ├── dag_ingest_to_lake.py   # DAG 1
│       └── dag_lake_to_warehouse.py # DAG 2
├── spark/
│   └── ingest_job.py               # PySpark job (runs on Dataproc Serverless)
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml
│   └── models/
│       ├── staging/
│       │   └── stg_steam_games.sql
│       └── marts/
│           ├── metacritic_by_genre.sql
│           └── releases_by_year_and_tier.sql
├── keys/
│   └── sa-key.example.json         # Structure reference only — real key is git-ignored
├── scripts/
│   ├── setup.sh                    # One-command setup
│   └── teardown.sh                 # Destroy all GCP resources
├── docker-compose.yml
├── Dockerfile.airflow
└── .env.example
```

---

## Prerequisites

| Tool | Install |
|---|---|
| Docker Desktop | https://www.docker.com/products/docker-desktop |
| Terraform ≥ 1.6 | https://developer.hashicorp.com/terraform/install |
| Python ≥ 3.11 | https://www.python.org/downloads |
| GCP account with billing enabled | https://console.cloud.google.com |
| Kaggle account | https://www.kaggle.com/settings → API → Create New Token |

---

## Setup

**1. Clone the repo**


**2. Fill in `.env`**
```bash
cp .env.example .env
# Edit .env with your GCP project ID, bucket name, and Kaggle credentials
# Generate a Fernet key:
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

**3. Run the setup script**
```bash
bash scripts/setup.sh
```

This single command runs Terraform, builds Docker images, starts Airflow, and unpauses both DAGs.

**4. Open Airflow and trigger the pipeline**

- Airflow UI → http://localhost:8080 (or your Codespaces forwarded URL)
- Trigger `steam_01_ingest_to_lake` — it will automatically trigger DAG 2 when done
- Full run takes ~15–20 minutes (Dataproc Serverless startup + Spark job + dbt)

**5. Connect Looker Studio**

- Go to [lookerstudio.google.com](https://lookerstudio.google.com)
- Add data source → BigQuery → your project → `steam_warehouse`
- Tile 1: `metacritic_by_genre` → bar chart, dimension = `genre`, metric = `avg_metacritic_score`
- Tile 2: `releases_by_year_and_tier` → stacked bar, dimension = `release_date`, breakdown = `price_tier_label`, metric = `game_count`

---

## Useful commands

```bash
# View logs
docker compose logs -f airflow-scheduler

# Stop containers
docker compose down

# Full reset (wipes Airflow DB)
docker compose down -v

# Rerun dbt only
docker exec steam-dbt dbt run --project-dir /usr/app/dbt --profiles-dir /usr/app/dbt

# Destroy all GCP resources
bash scripts/teardown.sh
```

---

## Notes

- All GCP resources are provisioned by Terraform — no manual setup in the GCP console required
- The Airflow GCP connection and all pipeline variables are configured automatically via environment variables in `docker-compose.yml`
- Re-running the pipeline is fully idempotent — all tables use `WRITE_TRUNCATE` and dbt uses full-refresh materialization
- The `keys/sa-key.json` service account key is written automatically by Terraform and is excluded from git

