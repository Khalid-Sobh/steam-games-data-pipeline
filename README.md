# Steam Games Data Pipeline

End-to-end data engineering project using the [Steam Games Dataset](https://www.kaggle.com/datasets/fronkongames/steam-games-dataset) (110k+ games).

**Stack:** Airflow · Spark (Dataproc Serverless) · Terraform · Docker · GCP (GCS + BigQuery) · dbt · Looker Studio

---

## Architecture

```
Your machine (Docker)
┌──────────────────────────────────┐
│  Airflow  ──── orchestrates ───► │──► Dataproc Serverless (Spark)
│  dbt      ──── sends SQL ──────► │──► BigQuery
└──────────────────────────────────┘

GCP
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  Kaggle ──► GCS/raw/games.json                         │
│                    │                                    │
│                    ▼                                    │
│         Dataproc Serverless                             │
│         (runs ingest_job.py)                            │
│                    │                                    │
│                    ▼                                    │
│         GCS/processed/steam/*.parquet                   │
│                    │                                    │
│                    ▼                                    │
│         BigQuery: raw_games                             │
│                    │                                    │
│                    ▼                                    │
│         dbt → stg_steam_games (view)                    │
│              → metacritic_by_genre (table)   ─► Tile 1 │
│              → releases_by_year_and_tier (table) ► Tile 2│
│                                                         │
│         Looker Studio Dashboard                         │
└─────────────────────────────────────────────────────────┘
```

**Nothing is processed locally.** Your machine only runs Airflow (scheduler) and dbt (SQL sender). All data movement and compute happens on GCP.

---

## Dashboard

| Tile | Chart type | Question answered |
|------|-----------|-------------------|
| 1 | Horizontal bar chart | Which genres have the highest average Metacritic score? |
| 2 | Stacked bar chart | How many games were released per year, broken down by price tier? |

---

## Project structure

```
steam-pipeline/
├── terraform/              # GCP infrastructure as code
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
├── airflow/
│   └── dags/
│       ├── dag_ingest_to_lake.py       # DAG 1: Kaggle → GCS → Dataproc
│       └── dag_lake_to_warehouse.py    # DAG 2: GCS → BigQuery → dbt
├── spark/
│   └── ingest_job.py       # PySpark job (runs on Dataproc Serverless)
├── dbt/
│   ├── dbt_project.yml
│   ├── profiles.yml
│   └── models/
│       ├── staging/
│       │   ├── sources.yml
│       │   └── stg_steam_games.sql
│       └── marts/
│           ├── schema.yml
│           ├── metacritic_by_genre.sql
│           └── releases_by_year_and_tier.sql
├── keys/
│   └── sa-key.example.json # Structure reference — real key is git-ignored
├── scripts/
│   ├── setup.sh            # One-command setup
│   └── teardown.sh         # Destroy everything
├── docker-compose.yml
├── Dockerfile.airflow
├── .env.example
└── README.md
```

---

## Prerequisites

Install these before running the setup script:

| Tool | Version | Install |
|------|---------|---------|
| Docker Desktop | latest | https://www.docker.com/products/docker-desktop |
| Terraform | ≥ 1.6 | https://developer.hashicorp.com/terraform/install |
| Python | ≥ 3.11 | https://www.python.org/downloads |
| GCP account | — | https://console.cloud.google.com |
| Kaggle account | — | https://www.kaggle.com |

---

## Step 1 — GCP project setup

1. Create a new GCP project at https://console.cloud.google.com
2. Enable billing for the project (Dataproc Serverless requires it)
3. Note your **Project ID** (visible in the top bar of the GCP console)

> **Cost estimate:** For a single daily run on 110k rows, Dataproc Serverless costs roughly $0.05–0.15 per run. GCS and BigQuery storage for this dataset is negligible (< $1/month).

---

## Step 2 — Kaggle API key

1. Go to https://www.kaggle.com/settings
2. Scroll to **API** section → **Create New Token**
3. This downloads `kaggle.json` — open it and note `username` and `key`

---

## Step 3 — Fill in `.env`

```bash
cp .env.example .env
```

Open `.env` and fill in every value:

```env
GCP_PROJECT_ID=my-actual-project-id      # from GCP console
GCS_BUCKET=my-steam-pipeline-bucket      # must be globally unique
BQ_DATASET=steam_warehouse
GCP_REGION=us-central1
GCP_LOCATION=US
KAGGLE_USERNAME=my_kaggle_username
KAGGLE_KEY=my_kaggle_api_key
AIRFLOW__CORE__FERNET_KEY=<generated>    # see below
AIRFLOW_UID=50000                        # Linux: run `echo $UID`
AIRFLOW_ADMIN_USERNAME=admin
AIRFLOW_ADMIN_PASSWORD=admin
AIRFLOW_ADMIN_EMAIL=admin@example.com
```

Generate the Fernet key:
```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

---

## Step 4 — Run the setup script

```bash
bash scripts/setup.sh
```

This single command:
- Validates your `.env`
- Runs `terraform apply` to create all GCP resources and write `keys/sa-key.json`
- Builds Docker images and starts all containers
- Waits for Airflow to be healthy
- Prints the Airflow URL and next steps

---

## Step 5 — Trigger the pipeline

Open **http://localhost:8080** (username/password from `.env`)

### Option A — Manual trigger (run now)

1. In the DAGs list, find **`steam_01_ingest_to_lake`**
2. Toggle it ON (the blue switch on the left)
3. Click the ▶ (Run) button → **Trigger DAG**
4. Watch the progress in Graph view — it takes ~10 minutes (Dataproc Serverless startup + Spark job)
5. Once DAG 1 finishes, find **`steam_02_lake_to_warehouse`**
6. Toggle it ON → **Trigger DAG**
7. This takes ~3–5 minutes (BigQuery load + dbt run)

### Option B — Let the schedule run automatically

Only DAG 1 has a schedule. It triggers DAG 2 automatically when it finishes.

| DAG | Schedule | Description |
|-----|----------|-------------|
| `steam_01_ingest_to_lake` | Daily 02:00 UTC | Downloads data, runs Spark, then triggers DAG 2 |
| `steam_02_lake_to_warehouse` | Triggered by DAG 1 | Loads to BQ, runs dbt |

Toggle **both** DAGs ON (so DAG 2 is enabled and can accept triggers), then leave them — the full pipeline runs automatically every day.

---

## Step 6 — Build the Looker Studio dashboard

1. Go to https://lookerstudio.google.com → **Blank report**
2. Click **Add data** → **BigQuery** → your project → `steam_warehouse`

**Tile 1 — Average Metacritic score by genre**
- Table: `metacritic_by_genre`
- Insert → **Bar chart**
- Dimension: `genre`
- Metric: `avg_metacritic_score`
- Sort: `avg_metacritic_score` descending

**Tile 2 — Games released per year by price tier**
- Table: `releases_by_year_and_tier`
- Insert → **Stacked bar chart**
- Dimension: `release_year`
- Breakdown dimension: `price_tier`
- Metric: `game_count`

---

## Useful commands

```bash
# View logs
docker compose logs -f airflow-scheduler
docker compose logs -f airflow-webserver
docker compose logs -f dbt

# Stop all containers (keeps data)
docker compose down

# Stop and wipe Airflow metadata DB (full reset)
docker compose down -v

# Restart after stopping
docker compose up -d

# Run dbt manually
docker exec steam-dbt dbt run --project-dir /usr/app/dbt --profiles-dir /usr/app/dbt

# Run dbt tests manually
docker exec steam-dbt dbt test --project-dir /usr/app/dbt --profiles-dir /usr/app/dbt

# Check GCS bucket contents
gsutil ls gs://YOUR_BUCKET_NAME/

# Destroy everything (GCP + Docker)
bash scripts/teardown.sh
```

---

## Troubleshooting

**`keys/sa-key.json` not found**
→ Terraform did not finish. Re-run `bash scripts/setup.sh` or run `cd terraform && terraform apply` manually.

**Airflow shows "Connection refused" on port 8080**
→ Containers are still starting. Wait 60 seconds and refresh.

**DAG 1 fails at `spark_ingest_dataproc_serverless`**
→ Most common cause: Dataproc API not enabled or VPC not ready. Check the task log in Airflow UI for the exact GCP error message. Make sure billing is enabled on your GCP project.

**DAG 1 fails at `download_kaggle_to_gcs`**
→ Check `KAGGLE_USERNAME` and `KAGGLE_KEY` in your `.env`. Re-run `bash scripts/setup.sh` after fixing.

**dbt fails with "Not found: Dataset"**
→ BigQuery dataset was not created. Re-run Terraform: `cd terraform && terraform apply ...`

**`docker exec steam-dbt` fails**
→ The dbt container is not running. Run `docker compose up -d dbt` and retry.

---

## How the secrets work

| Secret | Where it lives | How it gets there |
|--------|---------------|-------------------|
| GCP service account key | `keys/sa-key.json` | Written by `terraform apply` automatically |
| Kaggle credentials | `.env` only | You fill them in; passed to Airflow as Variables via `AIRFLOW_VAR_*` env vars |
| Airflow Fernet key | `.env` only | You generate it once with the Python command |

`keys/sa-key.json` and `.env` are both in `.gitignore` — they are never committed.

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
