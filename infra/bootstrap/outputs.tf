output "state_bucket_name" {
  value       = oci_objectstorage_bucket.terraform_state.name
  description = "Use this in each root's native OCI backend configuration."
}

output "backup_bucket_name" {
  value = oci_objectstorage_bucket.backups.name
}

output "operations_topic_id" {
  value = oci_ons_notification_topic.operations.id
}

