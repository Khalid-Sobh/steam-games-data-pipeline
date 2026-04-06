variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "bucket_name" {
  description = "GCS bucket name (must be globally unique)"
  type        = string
}

variable "bq_dataset" {
  description = "BigQuery dataset name"
  type        = string
  default     = "steam_warehouse"
}

variable "gcp_region" {
  description = "GCP region for Dataproc Serverless and VPC (single-region)"
  type        = string
  default     = "us-central1"
}

variable "gcp_location" {
  description = "GCS and BigQuery location (multi-region)"
  type        = string
  default     = "US"
}
