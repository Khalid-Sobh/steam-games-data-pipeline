terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.gcp_region
  # credentials = file("../keys/sa-key.json")
}

# ── Enable required GCP APIs ─────────────────────────────────────────────────

resource "google_project_service" "apis" {
  for_each = toset([
    "dataproc.googleapis.com",
    "bigquery.googleapis.com",
    "storage.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ── VPC network (required by Dataproc Serverless) ────────────────────────────

resource "google_compute_network" "pipeline_vpc" {
  name                    = "pipeline-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "pipeline_subnet" {
  name                     = "pipeline-subnet"
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.gcp_region
  network                  = google_compute_network.pipeline_vpc.id
  private_ip_google_access = true
}

# ── GCS buckets ───────────────────────────────────────────────────────────────

resource "google_storage_bucket" "data_lake" {
  name          = var.bucket_name
  location      = var.gcp_location
  force_destroy = true
  depends_on    = [google_project_service.apis]

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 90 }
  }
}

resource "google_storage_bucket" "dataproc_temp" {
  name          = "${var.bucket_name}-dataproc-temp"
  location      = var.gcp_region
  force_destroy = true
  depends_on    = [google_project_service.apis]
}

# Pre-create GCS "folder" prefixes by uploading placeholder files
resource "google_storage_bucket_object" "raw_placeholder" {
  name    = "raw/.keep"
  bucket  = google_storage_bucket.data_lake.name
  content = "placeholder"
}

resource "google_storage_bucket_object" "processed_placeholder" {
  name    = "processed/.keep"
  bucket  = google_storage_bucket.data_lake.name
  content = "placeholder"
}

resource "google_storage_bucket_object" "scripts_placeholder" {
  name    = "scripts/.keep"
  bucket  = google_storage_bucket.data_lake.name
  content = "placeholder"
}

# ── BigQuery dataset ──────────────────────────────────────────────────────────

resource "google_bigquery_dataset" "warehouse" {
  dataset_id = var.bq_dataset
  location   = var.gcp_location
  depends_on = [google_project_service.apis]
}

# ── Service account ───────────────────────────────────────────────────────────

resource "google_service_account" "pipeline_sa" {
  account_id   = "pipeline-sa"
  display_name = "Steam Pipeline Service Account"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "sa_roles" {
  for_each = toset([
    "roles/bigquery.admin",
    "roles/storage.admin",
    "roles/dataproc.editor",
    "roles/dataproc.worker",
    "roles/iam.serviceAccountUser",
    "roles/compute.networkUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.pipeline_sa.email}"
}

resource "google_service_account_key" "pipeline_key" {
  service_account_id = google_service_account.pipeline_sa.name
}

# Write the key file locally so Docker containers can use it
resource "local_file" "sa_key_file" {
  content         = base64decode(google_service_account_key.pipeline_key.private_key)
  filename        = "${path.module}/../keys/sa-key.json"
  file_permission = "0600"
}

resource "google_compute_firewall" "dataproc_internal" {
  name    = "dataproc-internal"
  network = google_compute_network.pipeline_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/24"]
  target_tags   = []
}