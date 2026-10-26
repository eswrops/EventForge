resource "oci_objectstorage_bucket" "terraform_state" {
  compartment_id = var.compartment_ocid
  namespace      = var.object_storage_namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"

  object_events_enabled = false
}

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = var.compartment_ocid
  namespace      = var.object_storage_namespace
  name           = var.backup_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"

  object_events_enabled = false
}

resource "oci_identity_dynamic_group" "eventforge_instances" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-instances"
  description    = "Only the two EventForge application instances."
  matching_rule  = "Any {${join(", ", [for id in var.instance_ocids : "instance.id = '${id}'"])}"
}

resource "oci_identity_policy" "eventforge_instance_backups" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-instance-backups"
  description    = "Permits EventForge instances to write only the backup bucket."

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.eventforge_instances.name} to manage objects in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.eventforge_instances.name} to inspect buckets in compartment id ${var.compartment_ocid} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
  ]
}

resource "oci_identity_policy" "github_oidc" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-github-oidc"
  description    = "Least-privilege authorization for the constrained GitHub production workload identity."
  statements     = [var.github_oidc_policy_statement]
}

resource "oci_ons_notification_topic" "operations" {
  compartment_id = var.compartment_ocid
  name           = "eventforge-operations"
  description    = "Infrastructure and budget alerts for EventForge."
}

resource "oci_ons_subscription" "operations_email" {
  compartment_id = var.compartment_ocid
  topic_id       = oci_ons_notification_topic.operations.id
  protocol       = "EMAIL"
  endpoint       = var.notification_email
}

