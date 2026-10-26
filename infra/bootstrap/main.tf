resource "oci_objectstorage_bucket" "terraform_state" {
  compartment_id = var.compartment_ocid
  namespace      = var.object_storage_namespace
  name           = var.state_bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Enabled"
  kms_key_id     = var.state_bucket_kms_key_id

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

# Terraform state contains sensitive values. Keep versioning enabled for
# recovery, while retaining old versions for a bounded, cost-conscious window.
resource "oci_objectstorage_object_lifecycle_policy" "terraform_state_versions" {
  bucket    = oci_objectstorage_bucket.terraform_state.name
  namespace = var.object_storage_namespace

  rules {
    action      = "DELETE"
    is_enabled  = true
    name        = "expire-noncurrent-state-versions"
    target      = "previous-object-versions"
    time_amount = var.state_version_retention_days
    time_unit   = "DAYS"
  }
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

resource "oci_identity_policy" "github_oidc_plan" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-github-oidc-plan"
  description    = "Read-only OCI access plus Terraform state locking for the constrained GitHub production-plan workload."
  statements     = tolist(var.github_plan_oidc_policy_statements)
}

resource "oci_identity_policy" "github_oidc_apply" {
  compartment_id = var.tenancy_ocid
  name           = "eventforge-github-oidc"
  description    = "Least-privilege apply authorization for the constrained GitHub production workload."
  statements     = tolist(var.github_apply_oidc_policy_statements)
}

# Preserve state for installations created before plan/apply identities were
# split. The existing policy becomes the apply policy; the plan policy is new.
moved {
  from = oci_identity_policy.github_oidc
  to   = oci_identity_policy.github_oidc_apply
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

