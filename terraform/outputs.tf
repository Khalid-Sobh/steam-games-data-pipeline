output "bucket_name" {
  description = "GCS data lake bucket name"
  value       = google_storage_bucket.data_lake.name
}

output "dataproc_temp_bucket" {
  description = "Dataproc temporary bucket name"
  value       = google_storage_bucket.dataproc_temp.name
}

output "bq_dataset" {
  description = "BigQuery dataset ID"
  value       = google_bigquery_dataset.warehouse.dataset_id
}

output "sa_email" {
  description = "Service account email"
  value       = google_service_account.pipeline_sa.email
}

output "vpc_subnet" {
  description = "VPC subnet URI for Dataproc Serverless"
  value       = "regions/${var.gcp_region}/subnetworks/${google_compute_subnetwork.pipeline_subnet.name}"
}

output "sa_key_path" {
  description = "Local path to the generated service account key"
  value       = local_file.sa_key_file.filename
}
